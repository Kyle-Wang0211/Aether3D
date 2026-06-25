// sift_orientation.wgsl — GPU DSP-SIFT Stage-4b per-keypoint orientation
// assignment: build a 36-bin Gaussian-weighted gradient-orientation histogram
// over the affine-warped patch, smooth it, find the dominant peak + every peak
// >= 0.8*max, parabolic-interpolate each for sub-bin orientation, and EXPAND the
// keypoint into 1-4 oriented copies (atomic-append, one record per orientation).
//
// See third_party/glomap_vendor/GPU_DSP_SIFT_PLAN.md, S4 scope:
//   "orientation: per-kp 36-bin histogram, 1-4x expand (reads gss)".
// Stage gate (PLAN line 70): orient median <= 1 deg.
//
// INPUT  = the (affine+refined) keypoint frames (VlFrameOrientedEllipse:
//          a11,a21,a12,a22,x,y in image-frame coords) — i.e. the output of S2
//          refine fed through S4a affine-shape (here the host supplies the exact
//          frames VLFeat produced post-affine, so this kernel is validated in
//          ISOLATION from the affine-shape kernel, the same methodology S1/S2
//          used to isolate from gss-build) — PLUS the full multi-octave gss
//          pyramid (flat) + a per-octave geometry table.
// OUTPUT = a DENSE oriented-keypoint buffer: one OrientedKp record per detected
//          orientation (1-4 per input kp), atomic-appended. The host re-derives
//          the rotated affine frame exactly as vl_covdet_extract_orientations
//          (covdet.c:2868-2889) does from (input frame, angle).
//
// ════════════════════════════════════════════════════════════════════════════
//  VLFeat parity — line-by-line correspondence
//  (covdet.c / mathop.c / imopv.c in
//   third_party/glomap_vendor/colmap-src/thirdparty/VLFeat)
// ════════════════════════════════════════════════════════════════════════════
//
//  ENTRY = vl_covdet_extract_orientations_for_frame (covdet.c:2697-2847).
//  Constants (covdet.c:1434-1443):
//    VL_COVDET_AA_PATCH_RESOLUTION                 = 20  -> side = 2*20+1 = 41
//    VL_COVDET_AA_RELATIVE_INTEGRATION_SIGMA       = 3
//    VL_COVDET_AA_PATCH_EXTENT  = 3*INTEGRATION_SIGMA = 9
//    VL_COVDET_OR_NUM_ORIENTATION_HISTOGAM_BINS    = 36  -> binExtent = 2pi/36
//    VL_COVDET_OR_ADDITIONAL_PEAKS_RELATIVE_SIZE   = 0.8
//    VL_COVDET_MAX_NUM_ORIENTATIONS                = 4
//    sigmaD (desired patch smoothing) = 1.0   (covdet.c:2722)
//
//  (1) Axis-aligned-anisotropy decomposition (covdet.c:2744-2752):
//        A = [[a11,a12],[a21,a22]]  (column-major M = {a11,a21,a12,a22})
//        vl_svd2(D,U,V,A)                         -> A = U D V'  (mathop.c:640)
//        A := U*D   (A[0]=U[0]*D[0],A[1]=U[1]*D[0],A[2]=U[2]*D[3],A[3]=U[3]*D[3])
//        theta0 = atan2(V[1], V[0])               (covdet.c:2752, full libm atan2)
//      vl_svd2 = svd2 + vl_lapack_dlasv2 (mathop.c:640-826), ported verbatim
//      below (svd2_UDtheta0). VLFeat does this in DOUBLE; we do fp32 in-register
//      (the documented WGSL-no-f64 divergence point; quantified by the harness).
//
//  (2) Patch warp (vl_covdet_extract_patch_helper, covdet.c:2166-2408) with
//      resolution=20, extent=9, sigma=sigmaD=1.0, A=U*D, T={frame.x,frame.y},
//      d1=D[0], d2=D[3]:
//        - level select (covdet.c:2222-2241): factor=1/min(d1,d2); scan octaves
//          o=first+1..last picking the largest sigma_(o,s) with factor*sigma_<=sigma;
//          s clamped to [octaveFirstSubdivision, octaveLastSubdivision];
//          sigma_ = baseScale*2^(o + s/octaveResolution);
//          sigma1 = sigma_/d1, sigma2 = sigma_/d2.
//        - read gss level (o,s); A,T /= step (covdet.c:2259-2264).
//        - bilinear warp resample side*side (covdet.c:2365-2398), with
//          clamp-to-edge boundary continuity (covdet.c:2266-2359 padding,
//          here folded into a clamped fetch — see warp_sample()).
//
//  (3) Patch pre-smoothing (covdet.c:2767-2774):
//        deltaSigma1 = sqrt(max(sigmaD^2 - sigma1^2, 0))
//        deltaSigma2 = sqrt(max(sigmaD^2 - sigma2^2, 0))
//        stephat     = extent / resolution = 9/20 = 0.45
//        vl_imsmooth_f(aaPatch, ..., deltaSigma1/stephat, deltaSigma2/stephat)
//      vl_imsmooth_f = separable Gaussian (imopv.c:644-679) with the normalized
//      kernel _vl_new_gaussian_fitler_ (imopv.c:620-642, half-width ceil(3*sig),
//      taps exp(-0.5*(i/sig)^2) normalized to unit mass) and VL_PAD_BY_CONTINUITY
//      (clamp-to-edge). v-pass (sigmay) then h-pass (sigmax) (imopv.c:662-672).
//      Ported below (gaussian_smooth_patch). NO-OP when both deltaSigma==0
//      (kernel size 1, tap 1.0) — common when sigma_>=sigmaD.
//
//  (4) Histogram of oriented gradients (covdet.c:2776-2794):
//        vl_imgradient_polar_f(aaPatchX=modulus, aaPatchY=angle, 1, side,
//                              aaPatch, side, side, side)   (imopv.c:874-974)
//          gradient: border px = forward/backward diff (g = nbr - self);
//          interior px = central diff *0.5; modulus = vl_fast_sqrt_f(gx^2+gy^2)
//          (mathop.h:544 fast inv-sqrt, x<1e-8 -> 0); angle =
//          vl_mod_2pi_f(vl_fast_atan2_f(gy,gx)+2pi) (mathop.h:407 c3/c1 approx).
//        per pixel k:  x = angle/binExtent; bin = floor(x); w2 = x-bin; w1 = 1-w2;
//          hist[(bin+36)%36]   += w1 * modulus * mask[k];
//          hist[(bin+36+1)%36] += w2 * modulus * mask[k];
//        mask[k] = aaMask = exp(-0.5*(dx^2+dy^2)), dx=i*step/sigma, dy=j*step/sigma,
//          step=2*extent/side=18/41, sigma=INTEGRATION_SIGMA=3 (covdet.c:1545-1556).
//
//  (5) Smooth the histogram 6 passes (covdet.c:2796-2807): cyclic 3-tap box
//        curr = (prev + hist[i] + hist[(i+1)%36]) / 3, carrying `prev`/`first`
//        exactly (the in-place dependency is load-bearing).
//
//  (6) Peaks + parabolic interpolation + expand (covdet.c:2809-2838):
//        maxPeakValue = max_i hist[i]
//        for i in 0..35:  h0=hist[i], hm=hist[(i-1)%36], hp=hist[(i+1)%36]
//          if h0 > 0.8*maxPeakValue && h0>hm && h0>hp:    (strict local max)
//            di = -0.5*(hp-hm)/(hp+hm-2*h0)               (quadratic interp)
//            th = binExtent*(i+di) + theta0
//            emit orientation (angle=th, score=h0); stop at 4 orientations.
//      (transposed=false in COLMAP/our path, so the -pi/2 branch covdet.c:2829
//       is not taken.) VLFeat then sorts orientations by descending score
//       (covdet.c:2841) — done HOST-side on the emitted records.
//
//  (7) Frame rotation (vl_covdet_extract_orientations, covdet.c:2868-2889) is
//      HOST-side from each (input frame, angle): r1=cos(angle), r2=sin(angle);
//        a11' = +a11*r1 + a12*r2 ;  a21' = +a21*r1 + a22*r2
//        a12' = -a11*r2 + a12*r1 ;  a22' = -a21*r2 + a22*r1
//      We emit (kp_index, angle, score) and the host applies this (matches the
//      harness; production S5b can consume angle directly).
//
// ════════════════════════════════════════════════════════════════════════════
//  fp32 discipline (PLAN line 58-62) + expected divergence
// ════════════════════════════════════════════════════════════════════════════
//  WGSL has no f64; VLFeat does svd2 / dlasv2 / patch-warp / smoothing / hist /
//  peak-interp in DOUBLE (the gss itself is fp32). We do everything fp32
//  in-register / in private arrays. Documented fp32-fragile points (the harness
//  quantifies each):
//   * svd2/dlasv2 singular values + V rotation -> theta0: an fp32 theta0 error
//     shifts ALL bins by a constant; bounded by the c3/c1 atan2 approx (max
//     0.0061 rad = 0.35 deg) + the dlasv2 fp32 error.
//   * the level-select floor()/clamp (covdet.c:2225): an fp32 log2 landing within
//     ~1e-6 of an integer can pick a different gss level -> a different patch.
//   * the 0.8*maxPeakValue threshold and the strict h0>hm && h0>hp test: an fp32
//     tie near a secondary peak can add/drop one orientation (the expansion-count
//     disagreement the gate measures).
//   * vl_fast_sqrt_f / vl_fast_atan2_f are themselves APPROXIMATIONS in VLFeat
//     (not libm) — we replicate them BIT-FOR-BIT (fast_sqrt_f / fast_atan2_f
//     below) so the histogram weighting + binning match VLFeat's fast path, NOT
//     a "more accurate" libm path that would DIVERGE from the CPU reference.
//
// ════════════════════════════════════════════════════════════════════════════
//  Threading model
// ════════════════════════════════════════════════════════════════════════════
//  ONE invocation per input keypoint (1D dispatch, workgroup_size(64),
//  ceil(num_kp/64) workgroups; lanes past num_kp early-out). Each lane owns its
//  41x41 patch (fp32 private array, 1681*4 = 6.7 KB) + the 36-bin histogram
//  (private). Divergence (iteration / branch) is per-lane and benign. The PLAN's
//  threadgroup-per-keypoint cooperative warp is an S4 PERF refinement (frees the
//  per-lane patch register pressure); it does NOT change parity and is deferred —
//  this kernel proves the algorithm + the expansion contract first. The expand
//  (1-4 records) is a single shared atomic<u32> append.

