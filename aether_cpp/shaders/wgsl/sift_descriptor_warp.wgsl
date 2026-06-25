// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// sift_descriptor_warp.wgsl — GPU DSP-SIFT Stage S5b: ON-GPU descriptor
// WARP-SETUP. Moves the per-(keypoint x dsp-scale) affine-SVD + fp64 scale-space
// LEVEL PICK + variable-size patch PADDING (covdet.c:2222-2360 — until now the
// HOST fp64 `build_warp_setup` bottleneck in extract_fullgpu.cc) onto the GPU,
// reading the RESIDENT gss pyramid directly and emitting the SAME per-rec padded
// plane that the validated sift_dsp_descriptor.wgsl consumes — so the descriptor
// chain stays fully GPU + gss-resident THROUGH the descriptor.
//
// ── WHY (the bottleneck this removes) ──
//   extract_fullgpu.cc ran FULLY GPU + gss-resident through ORIENTATION, but the
//   descriptor warp-setup (~82k warps = N_kp x 10 dsp scales) was HOST-side fp64
//   + a host plane memcpy per warp → cumulative speedup stalled at ~1.1-1.5x.
//   This kernel produces the per-rec plane on the GPU FROM THE RESIDENT PYRAMID:
//   no host fp64 loop, no host memcpy, the resident gss never leaves the GPU.
//
// ── TWO ENTRY POINTS (count → host prefix-sum → fill), mirroring the
//    suppression kernel's GPU-count / host-scan / GPU-scatter pattern ──
//   warp_size : 1 invocation / (kp x scale) rec. Affine SVD (singular values) →
//               fp64-emulated-in-f32 level pick (o,s) → bbox → padded-plane dims
//               (lw,lh). Writes WarpGeom{A/step, T/step, x0i,y0i, level_base,
//               lw,lh, pad-segments} + plane float count (lw*lh) to plane_floats
//               (host prefix-sums it to per-rec plane offsets).
//   warp_fill : 1 WORKGROUP / rec. All 64 lanes cooperatively materialize the
//               (possibly padded) plane into out_planes reading the RESIDENT
//               pyramid, replicating covdet.c:2305-2358's 3-segment edge fill
//               EXACTLY (incl. the right-edge `-2` quirk). Emits the final
//               PatchRec (level_off = rec_offset[r], T shifted by -x0i/-y0i) so
//               the descriptor reads out_planes byte-identically to the host path.
//
// ── PARITY DISCIPLINE ──
//   The fp64 level-pick loop (covdet.c:2241-2257: vl_log2_d / pow on doubles) is
//   the PLAN risk-4 fp-sensitive piece. WGSL has no f64 → computed in f32 here.
//   floor(log2 ratio) is far from an integer boundary for almost all keypoints,
//   so an f32-vs-f64 flip needs the ratio within ~1e-6 of an integer — rare; the
//   harness MEASURES the level-pick agreement vs the host fp64 path and reports
//   flips honestly. The bbox / pad geometry + the edge replication are integer +
//   fp32-exact (no catastrophic cancellation) → bit-identical once the level
//   pick agrees. Singular values from the analytic 2x2 formula (mathematically
//   identical to VLFeat vl_svd2 / dlasv2 — smax/smin are unique).

// ── Layout constants (VLFeat / COLMAP, fixed) ──
const PATCH_RES : i32 = 15;          // kPatchResolution
const VL_INFINITY : f32 = 3.0e38;

// Resident pyramid per-octave geometry (matches the host OctGeomW upload).
struct OctGeomW {
  w : u32, h : u32, base : u32, pad : u32,
  step : f32, pad1 : f32, pad2 : f32, pad3 : f32,
};

// Per-rec INPUT: oriented+affine ellipse (a11..a22 ALREADY x dsp-scale on host —
// a trivial scalar; everything heavy stays here), in IMAGE coords.
struct WarpIn {
  x : f32, y : f32,
  a11 : f32, a12 : f32, a21 : f32, a22 : f32,
  pad0 : f32, pad1 : f32,
};

