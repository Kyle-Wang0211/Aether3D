#include "pw_gpu_frontend.h"
#include "pw_gpufe_wgsl.h"
#include "dawn_kernel_harness.h"
#include <webgpu/webgpu_cpp.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
namespace pw::gpufe {
using aether::tools::DawnKernelHarness;
namespace {
constexpr int PAD = 21, MAXL = 3, WIN = 21;
constexpr int kMaxInflight = 1;
constexpr uint32_t kMaxCandidates = 262144;  // GFTT candidates above threshold after NMS (dark/noisy frames overflowed 65536 -> CPU fallback); more -> caller falls back to CPU
struct P { uint32_t w, h, pw, ph, w2, h2, pw2, ph2, tiles_x, tiles_y, tw, th; float inv_tw, inv_th, lut_scale; uint32_t clip, base, base2, dbase, pwq, pwq2, r0, r1, r2; };
struct GP { uint32_t width, height; float scale, k, quality; uint32_t max_corners, pwq, base; };
struct LKP { uint32_t n, levels, maxlevel, flags; uint32_t lv[4][4]; uint32_t dlv[4][4]; };
double now_ms() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
uint32_t g16(uint32_t n) { return (n + 15) / 16; }
struct FrameBuf {   // GPU-resident padded pyramid + Scharr derivatives; pooled per (W,H)
    int L = 0; uint32_t W = 0, H = 0; std::vector<P> prm; std::vector<wgpu::Buffer> b_prm; wgpu::Buffer img, der, b_prm_all; size_t n_img = 0, n_der = 0;   // n_img: words (packed u8), n_der: u32 per padded pixel
    wgpu::Buffer b_src, b_hist, b_lut, b_pack, st_pack;   // per-frame scratch (frames may be in flight concurrently)
    int mode = 0; bool want_pyr = false; wgpu::Buffer st_img; DawnKernelHarness::AsyncBatch pending_det; bool det_ready = false;   // mode 0: levels+derivatives (GPU LK), 1: level 0 only (hybrid), 2: levels, no derivatives (hybrid + GPU pyramid readback)   // hybrid: detection submitted separately (B) after CLAHE (A)
    DawnKernelHarness::AsyncBatch pending; bool want_clahe = false; bool ready = false; bool failed = false; bool counted = false; double t_submit = 0;
    bool with_detect = false; wgpu::Buffer b_cnt, b_corners, st_det; std::vector<uint8_t> cand; bool have_cand = false;   // detection fused into the frame batch
};
struct PoolState { std::mutex m; std::vector<std::unique_ptr<FrameBuf>> free; std::atomic<int>* inflight = nullptr; void inflight_release() { if (inflight) --*inflight; } };
}  // namespace
class Frame {
public:
    std::unique_ptr<FrameBuf> buf; std::weak_ptr<PoolState> pool;
    ~Frame() { if (buf && buf->pending.valid) { buf->pending.valid = false; if (buf->counted) { buf->counted = false; if (auto p = pool.lock()) p->inflight_release(); } }   // dropped before use: the queued GPU work is harmless, the buffers just go back to the pool (next preprocess overwrites them after its own submit order)
               if (auto p = pool.lock()) { std::lock_guard<std::mutex> g(p->m); if (p->free.size() < 3) p->free.push_back(std::move(buf)); } }
};
class FrontEndImpl final : public FrontEnd {
public:
    // GPU timestamps (AETHER_GPU_TIMESTAMPS=1): after each batch, per-pass GPU ns attributed to kernel names in dispatch order.
    std::map<std::string, std::pair<double, uint64_t>> kernel_ns_;
    void ts_attribute(const std::vector<const char*>& names) {
        if (!h_.gpu_ts_enabled()) return;
        std::vector<uint64_t> ns; if (!h_.gpu_ts_resolve(&ns)) { h_.gpu_ts_reset(); return; }
        for (size_t i = 0; i < ns.size() && i < names.size(); ++i) { auto& e = kernel_ns_[names[i]]; e.first += (double)ns[i]; e.second++; }
        h_.gpu_ts_reset();
    }
    std::string kernel_ms_json() const { std::string j = "{"; bool first = true; for (auto& kv : kernel_ns_) { char buf[96]; snprintf(buf, sizeof buf, "%s\"%s\":%.3f", first ? "" : ",", kv.first.c_str(), kv.second.second ? kv.second.first / kv.second.second / 1e6 : 0.0); j += buf; first = false; } return j + "}"; }
    bool init(std::string* err) {
        if (!h_.init()) { if (err) *err = "Dawn harness init failed"; return false; }
        // Strict math (Metal mathMode=safe): the kernels are bit-exact replicas; fast-math reciprocal/sqrt/reassociation
        // on the device GPU is a variable we do not want. (Contraction is still blocked by the fma(x,y,0.0) guards.)
        h_.set_strict_math(true);
        strict_ = h_.strict_math();
        auto load = [&](const char* name, const std::string& src) { auto p = h_.load_compute(src); std::string e; if (!p || DawnKernelHarness::take_device_error(&e)) { if (err) *err = std::string("shader ") + name + ": " + e; warn_ += std::string("shader ") + name + " failed: " + e.substr(0, 200) + "; "; return wgpu::ComputePipeline(); } return p; };
        const std::string gc = wgsl::k_gftt_common, lc = wgsl::k_lk_common;
        p_sobel_ = load("sobel", gc + wgsl::k_sobel_dxdy); p_harris_ = load("harris", gc + wgsl::k_harris_box); p_harris_fused_ = load("harris_fused", gc + wgsl::k_harris_fused); p_max_ = load("max", gc + wgsl::k_gftt_max); p_thr_ = load("thr", gc + wgsl::k_gftt_thr); p_find_ = load("find", gc + wgsl::k_gftt_find);
        p_hist_ = load("hist", lc + wgsl::k_clahe_hist); p_lut_ = load("lut", lc + wgsl::k_clahe_lut); p_interp_ = load("interp", lc + wgsl::k_clahe_interp); p_pad_ = load("pad", lc + wgsl::k_pad_reflect101); p_down_ = load("pyrdown", lc + wgsl::k_pyrdown); p_scharr_ = load("scharr", lc + wgsl::k_scharr); p_pack_ = load("pack", lc + wgsl::k_pack_u8); p_unpack_ = load("unpack", lc + wgsl::k_unpack_u8);
        p_lk_ = load("lk", wgsl::k_lk_track_wg); p_lk_simple_ = load("lk_simple", wgsl::k_lk_track); p_fp_ = load("fp_selfcheck", wgsl::k_fp_selfcheck);
        pool_ = std::make_shared<PoolState>(); pool_->inflight = &inflight_;
        return p_sobel_ && p_harris_ && p_harris_fused_ && p_max_ && p_thr_ && p_find_ && p_hist_ && p_lut_ && p_interp_ && p_pad_ && p_down_ && p_scharr_ && p_pack_ && p_unpack_ && p_lk_ && p_fp_;
    }
    std::shared_ptr<Frame> preprocess(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, std::vector<uint8_t>* clahe_out) override {
        auto f = preprocess_impl(gray, w, h, stride, clip_limit, tiles_x, tiles_y, clahe_out != nullptr, false); if (!f) return nullptr;
        if (!finish(*f, clahe_out)) return nullptr; return f;
    }
    std::shared_ptr<Frame> preprocess_async(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, bool want_clahe) override {
        if (inflight_.load() >= kMaxInflight) { ++declined_; return nullptr; }   // keep the tracker's batches from queueing behind prefetches
        return preprocess_impl(gray, w, h, stride, clip_limit, tiles_x, tiles_y, want_clahe, false); }
    std::shared_ptr<Frame> preprocess_preclahe(const uint8_t* g, int w, int h, int stride) override { auto f = preprocess_impl(g, w, h, stride, 6.0, 8, 8, false, true); if (!f || !finish(*f, nullptr)) return nullptr; return f; }
    // Encode + submit (no wait). Thread-safe: the harness batch state is guarded by gpu_mu_.
    std::shared_ptr<Frame> preprocess_detect(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, double quality, double harris_k, std::vector<uint8_t>* clahe_out, bool gpu_pyramid) override {
        auto f = preprocess_impl(gray, w, h, stride, clip_limit, tiles_x, tiles_y, true, false, true, quality, harris_k, gpu_pyramid); if (!f || !finish(*f, clahe_out)) return nullptr; return f; }
    std::shared_ptr<Frame> preprocess_detect_async(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, double quality, double harris_k, bool gpu_pyramid) override {
        if (inflight_.load() >= kMaxInflight) { ++declined_; return nullptr; }
        return preprocess_impl(gray, w, h, stride, clip_limit, tiles_x, tiles_y, true, false, true, quality, harris_k, gpu_pyramid);
    }
    std::shared_ptr<Frame> preprocess_impl(const uint8_t* gray, int w, int h, int stride, double clip_limit, int tiles_x, int tiles_y, bool want_clahe, bool pre_clahe, bool with_detect = false, double quality = 1e-3, double harris_k = 0.04, bool gpu_pyr = false) {
        const double t0 = now_ms();
        if (w % tiles_x || h % tiles_y) { error_ = "preprocess: image size not divisible by CLAHE tile grid (unsupported)"; return nullptr; }
        std::unique_lock<std::mutex> lk(gpu_mu_);
        ensure_pre(w, h, tiles_x, tiles_y, clip_limit);   // must precede acquire(): FrameBuf uniforms carry the CLAHE constants
        auto f = std::make_shared<Frame>(); f->pool = pool_; f->buf = acquire((uint32_t)w, (uint32_t)h, with_detect ? (gpu_pyr ? 2 : 1) : 0);
        FrameBuf& fb = *f->buf; if (!b_probe_prm_) b_probe_prm_ = fb.b_prm[0]; fb.want_pyr = with_detect && gpu_pyr;
        fb.want_clahe = want_clahe; fb.ready = false; fb.failed = false; fb.with_detect = with_detect; fb.have_cand = false; fb.det_ready = false;
        const size_t n = size_t(w) * h; const size_t n4 = (n + 3) / 4;
        auto q = h_.device().GetQueue();
        if (stride == w && (n & 3) == 0) { q.WriteBuffer(fb.b_src, 0, gray, n); }   // contiguous: upload straight from the caller's buffer, no copy
        else { thread_local std::vector<uint32_t> packed; packed.assign(n4, 0); for (int y = 0; y < h; ++y) memcpy(reinterpret_cast<uint8_t*>(packed.data()) + size_t(y) * w, gray + size_t(y) * stride, w); q.WriteBuffer(fb.b_src, 0, packed.data(), n4 * 4); }
        q.WriteBuffer(fb.b_hist, 0, zeros_.data(), zeros_.size() * 4);
        const double t1 = now_ms(); st_.pre_host_ms += t1 - t0;
        h_.begin_batch();
        if (pre_clahe) { h_.dispatch_batched(p_unpack_, {fb.b_src, fb.img, fb.b_prm[0]}, g16(fb.prm[0].pwq), g16(fb.prm[0].ph)); }
        else {
        h_.dispatch_batched(p_hist_, {fb.b_src, fb.b_hist, fb.b_prm[0]}, tiles_x, tiles_y);
        h_.dispatch_batched(p_lut_, {fb.b_hist, fb.b_lut, fb.b_prm[0]}, (uint32_t)((zeros_.size() / 256 + 63) / 64));
        h_.dispatch_batched(p_interp_, {fb.b_src, fb.b_lut, fb.img, fb.b_prm[0], b_colt_, b_rowt_}, g16(fb.prm[0].pwq), g16(fb.prm[0].ph));
        }
        if (!with_detect) {   // GPU pyramid + Scharr (GPU-LK mode)
            for (int l = 0; l + 1 < fb.L; ++l) h_.dispatch_batched(p_down_, {fb.img, fb.b_prm[l]}, g16(fb.prm[l].pwq2), g16(fb.prm[l].ph2));   // borders fused into interp/pyrdown
            h_.dispatch_batched(p_scharr_, {fb.img, fb.der, fb.b_prm_all}, g16(fb.prm[0].pw), g16(fb.prm[0].ph), (uint32_t)fb.L);   // all levels, z = level
        }
        if (fb.want_pyr) {   // hybrid + GPU pyramid: pyrDown levels (no derivatives: the CPU LK computes Scharr itself), whole packed pyramid read back
            for (int l = 0; l + 1 < fb.L; ++l) h_.dispatch_batched(p_down_, {fb.img, fb.b_prm[l]}, g16(fb.prm[l].pwq2), g16(fb.prm[l].ph2));
            h_.copy_region_batched(fb.img, 0, fb.st_img, 0, fb.n_img * 4);
        } else if (want_clahe) { h_.dispatch_batched(p_pack_, {fb.img, fb.b_pack, fb.b_prm[0]}, (uint32_t)((n4 + 255) / 256)); h_.copy_region_batched(fb.b_pack, 0, fb.st_pack, 0, n4 * 4); }
        if (with_detect) {    // batch A ends here (CLAHE); batch B = goodFeaturesToTrack candidates, waited for separately in detect()
            fb.pending = h_.end_batch_async(); fb.t_submit = now_ms(); fb.counted = true; ++inflight_;
            const uint32_t W = (uint32_t)w, H = (uint32_t)h; const P& q0 = fb.prm[0];
            const int block = 3, ksize = 3; double scale = (double)(1 << (ksize - 1)) * block * 255.0; scale = 1.0 / scale;
            ensure_detect(W, H, (float)scale, (float)harris_k, (float)quality, q0.pwq, q0.base);
            const uint32_t maxGroups = std::min<uint32_t>(1024, (W * H + 255) / 256);
            if (!fb.b_cnt) { uint32_t zu = 0; fb.b_cnt = h_.upload(&zu, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst); fb.b_corners = h_.alloc(size_t(kMaxCandidates) * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); fb.st_det = h_.alloc_staging_for_readback(256 + size_t(kMaxCandidates) * 8); }
            const uint32_t zero = 0; q.WriteBuffer(fb.b_cnt, 0, &zero, 4);
            if (quality != qsplit_q_) { qsplit_q_ = quality; float qs[4] = {(float)quality, (float)(quality - (double)(float)quality), 0, 0}; q.WriteBuffer(b_qsplit_, 0, qs, 16); }
            h_.begin_batch();
            h_.dispatch_batched(p_harris_fused_, {fb.img, b_eig_, b_gp_}, g16(W), g16(H));   // Sobel fused into Harris (no dx/dy round trip)
            h_.dispatch_batched(p_max_, {b_eig_, b_partial_, b_gp_}, maxGroups);
            h_.dispatch_batched(p_thr_, {b_partial_, b_thr_, b_qsplit_}, 1);
            h_.dispatch_batched(p_find_, {b_eig_, b_thr_, fb.b_cnt, fb.b_corners, b_gp_}, g16(W - 2), g16(H - 2));
            h_.copy_region_batched(fb.b_cnt, 0, fb.st_det, 0, 4); h_.copy_region_batched(fb.b_corners, 0, fb.st_det, 256, size_t(kMaxCandidates) * 8);
            fb.pending_det = h_.end_batch_async();
            std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { error_ = "preprocess: " + (e.empty() ? std::string("device unhealthy") : e); return nullptr; }
            st_.preprocess_ms += now_ms() - t0; ++st_.n_preprocess; return f;
        }
        fb.pending = h_.end_batch_async(); fb.t_submit = now_ms(); fb.counted = true; ++inflight_;
        std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { error_ = "preprocess: " + (e.empty() ? std::string("device unhealthy") : e); return nullptr; }
        st_.preprocess_ms += now_ms() - t0; ++st_.n_preprocess; return f;
    }
    // Block until the frame's GPU work is done (and read the CLAHE image back once, if it was requested).
    bool finish(const Frame& f, std::vector<uint8_t>* clahe_out) override {
        FrameBuf& fb = *f.buf;
        std::lock_guard<std::mutex> lk(gpu_mu_);
        if (!fb.ready && !fb.failed) {
            const double t0 = now_ms();
            if (fb.counted) { fb.counted = false; --inflight_; }
            if (!h_.wait_async(fb.pending)) { fb.failed = true; error_ = "preprocess: GPU wait failed"; return false; }
            st_.pre_wait_ms += now_ms() - t0; st_.pre_gpu_ms += now_ms() - fb.t_submit;
            if (fb.want_pyr) { const double t2 = now_ms(); fb_clahe_[&fb] = h_.readback(fb.st_img, fb.n_img * 4); st_.pre_read_ms += now_ms() - t2; }
            else if (fb.want_clahe) { const double t2 = now_ms(); const size_t n = size_t(fb.W) * fb.H; auto rb = h_.readback(fb.st_pack, ((n + 3) / 4) * 4); fb_clahe_[&fb].assign(rb.begin(), rb.begin() + n); st_.pre_read_ms += now_ms() - t2; }
            std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { fb.failed = true; error_ = "preprocess: " + (e.empty() ? std::string("device unhealthy") : e); return false; }
            fb.ready = true;
        }
        if (fb.failed) return false;
        if (clahe_out) { auto it = fb_clahe_.find(&fb); if (it != fb_clahe_.end()) { *clahe_out = it->second; fb_clahe_.erase(it); } else { error_ = "finish: CLAHE readback was not requested"; return false; } }
        return true;
    }
    // featureselect.cpp host part: sort desc (ties: later raster address first), minDistance grid, maxCorners
    bool select_candidates(const std::vector<uint8_t>& rb, uint32_t W, int max_corners, double min_distance, std::vector<Keypoint>& out) {
        uint32_t cnt; memcpy(&cnt, rb.data(), 4); if (cnt > kMaxCandidates) { error_ = "detect: candidate overflow"; return false; }
        struct C { float v; int x, y; }; std::vector<C> cs(cnt);
        for (uint32_t i = 0; i < cnt; ++i) { uint32_t vb, yx; memcpy(&vb, rb.data() + 256 + i * 8, 4); memcpy(&yx, rb.data() + 256 + i * 8 + 4, 4); float v; memcpy(&v, &vb, 4); cs[i] = {v, int(yx >> 16), int(yx & 0xffff)}; }
        std::sort(cs.begin(), cs.end(), [&](const C& a, const C& b) { if (a.v != b.v) return a.v > b.v; return (a.y * (long)W + a.x) > (b.y * (long)W + b.x); });
        if (min_distance >= 1) {
            const int cell = (int)std::lround(min_distance), gw = (W + cell - 1) / cell, gh = (grid_h_ + cell - 1) / cell; const double md2 = min_distance * min_distance;
            grid_.assign(size_t(gw) * gh, {});
            for (auto& c : cs) { bool good = true; int xc = c.x / cell, yc = c.y / cell; int x1 = std::max(0, xc - 1), y1 = std::max(0, yc - 1), x2 = std::min(gw - 1, xc + 1), y2 = std::min(gh - 1, yc + 1);
                for (int yy = y1; yy <= y2 && good; ++yy) for (int xx = x1; xx <= x2 && good; ++xx) for (auto& m : grid_[size_t(yy) * gw + xx]) { float dxx = c.x - m.first, dyy = c.y - m.second; if (dxx * dxx + dyy * dyy < md2) { good = false; break; } }
                if (good) { grid_[size_t(yc) * gw + xc].push_back({(float)c.x, (float)c.y}); out.push_back({(float)c.x, (float)c.y, c.v}); if ((int)out.size() >= max_corners) break; } }
        } else { for (auto& c : cs) { out.push_back({(float)c.x, (float)c.y, c.v}); if ((int)out.size() >= max_corners) break; } }
        return true;
    }
    bool detect(const Frame& f, int max_corners, double quality, double min_distance, double harris_k, std::vector<Keypoint>& out) override {
        if (!finish(f, nullptr)) return false;
        std::lock_guard<std::mutex> lk(gpu_mu_);
        const double t0 = now_ms(); out.clear();
        if (f.buf->with_detect) {
            FrameBuf& fb = *f.buf;
            if (!fb.det_ready) { const double tw = now_ms(); if (!h_.wait_async(fb.pending_det)) { error_ = "detect: GPU wait failed"; return false; } st_.det_gpu_ms += now_ms() - tw;
                const double t3 = now_ms(); fb.cand = h_.readback(fb.st_det, 256 + size_t(kMaxCandidates) * 8); st_.det_read_ms += now_ms() - t3; fb.det_ready = true;
                std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { error_ = "detect: " + e; return false; } }
            const double t4 = now_ms(); const bool ok = select_candidates(fb.cand, fb.W, max_corners, min_distance, out); st_.det_host_ms += now_ms() - t4; st_.detect_ms += now_ms() - t0; ++st_.n_detect; return ok; }
        const FrameBuf& fb = *f.buf; const uint32_t W = fb.W, H = fb.H; const P& q0 = fb.prm[0];
        const int block = 3, ksize = 3; double scale = (double)(1 << (ksize - 1)) * block * 255.0; scale = 1.0 / scale;   // cornerEigenValsVecs 8U scale
        ensure_detect(W, H, (float)scale, (float)harris_k, (float)quality, q0.pwq, q0.base);
        const uint32_t maxGroups = std::min<uint32_t>(1024, (W * H + 255) / 256);
        auto q = h_.device().GetQueue(); const uint32_t zero = 0;
        q.WriteBuffer(b_cnt_, 0, &zero, 4);
        if (quality != qsplit_q_) { qsplit_q_ = quality; float qs[4] = {(float)quality, (float)(quality - (double)(float)quality), 0, 0}; q.WriteBuffer(b_qsplit_, 0, qs, 16); }
        h_.begin_batch();   // ONE submission: sobel -> harris -> max partials -> threshold (GPU) -> find -> copies
        h_.dispatch_batched(p_harris_fused_, {fb.img, b_eig_, b_gp_}, g16(W), g16(H));   // Sobel fused into Harris (no dx/dy round trip)
        h_.dispatch_batched(p_max_, {b_eig_, b_partial_, b_gp_}, maxGroups);
        h_.dispatch_batched(p_thr_, {b_partial_, b_thr_, b_qsplit_}, 1);
        h_.dispatch_batched(p_find_, {b_eig_, b_thr_, b_cnt_, b_corners_, b_gp_}, g16(W - 2), g16(H - 2));
        h_.copy_region_batched(b_cnt_, 0, st_det_, 0, 4); h_.copy_region_batched(b_corners_, 0, st_det_, 256, size_t(kMaxCandidates) * 8);
        h_.end_batch(); ts_attribute({"sobel", "harris", "gftt_max", "gftt_thr", "gftt_find"});
        const double t3 = now_ms(); st_.det_gpu_ms += t3 - t0;
        auto rb = h_.readback(st_det_, 256 + size_t(kMaxCandidates) * 8);
        const double t4 = now_ms(); st_.det_read_ms += t4 - t3;
        std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { error_ = "detect: " + (e.empty() ? std::string("device unhealthy") : e); return false; }
        if (!select_candidates(rb, W, max_corners, min_distance, out)) return false;
        st_.det_host_ms += now_ms() - t4;
        st_.detect_ms += now_ms() - t0; ++st_.n_detect; return true;
    }
    bool track(const Frame& I, const Frame& J, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status) override {
        std::vector<std::array<float, 2>> rev; std::vector<uint8_t> rst; return run_lk(I, J, prev_pts, next_inout, status, nullptr, nullptr);
    }
    bool track_fwd_rev(const Frame& I, const Frame& J, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                       std::vector<std::array<float, 2>>& rev_inout, std::vector<uint8_t>& rev_status) override { return run_lk(I, J, prev_pts, next_inout, status, &rev_inout, &rev_status); }
    bool track_simple(const Frame& I, const Frame& J, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                      std::vector<std::array<float, 2>>& rev_inout, std::vector<uint8_t>& rev_status) override { return run_lk(I, J, prev_pts, next_inout, status, &rev_inout, &rev_status, 1); }
    bool track_variant(int v, const Frame& I, const Frame& J, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                       std::vector<std::array<float, 2>>& rev_inout, std::vector<uint8_t>& rev_status) override { return run_lk(I, J, prev_pts, next_inout, status, &rev_inout, &rev_status, v); }
    std::string selfcheck() override {
        std::lock_guard<std::mutex> lk(gpu_mu_);
        const int N = 1 << 14; std::vector<float> in(N * 4); uint32_t seed = 12345u;
        auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return (seed >> 8) * (1.0f / 16777216.0f); };
        for (int i = 0; i < N; ++i) { in[i * 4] = 0.5f + 1.5f * rnd(); in[i * 4 + 1] = rnd() * 2.f - 1.f; in[i * 4 + 2] = rnd() * 4.f; in[i * 4 + 3] = rnd() - 0.5f; }
        auto bi = h_.upload(in.data(), in.size() * 4, wgpu::BufferUsage::Storage); auto bo = h_.alloc(N * 56, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); auto st = h_.alloc_staging_for_readback(N * 56);
        h_.begin_batch(); h_.dispatch_batched(p_fp_, {bi, bo}, N / 64); h_.copy_region_batched(bo, 0, st, 0, N * 56); h_.end_batch(); auto rb = h_.readback(st, N * 56);
        std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) return "{\"error\":\"" + e + "\"}";
        const float* out = reinterpret_cast<const float*>(rb.data()); int bad[14] = {0}; float ex[14] = {0}, gx[14] = {0};
        for (int i = 0; i < N; ++i) { volatile float a = in[i * 4], b = in[i * 4 + 1], c = in[i * 4 + 2], d = in[i * 4 + 3];
            int ia = (int)(a * 65536.0f * 500.0f); float ab = a * b, cd = c * d, a1 = a + 1.0f, ap = a + b, apc = ap * c, da = d * a;
            float ref[14] = { 1.0f / a, std::sqrt((float)a), (float)(ia * 3 + 1), ab + cd, std::nearbyint(a * 8.0f + 0.5f), ab, ap, (ab - cd) * (1.0f / a1), std::floor(a * 1000.0f - 0.5f), a * (1.0f / 1048576.0f), (float)(-(ia * 3 + 1)), apc - da, std::sqrt((float)a), 1.0f / a1 };
            for (int k = 0; k < 14; ++k) { float g = out[i * 14 + k]; if (memcmp(&g, &ref[k], 4) != 0) { if (!bad[k]) { ex[k] = ref[k]; gx[k] = g; } ++bad[k]; } } }
        static const char* names[14] = {"div", "sqrt", "i2f", "fma0_guard", "round", "mul", "add", "lk_delta", "floor", "flt_scale", "i2f_neg", "unguarded_contract", "sqrt_rn", "div_rn"};
        std::string j = "{\"n\":" + std::to_string(N) + ",\"strict\":" + (strict_ ? "true" : "false") + ",\"shader_warnings\":\"" + warn_ + "\""; char buf[160];
        for (int k = 0; k < 14; ++k) { snprintf(buf, sizeof buf, ",\"%s\":%d", names[k], bad[k]); j += buf; if (bad[k]) { snprintf(buf, sizeof buf, ",\"%s_ex\":\"%.9g vs %.9g\"", names[k], ex[k], gx[k]); j += buf; } }
        return j + "}";
    }
    bool pyramid_layout(const Frame& f, std::vector<PyrLevel>& out) override {
        const FrameBuf& fb = *f.buf; out.resize(fb.L);
        for (int l = 0; l < fb.L; ++l) { const P& q = fb.prm[l]; out[l] = PyrLevel{(int)q.w, (int)q.h, (int)q.pw, (int)q.ph, (int)q.pwq, (int)q.base}; }
        return fb.L > 0;
    }
    bool dump_pyramid(const Frame& f, std::vector<std::vector<uint8_t>>& levels, std::vector<std::vector<int16_t>>& derivs) override {
        if (!finish(f, nullptr)) return false; std::lock_guard<std::mutex> lk(gpu_mu_);
        const FrameBuf& fb = *f.buf; auto st_i = h_.alloc_staging_for_readback(fb.n_img * 4), st_d = h_.alloc_staging_for_readback(fb.n_der * 4);
        h_.copy_to_staging(fb.img, st_i, fb.n_img * 4); auto gi = h_.readback(st_i, fb.n_img * 4);
        h_.copy_to_staging(fb.der, st_d, fb.n_der * 4); auto gd = h_.readback(st_d, fb.n_der * 4);
        std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { error_ = "dump_pyramid: " + e; return false; }
        levels.assign(fb.L, {}); derivs.assign(fb.L, {});
        for (int l = 0; l < fb.L; ++l) { const P& q = fb.prm[l]; const size_t n = size_t(q.pw) * q.ph; levels[l].resize(n); derivs[l].resize(n * 2);
            for (uint32_t y = 0; y < q.ph; ++y) for (uint32_t x = 0; x < q.pw; ++x) { uint32_t wv; memcpy(&wv, gi.data() + (q.base + y * q.pwq + (x >> 2)) * 4, 4); levels[l][size_t(y) * q.pw + x] = (uint8_t)(wv >> ((x & 3) * 8)); }
            for (size_t i = 0; i < n; ++i) { uint32_t v; memcpy(&v, gd.data() + (q.dbase + i) * 4, 4); derivs[l][i * 2] = (int16_t)(v & 0xffff); derivs[l][i * 2 + 1] = (int16_t)(v >> 16); } }
        return true;
    }
    std::shared_ptr<Frame> upload_pyramid(int w, int h, const std::vector<std::vector<uint8_t>>& levels, const std::vector<std::vector<int16_t>>& derivs) override {
        std::lock_guard<std::mutex> lk(gpu_mu_); ensure_pre(w, h, 8, 8, 6.0);
        auto f = std::make_shared<Frame>(); f->pool = pool_; f->buf = acquire((uint32_t)w, (uint32_t)h); FrameBuf& fb = *f->buf;
        if ((int)levels.size() != fb.L) { error_ = "upload_pyramid: level count mismatch"; return nullptr; }
        std::vector<uint32_t> img(fb.n_img, 0), der(fb.n_der, 0);
        for (int l = 0; l < fb.L; ++l) { const P& q = fb.prm[l]; const size_t n = size_t(q.pw) * q.ph; if (levels[l].size() != n || derivs[l].size() != n * 2) { error_ = "upload_pyramid: size mismatch"; return nullptr; }
            for (uint32_t y = 0; y < q.ph; ++y) for (uint32_t x = 0; x < q.pw; ++x) img[q.base + y * q.pwq + (x >> 2)] |= uint32_t(levels[l][size_t(y) * q.pw + x]) << ((x & 3) * 8);
            for (size_t i = 0; i < n; ++i) der[q.dbase + i] = (uint32_t(uint16_t(derivs[l][i * 2]))) | (uint32_t(uint16_t(derivs[l][i * 2 + 1])) << 16); }
        auto qu = h_.device().GetQueue(); qu.WriteBuffer(fb.img, 0, img.data(), img.size() * 4); qu.WriteBuffer(fb.der, 0, der.data(), der.size() * 4);
        fb.ready = true; fb.failed = false; return f;
    }
    std::string kernel_times() override { return kernel_ms_json(); }
    double probe_latency() override {
        if (!b_cnt_) return -1;   // needs the detect buffers (any tiny storage buffer will do)
        if (!b_probe_hist_) { b_probe_hist_ = h_.alloc(zeros_.size() * 4, wgpu::BufferUsage::Storage); b_probe_lut_ = h_.alloc(zeros_.size() * 4, wgpu::BufferUsage::Storage); }
        std::lock_guard<std::mutex> lk(gpu_mu_); const double t0 = now_ms(); h_.begin_batch(); h_.dispatch_batched(p_lut_, {b_probe_hist_, b_probe_lut_, b_probe_prm_}, 1); h_.end_batch();
        return now_ms() - t0;
    }
    bool healthy() const override { return h_.healthy(); }
    std::string take_error() override { std::string e; e.swap(error_); return e; }
    Stats stats() const override { Stats s = st_; s.prefetch_declined = declined_.load(); return s; }
