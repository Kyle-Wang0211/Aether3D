// sift_nonextrema_suppress.wgsl — GPU spatial-grid nonExtremaSuppression
// (covdet.c:2104-2139, VLFeat nonExtremaSuppression = 0.5 ON by default and NOT
// disabled by COLMAP). Stage S2b of the GPU DSP-SIFT port.
//
// See third_party/glomap_vendor/bench/gpu_extrema_iface.md (S2b section) for the
// canonical interface. INPUT = the dense S2 `Keypoint` survivor buffer produced
// by sift_refine_gate.wgsl (48 bytes/record: x_local,y_local,z_local:f32,
// octave:u32, sigma,step,peak_score,edge_score:f32). OUTPUT = the suppressed
// survivor set (keep-flag, then a compaction pass) — the same set VLFeat's CPU
// O(N^2) suppression leaves behind.
//
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat criterion — line-by-line (covdet.c:2104-2139)
// ════════════════════════════════════════════════════════════════════════════
//  CPU reference (covdet.c:2108-2130), tol = self->nonExtremaSuppression = 0.5
//  (covdet.c:1536 default), x/y = frame.x/frame.y, sigma = frame.a11, score =
//  peakScore:
//
//    for i in features:                       // the JUDGE
//      if score[i] == 0: continue ;           // 2113
//      for j in features:                     // the CANDIDATE to maybe suppress
//        if score[j] == 0: continue ;         // 2120
//        if  sigma[i] < (1+tol)*sigma[j]      // 2121  (scale window, symmetric)
//         && sigma[j] < (1+tol)*sigma[i]      // 2122
//         && |x[j]-x[i]| < tol*sigma[i]       // 2123  (spatial — JUDGE i's sigma)
//         && |y[j]-y[i]| < tol*sigma[i]       // 2124
//         && |score[i]| > |score[j]| :        // 2125  (strict — judge strictly stronger)
//            score[j] = 0 ;                    // 2126  (suppress j, in place)
//    compact: keep features with score != 0  // 2131-2138
//
//  NOTE 1 (the spatial test uses the JUDGE's sigma, covdet.c:2123-2124): the
//  half-window that decides whether `j` is suppressed by `i` is tol*sigma_i, NOT
//  tol*sigma_j. So for a CANDIDATE j the set of judges that can reach it is
//  {i : |x_i-x_j| < tol*sigma_i}. We GATHER per-candidate, so we need a search
//  radius that bounds all such i. The scale window (2121-2122) forces
//  sigma_i < (1+tol)*sigma_j, hence tol*sigma_i < tol*(1+tol)*sigma_j. With
//  tol=0.5 that is < 0.75*sigma_j. So searching a frame-space radius of
//  tol*(1+tol)*sigma_j around j is GUARANTEED to cover every judge that could
//  suppress j (proof above). The kernel uses exactly that radius -> the grid
//  search is a SUPERSET of the candidates VLFeat would test, then the full
//  5-clause predicate (2121-2125) filters bit-for-bit.
//
//  NOTE 2 (strict score compare, covdet.c:2125 `|score| > |score_|`): equal
//  |score| does NOT suppress (a tie keeps both). VLFeat's outer/inner loops also
//  hit the i==j diagonal but the i==j case fails 2125 (|s|>|s| is false), so it
//  is a no-op; we skip j==self explicitly for clarity (identical result).
//
//  NOTE 3 (in-place mutation / order independence, covdet.c:2126): VLFeat zeroes
//  score[j] DURING the double loop, so a zeroed j is skipped both as a future
//  judge AND a future candidate. This is sequential. We implement the
//  ORDER-INDEPENDENT rule "j is suppressed iff THERE EXISTS a judge i (with its
//  ORIGINAL score, all kept) satisfying 2121-2125". These differ ONLY when a
//  feature j that VLFeat zeroed would itself have suppressed some k that no
//  surviving feature suppresses. That requires |s_i|>|s_j|>|s_k| with k in j's
//  box but NOT in i's box. The harness (parity_suppress.cc) MEASURES how often
//  this happens on the real test image (target: survivor sets identical). The
//  fixed-point variant below (run the kernel to convergence) collapses the gap
//  to zero when it occurs; one pass is the fast path, the harness reports both.
//
// ════════════════════════════════════════════════════════════════════════════
//  Spatial grid (bucketed) — NOT O(N^2)
// ════════════════════════════════════════════════════════════════════════════
//  Host bins every keypoint into a uniform frame-space grid (cell_size chosen so
//  a typical suppression box spans ~1 cell; see parity_suppress.cc). Two GPU
//  passes the host orchestrates:
//    PASS A `bin_count`  : per kp, atomicAdd 1 to its cell's counter.
//      (host then prefix-sums the counts -> per-cell start offsets)
//    PASS B `bin_scatter`: per kp, atomicAdd its cell's running cursor -> write
//      the kp index into the sorted-by-cell `cell_items` array.
//    PASS C `suppress`   : per CANDIDATE kp j, scan only the grid cells whose
//      union covers the frame-space disc of radius tol*(1+tol)*sigma_j centred
//      at j (NOTE 1). For each kp i in those cells, evaluate the full 5-clause
//      VLFeat predicate (2121-2125). If ANY qualifying judge exists, mark j
//      suppressed (keep_flag[j] = 0). Else keep_flag[j] = 1.
//  Each candidate touches only O(cells_in_radius * kps_per_cell) neighbours, not
//  N. High-octave (large-sigma) kps scan a wider radius but are few (the octave
//  pyramid shrinks the image 4x/octave), so total work is ~linear.
//
//  The HOST does the prefix-sum (a handful of u32 over a small grid) and the
//  final stream-compaction of kept kps (it already reads keep_flag back). Both
//  are trivially serial on the host and out of the hot path; this file is the
//  three compute entry points.
//
// ════════════════════════════════════════════════════════════════════════════
//  fp discipline
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat does the suppression compare in DOUBLE (covdet.c:2109-2125 all double),
//  reading frame.x/.y/.a11/peakScore which are themselves double-promoted from
//  the fp32 refine outputs. Our Keypoint stores fp32. We compute the predicate in
//  fp32 in-register. The 5 comparisons are against products like (1+tol)*sigma
//  and tol*sigma; an fp32-vs-double rounding flip is possible only for a pair
//  sitting within ~1e-6 of a window boundary. The harness counts those.
//
// ════════════════════════════════════════════════════════════════════════════
//  Bindings (@group(0)) — see bench/gpu_extrema_iface.md (S2b)
// ════════════════════════════════════════════════════════════════════════════
//    binding(0) storage read        kps        : array<Keypoint>  the S2 survivors
//    binding(1) storage read_write  cell_count : array<atomic<u32>>  per-cell
//                                                 counter (PASS A) / cursor (PASS B)
//    binding(2) storage read        cell_start : array<u32>  per-cell start offset
//                                                 (host prefix-sum of PASS A counts)
//    binding(3) storage read_write  cell_items : array<u32>  kp indices sorted by
//                                                 cell (PASS B write target)
//    binding(4) storage read_write  keep_flag  : array<u32>  1=keep 0=suppressed
//                                                 (PASS C write target)
//    binding(5) uniform             P          : SuppressParams
//    binding(6) storage read        alive      : array<u32>  judge alive-status
//                                                 input for the fixed-point
//                                                 iteration (see ORDER below)
//
// ════════════════════════════════════════════════════════════════════════════
//  EXACT VLFeat parity via a fixed-point iteration (resolves NOTE 3)
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat's in-place mutation means a judge i that was itself suppressed by an
//  EARLIER (stronger) judge stops suppressing anyone. The suppression relation
//  "i suppresses j" requires |score_i| > |score_j| (STRICT), so it is a strict
//  DAG ordered by |peakScore| — no cycles. The UNIQUE fixed point of "j is
//  suppressed iff some STILL-ALIVE stronger neighbour suppresses it" therefore
//  equals VLFeat's sequential result exactly (verified: parity_suppress.cc, the
//  3-level chains 9204->23316->2272 and 11543->24271->2850 both resolve). The
//  host drives the iteration: `alive` starts all-1; each pass the judge loop
//  skips i with alive[i]==0; output keep_flag is copied back into alive; repeat
//  until keep_flag is stable (typically 2-3 passes; chains are short). A SINGLE
//  pass (alive all-1) is the fast approximate path — within ~1e-4 of exact
//  (2/26416 differ on the test image) — the harness reports both.