// Per-rec geometry from warp_size. 64 bytes.
struct WarpGeom {
  a0 : f32, a1 : f32, a2 : f32, a3 : f32,
  tx : f32, ty : f32,            // T already /step (NOT yet shifted by -x0i/-y0i)
  x0i : i32, y0i : i32,
  level_base : u32, lw : u32, lh : u32, oct_idx : u32,
  src_w : u32, src_h : u32,      // resident level dims (for the fill clamp/copy)
  status : u32, pad1 : u32,
};

// Final PatchRec — byte-identical to sift_dsp_descriptor.wgsl's PatchRec (48B).
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
  num_recs : u32,
  num_octaves : u32,
  first_octave : i32,
  last_octave : i32,
  first_sub : i32,
  last_sub : i32,
  octave_res : f32,
  base_scale : f32,
  extent : f32,             // kPatchRelativeExtent = 7.5
  stephat : f32,            // extent / PATCH_RES
  sigma : f32,              // kPatchRelativeSmoothing = 1.0 (the warp "sigma")
  pad0 : f32,
};

// ════════════════════════════════════════════════════════════════════════════
//  warp_size — geometry only (the build_warp_setup "setup" half), 1 inv / rec.
// ════════════════════════════════════════════════════════════════════════════
@group(0) @binding(0) var<storage, read>       w_in     : array<WarpIn>;
@group(0) @binding(1) var<storage, read>       octs     : array<OctGeomW>;
@group(0) @binding(2) var<storage, read_write> geom_out : array<WarpGeom>;
@group(0) @binding(3) var<storage, read_write> plane_floats : array<u32>;
@group(0) @binding(4) var<uniform>             SP       : Params;

// Analytic singular values of M = [[a,c],[b,d]] (column-major a11,a21,a12,a22).
// Returns (smax, smin). Mathematically identical to VLFeat vl_svd2's S[0]/S[3].
fn svd2_singular(a : f32, b : f32, c : f32, d : f32) -> vec2<f32> {
  let e : f32 = (a + d) * 0.5;
  let f : f32 = (a - d) * 0.5;
  let g : f32 = (b + c) * 0.5;
  let h : f32 = (b - c) * 0.5;
  let q : f32 = sqrt(e * e + h * h);
  let rr : f32 = sqrt(f * f + g * g);
  return vec2<f32>(q + rr, abs(q - rr));
}

@compute @workgroup_size(64)
fn warp_size(@builtin(global_invocation_id) gid : vec3<u32>) {
  let r : u32 = gid.x;
  if (r >= SP.num_recs) { return; }
  let wi : WarpIn = w_in[r];

  let a11 : f32 = wi.a11; let a21 : f32 = wi.a21;
  let a12 : f32 = wi.a12; let a22 : f32 = wi.a22;
  let sv : vec2<f32> = svd2_singular(a11, a21, a12, a22);
  let d1 : f32 = sv.x; let d2 : f32 = sv.y;
  let factor : f32 = 1.0 / min(d1, d2);

  // ── fp64 level pick (covdet.c:2241-2257), emulated in f32 (PLAN risk 4) ──
  let log_arg : f32 = log2(SP.sigma / (factor * SP.base_scale));
  var o : i32 = SP.first_octave;
  for (var oo : i32 = SP.first_octave + 1; oo <= SP.last_octave; oo = oo + 1) {
    var ss : i32 = i32(floor(log_arg - f32(oo)));
    ss = max(ss, SP.first_sub);
    ss = min(ss, SP.last_sub);
    let sigma_ : f32 = SP.base_scale * exp2(f32(oo) + f32(ss) / SP.octave_res);
    o = oo;
    if (factor * sigma_ > SP.sigma) { o = oo - 1; break; }
  }
  o = min(o, SP.last_octave);
  var s : i32 = i32(floor(log_arg - f32(o)));
  s = max(s, SP.first_sub);
  s = min(s, SP.last_sub);

  let oct_idx : u32 = u32(o - SP.first_octave);
  let oc : OctGeomW = octs[oct_idx];
  let step : f32 = oc.step;
  let inv_step : f32 = 1.0 / step;

  let A0 : f32 = a11 * inv_step; let A1 : f32 = a21 * inv_step;
  let A2 : f32 = a12 * inv_step; let A3 : f32 = a22 * inv_step;
  let T0 : f32 = wi.x * inv_step; let T1 : f32 = wi.y * inv_step;

  let ext : f32 = SP.extent;
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
  let w : i32 = i32(oc.w); let h : i32 = i32(oc.h);
  let patchWidth : i32 = x1i - x0i + 1;
  let patchHeight : i32 = y1i - y0i + 1;

  var gout : WarpGeom;
  gout.a0 = A0; gout.a1 = A1; gout.a2 = A2; gout.a3 = A3;
  gout.tx = T0; gout.ty = T1;
  gout.x0i = x0i; gout.y0i = y0i;
  gout.oct_idx = oct_idx;
  gout.level_base = oc.base + u32(s - SP.first_sub) * (oc.w * oc.h);
  gout.lw = u32(patchWidth);
  gout.lh = u32(patchHeight);
  gout.src_w = oc.w; gout.src_h = oc.h;
  gout.status = 0u; gout.pad1 = 0u;
  geom_out[r] = gout;
  plane_floats[r] = u32(patchWidth * patchHeight);
}

