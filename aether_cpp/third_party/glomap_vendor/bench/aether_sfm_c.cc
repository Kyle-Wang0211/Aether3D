// aether_sfm_c.cc — implementation of the on-device SfM C ABI
// (aether_cpp/include/aether_sfm_c.h).
//
// DEVICE-ONLY: this TU links colmap::IncrementalPipeline + colmap::Database
// from the three arm64-device-only static archives (libglomap_core.a /
// libceres.a / libglog.a). The simulator build compiles aether_sfm_stub.cc
// instead, which returns AETHER_SFM_ERR_UNSUPPORTED for every entry point.
//
// v1 surface implemented here:
//   - aether_sfm_run        (validated batch path; wraps colmap_bench 1:1,
//                            keeps the Reconstruction live for the getters)
//   - aether_sfm_get_poses  (Reconstruction::Images()[id].CamFromWorld())
//   - aether_sfm_get_points (Reconstruction::Points3D() xyz+color)
//   - aether_sfm_free / aether_sfm_points_free / aether_sfm_options_default
//   - aether_sfm_result_str
//
// Streaming surface (aether_sfm_create / add_frame / finalize) is wired against
// the real colmap::Database write API; add_frame's pairwise matching uses the
// CPU brute-force matcher (aether_sift_match path). The two-view-geometry write
// uses an identity-config placeholder (COLMAP re-verifies geometry during
// incremental mapping anyway). See NOTE markers for the parts that are honest
// placeholders pending the GPU-match (GpuMatch.m) integration.

#include "aether_sfm_c.h"

#include "colmap/controllers/incremental_pipeline.h"
#include "colmap/estimators/two_view_geometry.h"
#include "colmap/feature/types.h"
#include "colmap/feature/utils.h"
#include "colmap/geometry/rigid3.h"
#include "colmap/scene/camera.h"
#include "colmap/scene/database.h"
#include "colmap/scene/image.h"
#include "colmap/scene/point3d.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/reconstruction_manager.h"
#include "colmap/scene/two_view_geometry.h"

#include <glog/logging.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// On-device DSP-SIFT extractor + CPU matcher (dsp_sift_c.cc, same archive set).
extern "C" int aether_dsp_sift_extract(const uint8_t* gray, int width,
                                       int height, int max_features,
                                       float* out_xy, uint8_t* out_desc,
                                       int out_cap, int* out_count);
extern "C" int aether_sift_match(const uint8_t* desc1, int n1,
                                 const uint8_t* desc2, int n2, double max_ratio,
                                 int* out_num_matches);
// GAP-2: brute-force match that EMITS the {i,j} index pairs (0-based into each
// image's keypoints) so we can persist correspondences. out_pairs holds
// out_cap_pairs*2 ints; *out_num_pairs = #pairs written. Returns 0 on success.
extern "C" int aether_sift_match_pairs(const uint8_t* desc1, int n1,
                                       const uint8_t* desc2, int n2,
                                       double max_ratio, int* out_pairs,
                                       int out_cap_pairs, int* out_num_pairs);

// [MIGRATION 4.0.4 / STEP 5] The glomap::RetriangulateTracks linker stub was
// removed together with GLOMAP. It existed only to satisfy -force_load of
// libglomap_core.a (global_mapper.cc.o referenced the symbol). With GLOMAP no
// longer compiled into glomap_core there is no such reference, so the stub is
// dead. The colmap incremental pipeline this wrapper drives never used it.

namespace {

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

// Per-frame record kept on the session for the streaming surface so we can
// match a new frame against the previous k_neighbors without re-reading the db.
struct FrameRecord {
  int frame_id = -1;
  colmap::image_t image_id = 0;
  int n_keypoints = 0;
  std::vector<uint8_t> descriptors;  // 128 * n_keypoints, RootSIFT
  std::vector<float> xy;             // 2 * n_keypoints, image pixel coords
  bool has_pose = false;             // ARKit world->cam pose prior available
  Eigen::Quaterniond pose_q{1, 0, 0, 0};  // world->cam rotation (qw,qx,qy,qz)
  Eigen::Vector3d pose_t{0, 0, 0};         // world->cam translation
};

}  // namespace

struct aether_sfm_session {
  aether_sfm_options_t options{};
  std::string db_path;
  std::string image_path;
  bool owns_db_file = false;  // streaming sessions delete their temp db on free

  // Streaming state (NULL for pure-batch sessions until finalize fills recon).
  std::shared_ptr<colmap::Database> db;
  std::vector<FrameRecord> frames;
  colmap::camera_t camera_id = 0;

  // Result of finalize()/run(): the largest reconstruction.
  std::shared_ptr<colmap::ReconstructionManager> recon_manager;
  std::shared_ptr<const colmap::Reconstruction> recon;  // best model, or null

