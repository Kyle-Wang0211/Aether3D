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
#define PWDENSE_ABI_VERSION 3

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
/* [v2 2026-09-15] Progressive delivery. Called from pwdense_run2 once per REFERENCE frame the moment that
   frame's fusion is done (dependency order: a reference is fused as soon as it and its nsrc source views are
   inferred, so chunks arrive while inference is still running). xyz = n*3 floats, rgb = n*3 bytes, in the sparse
   PLY's world frame, already box-filtered — exactly the bytes that frame contributes to out_ply. frame_index =
   index into the caller's frames array. Buffers are valid only during the call. Return non-zero to cancel.
   The final out_ply is byte-identical to pwdense_run's (frames written in frame order regardless of the order
   in which they were fused). */
typedef int (*pwdense_chunk_fn)(int32_t frame_index, const float* xyz, const uint8_t* rgb, int32_t n_points,
                                void* user);

/* Returns 0 ok, 1 cancelled, 2 input error, 3 model error, 4 fusion error, -1 unavailable. */
PWDENSE_API int32_t pwdense_run(const pwdense_frame_t* frames, int32_t n_frames,
                                const float* points_xyz, int32_t n_points,
                                const pwdense_options_t* opts,
                                pwdense_progress_fn progress, void* user,
                                pwdense_stats_t* out_stats);
/* [v3 2026-09-16] Frame with an optional raw NV12 source. When nv12_path != NULL it takes precedence over
   jpeg_path (which may then be NULL): the frame is a FULL-RANGE 4:2:0 bi-planar file exactly as the PWVA/HEVC
   decoder hands it out — Y plane (nv12_height*nv12_width bytes) then the interleaved CbCr plane
   ((nv12_height/2)*nv12_width bytes), both tightly packed. nv12_matrix selects the YUV->RGB constants:
   0 = BT.601 full range, 1 = BT.709 full range (see dense_images.h). The archived-photo path is not promised
   byte-identical to the fresh-JPEG path (user decision 2026-09-16); the JPEG path is unchanged and identical to v2.
   The layout of the first 11 members is exactly pwdense_frame_t. */
typedef struct pwdense_frame_v3_t {
    int32_t frame_id;
    double fx, fy, cx, cy;
    double image_w, image_h;
    double q_wxyz[4];
    double t[3];
    const char* jpeg_path;     /* v2 field; NULL allowed when nv12_path is set */
    const char* nv12_path;     /* NULL -> use jpeg_path */
    int32_t nv12_width, nv12_height;
    int32_t nv12_matrix;
    int32_t reserved0;         /* must be 0 */
} pwdense_frame_v3_t;

/* v2: same as pwdense_run plus the per-frame chunk callback (chunk may be NULL == pwdense_run). */
PWDENSE_API int32_t pwdense_run2(const pwdense_frame_t* frames, int32_t n_frames,
                                 const float* points_xyz, int32_t n_points,
                                 const pwdense_options_t* opts,
                                 pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user,
                                 pwdense_stats_t* out_stats);
/* v3: same as pwdense_run2 over pwdense_frame_v3_t frames (JPEG or raw NV12 sources per frame). */
PWDENSE_API int32_t pwdense_run3(const pwdense_frame_v3_t* frames, int32_t n_frames,
                                 const float* points_xyz, int32_t n_points,
                                 const pwdense_options_t* opts,
                                 pwdense_progress_fn progress, pwdense_chunk_fn chunk, void* user,
                                 pwdense_stats_t* out_stats);

#ifdef __cplusplus
}
#endif
