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
#include "colmap/geometry/triangulation.h"
#include "colmap/scene/camera.h"
#include "colmap/scene/database.h"
#include "colmap/scene/image.h"
#include "colmap/scene/point3d.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/reconstruction_manager.h"
#include "colmap/scene/two_view_geometry.h"
#include "colmap/scene/track.h"
#include "colmap/estimators/bundle_adjustment.h"
#include "colmap/estimators/bundle_adjustment_ceres.h"
#include "colmap/sfm/observation_manager.h"

#include <glog/logging.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// On-device DSP-SIFT extractor + CPU matcher (dsp_sift_c.cc, same archive set).
extern "C" int aether_dsp_sift_extract(const uint8_t* gray, int width,
                                       int height, int max_features,
                                       float* out_xy, uint8_t* out_desc,
                                       int out_cap, int* out_count);
// GPU DSP-SIFT extractor (dsp_sift_gpu_c.cc). Same xy/128-d/UBC/RootSIFT
// contract; falls back to the CPU _threaded path in-ABI on any GPU failure
// (init / capacity / NaN), so the caller is unaware. num_threads is ignored.
//
// WEAK symbol: targets that don't link the Dawn-backed dsp_sift_gpu_c.cc (e.g.
// CPU-only host benches) still link aether_sfm_c.cc — the weak ref resolves to
// nullptr there, and the use_gpu_extract path guards on it (falls back to CPU).
// Production iOS/Android links dsp_sift_gpu_c.cc so the symbol is real.
extern "C" __attribute__((weak)) int aether_dsp_sift_extract_gpu(
    const uint8_t* gray, int width, int height, int max_features,
    int num_threads, float* out_xy, uint8_t* out_desc, int out_cap,
    int* out_count);
extern "C" int aether_sift_match(const uint8_t* desc1, int n1,
                                 const uint8_t* desc2, int n2, double max_ratio,
                                 int* out_num_matches);
// Pairs-returning variant (dsp_sift_c.cc): identical cross-checked matcher,
// but emits the [idx1, idx2] correspondence list add_frame persists via
// WriteMatches/WriteTwoViewGeometry — the streaming-registration enabler.
extern "C" int aether_sift_match_pairs(const uint8_t* desc1, int n1,
                                       const uint8_t* desc2, int n2,
                                       double max_ratio, uint32_t* out_pairs,
                                       int max_pairs, int* out_num_matches);
// GPU tiled-GEMM matcher, pairs variant (platform-side TU, e.g. pocketworld's
// pwsfm_gpu_match.mm — simdgroup_matrix Metal, mutual cross-check INSIDE,
// bench-proven 11568x11568 @ 119 ms on A16). WEAK for the same reason as
// aether_dsp_sift_extract_gpu: host benches / non-Metal targets resolve it to
// nullptr and add_frame stays on the CPU matcher. Selected via
// options.use_gpu_match; any non-zero return skips that pair on device. Host
// benches without the weak symbol still use the CPU matcher.
extern "C" __attribute__((weak)) int aether_gpu_match_gemm_pairs(
    const uint8_t* desc1, int n1, const uint8_t* desc2, int n2,
    double max_ratio, uint32_t* out_pairs, int max_pairs,
    int* out_num_matches);
// Geometry-guided Metal matcher. guide_mode 1 applies an E/F epipolar band;
// guide_mode 2 applies a homography transfer-error gate. matrix12 maps the
// first image into the second image's geometry and matrix21 is its reverse.
// Spatial revisit matching is intentionally fail-closed when this device-side
// symbol is unavailable or errors; it must never open the minutes-scale CPU
// brute-force fallback during finish-time refinement.
extern "C" __attribute__((weak)) int aether_gpu_match_gemm_pairs_guided(
    const uint8_t* desc1, int n1, const float* xy1,
    const uint8_t* desc2, int n2, const float* xy2, double max_ratio,
    const float* matrix12, const float* matrix21, int guide_mode,
    float max_residual, uint32_t* out_pairs, int max_pairs,
    int* out_num_matches);

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
  // Keypoint positions (pixel coords at the fed resolution), kept so the
  // two-view geometry of every new pair can be estimated without a sqlite
  // read-back. ~1.5k pts × 16 B ≈ 24 KB/frame — negligible.
  std::vector<Eigen::Vector2d> points;
  // ARKit CamFromWorld for this frame, ALREADY flipped into COLMAP camera axes
  // (C = diag(1,-1,-1)); used ONLY by the throwaway live-preview triangulation.
  colmap::Rigid3d cam_from_world;
  bool has_pose = false;
};

struct PointIdPair {
  colmap::point3D_t a = 0;
  colmap::point3D_t b = 0;

  bool operator==(const PointIdPair& other) const {
    return a == other.a && b == other.b;
  }
};

struct PointIdPairHash {
  size_t operator()(const PointIdPair& p) const {
    const size_t h1 = std::hash<colmap::point3D_t>{}(p.a);
    const size_t h2 = std::hash<colmap::point3D_t>{}(p.b);
    return h1 ^ (h2 + 0x9e3779b97f4a7c15ULL + (h1 << 6) + (h1 >> 2));
  }
};

PointIdPair CanonicalPointPair(colmap::point3D_t p1, colmap::point3D_t p2) {
  return p1 < p2 ? PointIdPair{p1, p2} : PointIdPair{p2, p1};
}

bool TracksHaveDisjointImages(const colmap::Track& t1,
                              const colmap::Track& t2) {
  std::unordered_set<colmap::image_t> images;
  images.reserve(t1.Length() + t2.Length());
  for (const auto& el : t1.Elements()) {
    if (!images.insert(el.image_id).second) return false;
  }
  for (const auto& el : t2.Elements()) {
    if (!images.insert(el.image_id).second) return false;
  }
  return true;
}

bool ReprojectsCleanlyToTrack(const colmap::Reconstruction& recon,
                              const colmap::Camera& camera,
                              const colmap::Track& track,
                              const Eigen::Vector3d& xyz,
                              double max_reproj_px) {
  for (const auto& el : track.Elements()) {
    if (!recon.ExistsImage(el.image_id)) return false;
    const colmap::Image& image = recon.Image(el.image_id);
    if (!image.HasPose() || el.point2D_idx >= image.NumPoints2D()) return false;
    const Eigen::Vector3d x_cam = image.CamFromWorld() * xyz;
    if (x_cam.z() <= 0.0) return false;
    const std::optional<Eigen::Vector2d> px = camera.ImgFromCam(x_cam);
    if (!px) return false;
    if ((*px - image.Point2D(el.point2D_idx).xy).norm() > max_reproj_px) {
      return false;
    }
  }
  return true;
}

bool CanMergeLivePoints(const colmap::Reconstruction& recon,
                        const colmap::Camera& camera,
                        colmap::point3D_t pid1,
                        colmap::point3D_t pid2,
                        double max_reproj_px) {
  if (pid1 == pid2) return false;
  if (!recon.ExistsPoint3D(pid1) || !recon.ExistsPoint3D(pid2)) return false;
  const colmap::Point3D& p1 = recon.Point3D(pid1);
  const colmap::Point3D& p2 = recon.Point3D(pid2);
  if (!TracksHaveDisjointImages(p1.track, p2.track)) return false;
  const double n1 = static_cast<double>(p1.track.Length());
  const double n2 = static_cast<double>(p2.track.Length());
  if (n1 <= 0.0 || n2 <= 0.0) return false;
  const Eigen::Vector3d merged_xyz = (n1 * p1.xyz + n2 * p2.xyz) / (n1 + n2);
  return ReprojectsCleanlyToTrack(recon, camera, p1.track, merged_xyz,
                                  max_reproj_px) &&
         ReprojectsCleanlyToTrack(recon, camera, p2.track, merged_xyz,
                                  max_reproj_px);
}

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
  // Copy of the shared SIMPLE_PINHOLE camera written to the db on the first
  // frame — needed by EstimateTwoViewGeometry for every subsequent pair
  // (same object for both sides: single shared camera per session).
  colmap::Camera camera;

  // Rough live-preview cloud (throwaway): triangulated during capture from the
  // per-frame matches + ARKit poses. World frame = ARKit world. The finalize
  // pipeline is unchanged and still yields the authoritative model.
  std::vector<Eigen::Vector3d> preview_points;
  std::mutex preview_mutex;  // add_frame writer vs. get_preview_points reader

  // ── Streaming live local-BA preview (replaces the raw-triangulation cloud) ──
  // Incrementally grown Reconstruction: shared camera+rig seeded on frame 0, one
  // registered image per posed frame (ARKit pose), tracks grown from the
  // cross-checked matches, refined by a windowed Cauchy local BA each frame.
  // Separate from `recon` (finalize output); owned solely by add_frame (worker).
  colmap::Reconstruction live_recon;
  bool live_recon_ready = false;                                // camera+rig added
  std::vector<colmap::image_t> reg_order;                       // registration order → window
  int ba_window = 12;    // W: most-recent frames refined per pass (K=12 validated)
  int ba_every_n = 1;    // run the windowed BA every Nth frame (raise under thermal)
  int ba_max_iters = 5;  // bounded ceres iters/frame for the ~2s budget
  // Cumulative streaming-quality telemetry (whole capture) — surfaced by
  // aether_sfm_stream_stats so the worker can log which floater filter did what.
  int64_t stat_tvg_inlier_pairs = 0;  // grow/create pairs taken from TVG inliers
  int64_t stat_raw_pairs = 0;         // pairs that fell back to raw (empty inliers)
  int64_t stat_grow_rejected = 0;     // grow-gate reproj/cheirality rejections
  int64_t stat_grow_accepted = 0;     // observations grown onto existing points
  int64_t stat_grow_reject_cheirality = 0;
  int64_t stat_grow_reject_reproj = 0;
  int64_t stat_create_reject_cheirality = 0;
  int64_t stat_create_reject_tri_angle = 0;
  int64_t stat_create_reject_reproj = 0;
  int64_t stat_already_assigned = 0;  // both observations already on same track
  int64_t stat_merge_needed = 0;      // both observations on different tracks
  int64_t stat_merge_accepted = 0;    // conservative live track merges accepted
  int64_t stat_merge_rejected = 0;    // unique live merge attempts rejected
  int64_t stat_spatial_pairs_considered = 0;  // ARKit-near/time-far candidates
  int64_t stat_spatial_pairs_attempted = 0;   // descriptor matches attempted
  int64_t stat_spatial_pairs_written = 0;     // TVG-verified pairs added to db
  int64_t stat_spatial_inliers = 0;           // total TVG inlier matches written
  int64_t stat_spatial_anchor_attempted = 0;  // globally scheduled center anchors
  int64_t stat_spatial_anchor_passed = 0;     // centers passing strict guided gate
  int64_t stat_spatial_regions_confirmed = 0; // revisit regions passing 2-of-3
  int64_t stat_spatial_expanded_attempted = 0;// i+/-2 x j+/-2 pair attempts
  int64_t stat_spatial_guided_pairs = 0;      // guided matcher calls completed
  int64_t stat_spatial_guided_inliers = 0;    // matches returned by guided calls
  int64_t stat_spatial_quadratic_attempted = 0;// exponential-time fallback work
  int64_t stat_spatial_quadratic_written = 0; // fallback pairs committed to db
  int64_t stat_spatial_budget_skipped = 0;    // fair scheduler work omitted at cap
  int64_t stat_temporal_detail_pairs = 0;     // K-neighbor TVGs revisited post-BA
  int64_t stat_temporal_detail_matches = 0;   // temporal TVG inliers inspected
  int64_t stat_temporal_detail_created = 0;   // new final-pose detail points
  int64_t stat_temporal_detail_grown = 0;     // observations added to final tracks
  int64_t stat_temporal_detail_reject_cheirality = 0;
  int64_t stat_temporal_detail_reject_reproj = 0;
  int64_t stat_temporal_detail_reject_tri_angle = 0;
  int64_t stat_temporal_detail_conflicts = 0; // cross-track / duplicate-image skips
  int64_t stat_reproj_filtered = 0;   // obs deleted by the post-BA reproj filter
  int64_t stat_tri_filtered = 0;      // obs deleted by the post-BA tri-angle filter

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

  // Per-frame telemetry read back by aether_sfm_debug_last (perf diagnostics).
  // The exact values behind the device log line
  //   extract=<..>ms match=<..>ms cand=<..> gpuM=<..> cpuM=<..>
  // Written at the end of each aether_sfm_add_frame; describe the LAST frame.
  double last_extract_ms = 0.0;   // DSP-SIFT extract wall time (>~2000 => GPU->CPU fallback)
  double last_match_ms = 0.0;     // total per-pair matching wall time this frame
  int last_n_cand = 0;            // # previous frames in the window matched against
  int last_gpu_matches = 0;       // matches accepted via the GPU GEMM matcher
  int last_cpu_matches = 0;       // matches accepted via CPU fallback (>0 => GPU matcher failed)
};

