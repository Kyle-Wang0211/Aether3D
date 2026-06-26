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

// Add one frame from ALREADY-EXTRACTED features (the GPU DSP-SIFT extractor's
// output) — NO internal re-extraction. This is the streaming feature-injection
// entry the orchestrator's IngestFn calls with the GPU `feats` it already
// computed (see aether_gpu_sift_extract):
//   - keypoints_stride4: count * {x, y, sigma, octave} floats (GPU native layout;
//     only x,y are used by the SfM geometry).
//   - descriptors:       count * 128 uint8 RootSIFT.
//   - width/height/fx/fy/cx/cy: shared-camera intrinsics (created lazily on the
//     first frame, self-calibrated by BA from the ARKit prior).
//   - pose_qwxyz/pose_t (may be NULL): ARKit world->cam pose prior used for
//     pose-guided match pruning (cheaper matching; never invents pairs).
// Internally: WriteKeypoints/WriteDescriptors for this image, then matches +
// persists (WriteMatches + geometric verification -> WriteTwoViewGeometry)
// against the previous k_neighbors frames so the incremental mapper can register
// it. Returns the assigned frame index in *out_frame_id.
aether_sfm_result_t aether_sfm_add_frame_with_features(
    aether_sfm_session_t* s, int width, int height, float fx, float fy,
    float cx, float cy,
    const float* keypoints_stride4,   // count * {x,y,sigma,octave}
    const uint8_t* descriptors,       // count * 128 RootSIFT
    unsigned int count,
    const double pose_qwxyz[4],       // may be NULL
    const double pose_t[3],           // may be NULL
    int* out_frame_id);

// Run colmap::IncrementalPipeline over the accumulated db (native incremental
// triangulation + re-triangulation + local/global BA). out_json (optional)
// gets {solve_ms,n_registered,n_points3d,reproj_px}.
aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s,
                                        char* out_json, int out_cap);

// ─── per-frame incremental register (true step-3 streaming) ─────────
// Drives colmap::IncrementalMapper DIRECTLY, one frame at a time, instead of
// running the whole IncrementalPipeline at finalize. Two entry points + a live
// IncrementalMapper/Reconstruction/DatabaseCache held on the session:
//
//   begin_incremental : build the DatabaseCache from the frames accumulated so
//                       far (add_frame_with_features), BeginReconstruction, run
//                       the bootstrap seed (FindInitialImagePair ->
//                       RegisterInitialImagePair -> TriangulateImage(x2) ->
//                       AdjustGlobalBundle -> Normalize -> FilterPoints/Frames).
//                       Call ONCE after the frames+matches are in the db. The
//                       correspondence graph is FROZEN at this point (COLMAP
//                       4.0.4 cannot extend a live cache), so frames added AFTER
//                       this call are not registerable — add all frames first,
//                       then begin, then stream register over the frozen graph.
//                       Returns AETHER_SFM_ERR_NO_INITIAL_PAIR if no seed yet.
//
//   register_next_frame : register ONE already-added frame (by the frame_id
//                       returned from add_frame_with_features) into the live
//                       model: RegisterNextImage -> TriangulateImage ->
//                       IterativeLocalRefinement (local window BA only; global
//                       BA is DEFERRED to finalize, never on this path). Out-
//                       params expose the just-registered pose + incremental
//                       point stats so the capture UI can render immediately.
//                       out_registered=0 (with AETHER_SFM_OK) means the frame is
//                       not yet registerable (too few 2D-3D inliers) — a normal
//                       streaming outcome, keep going.
//
// Cost: register_next_frame is O(1) in N (PnP + this image's triangulation +
// fixed-window local BA). The single O(N) graph load is in begin_incremental;
// the single O(N) global solve stays in finalize.
aether_sfm_result_t aether_sfm_begin_incremental(aether_sfm_session_t* s,
                                                 char* out_json, int out_cap);

