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
  int k_neighbors;        // K match candidates per frame (production 12).
                          // [SPATIAL-FIRST 2026-07-11] selected spatial-first:
                          // ARKit camera-center K-NN ∩ view-angle < 45°,
                          // temporal fill to K; pure-temporal window when the
                          // frame has no usable pose. Budget: at most K pairs.
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
// then match against k_neighbors candidate frames (spatial-first selection;
// see the k_neighbors field doc) -> WriteMatches + WriteTwoViewGeometry.
// Returns the assigned frame index in *out_frame_id.
aether_sfm_result_t aether_sfm_add_frame(aether_sfm_session_t* s,
                                         const uint8_t* gray,
                                         int width, int height,
                                         float fx, float fy,
                                         float cx, float cy,
                                         const double pose_qwxyz[4],  // may be NULL
                                         const double pose_t[3],      // may be NULL
                                         int* out_frame_id);

// Feature-injection sibling of aether_sfm_add_frame: skips extraction and
// feeds precomputed keypoints (xy pairs, extractor's +0.5 half-pixel
// convention) + n_keypoints×128 UBC RootSIFT u8 descriptors into the same
// streaming core (camera/db writes, k-neighbor matching, live track growth,
// windowed BA). Built for HOST replay of a pulled device sfm_live.db —
// verifying streaming-path changes against real captures without the device.
// Production capture keeps using aether_sfm_add_frame.
aether_sfm_result_t aether_sfm_add_frame_features(aether_sfm_session_t* s,
                                                  const float* xy,
                                                  const uint8_t* desc,
                                                  int n_keypoints,
                                                  int width, int height,
                                                  float fx, float fy,
                                                  float cx, float cy,
                                                  const double pose_qwxyz[4],
                                                  const double pose_t[3],
                                                  int* out_frame_id);

// Remove one captured frame and ALL of its contribution to the reconstruction.
// Called when the user deletes a photo: "照片删了,数据也必须删了"(用户签决
// 2026-07-20)—— the deleted photo must not influence the delivered cloud.
//
// Every step is a stock COLMAP operation; this entry point is a forwarding
// shell with no algorithm of its own:
//   1. colmap::ObservationManager::DeRegisterFrame(frame_id) — drops every
//      observation of the frame, deletes 3D points whose track falls below two
//      elements (DeleteObservation's documented behaviour), maintains the
//      correspondence-graph visibility counters, then de-registers the frame.
//      Frames here are trivial rigs (frame_id == image_id, see add_frame).
//   2. Database::DeleteMatches / DeleteTwoViewGeometry / DeleteInlierMatches
//      for every pair touching this image — the row stays but is left isolated,
//      so ANY db-driven rebuild (resume / full-rerun fallback) can no longer
//      register it. COLMAP has no single-image delete; isolation is the
//      supported equivalent and needs no raw SQL.
//
// ⚠️ Surviving points keep the coordinates they were triangulated at (with the
// deleted frame participating). Fully erasing its influence requires the
// caller to re-triangulate + BA afterwards — that is what COLMAP itself does
// after FilterFrames, and the user signed off on the resulting小幅点云位移
// ("拍了虚的/有人经过的照片,产生的不良点云本来就该被纠正").
//
// out_json (optional) gets
// {removed_obs, deleted_points, cleared_pairs, n_registered, n_points3d}.
// Returns AETHER_SFM_OK even when the frame was never registered (no-op).
aether_sfm_result_t aether_sfm_remove_frame(aether_sfm_session_t* s,
                                            int frame_id,
                                            char* out_json, int out_cap);

// Run colmap::IncrementalPipeline over the accumulated db (native incremental
// triangulation + re-triangulation + local/global BA). out_json (optional)
// gets {solve_ms,n_registered,n_points3d,reproj_px}.
aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s,
                                        char* out_json, int out_cap);

// ─── async finalize (off-the-critical-path global BA) ───────────────
// Progress flag for aether_sfm_finalize_async (poll via aether_sfm_finalize_status).
typedef enum aether_sfm_finalize_status {
  AETHER_SFM_FINALIZE_IDLE = 0,         // not started
  AETHER_SFM_FINALIZE_LOCAL_READY = 1,  // worker refining (see note below)
  AETHER_SFM_FINALIZE_REFINED = 2,      // global BA done; recon swapped to refined
  AETHER_SFM_FINALIZE_ERROR = 3,        // refinement failed
} aether_sfm_finalize_status_t;

