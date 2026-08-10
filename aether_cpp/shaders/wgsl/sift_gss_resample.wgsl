// sift_gss_resample.wgsl — 2× integer-decimation octave downsample for the GSS.
//
// GPU DSP-SIFT Stage 1b (see glomap_vendor/GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §2-S1b).
// Mirrors VLFeat scalespace.c copy_and_downsample() with numOctaves==1 (step=2):
// dst[dx,dy] = src[2*dx, 2*dy]. Pure decimation, NO interpolation — VLFeat takes
// the top-left sample of each 2×2 block.
//
// dst dimensions are the next octave's geometry: dst_width = src_width >> 1,
// dst_height = src_height >> 1 (vl_scalespace_get_octave_geometry: VL_SHIFT_LEFT).
// The host sizes the dst buffer accordingly and dispatches over (dst_w, dst_h).

struct Params {
  src_width  : u32,
  dst_width  : u32,
  dst_height : u32,
  src_off    : u32,
  dst_off    : u32,
  _pad0      : u32,
  _pad1      : u32,
  _pad2      : u32,
};

// [PACK-ZERO 2026-08-10] src 与 dst 是同一 packed 大缓冲的两个不相交区间;
// WebGPU 禁止同 buffer 同 dispatch 内 read + read_write 双绑定(aliasing
// 校验),故这里用**单一** read_write 绑定 + 双偏移。区间不相交 ⇒ 语义同旧。
@group(0) @binding(0) var<storage, read_write> data : array<f32>;
@group(0) @binding(1) var<uniform>             P    : Params;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let dx : u32 = gid.x;
  let dy : u32 = gid.y;
  if (dx >= P.dst_width || dy >= P.dst_height) { return; }

  let sx : u32 = dx << 1u;
  let sy : u32 = dy << 1u;
  data[P.dst_off + dy * P.dst_width + dx] = data[P.src_off + sy * P.src_width + sx];
}