aether_sfm_result_t aether_sfm_register_next_frame(
    aether_sfm_session_t* s,
    int frame_id,               // index from add_frame_with_features
    double out_pose_qwxyz[4],   // CamFromWorld rotation (w,x,y,z); may be NULL
    double out_pose_t[3],       // CamFromWorld translation; may be NULL
    int* out_registered,        // 1 if this frame got a pose this call, else 0
    int* out_new_points,        // points3D created this call (delta)
    int* out_total_points,      // total points3D in the live model now
    double* out_reproj);        // current mean reproj over the live model

// ─── TRUE LIVE-INTERLEAVED incremental register (sparse cloud grows DURING
//     capture) ──────────────────────────────────────────────────────────
// The frozen-graph model above (begin_incremental + register_next_frame) requires
// ALL frames to be in the db BEFORE begin_incremental, because COLMAP 4.0.4's
// CorrespondenceGraph::Finalize() is one-shot and irreversible (it destroys the
// mutable per-image `corrs` and the query path FindCorrespondences THROW_CHECKs
// finalized_). So that path is a POST-capture replay over a fully-captured graph.
//
// This live path is genuinely interleaved: it adds a frame's correspondences to a
// LIVE, growing session and registers it immediately, with the cloud growing
// frame-by-frame DURING capture. Because stock COLMAP cannot extend a finalized
// cache in place, the live-mutation mechanism is a PERIODIC BOUNDED RE-CACHE
// (the recommended workaround): the new frame's image+keypoints+matches+TVGs are
// streamed into the db every call; every `recache_every` frames (default 8) the
// session rebuilds a fresh DatabaseCache + IncrementalMapper and CONTINUES the
// SAME live Reconstruction (Reconstruction::Load is additive + preserves the
// already-registered poses/3D points, EndReconstruction(discard=false) keeps the
// registered model via TearDown). Between re-caches, newly-cached frames register
// against the existing model via RegisterNextImage + TriangulateImage + local BA.
//
// COST (honest): the per-frame REGISTER step is O(local) (PnP + this image's
// triangulation + fixed-window local BA) and does NOT grow with N. The re-cache
// rebuild is O(current graph) and lands once per `recache_every` frames; on device
// it runs on a background thread off the per-frame critical path. The two out-
// params out_recache_ms / out_register_ms separate the two so the caller can see
// the register cost stays flat while the (amortized) re-cache spike is reported.
//
// Bootstrap is handled live: the first `bootstrap_k` frames are accumulated, then
// the seed runs (FindInitialImagePair -> RegisterInitialImagePair ->
// TriangulateImage x2 -> AdjustGlobalBundle -> Normalize -> Filter); subsequent
// frames register incrementally. out_registered=0 with AETHER_SFM_OK = not yet
// registerable (normal streaming outcome — keep feeding frames).
//
// This REPLACES the begin/freeze model for the live path; the old path is kept for
// comparison/baseline. Configure recache_every / bootstrap_k via the options-less
// defaults (8 / 6) or aether_sfm_set_live_params.
typedef struct aether_sfm_live_stats {
  int registered;       // 1 if THIS frame got a pose this call, else 0
  int new_points;       // points3D created this call (delta)
  int total_points;     // total points3D in the live model now
  int total_registered; // running count of registered frames
  double reproj_px;     // current mean reproj over the live model
  double register_ms;   // O(local) per-frame register wall time (flat in N)
  double recache_ms;    // re-cache rebuild wall time this call (0 if no rebuild)
  int did_recache;      // 1 if a graph re-cache happened this call
  int did_bootstrap;    // 1 if the bootstrap seed fired this call
} aether_sfm_live_stats_t;

// Tune the live path. recache_every>0 = rebuild the cache every N frames;
// bootstrap_k>=2 = accumulate this many frames before seeding. Call before the
// first aether_sfm_add_and_register_frame (later calls are honored at the next
// boundary). Defaults: recache_every=8, bootstrap_k=6.
// max_register_per_call>0 caps how many frames register per add_and_register call
// (bounds the cascade cost; the rest drain on later calls). Pass 0 to leave the
// default (4).
aether_sfm_result_t aether_sfm_set_live_params(aether_sfm_session_t* s,
                                               int recache_every,
                                               int bootstrap_k,
                                               int max_register_per_call);