// ── Constants (covdet.c:1434-1443) ──
const RES   : i32 = 20;                 // VL_COVDET_AA_PATCH_RESOLUTION
const SIDE  : i32 = 41;                 // 2*RES+1
const NPIX  : i32 = 1681;               // SIDE*SIDE
const NBINS : i32 = 36;                 // VL_COVDET_OR_NUM_ORIENTATION_HISTOGAM_BINS
const MAXOR : u32 = 4u;                 // VL_COVDET_MAX_NUM_ORIENTATIONS
const EXTENT     : f32 = 9.0;           // 3*INTEGRATION_SIGMA
const INTEG_SIG  : f32 = 3.0;           // VL_COVDET_AA_RELATIVE_INTEGRATION_SIGMA
const SIGMA_D    : f32 = 1.0;           // covdet.c:2722
const PEAK_REL   : f32 = 0.8;           // VL_COVDET_OR_ADDITIONAL_PEAKS_RELATIVE_SIZE
const VL_PI      : f32 = 3.141592653589793;
const TWO_PI     : f32 = 6.283185307179586;
const BIN_EXTENT : f32 = TWO_PI / 36.0;
const STEPHAT    : f32 = EXTENT / 20.0; // extent/resolution = 0.45 (smoothing step)
const MASK_STEP  : f32 = 18.0 / 41.0;   // 2*extent/(2*w+1) = 18/41 (covdet.c:1548)

