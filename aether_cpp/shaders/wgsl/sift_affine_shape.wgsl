// sift_affine_shape.wgsl — GPU DSP-SIFT Stage-4a per-keypoint iterative
// affine-shape adaptation (the HARDEST stage of the GPU port).
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, S4 scope + "The two
// GPU-hard problems (b)". Stage gate (PLAN line 70): ellipse rel-Frobenius
// median <= 2e-2.
//
// INPUT  = post-refine keypoints (the S2 survivor "Keypoint" frames: circular
//          oriented-ellipse frames produced by vl_covdet_detect, covdet.c:
//          2027-2037 — a11=a22=sigma, a12=a21=0, (x,y) in image coords) + the
//          resident gss pyramid (all octaves/levels) + a per-octave geometry
//          table.
// OUTPUT = one AffineShape record per keypoint: the adapted 2x2 ellipse
//          (a11,a12,a21,a22) + a status flag (converged / kept / rejected).
//          VLFeat (vl_covdet_extract_affine_shape, covdet.c:2651-2668) DROPS a
//          feature ONLY when the per-frame routine returns a non-VL_ERR_OK
//          status, which happens ONLY when the patch extraction goes out of the
//          scale-space (covdet.c:2537) — the anisotropy-divergence and the
//          lxx==0||lyy==0 cases BREAK but still keep the feature (returning
//          VL_ERR_OK with the last/reset shape). We replicate that exactly.
//
// ════════════════════════════════════════════════════════════════════════════
//  THREADGROUP-PER-KEYPOINT (PLAN "The two GPU-hard problems (b)")
// ════════════════════════════════════════════════════════════════════════════
//  1 workgroup owns 1 keypoint. The 41x41 = 1681 patch pixels are warped +
//  gradient'd + 2nd-moment-reduced COOPERATIVELY by the 256 lanes. The two
//  vl_svd2 (closed-form scalar 2x2 SVD, mathop.c:641 -> vl_lapack_dlasv2
//  mathop.c:712) + the convergence/anisotropy tests run on LANE 0 in workgroup
//  memory. Iteration divergence is PER-TG, not per-lane: every lane loops the
//  same number of rounds, gated by a shared `done` flag, so there is no
//  intra-workgroup control divergence around the barriers.
//
// ════════════════════════════════════════════════════════════════════════════
//  WGSL WORKGROUP-MEMORY LIMIT (PLAN: 41x41x3 fp32 ~= 20KB > portable 16KB)
// ════════════════════════════════════════════════════════════════════════════
//  The portable maxComputeWorkgroupStorageSize is 16384 bytes (the WebGPU
//  default; the harness does NOT raise it). The PLAN's 20KB figure assumes the
//  patch AND both gradient images (Lx, Ly) are resident (3 x 1681 x 4). We
//  AVOID that: only the PATCH is stored in workgroup memory (1681 x f32 =
//  6724 B), and the gradient is recomputed ON-THE-FLY per pixel during the
//  moment reduction (vl_imgradient_f is a 1-pixel-stencil central difference,
//  imopv.c:723-829 — each pixel's Lx,Ly need only its 4 axis-neighbours, all
//  present in the stored patch). Budget:
//      patch         : 1681 * 4 = 6724 B
//      reduce sdata  :  3 * 256 * 4 = 3072 B   (lxx, lxy, lyy partials)
//      shared scalars:  ~40 * 4   =  160 B     (A,D,T,sel,flags)
//      ------------------------------------------------
//      total         : ~9956 B  <  16384 B  (portable) — fp32 patch FITS.
//  So no fp16 patch / no half-tiling is needed at this resolution; we keep the
//  patch in fp32, matching the "fp32 in-register" discipline (PLAN line 58-62)
//  and side-stepping the fp16-patch precision question entirely.
//
// ════════════════════════════════════════════════════════════════════════════
//  fp32 vs fp64 (PLAN risk 4: VLFeat uses fp64; WGSL has no fp64)
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat does the affine-shape math in double. WGSL has no f64. ALL scalar
//  iteration math here is f32. The hard thresholds that can flip a keep/reject
//  or a converge/continue decision are:
//    * anisotropy > VL_COVDET_AA_MAX_ANISOTROPY (5)        — covdet.c:2501
//    * Q[3]/Q[0] < CONV (1.001) && Q[0]/Q[3] < CONV        — covdet.c:2584
//    * lxx==0 || lyy==0                                     — covdet.c:2564
//  These are MARGIN comparisons (anisotropy ~5, ratio ~1.001) on quantities far
//  from f32 epsilon, so a flip needs a value sitting within ~1e-6 of the
//  boundary — rare. The harness COUNTS the flips (converge-decision agreement)
//  and reports them honestly rather than hiding them. The dlasv2 inner SVD is
//  the most fp-sensitive piece; if the measured flip rate ever breaks the gate
//  it can be promoted to a software-double emulation in dlasv2 ONLY (PLAN risk
//  4). This kernel keeps it f32 and lets the harness measure the actual cost.
//
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat line-by-line correspondence
//  (covdet.c / mathop.c / imopv.c in colmap-src/thirdparty/VLFeat)
// ════════════════════════════════════════════════════════════════════════════
//  Constants (covdet.c:1434-1442):
//    VL_COVDET_AA_PATCH_RESOLUTION 20  -> side = 41, resolution = 20
//    VL_COVDET_AA_MAX_NUM_ITERATIONS 15
//    VL_COVDET_AA_RELATIVE_INTEGRATION_SIGMA 3   (mask sigma)
//    VL_COVDET_AA_RELATIVE_DERIVATIVE_SIGMA 1    (= sigmaD, the target patch smoothing)
//    VL_COVDET_AA_MAX_ANISOTROPY 5
//    VL_COVDET_AA_CONVERGENCE_THRESHOLD 1.001
//    VL_COVDET_AA_PATCH_EXTENT = 3*3 = 9
//    aaAccurateSmoothing = VL_FALSE (default) -> NO in-loop re-smoothing
//    transposed = VL_FALSE (default) -> "up is the y axis" in the upright fixup
//  Mask (covdet.c:1545-1556): aaMask[(i+w)+(2w+1)(j+w)] = exp(-0.5*((i*step/s)^2
//    + (j*step/s)^2)), step=2*extent/(2w+1), s=integration sigma — recomputed
//    here (it is a fixed Gaussian window, identical for every keypoint).
//  Iteration loop = vl_covdet_extract_affine_shape_for_frame (covdet.c:2462-
//    2642): vl_svd2 -> anisotropy gate -> scale-fix factor -> A=U*D -> store ->
//    maxiter check -> extract_patch_helper -> vl_imgradient_f -> 2nd moment M ->
//    vl_svd2(M) -> convergence -> A <- A * P Q^{-1/2}.  Then the upright fixup
//    (covdet.c:2610-2639) via vl_solve_linear_system_2 (mathop.c:871).
//  extract_patch_helper (covdet.c:2166-2407): level (o,s) scale-search (2222-
//    2239), A/=step T/=step (2259-2264), bounding box (2266-2295), padding by
//    continuity (2303-2359), bilinear resample (2365-2398).
//  vl_svd2 (mathop.c:641-683) + vl_lapack_dlasv2 (mathop.c:712-826) reproduced
//    verbatim below as svd2() / dlasv2().

