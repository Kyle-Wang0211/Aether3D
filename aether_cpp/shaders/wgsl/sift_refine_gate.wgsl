// sift_refine_gate.wgsl — GPU DSP-SIFT Stage-2 per-candidate Newton subpixel
// refine + peak/edge gates + survivor compaction (atomic-append).
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, S2 scope:
//   "GPU compaction (scan) + Newton refine + gates -> finish detection on GPU".
// Stage gate (PLAN line 68): kp recall/precision >= 0.97, median pos-err <=
// 0.05px.
//
// INPUT  = the S1 candidate buffer (CandidateExtremum records, integer DoG
//          voxel (octave,level,x,y) + dog_value) produced by
//          sift_dog_extrema_test.wgsl. See bench/gpu_extrema_iface.md.
// OUTPUT = a DENSE keypoint buffer of SURVIVORS: refined subpixel (x,y) in
//          octave-local css coordinates + refined subpixel scale z + the
//          octave + per-octave step + peak/edge scores + frame sigma. The host
//          maps (octave-local x,y,z, step) -> image-space frame exactly as
//          VLFeat covdet.c:2027-2037 does (and the host can re-derive sigma; we
//          also emit it for convenience). Layout documented at the bottom + in
//          bench/gpu_extrema_iface.md (extended for S2).
//
// ════════════════════════════════════════════════════════════════════════════
//  COMPACTION CHOICE — atomic-append (NOT prefix-sum scan + scatter)
// ════════════════════════════════════════════════════════════════════════════
//  The PLAN offers two options ("compaction via prefix_sum_scan + sort_scatter,
//  OR warp-aggregated atomic"). This kernel uses a single `atomic<u32>` append.
//  Justification:
//   * The S1 candidates are ALREADY a dense compact array (atomic-appended in
//     S1), so there is no per-voxel keep-flag MAP to Blelloch-scan — the scan
//     route would require us to first MATERIALIZE a keep-flag array sized to the
//     candidate count, run a multi-dispatch scan, then a scatter pass (3
//     dispatches + 2 scratch buffers) just to compact a list that one atomic
//     counter compacts in a single dispatch.
//   * The survivor count is SMALL: ~8k survivors out of ~37k candidates on the
//     4224x2376 test image (the gates reject most), so global atomic contention
//     on ONE counter is one increment per SURVIVOR (not per candidate) — cheap.
//   * S1 already proved atomic-append + count readback is <1ms at this scale,
//     and used the identical idiom. Reusing it keeps detection a one-dispatch
//     GPU stage with one tiny count readback, matching the PLAN's "ONE forced
//     round-trip / frame" goal.
//  The scan/scatter primitives stay reserved for S5a (radix sort by octave/scale
//  + the 8192 clamp), where there IS a sort key and the scan pattern fits.
//
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat parity — line-by-line correspondence
//  (covdet.c / mathop.c in third_party/glomap_vendor/colmap-src/thirdparty/VLFeat)
// ════════════════════════════════════════════════════════════════════════════
//
//  (1) DoG sample recompute — same as S1: css[lvl](x,y) = gss[lvl] - gss[lvl+1]
//      (_vl_dog_response sign, covdet.c:1898-1907 / call site 1966-1969). fp32
//      in-register, recomputed on demand from the resident gss (PLAN "DoG =
//      adjacent gss subtract, FUSED, never materialize css"). The refine reads a
//      3x3x3 neighbourhood of css around the (possibly relocated) voxel.
//
//  (2) Newton subpixel refine — vl_refine_local_extreum_3 (covdet.c:1206-1318):
//        for iter in 0..4 (<=5 iters, covdet.c:1233):
//          x += dx ; y += dy ;                              (1234-1235)
//          gradient (central diff, *0.5):
//            Dx = 0.5*(at(+1,0,0)-at(-1,0,0)), Dy, Dz       (1239-1241)
//          Hessian (2nd diff):
//            Dxx = at(+1,0,0)+at(-1,0,0)-2*at(0,0,0), Dyy, Dzz   (1244-1246)
//            Dxy = 0.25*(at(+1,+1,0)+at(-1,-1,0)-at(-1,+1,0)-at(+1,-1,0)), Dxz, Dyz (1248-1250)
//          A = [[Dxx,Dxy,Dxz],[Dxy,Dyy,Dyz],[Dxz,Dyz,Dzz]], b = -[Dx,Dy,Dz] (1253-1262)
//          err = vl_solve_linear_system_3(b, A, b)          (1264) -> b := A^-1 b
//          if err != OK: b = 0; break;                      (1266-1271)
//          dx = (b0>0.6 && x<W-2 ? 1:0) + (b0<-0.6 && x>1 ? -1:0)   (1275-1276)
//          dy = (b1>0.6 && y<H-2 ? 1:0) + (b1<-0.6 && y>1 ? -1:0)   (1278-1279)
//          if dx==0 && dy==0: break ;                        (1281)
//        NOTE the relocation moves ONLY x and y by +-1 (never z): VLFeat's loop
//        adjusts dx,dy only (1275-1279) — z is refined purely by the b[2] offset.
//        NOTE the bound test uses the PRE-increment x (x < W-2 etc.), matching
//        VLFeat's expression order (the `x += dx` for the NEXT iter is at loop
//        top 1234, after this iter's dx is computed).
//
//      vl_solve_linear_system_3 (mathop.c:839-860) = vl_gaussian_elimination on
//      the augmented 3x4 [A|b] with PARTIAL PIVOTING (max-abs pivot per column,
//      mathop.c:935-945), singular if max|pivot| < 1e-10 -> VL_ERR_OVERFLOW
//      (948), then forward-eliminate (971-977) + back-substitute (997-1007).
//      Reimplemented inline here (gauss3x4) bit-for-bit on the SAME ops; fp32
//      in-register (VLFeat uses double — see fp32 discipline note below).
//
//  (3) Scores (covdet.c:1286-1296, computed from the LAST-iter gradient/Hessian
//      and the LAST solved offset b):
//        peakScore = at(0,0,0) + 0.5*(Dx*b0 + Dy*b1 + Dz*b2)     (1286-1287)
//        alpha     = (Dxx+Dyy)^2 / (Dxx*Dyy - Dxy*Dxy)           (1288)
//        edgeScore = alpha<0 ? +INF
//                            : (0.5*alpha-1) + sqrt(max(0.25*alpha-1,0)*alpha) (1291-1296)
//      `at(0,0,0)` here is css at the FINAL (relocated) voxel — i.e. the kernel
//      re-reads css at the current (x,y,z) after the loop (covdet.c reuses `pt`
//      from the last iteration, which points at the final x,y,z; we recompute).
//
//  (4) Stability / accept (vl_refine_local_extreum_3 return, covdet.c:1307-1314):
//        refined.x = x + b0 ; refined.y = y + b1 ; refined.z = z + b2 (1301-1303)
//        ok_refine = (err==OK) && |b0|<1.5 && |b1|<1.5 && |b2|<1.5
//                    && 0<=refined.x<=W-1 && 0<=refined.y<=H-1 && 0<=refined.z<=D-1
//
//  (5) Peak + edge gates (vl_covdet_detect, covdet.c:2024-2025):
//        ok &= fabs(refined.peakScore) > peakThreshold
//        ok &= refined.edgeScore       < edgeThreshold
//      COLMAP defaults (sift.h:43-58): peakThreshold = 0.02/octave_resolution =
//      0.02/3, edgeThreshold = 10.0. Host supplies both (peak_threshold here is
//      the FULL peakThreshold, NOT the 0.8x detect pre-gate — covdet.c:2024 uses
//      the un-scaled peakThreshold for the post-refine peak gate).
//
//  (6) Frame mapping (covdet.c:2027-2037), done HOST-side from our output, but we
//      also emit sigma for convenience:
//        sigma   = baseScale * 2^( octave + (refined.z + octaveFirstSubdivision)
//                                            / octaveResolution )
//        frame.x = refined.x * step ; frame.y = refined.y * step
//        feature.s = round(refined.z)   ; feature.o = octave
//      (COLMAP then adds +0.5 to x,y: sift.cc:422-423.)
//      NOTE on z indexing: our `level` is css-LOCAL (z, 0-based; == s -
//      octaveFirstSubdivision), exactly the `extrema[3i+2]` z that
//      vl_find_local_extrema_3 emits (covdet.c:1115-1117) and that
//      vl_refine_local_extreum_3 receives as `z` (covdet.c:1209). So refined.z
//      is css-local; sigma re-adds octaveFirstSubdivision (covdet.c:2028). We
//      pass octaveFirstSubdivision / octaveResolution / baseScale in Params.
//
//  NON-EXTREMA SUPPRESSION (covdet.c:2104-2139, nonExtremaSuppression=0.5 ON by
//  VLFeat default and NOT disabled by COLMAP) is a GLOBAL O(N^2) pass over the
//  FINAL frame-space feature list (suppresses a kp if a stronger kp sits within
//  tol*sigma spatially AND within (1+tol) in scale). It is NOT part of per-
//  candidate refine — it cannot run in this one-invocation-per-candidate kernel
//  and is deferred (host post-pass / a later GPU stage). The validation harness
//  measures parity BOTH ways (vs VLFeat's pre-suppression and post-suppression
//  feature list) so the suppression's effect is quantified, not hidden.
//
// ════════════════════════════════════════════════════════════════════════════
//  fp32 discipline (PLAN line 58-62)
// ════════════════════════════════════════════════════════════════════════════
//  WGSL has no f64. VLFeat does the refine in DOUBLE. We do the entire refine,
//  the Gaussian-elimination solve, and the scores in fp32 in-register (the gss
//  itself is fp32 here; the production store is fp16 with fp32 in-register). The
//  expected divergence vs VLFeat is at:
//   * the singular cutoff (|pivot| < 1e-10): fp32 rounding can flip OK/overflow
//     on a near-degenerate Hessian.
//   * the >0.6 relocation branch and the <1.5 / [0,dim-1] accept bounds: an
//     offset landing within ~1e-6 of 0.6 / 1.5 / a border can flip in fp32.
//   * the edgeScore < edgeThreshold gate near edgeThreshold=10 (sqrt of an
//     fp32-accumulated alpha) and the |peakScore| > peakThreshold gate near
//     threshold.
//  The harness quantifies each (counts near-threshold flips + position error
//  distribution) so the fp32 cost is a measured number, not an assumption.
//
// ════════════════════════════════════════════════════════════════════════════
//  OUTPUT INTERFACE (shared with task B / S3 — see bench/gpu_extrema_iface.md)
// ════════════════════════════════════════════════════════════════════════════
//  Bindings (@group(0)):
//    binding(0) storage read        gss        : array<f32>  one octave's gss
//                                                 levels, flat level-major:
//                                                 gss[(lvl*H+y)*W+x], lvl in [0..D].
//    binding(1) storage read        cands      : array<CandidateExtremum>  the S1
//                                                 candidate records for THIS octave.
//    binding(2) storage read_write  out_count  : atomic<u32>  survivor count
//                                                 (caller zero-inits ONCE, shared
//                                                 across octaves for a dense
//                                                 multi-octave output).
//    binding(3) storage read_write  out_kp     : array<Keypoint>  dense survivor
//                                                 append target, capacity = P.max_kp.
//    binding(4) uniform             P          : RefineParams
//
//  One invocation per S1 candidate of THIS octave. 1D dispatch:
//  ceil(num_cands / 64) workgroups of workgroup_size(64). Invocations past
//  num_cands early-out. Lanes that fail refine/gates simply do not append
//  (divergence is benign — "lanes idle on convergence", PLAN).

