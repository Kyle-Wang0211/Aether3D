// dense_runner.cc — see dense_runner.h.
#include "dense_runner.h"

#include <onnxruntime_cxx_api.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <random>
#include <unordered_map>

namespace aether::dense {

// [2026-09-16 lossless-speedup v1, task 4.1 bench arms] Session knobs read from the environment, ONLY for the device
// bench (com.kyle.casdiffdensebench launches with --environment-variables). With none of them set the session is
// configured exactly as before (ORT_ENABLE_BASIC + AppendExecutionProvider("WebGPU", {}) + WARNING logging), so the
// production app is untouched until a knob has passed the byte gate and is promoted to a code default.
//   PWDENSE_ORT_VALIDATION     -> ep.webgpuexecutionprovider.validationMode   (disabled|wgpuOnly|basic|full)
//   PWDENSE_ORT_MAX_PENDING    -> ep.webgpuexecutionprovider.maxNumPendingDispatches (1..4096, default 16)
//   PWDENSE_ORT_DEFAULT_CACHE  -> ep.webgpuexecutionprovider.defaultBufferCacheMode (disabled|lazyRelease|simple|bucket)
//   PWDENSE_ORT_STORAGE_CACHE  -> ep.webgpuexecutionprovider.storageBufferCacheMode
//   PWDENSE_ORT_INT64=1        -> ep.webgpuexecutionprovider.enableInt64 (int64 Clip/Cast/arith kernels on the GPU; today the
//                                 model's one int64 Clip falls to the CPU and forces a GPU->CPU->GPU round trip per run)
//   PWDENSE_ORT_PROFILE        -> SessionOptions::EnableProfiling(<path prefix>)  (per-kernel GPU timestamps)
//   PWDENSE_ORT_LOG            -> append ORT's own log lines to this file (the EP self-reports the parsed options at
//                                 VERBOSE: webgpu_provider_factory.cc "WebGPU EP ValidationMode: ..." etc.)
//   PWDENSE_ORT_VERBOSE=1      -> logging severity VERBOSE (needs PWDENSE_ORT_LOG to be readable on a device)
// Option keys: onnxruntime/core/providers/webgpu/webgpu_provider_options.h (v1.29.0). The full-prefix
// AddConfigEntry form is the one ParseEpConfig reads (webgpu_provider_factory.cc:40-45).
namespace {
struct Knobs {
    std::string validation, max_pending, default_cache, storage_cache, profile, log;
    bool verbose = false, int64 = false;
    std::string layout;   // PWDENSE_ORT_LAYOUT=NCHW|NHWC -> ep.webgpuexecutionprovider.preferredLayout (bench only: changes conv kernels)
    static std::string env(const char* k) { const char* v = std::getenv(k); return v ? std::string(v) : std::string(); }
    static Knobs read() {
        Knobs k;
        k.validation = env("PWDENSE_ORT_VALIDATION"); k.max_pending = env("PWDENSE_ORT_MAX_PENDING");
        k.default_cache = env("PWDENSE_ORT_DEFAULT_CACHE"); k.storage_cache = env("PWDENSE_ORT_STORAGE_CACHE");
        k.profile = env("PWDENSE_ORT_PROFILE"); k.log = env("PWDENSE_ORT_LOG");
        k.verbose = env("PWDENSE_ORT_VERBOSE") == "1";
        k.int64 = env("PWDENSE_ORT_INT64") == "1";
        k.layout = env("PWDENSE_ORT_LAYOUT");
        return k;
    }
    bool any() const { return !validation.empty() || !max_pending.empty() || !default_cache.empty() || !storage_cache.empty() || !profile.empty() || !log.empty() || verbose || int64 || !layout.empty(); }
};
std::mutex g_log_mu;
std::string g_log_path;
void file_logger(void* /*param*/, OrtLoggingLevel severity, const char* category, const char* logid, const char* code_location, const char* message) {
    std::lock_guard<std::mutex> lk(g_log_mu);
    FILE* f = std::fopen(g_log_path.c_str(), "a"); if (!f) return;
    std::fprintf(f, "[%d] %s %s %s: %s\n", (int)severity, logid ? logid : "", category ? category : "", code_location ? code_location : "", message ? message : "");
    std::fclose(f);
}
void self_report(const Knobs& k) {
    if (k.log.empty()) return;
    std::lock_guard<std::mutex> lk(g_log_mu);
    FILE* f = std::fopen(k.log.c_str(), "a"); if (!f) return;
    std::fprintf(f, "pwdense ort knobs: validationMode=%s maxNumPendingDispatches=%s defaultBufferCacheMode=%s storageBufferCacheMode=%s profile=%s verbose=%d enableInt64=%d\n",
                 k.validation.empty() ? "(default)" : k.validation.c_str(), k.max_pending.empty() ? "(default)" : k.max_pending.c_str(),
                 k.default_cache.empty() ? "(default)" : k.default_cache.c_str(), k.storage_cache.empty() ? "(default)" : k.storage_cache.c_str(),
                 k.profile.empty() ? "(off)" : k.profile.c_str(), k.verbose ? 1 : 0, k.int64 ? 1 : 0);
    std::fclose(f);
}
std::unique_ptr<Ort::Env> make_env(const Knobs& k) {
    const OrtLoggingLevel lvl = k.verbose ? ORT_LOGGING_LEVEL_VERBOSE : ORT_LOGGING_LEVEL_WARNING;
    if (!k.log.empty()) { { std::lock_guard<std::mutex> lk(g_log_mu); g_log_path = k.log; } return std::make_unique<Ort::Env>(lvl, "pwdense", file_logger, nullptr); }
    return std::make_unique<Ort::Env>(lvl, "pwdense");
}
}  // namespace

// [2026-09-16 feature reuse] What one input of the R (rest) session is bound to. Parsed ONCE from the session's
// own reported input names, never from an assumed order: the split graph exposes the 10 views' feature maps
// under the names onnx.utils.extract_model kept from the export.
//   k == 0            : "/core/feature/out{L}/Conv_output_0"
//   k >= 1            : "/core/feature/out{L}_{k}/Conv_output_0"     (L = 1,2,3 -> level 0,1,2)
enum class DenseRIn { Feature, RefImg, Pm1, Pm2, Pm3, Dv, N2, N3 };
struct DenseRBind { DenseRIn what = DenseRIn::RefImg; int slot = 0, level = 0; };
namespace {
// Returns true and fills slot/level when `nm` is one of the FeatureNet output names above.
bool parse_feature_name(const std::string& nm, int n_view, int* slot, int* level) {
    static const char kPre[] = "/core/feature/out";
    static const char kSuf[] = "/Conv_output_0";
    const size_t pre = sizeof(kPre) - 1, suf = sizeof(kSuf) - 1;
    if (nm.size() <= pre + suf || nm.compare(0, pre, kPre) != 0 || nm.compare(nm.size() - suf, suf, kSuf) != 0) return false;
    const std::string mid = nm.substr(pre, nm.size() - pre - suf);   // "1" or "1_7"
    if (mid.empty() || mid[0] < '1' || mid[0] > '3') return false;
    *level = mid[0] - '1';
    if (mid.size() == 1) { *slot = 0; return true; }
    if (mid[1] != '_' || mid.size() < 3) return false;
    int k = 0;
    for (size_t i = 2; i < mid.size(); ++i) { if (mid[i] < '0' || mid[i] > '9') return false; k = k * 10 + (mid[i] - '0'); }
    if (k < 1 || k >= n_view) return false;
    *slot = k;
    return true;
}
}  // namespace

struct DenseRunner::Impl {
    Knobs knobs = Knobs::read();
    std::unique_ptr<Ort::Env> env = make_env(knobs);
    std::unique_ptr<Ort::Session> sess;
    std::vector<std::string> in_names;
    std::vector<const char*> in_ptrs;
    // split mode
    std::unique_ptr<Ort::Session> feat;                    // F session
    std::vector<std::string> feat_in_names, feat_out_names;
    std::vector<const char*> feat_in_ptrs, feat_out_ptrs;
    std::vector<std::string> rest_in_names;                // R session (`sess` holds it, so ready() still works)
    std::vector<const char*> rest_in_ptrs;
    std::vector<DenseRBind> rest_bind;

