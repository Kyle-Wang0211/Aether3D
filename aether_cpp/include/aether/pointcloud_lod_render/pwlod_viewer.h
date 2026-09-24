// pwlod_viewer.h -- FROZEN C ABI (v2) between the PocketWorld point-cloud LOD engine
// (Aether3D, aether_cpp/include/aether/pointcloud_lod_render/) and each platform shell
// (iOS now; Android / HarmonyOS later).
//
// v2 (2026-09-24): pwlod_frame_stats.lowest_spacing added (last field), ABI version 2.
// v2 comment fix (2026-09-24): lowest_spacing defined exactly as Potree computes it (layout unchanged).
// Frozen by the coordinating session on 2026-09-24 (plan LOD_ARLOOPBENCH_PLAN_20260924.md,
// user choices A1 + B1 + orthographic via Cesium). Neither side edits this file; a needed
// change is reported back to the coordinator, who changes it for both sides at once.
//
// Rules
//   * No platform types. Only <stdint.h> and the Dawn C header (webgpu.h sha256 6d632738...).
//     IOSurface / AHardwareBuffer / OHNativeWindow are imported by the SHELL into a
//     WGPUSharedTextureMemory + WGPUTexture on the device this library created.
//   * Plan 3b / B1 (Flutter camera-plugin shape) lives in the ENGINE so every shell gets it:
//     a std::thread render loop owned by the viewer; completion via wgpuQueueOnSubmittedWorkDone;
//     a ring of shell-provided targets; a target is published only after its GPU work completed;
//     the consumer takes the latest published target without waiting. The only blocking waits
//     happen on the render thread, never on the caller's thread.
//   * Selection / streaming / controller = aether::pointcloud_lod unchanged: Potree
//     updateVisibility, <= 2 uploads per frame, <= 4 loads in flight, parent fallback, Cesium
//     multiplicative controller on minimumNodePixelSize with the point budget as hard ceiling.
//   * PWLOD_PROJ_ORTHOGRAPHIC: node screen size follows CesiumJS Cesium3DTile.js:945-954
//     @113c068e9af3 (pixelSize = max(frustum height, frustum width) / max(viewport w, h), no
//     distance term); adaptive point size follows Potree pointcloud.vs's orthographic branch.
#pragma once

#include <stdint.h>
#include <webgpu/webgpu.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PWLOD_ABI_VERSION 2
#define PWLOD_TARGET_COUNT 3 /* ring size; the only accepted value in v1 */

typedef enum pwlod_status {
  PWLOD_OK = 0,
  PWLOD_ERR_ARG = 1,    /* null pointer, bad enum, non-finite value, zero viewport, count != 3 */
  PWLOD_ERR_IO = 2,     /* file missing / unreadable */
  PWLOD_ERR_FORMAT = 3, /* corrupt or unsupported octree / PLY (reported, never aborts) */
  PWLOD_ERR_GPU = 4,    /* adapter / device / pipeline creation failed, or device lost */
  PWLOD_ERR_STATE = 5,  /* wrong call order, e.g. start() without targets, or nothing published yet */
  PWLOD_ERR_NOMEM = 6
} pwlod_status;

/* ---------------------------------------------------------------- GPU (plan 3a / A1) */

/* Instance + adapter + device created exactly like pw_lod_bench.cpp InitGpu (TimedWaitAny
   instance feature, default backend, Null backend refused, adapter's max storage limits,
   TimestampQuery when available) PLUS the caller's required features. The shell passes the
   feature its platform needs to share textures with the UI toolkit, e.g. on iOS
   WGPUFeatureName_SharedTextureMemoryIOSurface; the engine never names a platform. */
typedef struct pwlod_gpu {
  WGPUInstance instance;
  WGPUAdapter adapter;
  WGPUDevice device;
  WGPUQueue queue;
  WGPUBackendType backend;
} pwlod_gpu;

pwlod_status pwlod_gpu_create(const WGPUFeatureName* required_features,
                              uint32_t required_feature_count,
                              pwlod_gpu* out_gpu);
void pwlod_gpu_destroy(pwlod_gpu* gpu); /* after every viewer on it is destroyed; NULL ok */

/* ---------------------------------------------------------------- viewer */

typedef struct pwlod_viewer pwlod_viewer; /* opaque */

typedef enum pwlod_projection {
  PWLOD_PROJ_PERSPECTIVE = 0,
  PWLOD_PROJ_ORTHOGRAPHIC = 1
} pwlod_projection;

