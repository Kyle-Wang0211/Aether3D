// sift_suppress_grid_scatter.wgsl — [K7 2026-09-06] pass 3:把候选下标散射进
// 各自格子的区间(格内顺序由原子游标决定,无序;抑制谓词是集合上的 OR,
// 与格内顺序无关)。
const KP_STRIDE : u32 = 8u;
struct Params { count : u32, tol : f32, width : u32, height : u32, cell : u32, ncx : u32, ncy : u32, ncells : u32, };
@group(0) @binding(0) var<storage, read>       kp_buffer   : array<u32>;
@group(0) @binding(1) var<storage, read>       cell_start  : array<u32>;
@group(0) @binding(2) var<storage, read_write> cell_cursor : array<atomic<u32>>;
@group(0) @binding(3) var<storage, read_write> cell_items  : array<u32>;
@group(0) @binding(4) var<uniform>             P           : Params;
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
  let c = cell_of(i);
  let slot = cell_start[c] + atomicAdd(&cell_cursor[c], 1u);
  cell_items[slot] = i;
}
