// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// sift_descriptor_fused.wgsl — GPU DSP-SIFT FUSED warp-setup + descriptor.
// Entry point: `descriptor_fused`.
//
// ── WHAT THIS FUSES (and why) ────────────────────────────────────────────────
// The two-kernel descriptor chain was:
//   1. sift_descriptor_warp.wgsl (warp_size + warp_fill): per (kp x dsp-scale)
//      affine-SVD + fp64-emulated level pick + bbox + 3-segment edge-pad fill,
//      WRITING each padded plane into a ~3.4 GB global `out_planes` buffer.
//   2. sift_dsp_descriptor.wgsl (descriptor): READING those planes back,
//      bilinear-warping the 31x31 patch, polar gradient, raw SIFT, DSP mean,
//      RootSIFT, byte quantize, UBC reorder.
// The write-3.4GB + read-3.4GB round-trip is the measured bottleneck AND blows
// past Dawn's 2 GB buffer limit (forced batching). This kernel does the SAME
// math but materializes NO plane: for each (kp x scale) it computes the warp
// geometry IN-REGISTER, then build_patch samples the RESIDENT gss DIRECTLY,
// folding the 3-segment edge-replication into the per-pixel fetch
// (`sample_plane`). Everything after the patch fetch (gradient / raw descriptor /
// DSP mean / RootSIFT / UBC) is COPIED VERBATIM from sift_dsp_descriptor.wgsl —
// the descriptor math is byte-identical, only the patch SOURCE changed from a
// pre-filled plane to an on-the-fly edge-replicated read of the resident level.
//
// ── BYTE-IDENTITY ARGUMENT ───────────────────────────────────────────────────
//   * Level pick / SVD / bbox / x0i,y0i / lw,lh : VERBATIM from
//     sift_descriptor_warp.wgsl::warp_size (same f32 ops, same order) → the
//     SAME (a0..a3, tx, ty after the -x0i/-y0i shift, lw, lh, level_base).
//   * Patch pixel value at plane coord (px,py): `sample_plane(g, px, py)` returns
//     the EXACT float that warp_fill would have written into out_planes[px,py]
//     for that rec — the same `level[src_y*w + clamp(x0i,0,w-1) + sadv]` indices,
//     same 3-segment left/central/right split incl. the right-edge `-2` quirk,
//     same top/bottom pad-row clamp, same degenerate zero-fill. Proof is the
//     1:1 line correspondence to fill_band_row / build_warp_setup.
//   * build_patch bilinear math reads sample_plane(xi,yi),(xi+1,yi),(xi,yi+1),
//     (xi+1,yi+1) with the SAME wx/wy lerp as the unfused build_patch (which read
//     plane[yi*w+xi] etc.) — identical because sample_plane(px,py) == plane[py*w+px].
//   * gradient / calc_raw_descriptor / DSP mean / RootSIFT / quantize / UBC :
//     VERBATIM (line-for-line) from sift_dsp_descriptor.wgsl. Same fast-math
//     (Quake rsqrt, atan2 poly, fast_expn LUT, mod_2pi loop), same accumulation
//     order, same 0.2 clamp, same 512x round, same q[] UBC permute, same packing.
// → fused descriptor cosine vs unfused must be ~1.0 (bit-identical modulo the
//   GPU scheduler's freedom in fp; the op stream is the same).
//
// ── MEMORY ───────────────────────────────────────────────────────────────────
// No out_planes. The only big buffer is the RESIDENT gss (already resident from
// the gss-build kernels, shared with detect/refine/affine/orient). Per-thread
// patch is the SAME 3x961 f32 var<private> the descriptor already used. Scales
// are processed SEQUENTIALLY in-register (no per-(kp x scale) plane), so peak
// memory drops by the entire ~3.4 GB intermediate.

