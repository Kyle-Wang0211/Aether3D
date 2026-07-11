// sift_affine_shape.wgsl — per-keypoint affine shape estimation (Stage C).
//
// GPU port of VLFeat vl_covdet_extract_affine_shape_for_frame (covdet.c:2463),
// the Baumberg-Lindeberg iteration that turns each isotropic DoG keypoint into
// an oriented ellipse (a11,a12,a21,a22). One WORKGROUP per keypoint; 64 lanes
// cooperate on the 41x41 affine wpatch warp + second-moment accumulation.
//
// Constants (covdet.c:1434-1442):
//   PATCH_RESOLUTION 20  -> side = 41, wpatch = 41x41 = 1681 px
//   MAX_NUM_ITERATIONS 15
//   RELATIVE_INTEGRATION_SIGMA 3   (mask sigma; EXTENT = 3*3 = 9)
//   RELATIVE_DERIVATIVE_SIGMA  1   (sigmaD, the wpatch-helper target smoothing)
//   MAX_ANISOTROPY 5
//   CONVERGENCE_THRESHOLD 1.001
//   ACCURATE_SMOOTHING false       (so the in-loop imsmooth is SKIPPED)
//
// 16KB workgroup-memory budget: VLFeat materializes aaPatch + aaPatchX +
// aaPatchY + aaMask (4 x 41x41 f32 = ~26.9KB > 16KB). We keep ONLY aaPatch
// resident in workgroup memory (1681 f32 = 6724B); the gradient (central diff)
// and the gaussian mask are recomputed ON THE FLY per pixel during the
// second-moment accumulation (mask is the closed form exp(-0.5*(dx^2+dy^2)),
// gradient is a 4-neighbour read of the resident wpatch). This stays well under
// 16KB and avoids the GPU_DSP_SIFT_PLAN.md:88 overflow.
//
// f32 throughout (VLFeat uses f64; no f64 in WGSL). The SVD/iteration is on
// well-conditioned 2x2 systems; the gate tolerates the f32 round-off.
//
// Cross-octave: the wpatch-helper level selection (covdet.c:2222-2239) scans all
// octaves and may sample octave 1+ for an octave-0 keypoint (verified: 7.9% of
// real octave-0 kps). The full fo=0 pyramid is packed into `packed_gss` with a
// per-(octave,sublevel) meta table, so any level is reachable from one binding.

const SIDE : u32 = 41u;            // 2*20 + 1
const NPIX : u32 = 1681u;          // 41*41
const RES  : f32 = 20.0;           // PATCH_RESOLUTION
const EXTENT : f32 = 9.0;          // 3 * INTEGRATION_SIGMA(3)
const SIGMA_D : f32 = 1.0;         // RELATIVE_DERIVATIVE_SIGMA
const INTEG_SIGMA : f32 = 3.0;     // RELATIVE_INTEGRATION_SIGMA (mask)
const MAX_ITER : i32 = 15;
const MAX_ANISO : f32 = 5.0;
const CONV : f32 = 1.001;
const KP_STRIDE : u32 = 8u;
const WG : u32 = 64u;

struct LevelMeta { offset : u32, width : u32, height : u32, pad : u32 };

struct Params {
  count        : u32,
  first_octave : i32,
  last_octave  : i32,
  oct_res      : i32,
  base_scale   : f32,
  oct_first_sub: i32,
  oct_last_sub : i32,
  levels_per_oct : u32,   // kLevelsPerOctave = 6
};

@group(0) @binding(0) var<storage, read>       packed_gss : array<f32>;
@group(0) @binding(1) var<storage, read>       level_meta : array<LevelMeta>;
@group(0) @binding(2) var<storage, read>       kp_buffer  : array<u32>;   // count*KP_STRIDE
@group(0) @binding(3) var<storage, read_write> out_ell    : array<f32>;   // count*5 (a11,a12,a21,a22,ok)
@group(0) @binding(4) var<uniform>             P          : Params;