// Two-phase finalize for "拍完即出图". Phase 1 (this call): on the normal live
// streaming path the capture-time live local-BA reconstruction is handed to
// the background worker (milliseconds; out_json carries its summary with
// phase1:"live_reuse"). Phase 2 (background worker): finish-time db
// enrichment (spatial revisit + starved re-match, GPU) runs in parallel with
// a stage-1 global refinement (CPU), then the stage-2 Cauchy global BA +
// track completion consume the enriched db; the refined model is published
// (status becomes REFINED) and the getters return it.
//
// [FINALIZE-ZEROCOPY 2026-07-11] On the live path the LOCAL model is NOT
// published (product sign-off: it is never displayed) — get_poses/get_points
// return AETHER_SFM_ERR_NOT_REGISTERED between LOCAL_READY and REFINED, and
// the live-preview getters (get_preview_tracked / live_diag) also gate off
// once this call returns. Resume sessions (rebuilt from an sfm_live.db, no
// in-memory live recon) keep the old behavior: the db-driven LOCAL model is
// published at LOCAL_READY and readable while the worker refines a copy.
// The session owns the worker thread; aether_sfm_free joins it. Downstream
// (colorize/depth/fusion) must wait for REFINED.
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

// Legacy experimental pure global BA over live_recon. It does not create
// missing cross-view tracks, merge duplicate tracks, or retriangulate; do not
// use it as the finish-time double-wall fix without a spatial-revisit bridge.
// Device only: run on the capture worker isolate (see .cc threading).
aether_sfm_result_t aether_sfm_global_refine(aether_sfm_session_t* s);

// Per-frame timing/counters of the LAST aether_sfm_add_frame (perf
// diagnostics) — the numbers behind the device log line
//   extract=<..>ms match=<..>ms cand=<..> gpuM=<..> cpuM=<..>
// extract_ms > ~2000 flags a GPU→CPU extractor fallback; cpu_matches > 0
// flags a GPU matcher failure. Any out-ptr may be NULL; all fields are
// zero before the first add_frame. (Declaration added 2026-07-11 — the
// implementation predates it and the pwsfm shim already consumed it.)
void aether_sfm_debug_last(aether_sfm_session_t* s, double* extract_ms,
                           double* match_ms, int* n_cand, int* gpu_matches,
                           int* cpu_matches);

// Cumulative streaming-quality counters over the whole capture — which floater
// filter did what. tvg_pairs/raw_pairs = grow/create pairs from the geometric
// (TVG RANSAC) inliers vs raw-fallback; grow_accepted/rejected = growth
// observations kept vs gated; reproj_filtered/tri_filtered = obs culled by the
// post-BA reprojection and multi-view triangulation-angle filters. Nullable.
void aether_sfm_stream_stats(aether_sfm_session_t* s, int64_t* tvg_pairs,
                             int64_t* raw_pairs, int64_t* grow_accepted,
                             int64_t* grow_rejected, int64_t* reproj_filtered,
                             int64_t* tri_filtered,
                             int64_t* grow_reject_cheirality,
                             int64_t* grow_reject_reproj,
                             int64_t* create_reject_cheirality,
                             int64_t* create_reject_tri_angle,
                             int64_t* create_reject_reproj,
                             int64_t* already_assigned,
                             int64_t* merge_needed,
                             int64_t* merge_accepted,
                             int64_t* merge_rejected,
                             int64_t* spatial_considered,
                             int64_t* spatial_attempted,
                             int64_t* spatial_written,
                             int64_t* spatial_inliers,
                             int64_t* spatial_anchor_attempted,
                             int64_t* spatial_anchor_passed,
                             int64_t* spatial_regions_confirmed,
                             int64_t* spatial_expanded_attempted,
                             int64_t* spatial_guided_pairs,
                             int64_t* spatial_guided_inliers,
                             int64_t* spatial_quadratic_attempted,
                             int64_t* spatial_quadratic_written,
                             int64_t* spatial_budget_skipped,
                             int64_t* temporal_detail_pairs,
                             int64_t* temporal_detail_matches,
                             int64_t* temporal_detail_created,
                             int64_t* temporal_detail_grown,
                             int64_t* temporal_detail_reject_cheirality,
                             int64_t* temporal_detail_reject_reproj,
                             int64_t* temporal_detail_reject_tri_angle,
                             int64_t* temporal_detail_conflicts);