// ── Layout constants (VLFeat / COLMAP, all fixed) ──
const NBO : i32 = 8;          // orientation bins  (sift.c:675)
const NBP : i32 = 4;          // spatial bins/side (sift.c:676)
const DESC_LEN : i32 = 128;   // NBO*NBP*NBP
const PATCH_RES : i32 = 15;   // kPatchResolution
const PATCH_SIDE : i32 = 31;  // 2*PATCH_RES+1
const MAGNIF : f32 = 3.0;
const WINDOW_SIZE : f32 = 2.0;
const VL_PI : f32 = 3.141592653589793;
const VL_EPSILON_F : f32 = 1.19209290E-07;
const EXPN_SZ : f32 = 256.0;
const EXPN_MAX : f32 = 25.0;
const VL_INFINITY : f32 = 3.0e38;

// Resident pyramid per-octave geometry (matches sift_descriptor_warp.wgsl OctGeomW).
struct OctGeomW {
  w : u32, h : u32, base : u32, pad : u32,
  step : f32, pad1 : f32, pad2 : f32, pad3 : f32,
};

// Per (kp x scale) INPUT frame: oriented+affine ellipse with a11..a22 ALREADY
// x dsp-scale on host (a trivial scalar). IMAGE coords. Matches WarpIn (32B).
struct WarpIn {
  x : f32, y : f32,
  a11 : f32, a12 : f32, a21 : f32, a22 : f32,
  pad0 : f32, pad1 : f32,
};

// Per-rec warp geometry, computed in-register (NOT stored to global). Mirror of
// sift_descriptor_warp.wgsl WarpGeom's load-bearing fields. tx/ty here are the
// FINAL descriptor T (already shifted by -x0i/-y0i so the patch origin is (0,0)).
struct WarpGeom {
  a0 : f32, a1 : f32, a2 : f32, a3 : f32,
  tx : f32, ty : f32,             // FINAL T (shifted by -x0i/-y0i)
  x0i : i32, y0i : i32,
  level_base : u32, lw : i32, lh : i32,
  src_w : i32, src_h : i32,
  extent : f32, stephat : f32,
};

// Combined params: the warp-setup geometry params (sift_descriptor_warp.wgsl
// Params subset) + the descriptor params (sift_dsp_descriptor.wgsl Params subset).
struct Params {
  num_kp : u32,
  dsp_num_scales : u32,    // 10
  first_octave : i32,
  last_octave : i32,
  first_sub : i32,
  last_sub : i32,
  octave_res : f32,
  base_scale : f32,
  extent : f32,            // kPatchRelativeExtent = 7.5
  stephat : f32,           // extent / PATCH_RES
  sigma : f32,             // kPatchRelativeSmoothing = 1.0 (the warp "sigma")
  k_sigma : f32,           // kSigma fed to vl_sift_calc_raw_descriptor
};

@group(0) @binding(0) var<storage, read>       gss      : array<f32>;  // RESIDENT pyramid
@group(0) @binding(1) var<storage, read>       w_in     : array<WarpIn>; // num_kp * dsp_num_scales
@group(0) @binding(2) var<storage, read>       octs     : array<OctGeomW>;
@group(0) @binding(3) var<storage, read>       expn_tab : array<f32>;   // 257 entries
@group(0) @binding(4) var<storage, read_write> out_desc : array<u32>;   // num_kp * 32
@group(0) @binding(5) var<uniform>             P        : Params;
// Debug: post-L1Root/sqrt float descriptor (VLFeat bin order [by][bx][bt]).
@group(0) @binding(6) var<storage, read_write> dbg_desc : array<f32>;

// ════════════════════════════════════════════════════════════════════════════
//  VLFeat fast-math, bit-replicated — VERBATIM from sift_dsp_descriptor.wgsl.
// ════════════════════════════════════════════════════════════════════════════

