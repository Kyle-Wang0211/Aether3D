// dense_runner.h — CasDiffMVS ONNX Runtime session for the on-device dense runner (Stage 1).
//
// Copied from the certified device bench (casdiffmvs_wgsl_port_2026-08-17/bench/bench_main.cc, A16 parity run
// 2026-09-14): self-built ORT 1.29.0 with the WebGPU EP, graph optimisation pinned to ORT_ENABLE_BASIC
// (EXTENDED and above make the WebGPU EP emit non-finite values silently — onnxruntime issue #32145),
// inputs fed BY NAME in the session's reported order (imgs, pm_stage1..3, depth_values, noise_stage2/3),
// outputs {depth, conf0, conf1, conf2}.
//
// [2026-09-16 dense-lossless-speedup-v1, §7 "特征跨视图复用"] SPLIT MODE, additive: the same graph run as TWO
// sessions so each image's FeatureNet is computed ONCE per job instead of ~10 times (once as the reference and
// ~nsrc times as a source of its neighbours). Nothing about the fused path below changes — init()/run() are
// still the byte baseline and the arm the gate compares against.
//   F session (casdiffmvs_feat.onnx)  : one view's image  -> that view's three feature maps.
//   R session (casdiffmvs_rest.onnx)  : the 10 views' feature maps (+ the reference image for the context net,
//                                       + pm_stage1..3 / depth_values / noise_stage2,3) -> depth, conf0..2.
// Prior art replicated (not invented here):
//   * hloc — cvg/Hierarchical-Localization (Apache-2.0): extract_features.py writes one feature entry per IMAGE
//     to an h5 and every pair in match_features.py reads it back; features are never recomputed per pair.
//   * FADEC — arXiv:2212.00357 §II-B2: DeepVideoMVS's FeatureShrinker outputs are kept in a keyframe feature
//     buffer and reused by later frames (the original DeepVideoMVS buffers only pose+image and recomputes).
//   * The graph split itself was produced with onnx.utils.extract_model (onnx/onnx, Apache-2.0) — an exact
//     tensor-name cut that carries only the referenced initializers; no node was hand-edited. The cut is legal
//     because the official forward is already per-view batch=1 (cvg/diffmvs models/diffusion.py:157-158
//     `for img in imgs: self.feature(img)`), so the single-view subgraph has the SAME shapes as the export.
// There is no official bit-exactness guarantee for splitting a graph across two ORT sessions (ORT documents
// none), so the only thing that licenses this is the end-to-end byte gate: pack + PLY sha vs the fused arm,
// plus a wrong-view-order negative control.
#pragma once
#include <cstddef>
#include <memory>
#include <string>
#include <vector>
#include "dense_inputs.h"

namespace Ort { struct Env; struct Session; }

namespace aether::dense {

// One view's FeatureNet output, CPU-resident (plain std::vector, no EP-specific allocator: the same code has to
// build for iOS / Android / HarmonyOS). Sizes for the shipped 768x576 model are fixed by the export:
//   f[0] [1,48,72,96]   1.33 MB    f[1] [1,32,144,192] 3.54 MB    f[2] [1,16,288,384] 7.08 MB   => 12.5 MB/view.
// Uploading them per R run is a pure host->device copy; a GPU-resident IoBinding is a LATER step and is
// deliberately not done here (it would pin buffers across sessions and needs its own gate).
struct FeatureSet {
    std::vector<float> f[3];
    bool empty() const { return f[0].empty() || f[1].empty() || f[2].empty(); }
    size_t bytes() const { return (f[0].size() + f[1].size() + f[2].size()) * sizeof(float); }
};

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

    // ---- split mode (feature reuse) ----
    // Builds BOTH sessions in the same Ort::Env with the same SessionOptions recipe init() uses (ORT_ENABLE_BASIC
    // + AppendExecutionProvider("WebGPU", {}) + the env Knobs block), so the two arms differ only by the graph
    // cut. *session_ms covers both. Mutually exclusive with init() on the same object.
    bool init_split(const std::string& feat_model, const std::string& rest_model, bool webgpu, int W, int H,
                    int n_view, std::string* err, double* session_ms);
    // img: 3*H*W float32, ONE view (the same fp16->fp32, grey replicated to 3 channels, slice the fused path
    // puts at `imgs[k]`). Fills out.f[0..2]; out is resized as needed.
    bool run_features(const float* img, FeatureSet& out, double* ms, std::string* err);
    // views: n_view pointers, views[0] = reference, views[1..nsrc] = the neighbours IN THE SAME ORDER the fused
    // path laid them out in `imgs`. ref_img: 3*H*W float32 of views[0] (the context net still reads the image).
    bool run_rest(const FeatureSet* const* views, const float* ref_img, const FrameInputs& in,
                  const float* noise2, const float* noise3,
                  float* depth, float* conf0, float* conf1, float* conf2, double* ms, std::string* err);
    // Element counts of the three feature maps for the configured W/H (48*H/8*W/8, 32*H/4*W/4, 16*H/2*W/2).
    void feature_sizes(size_t n[3]) const;

    void release();
    bool ready() const { return sess_ != nullptr; }
    bool split() const { return split_; }
private:
    struct Impl; std::unique_ptr<Impl> impl_;
    void* sess_ = nullptr;
    int W_ = 0, H_ = 0, nview_ = 0;
    bool split_ = false;
};

// torch.randn_like semantics (standard normal) for the diffusion noise inputs, deterministic per (seed, frame).
// std::mt19937_64 + std::normal_distribution<float>(0,1). The certified device parity used the reference's
// own noise instead (fed through DenseJob::ext_noise); this is only the product's runtime source.
void make_noise(uint64_t seed, int frame_id, size_t n2, size_t n3, std::vector<float>& noise2, std::vector<float>& noise3);

}  // namespace aether::dense
