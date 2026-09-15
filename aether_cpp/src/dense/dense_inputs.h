// dense_inputs.h — per-frame CasDiffMVS model inputs from the session camera table (Stage 1, input side).
//
// Ported from the device input packer pack_inputs.py (casdiffmvs_wgsl_port_2026-08-17/bench), which is
// what the certified device parity run consumed:
//   view = [f] + neighbors[f]                              (NIMG = nsrc + 1 views, reference first)
//   base[:,0]   = [R|t; 0 0 0 1]  (float32, from cams R[9:18], t[18:21])
//   base[:,1,:3,:3] = K           (float32, from cams K[0:9])
//   pm_stage1/2/3 = base with [:,1,:2,:] /= 8.0 / 4.0 / 2.0   (stage 4 is never read by the graph)
//   depth_values  = np.linspace(1/dmax, 1/dmin, 384, dtype=float32)   (dense_preproc::depth_values)
//   imgs          = fp16 grey -> fp32, replicated to 3 channels (bench_main.cc)
// Every op is an exact power-of-two scale or a numpy-linspace replica, so the gate is byte equality
// with inputs8.bin's blocks.
#pragma once
#include <cstdint>
#include <vector>

namespace aether::dense {

constexpr int DENSE_NUM_DEPTH = 384;

struct FrameInputs {
    int n_view = 0;
    std::vector<float> pm[3];     // n_view*2*4*4 each, stages 1..3
    std::vector<float> dv;        // 384
};

// cams: NF*36 (fixture layout). views: n_view indices, reference first.
void build_frame_inputs(const float* cams, const std::vector<int32_t>& views, FrameInputs& out);

// fp16 (IEEE binary16 bits) -> fp32, exactly as bench_main.cc converts the image bank.
float fp16_to_fp32(uint16_t x);
// fp32 -> fp16 bits, round-to-nearest-even (numpy astype(np.float16)).
uint16_t fp32_to_fp16(float f);

}  // namespace aether::dense