  // Async finalize (aether_sfm_finalize_async): phase 1 fills `recon` with a
  // LOCAL-only result (instant), then `refine_thread` runs the global BA on a
  // copy and atomically swaps `recon` to the refined model. `recon_mutex` guards
  // every read/write of `recon` once the worker may be running; `finalize_status`
  // is the lock-free progress flag the caller polls.
  std::mutex recon_mutex;
  std::thread refine_thread;
  std::atomic<int> finalize_status{0};  // aether_sfm_finalize_status_t
  double refine_ms = 0.0;               // worker global-BA wall time
};

namespace {

// Pick the largest reconstruction in the manager and write the JSON summary.
std::shared_ptr<const colmap::Reconstruction> PickBestAndReport(
    const std::shared_ptr<colmap::ReconstructionManager>& manager,
    double solve_ms, char* out_json, int out_cap) {
  std::shared_ptr<const colmap::Reconstruction> best;
  size_t best_reg = 0, best_pts = 0;
  double best_reproj = 0.0, best_track = 0.0;
  for (size_t i = 0; i < manager->Size(); ++i) {
    const auto& recon = manager->Get(i);
    if (recon->NumRegImages() >= best_reg) {
      best_reg = recon->NumRegImages();
      best_pts = recon->NumPoints3D();
      best_reproj = recon->ComputeMeanReprojectionError();
      best_track = recon->ComputeMeanTrackLength();
      best = recon;
    }
  }
  if (out_json && out_cap > 0) {
    std::snprintf(out_json, out_cap,
                  "{\"solve_ms\":%.1f,\"n_models\":%zu,\"n_registered\":%zu,"
                  "\"n_points3d\":%zu,\"reproj_px\":%.4f,\"track_len\":%.3f}",
                  solve_ms, manager->Size(), best_reg, best_pts, best_reproj,
                  best_track);
  }
  return best;
}

// Run the validated IncrementalPipeline over (db_path, image_path) into a fresh
// reconstruction manager, fill *out_recon with the best model + write JSON.
aether_sfm_result_t RunIncremental(
    const std::string& db_path, const std::string& image_path,
    const aether_sfm_options_t& opts,
    std::shared_ptr<colmap::ReconstructionManager>* out_manager,
    std::shared_ptr<const colmap::Reconstruction>* out_recon, char* out_json,
    int out_cap, bool local_only = false) {
  try {
    auto pipeline_opts = std::make_shared<colmap::IncrementalPipelineOptions>();
    pipeline_opts->min_num_matches = 15;
    // No images on device => no point colors to read; skip color extraction
    // (avoids per-image "could not read image" warnings + the file I/O).
    if (image_path.empty()) pipeline_opts->extract_colors = false;
    // [A] Defer ALL in-loop global BA (periodic + recovery) to the single
    // finalize solve. Grounded on the real-res bench (396 frames, 9555 kp/img,
    // 231k pts, host ceres): per-frame registration becomes LOCAL-BA-ONLY ->
    // worst single frame 16122ms (periodic, 19 frames >2s) collapses to 511ms,
    // ZERO frames >2s. The periodic global BA is the only O(N)-growing term and
    // the per-frame SLA breaker; the EARLIER periodic caps (gref1/giter15) were
    // NOT enough at real resolution (in-loop + recovery solves still spiked to
    // 17s). Deferring takes every O(N) global solve off the per-frame critical
    // path so capture-time UI latency stays local-only regardless of N.
    // Bonus: reproj IMPROVES 1.1651 -> 1.1455 — the single finalize global BA
    // over the complete model converges cleaner than incremental periodic refines.
    pipeline_opts->defer_global_ba = true;
    // [ASYNC] local_only => also skip the finalize global BA, so Run() returns a
    // LOCAL-only reconstruction (instant). The async-finalize worker then runs
    // the global BA off the critical path. Batch/sync callers pass false and get
    // the validated full-finalize result (reproj 1.1455).
    if (local_only) pipeline_opts->skip_finalize_global_ba = true;
    // Local BA caps = the per-frame UI cost (the ONLY thing on the critical path
    // now). liter15 + mt6000 (multi-thread above 6k residuals). max 511ms desktop.
    pipeline_opts->ba_local_max_num_iterations = 15;
    pipeline_opts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
    // [AETHER ship config 2026-06-24] Wire the grounded BA optimizations (were only
    // in the bench before; production was using default SOFT_L1 local / TRIVIAL
    // global = the useless ~local-floor finalize):
    //  - CAUCHY local+global: the finalize's ENTIRE value. A1 experiment: TRIVIAL
    //    finalize reproj 0.938 ~= local floor; CAUCHY -> 0.84. NOT droppable.
    //  - global CAUCHY routes to DENSE_SCHUR (override in incremental_pipeline.cc):
    //    Eigen dense Cholesky (Accelerate sparse fails on CAUCHY). Device finalize
    //    192s(ITERATIVE) -> 53s(DENSE) -> 43s(+gftol). Full quality.
    //  - gftol=1e-6: each solve stops on convergence instead of burning the giter
    //    cap (function_tolerance was 0). -30% time, quality within +-0.003 noise.
    //  - keep-CAUCHY local pass-2 (incremental_mapper.cc) + lnum=10: better preview
    //    (0.936->0.86) + lower drift (2.08%/7.12% -> 1.42%/4.87%). Device 2s-gate
    //    1695ms (the per-frame SLA only binds the FUTURE streaming path; current
    //    production runs pipeline.Run() as ONE post-capture batch -> no per-frame gate).
    pipeline_opts->ba_local_loss_type = 2;     // CAUCHY
    pipeline_opts->ba_local_loss_scale = 1.0;
    pipeline_opts->ba_global_loss_type = 2;    // CAUCHY (-> DENSE_SCHUR via override)
    pipeline_opts->ba_global_loss_scale = 1.0;
    pipeline_opts->ba_global_function_tolerance = 1e-6;  // converge-stop
    pipeline_opts->mapper.ba_local_num_images = 10;
    // [AETHER] NOTE: ignore_redundant_points3D + freeze-intrinsics were tried (RAM
    // 2.36->1.45GB, 4x faster) but cost reproj 0.955->0.9952 (~4%) -> REVERTED per the
    // zero-quality-loss requirement. Full intrinsic refinement + all points stay.
    // Quality-neutral memory wins only: ITERATIVE routing (device-safe, same optimum)
    // + (GLOMAP) tracks_full release. Full-scene fit relies on moderate (non-exhaustive)
    // match density, not on dropping points/intrinsics.
    // [B] Per-frame margin knob, GATED on the iPhone BA-factor measurement:
    // ba_local_num_images 6->4 cuts per-frame max 511->389ms but costs reproj
    // 1.1455->1.1574. Default keeps 6 (best reproj); drop to 4 ONLY if the device
    // cannot hold a 511ms local BA under the 2s SLA. (Memory-bound BA likely runs
    // ~3-5x desktop, not the ~6x of compute-bound extraction -> 511ms*4 ~ 2s.)
    //
    // Finalize global BA is now the ONLY global solve -> it MUST run FULL
    // (default gref5/giter50) to converge; the old E4 periodic caps under-converge
    // it (reproj 1.1847). Cost ~103s desktop (~5-8min device) is a one-time
    // POST-capture price, async-able onto a worker thread later. Left at defaults.
    auto manager = std::make_shared<colmap::ReconstructionManager>();

    const double t0 = NowMs();
    // [MIGRATION 4.0.4] image_path moved into options; the pipeline ctor takes a
    // Database shared_ptr (not a db_path string). Mirrors colmap_bench.cc.
    pipeline_opts->image_path = image_path;
    colmap::IncrementalPipeline pipeline(
        pipeline_opts, colmap::Database::Open(db_path), manager);
    pipeline.Run();
    const double solve_ms = NowMs() - t0;

    *out_manager = manager;
    *out_recon = PickBestAndReport(manager, solve_ms, out_json, out_cap);
    return AETHER_SFM_OK;
  } catch (const std::exception& e) {
    if (out_json && out_cap > 0) {
      std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    }
    return AETHER_SFM_ERR_INTERNAL;
  }
}

// Async-finalize worker: deep-copy the local-only reconstruction, run the global
// BA (retriangulation + global bundle adjustment) via the pipeline's PUBLIC
// TriangulateReconstruction — the same validated plumbing the synchronous
// finalize uses — then atomically swap the refined model into the session. Runs
// off the UI thread so the caller already has the instant local result. db_path
// must be readable (the session closed its handle before spawning this).
void RefineGlobalBA(aether_sfm_session* s,
                    std::shared_ptr<const colmap::Reconstruction> local) {
  try {
    const double t0 = NowMs();
    auto refined = std::make_shared<colmap::Reconstruction>(*local);
    auto popts = std::make_shared<colmap::IncrementalPipelineOptions>();
    popts->min_num_matches = 15;
    popts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
    // Global BA at FULL convergence (default gref5/giter50) = the validated
    // finalize quality (reproj 1.1455). TriangulateReconstruction reads
    // ba_global_* + Mapper() + Triangulation() from these options.
    auto manager = std::make_shared<colmap::ReconstructionManager>();
    // [MIGRATION 4.0.4] image_path in options; ctor takes a Database shared_ptr.
    popts->image_path = s->image_path;
    colmap::IncrementalPipeline pipeline(
        popts, colmap::Database::Open(s->db_path), manager);
    pipeline.RefineReconstruction(refined);
    {
      std::lock_guard<std::mutex> lk(s->recon_mutex);
      s->recon = refined;
      s->refine_ms = NowMs() - t0;
    }
    s->finalize_status.store(2);  // AETHER_SFM_FINALIZE_REFINED
  } catch (...) {
    s->finalize_status.store(3);  // AETHER_SFM_FINALIZE_ERROR
  }
}

// Whether two frames carrying ARKit world->cam pose priors are within
// `max_angle_deg` viewing-direction angle of each other. Used as the GAP-3
// pose-prior guard: skip matching frame pairs whose cameras look in wildly
// different directions (they cannot share enough surface for a useful epipolar
// geometry), which prunes the O(k) candidate matches per frame to the ones the
// pose says can actually overlap. Conservative: if either pose is missing we
// return true (fall back to unguided matching — never drop a real pair).
bool PosePriorAllowsMatch(const FrameRecord& a, const FrameRecord& b,
                          double max_angle_deg) {
  if (!a.has_pose || !b.has_pose) return true;  // unguided fallback
  // world->cam rotation R maps world points into the camera frame. The camera's
  // optical axis in WORLD coords is R^T * (0,0,1) = third ROW of R^T = third
  // COLUMN of R... i.e. R.transpose().col(2). Compare the two world-space axes.
  const Eigen::Matrix3d Ra = a.pose_q.normalized().toRotationMatrix();
  const Eigen::Matrix3d Rb = b.pose_q.normalized().toRotationMatrix();
  const Eigen::Vector3d za = Ra.transpose().col(2);  // cam a optical axis (world)
  const Eigen::Vector3d zb = Rb.transpose().col(2);  // cam b optical axis (world)
  const double cos_ang = za.normalized().dot(zb.normalized());
  const double ang_deg =
      std::acos(std::max(-1.0, std::min(1.0, cos_ang))) * 180.0 / M_PI;
  return ang_deg <= max_angle_deg;
}

// GAP-2 + GAP-3 core: match `cur` against each of the previous k frames, persist
// the resulting index-pair correspondences (Database::WriteMatches) and the
// geometrically-verified inlier set (EstimateTwoViewGeometry ->
// WriteTwoViewGeometry) so the incremental mapper's correspondence graph
// (database_cache reads ReadTwoViewGeometries) can register the streamed frame.
// `pose_guided` (GAP-3): when both frames carry an ARKit pose prior, skip pairs
// whose optical axes diverge by more than guided_max_angle_deg (cheaper: fewer
// brute-force matches + fewer RANSAC verifications). Returns the number of pairs
// that produced a non-degenerate two-view geometry (>=1 means the frame is
// connected into the graph).
int MatchAndPersistAgainstPrev(aether_sfm_session* s, const FrameRecord& cur,
                               bool pose_guided, double guided_max_angle_deg) {
  const int frame_id = cur.frame_id;
  const int k = s->options.k_neighbors > 0 ? s->options.k_neighbors : 6;
  const int start = (frame_id - k) > 0 ? (frame_id - k) : 0;
  const double max_ratio =
      s->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.7;

  // The shared camera (created on the first frame) is used for both views — a
  // single self-calibrated SIMPLE_PINHOLE group (see add_frame note). Reading it
  // once avoids a per-pair db round-trip.
  colmap::Camera camera = s->db->ReadCamera(s->camera_id);

  // Reusable keypoint->points conversion for the current frame.
  auto kps_to_points = [](const std::vector<float>& xy,
                          int n) -> std::vector<Eigen::Vector2d> {
    std::vector<Eigen::Vector2d> pts(n);
    for (int i = 0; i < n; ++i) {
      pts[i] = Eigen::Vector2d(xy[2 * i], xy[2 * i + 1]);
    }
    return pts;
  };
  const std::vector<Eigen::Vector2d> points_cur =
      kps_to_points(cur.xy, cur.n_keypoints);

  colmap::TwoViewGeometryOptions tvg_opts;  // colmap defaults (min 15 inliers)

  int n_verified = 0;
  std::vector<int> pair_buf;  // {i,j} flat
  for (int j = start; j < frame_id; ++j) {
    const FrameRecord& prev = s->frames[j];
    if (pose_guided &&
        !PosePriorAllowsMatch(prev, cur, guided_max_angle_deg)) {
      continue;  // GAP-3: pose says these views can't overlap — skip
    }

    // GAP-2: get the actual index pairs (not just a count).
    const int cap_pairs = std::min(prev.n_keypoints, cur.n_keypoints);
    pair_buf.assign(static_cast<size_t>(cap_pairs) * 2, 0);
    int n_pairs = 0;
    const int mrc = aether_sift_match_pairs(
        prev.descriptors.data(), prev.n_keypoints, cur.descriptors.data(),
        cur.n_keypoints, max_ratio, pair_buf.data(), cap_pairs, &n_pairs);
    if (mrc != 0 || n_pairs <= 0) continue;

    colmap::FeatureMatches matches(n_pairs);
    for (int m = 0; m < n_pairs; ++m) {
      matches[m] = colmap::FeatureMatch(
          static_cast<colmap::point2D_t>(pair_buf[2 * m]),       // idx in prev
          static_cast<colmap::point2D_t>(pair_buf[2 * m + 1]));  // idx in cur
    }
    // Persist the raw matches (image_id order: prev=image1, cur=image2).
    s->db->WriteMatches(prev.image_id, cur.image_id, matches);

    // Geometric verification -> inlier two-view geometry (mirrors COLMAP's own
    // feature_matching_utils flow: keypoints -> points -> EstimateTwoViewGeometry).
    const std::vector<Eigen::Vector2d> points_prev =
        kps_to_points(prev.xy, prev.n_keypoints);
    colmap::TwoViewGeometry tvg = colmap::EstimateTwoViewGeometry(
        camera, points_prev, camera, points_cur, matches, tvg_opts);
    s->db->WriteTwoViewGeometry(prev.image_id, cur.image_id, tvg);
    if (tvg.config != colmap::TwoViewGeometry::UNDEFINED &&
        tvg.config != colmap::TwoViewGeometry::DEGENERATE &&
        !tvg.inlier_matches.empty()) {
      ++n_verified;
    }
  }
  return n_verified;
}

}  // namespace