// ── Input keypoint frame (affine+refined), image-frame coords. 32 bytes. ──
// Mirrors VlFrameOrientedEllipse {x,y,a11,a12,a21,a22} + octave hint for the
// level-select octave range (echoed back into each output record). std430.
struct InputKp {
  x   : f32,
  y   : f32,
  a11 : f32,
  a12 : f32,
  a21 : f32,
  a22 : f32,
  octave : i32,   // echoed; not used by the warp (level-select scans all octaves)
  _pad0  : u32,
};

// ── Output oriented-keypoint record (one per detected orientation). 16 bytes. ──
struct OrientedKp {
  kp_index : u32,   // index into the InputKp array (so host re-derives the frame)
  angle    : f32,   // th = binExtent*(i+di) + theta0  (radians)
  score    : f32,   // h0 (smoothed-histogram peak value)
  _pad0    : u32,
};

// ── Per-octave geometry row (the flat gss pyramid's offset table). 32 bytes. ──
// One row per octave o in [first_octave .. last_octave]. `gss_offset` is the
// element offset (in f32) into `gss` where octave o's level block begins; the
// block is `num_levels` levels of `width*height` each, level-major. The level
// index s ranges over [first_sub .. last_sub]; level s sits at local index
// (s - first_sub).
struct OctaveGeom {
  width      : i32,
  height     : i32,
  step       : f32,   // ogeom.step = 2^o
  gss_offset : u32,   // f32-element offset into the flat gss buffer
  octave     : i32,   // the octave index o (== first_octave + row)
  _pad0      : u32,
  _pad1      : u32,
  _pad2      : u32,
};

struct OrientParams {
  num_kp           : u32,    // number of input keypoints
  num_octaves      : u32,    // rows in `geom`
  first_octave     : i32,    // geom.firstOctave
  last_octave      : i32,    // geom.lastOctave
  first_sub        : i32,    // geom.octaveFirstSubdivision (gss; default -1)
  last_sub         : i32,    // geom.octaveLastSubdivision  (gss; DOG default 4)
  octave_res       : f32,    // geom.octaveResolution (default 3)
  base_scale       : f32,    // geom.baseScale (1.6*2^(1/3))
  max_out          : u32,    // capacity of out_kp (records)
  _pad0            : u32,
  _pad1            : u32,
  _pad2            : u32,
};

@group(0) @binding(0) var<storage, read>       gss     : array<f32>;
@group(0) @binding(1) var<storage, read>        kps     : array<InputKp>;
@group(0) @binding(2) var<storage, read>        geom    : array<OctaveGeom>;
@group(0) @binding(3) var<storage, read_write>  out_count : atomic<u32>;
@group(0) @binding(4) var<storage, read_write>  out_kp    : array<OrientedKp>;
@group(0) @binding(5) var<uniform>              P         : OrientParams;

// ════════════════════════════════════════════════════════════════════════════
//  vl_fast_atan2_f (mathop.h:407-424) — VLFeat's c3/c1 polynomial approximation.
//  Replicated BIT-FOR-BIT (NOT libm atan2) so the bin assignment matches the CPU
//  reference exactly. VL_EPSILON_F = 1.19209290e-07 (single-precision eps).
// ════════════════════════════════════════════════════════════════════════════
const VL_EPSILON_F : f32 = 1.19209290e-07;

