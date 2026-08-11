#include <stdlib.h>
#include <string.h>

#include "../include/aether_sfm_c.h"

// Simulator-only private backend for the official forwarding shim. The product
// never executes SfM on a simulator; these definitions keep both simulator
// architectures linkable without importing the self-route static stub.
void aether_sfm_options_default(aether_sfm_options_t* out) {
  if (out == NULL) return;
  out->max_features = 2048;
  out->image_width = 0;
  out->image_height = 0;
  out->match_max_ratio = 0.8f;
  out->use_gpu_match = 0;
  out->k_neighbors = 6;
  out->use_gpu_extract = 0;
}

aether_sfm_result_t aether_sfm_run(const char* db_path,
                                   const char* image_path,
                                   const aether_sfm_options_t* options,
                                   aether_sfm_session_t** out_session,
                                   char* out_json, int out_cap) {
  (void)db_path;
  (void)image_path;
  (void)options;
  if (out_session) *out_session = NULL;
  if (out_json && out_cap > 0) out_json[0] = '\0';
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_create(const char* db_path,
                                      const aether_sfm_options_t* options,
                                      aether_sfm_session_t** out_session) {
  (void)db_path;
  (void)options;
  if (out_session) *out_session = NULL;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_add_frame(aether_sfm_session_t* session,
                                         const uint8_t* gray,
                                         int width, int height,
                                         float fx, float fy,
                                         float cx, float cy,
                                         const double pose_qwxyz[4],
                                         const double pose_t[3],
                                         int* out_frame_id) {
  (void)session;
  (void)gray;
  (void)width;
  (void)height;
  (void)fx;
  (void)fy;
  (void)cx;
  (void)cy;
  (void)pose_qwxyz;
  (void)pose_t;
  if (out_frame_id) *out_frame_id = -1;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_get_poses(aether_sfm_session_t* session,
                                         aether_sfm_pose_t* out_poses,
                                         int cap, int* out_count) {
  (void)session;
  (void)out_poses;
  (void)cap;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

aether_sfm_result_t aether_sfm_get_points(aether_sfm_session_t* session,
                                          aether_sfm_point_t** out_points,
                                          int* out_count) {
  (void)session;
  if (out_points) *out_points = NULL;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
}

void aether_sfm_points_free(aether_sfm_point_t* points) { free(points); }

void aether_sfm_free(aether_sfm_session_t* session) { (void)session; }
