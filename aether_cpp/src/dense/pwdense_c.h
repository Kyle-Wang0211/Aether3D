// pwdense_c.h — C ABI of the on-device dense point cloud job (PWDense.framework), consumed by Dart via dart:ffi.
// The Dart side assembles the inputs it already owns (official_sfm_sparse_meta.json poses, per-photo sidecar
// intrinsics, fed-frames jpeg paths materialised through PhotoArchiveResolver, official_sfm_sparse.ply xyz);
// no JSON is parsed here. Everything behind this ABI is the gated C++ in aether_cpp/src/dense.
#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PWDENSE_API __attribute__((visibility("default")))
#define PWDENSE_ABI_VERSION 1

typedef struct pwdense_frame_t {
    int32_t frame_id;          /* refined-pose frame id (official_sfm_sparse_meta.json poses[].frame_id) */
    double fx, fy, cx, cy;     /* sidecar intrinsics_fxfycxcy at the photo's resolution */
    double image_w, image_h;   /* sidecar image_w / image_h */
    double q_wxyz[4];          /* refined quat_wxyz (world -> camera, COLMAP/OpenCV axes) */
    double t[3];               /* refined t */
    const char* jpeg_path;     /* materialised JPEG of this frame */
} pwdense_frame_t;

typedef struct pwdense_options_t {
    int32_t width, height;     /* model resolution, 768x576 */
    int32_t nsrc;              /* source views per reference, 9 */
    int32_t webgpu;            /* 1 = WebGPU EP (production), 0 = CPU EP (debug) */
    const char* model_path;    /* fused CasDiffMVS ONNX; NULL -> pwdense_default_model_path() */
    const char* work_dir;      /* scratch dir for the depth pack (created; ~NF x 7 MB) */
    const char* out_ply;       /* output PLY (binary little endian xyz f32 + rgb u8, the app's own layout) */
    uint64_t noise_seed;
    /* Selection (the viewer's SelectionBox): has_box=0 -> whole cloud. Centre, FULL side lengths, row-major
       local->world rotation, all in the sparse PLY's world frame. Frames seeing no sparse point inside the box
       are left out; only fused points inside the box are delivered. */
    int32_t has_box;
    double box_center[3];
    double box_size[3];
    double box_rot[9];
} pwdense_options_t;

/* Progress: phase in {"session","images","infer","fuse","done"}; return non-zero to cancel. */
typedef int (*pwdense_progress_fn)(const char* phase, int32_t done, int32_t total, void* user);

typedef struct pwdense_stats_t {
    int32_t frames, inferred, images;
    int32_t frames_selected;   /* frames used after the selection subset (== frames when no box or fallback) */
    int32_t box_fallback;      /* 1 if fewer than nsrc+1 frames saw the box and the whole set was used */
    double session_ms, images_ms, ort_session_ms, infer_ms_median, infer_ms_total, fuse_ms;
    uint64_t points;
    double photo_frac, geo_frac, final_frac;
    char error[256];
} pwdense_stats_t;

PWDENSE_API int32_t pwdense_abi_version(void);
PWDENSE_API int32_t pwdense_available(void);                       /* 1 on device builds, 0 on the simulator stub */
PWDENSE_API int32_t pwdense_options_default(pwdense_options_t* o);  /* fills the certified fixture97 parameters */
PWDENSE_API const char* pwdense_default_model_path(void);           /* casdiffmvs.onnx shipped inside PWDense.framework */
/* Returns 0 ok, 1 cancelled, 2 input error, 3 model error, 4 fusion error, -1 unavailable. */
PWDENSE_API int32_t pwdense_run(const pwdense_frame_t* frames, int32_t n_frames,
                                const float* points_xyz, int32_t n_points,
                                const pwdense_options_t* opts,
                                pwdense_progress_fn progress, void* user,
                                pwdense_stats_t* out_stats);

#ifdef __cplusplus
}
#endif