// Live-recon quality snapshot + merge-gate reject-reason breakdown (the
// rejected total is in aether_sfm_stream_stats; these three attribute it).
// mean_reproj_px is computed on demand over every live observation with the
// recon's own camera. Same threading contract as aether_sfm_stream_stats:
// call from the add_frame worker thread. All out-params nullable.
void aether_sfm_live_diag(aether_sfm_session_t* s, double* mean_reproj_px,
                          int64_t* n_points, int64_t* n_track3plus,
                          int64_t* n_obs, int64_t* merge_reject_shared_image,
                          int64_t* merge_reject_reproj,
                          int64_t* merge_reject_missing);

// [SPATIAL-FIRST 2026-07-11] Capture-time candidate-selection attribution:
// spatial_first_pairs = add_frame match candidates chosen by the spatial K-NN
// ∩ view-angle rule; temporal_fallback_pairs = candidates from the temporal
// fill (spatial set short) or the full no-pose temporal fallback. Their sum is
// the total match pairs attempted during capture. Same threading contract as
// aether_sfm_stream_stats (call from the add_frame worker). Nullable.
void aether_sfm_candidate_stats(aether_sfm_session_t* s,
                                int64_t* spatial_first_pairs,
                                int64_t* temporal_fallback_pairs);

// [MATCH-FAIL TELEMETRY + FINALIZE-REMATCH 2026-07-11] Capture-time GPU
// matcher failure accounting + finalize starved-frame re-match counters.
// Motivation: a thermally throttled Metal matcher fails whole SEGMENTS of
// pairs during capture (fail-closed skips → the db silently lacks those
// matches → contiguous frame blocks never register). gpu_fail_* expose the
// formerly-silent failures (by_rc = 8 int64 buckets indexed by the
// pwsfm_gpu_match return code: 1=bad args, 2=Metal unavailable, 5/6=buffer
// alloc, 7=command-buffer error; bucket 0 = out-of-range). rematch_* count
// the finalize pass that re-runs missing temporal-window pairs for starved
// frames through the same matcher route (cooler at finish time) before
// RunIncremental consumes the db. Same threading contract as
// aether_sfm_stream_stats. All out-params nullable.
void aether_sfm_match_fail_stats(aether_sfm_session_t* s,
                                 int64_t* gpu_fail_total,
                                 int64_t* gpu_fail_by_rc,
                                 int64_t* gpu_fail_max_streak,
                                 int64_t* rematch_starved_frames,
                                 int64_t* rematch_candidates,
                                 int64_t* rematch_attempted,
                                 int64_t* rematch_written,
                                 int64_t* rematch_inliers,
                                 int64_t* rematch_failed);

// [THERMAL-THROTTLE 2026-07-11] Platform push of the ProcessInfo thermal
// bucket (0 nominal · 1 fair · 2 serious · 3 critical; anything else =
// unknown, never throttles). Call right before aether_sfm_add_frame. When the
// state is serious/critical AND the throttle is enabled, add_frame reduces
// its live match-candidate window (production 12 → AETHER_LIVE_CAND_K_HOT)
// so the Metal matcher yields GPU time to the camera pipeline under thermal
// pressure (cap45 camera-freeze root cause). Throttled frames are re-matched
// to the full temporal window by the finalize starved-frame pass.
// ⚠️ Throttle ships DEFAULT OFF (host A/B 2026-07-11: cap45 delivered +2.4%
// MORE points than the ±2% gate — positive-direction band exceed via the
// finalize backfill; see aether_sfm_c.cc). Opt-in: AETHER_LIVE_CAND_K_HOT=6.
// Pushing the thermal state itself is always safe/no-op when disabled.
void aether_sfm_set_thermal_state(aether_sfm_session_t* s, int state);

// [THERMAL-THROTTLE 2026-07-11] Telemetry: frames fed with the reduced live K
// this capture (0 = throttle never engaged). Same threading contract as
// aether_sfm_stream_stats. Nullable out-param.
void aether_sfm_thermal_throttle_stats(aether_sfm_session_t* s,
                                       int64_t* throttled_frames);

