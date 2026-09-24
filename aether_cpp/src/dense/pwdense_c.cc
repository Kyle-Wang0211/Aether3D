// pwdense_c.cc — C ABI over dense_pipeline (device build). The simulator slice uses pwdense_c_sim.c instead.
#include "pwdense_c.h"

#include <dlfcn.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "dense_pipeline.h"

using namespace aether::dense;

namespace {
// [v2 2026-09-15] dense_run indexes DenseJob::frames, which pwdense_run2 re-sorts by frame_id; the ABI promises
// an index into the CALLER's frames array, so both callbacks go through this one context to map it back.
struct Tramp {
    pwdense_progress_fn progress = nullptr;
    pwdense_chunk_fn chunk = nullptr;
    void* user = nullptr;
    const std::vector<size_t>* order = nullptr;   // job index -> caller index
};
int tramp_progress(const char* phase, int done, int total, void* u) {
    Tramp* t = (Tramp*)u;
    return t->progress ? t->progress(phase, done, total, t->user) : 0;
}
int tramp_chunk(int frame_index, const float* xyz, const uint8_t* rgb, int n_points, void* u) {
    Tramp* t = (Tramp*)u;
    const int caller = (frame_index >= 0 && (size_t)frame_index < t->order->size()) ? (int)(*t->order)[frame_index] : frame_index;
    return t->chunk(caller, xyz, rgb, n_points, t->user);
}

// [v3 2026-09-16 lossless-speedup v1] The ONE body behind pwdense_run / run2 / run3. Callers hand over per-frame
// sources (dense_images.h FrameSource); run/run2 build Jpeg sources from jpeg_path, so the fresh-photo path is the
// same decode -> resize -> L -> f16 chain it always was. `sources` and `frames` are sorted together, and
// DenseJob::jpeg_paths is kept in that same order and size (dense_pipeline.cc validates it).
int32_t run_sources(std::vector<SessionFrame>& frames, std::vector<FrameSource>& sources,
                    const float* points_xyz, int32_t n_points, const pwdense_options_t* opts,
                    pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user, pwdense_stats_t* out) {
    // the fixture builder sorts registered poses by frame_id; enforce the same order here
    std::vector<size_t> order(frames.size()); for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return frames[a].frame_id < frames[b].frame_id; });

    DenseJob job;
    job.frames.reserve(frames.size()); job.sources.reserve(frames.size()); job.jpeg_paths.reserve(frames.size());
    for (size_t i : order) {
        job.frames.push_back(frames[i]);
        job.sources.push_back(sources[i]);
        // jpeg_paths stays the same length/order as frames (dense_pipeline.cc:108); it is ignored whenever
        // `sources` is non-empty, and an NV12 frame has no JPEG to name.
        job.jpeg_paths.push_back(sources[i].kind == FrameSourceKind::Jpeg ? sources[i].path : std::string());
    }
    job.points.assign(points_xyz, points_xyz + (size_t)n_points * 3);
    job.session.W = opts->width; job.session.H = opts->height; job.session.nsrc = opts->nsrc;
    job.model_path = opts->model_path ? opts->model_path : pwdense_default_model_path();
    // [dense-lossless-speedup-v1, feature reuse] The split models produced by ONNX's official onnx.utils.extract_model
    // (tools/featreuse_split.py) ship next to the fused model inside PWDense.framework. When BOTH are present the job
    // computes each image's features once and reuses them across reference views (hloc's pattern); otherwise the fused
    // graph runs exactly as before. The C ABI is unchanged: the paths are derived from model_path's directory.
    {
        const std::string dir = job.model_path.substr(0, job.model_path.find_last_of('/') == std::string::npos ? 0 : job.model_path.find_last_of('/'));
        const std::string f = dir + "/casdiffmvs_feat.onnx", r = dir + "/casdiffmvs_rest.onnx";
        FILE* ff = std::fopen(f.c_str(), "rb"); FILE* fr = std::fopen(r.c_str(), "rb");
        if (ff && fr) { job.feat_model_path = f; job.rest_model_path = r; }
        if (ff) std::fclose(ff); if (fr) std::fclose(fr);
    }
    job.webgpu = opts->webgpu != 0; job.work_dir = opts->work_dir; job.out_ply = opts->out_ply; job.noise_seed = opts->noise_seed;
    if (opts->has_box) {
        job.has_box = true;
        for (int k = 0; k < 3; ++k) { job.box_c[k] = opts->box_center[k]; job.box_s[k] = opts->box_size[k]; }
        for (int k = 0; k < 9; ++k) job.box_rot[k] = opts->box_rot[k];
    }

    DenseStats st;
    // chunk == NULL keeps the pre-v2 call verbatim (no trampoline, no progressive schedule).
    Tramp tr{progress, chunk, user, &order};
    const int rc = chunk ? dense_run(job, tramp_progress, tramp_chunk, &tr, &st)
                         : dense_run(job, progress, (dense_chunk_fn) nullptr, user, &st);
    if (out) {
        out->frames = st.NF; out->inferred = st.inferred; out->images = st.images; out->frames_selected = st.frames_selected; out->box_fallback = st.box_fallback ? 1 : 0;
        out->session_ms = st.session_ms; out->images_ms = st.images_ms; out->ort_session_ms = st.ort_session_ms;
        out->infer_ms_median = st.infer_ms_median; out->infer_ms_total = st.infer_ms_total; out->fuse_ms = st.fuse_ms;
        out->points = st.fuse.points; out->photo_frac = st.fuse.photo_frac; out->geo_frac = st.fuse.geo_frac; out->final_frac = st.fuse.final_frac;
        std::strncpy(out->error, st.error.c_str(), sizeof out->error - 1);
    }
    return rc;
}