    // The one SessionOptions recipe, shared by the fused session and by BOTH split sessions so the arms differ
    // only by which graph they load.
    void configure(Ort::SessionOptions& so, bool webgpu, bool report) const {
        so.SetGraphOptimizationLevel(ORT_ENABLE_BASIC);   // bench_main.cc: EXTENDED+ -> silent non-finite on WebGPU
        const Knobs& k = knobs;
        if (k.any()) {   // bench arms only; see the Knobs comment
            if (!k.validation.empty())    so.AddConfigEntry("ep.webgpuexecutionprovider.validationMode", k.validation.c_str());
            if (!k.max_pending.empty())   so.AddConfigEntry("ep.webgpuexecutionprovider.maxNumPendingDispatches", k.max_pending.c_str());
            if (!k.default_cache.empty()) so.AddConfigEntry("ep.webgpuexecutionprovider.defaultBufferCacheMode", k.default_cache.c_str());
            if (!k.storage_cache.empty()) so.AddConfigEntry("ep.webgpuexecutionprovider.storageBufferCacheMode", k.storage_cache.c_str());
            if (!k.profile.empty())       so.EnableProfiling(k.profile.c_str());
            if (k.int64)                  so.AddConfigEntry("ep.webgpuexecutionprovider.enableInt64", "1");
            if (!k.layout.empty())        so.AddConfigEntry("ep.webgpuexecutionprovider.preferredLayout", k.layout.c_str());
            if (report) self_report(k);
        }
        if (webgpu) { std::unordered_map<std::string, std::string> opts; so.AppendExecutionProvider("WebGPU", opts); }
    }
};

DenseRunner::DenseRunner() : impl_(new Impl) {}
DenseRunner::~DenseRunner() { release(); }
void DenseRunner::release() {
    if (impl_) { impl_->sess.reset(); impl_->feat.reset(); }
    sess_ = nullptr;
}

bool DenseRunner::init(const std::string& model, bool webgpu, int W, int H, int n_view, std::string* err, double* session_ms) {
    try {
        Ort::SessionOptions so;
        impl_->configure(so, webgpu, true);
        const auto t0 = std::chrono::steady_clock::now();
        impl_->sess = std::make_unique<Ort::Session>(*impl_->env, model.c_str(), so);
        if (session_ms) *session_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        Ort::AllocatorWithDefaultOptions alloc;
        impl_->in_names.clear(); impl_->in_ptrs.clear();
        for (size_t i = 0; i < impl_->sess->GetInputCount(); ++i) impl_->in_names.push_back(impl_->sess->GetInputNameAllocated(i, alloc).get());
        for (auto& s : impl_->in_names) impl_->in_ptrs.push_back(s.c_str());
        W_ = W; H_ = H; nview_ = n_view; split_ = false; sess_ = impl_->sess.get();
        return true;
    } catch (const std::exception& e) { if (err) *err = e.what(); release(); return false; }
}

void DenseRunner::feature_sizes(size_t n[3]) const {
    n[0] = (size_t)48 * (H_ / 8) * (W_ / 8);
    n[1] = (size_t)32 * (H_ / 4) * (W_ / 4);
    n[2] = (size_t)16 * (H_ / 2) * (W_ / 2);
}

bool DenseRunner::init_split(const std::string& feat_model, const std::string& rest_model, bool webgpu, int W, int H,
                             int n_view, std::string* err, double* session_ms) {
    try {
        const auto t0 = std::chrono::steady_clock::now();
        { Ort::SessionOptions so; impl_->configure(so, webgpu, true);
          impl_->feat = std::make_unique<Ort::Session>(*impl_->env, feat_model.c_str(), so); }
        { Ort::SessionOptions so; impl_->configure(so, webgpu, false);
          impl_->sess = std::make_unique<Ort::Session>(*impl_->env, rest_model.c_str(), so); }
        if (session_ms) *session_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        W_ = H_ = 0;   // only set once the name plan below validated
        Ort::AllocatorWithDefaultOptions alloc;
        impl_->feat_in_names.clear(); impl_->feat_in_ptrs.clear(); impl_->feat_out_names.clear(); impl_->feat_out_ptrs.clear();
        for (size_t i = 0; i < impl_->feat->GetInputCount(); ++i) impl_->feat_in_names.push_back(impl_->feat->GetInputNameAllocated(i, alloc).get());
        for (size_t i = 0; i < impl_->feat->GetOutputCount(); ++i) impl_->feat_out_names.push_back(impl_->feat->GetOutputNameAllocated(i, alloc).get());
        if (impl_->feat_in_names.size() != 1) { if (err) *err = "feature model must take exactly one input"; release(); return false; }
        if (impl_->feat_out_names.size() != 3) { if (err) *err = "feature model must produce three outputs"; release(); return false; }
        for (auto& s : impl_->feat_in_names) impl_->feat_in_ptrs.push_back(s.c_str());
        for (auto& s : impl_->feat_out_names) impl_->feat_out_ptrs.push_back(s.c_str());
        // The F session's outputs come back in the graph's own order; the R session names them explicitly, so the
        // only thing we must pin here is which of the three levels each output is. out1/out2/out3 <-> level 0/1/2.
        for (size_t i = 0; i < 3; ++i) {
            int slot = -1, level = -1;
            if (!parse_feature_name(impl_->feat_out_names[i], n_view, &slot, &level) || slot != 0 || level != (int)i) {
                if (err) *err = "unexpected feature model output name: " + impl_->feat_out_names[i]; release(); return false;
            }
        }
        impl_->rest_in_names.clear(); impl_->rest_in_ptrs.clear(); impl_->rest_bind.clear();
        for (size_t i = 0; i < impl_->sess->GetInputCount(); ++i) impl_->rest_in_names.push_back(impl_->sess->GetInputNameAllocated(i, alloc).get());
        for (auto& s : impl_->rest_in_names) impl_->rest_in_ptrs.push_back(s.c_str());
        int n_feat_in = 0;
        for (const std::string& nm : impl_->rest_in_names) {
            DenseRBind b;
            if (parse_feature_name(nm, n_view, &b.slot, &b.level)) { b.what = DenseRIn::Feature; ++n_feat_in; }
            else if (nm == "/Gather_output_0") b.what = DenseRIn::RefImg;
            else if (nm == "pm_stage1")        b.what = DenseRIn::Pm1;
            else if (nm == "pm_stage2")        b.what = DenseRIn::Pm2;
            else if (nm == "pm_stage3")        b.what = DenseRIn::Pm3;
            else if (nm == "depth_values")     b.what = DenseRIn::Dv;
            else if (nm == "noise_stage2")     b.what = DenseRIn::N2;
            else if (nm == "noise_stage3")     b.what = DenseRIn::N3;
            else { if (err) *err = "unknown rest-model input: " + nm; release(); return false; }
            impl_->rest_bind.push_back(b);
        }
        if (n_feat_in != n_view * 3) {
            if (err) *err = "rest model wants " + std::to_string(n_feat_in) + " feature inputs, expected " + std::to_string(n_view * 3);
            release(); return false;
        }
        W_ = W; H_ = H; nview_ = n_view; split_ = true; sess_ = impl_->sess.get();
        return true;
    } catch (const std::exception& e) { if (err) *err = e.what(); release(); return false; }
}

bool DenseRunner::run_features(const float* img, FeatureSet& out, double* ms, std::string* err) {
    if (!sess_ || !split_ || !impl_->feat) { if (err) *err = "split session not initialised"; return false; }
    try {
        auto mi = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<int64_t> sh{1, 3, H_, W_};
        Ort::Value in = Ort::Value::CreateTensor<float>(mi, const_cast<float*>(img), (size_t)3 * H_ * W_, sh.data(), sh.size());
        const auto t0 = std::chrono::steady_clock::now();
        auto res = impl_->feat->Run(Ort::RunOptions{nullptr}, impl_->feat_in_ptrs.data(), &in, 1,
                                    impl_->feat_out_ptrs.data(), impl_->feat_out_ptrs.size());
        if (ms) *ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        size_t want[3]; feature_sizes(want);
        for (int k = 0; k < 3; ++k) {
            const size_t n = res[k].GetTensorTypeAndShapeInfo().GetElementCount();
            if (n != want[k]) {
                if (err) *err = "feature output " + impl_->feat_out_names[k] + " has " + std::to_string(n) + " elements, expected " + std::to_string(want[k]);
                return false;
            }
            const float* p = res[k].GetTensorData<float>();
            out.f[k].assign(p, p + n);
        }
        return true;
    } catch (const std::exception& e) { if (err) *err = e.what(); return false; }
}

bool DenseRunner::run_rest(const FeatureSet* const* views, const float* ref_img, const FrameInputs& in,
                           const float* noise2, const float* noise3,
                           float* depth, float* conf0, float* conf1, float* conf2, double* ms, std::string* err) {
    if (!sess_ || !split_) { if (err) *err = "split session not initialised"; return false; }
    try {
        const size_t HW = (size_t)W_ * H_, n2 = (size_t)(H_ / 4) * (W_ / 4), n3 = (size_t)(H_ / 2) * (W_ / 2);
        size_t fsz[3]; feature_sizes(fsz);
        auto mi = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::vector<int64_t> sh_ref{1, 3, H_, W_}, sh_pm{1, nview_, 2, 4, 4}, sh_dv{1, DENSE_NUM_DEPTH},
                             sh_n2{1, 1, H_ / 4, W_ / 4}, sh_n3{1, 1, H_ / 2, W_ / 2};
        std::vector<int64_t> sh_f[3] = {{1, 48, H_ / 8, W_ / 8}, {1, 32, H_ / 4, W_ / 4}, {1, 16, H_ / 2, W_ / 2}};
        std::vector<Ort::Value> vals; vals.reserve(impl_->rest_bind.size());
        auto push = [&](const float* p, std::vector<int64_t>& s, size_t n) {
            vals.push_back(Ort::Value::CreateTensor<float>(mi, const_cast<float*>(p), n, s.data(), s.size()));
        };
        for (const DenseRBind& b : impl_->rest_bind) {   // by NAME, in the session's own reported order
            switch (b.what) {
                case DenseRIn::Feature: {
                    const FeatureSet* fs = views[b.slot];
                    if (!fs || fs->f[b.level].size() != fsz[b.level]) { if (err) *err = "missing/short feature set for view slot " + std::to_string(b.slot); return false; }
                    push(fs->f[b.level].data(), sh_f[b.level], fsz[b.level]);
                    break;
                }
                case DenseRIn::RefImg: push(ref_img, sh_ref, (size_t)3 * HW); break;
                case DenseRIn::Pm1:    push(in.pm[0].data(), sh_pm, (size_t)nview_ * 32); break;
                case DenseRIn::Pm2:    push(in.pm[1].data(), sh_pm, (size_t)nview_ * 32); break;
                case DenseRIn::Pm3:    push(in.pm[2].data(), sh_pm, (size_t)nview_ * 32); break;
                case DenseRIn::Dv:     push(in.dv.data(), sh_dv, DENSE_NUM_DEPTH); break;
                case DenseRIn::N2:     push(noise2, sh_n2, n2); break;
                case DenseRIn::N3:     push(noise3, sh_n3, n3); break;
            }
        }
        const char* out_names[] = {"depth", "conf0", "conf1", "conf2"};
        const auto t0 = std::chrono::steady_clock::now();
        auto out = impl_->sess->Run(Ort::RunOptions{nullptr}, impl_->rest_in_ptrs.data(), vals.data(), vals.size(), out_names, 4);
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
