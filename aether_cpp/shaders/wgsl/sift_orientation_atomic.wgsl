// sift_orientation_atomic.wgsl — 36 格定点共享原子加方向直方图。
//
// [ORIENT-ATOMIC 2026-08-10 用户签,DESC-ATOMIC 同款质量门] 与
// sift_orientation.wgsl 唯一差异:每 lane 私有 local_hist[36](144B 寄存
// 器)+ 36 轮逐 bin 归约(~290 barrier/kp)→ 36 格共享 atomic<i32> 黑板
// + 每 kp 自适应定点曝光 FXP=2^30/(maxgrad*2048)(2048>=1681 像素上界;
// 预扫 u32 atomicMax on f32 bits)。梯度/权重/插值数学与原版逐字符相同。
// 原版注释当年就写了"定点原子加?"然后放弃 —— DESC-ATOMIC(desc −76%)
// 已验证此路;此处 barrier 消灭量更大(290→~6)。

const SIDE : u32 = 41u;
const NPIX : u32 = 1681u;
const RES  : f32 = 20.0;
const EXTENT : f32 = 9.0;
const SIGMA_D : f32 = 1.0;
const INTEG_SIGMA : f32 = 3.0;
const NUM_BINS : u32 = 36u;
const PEAK_REL : f32 = 0.8;
const MAX_ORI : u32 = 4u;
const KP_STRIDE : u32 = 8u;
const OUT_STRIDE : u32 = 8u;     // oriented kp record (x,y,a11,a12,a21,a22,o,s)
const WG : u32 = 384u;  // [K9] 每 keypoint 256 lane:逐像素工作互相独立、直方图是整数原子、max 与顺序无关 ⇒ 逐位同;目的=提高驻留 SIMD 组数
const PI : f32 = 3.14159265358979323846;
const CAP : u32 = 65536u;        // oriented-kp output capacity guard

struct LevelMeta { offset : u32, width : u32, height : u32, pad : u32 };

struct Params {
  count        : u32,
  first_octave : i32,
  last_octave  : i32,
  oct_res      : i32,
  base_scale   : f32,
  oct_first_sub: i32,
  oct_last_sub : i32,
  levels_per_oct : u32,
};

@group(0) @binding(0) var<storage, read>       packed_gss : array<f32>;
@group(0) @binding(1) var<storage, read>       level_meta : array<LevelMeta>;
@group(0) @binding(2) var<storage, read>       kp_in      : array<u32>;   // count*KP_STRIDE
@group(0) @binding(3) var<storage, read_write> kp_out     : array<u32>;   // CAP*OUT_STRIDE
@group(0) @binding(4) var<storage, read_write> out_counter: atomic<u32>;
@group(0) @binding(5) var<storage, read_write> dbg        : array<f32>;   // CAP*2 (frame_idx, theta)
@group(0) @binding(6) var<uniform>             P          : Params;

var<workgroup> wpatch  : array<f32, 1681>;
var<workgroup> wsmooth : array<f32, 1681>;
var<workgroup> hist    : array<f32, 36>;
var<workgroup> histA : array<atomic<i32>, 36>;  // 定点原子黑板
var<workgroup> maxg2_bits : atomic<u32>;        // 预扫 max(|grad|^2) f32 bits
var<workgroup> A_ud    : array<f32, 4>;         // U*D (col-major) for the warp
var<workgroup> A_aff   : array<f32, 4>;         // affine ellipse (col-major), for output rotation
var<workgroup> T_sh    : array<f32, 2>;
var<workgroup> sc      : array<f32, 4>;         // theta0, d1, d2, (spare)
var<workgroup> tapsx   : array<f32, 16>;        // imsmooth x taps (<=15)
var<workgroup> tapsy   : array<f32, 16>;
var<workgroup> tapn    : array<u32, 2>;         // taps count x,y (radius*2+1)

