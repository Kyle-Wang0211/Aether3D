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

aether_sfm_result_t aether_sfm_add_frame_with_features(
    aether_sfm_session_t* s, int width, int height, float fx, float fy,
    float cx, float cy, const float* keypoints_stride4,
    const uint8_t* descriptors, unsigned int count,
    const double pose_qwxyz[4], const double pose_t[3], int* out_frame_id) {
  (void)s; (void)width; (void)height; (void)fx; (void)fy; (void)cx; (void)cy;
  (void)keypoints_stride4; (void)descriptors; (void)count; (void)pose_qwxyz;
  (void)pose_t;
  if (out_frame_id) *out_frame_id = -1;
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

aether_sfm_result_t aether_sfm_attach_db_frames(aether_sfm_session_t* s,
                                                int* out_num_frames) {
  (void)s;
  if (out_num_frames) *out_num_frames = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_begin_incremental(aether_sfm_session_t* s,
                                                 char* out_json, int out_cap) {
  (void)s;
  return Unsupported(out_json, out_cap);
}

aether_sfm_result_t aether_sfm_register_next_frame(
    aether_sfm_session_t* s, int frame_id, double out_pose_qwxyz[4],
    double out_pose_t[3], int* out_registered, int* out_new_points,
    int* out_total_points, double* out_reproj) {
  (void)s; (void)frame_id; (void)out_pose_qwxyz; (void)out_pose_t;
  if (out_registered) *out_registered = 0;
  if (out_new_points) *out_new_points = 0;
  if (out_total_points) *out_total_points = 0;
  if (out_reproj) *out_reproj = 0.0;
  return AETHER_SFM_ERR_UNSUPPORTED;
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

void aether_sfm_free(aether_sfm_session_t* s) { (void)s; }

}  // extern "C"
