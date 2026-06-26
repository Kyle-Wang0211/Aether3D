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
#include "colmap/sfm/incremental_mapper.h"
#include "colmap/sfm/incremental_triangulator.h"
#include "colmap/scene/database_cache.h"
#include "colmap/estimators/bundle_adjustment.h"
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

  // ── per-frame incremental register state (aether_sfm_begin_incremental /
  //    aether_sfm_register_next_frame). The DatabaseCache MUST outlive the
  //    mapper (mapper borrows std::shared_ptr<const DatabaseCache>); the live
  //    Reconstruction IS the UI cloud (also pointed-to by s->recon). All persist
  //    across register_next_frame calls — do NOT recreate per frame.
  std::shared_ptr<colmap::DatabaseCache> database_cache;
  std::unique_ptr<colmap::IncrementalMapper> mapper;
  std::shared_ptr<colmap::Reconstruction> live_recon;
  bool incremental_seeded = false;
  // The option-builders the per-frame path reproduces (same validated 0.84-reproj
  // BA config the pipeline injects: CAUCHY local, lnum=10 window, liter15).
  std::shared_ptr<colmap::IncrementalPipelineOptions> inc_opts;

  // ── TRUE LIVE-INTERLEAVED state (aether_sfm_add_and_register_frame). Unlike
  //    the begin/freeze path above, the live graph GROWS during capture: each
  //    add_and_register_frame appends the new frame's image NAME to live_fed_names
  //    and, every live_recache_every frames, rebuilds the DatabaseCache RESTRICTED
  //    to live_fed_names (DatabaseCache::Options::image_names) so the cache/graph
  //    cost scales with the FED SUBSET, not the full db. The live Reconstruction is
  //    continued across rebuilds (Reconstruction::Load is additive + preserves
  //    registered poses/points; EndReconstruction(discard=false)->TearDown keeps
  //    the registered model). live_recon doubles as s->recon (UI cloud). The
  //    register step itself is O(local) and never re-Finalizes the whole graph.
  bool live_mode = false;                 // add_and_register_frame path active
  int live_recache_every = 8;             // rebuild cache every N fed frames
  int live_bootstrap_k = 6;               // accumulate K frames before seeding
  int live_max_register_per_call = 4;     // cap registrations/call (bounds cost)
  bool live_seeded = false;
  int live_fed_count = 0;                 // frames fed so far (temporal)
  int live_since_recache = 0;             // frames fed since last cache rebuild
  std::unordered_set<std::string> live_fed_names;  // staged image names (subset)
  std::unordered_map<int, colmap::image_t> live_frame_to_image;  // feed idx->image
  std::shared_ptr<colmap::Database> live_src_db;  // bench: the real graph (RO)
  // Fed-but-not-yet-registered images. After each re-cache we sweep these (in a
  // bounded retry loop) because a newly-registered/triangulated frame gives its
  // covisible neighbours the 2D-3D correspondences they previously lacked — the
  // standard incremental-SfM frontier. Bounded: only the current fed subset.
  std::unordered_set<colmap::image_t> live_pending;

  // ── AETHER DIAGNOSTIC: per-image LAST RegisterNextImage failure reason +
  //    the raw gate counts at that last attempt. Updated every time
  //    LiveRegisterImage tries (and fails) to register an image; cleared when
  //    the image finally registers. After the feed, the entries that remain are
  //    the frames that NEVER registered, keyed by their final failure reason.
  struct LiveRegFailInfo {
    int reason = 6;        // see AetherLastRegFailReason() codes
    int num_visible = -1;  // NumVisiblePoints3D at last attempt
    int num_corrs = -1;    // tri_points2D count at last attempt
    int min_inliers = -1;  // abs_pose_min_num_inliers threshold
    int attempts = 0;      // how many times RegisterNextImage was tried
  };
  std::unordered_map<colmap::image_t, LiveRegFailInfo> live_reg_fail;

  // ── AETHER POSE-PRIOR PATH (aether_sfm_set_image_pose_prior). When enabled,
  //    LiveRegisterImage first tries the normal PnP RegisterNextImage; if that
  //    fails AND a known ARKit cam_from_world prior exists for this image, it
  //    registers via the prior (RegisterNextImageWithPosePrior), bypassing the
  //    2D-3D resection that the diagnostic showed kills ~94% of live frames.
  bool live_use_pose_prior = false;
  std::unordered_map<colmap::image_t, colmap::Rigid3d> live_pose_prior;  // cam_from_world
  int live_prior_reg_count = 0;  // how many frames registered VIA the prior path

  // ── AETHER COVERAGE PROBE: BA cap. When set (env AETHER_LIVE_BACAP=1), skip
  //    the per-frame IterativeLocalRefinement (local BA) — the term that drove
  //    the prior p95 ~3065ms. This is a COVERAGE-ONLY probe: registration +
  //    triangulation still run (so the prior path still has 3D structure to link
  //    against), but the expensive local-window BA is disabled so a full-414 feed
  //    completes fast. reproj/cost bounding is a SEPARATE known task.
  bool live_cap_ba = false;     // skip IterativeLocalRefinement (local BA)
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