// ════════════════════════════════════════════════════════════════════════════
//  warp_fill — materialize each rec's (possibly padded) plane into out_planes
//  from the RESIDENT pyramid + emit the final PatchRec. 1 workgroup / rec.
// ════════════════════════════════════════════════════════════════════════════
@group(0) @binding(0) var<storage, read>       gss        : array<f32>;  // RESIDENT pyramid
@group(0) @binding(1) var<storage, read>       geom_in    : array<WarpGeom>;
@group(0) @binding(2) var<storage, read>       rec_offset : array<u32>;  // host prefix-sum
@group(0) @binding(3) var<storage, read_write> out_planes : array<f32>;
@group(0) @binding(4) var<storage, read_write> recs_out   : array<PatchRec>;
@group(0) @binding(5) var<uniform>             FP          : Params;

// WGSL/Dawn caps DispatchWorkgroups at 65535 per dimension. With ~82k recs we
// dispatch a CAPPED grid (<=65535 workgroups) and each workgroup strides over
// recs r = wg.x, wg.x+GRID, wg.x+2*GRID, ... (GRID passed via FP.pad0). This
// keeps the simple 1-workgroup-per-rec body while staying within the limit.
const WARP_FILL_GRID : u32 = 32768u;  // workgroups dispatched (host must match)

@compute @workgroup_size(64)
fn warp_fill(@builtin(workgroup_id) wg : vec3<u32>,
             @builtin(local_invocation_id) lid : vec3<u32>) {
  // stride over recs (the host dispatches WARP_FILL_GRID workgroups). All 64
  // lanes of a workgroup process the SAME rec each iteration → uniform control
  // flow; no workgroupBarrier is used (the up/down pad rows RE-RUN the 3-segment
  // band fill for their source row, so there is no read-after-write dependency).
  for (var r : u32 = wg.x; r < FP.num_recs; r = r + WARP_FILL_GRID) {
    fill_one(r, lid.x);
  }
}

// Fill ONE output row `out_y` of rec `r`'s plane by edge-replicating the source
// level row `src_y` with covdet.c:2324-2330's 3-segment left/central/right logic
// (incl. the right-edge `-2` quirk). Used for the central band AND the top/bottom
// pad rows (which use the clamped band-edge source row) → no inter-row dependency.
fn fill_band_row(r : u32, out_y : i32, src_y : i32) {
  let g : WarpGeom = geom_in[r];
  let w : i32 = i32(g.src_w);
  let lw : i32 = i32(g.lw);
  let padx0 : i32 = max(0, -g.x0i);
  let padx1 : i32 = max(0, (g.x0i + lw - 1) - (w - 1));
  let base : u32 = g.level_base;
  let dst_base : u32 = rec_offset[r];
  let src0 : u32 = base + u32(src_y * w + clamp(g.x0i, 0, w - 1));
  let drow : u32 = dst_base + u32(out_y * lw);
  var di : i32 = 0;
  for (var xi : i32 = g.x0i; xi < g.x0i + padx0; xi = xi + 1) {
    out_planes[drow + u32(di)] = gss[src0]; di = di + 1;
  }
  var sadv : i32 = 0;
  for (var xi : i32 = g.x0i + padx0; xi < g.x0i + lw - padx1 - 2; xi = xi + 1) {
    out_planes[drow + u32(di)] = gss[src0 + u32(sadv)]; di = di + 1; sadv = sadv + 1;
  }
  let last : f32 = gss[src0 + u32(max(sadv - 1, 0))];
  for (var xi : i32 = g.x0i + lw - padx1 - 2; xi < g.x0i + lw; xi = xi + 1) {
    out_planes[drow + u32(di)] = last; di = di + 1;
  }
}