// ── S1 input record (must byte-match sift_dog_extrema_test.wgsl) ──
struct CandidateExtremum {
  octave    : u32,
  level     : u32,   // css-local scale index z (0-based)
  x         : u32,
  y         : u32,
  dog_value : f32,
};

// ── S2 output survivor record (dense). 48 bytes, std430-aligned. ──
struct Keypoint {
  x_local   : f32,   // refined subpixel x in octave-local css coords (refined.x)
  y_local   : f32,   // refined subpixel y in octave-local css coords (refined.y)
  z_local   : f32,   // refined subpixel css-local scale (refined.z)
  octave    : u32,   // detection octave o
  sigma     : f32,   // baseScale * 2^(o + (z + octaveFirstSubdivision)/octaveResolution)
  step      : f32,   // per-octave step (frame.x = x_local*step; host adds +0.5)
  peak_score: f32,   // refined.peakScore (signed)
  edge_score: f32,   // refined.edgeScore
};

struct RefineParams {
  width        : u32,   // W: css/gss octave width
  height       : u32,   // H: css/gss octave height
  num_css      : u32,   // D: number of css levels (gss levels = D+1)
  num_cands    : u32,   // number of S1 candidate records for this octave
  peak_thr     : f32,   // FULL peakThreshold (post-refine gate; NOT the 0.8x)
  edge_thr     : f32,   // edgeThreshold (default 10.0)
  base_scale   : f32,   // cgeom.baseScale
  step         : f32,   // per-octave step (octave geometry .step)
  first_sub    : i32,   // octaveFirstSubdivision (signed; default -1)
  octave_res   : f32,   // octaveResolution (default 3)
  max_kp       : u32,   // capacity of out_kp (records)
  _pad0        : u32,
};

