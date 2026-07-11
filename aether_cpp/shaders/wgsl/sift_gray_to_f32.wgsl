// sift_gray_to_f32.wgsl — u8 grayscale → f32/255 for the GPU DSP-SIFT scale-space.
//
// GPU DSP-SIFT Stage 0 (see glomap_vendor/GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §2-S0).
// Mirrors colmap/feature/sift.cc:383 `data_float[i] = uint8 / 255.0f` exactly:
// this is the VLFeat covdet input. Bit-exact vs the CPU divide (single f32 op).
//
// The u8 image is uploaded packed 4 bytes per u32 (row-major, tightly packed,
// no row padding) because WGSL storage buffers address 4-byte words. The
// destination is one f32 per pixel, row-major, same (width, height).

struct Params {
  width  : u32,
  height : u32,
};

@group(0) @binding(0) var<storage, read>       src_u8 : array<u32>; // packed 4 u8/word
@group(0) @binding(1) var<storage, read_write> dst    : array<f32>;
@group(0) @binding(2) var<uniform>             P      : Params;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
  let x : u32 = gid.x;
  let y : u32 = gid.y;
  if (x >= P.width || y >= P.height) { return; }

  let lin   : u32 = y * P.width + x;
  let word  : u32 = src_u8[lin >> 2u];
  let shift : u32 = (lin & 3u) * 8u;
  let byte  : u32 = (word >> shift) & 0xFFu;

  dst[lin] = f32(byte) / 255.0;
}
