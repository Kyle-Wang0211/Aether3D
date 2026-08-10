// sift_gss_blur_fused.wgsl — H+V 融合可分离高斯(FidelityFX Blur 结构)。
//
// [GSS-FUSED 2026-08-10] 结构抄 AMD FidelityFX Blur(MIT):每个 workgroup
// 认领一条 8 像素宽的纵向条带,自上而下滑动;H 结果存 workgroup 共享内存
// 环形缓冲(每行只算一次,零 halo 重算),V 直接消费环形缓冲写出 —— 旧
// 2-pass 路径的 scratch 全局往返(写 w*h + 读 w*h*(2R+1))整段消失。
//
// ⚠️ 数学与 sift_gss_blur.wgsl 逐位相同:H 的 k 循环、clamp-to-edge、V 的
// k 循环全部原序原样;中间量 f32(与旧路 scratch 的 f32 存储同精度)⇒
// 输出与 2-pass 路径 bit-identical(唯一区别是中间值住共享内存而非全局)。
//
// src 与 dst 都是 packed 大缓冲的不相交层区间;WebGPU 禁止同 buffer 在一个
// dispatch 内 read+read_write 双绑定,故单一 read_write 绑定 + 双偏移。
//
// 约束:radius <= 16(环形缓冲 40 行 >= 2*16+8);host 超限自动回落 2-pass。

struct Params {
  width   : u32,
  height  : u32,
  radius  : u32,   // kernel half-width; full length = 2*radius + 1
  src_off : u32,   // packed 大缓冲内的 src 层 element 偏移
  dst_off : u32,
  _pad0   : u32,
  _pad1   : u32,
  _pad2   : u32,
};

@group(0) @binding(0) var<storage, read_write> data : array<f32>;
@group(0) @binding(1) var<storage, read>       taps : array<f32>;
@group(0) @binding(2) var<uniform>             P    : Params;

const RS : u32 = 40u;                       // 环形缓冲行数 >= 2*R_MAX+8
var<workgroup> ring : array<f32, 320>;      // RS * 8 列

fn clampi(v : i32, lo : i32, hi : i32) -> i32 {
  return max(lo, min(v, hi));
}

// 与 sift_gss_blur.wgsl 的 axis==0 分支逐位相同的 H 卷积。
fn h_blur_at(x : i32, y : i32) -> f32 {
  let w    : i32 = i32(P.width);
  let base : i32 = y * w;
  let r    : i32 = i32(P.radius);
  let len  : i32 = 2 * r + 1;
  var acc  : f32 = 0.0;
  for (var k : i32 = 0; k < len; k = k + 1) {
    let sx : i32 = clampi(x + (k - r), 0, w - 1);
    acc = acc + taps[k] * data[P.src_off + u32(base + sx)];
  }
  return acc;
}

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(workgroup_id) wid : vec3<u32>,
        @builtin(local_invocation_id) lid : vec3<u32>) {
  let tx : u32 = lid.x % 8u;        // 条带内列
  let ty : u32 = lid.x / 8u;        // 块内行
  let x  : u32 = wid.x * 8u + tx;
  let w  : u32 = P.width;
  let h  : i32 = i32(P.height);
  let r  : i32 = i32(P.radius);

  // 预载 H 行 0 .. min(7+r, h-1)(块 0 的 V 支持域;负行 clamp 到 0)。
  let pre : i32 = min(8 + r, h);
  for (var row : i32 = i32(ty); row < pre; row = row + 8) {
    if (x < w) {
      ring[(u32(row) % RS) * 8u + tx] = h_blur_at(i32(x), row);
    }
  }
  var loaded : i32 = pre;

  var yb : i32 = 0;
  loop {
    if (yb >= h) { break; }
    workgroupBarrier();  // 预载/上一轮补载对全组可见

    // V:与 sift_gss_blur.wgsl 的 axis==1 分支逐位相同(k 原序,行 clamp),
    // 只是采样源从全局 scratch 换成环形缓冲里的同值 f32。
    let y : i32 = yb + i32(ty);
    if (y < h && x < w) {
      let len : i32 = 2 * r + 1;
      var acc : f32 = 0.0;
      for (var k : i32 = 0; k < len; k = k + 1) {
        let sy : i32 = clampi(y + (k - r), 0, h - 1);
        acc = acc + taps[k] * ring[(u32(sy) % RS) * 8u + tx];
      }
      data[P.dst_off + u32(y) * w + x] = acc;
    }
    workgroupBarrier();  // 本块 V 读完后才允许覆写环形缓冲

    // 补载下一块所需 H 行(每行只算一次;RS>=2r+8 保证不覆写在用行)。
    let need : i32 = min(h, yb + 16 + r);
    for (var row : i32 = loaded + i32(ty); row < need; row = row + 8) {
      if (x < w) {
        ring[(u32(row) % RS) * 8u + tx] = h_blur_at(i32(x), row);
      }
    }
    loaded = max(loaded, need);
    yb = yb + 8;
  }
}
