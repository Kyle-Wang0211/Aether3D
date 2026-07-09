// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether_sfm — on-device Structure-from-Motion C ABI.
//
// Wraps the validated COLMAP *incremental* SfM pipeline
// (colmap::IncrementalPipeline → native incremental triangulation +
// re-triangulation + local/global BA) that was benchmarked on-device in
// glomap_vendor/bench/colmap_bench.cc. The implementation links against the
// three arm64-device-only static libraries vendored under
// aether_cpp/third_party/:
//   - glomap_vendor/build-ios/libglomap_core.a  (colmap+glomap+poselib subset)
//   - ceres-build-ios/lib/libceres.a            (BA solver, Accelerate, no GPL)
//   - glog-install/lib/libglog.a                (BSD-3 logging)
//
// There is NO simulator slice for these archives (arm64-device only), so the
// implementation TU is compiled under a device-only guard. On the simulator a
// stub TU returns AETHER_SFM_ERR_UNSUPPORTED for every entry point so the FFI
// symbols still resolve (link + dlsym stable) and the Dart layer can degrade
// gracefully.
//
// Two surfaces, same validated core:
//   (1) BATCH (v1, validated fast path) — aether_sfm_run / aether_sfm_run_dir:
//       point it at a prebuilt COLMAP sqlite db (+ image dir) and it runs the
//       exact colmap_bench path, leaving the Reconstruction live so the caller
//       reads poses + points via the getters. This mirrors colmap_bench()
//       1:1; it is the safest first integration.
//   (2) STREAMING (follow-up) — aether_sfm_create / add_frame / finalize:
//       accumulate frames one-at-a-time into a private sqlite db
//       (aether_dsp_sift_extract → WriteKeypoints/WriteDescriptors → match →
//       WriteMatches/WriteTwoViewGeometry) then finalize() runs the SAME
//       IncrementalPipeline over the accumulated db.
//
// Memory convention: caller-frees-output (mirrors aether_glb_norm_c.h). Opaque
// session handle owns the sqlite db + the live Reconstruction; aether_sfm_free
// drops both. Point arrays are lib-malloc'd and freed via
// aether_sfm_points_free to avoid heap-allocator mismatch across the FFI line.

#ifndef AETHER_SFM_C_H
#define AETHER_SFM_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Result codes ───────────────────────────────────────────────────
// Stable across versions — append new codes, never renumber.
typedef enum aether_sfm_result {
  AETHER_SFM_OK = 0,
  AETHER_SFM_ERR_INVALID_ARG = 1,
  AETHER_SFM_ERR_DB = 2,
  AETHER_SFM_ERR_EXTRACT = 3,
  AETHER_SFM_ERR_NO_INITIAL_PAIR = 4,
  AETHER_SFM_ERR_NOT_REGISTERED = 5,
  AETHER_SFM_ERR_INTERNAL = 6,
  AETHER_SFM_ERR_UNSUPPORTED = 7,  // returned by the simulator stub TU
} aether_sfm_result_t;

typedef struct aether_sfm_session aether_sfm_session_t;  // opaque

typedef struct aether_sfm_options {
  int max_features;     // 2048 (validated config)
  int image_width;      // intrinsics reference width
  int image_height;
  float match_max_ratio;  // 0.7 default (Lowe ratio for the matcher)
  int use_gpu_match;      // 1 = aether_gpu_match (Metal), 0 = CPU aether_sift_match
  int k_neighbors;        // K=6..8 sequential window of pair candidates
  int use_gpu_extract;    // 1 = GPU DSP-SIFT (Dawn/WGSL, f16-on-A16, CPU
                          //     fallback in-ABI), 0 = CPU aether_dsp_sift_extract.
                          //     Default 0; the iOS/Flutter shim flips to 1.
} aether_sfm_options_t;
void aether_sfm_options_default(aether_sfm_options_t* out);

// ─── streaming pipeline ─────────────────────────────────────────────
// Creates a session backed by a private sqlite db at db_path (temp dir).
aether_sfm_result_t aether_sfm_create(const char* db_path,
                                      const aether_sfm_options_t* options,
                                      aether_sfm_session_t** out_session);