// Shared argument check for run2 / run3 (frames array itself is checked by the caller's loop).
bool bad_common_args(const void* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                     const pwdense_options_t* opts) {
    return !frames || n_frames <= 0 || !points_xyz || n_points < 0 || !opts || !opts->work_dir || !opts->out_ply;
}

// v2 -> SessionFrame (the first 11 members of pwdense_frame_v3_t have exactly this layout).
void fill_session_frame(SessionFrame& s, int32_t frame_id, double fx, double fy, double cx, double cy,
                        double image_w, double image_h, const double q_wxyz[4], const double t[3]) {
    s.frame_id = frame_id; s.fx = fx; s.fy = fy; s.cx = cx; s.cy = cy; s.image_w = image_w; s.image_h = image_h;
    for (int k = 0; k < 4; ++k) s.q[k] = q_wxyz[k];
    for (int k = 0; k < 3; ++k) s.t[k] = t[k];
}

}  // namespace

extern "C" {

int32_t pwdense_abi_version(void) { return PWDENSE_ABI_VERSION; }
int32_t pwdense_available(void) { return 1; }

int32_t pwdense_options_default(pwdense_options_t* o) {
    if (!o) return 2;
    std::memset(o, 0, sizeof *o);
    o->width = 768; o->height = 576; o->nsrc = 9; o->webgpu = 1; o->noise_seed = 0x5EEDDEE5ULL;
    return 0;
}

const char* pwdense_default_model_path(void) {
    // The model ships next to the library binary inside PWDense.framework: <framework>/casdiffmvs.onnx
    static std::string path;
    if (path.empty()) {
        Dl_info info{};
        if (dladdr((const void*)&pwdense_default_model_path, &info) && info.dli_fname) {
            std::string p = info.dli_fname;
            const size_t s = p.find_last_of('/');
            path = (s == std::string::npos ? std::string(".") : p.substr(0, s)) + "/casdiffmvs.onnx";
        } else {
            path = "casdiffmvs.onnx";
        }
    }
    return path.c_str();
}

int32_t pwdense_run(const pwdense_frame_t* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                    const pwdense_options_t* opts, pwdense_progress_fn progress, void* user, pwdense_stats_t* out) {
    return pwdense_run2(frames, n_frames, points_xyz, n_points, opts, progress, nullptr, user, out);
}

int32_t pwdense_run2(const pwdense_frame_t* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                     const pwdense_options_t* opts, pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user,
                     pwdense_stats_t* out) {
    if (out) std::memset(out, 0, sizeof *out);
    if (bad_common_args(frames, n_frames, points_xyz, n_points, opts)) {
        if (out) std::strncpy(out->error, "bad arguments", sizeof out->error - 1);
        return 2;
    }
    std::vector<SessionFrame> fr; std::vector<FrameSource> src;
    fr.reserve(n_frames); src.reserve(n_frames);
    for (int32_t i = 0; i < n_frames; ++i) {
        const pwdense_frame_t& f = frames[i]; SessionFrame s;
        fill_session_frame(s, f.frame_id, f.fx, f.fy, f.cx, f.cy, f.image_w, f.image_h, f.q_wxyz, f.t);
        if (!f.jpeg_path) { if (out) std::strncpy(out->error, "frame without jpeg_path", sizeof out->error - 1); return 2; }
        FrameSource fs; fs.kind = FrameSourceKind::Jpeg; fs.path = f.jpeg_path;
        fr.push_back(s); src.push_back(std::move(fs));
    }
    return run_sources(fr, src, points_xyz, n_points, opts, progress, chunk, user, out);
}

int32_t pwdense_run3(const pwdense_frame_v3_t* frames, int32_t n_frames, const float* points_xyz, int32_t n_points,
                     const pwdense_options_t* opts, pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user,
                     pwdense_stats_t* out) {
    if (out) std::memset(out, 0, sizeof *out);
    if (bad_common_args(frames, n_frames, points_xyz, n_points, opts)) {
        if (out) std::strncpy(out->error, "bad arguments", sizeof out->error - 1);
        return 2;
    }
    std::vector<SessionFrame> fr; std::vector<FrameSource> src;
    fr.reserve(n_frames); src.reserve(n_frames);
    for (int32_t i = 0; i < n_frames; ++i) {
        const pwdense_frame_v3_t& f = frames[i]; SessionFrame s;
        fill_session_frame(s, f.frame_id, f.fx, f.fy, f.cx, f.cy, f.image_w, f.image_h, f.q_wxyz, f.t);
        FrameSource fs;
        if (f.nv12_path) {
            // nv12_path wins over jpeg_path (pwdense_c.h v3). Size/parity of the plane file is validated by
            // load_frame_rgb; here we only reject a frame that cannot describe a plane at all.
            if (f.nv12_width <= 0 || f.nv12_height <= 0 || (f.nv12_width & 1) || (f.nv12_height & 1)) {
                if (out) std::snprintf(out->error, sizeof out->error, "frame %d: bad nv12 size %dx%d (positive and even required)",
                                       (int)f.frame_id, (int)f.nv12_width, (int)f.nv12_height);
                return 2;
            }
            if (f.nv12_matrix != 0 && f.nv12_matrix != 1) {
                if (out) std::snprintf(out->error, sizeof out->error, "frame %d: nv12_matrix must be 0 or 1, got %d",
                                       (int)f.frame_id, (int)f.nv12_matrix);
                return 2;
            }
            fs.kind = FrameSourceKind::Nv12; fs.path = f.nv12_path;
            fs.width = f.nv12_width; fs.height = f.nv12_height; fs.nv12_matrix = f.nv12_matrix;
        } else if (f.jpeg_path) {
            fs.kind = FrameSourceKind::Jpeg; fs.path = f.jpeg_path;
        } else {
            if (out) std::snprintf(out->error, sizeof out->error, "frame %d: neither nv12_path nor jpeg_path", (int)f.frame_id);
            return 2;
        }
        fr.push_back(s); src.push_back(std::move(fs));
    }
    return run_sources(fr, src, points_xyz, n_points, opts, progress, chunk, user, out);
}

}  // extern "C"