fn fast_atan2_f(y : f32, x : f32) -> f32 {
  let c3 : f32 = 0.1821;
  let c1 : f32 = 0.9675;
  let abs_y : f32 = abs(y) + VL_EPSILON_F;
  var r : f32;
  var angle : f32;
  if (x >= 0.0) {
    r = (x - abs_y) / (x + abs_y);
    angle = VL_PI / 4.0;
  } else {
    r = (x + abs_y) / (abs_y - x);
    angle = 3.0 * VL_PI / 4.0;
  }
  angle = angle + (c3 * r * r - c1) * r;
  if (y < 0.0) { return -angle; }
  return angle;
}

fn mod_2pi_f(x_in : f32) -> f32 {
  var x : f32 = x_in;
  // while loops match vl_mod_2pi_f (mathop.h:112-114) exactly. In practice the
  // argument is fast_atan2 in [-3pi/4, 3pi/4] plus 2pi, so 1-2 iterations.
  loop {
    if (!(x > TWO_PI)) { break; }
    x = x - TWO_PI;
  }
  loop {
    if (!(x < 0.0)) { break; }
    x = x + TWO_PI;
  }
  return x;
}

// vl_fast_sqrt_f (mathop.h:479-547): Quake fast inverse-sqrt (bit hack +
// TWO Newton steps), then x*resqrt(x); x<1e-8 -> 0. Replicated bit-for-bit so
// the gradient modulus weighting matches the CPU reference (NOT libm sqrt).
fn fast_resqrt_f(x : f32) -> f32 {
  let xhalf : f32 = 0.5 * x;
  var i : i32 = bitcast<i32>(x);
  i = 0x5f3759df - (i >> 1u);
  var y : f32 = bitcast<f32>(i);
  y = y * (1.5 - xhalf * y * y);
  y = y * (1.5 - xhalf * y * y);
  return y;
}
fn fast_sqrt_f(x : f32) -> f32 {
  if (x < 1e-8) { return 0.0; }
  return x * fast_resqrt_f(x);
}

// vl_floor_d analog for f32: floor toward -inf, returns i32.
fn floor_i(x : f32) -> i32 {
  return i32(floor(x));
}

// ════════════════════════════════════════════════════════════════════════════
//  vl_lapack_dlasv2 (mathop.c:712-826) + vl_svd2 (mathop.c:640-683), fp32.
//  Returns A=U*D and theta0 = atan2(V[1],V[0]) and the two singular values
//  d1=D[0]=smax, d2=D[3]=smin. M is column-major {a11,a21,a12,a22}.
// ════════════════════════════════════════════════════════════════════════════
fn dsign(x : f32) -> f32 { if (x < 0.0) { return -1.0; } return 1.0; }

struct Svd2Out {
  // A := U*D (column-major a[0..3]) and the singular values + theta0.
  a0 : f32, a1 : f32, a2 : f32, a3 : f32,
  d1 : f32,        // D[0] = smax (first singular value)
  d2 : f32,        // D[3] = smin (second singular value)
  theta0 : f32,    // atan2(V[1], V[0])
};

