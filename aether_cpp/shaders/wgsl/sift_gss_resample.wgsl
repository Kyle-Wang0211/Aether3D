// sift_gss_resample.wgsl — VLFeat scale-space 2x resampling (down / up) for the
// GPU DSP-SIFT scale-space build.
//
// GPU DSP-SIFT Stage 1 (see glomap_vendor/GPU_DSP_SIFT_PLAN.md). These kernels
// realize the octave-transition resampling of VLFeat's Gaussian scale space:
//   - DOWNSAMPLE: octave o-1 -> octave o (the first_octave=0 production path).
//   - UPSAMPLE:   octave 0 -> octave -1 (only used when first_octave=-1; the
//                 plan adopted fo0 so this is for completeness/parity, NOT on
//                 the critical path — 2026-06-25 week-1 Gate 1 PASS).
//
// CPU reference replicated EXACTLY (byte-for-byte sampling, modulo GPU FP):
//   third_party/glomap_vendor/colmap-src/thirdparty/VLFeat/scalespace.c
//   - copy_and_downsample   (lines 497-520)
//   - copy_and_upsample     (lines 450-480)
//   driven by _vl_scalespace_start_octave_from_previous_octave (line 782,
//   numOctaves=1 => step=2) and _vl_scalespace_start_octave_from_image
//   (line 719/725, the upsample loop for first_octave<0).
//
// ─── DOWNSAMPLE mapping (copy_and_downsample, step = 1<<numOctaves) ───────────
//   VLFeat octave transitions ALWAYS call with numOctaves=1 => step=2. The CPU
//   loop is:
//     for (y = 0; y < height;        y += step)            // y = 0,2,4,...
//       for (x = 0; x < width-(step-1); x += step)         // x = 0,2,4,... < width-1
//         *dst++ = source[y*width + x];                    // top-left of 2x2 block
//   So output pixel (ox,oy) == source pixel (step*ox, step*oy) — pure decimation,
//   origin 0, NO averaging, NO interpolation. Output dims are
//     dwidth  = floor(width  / step)   (== width  >> numOctaves, the geometry's
//     dheight = floor(height / step)    VL_SHIFT_LEFT(.,-o) for one octave step).
//   Verified: for width W, the count of valid x (x<W-1, x%2==0) == floor(W/2)
//   for both even and odd W (W=2376->1188, 4224->2112, 2049->1024, ...). Because
//   the loop bound guarantees step*ox <= width-2 and step*oy <= height-1, the
//   read is always in bounds: downsample needs NO edge clamp (it cannot over-read
//   a valid (dwidth,dheight) output). We still clamp defensively (a no-op here)
//   to stay robust to any host dim rounding.
//
// ─── UPSAMPLE mapping (copy_and_upsample, linear interp + edge continuity) ────
//   Output is exactly (2*width) x (2*height). For each SOURCE pixel (x,y) the CPU
//   writes a 2x2 output block at (2x,2y):
//     ox = (x < width-1)  ? 1     : 0      // right neighbor, replicate at last col
//     oy = (y < height-1) ? width : 0      // below neighbor, replicate at last row
//     v00 = src[y,   x   ]
//     v10 = src[y,   x+ox]
//     v01 = src[y+oy/width, x]             (oy is a row offset in elements)
//     v11 = src[y+oy/width, x+ox]
//     dst[2y  , 2x  ] = v00
//     dst[2y  , 2x+1] = 0.5  * (v00 + v10)
//     dst[2y+1, 2x  ] = 0.5  * (v00 + v01)
//     dst[2y+1, 2x+1] = 0.25 * (v00 + v01 + v10 + v11)
//   i.e. bilinear up-2x with VL_PAD_BY_CONTINUITY (clamp-to-edge) on the right /
//   bottom borders (ox/oy collapse to 0 -> the edge pixel is replicated, so the
//   "neighbor" equals the pixel itself there). We dispatch one invocation per
//   SOURCE pixel (matching the CPU loop nest) and write its 4 outputs, so the
//   averaging weights and clamp behaviour are bit-for-bit the CPU's (modulo GPU
//   fp32 rounding). Output stride = 2*width (= P.dst_width passed by the host).
//
// ─── fp32 discipline (PLAN "fp32 in-register, fp16 storage") ──────────────────
//   Downsample is a pure copy (no arithmetic) so storage precision is the only
//   precision. Upsample averages near values; the PLAN mandates the math run in
//   fp32 in-register, with fp16 only as the STORAGE format. This file matches the
//   sift_gss_blur.wgsl convention: it stores f32 for the first parity pass (the
//   blur kernel does the same, with the explicit note that fp16-store is the
//   memory optimization layered on AFTER gss parity holds, max-rel <= 1e-3). The
//   averaging temporaries (v00..v11, the 0.5/0.25 combinations) are f32
//   in-register regardless, so flipping `src`/`dst` to a packed-f16 storage view
//   later (per the PLAN's 161 MB gss) changes ONLY load/store, never the math —
//   exactly the fp16-store / fp32-accumulate contract.
//
// NOT YET PARITY-VALIDATED — Stage-1 starting kernel; gss parity (max-rel<=1e-3,
// RMS<=2e-4) is week-1 work via bench/extract_gpuparity.cc (task ③).

