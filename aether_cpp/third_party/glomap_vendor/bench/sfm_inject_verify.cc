// sfm_inject_verify.cc — HOST verification harness for the GPU-feature
// injection + correspondence-persistence path (gpu-sift-s1 / GAP 1+2+3).
//
// PROVES end-to-end that per-frame streaming registration works with INJECTED
// features (the GPU-extractor seam) + PERSISTED index-pair matches:
//
//   for each of the first N images in a prebuilt COLMAP bench db (real DSP-SIFT
//   features — same distribution the GPU extractor produces):
//       read keypoints(x,y) + 128-D descriptors via colmap::Database
//       -> aether_sfm_add_frame_with_features(...)   [GAP-1 injection]
//            -> WriteKeypoints/WriteDescriptors
//            -> match-persist vs prev k frames        [GAP-2 + GAP-3]
//   -> aether_sfm_finalize()                          [incremental mapper]
//   -> report: registered frames, sparse-cloud point count, mean reproj px.
//
// This is the SfM-side proof; it does not need the GPU device (it feeds the SAME
// feature shape the GPU emits). Build: bench/build_sfm_inject_verify.sh.
//
// Usage: sfm_inject_verify <bench_db.db> <num_frames> [k_neighbors]

#include "aether_sfm_c.h"

#include "colmap/scene/database.h"
#include "colmap/feature/types.h"

