// sift_gss_blur_fused.wgsl — H+V 融合可分离高斯(FidelityFX Blur 结构)。
// [K2a 2026-09-06] 在 GSS-FUSED 基础上把 H 的源像素段(8+2r 列 × 8 行)先
// 协作搬进共享内存 seg,再由 seg 做 H 卷积;taps 也搬进共享内存。
// 数学逐位不变:H 的 k 循环原序原样,每个 seg 元素就是原来 clamp 后读到的
// 同一个 f32 值,乘加顺序不变 ⇒ 与 GSS-FUSED 输出 bit-identical。
// 全局载入从每像素 (2r+1) 次降到每像素 ceil((8+2r)/8) ≤ 5 次。
// 绑定/Params/dispatch 几何与 GSS-FUSED 完全相同(host 零改动)。
// 约束:radius <= 16(seg 40 列 >= 8+2*16;ring 40 行 >= 2*16+8)。

struct Params {
  width   : u32,
  height  : u32,
  radius  : u32,
  src_off : u32,
  dst_off : u32,
  _pad0   : u32,
  _pad1   : u32,
  _pad2   : u32,
};

@group(0) @binding(0) var<storage, read_write> data : array<f32>;
@group(0) @binding(1) var<storage, read>       taps : array<f32>;
@group(0) @binding(2) var<uniform>             P    : Params;

const BR  : u32 = 32u;                      // [K2d] 每块行数(线程数 = 8*BR)
const RS  : u32 = 64u;                      // [K2b] 环形缓冲行数取 2 的幂 ⇒ 取模变按位与(仅索引,数值不变)
const SEG : u32 = 40u;                      // 源段列数 = 8 + 2*R_MAX
var<workgroup> ring : array<f32, 512>;      // RS * 8 列
var<workgroup> seg  : array<f32, 1280>;      // BR 行 × SEG 列(clamp 后的源值)
var<workgroup> tp   : array<f32, 33>;       // taps 副本

fn clampi(v : i32, lo : i32, hi : i32) -> i32 {
  return max(lo, min(v, hi));
}

// 把源行 [row0, row0+n) 的列段 [x0-r, x0+8+r) 搬进 seg(clamp-to-edge)。
// 线程 (tx,ty) 负责行 ty、列 tx, tx+8, ...(< 8+2r)。
fn stage_rows(row0 : i32, n : i32, x0 : i32, tx : u32, ty : u32) {
  let w   : i32 = i32(P.width);
  let r   : i32 = i32(P.radius);
  let cols : i32 = 8 + 2 * r;
  if (i32(ty) < n) {
    let base : i32 = (row0 + i32(ty)) * w;
    for (var j : i32 = i32(tx); j < cols; j = j + 8) {
      let sx : i32 = clampi(x0 + j - r, 0, w - 1);
      seg[ty * SEG + u32(j)] = data[P.src_off + u32(base + sx)];
    }
  }
}

// 与 sift_gss_blur.wgsl 的 axis==0 分支逐位相同的 H 卷积(源取自 seg 行 ty)。
fn h_blur_seg(tx : u32, ty : u32) -> f32 {
  let r   : i32 = i32(P.radius);
  let len : i32 = 2 * r + 1;
  let sb  : u32 = ty * SEG + tx;
  var acc : f32 = 0.0;
  for (var k : i32 = 0; k < len; k = k + 1) {
    acc = acc + tp[k] * seg[sb + u32(k)];
  }
  return acc;
}

@compute @workgroup_size(256, 1, 1)
fn main(@builtin(workgroup_id) wid : vec3<u32>,
        @builtin(local_invocation_id) lid : vec3<u32>) {
  let tx : u32 = lid.x % 8u;
  let ty : u32 = lid.x / 8u;
  let x0 : i32 = i32(wid.x * 8u);
  let x  : u32 = wid.x * 8u + tx;
  let w  : u32 = P.width;
  let h  : i32 = i32(P.height);
  let r  : i32 = i32(P.radius);
  let len : i32 = 2 * r + 1;
  if (i32(lid.x) < len) { tp[lid.x] = taps[lid.x]; }

  // 预载 H 行 0 .. pre-1(块 0 的 V 支持域),按 8 行一段分批经 seg。
  let pre : i32 = min(i32(BR) + r, h);
  var row0 : i32 = 0;
  loop {
    if (row0 >= pre) { break; }
    let n : i32 = min(i32(BR), pre - row0);
    stage_rows(row0, n, x0, tx, ty);
    workgroupBarrier();
    if (i32(ty) < n && x < w) {
      ring[(u32(row0 + i32(ty)) & (RS - 1u)) * 8u + tx] = h_blur_seg(tx, ty);
    }
    workgroupBarrier();
    row0 = row0 + i32(BR);
  }
  var loaded : i32 = pre;

  var yb : i32 = 0;
  loop {
    if (yb >= h) { break; }
    workgroupBarrier();  // 预载/上一轮补载对全组可见

    // V:与 sift_gss_blur.wgsl 的 axis==1 分支逐位相同(k 原序,行 clamp)。
    let y : i32 = yb + i32(ty);
    if (y < h && x < w) {
      var acc : f32 = 0.0;
      for (var k : i32 = 0; k < len; k = k + 1) {
        let sy : i32 = clampi(y + (k - r), 0, h - 1);
        acc = acc + tp[k] * ring[(u32(sy) & (RS - 1u)) * 8u + tx];
      }
      data[P.dst_off + u32(y) * w + x] = acc;
    }
    workgroupBarrier();  // 本块 V 读完后才允许覆写环形缓冲

    // 补载下一块所需 H 行 [loaded, need)(稳态每块 8 行,一线程一行)。
    let need : i32 = min(h, yb + 2 * i32(BR) + r);
    let n : i32 = need - loaded;
    if (n > 0) {
      stage_rows(loaded, n, x0, tx, ty);
      workgroupBarrier();
      if (i32(ty) < n && x < w) {
        ring[(u32(loaded + i32(ty)) & (RS - 1u)) * 8u + tx] = h_blur_seg(tx, ty);
      }
      loaded = need;
    }
    yb = yb + i32(BR);
  }
}