typedef enum pwlod_point_size_mode {
  PWLOD_PSIZE_FIXED = 0,   /* measurement arm only */
  PWLOD_PSIZE_ADAPTIVE = 1 /* Potree PointSizeType.ADAPTIVE (pointcloud.vs getLOD) */
} pwlod_point_size_mode;

typedef struct pwlod_camera {
  double view_proj_row_major[16]; /* world -> clip, ROW-major, WebGPU clip z in [0, 1] */
  double eye_world[3];            /* camera position in the octree's world frame */
  pwlod_projection projection;
  double fov_y_degrees;           /* PERSPECTIVE only */
  double ortho_width_world;       /* ORTHOGRAPHIC only: frustum.right - frustum.left */
  double ortho_height_world;      /* ORTHOGRAPHIC only: frustum.top - frustum.bottom */
  uint32_t viewport_width_px;     /* must equal the targets' size */
  uint32_t viewport_height_px;
} pwlod_camera;

typedef struct pwlod_params {
  int64_t point_budget;                  /* hard ceiling; default 3630000 */
  double target_frame_ms;                /* controller target + render-loop pacing; default 33.333 */
  pwlod_point_size_mode point_size_mode; /* default ADAPTIVE */
  int32_t async_loading;                 /* 1 = Potree async (default); 0 = synchronous arm */
  uint64_t cache_bytes;                  /* node cache cap; default and minimum 15 * point_budget */
  float background_rgba[4];              /* clear colour; default 0,0,0,1 */
  /* Negative-control switches for the plan 3b judges. Default 0; never set in a product. */
  int32_t debug_render_sleep_ms;         /* render thread sleeps this long every frame */
  int32_t debug_publish_before_done;     /* 1 = publish at submit instead of at GPU completion */
} pwlod_params;

typedef struct pwlod_frame_stats {
  uint64_t frame_number;          /* 1, 2, 3 ... per submitted frame */
  uint64_t completed_frame_number;/* highest frame whose OnSubmittedWorkDone fired (its own path) */
  int64_t points_drawn;
  int32_t nodes_drawn;
  int32_t nodes_loading;          /* in flight after this frame */
  int32_t uploads_this_frame;     /* <= 2 when async_loading = 1 */
  int64_t dropped_for_cache;      /* nodes skipped because the cache was too small */
  double min_node_pixel_size;     /* controller state after this frame */
  double cpu_ms;                  /* select + stream bookkeeping + encode + submit */
  double gpu_ms;                  /* submit -> OnSubmittedWorkDone; -1 if not yet known */
  /* v2: Potree's per-frame lowestSpacing exactly as Potree_update_visibility.js :114, :276-280,
     :413 @5636cd4 computes it: min spacing over EVERY node popped from the priority queue this
     frame, taken before the budget break (:282) and the visibility test (:286) -- so nodes
     outside the frustum and the node that trips the budget count too. <= 0 if the queue was
     empty. The shell feeds it to Potree Viewer.update's near/far rule (viewer.js:1749-1771). */
  double lowest_spacing;
} pwlod_frame_stats;

/* One ring slot. `memory` is the shared-texture memory `texture` was created from; the engine
   brackets every use with wgpuSharedTextureMemoryBeginAccess / EndAccess. NULL `memory` = a plain
   texture (host tests). Usage must include RenderAttachment | CopySrc. */
typedef struct pwlod_target {
  WGPUTexture texture;
  WGPUSharedTextureMemory memory;
} pwlod_target;

/* Called on the render thread right after target `target_index` was published (i.e. after its
   GPU work completed, unless debug_publish_before_done). Must return quickly and must not call
   back into the viewer: a shell only posts "new frame" to its platform thread (iOS:
   DispatchQueue.main.async { textureFrameAvailable }). */
typedef void (*pwlod_frame_ready_fn)(void* user,
                                     uint32_t target_index,
                                     const pwlod_frame_stats* stats);

void pwlod_params_default(pwlod_params* out);

pwlod_status pwlod_viewer_create(const pwlod_gpu* gpu, pwlod_viewer** out_viewer);

/* Any thread. Loads metadata.json + hierarchy.bin (octree.bin is streamed). Replaces the
   current octree; the render thread switches at a frame boundary. */
pwlod_status pwlod_viewer_load_octree(pwlod_viewer* viewer, const char* octree_dir);

/* Any thread; copied under a lock and picked up by the next frame. */
pwlod_status pwlod_viewer_set_params(pwlod_viewer* viewer, const pwlod_params* params);
pwlod_status pwlod_viewer_set_camera(pwlod_viewer* viewer, const pwlod_camera* camera);

/* Only while stopped. count must be PWLOD_TARGET_COUNT; all targets same size and format
   (RGBA8Unorm or BGRA8Unorm). The viewer does not take ownership. Resize = stop, set, start. */