struct Keypoint {
  x_local   : f32,
  y_local   : f32,
  z_local   : f32,
  octave    : u32,
  sigma     : f32,
  step      : f32,
  peak_score: f32,
  edge_score: f32,
};

struct SuppressParams {
  num_kp     : u32,   // number of input keypoints
  grid_w     : u32,   // grid columns
  grid_h     : u32,   // grid rows
  num_cells  : u32,   // grid_w * grid_h (cell_count / cell_start length)
  cell_size  : f32,   // frame-space cell edge length (px)
  tol        : f32,   // nonExtremaSuppression threshold (0.5)
  _pad0      : u32,
  _pad1      : u32,
};

@group(0) @binding(0) var<storage, read>       kps        : array<Keypoint>;
@group(0) @binding(1) var<storage, read_write> cell_count : array<atomic<u32>>;
@group(0) @binding(2) var<storage, read>       cell_start : array<u32>;
@group(0) @binding(3) var<storage, read_write> cell_items : array<u32>;
@group(0) @binding(4) var<storage, read_write> keep_flag  : array<u32>;
@group(0) @binding(5) var<uniform>             P          : SuppressParams;
@group(0) @binding(6) var<storage, read>       alive      : array<u32>;

// Frame-space x for kp k: frame.x = x_local*step (+0.5 host-side; the +0.5
// cancels in every difference x_j-x_i, so we omit it — the predicate only ever
// uses DIFFERENCES of frame coords, covdet.c:2116-2117). Likewise frame.y.
fn frame_x(k : u32) -> f32 { return kps[k].x_local * kps[k].step; }
fn frame_y(k : u32) -> f32 { return kps[k].y_local * kps[k].step; }

