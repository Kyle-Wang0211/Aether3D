// dense_runner.h — CasDiffMVS ONNX Runtime session for the on-device dense runner (Stage 1).
//
// Copied from the certified device bench (casdiffmvs_wgsl_port_2026-08-17/bench/bench_main.cc, A16 parity run
// 2026-09-14): self-built ORT 1.29.0 with the WebGPU EP, graph optimisation pinned to ORT_ENABLE_BASIC
// (EXTENDED and above make the WebGPU EP emit non-finite values silently — onnxruntime issue #32145),
// inputs fed BY NAME in the session's reported order (imgs, pm_stage1..3, depth_values, noise_stage2/3),
// outputs {depth, conf0, conf1, conf2}.
#pragma once
#include <memory>
#include <string>
#include <vector>
#include "dense_inputs.h"

namespace Ort { struct Env; struct Session; }

namespace aether::dense {

class DenseRunner {
public:
    DenseRunner();
    ~DenseRunner();
    // model: fused ONNX (Conv3d fused, WebGPU EP requirement). webgpu=false -> CPU EP (debug only).
    bool init(const std::string& model, bool webgpu, int W, int H, int n_view, std::string* err, double* session_ms);
    // imgs: n_view*3*H*W float32 (grey replicated to 3 channels). noise2: (H/4)*(W/4), noise3: (H/2)*(W/2).
    // depth/conf: H*W each. Returns false with *err on failure.
    bool run(const float* imgs, const FrameInputs& in, const float* noise2, const float* noise3,
             float* depth, float* conf0, float* conf1, float* conf2, double* ms, std::string* err);
    void release();
    bool ready() const { return sess_ != nullptr; }
private:
    struct Impl; std::unique_ptr<Impl> impl_;
    void* sess_ = nullptr;
    int W_ = 0, H_ = 0, nview_ = 0;
};

// torch.randn_like semantics (standard normal) for the diffusion noise inputs, deterministic per (seed, frame).
// std::mt19937_64 + std::normal_distribution<float>(0,1). The certified device parity used the reference's
// own noise instead (fed through DenseJob::ext_noise); this is only the product's runtime source.
void make_noise(uint64_t seed, int frame_id, size_t n2, size_t n3, std::vector<float>& noise2, std::vector<float>& noise3);

}  // namespace aether::dense