fn vl_fast_resqrt_f(x : f32) -> f32 {
  let xhalf : f32 = 0.5 * x;
  var i : i32 = bitcast<i32>(x);
  i = 0x5f3759df - (i >> 1u);
  var y : f32 = bitcast<f32>(i);
  y = y * (1.5 - xhalf * y * y);
  y = y * (1.5 - xhalf * y * y);
  return y;
}

fn vl_fast_sqrt_f(x : f32) -> f32 {
  if (x < 1e-8) { return 0.0; }
  return x * vl_fast_resqrt_f(x);
}

fn vl_abs_f(x : f32) -> f32 { return abs(x); }

fn vl_fast_atan2_f(y : f32, x : f32) -> f32 {
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
  var x : f32 = x_in;
  let two_pi : f32 = 2.0 * VL_PI;
  loop { if (x <= two_pi) { break; } x = x - two_pi; }
  loop { if (x >= 0.0) { break; } x = x + two_pi; }
  return x;
}

fn vl_floor_f(x : f32) -> f32 { return floor(x); }

fn fast_expn(x_in : f32) -> f32 {
  if (x_in > EXPN_MAX) { return 0.0; }
  let x : f32 = x_in * (EXPN_SZ / EXPN_MAX);
  let i : i32 = i32(floor(x));
  let r : f32 = x - f32(i);
  let a : f32 = expn_tab[u32(i)];
  let b : f32 = expn_tab[u32(i) + 1u];
  return a + r * (b - a);
}

// ════════════════════════════════════════════════════════════════════════════
//  Warp-setup geometry — VERBATIM math from sift_descriptor_warp.wgsl::warp_size,
//  but the result is RETURNED in-register (NOT stored to a global geom buffer).
//  Also folds in the warp_fill PatchRec emission (the -x0i/-y0i T shift).
// ════════════════════════════════════════════════════════════════════════════

// Analytic singular values of M = [[a,c],[b,d]] (column-major a11,a21,a12,a22).
fn svd2_singular(a : f32, b : f32, c : f32, d : f32) -> vec2<f32> {
  let e : f32 = (a + d) * 0.5;
  let f : f32 = (a - d) * 0.5;
  let gg : f32 = (b + c) * 0.5;
  let hh : f32 = (b - c) * 0.5;
  let q : f32 = sqrt(e * e + hh * hh);
  let rr : f32 = sqrt(f * f + gg * gg);
  return vec2<f32>(q + rr, abs(q - rr));
}