@group(0) @binding(0) var<storage, read>       gss       : array<f32>;
@group(0) @binding(1) var<storage, read>       cands     : array<CandidateExtremum>;
@group(0) @binding(2) var<storage, read_write> out_count : atomic<u32>;
@group(0) @binding(3) var<storage, read_write> out_kp    : array<Keypoint>;
@group(0) @binding(4) var<uniform>             P         : RefineParams;

// css voxel = gss[lvl] - gss[lvl+1]  (VLFeat _vl_dog_response sign). fp32
// in-register; reads two adjacent gss levels from the flat per-octave buffer.
// Caller guarantees (x,y) interior and lvl in [0, D-1] so gss[lvl] and
// gss[lvl+1] are in-range.
fn dog_at(x : i32, y : i32, lvl : i32) -> f32 {
  let W : i32 = i32(P.width);
  let H : i32 = i32(P.height);
  let plane : i32 = W * H;
  let idx : i32 = (lvl * H + y) * W + x;
  return gss[idx] - gss[idx + plane];   // gss[lvl] - gss[lvl+1]
}

// vl_solve_linear_system_3 == vl_gaussian_elimination on the augmented 3x4
// [A|b] with partial pivoting (mathop.c:839-860 -> 906-1008). A is row-major
// 3x3 here (a[r][c]); b is the RHS / solution in/out. Returns true on success,
// false on singular (max|pivot| < 1e-10 -> VL_ERR_OVERFLOW, mathop.c:948).
//
// VLFeat lays M out COLUMN-major as M[i + j*numRows] with M = [A | b] where the
// VLFeat A passed in is itself Aat(i,j)=A[i+j*3] (column-major, but A is
// SYMMETRIC here so row==col layout, no transpose ambiguity). We carry M as a
// flat array<f32,12> in the SAME column-major [i + j*3] indexing so the pivot /
// eliminate / back-substitute loops are line-identical to mathop.c.
//   M column j (0..2) = A column j ; M column 3 = b.
fn gauss3x4(a00:f32, a01:f32, a02:f32,
            a11:f32, a12:f32, a22:f32,
            b0:f32, b1:f32, b2:f32,
            sol: ptr<function, vec3<f32>>) -> bool {
  // Build M column-major, M[i + j*3], i=row, j=col. A is symmetric:
  //   col0 = (a00,a01,a02) col1 = (a01,a11,a12) col2 = (a02,a12,a22) col3 = b.
  var M : array<f32, 12>;
  M[0] = a00; M[1] = a01; M[2] = a02;   // col 0
  M[3] = a01; M[4] = a11; M[5] = a12;   // col 1
  M[6] = a02; M[7] = a12; M[8] = a22;   // col 2
  M[9] = b0;  M[10] = b1; M[11] = b2;   // col 3 (RHS)

  let numRows : i32 = 3;
  let numCols : i32 = 4;

  // Gauss elimination with partial pivoting (mathop.c:914-995).
  for (var j : i32 = 0; j < numRows; j = j + 1) {
    var maxa : f32 = 0.0;
    var maxabsa : f32 = 0.0;
    var maxi : i32 = -1;
    // look for the maximally stable pivot (mathop.c:936-944)
    for (var i : i32 = j; i < numRows; i = i + 1) {
      let aij : f32 = M[i + j * numRows];
      let absa : f32 = abs(aij);
      if (absa > maxabsa) {
        maxa = aij;
        maxabsa = absa;
        maxi = i;
      }
    }
    let ip : i32 = maxi;
    // singular -> give up (mathop.c:948). 1e-10 in fp32 (denormal-ish; matches
    // VLFeat's literal — fp32 can flip OK/overflow here vs VLFeat double, the
    // documented near-singular divergence point).
    if (maxabsa < 1e-10) { return false; }

    // swap j-th row with pivot row and normalize j-th row (mathop.c:951-954)
    for (var jj : i32 = j; jj < numCols; jj = jj + 1) {
      let tmp : f32 = M[ip + jj * numRows];
      M[ip + jj * numRows] = M[j + jj * numRows];
      M[j + jj * numRows] = tmp;
      M[j + jj * numRows] = M[j + jj * numRows] / maxa;
    }

    // elimination (mathop.c:972-977)
    for (var ii : i32 = j + 1; ii < numRows; ii = ii + 1) {
      let x : f32 = M[ii + j * numRows];
      for (var jj : i32 = j; jj < numCols; jj = jj + 1) {
        M[ii + jj * numRows] = M[ii + jj * numRows] - x * M[j + jj * numRows];
      }
    }
  }

  // backward substitution (mathop.c:998-1007)
  for (var i : i32 = numRows - 1; i > 0; i = i - 1) {
    for (var ii : i32 = i - 1; ii >= 0; ii = ii - 1) {
      let x : f32 = M[ii + i * numRows];
      for (var jj : i32 = numRows; jj < numCols; jj = jj + 1) {
        M[ii + jj * numRows] = M[ii + jj * numRows] - x * M[i + jj * numRows];
      }
    }
  }

  // solution = last column (mathop.c:856-858)
  *sol = vec3<f32>(M[9], M[10], M[11]);
  return true;
}