// Add one frame. gray = row-major top-down grayscale (CGImage convention,
// same as aether_dsp_sift_extract). ARKit intrinsics (fx,fy,cx,cy) +
// world->cam pose prior (qw,qx,qy,qz, tx,ty,tz) supplied per frame.
// Internally: aether_dsp_sift_extract -> WriteKeypoints/WriteDescriptors,
// then match against the previous k_neighbors frames -> WriteMatches +
// WriteTwoViewGeometry. Returns the assigned frame index in *out_frame_id.
aether_sfm_result_t aether_sfm_add_frame(aether_sfm_session_t* s,
                                         const uint8_t* gray,
                                         int width, int height,
                                         float fx, float fy,
                                         float cx, float cy,
                                         const double pose_qwxyz[4],  // may be NULL
                                         const double pose_t[3],      // may be NULL
                                         int* out_frame_id);

// Run colmap::IncrementalPipeline over the accumulated db (native incremental
// triangulation + re-triangulation + local/global BA). out_json (optional)
// gets {solve_ms,n_registered,n_points3d,reproj_px}.
aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s,
                                        char* out_json, int out_cap);

// ─── async finalize (off-the-critical-path global BA) ───────────────
// Progress flag for aether_sfm_finalize_async (poll via aether_sfm_finalize_status).
typedef enum aether_sfm_finalize_status {
  AETHER_SFM_FINALIZE_IDLE = 0,         // not started
  AETHER_SFM_FINALIZE_LOCAL_READY = 1,  // local recon live; global BA refining
  AETHER_SFM_FINALIZE_REFINED = 2,      // global BA done; recon swapped to refined
  AETHER_SFM_FINALIZE_ERROR = 3,        // refinement failed
} aether_sfm_finalize_status_t;

// Two-phase finalize for "拍完即出图". Phase 1 (this call, synchronous): runs the
// incremental register + LOCAL BA only, so the LOCAL reconstruction is live the
// instant this returns OK — read poses/points immediately (status becomes
// LOCAL_READY). Phase 2 (background thread): the heavy O(N) finalize global BA
// runs OFF the UI critical path; when it converges the globally-refined model is
// atomically swapped in (status becomes REFINED) and the getters then return it.
// out_json carries the LOCAL summary. The session owns the worker thread;
// aether_sfm_free joins it. Downstream (depth/fusion) should wait for REFINED;
// the live preview can use the LOCAL_READY model immediately.
aether_sfm_result_t aether_sfm_finalize_async(aether_sfm_session_t* s,
                                              char* out_json, int out_cap);

// Lock-free poll of the background refinement (aether_sfm_finalize_status_t).
int aether_sfm_finalize_status(aether_sfm_session_t* s);

// ─── outputs (only valid after finalize/run OK) ─────────────────────
typedef struct aether_sfm_pose {
  int frame_id;     // matches out_frame_id from add_frame
  int registered;   // 1 if COLMAP registered it
  double qwxyz[4];  // CamFromWorld rotation (Rigid3d quaternion)
  double t[3];      // CamFromWorld translation
} aether_sfm_pose_t;

// Caller passes a buffer of capacity cap; *out_count = total poses (== #frames).
// Poses are read from Reconstruction::Images()[id].CamFromWorld().
aether_sfm_result_t aether_sfm_get_poses(aether_sfm_session_t* s,
                                         aether_sfm_pose_t* out_poses,
                                         int cap, int* out_count);

typedef struct aether_sfm_point {
  float x, y, z;
  uint8_t r, g, b;
  uint8_t _pad[2];
} aether_sfm_point_t;

// Allocates an array the caller frees via aether_sfm_points_free. Read from
// Reconstruction::Points3D() (Point3D::xyz + color). Two-call pattern: pass
// out_points=NULL to just get *out_count, or pass a pointer-to-pointer that
// the lib mallocs.
aether_sfm_result_t aether_sfm_get_points(aether_sfm_session_t* s,
                                          aether_sfm_point_t** out_points,
                                          int* out_count);
void aether_sfm_points_free(aether_sfm_point_t* points);

// ─── live preview (rough, throwaway) ────────────────────────────────
// Rough point cloud triangulated DURING capture from per-frame matches + the
// ARKit poses passed to aether_sfm_add_frame — available WITHOUT finalize, for
// the instant capture-end region selector. NOT the authoritative model
// (finalize() still produces that). Points are ARKit-world (x,y,z) triples.
// Two-call sizing: pass out_xyz=NULL to read *out_count (total available), then
// allocate cap*3 floats and call again; fills min(cap, *out_count) points.
aether_sfm_result_t aether_sfm_get_preview_points(aether_sfm_session_t* s,
                                                  float* out_xyz, int cap,
                                                  int* out_count);