// ─── Constants ───────────────────────────────────────────────────────────────
const RES        : i32 = 20;          // VL_COVDET_AA_PATCH_RESOLUTION
const SIDE       : i32 = 41;          // 2*RES+1
const NPIX       : u32 = 1681u;       // SIDE*SIDE
const MAX_ITER   : i32 = 15;          // VL_COVDET_AA_MAX_NUM_ITERATIONS
const MAX_ANISO  : f32 = 5.0;         // VL_COVDET_AA_MAX_ANISOTROPY
const CONV_THR   : f32 = 1.001;       // VL_COVDET_AA_CONVERGENCE_THRESHOLD
const EXTENT     : f32 = 9.0;         // VL_COVDET_AA_PATCH_EXTENT (3*INTEG_SIGMA)
const INTEG_SIGMA: f32 = 3.0;         // VL_COVDET_AA_RELATIVE_INTEGRATION_SIGMA
const SIGMA_D    : f32 = 1.0;         // VL_COVDET_AA_RELATIVE_DERIVATIVE_SIGMA (target patch smoothing)
const WG         : u32 = 256u;        // lanes per workgroup
const VL_EPS     : f32 = 1.19209290e-07;  // VL_EPSILON_D used as the dlasv2 threshold (single-precision eps; see note)

// Status flags (output).
const ST_OK_CONVERGED : u32 = 0u;  // loop hit the convergence test
const ST_OK_MAXITER   : u32 = 1u;  // ran out of iterations, KEPT (VLFeat keeps it)
const ST_OK_ANISO     : u32 = 2u;  // anisotropy diverged, KEPT with last shape (covdet.c:2501-2504)
const ST_OK_DEGENERATE: u32 = 3u;  // lxx==0||lyy==0, reset to input frame, KEPT (covdet.c:2564-2567)
const ST_REJECT_OOB   : u32 = 4u;  // patch went out of scale space, DROPPED (covdet.c:2537)