fn fill_one(r : u32, lane : u32) {
  let g : WarpGeom = geom_in[r];

  let w : i32 = i32(g.src_w);
  let h : i32 = i32(g.src_h);
  let lw : i32 = i32(g.lw);
  let lh : i32 = i32(g.lh);
  let base : u32 = g.level_base;        // resident level origin
  let dst_base : u32 = rec_offset[r];   // this rec's plane in out_planes

  let oob : bool = (g.x0i < 0) || ((g.x0i + lw - 1) > w - 1) ||
                   (g.y0i < 0) || ((g.y0i + lh - 1) > h - 1);

  // Emit the final PatchRec (lane 0). The descriptor reads
  // out_planes[level_off + yi*lw + xi]; T is shifted by -x0i/-y0i so the patch
  // origin lands at (0,0) of the materialized plane (covdet.c:2357-2358 for OOB;
  // the non-pad branch shifts by the sub-plane origin identically).
  if (lane == 0u) {
    var pr : PatchRec;
    pr.a0 = g.a0; pr.a1 = g.a1; pr.a2 = g.a2; pr.a3 = g.a3;
    pr.tx = g.tx - f32(g.x0i);
    pr.ty = g.ty - f32(g.y0i);
    pr.extent = FP.extent;
    pr.stephat = FP.stephat;
    pr.level_off = dst_base;
    pr.lw = g.lw; pr.lh = g.lh; pr.pad0 = 0u;
    recs_out[r] = pr;
  }

  if (!oob) {
    // Non-pad branch (covdet.c:2362's `level + (y0i+yi)*width + x0i` sub-copy).
    for (var yy : i32 = i32(lane); yy < lh; yy = yy + 64) {
      let srow : u32 = base + u32((g.y0i + yy) * w + g.x0i);
      let drow : u32 = dst_base + u32(yy * lw);
      for (var xx : i32 = 0; xx < lw; xx = xx + 1) {
        out_planes[drow + u32(xx)] = gss[srow + u32(xx)];
      }
    }
    return;
  }

  // ── OOB padded fill: replicate covdet.c:2305-2358 EXACTLY (barrier-free) ──
  let pady0 : i32 = max(0, -g.y0i);
  let pady1 : i32 = max(0, (g.y0i + lh - 1) - (h - 1));
  if (pady0 < lh - pady1) {
    // Every output row yy maps to a source level row: central rows use g.y0i+yy;
    // the top pad rows (0..pady0-1) replicate band-top source row g.y0i+pady0;
    // the bottom pad rows replicate band-bottom source row g.y0i+(lh-pady1-1).
    // Each row is produced independently by fill_band_row → no barrier needed.
    for (var yy : i32 = i32(lane); yy < lh; yy = yy + 64) {
      var src_y : i32 = g.y0i + yy;
      if (yy < pady0) { src_y = g.y0i + pady0; }
      else if (yy >= lh - pady1) { src_y = g.y0i + (lh - pady1 - 1); }
      fill_band_row(r, yy, src_y);
    }
  } else {
    // degenerate (covdet.c:2342-2344): zero-fill.
    for (var yy : i32 = i32(lane); yy < lh; yy = yy + 64) {
      let dd : u32 = dst_base + u32(yy * lw);
      for (var xx : i32 = 0; xx < lw; xx = xx + 1) { out_planes[dd + u32(xx)] = 0.0; }
    }
  }
}
