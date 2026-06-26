// sfm_stream_verify.cc — HOST verification of the TRUE per-frame incremental
// register ABI (aether_sfm_begin_incremental + aether_sfm_register_next_frame),
// gated against the batch finalize baseline on the SAME real capture sequence.
//
// Pipeline (mirrors sfm_inject_verify.cc's inject path, then streams register):
//   for each of the first N images in a prebuilt COLMAP bench db (real DSP-SIFT
//   features — same distribution the GPU extractor produces):
//       read keypoints(x,y) + 128-D descriptors via colmap::Database
//       -> aether_sfm_add_frame_with_features(...)   [inject + match-persist]
//   -> aether_sfm_begin_incremental()                 [bootstrap seed]
//   -> for each frame: aether_sfm_register_next_frame()   [TRUE step-3]
//        log: frame#, registered, new_points, total_cloud_points, per_frame_ms,
//             reproj  (the per-frame growth + cost + reproj curves)
//
// Then, on a SECOND session with the SAME injected db, run aether_sfm_finalize()
// (batch) for the baseline reproj the incremental final must not exceed.
//
// VERIFY gates (printed as VERIFY_* lines + a final VERDICT):
//   (a) cloud_grows_per_frame — total grows on most frames after the seed
//   (b) reproj_holds          — incremental final reproj <= batch baseline
//   (c) cost_bounded          — per_frame_ms median/p95 do NOT grow O(N)
//   (d) bootstrap_works       — the seed succeeded and registration proceeded
//
// Usage: sfm_stream_verify <bench_db.db> <num_frames> [k_neighbors] [max_kp]

#include "aether_sfm_c.h"

#include "colmap/scene/database.h"
#include "colmap/feature/types.h"

#include <glog/logging.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

