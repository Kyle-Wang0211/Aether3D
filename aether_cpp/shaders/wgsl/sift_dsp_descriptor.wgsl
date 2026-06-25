// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// sift_dsp_descriptor.wgsl — GPU DSP (domain-size-pooling) SIFT descriptor.
// GPU DSP-SIFT port, Stage S3. Entry point: `descriptor`.
//
// Per oriented+affine keypoint:
//   for each of dsp_num_scales (=10) dsp_scales:
//     1. ELLIPSE-WARP a (2*resolution+1)^2 patch out of the gss via bilinear
//        resample (VLFeat covdet.c vl_covdet_extract_patch_helper:2362-2399).
//     2. POLAR GRADIENT of the patch (VLFeat imopv.c vl_imgradient_polar_f:875).
//     3. RAW SIFT DESCRIPTOR: 4x4 spatial x 8 orientation bins, trilinear
//        scatter + L2-norm + 0.2 clamp + L2-norm
//        (VLFeat sift.c vl_sift_calc_raw_descriptor:1754-1903, angle0=0).
//   AVERAGE the dsp_num_scales raw descriptors
//        (COLMAP sift.cc:426-433 / aether_threaded_extract.cc:289-293).
//   L1_ROOT (RootSIFT): d *= 1/sum(|d|); d = sqrt(d)
//        (colmap/feature/utils.cc:49-55, L1RootNormalizeFeatureDescriptors).
//   -> 128 uint8 via round(512*d) clamp [0,255]
//        (colmap/feature/utils.cc:57-69, FeatureDescriptorsToUnsignedByte).
//   -> UBC reorder of the 8 orientation bins q={0,7,6,5,4,3,2,1}
//        (sift.cc TransformVLFeatToUBCFeatureDescriptors /
//         aether_threaded_extract.cc:34-50).
//
// ── PARITY DISCIPLINE ───────────────────────────────────────────────────────
// All warp + gradient + descriptor accumulation is fp32 IN-REGISTER (PLAN
// "fp32 discipline"). The fast-math helpers are bit-replicated, NOT replaced
// by the WGSL builtins, because VLFeat uses them on the parity path and they
// are NOT IEEE-accurate:
//   * vl_fast_resqrt_f  (mathop.h:479-501) — Quake inverse-sqrt, magic
//     0x5f3759df + TWO Newton steps. Feeds vl_fast_sqrt_f.
//   * vl_fast_sqrt_f    (mathop.h:544-548) — x<1e-8 ? 0 : x*resqrt(x). Used in
//     the gradient magnitude (imopv SAVE_BACK:893) AND normalize_histogram
//     (sift.c:1712).
//   * vl_fast_atan2_f   (mathop.h:407-424) — c1/c3 polynomial atan2 approx.
//   * fast_expn         (sift.c:691-720) — 256-entry exp(-x) LUT + linear
//     interp over [0,EXPN_MAX=25]. The LUT is uploaded as a uniform-fed
//     storage buffer (host builds it with the same exp()).
//   * vl_mod_2pi_f      (mathop.h:110-115) — subtract/add loop, NOT fmod.
//
// The per-(keypoint x scale) AFFINE SVD + scale-space LEVEL SELECTION + patch
// PADDING geometry (covdet.c:2222-2360, fp64 on the CPU) are done HOST-SIDE and
// fed in as a PatchRec per (keypoint,scale): the warp matrix A/step, translate
// T/step, the chosen gss level byte-offset + dims. This is deliberate: S3's
// scope is the descriptor compute; S4 is where affine-shape moves to the GPU
// (PLAN risk #4 documents the fp64 SVD divergence that S3 must NOT inherit).
// The kernel reproduces the in-level bilinear warp + everything after it.

// ── Layout constants (VLFeat / COLMAP, all fixed) ──
const NBO : i32 = 8;          // orientation bins  (sift.c:675)
const NBP : i32 = 4;          // spatial bins/side (sift.c:676)
const DESC_LEN : i32 = 128;   // NBO*NBP*NBP
const PATCH_RES : i32 = 15;   // kPatchResolution (aether_threaded_extract.cc:225)
const PATCH_SIDE : i32 = 31;  // 2*PATCH_RES+1
const MAGNIF : f32 = 3.0;     // vl_sift_set_magnif(3.0) (extract:223; sift.c default)
const WINDOW_SIZE : f32 = 2.0;// f->windowSize = NBP/2 = 2 (sift.c:926)
const VL_PI : f32 = 3.141592653589793;
const VL_EPSILON_F : f32 = 1.19209290E-07;
const EXPN_SZ : f32 = 256.0;  // fast_expn LUT size (sift.c:671)
const EXPN_MAX : f32 = 25.0;  // fast_expn LUT max  (sift.c:672)
const MAX_DSP_SCALES : u32 = 16u;  // upper bound on dsp_num_scales