namespace {

struct SpatialRevisitCandidate {
  int i = -1;
  int j = -1;
  double distance_m = 0.0;
  double angle_rad = 0.0;
  double score = 0.0;
  int anchor_rank = 0;
  bool quadratic = false;
};

Eigen::Vector3d CameraForwardWorld(const colmap::Rigid3d& cam_from_world) {
  return cam_from_world.rotation().inverse() * Eigen::Vector3d(0.0, 0.0, 1.0);
}

constexpr int kSpatialCandidatePool = 12;
constexpr int kSpatialAnchorsPerFrame = 3;
constexpr int kSpatialPreliminaryInliers = 15;
constexpr int kSpatialFinalInliers = 30;
constexpr double kSpatialPreliminaryMinInlierRatio = 0.10;
constexpr double kSpatialFinalMinInlierRatio = 0.25;
constexpr double kSpatialMatchRatio = 0.8;
constexpr double kGuidedMaxErrorPixels = 4.0;
constexpr double kSpatialFinalMaxErrorPixels = 1.0;
constexpr int kSpatialMaxTotalPairs = 1200;
// Reserve finish-time budget for 2-of-3 confirmation, neighborhood expansion,
// and the quadratic fallback. At 300-400 frames this still gives every frame
// its best anchor before any frame consumes all three.
constexpr int kSpatialInitialAnchorBudget = 720;

enum class SpatialPairPurpose {
  kAnchor,
  kConfirm,
  kExpansion,
  kQuadraticAnchor,
  kQuadraticConfirm,
  kQuadraticExpansion,
};

struct VerifiedSpatialPair {
  bool valid = false;
  bool existing = false;
  bool written = false;
  int raw_matches = 0;
  int initial_inliers = 0;
  int final_inliers = 0;
  colmap::FeatureMatches matches;
  colmap::TwoViewGeometry geometry;
};

using SpatialPairCache = std::unordered_map<uint64_t, VerifiedSpatialPair>;

uint64_t FramePairKey(int frame_idx1, int frame_idx2) {
  const uint32_t hi = static_cast<uint32_t>(std::max(frame_idx1, frame_idx2));
  const uint32_t lo = static_cast<uint32_t>(std::min(frame_idx1, frame_idx2));
  return (static_cast<uint64_t>(hi) << 32) | lo;
}

bool IsQuadraticPurpose(SpatialPairPurpose purpose) {
  return purpose == SpatialPairPurpose::kQuadraticAnchor ||
         purpose == SpatialPairPurpose::kQuadraticConfirm ||
         purpose == SpatialPairPurpose::kQuadraticExpansion;
}

bool IsExpansionPurpose(SpatialPairPurpose purpose) {
  return purpose == SpatialPairPurpose::kExpansion ||
         purpose == SpatialPairPurpose::kQuadraticExpansion;
}

void CopyMatrixRowMajor(const Eigen::Matrix3d& matrix,
                        std::array<float, 9>* out) {
  for (int row = 0; row < 3; ++row) {
    for (int col = 0; col < 3; ++col) {
      (*out)[row * 3 + col] = static_cast<float>(matrix(row, col));
    }
  }
}

void CopyPixelPoints(const std::vector<Eigen::Vector2d>& points,
                     std::vector<float>* out) {
  out->resize(points.size() * 2);
  for (size_t i = 0; i < points.size(); ++i) {
    (*out)[2 * i] = static_cast<float>(points[i].x());
    (*out)[2 * i + 1] = static_cast<float>(points[i].y());
  }
}

void CopyNormalizedPoints(const colmap::Camera& camera,
                          const std::vector<Eigen::Vector2d>& points,
                          std::vector<float>* out) {
  out->resize(points.size() * 2);
  for (size_t i = 0; i < points.size(); ++i) {
    const std::optional<Eigen::Vector2d> normalized = camera.CamFromImg(points[i]);
    (*out)[2 * i] = normalized ? static_cast<float>(normalized->x()) : 1e6f;
    (*out)[2 * i + 1] =
        normalized ? static_cast<float>(normalized->y()) : 1e6f;
  }
}

bool PrepareGuidedGeometry(const aether_sfm_session* s,
                           const FrameRecord& a,
                           const FrameRecord& b,
                           const colmap::TwoViewGeometry& geometry,
                           std::vector<float>* xy_a,
                           std::vector<float>* xy_b,
                           std::array<float, 9>* matrix_ab,
                           std::array<float, 9>* matrix_ba,
                           int* guide_mode,
                           float* max_residual) {
  if (!s || !xy_a || !xy_b || !matrix_ab || !matrix_ba || !guide_mode ||
      !max_residual) {
    return false;
  }

  const bool calibrated =
      (geometry.config == colmap::TwoViewGeometry::CALIBRATED ||
       geometry.config == colmap::TwoViewGeometry::CALIBRATED_RIG) &&
      geometry.E.has_value();
  const bool uncalibrated =
      geometry.config == colmap::TwoViewGeometry::UNCALIBRATED &&
      geometry.F.has_value();
  const bool homography =
      (geometry.config == colmap::TwoViewGeometry::PLANAR ||
       geometry.config == colmap::TwoViewGeometry::PANORAMIC ||
       geometry.config == colmap::TwoViewGeometry::PLANAR_OR_PANORAMIC) &&
      geometry.H.has_value();

  if (calibrated) {
    CopyNormalizedPoints(s->camera, a.points, xy_a);
    CopyNormalizedPoints(s->camera, b.points, xy_b);
    CopyMatrixRowMajor(*geometry.E, matrix_ab);
    CopyMatrixRowMajor(geometry.E->transpose(), matrix_ba);
    const double normalized_error =
        s->camera.CamFromImgThreshold(kGuidedMaxErrorPixels);
    *max_residual = static_cast<float>(normalized_error * normalized_error);
    *guide_mode = 1;
    return true;
  }
  if (uncalibrated) {
    CopyPixelPoints(a.points, xy_a);
    CopyPixelPoints(b.points, xy_b);
    CopyMatrixRowMajor(*geometry.F, matrix_ab);
    CopyMatrixRowMajor(geometry.F->transpose(), matrix_ba);
    *max_residual = static_cast<float>(kGuidedMaxErrorPixels *
                                       kGuidedMaxErrorPixels);
    *guide_mode = 1;
    return true;
  }
  if (homography) {
    if (!geometry.H->allFinite() || std::abs(geometry.H->determinant()) < 1e-12) {
      return false;
    }
    const Eigen::Matrix3d inverse = geometry.H->inverse();
    if (!inverse.allFinite()) return false;
    CopyPixelPoints(a.points, xy_a);
    CopyPixelPoints(b.points, xy_b);
    CopyMatrixRowMajor(*geometry.H, matrix_ab);
    CopyMatrixRowMajor(inverse, matrix_ba);
    *max_residual = static_cast<float>(kGuidedMaxErrorPixels *
                                       kGuidedMaxErrorPixels);
    *guide_mode = 2;
    return true;
  }
  return false;
}

bool RunGuidedSpatialMatch(aether_sfm_session* s,
                           const FrameRecord& a,
                           const FrameRecord& b,
                           const colmap::TwoViewGeometry& geometry,
                           colmap::FeatureMatches* guided_matches) {
  if (!s || !guided_matches || !s->options.use_gpu_match ||
      aether_gpu_match_gemm_pairs_guided == nullptr) {
    return false;
  }

  std::vector<float> xy_a;
  std::vector<float> xy_b;
  std::array<float, 9> matrix_ab{};
  std::array<float, 9> matrix_ba{};
  int guide_mode = 0;
  float max_residual = 0.0f;
  if (!PrepareGuidedGeometry(s, a, b, geometry, &xy_a, &xy_b, &matrix_ab,
                             &matrix_ba, &guide_mode, &max_residual)) {
    return false;
  }

  const int cap = std::min(a.n_keypoints, b.n_keypoints);
  if (cap < kSpatialFinalInliers) return false;
  std::vector<uint32_t> pair_buf(static_cast<size_t>(cap) * 2);
  int num_matches = 0;
  const int rc = aether_gpu_match_gemm_pairs_guided(
      a.descriptors.data(), a.n_keypoints, xy_a.data(), b.descriptors.data(),
      b.n_keypoints, xy_b.data(), kSpatialMatchRatio, matrix_ab.data(),
      matrix_ba.data(), guide_mode, max_residual, pair_buf.data(), cap,
      &num_matches);
  if (rc != 0) return false;

  ++s->stat_spatial_guided_pairs;
  s->stat_spatial_guided_inliers += num_matches;
  guided_matches->resize(num_matches);
  for (int m = 0; m < num_matches; ++m) {
    (*guided_matches)[m].point2D_idx1 = pair_buf[2 * m];
    (*guided_matches)[m].point2D_idx2 = pair_buf[2 * m + 1];
  }
  return true;
}

bool VerifySpatialPair(aether_sfm_session* s,
                       int frame_idx1,
                       int frame_idx2,
                       SpatialPairPurpose purpose,
                       SpatialPairCache* cache,
                       int* attempted_total) {
  if (!s || !s->db || !cache || !attempted_total || frame_idx1 == frame_idx2) {
    return false;
  }
  const int later = std::max(frame_idx1, frame_idx2);
  const int earlier = std::min(frame_idx1, frame_idx2);
  if (earlier < 0 || later >= static_cast<int>(s->frames.size())) return false;

  const uint64_t key = FramePairKey(later, earlier);
  const auto cached = cache->find(key);
  if (cached != cache->end()) return cached->second.valid;
  auto [it, inserted] = cache->try_emplace(key);
  (void)inserted;
  VerifiedSpatialPair& result = it->second;
  const FrameRecord& a = s->frames[earlier];
  const FrameRecord& b = s->frames[later];
  if (a.n_keypoints <= 0 || b.n_keypoints <= 0) return false;

  if (s->db->ExistsMatches(a.image_id, b.image_id)) {
    result.existing = true;
    if (!s->db->ExistsTwoViewGeometry(a.image_id, b.image_id)) return false;
    result.matches = s->db->ReadMatches(a.image_id, b.image_id);
    result.geometry = s->db->ReadTwoViewGeometry(a.image_id, b.image_id);
    result.raw_matches = static_cast<int>(result.matches.size());
    result.initial_inliers =
        static_cast<int>(result.geometry.inlier_matches.size());
    result.final_inliers = result.initial_inliers;
    result.valid = result.raw_matches >= kSpatialPreliminaryInliers &&
                   result.final_inliers >= kSpatialFinalInliers &&
                   static_cast<double>(result.initial_inliers) >=
                       kSpatialFinalMinInlierRatio * result.raw_matches;
    return result.valid;
  }

  if (*attempted_total >= kSpatialMaxTotalPairs) {
    ++s->stat_spatial_budget_skipped;
    return false;
  }
  ++*attempted_total;
  ++s->stat_spatial_pairs_attempted;
  if (purpose == SpatialPairPurpose::kAnchor ||
      purpose == SpatialPairPurpose::kQuadraticAnchor) {
    ++s->stat_spatial_anchor_attempted;
  }
  if (IsExpansionPurpose(purpose)) ++s->stat_spatial_expanded_attempted;
  if (IsQuadraticPurpose(purpose)) ++s->stat_spatial_quadratic_attempted;

  const int cap = std::min(a.n_keypoints, b.n_keypoints);
  if (cap < kSpatialPreliminaryInliers) return false;
  std::vector<uint32_t> pair_buf(static_cast<size_t>(cap) * 2);
  int num_matches = 0;
  int match_rc = 1;
  if (s->options.use_gpu_match) {
    // Device finish-time policy is fail-closed: missing/erroring Metal never
    // falls into O(N^2) CPU matching and turns a short finalize into minutes.
    if (aether_gpu_match_gemm_pairs == nullptr) return false;
    match_rc = aether_gpu_match_gemm_pairs(
        a.descriptors.data(), a.n_keypoints, b.descriptors.data(),
        b.n_keypoints, kSpatialMatchRatio, pair_buf.data(), cap, &num_matches);
    if (match_rc != 0) return false;
  } else {
    match_rc = aether_sift_match_pairs(
        a.descriptors.data(), a.n_keypoints, b.descriptors.data(),
        b.n_keypoints, kSpatialMatchRatio, pair_buf.data(), cap, &num_matches);
  }
  if (match_rc != 0 || num_matches < kSpatialPreliminaryInliers) return false;

  colmap::FeatureMatches matches(num_matches);
  for (int m = 0; m < num_matches; ++m) {
    matches[m].point2D_idx1 = pair_buf[2 * m];
    matches[m].point2D_idx2 = pair_buf[2 * m + 1];
  }
  colmap::FeatureMatches matches_for_tvg = matches;
  const colmap::TwoViewGeometryOptions tvg_options;
  colmap::TwoViewGeometry geometry = colmap::EstimateTwoViewGeometry(
      s->camera, a.points, s->camera, b.points, std::move(matches_for_tvg),
      tvg_options);
  const int initial_inliers =
      static_cast<int>(geometry.inlier_matches.size());
  if (initial_inliers < kSpatialPreliminaryInliers ||
      static_cast<double>(initial_inliers) <
          kSpatialPreliminaryMinInlierRatio * num_matches) {
    return false;
  }

  // Guided matching only proposes additional correspondences inside the
  // initial geometry's 4px band. It does NOT prove they are inliers. COLMAP's
  // global pipeline explicitly warns that writing guided candidates directly
  // to two_view_geometries regresses reconstruction quality. Re-estimate TVG
  // over the guided candidate set with the global mapper's strict gate before
  // any correspondence reaches sqlite.
  colmap::FeatureMatches guided_matches;
  if (!RunGuidedSpatialMatch(s, a, b, geometry, &guided_matches)) return false;
  colmap::TwoViewGeometryOptions final_tvg_options;
  final_tvg_options.ransac_options.max_error = kSpatialFinalMaxErrorPixels;
  final_tvg_options.min_num_inliers = kSpatialFinalInliers;
  final_tvg_options.min_inlier_ratio = kSpatialFinalMinInlierRatio;
  colmap::FeatureMatches guided_for_tvg = guided_matches;
  colmap::TwoViewGeometry final_geometry = colmap::EstimateTwoViewGeometry(
      s->camera, a.points, s->camera, b.points, std::move(guided_for_tvg),
      final_tvg_options);
  const int final_inliers =
      static_cast<int>(final_geometry.inlier_matches.size());
  if (final_inliers < kSpatialFinalInliers ||
      static_cast<double>(final_inliers) <
          kSpatialFinalMinInlierRatio * guided_matches.size()) {
    return false;
  }

  result.raw_matches = static_cast<int>(guided_matches.size());
  result.initial_inliers = initial_inliers;
  result.final_inliers = final_inliers;
  result.matches = std::move(guided_matches);
  result.geometry = std::move(final_geometry);
  result.valid = true;
  return true;
}

bool WriteVerifiedSpatialPair(aether_sfm_session* s,
                              int frame_idx1,
                              int frame_idx2,
                              bool quadratic,
                              SpatialPairCache* cache) {
  if (!s || !s->db || !cache || frame_idx1 == frame_idx2) return false;
  const int later = std::max(frame_idx1, frame_idx2);
  const int earlier = std::min(frame_idx1, frame_idx2);
  const auto it = cache->find(FramePairKey(later, earlier));
  if (it == cache->end() || !it->second.valid) return false;
  VerifiedSpatialPair& result = it->second;
  if (result.existing || result.written) return true;

  const FrameRecord& a = s->frames[earlier];
  const FrameRecord& b = s->frames[later];
  if (s->db->ExistsMatches(a.image_id, b.image_id) ||
      s->db->ExistsTwoViewGeometry(a.image_id, b.image_id)) {
    return false;
  }
  s->db->WriteMatches(a.image_id, b.image_id, result.matches);
  s->db->WriteTwoViewGeometry(a.image_id, b.image_id, result.geometry);
  result.written = true;
  ++s->stat_spatial_pairs_written;
  s->stat_spatial_inliers += result.final_inliers;
  if (quadratic) ++s->stat_spatial_quadratic_written;
  return true;
}

std::vector<SpatialRevisitCandidate> SelectDiverseAnchors(
    std::vector<SpatialRevisitCandidate> pool, int temporal_k) {
  std::vector<SpatialRevisitCandidate> selected;
  selected.reserve(kSpatialAnchorsPerFrame);
  const int min_separation = std::max(3, temporal_k / 3);
  for (const SpatialRevisitCandidate& candidate : pool) {
    bool separated = true;
    for (const SpatialRevisitCandidate& prior : selected) {
      if (std::abs(candidate.j - prior.j) < min_separation) {
        separated = false;
        break;
      }
    }
    if (separated) selected.push_back(candidate);
    if (static_cast<int>(selected.size()) == kSpatialAnchorsPerFrame) break;
  }
  for (const SpatialRevisitCandidate& candidate : pool) {
    if (static_cast<int>(selected.size()) == kSpatialAnchorsPerFrame) break;
    const bool duplicate = std::any_of(
        selected.begin(), selected.end(), [&](const SpatialRevisitCandidate& x) {
          return x.i == candidate.i && x.j == candidate.j;
        });
    if (!duplicate) selected.push_back(candidate);
  }
  for (int rank = 0; rank < static_cast<int>(selected.size()); ++rank) {
    selected[rank].anchor_rank = rank;
  }
  return selected;
}

std::vector<SpatialRevisitCandidate> BuildSpatialAnchors(
    aether_sfm_session* s, int temporal_k) {
  constexpr double kPrimaryDistanceMeters = 1.0;
  constexpr double kFallbackDistanceMeters = 1.5;
  constexpr double kPrimaryAngleRadians = 45.0 * M_PI / 180.0;
  constexpr double kFallbackAngleRadians = 60.0 * M_PI / 180.0;
  const double primary_min_dot = std::cos(kPrimaryAngleRadians);
  const double fallback_min_dot = std::cos(kFallbackAngleRadians);
  std::vector<SpatialRevisitCandidate> anchors;

  for (int i = 0; i < static_cast<int>(s->frames.size()); ++i) {
    const FrameRecord& current = s->frames[i];
    if (!current.has_pose) continue;
    const Eigen::Vector3d center = current.cam_from_world.TgtOriginInSrc();
    const Eigen::Vector3d forward = CameraForwardWorld(current.cam_from_world);
    std::vector<SpatialRevisitCandidate> primary;
    std::vector<SpatialRevisitCandidate> fallback;
    for (int j = 0; j + temporal_k < i; ++j) {
      const FrameRecord& previous = s->frames[j];
      if (!previous.has_pose) continue;
      const double distance =
          (center - previous.cam_from_world.TgtOriginInSrc()).norm();
      if (distance > kFallbackDistanceMeters) continue;
      const double dot = std::max(
          -1.0, std::min(1.0, forward.dot(CameraForwardWorld(previous.cam_from_world))));
      if (dot < fallback_min_dot) continue;
      const double angle = std::acos(dot);
      SpatialRevisitCandidate candidate;
      candidate.i = i;
      candidate.j = j;
      candidate.distance_m = distance;
      candidate.angle_rad = angle;
      if (distance <= kPrimaryDistanceMeters && dot >= primary_min_dot) {
        candidate.score = distance / kPrimaryDistanceMeters +
                          angle / kPrimaryAngleRadians;
        primary.push_back(candidate);
      } else {
        candidate.score = 2.0 + distance / kFallbackDistanceMeters +
                          angle / kFallbackAngleRadians;
        fallback.push_back(candidate);
      }
    }
    const auto quality_order = [](const SpatialRevisitCandidate& a,
                                  const SpatialRevisitCandidate& b) {
      if (a.score != b.score) return a.score < b.score;
      return std::abs(a.i - a.j) > std::abs(b.i - b.j);
    };
    std::sort(primary.begin(), primary.end(), quality_order);
    std::sort(fallback.begin(), fallback.end(), quality_order);
    std::vector<SpatialRevisitCandidate> pool;
    pool.reserve(kSpatialCandidatePool);
    for (const SpatialRevisitCandidate& candidate : primary) {
      if (static_cast<int>(pool.size()) == kSpatialCandidatePool) break;
      pool.push_back(candidate);
    }
    for (const SpatialRevisitCandidate& candidate : fallback) {
      if (static_cast<int>(pool.size()) == kSpatialCandidatePool) break;
      pool.push_back(candidate);
    }
    s->stat_spatial_pairs_considered += pool.size();
    std::vector<SpatialRevisitCandidate> selected =
        SelectDiverseAnchors(std::move(pool), temporal_k);
    anchors.insert(anchors.end(), selected.begin(), selected.end());
  }
  return anchors;
}

std::vector<SpatialRevisitCandidate> BuildQuadraticAnchors(
    const aether_sfm_session* s, int temporal_k) {
  std::vector<SpatialRevisitCandidate> anchors;
  for (int i = 0; i < static_cast<int>(s->frames.size()); ++i) {
    int rank = 0;
    for (int offset = 1; offset <= i; offset *= 2) {
      if (offset > temporal_k) {
        SpatialRevisitCandidate candidate;
        candidate.i = i;
        candidate.j = i - offset;
        candidate.score = static_cast<double>(rank);
        candidate.anchor_rank = rank;
        candidate.quadratic = true;
        anchors.push_back(candidate);
        if (++rank == kSpatialAnchorsPerFrame) break;
      }
      if (offset > i / 2) break;
    }
  }
  return anchors;
}

int ProcessRevisitAnchors(aether_sfm_session* s,
                          std::vector<SpatialRevisitCandidate> anchors,
                          bool quadratic,
                          int anchor_attempt_limit,
                          SpatialPairCache* cache,
                          int* attempted_total) {
  std::sort(anchors.begin(), anchors.end(),
            [](const SpatialRevisitCandidate& a,
               const SpatialRevisitCandidate& b) {
              // Rank-first scheduling gives every frame its best candidate
              // before any frame consumes candidate two or three. Quality then
              // decides globally, so a chronological early return cannot starve
              // the tail of a long capture.
              if (a.anchor_rank != b.anchor_rank) {
                return a.anchor_rank < b.anchor_rank;
              }
              if (a.score != b.score) return a.score < b.score;
              if (a.i != b.i) return a.i < b.i;
              return a.j < b.j;
            });

  std::vector<SpatialRevisitCandidate> successful;
  size_t anchor_index = 0;
  for (; anchor_index < anchors.size(); ++anchor_index) {
    if (*attempted_total >= anchor_attempt_limit) break;
    const SpatialPairPurpose purpose =
        quadratic ? SpatialPairPurpose::kQuadraticAnchor
                  : SpatialPairPurpose::kAnchor;
    if (VerifySpatialPair(s, anchors[anchor_index].i, anchors[anchor_index].j,
                          purpose, cache, attempted_total)) {
      ++s->stat_spatial_anchor_passed;
      successful.push_back(anchors[anchor_index]);
    }
  }
  if (anchor_index < anchors.size()) {
    s->stat_spatial_budget_skipped += anchors.size() - anchor_index;
  }

  std::sort(successful.begin(), successful.end(),
            [&](const SpatialRevisitCandidate& a,
                const SpatialRevisitCandidate& b) {
              const int a_inliers = cache->at(FramePairKey(a.i, a.j)).final_inliers;
              const int b_inliers = cache->at(FramePairKey(b.i, b.j)).final_inliers;
              if (a_inliers != b_inliers) return a_inliers > b_inliers;
              return a.score < b.score;
            });

  // Non-max suppression avoids proving and expanding the same physical revisit
  // dozens of times when adjacent frames all selected the same loop closure.
  std::vector<SpatialRevisitCandidate> seeds;
  for (const SpatialRevisitCandidate& candidate : successful) {
    const bool overlaps = std::any_of(
        seeds.begin(), seeds.end(), [&](const SpatialRevisitCandidate& seed) {
          return std::abs(candidate.i - seed.i) <= 4 &&
                 std::abs(candidate.j - seed.j) <= 4;
        });
    if (!overlaps) seeds.push_back(candidate);
  }

  int confirmed_regions = 0;
  for (const SpatialRevisitCandidate& seed : seeds) {
    int available = 0;
    int passed = 0;
    std::vector<std::pair<int, int>> support_pairs;
    for (int delta = -1; delta <= 1; ++delta) {
      const int i = seed.i + delta;
      const int j = seed.j + delta;
      if (i < 0 || j < 0 || i >= static_cast<int>(s->frames.size()) ||
          j >= static_cast<int>(s->frames.size()) || i == j) {
        continue;
      }
      ++available;
      const SpatialPairPurpose purpose =
          quadratic ? SpatialPairPurpose::kQuadraticConfirm
                    : SpatialPairPurpose::kConfirm;
      if (VerifySpatialPair(s, i, j, purpose, cache, attempted_total)) {
        ++passed;
        support_pairs.emplace_back(i, j);
      }
    }
    if (available < 2 || passed < 2) continue;

    ++confirmed_regions;
    ++s->stat_spatial_regions_confirmed;
    for (const auto& pair : support_pairs) {
      WriteVerifiedSpatialPair(s, pair.first, pair.second, quadratic, cache);
    }

    // A proven anchor seeds the complete local covisibility neighborhood. Each
    // expanded pair still has to independently pass raw TVG, guided matching,
    // >=20 inliers, and >=10% initial inlier ratio before it reaches sqlite.
    for (int di = -2; di <= 2; ++di) {
      for (int dj = -2; dj <= 2; ++dj) {
        const int i = seed.i + di;
        const int j = seed.j + dj;
        if (i < 0 || j < 0 || i >= static_cast<int>(s->frames.size()) ||
            j >= static_cast<int>(s->frames.size()) || i == j) {
          continue;
        }
        const SpatialPairPurpose purpose =
            quadratic ? SpatialPairPurpose::kQuadraticExpansion
                      : SpatialPairPurpose::kExpansion;
        if (VerifySpatialPair(s, i, j, purpose, cache, attempted_total)) {
          WriteVerifiedSpatialPair(s, i, j, quadratic, cache);
        }
      }
    }
  }
  return confirmed_regions;
}

void AddSpatialRevisitMatches(aether_sfm_session* s) {
  if (!s || !s->db || s->frames.size() < 3 || s->camera_id == 0) return;
  const int temporal_k = s->options.k_neighbors > 0 ? s->options.k_neighbors : 12;
  SpatialPairCache cache;
  cache.reserve(kSpatialMaxTotalPairs * 2);
  int attempted_total = 0;

  const std::vector<SpatialRevisitCandidate> spatial_anchors =
      BuildSpatialAnchors(s, temporal_k);
  const int spatial_regions = ProcessRevisitAnchors(
      s, spatial_anchors, false,
      std::min(kSpatialInitialAnchorBudget, kSpatialMaxTotalPairs), &cache,
      &attempted_total);

  // COLMAP-style quadratic overlap is a sparse safety net, not parallel blind
  // work: only use powers-of-two temporal gaps when ARKit produced no confirmed
  // multi-frame revisit region at all.
  if (spatial_regions == 0 && attempted_total < kSpatialMaxTotalPairs) {
    const std::vector<SpatialRevisitCandidate> quadratic_anchors =
        BuildQuadraticAnchors(s, temporal_k);
    ProcessRevisitAnchors(s, quadratic_anchors, true, kSpatialMaxTotalPairs,
                          &cache, &attempted_total);
  }
}

// Rebuild the dense, locally stable detail layer after the global camera solve.
// Spatial/guided pairs have already done their job by constraining loop closure;
// this pass consumes only the original temporal K-neighbor TVG inliers. Camera
// poses and intrinsics stay fixed: the pass may create points or add a clean
// observation, but never merges existing points and never runs another BA.
// Processing larger temporal gaps first gives each new point the strongest
// available baseline inside K before adjacent frames try to grow its track.
void RestoreTemporalDetail(aether_sfm_session* s,
                           colmap::Reconstruction* reconstruction) {
  if (!s || !reconstruction || s->frames.size() < 2) return;

  constexpr double kMinTriAngleRad = 0.05235987755982988;  // 3 degrees
  // 39-capture replay: 4 px kept one 2.8x-q99 ray; 3 px retained ~62.7k
  // delivered points while reducing all added points below 1.18x-q99.
  constexpr double kMaxReprojPx = 3.0;
  const int temporal_k =
      std::max(1, s->options.k_neighbors > 0 ? s->options.k_neighbors : 12);
  const int num_frames = static_cast<int>(s->frames.size());
  auto db = colmap::Database::Open(s->db_path);

  const auto reprojects_cleanly = [&](const colmap::Image& image,
                                      const colmap::Camera& camera,
                                      colmap::point2D_t point2D_idx,
                                      const Eigen::Vector3d& xyz) {
    const Eigen::Vector3d x_cam = image.CamFromWorld() * xyz;
    if (x_cam.z() <= 0.0) return false;
    const std::optional<Eigen::Vector2d> projected = camera.ImgFromCam(x_cam);
    return projected &&
           (*projected - image.Point2D(point2D_idx).xy).norm() <=
               kMaxReprojPx;
  };

  const auto has_image_in_track = [](const colmap::Track& track,
                                     colmap::image_t image_id) {
    return std::any_of(track.Elements().begin(), track.Elements().end(),
                       [image_id](const colmap::TrackElement& element) {
                         return element.image_id == image_id;
                       });
  };

  const auto has_stable_baseline = [&](const colmap::Track& track,
                                       const colmap::Image& candidate,
                                       const Eigen::Vector3d& xyz) {
    const Eigen::Vector3d candidate_center =
        candidate.CamFromWorld().TgtOriginInSrc();
    for (const colmap::TrackElement& element : track.Elements()) {
      if (!reconstruction->ExistsImage(element.image_id)) continue;
      const colmap::Image& observed = reconstruction->Image(element.image_id);
      if (!observed.HasPose()) continue;
      if (colmap::CalculateTriangulationAngle(
              candidate_center, observed.CamFromWorld().TgtOriginInSrc(), xyz) >=
          kMinTriAngleRad) {
        return true;
      }
    }
    return false;
  };

  for (int gap = std::min(temporal_k, num_frames - 1); gap >= 1; --gap) {
    for (int right = gap; right < num_frames; ++right) {
      const FrameRecord& frame1 = s->frames[right - gap];
      const FrameRecord& frame2 = s->frames[right];
      if (!reconstruction->ExistsImage(frame1.image_id) ||
          !reconstruction->ExistsImage(frame2.image_id)) {
        continue;
      }
      colmap::Image& image1 = reconstruction->Image(frame1.image_id);
      colmap::Image& image2 = reconstruction->Image(frame2.image_id);
      if (!image1.HasPose() || !image2.HasPose() ||
          !db->ExistsTwoViewGeometry(frame1.image_id, frame2.image_id)) {
        continue;
      }

      const colmap::TwoViewGeometry geometry =
          db->ReadTwoViewGeometry(frame1.image_id, frame2.image_id);
      if (geometry.inlier_matches.empty()) continue;
      ++s->stat_temporal_detail_pairs;
      s->stat_temporal_detail_matches += geometry.inlier_matches.size();

      const colmap::Camera& camera1 =
          reconstruction->Camera(image1.CameraId());
      const colmap::Camera& camera2 =
          reconstruction->Camera(image2.CameraId());
      for (const colmap::FeatureMatch& match : geometry.inlier_matches) {
        if (match.point2D_idx1 >= image1.NumPoints2D() ||
            match.point2D_idx2 >= image2.NumPoints2D()) {
          ++s->stat_temporal_detail_conflicts;
          continue;
        }

        const colmap::Point2D& point1 =
            image1.Point2D(match.point2D_idx1);
        const colmap::Point2D& point2 =
            image2.Point2D(match.point2D_idx2);
        const bool has1 = point1.HasPoint3D();
        const bool has2 = point2.HasPoint3D();

        if (has1 && has2) {
          if (point1.point3D_id != point2.point3D_id) {
            ++s->stat_temporal_detail_conflicts;
          }
          continue;
        }

        if (has1 || has2) {
          const colmap::point3D_t point3D_id =
              has1 ? point1.point3D_id : point2.point3D_id;
          const colmap::image_t grow_image_id =
              has1 ? frame2.image_id : frame1.image_id;
          const colmap::point2D_t grow_point2D_idx =
              has1 ? match.point2D_idx2 : match.point2D_idx1;
          colmap::Image& grow_image = has1 ? image2 : image1;
          const colmap::Camera& grow_camera = has1 ? camera2 : camera1;
          const colmap::Point3D& point3D =
              reconstruction->Point3D(point3D_id);
          if (has_image_in_track(point3D.track, grow_image_id)) {
            ++s->stat_temporal_detail_conflicts;
            continue;
          }
          const Eigen::Vector3d x_cam =
              grow_image.CamFromWorld() * point3D.xyz;
          if (x_cam.z() <= 0.0) {
            ++s->stat_temporal_detail_reject_cheirality;
            continue;
          }
          if (!reprojects_cleanly(grow_image, grow_camera,
                                  grow_point2D_idx, point3D.xyz)) {
            ++s->stat_temporal_detail_reject_reproj;
            continue;
          }
          if (!has_stable_baseline(point3D.track, grow_image, point3D.xyz)) {
            ++s->stat_temporal_detail_reject_tri_angle;
            continue;
          }
          reconstruction->AddObservation(
              point3D_id,
              colmap::TrackElement(grow_image_id, grow_point2D_idx));
          ++s->stat_temporal_detail_grown;
          continue;
        }

        const std::optional<Eigen::Vector2d> cam_point1 =
            camera1.CamFromImg(point1.xy);
        const std::optional<Eigen::Vector2d> cam_point2 =
            camera2.CamFromImg(point2.xy);
        if (!cam_point1 || !cam_point2) {
          ++s->stat_temporal_detail_reject_reproj;
          continue;
        }
        Eigen::Vector3d xyz;
        if (!colmap::TriangulatePoint(image1.CamFromWorld().ToMatrix(),
                                     image2.CamFromWorld().ToMatrix(),
                                     *cam_point1, *cam_point2, &xyz)) {
          ++s->stat_temporal_detail_reject_tri_angle;
          continue;
        }
        const Eigen::Vector3d x_cam1 = image1.CamFromWorld() * xyz;
        const Eigen::Vector3d x_cam2 = image2.CamFromWorld() * xyz;
        if (x_cam1.z() <= 0.0 || x_cam2.z() <= 0.0) {
          ++s->stat_temporal_detail_reject_cheirality;
          continue;
        }
        if (colmap::CalculateTriangulationAngle(
                image1.CamFromWorld().TgtOriginInSrc(),
                image2.CamFromWorld().TgtOriginInSrc(), xyz) <
            kMinTriAngleRad) {
          ++s->stat_temporal_detail_reject_tri_angle;
          continue;
        }
        if (!reprojects_cleanly(image1, camera1, match.point2D_idx1, xyz) ||
            !reprojects_cleanly(image2, camera2, match.point2D_idx2, xyz)) {
          ++s->stat_temporal_detail_reject_reproj;
          continue;
        }

        colmap::Track track;
        track.AddElement(frame1.image_id, match.point2D_idx1);
        track.AddElement(frame2.image_id, match.point2D_idx2);
        reconstruction->AddPoint3D(xyz, std::move(track),
                                   Eigen::Vector3ub::Zero());
        ++s->stat_temporal_detail_created;
      }
    }
  }
  db->Close();
}

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
    pipeline_opts->image_path = image_path;  // [4.0.4] image_path moved into options
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

// Async-finalize worker: deep-copy the local-only reconstruction, run global bundle
// adjustment via the pipeline's PUBLIC RefineReconstruction() (iterative global
// refinement + FilterFrames + UpdatePoint3DErrors — NO per-image re-triangulation;
// TriangulateReconstruction() would add that and is a separate A/B), then atomically
// swap the refined model into the session. Runs off the UI thread so the caller
// already has the instant local result. db_path must be readable (the session closed
// its handle before spawning this).
void RefineGlobalBA(aether_sfm_session* s,
                    std::shared_ptr<const colmap::Reconstruction> local) {
  try {
    const double t0 = NowMs();
    auto refined = std::make_shared<colmap::Reconstruction>(*local);
    auto popts = std::make_shared<colmap::IncrementalPipelineOptions>();
    popts->min_num_matches = 15;
    popts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
    // [2026-07-10] COMPLETE the phase-2 Cauchy config. This block previously set only
    // min_num_matches + residuals, so ba_global_loss_type defaulted to 0 (TRIVIAL) —
    // phase 2 was NOT the full Cauchy it was described as. Set the SAME validated global
    // config the synchronous RunPipeline uses (aether_sfm_c.cc:1200-1202): Cauchy@1.0,
    // gftol 1e-6, gref5/giter50 (defaults, set explicit so they hit the log).
    // RefineReconstruction (below) runs iterative global refinement, which reads
    // ba_global_* for its loss. NOTE: this changes ONLY the loss config; the
    // RefineReconstruction-vs-TriangulateReconstruction choice is a SEPARATE algorithmic
    // decision, intentionally left unchanged here for a controlled A/B.
    popts->ba_global_loss_type = 2;              // CAUCHY (was defaulting to 0=TRIVIAL)
    popts->ba_global_loss_scale = 1.0;
    popts->ba_global_function_tolerance = 1e-6;  // converge-stop
    popts->ba_global_max_refinements = 5;
    popts->ba_global_max_num_iterations = 50;
    auto manager = std::make_shared<colmap::ReconstructionManager>();
    popts->image_path = s->image_path;  // [4.0.4] image_path moved into options
    colmap::IncrementalPipeline pipeline(
        popts, colmap::Database::Open(s->db_path), manager);
    pipeline.RefineReconstruction(refined);
    RestoreTemporalDetail(s, refined.get());
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
  out->use_gpu_extract = 0;  // CPU DSP-SIFT by default; iOS shim flips to 1
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
    // Streaming callers pass a capture-owned db path (`sfm_live.db`). Keep it
    // after free so detached/background finalize or the launch-time recovery
    // sweep can retry if the app is killed mid-solve.
    s->owns_db_file = false;
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
  // pose_qwxyz/pose_t = ARKit CamFromWorld (world->camera), quaternion [w,x,y,z],
  // ARKit camera axes (+X right, +Y up, -Z forward). Consumed below to build the
  // throwaway live-preview cloud only; the authoritative finalize still self-
  // estimates CamFromWorld (this prior does NOT feed the v1 solve).
  try {
    const int max_features =
        s->options.max_features > 0 ? s->options.max_features : 2048;

    // 1) DSP-SIFT extraction. use_gpu_extract routes to the GPU DSP-SIFT
    //    (Dawn/WGSL, f16 on A16) which is output-equivalent (xy/128-d/UBC/
    //    RootSIFT) and falls back to the CPU _threaded path IN-ABI on any GPU
    //    failure — so this call site is unaware which path ran. Default = CPU.
    std::vector<float> xy(static_cast<size_t>(max_features) * 2);
    std::vector<uint8_t> desc(static_cast<size_t>(max_features) * 128);
    int n = 0;
    const bool gpu_avail =
        s->options.use_gpu_extract && (aether_dsp_sift_extract_gpu != nullptr);
    const double t_extract0 = NowMs();
    const int erc =
        gpu_avail
            ? aether_dsp_sift_extract_gpu(gray, width, height, max_features,
                                          /*num_threads=*/0, xy.data(),
                                          desc.data(), max_features, &n)
            : aether_dsp_sift_extract(gray, width, height, max_features,
                                      xy.data(), desc.data(), max_features, &n);
    const double extract_ms = NowMs() - t_extract0;
    if (erc != 0 || n <= 0) {
      // Record the (possibly large) extract time even on failure so the log
      // reflects a stalled/fallback extractor; zero the match-side counters.
      s->last_extract_ms = extract_ms;
      s->last_match_ms = 0.0;
      s->last_n_cand = s->last_gpu_matches = s->last_cpu_matches = 0;
      return AETHER_SFM_ERR_EXTRACT;
    }

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
      // Keep the camera on the session (with its db id) for the per-pair
      // two-view geometry estimation below.
      camera.camera_id = s->camera_id;
      s->camera = camera;
      // Seed the live Reconstruction's shared camera + its trivial rig once.
      // Rig id == camera id, required before AddImageWithTrivialFrame.
      s->live_recon.AddCameraWithTrivialRig(s->camera);
      s->live_recon_ready = true;
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
    rec.points = colmap::FeatureKeypointsToPointsVector(kps);

    // Build this frame's CamFromWorld in COLMAP convention (see header derivation):
    //   X_colmapcam = C*(R_w2c*X_world + t_w2c),  C = diag(1,-1,-1) (180° about +X).
    // Used ONLY by the throwaway live-preview triangulation below.
    if (pose_qwxyz && pose_t) {
      const Eigen::Quaterniond q_w2c(pose_qwxyz[0], pose_qwxyz[1],
                                     pose_qwxyz[2], pose_qwxyz[3]);  // [w,x,y,z]
      const Eigen::Matrix3d R_w2c = q_w2c.normalized().toRotationMatrix();
      const Eigen::Vector3d t_w2c(pose_t[0], pose_t[1], pose_t[2]);
      Eigen::Matrix3d C = Eigen::Matrix3d::Identity();
      C(1, 1) = -1.0;
      C(2, 2) = -1.0;
      rec.cam_from_world = colmap::Rigid3d(
          Eigen::Quaterniond(Eigen::Matrix3d(C * R_w2c)), C * t_w2c);
      rec.has_pose = true;
    }

    // Register this frame into the live Reconstruction with its ARKit pose.
    // Trivial rig/frame (frame_id == image_id); the 2-arg overload sets the
    // pose AND RegisterFrame()s it in one call.
    if (rec.has_pose && s->live_recon_ready) {
      colmap::Image rimg;
      rimg.SetImageId(image_id);
      rimg.SetName(name);
      rimg.SetCameraId(s->camera_id);
      rimg.SetPoints2D(rec.points);  // kp order == point2D_idx
      s->live_recon.AddImageWithTrivialFrame(std::move(rimg), rec.cam_from_world);
      s->reg_order.push_back(image_id);
    }

    // 4) Match against the previous k_neighbors frames (CPU brute-force,
    //    MUTUALLY cross-checked inside aether_sift_match_pairs) and PERSIST
    //    the correspondences — the exact sequence colmap's own matching
    //    pipeline uses (feature_matching.cc): WriteMatches with the raw
    //    cross-checked pairs, EstimateTwoViewGeometry (E/F/H RANSAC at
    //    colmap defaults) over the same pairs, WriteTwoViewGeometry with the
    //    verified inliers. finalize()'s IncrementalPipeline consumes the
    //    two_view_geometries table as-is (min_num_matches=15 filters weak
    //    pairs there). This closes the formerly-documented streaming gap
    //    ("matcher returns count only") that left the matches table empty
    //    and made every finalize return ERR_NOT_REGISTERED.
    const int k = s->options.k_neighbors > 0 ? s->options.k_neighbors : 6;
    const int start = (frame_id - k) > 0 ? (frame_id - k) : 0;
    const double ratio = s->options.match_max_ratio > 0
                             ? s->options.match_max_ratio
                             : 0.7;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    const double t_match0 = NowMs();
    int n_cand = 0, gpu_matches = 0, cpu_matches = 0;
    std::vector<uint32_t> pair_buf;
    // Live-preview triangulation scratch. Triangulate each NEW-frame keypoint at
    // most once per add_frame (cheap dedup: a keypoint matched across several
    // prev frames would otherwise emit several near-duplicate 3D points).
    // Points created or grown in the live Reconstruction this frame → the
    // variable set for the windowed local BA below.
    std::unordered_set<colmap::point3D_t> touched;
    constexpr double kMinTriAngleRad = 0.05235987755982988;  // 3.0 deg parallax
    constexpr double kMaxCreateReprojPx = 10.0;  // strict new-point gate
    constexpr double kMaxGrowReprojPx = 14.0;    // TVG-inlier grow absorbs ARKit drift
    constexpr double kMaxMergeReprojPx = 8.0;    // stricter: irreversible track merge
    const bool gpu_match_avail =
        s->options.use_gpu_match && (aether_gpu_match_gemm_pairs != nullptr);
    std::unordered_set<PointIdPair, PointIdPairHash> merge_trials;
    for (int j = start; j < frame_id; ++j) {
      const FrameRecord& prev = s->frames[j];
      ++n_cand;
      // Cross-checked matches are unique per left index → min(n1,n2) bounds.
      const int cap = prev.n_keypoints < rec.n_keypoints ? prev.n_keypoints
                                                         : rec.n_keypoints;
      pair_buf.resize(static_cast<size_t>(cap) * 2);
      int num_matches = 0;
      // GPU tiled-GEMM first when enabled+linked (mutual cross-check inside).
      // On device, a Metal failure used to fall back to the CPU brute-force
      // matcher and could stall the streaming queue for minutes. If the GPU
      // symbol is present but this pair fails, skip the pair; CPU remains the
      // host/no-Metal fallback when the weak GPU symbol is absent.
      int mrc = 1;
      bool used_gpu = false;
      if (gpu_match_avail) {
        mrc = aether_gpu_match_gemm_pairs(
            prev.descriptors.data(), prev.n_keypoints, rec.descriptors.data(),
            rec.n_keypoints, ratio, pair_buf.data(), cap, &num_matches);
        if (mrc != 0) continue;
        used_gpu = true;
      } else {
        mrc = aether_sift_match_pairs(
            prev.descriptors.data(), prev.n_keypoints, rec.descriptors.data(),
            rec.n_keypoints, ratio, pair_buf.data(), cap, &num_matches);
      }
      if (mrc != 0 || num_matches <= 0) continue;
      if (used_gpu) gpu_matches += num_matches; else cpu_matches += num_matches;

      colmap::FeatureMatches matches(num_matches);
      for (int m = 0; m < num_matches; ++m) {
        matches[m].point2D_idx1 = pair_buf[2 * m];
        matches[m].point2D_idx2 = pair_buf[2 * m + 1];
      }
      s->db->WriteMatches(prev.image_id, image_id, matches);

      colmap::TwoViewGeometry two_view_geometry =
          colmap::EstimateTwoViewGeometry(s->camera, prev.points, s->camera,
                                          rec.points, std::move(matches),
                                          tvg_options);
      s->db->WriteTwoViewGeometry(prev.image_id, image_id, two_view_geometry);

      // ── Incremental track growth into the live Reconstruction ──
      // Consult the RECON's Point2D->Point3D links (the single source of truth)
      // for track membership: create a new 2-view point or grow an existing
      // track by one observation. Querying the recon directly — not a side map —
      // means the per-frame floater filter below can freely DeletePoint3D /
      // DeleteObservation (which reset those links) with NO dangling-id
      // bookkeeping. The windowed BA after the loop refines these poses+points.
      //
      // Seed tracks from the GEOMETRICALLY-VERIFIED matches — the TwoViewGeometry
      // RANSAC (E/F/H) inliers, not the raw cross-checked pairs. A raw pair that
      // survives cross-check + Lowe ratio can still be geometrically inconsistent
      // (repetitive texture, specular highlights) → it seeds a floater the
      // creation gates don't always catch (the halo of scattered points around
      // the surface). Inliers remove those at the source. Fall back to raw pairs
      // only when the TVG was degenerate (empty inliers) so a hard two-view case
      // still contributes rather than vanishing.
      if (rec.has_pose && prev.has_pose && s->live_recon_ready) {
        const Eigen::Matrix3x4d P_prev = prev.cam_from_world.ToMatrix();
        const Eigen::Matrix3x4d P_cur = rec.cam_from_world.ToMatrix();
        const Eigen::Vector3d c_prev = prev.cam_from_world.TgtOriginInSrc();
        const Eigen::Vector3d c_cur = rec.cam_from_world.TgtOriginInSrc();
        const colmap::FeatureMatches& inliers = two_view_geometry.inlier_matches;
        const bool use_inliers = !inliers.empty();
        const int grow_n =
            use_inliers ? static_cast<int>(inliers.size()) : num_matches;
        if (use_inliers) s->stat_tvg_inlier_pairs += grow_n;
        else s->stat_raw_pairs += grow_n;
        for (int mm = 0; mm < grow_n; ++mm) {
          const uint32_t i1 = use_inliers ? inliers[mm].point2D_idx1
                                          : pair_buf[2 * mm];      // prev kp index
          const uint32_t i2 = use_inliers ? inliers[mm].point2D_idx2
                                          : pair_buf[2 * mm + 1];  // cur kp index
          if (i1 >= prev.points.size() || i2 >= rec.points.size()) continue;
          const colmap::Point2D& o1 = s->live_recon.Image(prev.image_id).Point2D(i1);
          const colmap::Point2D& o2 = s->live_recon.Image(image_id).Point2D(i2);
          const bool has1 = o1.HasPoint3D();
          const bool has2 = o2.HasPoint3D();

          // Both assigned: same track = nothing; different tracks = try a
          // conservative live MergePoints3D. This directly attacks duplicate
          // fragmented tracks without a finish-time global BA. Only TVG
          // inliers are allowed to merge; raw fallback pairs still just log the
          // signal so they cannot glue unrelated texture repeats together.
          if (has1 && has2) {
            if (o1.point3D_id == o2.point3D_id) ++s->stat_already_assigned;
            else {
              ++s->stat_merge_needed;
              if (!use_inliers) continue;
              const PointIdPair key =
                  CanonicalPointPair(o1.point3D_id, o2.point3D_id);
              if (!merge_trials.insert(key).second) continue;
              if (CanMergeLivePoints(s->live_recon, s->camera, key.a, key.b,
                                     kMaxMergeReprojPx)) {
                const colmap::point3D_t merged =
                    s->live_recon.MergePoints3D(key.a, key.b);
                touched.erase(key.a);
                touched.erase(key.b);
                touched.insert(merged);
                ++s->stat_merge_accepted;
              } else {
                ++s->stat_merge_rejected;
              }
            }
            continue;
          }

          // One side assigned: grow that Point3D by the unassigned observation.
          // GATE the growth the same way creation is gated: the new observation
          // must be in front of the growing camera AND reproject near the
          // existing point. An UNGATED AddObservation lets a geometrically-wrong
          // match (one that survived cross-check + Lowe ratio but is still a
          // mismatch) attach a foreign-surface observation to a good point —
          // geometry barely moves (the point isn't re-triangulated) but the
          // track-based colorizer averages that stray pixel in → color bleed (a
          // red object's pixel pulled into a brown floor point). Rejecting it
          // fixes the color with no point-count loss (the keypoint stays free to
          // seed its own point).
          if (has1 || has2) {
            const colmap::point3D_t pid = has1 ? o1.point3D_id : o2.point3D_id;
            const colmap::image_t gimg = has1 ? image_id : prev.image_id;
            const colmap::point2D_t gidx = has1 ? i2 : i1;
            const colmap::Rigid3d& gcfw =
                has1 ? rec.cam_from_world : prev.cam_from_world;
            const Eigen::Vector2d& gkp = has1 ? rec.points[i2] : prev.points[i1];
            const Eigen::Vector3d Xg = gcfw * s->live_recon.Point3D(pid).xyz;
            if (Xg.z() <= 0.0) {
              ++s->stat_grow_rejected;
              ++s->stat_grow_reject_cheirality;
              continue;
            }
            const std::optional<Eigen::Vector2d> pg = s->camera.ImgFromCam(Xg);
            const double grow_gate = use_inliers ? kMaxGrowReprojPx
                                                 : kMaxCreateReprojPx;
            if (!pg || (*pg - gkp).norm() > grow_gate) {
              ++s->stat_grow_rejected;
              ++s->stat_grow_reject_reproj;
              continue;
            }
            s->live_recon.AddObservation(pid, colmap::TrackElement(gimg, gidx));
            touched.insert(pid);
            ++s->stat_grow_accepted;
            continue;
          }

          // Neither assigned: brand-new 2-view track. Triangulate + gate.
          const std::optional<Eigen::Vector2d> nn1 = s->camera.CamFromImg(prev.points[i1]);
          const std::optional<Eigen::Vector2d> nn2 = s->camera.CamFromImg(rec.points[i2]);
          if (!nn1 || !nn2) {
            ++s->stat_create_reject_reproj;
            continue;
          }
          Eigen::Vector3d X_world;
          if (!colmap::TriangulatePoint(P_prev, P_cur, *nn1, *nn2, &X_world)) {
            ++s->stat_create_reject_tri_angle;
            continue;
          }
          const Eigen::Vector3d X_prev = prev.cam_from_world * X_world;
          const Eigen::Vector3d X_cur = rec.cam_from_world * X_world;
          if (X_prev.z() <= 0.0 || X_cur.z() <= 0.0) {
            ++s->stat_create_reject_cheirality;
            continue;
          }
          if (colmap::CalculateTriangulationAngle(c_prev, c_cur, X_world) <
              kMinTriAngleRad) {
            ++s->stat_create_reject_tri_angle;
            continue;
          }
          const std::optional<Eigen::Vector2d> rr1 = s->camera.ImgFromCam(X_prev);
          const std::optional<Eigen::Vector2d> rr2 = s->camera.ImgFromCam(X_cur);
          if (!rr1 || !rr2) {
            ++s->stat_create_reject_reproj;
            continue;
          }
          if ((*rr1 - prev.points[i1]).norm() > kMaxCreateReprojPx ||
              (*rr2 - rec.points[i2]).norm() > kMaxCreateReprojPx) {
            ++s->stat_create_reject_reproj;
            continue;
          }

          colmap::Track track;
          track.AddElement(prev.image_id, i1);
          track.AddElement(image_id, i2);
          const colmap::point3D_t pid =
              s->live_recon.AddPoint3D(X_world, std::move(track), Eigen::Vector3ub::Zero());
          touched.insert(pid);
        }
      }
    }

    // ── Windowed local bundle adjustment (Cauchy) over the last W frames ──
    // Refines the window's poses+points each frame. Older structure is held
    // constant automatically (a Point3D whose track extends beyond the window is
    // fixed → anchors the window, bounds drift). Bounded ceres iters keep it in
    // the ~2s/frame budget.
    if (rec.has_pose && s->live_recon_ready && s->live_recon.NumRegImages() >= 3 &&
        (frame_id % (s->ba_every_n > 0 ? s->ba_every_n : 1)) == 0) {
      const int W = s->ba_window > 0 ? s->ba_window : 12;
      const int n_reg = static_cast<int>(s->reg_order.size());
      const int w0 = n_reg > W ? n_reg - W : 0;

      colmap::BundleAdjustmentConfig ba_config;
      ba_config.FixGauge(colmap::BundleAdjustmentGauge::THREE_POINTS);
      for (int t = w0; t < n_reg; ++t) ba_config.AddImage(s->reg_order[t]);
      // Fix intrinsics once frames exist outside the window; the finalize
      // global BA refines focal.
      if (n_reg > W) ba_config.SetConstantCamIntrinsics(s->camera_id);
      // Variable points = those touched this frame with a short track (<=15),
      // pulled in with their out-of-window observations as constant anchors.
      for (const colmap::point3D_t pid : touched) {
        if (s->live_recon.Point3D(pid).track.Length() <= 15)
          ba_config.AddVariablePoint(pid);
      }

      colmap::BundleAdjustmentOptions ba_options;
      ba_options.refine_rig_from_world = true;
      ba_options.refine_points3D = true;
      ba_options.refine_focal_length = true;  // config fixes it when windowed
      ba_options.refine_principal_point = false;
      ba_options.print_summary = false;
      ba_options.ceres->loss_function_type =
          colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
      ba_options.ceres->loss_function_scale = 1.0;
      ba_options.ceres->solver_options.max_num_iterations =
          s->ba_max_iters > 0 ? s->ba_max_iters : 5;

      try {
        auto ba =
            colmap::CreateDefaultBundleAdjuster(ba_options, ba_config, s->live_recon);
        ba->Solve();
        // ── Floater cleanup on the refined window (COLMAP-standard) ──
        // Runs at the BA cadence (already gated by ba_every_n). Deletes negative-
        // depth observations + high-reproj points among those touched this frame;
        // ExistsPoint3D-guarded internally (observation_manager.cc:377), so ids
        // already removed by the negative-depth pass are skipped, not dereferenced.
        // The recon's Point2D links are reset on delete, so the match-loop queries
        // above stay correct — no obs map to invalidate.
        colmap::ObservationManager obs_mgr(s->live_recon);
        obs_mgr.FilterObservationsWithNegativeDepth();
        s->stat_reproj_filtered +=
            obs_mgr.FilterPoints3DWithLargeReprojectionError(/*max_error=*/4.0, touched);
        // Multi-view min-parallax cull (the "多视角检查"): after BA moves the
        // poses/points, a point whose whole track has collapsed to a tiny
        // max-parallax is a depth-ambiguous floater the reproj gate can't see
        // (it may still reproject cleanly). This is COLMAP's finalize signal
        // (filter_min_tri_angle=1.5°). MUST run AFTER the reproj filter above
        // (observation_manager.cc:313-315: else high-error obs inflate a fake
        // angle). 1.5° (not the 3.0° creation gate) so it only deletes points BA
        // itself pushed below finalize's own threshold — near-no-op on the early
        // 2-view-heavy preview, so it barely thins the cloud.
        s->stat_tri_filtered += obs_mgr.FilterPoints3DWithSmallTriangulationAngle(
            /*min_tri_angle_deg=*/2.0, touched);
      } catch (const std::exception&) {
        // A degenerate window / filter error must not kill capture — carry on.
      }
    }

    // Publish the BA-refined live cloud into preview_points (served unchanged by
    // the getter). Short lock; the getter never blocks on the BA itself.
    {
      std::vector<Eigen::Vector3d> snap;
      snap.reserve(s->live_recon.NumPoints3D());
      for (const auto& [pid, pt] : s->live_recon.Points3D()) snap.push_back(pt.xyz);
      std::lock_guard<std::mutex> lk(s->preview_mutex);
      s->preview_points.swap(snap);
    }

    s->frames.push_back(std::move(rec));
    s->last_extract_ms = extract_ms;
    s->last_match_ms = NowMs() - t_match0;
    s->last_n_cand = n_cand;
    s->last_gpu_matches = gpu_matches;
    s->last_cpu_matches = cpu_matches;
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
    AddSpatialRevisitMatches(s);
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
    AddSpatialRevisitMatches(s);
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
        const Eigen::Quaterniond q = c_from_w.rotation();  // [4.0.4] member -> method
        p.qwxyz[0] = q.w();
        p.qwxyz[1] = q.x();
        p.qwxyz[2] = q.y();
        p.qwxyz[3] = q.z();
        p.t[0] = c_from_w.translation().x();  // [4.0.4] member -> method
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

aether_sfm_result_t aether_sfm_get_points_tracked(
    aether_sfm_session_t* s, aether_sfm_point_t** out_points, int* out_count,
    int32_t** out_obs_offsets, aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count) {
  if (!s || !out_points || !out_count || !out_obs_offsets || !out_obs ||
      !out_obs_count) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  std::shared_ptr<const colmap::Reconstruction> recon;
  {
    std::lock_guard<std::mutex> lk(s->recon_mutex);
    recon = s->recon;  // stable snapshot; survives an async swap
  }
  if (!recon) return AETHER_SFM_ERR_NOT_REGISTERED;
  const auto& pts = recon->Points3D();
  const int n = static_cast<int>(pts.size());

  int64_t total_obs = 0;
  for (const auto& [point_id, point] : pts) {
    total_obs += static_cast<int64_t>(point.track.Length());
  }

  auto* arr = static_cast<aether_sfm_point_t*>(
      std::malloc(static_cast<size_t>(n) * sizeof(aether_sfm_point_t)));
  auto* offs = static_cast<int32_t*>(
      std::malloc((static_cast<size_t>(n) + 1) * sizeof(int32_t)));
  auto* obs = static_cast<aether_sfm_track_obs_t*>(std::malloc(
      static_cast<size_t>(total_obs) * sizeof(aether_sfm_track_obs_t)));
  if ((n > 0 && (!arr || !offs)) || (total_obs > 0 && !obs)) {
    std::free(arr);
    std::free(offs);
    std::free(obs);
    return AETHER_SFM_ERR_INTERNAL;
  }

  int i = 0;
  int64_t w = 0;
  for (const auto& [point_id, point] : pts) {
    aether_sfm_point_t& o = arr[i];
    o.x = static_cast<float>(point.xyz.x());
    o.y = static_cast<float>(point.xyz.y());
    o.z = static_cast<float>(point.xyz.z());
    o.r = point.color(0);
    o.g = point.color(1);
    o.b = point.color(2);
    o._pad[0] = o._pad[1] = 0;
    offs[i] = static_cast<int32_t>(w);
    for (const auto& el : point.track.Elements()) {
      // Track elements always reference existing images in a valid model,
      // but guard anyway — a dropped element only shortens this point's run.
      if (!recon->ExistsImage(el.image_id)) continue;
      const auto& xy = recon->Image(el.image_id).Point2D(el.point2D_idx).xy;
      aether_sfm_track_obs_t& t = obs[w++];
      // image_id is 1-based from WriteImage; frame_id mirrors get_poses.
      t.frame_id = static_cast<int32_t>(el.image_id) - 1;
      t.x = static_cast<float>(xy.x());
      t.y = static_cast<float>(xy.y());
    }
    ++i;
  }
  offs[n] = static_cast<int32_t>(w);
  *out_points = arr;
  *out_count = n;
  *out_obs_offsets = offs;
  *out_obs = obs;
  *out_obs_count = w;
  return AETHER_SFM_OK;
}

void aether_sfm_track_obs_free(int32_t* offsets, aether_sfm_track_obs_t* obs) {
  std::free(offsets);
  std::free(obs);
}

// Sibling of aether_sfm_get_points_tracked that reads the LIVE streaming
// local-BA reconstruction (s->live_recon) instead of the finalize output
// (s->recon), so the worker can true-color the streaming cloud through the SAME
// colorize path. Identical output contract: points via aether_sfm_points_free,
// offsets+obs via aether_sfm_track_obs_free.
//
// THREADING: live_recon is single-writer, owned by aether_sfm_add_frame on the
// capture worker isolate, and — unlike s->recon — is NEVER swapped by an async
// thread. This getter therefore takes NO lock and MUST be called on that same
// worker isolate, serially between add_frame calls. If the Dart binding ever
// calls it off that thread, wrap live_recon's mutation in add_frame AND this
// read in a shared mutex (a torn read of a live Reconstruction is UB).
aether_sfm_result_t aether_sfm_get_preview_tracked(
    aether_sfm_session_t* s, aether_sfm_point_t** out_points, int* out_count,
    int32_t** out_obs_offsets, aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count) {
  if (!s || !out_points || !out_count || !out_obs_offsets || !out_obs ||
      !out_obs_count) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  if (!s->live_recon_ready) return AETHER_SFM_ERR_NOT_REGISTERED;
  const colmap::Reconstruction& recon = s->live_recon;
  const auto& pts = recon.Points3D();
  const int n = static_cast<int>(pts.size());

  int64_t total_obs = 0;
  for (const auto& [point_id, point] : pts)
    total_obs += static_cast<int64_t>(point.track.Length());

  auto* arr = static_cast<aether_sfm_point_t*>(
      std::malloc(static_cast<size_t>(n) * sizeof(aether_sfm_point_t)));
  auto* offs = static_cast<int32_t*>(
      std::malloc((static_cast<size_t>(n) + 1) * sizeof(int32_t)));
  auto* obs = static_cast<aether_sfm_track_obs_t*>(std::malloc(
      static_cast<size_t>(total_obs) * sizeof(aether_sfm_track_obs_t)));
  if ((n > 0 && (!arr || !offs)) || (total_obs > 0 && !obs)) {
    std::free(arr);
    std::free(offs);
    std::free(obs);
    return AETHER_SFM_ERR_INTERNAL;
  }

  int i = 0;
  int64_t w = 0;
  for (const auto& [point_id, point] : pts) {
    aether_sfm_point_t& o = arr[i];
    o.x = static_cast<float>(point.xyz.x());
    o.y = static_cast<float>(point.xyz.y());
    o.z = static_cast<float>(point.xyz.z());
    o.r = point.color(0);
    o.g = point.color(1);
    o.b = point.color(2);
    o._pad[0] = o._pad[1] = 0;
    offs[i] = static_cast<int32_t>(w);
    for (const auto& el : point.track.Elements()) {
      if (!recon.ExistsImage(el.image_id)) continue;
      const auto& xy = recon.Image(el.image_id).Point2D(el.point2D_idx).xy;
      aether_sfm_track_obs_t& t = obs[w++];
      // image_id is 1-based from WriteImage; frame_id mirrors get_poses / get_points_tracked.
      t.frame_id = static_cast<int32_t>(el.image_id) - 1;
      t.x = static_cast<float>(xy.x());
      t.y = static_cast<float>(xy.y());
    }
    ++i;
  }
  offs[n] = static_cast<int32_t>(w);
  *out_points = arr;
  *out_count = n;
  *out_obs_offsets = offs;
  *out_obs = obs;
  *out_obs_count = w;
  return AETHER_SFM_OK;
}

// Legacy experimental one-shot GLOBAL BA over the streaming live_recon. This is
// intentionally NOT the finish-time delivery path: device tests showed pure BA
// can refine existing tracks but cannot create missing cross-view tracks, merge
// duplicate tracks, or retriangulate a revisit into a single wall. Keep it as an
// explicit experiment only; spatial-revisit matching + track merge/retriangulate
// must provide the bridge before any global solve can close a double wall.
//
// Refines live_recon IN PLACE + republishes preview_points. Idempotent-ish
// (re-running just re-optimizes). On any failure the windowed cloud is kept.
// THREADING: like get_preview_tracked, must run on the capture worker isolate
// (mutates live_recon); the getter is called after this returns.
aether_sfm_result_t aether_sfm_global_refine(aether_sfm_session_t* s) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  if (!s->live_recon_ready || s->live_recon.NumRegImages() < 3)
    return AETHER_SFM_ERR_NOT_REGISTERED;
  try {
    // ---- STAGE 1: pose-correcting global BA, OBSERVATION-CAPPED --------------
    // Double-wall = accumulated pose drift, NOT a per-point error. So the drift
    // fix only needs the POSES optimized against a well-distributed subset of
    // long tracks — NOT every one of the (up to millions of) points. We cap the
    // residuals fed to this pass so its cost is bounded and DECOUPLED from total
    // frame/point count: at any capture size stage-1 stays a few seconds. The
    // longest tracks are the ones that SPAN revisits (a wall seen twice → one
    // long track linking both visits), so ranking by length and taking the top
    // until the obs budget is hit is exactly what collapses the two layers.
    const size_t n_frames = s->reg_order.size();
    // ~120 obs/frame keeps per-pose constraint density healthy, floored at 80k
    // (tiny captures) and ceilinged at 400k (huge captures stay bounded).
    const size_t kMaxObs =
        std::min<size_t>(400000, std::max<size_t>(80000, n_frames * 120));

    std::vector<std::pair<int, colmap::point3D_t>> ranked;  // (track_len, pid)
    ranked.reserve(s->live_recon.NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon.Points3D())
      ranked.emplace_back(static_cast<int>(pt.track.Length()), pid);
    std::sort(ranked.begin(), ranked.end(),
              std::greater<std::pair<int, colmap::point3D_t>>());  // longest first

    colmap::BundleAdjustmentConfig cfg1;
    cfg1.FixGauge(colmap::BundleAdjustmentGauge::THREE_POINTS);
    for (const colmap::image_t img_id : s->reg_order) cfg1.AddImage(img_id);
    size_t obs_budget = 0;
    for (const auto& [len, pid] : ranked) {
      if (obs_budget >= kMaxObs) break;
      cfg1.AddVariablePoint(pid);
      obs_budget += static_cast<size_t>(len);
    }

    colmap::BundleAdjustmentOptions opt1;
    opt1.refine_rig_from_world = true;   // poses FREE → drift redistributes
    opt1.refine_points3D = true;
    opt1.refine_focal_length = false;    // trust the ARKit focal (one shared cam)
    opt1.refine_principal_point = false;
    opt1.print_summary = false;
    opt1.ceres->loss_function_type =
        colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
    opt1.ceres->loss_function_scale = 1.0;
    opt1.ceres->solver_options.max_num_iterations = 25;  // gref=1, giter~20-25
    colmap::CreateDefaultBundleAdjuster(opt1, cfg1, s->live_recon)->Solve();

    // ---- STAGE 2: structure-only refit, ALL points, POSES FIXED -------------
    // Stage 1 moved the poses; every point NOT in the capped subset is now stale
    // (it was triangulated under the old drifted poses). With poses held CONSTANT
    // the per-point problems are separable — Ceres solves millions of tiny 3-DOF
    // fits in one linear-cost pass — so this refits the WHOLE cloud onto the
    // corrected geometry cheaply, regardless of point count. (No gauge fix
    // needed: fixed poses already pin the gauge.)
    colmap::BundleAdjustmentConfig cfg2;
    for (const colmap::image_t img_id : s->reg_order) cfg2.AddImage(img_id);
    for (const auto& [pid, pt] : s->live_recon.Points3D())
      cfg2.AddVariablePoint(pid);

    colmap::BundleAdjustmentOptions opt2 = opt1;
    opt2.refine_rig_from_world = false;  // poses FROZEN → structure-only, fast
    opt2.ceres->solver_options.max_num_iterations = 10;
    colmap::CreateDefaultBundleAdjuster(opt2, cfg2, s->live_recon)->Solve();

    // Global floater cleanup (all points now, not just a window's touched set).
    colmap::ObservationManager obs_mgr(s->live_recon);
    obs_mgr.FilterObservationsWithNegativeDepth();
    std::unordered_set<colmap::point3D_t> all_pts;
    all_pts.reserve(s->live_recon.NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon.Points3D()) all_pts.insert(pid);
    obs_mgr.FilterPoints3DWithLargeReprojectionError(/*max_error=*/4.0, all_pts);
    obs_mgr.FilterPoints3DWithSmallTriangulationAngle(/*min_tri_angle_deg=*/2.0,
                                                      all_pts);

    // Republish the collapsed cloud into preview_points.
    std::vector<Eigen::Vector3d> snap;
    snap.reserve(s->live_recon.NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon.Points3D()) snap.push_back(pt.xyz);
    {
      std::lock_guard<std::mutex> lk(s->preview_mutex);
      s->preview_points.swap(snap);
    }
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_INTERNAL;  // keep the windowed cloud on failure
  }
}

// Rough live-preview point cloud accumulated during capture (throwaway; built by
// triangulating per-frame matches with the ARKit poses — NOT the authoritative
// finalize model). World frame = ARKit world. Fills out_xyz with up to `cap`
// points (cap*3 floats); *out_count = TOTAL available (may exceed cap — call once
// with out_xyz=NULL to size, then again to fill).
aether_sfm_result_t aether_sfm_get_preview_points(aether_sfm_session_t* s,
                                                  float* out_xyz, int cap,
                                                  int* out_count) {
  if (!s || !out_count) return AETHER_SFM_ERR_INVALID_ARG;
  std::lock_guard<std::mutex> lk(s->preview_mutex);
  const int n = static_cast<int>(s->preview_points.size());
  *out_count = n;
  if (!out_xyz) return AETHER_SFM_OK;  // count-only sizing query
  const int m = (n < cap) ? n : cap;
  for (int i = 0; i < m; ++i) {
    const Eigen::Vector3d& p = s->preview_points[i];
    out_xyz[3 * i + 0] = static_cast<float>(p.x());
    out_xyz[3 * i + 1] = static_cast<float>(p.y());
    out_xyz[3 * i + 2] = static_cast<float>(p.z());
  }
  return AETHER_SFM_OK;
}

// Per-frame timing/counters of the LAST aether_sfm_add_frame (perf diagnostics;
// see aether_sfm_c.h). Pure read-back of the values add_frame stashes on the
// session — the numbers behind the device log line
//   extract=<extract_ms>ms match=<match_ms>ms cand=<n_cand> gpuM=<..> cpuM=<..>
// Any out-ptr may be NULL. Safe before the first add_frame (fields zero-init).
void aether_sfm_debug_last(aether_sfm_session_t* s, double* extract_ms,
                           double* match_ms, int* n_cand, int* gpu_matches,
                           int* cpu_matches) {
  if (!s) return;
  if (extract_ms) *extract_ms = s->last_extract_ms;
  if (match_ms) *match_ms = s->last_match_ms;
  if (n_cand) *n_cand = s->last_n_cand;
  if (gpu_matches) *gpu_matches = s->last_gpu_matches;
  if (cpu_matches) *cpu_matches = s->last_cpu_matches;
}

// Cumulative streaming-quality counters over the whole capture (see the session
// stat_* fields). Lets the worker log which floater filter did what:
//   tvg_pairs/raw_pairs — geometric-inlier vs raw-fallback grow/create pairs
//   grow_accepted/rejected — track-growth observations kept vs gated out
//   reproj_filtered/tri_filtered — points/obs culled by each post-BA filter
// Any out-ptr may be NULL. Safe before the first add_frame (fields zero-init).
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
                             int64_t* temporal_detail_conflicts) {
  if (!s) return;
  if (tvg_pairs) *tvg_pairs = s->stat_tvg_inlier_pairs;
  if (raw_pairs) *raw_pairs = s->stat_raw_pairs;
  if (grow_accepted) *grow_accepted = s->stat_grow_accepted;
  if (grow_rejected) *grow_rejected = s->stat_grow_rejected;
  if (reproj_filtered) *reproj_filtered = s->stat_reproj_filtered;
  if (tri_filtered) *tri_filtered = s->stat_tri_filtered;
  if (grow_reject_cheirality)
    *grow_reject_cheirality = s->stat_grow_reject_cheirality;
  if (grow_reject_reproj) *grow_reject_reproj = s->stat_grow_reject_reproj;
  if (create_reject_cheirality)
    *create_reject_cheirality = s->stat_create_reject_cheirality;
  if (create_reject_tri_angle)
    *create_reject_tri_angle = s->stat_create_reject_tri_angle;
  if (create_reject_reproj)
    *create_reject_reproj = s->stat_create_reject_reproj;
  if (already_assigned) *already_assigned = s->stat_already_assigned;
  if (merge_needed) *merge_needed = s->stat_merge_needed;
  if (merge_accepted) *merge_accepted = s->stat_merge_accepted;
  if (merge_rejected) *merge_rejected = s->stat_merge_rejected;
  if (spatial_considered)
    *spatial_considered = s->stat_spatial_pairs_considered;
  if (spatial_attempted) *spatial_attempted = s->stat_spatial_pairs_attempted;
  if (spatial_written) *spatial_written = s->stat_spatial_pairs_written;
  if (spatial_inliers) *spatial_inliers = s->stat_spatial_inliers;
  if (spatial_anchor_attempted)
    *spatial_anchor_attempted = s->stat_spatial_anchor_attempted;
  if (spatial_anchor_passed)
    *spatial_anchor_passed = s->stat_spatial_anchor_passed;
  if (spatial_regions_confirmed)
    *spatial_regions_confirmed = s->stat_spatial_regions_confirmed;
  if (spatial_expanded_attempted)
    *spatial_expanded_attempted = s->stat_spatial_expanded_attempted;
  if (spatial_guided_pairs)
    *spatial_guided_pairs = s->stat_spatial_guided_pairs;
  if (spatial_guided_inliers)
    *spatial_guided_inliers = s->stat_spatial_guided_inliers;
  if (spatial_quadratic_attempted)
    *spatial_quadratic_attempted = s->stat_spatial_quadratic_attempted;
  if (spatial_quadratic_written)
    *spatial_quadratic_written = s->stat_spatial_quadratic_written;
  if (spatial_budget_skipped)
    *spatial_budget_skipped = s->stat_spatial_budget_skipped;
  if (temporal_detail_pairs)
    *temporal_detail_pairs = s->stat_temporal_detail_pairs;
  if (temporal_detail_matches)
    *temporal_detail_matches = s->stat_temporal_detail_matches;
  if (temporal_detail_created)
    *temporal_detail_created = s->stat_temporal_detail_created;
  if (temporal_detail_grown)
    *temporal_detail_grown = s->stat_temporal_detail_grown;
  if (temporal_detail_reject_cheirality) {
    *temporal_detail_reject_cheirality =
        s->stat_temporal_detail_reject_cheirality;
  }
  if (temporal_detail_reject_reproj)
    *temporal_detail_reject_reproj = s->stat_temporal_detail_reject_reproj;
  if (temporal_detail_reject_tri_angle) {
    *temporal_detail_reject_tri_angle =
        s->stat_temporal_detail_reject_tri_angle;
  }
  if (temporal_detail_conflicts)
    *temporal_detail_conflicts = s->stat_temporal_detail_conflicts;
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