// ─── Bindings ────────────────────────────────────────────────────────────────
// (0) gss : the resident Gaussian scale-space pyramid, flattened. Per octave o
//     in [firstOctave..lastOctave], all subdivisions s in [firstSub..lastSub]
//     are stored contiguously level-major: gss[ oct_base[o-firstOctave]
//     + (s-firstSub)*W*H + y*W + x ]. The host builds oct_base + the geometry
//     table to match VLFeat's own gss byte layout.
@group(0) @binding(0) var<storage, read> gss : array<f32>;

// (1) per-octave geometry table (one OctGeom per octave, firstOctave..lastOctave).
struct OctGeom {
  width    : u32,   // ogeom.width  (scalespace.c:372)
  height   : u32,   // ogeom.height
  base     : u32,   // float offset of (o, firstSub) within `gss`
  pad      : u32,
  step     : f32,   // ogeom.step = pow(2,o)  (scalespace.c:374)
  pad1     : f32,
  pad2     : f32,
  pad3     : f32,
};
@group(0) @binding(1) var<storage, read> octs : array<OctGeom>;

// (2) input keypoint frames (post-refine circular oriented ellipses).
struct InFrame {
  x   : f32,
  y   : f32,
  a11 : f32,
  a12 : f32,
  a21 : f32,
  a22 : f32,
  pad0: f32,
  pad1: f32,
};
@group(0) @binding(2) var<storage, read> frames : array<InFrame>;

// (3) output adapted shapes.
struct AffineShape {
  a11    : f32,
  a12    : f32,
  a21    : f32,
  a22    : f32,
  x      : f32,   // passthrough center (unchanged by affine shape)
  y      : f32,
  status : u32,   // ST_*
  iters  : u32,   // iterations actually run (diagnostic)
};
@group(0) @binding(3) var<storage, read_write> out_shapes : array<AffineShape>;

// (4) uniforms — geometry scalars shared by all keypoints.
struct Params {
  num_kp        : u32,
  num_octaves   : u32,
  first_octave  : i32,
  last_octave   : i32,
  first_sub     : i32,   // geom.octaveFirstSubdivision
  last_sub      : i32,   // geom.octaveLastSubdivision
  octave_res    : f32,   // geom.octaveResolution
  base_scale    : f32,   // geom.baseScale
};
@group(0) @binding(4) var<uniform> P : Params;

// ─── Workgroup storage (see budget note above) ───────────────────────────────
var<workgroup> gpatch : array<f32, 1681>;   // the warped patch (fp32)
var<workgroup> red_xx : array<f32, 256>;   // lxx partials
var<workgroup> red_xy : array<f32, 256>;   // lxy partials
var<workgroup> red_yy : array<f32, 256>;   // lyy partials

// Shared scalar iteration state (all written/read on lane 0; broadcast via barrier).
var<workgroup> sA : array<f32, 4>;   // current A (a11,a21,a12,a22) — VLFeat column-major A[]
var<workgroup> sT : array<f32, 2>;   // T (image-frame center / step is applied per-extract)
var<workgroup> sD : array<f32, 2>;   // D[0], D[3] (singular values, after scale-fix)
var<workgroup> sAdapt : array<f32, 4>; // the adapted frame's A (a11,a21,a12,a22)
var<workgroup> sRefScale : f32;       // referenceScale (smallest sv fixed after iter 0)
var<workgroup> sDone : u32;           // loop-exit flag (0 = continue)
var<workgroup> sStatus : u32;         // final status
var<workgroup> sIter : i32;           // iteration counter

// ─── vl_lapack_dlasv2 (mathop.c:712-826) — 2x2 upper-triangular SVD ──────────
// Returns smin, smax, (sv,cv) right singular vec, (su,cu) left singular vec for
// the largest sv. f32 port of the double original. The 17/36/46-ulp comments in
// the source describe DOUBLE ulps; in f32 the absolute error is larger but the
// downstream tests are wide margins (see fp32-vs-fp64 note).
struct Dlasv2 { smin: f32, smax: f32, sv: f32, cv: f32, su: f32, cu: f32 };

fn fsign(x: f32) -> f32 { if (x < 0.0) { return -1.0; } return 1.0; }
fn isign(i: f32) -> f32 { if (i < 0.0) { return -1.0; } return 1.0; }

