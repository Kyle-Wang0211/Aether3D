// dense_pipeline.cc — see dense_pipeline.h.
#include "dense_pipeline.h"

#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <set>
#include <thread>

#include "dense_images.h"
#include "dense_inputs.h"
#include "dense_runner.h"

namespace aether::dense {

namespace {
using clk = std::chrono::steady_clock;
double ms_since(clk::time_point t) { return std::chrono::duration<double, std::milli>(clk::now() - t).count(); }

bool write_rows(const std::string& path, const void* data, size_t bytes, long offset) {
    FILE* f = std::fopen(path.c_str(), "r+b"); if (!f) return false;
    std::fseek(f, offset, SEEK_SET); const bool ok = std::fwrite(data, 1, bytes, f) == bytes; std::fclose(f); return ok;
}
// One reference frame's bookkeeping while its points sit in a spill file: enough to rebuild FusePackStats in
// frame order no matter which order the frames were fused in.
struct RefRecord { bool done = false; uint64_t hs[5] = {0, 0, 0, 0, 0}; uint64_t digest = 0; double ph = 0, ge = 0, fi = 0; size_t n = 0; };

bool create_zero_file(const std::string& path, size_t bytes) {
    FILE* f = std::fopen(path.c_str(), "wb"); if (!f) return false;
    const bool ok = bytes == 0 || (std::fseek(f, (long)bytes - 1, SEEK_SET) == 0 && std::fputc(0, f) != EOF);
    std::fclose(f); return ok;
}

// [2026-09-16 dense-lossless-speedup-v1, A1-A4] Scheduling only. Not one arithmetic operation moved or changed:
// every buffer below is filled by exactly the same calls in exactly the same order as before — only earlier in
// time, or on a different thread. The three overlaps are
//   A2 decode pool      : the imgs set is decoded by several threads (one independent decoder per image),
//   A3 session overlap  : DenseRunner::init runs on its own thread while the decode pool works,
//   A1 fusion worker    : one worker fuses + spills reference frames released by FuseScheduler, and
//   A4 imgbuf prefetch  : one helper fills the NEXT view's imgbuf/FrameInputs/noise during run.run().
// Invariants that are NOT negotiable and are enforced structurally below:
//   * DenseRunner::run is only ever called on the thread that called dense_run (ORT issue #31627: concurrent
//     WebGPU Run() crashes), and the session is created/released on the calling thread's timeline.
//   * `progress` and `chunk` are only ever called on the thread that called dense_run (the Dart side binds
//     them with NativeCallable.isolateLocal, which crashes when called from any other thread).
//   * the PLY is still assembled from the spill files in FRAME order, so out_ply is byte-identical.
//
// Thread counts come from std::thread::hardware_concurrency(), capped by MEMORY rather than by a guessed
// "good" number: a decode worker holds one FULL-RESOLUTION RGB image (a 12 MP phone photo is 36 MB) plus its
// 768x576 resize while the ~1.3 GB ORT session is being built next to it, so four in flight (~150 MB) is the
// ceiling the phone's jetsam budget allows. The fusion worker and the imgbuf prefetch are one thread each by
// construction (a single serial queue / a single next-view slot) and need no count at all.
constexpr unsigned kDecodeThreadCap = 4;
// [bench ablation, 2026-09-16] Two environment switches, read ONLY to attribute wall-clock on the device bench;
// unset (production) = the full pipeline. They change scheduling, never bytes:
//   PWDENSE_PIPE_NO_PREFETCH=1  fill the next view's imgbuf inline on the calling thread (A4 off)
//   PWDENSE_PIPE_SYNC_FUSE=1    wait for the fusion worker after every view (fusion no longer overlaps, A1 off)
//   PWDENSE_PIPE_SYNC_ORT=1     build the ORT session inline before the decode (A3 off; also puts the session's
//                               own threads back on the calling thread's QoS lineage)
bool env_flag(const char* k) { const char* v = std::getenv(k); return v && v[0] == '1' && v[1] == 0; }
unsigned decode_threads(size_t n_images) {
    const unsigned hw = std::thread::hardware_concurrency();
    unsigned n = hw ? hw : 1u;
    if (n > kDecodeThreadCap) n = kDecodeThreadCap;
    if (n_images && (size_t)n > n_images) n = (unsigned)n_images;
    return n ? n : 1u;
}

// One view slot of the model's `imgs` tensor: the fp16 grey bank entry converted to fp32 and replicated to three
// channels (bench_main.cc). Used by BOTH the fused path's imgbuf and the split path's per-image F input and its
// reference image, so the bytes the model sees are produced by exactly one piece of code.
void bank_to_img3(const std::vector<uint16_t>& g, size_t N, float* dst) {
    for (size_t i = 0; i < N; ++i) { const float fv = fp16_to_fp32(g[i]); for (int c = 0; c < 3; ++c) dst[(size_t)c * N + i] = fv; }
}

// Joins a std::thread on every exit path, error returns included, so no worker ever outlives dense_run.
struct Joiner {
    std::thread& t;
    explicit Joiner(std::thread& th) : t(th) {}
    Joiner(const Joiner&) = delete; Joiner& operator=(const Joiner&) = delete;
    ~Joiner() { if (t.joinable()) t.join(); }
};

// A1: the calling thread hands "this reference frame is fusable now" to one worker and gets back everything
// the old `drain` lambda computed; the worker never touches FuseScheduler, chunk or progress.
struct FuseOut { int frame = -1; FuseFrameResult fr; };
struct FuseQ {
    std::mutex m;
    std::condition_variable cv_task, cv_res;
    std::deque<int> tasks;
    std::deque<FuseOut> res;
    bool closed = false;   // no more tasks will be pushed
    bool done = false;     // the worker has exited
    bool stop = false;     // cancel / teardown
    int rc = 0;            // 2 pack or spill error, 4 fusion error (same codes the old drain returned)
    std::string err;
    double busy_ms = 0;    // worker busy time -> DenseStats::fuse_ms
};
// Stops and joins the fusion worker on every exit path. It must SET stop before joining: the worker may be
// blocked waiting for a delivery slot, and a plain join() would then deadlock.
struct FuseStopper {
    FuseQ& q; std::thread& t;
    FuseStopper(FuseQ& qq, std::thread& th) : q(qq), t(th) {}
    FuseStopper(const FuseStopper&) = delete; FuseStopper& operator=(const FuseStopper&) = delete;
    ~FuseStopper() {
        if (!t.joinable()) return;
        { std::lock_guard<std::mutex> lk(q.m); q.stop = true; q.closed = true; }
        q.cv_task.notify_all(); t.join();
    }
};
}  // namespace

int dense_run(const DenseJob& job, dense_progress_fn progress, dense_chunk_fn chunk, void* user, DenseStats* st) {
    DenseStats scratch; DenseStats& S = st ? *st : scratch;
    if (job.frames.empty() || job.jpeg_paths.size() != job.frames.size() || job.points.size() % 3) { S.error = "bad job inputs"; return 2; }
    const int W = job.session.W, H = job.session.H, NS = job.session.nsrc, NV = NS + 1;
    const size_t N = (size_t)W * H, n2 = (size_t)(H / 4) * (W / 4), n3 = (size_t)(H / 2) * (W / 2);
    const long NP = (long)(job.points.size() / 3);

    // 1. session table on all frames; with a selection box, keep the frames that see the box and rebuild the
    //    table on that subset (the recipe itself is unchanged: view selection + depth range over the subset).
    auto t = clk::now();
    if (progress && progress("session", 0, 1, user)) return 1;
    std::vector<SessionFrame> frames = job.frames; std::vector<std::string> jpegs = job.jpeg_paths;
    std::vector<int> orig(frames.size()); for (size_t i = 0; i < orig.size(); ++i) orig[i] = (int)i;   // subset index -> job index
    SessionTable tab; build_session_table(frames, job.points, job.session, tab);
    S.NF = (int)job.frames.size(); S.frames_selected = S.NF;
    BoxFilter box{}; const BoxFilter* boxp = nullptr;
    if (job.has_box) {
        for (int k = 0; k < 3; ++k) { box.c[k] = job.box_c[k]; box.s[k] = job.box_s[k]; }
        for (int k = 0; k < 9; ++k) box.rot[k] = job.box_rot[k];
        boxp = &box;
        std::vector<uint8_t> inside(NP, 0);
        for (long n = 0; n < NP; ++n) inside[n] = box.contains(job.points[n * 3], job.points[n * 3 + 1], job.points[n * 3 + 2]);
        std::vector<int> keep;
        for (int i = 0; i < tab.NF; ++i) {
            const uint8_t* v = &tab.vis[(size_t)i * NP];
            for (long n = 0; n < NP; ++n) if (v[n] && inside[n]) { keep.push_back(i); break; }
        }
        if ((int)keep.size() >= NV) {
            std::vector<SessionFrame> f2; std::vector<std::string> j2; std::vector<int> o2;
            for (int i : keep) { f2.push_back(frames[i]); j2.push_back(jpegs[i]); o2.push_back(orig[i]); }
            frames.swap(f2); jpegs.swap(j2); orig.swap(o2);
            SessionTable t2; build_session_table(frames, job.points, job.session, t2); tab = std::move(t2);
        } else {
            S.box_fallback = true;   // too few frames see the box for a 1+nsrc tuple: run the whole set, still crop the output
        }
        S.frames_selected = (int)frames.size();
    }
    const int NF = (int)frames.size();
    S.session_ms = ms_since(t);
    if (progress && progress("session", 1, 1, user)) return 1;

    // which views: refs = [ref_begin, ref_end] within the (possibly subset) frame list; infer_set = refs ∪ nb(refs);
    // image_set = infer_set ∪ nb(infer_set)
    const int r0 = job.ref_begin, r1 = job.ref_end < 0 ? NF - 1 : std::min(job.ref_end, NF - 1);
    if (r0 < 0 || r0 > r1) { S.error = "bad ref range"; return 2; }
    std::set<int> infer, imgs;
    for (int f = r0; f <= r1; ++f) { infer.insert(f); for (int j = 0; j < NS; ++j) infer.insert(tab.neighbors[(size_t)f * NS + j]); }
    for (int v : infer) { imgs.insert(v); for (int j = 0; j < NS; ++j) imgs.insert(tab.neighbors[(size_t)v * NS + j]); }

    // [A3] The ORT session is ~1.3 GB of graph work that needs none of the photos, so it is built on its own
    // thread while the decode pool below runs. It is joined before the inference loop and every failure is
    // handled there exactly as it was when init() ran inline (return 3 with the same message).
    //
    // [2026-09-16 feature reuse] With feat_model_path/rest_model_path set the same graph is opened as two
    // sessions instead of one; everything else about this stage (thread, timing, error code) is unchanged.
    const bool split_mode = !job.feat_model_path.empty() && !job.rest_model_path.empty();
    DenseRunner run;
    bool ort_ok = false; std::string ort_err;
    auto ort_init = [&] {
        ort_ok = split_mode ? run.init_split(job.feat_model_path, job.rest_model_path, job.webgpu, W, H, NV, &ort_err, &S.ort_session_ms)
                            : run.init(job.model_path, job.webgpu, W, H, NV, &ort_err, &S.ort_session_ms);
    };
    std::thread ort_thread;
    if (env_flag("PWDENSE_PIPE_SYNC_ORT")) ort_init();   // ablation: A3 off, inline like before
    else ort_thread = std::thread(ort_init);
    Joiner ort_join(ort_thread);
    bool ort_joined = false;
    auto ensure_ort = [&]() -> bool {   // idempotent; the session must exist before the features phase
        if (!ort_joined) { if (ort_thread.joinable()) ort_thread.join(); ort_joined = true; }
        return ort_ok;
    };

    // 2. images: grey f16 bank for image_set, RGB kept for the pack (colours of inferred views)
    //    [A2] Images are independent (libjpeg-turbo doc/libjpeg.txt:244-247 allows any number of concurrent
    //    decompressors), so the SAME per-image chain — load_frame_rgb -> pil_resize_bilinear_rgb ->
    //    pil_rgb_to_l -> gray_to_f16 — runs on a small pool. Each image writes its own bank[v]/rgb[v] slot,
    //    which is why the f16 bank is byte-identical whatever order they finish in.
    t = clk::now();
    std::vector<std::vector<uint16_t>> bank(NF);
    std::vector<std::vector<uint8_t>> rgb(NF);
    const std::vector<int> img_list(imgs.begin(), imgs.end());
    {
        const unsigned nthr = decode_threads(img_list.size());
        S.image_threads = (int)nthr;
        std::mutex mu; std::condition_variable cv;
        size_t next = 0; int ndone = 0; bool failed = false, stop = false; std::string ferr;
        auto worker = [&] {
            for (;;) {
                size_t i;
                { std::lock_guard<std::mutex> lk(mu); if (stop || failed || next >= img_list.size()) return; i = next++; }
                const int v = img_list[i];
                FrameSource fs;
                if (!job.sources.empty()) fs = job.sources[(size_t)orig[v]];
                else { fs.kind = FrameSourceKind::Jpeg; fs.path = jpegs[v]; }
                RgbImage src, rs; std::vector<uint8_t> gray; std::string e;
                if (!load_frame_rgb(fs, src, &e)) {
                    { std::lock_guard<std::mutex> lk(mu); if (!failed) { failed = true; ferr = e; } }
                    cv.notify_all(); return;
                }
                pil_resize_bilinear_rgb(src, W, H, rs);
                pil_rgb_to_l(rs, gray); gray_to_f16(gray, bank[v]);
                if (infer.count(v)) rgb[v] = std::move(rs.rgb);
                { std::lock_guard<std::mutex> lk(mu); ++ndone; }
                cv.notify_all();
            }
        };
        std::vector<std::thread> pool; pool.reserve(nthr);
        for (unsigned k = 0; k < nthr; ++k) pool.emplace_back(worker);
        int rc = 0, reported = -1;
        {   // progress is reported from the CALLING thread as results land; the workers only bump a counter
            std::unique_lock<std::mutex> lk(mu);
            for (;;) {
                if (failed) { rc = 2; break; }
                if (ndone != reported) {
                    reported = ndone; const int d = reported;
                    lk.unlock();
                    const int cancel = progress ? progress("images", d, (int)img_list.size(), user) : 0;
                    lk.lock();
                    if (cancel) { rc = 1; stop = true; break; }
                    continue;
                }
                if (ndone >= (int)img_list.size()) break;
                cv.wait(lk);
            }
        }
        cv.notify_all();
        for (auto& th : pool) th.join();
        if (rc == 1) return 1;
        if (rc == 2) { S.error = ferr.empty() ? std::string("image decode failed") : ferr; return 2; }
    }
    S.images = (int)img_list.size(); S.images_ms = ms_since(t);

    // 2b. [2026-09-16 feature reuse, split mode only] FeatureNet ONCE per image.
    //     The fused graph carries ten copies of the FeatureNet and therefore recomputes every image's features
    //     once per (reference, source) use — on the 21-photo production job that is ~10x per image (§7.1 of the
    //     survey: 565 ms of the 2005 ms per view). Here each image in `imgs` goes through the F session exactly
    //     once and its three maps are cached; the R session then consumes the cached maps in the SAME view order
    //     the fused `imgs` tensor had. Prior art: hloc (cvg, Apache-2.0) extract_features -> h5 -> every pair
    //     reads it back; FADEC (arXiv:2212.00357 §II-B2) keyframe feature buffer.
    //     Run serially on the CALLING thread: the GPU is serial anyway and ORT issue #31627 forbids concurrent
    //     WebGPU Run(); progress is therefore reported from the calling thread like every other phase.
    //     MEMORY: the cache is one FeatureSet per IMAGE = 12.5 MB ([1,48,72,96] 1.33 + [1,32,144,192] 3.54 +
    //     [1,16,288,384] 7.08). 47 images on the host gate bundle = 588 MB; 21 images in production = 262 MB,
    //     next to the ~1.3 GB session (iPhone 14 Pro Max foreground jetsam ~3063 MB, survey §7.2). It is freed
    //     the moment inference ends, before the fusion-only tail.
    std::vector<FeatureSet> feat;
    if (split_mode) {
        if (!ensure_ort()) { S.error = "ort init: " + ort_err; return 3; }
        t = clk::now();
        feat.resize(NF);
        std::vector<float> img3((size_t)3 * N);
        std::string ferr;
        for (size_t i = 0; i < img_list.size(); ++i) {
            if (progress && progress("features", (int)i, (int)img_list.size(), user)) return 1;
            const int v = img_list[i];
            bank_to_img3(bank[v], N, img3.data());
            double dt = 0;
            if (!run.run_features(img3.data(), feat[v], &dt, &ferr)) { S.error = "ort features: " + ferr; return 3; }
            (void)dt;
        }
        S.feat_count = (int)img_list.size();
        S.feat_ms_total = ms_since(t);
        if (progress && progress("features", (int)img_list.size(), (int)img_list.size(), user)) return 1;
    }

    // 3. pack on disk: local index = refs first (0..nref-1), then the other inferred views
    mkdir(job.work_dir.c_str(), 0755);
    std::vector<int> local; for (int f = r0; f <= r1; ++f) local.push_back(f);
    for (int v : infer) if (v < r0 || v > r1) local.push_back(v);
    std::vector<int> lidx(NF, -1); for (size_t i = 0; i < local.size(); ++i) lidx[local[i]] = (int)i;
    const int NL = (int)local.size();
    const std::string pack = job.work_dir;
    for (const char* nm : {"depth.f32", "conf0.f32", "conf1.f32", "conf2.f32"}) if (!create_zero_file(pack + "/" + nm, (size_t)NL * N * 4)) { S.error = "cannot create pack"; return 2; }
    {
        std::vector<uint8_t> rgbpack((size_t)NL * N * 3, 0); std::vector<float> campack((size_t)NL * 36); std::vector<int32_t> nbpack((size_t)NL * NS, 0);
        for (int i = 0; i < NL; ++i) {
            const int v = local[i];
            if (!rgb[v].empty()) std::copy(rgb[v].begin(), rgb[v].end(), rgbpack.begin() + (size_t)i * N * 3);
            std::copy(tab.cams.begin() + (size_t)v * 36, tab.cams.begin() + (size_t)(v + 1) * 36, campack.begin() + (size_t)i * 36);
            for (int j = 0; j < NS; ++j) { const int s = tab.neighbors[(size_t)v * NS + j]; nbpack[(size_t)i * NS + j] = lidx[s] >= 0 ? lidx[s] : 0; }
        }
        FILE* f;
        f = std::fopen((pack + "/rgb.u8").c_str(), "wb"); std::fwrite(rgbpack.data(), 1, rgbpack.size(), f); std::fclose(f);
        f = std::fopen((pack + "/cams.f32").c_str(), "wb"); std::fwrite(campack.data(), 4, campack.size(), f); std::fclose(f);
        f = std::fopen((pack + "/neighbors.i32").c_str(), "wb"); std::fwrite(nbpack.data(), 4, nbpack.size(), f); std::fclose(f);
        f = std::fopen((pack + "/meta.txt").c_str(), "w");
        std::fprintf(f, "%d %d %d %d %d %.9g %.9g %.9g %.9g %.9g\n", NL, W, H, NS, job.fuse.geo_mask_thres, job.fuse.geo_pixel_thres, job.fuse.geo_depth_thres,
                     job.fuse.photo_thres[0], job.fuse.photo_thres[1], job.fuse.photo_thres[2]);
        std::fclose(f);
    }

    // 4. inference, one view at a time, rows written straight into the pack. With a chunk callback every
    //    reference frame is fused and delivered the moment its ref view and all NS source views are inferred
    //    (FuseScheduler), so the app sees points long before the last view is done; the points are spilled to
    //    fused_<f>.bin and assembled in frame order in step 5, which is what makes out_ply identical.
    //    [A1] The fusion itself now runs on one worker thread fed by a queue, so it overlaps the next view's
    //    GPU inference instead of stalling it; the scheduler, chunk and progress stay on the calling thread.
    const int nref = r1 - r0 + 1;
    auto spill_path = [&](int f) { char b[32]; std::snprintf(b, sizeof b, "/fused_%05d.bin", f); return pack + b; };
    std::vector<RefRecord> rec(nref);
    FuseScheduler sched(tab.neighbors.data(), NF, NS, r0, r1);
    std::vector<int> ready;
    int nfused = 0; double fuse_ms = 0;
    // Fused-but-undelivered frames the worker may run ahead by. Two is the plain double buffer: one frame
    // being handed to the app, one already fused and waiting. A deeper queue buys no overlap — the calling
    // thread pumps after every single inference — and would only raise peak RSS by another fused frame
    // (xyz+rgb of one reference view).
    const size_t kFuseOutstanding = 2;
    FuseQ q;
    std::thread fuse_thread;
    FuseStopper fuse_stop(q, fuse_thread);
    if (chunk) {
        fuse_thread = std::thread([&] {
            for (;;) {
                int f = -1;
                {
                    std::unique_lock<std::mutex> lk(q.m);
                    q.cv_task.wait(lk, [&] { return q.stop || q.rc || (q.closed && q.tasks.empty()) || (!q.tasks.empty() && q.res.size() < kFuseOutstanding); });
                    if (q.stop || q.rc) break;
                    if (q.tasks.empty()) break;                         // closed and drained
                    if (q.res.size() >= kFuseOutstanding) continue;     // spurious wake with a full delivery queue
                    f = q.tasks.front(); q.tasks.pop_front();
                }
                const auto tf = clk::now();
                // fresh mapping: only a map created after the write is guaranteed to see the new rows. The
                // calling thread pushes f only after write_rows() returned for the last view f depends on, and
                // this open() happens after the pop, so the ordering the old inline drain relied on still holds.
                FusePack pk;
                if (!pk.open(pack)) { std::lock_guard<std::mutex> lk(q.m); q.rc = 2; q.err = "cannot open pack"; break; }
                FuseFrameResult fr;
                if (!fuse_pack_frame(pk, f - r0, boxp, fr)) { std::lock_guard<std::mutex> lk(q.m); q.rc = 4; q.err = "fusion failed on pack"; break; }
                RefRecord& R = rec[f - r0];
                std::memcpy(R.hs, fr.hs, sizeof R.hs); R.digest = fr.digest;
                R.ph = fr.photo_frac; R.ge = fr.geo_frac; R.fi = fr.final_frac; R.n = fr.points(); R.done = true;
                if (!fuse_spill_write(spill_path(f), fr.xyz, fr.rgb)) { std::lock_guard<std::mutex> lk(q.m); q.rc = 2; q.err = "cannot spill fused frame"; break; }
                const double dt = ms_since(tf);
                { std::lock_guard<std::mutex> lk(q.m); q.busy_ms += dt; FuseOut o; o.frame = f; o.fr = std::move(fr); q.res.push_back(std::move(o)); }
                q.cv_res.notify_all();
            }
            { std::lock_guard<std::mutex> lk(q.m); q.done = true; }
            q.cv_res.notify_all();
        });
    }
    int prc = 0;
    // Hands the worker's finished frames to the app. ONLY ever called on the calling thread, so chunk() and
    // progress() are invoked from the thread that called dense_run. Frames leave the queue in the order the
    // scheduler released them, which is the order the old inline drain delivered them in.
    auto pump = [&](bool wait_for_worker) -> bool {
        for (;;) {
            FuseOut out;
            {
                std::unique_lock<std::mutex> lk(q.m);
                if (q.rc) { prc = q.rc; S.error = q.err; return false; }
                if (q.res.empty()) {
                    if (!wait_for_worker || q.done) return true;
                    q.cv_res.wait(lk);
                    continue;
                }
                out = std::move(q.res.front()); q.res.pop_front();
            }
            q.cv_task.notify_all();
            ++nfused;
            if (chunk(orig[out.frame], out.fr.xyz.data(), out.fr.rgb.data(), (int)out.fr.points(), user)) { prc = 1; return false; }
            if (progress && progress("fuse", nfused, nref, user)) { prc = 1; return false; }
        }
    };

    {
        if (!ensure_ort()) { S.error = "ort init: " + ort_err; return 3; }
        std::string err;
        // [A4] Two slots: while run.run() reads slot i, a helper thread fills slot i+1 with the NEXT view's
        // imgbuf (fp16 -> fp32, replicated to 3 channels), its FrameInputs and its noise — the same three
        // calls, per view, in the same order, so make_noise(seed, frame_id) still produces that view's noise.
        // In SPLIT mode only slot 0 of imgbuf is filled (the reference image the context net still reads); the
        // other nine views arrive as cached feature maps addressed by `views`.
        struct Slot { std::vector<float> imgbuf; FrameInputs in; std::vector<float> nz2, nz3; const float *p2 = nullptr, *p3 = nullptr; std::vector<int32_t> views; };
        const int nfill = split_mode ? 1 : NV;
        Slot slot[2];
        for (int k = 0; k < 2; ++k) slot[k].imgbuf.assign((size_t)nfill * 3 * N, 0.0f);
        // [NEGATIVE CONTROL, bench only] Swap feature slots 1 and 2 of every view tuple. The R session then reads
        // the right images' features in the WRONG order, which must change the pack sha. Never set in production.
        const bool neg_swap12 = split_mode && env_flag("PWDENSE_SPLIT_SWAP12") && NS >= 2;
        auto prep = [&](int v, Slot& s) {
            std::vector<int32_t> views{v}; for (int j = 0; j < NS; ++j) views.push_back(tab.neighbors[(size_t)v * NS + j]);
            for (int k = 0; k < nfill; ++k) bank_to_img3(bank[views[k]], N, s.imgbuf.data() + (size_t)k * 3 * N);
            build_frame_inputs(tab.cams.data(), views, s.in);
            s.views = views;
            if (neg_swap12) std::swap(s.views[1], s.views[2]);
            if (job.ext_noise) { s.p2 = job.ext_noise + (size_t)orig[v] * (n2 + n3); s.p3 = s.p2 + n2; }   // hooks are laid out per job frame
            else { make_noise(job.noise_seed, (int)frames[v].frame_id, n2, n3, s.nz2, s.nz3); s.p2 = s.nz2.data(); s.p3 = s.nz3.data(); }
        };
        const std::vector<int> infer_list(infer.begin(), infer.end());
        const bool no_prefetch = env_flag("PWDENSE_PIPE_NO_PREFETCH"), sync_fuse = env_flag("PWDENSE_PIPE_SYNC_FUSE");
        size_t enqueued = 0;
        std::thread prep_thread;
        Joiner prep_join(prep_thread);
        if (!infer_list.empty()) prep(infer_list[0], slot[0]);
        std::vector<float> depth(N), c0(N), c1(N), c2(N), ms;
        int done = 0;
        for (size_t idx = 0; idx < infer_list.size(); ++idx) {
            const int v = infer_list[idx];
            if (progress && progress("infer", done, (int)infer_list.size(), user)) return 1;
            if (prep_thread.joinable()) prep_thread.join();   // slot[idx % 2] is ready
            Slot& cur = slot[idx % 2];
            if (no_prefetch && idx > 0) prep(v, cur);         // ablation: the old inline fill, GPU idle meanwhile
            if (!no_prefetch && idx + 1 < infer_list.size()) {   // fill the other slot while the GPU works
                const int nv2 = infer_list[idx + 1]; Slot* nxt = &slot[(idx + 1) % 2];
                prep_thread = std::thread([&, nv2, nxt] { prep(nv2, *nxt); });
            }
            double dt = 0;
            if (split_mode) {   // the 10 feature slots in the SAME view order the fused `imgs` tensor had
                std::vector<const FeatureSet*> fv((size_t)NV, nullptr);
                for (int k = 0; k < NV; ++k) fv[k] = &feat[cur.views[k]];
                if (!run.run_rest(fv.data(), cur.imgbuf.data(), cur.in, cur.p2, cur.p3, depth.data(), c0.data(), c1.data(), c2.data(), &dt, &err)) { S.error = "ort run: " + err; return 3; }
            } else if (!run.run(cur.imgbuf.data(), cur.in, cur.p2, cur.p3, depth.data(), c0.data(), c1.data(), c2.data(), &dt, &err)) { S.error = "ort run: " + err; return 3; }
            if (done > 0) ms.push_back(dt); S.infer_ms_total += dt;   // first view carries shader compile / warm-up
            const long off = (long)((size_t)lidx[v] * N * 4);
            if (!write_rows(pack + "/depth.f32", depth.data(), N * 4, off) || !write_rows(pack + "/conf0.f32", c0.data(), N * 4, off) ||
                !write_rows(pack + "/conf1.f32", c1.data(), N * 4, off) || !write_rows(pack + "/conf2.f32", c2.data(), N * 4, off)) { S.error = "pack write"; return 2; }
            if (job.ref_depth) {
                const float* rd = job.ref_depth + (size_t)orig[v] * N;
                for (size_t i = 0; i < N; ++i) {
                    if (!std::isfinite(depth[i])) { ++S.parity_nonfinite; continue; }
                    const double r = std::fabs(depth[i] - rd[i]) / std::max(rd[i], 1e-6f);
                    if (r > 0.01) ++S.parity_bad1;
                    S.parity_worst_rel = std::max(S.parity_worst_rel, r); ++S.parity_pixels;
                }
            }
            ++done;
            if (chunk) {   // rows are on disk: hand the refs the scheduler releases to the fusion worker
                sched.mark_inferred(v);
                sched.take_ready(ready);
                if (!ready.empty()) {
                    { std::lock_guard<std::mutex> lk(q.m); for (int f : ready) q.tasks.push_back(f); }
                    enqueued += ready.size();
                    q.cv_task.notify_all();
                }
                if (!pump(false)) return prc;
                if (sync_fuse) {   // ablation: behave like the inline drain — nothing overlaps the fusion
                    while ((size_t)nfused < enqueued) {
                        { std::unique_lock<std::mutex> lk(q.m); q.cv_res.wait(lk, [&] { return !q.res.empty() || q.rc || q.done; }); if (q.rc || (q.done && q.res.empty())) break; }
                        if (!pump(false)) return prc;
                    }
                }
            }
        }
        S.inferred = done;
        std::sort(ms.begin(), ms.end()); S.infer_ms_median = ms.empty() ? 0 : ms[ms.size() / 2];
        if (chunk) {   // hand over anything the scheduler still holds (take_ready already ran after every view,
                       // so this is the same defensive last drain the inline version did), then close the queue.
            sched.take_ready(ready);
            { std::lock_guard<std::mutex> lk(q.m); for (int f : ready) q.tasks.push_back(f); q.closed = true; }
            q.cv_task.notify_all();   // the worker may keep fusing through release()
        }
        run.release();   // free the ~1.3 GB session before fusion touches the pack
        feat.clear(); feat.shrink_to_fit();   // and the 12.5 MB/image feature cache: the fusion tail never reads it
    }
    if (progress && progress("infer", (int)infer.size(), (int)infer.size(), user)) return 1;

    // 5. fusion from the pack (refs are local 0..nref-1); the box crops the delivered points
    t = clk::now();
    if (!chunk) {   // pre-Stage-3 path, untouched
        const int rc = fuse_pack(pack, 0, r1 - r0, job.out_ply, progress, user, &S.fuse, boxp);
        S.fuse_ms = ms_since(t);
        if (rc == 1) return 1;
        if (rc != 0) { S.error = "fusion failed on pack"; return 4; }
        if (progress) progress("done", 1, 1, user);
        return 0;
    }
    {   // refs left over (a ref whose own view is its last dependency) are still in the worker: drain it dry
        const auto tw = clk::now();
        if (!pump(true)) return prc;
        S.fuse_wait_ms = ms_since(tw);
    }
    fuse_thread.join();
    { std::lock_guard<std::mutex> lk(q.m); if (q.rc) { S.error = q.err; return q.rc; } fuse_ms = q.busy_ms; }
    for (int i = 0; i < nref; ++i) if (!rec[i].done) { S.error = "reference frame never became fusable"; return 4; }
    // assemble in FRAME order: the PLY bytes, the FNV fold and the frac sums are then exactly fuse_pack's
    FusePlyWriter ply;
    if (!ply.begin(job.out_ply)) { S.error = "cannot write ply"; return 4; }
    double ph = 0, ge = 0, fi = 0; uint64_t hall = 1469598103934665603ULL;
    S.fuse.frame_digest.clear();
    for (int f = r0; f <= r1; ++f) {
        const RefRecord& R = rec[f - r0];
        hall = fnv1a64(R.hs, sizeof R.hs, hall);
        S.fuse.frame_digest.push_back(R.digest);
        if (!fuse_spill_append(spill_path(f), ply)) { S.error = "cannot read spilled frame"; return 4; }
        std::remove(spill_path(f).c_str());
        ph += R.ph; ge += R.ge; fi += R.fi;
    }
    if (!ply.finish()) { S.error = "cannot write ply"; return 4; }
    S.fuse.frames = nref; S.fuse.points = ply.points();
    S.fuse.photo_frac = ph / nref; S.fuse.geo_frac = ge / nref; S.fuse.final_frac = fi / nref; S.fuse.digest = hall;
    S.fuse_ms = fuse_ms + ms_since(t);
    if (progress) progress("done", 1, 1, user);
    return 0;
}

}  // namespace aether::dense