// ─── track observations (COLMAP-faithful color sampling) ───────────
// One 2D observation of a 3D point: the frame it was DETECTED in and the
// keypoint position in that frame's fed pixel space. Track membership is a
// visibility proof — sampling photo colors at these coordinates is
// occlusion-free by construction (exactly how COLMAP extract_colors works).
// Reprojection-based sampling is NOT: a point occluded in the sampled frame
// silently picks up the occluder's color.
typedef struct aether_sfm_track_obs {
  int32_t frame_id;  // matches aether_sfm_pose_t.frame_id (image_id - 1)
  float x, y;        // keypoint coords in the fed frame's pixel space
} aether_sfm_track_obs_t;

// Atomic points+tracks snapshot. Same per-point payload as
// aether_sfm_get_points PLUS the track observations, all read from ONE
// Reconstruction snapshot (a separate get_points/get_tracks call pair could
// straddle the async LOCAL→REFINED swap and disagree on point order/count).
// Observations for point i live in
//   out_obs[out_obs_offsets[i] .. out_obs_offsets[i+1])
// and out_obs_offsets has *out_count + 1 entries. Free the points via
// aether_sfm_points_free, the offsets+obs via aether_sfm_track_obs_free.
aether_sfm_result_t aether_sfm_get_points_tracked(
    aether_sfm_session_t* s,
    aether_sfm_point_t** out_points,
    int* out_count,
    int32_t** out_obs_offsets,
    aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count);
void aether_sfm_track_obs_free(int32_t* offsets, aether_sfm_track_obs_t* obs);

// Sibling of aether_sfm_get_points_tracked that reads the LIVE streaming
// local-BA reconstruction (built incrementally during capture) rather than the
// finalize output — so the worker can true-color the streaming cloud through
// the same colorize path. Identical output contract (points freed via
// aether_sfm_points_free, offsets+obs via aether_sfm_track_obs_free). Device
// only: must be called on the capture worker isolate (see .cc threading note).
aether_sfm_result_t aether_sfm_get_preview_tracked(
    aether_sfm_session_t* s,
    aether_sfm_point_t** out_points,
    int* out_count,
    int32_t** out_obs_offsets,
    aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count);

// Cumulative streaming-quality counters over the whole capture — which floater
// filter did what. tvg_pairs/raw_pairs = grow/create pairs from the geometric
// (TVG RANSAC) inliers vs raw-fallback; grow_accepted/rejected = growth
// observations kept vs gated; reproj_filtered/tri_filtered = obs culled by the
// post-BA reprojection and multi-view triangulation-angle filters. Nullable.
void aether_sfm_stream_stats(aether_sfm_session_t* s, int64_t* tvg_pairs,
                             int64_t* raw_pairs, int64_t* grow_accepted,
                             int64_t* grow_rejected, int64_t* reproj_filtered,
                             int64_t* tri_filtered);

// Destroys session, drops the sqlite db file.
void aether_sfm_free(aether_sfm_session_t* s);

// ─── batch convenience (v1 fast path) ───────────────────────────────
// aether_sfm_run: the validated path. Runs IncrementalPipeline over a prebuilt
// COLMAP sqlite db (db_path) + image dir (image_path), leaving the session
// live so the caller reads poses + points via the getters above. Mirrors
// colmap_bench(db,image_path,out_json,cap) exactly. out_session may be NULL if
// the caller only wants the JSON summary (the internal session is then freed).
aether_sfm_result_t aether_sfm_run(const char* db_path,
                                   const char* image_path,
                                   const aether_sfm_options_t* options,  // may be NULL
                                   aether_sfm_session_t** out_session,   // may be NULL
                                   char* out_json, int out_cap);

// aether_sfm_run_dir: runs the whole validated pipeline over a directory of
// JPEGs + a sidecar poses.json, returning poses+points via the getters by
// leaving the session live. Does extraction+match+db-build in-process instead
// of consuming a prebuilt db.
aether_sfm_result_t aether_sfm_run_dir(const char* capture_dir,
                                       const aether_sfm_options_t* options,
                                       aether_sfm_session_t** out_session,
                                       char* out_json, int out_cap);

// Convenience: human-readable string for a result code. Static storage; do not
// free.
const char* aether_sfm_result_str(aether_sfm_result_t code);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_SFM_C_H