// Build the AETHER ship-config IncrementalPipelineOptions (the validated
// CAUCHY-local/global + DENSE_SCHUR-routing + deferred-global-BA config). Shared
// by RunIncremental (batch finalize) and the per-frame register path so both run
// the SAME BA option-builders (LocalBundleAdjustment()/GlobalBundleAdjustment()/
// Mapper()/Triangulation()) — the per-frame path must NOT hand-roll
// BundleAdjustmentOptions or it loses the 0.84-reproj config.
std::shared_ptr<colmap::IncrementalPipelineOptions> MakeShipOptions(
    const std::string& image_path, bool local_only) {
  auto o = std::make_shared<colmap::IncrementalPipelineOptions>();
  o->min_num_matches = 15;
  if (image_path.empty()) o->extract_colors = false;
  o->defer_global_ba = true;  // per-frame path NEVER triggers in-loop global BA
  if (local_only) o->skip_finalize_global_ba = true;
  o->ba_local_max_num_iterations = 15;
  o->ba_min_num_residuals_for_cpu_multi_threading = 6000;
  o->ba_local_loss_type = 2;   // CAUCHY
  o->ba_local_loss_scale = 1.0;
  o->ba_global_loss_type = 2;  // CAUCHY (-> DENSE_SCHUR via override)
  o->ba_global_loss_scale = 1.0;
  o->ba_global_function_tolerance = 1e-6;
  o->mapper.ba_local_num_images = 10;
  o->image_path = image_path;
  return o;
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

// ── LIVE re-cache: rebuild the DatabaseCache restricted to the frames fed so
//    far (live_fed_names) and (re)attach a fresh IncrementalMapper that CONTINUES
//    the existing live Reconstruction. This is the bounded live-mutation step:
//    the cache/graph is rebuilt over the FED SUBSET only (not the whole db), and
//    the registered poses + 3D points survive because Reconstruction::Load is
//    additive and EndReconstruction(discard=false) keeps the registered model.
//    Returns false on hard failure. seed_if_unseeded: when the live model has no
//    registered frames yet, run the bootstrap seed inside this rebuild.
bool LiveRebuildCacheAndMapper(aether_sfm_session* s, double* out_recache_ms) {
  const double t0 = NowMs();

  // Flush sqlite writes so the cache sees every staged frame/match.
  if (s->db) s->db->Close();
  auto db = colmap::Database::Open(s->db_path);

  if (!s->inc_opts) s->inc_opts = MakeShipOptions(s->image_path, false);

  colmap::DatabaseCache::Options cache_opts;
  cache_opts.min_num_matches = static_cast<size_t>(s->inc_opts->min_num_matches);
  cache_opts.ignore_watermarks = s->inc_opts->ignore_watermarks;
  cache_opts.load_all_images = s->inc_opts->load_all_images;
  // RESTRICT the cache to the temporally-fed subset — this is what keeps the
  // rebuild O(fed-subset) instead of O(full-db). Empty => whole db (not used
  // on the live path).
  cache_opts.image_names = s->live_fed_names;

  auto new_cache = colmap::DatabaseCache::Create(*db, cache_opts);
  db->Close();
  s->db = colmap::Database::Open(s->db_path);  // reopen streaming handle

  if (new_cache->NumImages() < 2) {
    if (out_recache_ms) *out_recache_ms = NowMs() - t0;
    return false;  // not enough connected frames yet (keep accumulating)
  }

  // Tear down the prior mapper FIRST (it borrows the old cache + recon). With
  // discard=false, TearDown keeps registered frames + 3D points on live_recon.
  if (s->mapper) {
    try {
      s->mapper->EndReconstruction(/*discard=*/false);
    } catch (...) {
    }
    s->mapper.reset();
  }
  if (!s->live_recon) s->live_recon = std::make_shared<colmap::Reconstruction>();

  s->database_cache = new_cache;
  s->mapper = std::make_unique<colmap::IncrementalMapper>(s->database_cache);
  // BeginReconstruction re-Loads the new cache into the SAME live_recon
  // (additive: new images merged, existing poses/points preserved) and rebuilds
  // the ObservationManager snapshot over the now-larger graph.
  s->mapper->BeginReconstruction(s->live_recon);

  if (out_recache_ms) *out_recache_ms = NowMs() - t0;
  return true;
}

// LIVE bootstrap: with the just-built mapper/cache, run the seed (same body as
// begin_incremental's seed) into the live_recon. Returns true on success.
bool LiveBootstrapSeed(aether_sfm_session* s) {
  const colmap::IncrementalMapper::Options mapper_opts = s->inc_opts->Mapper();
  colmap::image_t id1 = 0, id2 = 0;
  colmap::Rigid3d cam2_from_cam1;
  if (!s->mapper->FindInitialImagePair(mapper_opts, id1, id2, cam2_from_cam1)) {
    return false;
  }
  s->mapper->RegisterInitialImagePair(mapper_opts, id1, id2, cam2_from_cam1);
  colmap::IncrementalTriangulator::Options tri_opts = s->inc_opts->Triangulation();
  tri_opts.min_angle = mapper_opts.init_min_tri_angle;
  for (const colmap::image_t image_id : {id1, id2}) {
    const colmap::Image& image = s->live_recon->Image(image_id);
    for (const colmap::data_t& data_id : image.FramePtr()->ImageIds()) {
      s->mapper->TriangulateImage(tri_opts, data_id.id);
    }
  }
  if (s->live_recon->NumPoints3D() == 0) return false;
  s->mapper->AdjustGlobalBundle(mapper_opts,
                                s->inc_opts->GlobalBundleAdjustment());
  s->live_recon->Normalize();
  s->mapper->FilterPoints(mapper_opts);
  s->mapper->FilterFrames(mapper_opts);
  return s->live_recon->NumRegFrames() > 0 && s->live_recon->NumPoints3D() > 0;
}

// LIVE register: register one already-cached image into the live model
// (RegisterNextImage -> TriangulateImage -> IterativeLocalRefinement). O(local).
// Returns true if newly registered (or already registered).
bool LiveRegisterImage(aether_sfm_session* s, colmap::image_t image_id,
                       int* out_new_points) {
  const int before_pts = static_cast<int>(s->live_recon->NumPoints3D());
  const colmap::IncrementalMapper::Options mapper_opts = s->inc_opts->Mapper();
  const bool already = s->live_recon->ExistsImage(image_id) &&
                       s->live_recon->Image(image_id).HasPose();
  bool reg_ok = already;
  bool reg_via_prior = false;
  if (!already && s->live_recon->ExistsImage(image_id)) {
    reg_ok = s->mapper->RegisterNextImage(mapper_opts, image_id);
    // AETHER POSE-PRIOR FALLBACK: if normal PnP resection failed but we hold a
    // known ARKit cam_from_world for this image, register via the prior. This
    // bypasses the 2D-3D visibility gate (reason 1/2) that the diagnostic showed
    // blocks ~94% of live frames — exactly the class a pose prior removes.
    if (!reg_ok && s->live_use_pose_prior) {
      auto pit = s->live_pose_prior.find(image_id);
      if (pit != s->live_pose_prior.end()) {
        reg_ok = s->mapper->RegisterNextImageWithPosePrior(
            mapper_opts, image_id, pit->second, /*max_reproj_error_px=*/12.0);
        if (reg_ok) {
          reg_via_prior = true;
          ++s->live_prior_reg_count;
        }
      }
    }
    // AETHER DIAGNOSTIC: record WHY this attempt failed (or clear on success).
    if (!reg_ok) {
      auto& info = s->live_reg_fail[image_id];
      info.reason = colmap::AetherLastRegFailReason();
      info.num_visible = colmap::AetherLastNumVisiblePoints3D();
      info.num_corrs = colmap::AetherLastNum2D3DCorrs();
      info.min_inliers = colmap::AetherLastMinInliers();
      ++info.attempts;
    } else {
      s->live_reg_fail.erase(image_id);
    }
  }
  (void)reg_via_prior;
  if (reg_ok) {
    const colmap::Image& image = s->live_recon->Image(image_id);
    for (const colmap::data_t& data_id : image.FramePtr()->ImageIds()) {
      s->mapper->TriangulateImage(s->inc_opts->Triangulation(), data_id.id);
    }
    // AETHER COVERAGE PROBE: cap the per-frame local BA (the p95 ~3065ms term).
    // Coverage only depends on RegisterNextImage[WithPosePrior] succeeding +
    // triangulation building cloud the prior path can link against; the local
    // bundle adjustment refines but does not change WHICH frames register, so we
    // skip it under AETHER_LIVE_BACAP to let a full-414 feed complete fast.
    if (!already && !s->live_cap_ba) {
      s->mapper->IterativeLocalRefinement(
          s->inc_opts->ba_local_max_refinements,
          s->inc_opts->ba_local_max_refinement_change, mapper_opts,
          s->inc_opts->LocalBundleAdjustment(), s->inc_opts->Triangulation(),
          image_id);
    }
  }
  if (out_new_points) {
    *out_new_points = static_cast<int>(s->live_recon->NumPoints3D()) - before_pts;
  }
  return reg_ok;
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

// ─── bench-only: attach an existing db's frozen correspondence graph ─
// Open an existing COLMAP db that already has images+keypoints+matches+TVGs and
// populate s->frames (frame_id -> image_id) in image-rowid (capture) order so the
// per-frame register path can stream over that REAL graph without re-injecting
// descriptors. Only image_id is needed by register_next_frame; descriptors/xy are
// not read on the register path (the frozen DatabaseCache owns the geometry).
aether_sfm_result_t aether_sfm_attach_db_frames(aether_sfm_session_t* s,
                                                int* out_num_frames) {
  if (out_num_frames) *out_num_frames = 0;
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    // (Re)open the db at db_path as the session db; this is a caller-owned file.
    if (s->db) s->db->Close();
    s->db = colmap::Database::Open(s->db_path);
    if (!s->db) return AETHER_SFM_ERR_DB;
    s->owns_db_file = false;  // attached an existing, caller-owned db

    std::vector<colmap::Image> images = s->db->ReadAllImages();
    // ReadAllImages returns rowid (capture) order. Map each to a frame slot.
    s->frames.clear();
    s->frames.reserve(images.size());
    for (const colmap::Image& img : images) {
      FrameRecord rec;
      rec.frame_id = static_cast<int>(s->frames.size());
      rec.image_id = img.ImageId();
      // n_keypoints/descriptors/xy left empty: the register path does not touch
      // them (geometry comes from the frozen DatabaseCache built in begin).
      s->frames.push_back(std::move(rec));
    }
    if (out_num_frames) *out_num_frames = static_cast<int>(s->frames.size());
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_DB;
  }
}

// ─── per-frame incremental register (true step-3 streaming) ─────────
// Build the live IncrementalMapper from the db accumulated so far and run the
// bootstrap seed. Mirrors IncrementalPipeline::InitializeReconstruction over the
// frozen correspondence graph (DatabaseCache::Create reads all matches/TVGs that
// add_frame_with_features persisted). Transitions ACCUMULATING -> SEEDED.
aether_sfm_result_t aether_sfm_begin_incremental(aether_sfm_session_t* s,
                                                 char* out_json, int out_cap) {
  if (!s || !s->db) return AETHER_SFM_ERR_INVALID_ARG;
  if (s->incremental_seeded) return AETHER_SFM_OK;  // idempotent
  try {
    const double t0 = NowMs();
    // Flush sqlite writes so DatabaseCache::Create sees every frame/match.
    s->db->Close();
    auto db = colmap::Database::Open(s->db_path);

    s->inc_opts = MakeShipOptions(s->image_path, /*local_only=*/false);

    // Build the (frozen) correspondence-graph cache ONCE. This is the single
    // O(N) graph load; subsequent register_next_frame calls are O(1) in N.
    colmap::DatabaseCache::Options cache_opts;
    cache_opts.min_num_matches =
        static_cast<size_t>(s->inc_opts->min_num_matches);
    cache_opts.ignore_watermarks = s->inc_opts->ignore_watermarks;
    cache_opts.load_all_images = s->inc_opts->load_all_images;
    s->database_cache = colmap::DatabaseCache::Create(*db, cache_opts);
    db->Close();
    // Reopen the streaming handle so getters/finalize still work afterwards.
    s->db = colmap::Database::Open(s->db_path);

    if (s->database_cache->NumImages() < 2) {
      if (out_json && out_cap > 0)
        std::snprintf(out_json, out_cap,
                      "{\"error\":\"need >=2 images in graph, have %zu\"}",
                      s->database_cache->NumImages());
      return AETHER_SFM_ERR_NO_INITIAL_PAIR;
    }

    s->live_recon = std::make_shared<colmap::Reconstruction>();
    s->mapper =
        std::make_unique<colmap::IncrementalMapper>(s->database_cache);
    s->mapper->BeginReconstruction(s->live_recon);

    const colmap::IncrementalMapper::Options mapper_opts =
        s->inc_opts->Mapper();

    // Bootstrap = InitializeReconstruction (incremental_pipeline.cc:406): find a
    // seed pair, register it, triangulate both, one global BA, normalize, filter.
    colmap::image_t id1 = 0, id2 = 0;
    colmap::Rigid3d cam2_from_cam1;
    if (!s->mapper->FindInitialImagePair(mapper_opts, id1, id2,
                                         cam2_from_cam1)) {
      if (out_json && out_cap > 0)
        std::snprintf(out_json, out_cap,
                      "{\"error\":\"no good initial image pair\"}");
      return AETHER_SFM_ERR_NO_INITIAL_PAIR;
    }
    s->mapper->RegisterInitialImagePair(mapper_opts, id1, id2, cam2_from_cam1);

    colmap::IncrementalTriangulator::Options tri_opts =
        s->inc_opts->Triangulation();
    tri_opts.min_angle = mapper_opts.init_min_tri_angle;
    for (const colmap::image_t image_id : {id1, id2}) {
      const colmap::Image& image = s->live_recon->Image(image_id);
      for (const colmap::data_t& data_id : image.FramePtr()->ImageIds()) {
        s->mapper->TriangulateImage(tri_opts, data_id.id);
      }
    }
    if (s->live_recon->NumPoints3D() == 0) {
      if (out_json && out_cap > 0)
        std::snprintf(out_json, out_cap,
                      "{\"error\":\"seed triangulation produced 0 points\"}");
      return AETHER_SFM_ERR_NO_INITIAL_PAIR;
    }
    s->mapper->AdjustGlobalBundle(mapper_opts,
                                  s->inc_opts->GlobalBundleAdjustment());
    s->live_recon->Normalize();
    s->mapper->FilterPoints(mapper_opts);
    s->mapper->FilterFrames(mapper_opts);
    if (s->live_recon->NumRegFrames() == 0 ||
        s->live_recon->NumPoints3D() == 0) {
      if (out_json && out_cap > 0)
        std::snprintf(out_json, out_cap,
                      "{\"error\":\"seed failed after BA/filter\"}");
      return AETHER_SFM_ERR_NO_INITIAL_PAIR;
    }

    s->incremental_seeded = true;
    {
      std::lock_guard<std::mutex> lk(s->recon_mutex);
      s->recon = s->live_recon;  // getters read the live model
    }
    const double seed_ms = NowMs() - t0;
    if (out_json && out_cap > 0) {
      std::snprintf(
          out_json, out_cap,
          "{\"seed_ms\":%.1f,\"seed_img1\":%d,\"seed_img2\":%d,"
          "\"reg_frames\":%zu,\"points3d\":%zu,\"reproj_px\":%.4f}",
          seed_ms, static_cast<int>(id1), static_cast<int>(id2),
          s->live_recon->NumRegFrames(), s->live_recon->NumPoints3D(),
          s->live_recon->ComputeMeanReprojectionError());
    }
    return AETHER_SFM_OK;
  } catch (const std::exception& e) {
    if (out_json && out_cap > 0)
      std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return AETHER_SFM_ERR_INTERNAL;
  }
}

aether_sfm_result_t aether_sfm_register_next_frame(
    aether_sfm_session_t* s, int frame_id, double out_pose_qwxyz[4],
    double out_pose_t[3], int* out_registered, int* out_new_points,
    int* out_total_points, double* out_reproj) {
  if (out_registered) *out_registered = 0;
  if (out_new_points) *out_new_points = 0;
  if (!s || !s->mapper || !s->incremental_seeded) {
    return AETHER_SFM_ERR_NOT_REGISTERED;  // begin_incremental not run / failed
  }
  if (frame_id < 0 || frame_id >= static_cast<int>(s->frames.size())) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  try {
    const colmap::image_t image_id = s->frames[frame_id].image_id;
    if (!s->live_recon->ExistsImage(image_id)) {
      // Frame not in the frozen graph (added after begin_incremental).
      return AETHER_SFM_ERR_INVALID_ARG;
    }
    // Already registered (e.g. it was a seed image): report its current state.
    const bool already = s->live_recon->Image(image_id).HasPose();
    const int before_pts = static_cast<int>(s->live_recon->NumPoints3D());

    const colmap::IncrementalMapper::Options mapper_opts =
        s->inc_opts->Mapper();

    bool reg_ok = already;
    if (!already) {
      // Per-frame body (incremental_pipeline.cc:583-617), one frame:
      //   RegisterNextImage -> TriangulateImage(frame's images)
      //   -> IterativeLocalRefinement (local window; NO global BA, NO
      //      FindNextImages O(N) scan — we know the frame_id directly).
      reg_ok = s->mapper->RegisterNextImage(mapper_opts, image_id);
    }

    if (reg_ok) {
      const colmap::Image& image = s->live_recon->Image(image_id);
      for (const colmap::data_t& data_id : image.FramePtr()->ImageIds()) {
        s->mapper->TriangulateImage(s->inc_opts->Triangulation(), data_id.id);
      }
      if (!already) {
        s->mapper->IterativeLocalRefinement(
            s->inc_opts->ba_local_max_refinements,
            s->inc_opts->ba_local_max_refinement_change, mapper_opts,
            s->inc_opts->LocalBundleAdjustment(), s->inc_opts->Triangulation(),
            image_id);
      }
    }

    const int after_pts = static_cast<int>(s->live_recon->NumPoints3D());
    if (out_registered) *out_registered = reg_ok ? 1 : 0;
    if (out_new_points) *out_new_points = after_pts - before_pts;
    if (out_total_points) *out_total_points = after_pts;

    if (reg_ok && (out_pose_qwxyz || out_pose_t)) {
      const colmap::Rigid3d c_from_w =
          s->live_recon->Image(image_id).CamFromWorld();
      const Eigen::Quaterniond q = c_from_w.rotation();
      if (out_pose_qwxyz) {
        out_pose_qwxyz[0] = q.w();
        out_pose_qwxyz[1] = q.x();
        out_pose_qwxyz[2] = q.y();
        out_pose_qwxyz[3] = q.z();
      }
      if (out_pose_t) {
        out_pose_t[0] = c_from_w.translation().x();
        out_pose_t[1] = c_from_w.translation().y();
        out_pose_t[2] = c_from_w.translation().z();
      }
    }
    if (out_reproj) {
      s->live_recon->UpdatePoint3DErrors();
      *out_reproj = s->live_recon->ComputeMeanReprojectionError();
    }
    return AETHER_SFM_OK;  // not-registered (reg_ok==0) is a normal outcome
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_INTERNAL;
  }
}

// ─── TRUE LIVE-INTERLEAVED add+register ─────────────────────────────
aether_sfm_result_t aether_sfm_set_live_params(aether_sfm_session_t* s,
                                               int recache_every,
                                               int bootstrap_k,
                                               int max_register_per_call) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  if (recache_every > 0) s->live_recache_every = recache_every;
  if (bootstrap_k >= 2) s->live_bootstrap_k = bootstrap_k;
  if (max_register_per_call > 0)
    s->live_max_register_per_call = max_register_per_call;
  // AETHER COVERAGE PROBE: env knob to cap the per-frame local BA. Env-gated so
  // it stays out of the stable ABI (this is a diagnostic-only path).
  if (const char* e = std::getenv("AETHER_LIVE_BACAP")) {
    s->live_cap_ba = (e[0] != '0');
    std::fprintf(stderr, "[aether] AETHER_LIVE_BACAP=%s -> live_cap_ba=%d\n", e,
                 s->live_cap_ba ? 1 : 0);
  }
  return AETHER_SFM_OK;
}