fn dlasv2(f_in: f32, g_in: f32, h_in: f32) -> Dlasv2 {
  var ft = f_in; var gt = g_in; var ht = h_in;
  var fa = abs(f_in); var ga = abs(g_in); var ha = abs(h_in);
  var pmax: i32 = 1;
  var swap: bool = false;
  var glarge: bool = false;
  var smin: f32 = 0.0; var smax: f32 = 0.0;
  var cut: f32 = 0.0; var sut: f32 = 0.0;
  var cvt: f32 = 0.0; var svt: f32 = 0.0;
  var tmp: f32 = 0.0;

  // make fa >= ha
  if (fa < ha) {
    pmax = 3;
    tmp = ft; ft = ht; ht = tmp;
    tmp = fa; fa = ha; ha = tmp;
    swap = true;
  }

  if (ga == 0.0) {            // diagonal
    smin = ha;
    smax = fa;
    cut = 1.0; sut = 0.0;
    cvt = 1.0; svt = 0.0;
  } else {                    // not diagonal
    if (ga > fa) {            // g is the largest entry
      pmax = 2;
      if ((fa / ga) < VL_EPS) {  // g is very large
        glarge = true;
        smax = ga;
        if (ha > 1.0) {
          smin = fa / (ga / ha);
        } else {
          smin = (fa / ga) * ha;
        }
        cut = 1.0; sut = ht / gt;
        cvt = 1.0; svt = ft / gt;
      }
    }
    if (!glarge) {            // normal case
      let fmh = fa - ha;
      var d: f32;
      if (fmh == fa) { d = 1.0; } else { d = fmh / fa; }
      let q = gt / ft;
      let s = 2.0 - d;
      let dd = d * d;
      let qq = q * q;
      let ss = s * s;
      let spq = sqrt(ss + qq);
      var dpq: f32;
      if (d == 0.0) { dpq = abs(q); } else { dpq = sqrt(dd + qq); }
      let a = 0.5 * (spq + dpq);
      smin = ha / a;
      smax = fa * a;
      if (qq == 0.0) {
        if (d == 0.0) {
          tmp = fsign(ft) * 2.0 * fsign(gt);
        } else {
          tmp = gt / (fsign(ft) * fmh) + q / s;
        }
      } else {
        tmp = (q / (spq + s) + q / (dpq + d)) * (1.0 + a);
      }
      let tt = sqrt(tmp * tmp + 4.0);
      cvt = 2.0 / tt;
      svt = tmp / tt;
      cut = (cvt + svt * q) / a;
      sut = (ht / ft) * svt / a;
    }
  }

  var out: Dlasv2;
  if (swap) {
    out.cu = svt; out.su = cvt;
    out.cv = sut; out.sv = cut;
  } else {
    out.cu = cut; out.su = sut;
    out.cv = cvt; out.sv = svt;
  }
  // correct the signs of smax and smin
  var tsign: f32 = 1.0;
  if (pmax == 1) { tsign = fsign(out.cv) * fsign(out.cu) * fsign(f_in); }
  if (pmax == 2) { tsign = fsign(out.sv) * fsign(out.cu) * fsign(g_in); }
  if (pmax == 3) { tsign = fsign(out.sv) * fsign(out.su) * fsign(h_in); }
  out.smax = isign(tsign) * smax;
  out.smin = isign(tsign * fsign(f_in) * fsign(h_in)) * smin;
  return out;
}

// ─── vl_svd2 (mathop.c:641-683) — full 2x2 SVD, M = U S V' ───────────────────
// M, U, V are column-major 2x2 (M[0]=m11, M[1]=m21, M[2]=m12, M[3]=m22), exactly
// as VLFeat lays them out. Returns S (diagonal: S0=smax, S3=smin), U (4), V (4).
struct Svd2 { S0: f32, S3: f32, U: array<f32,4>, V: array<f32,4> };

fn svd2(m11: f32, m21: f32, m12: f32, m22: f32) -> Svd2 {
  var cu1 = m11;
  var su1 = m21;
  let norm = sqrt(cu1 * cu1 + su1 * su1);
  cu1 = cu1 / norm;
  su1 = su1 / norm;

  let f = cu1 * m11 + su1 * m21;
  let g = cu1 * m12 + su1 * m22;
  let h = -su1 * m12 + cu1 * m22;

  let r = dlasv2(f, g, h);
  let cu2 = r.cu; let su2 = r.su;
  let cv2 = r.cv; let sv2 = r.sv;

  var o: Svd2;
  o.S0 = r.smax;
  o.S3 = r.smin;
  o.U[0] = cu2 * cu1 - su2 * su1;
  o.U[1] = su2 * cu1 + cu2 * su1;
  o.U[2] = -cu2 * su1 - su2 * cu1;
  o.U[3] = -su2 * su1 + cu2 * cu1;
  o.V[0] = cv2;
  o.V[1] = sv2;
  o.V[2] = -sv2;
  o.V[3] = cv2;
  return o;
}