// AETHER POSE-PRIOR PATH. Enable a known per-frame ARKit world pose so that
// frames whose 2D-3D visibility is too low for plain PnP register via the known
// pose instead. `enable` toggles the prior fallback in LiveRegisterImage.
aether_sfm_result_t aether_sfm_set_pose_prior_enabled(aether_sfm_session_t* s,
                                                      int enable);

// Attach an ARKit pose prior for one db image. `cam_from_world` is the 3x4
// COLMAP-convention camera-from-world pose as a row-major [R|t] (12 doubles:
// r00 r01 r02 tx r10 r11 r12 ty r20 r21 r22 tz). The caller is responsible for
// converting the ARKit world-from-camera transform into COLMAP cam_from_world
// (rotation transpose + camera-axis flip). Stored on the session and consumed by
// LiveRegisterImage's prior fallback only when the prior path is enabled.
aether_sfm_result_t aether_sfm_set_image_pose_prior(aether_sfm_session_t* s,
                                                    int image_id,
                                                    const double* cam_from_world_3x4);

// Read back how many frames registered VIA the pose-prior fallback (diagnostic).
int aether_sfm_num_prior_registered(aether_sfm_session_t* s);

// TRUE live-interleaved add+register. `frame_id` is the caller's monotonically-
// increasing capture index (also the order in which frames must be fed). The
// session must already carry this frame's image+correspondences in the db — in
// production via a prior aether_sfm_add_frame_with_features(frame_id...) on the
// SAME session; in the host-verify bench via aether_sfm_live_stage_db_image which
// stages one real-graph image into the live db in temporal order. Adds the frame
// to the live graph (periodic bounded re-cache) and registers it immediately.
aether_sfm_result_t aether_sfm_add_and_register_frame(
    aether_sfm_session_t* s,
    int frame_id,
    aether_sfm_live_stats_t* out_stats);   // may be NULL

// FINAL FLUSH — call ONCE after the live feed loop ends. Explicitly OFF the
// per-frame critical path. The periodic recache cadence strands the last few fed
// frames (they sit in the pending frontier but no further recache fires to put
// them in the cache). This flush does a final recache over ALL fed frames, drains
// the ENTIRE pending frontier with no per-call cap, then runs one global BA +
// filter to tighten reproj over the complete model. Brings coverage -> ~100%.
// Idempotent (a second call is a cheap no-op that just refreshes out_stats).
aether_sfm_result_t aether_sfm_live_final_flush(
    aether_sfm_session_t* s,
    aether_sfm_live_stats_t* out_stats);   // may be NULL

// HOST-VERIFY helper: stage ONE image (by the live-feed index `feed_index` into a
// caller-supplied temporal image_id ordering) FROM an already-open source db that
// carries the full graph, INTO the live session's db, copying its keypoints +
// the matches/TVGs that connect it to previously-staged images. This is how the
// bench feeds the real414 graph in TEMPORAL order one frame at a time so the live
// cloud genuinely grows per frame (not a pre-built full graph). Production does
// NOT use this — it streams real features via add_frame_with_features.
aether_sfm_result_t aether_sfm_live_stage_db_image(aether_sfm_session_t* s,
                                                   const char* src_db_path,
                                                   int src_image_id,
                                                   int* out_frame_id);

// ─── bench-only: attach an EXISTING db's frozen correspondence graph ─
// HOST-VERIFY helper (NOT a production capture entry point). Opens an existing
// COLMAP database that ALREADY carries a complete correspondence graph (images +
// keypoints + matches + two_view_geometries — e.g. the real414 research db whose
// stored descriptors were stripped but whose matches/TVGs are intact) as the
// session's db, and populates the session's frame_id -> image_id mapping in image
// order so begin_incremental + register_next_frame can stream over that REAL,
// production-grade graph WITHOUT re-injecting descriptors. The frame order is the
// db's image rowid order (capture order, as written by the research extractor).
// out_num_frames returns how many frames were attached. The session does NOT own
// the db file (does not delete it on free). Pure-batch finalize on the same
// session still works (it reopens db_path).
aether_sfm_result_t aether_sfm_attach_db_frames(aether_sfm_session_t* s,
                                                int* out_num_frames);

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