aether_sfm_result_t aether_sfm_set_pose_prior_enabled(aether_sfm_session_t* s,
                                                      int enable) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  s->live_use_pose_prior = (enable != 0);
  return AETHER_SFM_OK;
}

aether_sfm_result_t aether_sfm_set_image_pose_prior(
    aether_sfm_session_t* s, int image_id, const double* cam_from_world_3x4) {
  if (!s || !cam_from_world_3x4 || image_id <= 0)
    return AETHER_SFM_ERR_INVALID_ARG;
  const double* m = cam_from_world_3x4;
  Eigen::Matrix3d R;
  R << m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10];
  const Eigen::Vector3d t(m[3], m[7], m[11]);
  const colmap::Rigid3d cam_from_world(Eigen::Quaterniond(R).normalized(), t);
  s->live_pose_prior[static_cast<colmap::image_t>(image_id)] = cam_from_world;
  return AETHER_SFM_OK;
}

int aether_sfm_num_prior_registered(aether_sfm_session_t* s) {
  return s ? s->live_prior_reg_count : 0;
}

// Stage one source-db image (with its keypoints + the matches/TVGs connecting it
// to already-staged images) into the live session db, preserving image_id. This
// is the host-verify feed: it makes the real414 graph arrive one frame at a time
// in TEMPORAL order so the live cloud genuinely grows per frame.
aether_sfm_result_t aether_sfm_live_stage_db_image(aether_sfm_session_t* s,
                                                   const char* src_db_path,
                                                   int src_image_id,
                                                   int* out_frame_id) {
  if (!s || !s->db || !src_db_path) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    // Open the source graph once and cache it on the session.
    if (!s->live_src_db) {
      s->live_src_db = colmap::Database::Open(src_db_path);
      if (!s->live_src_db) return AETHER_SFM_ERR_DB;
      // Copy rigs + cameras up-front (small, shared by all images).
      for (const colmap::Rig& rig : s->live_src_db->ReadAllRigs()) {
        if (!s->db->ExistsRig(rig.RigId())) s->db->WriteRig(rig, /*use=*/true);
      }
      for (const colmap::Camera& cam : s->live_src_db->ReadAllCameras()) {
        if (!s->db->ExistsCamera(cam.camera_id))
          s->db->WriteCamera(cam, /*use=*/true);
      }
    }
    const colmap::image_t image_id =
        static_cast<colmap::image_t>(src_image_id);
    // The feed index for this staged frame is the number staged so far; record
    // the feed_idx -> image_id map so add_and_register_frame can resolve it.
    const int feed_idx = static_cast<int>(s->live_frame_to_image.size());
    if (s->db->ExistsImage(image_id)) {
      // already staged (idempotent) — keep the existing mapping.
      if (out_frame_id) *out_frame_id = feed_idx;
      return AETHER_SFM_OK;
    }
    // Frame (4.0.4 rigs/frames): copy the owning frame if present + not yet here.
    colmap::Image img = s->live_src_db->ReadImage(image_id);
    if (img.HasFrameId() && !s->db->ExistsFrame(img.FrameId())) {
      colmap::Frame fr = s->live_src_db->ReadFrame(img.FrameId());
      s->db->WriteFrame(fr, /*use_frame_id=*/true);
    }
    s->db->WriteImage(img, /*use_image_id=*/true);
    s->db->WriteKeypoints(image_id, s->live_src_db->ReadKeypoints(image_id));

    // Copy matches + TVGs linking this image to ALREADY-staged images (temporal:
    // only earlier-fed frames exist yet, exactly the streaming reality).
    for (const auto& [fed_idx, prev_image_id] : s->live_frame_to_image) {
      if (!s->live_src_db->ExistsMatches(prev_image_id, image_id) &&
          !s->live_src_db->ExistsMatches(image_id, prev_image_id)) {
        continue;
      }
      colmap::FeatureMatches m =
          s->live_src_db->ReadMatches(prev_image_id, image_id);
      if (!m.empty()) s->db->WriteMatches(prev_image_id, image_id, m);
      if (s->live_src_db->ExistsTwoViewGeometry(prev_image_id, image_id)) {
        colmap::TwoViewGeometry tvg =
            s->live_src_db->ReadTwoViewGeometry(prev_image_id, image_id);
        s->db->WriteTwoViewGeometry(prev_image_id, image_id, tvg);
      }
    }
    // Record the feed_idx -> image_id map now that the frame is staged.
    s->live_frame_to_image[feed_idx] = image_id;
    if (out_frame_id) *out_frame_id = feed_idx;
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_DB;
  }
}