// Cell coordinate of a frame-space point. Clamped to [0,grid-1]. frame coords
// are >= 0 (x_local,y_local in [0,dim-1]); clamp guards fp edge cases.
fn cell_of(fx : f32, fy : f32) -> vec2<u32> {
  let cs : f32 = P.cell_size;
  var cx : i32 = i32(floor(fx / cs));
  var cy : i32 = i32(floor(fy / cs));
  cx = clamp(cx, 0, i32(P.grid_w) - 1);
  cy = clamp(cy, 0, i32(P.grid_h) - 1);
  return vec2<u32>(u32(cx), u32(cy));
}

// The Dawn harness derives ONE bind-group layout per entry point from the
// bindings reachable in that entry's call graph, and binds a fixed index->binding
// vector. To keep the SAME 6-binding layout across all three entry points (so
// the harness can reuse one bind vector), every entry references all 6 bindings.
// `touch_all_bindings` is a reachable no-op: it reads cell_start/cell_items and
// conditionally writes keep_flag under a guard that is never true at dispatch
// (gid past num_kp early-outs before this runs), so the bindings enter the
// layout without changing behaviour.
fn touch_all_bindings(k : u32) {
  // statically reaches cell_count(1), cell_start(2), cell_items(3),
  // keep_flag(4), alive(6) — never has a runtime effect because callers guard
  // k < num_kp and this branch needs k >= num_kp (no invocation satisfies both).
  if (k >= P.num_kp) {
    let z : u32 = atomicLoad(&cell_count[0]);
    let a : u32 = cell_start[0];
    let b : u32 = cell_items[0];
    let d : u32 = alive[0];
    keep_flag[0] = z + a + b + d;
  }
}

// ── PASS A: count kps per cell. ──
@compute @workgroup_size(64, 1, 1)
fn bin_count(@builtin(global_invocation_id) gid : vec3<u32>) {
  let k : u32 = gid.x;
  touch_all_bindings(k);
  if (k >= P.num_kp) { return; }
  let c : vec2<u32> = cell_of(frame_x(k), frame_y(k));
  let cell : u32 = c.y * P.grid_w + c.x;
  atomicAdd(&cell_count[cell], 1u);
}

// ── PASS B: scatter kp indices into cell_items, bucketed by cell. ──
// cell_count has been RESET to 0 by the host (it is reused as a per-cell write
// cursor). cell_start[cell] is the host prefix-sum of the PASS A counts.
@compute @workgroup_size(64, 1, 1)
fn bin_scatter(@builtin(global_invocation_id) gid : vec3<u32>) {
  let k : u32 = gid.x;
  touch_all_bindings(k);   // keep the 6-binding layout uniform across passes
  if (k >= P.num_kp) { return; }
  let c : vec2<u32> = cell_of(frame_x(k), frame_y(k));
  let cell : u32 = c.y * P.grid_w + c.x;
  let slot : u32 = atomicAdd(&cell_count[cell], 1u);
  cell_items[cell_start[cell] + slot] = k;
}

