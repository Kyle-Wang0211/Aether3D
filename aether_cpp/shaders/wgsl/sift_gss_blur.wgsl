// sift_gss_blur.wgsl — separable 1D Gaussian for the GPU DSP-SIFT scale-space.
//
// GPU DSP-SIFT Stage 1 (see glomap_vendor/GPU_DSP_SIFT_PLAN.md). One 1D pass
// along `axis` (0 = horizontal/rows, 1 = vertical/cols); the host runs it twice
// (h then v) per smoothing step to realize the separable 2D Gaussian, matching
// VLFeat imopv.c vl_imconvcol / vl_imsmooth_f. Edge handling = clamp-to-edge
// (VLFeat VL_PAD_BY_CONTINUITY). Taps are precomputed on the host per the VLFeat
// scale-space sigma recurrence (deltaSigma = sqrt(sigma_s^2 - sigma_{s-1}^2)).
//
// fp32 storage here for a clear first parity pass (gss max-rel <= 1e-3 vs the
// CPU vl_scalespace levels); the PLAN's fp16-store / fp32-accumulate is the
// memory optimization layered on AFTER parity holds. Accumulation is fp32.
//
// NOT YET PARITY-VALIDATED — this is the Stage-1 starting kernel.

struct Params {
  width  : u32,
  height : u32,
  radius : u32,   // kernel half-width; full length = 2*radius + 1
  axis   : u32,   // 0 = horizontal, 1 = vertical
  // [PACK-ZERO 2026-08-10] 层住进 packed 大缓冲:src/dst 各带 element 偏移。
  src_off : u32,
  dst_off : u32,
};

@group(0) @binding(0) var<storage, read>       src   : array<f32>;
@group(0) @binding(1) var<storage, read>       taps  : array<f32>; // length 2*radius+1, sum=1
@group(0) @binding(2) var<storage, read_write> dst   : array<f32>;
@group(0) @binding(3) var<uniform>             P     : Params;

fn clampi(v : i32, lo : i32, hi : i32) -> i32 {
  return max(lo, min(v, hi));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let x : u32 = gid.x;
  let y : u32 = gid.y;
  if (x >= P.width || y >= P.height) { return; }

  let r   : i32 = i32(P.radius);
  let len : i32 = 2 * r + 1;
  var acc : f32 = 0.0;

  if (P.axis == 0u) {
    // horizontal: sample along x, clamp to [0, width-1]
    let base : i32 = i32(y) * i32(P.width);
    let cx   : i32 = i32(x);
    for (var k : i32 = 0; k < len; k = k + 1) {
      let sx : i32 = clampi(cx + (k - r), 0, i32(P.width) - 1);
      acc = acc + taps[k] * src[P.src_off + u32(base + sx)];
    }
  } else {
    // vertical: sample along y, clamp to [0, height-1]
    let cy : i32 = i32(y);
    for (var k : i32 = 0; k < len; k = k + 1) {
      let sy : i32 = clampi(cy + (k - r), 0, i32(P.height) - 1);
      acc = acc + taps[k] * src[P.src_off + u32(sy * i32(P.width) + i32(x))];
    }
  }

  dst[P.dst_off + y * P.width + x] = acc;
}