// Per (keypoint x scale) warp record — built host-side (the affine SVD + level
// pick + padding live on the CPU for S3; see header). std430, 12 f32 = 48 B.
//   A = [a0 a1 ; a2 a3] already divided by step (covdet.c:2259-2262);
//       column-major map patch->level (a0=A[0],a1=A[1],a2=A[2],a3=A[3]).
//   T = (tx,ty) already divided by step and shifted by the pad origin x0i/y0i
//       (covdet.c:2263-2264,2357-2358).
//   extent = kPatchRelativeExtent = 7.5; stephat = extent/PATCH_RES.
//   level_off = first float index of the chosen (possibly padded) level plane;
//   lw/lh = that plane's width/height; the level data is in `gss`.
struct PatchRec {
  a0 : f32, a1 : f32, a2 : f32, a3 : f32,
  tx : f32, ty : f32,
  extent : f32,
  stephat : f32,
  level_off : u32,
  lw : u32,
  lh : u32,
  pad0 : u32,
};

struct Params {
  num_kp : u32,
  dsp_num_scales : u32,   // 10 (or 1 when DSP off)
  patch_sigma : u32,      // unused placeholder (kept for 16B align); kSigma is a f32 below
  pad0 : u32,
  k_sigma : f32,          // kSigma fed to vl_sift_calc_raw_descriptor (extract:230-231)
  pad1 : f32, pad2 : f32, pad3 : f32,
};

@group(0) @binding(0) var<storage, read>       gss      : array<f32>; // all warp source levels, concatenated
@group(0) @binding(1) var<storage, read>       recs     : array<PatchRec>; // num_kp * dsp_num_scales
@group(0) @binding(2) var<storage, read>       expn_tab : array<f32>;  // 257 entries (fast_expn LUT)
@group(0) @binding(3) var<storage, read_write> out_desc : array<u32>;  // num_kp * 32 (128 uint8 packed 4/word)
@group(0) @binding(4) var<uniform>             P        : Params;
// Debug: post-L1Root/sqrt float descriptor in VLFeat (non-UBC) bin order
// [by][bx][bt]. 128 f32 per kp. Written unconditionally; harness may ignore.
@group(0) @binding(5) var<storage, read_write> dbg_desc : array<f32>;

// ── VLFeat fast-math, bit-replicated (see header) ──

fn vl_fast_resqrt_f(x : f32) -> f32 {
  // mathop.h:479-501. 32-bit Quake rsqrt: magic 0x5f3759df + two Newton steps.
  let xhalf : f32 = 0.5 * x;
  var i : i32 = bitcast<i32>(x);
  i = 0x5f3759df - (i >> 1u);
  var y : f32 = bitcast<f32>(i);
  y = y * (1.5 - xhalf * y * y);
  y = y * (1.5 - xhalf * y * y);
  return y;
}

fn vl_fast_sqrt_f(x : f32) -> f32 {
  // mathop.h:544-548.
  if (x < 1e-8) { return 0.0; }
  return x * vl_fast_resqrt_f(x);
}

fn vl_abs_f(x : f32) -> f32 { return abs(x); }

