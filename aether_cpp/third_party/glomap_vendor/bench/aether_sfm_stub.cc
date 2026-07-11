// aether_sfm_stub.cc — simulator-slice (and any non-device) stub for the
// on-device SfM C ABI. The colmap/glomap/ceres/glog archives are arm64-DEVICE
// only (no simulator slice), so the real implementation (aether_sfm_c.cc) can
// only be linked into the device build. On the simulator we still need the FFI
// symbols to exist so the Runner links and dart:ffi dlsym resolves — every
// entry point returns AETHER_SFM_ERR_UNSUPPORTED and the getters report empty.
//
// Selection is build-system driven: the device CMake/podspec compiles
// aether_sfm_c.cc; the simulator compiles this file. They are never both
// linked into the same slice (duplicate symbols otherwise).

#include "aether_sfm_c.h"

#include <cstdio>
#include <cstring>

extern "C" {

void aether_sfm_options_default(aether_sfm_options_t* out) {
  if (!out) return;
  out->max_features = 2048;
  out->image_width = 0;
  out->image_height = 0;
  out->match_max_ratio = 0.7f;
  out->use_gpu_match = 0;
  out->k_neighbors = 6;
}

const char* aether_sfm_result_str(aether_sfm_result_t code) {
  switch (code) {
    case AETHER_SFM_OK: return "AETHER_SFM_OK";
    case AETHER_SFM_ERR_INVALID_ARG: return "AETHER_SFM_ERR_INVALID_ARG";
    case AETHER_SFM_ERR_DB: return "AETHER_SFM_ERR_DB";
    case AETHER_SFM_ERR_EXTRACT: return "AETHER_SFM_ERR_EXTRACT";
    case AETHER_SFM_ERR_NO_INITIAL_PAIR: return "AETHER_SFM_ERR_NO_INITIAL_PAIR";
    case AETHER_SFM_ERR_NOT_REGISTERED: return "AETHER_SFM_ERR_NOT_REGISTERED";
    case AETHER_SFM_ERR_INTERNAL: return "AETHER_SFM_ERR_INTERNAL";
    case AETHER_SFM_ERR_UNSUPPORTED: return "AETHER_SFM_ERR_UNSUPPORTED";
  }
  return "AETHER_SFM_ERR_UNKNOWN";
}

static aether_sfm_result_t Unsupported(char* out_json, int out_cap) {
  if (out_json && out_cap > 0) {
    std::snprintf(out_json, out_cap,
                  "{\"error\":\"on-device SfM unavailable on this slice "
                  "(arm64 device only)\"}");
  }
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_run(const char* db_path, const char* image_path,
                                   const aether_sfm_options_t* options,
                                   aether_sfm_session_t** out_session,
                                   char* out_json, int out_cap) {
  (void)db_path; (void)image_path; (void)options;
  if (out_session) *out_session = nullptr;
  return Unsupported(out_json, out_cap);
}

aether_sfm_result_t aether_sfm_run_dir(const char* capture_dir,
                                       const aether_sfm_options_t* options,
                                       aether_sfm_session_t** out_session,
                                       char* out_json, int out_cap) {
  (void)capture_dir; (void)options;
  if (out_session) *out_session = nullptr;
  return Unsupported(out_json, out_cap);
}

aether_sfm_result_t aether_sfm_create(const char* db_path,
                                      const aether_sfm_options_t* options,
                                      aether_sfm_session_t** out_session) {
  (void)db_path; (void)options;
  if (out_session) *out_session = nullptr;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_add_frame(aether_sfm_session_t* s,
                                         const uint8_t* gray, int width,
                                         int height, float fx, float fy,
                                         float cx, float cy,
                                         const double pose_qwxyz[4],
                                         const double pose_t[3],
                                         int* out_frame_id) {
  (void)s; (void)gray; (void)width; (void)height; (void)fx; (void)fy;
  (void)cx; (void)cy; (void)pose_qwxyz; (void)pose_t;
  if (out_frame_id) *out_frame_id = -1;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_add_frame_features(
    aether_sfm_session_t* s, const float* xy, const uint8_t* desc,
    int n_keypoints, int width, int height, float fx, float fy, float cx,
    float cy, const double pose_qwxyz[4], const double pose_t[3],
    int* out_frame_id) {
  (void)s; (void)xy; (void)desc; (void)n_keypoints; (void)width; (void)height;
  (void)fx; (void)fy; (void)cx; (void)cy; (void)pose_qwxyz; (void)pose_t;
  if (out_frame_id) *out_frame_id = -1;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

void aether_sfm_live_diag(aether_sfm_session_t* s, double* mean_reproj_px,
                          int64_t* n_points, int64_t* n_track3plus,
                          int64_t* n_obs, int64_t* merge_reject_shared_image,
                          int64_t* merge_reject_reproj,
                          int64_t* merge_reject_missing) {
  (void)s;
  if (mean_reproj_px) *mean_reproj_px = 0.0;
  if (n_points) *n_points = 0;
  if (n_track3plus) *n_track3plus = 0;
  if (n_obs) *n_obs = 0;
  if (merge_reject_shared_image) *merge_reject_shared_image = 0;
  if (merge_reject_reproj) *merge_reject_reproj = 0;
  if (merge_reject_missing) *merge_reject_missing = 0;
}

void aether_sfm_candidate_stats(aether_sfm_session_t* s,
                                int64_t* spatial_first_pairs,
                                int64_t* temporal_fallback_pairs) {
  (void)s;
  if (spatial_first_pairs) *spatial_first_pairs = 0;
  if (temporal_fallback_pairs) *temporal_fallback_pairs = 0;
}

void aether_sfm_match_fail_stats(aether_sfm_session_t* s,
                                 int64_t* gpu_fail_total,
                                 int64_t* gpu_fail_by_rc,
                                 int64_t* gpu_fail_max_streak,
                                 int64_t* rematch_starved_frames,
                                 int64_t* rematch_candidates,
                                 int64_t* rematch_attempted,
                                 int64_t* rematch_written,
                                 int64_t* rematch_inliers,
                                 int64_t* rematch_failed) {
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
}

void aether_sfm_final_diag(aether_sfm_session_t* s, double* mean_reproj_px,
                           int64_t* n_points, int64_t* n_track3plus,
                           int64_t* n_obs) {
  (void)s;
  if (mean_reproj_px) *mean_reproj_px = 0.0;
  if (n_points) *n_points = 0;
  if (n_track3plus) *n_track3plus = 0;
  if (n_obs) *n_obs = 0;
}

aether_sfm_result_t aether_sfm_debug_dump_model(aether_sfm_session_t* s,
                                                const char* dir) {
  (void)s;
  (void)dir;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s, char* out_json,
                                        int out_cap) {
  (void)s;
  return Unsupported(out_json, out_cap);
}

aether_sfm_result_t aether_sfm_finalize_async(aether_sfm_session_t* s,
                                              char* out_json, int out_cap) {
  (void)s;
  return Unsupported(out_json, out_cap);
}

int aether_sfm_finalize_status(aether_sfm_session_t* s) {
  (void)s;
  return AETHER_SFM_FINALIZE_ERROR;
}

aether_sfm_result_t aether_sfm_get_poses(aether_sfm_session_t* s,
                                         aether_sfm_pose_t* out_poses, int cap,
                                         int* out_count) {
  (void)s; (void)out_poses; (void)cap;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_get_points(aether_sfm_session_t* s,
                                          aether_sfm_point_t** out_points,
                                          int* out_count) {
  (void)s;
  if (out_points) *out_points = nullptr;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

void aether_sfm_points_free(aether_sfm_point_t* points) { (void)points; }

aether_sfm_result_t aether_sfm_get_preview_points(aether_sfm_session_t* s,
                                                  float* out_xyz, int cap,
                                                  int* out_count) {
  (void)s;
  (void)out_xyz;
  (void)cap;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

void aether_sfm_free(aether_sfm_session_t* s) { (void)s; }

}  // extern "C"