fn compute_geom(wi : WarpIn) -> WarpGeom {
  let a11 : f32 = wi.a11; let a21 : f32 = wi.a21;
  let a12 : f32 = wi.a12; let a22 : f32 = wi.a22;
  let sv : vec2<f32> = svd2_singular(a11, a21, a12, a22);
  let d1 : f32 = sv.x; let d2 : f32 = sv.y;
  let factor : f32 = 1.0 / min(d1, d2);

  // ── fp64 level pick (covdet.c:2241-2257), emulated in f32 (PLAN risk 4) ──
  let log_arg : f32 = log2(P.sigma / (factor * P.base_scale));
  var o : i32 = P.first_octave;
  for (var oo : i32 = P.first_octave + 1; oo <= P.last_octave; oo = oo + 1) {
    var ss : i32 = i32(floor(log_arg - f32(oo)));
    ss = max(ss, P.first_sub);
    ss = min(ss, P.last_sub);
    let sigma_ : f32 = P.base_scale * exp2(f32(oo) + f32(ss) / P.octave_res);
    o = oo;
    if (factor * sigma_ > P.sigma) { o = oo - 1; break; }
  }
  o = min(o, P.last_octave);
  var s : i32 = i32(floor(log_arg - f32(o)));
  s = max(s, P.first_sub);
  s = min(s, P.last_sub);

  let oct_idx : u32 = u32(o - P.first_octave);
  let oc : OctGeomW = octs[oct_idx];
  let step : f32 = oc.step;
  let inv_step : f32 = 1.0 / step;

  let A0 : f32 = a11 * inv_step; let A1 : f32 = a21 * inv_step;
  let A2 : f32 = a12 * inv_step; let A3 : f32 = a22 * inv_step;
  let T0 : f32 = wi.x * inv_step; let T1 : f32 = wi.y * inv_step;

  let ext : f32 = P.extent;
  let boxx = array<f32, 4>(ext, ext, -ext, -ext);
  let boxy = array<f32, 4>(-ext, ext, ext, -ext);
  var x0 : f32 = VL_INFINITY; var x1 : f32 = -VL_INFINITY;
  var y0 : f32 = VL_INFINITY; var y1 : f32 = -VL_INFINITY;
  for (var i : i32 = 0; i < 4; i = i + 1) {
    let xx : f32 = A0 * boxx[i] + A2 * boxy[i] + T0;
    let yy : f32 = A1 * boxx[i] + A3 * boxy[i] + T1;
    x0 = min(x0, xx); x1 = max(x1, xx);
    y0 = min(y0, yy); y1 = max(y1, yy);
  }
  let x0i : i32 = i32(floor(x0)) - 1;
  let y0i : i32 = i32(floor(y0)) - 1;
  let x1i : i32 = i32(ceil(x1)) + 1;
  let y1i : i32 = i32(ceil(y1)) + 1;
  let patchWidth : i32 = x1i - x0i + 1;
  let patchHeight : i32 = y1i - y0i + 1;

  var g : WarpGeom;
  g.a0 = A0; g.a1 = A1; g.a2 = A2; g.a3 = A3;
  // FINAL descriptor T = (T/step) shifted by the pad origin (covdet.c:2357-2358 /
  // warp_fill PatchRec emission). Identical for OOB and non-OOB branches.
  g.tx = T0 - f32(x0i);
  g.ty = T1 - f32(y0i);
  g.x0i = x0i; g.y0i = y0i;
  g.level_base = oc.base + u32(s - P.first_sub) * (oc.w * oc.h);
  g.lw = patchWidth; g.lh = patchHeight;
  g.src_w = i32(oc.w); g.src_h = i32(oc.h);
  g.extent = P.extent; g.stephat = P.stephat;
  return g;
}

// ════════════════════════════════════════════════════════════════════════════
//  sample_plane(g, px, py): the float that warp_fill would have written into
//  out_planes at plane coordinate (px, py) for this rec — read straight from the
//  resident gss level with the 3-segment edge replication folded in. Returns the
//  SAME value as plane[py*lw + px] in the unfused path.
//
//  1:1 with build_warp_setup (parity_warp.cc:201-241) + fill_band_row
//  (sift_descriptor_warp.wgsl:223-245). px in [0,lw), py in [0,lh).
// ════════════════════════════════════════════════════════════════════════════
fn sample_plane(g : WarpGeom, px : i32, py : i32) -> f32 {
  let w : i32 = g.src_w;
  let h : i32 = g.src_h;
  let lw : i32 = g.lw;
  let lh : i32 = g.lh;
  let base : u32 = g.level_base;

  let oob : bool = (g.x0i < 0) || ((g.x0i + lw - 1) > w - 1) ||
                   (g.y0i < 0) || ((g.y0i + lh - 1) > h - 1);

  if (!oob) {
    // Non-pad sub-copy: plane[py*lw+px] = level[(y0i+py)*w + (x0i+px)].
    return gss[base + u32((g.y0i + py) * w + (g.x0i + px))];
  }

  // ── OOB padded fill ──
  let pady0 : i32 = max(0, -g.y0i);
  let pady1 : i32 = max(0, (g.y0i + lh - 1) - (h - 1));
  if (pady0 >= lh - pady1) {
    // degenerate (covdet.c:2342-2344 / warp_fill else-branch): zero-fill.
    return 0.0;
  }

  // Row clamp: central rows use g.y0i+py; top pad rows replicate band-top source
  // row g.y0i+pady0; bottom pad rows replicate band-bottom row g.y0i+(lh-pady1-1).
  var src_y : i32 = g.y0i + py;
  if (py < pady0) { src_y = g.y0i + pady0; }
  else if (py >= lh - pady1) { src_y = g.y0i + (lh - pady1 - 1); }

  // Within-row 3-segment fill (fill_band_row / build_warp_setup inner loop).
  let padx0 : i32 = max(0, -g.x0i);
  let padx1 : i32 = max(0, (g.x0i + lw - 1) - (w - 1));
  let src0 : u32 = base + u32(src_y * w + clamp(g.x0i, 0, w - 1));

  if (px < padx0) {
    // left pad: replicate src[0].
    return gss[src0];
  }
  if (px < lw - padx1 - 2) {
    // central: src[sadv], sadv = px - padx0.
    let sadv : i32 = px - padx0;
    return gss[src0 + u32(sadv)];
  }
  // right pad (incl. the right-edge `-2` quirk): last central value
  // src[max(count_central-1, 0)], count_central = (lw - padx1 - 2) - padx0.
  let count_central : i32 = (lw - padx1 - 2) - padx0;
  let last_idx : i32 = max(count_central - 1, 0);
  return gss[src0 + u32(last_idx)];
}