extern "C" {

void aether_sfm_options_default(aether_sfm_options_t* out) {
  if (!out) return;
  out->max_features = 2048;
  out->image_width = 0;
  out->image_height = 0;
  out->match_max_ratio = 0.7f;
  out->use_gpu_match = 0;  // CPU brute-force by default; iOS shim can flip to 1
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

// ─── batch (validated v1) ───────────────────────────────────────────
aether_sfm_result_t aether_sfm_run(const char* db_path, const char* image_path,
                                   const aether_sfm_options_t* options,
                                   aether_sfm_session_t** out_session,
                                   char* out_json, int out_cap) {
  if (!db_path || !image_path) return AETHER_SFM_ERR_INVALID_ARG;

  aether_sfm_options_t opts;
  if (options) {
    opts = *options;
  } else {
    aether_sfm_options_default(&opts);
  }

  std::shared_ptr<colmap::ReconstructionManager> manager;
  std::shared_ptr<const colmap::Reconstruction> recon;
  const aether_sfm_result_t rc = RunIncremental(
      db_path, image_path, opts, &manager, &recon, out_json, out_cap);
  if (rc != AETHER_SFM_OK) return rc;

  if (out_session) {
    auto* s = new aether_sfm_session();
    s->options = opts;
    s->db_path = db_path;
    s->image_path = image_path;
    s->owns_db_file = false;  // batch path consumes a caller-owned db
    s->recon_manager = manager;
    s->recon = recon;
    *out_session = s;
  }
  return AETHER_SFM_OK;
}

aether_sfm_result_t aether_sfm_run_dir(const char* capture_dir,
                                       const aether_sfm_options_t* options,
                                       aether_sfm_session_t** out_session,
                                       char* out_json, int out_cap) {
  // NOTE (honest stub): the in-process extract+match+db-build path is the
  // streaming surface composed together (create → add_frame×N → finalize) over
  // a directory of JPEGs + poses.json. JPEG decode is a platform-side concern
  // (CGImage on iOS); this convenience entry needs a portable JPEG decoder to
  // be self-contained, which is not yet vendored into the device archive. Until
  // then callers use aether_sfm_run with a prebuilt db, or drive the streaming
  // API directly with platform-decoded grayscale buffers.
  (void)capture_dir;
  (void)options;
  (void)out_session;
  if (out_json && out_cap > 0) {
    std::snprintf(out_json, out_cap,
                  "{\"error\":\"run_dir not implemented: drive create/"
                  "add_frame/finalize with platform-decoded frames\"}");
  }
  return AETHER_SFM_ERR_UNSUPPORTED;
}

// ─── streaming ──────────────────────────────────────────────────────
aether_sfm_result_t aether_sfm_create(const char* db_path,
                                      const aether_sfm_options_t* options,
                                      aether_sfm_session_t** out_session) {
  if (!db_path || !out_session) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    auto* s = new aether_sfm_session();
    if (options) {
      s->options = *options;
    } else {
      aether_sfm_options_default(&s->options);
    }
    s->db_path = db_path;
    s->owns_db_file = true;
    s->db = colmap::Database::Open(db_path);
    if (!s->db) {
      delete s;
      return AETHER_SFM_ERR_DB;
    }
    *out_session = s;
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_DB;
  }
}

aether_sfm_result_t aether_sfm_add_frame(aether_sfm_session_t* s,
                                         const uint8_t* gray, int width,
                                         int height, float fx, float fy,
                                         float cx, float cy,
                                         const double pose_qwxyz[4],
                                         const double pose_t[3],
                                         int* out_frame_id) {
  if (!s || !s->db || !gray || width <= 0 || height <= 0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  try {
    const int max_features =
        s->options.max_features > 0 ? s->options.max_features : 2048;

    // 1) DSP-SIFT extraction (validated unmodified colmap covariant SIFT).
    std::vector<float> xy(static_cast<size_t>(max_features) * 2);
    std::vector<uint8_t> desc(static_cast<size_t>(max_features) * 128);
    int n = 0;
    const int erc = aether_dsp_sift_extract(gray, width, height, max_features,
                                            xy.data(), desc.data(), max_features,
                                            &n);
    if (erc != 0 || n <= 0) return AETHER_SFM_ERR_EXTRACT;

    // 2) Single shared camera (SIMPLE_PINHOLE: f, cx, cy), self-calibrated by
    //    BA — the RealityScan/RealityCapture default (soft-prior, refined per
    //    calibration group), and the only intrinsics model that is valid and
    //    identical across iOS/Android/HarmonyOS once FOCUS IS LOCKED at capture
    //    (cross-platform research 2026-06-23: ARCore does NOT report
    //    focus-varying per-frame intrinsics — github.com/google-ar #1239 — so a
    //    per-frame-intrinsics design is iOS-only and breaks 3-platform parity).
    //    Locking focus makes one shared focal physically correct for the whole
    //    session; BA refines it from the ARKit value as a soft prior.
    if (s->camera_id == 0) {
      colmap::Camera camera = colmap::Camera::CreateFromModelId(
          colmap::kInvalidCameraId, colmap::SimplePinholeCameraModel::model_id,
          /*focal_length=*/0.5 * (fx + fy), width, height);
      // Override principal point with the ARKit values.
      camera.SetPrincipalPointX(cx);
      camera.SetPrincipalPointY(cy);
      s->camera_id = s->db->WriteCamera(camera);
    }

    // 3) Write image + keypoints + descriptors.
    const int frame_id = static_cast<int>(s->frames.size());
    colmap::Image image;
    char name[64];
    std::snprintf(name, sizeof(name), "frame_%06d.jpg", frame_id);
    image.SetName(name);
    image.SetCameraId(s->camera_id);
    const colmap::image_t image_id = s->db->WriteImage(image);

    colmap::FeatureKeypoints kps(n);
    for (int i = 0; i < n; ++i) {
      kps[i] = colmap::FeatureKeypoint(xy[2 * i], xy[2 * i + 1]);
    }
    // [MIGRATION 4.0.4 / STEP 5] FeatureDescriptors is now a struct
    // {FeatureExtractorType type; FeatureDescriptorsData data;}. The raw
    // uint8 matrix is the `.data` member; tag the type so WriteDescriptors
    // serializes it consistently with ReadDescriptors.
    colmap::FeatureDescriptors descriptors;
    descriptors.type = colmap::FeatureExtractorType::SIFT;
    descriptors.data.resize(n, 128);
    std::memcpy(descriptors.data.data(), desc.data(),
                static_cast<size_t>(n) * 128);
    s->db->WriteKeypoints(image_id, kps);
    s->db->WriteDescriptors(image_id, descriptors);

    FrameRecord rec;
    rec.frame_id = frame_id;
    rec.image_id = image_id;
    rec.n_keypoints = n;
    rec.descriptors.assign(desc.begin(), desc.begin() + (size_t)n * 128);
    rec.xy.assign(xy.begin(), xy.begin() + (size_t)n * 2);
    if (pose_qwxyz && pose_t) {
      rec.has_pose = true;
      rec.pose_q = Eigen::Quaterniond(pose_qwxyz[0], pose_qwxyz[1],
                                      pose_qwxyz[2], pose_qwxyz[3]);
      rec.pose_t = Eigen::Vector3d(pose_t[0], pose_t[1], pose_t[2]);
    }

    // 4) GAP-2 + GAP-3: match against the previous k_neighbors frames, persist
    //    the index-pair correspondences (WriteMatches) AND the geometrically
    //    verified inlier two-view geometry (WriteTwoViewGeometry) so the
    //    incremental mapper's correspondence graph can register this frame.
    //    Pose-guided pruning (GAP-3) activates only when this frame and the
    //    candidate both carry an ARKit pose prior; it only PRUNES pairs whose
    //    optical axes diverge too far, and never invents pairs.
    s->frames.push_back(std::move(rec));
    MatchAndPersistAgainstPrev(s, s->frames.back(),
                               /*pose_guided=*/true,
                               /*guided_max_angle_deg=*/75.0);
    if (out_frame_id) *out_frame_id = frame_id;
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_INTERNAL;
  }
}

// GAP-1: inject ALREADY-EXTRACTED features (from the GPU DSP-SIFT extractor)
// instead of re-running the CPU extractor. `keypoints_stride4` is the GPU
// extractor's native layout: count * {x, y, sigma, octave} floats (we use x,y;
// sigma/octave are kept by the descriptor and not needed by the SfM geometry).
// `descriptors` is count*128 uint8 RootSIFT. fx/fy/cx/cy + width/height supply
// the shared-camera intrinsics (created lazily on the first frame, identical to
// add_frame). `pose_qwxyz`/`pose_t` (may be NULL) carry the ARKit world->cam
// prior used for GAP-3 pose-guided match pruning. Writes
// WriteKeypoints/WriteDescriptors for the frame, then matches+persists against
// the previous k frames exactly like add_frame — but with ZERO redundant
// extraction (the orchestrator already paid for it on the GPU).
aether_sfm_result_t aether_sfm_add_frame_with_features(
    aether_sfm_session_t* s, int width, int height, float fx, float fy,
    float cx, float cy, const float* keypoints_stride4,
    const uint8_t* descriptors, unsigned int count,
    const double pose_qwxyz[4], const double pose_t[3], int* out_frame_id) {
  if (!s || !s->db || width <= 0 || height <= 0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  if (!keypoints_stride4 || !descriptors || count == 0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  try {
    int n = static_cast<int>(count);
    const int cap =
        s->options.max_features > 0 ? s->options.max_features : 8192;
    if (n > cap) n = cap;  // clamp to the configured feature budget

    // 1) Shared self-calibrated SIMPLE_PINHOLE camera (created once). Identical
    //    to add_frame: BA refines the ARKit focal from the prior.
    if (s->camera_id == 0) {
      colmap::Camera camera = colmap::Camera::CreateFromModelId(
          colmap::kInvalidCameraId, colmap::SimplePinholeCameraModel::model_id,
          /*focal_length=*/0.5 * (fx + fy), width, height);
      camera.SetPrincipalPointX(cx);
      camera.SetPrincipalPointY(cy);
      s->camera_id = s->db->WriteCamera(camera);
    }

    // 2) Write image + keypoints + descriptors (GAP-1: injected, not extracted).
    const int frame_id = static_cast<int>(s->frames.size());
    colmap::Image image;
    char name[64];
    std::snprintf(name, sizeof(name), "frame_%06d.jpg", frame_id);
    image.SetName(name);
    image.SetCameraId(s->camera_id);
    const colmap::image_t image_id = s->db->WriteImage(image);

    colmap::FeatureKeypoints kps(n);
    std::vector<float> xy(static_cast<size_t>(n) * 2);
    for (int i = 0; i < n; ++i) {
      const float x = keypoints_stride4[i * 4 + 0];
      const float y = keypoints_stride4[i * 4 + 1];
      kps[i] = colmap::FeatureKeypoint(x, y);  // x,y only (geometry needs xy)
      xy[2 * i] = x;
      xy[2 * i + 1] = y;
    }
    colmap::FeatureDescriptors desc;
    desc.type = colmap::FeatureExtractorType::SIFT;
    desc.data.resize(n, 128);
    std::memcpy(desc.data.data(), descriptors,
                static_cast<size_t>(n) * 128);
    s->db->WriteKeypoints(image_id, kps);
    s->db->WriteDescriptors(image_id, desc);

    FrameRecord rec;
    rec.frame_id = frame_id;
    rec.image_id = image_id;
    rec.n_keypoints = n;
    rec.descriptors.assign(descriptors, descriptors + (size_t)n * 128);
    rec.xy = std::move(xy);
    if (pose_qwxyz && pose_t) {
      rec.has_pose = true;
      rec.pose_q = Eigen::Quaterniond(pose_qwxyz[0], pose_qwxyz[1],
                                      pose_qwxyz[2], pose_qwxyz[3]);
      rec.pose_t = Eigen::Vector3d(pose_t[0], pose_t[1], pose_t[2]);
    }

    // 3) GAP-2 + GAP-3 match-persist (same path as add_frame).
    s->frames.push_back(std::move(rec));
    MatchAndPersistAgainstPrev(s, s->frames.back(),
                               /*pose_guided=*/true,
                               /*guided_max_angle_deg=*/75.0);
    if (out_frame_id) *out_frame_id = frame_id;
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_INTERNAL;
  }
}

aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s, char* out_json,
                                        int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    if (s->db) s->db->Close();  // flush sqlite before the pipeline re-opens it
    std::shared_ptr<colmap::ReconstructionManager> manager;
    std::shared_ptr<const colmap::Reconstruction> recon;
    // image_path empty: keypoints/descriptors come from the db; colmap reads
    // colors from images only when present, otherwise points get zero color.
    const aether_sfm_result_t rc = RunIncremental(
        s->db_path, s->image_path, s->options, &manager, &recon, out_json,
        out_cap);
    if (rc != AETHER_SFM_OK) return rc;
    s->recon_manager = manager;
    s->recon = recon;
    if (!recon || recon->NumRegImages() == 0) {
      return AETHER_SFM_ERR_NOT_REGISTERED;
    }
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_INTERNAL;
  }
}

// Two-phase async finalize. Phase 1 (synchronous, this call): incremental
// register + local BA only -> LOCAL reconstruction is live in *recon the instant
// this returns OK (status = LOCAL_READY), so the UI can show the model now.
// Phase 2 (background thread): the heavy O(N) global BA runs off the critical
// path; when it converges the refined model is atomically swapped into *recon
// (status = REFINED). The getters always read whatever is current under the
// mutex (local first, refined later). out_json carries the LOCAL summary.
aether_sfm_result_t aether_sfm_finalize_async(aether_sfm_session_t* s,
                                              char* out_json, int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  if (s->refine_thread.joinable()) s->refine_thread.join();  // drain prior run
  try {
    if (s->db) s->db->Close();  // release sqlite before the pipeline reopens it
    std::shared_ptr<colmap::ReconstructionManager> manager;
    std::shared_ptr<const colmap::Reconstruction> local;
    const aether_sfm_result_t rc =
        RunIncremental(s->db_path, s->image_path, s->options, &manager, &local,
                       out_json, out_cap, /*local_only=*/true);
    if (rc != AETHER_SFM_OK) {
      s->finalize_status.store(3);
      return rc;
    }
    if (!local || local->NumRegImages() == 0) {
      s->finalize_status.store(3);
      return AETHER_SFM_ERR_NOT_REGISTERED;
    }
    {
      std::lock_guard<std::mutex> lk(s->recon_mutex);
      s->recon_manager = manager;
      s->recon = local;
    }
    s->finalize_status.store(1);  // LOCAL_READY
    s->refine_thread = std::thread(RefineGlobalBA, s, local);
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    s->finalize_status.store(3);
    return AETHER_SFM_ERR_INTERNAL;
  }
}

// Poll the background refinement: 0=IDLE, 1=LOCAL_READY (local live, refining),
// 2=REFINED (global BA done, *recon swapped), 3=ERROR.
int aether_sfm_finalize_status(aether_sfm_session_t* s) {
  if (!s) return 3;
  return s->finalize_status.load();
}

// ─── outputs ────────────────────────────────────────────────────────
aether_sfm_result_t aether_sfm_get_poses(aether_sfm_session_t* s,
                                         aether_sfm_pose_t* out_poses, int cap,
                                         int* out_count) {
  if (!s || !out_count) return AETHER_SFM_ERR_INVALID_ARG;
  std::shared_ptr<const colmap::Reconstruction> recon;
  {
    std::lock_guard<std::mutex> lk(s->recon_mutex);
    recon = s->recon;  // stable snapshot; survives an async swap
  }
  if (!recon) return AETHER_SFM_ERR_NOT_REGISTERED;
  const auto& images = recon->Images();
  int written = 0;
  int total = 0;
  for (const auto& [image_id, image] : images) {
    ++total;
    if (out_poses && written < cap) {
      aether_sfm_pose_t& p = out_poses[written];
      // image_id is 1-based from WriteImage; expose 0-based frame index.
      p.frame_id = static_cast<int>(image_id) - 1;
      p.registered = image.HasPose() ? 1 : 0;
      if (image.HasPose()) {
        const colmap::Rigid3d c_from_w = image.CamFromWorld();
        // [MIGRATION 4.0.4] Rigid3d::rotation/translation are METHODS now
        // (Eigen::Map accessors over params[qx,qy,qz,qw,tx,ty,tz]), not the
        // 3.x public members. Call them.
        const Eigen::Quaterniond q = c_from_w.rotation();
        p.qwxyz[0] = q.w();
        p.qwxyz[1] = q.x();
        p.qwxyz[2] = q.y();
        p.qwxyz[3] = q.z();
        p.t[0] = c_from_w.translation().x();
        p.t[1] = c_from_w.translation().y();
        p.t[2] = c_from_w.translation().z();
      } else {
        p.qwxyz[0] = 1.0;
        p.qwxyz[1] = p.qwxyz[2] = p.qwxyz[3] = 0.0;
        p.t[0] = p.t[1] = p.t[2] = 0.0;
      }
      ++written;
    }
  }
  *out_count = total;
  return AETHER_SFM_OK;
}

aether_sfm_result_t aether_sfm_get_points(aether_sfm_session_t* s,
                                          aether_sfm_point_t** out_points,
                                          int* out_count) {
  if (!s || !out_count) return AETHER_SFM_ERR_INVALID_ARG;
  std::shared_ptr<const colmap::Reconstruction> recon;
  {
    std::lock_guard<std::mutex> lk(s->recon_mutex);
    recon = s->recon;  // stable snapshot; survives an async swap
  }
  if (!recon) return AETHER_SFM_ERR_NOT_REGISTERED;
  const auto& pts = recon->Points3D();
  const int n = static_cast<int>(pts.size());
  *out_count = n;
  if (!out_points) return AETHER_SFM_OK;  // count-only query

  auto* arr = static_cast<aether_sfm_point_t*>(
      std::malloc(static_cast<size_t>(n) * sizeof(aether_sfm_point_t)));
  if (!arr && n > 0) return AETHER_SFM_ERR_INTERNAL;
  int i = 0;
  for (const auto& [point_id, point] : pts) {
    aether_sfm_point_t& o = arr[i++];
    o.x = static_cast<float>(point.xyz.x());
    o.y = static_cast<float>(point.xyz.y());
    o.z = static_cast<float>(point.xyz.z());
    o.r = point.color(0);
    o.g = point.color(1);
    o.b = point.color(2);
    o._pad[0] = o._pad[1] = 0;
  }
  *out_points = arr;
  return AETHER_SFM_OK;
}

void aether_sfm_points_free(aether_sfm_point_t* points) {
  std::free(points);
}

void aether_sfm_free(aether_sfm_session_t* s) {
  if (!s) return;
  // The async-finalize worker captures `s`; it MUST finish before we delete.
  if (s->refine_thread.joinable()) s->refine_thread.join();
  if (s->db) {
    try {
      s->db->Close();
    } catch (...) {
    }
  }
  if (s->owns_db_file && !s->db_path.empty()) {
    std::remove(s->db_path.c_str());
  }
  delete s;
}

}  // extern "C"