// Inject the first `n` images' real DSP-SIFT features from `src` into a fresh
// streaming session at out_db_path (the SAME inject+match-persist path as
// sfm_inject_verify.cc). Returns the open session + the per-frame frame_ids.
aether_sfm_session_t* BuildInjectedSession(colmap::Database& src,
                                           const std::vector<colmap::Image>& images,
                                           int n, int k_neighbors, int max_kp,
                                           const std::string& out_db_path,
                                           std::vector<int>* frame_ids) {
  std::remove(out_db_path.c_str());
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
    return nullptr;
  }

  colmap::Camera ref_cam;
  {
    std::vector<colmap::Camera> cams = src.ReadAllCameras();
    if (!cams.empty()) ref_cam = cams.front();
  }
  const float fx = ref_cam.FocalLengthX() > 0 ? ref_cam.FocalLengthX() : 3200.f;
  const float fy = ref_cam.FocalLengthY() > 0 ? ref_cam.FocalLengthY() : 3200.f;
  const int W = ref_cam.width > 0 ? static_cast<int>(ref_cam.width) : 4224;
  const int H = ref_cam.height > 0 ? static_cast<int>(ref_cam.height) : 2376;
  const float cx =
      ref_cam.PrincipalPointX() > 0 ? ref_cam.PrincipalPointX() : W * 0.5f;
  const float cy =
      ref_cam.PrincipalPointY() > 0 ? ref_cam.PrincipalPointY() : H * 0.5f;

  frame_ids->clear();
  for (int i = 0; i < n; ++i) {
    const colmap::image_t image_id = images[i].ImageId();
    colmap::FeatureKeypoints kps = src.ReadKeypoints(image_id);
    colmap::FeatureDescriptors desc = src.ReadDescriptors(image_id);
    const int nk = static_cast<int>(kps.size());
    const int nd = static_cast<int>(desc.data.rows());
    int cnt = std::min(nk, nd);
    if (cnt <= 0 || desc.data.cols() != 128) continue;
    if (max_kp > 0 && cnt > max_kp) cnt = max_kp;

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
        static_cast<unsigned int>(cnt), /*pose_qwxyz=*/nullptr,
        /*pose_t=*/nullptr, &frame_id);
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "inject frame %d FAILED rc=%d (%s)\n", i, rc,
                   aether_sfm_result_str(rc));
      aether_sfm_free(sess);
      return nullptr;
    }
    frame_ids->push_back(frame_id);
    if ((i + 1) % 25 == 0)
      std::fprintf(stderr, "  injected %d/%d frames (%d kp last)\n", i + 1, n,
                   cnt);
  }
  return sess;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <bench_db.db> <num_frames> [k_neighbors] [max_kp]\n",
                 argv[0]);
    return 2;
  }
  google::InitGoogleLogging(argv[0]);
  FLAGS_minloglevel = 2;  // quiet INFO+WARNING; keep ERROR

  const std::string src_db_path = argv[1];
  const int num_frames = std::atoi(argv[2]);
  const int k_neighbors = argc > 3 ? std::atoi(argv[3]) : 6;
  const int max_kp = argc > 4 ? std::atoi(argv[4]) : 0;

  std::shared_ptr<colmap::Database> src;
  try {
    src = colmap::Database::Open(src_db_path);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "cannot open src db: %s\n", e.what());
    return 3;
  }
  std::vector<colmap::Image> images = src->ReadAllImages();
  const int n = std::min<int>(num_frames, static_cast<int>(images.size()));
  std::fprintf(stderr,
               "src db: %zu images; streaming first %d (k=%d, max_kp=%d)\n",
               images.size(), n, k_neighbors, max_kp);

  // ─── PASS 1: per-frame incremental register ───────────────────────
  const std::string inc_db = "/tmp/sfm_stream_verify_inc.db";
  std::vector<int> frame_ids;
  aether_sfm_session_t* inc =
      BuildInjectedSession(*src, images, n, k_neighbors, max_kp, inc_db,
                           &frame_ids);
  if (!inc) return 4;
  std::fprintf(stderr, "injected %zu frames; begin_incremental (bootstrap)\n",
               frame_ids.size());

  char seed_json[512] = {0};
  const double t_seed = NowMs();
  const aether_sfm_result_t brc =
      aether_sfm_begin_incremental(inc, seed_json, sizeof(seed_json));
  const double seed_ms = NowMs() - t_seed;
  std::fprintf(stdout, "BEGIN_JSON %s (rc=%d %s, %.1fms)\n", seed_json, brc,
               aether_sfm_result_str(brc), seed_ms);
  const bool bootstrap_works = (brc == AETHER_SFM_OK);
  if (!bootstrap_works) {
    std::fprintf(stdout, "VERDICT FAIL (bootstrap failed)\n");
    aether_sfm_free(inc);
    return 1;
  }

  // Per-frame register over EVERY injected frame in capture order. Seed images
  // are already registered (register_next_frame reports them registered with 0
  // new points, which we exclude from the growth ratio).
  std::printf("frame# registered new_points total_cloud per_frame_ms reproj\n");
  std::vector<double> per_frame_ms;          // register cost for non-seed frames
  std::vector<int> totals;                   // total_cloud after each call
  int registered_count = 0;
  int grew_count = 0, growth_eligible = 0;
  double last_reproj = 0.0;
  int prev_total = -1;
  for (size_t k = 0; k < frame_ids.size(); ++k) {
    const int fid = frame_ids[k];
    double qwxyz[4] = {1, 0, 0, 0}, t[3] = {0, 0, 0};
    int reg = 0, newp = 0, total = 0;
    double reproj = 0.0;
    const double t0 = NowMs();
    const aether_sfm_result_t rc = aether_sfm_register_next_frame(
        inc, fid, qwxyz, t, &reg, &newp, &total, &reproj);
    const double ms = NowMs() - t0;
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "register frame %d rc=%d (%s)\n", fid, rc,
                   aether_sfm_result_str(rc));
    }
    std::printf("%5d %10d %10d %12d %12.2f %8.4f\n", fid, reg, newp, total, ms,
                reproj);
    if (reg) {
      ++registered_count;
      last_reproj = reproj;
      per_frame_ms.push_back(ms);
      totals.push_back(total);
      // Growth eligibility: a non-seed frame that registered. Seed frames
      // (k==0,1 typically) come back registered with newp==0 because they were
      // triangulated at bootstrap — exclude the first two registered frames.
      if (prev_total >= 0) {
        ++growth_eligible;
        if (total > prev_total) ++grew_count;
      }
      prev_total = total;
    }
  }

  // Final incremental reproj over the live model.
  int inc_total_pts = 0;
  aether_sfm_get_points(inc, nullptr, &inc_total_pts);
  int inc_pose_total = 0;
  aether_sfm_get_poses(inc, nullptr, 0, &inc_pose_total);
  std::vector<aether_sfm_pose_t> poses(inc_pose_total > 0 ? inc_pose_total : 1);
  int pose_count = 0;
  aether_sfm_get_poses(inc, poses.data(), inc_pose_total, &pose_count);
  int inc_registered = 0;
  for (int i = 0; i < pose_count; ++i)
    if (poses[i].registered) ++inc_registered;

  std::fprintf(stdout,
               "INCREMENTAL registered=%d points3d=%d final_reproj=%.4f\n",
               inc_registered, inc_total_pts, last_reproj);

  // Cost stats (non-seed registered frames).
  double med_ms = 0, p95_ms = 0;
  if (!per_frame_ms.empty()) {
    std::vector<double> sorted = per_frame_ms;
    std::sort(sorted.begin(), sorted.end());
    med_ms = sorted[sorted.size() / 2];
    p95_ms = sorted[std::min(sorted.size() - 1,
                             (size_t)(sorted.size() * 0.95))];
  }
  // O(N) check: compare mean per-frame cost of the FIRST third vs LAST third of
  // the registered frames. If cost is O(N) the last third is much slower.
  double first_third_mean = 0, last_third_mean = 0;
  if (per_frame_ms.size() >= 6) {
    const size_t third = per_frame_ms.size() / 3;
    for (size_t i = 0; i < third; ++i) first_third_mean += per_frame_ms[i];
    for (size_t i = per_frame_ms.size() - third; i < per_frame_ms.size(); ++i)
      last_third_mean += per_frame_ms[i];
    first_third_mean /= third;
    last_third_mean /= third;
  }

  aether_sfm_free(inc);

  // ─── PASS 2: batch finalize baseline on the SAME sequence ─────────
  const std::string batch_db = "/tmp/sfm_stream_verify_batch.db";
  std::vector<int> batch_frame_ids;
  aether_sfm_session_t* batch =
      BuildInjectedSession(*src, images, n, k_neighbors, max_kp, batch_db,
                          &batch_frame_ids);
  if (!batch) return 5;
  std::fprintf(stderr, "batch: injected %zu frames; finalize\n",
               batch_frame_ids.size());
  char batch_json[512] = {0};
  const aether_sfm_result_t frc =
      aether_sfm_finalize(batch, batch_json, sizeof(batch_json));
  std::fprintf(stdout, "BATCH_JSON %s (rc=%d %s)\n", batch_json, frc,
               aether_sfm_result_str(frc));
  // Parse reproj_px from the batch JSON.
  double batch_reproj = -1.0;
  {
    const char* p = std::strstr(batch_json, "\"reproj_px\":");
    if (p) batch_reproj = std::atof(p + std::strlen("\"reproj_px\":"));
  }
  int batch_pts = 0;
  aether_sfm_get_points(batch, nullptr, &batch_pts);
  int batch_pose_total = 0;
  aether_sfm_get_poses(batch, nullptr, 0, &batch_pose_total);
  std::vector<aether_sfm_pose_t> bposes(batch_pose_total > 0 ? batch_pose_total
                                                            : 1);
  int bpc = 0;
  aether_sfm_get_poses(batch, bposes.data(), batch_pose_total, &bpc);
  int batch_registered = 0;
  for (int i = 0; i < bpc; ++i)
    if (bposes[i].registered) ++batch_registered;
  aether_sfm_free(batch);

  std::fprintf(stdout,
               "BATCH registered=%d points3d=%d baseline_reproj=%.4f\n",
               batch_registered, batch_pts, batch_reproj);

  // ─── VERIFY ───────────────────────────────────────────────────────
  const double growth_ratio =
      growth_eligible > 0 ? (double)grew_count / growth_eligible : 0.0;
  const bool cloud_grows = growth_ratio >= 0.6;  // grows on a clear majority
  // reproj holds: incremental final <= batch baseline within noise (+5%).
  const bool reproj_holds =
      (batch_reproj > 0) && (last_reproj <= batch_reproj * 1.05);
  // cost bounded: last-third mean within 2x of first-third mean (NOT O(N) which
  // would be ~N/2 ratio over the run).
  const bool cost_bounded =
      (first_third_mean <= 0) ||
      (last_third_mean <= first_third_mean * 2.0 + 5.0 /*ms floor*/);

  std::fprintf(stdout,
               "VERIFY cloud_grows=%d (grew %d/%d = %.2f)\n",
               cloud_grows ? 1 : 0, grew_count, growth_eligible, growth_ratio);
  std::fprintf(stdout,
               "VERIFY reproj_holds=%d (inc %.4f vs batch %.4f)\n",
               reproj_holds ? 1 : 0, last_reproj, batch_reproj);
  std::fprintf(stdout,
               "VERIFY cost_bounded=%d (median %.2fms p95 %.2fms; "
               "first3rd %.2fms last3rd %.2fms)\n",
               cost_bounded ? 1 : 0, med_ms, p95_ms, first_third_mean,
               last_third_mean);
  std::fprintf(stdout, "VERIFY bootstrap_works=%d (seed %.1fms)\n",
               bootstrap_works ? 1 : 0, seed_ms);

  const bool pass = bootstrap_works && cloud_grows && reproj_holds &&
                    cost_bounded && inc_registered >= 2 && inc_total_pts > 0;
  std::fprintf(stdout, "VERDICT %s\n", pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}