// ════════════════════════════════════════════════════════════════════════════
//  Patch / gradient / descriptor — VERBATIM from sift_dsp_descriptor.wgsl,
//  except build_patch reads sample_plane() instead of a materialized plane.
// ════════════════════════════════════════════════════════════════════════════

var<private> g_patch : array<f32, 961>;     // 31*31
var<private> g_mod : array<f32, 961>;
var<private> g_ang : array<f32, 961>;

fn build_patch(g : WarpGeom) {
  // covdet.c:2362-2399 resample loop, identical to sift_dsp_descriptor.wgsl
  // build_patch but the four bilinear taps come from sample_plane(px,py) instead
  // of plane[py*lw+px] — the values are equal by sample_plane's construction.
  var pt : i32 = 0;
  var yhat : f32 = -g.extent;
  for (var yyi : i32 = 0; yyi < PATCH_SIDE; yyi = yyi + 1) {
    var xhat : f32 = -g.extent;
    let rx : f32 = g.a2 * yhat + g.tx;
    let ry : f32 = g.a3 * yhat + g.ty;
    for (var xxi : i32 = 0; xxi < PATCH_SIDE; xxi = xxi + 1) {
      let x : f32 = g.a0 * xhat + rx;
      let y : f32 = g.a1 * xhat + ry;
      let xi : i32 = i32(floor(x));
      let yi : i32 = i32(floor(y));
      let i00 : f32 = sample_plane(g, xi,     yi);
      let i10 : f32 = sample_plane(g, xi + 1, yi);
      let i01 : f32 = sample_plane(g, xi,     yi + 1);
      let i11 : f32 = sample_plane(g, xi + 1, yi + 1);
      let wx : f32 = x - f32(xi);
      let wy : f32 = y - f32(yi);
      g_patch[pt] =
        (1.0 - wy) * ((1.0 - wx) * i00 + wx * i10) +
        wy * ((1.0 - wx) * i01 + wx * i11);
      pt = pt + 1;
      xhat = xhat + g.stephat;
    }
    yhat = yhat + g.stephat;
  }
}

