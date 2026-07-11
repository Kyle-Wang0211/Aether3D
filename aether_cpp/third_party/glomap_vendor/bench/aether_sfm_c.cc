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
#include "colmap/scene/database_cache.h"
#include "colmap/scene/image.h"
#include "colmap/scene/point3d.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/reconstruction_manager.h"
#include "colmap/scene/two_view_geometry.h"
#include "colmap/scene/track.h"
#include "colmap/estimators/bundle_adjustment.h"
#include "colmap/estimators/bundle_adjustment_ceres.h"
#include "colmap/sfm/incremental_mapper.h"
#include "colmap/sfm/observation_manager.h"

#include <glog/logging.h>

#if defined(__APPLE__)
#include <pthread.h>  // pthread_set_qos_class_self_np (finalize refine QoS)
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <filesystem>
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
// match a new frame against its k_neighbors candidates without re-reading the
// db (candidates are spatial-first — see SelectStreamCandidates).
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

// Why a live merge attempt was rejected — surfaced via aether_sfm_live_diag so
// the acceptance rate is attributable (the 2026-07-10 device run accepted
// 3/13021 merge-needed signals and the reason was invisible).
enum class MergeReject {
  kNone = 0,        // merge is acceptable
  kMissing,         // point deleted / empty track / broken obs (defensive)
  kSharedImage,     // both tracks observe the same image (opt-in gate, off)
  kReproj,          // union refit fails cheirality/reproj on some observation
};