// ── 2x2 SVD (identical to sift_affine_shape.wgsl) ──
fn fsign(x : f32) -> f32 { if (x < 0.0) { return -1.0; } return 1.0; }
struct Dlasv2 { smin:f32, smax:f32, sv:f32, cv:f32, su:f32, cu:f32 };
fn dlasv2(f : f32, g : f32, h : f32) -> Dlasv2 {
  var o : Dlasv2;
  var ft = f; var gt = g; var ht = h;
  var fa = abs(f); var ga = abs(g); var ha = abs(h);
  var pmax : i32 = 1; var swap : i32 = 0; var glarge : i32 = 0;
  var svt : f32 = 0.0; var cvt : f32 = 1.0; var sut : f32 = 0.0; var cut : f32 = 1.0;
  var smin : f32 = 0.0; var smax : f32 = 0.0;
  if (fa < ha) { pmax = 3; let t1=ft; ft=ht; ht=t1; let t2=fa; fa=ha; ha=t2; swap=1; }
  if (ga == 0.0) { smin=ha; smax=fa; cut=1.0; sut=0.0; cvt=1.0; svt=0.0; }
  else {
    if (ga > fa) {
      pmax = 2;
      if ((fa / ga) < 2.2204460492503131e-16) {
        glarge = 1; smax = ga;
        if (ha > 1.0) { smin = fa / (ga / ha); } else { smin = (fa / ga) * ha; }
        cut=1.0; sut=ht/gt; cvt=1.0; svt=ft/gt;
      }
    }
    if (glarge == 0) {
      var d : f32; let fmh = fa - ha;
      if (fmh == fa) { d = 1.0; } else { d = fmh / fa; }
      let q = gt/ft; let s = 2.0 - d;
      let dd = d*d; let qq = q*q; let ss = s*s;
      let spq = sqrt(ss + qq);
      var dpq : f32; if (d == 0.0) { dpq = abs(q); } else { dpq = sqrt(dd + qq); }
      let a = 0.5 * (spq + dpq);
      smin = ha / a; smax = fa * a;
      var tmp : f32;
      if (qq == 0.0) {
        if (d == 0.0) { tmp = fsign(ft) * 2.0 * fsign(gt); }
        else { tmp = gt / (fsign(ft) * fmh) + q / s; }
      } else { tmp = (q/(spq+s) + q/(dpq+d)) * (1.0 + a); }
      let tt = sqrt(tmp*tmp + 4.0);
      cvt = 2.0/tt; svt = tmp/tt; cut = (cvt + svt*q)/a; sut = (ht/ft)*svt/a;
    }
  }
  if (swap == 1) { o.cu=svt; o.su=cvt; o.cv=sut; o.sv=cut; }
  else { o.cu=cut; o.su=sut; o.cv=cvt; o.sv=svt; }
  var tsign : f32 = 1.0;
  if (pmax==1) { tsign = fsign(o.cv)*fsign(o.cu)*fsign(f); }
  if (pmax==2) { tsign = fsign(o.sv)*fsign(o.cu)*fsign(g); }
  if (pmax==3) { tsign = fsign(o.sv)*fsign(o.su)*fsign(h); }
  o.smax = tsign*smax; o.smin = (tsign*fsign(f)*fsign(h))*smin;
  return o;
}
struct Svd2 { s0:f32, s3:f32, u0:f32, u1:f32, u2:f32, u3:f32, v0:f32, v1:f32, v2:f32, v3:f32 };
fn svd2(m11:f32, m21:f32, m12:f32, m22:f32) -> Svd2 {
  var r : Svd2;
  var cu1 = m11; var su1 = m21;
  let norm = sqrt(cu1*cu1 + su1*su1);
  cu1 = cu1/norm; su1 = su1/norm;
  let f = cu1*m11 + su1*m21; let g = cu1*m12 + su1*m22; let h = -su1*m12 + cu1*m22;
  let d = dlasv2(f, g, h);
  r.s0=d.smax; r.s3=d.smin;
  r.u0=d.cu*cu1 - d.su*su1; r.u1=d.su*cu1 + d.cu*su1;
  r.u2=-d.cu*su1 - d.su*cu1; r.u3=-d.su*su1 + d.cu*cu1;
  r.v0=d.cv; r.v1=d.sv; r.v2=-d.sv; r.v3=d.cv;
  return r;
}

