// pwdense_c.cc — C ABI over dense_pipeline (device build). The simulator slice uses pwdense_c_sim.c instead.
#include "pwdense_c.h"

#include <dlfcn.h>

#include <algorithm>
#include <cstring>
#include <string>

#include "dense_pipeline.h"

using namespace aether::dense;

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
    if (out) std::memset(out, 0, sizeof *out);
    if (!frames || n_frames <= 0 || !points_xyz || n_points < 0 || !opts || !opts->work_dir || !opts->out_ply) {
        if (out) std::strncpy(out->error, "bad arguments", sizeof out->error - 1);
        return 2;
    }
    DenseJob job;
    job.frames.reserve(n_frames); job.jpeg_paths.reserve(n_frames);
    for (int32_t i = 0; i < n_frames; ++i) {
        const pwdense_frame_t& f = frames[i]; SessionFrame s;
        s.frame_id = f.frame_id; s.fx = f.fx; s.fy = f.fy; s.cx = f.cx; s.cy = f.cy; s.image_w = f.image_w; s.image_h = f.image_h;
        for (int k = 0; k < 4; ++k) s.q[k] = f.q_wxyz[k]; for (int k = 0; k < 3; ++k) s.t[k] = f.t[k];
        if (!f.jpeg_path) { if (out) std::strncpy(out->error, "frame without jpeg_path", sizeof out->error - 1); return 2; }
        job.frames.push_back(s); job.jpeg_paths.emplace_back(f.jpeg_path);
    }
    // the fixture builder sorts registered poses by frame_id; enforce the same order here
    std::vector<size_t> order(job.frames.size()); for (size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return job.frames[a].frame_id < job.frames[b].frame_id; });
    { std::vector<SessionFrame> fr; std::vector<std::string> jp; for (size_t i : order) { fr.push_back(job.frames[i]); jp.push_back(job.jpeg_paths[i]); } job.frames.swap(fr); job.jpeg_paths.swap(jp); }
    job.points.assign(points_xyz, points_xyz + (size_t)n_points * 3);
    job.session.W = opts->width; job.session.H = opts->height; job.session.nsrc = opts->nsrc;
    job.model_path = opts->model_path ? opts->model_path : pwdense_default_model_path();
    job.webgpu = opts->webgpu != 0; job.work_dir = opts->work_dir; job.out_ply = opts->out_ply; job.noise_seed = opts->noise_seed;
    if (opts->has_box) {
        job.has_box = true;
        for (int k = 0; k < 3; ++k) { job.box_c[k] = opts->box_center[k]; job.box_s[k] = opts->box_size[k]; }
        for (int k = 0; k < 9; ++k) job.box_rot[k] = opts->box_rot[k];
    }

    DenseStats st;
    const int rc = dense_run(job, progress, user, &st);
    if (out) {
        out->frames = st.NF; out->inferred = st.inferred; out->images = st.images; out->frames_selected = st.frames_selected; out->box_fallback = st.box_fallback ? 1 : 0;
        out->session_ms = st.session_ms; out->images_ms = st.images_ms; out->ort_session_ms = st.ort_session_ms;
        out->infer_ms_median = st.infer_ms_median; out->infer_ms_total = st.infer_ms_total; out->fuse_ms = st.fuse_ms;
        out->points = st.fuse.points; out->photo_frac = st.fuse.photo_frac; out->geo_frac = st.fuse.geo_frac; out->final_frac = st.fuse.final_frac;
        std::strncpy(out->error, st.error.c_str(), sizeof out->error - 1);
    }
    return rc;
}

}  // extern "C"
