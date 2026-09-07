// sift_suppress_grid_scan.wgsl — [K7 2026-09-06] pass 2:单 workgroup 对
// ncells 个格子计数做 exclusive 前缀和,写 cell_start[0..ncells](末项 = 总数)。
// 纯整数,确定性。
struct Params { count : u32, tol : f32, width : u32, height : u32, cell : u32, ncx : u32, ncy : u32, ncells : u32, };
@group(0) @binding(0) var<storage, read>       cell_count : array<u32>;
@group(0) @binding(1) var<storage, read_write> cell_start : array<u32>;
@group(0) @binding(2) var<uniform>             P          : Params;
const WG : u32 = 256u;
var<workgroup> part : array<u32, 256>;
@compute @workgroup_size(256, 1, 1)
fn main(@builtin(local_invocation_id) lid : vec3<u32>) {
  let t = lid.x;
  let n = P.ncells;
  let chunk = (n + WG - 1u) / WG;
  let lo = min(t * chunk, n);
  let hi = min(lo + chunk, n);
  var s : u32 = 0u;
  for (var c = lo; c < hi; c = c + 1u) { s = s + cell_count[c]; }
  part[t] = s;
  workgroupBarrier();
  if (t == 0u) {
    var run : u32 = 0u;
    for (var k = 0u; k < WG; k = k + 1u) { let v = part[k]; part[k] = run; run = run + v; }
    cell_start[n] = run;
  }
  workgroupBarrier();
  var run2 : u32 = part[t];
  for (var c = lo; c < hi; c = c + 1u) { cell_start[c] = run2; run2 = run2 + cell_count[c]; }
}