pwlod_status pwlod_viewer_set_targets(pwlod_viewer* viewer,
                                      const pwlod_target* targets,
                                      uint32_t count,
                                      WGPUTextureFormat format,
                                      uint32_t width_px,
                                      uint32_t height_px);

/* Spawns the render thread. It renders when something changed (camera, params, octree, loads
   in flight, controller not settled) and at most once per target_frame_ms; otherwise it sleeps
   on a condition variable. Each frame renders into a target that is neither the latest published
   one nor the one the consumer holds, so a target the UI may still sample is never overwritten. */
pwlod_status pwlod_viewer_start(pwlod_viewer* viewer, pwlod_frame_ready_fn on_frame, void* user);

/* Consumer side (iOS: copyPixelBuffer on the raster thread). Never waits for the GPU or the
   render thread (only a short mutex). Returns the latest published target, marks it as held by
   the consumer (releasing the previously held one) and returns PWLOD_ERR_STATE if nothing has
   been published yet. */
pwlod_status pwlod_viewer_acquire_latest(pwlod_viewer* viewer,
                                         uint32_t* out_target_index,
                                         uint64_t* out_frame_number);

/* Joins the render thread after its in-flight frame completed. Idempotent. */
pwlod_status pwlod_viewer_stop(pwlod_viewer* viewer);

/* Any thread: stats of the latest published frame. */
pwlod_status pwlod_viewer_get_stats(pwlod_viewer* viewer, pwlod_frame_stats* out_stats);

/* Host tests and one-shot captures: render ONE frame into `target` on the caller's thread and
   wait for it. Only while stopped. Same code path as the render thread's frame body. */
pwlod_status pwlod_viewer_render_once(pwlod_viewer* viewer,
                                      const pwlod_target* target,
                                      WGPUTextureFormat format,
                                      uint32_t width_px,
                                      uint32_t height_px,
                                      pwlod_frame_stats* out_stats);

void pwlod_viewer_destroy(pwlod_viewer* viewer); /* stops first; NULL is a no-op */

/* ---------------------------------------------------------------- on-device build (plan L6) */

typedef struct pwlod_build_report {
  uint64_t ply_points;      /* vertex count in the PLY header */
  uint64_t tree_points;     /* sum of numPoints over all nodes (C1: must equal ply_points) */
  uint64_t octree_bin_bytes;/* C1: must equal 18 * tree_points */
  int32_t nodes;
  double elapsed_ms;
} pwlod_build_report;

/* PR #100 buildFromPly + optionsForBudget(out_dir, chunk_dir, memory_budget_mb, threads).
   BLOCKING: call from a background thread. memory_budget_mb <= 0 / threads <= 0 = library
   defaults. chunk_dir is caller-owned scratch the caller deletes afterwards. Peak memory is the
   shell's to measure (it is an OS query). report and err_buf may be NULL. */
pwlod_status pwlod_build_from_ply(const char* ply_path,
                                  const char* out_dir,
                                  const char* chunk_dir,
                                  int32_t memory_budget_mb,
                                  int32_t threads,
                                  pwlod_build_report* report,
                                  char* err_buf,
                                  uint32_t err_buf_len);

/* On-device self-check of a built tree = the library's own host judges, run on the phone.
   C1: tree_points and 18 * tree_points == octree_bin_bytes (caller compares with ply_points).
   C2: node byte ranges tile octree.bin with no gap and no overlap (test_octree.cpp).
   S2: every leaf is selected with the camera placed in front of it (test_select.cpp).
   Returns PWLOD_OK only if C2 and S2 both pass; the report says which failed. */
typedef struct pwlod_verify_report {
  uint64_t tree_points;
  uint64_t octree_bin_bytes;
  int32_t nodes;
  int32_t leaves;
  int32_t leaves_selected;  /* S2 passes iff == leaves */
  int64_t byte_gaps;        /* C2 passes iff 0 */
  int64_t byte_overlaps;    /* C2 passes iff 0 */
} pwlod_verify_report;

pwlod_status pwlod_verify_octree(const char* octree_dir, pwlod_verify_report* out_report);

/* ---------------------------------------------------------------- measurement (plan M1) */
/* pwlod_run() from pw_splat_ab_bench Sources/lod/pw_lod_bench.h is carried into the same
   library unchanged, declared in its own header pw_lod_bench.h (not repeated here). */

/* "<engine git sha8> abi=2" -- checked against the vendored artifact's receipt. */
const char* pwlod_version(void);

#ifdef __cplusplus
}
#endif