fn vl_fast_atan2_f(y : f32, x : f32) -> f32 {
  // mathop.h:407-424.
  let c3 : f32 = 0.1821;
  let c1 : f32 = 0.9675;
  let abs_y : f32 = vl_abs_f(y) + VL_EPSILON_F;
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

fn vl_mod_2pi_f(x_in : f32) -> f32 {
  // mathop.h:110-115. Loop subtract/add, NOT fmod (matches FP path exactly).
  var x : f32 = x_in;
  let two_pi : f32 = 2.0 * VL_PI;
  loop { if (x <= two_pi) { break; } x = x - two_pi; }
  loop { if (x >= 0.0) { break; } x = x + two_pi; }
  return x;
}

fn vl_floor_f(x : f32) -> f32 { return floor(x); }

fn fast_expn(x_in : f32) -> f32 {
  // sift.c:691-706. exp(-x) via 256-entry LUT (uploaded as expn_tab) + linear
  // interp. Argument expected in [0, EXPN_MAX].
  if (x_in > EXPN_MAX) { return 0.0; }
  let x : f32 = x_in * (EXPN_SZ / EXPN_MAX);
  let i : i32 = i32(floor(x));   // vl_floor_d
  let r : f32 = x - f32(i);
  let a : f32 = expn_tab[u32(i)];
  let b : f32 = expn_tab[u32(i) + 1u];
  return a + r * (b - a);
}

// ── Patch warp: bilinear resample of one (PATCH_SIDE x PATCH_SIDE) patch out of
//    the chosen gss level (covdet.c:2362-2399). Writes into the `patch` scratch.
//    `pt` indexes patch in row-major PATCH_SIDE stride (matches CPU `*pt++`).
// We keep the patch in a workgroup-private array (fp32 in-register / private).

// ── Polar gradient of the patch (imopv.c vl_imgradient_polar_f). The CPU lays
//    grad as interleaved [mod, angle] with x-stride 2, y-stride 2*w. We store
//    mod & angle in two private arrays indexed [y*PATCH_SIDE + x].

var<private> g_patch : array<f32, 961>;     // 31*31
var<private> g_mod : array<f32, 961>;
var<private> g_ang : array<f32, 961>;

fn build_patch(rec : PatchRec) {
  // covdet.c:2362-2399 resample loop. xhat/yhat march from -extent by stephat.
  let w : i32 = i32(rec.lw);
  let base : u32 = rec.level_off;
  var pt : i32 = 0;
  var yhat : f32 = -rec.extent;
  for (var yyi : i32 = 0; yyi < PATCH_SIDE; yyi = yyi + 1) {
    var xhat : f32 = -rec.extent;
    let rx : f32 = rec.a2 * yhat + rec.tx;
    let ry : f32 = rec.a3 * yhat + rec.ty;
    for (var xxi : i32 = 0; xxi < PATCH_SIDE; xxi = xxi + 1) {
      let x : f32 = rec.a0 * xhat + rx;
      let y : f32 = rec.a1 * xhat + ry;
      let xi : i32 = i32(floor(x));
      let yi : i32 = i32(floor(y));
      let i00 : f32 = gss[base + u32(yi * w + xi)];
      let i10 : f32 = gss[base + u32(yi * w + xi + 1)];
      let i01 : f32 = gss[base + u32((yi + 1) * w + xi)];
      let i11 : f32 = gss[base + u32((yi + 1) * w + xi + 1)];
      let wx : f32 = x - f32(xi);
      let wy : f32 = y - f32(yi);
      g_patch[pt] =
        (1.0 - wy) * ((1.0 - wx) * i00 + wx * i10) +
        wy * ((1.0 - wx) * i01 + wx * i11);
      pt = pt + 1;
      xhat = xhat + rec.stephat;
    }
    yhat = yhat + rec.stephat;
  }
}

fn build_gradient() {
  // vl_imgradient_polar_f (imopv.c:875-974). w==h==PATCH_SIDE, stride=PATCH_SIDE.
  // SAVE_BACK: mod = fast_sqrt(gx^2+gy^2); ang = mod_2pi(atan2(gy,gx)+2pi).
  let w : i32 = PATCH_SIDE;
  let h : i32 = PATCH_SIDE;
  for (var y : i32 = 0; y < h; y = y + 1) {
    for (var x : i32 = 0; x < w; x = x + 1) {
      let idx : i32 = y * w + x;
      var gx : f32;
      var gy : f32;
      // x derivative (central interior, forward/backward on borders)
      if (x == 0) {
        gx = g_patch[idx + 1] - g_patch[idx];
      } else if (x == w - 1) {
        gx = g_patch[idx] - g_patch[idx - 1];
      } else {
        gx = 0.5 * (g_patch[idx + 1] - g_patch[idx - 1]);
      }
      // y derivative
      if (y == 0) {
        gy = g_patch[idx + w] - g_patch[idx];
      } else if (y == h - 1) {
        gy = g_patch[idx] - g_patch[idx - w];
      } else {
        gy = 0.5 * (g_patch[idx + w] - g_patch[idx - w]);
      }
      g_mod[idx] = vl_fast_sqrt_f(gx * gx + gy * gy);
      g_ang[idx] = vl_mod_2pi_f(vl_fast_atan2_f(gy, gx) + 2.0 * VL_PI);
    }
  }
}

// One raw SIFT descriptor of the current g_mod/g_ang patch into `descr` (128).
// angle0 = 0 (the patch is already oriented). x=y=PATCH_RES (patch center,
// aether_threaded_extract.cc:283), sigma=k_sigma. sift.c:1754-1903.
fn calc_raw_descriptor(descr : ptr<function, array<f32, 128>>) {
  let w : i32 = PATCH_SIDE;
  let h : i32 = PATCH_SIDE;
  let x : f32 = f32(PATCH_RES);
  let y : f32 = f32(PATCH_RES);
  let sigma : f32 = P.k_sigma;
  let angle0 : f32 = 0.0;

  // Note: VLFeat uses VL_EPSILON_D (double eps) for SBP; in fp32 it is ~0.
  let SBP : f32 = MAGNIF * sigma;                          // + eps_d ~ 0
  let xi : i32 = i32(x + 0.5);
  let yi : i32 = i32(y + 0.5);
  let st0 : f32 = sin(angle0);                              // 0
  let ct0 : f32 = cos(angle0);                              // 1
  let Wb : i32 = i32(floor(sqrt(2.0) * SBP * f32(NBP + 1) / 2.0 + 0.5));

  // clear descriptor
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { (*descr)[b] = 0.0; }

  // bounds check (sift.c:1787-1791): xi<0||xi>=w||yi<0||yi>=h-1 -> return zeros
  if (xi < 0 || xi >= w || yi < 0 || yi >= h - 1) { return; }

  let nbp_half : i32 = NBP / 2;  // 2
  let wsigma : f32 = WINDOW_SIZE;

  // dyi/dxi range = intersection of [-W,W] and the image rect (sift.c:1809-1813).
  let dyi_lo : i32 = max(-Wb, -yi);
  let dyi_hi : i32 = min(Wb, h - yi - 1);
  let dxi_lo : i32 = max(-Wb, -xi);
  let dxi_hi : i32 = min(Wb, w - xi - 1);

  for (var dyi : i32 = dyi_lo; dyi <= dyi_hi; dyi = dyi + 1) {
    for (var dxi : i32 = dxi_lo; dxi <= dxi_hi; dxi = dxi + 1) {
      let sx : i32 = xi + dxi;
      let sy : i32 = yi + dyi;
      let gmag : f32 = g_mod[sy * w + sx];
      let angle : f32 = g_ang[sy * w + sx];
      let theta : f32 = vl_mod_2pi_f(angle - angle0);

      let dx : f32 = f32(xi + dxi) - x;
      let dy : f32 = f32(yi + dyi) - y;

      let nx : f32 = (ct0 * dx + st0 * dy) / SBP;
      let ny : f32 = (-st0 * dx + ct0 * dy) / SBP;
      let nt : f32 = f32(NBO) * theta / (2.0 * VL_PI);

      let win : f32 = fast_expn((nx * nx + ny * ny) / (2.0 * wsigma * wsigma));

      let binx : i32 = i32(vl_floor_f(nx - 0.5));
      let biny : i32 = i32(vl_floor_f(ny - 0.5));
      let bint : i32 = i32(vl_floor_f(nt));
      let rbinx : f32 = nx - (f32(binx) + 0.5);
      let rbiny : f32 = ny - (f32(biny) + 0.5);
      let rbint : f32 = nt - f32(bint);

      for (var dbinx : i32 = 0; dbinx < 2; dbinx = dbinx + 1) {
        for (var dbiny : i32 = 0; dbiny < 2; dbiny = dbiny + 1) {
          for (var dbint : i32 = 0; dbint < 2; dbint = dbint + 1) {
            if (binx + dbinx >= -nbp_half && binx + dbinx < nbp_half &&
                biny + dbiny >= -nbp_half && biny + dbiny < nbp_half) {
              let weight : f32 = win * gmag
                * vl_abs_f(1.0 - f32(dbinx) - rbinx)
                * vl_abs_f(1.0 - f32(dbiny) - rbiny)
                * vl_abs_f(1.0 - f32(dbint) - rbint);
              // atd(binx+dbinx, biny+dbiny, (bint+dbint)%NBO):
              //   dpt = descr + (NBP/2)*binyo + (NBP/2)*binxo, binyo=NBO*NBP,
              //   binxo=NBO, binto=1 (sift.c:1778-1803). The index below folds
              //   the dpt center offset in directly.
              let bx : i32 = binx + dbinx + nbp_half;     // 0..NBP-1
              let by : i32 = biny + dbiny + nbp_half;      // 0..NBP-1
              let bt : i32 = (bint + dbint) % NBO;          // 0..NBO-1 (>=0 here)
              let off : i32 = by * (NBO * NBP) + bx * NBO + bt;
              (*descr)[off] = (*descr)[off] + weight;
            }
          }
        }
      }
    }
  }

  // normalize_histogram (sift.c:1877): L2 with vl_fast_sqrt + VL_EPSILON_F.
  var norm : f32 = 0.0;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { norm = norm + (*descr)[b] * (*descr)[b]; }
  norm = vl_fast_sqrt_f(norm) + VL_EPSILON_F;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { (*descr)[b] = (*descr)[b] / norm; }

  // numSamples + norm_thresh gate: f->norm_thresh == 0 (default) so this branch
  // is FALSE -> always take the truncate path (sift.c:1889). We thus skip the
  // numSamples computation (it only matters when norm_thresh!=0).

  // truncate at 0.2 then re-normalize (sift.c:1894-1900).
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) {
    if ((*descr)[b] > 0.2) { (*descr)[b] = 0.2; }
  }
  norm = 0.0;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { norm = norm + (*descr)[b] * (*descr)[b]; }
  norm = vl_fast_sqrt_f(norm) + VL_EPSILON_F;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { (*descr)[b] = (*descr)[b] / norm; }
}

