// sift_dsp_mean.wgsl — DSP scale mean (③ scale-parallel descriptor, pass 2).
//
// The scale-parallel descriptor kernel (sift_dsp_descriptor_par.wgsl) writes one
// normalized 128-bin descriptor per (keypoint, scale) into scale_desc. This pass
// averages the DSP_NUM scales per keypoint into the final raw_desc, summing in
// FIXED order sc=0,1,…,DSP_NUM-1 — byte-identical to the serial accumulate in the
// original kernel (same f32 add order). Then ×(1/DSP_NUM), matching
// aether_threaded_extract.cc's colwise().mean().
//
// One thread per (keypoint, bin): gid.x in [0, count*128).

const DSP_NUM : u32 = 10u;

struct Params { count : u32 };

@group(0) @binding(0) var<storage, read>       scale_desc : array<f32>;  // count*DSP_NUM*128
@group(0) @binding(1) var<storage, read_write> raw_desc   : array<f32>;  // count*128
@group(0) @binding(2) var<uniform>             P          : Params;

@compute @workgroup_size(64,1,1)
fn main(@builtin(global_invocation_id) gid:vec3<u32>){
  let idx = gid.x;                 // kp*128 + bin
  if (idx >= P.count * 128u) { return; }
  let kp  = idx / 128u;
  let bin = idx % 128u;
  // sum the DSP_NUM scales in order 0..DSP_NUM-1 (matches the serial accumulate).
  var acc : f32 = 0.0;
  for (var sc : u32 = 0u; sc < DSP_NUM; sc = sc + 1u) {
    acc = acc + scale_desc[(kp * DSP_NUM + sc) * 128u + bin];
  }
  raw_desc[idx] = acc * (1.0 / f32(DSP_NUM));
}