// [P1-LIVE-REPAY 2026-07-11] Capture-idle debt repayment: re-match up to
// max_pairs missing temporal-window pairs of currently starved frames (GPU
// matcher failures / thermal-throttled frames) through the same matcher route
// and db-write sequence as add_frame — prepaying the debt the finalize
// starved-frame re-match would otherwise pay on a hot finish-time GPU (cap46:
// 336 pairs at ~410 ms → 137.9 s enrichment; a healthy capture-time GPU pair
// costs ~16 ms). Call from the SAME worker thread as add_frame, only when the
// frame queue has slack (offer interval > processing time). Refuses outright
// at thermal serious/critical (never adds GPU load to the condition that
// caused the debt). Each missing pair is attempted at most once per session;
// the finalize re-match remains the safety net for anything still missing.
// db-only (the live preview recon is untouched), so the delivered model is
// identical whether a pair was repaid live or at finalize. Returns pairs
// written this call (0 = nothing to do / refused), -1 on bad args.
int aether_sfm_live_repay(aether_sfm_session_t* s, int max_pairs);

// [P1 2026-07-11] Finalize-speedup package counters: idle repay (see
// aether_sfm_live_repay), rc=7 backoff-retry (gpu_retry_attempts = extra
// matcher invocations, gpu_retry_recovered = pairs saved by a retry;
// AETHER_GPU_MATCH_RETRY=0 disables), and the finalize enrichment time
// budget (enrich_budget_stopped = fresh match attempts skipped after the
// budget was exhausted; AETHER_ENRICH_TIME_BUDGET_MS unset = auto/stage-1
// window, >0 = fixed ms, <=0 = off). Same threading contract as
// aether_sfm_stream_stats. All out-params nullable.
void aether_sfm_repair_stats(aether_sfm_session_t* s, int64_t* repay_calls,
                             int64_t* repay_attempted, int64_t* repay_written,
                             int64_t* repay_inliers, int64_t* repay_failed,
                             int64_t* repay_skipped_thermal,
                             int64_t* gpu_retry_attempts,
                             int64_t* gpu_retry_recovered,
                             int64_t* enrich_budget_stopped);

// Finalize-output quality snapshot: the live_diag quality fields computed over
// the CURRENT finalize reconstruction (LOCAL or REFINED — whichever the
// getters serve; snapshotted under the recon mutex, safe alongside the async
// refine). mean_reproj_px uses the recon's own BA-refined camera. All zeros
// before finalize. Out-params nullable.
void aether_sfm_final_diag(aether_sfm_session_t* s, double* mean_reproj_px,
                           int64_t* n_points, int64_t* n_track3plus,
                           int64_t* n_obs);

// [L1-ARBITRATE 2026-07-12] Ghost-layer L1 CasDiffMVS 1-bit arbitration over
// the session's run_dir files: consumes the AETHER_GHOST_MASK=1 finalize-tail
// sidecars (arbitration_plan.bin / arbitration_points.bin / ghost_mask.bin)
// plus the per-ref depth bins written by the platform CoreML runner
// (l1_depth_<frameId>.bin, contract in arbitration_plan.json), applies the
// Mac-calibrated terminal rules (height-domain per-view votes + 3x3-patch
// median + SUP>=2/SEE=0 hysteresis + mirror defense: below-floor evidence
// never rescues; abstain -> visible, 误隐=0 policy) and rewrites
// ghost_mask.bin with the rescued/confirmed bits (5/6) + a
// ghost_arbitration.json stats sidecar. File-driven only — no reconstruction
// state is read, safe on any thread after the runner finished. Returns OK on
// success (out_json gets a stats summary), NOT_REGISTERED when the inputs are
// absent (mask/plan never written or runner never ran — treat as a no-op),
// INTERNAL on real failures. Call AFTER finalize REFINED and after the
// platform runner wrote the depth bins.
aether_sfm_result_t aether_sfm_arbitrate(aether_sfm_session_t* s,
                                         char* out_json, int out_cap);

// [AETHER BA-MIXED A/B 2026-07-11] Debug/bench-only: write the current
// authoritative reconstruction (refined after REFINED, else live/local) as a
// COLMAP binary model (cameras.bin/images.bin/points3D.bin) into dir, so host
// A/B harnesses can score it with pycolmap-based quality gates verbatim.
// Never called by the app; snapshotted under the recon mutex.
aether_sfm_result_t aether_sfm_debug_dump_model(aether_sfm_session_t* s,
                                                const char* dir);

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