// ── PASS C: per-candidate suppression test over neighbour cells. ──
@compute @workgroup_size(64, 1, 1)
fn suppress(@builtin(global_invocation_id) gid : vec3<u32>) {
  let j : u32 = gid.x;
  touch_all_bindings(j);   // keep the 6-binding layout uniform across passes
  if (j >= P.num_kp) { return; }

  let tol     : f32 = P.tol;
  let onep    : f32 = 1.0 + tol;       // (1+tol)
  let xj      : f32 = frame_x(j);
  let yj      : f32 = frame_y(j);
  let sigj    : f32 = kps[j].sigma;    // frame.a11 (covdet.c:2032 a11==sigma)
  let scorej  : f32 = kps[j].peak_score;
  let absj    : f32 = abs(scorej);

  // A score==0 input kp is already "suppressed" upstream (covdet.c:2120 skips
  // it as a candidate). Match: keep it out of the survivor set.
  if (scorej == 0.0) { keep_flag[j] = 0u; return; }

  // Search radius (frame px) that bounds every judge i able to reach j:
  // tol*sigma_i with sigma_i < (1+tol)*sigma_j  =>  radius = tol*(1+tol)*sigma_j
  // (NOTE 1 in the header — a guaranteed superset; the exact predicate filters).
  let radius : f32 = tol * onep * sigj;

  // Grid cell span covering [xj-radius, xj+radius] x [yj-radius, yj+radius].
  let cs   : f32 = P.cell_size;
  let gw   : i32 = i32(P.grid_w);
  let gh   : i32 = i32(P.grid_h);
  let cx0  : i32 = clamp(i32(floor((xj - radius) / cs)), 0, gw - 1);
  let cx1  : i32 = clamp(i32(floor((xj + radius) / cs)), 0, gw - 1);
  let cy0  : i32 = clamp(i32(floor((yj - radius) / cs)), 0, gh - 1);
  let cy1  : i32 = clamp(i32(floor((yj + radius) / cs)), 0, gh - 1);

  var suppressed : bool = false;

  for (var cy : i32 = cy0; cy <= cy1 && !suppressed; cy = cy + 1) {
    for (var cx : i32 = cx0; cx <= cx1 && !suppressed; cx = cx + 1) {
      let cell  : u32 = u32(cy) * P.grid_w + u32(cx);
      let start : u32 = cell_start[cell];
      // count for this cell = cell_start[cell+1]-cell_start[cell]; cell_start is
      // length num_cells+1 (host appends the total as the final sentinel).
      let stop  : u32 = cell_start[cell + 1u];
      for (var t : u32 = start; t < stop; t = t + 1u) {
        let i : u32 = cell_items[t];
        if (i == j) { continue; }                 // i==j is a 2125 no-op; skip
        if (alive[i] == 0u) { continue; }          // fixed-point: dead judges
                                                   // stop suppressing (covdet.c
                                                   // :2113 in-place semantics)
        let scorei : f32 = kps[i].peak_score;
        if (scorei == 0.0) { continue; }           // covdet.c:2113 judge skip
        let sigi   : f32 = kps[i].sigma;
        // 5-clause VLFeat predicate (covdet.c:2121-2125), fp32:
        //   sigma_i < (1+tol)*sigma_j  &&  sigma_j < (1+tol)*sigma_i
        //   && |x_i-x_j| < tol*sigma_i && |y_i-y_j| < tol*sigma_i
        //   && |score_i| > |score_j|
        let dx : f32 = frame_x(i) - xj;            // covdet.c:2116 (i is the j-loop var there)
        let dy : f32 = frame_y(i) - yj;            // covdet.c:2117
        let tsi : f32 = tol * sigi;                // tol*sigma_i (judge's sigma)
        if (sigi < onep * sigj &&
            sigj < onep * sigi &&
            abs(dx) < tsi &&
            abs(dy) < tsi &&
            abs(scorei) > absj) {
          suppressed = true;
        }
      }
    }
  }

  keep_flag[j] = select(1u, 0u, suppressed);
}