fn svd2_UDtheta0(m11 : f32, m21 : f32, m12 : f32, m22 : f32) -> Svd2Out {
  // vl_svd2 (mathop.c:643-663): rotate M by U1 to upper-triangular [f g;0 h].
  var cu1 : f32 = m11;
  var su1 : f32 = m21;
  let norm : f32 = sqrt(cu1 * cu1 + su1 * su1);
  cu1 = cu1 / norm;
  su1 = su1 / norm;
  let f : f32 = cu1 * m11 + su1 * m21;
  let g : f32 = cu1 * m12 + su1 * m22;
  let h : f32 = -su1 * m12 + cu1 * m22;

  // ── vl_lapack_dlasv2(f,g,h) (mathop.c:712-826) ──
  var svt : f32; var cvt : f32; var sut : f32; var cut : f32;
  var ft : f32 = f; var ht : f32 = h; let gt : f32 = g;
  var fa : f32 = abs(f); var ha : f32 = abs(h); let ga : f32 = abs(g);
  var pmax : i32 = 1;
  var swap : bool = false;
  var glarge : bool = false;
  var smin : f32 = 0.0;
  var smax : f32 = 0.0;

  if (fa < ha) {
    pmax = 3;
    let tmp0 : f32 = ft; ft = ht; ht = tmp0;       // swap ft,ht
    let tmp1 : f32 = fa; fa = ha; ha = tmp1;       // swap fa,ha
    swap = true;
  }

  if (ga == 0.0) {
    smin = ha;
    smax = fa;
    cut = 1.0; sut = 0.0;
    cvt = 1.0; svt = 0.0;
  } else {
    // initialize cut/etc so all paths assign (WGSL definite-init).
    cut = 1.0; sut = 0.0; cvt = 1.0; svt = 0.0;
    if (ga > fa) {
      pmax = 2;
      // VL_EPSILON_D in the original; fp32 path uses the same literal value.
      // (fa/ga < eps means g dominates; rare for affine frames.)
      if ((fa / ga) < 2.220446049250313e-16) {
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
    if (!glarge) {
      var d : f32;
      let fmh : f32 = fa - ha;
      if (fmh == fa) { d = 1.0; } else { d = fmh / fa; }
      let q : f32 = gt / ft;
      let s : f32 = 2.0 - d;
      let dd : f32 = d * d;
      let qq : f32 = q * q;
      let ss : f32 = s * s;
      let spq : f32 = sqrt(ss + qq);
      var dpq : f32;
      if (d == 0.0) { dpq = abs(q); } else { dpq = sqrt(dd + qq); }
      let a : f32 = 0.5 * (spq + dpq);
      smin = ha / a;
      smax = fa * a;
      var tmp : f32;
      if (qq == 0.0) {
        if (d == 0.0) {
          tmp = dsign(ft) * 2.0 * dsign(gt);
        } else {
          tmp = gt / (dsign(ft) * fmh) + q / s;
        }
      } else {
        tmp = (q / (spq + s) + q / (dpq + d)) * (1.0 + a);
      }
      let tt : f32 = sqrt(tmp * tmp + 4.0);
      cvt = 2.0 / tt;
      svt = tmp / tt;
      cut = (cvt + svt * q) / a;
      sut = (ht / ft) * svt / a;
    }
  }

  // unscramble (mathop.c:813-819)
  var cu : f32; var su : f32; var cv : f32; var sv : f32;
  if (swap) {
    cu = svt; su = cvt; cv = sut; sv = cut;
  } else {
    cu = cut; su = sut; cv = cvt; sv = svt;
  }
  // sign correction (mathop.c:820-825)
  var tsign : f32 = 1.0;
  if (pmax == 1) { tsign = dsign(cv) * dsign(cu) * dsign(f); }
  if (pmax == 2) { tsign = dsign(sv) * dsign(cu) * dsign(g); }
  if (pmax == 3) { tsign = dsign(sv) * dsign(su) * dsign(h); }
  smax = dsign(tsign) * smax;
  smin = dsign(tsign * dsign(f) * dsign(h)) * smin;

  // vl_svd2 reconstruct U,V (mathop.c:665-682). su2/cu2 = (su,cu); sv2/cv2=(sv,cv).
  // U[0]=cu2*cu1-su2*su1 ; U[1]=su2*cu1+cu2*su1 ; U[2]=-cu2*su1-su2*cu1 ; U[3]=-su2*su1+cu2*cu1
  let U0 : f32 = cu * cu1 - su * su1;
  let U1 : f32 = su * cu1 + cu * su1;
  let U2 : f32 = -cu * su1 - su * cu1;
  let U3 : f32 = -su * su1 + cu * cu1;
  // V[0]=cv2 ; V[1]=sv2 ; V[2]=-sv2 ; V[3]=cv2
  let V0 : f32 = cv;
  let V1 : f32 = sv;
  // S[0]=smax ; S[3]=smin
  let D0 : f32 = smax;
  let D3 : f32 = smin;

  // A := U*D (covdet.c:2747-2750): a0=U0*D0,a1=U1*D0,a2=U2*D3,a3=U3*D3
  var o : Svd2Out;
  o.a0 = U0 * D0;
  o.a1 = U1 * D0;
  o.a2 = U2 * D3;
  o.a3 = U3 * D3;
  o.d1 = D0;
  o.d2 = D3;
  o.theta0 = atan2(V1, V0);   // covdet.c:2752 — full atan2 (NOT the fast approx)
  return o;
}

// ════════════════════════════════════════════════════════════════════════════
//  Level select (vl_covdet_extract_patch_helper, covdet.c:2222-2241).
//  Returns the chosen octave row index (into geom[]) and the level s, plus
//  sigma1=sigma_/d1, sigma2=sigma_/d2 (for the pre-smoothing).
// ════════════════════════════════════════════════════════════════════════════
struct LevelSel {
  row    : i32,    // index into geom[] (geom row for the chosen octave)
  s      : i32,    // chosen subdivision level
  sigma1 : f32,
  sigma2 : f32,
};

fn vl_log2(x : f32) -> f32 { return log2(x); }

fn select_level(d1 : f32, d2 : f32, sigma : f32) -> LevelSel {
  let factor : f32 = 1.0 / min(d1, d2);
  let firstO : i32 = P.first_octave;
  let lastO  : i32 = P.last_octave;
  let firstSub : i32 = P.first_sub;
  let lastSub  : i32 = P.last_sub;
  let baseScale : f32 = P.base_scale;
  let octRes : f32 = P.octave_res;

  // Scan octaves firstO+1 .. lastO, stop when no level satisfies factor*sigma_<=sigma.
  // (covdet.c:2224-2234). `o` ends one BELOW the first failing octave (the o--).
  var o : i32 = firstO + 1;
  loop {
    if (o > lastO) { break; }
    var s : i32 = floor_i(vl_log2(sigma / (factor * baseScale)) - f32(o));
    s = max(s, firstSub);
    s = min(s, lastSub);
    let sigma_ : f32 = baseScale * pow(2.0, f32(o) + f32(s) / octRes);
    if (factor * sigma_ > sigma) {
      o = o - 1;
      break;
    }
    o = o + 1;
  }
  // covdet.c:2235: o = min(o, lastOctave). (After a clean fall-through o==lastO+1.)
  o = min(o, lastO);
  // Re-evaluate s for the final o (covdet.c:2236-2239).
  var s : i32 = floor_i(vl_log2(sigma / (factor * baseScale)) - f32(o));
  s = max(s, firstSub);
  s = min(s, lastSub);
  let sigma_ : f32 = baseScale * pow(2.0, f32(o) + f32(s) / octRes);

  var out : LevelSel;
  out.row = o - firstO;          // geom row index
  out.s = s;
  out.sigma1 = sigma_ / d1;
  out.sigma2 = sigma_ / d2;
  return out;
}

// Clamp-to-edge fetch of gss level (row=geom row, s=level), pixel (xi,yi).
// VLFeat pads the extracted region by continuity (covdet.c:2266-2359) so an
// out-of-bounds sample reads the nearest edge pixel — equivalent to clamping
// the fetch coordinates. The patch box leaves a 1px bilinear border in-bounds.
fn gss_fetch(row : i32, s : i32, xi : i32, yi : i32) -> f32 {
  let W : i32 = geom[row].width;
  let H : i32 = geom[row].height;
  let cx : i32 = clamp(xi, 0, W - 1);
  let cy : i32 = clamp(yi, 0, H - 1);
  let local_lvl : i32 = s - P.first_sub;               // level block index
  let base : u32 = geom[row].gss_offset
                 + u32((local_lvl * H + cy) * W + cx);
  return gss[base];
}

// ════════════════════════════════════════════════════════════════════════════
//  Patch pre-smoothing — separable Gaussian, clamp-to-edge.
//  vl_imsmooth_f (imopv.c:644-679) builds a normalized Gaussian kernel
//  (_vl_new_gaussian_fitler_, imopv.c:620-642: half-width w=ceil(3*sigma), taps
//  exp(-0.5*(i/sigma)^2), normalized to unit mass) and convolves it separably
//  with VL_PAD_BY_CONTINUITY (clamp-to-edge). vl_imsmooth_f runs the V pass
//  (sigmay) FIRST, then the H pass (sigmax) (imopv.c:662-672). For a symmetric
//  normalized filter, the chunked continuity-padded vl_imconvcol_v is exactly a
//  clamp-to-edge separable convolution — reimplemented as such here.
//
//  sigma==0 -> width=ceil(0)=0 -> kernel size 1, tap 1.0 (identity, no-op),
//  matching VLFeat (deltaSigma==0 when sigma_>=sigmaD).
//
//  MAXHW = 15 (kernel up to 31 taps). For the orientation pass sigma_smooth =
//  deltaSigma/stephat <= sqrt(1)/0.45 = 2.22 -> w=ceil(6.67)=7 <= 15. Bounds
//  the private kernel buffer; an out-of-range sigma would saturate (loud: the
//  harness compares vs VLFeat so a clamp shows up as error).
const MAXHW : i32 = 15;

// Build the normalized 1D Gaussian (returns half-width; taps written to `k`,
// k[0..2*hw] with k[hw] the center). Identity (hw=0,k[0]=1) when sigma<=0.
fn build_gauss(sigma : f32, k : ptr<function, array<f32, 31>>) -> i32 {
  if (sigma <= 0.0) {
    (*k)[0] = 1.0;
    return 0;
  }
  var hw : i32 = i32(ceil(sigma * 3.0));
  if (hw > MAXHW) { hw = MAXHW; }
  // mass = 1 + 2*sum_{i=1..hw} g(i)  (imopv.c:624-639)
  var mass : f32 = 1.0;
  (*k)[hw] = 1.0;
  for (var i : i32 = 1; i <= hw; i = i + 1) {
    let xx : f32 = f32(i) / sigma;
    let g : f32 = exp(-0.5 * xx * xx);
    mass = mass + g + g;
    (*k)[hw - i] = g;
    (*k)[hw + i] = g;
  }
  let n : i32 = 2 * hw + 1;
  for (var i : i32 = 0; i < n; i = i + 1) {
    (*k)[i] = (*k)[i] / mass;
  }
  return hw;
}

// In-place separable smooth of the 41x41 `patch` with sigmay (V pass first) then
// sigmax (H pass) — matching vl_imsmooth_f's pass order (imopv.c:662-672).
fn gaussian_smooth_patch(pat : ptr<function, array<f32, 1681>>,
                         sigmay : f32, sigmax : f32) {
  // Both zero -> nothing to do (the common sigma_>=sigmaD case).
  if (sigmay <= 0.0 && sigmax <= 0.0) { return; }

  var ky : array<f32, 31>;
  var kx : array<f32, 31>;
  let hwy : i32 = build_gauss(sigmay, &ky);
  let hwx : i32 = build_gauss(sigmax, &kx);

  var tmp : array<f32, 1681>;   // V-pass output

  // V pass (along y), clamp-to-edge.
  for (var xx : i32 = 0; xx < SIDE; xx = xx + 1) {
    for (var yy : i32 = 0; yy < SIDE; yy = yy + 1) {
      var acc : f32 = 0.0;
      for (var t : i32 = -hwy; t <= hwy; t = t + 1) {
        let sy : i32 = clamp(yy + t, 0, SIDE - 1);
        acc = acc + (*pat)[sy * SIDE + xx] * ky[hwy + t];
      }
      tmp[yy * SIDE + xx] = acc;
    }
  }
  // H pass (along x), clamp-to-edge, write back into pat.
  for (var yy : i32 = 0; yy < SIDE; yy = yy + 1) {
    for (var xx : i32 = 0; xx < SIDE; xx = xx + 1) {
      var acc : f32 = 0.0;
      for (var t : i32 = -hwx; t <= hwx; t = t + 1) {
        let sx : i32 = clamp(xx + t, 0, SIDE - 1);
        acc = acc + tmp[yy * SIDE + sx] * kx[hwx + t];
      }
      (*pat)[yy * SIDE + xx] = acc;
    }
  }
}

@compute @workgroup_size(64, 1, 1)
fn orient(@builtin(global_invocation_id) gid : vec3<u32>) {
  let kidx : u32 = gid.x;
  if (kidx >= P.num_kp) { return; }

  let kp : InputKp = kps[kidx];

  // (1) svd2 decomposition: A := U*D, theta0, singular values d1,d2.
  // A column-major M = {a11, a21, a12, a22} (covdet.c:2716).
  let sv : Svd2Out = svd2_UDtheta0(kp.a11, kp.a21, kp.a12, kp.a22);
  let theta0 : f32 = sv.theta0;
  let d1 : f32 = sv.d1;
  let d2 : f32 = sv.d2;

  // (2) level select with sigma = sigmaD = 1.0.
  let lv : LevelSel = select_level(d1, d2, SIGMA_D);
  let row : i32 = lv.row;
  let s   : i32 = lv.s;
  let step : f32 = geom[row].step;

  // A,T /= step (covdet.c:2259-2264). A is the U*D from svd2.
  let A0 : f32 = sv.a0 / step;
  let A1 : f32 = sv.a1 / step;
  let A2 : f32 = sv.a2 / step;
  let A3 : f32 = sv.a3 / step;
  let T0 : f32 = kp.x / step;
  let T1 : f32 = kp.y / step;

  // (2b) bilinear warp resample into a private patch (covdet.c:2365-2398).
  // stephat = extent/resolution = 0.45. yhat,xhat sweep [-extent, +extent].
  var pat : array<f32, 1681>;   // NPIX = 41*41 fp32 (~6.7 KB private)
  let stephat : f32 = EXTENT / f32(RES);
  var yhat : f32 = -EXTENT;
  for (var yyi : i32 = 0; yyi < SIDE; yyi = yyi + 1) {
    var xhat : f32 = -EXTENT;
    let rx : f32 = A2 * yhat + T0;
    let ry : f32 = A3 * yhat + T1;
    for (var xxi : i32 = 0; xxi < SIDE; xxi = xxi + 1) {
      let x : f32 = A0 * xhat + rx;
      let y : f32 = A1 * xhat + ry;
      let xi : i32 = floor_i(x);
      let yi : i32 = floor_i(y);
      let i00 : f32 = gss_fetch(row, s, xi,     yi);
      let i10 : f32 = gss_fetch(row, s, xi + 1, yi);
      let i01 : f32 = gss_fetch(row, s, xi,     yi + 1);
      let i11 : f32 = gss_fetch(row, s, xi + 1, yi + 1);
      let wx : f32 = x - f32(xi);
      let wy : f32 = y - f32(yi);
      pat[yyi * SIDE + xxi] =
        (1.0 - wy) * ((1.0 - wx) * i00 + wx * i10) +
        wy * ((1.0 - wx) * i01 + wx * i11);
      xhat = xhat + stephat;
    }
    yhat = yhat + stephat;
  }

  // (3) anisotropic pre-smoothing (covdet.c:2767-2774).
  let deltaSigma1 : f32 = sqrt(max(SIGMA_D * SIGMA_D - lv.sigma1 * lv.sigma1, 0.0));
  let deltaSigma2 : f32 = sqrt(max(SIGMA_D * SIGMA_D - lv.sigma2 * lv.sigma2, 0.0));
  // vl_imsmooth_f does sigmay (=deltaSigma2/stephat) first (v-pass), then sigmax.
  // imopv.c:662-672: filtery applied first, filterx second.
  gaussian_smooth_patch(&pat, deltaSigma2 / stephat, deltaSigma1 / stephat);

  // (4) histogram of oriented gradients (covdet.c:2776-2794). Build gradient
  // (modulus, angle) on the fly and accumulate the 36-bin histogram.
  var hist : array<f32, 36>;
  for (var b : i32 = 0; b < NBINS; b = b + 1) { hist[b] = 0.0; }

  for (var yy : i32 = 0; yy < SIDE; yy = yy + 1) {
    for (var xx : i32 = 0; xx < SIDE; xx = xx + 1) {
      let k : i32 = yy * SIDE + xx;
      // gradient (imopv.c:874-974). Border -> forward/backward diff; interior
      // -> central diff *0.5. stride = SIDE.
      var gx : f32;
      var gy : f32;
      if (xx == 0) {
        gx = pat[k + 1] - pat[k];
      } else if (xx == SIDE - 1) {
        gx = pat[k] - pat[k - 1];
      } else {
        gx = 0.5 * (pat[k + 1] - pat[k - 1]);
      }
      if (yy == 0) {
        gy = pat[k + SIDE] - pat[k];
      } else if (yy == SIDE - 1) {
        gy = pat[k] - pat[k - SIDE];
      } else {
        gy = 0.5 * (pat[k + SIDE] - pat[k - SIDE]);
      }
      let modulus : f32 = fast_sqrt_f(gx * gx + gy * gy);
      let angle : f32 = mod_2pi_f(fast_atan2_f(gy, gx) + TWO_PI);

      // mask weight: exp(-0.5*(dx^2+dy^2)), dx=i*step/sigma, dy=j*step/sigma,
      // i,j in [-w,w], step=18/41, sigma=3 (covdet.c:1545-1556). i=xx-RES, j=yy-RES.
      let dx_m : f32 = f32(xx - RES) * MASK_STEP / INTEG_SIG;
      let dy_m : f32 = f32(yy - RES) * MASK_STEP / INTEG_SIG;
      let weight : f32 = exp(-0.5 * (dx_m * dx_m + dy_m * dy_m));

      // bin accumulation (covdet.c:2787-2793)
      let xb : f32 = angle / BIN_EXTENT;
      let bin : i32 = floor_i(xb);
      let w2 : f32 = xb - f32(bin);
      let w1 : f32 = 1.0 - w2;
      let b0 : i32 = ((bin % NBINS) + NBINS) % NBINS;
      let b1 : i32 = (((bin + 1) % NBINS) + NBINS) % NBINS;
      hist[b0] = hist[b0] + w1 * (modulus * weight);
      hist[b1] = hist[b1] + w2 * (modulus * weight);
    }
  }

  // (5) smooth the histogram, 6 cyclic 3-tap passes (covdet.c:2796-2807).
  for (var iter : i32 = 0; iter < 6; iter = iter + 1) {
    var prev : f32 = hist[NBINS - 1];
    let first : f32 = hist[0];
    var i : i32 = 0;
    loop {
      if (i >= NBINS - 1) { break; }
      let curr : f32 = (prev + hist[i] + hist[(i + 1) % NBINS]) / 3.0;
      prev = hist[i];
      hist[i] = curr;
      i = i + 1;
    }
    // i == NBINS-1 here (last bin), VLFeat: hist[i] = (prev + hist[i] + first)/3
    hist[NBINS - 1] = (prev + hist[NBINS - 1] + first) / 3.0;
  }

  // (6a) histogram maximum (covdet.c:2809-2813).
  var maxPeakValue : f32 = 0.0;
  for (var i : i32 = 0; i < NBINS; i = i + 1) {
    maxPeakValue = max(maxPeakValue, hist[i]);
  }

  // (6b) peaks within 0.8*max + parabolic interp + EXPAND (covdet.c:2815-2838).
  var numOr : u32 = 0u;
  // Collect into a small private array so the host-visible sort order is the
  // SAME bin-scan order VLFeat emits (it then qsorts by score; we emit in scan
  // order + the harness sorts identically — see harness note).
  var ang : array<f32, 4>;
  var sco : array<f32, 4>;
  for (var i : i32 = 0; i < NBINS; i = i + 1) {
    let h0 : f32 = hist[i];
    let hm : f32 = hist[(((i - 1) % NBINS) + NBINS) % NBINS];
    let hp : f32 = hist[(((i + 1) % NBINS) + NBINS) % NBINS];
    if (h0 > PEAK_REL * maxPeakValue && h0 > hm && h0 > hp) {
      let di : f32 = -0.5 * (hp - hm) / (hp + hm - 2.0 * h0);
      let th : f32 = BIN_EXTENT * (f32(i) + di) + theta0;
      // transposed == false in our path (no -pi/2 branch, covdet.c:2827-2830).
      ang[numOr] = th;
      sco[numOr] = h0;
      numOr = numOr + 1u;
      if (numOr >= MAXOR) { break; }
    }
  }

  // (7) atomic-append numOr records (the 1-4x expansion). Reserve a contiguous
  // block so all of a kp's orientations land together (host groups by kp_index).
  if (numOr == 0u) { return; }
  let base : u32 = atomicAdd(&out_count, numOr);
  for (var j : u32 = 0u; j < numOr; j = j + 1u) {
    let slot : u32 = base + j;
    if (slot < P.max_out) {
      out_kp[slot].kp_index = kidx;
      out_kp[slot].angle    = ang[j];
      out_kp[slot].score    = sco[j];
      out_kp[slot]._pad0    = 0u;
    }
  }
}
