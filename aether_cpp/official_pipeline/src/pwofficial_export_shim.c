// pwofficial_export_shim.c — dlsym-visibility shim for the on-device SfM ABI.
//
// WHY: the Jun-29 COLMAP-4.0.4 libglomap_core.a compiles its TUs with
// -fvisibility=hidden, so every aether_sfm_* symbol is "private external"
// in the archive and gets LOCALIZED when statically linked into Runner —
// dart:ffi's dlsym(RTLD_DEFAULT, …) then can't find them (verified via
// `dyld_info -exports`: zero aether_sfm entries; nm shows lowercase 't').
// No linker flag can re-export a hidden symbol.
//
// FIX: this TU is compiled INTO the pod with explicit default visibility.
// Static linking within the binary is unaffected by hidden visibility, so
// these pure forwarders resolve against the force-loaded archive at link
// time, and their OWN pwofficial_* names land in the export trie for dlsym.
// Pure pass-through — zero algorithm logic lives here. The Dart binding
// (aether_sfm_ffi.dart) looks up the pwofficial_* names.
//
// Runner links this via -Wl,-u,_pwofficial_* (see aether3d_ffi.podspec): -u both
// pulls this object out of the pod archive and keeps each symbol through
// Release -dead_strip.
//
// SIMULATOR: the sim stub libaether_sfm.a predates finalize_async/status,
// so those two forwards would be undefined there — guarded to return
// UNSUPPORTED instead (the Dart layer gates on isSupported and never calls
// SfM on the simulator anyway; this just keeps the sim LINK green).

#include <TargetConditionals.h>

#include "../include/aether_sfm_c.h"

#define PWOFFICIAL_EXPORT __attribute__((visibility("default"), used))
#define PWOFFICIAL_HIDDEN __attribute__((visibility("hidden")))

// Stage-B instrumentation overlay seam. Device builds link the hidden private
// bridge object. Simulator packaging has no instrumentation carrier, so it
// receives proven local no-ops and cannot acquire unresolved bridge symbols.
// These calls are deliberately absent from both public ABI headers and never
// alter a forwarded result or output.
#if TARGET_OS_SIMULATOR
static void aether_preclamp_stage_b_bridge_create(void* session) {
  (void)session;
}
static void aether_preclamp_stage_b_bridge_thermal(void* session, int state) {
  (void)session;
  (void)state;
}
static void aether_preclamp_stage_b_bridge_pre_add(void* session) {
  (void)session;
}
static void aether_preclamp_stage_b_bridge_add(void* session, int result,
                                                const int* out_frame_id) {
  (void)session;
  (void)result;
  (void)out_frame_id;
}
static void aether_preclamp_stage_b_bridge_remove(void* session, int result) {
  (void)session;
  (void)result;
}
static void aether_preclamp_stage_b_bridge_finalize(void* session, int result) {
  (void)session;
  (void)result;
}
static void aether_preclamp_stage_b_bridge_free(void* session) {
  (void)session;
}
#else
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_create(void* session);
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_thermal(void* session,
                                                              int state);
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_pre_add(void* session);
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_add(
    void* session, int result, const int* out_frame_id);
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_remove(void* session,
                                                             int result);
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_finalize(void* session,
                                                               int result);
PWOFFICIAL_HIDDEN void aether_preclamp_stage_b_bridge_free(void* session);
#endif