// [MERGE-GATE 2026-07-11] Rewritten around a UNION-TRACK REFIT. The original
// gate reprojected the length-weighted AVERAGE of the two current positions
// (COLMAP's IncrementalTriangulator::Merge recipe) — correct in the mapper,
// where both fragments are already optimized against consistent poses, but
// nearly always wrong here: live fragments are independent low-parallax
// 2-view triangulations under ARKit-seeded, windowed-BA poses, so their depth
// error is large and the midpoint reprojects off BOTH tracks. Host replay of
// the cap47 device db attributed 98% of merge rejections to exactly that
// midpoint-reproj failure (12,892/13,142; the once-suspected disjoint-images
// gate accounted for only 250). Refitting one DLT triangulation over the
// UNION of observations uses the merged track's full (wider) baseline — the
// very benefit the merge exists to unlock — and the acceptance test stays as
// strict as before: EVERY observation of BOTH tracks must be in front of its
// camera and reproject within max_reproj_px of the REFIT position. Two
// physically-distinct points still cannot pass (no single 3D point fits both
// tracks' rays within the gate). On success *out_refit_xyz carries the fitted
// position for the caller to install on the merged point.
//
// The disjoint-images requirement is OPT-IN and OFF at the call site: COLMAP's
// merge has no such requirement (Reconstruction::MergePoints3D concatenates
// tracks that share images without complaint), and duplicate fragments of the
// same physical point routinely co-observe an image (DSP-SIFT emits
// near-identical keypoints at several scales, each seeding its own track).
MergeReject CanMergeLivePoints(const colmap::Reconstruction& recon,
                               const colmap::Camera& camera,
                               colmap::point3D_t pid1,
                               colmap::point3D_t pid2,
                               double max_reproj_px,
                               bool require_disjoint_images,
                               Eigen::Vector3d* out_refit_xyz) {
  if (pid1 == pid2) return MergeReject::kMissing;
  if (!recon.ExistsPoint3D(pid1) || !recon.ExistsPoint3D(pid2)) {
    return MergeReject::kMissing;
  }
  const colmap::Point3D& p1 = recon.Point3D(pid1);
  const colmap::Point3D& p2 = recon.Point3D(pid2);
  if (p1.track.Length() == 0 || p2.track.Length() == 0) {
    return MergeReject::kMissing;
  }
  if (require_disjoint_images &&
      !TracksHaveDisjointImages(p1.track, p2.track)) {
    return MergeReject::kSharedImage;
  }
  // DLT refit over the union of observations.
  std::vector<Eigen::Matrix3x4d> cams_from_world;
  std::vector<Eigen::Vector2d> cam_points;
  cams_from_world.reserve(p1.track.Length() + p2.track.Length());
  cam_points.reserve(p1.track.Length() + p2.track.Length());
  for (const colmap::Track* track : {&p1.track, &p2.track}) {
    for (const auto& el : track->Elements()) {
      if (!recon.ExistsImage(el.image_id)) return MergeReject::kMissing;
      const colmap::Image& image = recon.Image(el.image_id);
      if (!image.HasPose() || el.point2D_idx >= image.NumPoints2D()) {
        return MergeReject::kMissing;
      }
      const std::optional<Eigen::Vector2d> np =
          camera.CamFromImg(image.Point2D(el.point2D_idx).xy);
      if (!np) return MergeReject::kReproj;
      cams_from_world.push_back(image.CamFromWorld().ToMatrix());
      cam_points.push_back(*np);
    }
  }
  Eigen::Vector3d refit_xyz;
  if (!colmap::TriangulateMultiViewPoint(
          colmap::span<const Eigen::Matrix3x4d>(cams_from_world.data(),
                                                cams_from_world.size()),
          colmap::span<const Eigen::Vector2d>(cam_points.data(),
                                              cam_points.size()),
          &refit_xyz)) {
    return MergeReject::kReproj;
  }
  const bool ok = ReprojectsCleanlyToTrack(recon, camera, p1.track, refit_xyz,
                                           max_reproj_px) &&
                  ReprojectsCleanlyToTrack(recon, camera, p2.track, refit_xyz,
                                           max_reproj_px);
  if (!ok) return MergeReject::kReproj;
  if (out_refit_xyz) *out_refit_xyz = refit_xyz;
  return MergeReject::kNone;
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
  //
  // [FINALIZE-ZEROCOPY 2026-07-11] Held via shared_ptr so finalize_async can
  // MOVE the pointer into the refine worker instead of deep-copying the whole
  // model (colmap::Reconstruction has a user-defined copy ctor and NO move —
  // std::move on a by-value member would silently copy; transferring the
  // shared_ptr relocates nothing, so the Images' internal camera pointers stay
  // valid). After the move live_recon is nullptr and live_recon_ready=false:
  // every reader gates on the flag (and defensively on the pointer).
  std::shared_ptr<colmap::Reconstruction> live_recon;
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
  // Reject-reason breakdown of stat_merge_rejected (aether_sfm_live_diag).
  int64_t stat_merge_reject_shared_image = 0;  // disjoint-images gate (if on)
  int64_t stat_merge_reject_reproj = 0;        // merged-position reproj gate
  int64_t stat_merge_reject_missing = 0;       // deleted point / empty track
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
  // [SPATIAL-FIRST 2026-07-11] Capture-time candidate-selection attribution
  // (aether_sfm_candidate_stats): how many add_frame match candidates came
  // from the spatial K-NN ∩ view-angle rule vs the temporal fill/fallback.
  int64_t stat_cand_spatial_first_pairs = 0;
  int64_t stat_cand_temporal_fallback_pairs = 0;
  // [MATCH-FAIL TELEMETRY 2026-07-11] Capture-time GPU matcher failure
  // accounting — the formerly SILENT `mrc != 0 → continue` in add_frame.
  // Device evidence (capture 43, iPhone 14 Pro): thermal=serious from ~f52 →
  // aether_gpu_match_gemm_pairs failed for whole stretches of frames, the db
  // silently lost those pairs, and 37/118 frames ended unregistered.
  // by_rc buckets use the pwsfm_gpu_match.mm return codes (1=bad args,
  // 2=Metal pipeline unavailable, 5/6=MTLBuffer alloc failed, 7=command-buffer
  // error — e.g. GPU hang under thermal pressure); bucket 0 aggregates any
  // out-of-range rc. rc=0 with zero matches is a LEGITIMATE empty pair and is
  // never counted here.
  int64_t stat_gpu_match_fail_total = 0;
  int64_t stat_gpu_match_fail_by_rc[8] = {0};
  int64_t stat_gpu_match_fail_max_streak = 0;  // longest consecutive-fail run
  int64_t gpu_match_fail_streak = 0;  // internal running streak (not exposed)
  // [FINALIZE-REMATCH 2026-07-11] Finalize-time starved-frame re-match pass
  // counters (see FinalizeRematchStarvedFrames).
  int64_t stat_finalize_rematch_starved_frames = 0;
  int64_t stat_finalize_rematch_candidates = 0;  // missing window pairs found
  int64_t stat_finalize_rematch_attempted = 0;   // matcher invocations
  int64_t stat_finalize_rematch_written = 0;     // pairs persisted to the db
  int64_t stat_finalize_rematch_inliers = 0;     // TVG inliers persisted
  int64_t stat_finalize_rematch_failed = 0;      // matcher rc!=0 (skipped)

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

// [SPATIAL-FIRST 2026-07-11] Capture-time match-candidate selection.
//
// WHY: the previous policy matched each new frame against the last K frames by
// TIME. Track length then depends on the user's walking pattern: revisiting a
// region after more than K frames (backtracking, hopping between areas, uneven
// pacing) never re-matches against the earlier frames that SEE the same
// surface, so tracks fragment and finalize delivers fewer track>=3 points.
// Camera-center proximity is the property that actually predicts covisibility
// — 空间邻近应为第一标准,你没法控制用户的步伐 (architecture sign-off).
//
// POLICY (match budget unchanged — still at most K candidates per frame, same
// matcher chain and handoff §0:12 contract: 8192 features / mutual cross-check
// / a GPU-matcher failure skips the pair):
//   1. Spatial-first: the K nearest previous frames by ARKit camera-center
//      distance, gated on viewing-direction compatibility (forward-axis angle
//      < 45° — a same-position opposite-facing frame shares no surface).
//   2. Temporal fill: if the spatial set is short (< K), fill with the most
//      recent frames not already selected (per-pair dedup by frame index; a
//      (j, new) pair can never pre-exist in the db because the new frame id is
//      fresh, so in-set dedup is the complete dedup).
//   3. Degraded fallback: a frame WITHOUT a usable ARKit pose (tracking
//      limited / pose missing) selects the legacy pure-temporal window via
//      the same fill loop — the no-pose path behaves exactly as before.
// In a smooth continuous walk the K nearest ARE mostly the last K frames, so
// this converges to the old policy; it diverges exactly when the user's path
// makes time a bad proxy for space.
//
// Exactness over pose_hash_grid.h: the orientation gate breaks the grid's
// pure-kNN abstraction (the K compatible neighbours may sit arbitrarily many
// shells out), and this linear scan costs ~ns per previous frame — invisible
// next to the >=100 ms descriptor match each SELECTED candidate costs.
// Revisit only if captures ever reach ~10^5 frames.
constexpr double kStreamCandViewAngleMaxRad = 45.0 * M_PI / 180.0;

std::vector<int> SelectStreamCandidates(const aether_sfm_session& s,
                                        const FrameRecord& rec, int frame_id,
                                        int k, int* out_spatial,
                                        int* out_temporal) {
  std::vector<int> selected;
  if (out_spatial) *out_spatial = 0;
  if (out_temporal) *out_temporal = 0;
  if (k <= 0 || frame_id <= 0) return selected;
  selected.reserve(k);

  // Defensive: resume-rebuilt FrameRecords carry no in-memory descriptors and
  // cannot be matched (add_frame is never called on resumed sessions; live
  // frames always have descriptors when n_keypoints > 0).
  const auto usable = [&](int j) {
    const FrameRecord& prev = s.frames[j];
    return prev.n_keypoints > 0 && !prev.descriptors.empty();
  };

  // Kill switch: AETHER_STREAM_TEMPORAL_ONLY=1 forces the legacy pure-temporal
  // window (baseline arm of the host A/B; emergency same-binary revert on
  // device via setenv before aether_sfm_create).
  static const bool temporal_only = [] {
    const char* e = std::getenv("AETHER_STREAM_TEMPORAL_ONLY");
    return e && e[0] == '1';
  }();

  int n_spatial = 0;
  if (!temporal_only && rec.has_pose) {
    const Eigen::Vector3d center = rec.cam_from_world.TgtOriginInSrc();
    const Eigen::Vector3d forward = CameraForwardWorld(rec.cam_from_world);
    const double min_dot = std::cos(kStreamCandViewAngleMaxRad);
    std::vector<std::pair<double, int>> compatible;  // (center dist^2, j)
    compatible.reserve(frame_id);
    for (int j = 0; j < frame_id; ++j) {
      const FrameRecord& prev = s.frames[j];
      if (!prev.has_pose || !usable(j)) continue;
      const double dot = std::max(
          -1.0,
          std::min(1.0, forward.dot(CameraForwardWorld(prev.cam_from_world))));
      if (dot < min_dot) continue;
      compatible.emplace_back(
          (center - prev.cam_from_world.TgtOriginInSrc()).squaredNorm(), j);
    }
    n_spatial = std::min(k, static_cast<int>(compatible.size()));
    std::partial_sort(compatible.begin(), compatible.begin() + n_spatial,
                      compatible.end());  // (dist^2 asc, j asc) — deterministic
    for (int t = 0; t < n_spatial; ++t) {
      selected.push_back(compatible[t].second);
    }
  }
  if (out_spatial) *out_spatial = n_spatial;

  // Temporal fill / full fallback: most recent first, dedup'd against the
  // spatial picks.
  if (static_cast<int>(selected.size()) < k) {
    std::unordered_set<int> chosen(selected.begin(), selected.end());
    for (int j = frame_id - 1;
         j >= 0 && static_cast<int>(selected.size()) < k; --j) {
      if (!usable(j) || !chosen.insert(j).second) continue;
      selected.push_back(j);
      if (out_temporal) ++*out_temporal;
    }
  }
  // Chronological processing order — the caller's grow/merge sequencing stays
  // oldest-first, exactly like the legacy ascending-j loop.
  std::sort(selected.begin(), selected.end());
  return selected;
}

// [MATCH-FAIL TELEMETRY 2026-07-11] Record one capture-time GPU matcher
// failure (add_frame's fail-closed `mrc != 0 → continue`). Counts total +
// per-rc buckets + the consecutive-failure streak, and emits ONE warning line
// when a failure SEGMENT emerges (capture 43's thermal collapse failed whole
// frames of pairs back-to-back — a single skipped pair is normal noise, a run
// of them means the block behind it will not register without the finalize
// re-match). Re-logs every 64 further consecutive failures so an ongoing
// collapse stays visible without per-pair spam.
constexpr int kGpuMatchFailStreakWarn = 8;
void NoteGpuMatchFailure(aether_sfm_session* s, int rc) {
  ++s->stat_gpu_match_fail_total;
  const int bucket = (rc >= 1 && rc <= 7) ? rc : 0;
  ++s->stat_gpu_match_fail_by_rc[bucket];
  ++s->gpu_match_fail_streak;
  if (s->gpu_match_fail_streak > s->stat_gpu_match_fail_max_streak) {
    s->stat_gpu_match_fail_max_streak = s->gpu_match_fail_streak;
  }
  if (s->gpu_match_fail_streak == kGpuMatchFailStreakWarn ||
      (s->gpu_match_fail_streak > kGpuMatchFailStreakWarn &&
       s->gpu_match_fail_streak % 64 == 0)) {
    LOG(WARNING) << "[aether_sfm] GPU matcher failing in a segment: "
                 << s->gpu_match_fail_streak
                 << " consecutive pair failures (last rc=" << rc
                 << ", total=" << s->stat_gpu_match_fail_total
                 << "). Pairs are skipped fail-closed; finalize re-matches "
                    "starved frames.";
  }
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

  // [RESUME 2026-07-10] Frames rebuilt from the db by
  // RebuildFrameRecordsForResume carry NO in-memory descriptors/keypoints —
  // only the existing-matches fast path above can validate such pairs. Fail
  // closed instead of handing the matchers a null descriptor pointer.
  // Live-captured frames always have descriptors when n_keypoints > 0
  // (add_frame assigns them unconditionally), so this is unreachable live.
  if (a.descriptors.empty() || b.descriptors.empty()) return false;

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

// ── Resume support: rebuild minimal FrameRecords from the db ────────────────
// [RESUME 2026-07-10] A resumed finalize (launch-time "有db无PLY" recovery
// sweep / retry after the app was killed mid-solve) reopens sfm_live.db via
// aether_sfm_create + finalize(_async) WITHOUT replaying add_frame, so
// s->frames is EMPTY. RunIncremental itself is db-driven and unaffected, but
// BOTH finish-time enrichment passes are frame-driven and silently no-op:
//   - RestoreTemporalDetail early-returns on frames.size() < 2 → the resumed
//     model loses the whole temporal detail layer (observed on device: ~23k
//     delivered points on resume vs ~60k live for the same capture).
//   - AddSpatialRevisitMatches early-returns on frames.size() < 3 ||
//     camera_id == 0.
// Rebuild MINIMAL records: image_id (1-based WriteImage auto-increment ==
// capture order; add_frame names images "frame_%06d.jpg" with frame_id ==
// image_id-1, used as a cross-check) + n_keypoints, and refill the session
// camera from the db (single shared SIMPLE_PINHOLE per session).
//
// Deliberately NOT restored (memory: ~1 MB/frame descriptors at 8192 kp):
// descriptors, keypoint xy, ARKit poses. Consequences, by consumer:
//   - RestoreTemporalDetail reads ONLY image_id here; TVGs come from the db →
//     fully functional after this rebuild.
//   - AddSpatialRevisitMatches: pairs ALREADY IN THE DB (written by a previous
//     interrupted finalize) validate via VerifySpatialPair's existing-matches
//     fast path. FRESH spatial pairs would need descriptors + keypoints (+ the
//     GPU guided matcher); that is intentionally out of scope for resume —
//     VerifySpatialPair fails such pairs closed (empty-descriptor guard there).
//     has_pose stays false, so anchor building degrades to the quadratic
//     fallback whose fresh pairs also fail closed. Acceptable: loop-closure
//     pairs a previous finalize committed are consumed by RunIncremental from
//     two_view_geometries regardless of s->frames.
// Live sessions (frames non-empty) are untouched — strict no-op.
void RebuildFrameRecordsForResume(aether_sfm_session* s) {
  if (!s || !s->db || !s->frames.empty()) return;
  try {
    std::vector<colmap::Image> images = s->db->ReadAllImages();
    if (images.empty()) return;
    std::sort(images.begin(), images.end(),
              [](const colmap::Image& a, const colmap::Image& b) {
                return a.ImageId() < b.ImageId();
              });
    std::vector<FrameRecord> frames;
    frames.reserve(images.size());
    for (const colmap::Image& image : images) {
      FrameRecord rec;
      rec.image_id = image.ImageId();
      // Cross-check against the add_frame naming convention; fall back to the
      // 1-based-id convention if the name ever diverges.
      int parsed = -1;
      if (std::sscanf(image.Name().c_str(), "frame_%d.jpg", &parsed) == 1 &&
          parsed >= 0) {
        rec.frame_id = parsed;
      } else {
        rec.frame_id = static_cast<int>(image.ImageId()) - 1;
      }
      rec.n_keypoints =
          static_cast<int>(s->db->NumKeypointsForImage(image.ImageId()));
      frames.push_back(std::move(rec));
    }
    if (s->camera_id == 0) {
      const std::vector<colmap::Camera> cameras = s->db->ReadAllCameras();
      if (!cameras.empty()) {
        s->camera = cameras.front();
        s->camera_id = cameras.front().camera_id;
      }
    }
    s->frames = std::move(frames);
  } catch (const std::exception&) {
    // Fail open into the pre-fix behavior: with frames still empty the
    // enrichment passes skip themselves and the db-driven finalize proceeds.
    s->frames.clear();
  }
}

// ── Finalize-time starved-frame re-match ────────────────────────────────────
// [FINALIZE-REMATCH 2026-07-11] Repairs the db after a capture-time GPU
// matcher collapse. Device evidence (capture 43, iPhone 14 Pro): thermal=
// serious from ~f52 → aether_gpu_match_gemm_pairs failed in whole segments,
// add_frame skipped those pairs fail-closed, so the db simply LACKS the
// matches for a contiguous block → 37/118 frames unregistered, delivery
// collapsed to ~26k points. Host replay proved the block's DESCRIPTORS are
// intact (features were full 8192/frame; re-matching registers the block), so
// finalize — which runs after capture, typically cooler, with no 2 s/frame
// budget — re-runs the MISSING temporal-window pairs through the SAME matcher
// route before RunIncremental consumes the db.
//
// Starved trigger (calibrated on the capture-43 db): a frame is starved when
// it participates in < kRematchMinValidWindowPairs db pairs with
// >= kRematchValidInlierGate TVG inliers inside the temporal K-window.
// cap43 separation is clean: healthy frames sit at 4-21 valid window pairs,
// the collapsed block at 0-3.
//
// Candidates = temporal pairs (j, f) with gap <= K, ABSENT from `matches`,
// where EITHER side is starved. Either-side bridges the block boundary (the
// first healthy frame after a collapse still re-matches against the starved
// tail behind it). Missing-only keeps the pass idempotent (add_frame never
// writes a failed pair, so absence == never-succeeded) and write-once — the
// exact WriteMatches → EstimateTwoViewGeometry → WriteTwoViewGeometry
// sequence add_frame uses; RunIncremental's min_num_matches=15 then filters
// weak pairs identically to capture-time pairs.
//
// Second trigger — near-adjacent chain holes: a missing (f-1, f) or (f-2, f)
// pair is ALWAYS re-matched, starved or not. The capture-42 db showed the
// milder failure shape: frames keep 5-14 valid window pairs (above the
// starved gate) while the CONSECUTIVE chain has whole runs of never-attempted
// pairs (f105-f128) — partly a spatial-first side effect (revisit segments
// match across passes instead of adjacent frames) amplified by the thermal
// failures. The incremental mapper leans on chain continuity; these holes are
// cheap to close (cap42 +25 pairs, cap43 +2, healthy captures ~0).
//
// Budget: kFinalizeRematchMaxPairs bounds the extreme case (cap43's fully
// collapsed tail needs 686 pairs; the GPU GEMM matcher is ~0.1 s/pair at
// 8192 kp → ~1 min worst case, paid only by a capture that would otherwise
// lose a whole registration block). Gap-ascending round-robin spends the
// budget on the nearest (most registrable) neighbours of every starved frame
// first.
//
// Matcher policy = capture parity (HANDOFF §0:12): use_gpu_match=1 routes to
// the Metal GEMM matcher and a per-pair failure SKIPS that pair — CPU
// brute-force is never a device fallback. use_gpu_match=0 (host replay /
// no-Metal builds) uses the CPU matcher, exactly as capture did then. Resume
// sessions (FrameRecords rebuilt without descriptors) load keypoints +
// descriptors per frame from the db into a window-bounded cache (~K+1 frames
// ≈ 16 MB at 8192 kp — transient, freed on return).
constexpr int kRematchMinValidWindowPairs = 4;  // cap43-calibrated (see above)
constexpr int kRematchValidInlierGate = 15;     // == pipeline min_num_matches
constexpr int kRematchNearGap = 2;              // chain holes always re-matched
constexpr int kFinalizeRematchMaxPairs = 800;   // > cap43 worst case (688)

void FinalizeRematchStarvedFrames(aether_sfm_session* s) {
  if (!s || !s->db || s->frames.size() < 3 || s->camera_id == 0) return;
  const bool gpu_avail =
      s->options.use_gpu_match && (aether_gpu_match_gemm_pairs != nullptr);
  // Fail-closed like VerifySpatialPair: GPU requested but symbol absent →
  // skip the whole pass rather than degrade into O(N²) CPU matching.
  if (s->options.use_gpu_match && !gpu_avail) return;
  try {
    const int num_frames = static_cast<int>(s->frames.size());
    const int K = s->options.k_neighbors > 0 ? s->options.k_neighbors : 12;

    std::unordered_map<colmap::image_t, int> idx_of;
    idx_of.reserve(s->frames.size());
    for (int i = 0; i < num_frames; ++i) idx_of[s->frames[i].image_id] = i;

    // 1) Per-frame valid-pair count inside the temporal K-window, from the
    //    TVG table (counts capture-time pairs AND anything the spatial
    //    revisit pass just wrote).
    std::vector<int> win_valid(num_frames, 0);
    for (const auto& [pair_id, n_inliers] :
         s->db->ReadTwoViewGeometryNumInliers()) {
      if (n_inliers < kRematchValidInlierGate) continue;
      const auto [id1, id2] = colmap::PairIdToImagePair(pair_id);
      const auto a = idx_of.find(id1);
      const auto b = idx_of.find(id2);
      if (a == idx_of.end() || b == idx_of.end()) continue;
      if (std::abs(a->second - b->second) > K) continue;
      ++win_valid[a->second];
      ++win_valid[b->second];
    }
    std::vector<char> starved(num_frames, 0);
    int64_t n_starved = 0;
    for (int i = 0; i < num_frames; ++i) {
      if (s->frames[i].n_keypoints > 0 &&
          win_valid[i] < kRematchMinValidWindowPairs) {
        starved[i] = 1;
        ++n_starved;
      }
    }
    s->stat_finalize_rematch_starved_frames += n_starved;

    // 2) Missing pairs, gap-ascending round-robin so every frame gets its
    //    nearest neighbours before the budget can clip anything:
    //      gap <= kRematchNearGap  → always (chain-hole trigger),
    //      gap <= K                → when either side is starved.
    std::vector<std::pair<int, int>> todo;  // (j, f), j < f, frame indices
    todo.reserve(kFinalizeRematchMaxPairs);
    for (int gap = 1; gap <= K; ++gap) {
      for (int f = gap; f < num_frames; ++f) {
        const int j = f - gap;
        if (gap > kRematchNearGap && !starved[f] && !starved[j]) continue;
        if (s->frames[j].n_keypoints <= 0 || s->frames[f].n_keypoints <= 0) {
          continue;
        }
        if (s->db->ExistsMatches(s->frames[j].image_id,
                                 s->frames[f].image_id)) {
          continue;
        }
        ++s->stat_finalize_rematch_candidates;
        if (static_cast<int>(todo.size()) < kFinalizeRematchMaxPairs) {
          todo.emplace_back(j, f);
        }
      }
    }
    if (todo.empty()) return;
    // Cache locality for the resume-path db loads: process by later frame
    // ascending; every needed partner then lives within the last K indices.
    std::sort(todo.begin(), todo.end(),
              [](const std::pair<int, int>& a, const std::pair<int, int>& b) {
                if (a.second != b.second) return a.second < b.second;
                return a.first < b.first;
              });

    // Feature access: borrow the in-memory FrameRecord (live sessions) or
    // load keypoints+descriptors from the db (resume sessions), cached and
    // evicted outside the sliding window.
    struct RematchFeat {
      const uint8_t* desc = nullptr;
      const std::vector<Eigen::Vector2d>* pts = nullptr;
      int n = 0;
      std::vector<uint8_t> desc_store;
      std::vector<Eigen::Vector2d> pts_store;
    };
    std::unordered_map<int, RematchFeat> cache;
    const auto get_feat = [&](int i) -> const RematchFeat* {
      const FrameRecord& fr = s->frames[i];
      auto it = cache.find(i);
      if (it != cache.end()) return it->second.n > 0 ? &it->second : nullptr;
      RematchFeat& feat = cache[i];
      if (!fr.descriptors.empty() && !fr.points.empty()) {
        feat.desc = fr.descriptors.data();
        feat.pts = &fr.points;
        feat.n = fr.n_keypoints;
        return &feat;
      }
      const colmap::FeatureKeypoints kps = s->db->ReadKeypoints(fr.image_id);
      const colmap::FeatureDescriptors d = s->db->ReadDescriptors(fr.image_id);
      const int n = static_cast<int>(kps.size());
      if (n <= 0 || d.data.rows() != n || d.data.cols() != 128) {
        feat.n = 0;  // negative-cache the malformed frame
        return nullptr;
      }
      feat.desc_store.assign(d.data.data(),
                             d.data.data() + static_cast<size_t>(n) * 128);
      feat.pts_store = colmap::FeatureKeypointsToPointsVector(kps);
      feat.desc = feat.desc_store.data();
      feat.pts = &feat.pts_store;
      feat.n = n;
      return &feat;
    };

    // 3) Match + persist, mirroring add_frame's sequence and gates exactly.
    const double ratio =
        s->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.7;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    std::vector<uint32_t> pair_buf;
    for (const auto& [j, f] : todo) {
      // Evict cache entries that fell out of the sliding window (memory
      // bound for resume-path loads; borrowed live entries are cheap).
      for (auto it = cache.begin(); it != cache.end();) {
        if (it->first < f - K) it = cache.erase(it);
        else ++it;
      }
      const RematchFeat* fa = get_feat(j);
      const RematchFeat* fb = get_feat(f);
      if (!fa || !fb) continue;
      const int cap = fa->n < fb->n ? fa->n : fb->n;
      pair_buf.resize(static_cast<size_t>(cap) * 2);
      int num_matches = 0;
      ++s->stat_finalize_rematch_attempted;
      const int mrc =
          gpu_avail
              ? aether_gpu_match_gemm_pairs(fa->desc, fa->n, fb->desc, fb->n,
                                            ratio, pair_buf.data(), cap,
                                            &num_matches)
              : aether_sift_match_pairs(fa->desc, fa->n, fb->desc, fb->n,
                                        ratio, pair_buf.data(), cap,
                                        &num_matches);
      if (mrc != 0) {
        // Still failing (device still hot / Metal unavailable): keep the
        // capture-time semantics — skip the pair, never CPU brute-force.
        ++s->stat_finalize_rematch_failed;
        continue;
      }
      if (num_matches <= 0) continue;  // legitimate zero-match pair

      colmap::FeatureMatches matches(num_matches);
      for (int m = 0; m < num_matches; ++m) {
        matches[m].point2D_idx1 = pair_buf[2 * m];
        matches[m].point2D_idx2 = pair_buf[2 * m + 1];
      }
      s->db->WriteMatches(s->frames[j].image_id, s->frames[f].image_id,
                          matches);
      const colmap::TwoViewGeometry geometry = colmap::EstimateTwoViewGeometry(
          s->camera, *fa->pts, s->camera, *fb->pts, std::move(matches),
          tvg_options);
      s->db->WriteTwoViewGeometry(s->frames[j].image_id,
                                  s->frames[f].image_id, geometry);
      ++s->stat_finalize_rematch_written;
      s->stat_finalize_rematch_inliers +=
          static_cast<int64_t>(geometry.inlier_matches.size());
    }
    LOG(WARNING) << "[aether_sfm] finalize re-match: starved_frames="
                 << n_starved
                 << " candidates=" << s->stat_finalize_rematch_candidates
                 << " attempted=" << s->stat_finalize_rematch_attempted
                 << " written=" << s->stat_finalize_rematch_written
                 << " inliers=" << s->stat_finalize_rematch_inliers
                 << " failed=" << s->stat_finalize_rematch_failed
                 << " gpu_fail_capture=" << s->stat_gpu_match_fail_total;
  } catch (const std::exception& e) {
    // Enhancement pass only — a failure here must never take finalize down.
    LOG(WARNING) << "[aether_sfm] finalize re-match aborted: " << e.what();
  }
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

// [TRI-ANGLE A/B 2026-07-11] Finalize triangulation CREATION gate, env-tunable
// for host replay A/B (cap43 registration-rate investigation: device 81/118
// registered on the first 3.0° build vs 75% on the 1.5° build). Phase 1
// (RunIncremental / mapper registration) and phase 2 (RefineGlobalBA) read
// SEPARATE env names so "registration-wide, refine-strict" configs can be
// tested. Unset -> the shipped 3.0°.
double TriMinAngleDeg(const char* env_name) {
  const char* e = std::getenv(env_name);
  if (e && e[0]) {
    const double d = std::atof(e);
    if (d > 0.0) return d;
  }
  return 3.0;
}

// [AETHER BA-MIXED 2026-07-11] Finalize global BA mixed-precision solves
// (fp32 factorize/solve of the reduced camera system + fp64 iterative-
// refinement steps). ⚠️ DEFAULT OFF — host A/B (cap42, spatial_ab streaming
// driver, GPU matcher, thread-count controlled at 12) VETOED the default-on
// plan: the mixed arm shifted the DELIVERED cloud far outside the noise band
// (points 66752→72897 = +9.2%, mean reproj 1.0156→1.0430 = +0.027, 9-gate
// 4/9: reproj_median +5.2%, tri_angle x0.943, weak_track +5.4%, arkit_pos
// +15.7%). Attribution was exact: the threads-only arm was equal to baseline
// to 4 decimals on every metric, the mixed-only arm reproduced the full
// drift. Mechanism: the CAUCHY-reweighted Schur complement is near-singular
// (the same conditioning that crashes Accelerate's fp64 sparse Cholesky);
// fp32 factorization error scales with the condition number, iterative
// refinement stalls on it, and the LM trajectory converges to a visibly
// different (worse) state — NOT run-to-run noise. Opt-in for future
// experiments: AETHER_BA_MIXED=1 (+AETHER_BA_MIXED_REFINE=N, default 3).
// Capture-time LOCAL BA is never touched either way.
bool BaMixedEnabled() {
  const char* e = std::getenv("AETHER_BA_MIXED");
  return e && e[0] == '1';
}

// [AETHER BA-THREADS 2026-07-11] Finalize BA ceres thread budget. Previous
// behavior was num_threads=-1 -> hardware_concurrency (host M3 Pro 12, A16 6)
// for every solve above the 6000-residual floor. New default = min(6, hw-2):
// leaves headroom for the rest of the process (GPU-matcher CPU side, db I/O,
// Dart/UI on device) instead of saturating every core with Schur workers —
// A16: 4 threads (2P+2E stay free), host M3 Pro: 6. Env AETHER_BA_THREADS
// overrides (any positive integer). The stage-1 overlap window still halves
// whatever this returns (enrichment is the critical path there); stage 2 and
// the full re-run run the full budget.
int FinalizeBaThreads() {
  static const int cached = [] {
    if (const char* e = std::getenv("AETHER_BA_THREADS")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    const int hw = static_cast<int>(std::thread::hardware_concurrency());
    return std::max(1, std::min(6, hw - 2));
  }();
  return cached;
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
    // [AETHER BA-MIXED/THREADS 2026-07-11] This is the db-driven batch /
    // full-re-run finalize: global BA gets the finalize thread budget
    // (AETHER_BA_THREADS override; default min(6, hw-2), was -1 -> all
    // cores; quality equal to baseline to 4 decimals on every 9-gate metric,
    // host A/B). Mixed precision stays OFF unless AETHER_BA_MIXED=1
    // (A/B-vetoed default, see BaMixedEnabled). num_threads also feeds the
    // local-BA solves of this batch path — intended: same headroom
    // rationale, and the live capture-time local BA does NOT go through here
    // (hand-built options in the streaming path).
    pipeline_opts->ba_global_mixed_precision = BaMixedEnabled();
    pipeline_opts->num_threads = FinalizeBaThreads();
    pipeline_opts->mapper.ba_local_num_images = 10;
    // [TRI-ANGLE 2026-07-11] Creation parallax gate 1.5°(colmap default)→3.0°,
    // aligned with BOTH streaming creation gates (add_frame kMinTriAngleRad and
    // RestoreTemporalDetail — 3.0° each). The delivered cloud's low-parallax
    // tail was born HERE: the mapper's IncrementalTriangulator created tracks
    // down to 1.5° pairwise parallax (cap47 attribution: 25.9% of native
    // 2-view delivered points sat below 3° — depth-ambiguous fuzz around thin
    // structures). Creation-only: filter_min_tri_angle stays at its default,
    // so BA may still keep an existing point that drifts into [1.5°, 3°) —
    // same semantics as the live path. init_min_tri_angle (initial pair) is
    // far above both and unaffected (incremental_pipeline.cc:459 overrides
    // min_angle for the init pair only).
    pipeline_opts->triangulation.min_angle =
        TriMinAngleDeg("AETHER_TRI_MIN_ANGLE");
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

// [S3.5 RESTORE 2026-07-11] In-thread safety net for the refine worker: if the
// primary phase-2 path throws, fall back to the validated db-driven FULL
// pipeline re-run (registration + in-run Cauchy global BA) so the capture
// still delivers a refined cloud instead of an ERROR. Motivating case: the
// live-recon-reuse path registers frames by ARKit pose, so a frame whose
// every db pair fell below min_num_matches=15 (total capture-time GPU-matcher
// collapse that the finalize re-match could not repair — device still hot)
// exists in the recon but NOT in the DatabaseCache correspondence graph, and
// ObservationManager's bookkeeping loop throws std::out_of_range on it. The
// old chain never hit this only because its phase 1 silently dropped such
// frames. Cost: fallback duplicates the old full re-run — paid ONLY on an
// exception that previously ended the whole finalize in ERROR.
void RefineFallbackFullRerun(aether_sfm_session* s, const char* why) {
  LOG(WARNING) << "[aether_sfm] refine failed (" << why
               << ") — falling back to db-driven full re-run";
  try {
    const double t0 = NowMs();
    std::shared_ptr<colmap::ReconstructionManager> manager;
    std::shared_ptr<const colmap::Reconstruction> recon;
    const aether_sfm_result_t rc =
        RunIncremental(s->db_path, s->image_path, s->options, &manager, &recon,
                       nullptr, 0, /*local_only=*/false);
    if (rc != AETHER_SFM_OK || !recon || recon->NumRegImages() == 0) {
      s->finalize_status.store(3);  // AETHER_SFM_FINALIZE_ERROR
      return;
    }
    auto refined = std::make_shared<colmap::Reconstruction>(*recon);
    RestoreTemporalDetail(s, refined.get());
    {
      std::lock_guard<std::mutex> lk(s->recon_mutex);
      s->recon_manager = manager;
      s->recon = refined;
      s->refine_ms = NowMs() - t0;
    }
    s->finalize_status.store(2);  // AETHER_SFM_FINALIZE_REFINED
  } catch (...) {
    s->finalize_status.store(3);  // AETHER_SFM_FINALIZE_ERROR
  }
}

// Shared phase-2 pipeline options (the validated Cauchy global config).
// [2026-07-10] COMPLETE the phase-2 Cauchy config. This block previously set only
// min_num_matches + residuals, so ba_global_loss_type defaulted to 0 (TRIVIAL) —
// phase 2 was NOT the full Cauchy it was described as. Set the SAME validated global
// config the synchronous RunPipeline uses (RunIncremental above): Cauchy@1.0,
// gftol 1e-6, gref5/giter50 (defaults, set explicit so they hit the log).
// RefineReconstruction runs iterative global refinement, which reads
// ba_global_* for its loss. NOTE: this sets ONLY the loss config; the
// RefineReconstruction-vs-TriangulateReconstruction choice is a SEPARATE algorithmic
// decision, intentionally left unchanged here for a controlled A/B.
std::shared_ptr<colmap::IncrementalPipelineOptions> MakePhase2Options(
    const aether_sfm_session* s) {
  auto popts = std::make_shared<colmap::IncrementalPipelineOptions>();
  popts->min_num_matches = 15;
  popts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
  popts->ba_global_loss_type = 2;              // CAUCHY (was defaulting to 0=TRIVIAL)
  popts->ba_global_loss_scale = 1.0;
  popts->ba_global_function_tolerance = 1e-6;  // converge-stop
  popts->ba_global_max_refinements = 5;
  popts->ba_global_max_num_iterations = 50;
  // [AETHER BA-MIXED/THREADS 2026-07-11] Finalize phase-2 (stage 1 + stage 2)
  // global BA: the finalize thread budget (default min(6, hw-2),
  // AETHER_BA_THREADS override; quality equal to baseline to 4 decimals on
  // every 9-gate metric, host A/B). Mixed precision stays OFF unless
  // AETHER_BA_MIXED=1 (A/B-vetoed default, see BaMixedEnabled). Stage 1
  // additionally halves the budget during the enrichment overlap window (see
  // RefineGlobalBA).
  popts->ba_global_mixed_precision = BaMixedEnabled();
  popts->num_threads = FinalizeBaThreads();
  // [TRI-ANGLE 2026-07-11] Same 3.0° creation gate as RunIncremental:
  // IterativeGlobalRefinement's CompleteAndMergeTracks/retriangulation reads
  // Triangulation() too — keep phase 2 from re-admitting the <3° tail that
  // phase 1 now refuses to create.
  popts->triangulation.min_angle = TriMinAngleDeg("AETHER_TRI_MIN_ANGLE_P2");
  // [FINALIZE-OVERLAP 2026-07-11] Load ALL images into the DatabaseCache, not
  // just match-connected ones. The live-reuse recon registers frames by ARKit
  // pose; a frame whose every db pair fell below min_num_matches exists in the
  // recon but — without this — NOT in the cache, and ObservationManager's
  // bookkeeping throws std::out_of_range (previously only caught by the full
  // re-run fallback, which dropped the live registrations). Loading the image
  // with zero correspondences keeps it inert but resolvable.
  popts->load_all_images = true;
  popts->image_path = s->image_path;  // [4.0.4] image_path moved into options
  return popts;
}

// Async-finalize worker.
//
// live_reuse=true (normal completion, [FINALIZE-ZEROCOPY + FINALIZE-OVERLAP
// 2026-07-11]): `model` IS the moved-out live recon (sole owner — user signed
// off that the LOCAL model is never displayed, so nothing is published until
// REFINED and the refinement runs IN PLACE, zero deep copies; the old chain
// held live_recon + a LOCAL copy + a worker copy = 3 models at peak). The
// finish-time db enrichment (AddSpatialRevisitMatches +
// FinalizeRematchStarvedFrames — GPU matcher, writes the db) runs on a helper
// thread IN PARALLEL with a stage-1 refinement over a PRE-enrichment
// DatabaseCache snapshot (CPU: the same IterativeGlobalRefinement rounds the
// old chain ran serially AFTER the enrichment — CompleteAndMergeTracks /
// Retriangulate / Cauchy global BA over the capture-time pairs). Once both
// finish, stage 2 = the UNCHANGED RefineReconstruction over the ENRICHED db:
// its leading CompleteAndMergeTracks + Retriangulate consume the new spatial /
// re-match pairs, its BA rounds converge-stop early because stage 1 already
// converged the capture-graph part. Trade-off vs the serial baseline: the
// enrichment pairs join the refinement only in stage 2 (late) instead of from
// round 1 — accepted after the host 42/43 A/B held the quality gates (points
// ±2%, reproj ±0.02); AETHER_FINALIZE_NO_OVERLAP=1 is the same-binary revert
// (enrichment then a single full refinement, i.e. the exact serial order).
// db concurrency: the stage-1 cache snapshot is taken from s->db BEFORE the
// enrichment thread starts; during the overlap the enrichment thread is the
// db's only user; stage 2 reopens the db after the join.
//
// live_reuse=false (resume / degenerate path): unchanged semantics — `model`
// is the published LOCAL_READY model (db-driven RunIncremental output, still
// readable through the getters), so refine a deep copy and swap on success.
// Enrichment already ran synchronously in aether_sfm_finalize_async there.
void RefineGlobalBA(aether_sfm_session* s,
                    std::shared_ptr<colmap::Reconstruction> model,
                    bool live_reuse) {
  try {
#if defined(__APPLE__)
    // [S3.5 RESTORE 2026-07-11] The refined model IS the user-visible result
    // (no two-phase preview) and the user is waiting on the foreground waiting
    // page — run the global BA at user-initiated QoS so a default/background
    // QoS std::thread doesn't get E-core-throttled mid-wait.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
    const double t0 = NowMs();
    auto popts = MakePhase2Options(s);
    std::shared_ptr<colmap::Reconstruction> refined;
    double enrich_ms = 0.0, cache_pre_ms = 0.0, stage1_ms = 0.0;
    int stage1_rounds = 0;
    const char* stage1_state = "off";
    if (live_reuse) {
      refined = std::move(model);  // in place — nothing else holds this model
      // Kill switch: AETHER_FINALIZE_NO_OVERLAP=1 restores the serial order
      // (enrichment first, then one full refinement over the enriched db).
      static const bool no_overlap = [] {
        const char* e = std::getenv("AETHER_FINALIZE_NO_OVERLAP");
        return e && e[0] == '1';
      }();
      // Stage-1 graph snapshot BEFORE the enrichment thread writes the db.
      std::shared_ptr<colmap::DatabaseCache> cache_pre;
      if (!no_overlap && s->db && s->frames.size() >= 2) {
        try {
          const double t_cache = NowMs();
          colmap::DatabaseCache::Options copts;
          copts.min_num_matches =
              static_cast<size_t>(popts->min_num_matches);
          copts.load_all_images = true;  // see MakePhase2Options
          cache_pre = colmap::DatabaseCache::Create(*s->db, copts);
          cache_pre_ms = NowMs() - t_cache;
        } catch (const std::exception& e) {
          cache_pre.reset();
          LOG(WARNING) << "[aether_sfm] finalize stage-1 cache snapshot failed"
                          " ("
                       << e.what() << ") — no overlap, serial refinement";
        }
      }
      // Enrichment thread: GPU matcher writes the db; the passes are already
      // fail-soft internally, but an escaped exception here would terminate
      // the process (thread boundary) — catch everything. enrich_done is the
      // stage-1 window flag: stage-1 refinement rounds only run while the GPU
      // enrichment is still working (its wall time is "free"), so the round
      // budget adapts to the capture — a healthy capture whose enrichment is
      // seconds runs ~0 stage-1 rounds (stage 2 then IS the serial baseline),
      // a heavy revisit capture fills the whole window with useful rounds.
      std::atomic<bool> enrich_done{false};
      const double t_enrich0 = NowMs();
      std::thread enrich([s, &enrich_ms, &enrich_done, t_enrich0] {
#if defined(__APPLE__)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
        try {
          AddSpatialRevisitMatches(s);
          FinalizeRematchStarvedFrames(s);
        } catch (const std::exception& e) {
          LOG(WARNING) << "[aether_sfm] finalize db enrichment aborted: "
                       << e.what();
        } catch (...) {
          LOG(WARNING) << "[aether_sfm] finalize db enrichment aborted";
        }
        try {
          if (s->db) s->db->Close();  // flush before stage 2 reopens it
        } catch (...) {
        }
        enrich_ms = NowMs() - t_enrich0;
        enrich_done.store(true);
      });
      // Stage-1 refinement (CPU) over the capture-time graph, in parallel
      // with the enrichment: the SAME per-round sequence as colmap's
      // IterativeGlobalRefinement (CompleteAndMergeTracks + Retriangulate
      // once, then rounds of AdjustGlobalBundle + CompleteAndMergeTracks +
      // FilterPoints with the identical converge-stop), except the loop also
      // stops at the first round boundary after the enrichment finishes —
      // stage-1 never spends meaningfully past the free window. Failure is
      // non-fatal: stage 2 then simply runs the full refinement alone (== the
      // serial baseline).
      if (cache_pre) {
        const double t_s1 = NowMs();
#if defined(__APPLE__)
        // During the overlap the ENRICHMENT is the critical path (its
        // completion gates stage 2) while stage 1 is opportunistic filler —
        // measured on cap43: with both at USER_INITIATED the stage-1 BA
        // starved the enrichment's CPU side (TVG RANSAC) 42.9 s → 54.6 s.
        // Drop the worker to UTILITY for stage 1 only; restored below.
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
        try {
          colmap::IncrementalMapper mapper(cache_pre);
          mapper.BeginReconstruction(refined);
          const auto mapper_opts = popts->Mapper();
          auto ba_opts = popts->GlobalBundleAdjustment();
          const auto tri_opts = popts->Triangulation();
          // Halve the ceres thread pool for stage-1 solves only: the QoS drop
          // alone did not stop the BA from starving the enrichment (ceres
          // spawns its own default-QoS workers and the Schur solves saturate
          // memory bandwidth — cap43 enrichment 42.9 s serial → 54.9 s under
          // an all-cores stage 1). Stage 1 is window-bound filler, so slower
          // rounds cost nothing; stage 2 keeps the full thread pool.
          // [AETHER BA-THREADS 2026-07-11] The base is now the finalize
          // budget (min(6, hw-2) / AETHER_BA_THREADS) instead of raw
          // hardware_concurrency: overlap window = budget/2, exclusive
          // stage 2 = full budget.
          if (ba_opts.ceres) {
            const int full =
                ba_opts.ceres->solver_options.num_threads > 0
                    ? ba_opts.ceres->solver_options.num_threads
                    : static_cast<int>(std::thread::hardware_concurrency());
            ba_opts.ceres->solver_options.num_threads = std::max(1, full / 2);
          }
          // Window checks between the sub-steps too: a healthy capture whose
          // enrichment finishes in seconds must not pay for a full merge +
          // retriangulate pass it gains nothing from (stage 2 redoes both on
          // the enriched graph).
          if (!enrich_done.load()) mapper.CompleteAndMergeTracks(tri_opts);
          if (!enrich_done.load()) mapper.Retriangulate(tri_opts);
          for (int i = 0; i < popts->ba_global_max_refinements; ++i) {
            if (enrich_done.load()) break;  // window closed
            const size_t num_obs = refined->ComputeNumObservations();
            mapper.AdjustGlobalBundle(mapper_opts, ba_opts);
            size_t num_changed = mapper.CompleteAndMergeTracks(tri_opts);
            num_changed += mapper.FilterPoints(mapper_opts);
            ++stage1_rounds;
            const double changed =
                num_obs == 0 ? 0
                             : static_cast<double>(num_changed) / num_obs;
            if (changed < popts->ba_global_max_refinement_change) break;
          }
          mapper.EndReconstruction(/*discard=*/false);
          stage1_state = "ok";
        } catch (const std::exception& e) {
          stage1_state = "failed";
          stage1_rounds = 0;
          LOG(WARNING) << "[aether_sfm] finalize stage-1 refine failed ("
                       << e.what()
                       << ") — stage 2 runs the full refinement alone";
        } catch (...) {
          stage1_state = "failed";
          stage1_rounds = 0;
          LOG(WARNING) << "[aether_sfm] finalize stage-1 refine failed — "
                          "stage 2 runs the full refinement alone";
        }
        stage1_ms = NowMs() - t_s1;
        cache_pre.reset();  // free the snapshot before stage 2 loads its own
#if defined(__APPLE__)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
      }
      enrich.join();
      // Stage 2 completes the round budget: baseline runs gref(=5) rounds
      // total; stage 2 runs the remainder (floor 1 — the enriched graph's new
      // pairs always get at least Retriangulate/CompleteAndMergeTracks + one
      // Cauchy BA round + FilterPoints/FilterFrames). Without this cap the
      // per-round merge/filter churn re-burns all 5 rounds in stage 2 and the
      // parallel window buys nothing (measured cap42: 48.4 s ≈ serial 48.5 s).
      if (stage1_rounds > 0) {
        popts->ba_global_max_refinements =
            std::max(1, popts->ba_global_max_refinements - stage1_rounds);
      }
    } else {
      // Resume/degenerate path: the LOCAL model is published — refine a copy.
      refined = std::make_shared<colmap::Reconstruction>(*model);
    }
    // Stage 2 / main refinement over the (enriched) db — unchanged semantics:
    // IterativeGlobalRefinement + FilterFrames + UpdatePoint3DErrors.
    const double t_s2 = NowMs();
    auto manager = std::make_shared<colmap::ReconstructionManager>();
    colmap::IncrementalPipeline pipeline(
        popts, colmap::Database::Open(s->db_path), manager);
    pipeline.RefineReconstruction(refined);
    const double stage2_ms = NowMs() - t_s2;
    const double t_td = NowMs();
    RestoreTemporalDetail(s, refined.get());
    LOG(WARNING) << "[aether_sfm] finalize worker: cache_pre="
                 << static_cast<int64_t>(cache_pre_ms)
                 << "ms enrich=" << static_cast<int64_t>(enrich_ms)
                 << "ms stage1=" << static_cast<int64_t>(stage1_ms) << "ms ("
                 << stage1_state << ", rounds=" << stage1_rounds
                 << ") stage2=" << static_cast<int64_t>(stage2_ms)
                 << "ms (rounds<=" << popts->ba_global_max_refinements
                 << ") temporal=" << static_cast<int64_t>(NowMs() - t_td)
                 << "ms total=" << static_cast<int64_t>(NowMs() - t0) << "ms";
    {
      std::lock_guard<std::mutex> lk(s->recon_mutex);
      s->recon = refined;
      s->refine_ms = NowMs() - t0;
    }
    s->finalize_status.store(2);  // AETHER_SFM_FINALIZE_REFINED
  } catch (const std::exception& e) {
    RefineFallbackFullRerun(s, e.what());
  } catch (...) {
    RefineFallbackFullRerun(s, "unknown exception");
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
    // [FINALIZE-ZEROCOPY 2026-07-11] The live recon lives behind a shared_ptr
    // (see the session struct comment); allocate it up front so every gated
    // use can rely on non-null while live_recon_ready flags actual readiness.
    s->live_recon = std::make_shared<colmap::Reconstruction>();
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

// Shared core of aether_sfm_add_frame (extraction upstream) and
// aether_sfm_add_frame_features (features injected — host replay/verification
// of the streaming path from a pulled sfm_live.db). Everything from the shared
// camera write onward is identical between the two entries; extract_ms is the
// caller-measured extraction time (0 for injected features).
static aether_sfm_result_t AddFrameFeaturesImpl(
    aether_sfm_session_t* s, const float* xy, const uint8_t* desc, int n,
    int width, int height, float fx, float fy, float cx, float cy,
    const double pose_qwxyz[4], const double pose_t[3], double extract_ms,
    int* out_frame_id) {
  try {
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
      if (s->live_recon) {
        s->live_recon->AddCameraWithTrivialRig(s->camera);
        s->live_recon_ready = true;
      }
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
    std::memcpy(descriptors.data.data(), desc,
                static_cast<size_t>(n) * 128);
    s->db->WriteKeypoints(image_id, kps);
    s->db->WriteDescriptors(image_id, descriptors);

    FrameRecord rec;
    rec.frame_id = frame_id;
    rec.image_id = image_id;
    rec.n_keypoints = n;
    rec.descriptors.assign(desc, desc + static_cast<size_t>(n) * 128);
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
      s->live_recon->AddImageWithTrivialFrame(std::move(rimg), rec.cam_from_world);
      s->reg_order.push_back(image_id);
    }

    // 4) Match against k_neighbors candidate frames (CPU brute-force,
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
    //    [SPATIAL-FIRST 2026-07-11] Candidates are now SPATIAL-first (ARKit
    //    camera-center K-NN ∩ view-angle < 45°), temporal-filled to K, with a
    //    pure-temporal fallback when the frame has no usable pose — see
    //    SelectStreamCandidates. Budget unchanged: at most K pairs matched.
    const int k = s->options.k_neighbors > 0 ? s->options.k_neighbors : 6;
    int cand_spatial = 0, cand_temporal = 0;
    const std::vector<int> candidates = SelectStreamCandidates(
        *s, rec, frame_id, k, &cand_spatial, &cand_temporal);
    s->stat_cand_spatial_first_pairs += cand_spatial;
    s->stat_cand_temporal_fallback_pairs += cand_temporal;
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
    // [MERGE-GATE 2026-07-11] OFF = COLMAP-parity merge gating (COLMAP's merge
    // has no disjoint-images requirement; the union-refit reproj gate in
    // CanMergeLivePoints subsumes the safety concern). Host attribution on the
    // cap47 db replay: shared-image rejections 250 vs 12,892 midpoint-reproj
    // rejections — the real starvation was the midpoint test, fixed by the
    // union refit; disjoint-off recovers the remaining legitimate fragments.
    constexpr bool kMergeRequireDisjointImages = false;
    const bool gpu_match_avail =
        s->options.use_gpu_match && (aether_gpu_match_gemm_pairs != nullptr);
    std::unordered_set<PointIdPair, PointIdPairHash> merge_trials;
    for (const int j : candidates) {
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
        if (mrc != 0) {
          // [MATCH-FAIL TELEMETRY 2026-07-11] Same fail-closed skip as before
          // (no CPU fallback on device — a Metal failure used to stall the
          // queue for minutes), but no longer SILENT: rc-bucketed counters +
          // segment warning make a thermal matcher collapse visible, and the
          // finalize re-match pass repairs the db afterwards.
          NoteGpuMatchFailure(s, mrc);
          continue;
        }
        s->gpu_match_fail_streak = 0;  // healthy pair ends a failure segment
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
          const colmap::Point2D& o1 = s->live_recon->Image(prev.image_id).Point2D(i1);
          const colmap::Point2D& o2 = s->live_recon->Image(image_id).Point2D(i2);
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
              Eigen::Vector3d refit_xyz;
              const MergeReject verdict = CanMergeLivePoints(
                  *s->live_recon, s->camera, key.a, key.b, kMaxMergeReprojPx,
                  kMergeRequireDisjointImages, &refit_xyz);
              if (verdict == MergeReject::kNone) {
                const colmap::point3D_t merged =
                    s->live_recon->MergePoints3D(key.a, key.b);
                // Install the union refit (the position the gate validated),
                // not MergePoints3D's length-weighted average of two noisy
                // low-parallax estimates. The windowed BA below refines it
                // further (merged is in `touched`), and the post-BA reproj/
                // tri-angle filters police it like any other point.
                s->live_recon->Point3D(merged).xyz = refit_xyz;
                touched.erase(key.a);
                touched.erase(key.b);
                touched.insert(merged);
                ++s->stat_merge_accepted;
              } else {
                ++s->stat_merge_rejected;
                switch (verdict) {
                  case MergeReject::kSharedImage:
                    ++s->stat_merge_reject_shared_image;
                    break;
                  case MergeReject::kReproj:
                    ++s->stat_merge_reject_reproj;
                    break;
                  default:
                    ++s->stat_merge_reject_missing;
                    break;
                }
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
            const Eigen::Vector3d Xg = gcfw * s->live_recon->Point3D(pid).xyz;
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
            s->live_recon->AddObservation(pid, colmap::TrackElement(gimg, gidx));
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
              s->live_recon->AddPoint3D(X_world, std::move(track), Eigen::Vector3ub::Zero());
          touched.insert(pid);
        }
      }
    }

    // ── Windowed local bundle adjustment (Cauchy) over the last W frames ──
    // Refines the window's poses+points each frame. Older structure is held
    // constant automatically (a Point3D whose track extends beyond the window is
    // fixed → anchors the window, bounds drift). Bounded ceres iters keep it in
    // the ~2s/frame budget.
    if (rec.has_pose && s->live_recon_ready && s->live_recon->NumRegImages() >= 3 &&
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
        if (s->live_recon->Point3D(pid).track.Length() <= 15)
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
            colmap::CreateDefaultBundleAdjuster(ba_options, ba_config, *s->live_recon);
        ba->Solve();
        // ── Floater cleanup on the refined window (COLMAP-standard) ──
        // Runs at the BA cadence (already gated by ba_every_n). Deletes negative-
        // depth observations + high-reproj points among those touched this frame;
        // ExistsPoint3D-guarded internally (observation_manager.cc:377), so ids
        // already removed by the negative-depth pass are skipped, not dereferenced.
        // The recon's Point2D links are reset on delete, so the match-loop queries
        // above stay correct — no obs map to invalidate.
        colmap::ObservationManager obs_mgr(*s->live_recon);
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
    if (s->live_recon) {
      std::vector<Eigen::Vector3d> snap;
      snap.reserve(s->live_recon->NumPoints3D());
      for (const auto& [pid, pt] : s->live_recon->Points3D()) snap.push_back(pt.xyz);
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
  // ARKit camera axes (+X right, +Y up, -Z forward). Consumed by the impl to
  // build the throwaway live-preview cloud only; the authoritative finalize
  // still self-estimates CamFromWorld (this prior does NOT feed the v1 solve).
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

    return AddFrameFeaturesImpl(s, xy.data(), desc.data(), n, width, height,
                                fx, fy, cx, cy, pose_qwxyz, pose_t, extract_ms,
                                out_frame_id);
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_INTERNAL;
  }
}

// Feature-injection sibling of aether_sfm_add_frame: skips extraction and
// feeds precomputed keypoints (xy, +0.5 half-pixel convention, same as the
// extractor output) + 128-d UBC RootSIFT u8 descriptors straight into the
// shared streaming core. Purpose-built for HOST replay of a device capture
// (keypoints/descriptors read back from a pulled sfm_live.db + the fed ARKit
// poses) so streaming-path changes are verifiable off-device against real
// captures. Production apps keep calling aether_sfm_add_frame.
aether_sfm_result_t aether_sfm_add_frame_features(
    aether_sfm_session_t* s, const float* xy, const uint8_t* desc,
    int n_keypoints, int width, int height, float fx, float fy, float cx,
    float cy, const double pose_qwxyz[4], const double pose_t[3],
    int* out_frame_id) {
  if (!s || !s->db || !xy || !desc || n_keypoints <= 0 || width <= 0 ||
      height <= 0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  return AddFrameFeaturesImpl(s, xy, desc, n_keypoints, width, height, fx, fy,
                              cx, cy, pose_qwxyz, pose_t, /*extract_ms=*/0.0,
                              out_frame_id);
}

aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s, char* out_json,
                                        int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    RebuildFrameRecordsForResume(s);  // no-op unless frames empty (resume)
    AddSpatialRevisitMatches(s);
    FinalizeRematchStarvedFrames(s);  // repair thermal GPU-match gaps
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

// Two-phase async finalize. Phase 1 (this call, now milliseconds on the live
// path): hand the capture-time live local-BA reconstruction to the refine
// worker (status = LOCAL_READY). Phase 2 (background worker): finish-time db
// enrichment (GPU) in parallel with a stage-1 refinement (CPU), then the
// stage-2 Cauchy global BA + track completion over the enriched db; the
// refined model is published into *recon (status = REFINED). On the live path
// the getters serve nothing until REFINED (LOCAL is unpublished by sign-off);
// on the resume path they serve the LOCAL model under the mutex as before.
//
// [S3.5 RESTORE 2026-07-11] The live streaming reconstruction IS the phase-1
// result; finalize adds only the global refinement. Historically phase 1
// re-ran the FULL IncrementalPipeline from the db (RunIncremental local_only)
// because async finalize (2026-06-22, 5f7350ba) predates the live local-BA
// recon (2026-07-09, 74d5f477) and was never rewired — on device that full
// re-run alone cost 112-154 s (captures 42/43) and re-computed registrations
// the live path already held in memory, occasionally SPLITTING the capture
// into n_models=2 and dropping every frame of the smaller model (capture 43:
// 96/128 vs live 128/128). Reusing the live recon:
//   - phase 1 becomes a shared_ptr MOVE (instant; [FINALIZE-ZEROCOPY] — the
//     original S3.5 cut deep-copied here and again in the worker, +17%/+11%
//     peak RSS on the host 42/43 A/B) — no duplicate reconstruction;
//   - the model keeps ARKit-world gravity alignment + metric scale, and one
//     connected model (pose-registered, never split by match topology);
//   - the finalize-written db pairs (AddSpatialRevisitMatches +
//     FinalizeRematchStarvedFrames) are consumed INCREMENTALLY by phase 2:
//     RefineReconstruction's IterativeGlobalRefinement runs
//     CompleteAndMergeTracks + Retriangulate over the enriched correspondence
//     graph (track extension + new triangulations from the new pairs) before
//     and between the Cauchy global BA rounds, and RestoreTemporalDetail
//     consumes the re-matched temporal-window TVGs afterwards — nothing about
//     phase 2 changed, it always worked this way on the phase-1 model.
// RESUME sessions (launch-time "有db无PLY" recovery: no in-memory live recon)
// keep the validated db-driven full re-run below — unchanged semantics.
aether_sfm_result_t aether_sfm_finalize_async(aether_sfm_session_t* s,
                                              char* out_json, int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  if (s->refine_thread.joinable()) s->refine_thread.join();  // drain prior run
  try {
    const double t_enter = NowMs();
    RebuildFrameRecordsForResume(s);  // no-op unless frames empty (resume)

    // ── Normal completion path: live recon in memory → reuse it. ──
    // Guard: a degenerate live recon (<2 registered frames / 0 points — e.g.
    // ARKit poses never arrived) falls through to the db-driven re-run so the
    // "采集必出点云" guarantee keeps its full-strength fallback.
    //
    // [FINALIZE-ZEROCOPY + FINALIZE-OVERLAP 2026-07-11] Three changes vs the
    // first S3.5 cut, all grounded on the host 42/43 A/B (RSS +17%/+11%, the
    // 17-40 s GPU enrichment serial in front of the 30-47 s CPU phase 2):
    //   1. The live recon is MOVED into the worker (shared_ptr transfer), not
    //      deep-copied — and phase 2 refines it IN PLACE. Zero extra copies.
    //   2. NOTHING is published at LOCAL_READY on this path (user signed off:
    //      the LOCAL model is never displayed; the Dart worker only reads the
    //      getters after REFINED). get_points/get_poses between LOCAL_READY
    //      and REFINED now return AETHER_SFM_ERR_NOT_REGISTERED here.
    //   3. The finish-time db enrichment (spatial revisit + starved re-match,
    //      GPU) moved INTO the worker, where it runs in parallel with the
    //      stage-1 CPU refinement — see RefineGlobalBA. This call therefore
    //      returns in milliseconds. Consequence: stream-stats read right
    //      after this call no longer include the enrichment counters (they
    //      are logged natively by the worker instead).
    // The resume path (no in-memory live recon) below keeps the old serial
    // enrichment + db-driven re-run + published LOCAL model, unchanged.
    if (s->live_recon_ready && s->live_recon &&
        s->live_recon->NumRegImages() >= 2 &&
        s->live_recon->NumPoints3D() > 0) {
      std::shared_ptr<colmap::Reconstruction> work = std::move(s->live_recon);
      s->live_recon.reset();          // moved-from shared_ptr is null already; be explicit
      s->live_recon_ready = false;    // live getters now gate off
      work->UpdatePoint3DErrors();    // live path fills errors lazily
      if (out_json && out_cap > 0) {
        std::snprintf(
            out_json, out_cap,
            "{\"solve_ms\":%.1f,\"n_models\":1,\"n_registered\":%zu,"
            "\"n_points3d\":%zu,\"reproj_px\":%.4f,\"track_len\":%.3f,"
            "\"phase1\":\"live_reuse\"}",
            NowMs() - t_enter, work->NumRegImages(), work->NumPoints3D(),
            work->ComputeMeanReprojectionError(),
            work->ComputeMeanTrackLength());
      }
      {
        std::lock_guard<std::mutex> lk(s->recon_mutex);
        s->recon_manager.reset();  // no mapper manager on this path
        s->recon.reset();          // LOCAL model intentionally unpublished
      }
      s->finalize_status.store(1);  // LOCAL_READY (worker refining)
      s->refine_thread =
          std::thread(RefineGlobalBA, s, std::move(work), /*live_reuse=*/true);
      return AETHER_SFM_OK;
    }

    // ── Resume / degenerate path: serial enrichment + db-driven full re-run
    // (unchanged semantics). ──
    AddSpatialRevisitMatches(s);
    FinalizeRematchStarvedFrames(s);  // repair thermal GPU-match gaps
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
    // The worker's resume arm deep-copies before refining (LOCAL published).
    s->refine_thread =
        std::thread(RefineGlobalBA, s,
                    std::const_pointer_cast<colmap::Reconstruction>(local),
                    /*live_reuse=*/false);
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
  if (!s->live_recon_ready || !s->live_recon) {
    return AETHER_SFM_ERR_NOT_REGISTERED;
  }
  const colmap::Reconstruction& recon = *s->live_recon;
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

// Legacy experimental one-shot GLOBAL BA over the streaming live_recon-> This is
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
  if (!s->live_recon_ready || !s->live_recon ||
      s->live_recon->NumRegImages() < 3)
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
    ranked.reserve(s->live_recon->NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon->Points3D())
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
    colmap::CreateDefaultBundleAdjuster(opt1, cfg1, *s->live_recon)->Solve();

    // ---- STAGE 2: structure-only refit, ALL points, POSES FIXED -------------
    // Stage 1 moved the poses; every point NOT in the capped subset is now stale
    // (it was triangulated under the old drifted poses). With poses held CONSTANT
    // the per-point problems are separable — Ceres solves millions of tiny 3-DOF
    // fits in one linear-cost pass — so this refits the WHOLE cloud onto the
    // corrected geometry cheaply, regardless of point count. (No gauge fix
    // needed: fixed poses already pin the gauge.)
    colmap::BundleAdjustmentConfig cfg2;
    for (const colmap::image_t img_id : s->reg_order) cfg2.AddImage(img_id);
    for (const auto& [pid, pt] : s->live_recon->Points3D())
      cfg2.AddVariablePoint(pid);

    colmap::BundleAdjustmentOptions opt2 = opt1;
    opt2.refine_rig_from_world = false;  // poses FROZEN → structure-only, fast
    opt2.ceres->solver_options.max_num_iterations = 10;
    colmap::CreateDefaultBundleAdjuster(opt2, cfg2, *s->live_recon)->Solve();

    // Global floater cleanup (all points now, not just a window's touched set).
    colmap::ObservationManager obs_mgr(*s->live_recon);
    obs_mgr.FilterObservationsWithNegativeDepth();
    std::unordered_set<colmap::point3D_t> all_pts;
    all_pts.reserve(s->live_recon->NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon->Points3D()) all_pts.insert(pid);
    obs_mgr.FilterPoints3DWithLargeReprojectionError(/*max_error=*/4.0, all_pts);
    obs_mgr.FilterPoints3DWithSmallTriangulationAngle(/*min_tri_angle_deg=*/2.0,
                                                      all_pts);

    // Republish the collapsed cloud into preview_points.
    std::vector<Eigen::Vector3d> snap;
    snap.reserve(s->live_recon->NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon->Points3D()) snap.push_back(pt.xyz);
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

// Live-recon quality snapshot + merge-gate reject reasons. Additive diagnostic
// sibling of aether_sfm_stream_stats — same threading contract (call from the
// add_frame worker thread; the live recon is single-writer). mean_reproj_px is
// computed directly over every (point, observation) pair with the recon's own
// (possibly BA-refined) camera, NOT from Point3D::error (never populated on
// the live path).
void aether_sfm_live_diag(aether_sfm_session_t* s, double* mean_reproj_px,
                          int64_t* n_points, int64_t* n_track3plus,
                          int64_t* n_obs, int64_t* merge_reject_shared_image,
                          int64_t* merge_reject_reproj,
                          int64_t* merge_reject_missing) {
  if (!s) return;
  if (merge_reject_shared_image)
    *merge_reject_shared_image = s->stat_merge_reject_shared_image;
  if (merge_reject_reproj) *merge_reject_reproj = s->stat_merge_reject_reproj;
  if (merge_reject_missing)
    *merge_reject_missing = s->stat_merge_reject_missing;
  int64_t pts = 0, track3 = 0, obs = 0;
  double err_sum = 0.0;
  int64_t err_n = 0;
  // [FINALIZE-ZEROCOPY 2026-07-11] finalize_async moves the live recon into
  // the refine worker; after that this diagnostic reports zeros.
  if (!s->live_recon) {
    if (n_points) *n_points = 0;
    if (n_track3plus) *n_track3plus = 0;
    if (n_obs) *n_obs = 0;
    if (mean_reproj_px) *mean_reproj_px = 0.0;
    return;
  }
  try {
    for (const auto& [pid, pt] : s->live_recon->Points3D()) {
      ++pts;
      const size_t len = pt.track.Length();
      obs += static_cast<int64_t>(len);
      if (len >= 3) ++track3;
      for (const auto& el : pt.track.Elements()) {
        if (!s->live_recon->ExistsImage(el.image_id)) continue;
        const colmap::Image& image = s->live_recon->Image(el.image_id);
        if (!image.HasPose() || el.point2D_idx >= image.NumPoints2D()) continue;
        const Eigen::Vector3d x_cam = image.CamFromWorld() * pt.xyz;
        if (x_cam.z() <= 0.0) continue;
        const colmap::Camera* cam = image.CameraPtr();
        if (!cam) continue;
        const std::optional<Eigen::Vector2d> px = cam->ImgFromCam(x_cam);
        if (!px) continue;
        err_sum += (*px - image.Point2D(el.point2D_idx).xy).norm();
        ++err_n;
      }
    }
  } catch (const std::exception&) {
    // Diagnostic only — never throw across the ABI.
  }
  if (n_points) *n_points = pts;
  if (n_track3plus) *n_track3plus = track3;
  if (n_obs) *n_obs = obs;
  if (mean_reproj_px) *mean_reproj_px = err_n > 0 ? err_sum / err_n : 0.0;
}

// [SPATIAL-FIRST 2026-07-11] Capture-time candidate-selection attribution.
// spatial_first_pairs = candidates chosen by the spatial K-NN ∩ view-angle
// rule; temporal_fallback_pairs = candidates from the temporal fill (spatial
// set short) or the full no-pose fallback. Sum = total pairs attempted by
// add_frame over the capture. Same threading contract as
// aether_sfm_stream_stats. Nullable; zero before the first add_frame.
void aether_sfm_candidate_stats(aether_sfm_session_t* s,
                                int64_t* spatial_first_pairs,
                                int64_t* temporal_fallback_pairs) {
  if (!s) return;
  if (spatial_first_pairs)
    *spatial_first_pairs = s->stat_cand_spatial_first_pairs;
  if (temporal_fallback_pairs)
    *temporal_fallback_pairs = s->stat_cand_temporal_fallback_pairs;
}

// [MATCH-FAIL TELEMETRY + FINALIZE-REMATCH 2026-07-11] Capture-time GPU
// matcher failure accounting + the finalize starved-frame re-match counters.
// Additive diagnostic sibling of aether_sfm_stream_stats (same threading
// contract). gpu_fail_by_rc, if non-null, receives 8 int64 buckets indexed by
// the pwsfm_gpu_match.mm return code (bucket 0 = out-of-range rc). Nullable.
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
  if (!s) return;
  if (gpu_fail_total) *gpu_fail_total = s->stat_gpu_match_fail_total;
  if (gpu_fail_by_rc) {
    for (int i = 0; i < 8; ++i) gpu_fail_by_rc[i] = s->stat_gpu_match_fail_by_rc[i];
  }
  if (gpu_fail_max_streak)
    *gpu_fail_max_streak = s->stat_gpu_match_fail_max_streak;
  if (rematch_starved_frames)
    *rematch_starved_frames = s->stat_finalize_rematch_starved_frames;
  if (rematch_candidates)
    *rematch_candidates = s->stat_finalize_rematch_candidates;
  if (rematch_attempted)
    *rematch_attempted = s->stat_finalize_rematch_attempted;
  if (rematch_written) *rematch_written = s->stat_finalize_rematch_written;
  if (rematch_inliers) *rematch_inliers = s->stat_finalize_rematch_inliers;
  if (rematch_failed) *rematch_failed = s->stat_finalize_rematch_failed;
}

// Finalize-output quality snapshot: the aether_sfm_live_diag fields computed
// over the CURRENT finalize reconstruction (LOCAL or REFINED — whichever the
// getters serve). mean_reproj_px is computed over every observation with the
// recon's own (BA-refined) camera. Zeros before finalize.
void aether_sfm_final_diag(aether_sfm_session_t* s, double* mean_reproj_px,
                           int64_t* n_points, int64_t* n_track3plus,
                           int64_t* n_obs) {
  if (mean_reproj_px) *mean_reproj_px = 0.0;
  if (n_points) *n_points = 0;
  if (n_track3plus) *n_track3plus = 0;
  if (n_obs) *n_obs = 0;
  if (!s) return;
  std::shared_ptr<const colmap::Reconstruction> recon;
  {
    std::lock_guard<std::mutex> lk(s->recon_mutex);
    recon = s->recon;  // stable snapshot; survives the async LOCAL→REFINED swap
  }
  if (!recon) return;
  int64_t pts = 0, track3 = 0, obs = 0;
  double err_sum = 0.0;
  int64_t err_n = 0;
  try {
    for (const auto& [pid, pt] : recon->Points3D()) {
      ++pts;
      const size_t len = pt.track.Length();
      obs += static_cast<int64_t>(len);
      if (len >= 3) ++track3;
      for (const auto& el : pt.track.Elements()) {
        if (!recon->ExistsImage(el.image_id)) continue;
        const colmap::Image& image = recon->Image(el.image_id);
        if (!image.HasPose() || el.point2D_idx >= image.NumPoints2D()) continue;
        const Eigen::Vector3d x_cam = image.CamFromWorld() * pt.xyz;
        if (x_cam.z() <= 0.0) continue;
        const colmap::Camera* cam = image.CameraPtr();
        if (!cam) continue;
        const std::optional<Eigen::Vector2d> px = cam->ImgFromCam(x_cam);
        if (!px) continue;
        err_sum += (*px - image.Point2D(el.point2D_idx).xy).norm();
        ++err_n;
      }
    }
  } catch (const std::exception&) {
    // Diagnostic only — never throw across the ABI.
  }
  if (n_points) *n_points = pts;
  if (n_track3plus) *n_track3plus = track3;
  if (n_obs) *n_obs = obs;
  if (mean_reproj_px) *mean_reproj_px = err_n > 0 ? err_sum / err_n : 0.0;
}

aether_sfm_result_t aether_sfm_debug_dump_model(aether_sfm_session_t* s,
                                                const char* dir) {
  // [AETHER BA-MIXED A/B 2026-07-11] Debug/bench-only: write the current
  // authoritative reconstruction as a COLMAP binary model
  // (cameras.bin/images.bin/points3D.bin) so host A/B harnesses can score it
  // with the pycolmap 9-gate scorer verbatim. Never called by the app.
  if (!s || !dir || !dir[0]) return AETHER_SFM_ERR_INVALID_ARG;
  std::shared_ptr<const colmap::Reconstruction> recon;
  {
    std::lock_guard<std::mutex> lk(s->recon_mutex);
    recon = s->recon;
  }
  if (!recon) return AETHER_SFM_ERR_INTERNAL;
  try {
    std::filesystem::create_directories(dir);
    recon->Write(dir);
    return AETHER_SFM_OK;
  } catch (const std::exception& e) {
    LOG(WARNING) << "[aether_sfm] debug_dump_model failed: " << e.what();
    return AETHER_SFM_ERR_INTERNAL;
  }
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