// ── workgroup state ──
var<workgroup> wpatch : array<f32, 1681>;       // resident warped wpatch
var<workgroup> red   : array<f32, 64>;         // reduction scratch (one lane each)
var<workgroup> A_sh  : array<f32, 4>;          // shared current A (col-major a11,a21,a12,a22)
var<workgroup> T_sh  : array<f32, 2>;          // shared T (image-frame x,y)
var<workgroup> ctl   : u32;                    // control: 1 = stop the iteration
var<workgroup> refScale : f32;                 // referenceScale (fixed after iter0)
var<workgroup> adapt_sh : array<f32, 4>;       // published adapted A (col-major)
var<workgroup> d12_sh   : array<f32, 2>;       // d1,d2 for level pick

// ── 2x2 SVD: VLFeat vl_svd2 + vl_lapack_dlasv2 (mathop.c:641 / :713) ──
// Returns S (smax,0,0,smin), U, V as col-major 2x2. f64→f32 port, verbatim flow.
fn fsign(x : f32) -> f32 { if (x < 0.0) { return -1.0; } return 1.0; }
fn isign(i : i32) -> f32 { if (i < 0) { return -1.0; } return 1.0; }

// dlasv2 core: inputs f,g,h ; outputs smin,smax,sv,cv,su,cu.
struct Dlasv2 { smin:f32, smax:f32, sv:f32, cv:f32, su:f32, cu:f32 };
fn dlasv2(f : f32, g : f32, h : f32) -> Dlasv2 {
  var o : Dlasv2;
  var ft = f; var gt = g; var ht = h;
  var fa = abs(f); var ga = abs(g); var ha = abs(h);
  var pmax : i32 = 1;
  var swap : i32 = 0;
  var glarge : i32 = 0;
  var svt : f32 = 0.0; var cvt : f32 = 1.0; var sut : f32 = 0.0; var cut : f32 = 1.0;
  var smin : f32 = 0.0; var smax : f32 = 0.0;

  if (fa < ha) {
    pmax = 3;
    let t1 = ft; ft = ht; ht = t1;
    let t2 = fa; fa = ha; ha = t2;
    swap = 1;
  }

  if (ga == 0.0) {
    smin = ha; smax = fa;
    cut = 1.0; sut = 0.0; cvt = 1.0; svt = 0.0;
  } else {
    if (ga > fa) {
      pmax = 2;
      if ((fa / ga) < 2.2204460492503131e-16) {  // VL_EPSILON_D
        glarge = 1;
        smax = ga;
        if (ha > 1.0) { smin = fa / (ga / ha); } else { smin = (fa / ga) * ha; }
        cut = 1.0; sut = ht / gt; cvt = 1.0; svt = ft / gt;
      }
    }
    if (glarge == 0) {
      var d : f32;
      let fmh = fa - ha;
      if (fmh == fa) { d = 1.0; } else { d = fmh / fa; }
      let q = gt / ft;
      let s = 2.0 - d;
      let dd = d * d;
      let qq = q * q;
      let ss = s * s;
      let spq = sqrt(ss + qq);
      var dpq : f32;
      if (d == 0.0) { dpq = abs(q); } else { dpq = sqrt(dd + qq); }
      let a = 0.5 * (spq + dpq);
      smin = ha / a;
      smax = fa * a;
      var tmp : f32;
      if (qq == 0.0) {
        if (d == 0.0) { tmp = fsign(ft) * 2.0 * fsign(gt); }
        else { tmp = gt / (fsign(ft) * fmh) + q / s; }
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

  if (swap == 1) {
    o.cu = svt; o.su = cvt; o.cv = sut; o.sv = cut;
  } else {
    o.cu = cut; o.su = sut; o.cv = cvt; o.sv = svt;
  }
  var tsign : f32 = 1.0;
  if (pmax == 1) { tsign = fsign(o.cv) * fsign(o.cu) * fsign(f); }
  if (pmax == 2) { tsign = fsign(o.sv) * fsign(o.cu) * fsign(g); }
  if (pmax == 3) { tsign = fsign(o.sv) * fsign(o.su) * fsign(h); }
  o.smax = tsign * smax;
  o.smin = (tsign * fsign(f) * fsign(h)) * smin;
  return o;
}

// vl_svd2: M col-major (m11,m21,m12,m22). Returns S(diag), U, V col-major.
struct Svd2 { s0:f32, s3:f32, u0:f32, u1:f32, u2:f32, u3:f32, v0:f32, v1:f32, v2:f32, v3:f32 };
fn svd2(m11:f32, m21:f32, m12:f32, m22:f32) -> Svd2 {
  var r : Svd2;
  var cu1 = m11; var su1 = m21;
  let norm = sqrt(cu1 * cu1 + su1 * su1);
  cu1 = cu1 / norm; su1 = su1 / norm;
  let f = cu1 * m11 + su1 * m21;
  let g = cu1 * m12 + su1 * m22;
  let h = -su1 * m12 + cu1 * m22;
  let d = dlasv2(f, g, h);
  r.s0 = d.smax; r.s3 = d.smin;
  r.u0 = d.cu * cu1 - d.su * su1;
  r.u1 = d.su * cu1 + d.cu * su1;
  r.u2 = -d.cu * su1 - d.su * cu1;
  r.u3 = -d.su * su1 + d.cu * cu1;
  r.v0 = d.cv; r.v1 = d.sv; r.v2 = -d.sv; r.v3 = d.cv;
  return r;
}

// sample packed gss level `li` at clamped (x,y) — clamp-to-edge == VLFeat's
// "extend by continuity" padding for the warp.
fn level_at(li : u32, x : i32, y : i32) -> f32 {
  let m = level_meta[li];
  let w = i32(m.width); let h = i32(m.height);
  let cx = max(0, min(x, w - 1));
  let cy = max(0, min(y, h - 1));
  return packed_gss[m.offset + u32(cy * w + cx)];
}

// wpatch-helper level selection (covdet.c:2222-2239): pick octave o + sublevel s
// such that sigma_(o,s)*factor <= sigmaD, scanning octaves low→high; factor =
// 1/min(d1,d2). Returns flat level index into level_meta + the octave step.
struct LevelPick { li : u32, step : f32, ok : bool };
fn pick_level(d1 : f32, d2 : f32) -> LevelPick {
  var r : LevelPick;
  let factor = 1.0 / min(d1, d2);
  let lg2 = log2(SIGMA_D / (factor * P.base_scale));
  var o = P.first_octave + 1;
  loop {
    if (o > P.last_octave) { break; }
    var s = i32(floor(lg2 - f32(o)));
    s = max(s, P.oct_first_sub); s = min(s, P.oct_last_sub);
    let sigma_ = P.base_scale * exp2(f32(o) + f32(s) / f32(P.oct_res));
    if (factor * sigma_ > SIGMA_D) { o = o - 1; break; }
    o = o + 1;
  }
  o = min(o, P.last_octave);
  o = max(o, P.first_octave);   // guard (loop may leave o = first_octave)
  var s = i32(floor(lg2 - f32(o)));
  s = max(s, P.oct_first_sub); s = min(s, P.oct_last_sub);
  r.li = u32(o) * P.levels_per_oct + u32(s - P.oct_first_sub);
  r.step = exp2(f32(o));
  r.ok = true;
  return r;
}

@compute @workgroup_size(64, 1, 1)
fn main(@builtin(workgroup_id) wid : vec3<u32>,
        @builtin(local_invocation_id) lid : vec3<u32>) {
  let kp : u32 = wid.x;
  let lane : u32 = lid.x;
  if (kp >= P.count) { return; }

  // load keypoint frame (isotropic: a11=a22=sigma, a12=a21=0).
  let base = kp * KP_STRIDE;
  let fx = bitcast<f32>(kp_buffer[base + 0u]);
  let fy = bitcast<f32>(kp_buffer[base + 1u]);
  let sigma_kp = bitcast<f32>(kp_buffer[base + 2u]);

  if (lane == 0u) {
    // A col-major {a11,a21,a12,a22} = {sigma,0,0,sigma}; T = {x,y}.
    A_sh[0] = sigma_kp; A_sh[1] = 0.0; A_sh[2] = 0.0; A_sh[3] = sigma_kp;
    T_sh[0] = fx; T_sh[1] = fy;
    // default adapted = input frame (VLFeat returns frame if never updated).
    adapt_sh[0] = sigma_kp; adapt_sh[1] = 0.0; adapt_sh[2] = 0.0; adapt_sh[3] = sigma_kp;
    ctl = 0u;
  }
  workgroupBarrier();

  var iter : i32 = 0;
  loop {
    if (iter >= MAX_ITER) { break; }
    // workgroupUniformLoad makes ctl a UNIFORM value (and acts as a barrier),
    // so this break is in uniform control flow → barriers below are legal.
    if (workgroupUniformLoad(&ctl) != 0u) { break; }

    // ── lane 0: SVD(A) → anisotropy / factor / A = U*D, write adapted ──
    // also compute d1,d2 for the wpatch level selection.
    // All lanes need A for the warp, so lane0 writes A_sh then barrier.
    var d1 : f32 = 0.0; var d2 : f32 = 0.0;
    if (lane == 0u) {
      let sv = svd2(A_sh[0], A_sh[1], A_sh[2], A_sh[3]);
      var D0 = sv.s0; var D3 = sv.s3;
      let aniso = max(D0 / D3, D3 / D0);
      if (aniso > MAX_ANISO) {
        ctl = 1u;  // diverged: keep current adapted, stop
      } else {
        // factor: iter0 → 1 (referenceScale = min); else referenceScale/min.
        // VLFeat fixes the SMALLEST singular value after iter0. We track
        // referenceScale across iters via A_sh's implied scale: simpler to
        // recompute — referenceScale is min(D0,D3) at iter0. Store it in red[63]
        // (reused) on iter0.
        var factor : f32 = 1.0;
        if (iter == 0) {
          refScale = min(D0, D3);  // referenceScale, fixed hereafter
          factor = 1.0;
        } else {
          factor = refScale / min(D0, D3);
        }
        D0 = D0 * factor; D3 = D3 * factor;
        // A = U * D (col-major). U cols scaled by D0 (col0), D3 (col1).
        A_sh[0] = sv.u0 * D0; A_sh[1] = sv.u1 * D0;
        A_sh[2] = sv.u2 * D3; A_sh[3] = sv.u3 * D3;
        // publish adapted = A and d1,d2 for the warp/level-pick.
        adapt_sh[0] = A_sh[0]; adapt_sh[1] = A_sh[1];
        adapt_sh[2] = A_sh[2]; adapt_sh[3] = A_sh[3];
        d12_sh[0] = D0; d12_sh[1] = D3;
      }
    }
    // uniform barrier + ctl read; break if lane0 set divergence above.
    if (workgroupUniformLoad(&ctl) != 0u) { break; }

    // publish adapted from lane0's stash (all lanes read).
    d1 = d12_sh[0]; d2 = d12_sh[1];

    // last iteration: adapted is already published; stop BEFORE the (unused) warp.
    if (iter + 1 >= MAX_ITER) { break; }

    // ── pick gss level for the warp ──
    let pk = pick_level(d1, d2);
    let m = level_meta[pk.li];
    // A,T divided by step (covdet.c:2259-2264).
    let a0 = A_sh[0] / pk.step; let a1 = A_sh[1] / pk.step;
    let a2 = A_sh[2] / pk.step; let a3 = A_sh[3] / pk.step;
    let t0 = T_sh[0] / pk.step; let t1 = T_sh[1] / pk.step;

    // ── warp 41x41 wpatch (covdet.c:2365-2398), bilinear, clamp-to-edge ──
    let stephat = EXTENT / RES;
    for (var idx = lane; idx < NPIX; idx = idx + WG) {
      let yyi = i32(idx / SIDE);
      let xxi = i32(idx % SIDE);
      let yhat = -EXTENT + f32(yyi) * stephat;
      let xhat = -EXTENT + f32(xxi) * stephat;
      let rx = a2 * yhat + t0;
      let ry = a3 * yhat + t1;
      let x = a0 * xhat + rx;
      let y = a1 * xhat + ry;
      let xi = i32(floor(x));
      let yi = i32(floor(y));
      let wx = x - f32(xi);
      let wy = y - f32(yi);
      let i00 = level_at(pk.li, xi,     yi);
      let i10 = level_at(pk.li, xi + 1, yi);
      let i01 = level_at(pk.li, xi,     yi + 1);
      let i11 = level_at(pk.li, xi + 1, yi + 1);
      wpatch[idx] = (1.0 - wy) * ((1.0 - wx) * i00 + wx * i10) +
                   wy * ((1.0 - wx) * i01 + wx * i11);
    }
    workgroupBarrier();

    // ── second-moment M = Σ mask·[lx², lxly, ly²] (covdet.c:2549-2562) ──
    // gradient = vl_imgradient_f central diff (edges fwd/bwd); mask = closed form.
    var lxx : f32 = 0.0; var lxy : f32 = 0.0; var lyy : f32 = 0.0;
    let step_mask = (2.0 * EXTENT) / f32(SIDE);  // covdet.c:1548
    for (var idx = lane; idx < NPIX; idx = idx + WG) {
      let yy = i32(idx / SIDE);
      let xx = i32(idx % SIDE);
      // central-difference gradient of `wpatch` (vl_imgradient_f semantics):
      //   interior: 0.5*(p[+1]-p[-1]); first/last col/row: fwd/bwd diff.
      var lx : f32; var ly : f32;
      let c = wpatch[idx];
      if (xx == 0) { lx = wpatch[idx + 1u] - c; }
      else if (xx == i32(SIDE) - 1) { lx = c - wpatch[idx - 1u]; }
      else { lx = 0.5 * (wpatch[idx + 1u] - wpatch[idx - 1u]); }
      if (yy == 0) { ly = wpatch[idx + SIDE] - c; }
      else if (yy == i32(SIDE) - 1) { ly = c - wpatch[idx - SIDE]; }
      else { ly = 0.5 * (wpatch[idx + SIDE] - wpatch[idx - SIDE]); }
      // mask: i,j in [-20,20]; dx=i*step/sigma, mask=exp(-0.5(dx²+dy²)).
      let mi = f32(xx - 20);
      let mj = f32(yy - 20);
      let dxm = mi * step_mask / INTEG_SIGMA;
      let dym = mj * step_mask / INTEG_SIGMA;
      let mask = exp(-0.5 * (dxm * dxm + dym * dym));
      lxx = lxx + lx * lx * mask;
      lyy = lyy + ly * ly * mask;
      lxy = lxy + lx * ly * mask;
    }
    // reduce lxx,lyy,lxy across lanes (workgroup-barrier tree, no warp shuffle).
    // three sequential reductions via the shared `red` array.
    // --- lxx ---
    red[lane] = lxx; workgroupBarrier();
    var off = WG / 2u;
    loop { if (off == 0u) { break; } if (lane < off) { red[lane] = red[lane] + red[lane + off]; } workgroupBarrier(); off = off / 2u; }
    let Mxx = red[0]; workgroupBarrier();
    // --- lyy ---
    red[lane] = lyy; workgroupBarrier();
    off = WG / 2u;
    loop { if (off == 0u) { break; } if (lane < off) { red[lane] = red[lane] + red[lane + off]; } workgroupBarrier(); off = off / 2u; }
    let Myy = red[0]; workgroupBarrier();
    // --- lxy ---
    red[lane] = lxy; workgroupBarrier();
    off = WG / 2u;
    loop { if (off == 0u) { break; } if (lane < off) { red[lane] = red[lane] + red[lane + off]; } workgroupBarrier(); off = off / 2u; }
    let Mxy = red[0]; workgroupBarrier();

    // ── lane 0: M SVD → convergence test → A update (covdet.c:2564-2598) ──
    if (lane == 0u) {
      if (Mxx == 0.0 || Myy == 0.0) {
        // reset to input frame, stop (VLFeat: *adapted = frame; break).
        adapt_sh[0] = sigma_kp; adapt_sh[1] = 0.0; adapt_sh[2] = 0.0; adapt_sh[3] = sigma_kp;
        ctl = 1u;
      } else {
        let svm = svd2(Mxx, Mxy, Mxy, Myy);  // M col-major (Mxx,Mxy,Mxy,Myy)
        let Q0 = svm.s0; let Q3 = svm.s3;
        if (Q3 / Q0 < CONV && Q0 / Q3 < CONV) {
          ctl = 1u;  // converged: keep current adapted (already in adapt_sh)
        } else {
          // A <- A * P * Q^{-1/2}, P = svm.U (svm.u*). q0=sqrt(Q0), q1=sqrt(Q3).
          let q0 = sqrt(Q0); let q1 = sqrt(Q3);
          let P0 = svm.u0; let P1 = svm.u1; let P2 = svm.u2; let P3 = svm.u3;
          let A0 = A_sh[0]; let A1 = A_sh[1]; let A2 = A_sh[2]; let A3 = A_sh[3];
          // Ap (covdet.c:2593-2596), col-major.
          let Ap0 = (A0 * P0 + A2 * P1) / q0;
          let Ap1 = (A1 * P0 + A3 * P1) / q0;
          let Ap2 = (A0 * P2 + A2 * P3) / q1;
          let Ap3 = (A1 * P2 + A3 * P3) / q1;
          A_sh[0] = Ap0; A_sh[1] = Ap1; A_sh[2] = Ap2; A_sh[3] = Ap3;
        }
      }
    }
    workgroupBarrier();

    iter = iter + 1;
  }

  // Final published adapted A is in adapt_sh (lane0 wrote it; the loop's last
  // barrier ordered it). make-upright is lane-0-only → no further barriers.
  workgroupBarrier();

  // ── make-upright rotation (covdet.c:2610-2639): lane 0 only ──
  if (lane == 0u) {
    // A col-major {a11,a21,a12,a22} = adapt_sh.
    let A0 = adapt_sh[0]; let A1 = adapt_sh[1]; let A2 = adapt_sh[2]; let A3 = adapt_sh[3];
    // ref = (0,1) (up = y axis; transposed=false). solve A * ref_ = ref.
    // 2x2 solve via Gaussian elim (vl_solve_linear_system_2). A row-major in
    // VLFeat's Aat(i,j)=A[i+j*2] → here A[0]=A0,A[1]=A1,A[2]=A2,A[3]=A3 already.
    // Solve [[A0,A2],[A1,A3]] x = [0,1].
    let det = A0 * A3 - A2 * A1;
    var rx_ : f32; var ry_ : f32;
    if (abs(det) < 1e-10) { rx_ = 0.0; ry_ = 1.0; }
    else {
      // x = inv(A) * (0,1): inv = 1/det [[A3,-A2],[-A1,A0]]
      rx_ = (-A2 * 1.0) / det;   // (A3*0 - A2*1)/det
      ry_ = ( A0 * 1.0) / det;   // (-A1*0 + A0*1)/det
    }
    let angle = atan2(1.0, 0.0);            // ref = (0,1) → atan2(1,0)=pi/2
    let angle_ = atan2(ry_, rx_);
    let dangle = angle_ - angle;
    let r1 = cos(dangle); let r2 = sin(dangle);
    let o11 =  A0 * r1 + A2 * r2;
    let o21 =  A1 * r1 + A3 * r2;
    let o12 = -A0 * r2 + A2 * r1;
    let o22 = -A1 * r2 + A3 * r1;
    let outb = kp * 5u;
    out_ell[outb + 0u] = o11;  // a11
    out_ell[outb + 1u] = o12;  // a12
    out_ell[outb + 2u] = o21;  // a21
    out_ell[outb + 3u] = o22;  // a22
    out_ell[outb + 4u] = 1.0;  // ok flag (GPU always returns a frame, like VLFeat OK path)
  }
}
