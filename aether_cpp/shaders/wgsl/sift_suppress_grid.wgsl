// sift_suppress_grid.wgsl — [K7 2026-09-06] pass 4:网格分桶版非极值抑制。
// 谓词与 sift_nonextrema_suppress.wgsl 逐字符相同;唯一区别是候选 i 只从
// 可能满足空间条件的格子里取。证明:i 能压制 j 需 si < (1+tol)*sj 且
// |dx| < tol*si;tol=0.5 是 2 的幂 ⇒ tol*si 精确,且 si < fl((1+tol)*sj)
// ⇒ tol*si < tol*fl((1+tol)*sj) = R(精确)⇒ |dx| < R,|dy| < R。
// 扫 [xj-R, xj+R]×[yj-R, yj+R] 覆盖的格子(各留 1 格余量)⇒ 候选集是
// 原全集里所有可能压制者的超集;谓词是 OR ⇒ keep[j] 逐位相同。
const KP_STRIDE : u32 = 8u;
struct Params { count : u32, tol : f32, width : u32, height : u32, cell : u32, ncx : u32, ncy : u32, ncells : u32, };
@group(0) @binding(0) var<storage, read>       kp_buffer  : array<u32>;
@group(0) @binding(1) var<storage, read>       cell_start : array<u32>;   // ncells+1
@group(0) @binding(2) var<storage, read>       cell_items : array<u32>;
@group(0) @binding(3) var<storage, read_write> keep       : array<u32>;
@group(0) @binding(4) var<uniform>             P          : Params;
fn kp_x(i : u32)     -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 0u]); }
fn kp_y(i : u32)     -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 1u]); }
fn kp_sigma(i : u32) -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 2u]); }
fn kp_score(i : u32) -> f32 { return bitcast<f32>(kp_buffer[i * KP_STRIDE + 3u]); }
@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let j : u32 = gid.x;
  if (j >= P.count) { return; }
  let xj : f32 = kp_x(j);
  let yj : f32 = kp_y(j);
  let sj : f32 = kp_sigma(j);
  let scj : f32 = abs(kp_score(j));
  let onePlusTol : f32 = 1.0 + P.tol;
  let R : f32 = P.tol * (onePlusTol * sj);
  let cs : f32 = f32(P.cell);
  let cx0 = clamp(i32(floor((xj - R) / cs)) - 1, 0, i32(P.ncx) - 1);
  let cx1 = clamp(i32(floor((xj + R) / cs)) + 1, 0, i32(P.ncx) - 1);
  let cy0 = clamp(i32(floor((yj - R) / cs)) - 1, 0, i32(P.ncy) - 1);
  let cy1 = clamp(i32(floor((yj + R) / cs)) + 1, 0, i32(P.ncy) - 1);
  var suppressed : bool = false;
  for (var cy = cy0; cy <= cy1 && !suppressed; cy = cy + 1) {
    for (var cx = cx0; cx <= cx1 && !suppressed; cx = cx + 1) {
      let c = u32(cy) * P.ncx + u32(cx);
      let b = cell_start[c];
      let e = cell_start[c + 1u];
      for (var q = b; q < e; q = q + 1u) {
        let i = cell_items[q];
        if (i == j) { continue; }
        let si : f32 = kp_sigma(i);
        let sci : f32 = abs(kp_score(i));
        if (sj < onePlusTol * si && si < onePlusTol * sj &&
            abs(kp_x(i) - xj) < P.tol * si && abs(kp_y(i) - yj) < P.tol * si &&
            sci > scj) {
          suppressed = true;
          break;
        }
      }
    }
  }
  keep[j] = select(1u, 0u, suppressed);
}