fn level_at(li : u32, x : i32, y : i32) -> f32 {
  let m = level_meta[li];
  let w = i32(m.width); let h = i32(m.height);
  let cx = max(0, min(x, w - 1)); let cy = max(0, min(y, h - 1));
  return packed_gss[m.offset + u32(cy * w + cx)];
}
struct LevelPick { li : u32, step : f32, sigma1 : f32, sigma2 : f32 };
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
  o = min(o, P.last_octave); o = max(o, P.first_octave);
  var s = i32(floor(lg2 - f32(o)));
  s = max(s, P.oct_first_sub); s = min(s, P.oct_last_sub);
  let sigma_ = P.base_scale * exp2(f32(o) + f32(s) / f32(P.oct_res));
  r.li = u32(o) * P.levels_per_oct + u32(s - P.oct_first_sub);
  r.step = exp2(f32(o));
  r.sigma1 = sigma_ / d1;
  r.sigma2 = sigma_ / d2;
  return r;
}

// _vl_new_gaussian_fitler_f (imopv.c): width=ceil(sigma*3), exp(-0.5(i/sigma)^2),
// L1-normalized. Writes taps into `dst`, returns radius (count = 2*radius+1).
fn build_taps(sigma : f32, dst : ptr<workgroup, array<f32,16>>) -> u32 {
  if (sigma <= 1e-6) { (*dst)[0] = 1.0; return 0u; }
  let width = i32(ceil(sigma * 3.0));
  let r = min(width, 7);  // clamp to taps capacity (radius<=7 → 15 taps)
  var mass : f32 = 1.0;
  (*dst)[u32(r)] = 1.0;
  for (var i = 1; i <= r; i = i + 1) {
    let x = f32(i) / sigma;
    let g = exp(-0.5 * x * x);
    mass = mass + g + g;
    (*dst)[u32(r - i)] = g;
    (*dst)[u32(r + i)] = g;
  }
  let len = 2 * r + 1;
  for (var i = 0; i < len; i = i + 1) { (*dst)[u32(i)] = (*dst)[u32(i)] / mass; }
  return u32(r);
}