@compute @workgroup_size(64)
fn descriptor(@builtin(global_invocation_id) gid : vec3<u32>) {
  let kp : u32 = gid.x;
  if (kp >= P.num_kp) { return; }

  let nscales : u32 = P.dsp_num_scales;

  // Accumulate the per-scale raw descriptors, then average (DSP mean).
  var acc : array<f32, 128>;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { acc[b] = 0.0; }

  var scaled : array<f32, 128>;
  for (var s : u32 = 0u; s < nscales; s = s + 1u) {
    let rec : PatchRec = recs[kp * nscales + s];
    build_patch(rec);
    build_gradient();
    calc_raw_descriptor(&scaled);
    for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { acc[b] = acc[b] + scaled[b]; }
  }
  // colwise().mean() — divide by nscales (DSP) or by 1 (no DSP).
  let inv_n : f32 = 1.0 / f32(nscales);
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { acc[b] = acc[b] * inv_n; }

  // L1_ROOT (RootSIFT): d *= 1/sum(|d|); d = sqrt(d). (utils.cc:49-55)
  var l1 : f32 = 0.0;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { l1 = l1 + vl_abs_f(acc[b]); }
  let inv_l1 : f32 = 1.0 / l1;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) {
    let v : f32 = acc[b] * inv_l1;
    acc[b] = sqrt(v);
  }
  // debug dump (VLFeat bin order, pre-byte/pre-UBC)
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) {
    dbg_desc[kp * 128u + u32(b)] = acc[b];
  }

  // round(512*d) clamped [0,255] (utils.cc:57-69) THEN UBC reorder.
  // VLFeat bin order in acc[] is [by][bx][bt] with bt = 0..7. The UBC transform
  // (aether_threaded_extract.cc:34-50) maps source orientation k -> dest q[k]
  // within each spatial cell of 8 bins, where the cell index is
  // (j + 4*i) = bx + 4*by. So dest bin = 8*(bx + 4*by) + q[bt].
  // We pack 4 uint8 per output u32 word (little-endian byte order).
  let q = array<i32, 8>(0, 7, 6, 5, 4, 3, 2, 1);
  let word_base : u32 = kp * 32u;   // 128 bytes / 4 = 32 words
  // Build 128 dest bytes, then pack.
  var bytes : array<u32, 128>;
  for (var by : i32 = 0; by < NBP; by = by + 1) {
    for (var bx : i32 = 0; bx < NBP; bx = bx + 1) {
      for (var bt : i32 = 0; bt < NBO; bt = bt + 1) {
        let src_off : i32 = by * (NBO * NBP) + bx * NBO + bt;  // acc layout
        let cell : i32 = bx + 4 * by;
        let dst_off : i32 = 8 * cell + q[bt];                   // UBC dest
        let scaled_value : f32 = round(512.0 * acc[src_off]);
        var bv : f32 = scaled_value;
        if (bv < 0.0) { bv = 0.0; }
        if (bv > 255.0) { bv = 255.0; }
        bytes[dst_off] = u32(bv);
      }
    }
  }
  // pack 4 bytes/word, little-endian (byte0 in low bits).
  for (var word : u32 = 0u; word < 32u; word = word + 1u) {
    let b0 : u32 = bytes[word * 4u + 0u];
    let b1 : u32 = bytes[word * 4u + 1u];
    let b2 : u32 = bytes[word * 4u + 2u];
    let b3 : u32 = bytes[word * 4u + 3u];
    out_desc[word_base + word] = b0 | (b1 << 8u) | (b2 << 16u) | (b3 << 24u);
  }
}
