// dense_runner.cc — see dense_runner.h.
#include "dense_runner.h"

#include <onnxruntime_cxx_api.h>

#include <chrono>
#include <random>
#include <unordered_map>

namespace aether::dense {

struct DenseRunner::Impl {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "pwdense"};
    std::unique_ptr<Ort::Session> sess;
    std::vector<std::string> in_names;
    std::vector<const char*> in_ptrs;
};

DenseRunner::DenseRunner() : impl_(new Impl) {}
DenseRunner::~DenseRunner() { release(); }
void DenseRunner::release() { if (impl_) impl_->sess.reset(); sess_ = nullptr; }

bool DenseRunner::init(const std::string& model, bool webgpu, int W, int H, int n_view, std::string* err, double* session_ms) {
    try {
        Ort::SessionOptions so;
        so.SetGraphOptimizationLevel(ORT_ENABLE_BASIC);   // bench_main.cc: EXTENDED+ -> silent non-finite on WebGPU
        if (webgpu) { std::unordered_map<std::string, std::string> opts; so.AppendExecutionProvider("WebGPU", opts); }
        const auto t0 = std::chrono::steady_clock::now();
        impl_->sess = std::make_unique<Ort::Session>(impl_->env, model.c_str(), so);
        if (session_ms) *session_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        Ort::AllocatorWithDefaultOptions alloc;
        impl_->in_names.clear(); impl_->in_ptrs.clear();
        for (size_t i = 0; i < impl_->sess->GetInputCount(); ++i) impl_->in_names.push_back(impl_->sess->GetInputNameAllocated(i, alloc).get());
        for (auto& s : impl_->in_names) impl_->in_ptrs.push_back(s.c_str());
        W_ = W; H_ = H; nview_ = n_view; sess_ = impl_->sess.get();
        return true;
    } catch (const std::exception& e) { if (err) *err = e.what(); release(); return false; }
}

bool DenseRunner::run(const float* imgs, const FrameInputs& in, const float* noise2, const float* noise3,
                      float* depth, float* conf0, float* conf1, float* conf2, double* ms, std::string* err) {
    if (!sess_) { if (err) *err = "session not initialised"; return false; }
    try {
        const size_t HW = (size_t)W_ * H_, n2 = (size_t)(H_ / 4) * (W_ / 4), n3 = (size_t)(H_ / 2) * (W_ / 2);
        auto mi = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<int64_t> sh_img{1, nview_, 3, H_, W_}, sh_pm{1, nview_, 2, 4, 4}, sh_dv{1, DENSE_NUM_DEPTH},
                             sh_n2{1, 1, H_ / 4, W_ / 4}, sh_n3{1, 1, H_ / 2, W_ / 2};
        std::vector<Ort::Value> vals;
        auto push = [&](const float* p, std::vector<int64_t>& s, size_t n) {
            vals.push_back(Ort::Value::CreateTensor<float>(mi, const_cast<float*>(p), n, s.data(), s.size()));
        };
        for (auto& nm : impl_->in_names) {   // bench_main.cc: feed in the session's own order, never an assumed one
            if      (nm == "imgs")         push(imgs, sh_img, (size_t)nview_ * 3 * HW);
            else if (nm == "pm_stage1")    push(in.pm[0].data(), sh_pm, (size_t)nview_ * 32);
            else if (nm == "pm_stage2")    push(in.pm[1].data(), sh_pm, (size_t)nview_ * 32);
            else if (nm == "pm_stage3")    push(in.pm[2].data(), sh_pm, (size_t)nview_ * 32);
            else if (nm == "depth_values") push(in.dv.data(), sh_dv, DENSE_NUM_DEPTH);
            else if (nm == "noise_stage2") push(noise2, sh_n2, n2);
            else if (nm == "noise_stage3") push(noise3, sh_n3, n3);
            else { if (err) *err = "unknown model input: " + nm; return false; }
        }
        const char* out_names[] = {"depth", "conf0", "conf1", "conf2"};
        const auto t0 = std::chrono::steady_clock::now();
        auto out = impl_->sess->Run(Ort::RunOptions{nullptr}, impl_->in_ptrs.data(), vals.data(), vals.size(), out_names, 4);
        if (ms) *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        float* dst[4] = {depth, conf0, conf1, conf2};
        for (int k = 0; k < 4; ++k) {
            const size_t n = out[k].GetTensorTypeAndShapeInfo().GetElementCount();
            if (n != HW) { if (err) *err = "output " + std::string(out_names[k]) + " has " + std::to_string(n) + " elements, expected H*W"; return false; }
            const float* p = out[k].GetTensorData<float>();
            std::copy(p, p + HW, dst[k]);
        }
        return true;
    } catch (const std::exception& e) { if (err) *err = e.what(); return false; }
}

void make_noise(uint64_t seed, int frame_id, size_t n2, size_t n3, std::vector<float>& noise2, std::vector<float>& noise3) {
    std::mt19937_64 gen(seed ^ (0x9E3779B97F4A7C15ULL * (uint64_t)(frame_id + 1)));
    std::normal_distribution<float> N(0.f, 1.f);
    noise2.resize(n2); noise3.resize(n3);
    for (auto& v : noise2) v = N(gen);
    for (auto& v : noise3) v = N(gen);
}

}  // namespace aether::dense