#include <glog/logging.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <bench_db.db> <num_frames> [k_neighbors] [max_kp]\n",
                 argv[0]);
    return 2;
  }
  google::InitGoogleLogging(argv[0]);
  FLAGS_minloglevel = 1;  // quiet the per-frame INFO spam; keep warnings+

  const std::string src_db_path = argv[1];
  const int num_frames = std::atoi(argv[2]);
  const int k_neighbors = argc > 3 ? std::atoi(argv[3]) : 6;
  // Optional per-frame keypoint cap. The bench db holds ~16k DSP-SIFT keypoints
  // per image (full-res research extraction); the production GPU extractor caps
  // at 8192. Capping makes the O(n1*n2) CPU brute-force match tractable for host
  // verification while still proving the injection+persist+register path. The
  // bench db keypoints are response-sorted (strongest first), so the top-K cap
  // keeps the most reliable features. 0/absent = no cap (use all).
  const int max_kp = argc > 4 ? std::atoi(argv[4]) : 0;

  // ── 1) Open the bench db (read-only source of real DSP-SIFT features) ──
  std::shared_ptr<colmap::Database> src;
  try {
    src = colmap::Database::Open(src_db_path);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "cannot open src db: %s\n", e.what());
    return 3;
  }
  std::vector<colmap::Image> images = src->ReadAllImages();
  std::fprintf(stderr, "src db: %zu images; streaming first %d (k=%d)\n",
               images.size(), num_frames, k_neighbors);

  // ── 2) Fresh streaming session into a temp db ──
  const std::string out_db_path = "/tmp/sfm_inject_verify_out.db";
  std::remove(out_db_path.c_str());
  // colmap::Database::Open creates the schema if the file is new.
  { auto fresh = colmap::Database::Open(out_db_path); fresh->Close(); }

  aether_sfm_options_t opts;
  aether_sfm_options_default(&opts);
  opts.max_features = 8192;
  opts.k_neighbors = k_neighbors;
  opts.match_max_ratio = 0.7f;

  aether_sfm_session_t* sess = nullptr;
  if (aether_sfm_create(out_db_path.c_str(), &opts, &sess) != AETHER_SFM_OK ||
      !sess) {
    std::fprintf(stderr, "aether_sfm_create failed\n");
    return 4;
  }

  // Reference camera intrinsics from the src db (single shared camera there).
  colmap::Camera ref_cam;
  {
    std::vector<colmap::Camera> cams = src->ReadAllCameras();
    if (!cams.empty()) ref_cam = cams.front();
  }
  const float fx = ref_cam.FocalLengthX() > 0 ? ref_cam.FocalLengthX() : 3200.f;
  const float fy = ref_cam.FocalLengthY() > 0 ? ref_cam.FocalLengthY() : 3200.f;
  const int W = ref_cam.width > 0 ? static_cast<int>(ref_cam.width) : 4224;
  const int H = ref_cam.height > 0 ? static_cast<int>(ref_cam.height) : 2376;
  const float cx = ref_cam.PrincipalPointX() > 0 ? ref_cam.PrincipalPointX()
                                                 : W * 0.5f;
  const float cy = ref_cam.PrincipalPointY() > 0 ? ref_cam.PrincipalPointY()
                                                 : H * 0.5f;

  // ── 3) Stream each image's features through the INJECTION ABI ──
  const int n = std::min<int>(num_frames, static_cast<int>(images.size()));
  int injected = 0;
  for (int i = 0; i < n; ++i) {
    const colmap::image_t image_id = images[i].ImageId();
    colmap::FeatureKeypoints kps = src->ReadKeypoints(image_id);
    colmap::FeatureDescriptors desc = src->ReadDescriptors(image_id);
    const int nk = static_cast<int>(kps.size());
    const int nd = static_cast<int>(desc.data.rows());
    int cnt = std::min(nk, nd);
    if (cnt <= 0 || desc.data.cols() != 128) continue;
    if (max_kp > 0 && cnt > max_kp) cnt = max_kp;  // top-K cap

    // GPU-native stride-4 {x,y,sigma,octave}; sigma/octave unused -> 0.
    std::vector<float> kp4(static_cast<size_t>(cnt) * 4, 0.f);
    for (int j = 0; j < cnt; ++j) {
      kp4[j * 4 + 0] = kps[j].x;
      kp4[j * 4 + 1] = kps[j].y;
    }
    std::vector<uint8_t> d(static_cast<size_t>(cnt) * 128);
    std::memcpy(d.data(), desc.data.data(), static_cast<size_t>(cnt) * 128);

    int frame_id = -1;
    const aether_sfm_result_t rc = aether_sfm_add_frame_with_features(
        sess, W, H, fx, fy, cx, cy, kp4.data(), d.data(),
        static_cast<unsigned int>(cnt),
        /*pose_qwxyz=*/nullptr, /*pose_t=*/nullptr, &frame_id);
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "inject frame %d FAILED rc=%d (%s)\n", i, rc,
                   aether_sfm_result_str(rc));
      aether_sfm_free(sess);
      return 5;
    }
    ++injected;
    if ((i + 1) % 25 == 0)
      std::fprintf(stderr, "  injected %d/%d frames (%d kp last)\n", i + 1, n,
                   cnt);
  }
  std::fprintf(stderr, "injected %d frames; finalizing (incremental mapper)\n",
               injected);

  // ── 4) Finalize: run the incremental mapper over the accumulated db ──
  char json[512] = {0};
  const aether_sfm_result_t frc = aether_sfm_finalize(sess, json, sizeof(json));
  std::fprintf(stderr, "finalize rc=%d (%s)\n", frc,
               aether_sfm_result_str(frc));
  std::fprintf(stdout, "FINALIZE_JSON %s\n", json);

  // ── 5) Read back the proof: registered poses + sparse cloud ──
  int pose_total = 0;
  aether_sfm_get_poses(sess, nullptr, 0, &pose_total);
  std::vector<aether_sfm_pose_t> poses(pose_total > 0 ? pose_total : 1);
  int pose_count = 0;
  aether_sfm_get_poses(sess, poses.data(), pose_total, &pose_count);
  int registered = 0;
  for (int i = 0; i < pose_count; ++i)
    if (poses[i].registered) ++registered;

  int npts = 0;
  aether_sfm_get_points(sess, nullptr, &npts);

  std::fprintf(stdout,
               "RESULT injected=%d images_in_recon=%d registered=%d "
               "points3d=%d\n",
               injected, pose_count, registered, npts);

  aether_sfm_free(sess);
  const bool ok = (frc == AETHER_SFM_OK) && registered >= 2 && npts > 0;
  std::fprintf(stdout, "VERDICT %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