aether_sfm_result_t aether_sfm_add_and_register_frame(
    aether_sfm_session_t* s, int frame_id,
    aether_sfm_live_stats_t* out_stats) {
  if (out_stats) std::memset(out_stats, 0, sizeof(*out_stats));
  if (!s || !s->db) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    s->live_mode = true;
    // Resolve the image_id for this feed index. Production: add_frame_with_features
    // already wrote it and recorded s->frames[frame_id].image_id. Bench: the
    // staging helper wrote it preserving image_id (frame_to_image filled below).
    colmap::image_t image_id = 0;
    if (frame_id >= 0 && frame_id < static_cast<int>(s->frames.size())) {
      image_id = s->frames[frame_id].image_id;
    }
    auto it = s->live_frame_to_image.find(frame_id);
    if (it != s->live_frame_to_image.end()) image_id = it->second;
    if (image_id == 0) return AETHER_SFM_ERR_INVALID_ARG;

    // Record this frame's name into the fed-subset filter so the next re-cache
    // includes it. The graph GROWS by exactly this image each call.
    const std::string name = s->db->ReadImage(image_id).Name();
    s->live_fed_names.insert(name);
    s->live_frame_to_image[frame_id] = image_id;
    ++s->live_fed_count;
    ++s->live_since_recache;

    double recache_ms = 0.0;
    int did_recache = 0, did_bootstrap = 0;

    if (!s->live_seeded) {
      // BOOTSTRAP phase: accumulate live_bootstrap_k frames, then build the cache
      // over them and seed. Until seeded, the cloud is empty (no registered model
      // yet) — this is the live bootstrap, not a pre-built full graph.
      if (s->live_fed_count >= s->live_bootstrap_k) {
        if (LiveRebuildCacheAndMapper(s, &recache_ms)) {
          did_recache = 1;
          s->live_since_recache = 0;
          if (LiveBootstrapSeed(s)) {
            s->live_seeded = true;
            did_bootstrap = 1;
            {
              std::lock_guard<std::mutex> lk(s->recon_mutex);
              s->recon = s->live_recon;  // getters read the live cloud
            }
            // All fed images become the pending frontier except the ones the seed
            // just registered; the next add_and_register sweep will register the
            // ones now connected to the seed.
            for (const auto& [fidx, iid] : s->live_frame_to_image) {
              if (!(s->live_recon->ExistsImage(iid) &&
                    s->live_recon->Image(iid).HasPose())) {
                s->live_pending.insert(iid);
              }
            }
          }
        }
      }
      // Not seeded yet (or seed not ready): report accumulation state.
      if (out_stats) {
        out_stats->registered = 0;
        out_stats->new_points =
            s->live_recon ? static_cast<int>(s->live_recon->NumPoints3D()) : 0;
        out_stats->total_points = out_stats->new_points;
        out_stats->total_registered =
            s->live_recon ? static_cast<int>(s->live_recon->NumRegFrames()) : 0;
        out_stats->reproj_px =
            (s->live_recon && s->live_recon->NumPoints3D() > 0)
                ? s->live_recon->ComputeMeanReprojectionError()
                : 0.0;
        out_stats->recache_ms = recache_ms;
        out_stats->did_recache = did_recache;
        out_stats->did_bootstrap = did_bootstrap;
      }
      return AETHER_SFM_OK;
    }

    // STEADY-STATE: the just-fed frame joins the pending frontier. We re-cache
    // when due (periodic) OR when the current frame isn't in the (stale) cache,
    // so its correspondences become visible; then we sweep the pending frontier.
    s->live_pending.insert(image_id);

    // Re-cache PERIODICALLY only (every live_recache_every frames). The current
    // frame need NOT be in the cache this instant — it waits in the pending
    // frontier for the next periodic rebuild. This bounds the re-cache CADENCE so
    // the per-frame register cost stays flat (no force-rebuild every frame). The
    // cloud therefore grows in bursts every live_recache_every frames (the genuine
    // semi-live behavior the workaround provides), not strictly 1-per-frame.
    const bool recache_due = s->live_since_recache >= s->live_recache_every;
    if (recache_due) {
      if (LiveRebuildCacheAndMapper(s, &recache_ms)) {
        did_recache = 1;
        s->live_since_recache = 0;
      }
    }

    int new_points = 0;
    int registered_this_call = 0;
    bool current_reg = false;
    const double tr0 = NowMs();
    // BOUNDED retry sweep over the pending frontier. Registering one frame +
    // triangulating it gives covisible neighbours new 2D-3D correspondences, so
    // newly-registerable frames cascade — but we CAP the cascade at
    // live_max_register_per_call so the per-frame cost stays O(local*cap), NOT
    // O(pending). The remaining pending frames register on subsequent calls,
    // spreading the burst and keeping the cloud growing steadily. Each registered
    // frame's local BA is O(local); the cap bounds how many run per call.
    if (s->mapper && s->live_recon) {
      bool progress = true;
      while (progress && registered_this_call < s->live_max_register_per_call) {
        progress = false;
        std::vector<colmap::image_t> to_try(s->live_pending.begin(),
                                            s->live_pending.end());
        for (const colmap::image_t cand : to_try) {
          if (registered_this_call >= s->live_max_register_per_call) break;
          if (!s->live_recon->ExistsImage(cand)) continue;  // not in cache yet
          int np = 0;
          if (LiveRegisterImage(s, cand, &np)) {
            s->live_pending.erase(cand);
            new_points += np;
            ++registered_this_call;
            progress = true;
            if (cand == image_id) current_reg = true;
          }
        }
      }
    }
    const double register_ms = NowMs() - tr0;

    if (out_stats) {
      // "registered" = the cloud grew live this call (current frame got a pose,
      // OR a pending frame finally registered now that its neighbours are in).
      out_stats->registered = (current_reg || new_points > 0) ? 1 : 0;
      out_stats->new_points = new_points;
      out_stats->total_points =
          static_cast<int>(s->live_recon->NumPoints3D());
      out_stats->total_registered =
          static_cast<int>(s->live_recon->NumRegFrames());
      s->live_recon->UpdatePoint3DErrors();
      out_stats->reproj_px = s->live_recon->ComputeMeanReprojectionError();
      out_stats->register_ms = register_ms;
      out_stats->recache_ms = recache_ms;
      out_stats->did_recache = did_recache;
      out_stats->did_bootstrap = did_bootstrap;
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

// ── AETHER DIAGNOSTIC: dump the per-image final RegisterNextImage failure-reason
//    distribution for every FED frame that never registered, plus the raw gate
//    counts (visible 3D pts / 2D-3D corrs vs the min-inlier threshold). Writes a
//    line-per-failing-frame CSV to out_buf:
//      feed_image_id,reason,num_visible,num_corrs,min_inliers,attempts
//    reason codes: 0=success 1=too few VISIBLE 3D pts 2=too few 2D-3D corrs
//                  3=PnP failed 4=too few inliers 5=refine failed
//                  6=other/early 7=never attempted (never in cache during a sweep)
// Returns the number of failing (unregistered fed) frames.
int aether_sfm_dump_reg_failures(aether_sfm_session_t* s, char* out_buf,
                                 int out_cap) {
  if (!s || !s->live_recon) return 0;
  int n_fail = 0;
  int off = 0;
  auto emit = [&](colmap::image_t iid, int reason, int nv, int nc, int mi,
                  int att) {
    if (out_buf && off < out_cap - 1) {
      int w = std::snprintf(out_buf + off, out_cap - off,
                            "%d,%d,%d,%d,%d,%d\n", static_cast<int>(iid), reason,
                            nv, nc, mi, att);
      if (w > 0) off += w;
    }
    ++n_fail;
  };
  // Every fed frame that does NOT have a pose in the live model is a failure.
  for (const auto& [feed_idx, iid] : s->live_frame_to_image) {
    (void)feed_idx;
    const bool registered = s->live_recon->ExistsImage(iid) &&
                            s->live_recon->Image(iid).HasPose();
    if (registered) continue;
    auto it = s->live_reg_fail.find(iid);
    if (it != s->live_reg_fail.end()) {
      emit(iid, it->second.reason, it->second.num_visible, it->second.num_corrs,
           it->second.min_inliers, it->second.attempts);
    } else {
      // Fed but RegisterNextImage was never even called on it (it never entered
      // the cache-resident pending set during a sweep). reason 7.
      emit(iid, 7, -1, -1, -1, 0);
    }
  }
  return n_fail;
}

void aether_sfm_free(aether_sfm_session_t* s) {
  if (!s) return;
  // The async-finalize worker captures `s`; it MUST finish before we delete.
  if (s->refine_thread.joinable()) s->refine_thread.join();
  // Tear down the live incremental mapper before its borrowed DatabaseCache /
  // live Reconstruction drop. EndReconstruction(discard=false) finalizes the
  // registration stats; order matters (mapper borrows database_cache).
  if (s->mapper) {
    try {
      s->mapper->EndReconstruction(/*discard=*/false);
    } catch (...) {
    }
    s->mapper.reset();
  }
  if (s->live_src_db) {
    try {
      s->live_src_db->Close();
    } catch (...) {
    }
  }
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
