// sift_suppress_grid_count.wgsl — [K7 2026-09-06] 非极值抑制网格分桶,pass 1:
// 每个候选按 (x,y) 落进 cell 像素见方的格子,原子计数。整数计数,顺序无关。
const KP_STRIDE : u32 = 8u;
struct Params { count : u32, tol : f32, width : u32, height : u32, cell : u32, ncx : u32, ncy : u32, ncells : u32, };
@group(0) @binding(0) var<storage, read>       kp_buffer  : array<u32>;
@group(0) @binding(1) var<storage, read_write> cell_count : array<atomic<u32>>;
@group(0) @binding(2) var<uniform>             P          : Params;
fn cell_of(i : u32) -> u32 {
  let x = bitcast<f32>(kp_buffer[i * KP_STRIDE + 0u]);
  let y = bitcast<f32>(kp_buffer[i * KP_STRIDE + 1u]);
  let cx = clamp(i32(floor(x / f32(P.cell))), 0, i32(P.ncx) - 1);
  let cy = clamp(i32(floor(y / f32(P.cell))), 0, i32(P.ncy) - 1);
  return u32(cy) * P.ncx + u32(cx);
}
@compute @workgroup_size(64, 1, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let i = gid.x;
  if (i >= P.count) { return; }
  atomicAdd(&cell_count[cell_of(i)], 1u);
}