fn build_gradient() {
  let w : i32 = PATCH_SIDE;
  let h : i32 = PATCH_SIDE;
  for (var y : i32 = 0; y < h; y = y + 1) {
    for (var x : i32 = 0; x < w; x = x + 1) {
      let idx : i32 = y * w + x;
      var gx : f32;
      var gy : f32;
      if (x == 0) {
        gx = g_patch[idx + 1] - g_patch[idx];
      } else if (x == w - 1) {
        gx = g_patch[idx] - g_patch[idx - 1];
      } else {
        gx = 0.5 * (g_patch[idx + 1] - g_patch[idx - 1]);
      }
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

fn calc_raw_descriptor(descr : ptr<function, array<f32, 128>>) {
  let w : i32 = PATCH_SIDE;
  let h : i32 = PATCH_SIDE;
  let x : f32 = f32(PATCH_RES);
  let y : f32 = f32(PATCH_RES);
  let sigma : f32 = P.k_sigma;
  let angle0 : f32 = 0.0;

  let SBP : f32 = MAGNIF * sigma;
  let xi : i32 = i32(x + 0.5);
  let yi : i32 = i32(y + 0.5);
  let st0 : f32 = sin(angle0);
  let ct0 : f32 = cos(angle0);
  let Wb : i32 = i32(floor(sqrt(2.0) * SBP * f32(NBP + 1) / 2.0 + 0.5));

  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { (*descr)[b] = 0.0; }

  if (xi < 0 || xi >= w || yi < 0 || yi >= h - 1) { return; }

  let nbp_half : i32 = NBP / 2;
  let wsigma : f32 = WINDOW_SIZE;

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
              let bx : i32 = binx + dbinx + nbp_half;
              let by : i32 = biny + dbiny + nbp_half;
              let bt : i32 = (bint + dbint) % NBO;
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
fn descriptor_fused(@builtin(global_invocation_id) gid : vec3<u32>) {
  let kp : u32 = gid.x;
  if (kp >= P.num_kp) { return; }

  let nscales : u32 = P.dsp_num_scales;

  // Accumulate the per-scale raw descriptors, then average (DSP mean). Scales are
  // processed SEQUENTIALLY in-register (no per-scale plane buffer materialized).
  var acc : array<f32, 128>;
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { acc[b] = 0.0; }

  var scaled : array<f32, 128>;
  for (var sc : u32 = 0u; sc < nscales; sc = sc + 1u) {
    let wi : WarpIn = w_in[kp * nscales + sc];
    let g : WarpGeom = compute_geom(wi);   // FUSED warp-setup (in-register)
    build_patch(g);                         // sample resident gss directly
    build_gradient();
    calc_raw_descriptor(&scaled);
    for (var b : i32 = 0; b < DESC_LEN; b = b + 1) { acc[b] = acc[b] + scaled[b]; }
  }
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
  for (var b : i32 = 0; b < DESC_LEN; b = b + 1) {
    dbg_desc[kp * 128u + u32(b)] = acc[b];
  }

  // round(512*d) clamped [0,255] (utils.cc:57-69) THEN UBC reorder.
  let q = array<i32, 8>(0, 7, 6, 5, 4, 3, 2, 1);
  let word_base : u32 = kp * 32u;
  var bytes : array<u32, 128>;
  for (var by : i32 = 0; by < NBP; by = by + 1) {
    for (var bx : i32 = 0; bx < NBP; bx = bx + 1) {
      for (var bt : i32 = 0; bt < NBO; bt = bt + 1) {
        let src_off : i32 = by * (NBO * NBP) + bx * NBO + bt;
        let cell : i32 = bx + 4 * by;
        let dst_off : i32 = 8 * cell + q[bt];
        let scaled_value : f32 = round(512.0 * acc[src_off]);
        var bv : f32 = scaled_value;
        if (bv < 0.0) { bv = 0.0; }
        if (bv > 255.0) { bv = 255.0; }
        bytes[dst_off] = u32(bv);
      }
    }
  }
  for (var word : u32 = 0u; word < 32u; word = word + 1u) {
    let b0 : u32 = bytes[word * 4u + 0u];
    let b1 : u32 = bytes[word * 4u + 1u];
    let b2 : u32 = bytes[word * 4u + 2u];
    let b3 : u32 = bytes[word * 4u + 3u];
    out_desc[word_base + word] = b0 | (b1 << 8u) | (b2 << 16u) | (b3 << 24u);
  }
}