@compute @workgroup_size(384, 1, 1)
fn main(@builtin(workgroup_id) wid : vec3<u32>,
        @builtin(local_invocation_id) lid : vec3<u32>) {
  // [2D-DISPATCH 2026-08-10] n_kept 可超 WebGPU 单维派发上限 65535
  // (128k 检测上限后高频纹理实测 80,904)——host 侧按 (min(n,65535),
  //  ceil(n/65535)) 派发,这里重组线性索引;n<=65535 时 y 恒 0,逐位同旧。
  let kp = wid.y * 65535u + wid.x;
  let lane = lid.x;
  if (kp >= P.count) { return; }

  let base = kp * KP_STRIDE;
  let fx = bitcast<f32>(kp_in[base + 0u]);
  let fy = bitcast<f32>(kp_in[base + 1u]);
  // affine ellipse stored as a11,a12,a21,a22 in slots [2..5] for the oriented set
  // (Stage D consumes the AFFINE output, not the isotropic detect output).
  let a11 = bitcast<f32>(kp_in[base + 2u]);
  let a12 = bitcast<f32>(kp_in[base + 3u]);
  let a21 = bitcast<f32>(kp_in[base + 4u]);
  let a22 = bitcast<f32>(kp_in[base + 5u]);
  let oct = bitcast<i32>(kp_in[base + 6u]);
  let sub = bitcast<i32>(kp_in[base + 7u]);

  if (lane == 0u) {
    // A col-major {a11,a21,a12,a22}.
    let sv = svd2(a11, a21, a12, a22);
    A_ud[0] = sv.u0 * sv.s0; A_ud[1] = sv.u1 * sv.s0;
    A_ud[2] = sv.u2 * sv.s3; A_ud[3] = sv.u3 * sv.s3;
    A_aff[0] = a11; A_aff[1] = a21; A_aff[2] = a12; A_aff[3] = a22;  // col-major
    T_sh[0] = fx; T_sh[1] = fy;
    sc[0] = atan2(sv.v1, sv.v0);  // theta0
    sc[1] = sv.s0; sc[2] = sv.s3;
  }
  workgroupBarrier();

  // ── pick level + warp 41x41 patch (A_ud / step, clamp-to-edge) ──
  let pk = pick_level(sc[1], sc[2]);
  let a0 = A_ud[0] / pk.step; let a1 = A_ud[1] / pk.step;
  let a2 = A_ud[2] / pk.step; let a3 = A_ud[3] / pk.step;
  let t0 = T_sh[0] / pk.step; let t1 = T_sh[1] / pk.step;
  let stephat = EXTENT / RES;
  for (var idx = lane; idx < NPIX; idx = idx + WG) {
    let yyi = i32(idx / SIDE); let xxi = i32(idx % SIDE);
    let yhat = -EXTENT + f32(yyi) * stephat;
    let xhat = -EXTENT + f32(xxi) * stephat;
    let rx = a2 * yhat + t0; let ry = a3 * yhat + t1;
    let x = a0 * xhat + rx; let y = a1 * xhat + ry;
    let xi = i32(floor(x)); let yi = i32(floor(y));
    let wx = x - f32(xi); let wy = y - f32(yi);
    let i00 = level_at(pk.li, xi, yi);     let i10 = level_at(pk.li, xi+1, yi);
    let i01 = level_at(pk.li, xi, yi+1);   let i11 = level_at(pk.li, xi+1, yi+1);
    wpatch[idx] = (1.0 - wy) * ((1.0 - wx) * i00 + wx * i10) +
                  wy * ((1.0 - wx) * i01 + wx * i11);
  }
  workgroupBarrier();

  // ── imsmooth: anisotropic separable gaussian (deltaSigma1/stephat in x,
  //    deltaSigma2/stephat in y). vl_imsmooth_f does v-pass (y) then x-pass. ──
  if (lane == 0u) {
    let ds1 = sqrt(max(SIGMA_D*SIGMA_D - pk.sigma1*pk.sigma1, 0.0)) / stephat;
    let ds2 = sqrt(max(SIGMA_D*SIGMA_D - pk.sigma2*pk.sigma2, 0.0)) / stephat;
    tapn[0] = build_taps(ds1, &tapsx);  // x sigma
    tapn[1] = build_taps(ds2, &tapsy);  // y sigma
  }
  workgroupBarrier();
  let rx_t = i32(tapn[0]);
  let ry_t = i32(tapn[1]);
  // v-pass (y): wpatch -> wsmooth, clamp-to-edge (VL_PAD_BY_CONTINUITY).
  for (var idx = lane; idx < NPIX; idx = idx + WG) {
    let yy = i32(idx / SIDE); let xx = i32(idx % SIDE);
    var acc : f32 = 0.0;
    for (var k = -ry_t; k <= ry_t; k = k + 1) {
      let sy = max(0, min(yy + k, i32(SIDE) - 1));
      acc = acc + tapsy[u32(k + ry_t)] * wpatch[u32(sy) * SIDE + u32(xx)];
    }
    wsmooth[idx] = acc;
  }
  workgroupBarrier();
  // x-pass: wsmooth -> wpatch.
  for (var idx = lane; idx < NPIX; idx = idx + WG) {
    let yy = i32(idx / SIDE); let xx = i32(idx % SIDE);
    var acc : f32 = 0.0;
    for (var k = -rx_t; k <= rx_t; k = k + 1) {
      let sx = max(0, min(xx + k, i32(SIDE) - 1));
      acc = acc + tapsx[u32(k + rx_t)] * wsmooth[u32(yy) * SIDE + u32(sx)];
    }
    wpatch[idx] = acc;
  }
  workgroupBarrier();

  // ── histogram: polar gradient + mask, linear-interp into 36 bins ──
  if (lane < NUM_BINS) { hist[lane] = 0.0; }
  workgroupBarrier();
  let binExtent = 2.0 * PI / f32(NUM_BINS);
  let step_mask = (2.0 * EXTENT) / f32(SIDE);
  // [ORIENT-ATOMIC] 预扫定曝光(梯度公式与下方 scatter 逐字符同)。
  if (lane == 0u) { atomicStore(&maxg2_bits, 0u); }
  for (var b = lane; b < NUM_BINS; b = b + WG) { atomicStore(&histA[b], 0); }
  workgroupBarrier();
  var g2max : f32 = 0.0;
  for (var idx = lane; idx < NPIX; idx = idx + WG) {
    let yy = i32(idx / SIDE); let xx = i32(idx % SIDE);
    let c = wpatch[idx];
    var gx : f32; var gy : f32;
    if (xx == 0) { gx = wpatch[idx + 1u] - c; }
    else if (xx == i32(SIDE) - 1) { gx = c - wpatch[idx - 1u]; }
    else { gx = 0.5 * (wpatch[idx + 1u] - wpatch[idx - 1u]); }
    if (yy == 0) { gy = wpatch[idx + SIDE] - c; }
    else if (yy == i32(SIDE) - 1) { gy = c - wpatch[idx - SIDE]; }
    else { gy = 0.5 * (wpatch[idx + SIDE] - wpatch[idx - SIDE]); }
    g2max = max(g2max, gx * gx + gy * gy);
  }
  atomicMax(&maxg2_bits, bitcast<u32>(g2max));
  workgroupBarrier();
  let Mmax = sqrt(bitcast<f32>(atomicLoad(&maxg2_bits)));
  var FXP : f32 = 0.0;
  if (Mmax > 0.0) { FXP = 1073741824.0 / (Mmax * 2048.0); }  // 2^30/(M*2048)

  for (var idx = lane; idx < NPIX; idx = idx + WG) {
    let yy = i32(idx / SIDE); let xx = i32(idx % SIDE);
    let c = wpatch[idx];
    var gx : f32; var gy : f32;
    if (xx == 0) { gx = wpatch[idx + 1u] - c; }
    else if (xx == i32(SIDE) - 1) { gx = c - wpatch[idx - 1u]; }
    else { gx = 0.5 * (wpatch[idx + 1u] - wpatch[idx - 1u]); }
    if (yy == 0) { gy = wpatch[idx + SIDE] - c; }
    else if (yy == i32(SIDE) - 1) { gy = c - wpatch[idx - SIDE]; }
    else { gy = 0.5 * (wpatch[idx + SIDE] - wpatch[idx - SIDE]); }
    let modulus = sqrt(gx * gx + gy * gy);
    var angle = atan2(gy, gx) + 2.0 * PI;
    // mod 2pi
    angle = angle - 2.0 * PI * floor(angle / (2.0 * PI));
    let mi = f32(xx - 20); let mj = f32(yy - 20);
    let dxm = mi * step_mask / INTEG_SIGMA; let dym = mj * step_mask / INTEG_SIGMA;
    let weight = exp(-0.5 * (dxm * dxm + dym * dym));
    let xb = angle / binExtent;
    let bin = i32(floor(xb));
    let w2 = xb - f32(bin); let w1 = 1.0 - w2;
    let b0 = u32((bin + i32(NUM_BINS)) % i32(NUM_BINS));
    let b1 = u32((bin + i32(NUM_BINS) + 1) % i32(NUM_BINS));
    atomicAdd(&histA[b0], i32(round(w1 * (modulus * weight) * FXP)));
    atomicAdd(&histA[b1], i32(round(w2 * (modulus * weight) * FXP)));
  }
  // 黑板读回(FXP==0=全平 patch ⇒ hist 全 0,与原路径同语义)。
  workgroupBarrier();
  if (FXP > 0.0) {
    for (var b = lane; b < NUM_BINS; b = b + WG) { hist[b] = f32(atomicLoad(&histA[b])) / FXP; }
  } else {
    for (var b = lane; b < NUM_BINS; b = b + WG) { hist[b] = 0.0; }
  }
  workgroupBarrier();

  // ── lane 0: smooth histogram (6x), find peaks, append oriented features ──
  if (lane == 0u) {
    // 6x circular box-blur (covdet.c:2797-2807).
    for (var iter = 0; iter < 6; iter = iter + 1) {
      var prev = hist[NUM_BINS - 1u];
      let first = hist[0];
      var i : u32 = 0u;
      loop {
        if (i >= NUM_BINS - 1u) { break; }
        let curr = (prev + hist[i] + hist[(i + 1u) % NUM_BINS]) / 3.0;
        prev = hist[i];
        hist[i] = curr;
        i = i + 1u;
      }
      hist[NUM_BINS - 1u] = (prev + hist[NUM_BINS - 1u] + first) / 3.0;
    }
    // max
    var maxPeak : f32 = 0.0;
    for (var i = 0u; i < NUM_BINS; i = i + 1u) { maxPeak = max(maxPeak, hist[i]); }
    let theta0 = sc[0];
    // collect up to MAX_ORI peaks (in scan order, like VLFeat before its sort).
    var oc : u32 = 0u;
    var oth : array<f32, 4>;
    var osc : array<f32, 4>;
    for (var i = 0u; i < NUM_BINS; i = i + 1u) {
      let h0 = hist[i];
      let hm = hist[(i + NUM_BINS - 1u) % NUM_BINS];
      let hp = hist[(i + 1u) % NUM_BINS];
      if (h0 > PEAK_REL * maxPeak && h0 > hm && h0 > hp) {
        let di = -0.5 * (hp - hm) / (hp + hm - 2.0 * h0);
        let th = binExtent * (f32(i) + di) + theta0;
        if (oc < MAX_ORI) { oth[oc] = th; osc[oc] = h0; oc = oc + 1u; }
      }
    }
    // sort by score desc (selection sort, <=4).
    for (var a = 0u; a < oc; a = a + 1u) {
      var bi = a;
      for (var b = a + 1u; b < oc; b = b + 1u) { if (osc[b] > osc[bi]) { bi = b; } }
      if (bi != a) { let ts = osc[a]; osc[a] = osc[bi]; osc[bi] = ts; let tt = oth[a]; oth[a] = oth[bi]; oth[bi] = tt; }
    }
    // append oriented features: rotate AFFINE ellipse by R(theta).
    // VLFeat A col-major {a11,a21,a12,a22} = {A_aff[0..3]}.
    let Aa0 = A_aff[0]; let Aa1 = A_aff[1]; let Aa2 = A_aff[2]; let Aa3 = A_aff[3];
    for (var j = 0u; j < oc; j = j + 1u) {
      let r1 = cos(oth[j]); let r2 = sin(oth[j]);
      let o11 =  Aa0 * r1 + Aa2 * r2;
      let o21 =  Aa1 * r1 + Aa3 * r2;
      let o12 = -Aa0 * r2 + Aa2 * r1;
      let o22 = -Aa1 * r2 + Aa3 * r1;
      let slot = atomicAdd(&out_counter, 1u);
      if (slot < CAP) {
        let ob = slot * OUT_STRIDE;
        kp_out[ob + 0u] = bitcast<u32>(fx);
        kp_out[ob + 1u] = bitcast<u32>(fy);
        kp_out[ob + 2u] = bitcast<u32>(o11);  // a11
        kp_out[ob + 3u] = bitcast<u32>(o12);  // a12
        kp_out[ob + 4u] = bitcast<u32>(o21);  // a21
        kp_out[ob + 5u] = bitcast<u32>(o22);  // a22
        kp_out[ob + 6u] = bitcast<u32>(oct);
        kp_out[ob + 7u] = bitcast<u32>(sub);
        // debug/parity sidecar: input frame index + raw orientation angle.
        dbg[slot * 2u + 0u] = f32(kp);
        dbg[slot * 2u + 1u] = oth[j];
      }
    }
  }
}