private:
    std::unique_ptr<FrameBuf> acquire(uint32_t W, uint32_t H, int mode = 0) {
        { std::lock_guard<std::mutex> g(pool_->m); for (auto it = pool_->free.begin(); it != pool_->free.end(); ++it) if ((*it)->W == W && (*it)->H == H && (*it)->mode == mode) { auto b = std::move(*it); pool_->free.erase(it); return b; } }
        auto fb = std::make_unique<FrameBuf>(); fb->W = W; fb->H = H; fb->mode = mode; const bool slim = mode == 1;
        std::vector<uint32_t> lw{W}, lh{H};
        for (int l = 1; l <= (slim ? 0 : MAXL); ++l) { uint32_t nw = (lw.back() + 1) / 2, nh = (lh.back() + 1) / 2; if (nw <= WIN || nh <= WIN) break; lw.push_back(nw); lh.push_back(nh); }
        fb->L = (int)lw.size(); fb->prm.resize(fb->L); uint32_t base = 0, dbase = 0;
        for (int l = 0; l < fb->L; ++l) {
            P& q = fb->prm[l]; q = P{}; q.w = lw[l]; q.h = lh[l]; q.pw = lw[l] + 2 * PAD; q.ph = lh[l] + 2 * PAD; q.pwq = (q.pw + 3) / 4; q.base = base; q.dbase = dbase; base += q.pwq * q.ph; dbase += q.pw * q.ph;
            if (l + 1 < fb->L) { q.w2 = lw[l + 1]; q.h2 = lh[l + 1]; q.pw2 = lw[l + 1] + 2 * PAD; q.ph2 = lh[l + 1] + 2 * PAD; q.pwq2 = (q.pw2 + 3) / 4; q.base2 = base; }
            q.tiles_x = tiles_x_; q.tiles_y = tiles_y_; q.tw = tw_; q.th = th_; q.inv_tw = 1.0f / (float)tw_; q.inv_th = 1.0f / (float)th_; q.lut_scale = lut_scale_; q.clip = clip_;
        }
        fb->n_img = base; fb->n_der = dbase;
        fb->img = h_.alloc(fb->n_img * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
        if (mode == 2) fb->st_img = h_.alloc_staging_for_readback(fb->n_img * 4);
        if (mode == 0) fb->der = h_.alloc(fb->n_der * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
        for (int l = 0; l < fb->L; ++l) fb->b_prm.push_back(h_.upload(&fb->prm[l], sizeof(P), wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst));
        { const size_t n4 = (size_t(W) * H + 3) / 4; fb->b_src = h_.alloc(n4 * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
          fb->b_hist = h_.alloc(zeros_.size() * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst); fb->b_lut = h_.alloc(zeros_.size() * 4, wgpu::BufferUsage::Storage);
          fb->b_pack = h_.alloc(n4 * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); fb->st_pack = h_.alloc_staging_for_readback(n4 * 4); }
        { P all[4] = {}; for (int l = 0; l < fb->L && l < 4; ++l) all[l] = fb->prm[l]; fb->b_prm_all = h_.upload(all, sizeof all, wgpu::BufferUsage::Uniform); }
        return fb;
    }
    void ensure_pre(int w, int h, int tiles_x, int tiles_y, double clip_limit) {
        // CLAHE_Impl::apply constants + CLAHE_Interpolation_Body tables (float, no contraction: this TU is -ffp-contract=off)
        const uint32_t tw = w / tiles_x, th = h / tiles_y, tileTotal = tw * th; const float lutScale = (float)(256 - 1) / (float)tileTotal;
        int clip = 0; if (clip_limit > 0.0) { clip = (int)(clip_limit * tileTotal / 256); clip = std::max(clip, 1); }
        if (pre_w_ == (uint32_t)w && pre_h_ == (uint32_t)h && tiles_x_ == (uint32_t)tiles_x && tiles_y_ == (uint32_t)tiles_y && clip_ == (uint32_t)clip) return;
        pre_w_ = w; pre_h_ = h; tiles_x_ = tiles_x; tiles_y_ = tiles_y; tw_ = tw; th_ = th; lut_scale_ = lutScale; clip_ = clip;
        { std::lock_guard<std::mutex> g(pool_->m); pool_->free.clear(); }   // geometry/params changed: drop pooled frames (their uniforms are stale)
        zeros_.assign(size_t(tiles_x) * tiles_y * 256, 0);
        std::vector<float> colt(size_t(w) * 4), rowt(size_t(h) * 4);
        { const float inv_tw = 1.0f / tw; for (int x = 0; x < w; ++x) { float txf = x * inv_tw - 0.5f; int tx1 = (int)std::floor(txf); int tx2 = tx1 + 1; float xa = txf - tx1, xa1 = 1.0f - xa; tx1 = std::max(tx1, 0); tx2 = std::min(tx2, tiles_x - 1); colt[x * 4] = (float)(tx1 * 256); colt[x * 4 + 1] = (float)(tx2 * 256); colt[x * 4 + 2] = xa; colt[x * 4 + 3] = xa1; } }
        { const float inv_th = 1.0f / th; for (int y = 0; y < h; ++y) { float tyf = y * inv_th - 0.5f; int ty1 = (int)std::floor(tyf); int ty2 = ty1 + 1; float ya = tyf - ty1, ya1 = 1.0f - ya; ty1 = std::max(ty1, 0); ty2 = std::min(ty2, tiles_y - 1); rowt[y * 4] = (float)(ty1 * tiles_x * 256); rowt[y * 4 + 1] = (float)(ty2 * tiles_x * 256); rowt[y * 4 + 2] = ya; rowt[y * 4 + 3] = ya1; } }
        b_colt_ = h_.upload(colt.data(), colt.size() * 4, wgpu::BufferUsage::Storage); b_rowt_ = h_.upload(rowt.data(), rowt.size() * 4, wgpu::BufferUsage::Storage);
    }
    void ensure_detect(uint32_t W, uint32_t H, float scale, float k, float quality, uint32_t pwq, uint32_t base) {
        GP gp{W, H, scale, k, quality, kMaxCandidates, pwq, base};
        if (memcmp(&gp, &gp_, sizeof gp) == 0 && b_eig_) return;
        gp_ = gp; grid_h_ = H; b_gp_ = h_.upload(&gp, sizeof gp, wgpu::BufferUsage::Uniform);
        const size_t n = size_t(W) * H;
        b_dx_ = h_.alloc(n * 4, wgpu::BufferUsage::Storage); b_dy_ = h_.alloc(n * 4, wgpu::BufferUsage::Storage); b_eig_ = h_.alloc(n * 4, wgpu::BufferUsage::Storage);
        const uint32_t maxGroups = std::min<uint32_t>(1024, (W * H + 255) / 256);
        b_partial_ = h_.alloc(maxGroups * 4, wgpu::BufferUsage::Storage);
        float z = 0; uint32_t zu = 0;
        b_thr_ = h_.upload(&z, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst); { float qs[4] = {0, 0, 0, 0}; b_qsplit_ = h_.upload(qs, 16, wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst); qsplit_q_ = -1; } b_cnt_ = h_.upload(&zu, 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc | wgpu::BufferUsage::CopyDst);
        b_corners_ = h_.alloc(size_t(kMaxCandidates) * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        st_det_ = h_.alloc_staging_for_readback(256 + size_t(kMaxCandidates) * 8);
    }
    void ensure_lk(size_t n) {
        if (n <= lk_cap_) return; lk_cap_ = std::max<size_t>(n, 256);
        b_q_ = h_.alloc(sizeof(LKP), wgpu::BufferUsage::Uniform | wgpu::BufferUsage::CopyDst);
        b_prev_ = h_.alloc(lk_cap_ * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst);
        b_next_ = h_.alloc(lk_cap_ * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst | wgpu::BufferUsage::CopySrc);
        b_rev_ = h_.alloc(lk_cap_ * 8, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopyDst | wgpu::BufferUsage::CopySrc);
        b_st_ = h_.alloc(lk_cap_ * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc); b_rst_ = h_.alloc(lk_cap_ * 4, wgpu::BufferUsage::Storage | wgpu::BufferUsage::CopySrc);
        st_lk_ = h_.alloc_staging_for_readback(lk_cap_ * 24);
    }
    bool run_lk(const Frame& I, const Frame& J, const std::vector<std::array<float, 2>>& prev_pts, std::vector<std::array<float, 2>>& next_inout, std::vector<uint8_t>& status,
                std::vector<std::array<float, 2>>* rev_inout, std::vector<uint8_t>* rev_status, int variant = 0) {
        if (!finish(I, nullptr) || !finish(J, nullptr)) return false;
        std::lock_guard<std::mutex> lk(gpu_mu_);
        const double t0 = now_ms(); const size_t n = prev_pts.size(); status.assign(n, 0); if (rev_status) rev_status->assign(n, 0); if (n == 0) return true;
        if (next_inout.size() != n || (rev_inout && rev_inout->size() != n)) { error_ = "track: point vector sizes differ"; return false; }
        const FrameBuf& fi = *I.buf; const FrameBuf& fj = *J.buf;
        ensure_lk(n);
        LKP q{}; q.n = (uint32_t)n; q.levels = fi.L; q.maxlevel = std::min(fi.L, fj.L) - 1; q.flags = 0;
        for (int l = 0; l < fi.L; ++l) { q.lv[l][0] = fi.prm[l].w; q.lv[l][1] = fi.prm[l].h; q.lv[l][2] = fi.prm[l].pwq; q.lv[l][3] = fi.prm[l].base; q.dlv[l][0] = fi.prm[l].w; q.dlv[l][1] = fi.prm[l].h; q.dlv[l][2] = fi.prm[l].pw; q.dlv[l][3] = fi.prm[l].dbase; }
        auto qu = h_.device().GetQueue();
        qu.WriteBuffer(b_q_, 0, &q, sizeof q); qu.WriteBuffer(b_prev_, 0, prev_pts.data(), n * 8); qu.WriteBuffer(b_next_, 0, next_inout.data(), n * 8);
        if (rev_inout) qu.WriteBuffer(b_rev_, 0, rev_inout->data(), n * 8);
        const double t1 = now_ms(); st_.trk_host_ms += t1 - t0;
        h_.begin_batch();
        const wgpu::ComputePipeline* pipes[2] = {&p_lk_, &p_lk_simple_}; const auto& pipe = *pipes[variant < 2 ? variant : 0]; if (!pipe) { error_ = "track: kernel variant " + std::to_string(variant) + " unavailable"; return false; } const uint32_t groups = variant == 1 ? (uint32_t)((n + 31) / 32) : (uint32_t)n;
        h_.dispatch_batched(pipe, {fi.img, fj.img, fi.der, b_prev_, b_next_, b_st_, b_q_}, groups);
        if (rev_inout) h_.dispatch_batched(pipe, {fj.img, fi.img, fj.der, b_next_, b_rev_, b_rst_, b_q_}, groups);   // reverse: prev = forward result (as XRSLAM passes next_cvpoints)
        h_.copy_region_batched(b_next_, 0, st_lk_, 0, n * 8); h_.copy_region_batched(b_st_, 0, st_lk_, n * 8, n * 4);
        if (rev_inout) { h_.copy_region_batched(b_rev_, 0, st_lk_, n * 12, n * 8); h_.copy_region_batched(b_rst_, 0, st_lk_, n * 20, n * 4); }
        h_.end_batch(); ts_attribute({"lk_fwd", "lk_rev"});
        const double t2 = now_ms(); st_.trk_gpu_ms += t2 - t1;
        auto rb = h_.readback(st_lk_, n * 24);
        st_.trk_read_ms += now_ms() - t2;
        std::string e; if (!h_.healthy() || DawnKernelHarness::take_device_error(&e)) { error_ = "track: " + (e.empty() ? std::string("device unhealthy") : e); return false; }
        memcpy(next_inout.data(), rb.data(), n * 8); for (size_t i = 0; i < n; ++i) { uint32_t s; memcpy(&s, rb.data() + n * 8 + i * 4, 4); status[i] = s ? 1 : 0; }
        if (rev_inout) { memcpy(rev_inout->data(), rb.data() + n * 12, n * 8); for (size_t i = 0; i < n; ++i) { uint32_t s; memcpy(&s, rb.data() + n * 20 + i * 4, 4); (*rev_status)[i] = s ? 1 : 0; } }
        st_.track_ms += now_ms() - t0; ++st_.n_track; return true;
    }
    DawnKernelHarness h_;
    std::shared_ptr<PoolState> pool_;
    wgpu::ComputePipeline p_sobel_, p_harris_, p_harris_fused_, p_max_, p_thr_, p_find_, p_hist_, p_lut_, p_interp_, p_pad_, p_down_, p_scharr_, p_pack_, p_unpack_, p_lk_, p_lk_simple_, p_fp_;
    // preprocess scratch
    uint32_t pre_w_ = 0, pre_h_ = 0, tiles_x_ = 0, tiles_y_ = 0, tw_ = 0, th_ = 0, clip_ = 0; float lut_scale_ = 0;
    wgpu::Buffer b_colt_, b_rowt_, b_probe_prm_, b_probe_hist_, b_probe_lut_; std::mutex gpu_mu_; std::map<const FrameBuf*, std::vector<uint8_t>> fb_clahe_; std::vector<uint32_t> zeros_;
    // detect scratch
    GP gp_{}; uint32_t grid_h_ = 0; wgpu::Buffer b_gp_, b_dx_, b_dy_, b_eig_, b_partial_, b_thr_, b_qsplit_, b_cnt_, b_corners_, st_det_; double qsplit_q_ = -1; std::vector<std::vector<std::pair<float, float>>> grid_;
    // lk scratch
    size_t lk_cap_ = 0; wgpu::Buffer b_q_, b_prev_, b_next_, b_rev_, b_st_, b_rst_, st_lk_;
    std::string error_, warn_; Stats st_; bool strict_ = false; std::atomic<int> inflight_{0}; std::atomic<uint64_t> declined_{0};
};
std::unique_ptr<FrontEnd> FrontEnd::create(std::string* error) { auto p = std::make_unique<FrontEndImpl>(); if (!p->init(error)) return nullptr; return p; }
}  // namespace pw::gpufe