// ─── Gaussian integration mask weight at patch index (px,py) ──────────────────
// aaMask[(i+w)+(2w+1)(j+w)] = exp(-0.5*((i*step/sigma)^2 + (j*step/sigma)^2)),
// step = 2*EXTENT/(2w+1), sigma = INTEG_SIGMA, i=px-w, j=py-w. (covdet.c:1545-1556)
fn mask_weight(px: i32, py: i32) -> f32 {
  let step = (2.0 * EXTENT) / f32(2 * RES + 1);
  let dx = f32(px - RES) * step / INTEG_SIGMA;
  let dy = f32(py - RES) * step / INTEG_SIGMA;
  return exp(-0.5 * (dx * dx + dy * dy));
}

// vl_floor_d (mathop.h:147-152) for f32.
fn floori(x: f32) -> i32 {
  let xi = i32(x);
  if (x >= 0.0 || f32(xi) == x) { return xi; }
  return xi - 1;
}

// ─── Cooperative patch warp + scale-space level selection ─────────────────────
// Replicates vl_covdet_extract_patch_helper (covdet.c:2166-2407) for the default
// aaAccurateSmoothing=FALSE path: pick level (o,s), warp + bilinear-resample the
// patch with clamp-to-edge (VL_PAD_BY_CONTINUITY). Each lane fills a strided
// subset of the 1681 patch pixels. Writes `gpatch[]`. Returns true if the patch
// is fully in-bounds after clamp (always true with clamp; OOB only triggers the
// VLFeat reject when the SELECTED level does not exist — handled on lane 0).
//
// Inputs Apx (column-major A AFTER the iteration's A=U*D update, /step applied
// here), the level pointer base/W/H. d1,d2 = D[0],D[3] are the singular values
// used to pick the level.
fn warp_patch(localId: u32,
              a11: f32, a21: f32, a12: f32, a22: f32,
              tx: f32, ty: f32,
              base: u32, W: i32, H: i32, stepf: f32) {
  // A/=step, T/=step (covdet.c:2259-2264).
  let A0 = a11 / stepf;
  let A1 = a21 / stepf;
  let A2 = a12 / stepf;
  let A3 = a22 / stepf;
  let T0 = tx / stepf;
  let T1 = ty / stepf;

  let stephat = EXTENT / f32(RES);
  // Each lane handles patch indices k = localId, localId+WG, ...
  var k = localId;
  loop {
    if (k >= NPIX) { break; }
    let yyi = i32(k) / SIDE;
    let xxi = i32(k) % SIDE;
    let yhat = -EXTENT + f32(yyi) * stephat;
    let xhat = -EXTENT + f32(xxi) * stephat;
    let xf = A0 * xhat + A2 * yhat + T0;
    let yf = A1 * xhat + A3 * yhat + T1;
    // Clamp-to-edge bilinear (VL_PAD_BY_CONTINUITY). VLFeat pads a copy then
    // samples in-bounds; an equivalent clamp of the 4 taps reproduces the
    // continuity extension exactly for interior + border (the padded copy just
    // replicates edge rows/cols, which clamping the indices does directly).
    let xi = floori(xf);
    let yi = floori(yf);
    let wx = xf - f32(xi);
    let wy = yf - f32(yi);
    let x0 = clamp(xi,     0, W - 1);
    let x1 = clamp(xi + 1, 0, W - 1);
    let y0 = clamp(yi,     0, H - 1);
    let y1 = clamp(yi + 1, 0, H - 1);
    let i00 = gss[base + u32(y0 * W + x0)];
    let i10 = gss[base + u32(y0 * W + x1)];
    let i01 = gss[base + u32(y1 * W + x0)];
    let i11 = gss[base + u32(y1 * W + x1)];
    let v = (1.0 - wy) * ((1.0 - wx) * i00 + wx * i10)
          +        wy  * ((1.0 - wx) * i01 + wx * i11);
    gpatch[k] = v;
    k = k + WG;
  }
}