PWOFFICIAL_EXPORT void pwofficial_options_default(aether_sfm_options_t* out) {
  aether_sfm_options_default(out);
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_run(const char* db_path,
                                           const char* image_path,
                                           const aether_sfm_options_t* options,
                                           aether_sfm_session_t** out_session,
                                           char* out_json, int out_cap) {
  return aether_sfm_run(db_path, image_path, options, out_session, out_json,
                        out_cap);
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_create(const char* db_path,
                                              const aether_sfm_options_t* options,
                                              aether_sfm_session_t** out_session) {
  const aether_sfm_result_t result =
      aether_sfm_create(db_path, options, out_session);
  if (result == AETHER_SFM_OK && out_session != 0 && *out_session != 0) {
    aether_preclamp_stage_b_bridge_create(*out_session);
  }
  return result;
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_add_frame(aether_sfm_session_t* s,
                                                 const uint8_t* gray,
                                                 int width, int height,
                                                 float fx, float fy,
                                                 float cx, float cy,
                                                 const double pose_qwxyz[4],
                                                 const double pose_t[3],
                                                 int* out_frame_id) {
  aether_preclamp_stage_b_bridge_pre_add(s);
  const aether_sfm_result_t result =
      aether_sfm_add_frame(s, gray, width, height, fx, fy, cx, cy,
                           pose_qwxyz, pose_t, out_frame_id);
  aether_preclamp_stage_b_bridge_add(s, result, out_frame_id);
  return result;
}

/* [REMOVE-FRAME 2026-07-20] 用户删照片 → 撤回该帧的全部重建贡献。
   转发到 aether_sfm_remove_frame(内部全部是 COLMAP 现成操作:
   ObservationManager::DeRegisterFrame + Database::DeleteMatches/
   DeleteTwoViewGeometry)。模拟器无 native slice,返回 UNSUPPORTED。 */
PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_remove_frame(aether_sfm_session_t* s,
                                                    int frame_id,
                                                    char* out_json,
                                                    int out_cap) {
  aether_sfm_result_t result;
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)frame_id;
  (void)out_json;
  (void)out_cap;
  result = AETHER_SFM_ERR_UNSUPPORTED;
#else
  result = aether_sfm_remove_frame(s, frame_id, out_json, out_cap);
#endif
  aether_preclamp_stage_b_bridge_remove(s, result);
  return result;
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_finalize_async(aether_sfm_session_t* s,
                                                      char* out_json,
                                                      int out_cap) {
  aether_sfm_result_t result;
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_json;
  (void)out_cap;
  result = AETHER_SFM_ERR_UNSUPPORTED;
#else
  result = aether_sfm_finalize_async(s, out_json, out_cap);
#endif
  aether_preclamp_stage_b_bridge_finalize(s, result);
  return result;
}

PWOFFICIAL_EXPORT int pwofficial_finalize_status(aether_sfm_session_t* s) {
#if TARGET_OS_SIMULATOR
  (void)s;
  return AETHER_SFM_FINALIZE_ERROR;
#else
  return aether_sfm_finalize_status(s);
#endif
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_get_poses(aether_sfm_session_t* s,
                                                 aether_sfm_pose_t* out_poses,
                                                 int cap, int* out_count) {
  return aether_sfm_get_poses(s, out_poses, cap, out_count);
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_get_points(aether_sfm_session_t* s,
                                                  aether_sfm_point_t** out_points,
                                                  int* out_count) {
  return aether_sfm_get_points(s, out_points, out_count);
}

PWOFFICIAL_EXPORT void pwofficial_points_free(aether_sfm_point_t* points) {
  aether_sfm_points_free(points);
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_get_preview_points(
    aether_sfm_session_t* s, float* out_xyz, int cap, int* out_count) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_xyz;
  (void)cap;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_get_preview_points(s, out_xyz, cap, out_count);
#endif
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_get_points_tracked(
    aether_sfm_session_t* s, aether_sfm_point_t** out_points, int* out_count,
    int32_t** out_obs_offsets, aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_points;
  (void)out_count;
  (void)out_obs_offsets;
  (void)out_obs;
  (void)out_obs_count;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_get_points_tracked(s, out_points, out_count,
                                       out_obs_offsets, out_obs,
                                       out_obs_count);
#endif
}

PWOFFICIAL_EXPORT void pwofficial_track_obs_free(int32_t* offsets,
                                       aether_sfm_track_obs_t* obs) {
#if TARGET_OS_SIMULATOR
  (void)offsets;
  (void)obs;
#else
  aether_sfm_track_obs_free(offsets, obs);
#endif
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_get_preview_tracked(
    aether_sfm_session_t* s, aether_sfm_point_t** out_points, int* out_count,
    int32_t** out_obs_offsets, aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_points;
  (void)out_count;
  (void)out_obs_offsets;
  (void)out_obs;
  (void)out_obs_count;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_get_preview_tracked(s, out_points, out_count,
                                        out_obs_offsets, out_obs,
                                        out_obs_count);
#endif
}

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_global_refine(aether_sfm_session_t* s) {
#if TARGET_OS_SIMULATOR
  (void)s;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_global_refine(s);
#endif
}

PWOFFICIAL_EXPORT void pwofficial_debug_last(aether_sfm_session_t* s, double* extract_ms,
                                   double* match_ms, int* n_cand,
                                   int* gpu_matches, int* cpu_matches) {
#if TARGET_OS_SIMULATOR
  (void)s; (void)extract_ms; (void)match_ms; (void)n_cand;
  (void)gpu_matches; (void)cpu_matches;
#else
  aether_sfm_debug_last(s, extract_ms, match_ms, n_cand, gpu_matches,
                        cpu_matches);
#endif
}

PWOFFICIAL_EXPORT void pwofficial_stream_stats(aether_sfm_session_t* s, int64_t* tvg_pairs,
                                     int64_t* raw_pairs, int64_t* grow_accepted,
                                     int64_t* grow_rejected,
                                     int64_t* reproj_filtered,
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
                                     int64_t* temporal_detail_conflicts) {
#if TARGET_OS_SIMULATOR
  (void)s; (void)tvg_pairs; (void)raw_pairs; (void)grow_accepted;
  (void)grow_rejected; (void)reproj_filtered; (void)tri_filtered;
  (void)grow_reject_cheirality; (void)grow_reject_reproj;
  (void)create_reject_cheirality; (void)create_reject_tri_angle;
  (void)create_reject_reproj; (void)already_assigned; (void)merge_needed;
  (void)merge_accepted; (void)merge_rejected; (void)spatial_considered;
  (void)spatial_attempted; (void)spatial_written; (void)spatial_inliers;
  (void)spatial_anchor_attempted; (void)spatial_anchor_passed;
  (void)spatial_regions_confirmed; (void)spatial_expanded_attempted;
  (void)spatial_guided_pairs; (void)spatial_guided_inliers;
  (void)spatial_quadratic_attempted; (void)spatial_quadratic_written;
  (void)spatial_budget_skipped;
  (void)temporal_detail_pairs; (void)temporal_detail_matches;
  (void)temporal_detail_created; (void)temporal_detail_grown;
  (void)temporal_detail_reject_cheirality;
  (void)temporal_detail_reject_reproj;
  (void)temporal_detail_reject_tri_angle; (void)temporal_detail_conflicts;
#else
  aether_sfm_stream_stats(s, tvg_pairs, raw_pairs, grow_accepted, grow_rejected,
                          reproj_filtered, tri_filtered,
                          grow_reject_cheirality, grow_reject_reproj,
                          create_reject_cheirality, create_reject_tri_angle,
                          create_reject_reproj, already_assigned, merge_needed,
                          merge_accepted, merge_rejected, spatial_considered,
                          spatial_attempted, spatial_written, spatial_inliers,
                          spatial_anchor_attempted, spatial_anchor_passed,
                          spatial_regions_confirmed, spatial_expanded_attempted,
                          spatial_guided_pairs, spatial_guided_inliers,
                          spatial_quadratic_attempted, spatial_quadratic_written,
                          spatial_budget_skipped, temporal_detail_pairs,
                          temporal_detail_matches, temporal_detail_created,
                          temporal_detail_grown,
                          temporal_detail_reject_cheirality,
                          temporal_detail_reject_reproj,
                          temporal_detail_reject_tri_angle,
                          temporal_detail_conflicts);
#endif
}

// [SPATIAL-FIRST 2026-07-11] Capture-time candidate-selection attribution
// (spatial K-NN picks vs temporal fill/fallback). Guarded like stream_stats:
// the simulator stub archive predates this symbol, so zero-fill there.
PWOFFICIAL_EXPORT void pwofficial_candidate_stats(aether_sfm_session_t* s,
                                        int64_t* spatial_first_pairs,
                                        int64_t* temporal_fallback_pairs) {
#if TARGET_OS_SIMULATOR
  (void)s;
  if (spatial_first_pairs) *spatial_first_pairs = 0;
  if (temporal_fallback_pairs) *temporal_fallback_pairs = 0;
#else
  aether_sfm_candidate_stats(s, spatial_first_pairs, temporal_fallback_pairs);
#endif
}

// [MATCH-FAIL TELEMETRY 2026-07-11] Capture-time GPU matcher failure buckets
// (by pwofficial_gpu_match rc) + finalize starved-frame re-match counters — the
// cap44 observability gap: these existed in the archive since 07-11 but were
// never exported, so the Dart telemetry could not persist them. Guarded like
// candidate_stats: the simulator stub archive predates this symbol, zero-fill
// there. gpu_fail_by_rc, if non-NULL, must point at 8 int64 slots.
PWOFFICIAL_EXPORT void pwofficial_match_fail_stats(aether_sfm_session_t* s,
                                         int64_t* gpu_fail_total,
                                         int64_t* gpu_fail_by_rc,
                                         int64_t* gpu_fail_max_streak,
                                         int64_t* rematch_starved_frames,
                                         int64_t* rematch_candidates,
                                         int64_t* rematch_attempted,
                                         int64_t* rematch_written,
                                         int64_t* rematch_inliers,
                                         int64_t* rematch_failed) {
#if TARGET_OS_SIMULATOR
  (void)s;
  if (gpu_fail_total) *gpu_fail_total = 0;
  if (gpu_fail_by_rc) {
    for (int i = 0; i < 8; ++i) gpu_fail_by_rc[i] = 0;
  }
  if (gpu_fail_max_streak) *gpu_fail_max_streak = 0;
  if (rematch_starved_frames) *rematch_starved_frames = 0;
  if (rematch_candidates) *rematch_candidates = 0;
  if (rematch_attempted) *rematch_attempted = 0;
  if (rematch_written) *rematch_written = 0;
  if (rematch_inliers) *rematch_inliers = 0;
  if (rematch_failed) *rematch_failed = 0;
#else
  aether_sfm_match_fail_stats(s, gpu_fail_total, gpu_fail_by_rc,
                              gpu_fail_max_streak, rematch_starved_frames,
                              rematch_candidates, rematch_attempted,
                              rematch_written, rematch_inliers,
                              rematch_failed);
#endif
}

// [THERMAL-THROTTLE 2026-07-11] Platform thermal push (0..3, ProcessInfo
// bucket) — the Dart worker calls this right before each add_frame so the
// archive can halve the live match window under thermal serious (cap45
// camera-freeze fix). Simulator stub archive predates the symbol: no-op there
// (Dart gates on isSupported and never drives SfM on the simulator anyway).
PWOFFICIAL_EXPORT void pwofficial_set_thermal_state(aether_sfm_session_t* s, int state) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)state;
#else
  aether_sfm_set_thermal_state(s, state);
#endif
  aether_preclamp_stage_b_bridge_thermal(s, state);
}

// [THERMAL-THROTTLE 2026-07-11] Frames fed with the reduced live K this
// capture (telemetry; 0 = throttle never engaged). Zero-fill on simulator.
PWOFFICIAL_EXPORT void pwofficial_thermal_throttle_stats(aether_sfm_session_t* s,
                                               int64_t* throttled_frames) {
#if TARGET_OS_SIMULATOR
  (void)s;
  if (throttled_frames) *throttled_frames = 0;
#else
  aether_sfm_thermal_throttle_stats(s, throttled_frames);
#endif
}

// [P1-LIVE-REPAY 2026-07-11] Capture-idle debt repayment: re-match up to
// max_pairs missing temporal-window pairs of starved frames through the
// add_frame matcher route (db-only; thermal serious/critical refuses).
// Guarded like match_fail_stats: the simulator stub archive predates this
// symbol — return 0 (nothing to do) there.
PWOFFICIAL_EXPORT int pwofficial_live_repay(aether_sfm_session_t* s, int max_pairs) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)max_pairs;
  return 0;
#else
  return aether_sfm_live_repay(s, max_pairs);
#endif
}

// [P1 2026-07-11] Finalize-speedup package counters: idle repay (see
// pwofficial_live_repay), rc=7 backoff-retry, and the finalize enrichment time
// budget. Zero-fill on the simulator (stub archive predates the symbol).
PWOFFICIAL_EXPORT void pwofficial_repair_stats(aether_sfm_session_t* s,
                                     int64_t* repay_calls,
                                     int64_t* repay_attempted,
                                     int64_t* repay_written,
                                     int64_t* repay_inliers,
                                     int64_t* repay_failed,
                                     int64_t* repay_skipped_thermal,
                                     int64_t* gpu_retry_attempts,
                                     int64_t* gpu_retry_recovered,
                                     int64_t* enrich_budget_stopped) {
#if TARGET_OS_SIMULATOR
  (void)s;
  if (repay_calls) *repay_calls = 0;
  if (repay_attempted) *repay_attempted = 0;
  if (repay_written) *repay_written = 0;
  if (repay_inliers) *repay_inliers = 0;
  if (repay_failed) *repay_failed = 0;
  if (repay_skipped_thermal) *repay_skipped_thermal = 0;
  if (gpu_retry_attempts) *gpu_retry_attempts = 0;
  if (gpu_retry_recovered) *gpu_retry_recovered = 0;
  if (enrich_budget_stopped) *enrich_budget_stopped = 0;
#else
  aether_sfm_repair_stats(s, repay_calls, repay_attempted, repay_written,
                          repay_inliers, repay_failed, repay_skipped_thermal,
                          gpu_retry_attempts, gpu_retry_recovered,
                          enrich_budget_stopped);
#endif
}

// [L1-ARBITRATE 2026-07-12] Ghost-layer L1 CasDiffMVS 1-bit arbitration
// (file-driven over the run_dir; see aether_sfm_c.h). WEAK-IMPORT forward:
// the CURRENTLY vendored libglomap_core.a predates the symbol and the iOS
// archive rebuild ships in the next unified wave — the weak reference lets
// today's Runner link (podspec adds -Wl,-U,_aether_sfm_arbitrate) and
// resolves to NULL at runtime until the rebuilt archive lands, in which case
// this returns UNSUPPORTED and the Dart side treats L1 as a no-op.
#if !TARGET_OS_SIMULATOR
extern aether_sfm_result_t aether_sfm_arbitrate(aether_sfm_session_t* s,
                                                char* out_json, int out_cap)
    __attribute__((weak_import));
#endif

PWOFFICIAL_EXPORT aether_sfm_result_t pwofficial_arbitrate(aether_sfm_session_t* s,
                                                 char* out_json, int out_cap) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_json;
  (void)out_cap;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  if (&aether_sfm_arbitrate == 0) return AETHER_SFM_ERR_UNSUPPORTED;
  return aether_sfm_arbitrate(s, out_json, out_cap);
#endif
}

PWOFFICIAL_EXPORT void pwofficial_free(aether_sfm_session_t* s) {
  aether_preclamp_stage_b_bridge_free(s);
  aether_sfm_free(s);
}