@compute @workgroup_size(64, 1, 1)
fn refine(@builtin(global_invocation_id) gid : vec3<u32>) {
  let cidx : u32 = gid.x;
  if (cidx >= P.num_cands) { return; }   // lanes past the candidate count idle

  let W : i32 = i32(P.width);
  let H : i32 = i32(P.height);
  let D : i32 = i32(P.num_css);

  let c : CandidateExtremum = cands[cidx];

  // Initial integer voxel (vl_find_local_extrema_3 coords; covdet.c interior
  // guarantees 1<=x<=W-2, 1<=y<=H-2, 1<=z<=D-2 so neighbours are in-range).
  var x : i32 = i32(c.x);
  var y : i32 = i32(c.y);
  let z : i32 = i32(c.level);   // z is NOT relocated in VLFeat's loop

  // Newton refine state. dx/dy carry the relocation into the NEXT iter (VLFeat
  // applies x+=dx,y+=dy at the TOP of the loop, covdet.c:1234-1235).
  var dx : i32 = 0;
  var dy : i32 = 0;

  // These hold the LAST iteration's gradient/Hessian + solved offset, reused for
  // the scores after the loop (covdet.c:1286-1296 use the post-loop values).
  var Dx : f32 = 0.0; var Dy : f32 = 0.0; var Dz : f32 = 0.0;
  var Dxx : f32 = 0.0; var Dyy : f32 = 0.0; var Dzz : f32 = 0.0;
  var Dxy : f32 = 0.0; var Dxz : f32 = 0.0; var Dyz : f32 = 0.0;
  var b : vec3<f32> = vec3<f32>(0.0, 0.0, 0.0);
  var err_ok : bool = true;

  for (var iter : i32 = 0; iter < 5; iter = iter + 1) {
    x = x + dx;
    y = y + dy;

    // css 3x3x3 samples around (x,y,z). dog_at recomputes css from gss fp32.
    let c000 : f32 = dog_at(x,   y,   z  );
    let cp00 : f32 = dog_at(x+1, y,   z  );
    let cn00 : f32 = dog_at(x-1, y,   z  );
    let c0p0 : f32 = dog_at(x,   y+1, z  );
    let c0n0 : f32 = dog_at(x,   y-1, z  );
    let c00p : f32 = dog_at(x,   y,   z+1);
    let c00n : f32 = dog_at(x,   y,   z-1);
    let cpp0 : f32 = dog_at(x+1, y+1, z  );
    let cnn0 : f32 = dog_at(x-1, y-1, z  );
    let cnp0 : f32 = dog_at(x-1, y+1, z  );
    let cpn0 : f32 = dog_at(x+1, y-1, z  );
    let cp0p : f32 = dog_at(x+1, y,   z+1);
    let cn0n : f32 = dog_at(x-1, y,   z-1);
    let cn0p : f32 = dog_at(x-1, y,   z+1);
    let cp0n : f32 = dog_at(x+1, y,   z-1);
    let c0pp : f32 = dog_at(x,   y+1, z+1);
    let c0nn : f32 = dog_at(x,   y-1, z-1);
    let c0np : f32 = dog_at(x,   y-1, z+1);
    let c0pn : f32 = dog_at(x,   y+1, z-1);

    // gradient (central diff, *0.5) — covdet.c:1239-1241
    Dx = 0.5 * (cp00 - cn00);
    Dy = 0.5 * (c0p0 - c0n0);
    Dz = 0.5 * (c00p - c00n);

    // Hessian — covdet.c:1244-1250
    Dxx = cp00 + cn00 - 2.0 * c000;
    Dyy = c0p0 + c0n0 - 2.0 * c000;
    Dzz = c00p + c00n - 2.0 * c000;
    Dxy = 0.25 * (cpp0 + cnn0 - cnp0 - cpn0);
    Dxz = 0.25 * (cp0p + cn0n - cn0p - cp0n);
    Dyz = 0.25 * (c0pp + c0nn - c0np - c0pn);

    // A x = b with b = -grad (covdet.c:1253-1264). gauss3x4 solves in place.
    let solved : bool = gauss3x4(Dxx, Dxy, Dxz, Dyy, Dyz, Dzz,
                                 -Dx, -Dy, -Dz, &b);
    if (!solved) {
      // covdet.c:1266-1271 — b = 0; break (err != OK).
      b = vec3<f32>(0.0, 0.0, 0.0);
      err_ok = false;
      break;
    }

    // Relocate ONLY x,y by +-1 when |offset|>0.6 and inside bounds
    // (covdet.c:1275-1279). Bound test uses the CURRENT x,y (pre next-iter +=).
    var ndx : i32 = 0;
    if (b.x > 0.6 && x < W - 2) { ndx = ndx + 1; }
    if (b.x < -0.6 && x > 1)    { ndx = ndx - 1; }
    var ndy : i32 = 0;
    if (b.y > 0.6 && y < H - 2) { ndy = ndy + 1; }
    if (b.y < -0.6 && y > 1)    { ndy = ndy - 1; }
    dx = ndx;
    dy = ndy;

    if (dx == 0 && dy == 0) { break; }   // covdet.c:1281
  }

  // ── Scores (covdet.c:1286-1296) ──
  // at(0,0,0) is css at the FINAL (x,y,z). peakScore uses the LAST-iter grad +
  // the LAST solved b. If the solve failed (err_ok=false), b is zeroed -> the
  // peakScore degenerates to at(0,0,0) and the accept below already rejects on
  // err_ok, matching VLFeat (it still computes scores but returns ok=false).
  let center : f32 = dog_at(x, y, z);
  let peak_score : f32 = center + 0.5 * (Dx * b.x + Dy * b.y + Dz * b.z);

  let alpha_den : f32 = Dxx * Dyy - Dxy * Dxy;
  let alpha : f32 = (Dxx + Dyy) * (Dxx + Dyy) / alpha_den;
  var edge_score : f32;
  if (alpha < 0.0) {
    // not an extremum -> +INF (covdet.c:1293). WGSL has no INF literal; use a
    // huge value that always FAILS edge_score < edge_thr (edge_thr default 10).
    edge_score = 3.4e38;
  } else {
    // (0.5*alpha-1) + sqrt(max(0.25*alpha-1,0)*alpha)  (covdet.c:1295)
    edge_score = (0.5 * alpha - 1.0) + sqrt(max(0.25 * alpha - 1.0, 0.0) * alpha);
  }

  // refined subpixel position (covdet.c:1301-1303)
  let rx : f32 = f32(x) + b.x;
  let ry : f32 = f32(y) + b.y;
  let rz : f32 = f32(z) + b.z;

  // ── Accept: refine stability (covdet.c:1307-1314) ──
  var ok : bool = err_ok
    && abs(b.x) < 1.5 && abs(b.y) < 1.5 && abs(b.z) < 1.5
    && rx >= 0.0 && rx <= f32(W - 1)
    && ry >= 0.0 && ry <= f32(H - 1)
    && rz >= 0.0 && rz <= f32(D - 1);

  // ── Peak + edge gates (covdet.c:2024-2025) ──
  ok = ok && (abs(peak_score) > P.peak_thr);
  ok = ok && (edge_score < P.edge_thr);

  if (!ok) { return; }   // lane idles — no append (benign divergence)

  // sigma (covdet.c:2027-2029): baseScale * 2^(o + (z + firstSub)/res).
  let expo : f32 = f32(i32(c.octave))
                 + (rz + f32(P.first_sub)) / P.octave_res;
  let sigma : f32 = P.base_scale * exp2(expo);

  // ── Survivor: atomic-append to the dense output. ──
  let slot : u32 = atomicAdd(&out_count, 1u);
  if (slot < P.max_kp) {
    out_kp[slot] = Keypoint(
      rx, ry, rz,
      c.octave,
      sigma,
      P.step,
      peak_score,
      edge_score,
    );
  }
}