// vl_imgradient_f central-difference gradient at patch pixel (px,py) on the
// SIDE x SIDE stored `patch` (imopv.c:723-829: 0.5*(right-left) interior,
// one-sided forward/backward differences at the borders).
fn patch_grad(px: i32, py: i32) -> vec2<f32> {
  let c  = gpatch[u32(py * SIDE + px)];
  var gx: f32;
  var gy: f32;
  // x gradient
  if (px == 0) {
    gx = gpatch[u32(py * SIDE + (px + 1))] - c;
  } else if (px == SIDE - 1) {
    gx = c - gpatch[u32(py * SIDE + (px - 1))];
  } else {
    gx = 0.5 * (gpatch[u32(py * SIDE + (px + 1))] - gpatch[u32(py * SIDE + (px - 1))]);
  }
  // y gradient
  if (py == 0) {
    gy = gpatch[u32((py + 1) * SIDE + px)] - c;
  } else if (py == SIDE - 1) {
    gy = c - gpatch[u32((py - 1) * SIDE + px)];
  } else {
    gy = 0.5 * (gpatch[u32((py + 1) * SIDE + px)] - gpatch[u32((py - 1) * SIDE + px)]);
  }
  return vec2<f32>(gx, gy);
}

// ─── Scale-space level selection (covdet.c:2222-2239) on lane 0 ───────────────
// Replicates the patch-helper's "best level (o,s) such that sigma_(o,s)*factor
// <= sigma" search. sigma = SIGMA_D (the affine-shape target patch smoothing),
// factor = 1/min(d1,d2). Returns selected octave o and subdivision s, or o<
// firstOctave to signal "no valid level" (the VLFeat OOB-equivalent reject).
struct LevelSel { o: i32, s: i32, ok: bool };

fn select_level(d1: f32, d2: f32) -> LevelSel {
  let sigma = SIGMA_D;
  let factor = 1.0 / min(d1, d2);
  var o = P.first_octave;
  // for (o = firstOctave+1 ; o <= lastOctave ; ++o) { ... if (factor*sigma_ >
  // sigma) { o--; break; } }  — covdet.c:2224-2234.
  var oo = P.first_octave + 1;
  loop {
    if (oo > P.last_octave) { o = P.last_octave; break; }
    var s = floori(log2(sigma / (factor * P.base_scale)) - f32(oo));
    s = max(s, P.first_sub);
    s = min(s, P.last_sub);
    let sigma_ = P.base_scale * exp2(f32(oo) + f32(s) / P.octave_res);
    if (factor * sigma_ > sigma) { o = oo - 1; break; }
    oo = oo + 1;
  }
  o = min(o, P.last_octave);
  var s = floori(log2(sigma / (factor * P.base_scale)) - f32(o));
  s = max(s, P.first_sub);
  s = min(s, P.last_sub);
  var sel: LevelSel;
  sel.o = o;
  sel.s = s;
  sel.ok = (o >= P.first_octave && o <= P.last_octave);
  return sel;
}