// ───────────────────────── DOWNSAMPLE (priority path) ───────────────────────

struct DownParams {
  src_width  : u32,   // input octave width  (the larger image)
  src_height : u32,   // input octave height
  dst_width  : u32,   // output width  == src_width  >> 1 (floor)
  dst_height : u32,   // output height == src_height >> 1 (floor)
};

@group(0) @binding(0) var<storage, read>       d_src : array<f32>;
@group(0) @binding(1) var<storage, read_write> d_dst : array<f32>;
@group(0) @binding(2) var<uniform>             DP    : DownParams;

fn clampi(v : i32, lo : i32, hi : i32) -> i32 {
  return max(lo, min(v, hi));
}

// One invocation per OUTPUT pixel. Output (ox,oy) <- source (2*ox, 2*oy).
// Matches VLFeat copy_and_downsample with step=2 (numOctaves=1): top-left of
// each 2x2 block, origin 0, no averaging.
@compute @workgroup_size(8, 8, 1)
fn downsample(@builtin(global_invocation_id) gid : vec3<u32>) {
  let ox : u32 = gid.x;
  let oy : u32 = gid.y;
  if (ox >= DP.dst_width || oy >= DP.dst_height) { return; }

  // step = 2 (the only step VLFeat uses for octave transitions).
  let sx : i32 = clampi(i32(ox) * 2, 0, i32(DP.src_width)  - 1);
  let sy : i32 = clampi(i32(oy) * 2, 0, i32(DP.src_height) - 1);

  let v : f32 = d_src[sy * i32(DP.src_width) + sx];   // f32 storage, f32 value
  d_dst[oy * DP.dst_width + ox] = v;
}

// ───────────────────────── UPSAMPLE (completeness path) ─────────────────────

struct UpParams {
  src_width  : u32,   // input octave width
  src_height : u32,   // input octave height
  dst_width  : u32,   // output width  == 2 * src_width
  dst_height : u32,   // output height == 2 * src_height
};

@group(0) @binding(0) var<storage, read>       u_src : array<f32>;
@group(0) @binding(1) var<storage, read_write> u_dst : array<f32>;
@group(0) @binding(2) var<uniform>             UP    : UpParams;

// One invocation per SOURCE pixel (matches the CPU loop nest exactly). Each
// source pixel (x,y) produces the 2x2 output block anchored at (2x,2y).
// Matches VLFeat copy_and_upsample: linear interpolation with VL_PAD_BY_
// CONTINUITY (right/bottom neighbors clamp to the edge pixel).
@compute @workgroup_size(8, 8, 1)
fn upsample(@builtin(global_invocation_id) gid : vec3<u32>) {
  let x : u32 = gid.x;
  let y : u32 = gid.y;
  if (x >= UP.src_width || y >= UP.src_height) { return; }

  let w  : i32 = i32(UP.src_width);
  let xi : i32 = i32(x);
  let yi : i32 = i32(y);

  // VLFeat: ox = (x < width-1), oy = (y < height-1)*width. Replicate the edge
  // pixel at the last column / row (clamp-to-edge). Implemented as clamped index.
  let xr : i32 = clampi(xi + 1, 0, w - 1);                 // x + ox
  let yb : i32 = clampi(yi + 1, 0, i32(UP.src_height) - 1); // y + oy

  // Loads are f32 storage -> f32 in-register; all averaging is f32.
  let v00 : f32 = u_src[yi * w + xi];
  let v10 : f32 = u_src[yi * w + xr];
  let v01 : f32 = u_src[yb * w + xi];
  let v11 : f32 = u_src[yb * w + xr];

  // Output block anchored at (2x, 2y); output stride = UP.dst_width (= 2*src_w).
  let dw  : i32 = i32(UP.dst_width);
  let dx  : i32 = xi * 2;
  let dy  : i32 = yi * 2;
  let base: i32 = dy * dw + dx;

  d_store(base,          v00);                          // dst[2y  , 2x  ]
  d_store(base + 1,      0.5  * (v00 + v10));           // dst[2y  , 2x+1]
  d_store(base + dw,     0.5  * (v00 + v01));           // dst[2y+1, 2x  ]
  d_store(base + dw + 1, 0.25 * (v00 + v01 + v10 + v11)); // dst[2y+1, 2x+1]
}

// Helper so the four writes read clearly; trivially inlined by Tint.
fn d_store(idx : i32, val : f32) {
  u_dst[idx] = val;
}