@compute @workgroup_size(256)
fn affine_shape(@builtin(workgroup_id) wid: vec3<u32>,
                @builtin(local_invocation_id) lid: vec3<u32>) {
  let kp = wid.x;
  if (kp >= P.num_kp) { return; }
  let lane = lid.x;

  // ── lane 0: load the input frame, init A,T (covdet.c:2469-2488) ──
  if (lane == 0u) {
    let fr = frames[kp];
    // VLFeat: A[2*2] = {a11, a21, a12, a22}; T = {x,y}.
    sA[0] = fr.a11; sA[1] = fr.a21; sA[2] = fr.a12; sA[3] = fr.a22;
    sT[0] = fr.x;   sT[1] = fr.y;
    sAdapt[0] = fr.a11; sAdapt[1] = fr.a21; sAdapt[2] = fr.a12; sAdapt[3] = fr.a22;
    sDone = 0u;
    sStatus = ST_OK_MAXITER;   // default if we run out of iters
    sIter = 0;
    sRefScale = 0.0;
  }
  workgroupBarrier();

  // ── main iteration: while(1) (covdet.c:2490-2600) ──
  // PER-TG divergence: every lane runs MAX_ITER rounds; lane 0 sets sDone to
  // break early. Lanes only do the (uniform) cooperative warp+reduce when the
  // round is still live; the per-pixel loops have NO data-dependent branch.
  loop {
    // lane 0 does the SVD(A) -> anisotropy -> scale-fix -> A=U*D -> store, and
    // decides the level for this round's patch extraction.
    if (lane == 0u) {
      if (sDone == 0u) {
        // vl_svd2(D,U,V,A)  (covdet.c:2496)
        let sv = svd2(sA[0], sA[1], sA[2], sA[3]);
        var D0 = sv.S0;
        var D3 = sv.S3;
        let aniso = max(D0 / D3, D3 / D0);   // covdet.c:2497
        if (aniso > MAX_ANISO) {             // covdet.c:2501-2504 — diverged, KEEP last shape
          sStatus = ST_OK_ANISO;
          sDone = 1u;
        } else {
          // scale-fix: keep the smallest sv fixed after iter 0 (covdet.c:2508-2516)
          var factor: f32;
          if (sIter == 0) {
            sRefScale = min(D0, D3);
            factor = 1.0;
          } else {
            factor = sRefScale / min(D0, D3);
          }
          D0 = D0 * factor;
          D3 = D3 * factor;
          sD[0] = D0; sD[1] = D3;
          // A = U*D  (covdet.c:2518-2521)
          sA[0] = sv.U[0] * D0;
          sA[1] = sv.U[1] * D0;
          sA[2] = sv.U[2] * D3;
          sA[3] = sv.U[3] * D3;
          // adapted = A  (covdet.c:2523-2526)
          sAdapt[0] = sA[0]; sAdapt[1] = sA[1]; sAdapt[2] = sA[2]; sAdapt[3] = sA[3];
          // ++iter >= MAX_ITER -> break (covdet.c:2528). Status stays MAXITER.
          sIter = sIter + 1;
          if (sIter >= MAX_ITER) {
            sStatus = ST_OK_MAXITER;
            sDone = 1u;
          }
        }
      }
    }
    // workgroupUniformLoad() = barrier + load with a GUARANTEED-uniform result,
    // so the break is uniform control flow (Tint cannot prove a plain workgroup
    // read is uniform, which is why a bare `workgroupBarrier(); if (sDone)...`
    // trips the uniformity analysis before a later barrier).
    if (workgroupUniformLoad(&sDone) != 0u) { break; }

    // ── cooperative: select level + warp patch (covdet.c:2530-2536) ──
    // lane 0 selects the level; all lanes need (base,W,H,step) so broadcast via
    // a tiny shared slot reusing sD-adjacent scalars is awkward — instead all
    // lanes recompute the (uniform) level selection from sD (already barriered).
    // Load the SVD-derived singular values as GUARANTEED-uniform (they were
    // written by lane 0 above; workgroupUniformLoad makes sel.ok uniform so the
    // break-before-barrier below is uniform control flow).
    let d0u = workgroupUniformLoad(&sD[0]);
    let d1u = workgroupUniformLoad(&sD[1]);
    let sel = select_level(d0u, d1u);
    if (!sel.ok) {
      // patch went out of the scale space -> VLFeat returns err -> DROP. All
      // lanes compute the SAME sel (uniform), so this break is uniform.
      if (lane == 0u) { sStatus = ST_REJECT_OOB; sDone = 1u; }
      break;
    }
    let g = octs[u32(sel.o - P.first_octave)];
    let W = i32(g.width);
    let H = i32(g.height);
    let base = g.base + u32((sel.s - P.first_sub)) * g.width * g.height;
    warp_patch(lane, sA[0], sA[1], sA[2], sA[3], sT[0], sT[1], base, W, H, g.step);
    workgroupBarrier();

    // ── cooperative: 2nd moment matrix M = sum grad*grad' * mask (covdet.c:2549-2562) ──
    var lxx = 0.0;
    var lxy = 0.0;
    var lyy = 0.0;
    var k = lane;
    loop {
      if (k >= NPIX) { break; }
      let px = i32(k) % SIDE;
      let py = i32(k) / SIDE;
      let grad = patch_grad(px, py);
      let m = mask_weight(px, py);
      lxx = lxx + grad.x * grad.x * m;
      lyy = lyy + grad.y * grad.y * m;
      lxy = lxy + grad.x * grad.y * m;
      k = k + WG;
    }
    red_xx[lane] = lxx;
    red_xy[lane] = lxy;
    red_yy[lane] = lyy;
    workgroupBarrier();
    // tree reduction
    var stride = WG / 2u;
    loop {
      if (stride == 0u) { break; }
      if (lane < stride) {
        red_xx[lane] = red_xx[lane] + red_xx[lane + stride];
        red_xy[lane] = red_xy[lane] + red_xy[lane + stride];
        red_yy[lane] = red_yy[lane] + red_yy[lane + stride];
      }
      workgroupBarrier();
      stride = stride / 2u;
    }

    // ── lane 0: M -> svd2(M) -> convergence -> A <- A P Q^{-1/2} (covdet.c:2559-2598) ──
    if (lane == 0u) {
      let Mxx = red_xx[0];
      let Mxy = red_xy[0];
      let Myy = red_yy[0];
      if (Mxx == 0.0 || Myy == 0.0) {        // covdet.c:2564-2567 — reset to input, KEEP
        let fr = frames[kp];
        sAdapt[0] = fr.a11; sAdapt[1] = fr.a21; sAdapt[2] = fr.a12; sAdapt[3] = fr.a22;
        sStatus = ST_OK_DEGENERATE;
        sDone = 1u;
      } else {
        // M = {lxx, lxy, lxy, lyy}; vl_svd2(Q,P,P_,M) (covdet.c:2570).
        let sm = svd2(Mxx, Mxy, Mxy, Myy);
        let Q0 = sm.S0;
        let Q3 = sm.S3;
        // convergence: Q3/Q0 < CONV && Q0/Q3 < CONV (covdet.c:2584-2587)
        if (Q3 / Q0 < CONV_THR && Q0 / Q3 < CONV_THR) {
          sStatus = ST_OK_CONVERGED;
          sDone = 1u;
        } else {
          // A <- A * P Q^{-1/2}  (covdet.c:2589-2598)
          let q0 = sqrt(Q0);
          let q1 = sqrt(Q3);
          let Pm0 = sm.U[0]; let Pm1 = sm.U[1]; let Pm2 = sm.U[2]; let Pm3 = sm.U[3];
          let A0 = sA[0]; let A1 = sA[1]; let A2 = sA[2]; let A3 = sA[3];
          let Ap0 = (A0 * Pm0 + A2 * Pm1) / q0;
          let Ap1 = (A1 * Pm0 + A3 * Pm1) / q0;
          let Ap2 = (A0 * Pm2 + A2 * Pm3) / q1;
          let Ap3 = (A1 * Pm2 + A3 * Pm3) / q1;
          sA[0] = Ap0; sA[1] = Ap1; sA[2] = Ap2; sA[3] = Ap3;
        }
      }
    }
    if (workgroupUniformLoad(&sDone) != 0u) { break; }
  }

  // ── lane 0: upright fixup (covdet.c:2610-2639), transposed=FALSE -> up=y ──
  if (lane == 0u) {
    var a11 = sAdapt[0];
    var a21 = sAdapt[1];
    var a12 = sAdapt[2];
    var a22 = sAdapt[3];

    if (sStatus != ST_REJECT_OOB) {
      // A = {a11,a21,a12,a22}; ref = (0,1) (up is y axis).
      // vl_solve_linear_system_2(ref_, A, ref): solve A * ref_ = ref.
      // For a 2x2 A (column-major: A[0]=a11,A[1]=a21,A[2]=a12,A[3]=a22), the
      // matrix is [[a11,a12],[a21,a22]] and we solve [[a11,a12],[a21,a22]]*r=b.
      // VLFeat uses Gaussian elimination w/ pivoting; for a generic 2x2 the
      // closed-form Cramer solution is bit-equivalent up to fp ordering and the
      // result feeds an atan2 (angle), so any pivot-order fp delta is far below
      // the gate. b = (0,1).
      let det = a11 * a22 - a12 * a21;
      // ref_ = A^{-1} * (0,1) = (-a12, a11)/det.
      let ref0 = 0.0;
      let ref1 = 1.0;
      var rfx = (-a12) / det;   // (a22*0 - a12*1)/det
      var rfy = ( a11) / det;   // (-a21*0 + a11*1)/det
      let angle  = atan2(ref1, ref0);   // atan2(1,0)
      let angle_ = atan2(rfy, rfx);
      let dangle = angle_ - angle;
      let r1 = cos(dangle);
      let r2 = sin(dangle);
      let na11 = a11 * r1 + a12 * r2;
      let na21 = a21 * r1 + a22 * r2;
      let na12 = -a11 * r2 + a12 * r1;
      let na22 = -a21 * r2 + a22 * r1;
      a11 = na11; a21 = na21; a12 = na12; a22 = na22;
    }

    var o: AffineShape;
    o.a11 = a11; o.a21 = a21; o.a12 = a12; o.a22 = a22;
    o.x = sT[0]; o.y = sT[1];
    o.status = sStatus;
    o.iters = u32(sIter);
    out_shapes[kp] = o;
  }
}
