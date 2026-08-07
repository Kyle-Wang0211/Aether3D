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
#include "arkit_pose_store_v1.h"
#include "mandatory_arkit_gravity_v1.h"
#include "mandatory_gravity_tvg_v1.h"
#include "pair_policy_v2_c.h"
#include "pair_selection_v2.h"
#include "visual_loop_index_v1.h"
#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1
#include "official_isolated_floater.h"
#include "official_mirror_ghost.h"
#include "official_preclamp_instr_v1.h"

#ifndef AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
#define AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1 1
#endif

#define AETHER_GPU_TIMESTAMP_INTERNAL
#define AETHER_GPU_TIMESTAMP_WEAK_IMPORT __attribute__((weak_import))
#include "official_gpu_timestamp_writer_v1.h"
#undef AETHER_GPU_TIMESTAMP_WEAK_IMPORT
#undef AETHER_GPU_TIMESTAMP_INTERNAL

#include "colmap/controllers/incremental_pipeline.h"
#include "colmap/estimators/two_view_geometry.h"
#include "colmap/feature/types.h"
#include "colmap/feature/utils.h"
#include "colmap/geometry/essential_matrix.h"
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
#include <fstream>
#include <functional>
#include <limits>
#include <memory>
#include <condition_variable>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>
#include <deque>
#include <utility>
#include <vector>

// [GHOST-MASK 2026-07-12] Per-point ghost-layer display-mask pass (header-only,
// self-contained; parity-gated against the Python Phase0 reference).
#include "aether_ghost_mask.h"
#if __has_include("aether/sfm/tail_cache_epoch_v1.h")
#include "aether/sfm/tail_cache_epoch_v1.h"
#else
#include "../../include/aether/sfm/tail_cache_epoch_v1.h"
#endif
// [L1-PLAN/ARBITRATE 2026-07-12] Ghost-layer L1 CasDiffMVS arbitration:
// budgeted "按面积挑" keyframe plan (written at finalize tail alongside the
// mask when OFFICIAL_AETHER_GHOST_MASK=1) + the file-driven 1-bit arbitration ABI
// (aether_sfm_arbitrate) consuming the per-ref depth bins the platform
// runner writes. Header-only, shared verbatim with the Mac E2E harness.
#include "aether_l1_arbitrate.h"
#include "aether_l1_plan.h"

// [GPU-HANG-B1 2026-08-06 二期件2] Chromium 式 watchdog 线程(framework worker
// 总巡逻员;纯 std 单头文件,机制见 official_gpu_watchdog_v1.h)。session 持有
// 实例;add_frame 入口 Arm/出口 Disarm,extract/match 与 finalize stage 边界
// InProgress 打点;判死只落 jsonl(type:"watchdog_hang")+ 原子标志——一期
// 纯观测,不杀线程不杀进程不改任何行为。
#include "official_gpu_watchdog_v1.h"

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
// [SCALE-PERSIST 2026-08-06] _v2 siblings: identical contract plus optional
// per-keypoint detection scale/orientation outputs (either may be NULL; NULL
// reproduces v1 byte-for-byte — the v1 symbols are wrappers over _v2). The
// CPU _v2 is a STRONG ref like the v1 above (official_dsp_sift_c.cc lives in
// this same target); the GPU _v2 is WEAK like its v1 sibling, so host benches
// and older platform archives resolve it to nullptr and add_frame falls back
// (old symbol + no scales → unit affine, i.e. the pre-change behaviour).
extern "C" int aether_dsp_sift_extract_v2(const uint8_t* gray, int width,
                                          int height, int max_features,
                                          float* out_xy, uint8_t* out_desc,
                                          float* out_scales,
                                          float* out_orientations, int out_cap,
                                          int* out_count);
extern "C" __attribute__((weak)) int aether_dsp_sift_extract_gpu_v2(
    const uint8_t* gray, int width, int height, int max_features,
    int num_threads, float* out_xy, uint8_t* out_desc, float* out_scales,
    float* out_orientations, int out_cap, int* out_count);
// [AETHER-T-EXTRACT 2026-07-27] Per-stage extract durations (9 stages, see
// sift_extract_dawn.cc) — WEAK like the extractor itself; the A6
// descriptor-batching knife is sized from this split.
extern "C" __attribute__((weak)) void aether_sed_last_stages(double* out,
                                                             int cap);
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
// pwofficial_gpu_match.mm — simdgroup_matrix Metal, mutual cross-check INSIDE,
// bench-proven 11568x11568 @ 119 ms on A16). WEAK for the same reason as
// aether_dsp_sift_extract_gpu: host benches / non-Metal targets resolve it to
// nullptr and add_frame stays on the CPU matcher. Selected via
// options.use_gpu_match; any non-zero return skips that pair on device. Host
// benches without the weak symbol still use the CPU matcher.
extern "C" __attribute__((weak)) int aether_gpu_match_gemm_pairs(
    const uint8_t* desc1, int n1, const uint8_t* desc2, int n2,
    double max_ratio, uint32_t* out_pairs, int max_pairs,
    int* out_num_matches);
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
// Optional exact descriptor-residency sibling. Runtime keys are explicit and
// never derived from host pointers. Older platform TUs omit this weak symbol
// and retain the existing upload-per-call route.
extern "C" __attribute__((weak)) int aether_gpu_match_gemm_pairs_resident(
    uint64_t session_nonce, uint32_t frame1, uint32_t generation1,
    const uint8_t* desc1, int n1, uint32_t frame2, uint32_t generation2,
    const uint8_t* desc2, int n2, double max_ratio, uint32_t* out_pairs,
    int max_pairs, int* out_num_matches);
extern "C" __attribute__((weak)) void
aether_gpu_match_descriptor_residency_invalidate(uint64_t session_nonce,
                                                  uint32_t frame_ordinal);
extern "C" __attribute__((weak)) void
aether_gpu_match_descriptor_residency_clear_session(uint64_t session_nonce);
extern "C" __attribute__((weak)) int
aether_gpu_match_descriptor_residency_stats(
    uint64_t session_nonce, uint64_t* hits, uint64_t* misses,
    uint64_t* evictions, uint64_t* stale_replacements,
    uint64_t* upload_bytes, uint64_t* resident_bytes,
    uint64_t* resident_entries, uint64_t* allocation_failures,
    uint64_t* device_resets);
#endif
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
// [RC7-FILELOG 2026-07-11] Last Metal command-buffer error description
// (pwofficial_gpu_match.mm stashes it when it returns rc=7). WEAK for the same
// reason as the matcher symbols: host CPU benches resolve it to nullptr and
// the rc=7 jsonl line simply omits the Metal error text. Returns the number
// of bytes written (0 = no error recorded yet).
// [AETHER-T1 2026-07-26] Pure-observation timing globals accumulated inside
// the vendored IncrementalMapper::IterativeGlobalRefinement (see
// colmap-src/colmap/sfm/incremental_mapper.cc). The finalize wrapper zeroes
// them before the refinement it wants attributed and reads them after.
extern "C" double aether_igr_pre_ms;
extern "C" double aether_igr_ba_ms;
extern "C" double aether_igr_merge_ms;
extern "C" int aether_igr_rounds;
// [AETHER-T2 2026-07-29] Same contract, capture-time LOCAL path. Zeroed per
// frame right before IterativeLocalRefinement and drained into the frame_split
// jsonl record — the streaming local BA is 56.5% of stream cost and its
// internal split was never measured.
extern "C" double aether_ilr_find_ms;
extern "C" double aether_ilr_setup_ms;
extern "C" double aether_ilr_solve_ms;
extern "C" double aether_ilr_merge_ms;
extern "C" double aether_ilr_filter_ms;
extern "C" double aether_ilr_preproc_ms;
extern "C" double aether_ilr_minim_ms;
extern "C" double aether_ilr_postproc_ms;
extern "C" int aether_ilr_rounds;
extern "C" int aether_ilr_solves;
extern "C" int aether_ilr_iters;
extern "C" int aether_ilr_term_conv;
extern "C" int aether_ilr_term_nocnv;
extern "C" int aether_ilr_term_other;
extern "C" int aether_ilr_bundle_trace_calls;
extern "C" uint32_t aether_ilr_bundle_trace_query[16];
extern "C" int aether_ilr_bundle_trace_neighbor_count[16];
extern "C" int aether_ilr_bundle_trace_neighbor_total[16];
extern "C" uint32_t aether_ilr_bundle_trace_neighbors[16][15];
// [AETHER BA-RING 2026-07-26] Per-solve ceres Summary ring (defined in
// official_bundle_adjustment_ceres.cc): reset before an attributed block,
// drained into a ba_rounds jsonl record after.
extern "C" void aether_ba_ring_reset(void);
extern "C" int aether_ba_ring_count(void);
extern "C" int aether_ba_ring_get(int i, double* total_s, double* jac_s,
                                  double* lin_s, double* res_s, int* iters,
                                  int* term, int* threads);
extern "C" int aether_ba_set_gravity_prior(const char* name,
                                            const double* gravity_cam_xyz,
                                            double sigma_rad);
extern "C" void aether_ba_clear_gravity_priors();

extern "C" __attribute__((weak)) int aether_gpu_match_last_error(char* buf,
                                                                 int cap);

// [MIGRATION 4.0.4 / STEP 5] The glomap::RetriangulateTracks linker stub was
// removed together with GLOMAP. It existed only to satisfy -force_load of
// libglomap_core.a (global_mapper.cc.o referenced the symbol). With GLOMAP no
// longer compiled into glomap_core there is no such reference, so the stub is
// dead. The colmap incremental pipeline this wrapper drives never used it.

// [AETHER FINALIZE-SEGMENTS 2026-07-11] Telemetry-only accessor defined in
// colmap/estimators/bundle_adjustment_ceres.cc: the observability fields of
// the LAST ceres solve (the "[AETHER] solver_used=" log line's values), so
// the finalize worker can persist them — stderr is lost in detached device
// runs. Requires a libglomap_core.a built from the same source state.
namespace colmap {
void AetherLastBaSolveInfo(std::string* solver_used,
                           std::string* sparse_backend,
                           int* mixed,
                           int* threads,
                           std::string* dense_backend);
}  // namespace colmap

namespace {

// Production contract: the shipping mobile route ends at COLMAP's final global
// BA and official point filtering. The historical PocketWorld repair/detail
// passes remain in this translation unit only for reproducibility of old
// experiments; production must not execute them, even if a stale environment
// variable attempts to re-enable one.
constexpr bool kProductionOfficialEndpointOnly = true;

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
uint64_t NewDescriptorResidencySessionNonce() {
  static std::atomic<uint64_t> next{1};
  uint64_t nonce = next.fetch_add(1, std::memory_order_relaxed);
  if (nonce == 0) nonce = next.fetch_add(1, std::memory_order_relaxed);
  return nonce;
}
#endif

// Per-frame record kept on the session for the streaming surface so we can
// match a new frame against its k_neighbors candidates without re-reading the
// db (candidates are spatial-first — see SelectStreamCandidates).
struct FrameRecord {
  int frame_id = -1;
  colmap::image_t image_id = 0;
  // Immutable DB identity retained even when remove_frame marks image_id=0 to
  // withdraw the frame from all live candidate/reconstruction paths.
  colmap::image_t persisted_image_id = 0;
  uint64_t frame_identity_digest = 0;
  // The official route stores one calibrated PINHOLE camera per captured
  // image. ARKit reports this calibration for the same 12 MP ARFrame as the
  // JPEG, so autofocus-induced changes remain attached to their own image.
  colmap::camera_t camera_id = colmap::kInvalidCameraId;
  colmap::Camera camera;
  int n_keypoints = 0;
  std::vector<uint8_t> descriptors;  // 128 * n_keypoints, RootSIFT
  // Keypoint positions (pixel coords at the fed resolution), kept so the
  // two-view geometry of every new pair can be estimated without a sqlite
  // read-back. ~1.5k pts × 16 B ≈ 24 KB/frame — negligible.
  std::vector<Eigen::Vector2d> points;
  // ARKit CamFromWorld for this frame, ALREADY flipped into COLMAP camera axes
  // (C = diag(1,-1,-1)); used ONLY by the throwaway live-preview triangulation.
  colmap::Rigid3d cam_from_world;
  // Normalized physical-gravity direction in COLMAP camera coordinates.
  Eigen::Vector3d gravity_cam = Eigen::Vector3d::Zero();
  bool has_pose = false;
  // [THERMAL-THROTTLE 2026-07-11] True when this frame was matched against a
  // REDUCED candidate window (thermal serious → live K 12→6, GPU relief for
  // the camera pipeline). FinalizeRematchStarvedFrames treats such frames as
  // starved so the full temporal-K pair topology is restored at finish time
  // (cooler device, no 2 s/frame budget) — delivered quality is unchanged by
  // construction, only capture-time pacing differs.
  bool fed_throttled = false;
};

std::array<double, 3> FrameGravityArray(const FrameRecord& frame) {
  return {frame.gravity_cam.x(), frame.gravity_cam.y(),
          frame.gravity_cam.z()};
}

uint64_t FrameIdentityDigestV1(
    const std::string& name,
    const colmap::Camera& camera,
    const std::vector<Eigen::Vector2d>& points,
    const std::vector<uint8_t>& descriptors) {
  uint64_t hash = UINT64_C(1469598103934665603);
  const auto mix_byte = [&hash](const uint8_t byte) {
    hash ^= byte;
    hash *= UINT64_C(1099511628211);
  };
  const auto mix_u64 = [&mix_byte](const uint64_t value) {
    for (int shift = 0; shift < 64; shift += 8) {
      mix_byte(static_cast<uint8_t>((value >> shift) & 0xff));
    }
  };
  const auto mix_double = [&mix_u64](const double value) {
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    mix_u64(bits);
  };
  for (const char ch : name) mix_byte(static_cast<uint8_t>(ch));
  mix_byte(0);
  mix_u64(static_cast<uint64_t>(camera.model_id));
  mix_u64(camera.width);
  mix_u64(camera.height);
  mix_u64(camera.params.size());
  for (const double value : camera.params) mix_double(value);
  mix_u64(points.size());
  for (const Eigen::Vector2d& point : points) {
    mix_double(point.x());
    mix_double(point.y());
  }
  mix_u64(descriptors.size());
  for (const uint8_t value : descriptors) mix_byte(value);
  return hash == 0 ? 1 : hash;
}

aether::sfm::MandatoryGravityTwoViewResultV1
EstimateMandatoryFrameTwoViewGeometry(
    const FrameRecord& frame1,
    const std::vector<Eigen::Vector2d>& points1,
    const FrameRecord& frame2,
    const std::vector<Eigen::Vector2d>& points2,
    const colmap::FeatureMatches& matches,
    const colmap::TwoViewGeometryOptions& options) {
  if (!frame1.has_pose || !frame2.has_pose) {
    aether::sfm::MandatoryGravityTwoViewResultV1 result;
    result.status =
        aether::sfm::MandatoryGravityTwoViewStatusV1::kInvalidInput;
    result.geometry.config = colmap::TwoViewGeometry::DEGENERATE;
    return result;
  }
  return aether::sfm::EstimateMandatoryGravityTwoViewGeometryV1(
      frame1.camera, points1, FrameGravityArray(frame1), frame2.camera,
      points2, FrameGravityArray(frame2), matches, options);
}

bool MandatoryGravityTvgPersistable(
    const aether::sfm::MandatoryGravityTwoViewResultV1& result) {
  return result.status == aether::sfm::MandatoryGravityTwoViewStatusV1::kValid ||
         result.status == aether::sfm::MandatoryGravityTwoViewStatusV1::kPlanar;
}

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
                              const colmap::Track& track,
                              const Eigen::Vector3d& xyz,
                              double max_reproj_px) {
  for (const auto& el : track.Elements()) {
    if (!recon.ExistsImage(el.image_id)) return false;
    const colmap::Image& image = recon.Image(el.image_id);
    if (!image.HasPose() || el.point2D_idx >= image.NumPoints2D()) return false;
    const colmap::Camera* camera = image.CameraPtr();
    if (!camera) return false;
    const Eigen::Vector3d x_cam = image.CamFromWorld() * xyz;
    if (x_cam.z() <= 0.0) return false;
    const std::optional<Eigen::Vector2d> px = camera->ImgFromCam(x_cam);
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
// [KNIFE-A ③ 2026-07-11] Enrichment-targeting hint: the delivered model's
// 2-view / low-parallax (θ_max < 3°) tracks, snapshotted from the live recon
// BEFORE the finalize enrichment thread starts (the refine worker mutates the
// model concurrently under the overlap schedule, so the enrichment pass must
// never read the model directly). Consumed by AddSpatialRevisitMatches' top-up
// ordering when OFFICIAL_AETHER_ENRICH_TARGETED=1: pairs are ranked by how many of
// these tracks the pair can hand a ≥5°-parallax third observation — the exact
// upgrade the TrackUpgrade pass then banks — instead of by camera-center
// proximity (which is blind to WHY the extra pair is wanted).
struct EnrichTargetHint {
  struct LowTrack {
    Eigen::Vector3d xyz;          // current (pre-refine) triangulated position
    std::vector<int> frame_idxs;  // observing frames (indices into s->frames)
  };
  std::vector<LowTrack> tracks;
  std::vector<std::vector<int32_t>> by_frame;  // frame idx -> track ids
};

MergeReject CanMergeLivePoints(const colmap::Reconstruction& recon,
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
      const colmap::Camera* camera = image.CameraPtr();
      if (!camera) return MergeReject::kMissing;
      const std::optional<Eigen::Vector2d> np =
          camera->CamFromImg(image.Point2D(el.point2D_idx).xy);
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
  const bool ok =
      ReprojectsCleanlyToTrack(recon, p1.track, refit_xyz, max_reproj_px) &&
      ReprojectsCleanlyToTrack(recon, p2.track, refit_xyz, max_reproj_px);
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
  uint64_t descriptor_residency_nonce = 0;

  // Streaming state (NULL for pure-batch sessions until finalize fills recon).
  std::shared_ptr<colmap::Database> db;
  // [TAIL-CACHE-FIRST V1 2026-08-01] Default-off mutable master cache. It is
  // never a DatabaseCache::Create result (that graph is finalized). The epoch
  // policy owns fail-closed identity; this field owns COLMAP objects only.
  std::shared_ptr<colmap::DatabaseCache> tail_cache_master;
  aether::sfm::TailCacheEpochV1 tail_cache_epoch;
  std::unordered_set<colmap::image_pair_t> tail_cache_seen_db_pairs;
  std::mutex tail_cache_mutex;
  std::vector<FrameRecord> frames;
  // [VISUAL-LOOP V1 2026-08-03] Portable P10/L4 retrieval state. This owns
  // only bounded descriptor sketches and candidate scores; exact matching and
  // COLMAP TVG below remain the sole graph-edge authority.
  aether::sfm::PortableVisualLoopIndexV1 visual_loop_index;
  aether_preclamp_instr_v1::SessionRecords preclamp_instr_records;
  // Non-zero once at least one per-image camera has been written. Geometry
  // never reads this ID; each FrameRecord owns the camera for its image.
  colmap::camera_t camera_id = 0;

  // Rough live-preview cloud (throwaway): triangulated during capture from the
  // per-frame matches + ARKit poses. World frame = ARKit world. The finalize
  // pipeline is unchanged and still yields the authoritative model.
  std::vector<Eigen::Vector3d> preview_points;
  std::mutex preview_mutex;  // add_frame writer vs. get_preview_points reader

  // ── Streaming live local-BA preview (replaces the raw-triangulation cloud) ──
  // Incrementally grown Reconstruction: one calibrated camera+trivial rig per
  // image, one registered image per posed frame (ARKit pose), tracks grown from the
  // cross-checked matches, refined by COLMAP's upstream six-image local
  // refinement after each successfully registered frame.
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
  int ba_window = 6;     // COLMAP default: six most-connected local images
  int ba_every_n = 1;    // run the windowed BA every Nth frame (raise under thermal)
  // ── [INCREMENTAL-GLOBAL-BA 2026-07-13] Rolling capture-time global BA ────────
  // DEFAULT OFF (OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1). Every N registered frames the
  // worker runs a bounded, observation-capped, pose-only global BA over live_recon
  // (MaybeIncrementalGlobalRefine) so accumulated ARKit-pose drift is corrected AS
  // IT GROWS — a sliding window at a time — instead of in one 74s finalize solve.
  // When any incremental refine has fired, the finalize global solve COLLAPSES its
  // round budget (see RefineGlobalBA). Written+read only on the capture-worker
  // isolate that owns live_recon, so no lock (mirrors aether_sfm_global_refine).
  size_t last_global_refine_reg = 0;       // reg_order.size() at the last refine
  bool incremental_global_ba_ran = false;  // any incremental refine fired this run
  int64_t stat_incremental_refines = 0;    // # incremental refines executed
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
  // [OFFICIAL-TRIANGULATE 2026-07-26] Observations added by upstream
  // IncrementalMapper::TriangulateImage during capture (env-gated arm).
  int64_t stat_official_tri_added = 0;
  int64_t stat_spatial_budget_skipped = 0;    // fair scheduler work omitted at cap
  // [GUIDED-TEMPORAL 2026-07-12] Epipolar-guided re-match on the LIVE temporal
  // add_frame path (OFFICIAL_AETHER_GUIDED_TEMPORAL=1; DEFAULT OFF → bit-identical when
  // unset). Reuses the shipped spatial-enrichment guided chain: raw Lowe match →
  // colmap-default TVG (E/F seed) → guided re-match inside the epipolar band at
  // the relaxed ratio (0.8) → fresh TVG re-verify, adopted ONLY when it STRICTLY
  // dominates the raw pair's inlier count (so every downstream ghost/tri-angle
  // gate and min_num_matches=15 stay in force). Weak-texture lever only; useless
  // on view-dependent reflections (the appearance is wrong, epipolar can't fix).
  int64_t stat_guided_temporal_attempted = 0;      // guided matcher calls completed
  int64_t stat_guided_temporal_upgraded = 0;       // pairs where guided replaced raw
  int64_t stat_guided_temporal_extra_inliers = 0;  // Σ(guided − raw) TVG inliers on upgrade
  int64_t stat_temporal_detail_pairs = 0;     // K-neighbor TVGs revisited post-BA
  int64_t stat_temporal_detail_matches = 0;   // temporal TVG inliers inspected
  int64_t stat_temporal_detail_created = 0;   // new final-pose detail points
  int64_t stat_temporal_detail_grown = 0;     // observations added to final tracks
  int64_t stat_temporal_detail_reject_cheirality = 0;
  int64_t stat_temporal_detail_reject_reproj = 0;
  int64_t stat_temporal_detail_reject_tri_angle = 0;
  int64_t stat_temporal_detail_conflicts = 0; // cross-track / duplicate-image skips
  // [KNIFE-A 2026-07-11] 2-view 升维·并集重定位包 attribution.
  // ① RestoreTemporalDetail grow-refit (OFFICIAL_AETHER_TD_GROW_REFIT=1):
  int64_t stat_td_grow_refit_attempted = 0;  // grow candidates entering refit
  int64_t stat_td_grow_refit_accepted = 0;   // union-refit accepted grows
  int64_t stat_td_grow_refit_saved = 0;      // accepted where 3px@current would reject
  // [P2-FRAG-MERGE-REPRICE] refit accepts refused by the MIN_THETA floor
  // (candidate then fell through to the legacy gates)
  int64_t stat_td_grow_refit_min_theta_rej = 0;
  // ② finalize-tail TrackUpgrade (OFFICIAL_AETHER_TRACK_UPGRADE=1):
  int64_t stat_upgrade_eligible = 0;     // 2-view / θ_max<3° delivered points
  int64_t stat_upgrade_attempted = 0;    // eligible points with ≥1 free candidate obs
  int64_t stat_upgrade_accepted = 0;     // points union-refit upgraded
  int64_t stat_upgrade_obs_added = 0;    // observations added by the pass
  // per-point θ_max distribution summary, whole delivered model, pre/post:
  int64_t stat_upgrade_pre_npts = 0;
  int64_t stat_upgrade_pre_2view = 0;
  int64_t stat_upgrade_pre_lt3 = 0;      // θ_max < 3°
  int64_t stat_upgrade_post_npts = 0;
  int64_t stat_upgrade_post_2view = 0;
  int64_t stat_upgrade_post_lt3 = 0;
  double upgrade_theta_p50_pre_deg = 0.0;
  double upgrade_theta_p50_post_deg = 0.0;
  double upgrade_ms = 0.0;
  // ③ targeted enrichment (OFFICIAL_AETHER_ENRICH_TARGETED=1):
  int stat_mirror_ghost_logged = -1;  // [MIRROR-GHOST V1] 日志去重(每变化记一次)
  int stat_isolated_floater_logged = -1;  // [ISOLATED-FLOATER] 日志去重(同上)
  int64_t stat_enrich_targeted_tracks = 0;  // hint size (low-parallax tracks)
  int64_t stat_enrich_targeted_scored = 0;  // top-up pairs with score > 0
  // Snapshot for the ③ top-up ordering (see EnrichTargetHint). Written by the
  // refine worker BEFORE the enrichment thread spawns; read only by that
  // thread (happens-before via thread creation); reset after the join.
  std::shared_ptr<const EnrichTargetHint> enrich_hint;
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
  // by_rc buckets use the pwofficial_gpu_match.mm return codes (1=bad args,
  // 2=Metal pipeline unavailable, 5/6=MTLBuffer alloc failed, 7=command-buffer
  // error — e.g. GPU hang under thermal pressure); bucket 0 aggregates any
  // out-of-range rc. rc=0 with zero matches is a LEGITIMATE empty pair and is
  // never counted here.
  int64_t stat_gpu_match_fail_total = 0;
  int64_t stat_gpu_match_fail_by_rc[8] = {0};
  int64_t stat_gpu_match_fail_max_streak = 0;  // longest consecutive-fail run
  int64_t gpu_match_fail_streak = 0;  // internal running streak (not exposed)
  // [P1-REPAY-THERMAL2 2026-07-11] GPU pairs completed since the last rc=7
  // (add_frame worker thread ownership, same as the streak above). Feeds the
  // thermal=2 conditional-repay gate: repay at serious requires a clean
  // recent GPU history. rc=7 resets; other rc codes are deterministic
  // failures (bad args / pipeline / alloc), not thermal-pressure evidence.
  int64_t gpu_pairs_since_rc7 = 0;
  // [THERMAL-THROTTLE 2026-07-11] Latest ProcessInfo thermal bucket pushed by
  // the platform layer (aether_sfm_set_thermal_state; 0 nominal · 1 fair ·
  // 2 serious · 3 critical, -1/unset = unknown → never throttles). Written by
  // the Dart worker right before each add_frame; read by add_frame's
  // candidate-K selection. Atomic only for cross-thread hygiene — the worker
  // serializes set→add_frame on one thread.
  std::atomic<int> thermal_state{-1};
  int64_t stat_thermal_throttled_frames = 0;  // frames fed with reduced K
  bool throttle_active_logged = false;        // transition-edge logging state
  // [FINALIZE-REMATCH 2026-07-11] Finalize-time starved-frame re-match pass
  // counters (see FinalizeRematchStarvedFrames).
  int64_t stat_finalize_rematch_starved_frames = 0;
  int64_t stat_finalize_rematch_candidates = 0;  // missing window pairs found
  int64_t stat_finalize_rematch_attempted = 0;   // matcher invocations
  int64_t stat_finalize_rematch_written = 0;     // pairs persisted to the db
  int64_t stat_finalize_rematch_inliers = 0;     // TVG inliers persisted
  int64_t stat_finalize_rematch_failed = 0;      // matcher rc!=0 (skipped)
  // [P1-RC7-RETRY 2026-07-11] rc=7 backoff-retry accounting (see
  // GpuMatchGemmPairsRetry): attempts = EXTRA matcher invocations spent on
  // retries; recovered = pairs whose rc turned 0 on a retry (data that the
  // old fail-closed skip lost outright).
  int64_t stat_gpu_retry_attempts = 0;
  int64_t stat_gpu_retry_recovered = 0;
  // [QUAD-PREPAY 2026-07-26, signed] Capture-idle OFFICIAL quadratic prepay
  // (see PrepayQuadraticTick, driven through aether_sfm_live_repay). Same
  // worker-thread ownership as add_frame. prepay_scan is the next frame
  // index whose due (i, i+2^k) pairs have not yet been enqueued;
  // prepay_due holds enqueued-but-unattempted pairs in arrival order
  // (near gaps first for a given j, matching the finalize pass's value
  // ordering under its gap-ascending sort).
  size_t prepay_scan = 0;
  std::deque<std::pair<int, int>> prepay_due;
  int64_t stat_prepay_attempted = 0;  // matcher invocations by prepay
  int64_t stat_prepay_written = 0;    // pairs persisted to the db
  // [PROBE-GATE 2026-08-07] 512-row probe pre-scoring of live match
  // candidates (08-03 recon: probe512 AUC 0.9527 predicting TVG survival;
  // working point probe512<3 skips 42.6% of pairs at 1.75% inlier-weighted
  // geometry loss). DEFAULT OFF — OFFICIAL_AETHER_PROBE_GATE_MIN=0 keeps the
  // shipped behavior bit-identical; N>0 arms the gate at that score
  // threshold. Same worker-thread ownership as add_frame.
  int64_t stat_probe_attempted = 0;  // probe matcher invocations
  int64_t stat_probe_skipped = 0;    // candidates skipped (score < threshold)
  int64_t stat_probe_passed = 0;     // candidates that went on to full match
  int64_t stat_probe_fail_open = 0;  // probe rc!=0 → gate bypassed fail-open
  double stat_probe_ms = 0.0;        // wall spent inside probe matches
  // [IDLE-PREPAY 2026-08-07] Capture-idle starved-window repay at the
  // production official endpoint (see aether_sfm_live_repay). ticks = calls
  // that actually entered the starved-window pass from the idle channel.
  int64_t stat_idle_prepay_ticks = 0;
  // Steady-clock ms of the last completed add_frame; the idle-prepay leg only
  // fires when the worker has been frame-idle longer than
  // OFFICIAL_AETHER_IDLE_PREPAY_IDLE_MS. Worker-thread only.
  double last_add_frame_done_ms = 0.0;
  // [AETHER-T1 2026-07-26] finalize_split attribution (pure observation).
  double t1_stage1_ba_ms = 0.0;
  double t1_stage1_merge_ms = 0.0;
  double t1_enrich_gate_wait_ms = 0.0;
  // [EPI-PRIOR 2026-07-27] experiment-arm counters (arm default OFF).
  int64_t stat_epi_attempted = 0;  // guided attempts (live + enrichment)
  int64_t stat_epi_fallback = 0;   // rc!=0 or match-count collapse → full GEMM
  // [AETHER-T-EXTRACT 2026-07-27] last frame's extractor stage split
  // (pyramid/pack/detect/suppress/affine/orient/clamp/descriptor/desc-rb).
  double last_extract_stages[9] = {0};
  // [GPU-TIMESTAMP-PROBE V1] Writer-owned identity and the complete native
  // frame snapshot pulled immediately after the serialized GPU extraction.
  // The extractor POD intentionally contains none of these Session IDs.
  uint64_t gpu_timestamp_run_id = 0;
  uint64_t gpu_timestamp_frame_ordinal = 0;
  uint64_t gpu_timestamp_next_record_id = 1;
  bool gpu_timestamp_probe_written = false;
  uint64_t gpu_timestamp_probe_instance_id = 0;
  bool gpu_timestamp_pending_frame_ready = false;
  uint64_t gpu_timestamp_pending_frame_ordinal = 0;
  AetherGpuTimestampFrameV1 gpu_timestamp_pending_frame{};
  // [A1B-ASYNC-PVBA 2026-07-27] Async preview-BA experiment arm state
  // (default OFF). Ownership discipline: the WORKER thread does every kick
  // (snapshot copy) and harvest (merge-back); the background thread touches
  // ONLY its own model copy and its own db read connection, then parks the
  // refined copy behind async_pvba_mutex and flips async_pvba_done.
  std::thread async_pvba_thread;
  std::atomic<bool> async_pvba_running{false};
  std::atomic<bool> async_pvba_done{false};
  std::shared_ptr<colmap::Reconstruction> async_pvba_result;
  std::mutex async_pvba_mutex;
  int apvba_snapshot_nframes = 0;  // [A1B-V2] frames at kick time
  // [A1B-V4] Pre-BA poses of every frame in the snapshot, kept so the
  // background pass's correction can be PROPAGATED onto the frames accepted
  // while it ran (ORB-SLAM2 §: "propagating the correction of updated
  // keyframes ... to non-updated keyframes"). ~56 B/frame.
  std::unordered_map<colmap::frame_t, colmap::Rigid3d> apvba_snapshot_poses;
  double stat_apvba_last_corr_mm = 0.0;   // |t| of the propagated correction
  double stat_apvba_last_corr_deg = 0.0;  // its rotation angle
  // [A1B-V3] consecutive-drop backoff + last background error (v2's drop rate
  // was a self-amplifying loop: a failed harvest returns NOT_REGISTERED, the
  // next frame re-triggers, kicks doubled and so did the contention).
  int apvba_consecutive_drops = 0;
  int apvba_skip_kicks = 0;
  bool apvba_kick_armed = true;  // [A1B-V5] cadence match: one pass/publish
  std::string apvba_last_error;
  int64_t stat_apvba_kicks = 0;
  int64_t stat_apvba_merges = 0;
  int64_t stat_apvba_dropped = 0;   // bg failure / result discarded
  double stat_apvba_last_ba_ms = 0.0;
  double stat_apvba_merge_ms_total = 0.0;
  double stat_apvba_copy_ms_total = 0.0;
  // [P1-LIVE-REPAY 2026-07-11] Capture-idle debt-repayment pass counters
  // (see aether_sfm_live_repay). Same worker-thread ownership as add_frame.
  int64_t stat_repay_calls = 0;
  int64_t stat_repay_attempted = 0;        // matcher invocations by repay
  int64_t stat_repay_written = 0;          // pairs persisted to the db
  int64_t stat_repay_inliers = 0;          // TVG inliers persisted by repay
  int64_t stat_repay_failed = 0;           // matcher rc!=0 (left for finalize)
  int64_t stat_repay_skipped_thermal = 0;  // repay calls refused at serious+
  // Live pair bookkeeping for the repay scan (add_frame worker thread only):
  // per-frame valid-window-pair counters mirroring FinalizeRematchStarved-
  // Frames' win_valid (gap <= K, TVG inliers >= gate), plus the set of frame
  // pairs already RESOLVED live (db row written, matched-empty, or repaid) so
  // an idle scan never re-touches sqlite or the matcher for them. GPU-failed
  // add_frame pairs are deliberately NOT in the set — they are the debt.
  std::vector<int> live_win_valid;
  std::unordered_set<uint64_t> live_pairs_done;
  // [P1-ENRICH-BUDGET 2026-07-11] Finalize-enrichment time gate state (see
  // EnrichBudgetExhausted). enrich_start_ms is written by the thread that
  // runs the enrichment passes right before they start; stage1_done is the
  // AUTO-mode window signal set by the refine worker after its stage-1 block.
  double enrich_start_ms = 0.0;
  std::atomic<bool> enrich_stage1_done{false};
  int64_t stat_enrich_budget_stopped = 0;  // fresh attempts skipped by the gate
  // [P2-FRAG-MERGE 2026-07-11] Finalize-tail fragment-merge attribution (see
  // MergeFragmentTracks). Conservation invariant the pass must uphold:
  // frag_post_npts + frag_accepted == frag_pre_npts (a merge DEDUPLICATES two
  // fragments into one multi-view point — the count drop is not deletion).
  int64_t stat_frag_links = 0;              // TVG-connected track-pair candidates
  int64_t stat_frag_attempted = 0;          // pairs entering the union refit
  int64_t stat_frag_accepted = 0;           // merges installed
  int64_t stat_frag_obs_merged = 0;         // union track sizes of accepted merges
  int64_t stat_frag_reject_reproj = 0;      // union refit reproj/cheirality fail
  int64_t stat_frag_reject_theta = 0;       // θ_max did not strictly rise
  // [P2-FRAG-MERGE-REPRICE] union θ_max below OFFICIAL_AETHER_FRAG_MERGE_MIN_THETA_DEG
  int64_t stat_frag_reject_min_theta = 0;
  int64_t stat_frag_reject_degenerate = 0;  // broken obs / DLT failure
  int64_t stat_frag_pre_npts = 0, stat_frag_pre_2view = 0, stat_frag_pre_lt3 = 0;
  int64_t stat_frag_post_npts = 0, stat_frag_post_2view = 0, stat_frag_post_lt3 = 0;
  double frag_theta_p50_pre_deg = 0.0;
  double frag_theta_p50_post_deg = 0.0;
  double frag_ms = 0.0;

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

  // [GPU-HANG-B1 2026-08-06] Chromium 式 watchdog(见 official_gpu_watchdog_v1.h)。
  // 巡逻线程在 aether_sfm_create 启动、aether_sfm_free(join 完 refine/apvba
  // 线程后)停止。一期纯观测:hang_detected 只落 jsonl,不改任何行为。
  aether_gpu_watchdog_v1::WatchdogV1 gpu_watchdog;
};

namespace aether_preclamp_instr_v1 {

void ResetOfficialSessionRecords(::aether_sfm_session* session) noexcept {
  if (session == nullptr) return;
  ResetSessionRecords(&session->preclamp_instr_records);
}

bool CopyOfficialSessionRecords(
    const ::aether_sfm_session* session, std::vector<FrameCounts>* out) {
  if (session == nullptr) return false;
  return CopySessionRecords(&session->preclamp_instr_records, out);
}

bool DrainOfficialSessionRecords(
    ::aether_sfm_session* session, std::vector<FrameCounts>* out) noexcept {
  if (session == nullptr) return false;
  return DrainSessionRecords(&session->preclamp_instr_records, out);
}

}  // namespace aether_preclamp_instr_v1

namespace {

enum class TailCacheModeV1 { kOff, kShadow, kOn };

TailCacheModeV1 TailCacheMode() {
  static const TailCacheModeV1 cached = [] {
    const char* value = std::getenv("OFFICIAL_AETHER_TAIL_CACHE_V1");
    if (!value) return TailCacheModeV1::kOff;
    if (std::strcmp(value, "shadow") == 0) return TailCacheModeV1::kShadow;
    if (std::strcmp(value, "1") == 0 || std::strcmp(value, "on") == 0) {
      return TailCacheModeV1::kOn;
    }
    return TailCacheModeV1::kOff;
  }();
  return cached;
}

bool TailCacheActive() { return TailCacheMode() != TailCacheModeV1::kOff; }

bool DescriptorResidencyEnabledCore() {
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
  static const bool cached = [] {
    const char* value =
        std::getenv("OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1");
    return value && value[0] == '1' && value[1] == '\0';
  }();
  return cached;
#else
  return false;
#endif
}

bool TailCacheTraceEnabled() {
  static const bool cached = [] {
    const char* value = std::getenv("OFFICIAL_AETHER_TAIL_CACHE_V1");
    if (!value) return false;
    return std::strcmp(value, "off") == 0 ||
           std::strcmp(value, "shadow") == 0 ||
           std::strcmp(value, "1") == 0 || std::strcmp(value, "on") == 0;
  }();
  return cached;
}

const char* TailCacheDirtyReasonName(
    aether::sfm::TailCacheDirtyReasonV1 reason) {
  using Reason = aether::sfm::TailCacheDirtyReasonV1;
  switch (reason) {
    case Reason::kNone: return "none";
    case Reason::kPairOverwrite: return "pair_overwrite";
    case Reason::kRemoveFrame: return "remove_frame";
    case Reason::kLatePair: return "late_pair";
    case Reason::kModelReplacement: return "model_replacement";
    case Reason::kFinalizeMove: return "finalize_move";
    case Reason::kReconstructionSwap: return "reconstruction_swap";
    case Reason::kConfigChange: return "config_change";
    case Reason::kCacheInconsistency: return "cache_inconsistency";
    case Reason::kExceptionRetry: return "exception_retry";
    case Reason::kDeviceReset: return "device_reset";
    case Reason::kUnknownMutation: return "unknown_mutation";
  }
  return "unknown_mutation";
}

int64_t EpochMs();
void AppendMatchFailJsonl(aether_sfm_session* s, const std::string& line);

void AppendTailCacheEpochEventLockedV1(aether_sfm_session* s,
                                       const char* phase) {
  if (!s || !phase || !TailCacheTraceEnabled()) return;
  const auto& epoch = s->tail_cache_epoch;
  const std::string line =
      "{\"t\":" + std::to_string(static_cast<long long>(EpochMs())) +
      ",\"type\":\"tail_cache_epoch_event_v1\",\"phase\":\"" + phase +
      "\",\"state\":" + std::to_string(static_cast<int>(epoch.state())) +
      ",\"generation\":" + std::to_string(epoch.generation()) +
      ",\"invalidated_generation\":" +
      std::to_string(epoch.invalidated_generation()) +
      ",\"rebuild_parent_generation\":" +
      std::to_string(epoch.rebuild_parent_generation()) +
      ",\"dirty_reason\":\"" + TailCacheDirtyReasonName(epoch.dirty_reason()) +
      "\"}";
  AppendMatchFailJsonl(s, line);
}

void TailCacheMarkDirtyLockedV1(
    aether_sfm_session* s, aether::sfm::TailCacheDirtyReasonV1 reason,
    const char* phase = "dirty_before_mutation") {
  s->tail_cache_epoch.MarkDirty(reason);
  AppendTailCacheEpochEventLockedV1(s, phase);
}

void TailCacheInitialize(aether_sfm_session* s) {
  if (!s || !s->db || !TailCacheActive()) return;
  std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
  s->tail_cache_master = std::make_shared<colmap::DatabaseCache>();
  s->tail_cache_epoch.StartEmpty();
  s->tail_cache_seen_db_pairs.clear();
  if (s->db->NumImages() != 0) {
    TailCacheMarkDirtyLockedV1(
        s, aether::sfm::TailCacheDirtyReasonV1::kConfigChange);
  }
}

void TailCacheMarkDirty(aether_sfm_session* s,
                        aether::sfm::TailCacheDirtyReasonV1 reason) {
  if (!s || !TailCacheActive()) return;
  std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
  TailCacheMarkDirtyLockedV1(s, reason);
}

struct TailCacheMutableBuildV1 {
  std::shared_ptr<colmap::DatabaseCache> cache;
  std::vector<uint32_t> image_ids;
  std::vector<uint64_t> qualifying_pair_ids;
  std::unordered_set<colmap::image_pair_t> seen_db_pairs;
};

TailCacheMutableBuildV1 BuildMutableTailCacheV1(
    const colmap::Database& database) {
  TailCacheMutableBuildV1 out;
  out.cache = std::make_shared<colmap::DatabaseCache>();
  const bool has_rigs = database.NumRigs() > 0;
  const bool has_frames = database.NumFrames() > 0;

  if (has_rigs) {
    for (auto rig : database.ReadAllRigs()) out.cache->AddRig(std::move(rig));
  }
  for (auto camera : database.ReadAllCameras()) {
    if (!has_rigs) {
      colmap::Rig rig;
      rig.SetRigId(camera.camera_id);
      rig.AddRefSensor(camera.SensorId());
      out.cache->AddRig(std::move(rig));
    }
    out.cache->AddCamera(std::move(camera));
  }
  if (has_frames) {
    for (auto frame : database.ReadAllFrames()) {
      out.cache->AddFrame(std::move(frame));
    }
  }

  for (auto image : database.ReadAllImages()) {
    if (!has_frames) {
      colmap::Frame frame;
      frame.SetFrameId(image.ImageId());
      frame.SetRigId(image.CameraId());
      frame.AddDataId(image.DataId());
      image.SetFrameId(frame.FrameId());
      out.cache->AddFrame(std::move(frame));
    }
    image.SetPoints2D(colmap::FeatureKeypointsToPointsVector(
        database.ReadKeypoints(image.ImageId())));
    out.image_ids.push_back(static_cast<uint32_t>(image.ImageId()));
    out.cache->AddImage(std::move(image));
  }

  for (auto& [pair_id, geometry] : database.ReadTwoViewGeometries()) {
    out.seen_db_pairs.insert(pair_id);
    if (geometry.inlier_matches.size() < 15) continue;
    const auto [image1, image2] = colmap::PairIdToImagePair(pair_id);
    out.cache->CorrespondenceGraph()->AddTwoViewGeometry(
        image1, image2, std::move(geometry));
    out.qualifying_pair_ids.push_back(pair_id);
  }
  return out;
}

bool TailCacheRebuildLocked(aether_sfm_session* s) {
  if (!s || !s->db ||
      s->tail_cache_epoch.state() !=
          aether::sfm::TailCacheEpochStateV1::kDirty ||
      !s->tail_cache_epoch.BeginRebuild()) {
    return false;
  }
  AppendTailCacheEpochEventLockedV1(s, "rebuild_begin");
  try {
    // Keep the finalized fresh route as a rebuild oracle. The returned cache is
    // never mutated and is deliberately discarded after construction.
    colmap::DatabaseCache::Options oracle_options;
    oracle_options.min_num_matches = 15;
    oracle_options.load_all_images = true;
    const auto oracle = colmap::DatabaseCache::Create(*s->db, oracle_options);
    (void)oracle;

    TailCacheMutableBuildV1 rebuilt = BuildMutableTailCacheV1(*s->db);
    s->tail_cache_epoch.CompleteRebuild(rebuilt.image_ids,
                                       rebuilt.qualifying_pair_ids);
    if (!s->tail_cache_epoch.readable()) return false;
    s->tail_cache_master = std::move(rebuilt.cache);
    s->tail_cache_seen_db_pairs = std::move(rebuilt.seen_db_pairs);
    AppendTailCacheEpochEventLockedV1(s, "rebuild_complete");
    return true;
  } catch (...) {
    TailCacheMarkDirtyLockedV1(
        s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency,
        "rebuild_failed");
    return false;
  }
}

void TailCacheMirrorImage(aether_sfm_session* s,
                          const colmap::Camera& camera,
                          colmap::image_t image_id,
                          const char* name,
                          const std::vector<Eigen::Vector2d>& points) {
  if (!s || !TailCacheActive()) return;
  std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
  if (!s->tail_cache_epoch.readable() || !s->tail_cache_master) return;
  try {
    colmap::Rig rig;
    rig.SetRigId(camera.camera_id);
    rig.AddRefSensor(camera.SensorId());
    s->tail_cache_master->AddRig(std::move(rig));
    s->tail_cache_master->AddCamera(camera);

    colmap::Image image;
    image.SetImageId(image_id);
    image.SetName(name);
    image.SetCameraId(camera.camera_id);
    image.SetPoints2D(points);
    colmap::Frame frame;
    frame.SetFrameId(image_id);
    frame.SetRigId(camera.camera_id);
    frame.AddDataId(image.DataId());
    image.SetFrameId(frame.FrameId());
    s->tail_cache_master->AddFrame(std::move(frame));
    s->tail_cache_master->AddImage(std::move(image));
    if (!s->tail_cache_epoch.AdmitImage(static_cast<uint32_t>(image_id))) {
      TailCacheMarkDirtyLockedV1(
          s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency);
    }
  } catch (...) {
    TailCacheMarkDirtyLockedV1(
        s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency);
  }
}

bool TailCacheBeginPairWrite(aether_sfm_session* s,
                             colmap::image_t image1,
                             colmap::image_t image2,
                             bool late_write = false) {
  if (!s || !TailCacheActive()) return false;
  std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
  const colmap::image_pair_t pair_id =
      colmap::ImagePairToPairId(image1, image2);
  const bool first_write = s->tail_cache_seen_db_pairs.insert(pair_id).second;
  if (!first_write) {
    TailCacheMarkDirtyLockedV1(
        s, aether::sfm::TailCacheDirtyReasonV1::kPairOverwrite);
  } else if (late_write) {
    // Idle repay/prepay inserts a pair after the newest frame's normal
    // add-frame epoch. Rebuilding preserves the fresh SQLite pair ordering;
    // incrementally appending here could change correspondence adjacency and
    // a later FindLocalBundle tie-break.
    TailCacheMarkDirtyLockedV1(
        s, aether::sfm::TailCacheDirtyReasonV1::kLatePair);
  }
  return first_write;
}

void TailCacheCommitPair(aether_sfm_session* s,
                         colmap::image_t image1,
                         colmap::image_t image2,
                         const colmap::TwoViewGeometry& geometry,
                         bool first_write) {
  if (!s || !TailCacheActive() || !first_write ||
      geometry.inlier_matches.size() < 15) {
    return;
  }
  std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
  if (!s->tail_cache_epoch.readable() || !s->tail_cache_master) return;
  const colmap::image_pair_t pair_id =
      colmap::ImagePairToPairId(image1, image2);
  if (!s->tail_cache_epoch.AdmitPair(pair_id)) return;
  try {
    s->tail_cache_master->CorrespondenceGraph()->AddTwoViewGeometry(
        image1, image2, geometry);
  } catch (...) {
    TailCacheMarkDirtyLockedV1(
        s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency);
  }
}

struct SpatialRevisitCandidate {
  int i = -1;
  int j = -1;
  double distance_m = 0.0;
  double angle_rad = 0.0;
  double score = 0.0;
  int anchor_rank = 0;
  bool quadratic = false;
  // [KNIFE-A ③] top-up targeting: # of 2-view/low-parallax tracks this pair
  // can hand a ≥5°-parallax third observation (0 when the hint is absent).
  int target_score = 0;
};

Eigen::Vector3d CameraForwardWorld(const colmap::Rigid3d& cam_from_world) {
  return cam_from_world.rotation().inverse() * Eigen::Vector3d(0.0, 0.0, 1.0);
}

// [SPATIAL-FIRST 2026-07-11] Legacy capture-time match-candidate selection.
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

  // A frame is a usable candidate only when it is neither withdrawn nor
  // featureless. image_id == 0 is the withdrawal marker set by remove_frame and
  // mirrored by RebuildFrameRecordsForResume; it is tested explicitly rather
  // than inferred from n_keypoints so that the three pair-producing paths
  // (this one, AddOfficialQuadraticPairs, FinalizeRematchStarvedFrames) all
  // state the same predicate.
  // NOTE: the old comment here claimed resume-rebuilt records carry no
  // descriptors. That is no longer true for ACTIVE resumed frames — the
  // mandatory-ARKit recovery contract reads them back to recompute identity
  // digests.
  const auto usable = [&](int j) {
    const FrameRecord& prev = s.frames[j];
    return prev.image_id != 0 && prev.n_keypoints > 0 &&
           !prev.descriptors.empty();
  };

  // Kill switch: OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY=1 forces the legacy pure-temporal
  // window (baseline arm of the host A/B; emergency same-binary revert on
  // device via setenv before aether_sfm_create).
  static const bool temporal_only = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY");
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

// [SPATIAL-K20 2026-08-03] Product-required pair graph.
//
// Space is the primary source, not a hypothesis arm: select the twenty nearest
// non-recent, view-compatible ARKit poses, then independently add the previous
// two frames for short-term continuity.  The shared, platform-neutral C++ core
// owns ordering, canonical pair identity, source preservation and dedup, so
// iOS/Metal and future Vulkan/SIMD carriers cannot silently grow different
// pairing semantics.
//
// OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY remains an emergency/reference override
// and deliberately routes to the characterized legacy selector above.  The
// shipping default does not depend on an environment variable.
std::vector<int> SelectSpatialK20TemporalT2Candidates(
    const aether_sfm_session& s, const FrameRecord& rec, const int frame_id,
    const bool thermal_throttled, const int thermal_spatial_k,
    int* out_spatial, int* out_temporal) {
  if (out_spatial) *out_spatial = 0;
  if (out_temporal) *out_temporal = 0;
  if (frame_id <= 0) return {};

  aether_pair_policy_config_v2 abi_config{};
  aether_pair_policy_config_v2_default(&abi_config);
  if (aether_pair_policy_config_v2_validate(&abi_config) !=
      AETHER_PAIR_POLICY_V2_OK) {
    return {};
  }

  static const bool temporal_only = [] {
    const char* value = std::getenv("OFFICIAL_AETHER_STREAM_TEMPORAL_ONLY");
    return value != nullptr && value[0] == '1';
  }();
  if (temporal_only) {
    return SelectStreamCandidates(s, rec, frame_id, abi_config.spatial_k,
                                  out_spatial, out_temporal);
  }

  std::vector<aether::sfm::PairSelectionFrameV2> history;
  history.reserve(static_cast<size_t>(frame_id));
  for (int index = 0; index < frame_id; ++index) {
    const FrameRecord& previous = s.frames[index];
    aether::sfm::PairSelectionFrameV2 frame;
    frame.frame_id = index;
    frame.pose_valid = previous.has_pose;
    frame.matchable = previous.n_keypoints > 0 && !previous.descriptors.empty();
    if (previous.has_pose) {
      const Eigen::Vector3d center =
          previous.cam_from_world.TgtOriginInSrc();
      const Eigen::Vector3d forward =
          CameraForwardWorld(previous.cam_from_world);
      frame.center_xyz = {center.x(), center.y(), center.z()};
      frame.forward_xyz = {forward.x(), forward.y(), forward.z()};
    }
    history.push_back(frame);
  }

  aether::sfm::PairSelectionFrameV2 current;
  current.frame_id = frame_id;
  current.pose_valid = rec.has_pose;
  current.matchable = rec.n_keypoints > 0 && !rec.descriptors.empty();
  if (rec.has_pose) {
    const Eigen::Vector3d center = rec.cam_from_world.TgtOriginInSrc();
    const Eigen::Vector3d forward = CameraForwardWorld(rec.cam_from_world);
    current.center_xyz = {center.x(), center.y(), center.z()};
    current.forward_xyz = {forward.x(), forward.y(), forward.z()};
  }

  aether::sfm::PairSelectionConfigV2 config;
  // [K-REWIRE 2026-08-06 用户签决"K10上产,回环保留"] 常态空间 K 重新服从
  // 调用方传入的 k(= base_k 链:env OFFICIAL_AETHER_LIVE_CAND_K > options.
  // k_neighbors(生产 12)> 兜底 6)。此前这里常态用 abi_config.spatial_k
  // (硬编码 20)⇒ 08-06 上午随尺度重编上机后,K10 回滚被静默旁路,真机
  // cand=22(+回环尖峰 26),复现被判死的 K20 热债(未命名2:match 尖峰
  // 7.3s、时长史上最长)。质量侧同场真机图 A/B 已证 12 对/帧饱和
  // (K22→K12 点数 −0.34%)。thermal_spatial_k 形参实为"调用方解析后的
  // 生效 K"(热降频时已被调用方降过),两种状态同走一条线。
  // 回环检索(VISUAL-LOOP V1,每10帧+≤4)不受影响,按用户签决保留。
  // k 是"总预算"(签决的 K10 臂 = 空间10+时间2=总12),空间名额 = k − 时间窗。
  config.spatial_k =
      std::max(0, thermal_spatial_k - abi_config.temporal_lookback);
  (void)thermal_throttled;  // K 语义已并入 thermal_spatial_k,形参留作 ABI 稳定
  config.temporal_lookback = abi_config.temporal_lookback;
  config.spatial_recent_exclusion = abi_config.spatial_recent_exclusion;
  const aether::sfm::PairSelectionResultV2 result =
      aether::sfm::SelectSpatialTemporalCandidatesV2(history, current, config);

  std::vector<int> selected;
  selected.reserve(result.ordered_pairs.size());
  int spatial = 0;
  int temporal = 0;
  const uint32_t spatial_mask =
      static_cast<uint32_t>(aether::sfm::PairCandidateSourceV2::kSpatial);
  const uint32_t temporal_mask =
      static_cast<uint32_t>(aether::sfm::PairCandidateSourceV2::kTemporal);
  for (const aether::sfm::CanonicalPairCandidateV2& pair :
       result.ordered_pairs) {
    if (pair.second_frame_id != frame_id || pair.first_frame_id < 0 ||
        pair.first_frame_id >= frame_id) {
      continue;
    }
    selected.push_back(pair.first_frame_id);
    if ((pair.source_mask & spatial_mask) != 0U) ++spatial;
    if ((pair.source_mask & temporal_mask) != 0U) ++temporal;
  }
  if (out_spatial) *out_spatial = spatial;
  if (out_temporal) *out_temporal = temporal;
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

// [RC7-FILELOG 2026-07-11] Epoch-ms wall clock for the jsonl lines below
// (NowMs above is steady_clock — good for durations, useless for correlating
// against telemetry_native/telemetry_dart timestamps after a detached run).
int64_t EpochMs() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

// [RC7-FILELOG 2026-07-11] Append one JSONL line to <db_dir>/
// sfm_match_fail.jsonl — the pull-able file record of capture-time GPU
// matcher failures (and thermal-throttle transitions). Motivation: rc=7
// (MTLCommandBufferStatusError) evidence previously lived only in NSLog +
// in-memory counters; detached device runs (拔线) lose stderr/os_log, so the
// cap44/45 freeze forensics had timestamps for everything EXCEPT the GPU
// failures. The db directory is the app's Documents container on device —
// exactly what `devicectl copy` already recovers. Best-effort by design:
// open-append-close per event (events are rare; a thermal collapse writes a
// few hundred ~150 B lines), any I/O failure is swallowed.
void AppendMatchFailJsonl(aether_sfm_session* s, const std::string& line) {
  try {
    const std::filesystem::path p =
        std::filesystem::path(s->db_path).parent_path() /
        "sfm_match_fail.jsonl";
    FILE* f = std::fopen(p.string().c_str(), "a");
    if (!f) return;
    std::fputs(line.c_str(), f);
    std::fputc('\n', f);
    std::fclose(f);
  } catch (...) {
    // telemetry only — never take add_frame down
  }
}

struct LocalBundleTraceSnapshotV1 {
  int raw_calls = 0;
  int calls = 0;
  std::array<uint32_t, 16> query{};
  std::array<int, 16> neighbor_count{};
  std::array<int, 16> neighbor_total{};
  std::array<std::array<uint32_t, 15>, 16> neighbors{};
};

void ResetLocalBundleTraceV1() {
  aether_ilr_bundle_trace_calls = 0;
  std::memset(aether_ilr_bundle_trace_query, 0,
              sizeof(aether_ilr_bundle_trace_query));
  std::memset(aether_ilr_bundle_trace_neighbor_count, 0,
              sizeof(aether_ilr_bundle_trace_neighbor_count));
  std::memset(aether_ilr_bundle_trace_neighbor_total, 0,
              sizeof(aether_ilr_bundle_trace_neighbor_total));
  std::memset(aether_ilr_bundle_trace_neighbors, 0,
              sizeof(aether_ilr_bundle_trace_neighbors));
}

LocalBundleTraceSnapshotV1 CaptureLocalBundleTraceV1() {
  LocalBundleTraceSnapshotV1 snapshot;
  snapshot.raw_calls = std::max(aether_ilr_bundle_trace_calls, 0);
  snapshot.calls = std::min(snapshot.raw_calls, 16);
  for (int call = 0; call < snapshot.calls; ++call) {
    snapshot.query[call] = aether_ilr_bundle_trace_query[call];
    snapshot.neighbor_count[call] = std::min(
        std::max(aether_ilr_bundle_trace_neighbor_count[call], 0), 15);
    snapshot.neighbor_total[call] =
        std::max(aether_ilr_bundle_trace_neighbor_total[call], 0);
    for (int i = 0; i < snapshot.neighbor_count[call]; ++i) {
      snapshot.neighbors[call][i] =
          aether_ilr_bundle_trace_neighbors[call][i];
    }
  }
  return snapshot;
}

bool LocalBundleTraceExactV1(const LocalBundleTraceSnapshotV1& fresh,
                             const LocalBundleTraceSnapshotV1& mutable_cache) {
  if (fresh.raw_calls != mutable_cache.raw_calls ||
      fresh.calls != mutable_cache.calls) {
    return false;
  }
  for (int call = 0; call < fresh.calls; ++call) {
    if (fresh.query[call] != mutable_cache.query[call] ||
        fresh.neighbor_count[call] != mutable_cache.neighbor_count[call] ||
        fresh.neighbor_total[call] != mutable_cache.neighbor_total[call]) {
      return false;
    }
    for (int i = 0; i < fresh.neighbor_count[call]; ++i) {
      if (fresh.neighbors[call][i] != mutable_cache.neighbors[call][i]) {
        return false;
      }
    }
  }
  return true;
}

void AppendTailLocalBundleTraceV1(
    aether_sfm_session* s,
    int frame_id,
    int cache_reused,
    uint64_t cache_generation,
    const char* source,
    const LocalBundleTraceSnapshotV1& trace) {
  if (!s || !TailCacheTraceEnabled()) return;
  const char* mode =
      TailCacheMode() == TailCacheModeV1::kOn
          ? "on"
          : (TailCacheMode() == TailCacheModeV1::kShadow ? "shadow" : "off");
  for (int call = 0; call < trace.calls; ++call) {
    const int count = trace.neighbor_count[call];
    const int total = trace.neighbor_total[call];
    std::string line =
        "{\"t\":" + std::to_string(static_cast<long long>(EpochMs())) +
        ",\"type\":\"tail_local_bundle_v1\",\"fid\":" +
        std::to_string(frame_id) + ",\"cache\":\"" + mode +
        "\",\"source\":\"" + source +
        "\",\"cache_reused\":" + std::to_string(cache_reused) +
        ",\"tail_gen\":" + std::to_string(cache_generation) +
        ",\"call\":" + std::to_string(call) + ",\"query\":" +
        std::to_string(trace.query[call]) +
        ",\"neighbors\":[";
    for (int i = 0; i < count; ++i) {
      if (i != 0) line += ',';
      line += std::to_string(trace.neighbors[call][i]);
    }
    line += "],\"ba_images\":[" +
            std::to_string(trace.query[call]);
    for (int i = 0; i < count; ++i) {
      line += ',';
      line += std::to_string(trace.neighbors[call][i]);
    }
    line += "],\"neighbor_total\":" + std::to_string(total) +
            ",\"truncated\":" +
            (trace.raw_calls > trace.calls || total > count ? "true" : "false") +
            "}";
    AppendMatchFailJsonl(s, line);
  }
}

void AppendTailMatchCandidatesV1(aether_sfm_session* s,
                                 int frame_id,
                                 int configured_k,
                                 const std::vector<int>& candidates) {
  if (!s || !TailCacheTraceEnabled()) return;
  std::string line =
      "{\"t\":" + std::to_string(static_cast<long long>(EpochMs())) +
      ",\"type\":\"tail_match_candidates_v1\",\"fid\":" +
      std::to_string(frame_id) + ",\"configured_k\":" +
      std::to_string(configured_k) + ",\"match_candidate_ids\":[";
  bool first = true;
  for (const int index : candidates) {
    if (index < 0 || index >= static_cast<int>(s->frames.size())) continue;
    if (!first) line += ',';
    first = false;
    line += std::to_string(s->frames[static_cast<size_t>(index)].frame_id);
  }
  line += "],\"image_ids\":[";
  first = true;
  for (const int index : candidates) {
    if (index < 0 || index >= static_cast<int>(s->frames.size())) continue;
    if (!first) line += ',';
    first = false;
    line += std::to_string(s->frames[static_cast<size_t>(index)].image_id);
  }
  line += "]}";
  AppendMatchFailJsonl(s, line);
}

uint64_t NewGpuTimestampRunId() {
  static std::atomic<uint64_t> sequence{1};
  constexpr uint64_t kSequenceBits = 20;
  constexpr uint64_t kSequenceMask = (uint64_t{1} << kSequenceBits) - 1;
  const uint64_t epoch_ms =
      static_cast<uint64_t>(std::max<int64_t>(EpochMs(), 1));
  const uint64_t suffix =
      sequence.fetch_add(1, std::memory_order_relaxed) & kSequenceMask;
  return (epoch_ms << kSequenceBits) | suffix;
}

void AppendGpuTimestampProbeRecord(aether_sfm_session* s) {
  if (s == nullptr || s->gpu_timestamp_probe_written ||
      aether_sed_gpu_timestamp_probe_v1 == nullptr) {
    return;
  }
  AetherGpuTimestampProbeV1 probe{};
  probe.struct_size = sizeof(probe);
  if (aether_sed_gpu_timestamp_probe_v1(&probe) !=
      AETHER_GPU_TIMESTAMP_PULL_OK_V1) {
    return;
  }

  const aether::official::gpu_timestamp_writer_v1::RecordIdentityV1 identity{
      .run_id = s->gpu_timestamp_run_id,
      .frame_id = -1,
      .frame_ordinal = 0,
      .probe_record_id = s->gpu_timestamp_next_record_id,
  };
  std::string json;
  if (!aether::official::gpu_timestamp_writer_v1::SerializeProbeRecordV1(
          probe, identity, EpochMs(), &json)) {
    return;
  }
  AppendMatchFailJsonl(s, json);
  ++s->gpu_timestamp_next_record_id;
  s->gpu_timestamp_probe_instance_id = probe.probe_instance_id;
  s->gpu_timestamp_probe_written = true;
}

void PullGpuTimestampAfterExtraction(aether_sfm_session* s) {
  if (s == nullptr) return;
  s->gpu_timestamp_pending_frame_ready = false;
  ++s->gpu_timestamp_frame_ordinal;
  AppendGpuTimestampProbeRecord(s);
  if (!s->gpu_timestamp_probe_written ||
      aether_dsp_sift_take_last_gpu_timestamp_frame_v1 == nullptr) {
    return;
  }

  AetherGpuTimestampFrameV1 frame{};
  frame.struct_size = sizeof(frame);
  if (aether_dsp_sift_take_last_gpu_timestamp_frame_v1(&frame) !=
          AETHER_GPU_TIMESTAMP_PULL_OK_V1 ||
      frame.probe_instance_id != s->gpu_timestamp_probe_instance_id) {
    return;
  }
  s->gpu_timestamp_pending_frame = frame;
  s->gpu_timestamp_pending_frame_ordinal =
      s->gpu_timestamp_frame_ordinal;
  s->gpu_timestamp_pending_frame_ready = true;
}

void AppendGpuTimestampFrameRecord(aether_sfm_session* s, int frame_id) {
  if (s == nullptr || !s->gpu_timestamp_pending_frame_ready ||
      !s->gpu_timestamp_probe_written) {
    return;
  }
  const AetherGpuTimestampFrameV1 frame =
      s->gpu_timestamp_pending_frame;
  const uint64_t frame_ordinal =
      s->gpu_timestamp_pending_frame_ordinal;
  s->gpu_timestamp_pending_frame_ready = false;

  const aether::official::gpu_timestamp_writer_v1::RecordIdentityV1 identity{
      .run_id = s->gpu_timestamp_run_id,
      .frame_id = frame_id,
      .frame_ordinal = frame_ordinal,
      .probe_record_id = s->gpu_timestamp_next_record_id,
  };
  std::string json;
  if (!aether::official::gpu_timestamp_writer_v1::SerializeFrameRecordV1(
          frame, identity, EpochMs(), &json)) {
    return;
  }
  AppendMatchFailJsonl(s, json);
  ++s->gpu_timestamp_next_record_id;
}

// [AETHER BA-RING 2026-07-26, signed] Drain the per-solve ceres ring into a
// pullable ba_rounds record. Settles the stage-1 "thread tax vs
// round-position iteration count" confound and prices ftol early-stop for
// the round-allocation sign-off. Pure observation.
void AppendBaRingJsonl(aether_sfm_session* s, int stage) {
  try {
    const int n = aether_ba_ring_count();
    if (n <= 0) return;
    std::string line = "{\"t\":" + std::to_string(EpochMs()) +
                       ",\"type\":\"ba_rounds\",\"stage\":" +
                       std::to_string(stage) + ",\"solves\":[";
    char buf[160];
    for (int i = 0; i < n && i < 12; ++i) {
      double total_s, jac_s, lin_s, res_s;
      int iters, term, threads;
      if (!aether_ba_ring_get(i, &total_s, &jac_s, &lin_s, &res_s, &iters,
                              &term, &threads)) {
        break;
      }
      std::snprintf(buf, sizeof(buf),
                    "%s{\"total_s\":%.2f,\"jac_s\":%.2f,\"lin_s\":%.2f,"
                    "\"res_s\":%.2f,\"iters\":%d,\"term\":%d,\"thr\":%d}",
                    i ? "," : "", total_s, jac_s, lin_s, res_s, iters, term,
                    threads);
      line += buf;
    }
    line += "]}";
    AppendMatchFailJsonl(s, line);
  } catch (...) {
    // telemetry only
  }
}

// JSON string sanitizer for the Metal error text (quotes/backslashes/control
// chars → space; keeps the line machine-parseable without a JSON library).
std::string JsonSafe(const char* text, size_t max_len) {
  std::string out;
  if (!text) return out;
  out.reserve(max_len);
  for (size_t i = 0; text[i] != '\0' && i < max_len; ++i) {
    const char c = text[i];
    out.push_back((c == '"' || c == '\\' || (c >= 0 && c < 0x20)) ? ' ' : c);
  }
  return out;
}

void NoteGpuMatchFailure(aether_sfm_session* s, int rc, int prev_frame_id,
                         int new_frame_id) {
  ++s->stat_gpu_match_fail_total;
  const int bucket = (rc >= 1 && rc <= 7) ? rc : 0;
  ++s->stat_gpu_match_fail_by_rc[bucket];
  // [P1-REPAY-THERMAL2] rc=7 (thermal/GPU-pressure kill) dirties the clean
  // history the conditional repay gate requires.
  if (rc == 7) s->gpu_pairs_since_rc7 = 0;
  ++s->gpu_match_fail_streak;
  if (s->gpu_match_fail_streak > s->stat_gpu_match_fail_max_streak) {
    s->stat_gpu_match_fail_max_streak = s->gpu_match_fail_streak;
  }
  // [RC7-FILELOG 2026-07-11] Every capture-time matcher failure lands one
  // timestamped jsonl line WITH the pair id — 21 rc=7 events per capture is
  // the observed worst case order of magnitude (cap45), a full thermal
  // collapse (cap43, ~600) is still <100 KB. rc=7 lines carry the Metal
  // error description when the platform TU (pwofficial_gpu_match.mm) recorded one.
  {
    char head[192];
    std::snprintf(head, sizeof(head),
                  "{\"t\":%lld,\"type\":\"gpu_match_fail\",\"rc\":%d,"
                  "\"pair\":[%d,%d],\"streak\":%lld,\"total\":%lld,"
                  "\"thermal\":%d",
                  static_cast<long long>(EpochMs()), rc, prev_frame_id,
                  new_frame_id, static_cast<long long>(s->gpu_match_fail_streak),
                  static_cast<long long>(s->stat_gpu_match_fail_total),
                  s->thermal_state.load(std::memory_order_relaxed));
    std::string line(head);
    if (rc == 7 && aether_gpu_match_last_error != nullptr) {
      char err[192] = {0};
      if (aether_gpu_match_last_error(err, sizeof(err)) > 0) {
        line += ",\"metal_err\":\"";
        line += JsonSafe(err, sizeof(err));
        line += "\"";
      }
    }
    line += "}";
    AppendMatchFailJsonl(s, line);
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

// [P1-RC7-RETRY 2026-07-11] Backoff retry around the Metal GEMM matcher for
// rc=7 ONLY (MTLCommandBufferStatusError — the transient "command buffer
// killed under thermal/GPU pressure" failure). cap46 forensics: 49 rc=7
// events during capture and 93 more during finalize re-match; descriptors
// were intact throughout, i.e. the loss was recoverable by simply asking
// again once the GPU had a breather. rc=1/2/5/6 are deterministic (bad args /
// pipeline unavailable / MTLBuffer alloc) and are never retried. Two retries
// with 50 ms then 100 ms backoff bound the extra latency of a persistently
// dead pair at ~150 ms + two matcher calls. Default ON: the retry only
// changes behavior on pairs that are currently dropped fail-closed (pure
// recovery), host CPU-matcher builds never reach this path, and
// OFFICIAL_AETHER_GPU_MATCH_RETRY=0 is the same-binary kill switch (N>0 overrides the
// retry count).
int GpuMatchRetryLimit() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_GPU_MATCH_RETRY")) {
      const int v = std::atoi(e);
      if (v >= 0) return v;
    }
    return 2;
  }();
  return cached;
}

// [PROBE-GATE 2026-08-07] Probe pre-scoring threshold (08-03 recon,
// _host_experiments/probe-gate-recon-20260803): a 512-row even-stride
// subsample of the NEW frame's descriptors matched against the candidate's
// full descriptor set predicts whether the full pair survives TVG with
// AUC 0.9527 (corr 0.9862 with the full match count). Working point from the
// inlier-WEIGHTED cost ledger: probe512 < 3 → skip 42.6% of pairs at 1.75%
// weighted-inlier loss (inside the quality-lane "obs >= 0.98x" gate).
// Semantics here are deliberately deterministic and cross-platform: even
// integer stride over the row index (not the recon's sampling), same
// matcher entry (mutual cross-check included), same Lowe ratio as the full
// pair. DEFAULT OFF (0): unset/0 reproduces the shipped candidate loop
// byte-for-byte. N>0 arms the gate: candidates whose probe score < N never
// enter the full GEMM/TVG/db path (they stay eligible for the idle-repay and
// finalize re-match passes, which is the same fail-open debt route a GPU
// matcher failure already takes). Skipped pairs are counted per frame
// (probe_gate jsonl) and per capture (finalize segments json).
int ProbeGateMin() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_PROBE_GATE_MIN")) {
      const int v = std::atoi(e);
      if (v >= 0) return v;
    }
    return 0;  // DEFAULT OFF — host A/B only until the on-device verdict
  }();
  return cached;
}
constexpr int kProbeGateRows = 512;  // recon-fixed probe height

int GpuMatchGemmPairsRetry(aether_sfm_session* s, int frame1,
                           const uint8_t* d1, int n1, int frame2,
                           const uint8_t* d2, int n2, double max_ratio,
                           uint32_t* out_pairs, int max_pairs,
                           int* out_num_matches) {
  const auto match_once = [&] {
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
    if (s && s->descriptor_residency_nonce != 0 && frame1 >= 0 && frame2 >= 0 &&
        aether_gpu_match_gemm_pairs_resident != nullptr) {
      constexpr uint32_t kImmutableDescriptorGenerationV1 = 1;
      return aether_gpu_match_gemm_pairs_resident(
          s->descriptor_residency_nonce, static_cast<uint32_t>(frame1),
          kImmutableDescriptorGenerationV1, d1, n1,
          static_cast<uint32_t>(frame2), kImmutableDescriptorGenerationV1, d2,
          n2, max_ratio, out_pairs, max_pairs, out_num_matches);
    }
#endif
    return aether_gpu_match_gemm_pairs(d1, n1, d2, n2, max_ratio, out_pairs,
                                       max_pairs, out_num_matches);
  };
  int rc = match_once();
  for (int attempt = 0; rc == 7 && attempt < GpuMatchRetryLimit(); ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50 * (attempt + 1)));
    if (s) ++s->stat_gpu_retry_attempts;
    rc = match_once();
    if (rc == 0 && s) ++s->stat_gpu_retry_recovered;
  }
  return rc;
}

void AppendDescriptorResidencyStats(aether_sfm_session* s) {
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
  if (!s || s->descriptor_residency_nonce == 0 ||
      aether_gpu_match_descriptor_residency_stats == nullptr) {
    return;
  }
  uint64_t hits = 0;
  uint64_t misses = 0;
  uint64_t evictions = 0;
  uint64_t stale_replacements = 0;
  uint64_t upload_bytes = 0;
  uint64_t resident_bytes = 0;
  uint64_t resident_entries = 0;
  uint64_t allocation_failures = 0;
  uint64_t device_resets = 0;
  const int present = aether_gpu_match_descriptor_residency_stats(
      s->descriptor_residency_nonce, &hits, &misses, &evictions,
      &stale_replacements, &upload_bytes, &resident_bytes, &resident_entries,
      &allocation_failures, &device_resets);
  const int enabled = DescriptorResidencyEnabledCore() ? 1 : 0;
  char line[640];
  std::snprintf(
      line, sizeof(line),
      "{\"t\":%lld,\"type\":\"descriptor_residency_v1\",\"schema\":1,"
      "\"enabled\":%d,\"state_present\":%d,\"hits\":%llu,"
      "\"misses\":%llu,\"evictions\":%llu,\"stale_replacements\":%llu,"
      "\"upload_bytes\":%llu,\"resident_bytes\":%llu,"
      "\"resident_entries\":%llu,\"allocation_failures\":%llu,"
      "\"device_resets\":%llu}",
      static_cast<long long>(EpochMs()), enabled, present,
      static_cast<unsigned long long>(hits),
      static_cast<unsigned long long>(misses),
      static_cast<unsigned long long>(evictions),
      static_cast<unsigned long long>(stale_replacements),
      static_cast<unsigned long long>(upload_bytes),
      static_cast<unsigned long long>(resident_bytes),
      static_cast<unsigned long long>(resident_entries),
      static_cast<unsigned long long>(allocation_failures),
      static_cast<unsigned long long>(device_resets));
  AppendMatchFailJsonl(s, line);
#else
  (void)s;
#endif
}

void AppendTailCacheStats(aether_sfm_session* s) {
  if (!s || !TailCacheTraceEnabled()) return;
  const TailCacheModeV1 mode = TailCacheMode();
  std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
  char line[512];
  std::snprintf(
      line, sizeof(line),
      "{\"t\":%lld,\"type\":\"tail_cache_v1\",\"schema\":1,"
      "\"mode\":\"%s\",\"state\":%d,\"generation\":%llu,"
      "\"invalidated_generation\":%llu,\"rebuild_parent_generation\":%llu,"
      "\"dirty_reason\":\"%s\",\"images\":%zu,\"pairs\":%zu}",
      static_cast<long long>(EpochMs()),
      mode == TailCacheModeV1::kOn
          ? "on"
          : (mode == TailCacheModeV1::kShadow ? "shadow" : "off"),
      static_cast<int>(s->tail_cache_epoch.state()),
      static_cast<unsigned long long>(s->tail_cache_epoch.generation()),
      static_cast<unsigned long long>(
          s->tail_cache_epoch.invalidated_generation()),
      static_cast<unsigned long long>(
          s->tail_cache_epoch.rebuild_parent_generation()),
      TailCacheDirtyReasonName(s->tail_cache_epoch.dirty_reason()),
      s->tail_cache_epoch.image_count(), s->tail_cache_epoch.pair_count());
  AppendMatchFailJsonl(s, line);
}

// Guided-matcher sibling (same rc semantics; used by the enrichment verify
// chain, where a transient rc=7 previously failed the whole spatial pair).
int GpuMatchGuidedRetry(aether_sfm_session* s, const uint8_t* d1, int n1,
                        const float* xy1, const uint8_t* d2, int n2,
                        const float* xy2, double max_ratio,
                        const float* matrix12, const float* matrix21,
                        int guide_mode, float max_residual, uint32_t* out_pairs,
                        int max_pairs, int* out_num_matches) {
  int rc = aether_gpu_match_gemm_pairs_guided(
      d1, n1, xy1, d2, n2, xy2, max_ratio, matrix12, matrix21, guide_mode,
      max_residual, out_pairs, max_pairs, out_num_matches);
  for (int attempt = 0; rc == 7 && attempt < GpuMatchRetryLimit(); ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50 * (attempt + 1)));
    if (s) ++s->stat_gpu_retry_attempts;
    rc = aether_gpu_match_gemm_pairs_guided(
        d1, n1, xy1, d2, n2, xy2, max_ratio, matrix12, matrix21, guide_mode,
        max_residual, out_pairs, max_pairs, out_num_matches);
    if (rc == 0 && s) ++s->stat_gpu_retry_recovered;
  }
  return rc;
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

// [SCAN-MATRIX ENV 2026-07-11] Threshold-scan hooks for the host gate matrix.
// Same pattern as TriMinAngleDeg / FinalizeBaThreads: getenv once (static
// cache), default == the shipped constant, so an UNSET environment is
// bit-identical to the shipped binary (the tri-angle defaults return the exact
// radian literal, not a fresh degree→radian conversion). Context: every one of
// these gates was calibrated in the pre-DSP-fix era; the hooks let the scan
// matrix re-price them per-arm without rebuilding. The matrix's first verdict
// (T20 2026-07-11) re-priced all four tri-angle defaults 3.0°→2.0°; env
// overrides remain live for future re-pricing.
double EnvGateDouble(const char* name, double fallback) {
  const char* e = std::getenv(name);
  if (e && e[0]) {
    const double v = std::atof(e);
    if (v > 0.0) return v;
  }
  return fallback;
}

// ① OFFICIAL_AETHER_LIVE_TRI_MIN_ANGLE — live add_frame 2-view CREATION parallax gate,
//    degrees in the env, radians out. Default = shipped 2.0°.
//    [T20 2026-07-11] 3.0°→2.0° per the tri-angle scan matrix (cap44/cap45
//    db-replay, all four gates moved together): T20 recovered the point count
//    lost to the DSP-fix descriptors (+10-20%) with reproj/thickness inside
//    the judge gates; T15 re-admitted low-parallax fuzz, T25 kept losing
//    points. Combined-verified with the 6-scale DSP config before shipping.
double LiveCreateTriMinAngleRad() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_LIVE_TRI_MIN_ANGLE");
    if (e && e[0]) {
      const double deg = std::atof(e);
      if (deg > 0.0) return deg * M_PI / 180.0;
    }
    return 0.03490658503988659;  // shipped 2.0° literal (T20)
  }();
  return cached;
}

// ② OFFICIAL_AETHER_GROW_REPROJ_PX — live TVG-inlier grow reprojection gate. Default 14.
double LiveGrowMaxReprojPx() {
  static const double cached = EnvGateDouble("OFFICIAL_AETHER_GROW_REPROJ_PX", 14.0);
  return cached;
}

// ②b OFFICIAL_AETHER_CREATE_REPROJ_PX — live NEW-POINT reprojection gate.
// Default 10 (unchanged shipped value; unset == byte-identical behaviour).
// Exists so the create gate can be swept the way the grow gate already can:
// a 2026-07-26 provenance run showed 86.6% of the delivered cloud is authored
// by this live triangulator and that 27.7% of what it creates is then thrown
// away by official filtering (filter_max_reproj_error 4.0 / filter_min_tri_angle
// 1.5deg). Tightening the GROW gate made that worse, not better — grow and
// create compete, so an observation refused by grow spawns a fresh low-parallax
// point instead. This knob tests the other half of that hypothesis.
double LiveCreateMaxReprojPx() {
  static const double cached =
      EnvGateDouble("OFFICIAL_AETHER_CREATE_REPROJ_PX", 10.0);
  return cached;
}

// ②c OFFICIAL_AETHER_OFFICIAL_TRIANGULATE — call upstream
// IncrementalMapper::TriangulateImage on each accepted frame, the way
// controllers/incremental_pipeline.cc:817 does after registering an image.
// DEFAULT OFF: unset leaves the shipped path byte-identical. The point of the
// knob is to measure what the official triangulator finds on ARKit-registered
// poses that the hand-written create/grow/merge misses.
bool OfficialTriangulateImageEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_OFFICIAL_TRIANGULATE");
    return e && e[0] == '1';
  }();
  return cached;
}

// ②d OFFICIAL_AETHER_SELFDEV_TRIANGULATE=0 — turn OFF the hand-written live
// create/grow/merge and leave point authoring entirely to upstream
// IncrementalMapper::TriangulateImage (②c). DEFAULT ON: unset keeps the
// shipped behaviour. Matching and the db writes are NOT affected — the
// official triangulator consumes exactly those correspondences — only the
// three live_recon mutation sites (AddPoint3D / AddObservation /
// MergePoints3D) are skipped. Set ②c and clear this to get the pure
// upstream-triangulation arm.
bool SelfDevLiveTriangulationEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_SELFDEV_TRIANGULATE");
    return !(e && e[0] == '0');
  }();
  return cached;
}

// ②e OFFICIAL_AETHER_TRI_IGNORE_2VIEW=0 — let the OFFICIAL triangulator keep
// two-view feature tracks. Upstream default is true ("By default, COLMAP
// ignores two-view feature tracks in triangulation, resulting in fewer 3D
// points than possible" — official FAQ), which confounded the arm-E
// self-vs-official comparison: the official triangulator never even TRIED the
// 2-view geometry that makes up most of the delta. Unset keeps upstream's
// default, so shipped behaviour is byte-identical.
bool TriIgnoreTwoViewTracks() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_TRI_IGNORE_2VIEW");
    return !(e && e[0] == '0');
  }();
  return cached;
}

// [BIRTH-GATE-AB 2026-08-07] OFFICIAL_AETHER_BIRTH_MIN_TRI_ANGLE — host A/B
// 专用"出生门"旋钮:一个 env(度)同时覆盖两处
//   ① 点出生:triangulation.min_angle(官方 IncrementalTriangulator 的
//      CREATION 视差角门,上游默认 1.5°;finalize phase1/phase2 已被
//      OFFICIAL_AETHER_TRI_MIN_ANGLE(_P2) 抬到 2.0°,而流式 TriangulateImage
//      的 official_options 构造点一直吃上游默认 1.5°);
//   ② BA 后过滤:mapper.filter_min_tri_angle(FilterPoints/FilterAllPoints3D
//      的存留视差角门,上游默认 1.5°,本文件此前从未改过)。
// 教条依据=鬼层终审"根治只在 stage-1":交付层 3° 视差角过滤
// (DeliverMinTriAngleDeg)是事后删,本实验把同一把刀前移到出生/BA 存留时。
// 风险=低视差场景注册/增长变脆(MP-SfM 论文警告),故仅 host A/B。
// DEFAULT UNSET(或 <=0)⇒ 两处全部保持现值,逐字节复现出货行为。
double BirthMinTriAngleDeg() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_BIRTH_MIN_TRI_ANGLE");
    if (e && e[0]) {
      const double d = std::atof(e);
      if (d > 0.0) return d;
    }
    return 0.0;  // unset ⇒ 不覆盖
  }();
  return cached;
}
// [BIRTH-GATE-AB 2026-08-07] 统一施加点:本文件每个
// colmap::IncrementalPipelineOptions 构造点在配置完成后调用一次。env 未设时
// 严格 no-op(单变量纪律)。
void ApplyBirthGateAB(colmap::IncrementalPipelineOptions* o) {
  const double b = BirthMinTriAngleDeg();
  if (b > 0.0) {
    o->triangulation.min_angle = b;        // ① 出生门
    o->mapper.filter_min_tri_angle = b;    // ② BA 后 filter 门
  }
}

// [A1B-V5 2026-07-27] Two controlled-comparison knobs for the async
// preview-BA arm (defined here because the finalize apvba_summary emit needs
// them before the arm's own code). The v4 matrix cleared every engineering
// gate but left a reproducible point delta whose cause it could NOT isolate,
// because two things changed at once.
//   _PROPAGATE=0  — turn the ORB-SLAM-style correction propagation OFF while
//     leaving everything else identical (= v3 semantics). The only way to
//     price propagation on its own; v4 shipped it together with v3's
//     zero-sqlite + backoff, which also moved every snapshot boundary.
//   _MATCH_CADENCE=1 — kick at most ONE background pass per successful
//     publish. Without it the arms are not comparable at all: a harvest-less
//     tick returns ERR_NOT_REGISTERED, the Dart publish policy therefore does
//     NOT reset its growth baselines, so it re-triggers every frame and the
//     async arm kicks back-to-back — i.e. it runs strictly MORE global BA
//     than the sync arm, and more BA means more FilterPoints/FilterFrames
//     deletions. That confound is the leading explanation for the v4 delta,
//     and this knob is what tests it.
bool AsyncPreviewBaPropagate() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ASYNC_PREVIEW_BA_PROPAGATE");
    return !(e && e[0] == '0');
  }();
  return cached;
}
bool AsyncPreviewBaMatchCadence() {
  static const bool cached = [] {
    const char* e =
        std::getenv("OFFICIAL_AETHER_ASYNC_PREVIEW_BA_MATCH_CADENCE");
    return e && e[0] == '1';
  }();
  return cached;
}
// [A1B-V6 2026-07-27] _PARAM_ONLY=1 — the background pass solves PARAMETERS
// ONLY (a single official AdjustGlobalBundle) and performs NO structural
// mutation: no CompleteAndMergeTracks, no FilterPoints, no FilterFrames, no
// retriangulation. Provenance: the v5 controlled 2x2 isolated the async
// arm's entire point delta to a structural residual — the fingerprint was
// 2-view deletions + track-merge differences, i.e. STRUCTURE decided on a
// stale snapshot — while the cadence and propagation factors measured
// +0.005pp/+0.008pp. Parameters perturbed a few frames late wash out in the
// finalize's own stage-1/stage-2 convergence; structural divergence does
// not. So v6 defers every structural decision to the synchronous finalize
// (which redoes them from scratch over the full db anyway) and lets the
// background thread touch only pose/point values.
bool AsyncPreviewBaParamOnly() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ASYNC_PREVIEW_BA_PARAM_ONLY");
    return e && e[0] == '1';
  }();
  return cached;
}

// ③ OFFICIAL_AETHER_TD_TRI_ANGLE / OFFICIAL_AETHER_TD_REPROJ_PX — RestoreTemporalDetail gates
//    (tri-angle degrees in / radians out, reproj px). Defaults 2.0° / 3 px.
//    [T20 2026-07-11] 3.0°→2.0°, moved in lock-step with the other three
//    tri-angle gates (see LiveCreateTriMinAngleRad).
double TemporalDetailTriMinAngleRad() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_TD_TRI_ANGLE");
    if (e && e[0]) {
      const double deg = std::atof(e);
      if (deg > 0.0) return deg * M_PI / 180.0;
    }
    return 0.03490658503988659;  // shipped 2.0° literal (T20)
  }();
  return cached;
}
double TemporalDetailMaxReprojPx() {
  static const double cached = EnvGateDouble("OFFICIAL_AETHER_TD_REPROJ_PX", 3.0);
  return cached;
}

// ④ OFFICIAL_AETHER_ENRICH_PAIR_CAP — spatial-revisit enrichment budget override.
//    UNSET (returns 0) = legacy behavior exactly: anchor budget 720, hard cap
//    1200, quadratic fallback only when no spatial region confirmed, and the
//    ACTUAL attempted-pair count is whatever the anchor funnel yields (cap45
//    device run: 7). SET to N: N replaces the hard cap AND acts as a floor —
//    AddSpatialRevisitMatches appends a top-up pass over the remaining
//    beyond-K pairs (closest camera centers first) until N pairs were actually
//    attempted. Every top-up pair still passes the unchanged verification
//    chain (raw match ≥15 → TVG RANSAC ≥15 @10% → guided re-match → strict
//    TVG ≥30 inliers @1px, ratio ≥0.25) before it reaches sqlite.
int EnrichPairCapOverride() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_ENRICH_PAIR_CAP")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 0;
  }();
  return cached;
}
int SpatialTotalPairBudget() {
  const int cap = EnrichPairCapOverride();
  // [KNIFE-A ③ 2026-07-11] max(default, N) semantics: OFFICIAL_AETHER_ENRICH_PAIR_CAP=N
  // is a top-up FLOOR and must never REDUCE the legacy 1200 hard cap. The
  // joint scan hit exactly this trap: N=300 silently shrank the anchor budget
  // (min(720, 300)) and the total budget, so the "extra enrichment" arm was
  // simultaneously STARVING the anchor funnel it was supposed to top up.
  // UNSET stays bit-identical to the shipped binary.
  return cap > 0 ? std::max(cap, kSpatialMaxTotalPairs) : kSpatialMaxTotalPairs;
}

// [KNIFE-A 2026-07-11] Env opt-ins for the 2-view upgrade package. All three
// default OFF: an unset environment is bit-identical to the shipped binary.
// ① RestoreTemporalDetail grow acceptance switches from "3 px at the CURRENT
//    (never-refined) position" to a union refit over track+candidate — the
//    CanMergeLivePoints recipe — installing the refit position on success.
bool TdGrowRefitEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_TD_GROW_REFIT");
    return e && e[0] == '1';
  }();
  return cached;
}
// ② finalize-tail TrackUpgrade pass over the delivered model's 2-view /
//    low-parallax points (see UpgradeLowParallaxTracks).
bool TrackUpgradeEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_TRACK_UPGRADE");
    return e && e[0] == '1';
  }();
  return cached;
}
// ③ enrichment top-up ordering switches from camera-center proximity to the
//    2-view-upgrade-potential score (see EnrichTargetHint / ScoreEnrichPair).
bool EnrichTargetedEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ENRICH_TARGETED");
    return e && e[0] == '1';
  }();
  return cached;
}

// [GUIDED-TEMPORAL 2026-07-12] OFFICIAL_AETHER_GUIDED_TEMPORAL=1 opts the LIVE temporal
// add_frame matching into the epipolar-guided re-match chain already shipped on
// the spatial-enrichment path (RunGuidedMatch). DEFAULT OFF: an unset
// environment skips the guided branch entirely and is bit-identical to the
// shipped binary. The lever targets Lambertian weak/repetitive texture, where
// the plain 0.7 Lowe ratio kills geometrically-correct matches (2nd-NN ≈
// 1st-NN); the E/F epipolar band disambiguates them. It does NOT help
// view-dependent reflections (appearance itself is wrong) and never relaxes a
// downstream gate — see the call site in AddFrameFeaturesImpl.
bool GuidedTemporalEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_GUIDED_TEMPORAL");
    return e && e[0] == '1';
  }();
  return cached;
}

// [P2-FRAG-MERGE 2026-07-11] Finalize-tail duplicate-fragment merge pass
// (see MergeFragmentTracks). Default OFF: an unset environment is
// bit-identical to the shipped binary.
bool FragMergeEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_FRAG_MERGE");
    return e && e[0] == '1';
  }();
  return cached;
}
// Merge acceptance reproj gate (px). Default = the RestoreTemporalDetail /
// TrackUpgrade gate (3 px). OFFICIAL_AETHER_FRAG_MERGE_REPROJ_PX prices a wider gate
// on the host matrix (live merges use 8 px, the mapper's Complete uses 4 px;
// 83% of host merge attempts fail the 3 px all-observation fit) without
// touching the default arm.
double FragMergeMaxReprojPx() {
  static const double cached =
      EnvGateDouble("OFFICIAL_AETHER_FRAG_MERGE_REPROJ_PX", 0.0);
  return cached;
}
// [P2-FRAG-MERGE-REPRICE 2026-07-11] OFFICIAL_AETHER_FRAG_MERGE_MIN_THETA_DEG: the
// merged union's θ_max must ALSO reach at least this many degrees (on top of
// the strictly-beats-both-fragments rule). Motivation (cap47 forensic): the
// ghost second floor layer is built from merges whose union θ_max "rises"
// but stays in the low-parallax depth-ambiguity band — coagulating the
// diffuse noise shell into a coherent 2-3.5cm ghost plane (FRAG_MERGE@4px:
// ghost 4.3% → 6.7% of the floor slab). A floor on the ABSOLUTE post-merge
// parallax only banks merges whose union genuinely leaves the ambiguity
// band. Default 0 = gate off, bit-identical to the current knife.
double FragMergeMinThetaDeg() {
  static const double cached =
      EnvGateDouble("OFFICIAL_AETHER_FRAG_MERGE_MIN_THETA_DEG", 0.0);
  return cached;
}
// [P2-FRAG-MERGE-REPRICE 2026-07-11] Same MIN_THETA floor for the KNIFE-A ①
// grow refit (OFFICIAL_AETHER_TD_GROW_REFIT): a refit ACCEPT additionally requires the
// union's θ_max at the refit position to reach this many degrees; otherwise
// the candidate falls through to the legacy gates (the shipped acceptance),
// so the arm stays a superset of the default arm. Default 0 = off.
double TdGrowRefitMinThetaDeg() {
  static const double cached =
      EnvGateDouble("OFFICIAL_AETHER_TD_GROW_REFIT_MIN_THETA_DEG", 0.0);
  return cached;
}

// [P1-STAGE1-RECIPE 2026-07-11] Stage-1 refinement round/ftol overrides for
// the finalize-speedup pricing matrix. Context: on device (cap47) stage 1
// burned 5 rounds × thermal-slowed BA = 82.5 s and — through the AUTO enrich
// time gate, whose window is "stage-1 block finished" — kept the enrichment
// accepting new attempts for the whole 83.7 s. Capping stage-1 rounds ends
// BOTH earlier; the remainder formula hands the unused rounds to stage 2
// (converge-stop bounded) unchanged.
//   OFFICIAL_AETHER_STAGE1_ROUNDS_CAP=N (>0): stage-1 loop bound becomes
//     min(ba_global_max_refinements, N). Unset/0 = shipped behavior.
//   OFFICIAL_AETHER_STAGE1_FTOL=X (>0): stage-1 solves use ceres
//     function_tolerance=X instead of the shipped ba_global_function_
//     tolerance (1e-6). Stage 2 is NOT touched. Unset/0 = shipped.
// (记忆锚:rounds3+ftol 组合在 Mac 'o' 收尾管线 −59% 全门过;stage1 语境
// 由本矩阵重验,默认零漂移。)
int Stage1RoundsCap() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_STAGE1_ROUNDS_CAP")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 0;
  }();
  return cached;
}
double Stage1FtolOverride() {
  static const double cached = EnvGateDouble("OFFICIAL_AETHER_STAGE1_FTOL", 0.0);
  return cached;
}

// [BA-STAGE1-FULL 2026-07-26, signed] The cap43-era stage-1 protections
// (UTILITY QoS + halved ceres threads) assumed the enrichment was the
// finalize critical path. cap_1785078141726265 proved that inverted after
// the v2 matcher: enrich 35.6s < stage-1 46.7s, gate_wait=0 — the
// protections were taxing the true critical path 2x to yield to the side
// with 11s of slack. Defaults flip to full speed; the legacy posture stays
// one env away for the heavy-revisit shape (cap46: enrich 137.9s vs window
// 58.1s) where the old reasoning still holds.
bool Stage1HalfThreadsLegacy() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_STAGE1_HALF_THREADS");
    return e && e[0] == '1';
  }();
  return cached;
}
bool Stage1UtilityQosLegacy() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_STAGE1_UTILITY_QOS");
    return e && e[0] == '1';
  }();
  return cached;
}

// [QUAD-PIPELINE 2026-07-26, signed] Order-preserving matcher prefetch for
// the quadratic enrichment pass. Provenance: upstream COLMAP's own matching
// architecture IS a matcher→verifier pipeline (vendored
// colmap/controllers/feature_matching_utils.h:103-106, JobQueue chain with
// concurrent matcher and verifier workers) — the serial per-pair
// match→TVG loop in AddOfficialQuadraticPairs was our own simplification.
// This variant keeps the EXACT bar the full-pipeline investigation's A5
// clause demands: the GPU matcher (deterministic Metal + mutual
// cross-check, no PRNG) runs on a prefetch thread, while TVG estimation and
// all db writes stay on the enrichment thread in todo order — the RANSAC
// thread-local PRNG stream is byte-identical to the serial loop.
// cap_1785082211938612 measured the serial loop at 61.2s (444 pairs,
// ~70-90ms GPU + ~40-60ms CPU each, fully serialized) with stage-1 waiting
// 29s on it; overlapped, the pass approaches max(GPU_total, CPU_total).
// OFFICIAL_AETHER_QUAD_PIPELINE=0 restores the serial loop (also the
// automatic fallback for resume sessions, whose db-load LRU cache must not
// be read across threads).
bool QuadPipelineEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_QUAD_PIPELINE");
    return !(e && e[0] == '0');
  }();
  return cached;
}

// ── [EPI-PRIOR 2026-07-27] ARKit epipolar-prior guided matching — EXPERIMENT
// ARM, DEFAULT OFF (unset env ⇒ byte-identical shipped behaviour). The
// sign-off dossier knife: synthesize E = EssentialMatrixFromPose(
// cam_b_from_cam_a) from the FED ARKit poses (FrameRecord.cam_from_world is
// the raw prior — BA never writes it back), then run the EXISTING
// COLMAP-parity guided kernel (guideMode=1, PrepareGuidedGeometry calibrated
// path) so only candidates inside the epipolar band pay the descriptor
// distance. Provenance: [官方] colmap MatchGuided semantics (the kernel is
// already bit-parity with it); [调查 Track4] COLMAP guided accepts external
// TwoViewGeometry / ORB-SLAM3-style widen-then-fallback / Sensors-2016
// prior-noise sensitivity (95%→60% at 3σ ⇒ band must be gap-adaptive and
// fallback mandatory). Classification: APPROXIMATE (restricting candidates
// changes the Lowe-ratio denominator) — ships ONLY through the noise-band
// quality gates + user sign-off; cap7 sized the prize (~300s of the 500s
// wait is thermally-throttled GPU matching; band keep-fraction ~1-3% cuts
// that FLOP nearly proportionally).
//   OFFICIAL_AETHER_EPI_PRIOR_MATCH=1     master switch (default OFF)
//   OFFICIAL_AETHER_EPI_BAND_BASE_PX      band at gap 0 (default 30)
//   OFFICIAL_AETHER_EPI_BAND_PER_GAP_PX   widening per frame of gap (default 5)
//   OFFICIAL_AETHER_EPI_BAND_MAX_PX       band ceiling (default 150)
//   OFFICIAL_AETHER_EPI_FALLBACK_MIN      guided matches below this → redo
//                                         the pair with the full GEMM (150)
bool EpiPriorMatchEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_EPI_PRIOR_MATCH");
    return e && e[0] == '1';
  }();
  return cached;
}
double EpiBandBasePx() {
  static const double cached = EnvGateDouble("OFFICIAL_AETHER_EPI_BAND_BASE_PX", 30.0);
  return cached;
}
double EpiBandPerGapPx() {
  static const double cached =
      EnvGateDouble("OFFICIAL_AETHER_EPI_BAND_PER_GAP_PX", 5.0);
  return cached;
}
double EpiBandMaxPx() {
  static const double cached = EnvGateDouble("OFFICIAL_AETHER_EPI_BAND_MAX_PX", 150.0);
  return cached;
}
int EpiFallbackMinMatches() {
  static const int cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_EPI_FALLBACK_MIN");
    const int v = e ? std::atoi(e) : 150;
    return v > 0 ? v : 150;
  }();
  return cached;
}

// [INCREMENTAL-GLOBAL-BA 2026-07-13] Rolling capture-time global BA over
// live_recon (DEFAULT OFF). See the session fields + MaybeIncrementalGlobalRefine
// + the finalize collapse in RefineGlobalBA. All four knobs are env-gated so the
// cap51 host A/B can sweep cadence/window/finalize-rounds without a rebuild.
//   OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1        enable (default OFF → zero ship impact)
//   OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA_EVERY_N  refine cadence, registered frames (25)
//   OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA_WINDOW   free-pose sliding-window size (40)
//   OFFICIAL_AETHER_INCREMENTAL_FINALIZE_ROUNDS    finalize global-BA round cap once the
//                                         rolling refine has run (2 = "1-2 轮收尾")
// [E3 2026-08-04] Streaming local-BA scheduling knobs. EXPERIMENT ONLY: with
// neither variable set these reproduce the shipped behaviour exactly (enabled,
// every frame), so installing them is a no-op for production.
// Why they exist: the windowed local refinement measures 56.5% of stream cost,
// and the founders' own published architecture runs NO bundle adjustment inside
// the incremental loop — RC exposes only a "Final model optimization", which is
// itself user-disableable (sfmFinalModelOptimizationDraftMode). That made the
// comparison purely theoretical until now.
// ⚠️ Changing reconstruction output is a semantic change: host runs are
// diagnostic only and can never select a production winner.
bool StreamingLocalBaEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_LOCAL_BA");
    return !(e && e[0] == '0');  // default ON; only an explicit "0" disables
  }();
  return cached;
}

int StreamingLocalBaPeriod(int session_value) {
  static const int env_period = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_BA_EVERY_N")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 0;  // 0 = not overridden; the session field decides
  }();
  if (env_period > 0) return env_period;
  return session_value > 0 ? session_value : 1;
}

bool IncrementalGlobalBaEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA");
    return e && e[0] == '1';
  }();
  return cached;
}
int IncrementalGlobalBaEveryN() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA_EVERY_N")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 25;  // ~one bounded refine per 25 registered frames
  }();
  return cached;
}
int IncrementalGlobalBaWindow() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA_WINDOW")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 40;  // most-recent 40 frames get FREE poses; older = fixed anchors
  }();
  return cached;
}
int IncrementalFinalizeRounds() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_INCREMENTAL_FINALIZE_ROUNDS")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 2;  // finalize global BA rounds once the rolling refine pre-converged
  }();
  return cached;
}

// [P1-ENRICH-BUDGET 2026-07-11] Finalize-enrichment TIME gate. Target: the
// cap46 device finalize, where the GPU db enrichment (dominated by 336
// starved-frame re-match pairs at ~410 ms each on a still-hot GPU) ran
// 137.9 s against a 58.1 s stage-1 window — enrichment became the finalize
// critical path by +80 s. The gate stops STARTING new matcher attempts once
// the budget is exhausted; whatever pair is in flight completes and is kept.
//
// OFFICIAL_AETHER_ENRICH_TIME_BUDGET_MS:
//   unset      → AUTO: the budget is the ACTUAL stage-1 refinement window —
//                enrichment stops accepting new attempts once the refine
//                worker's stage-1 block has finished AND at least
//                kEnrichAutoFloorMs have elapsed (the floor protects healthy
//                captures from an early-converging stage 1; host D arms run
//                their whole enrichment in 10-23 s, well under it). Where no
//                stage 1 runs (OFFICIAL_AETHER_FINALIZE_NO_OVERLAP=1, snapshot
//                failure, resume/sync serial paths) AUTO never truncates —
//                those paths keep legacy unlimited semantics.
//   N > 0      → fixed wall budget of N ms for the enrichment passes (any
//                path), for the host truncation-cost curve.
//   N <= 0     → OFF: legacy unlimited (same-binary revert).
//
// Debt priority under an armed gate: the enrichment thread runs the starved-
// frame re-match FIRST (registration-critical repair pairs, gap-ascending —
// the most valuable debt) and the spatial-revisit pass second (anchor funnel
// rank-first, then the KNIFE-A ③ targeted top-up). With the gate off the
// legacy order is preserved bit-identically.
enum class EnrichBudgetMode { kOff = 0, kAuto = 1, kFixed = 2 };
constexpr double kEnrichAutoFloorMs = 30000.0;

EnrichBudgetMode EnrichBudgetModeOf() {
  static const EnrichBudgetMode cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ENRICH_TIME_BUDGET_MS");
    if (!e || !e[0]) return EnrichBudgetMode::kAuto;
    const long v = std::atol(e);
    if (v > 0) return EnrichBudgetMode::kFixed;
    return EnrichBudgetMode::kOff;
  }();
  return cached;
}

double EnrichBudgetFixedMs() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ENRICH_TIME_BUDGET_MS");
    const long v = e && e[0] ? std::atol(e) : 0;
    return v > 0 ? static_cast<double>(v) : 0.0;
  }();
  return cached;
}

// True once the enrichment passes must stop STARTING new matcher attempts.
// Reads enrich_start_ms (written by the enriching thread itself before the
// passes start) and the stage1_done atomic (written by the refine worker).
bool EnrichBudgetExhausted(aether_sfm_session* s) {
  if (!s || s->enrich_start_ms <= 0.0) return false;
  switch (EnrichBudgetModeOf()) {
    case EnrichBudgetMode::kOff:
      return false;
    case EnrichBudgetMode::kFixed:
      return NowMs() - s->enrich_start_ms > EnrichBudgetFixedMs();
    case EnrichBudgetMode::kAuto:
      return s->enrich_stage1_done.load(std::memory_order_relaxed) &&
             NowMs() - s->enrich_start_ms > kEnrichAutoFloorMs;
  }
  return false;
}

// Whether the gate can truncate THIS run (decides the debt-first order flip;
// stage1_planned = the refine worker created a stage-1 cache snapshot).
bool EnrichBudgetArmed(bool stage1_planned) {
  switch (EnrichBudgetModeOf()) {
    case EnrichBudgetMode::kOff:
      return false;
    case EnrichBudgetMode::kFixed:
      return true;
    case EnrichBudgetMode::kAuto:
      return stage1_planned;
  }
  return false;
}

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

// [E1 2026-08-04] Active connected-component count over the live pair graph.
// A single capture session must resolve to exactly ONE component; two or more
// means the pair topology fragmented, which is a stage-1 defect rather than a
// quality tradeoff. Havlena's Table 8.1 reports this next to wall clock and
// registered count, and it was the one column the frame_split record never
// carried — so a fragmented session was indistinguishable from a healthy one in
// telemetry. Union-find over the resolved-pair set costs microseconds against a
// ~1 s frame; this is pure observation and changes no behaviour.
int CountActiveComponentsV1(const aether_sfm_session& s) {
  const int n = static_cast<int>(s.frames.size());
  if (n <= 0) return 0;
  std::vector<int> parent(static_cast<size_t>(n));
  for (int i = 0; i < n; ++i) parent[static_cast<size_t>(i)] = i;
  const auto find = [&parent](int x) {
    while (parent[static_cast<size_t>(x)] != x) {
      parent[static_cast<size_t>(x)] =
          parent[static_cast<size_t>(parent[static_cast<size_t>(x)])];
      x = parent[static_cast<size_t>(x)];
    }
    return x;
  };
  for (const uint64_t key : s.live_pairs_done) {
    const int a = static_cast<int>(key >> 32);
    const int b = static_cast<int>(key & 0xFFFFFFFFULL);
    if (a < 0 || a >= n || b < 0 || b >= n) continue;
    const int ra = find(a);
    const int rb = find(b);
    if (ra != rb) parent[static_cast<size_t>(ra)] = rb;
  }
  // Count distinct roots reached from ACTIVE frames only. Withdrawn frames
  // (image_id == 0) and featureless frames are not vertices of the graph, but a
  // withdrawn frame can still be the union-find root of a live set, so the
  // roots must be collected rather than tested with find(i) == i.
  std::unordered_set<int> roots;
  for (int i = 0; i < n; ++i) {
    const FrameRecord& frame = s.frames[static_cast<size_t>(i)];
    if (frame.image_id == 0 || frame.n_keypoints <= 0) continue;
    roots.insert(find(i));
  }
  return static_cast<int>(roots.size());
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

void SetAllCameraIntrinsicsConstant(
    const colmap::Reconstruction& reconstruction,
    const std::vector<colmap::image_t>& image_ids,
    colmap::BundleAdjustmentConfig& config) {
  std::unordered_set<colmap::camera_t> camera_ids;
  camera_ids.reserve(image_ids.size());
  for (const colmap::image_t image_id : image_ids) {
    if (!reconstruction.ExistsImage(image_id)) continue;
    const colmap::Image& image = reconstruction.Image(image_id);
    if (camera_ids.insert(image.CameraId()).second) {
      config.SetConstantCamIntrinsics(image.CameraId());
    }
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
    CopyNormalizedPoints(a.camera, a.points, xy_a);
    CopyNormalizedPoints(b.camera, b.points, xy_b);
    CopyMatrixRowMajor(*geometry.E, matrix_ab);
    CopyMatrixRowMajor(geometry.E->transpose(), matrix_ba);
    // Match COLMAP's native two-view convention for unequal cameras: average
    // each camera's pixel-to-normalized threshold.
    const double normalized_error =
        0.5 * (a.camera.CamFromImgThreshold(kGuidedMaxErrorPixels) +
               b.camera.CamFromImgThreshold(kGuidedMaxErrorPixels));
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

// Geometry-guided re-match core. Shared by the spatial-enrichment verify chain
// (VerifySpatialPair) and the live temporal add_frame path
// (AddFrameFeaturesImpl, OFFICIAL_AETHER_GUIDED_TEMPORAL=1). Pure w.r.t. session state
// except for the rc=7 retry counters inside GpuMatchGuidedRetry — the
// guided-pair/inlier telemetry is booked by each caller so spatial and temporal
// totals stay separable.
bool RunGuidedMatch(aether_sfm_session* s,
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
  // [P1-RC7-RETRY] transient rc=7 gets two backoff retries before the pair
  // fails closed (see GpuMatchGuidedRetry).
  const int rc = GpuMatchGuidedRetry(
      s, a.descriptors.data(), a.n_keypoints, xy_a.data(),
      b.descriptors.data(), b.n_keypoints, xy_b.data(), kSpatialMatchRatio,
      matrix_ab.data(), matrix_ba.data(), guide_mode, max_residual,
      pair_buf.data(), cap, &num_matches);
  if (rc != 0) return false;

  guided_matches->resize(num_matches);
  for (int m = 0; m < num_matches; ++m) {
    (*guided_matches)[m].point2D_idx1 = pair_buf[2 * m];
    (*guided_matches)[m].point2D_idx2 = pair_buf[2 * m + 1];
  }
  return true;
}

// [EPI-PRIOR 2026-07-27] ARKit-prior guided match for one pair (see the env
// block for provenance and classification). Returns true with pair_buf/
// num_matches filled when the guided path succeeded AND cleared the
// fallback gate; false ⇒ caller runs the unchanged full GEMM (missing
// poses / resume frames / rc failure / match-count collapse all land here —
// the ORB-SLAM3-style safety net).
bool ArkitGuidedMatchPair(aether_sfm_session* s, const FrameRecord& a,
                          const FrameRecord& b, int gap, double ratio,
                          uint32_t* pair_buf, int cap, int* num_matches) {
  if (!s || !pair_buf || !num_matches || cap <= 0) return false;
  if (!a.has_pose || !b.has_pose) return false;
  if (a.descriptors.empty() || b.descriptors.empty()) return false;
  if (!s->options.use_gpu_match ||
      aether_gpu_match_gemm_pairs_guided == nullptr) {
    return false;
  }
  colmap::TwoViewGeometry geo;
  geo.config = colmap::TwoViewGeometry::CALIBRATED;
  geo.E = colmap::EssentialMatrixFromPose(b.cam_from_world *
                                          colmap::Inverse(a.cam_from_world));
  std::vector<float> xy_a;
  std::vector<float> xy_b;
  std::array<float, 9> matrix_ab{};
  std::array<float, 9> matrix_ba{};
  int guide_mode = 0;
  float max_residual = 0.0f;
  if (!PrepareGuidedGeometry(s, a, b, geo, &xy_a, &xy_b, &matrix_ab,
                             &matrix_ba, &guide_mode, &max_residual)) {
    return false;
  }
  // Gap-adaptive band (Sensors-2016: fixed narrow bands break when the
  // prior degrades; ARKit relative-pose error grows with the frame gap).
  const double band_px =
      std::min(EpiBandMaxPx(), EpiBandBasePx() + EpiBandPerGapPx() * gap);
  const double normalized =
      0.5 * (a.camera.CamFromImgThreshold(band_px) +
             b.camera.CamFromImgThreshold(band_px));
  max_residual = static_cast<float>(normalized * normalized);
  ++s->stat_epi_attempted;
  const int rc = GpuMatchGuidedRetry(
      s, a.descriptors.data(), a.n_keypoints, xy_a.data(),
      b.descriptors.data(), b.n_keypoints, xy_b.data(), ratio,
      matrix_ab.data(), matrix_ba.data(), guide_mode, max_residual, pair_buf,
      cap, num_matches);
  if (rc != 0) {
    ++s->stat_epi_fallback;
    return false;
  }
  if (*num_matches < EpiFallbackMinMatches()) {
    ++s->stat_epi_fallback;
    *num_matches = 0;
    return false;
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

  // [RESUME 2026-07-10, CORRECTED 2026-08-04] This used to state that
  // resume-rebuilt FrameRecords carry NO in-memory descriptors/keypoints. That
  // stopped being true when the mandatory-ARKit recovery contract made
  // RebuildFrameRecordsForResume read keypoints+descriptors back in order to
  // recompute each frame's identity digest: ACTIVE resumed frames now arrive
  // fully featured, so resumed pairs really do reach the matchers here instead
  // of being confined to the existing-matches fast path. Withdrawn frames are
  // the only ones still guaranteed empty (RebuildFrameRecordsForResume mirrors
  // remove_frame and clears them). The guard stays as fail-closed defense
  // against a null descriptor pointer, but it is no longer the resume gate it
  // was written to be — a behaviour change that is NOT covered by the
  // host-verification evidence for mandatory-arkit-gravity-v1.
  if (a.descriptors.empty() || b.descriptors.empty()) return false;

  if (*attempted_total >= SpatialTotalPairBudget()) {
    ++s->stat_spatial_budget_skipped;
    return false;
  }
  // [P1-ENRICH-BUDGET] Time gate on FRESH matcher attempts only — the
  // existing-matches db fast path above stays free, and an in-flight pair is
  // never aborted. No-op unless a budget is armed (see EnrichBudgetExhausted).
  if (EnrichBudgetExhausted(s)) {
    ++s->stat_enrich_budget_stopped;
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
    // [P1-RC7-RETRY] transient rc=7 gets two backoff retries first.
    if (aether_gpu_match_gemm_pairs == nullptr) return false;
    match_rc = GpuMatchGemmPairsRetry(
        s, a.frame_id, a.descriptors.data(), a.n_keypoints, b.frame_id,
        b.descriptors.data(), b.n_keypoints, kSpatialMatchRatio,
        pair_buf.data(), cap, &num_matches);
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
  const auto initial_tvg = EstimateMandatoryFrameTwoViewGeometry(
      a, a.points, b, b.points, matches_for_tvg, tvg_options);
  if (!MandatoryGravityTvgPersistable(initial_tvg)) return false;
  colmap::TwoViewGeometry geometry = initial_tvg.geometry;
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
  if (!RunGuidedMatch(s, a, b, geometry, &guided_matches)) return false;
  // [GUIDED-TEMPORAL 2026-07-12] Stat bookkeeping moved out of RunGuidedMatch;
  // the spatial path books exactly the same guided-pair/inlier totals as before.
  ++s->stat_spatial_guided_pairs;
  s->stat_spatial_guided_inliers += static_cast<int64_t>(guided_matches.size());
  colmap::TwoViewGeometryOptions final_tvg_options;
  final_tvg_options.ransac_options.max_error = kSpatialFinalMaxErrorPixels;
  final_tvg_options.min_num_inliers = kSpatialFinalInliers;
  final_tvg_options.min_inlier_ratio = kSpatialFinalMinInlierRatio;
  colmap::FeatureMatches guided_for_tvg = guided_matches;
  const auto final_tvg = EstimateMandatoryFrameTwoViewGeometry(
      a, a.points, b, b.points, guided_for_tvg, final_tvg_options);
  if (!MandatoryGravityTvgPersistable(final_tvg)) return false;
  colmap::TwoViewGeometry final_geometry = final_tvg.geometry;
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

// [KNIFE-A ③ 2026-07-11] Snapshot the delivered model's 2-view / low-parallax
// tracks into the enrichment-targeting hint (see EnrichTargetHint). Called by
// the refine worker on the live-reuse path BEFORE the enrichment thread spawns
// (the model is mutated concurrently afterwards). Track positions are the
// pre-refine live estimates — noisy in depth, but the targeting predicate only
// needs coarse visibility + parallax direction, both of which survive that
// noise.
constexpr double kEnrichTargetLowParallaxRad = 3.0 * M_PI / 180.0;
constexpr double kEnrichTargetGainRad = 5.0 * M_PI / 180.0;

std::shared_ptr<const EnrichTargetHint> BuildEnrichTargetHint(
    const aether_sfm_session& s, const colmap::Reconstruction& recon) {
  auto hint = std::make_shared<EnrichTargetHint>();
  std::unordered_map<colmap::image_t, int> idx_of;
  idx_of.reserve(s.frames.size());
  for (int i = 0; i < static_cast<int>(s.frames.size()); ++i) {
    idx_of[s.frames[i].image_id] = i;
  }
  hint->by_frame.assign(s.frames.size(), {});
  std::vector<int> fidx;
  for (const auto& [pid, pt] : recon.Points3D()) {
    const auto& els = pt.track.Elements();
    if (els.size() < 2) continue;
    fidx.clear();
    for (const auto& el : els) {
      const auto it = idx_of.find(el.image_id);
      if (it == idx_of.end() || !s.frames[it->second].has_pose) continue;
      if (std::find(fidx.begin(), fidx.end(), it->second) == fidx.end()) {
        fidx.push_back(it->second);
      }
    }
    if (fidx.size() < 2) continue;
    double max_ang = 0.0;
    for (size_t a = 0; a < fidx.size(); ++a) {
      const Eigen::Vector3d ca =
          s.frames[fidx[a]].cam_from_world.TgtOriginInSrc();
      for (size_t b = a + 1; b < fidx.size(); ++b) {
        max_ang = std::max(
            max_ang,
            colmap::CalculateTriangulationAngle(
                ca, s.frames[fidx[b]].cam_from_world.TgtOriginInSrc(),
                pt.xyz));
      }
    }
    if (els.size() != 2 && max_ang >= kEnrichTargetLowParallaxRad) continue;
    const int32_t tid = static_cast<int32_t>(hint->tracks.size());
    hint->tracks.push_back({pt.xyz, fidx});
    for (const int f : fidx) hint->by_frame[f].push_back(tid);
  }
  return hint;
}

// [KNIFE-A ③] How many hint tracks can pair (i, j) upgrade: a track observed
// by ONE side while the OTHER side (a) does not already observe it, (b) sees
// its position inside the frame with positive depth, and (c) adds ≥5° parallax
// against at least one existing observation. Pure poses + current positions —
// no descriptors touched.
int ScoreEnrichPair(const aether_sfm_session& s, const EnrichTargetHint& hint,
                    int i, int j) {
  const auto sees = [&](const FrameRecord& fr, const Eigen::Vector3d& X) {
    const Eigen::Vector3d xc = fr.cam_from_world * X;
    if (xc.z() <= 0.0) return false;
    const std::optional<Eigen::Vector2d> px = fr.camera.ImgFromCam(xc);
    return px && px->x() >= 0.0 && px->y() >= 0.0 &&
           px->x() < static_cast<double>(fr.camera.width) &&
           px->y() < static_cast<double>(fr.camera.height);
  };
  const auto count_dir = [&](int obs_f, int new_f) {
    if (obs_f < 0 || obs_f >= static_cast<int>(hint.by_frame.size())) return 0;
    const FrameRecord& nf = s.frames[new_f];
    const Eigen::Vector3d cn = nf.cam_from_world.TgtOriginInSrc();
    int n = 0;
    for (const int32_t tid : hint.by_frame[obs_f]) {
      const EnrichTargetHint::LowTrack& t = hint.tracks[tid];
      if (std::find(t.frame_idxs.begin(), t.frame_idxs.end(), new_f) !=
          t.frame_idxs.end()) {
        continue;  // both sides already observe it — no third view to gain
      }
      if (!sees(nf, t.xyz)) continue;
      for (const int f : t.frame_idxs) {
        if (colmap::CalculateTriangulationAngle(
                cn, s.frames[f].cam_from_world.TgtOriginInSrc(), t.xyz) >=
            kEnrichTargetGainRad) {
          ++n;
          break;
        }
      }
    }
    return n;
  };
  return count_dir(i, j) + count_dir(j, i);
}

void AddSpatialRevisitMatches(aether_sfm_session* s) {
  if (kProductionOfficialEndpointOnly) return;
  if (!s || !s->db || s->frames.size() < 3 || s->camera_id == 0) return;
  const int temporal_k = s->options.k_neighbors > 0 ? s->options.k_neighbors : 12;
  SpatialPairCache cache;
  cache.reserve(kSpatialMaxTotalPairs * 2);
  int attempted_total = 0;

  const std::vector<SpatialRevisitCandidate> spatial_anchors =
      BuildSpatialAnchors(s, temporal_k);
  const int spatial_regions = ProcessRevisitAnchors(
      s, spatial_anchors, false,
      std::min(kSpatialInitialAnchorBudget, SpatialTotalPairBudget()), &cache,
      &attempted_total);

  // COLMAP-style quadratic overlap is a sparse safety net, not parallel blind
  // work: only use powers-of-two temporal gaps when ARKit produced no confirmed
  // multi-frame revisit region at all.
  if (spatial_regions == 0 && attempted_total < SpatialTotalPairBudget()) {
    const std::vector<SpatialRevisitCandidate> quadratic_anchors =
        BuildQuadraticAnchors(s, temporal_k);
    ProcessRevisitAnchors(s, quadratic_anchors, true, SpatialTotalPairBudget(),
                          &cache, &attempted_total);
  }

  // [SCAN-MATRIX ENV ④ 2026-07-11] Enrichment top-up: with
  // OFFICIAL_AETHER_ENRICH_PAIR_CAP=N set, N is a floor as well as the cap. The anchor
  // funnel alone can starve enrichment (cap45 device run attempted only 7
  // pairs — a short orbit barely produces pose-gated revisit candidates), so
  // the matrix could never price "what do 200/300 extra finalize matches
  // buy". Enumerate every beyond-K pair, closest camera centers first, and
  // keep attempting until N pairs were actually matched. Verification is the
  // unchanged strict chain; anchor-pass pairs that verified but were left
  // unwritten pending 2-of-3 region confirmation are flushed from the cache
  // for free. UNSET env skips this block entirely — default behavior is
  // bit-identical to the pre-hook binary.
  const int enrich_cap = EnrichPairCapOverride();
  if (enrich_cap > 0) {
    // [KNIFE-A ③ 2026-07-11] Targeted ordering: with OFFICIAL_AETHER_ENRICH_TARGETED=1
    // and a hint snapshot available (live-reuse finalize), rank the top-up
    // pairs by how many 2-view/low-parallax tracks each pair can hand a
    // ≥5°-parallax third observation — the observation TrackUpgrade then
    // banks — instead of by camera-center proximity, which is blind to the
    // upgrade demand. Zero-score pairs keep the legacy distance order behind
    // the scored ones, so the floor semantics still fills to N either way.
    const std::shared_ptr<const EnrichTargetHint> hint =
        EnrichTargetedEnabled() ? s->enrich_hint : nullptr;
    if (hint) {
      s->stat_enrich_targeted_tracks =
          static_cast<int64_t>(hint->tracks.size());
    }
    std::vector<SpatialRevisitCandidate> topup;
    const int num_frames = static_cast<int>(s->frames.size());
    for (int i = 0; i < num_frames; ++i) {
      const FrameRecord& frame_i = s->frames[i];
      for (int j = 0; j + temporal_k < i; ++j) {
        const FrameRecord& frame_j = s->frames[j];
        SpatialRevisitCandidate candidate;
        candidate.i = i;
        candidate.j = j;
        if (frame_i.has_pose && frame_j.has_pose) {
          candidate.distance_m =
              (frame_i.cam_from_world.TgtOriginInSrc() -
               frame_j.cam_from_world.TgtOriginInSrc())
                  .norm();
          candidate.score = candidate.distance_m;
          if (hint) {
            candidate.target_score = ScoreEnrichPair(*s, *hint, i, j);
            if (candidate.target_score > 0) ++s->stat_enrich_targeted_scored;
          }
        } else {
          // Pose-less frames sort last, smaller temporal gaps first.
          candidate.score = 1.0e9 + static_cast<double>(i - j);
        }
        topup.push_back(candidate);
      }
    }
    std::sort(topup.begin(), topup.end(),
              [](const SpatialRevisitCandidate& a,
                 const SpatialRevisitCandidate& b) {
                if (a.target_score != b.target_score) {
                  return a.target_score > b.target_score;  // upgrades first
                }
                if (a.score != b.score) return a.score < b.score;
                if (a.i != b.i) return a.i < b.i;
                return a.j < b.j;
              });
    if (hint) {
      LOG(WARNING) << "[aether_sfm] enrich top-up targeted: low-parallax "
                      "tracks="
                   << s->stat_enrich_targeted_tracks
                   << " scored_pairs=" << s->stat_enrich_targeted_scored
                   << " of " << topup.size() << " beyond-K pairs";
    }
    for (const SpatialRevisitCandidate& candidate : topup) {
      if (attempted_total >= enrich_cap) break;
      if (VerifySpatialPair(s, candidate.i, candidate.j,
                            SpatialPairPurpose::kExpansion, &cache,
                            &attempted_total)) {
        WriteVerifiedSpatialPair(s, candidate.i, candidate.j, false, &cache);
      }
    }
  }
}

// [KNIFE-A 2026-07-11] Forward declaration (defined after RestoreTemporalDetail
// next to its main consumer UpgradeLowParallaxTracks): pose-fixed point-only
// Gauss-Newton polish used by both the ① grow refit and the ② track upgrade.
void PolishPointGN(const std::vector<const colmap::Image*>& images,
                   const std::vector<const colmap::Camera*>& cameras,
                   const std::vector<Eigen::Vector2d>& obs_px,
                   Eigen::Vector3d* xyz);

// Rebuild the dense, locally stable detail layer after the global camera solve.
// Spatial/guided pairs have already done their job by constraining loop closure;
// this pass consumes only the original temporal K-neighbor TVG inliers. Camera
// poses and intrinsics stay fixed: the pass may create points or add a clean
// observation, but never merges existing points and never runs another BA.
// Processing larger temporal gaps first gives each new point the strongest
// available baseline inside K before adjacent frames try to grow its track.
void RestoreTemporalDetail(aether_sfm_session* s,
                           colmap::Reconstruction* reconstruction) {
  if (kProductionOfficialEndpointOnly) return;
  if (!s || !reconstruction || s->frames.size() < 2) return;

  // [SCAN-MATRIX ENV ③] defaults = shipped 2.0° (T20) / 3 px; OFFICIAL_AETHER_TD_TRI_ANGLE /
  // OFFICIAL_AETHER_TD_REPROJ_PX override for the host gate matrix.
  const double kMinTriAngleRad = TemporalDetailTriMinAngleRad();
  // 39-capture replay: 4 px kept one 2.8x-q99 ray; 3 px retained ~62.7k
  // delivered points while reducing all added points below 1.18x-q99.
  const double kMaxReprojPx = TemporalDetailMaxReprojPx();
  // [KNIFE-A ① 2026-07-11] OFFICIAL_AETHER_TD_GROW_REFIT=1: grow acceptance becomes a
  // union refit (CanMergeLivePoints recipe) instead of "≤3 px at the CURRENT,
  // never-refined position". The delivered 2-view thick points are born of
  // low-parallax DLT depth noise; a wide-baseline observation of the SAME
  // surface point reprojects ~3.6 px off that noisy position (p90: 5.3 px) and
  // the current-position gate rejects exactly the observation that could fix
  // it. The refit triangulates over track+candidate (full union baseline),
  // accepts only if EVERY union observation is in front of its camera and
  // within kMaxReprojPx of the REFIT position (+ the same stable-baseline
  // rule, evaluated at the refit), and installs the refit position on accept.
  // A failed refit falls through to the legacy gates, so acceptance is a
  // strict superset of the default arm. Default OFF: unset env is
  // bit-identical to the shipped behavior.
  const bool kGrowRefit = TdGrowRefitEnabled();
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
          // [KNIFE-A ①] union-refit grow acceptance (env-gated; see above).
          if (kGrowRefit) {
            ++s->stat_td_grow_refit_attempted;
            // Legacy-gate verdict, attribution only: how many accepts the
            // refit SAVED relative to the 3px@current gate.
            const Eigen::Vector3d x_cam_cur =
                grow_image.CamFromWorld() * point3D.xyz;
            const bool legacy_ok =
                x_cam_cur.z() > 0.0 &&
                reprojects_cleanly(grow_image, grow_camera, grow_point2D_idx,
                                   point3D.xyz) &&
                has_stable_baseline(point3D.track, grow_image, point3D.xyz);
            bool usable = true;
            std::vector<Eigen::Matrix3x4d> cams_from_world;
            std::vector<Eigen::Vector2d> cam_points;
            std::vector<const colmap::Image*> union_imgs;
            std::vector<const colmap::Camera*> union_cams;
            std::vector<Eigen::Vector2d> union_px;
            cams_from_world.reserve(point3D.track.Length() + 1);
            cam_points.reserve(point3D.track.Length() + 1);
            for (const colmap::TrackElement& el : point3D.track.Elements()) {
              if (!reconstruction->ExistsImage(el.image_id)) {
                usable = false;
                break;
              }
              const colmap::Image& im = reconstruction->Image(el.image_id);
              if (!im.HasPose() || el.point2D_idx >= im.NumPoints2D()) {
                usable = false;
                break;
              }
              const colmap::Camera& cm =
                  reconstruction->Camera(im.CameraId());
              const std::optional<Eigen::Vector2d> nc =
                  cm.CamFromImg(im.Point2D(el.point2D_idx).xy);
              if (!nc) {
                usable = false;
                break;
              }
              cams_from_world.push_back(im.CamFromWorld().ToMatrix());
              cam_points.push_back(*nc);
              union_imgs.push_back(&im);
              union_cams.push_back(&cm);
              union_px.push_back(im.Point2D(el.point2D_idx).xy);
            }
            const std::optional<Eigen::Vector2d> nc_cand =
                grow_camera.CamFromImg(
                    grow_image.Point2D(grow_point2D_idx).xy);
            if (usable && nc_cand) {
              cams_from_world.push_back(grow_image.CamFromWorld().ToMatrix());
              cam_points.push_back(*nc_cand);
              union_imgs.push_back(&grow_image);
              union_cams.push_back(&grow_camera);
              union_px.push_back(grow_image.Point2D(grow_point2D_idx).xy);
              Eigen::Vector3d refit_xyz;
              if (colmap::TriangulateMultiViewPoint(
                      colmap::span<const Eigen::Matrix3x4d>(
                          cams_from_world.data(), cams_from_world.size()),
                      colmap::span<const Eigen::Vector2d>(cam_points.data(),
                                                          cam_points.size()),
                      &refit_xyz)) {
                // Pose-fixed GN polish: the DLT minimizes an ALGEBRAIC
                // residual; converge to the pixel-reproj optimum the
                // acceptance gate below actually measures (raises rescue
                // rate AND lowers the residual the added observation carries
                // into the delivered model's mean reproj).
                PolishPointGN(union_imgs, union_cams, union_px, &refit_xyz);
                bool refit_ok = reprojects_cleanly(
                    grow_image, grow_camera, grow_point2D_idx, refit_xyz);
                if (refit_ok) {
                  for (const colmap::TrackElement& el :
                       point3D.track.Elements()) {
                    const colmap::Image& im =
                        reconstruction->Image(el.image_id);
                    if (!reprojects_cleanly(
                            im, reconstruction->Camera(im.CameraId()),
                            el.point2D_idx, refit_xyz)) {
                      refit_ok = false;
                      break;
                    }
                  }
                }
                // [P2-FRAG-MERGE-REPRICE] Optional absolute parallax floor
                // on the refit ACCEPT: the union's θ_max at the refit must
                // reach OFFICIAL_AETHER_TD_GROW_REFIT_MIN_THETA_DEG. A union still
                // inside the low-parallax ambiguity band keeps the noisy
                // depth the ghost layer is made of (cap47: GROW_REFIT arm
                // ghost 4.3%→5.5%); refusing the refit here drops the
                // candidate to the legacy gates below (superset preserved).
                static const double kGrowMinThetaRad =
                    TdGrowRefitMinThetaDeg() * M_PI / 180.0;
                if (refit_ok && kGrowMinThetaRad > 0.0) {
                  double th_union = 0.0;
                  for (size_t i2 = 0; i2 < union_imgs.size(); ++i2) {
                    const Eigen::Vector3d ci =
                        union_imgs[i2]->CamFromWorld().TgtOriginInSrc();
                    for (size_t j2 = i2 + 1; j2 < union_imgs.size(); ++j2) {
                      th_union = std::max(
                          th_union,
                          colmap::CalculateTriangulationAngle(
                              ci,
                              union_imgs[j2]->CamFromWorld().TgtOriginInSrc(),
                              refit_xyz));
                    }
                  }
                  if (th_union < kGrowMinThetaRad) {
                    ++s->stat_td_grow_refit_min_theta_rej;
                    refit_ok = false;
                  }
                }
                if (refit_ok &&
                    has_stable_baseline(point3D.track, grow_image,
                                        refit_xyz)) {
                  reconstruction->Point3D(point3D_id).xyz = refit_xyz;
                  reconstruction->AddObservation(
                      point3D_id,
                      colmap::TrackElement(grow_image_id, grow_point2D_idx));
                  ++s->stat_temporal_detail_grown;
                  ++s->stat_td_grow_refit_accepted;
                  if (!legacy_ok) ++s->stat_td_grow_refit_saved;
                  continue;
                }
              }
            }
            // Refit unusable/rejected: fall through to the legacy gates so
            // this arm accepts a strict superset of the default arm.
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

// [KNIFE-A ② 2026-07-11] Pose-fixed point-only Gauss-Newton polish (analytic
// pinhole Jacobian, ≤4 iterations). The union DLT is algebraic (minimizes an
// algebraic residual, not pixels); this polish converges the refit position to
// the pixel-reproj optimum the acceptance gate actually measures. Poses and
// intrinsics stay constant — this is the "每点位姿固定微 LM". Non-pinhole
// cameras (never produced by this pipeline) skip the polish and keep the DLT
// result; any degeneracy (behind-camera, singular H) also returns early with
// the input position unchanged.
void PolishPointGN(const std::vector<const colmap::Image*>& images,
                   const std::vector<const colmap::Camera*>& cameras,
                   const std::vector<Eigen::Vector2d>& obs_px,
                   Eigen::Vector3d* xyz) {
  for (int iter = 0; iter < 4; ++iter) {
    Eigen::Matrix3d H = Eigen::Matrix3d::Zero();
    Eigen::Vector3d b = Eigen::Vector3d::Zero();
    int n_used = 0;
    for (size_t i = 0; i < images.size(); ++i) {
      const colmap::Camera& cam = *cameras[i];
      if (cam.model_id != colmap::SimplePinholeCameraModel::model_id &&
          cam.model_id != colmap::PinholeCameraModel::model_id) {
        return;
      }
      const colmap::Rigid3d& cfw = images[i]->CamFromWorld();
      const Eigen::Vector3d xc = cfw * (*xyz);
      if (xc.z() <= 1e-9) return;
      const std::optional<Eigen::Vector2d> px = cam.ImgFromCam(xc);
      if (!px) return;
      const double fx = cam.FocalLengthX();
      const double fy = cam.FocalLengthY();
      const double iz = 1.0 / xc.z();
      const Eigen::Vector2d r = *px - obs_px[i];
      Eigen::Matrix<double, 2, 3> jc;
      jc << fx * iz, 0.0, -fx * xc.x() * iz * iz,  //
          0.0, fy * iz, -fy * xc.y() * iz * iz;
      const Eigen::Matrix<double, 2, 3> J =
          jc * cfw.rotation().toRotationMatrix();
      H += J.transpose() * J;
      b += J.transpose() * r;
      ++n_used;
    }
    if (n_used < 2) return;
    H.diagonal().array() += 1e-8 * H.trace() + 1e-12;
    const Eigen::Vector3d dx = H.ldlt().solve(b);
    if (!dx.allFinite()) return;
    *xyz -= dx;
  }
}

// [KNIFE-A ② 2026-07-11] TrackUpgrade — finalize-tail 2-view upgrade pass
// (env OFFICIAL_AETHER_TRACK_UPGRADE=1, default OFF; runs AFTER RestoreTemporalDetail
// so the detail layer's fresh 2-view points are upgrade candidates too).
//
// WHY: the delivered cloud's thickness lives in its 2-view / low-parallax
// (θ_max < 3°) points — live 2° creations plus RestoreTemporalDetail
// creations, all triangulated OUTSIDE the BA's reach (pure DLT after stage 2,
// never refined). The observations that could fix them usually EXIST in the
// db (temporal TVGs RestoreTemporalDetail's gap≤K loop never pairs with them,
// enrichment spatial TVGs it never consumes at all) but are unreachable:
// the vendored mapper's Complete() gate rejects candidates >4 px from the
// CURRENT noisy position — for a point with 0.0067 thickness, a 10°-baseline
// observation sits ~3.6 px off (p90 points: 5.3 px), exactly the observation
// that could repair it. This pass does refit-semantics itself instead of
// touching the shared vendored mapper path:
//   1. index EVERY db TVG inlier that touches an eligible track's keypoints;
//   2. per eligible point, collect free (unassigned) partner keypoints from
//      images outside the track — one per image;
//   3. trimmed union refit: DLT over track+candidates, pose-fixed GN polish,
//      accept only if EVERY union observation is in front of its camera and
//      within the RestoreTemporalDetail reproj gate of the refit position;
//      violating candidates are dropped (≤3 rounds) rather than failing the
//      whole point;
//   4. on accept: install the refit position + AddObservation the survivors.
// Never deletes a point or an observation (点数只增不减); thickness improves
// because the upgraded points move to their full-baseline positions.
void UpgradeLowParallaxTracks(aether_sfm_session* s,
                              colmap::Reconstruction* reconstruction) {
  if (kProductionOfficialEndpointOnly) return;
  if (!TrackUpgradeEnabled() || !s || !reconstruction) return;
  const double t0 = NowMs();
  try {
    const double kMaxReprojPx = TemporalDetailMaxReprojPx();
    constexpr double kLowParallaxRad = 3.0 * M_PI / 180.0;

    // θ_max (max pairwise triangulation angle) over a track's posed obs.
    const auto theta_max = [&](const colmap::Track& track,
                               const Eigen::Vector3d& xyz) {
      double best = 0.0;
      const auto& els = track.Elements();
      for (size_t a = 0; a < els.size(); ++a) {
        if (!reconstruction->ExistsImage(els[a].image_id)) continue;
        const colmap::Image& ia = reconstruction->Image(els[a].image_id);
        if (!ia.HasPose()) continue;
        const Eigen::Vector3d ca = ia.CamFromWorld().TgtOriginInSrc();
        for (size_t b = a + 1; b < els.size(); ++b) {
          if (!reconstruction->ExistsImage(els[b].image_id)) continue;
          const colmap::Image& ib = reconstruction->Image(els[b].image_id);
          if (!ib.HasPose()) continue;
          best = std::max(best,
                          colmap::CalculateTriangulationAngle(
                              ca, ib.CamFromWorld().TgtOriginInSrc(), xyz));
        }
      }
      return best;
    };
    // Whole-model distribution summary (the 归因插桩): n / 2-view / θ<3° and
    // the θ_max p50. Fills the stat triple passed in.
    const auto summarize = [&](int64_t* n_out, int64_t* n2_out,
                               int64_t* lt3_out, double* p50_out) {
      std::vector<double> thetas;
      thetas.reserve(reconstruction->NumPoints3D());
      int64_t n2 = 0, lt3 = 0;
      for (const auto& [pid, pt] : reconstruction->Points3D()) {
        const double th = theta_max(pt.track, pt.xyz);
        thetas.push_back(th);
        if (pt.track.Length() == 2) ++n2;
        if (th < kLowParallaxRad) ++lt3;
      }
      *n_out = static_cast<int64_t>(thetas.size());
      *n2_out = n2;
      *lt3_out = lt3;
      if (!thetas.empty()) {
        std::nth_element(thetas.begin(), thetas.begin() + thetas.size() / 2,
                         thetas.end());
        *p50_out = thetas[thetas.size() / 2] * 180.0 / M_PI;
      }
    };

    // 1) Eligible set = 2-view tracks + low-parallax multi-view tracks, and
    //    the pre-pass distribution.
    std::vector<colmap::point3D_t> eligible;
    {
      std::vector<double> thetas;
      thetas.reserve(reconstruction->NumPoints3D());
      int64_t n2 = 0, lt3 = 0;
      for (const auto& [pid, pt] : reconstruction->Points3D()) {
        const double th = theta_max(pt.track, pt.xyz);
        thetas.push_back(th);
        const bool two_view = pt.track.Length() == 2;
        if (two_view) ++n2;
        if (th < kLowParallaxRad) ++lt3;
        if (two_view || th < kLowParallaxRad) eligible.push_back(pid);
      }
      s->stat_upgrade_pre_npts = static_cast<int64_t>(thetas.size());
      s->stat_upgrade_pre_2view = n2;
      s->stat_upgrade_pre_lt3 = lt3;
      if (!thetas.empty()) {
        std::nth_element(thetas.begin(), thetas.begin() + thetas.size() / 2,
                         thetas.end());
        s->upgrade_theta_p50_pre_deg =
            thetas[thetas.size() / 2] * 180.0 / M_PI;
      }
    }
    s->stat_upgrade_eligible = static_cast<int64_t>(eligible.size());
    if (eligible.empty()) {
      s->upgrade_ms = NowMs() - t0;
      return;
    }

    // 2) Correspondence index over ALL db TVG inliers (temporal, enrichment
    //    spatial, finalize re-match — everything), restricted to the eligible
    //    tracks' keypoints so memory stays bounded.
    const auto key_of = [](colmap::image_t img, uint32_t idx) {
      return (static_cast<uint64_t>(img) << 32) | idx;
    };
    std::unordered_set<uint64_t> needed;
    needed.reserve(eligible.size() * 3);
    for (const colmap::point3D_t pid : eligible) {
      for (const colmap::TrackElement& el :
           reconstruction->Point3D(pid).track.Elements()) {
        needed.insert(key_of(el.image_id, el.point2D_idx));
      }
    }
    std::unordered_map<uint64_t,
                       std::vector<std::pair<colmap::image_t, uint32_t>>>
        corr;
    corr.reserve(needed.size());
    {
      auto db = colmap::Database::Open(s->db_path);
      for (const auto& [pair_id, n_inliers] :
           db->ReadTwoViewGeometryNumInliers()) {
        if (n_inliers <= 0) continue;
        const auto [id1, id2] = colmap::PairIdToImagePair(pair_id);
        const colmap::TwoViewGeometry g = db->ReadTwoViewGeometry(id1, id2);
        for (const colmap::FeatureMatch& m : g.inlier_matches) {
          const uint64_t k1 = key_of(id1, m.point2D_idx1);
          const uint64_t k2 = key_of(id2, m.point2D_idx2);
          if (needed.count(k1)) corr[k1].emplace_back(id2, m.point2D_idx2);
          if (needed.count(k2)) corr[k2].emplace_back(id1, m.point2D_idx1);
        }
      }
      db->Close();
    }

    // 3) Per-point trimmed union refit. Serial by design: acceptance claims
    //    free keypoints, and first-come-first-served needs a total order.
    for (const colmap::point3D_t pid : eligible) {
      if (!reconstruction->ExistsPoint3D(pid)) continue;  // defensive
      const colmap::Point3D& point = reconstruction->Point3D(pid);

      std::unordered_set<colmap::image_t> excluded;  // track ∪ picked images
      for (const colmap::TrackElement& el : point.track.Elements()) {
        excluded.insert(el.image_id);
      }
      std::vector<std::pair<colmap::image_t, uint32_t>> kept;
      for (const colmap::TrackElement& el : point.track.Elements()) {
        const auto it = corr.find(key_of(el.image_id, el.point2D_idx));
        if (it == corr.end()) continue;
        for (const auto& [img2, idx2] : it->second) {
          if (excluded.count(img2)) continue;
          if (!reconstruction->ExistsImage(img2)) continue;
          const colmap::Image& im2 = reconstruction->Image(img2);
          if (!im2.HasPose() || idx2 >= im2.NumPoints2D()) continue;
          if (im2.Point2D(idx2).HasPoint3D()) continue;  // taken — no merge here
          excluded.insert(img2);  // one candidate per image
          kept.emplace_back(img2, idx2);
        }
      }
      if (kept.empty()) continue;
      ++s->stat_upgrade_attempted;

      Eigen::Vector3d accepted_xyz = Eigen::Vector3d::Zero();
      bool accepted = false;
      for (int round = 0; round < 3 && !kept.empty(); ++round) {
        std::vector<Eigen::Matrix3x4d> cams_from_world;
        std::vector<Eigen::Vector2d> cam_points;
        std::vector<const colmap::Image*> imgs;
        std::vector<const colmap::Camera*> cams;
        std::vector<Eigen::Vector2d> px;
        bool bad = false;
        const auto push_obs = [&](colmap::image_t img_id, uint32_t idx) {
          if (bad) return;
          if (!reconstruction->ExistsImage(img_id)) {
            bad = true;
            return;
          }
          const colmap::Image& im = reconstruction->Image(img_id);
          if (!im.HasPose() || idx >= im.NumPoints2D()) {
            bad = true;
            return;
          }
          const colmap::Camera& cm = reconstruction->Camera(im.CameraId());
          const Eigen::Vector2d p = im.Point2D(idx).xy;
          const std::optional<Eigen::Vector2d> nc = cm.CamFromImg(p);
          if (!nc) {
            bad = true;
            return;
          }
          cams_from_world.push_back(im.CamFromWorld().ToMatrix());
          cam_points.push_back(*nc);
          imgs.push_back(&im);
          cams.push_back(&cm);
          px.push_back(p);
        };
        for (const colmap::TrackElement& el : point.track.Elements()) {
          push_obs(el.image_id, el.point2D_idx);
        }
        const size_t n_track = imgs.size();
        for (const auto& [img2, idx2] : kept) push_obs(img2, idx2);
        if (bad) break;

        Eigen::Vector3d X;
        if (!colmap::TriangulateMultiViewPoint(
                colmap::span<const Eigen::Matrix3x4d>(cams_from_world.data(),
                                                      cams_from_world.size()),
                colmap::span<const Eigen::Vector2d>(cam_points.data(),
                                                    cam_points.size()),
                &X)) {
          break;
        }
        PolishPointGN(imgs, cams, px, &X);

        bool track_bad = false;
        std::vector<size_t> drop;  // indices into kept, ascending
        double worst_res = -1.0;
        size_t worst_cand = static_cast<size_t>(-1);
        for (size_t o = 0; o < imgs.size(); ++o) {
          double res = std::numeric_limits<double>::infinity();
          const Eigen::Vector3d xc = imgs[o]->CamFromWorld() * X;
          if (xc.z() > 0.0) {
            const std::optional<Eigen::Vector2d> pp = cams[o]->ImgFromCam(xc);
            if (pp) res = (*pp - px[o]).norm();
          }
          const bool ok = res <= kMaxReprojPx;
          if (o < n_track) {
            if (!ok) track_bad = true;
          } else {
            const size_t ci = o - n_track;
            if (!ok) drop.push_back(ci);
            if (res > worst_res) {
              worst_res = res;
              worst_cand = ci;
            }
          }
        }
        if (!track_bad && drop.empty()) {
          accepted = true;
          accepted_xyz = X;
          break;
        }
        if (!drop.empty()) {
          for (auto it = drop.rbegin(); it != drop.rend(); ++it) {
            kept.erase(kept.begin() + *it);
          }
        } else {
          // Track violated while every candidate fits: the candidate set is
          // self-consistent but pulls the point off its own track — shed the
          // worst-residual candidate and retry.
          if (worst_cand == static_cast<size_t>(-1)) break;
          kept.erase(kept.begin() + worst_cand);
        }
      }

      if (accepted && !kept.empty()) {
        reconstruction->Point3D(pid).xyz = accepted_xyz;
        for (const auto& [img2, idx2] : kept) {
          reconstruction->AddObservation(
              pid, colmap::TrackElement(img2, idx2));
        }
        ++s->stat_upgrade_accepted;
        s->stat_upgrade_obs_added += static_cast<int64_t>(kept.size());
      }
    }

    // 4) Post-pass distribution.
    summarize(&s->stat_upgrade_post_npts, &s->stat_upgrade_post_2view,
              &s->stat_upgrade_post_lt3, &s->upgrade_theta_p50_post_deg);
    s->upgrade_ms = NowMs() - t0;
    LOG(WARNING) << "[aether_sfm] track-upgrade: eligible="
                 << s->stat_upgrade_eligible
                 << " attempted=" << s->stat_upgrade_attempted
                 << " accepted=" << s->stat_upgrade_accepted
                 << " obs_added=" << s->stat_upgrade_obs_added << " pre{n="
                 << s->stat_upgrade_pre_npts << " 2view="
                 << s->stat_upgrade_pre_2view << " lt3="
                 << s->stat_upgrade_pre_lt3 << " theta_p50="
                 << s->upgrade_theta_p50_pre_deg << "deg} post{n="
                 << s->stat_upgrade_post_npts << " 2view="
                 << s->stat_upgrade_post_2view << " lt3="
                 << s->stat_upgrade_post_lt3 << " theta_p50="
                 << s->upgrade_theta_p50_post_deg << "deg} in "
                 << static_cast<int64_t>(s->upgrade_ms) << "ms";
  } catch (const std::exception& e) {
    // Enhancement pass only — never take the finalize down.
    s->upgrade_ms = NowMs() - t0;
    LOG(WARNING) << "[aether_sfm] track-upgrade aborted: " << e.what();
  }
}

// [P2-FRAG-MERGE 2026-07-11] FragmentMerge — finalize-tail duplicate-track
// merge pass (env OFFICIAL_AETHER_FRAG_MERGE=1, default OFF; runs AFTER
// UpgradeLowParallaxTracks so upgraded tracks participate with their full
// baselines).
//
// WHY: the remaining delivered thickness lives in REPEATED fragments of the
// same physical surface point — DSP-SIFT emits near-identical keypoints at
// several scales, each seeding its own low-parallax 2-view track (KNIFE-A
// verdict: ~18k upgrade-eligible 2-view points whose partner observations
// already sit on OTHER tracks; cap45 cross-track conflicts = 39,187).
// TrackUpgrade deliberately skips partner keypoints that already carry a
// Point3D ("taken — no merge here"); this pass handles exactly that case:
// when the db's TVG inlier graph CONNECTS two tracks (a keypoint of track A
// matched a keypoint of track B), they are fragment candidates of ONE point.
// A union refit over ALL observations of BOTH tracks (DLT + pose-fixed GN —
// the CanMergeLivePoints / KNIFE-A recipe) decides:
//   accept ⇔ EVERY union observation is in front of its camera AND within
//   the RestoreTemporalDetail reproj gate of the refit position AND the
//   union's θ_max at the refit STRICTLY exceeds both fragments' current
//   θ_max. 防误合并: two physically distinct points cannot both fit one 3D
//   position within the all-observation reproj gate, and a merge that does
//   not widen the effective baseline has no thickness value to bank.
// Unlike TrackUpgrade there is NO candidate trimming: every union
// observation belongs to one of the two DELIVERED tracks, and dropping one
// would delete delivered data — a violating observation therefore rejects
// the merge instead. Chains (A–B, B–C) merge fully within the single pass
// via redirect chasing. Accounting (物理点守恒): each accepted merge removes
// exactly one point id (two fragments → one multi-view point), so
// frag_post_npts + frag_accepted == frag_pre_npts must hold; observations
// are conserved exactly (MergePoints3D concatenates the tracks).
void MergeFragmentTracks(aether_sfm_session* s,
                         colmap::Reconstruction* reconstruction) {
  if (kProductionOfficialEndpointOnly) return;
  if (!FragMergeEnabled() || !s || !reconstruction) return;
  const double t0 = NowMs();
  try {
    const double kMaxReprojPx = FragMergeMaxReprojPx() > 0.0
                                    ? FragMergeMaxReprojPx()
                                    : TemporalDetailMaxReprojPx();
    constexpr double kLowParallaxRad = 3.0 * M_PI / 180.0;
    // [P2-FRAG-MERGE-REPRICE] absolute post-merge parallax floor (0 = off).
    const double kMinThetaRad = FragMergeMinThetaDeg() * M_PI / 180.0;

    const auto theta_max = [&](const colmap::Track& track,
                               const Eigen::Vector3d& xyz) {
      double best = 0.0;
      const auto& els = track.Elements();
      for (size_t a = 0; a < els.size(); ++a) {
        if (!reconstruction->ExistsImage(els[a].image_id)) continue;
        const colmap::Image& ia = reconstruction->Image(els[a].image_id);
        if (!ia.HasPose()) continue;
        const Eigen::Vector3d ca = ia.CamFromWorld().TgtOriginInSrc();
        for (size_t b = a + 1; b < els.size(); ++b) {
          if (!reconstruction->ExistsImage(els[b].image_id)) continue;
          const colmap::Image& ib = reconstruction->Image(els[b].image_id);
          if (!ib.HasPose()) continue;
          best = std::max(best,
                          colmap::CalculateTriangulationAngle(
                              ca, ib.CamFromWorld().TgtOriginInSrc(), xyz));
        }
      }
      return best;
    };
    const auto summarize = [&](int64_t* n_out, int64_t* n2_out,
                               int64_t* lt3_out, double* p50_out) {
      std::vector<double> thetas;
      thetas.reserve(reconstruction->NumPoints3D());
      int64_t n2 = 0, lt3 = 0;
      for (const auto& [pid, pt] : reconstruction->Points3D()) {
        const double th = theta_max(pt.track, pt.xyz);
        thetas.push_back(th);
        if (pt.track.Length() == 2) ++n2;
        if (th < kLowParallaxRad) ++lt3;
      }
      *n_out = static_cast<int64_t>(thetas.size());
      *n2_out = n2;
      *lt3_out = lt3;
      if (!thetas.empty()) {
        std::nth_element(thetas.begin(), thetas.begin() + thetas.size() / 2,
                         thetas.end());
        *p50_out = thetas[thetas.size() / 2] * 180.0 / M_PI;
      }
    };

    // 1) Pre-pass distribution + eligible set: the 2-view / low-parallax
    //    fragments the thickness lives in. The merge PARTNER may be any
    //    track (folding a 2-view fragment into a healthy multi-view track is
    //    the most valuable dedup of all).
    std::vector<colmap::point3D_t> eligible;
    {
      std::vector<double> thetas;
      thetas.reserve(reconstruction->NumPoints3D());
      int64_t n2 = 0, lt3 = 0;
      for (const auto& [pid, pt] : reconstruction->Points3D()) {
        const double th = theta_max(pt.track, pt.xyz);
        thetas.push_back(th);
        const bool two_view = pt.track.Length() == 2;
        if (two_view) ++n2;
        if (th < kLowParallaxRad) ++lt3;
        if (two_view || th < kLowParallaxRad) eligible.push_back(pid);
      }
      s->stat_frag_pre_npts = static_cast<int64_t>(thetas.size());
      s->stat_frag_pre_2view = n2;
      s->stat_frag_pre_lt3 = lt3;
      if (!thetas.empty()) {
        std::nth_element(thetas.begin(), thetas.begin() + thetas.size() / 2,
                         thetas.end());
        s->frag_theta_p50_pre_deg = thetas[thetas.size() / 2] * 180.0 / M_PI;
      }
    }
    if (eligible.empty()) {
      s->frag_ms = NowMs() - t0;
      return;
    }

    // 2) TVG-inlier correspondence index restricted to the eligible tracks'
    //    keypoints (same recipe/memory bound as TrackUpgrade step 2).
    const auto key_of = [](colmap::image_t img, uint32_t idx) {
      return (static_cast<uint64_t>(img) << 32) | idx;
    };
    std::unordered_set<uint64_t> needed;
    needed.reserve(eligible.size() * 3);
    for (const colmap::point3D_t pid : eligible) {
      for (const colmap::TrackElement& el :
           reconstruction->Point3D(pid).track.Elements()) {
        needed.insert(key_of(el.image_id, el.point2D_idx));
      }
    }
    std::unordered_map<uint64_t,
                       std::vector<std::pair<colmap::image_t, uint32_t>>>
        corr;
    corr.reserve(needed.size());
    {
      auto db = colmap::Database::Open(s->db_path);
      for (const auto& [pair_id, n_inliers] :
           db->ReadTwoViewGeometryNumInliers()) {
        if (n_inliers <= 0) continue;
        const auto [id1, id2] = colmap::PairIdToImagePair(pair_id);
        const colmap::TwoViewGeometry g = db->ReadTwoViewGeometry(id1, id2);
        for (const colmap::FeatureMatch& m : g.inlier_matches) {
          const uint64_t k1 = key_of(id1, m.point2D_idx1);
          const uint64_t k2 = key_of(id2, m.point2D_idx2);
          if (needed.count(k1)) corr[k1].emplace_back(id2, m.point2D_idx2);
          if (needed.count(k2)) corr[k2].emplace_back(id1, m.point2D_idx1);
        }
      }
      db->Close();
    }

    // 3) Candidate track pairs: an eligible track's keypoint matched (TVG
    //    inlier) against a keypoint ASSIGNED to a different track = one
    //    link; multiplicity = correspondence evidence strength.
    std::unordered_map<PointIdPair, int, PointIdPairHash> links;
    for (const colmap::point3D_t pid : eligible) {
      if (!reconstruction->ExistsPoint3D(pid)) continue;  // defensive
      for (const colmap::TrackElement& el :
           reconstruction->Point3D(pid).track.Elements()) {
        const auto it = corr.find(key_of(el.image_id, el.point2D_idx));
        if (it == corr.end()) continue;
        for (const auto& [img2, idx2] : it->second) {
          if (!reconstruction->ExistsImage(img2)) continue;
          const colmap::Image& im2 = reconstruction->Image(img2);
          if (!im2.HasPose() || idx2 >= im2.NumPoints2D()) continue;
          const colmap::Point2D& p2 = im2.Point2D(idx2);
          if (!p2.HasPoint3D() || p2.point3D_id == pid) continue;
          ++links[CanonicalPointPair(pid, p2.point3D_id)];
        }
      }
    }
    s->stat_frag_links = static_cast<int64_t>(links.size());

    // 4) Deterministic strongest-evidence-first order.
    std::vector<std::pair<PointIdPair, int>> ranked(links.begin(),
                                                    links.end());
    std::sort(ranked.begin(), ranked.end(),
              [](const std::pair<PointIdPair, int>& a,
                 const std::pair<PointIdPair, int>& b) {
                if (a.second != b.second) return a.second > b.second;
                if (a.first.a != b.first.a) return a.first.a < b.first.a;
                return a.first.b < b.first.b;
              });

    // 5) Serial merge with redirect chasing (fragment CHAINS A–B, B–C fold
    //    fully within this one pass).
    std::unordered_map<colmap::point3D_t, colmap::point3D_t> redirect;
    const auto resolve = [&](colmap::point3D_t pid) {
      auto it = redirect.find(pid);
      while (it != redirect.end()) {
        pid = it->second;
        it = redirect.find(pid);
      }
      return pid;
    };
    for (const auto& [pair, n_links] : ranked) {
      const colmap::point3D_t a = resolve(pair.a);
      const colmap::point3D_t b = resolve(pair.b);
      if (a == b) continue;  // already folded into the same point
      if (!reconstruction->ExistsPoint3D(a) ||
          !reconstruction->ExistsPoint3D(b)) {
        continue;
      }
      ++s->stat_frag_attempted;
      const colmap::Point3D& pa = reconstruction->Point3D(a);
      const colmap::Point3D& pb = reconstruction->Point3D(b);

      // Union refit: DLT over every observation of both tracks + pose-fixed
      // GN polish (the KNIFE-A recipe).
      std::vector<Eigen::Matrix3x4d> cams_from_world;
      std::vector<Eigen::Vector2d> cam_points;
      std::vector<const colmap::Image*> imgs;
      std::vector<const colmap::Camera*> cams;
      std::vector<Eigen::Vector2d> px;
      bool bad = false;
      const auto push_track = [&](const colmap::Track& track) {
        for (const colmap::TrackElement& el : track.Elements()) {
          if (bad) return;
          if (!reconstruction->ExistsImage(el.image_id)) {
            bad = true;
            return;
          }
          const colmap::Image& im = reconstruction->Image(el.image_id);
          if (!im.HasPose() || el.point2D_idx >= im.NumPoints2D()) {
            bad = true;
            return;
          }
          const colmap::Camera& cm = reconstruction->Camera(im.CameraId());
          const Eigen::Vector2d p = im.Point2D(el.point2D_idx).xy;
          const std::optional<Eigen::Vector2d> nc = cm.CamFromImg(p);
          if (!nc) {
            bad = true;
            return;
          }
          cams_from_world.push_back(im.CamFromWorld().ToMatrix());
          cam_points.push_back(*nc);
          imgs.push_back(&im);
          cams.push_back(&cm);
          px.push_back(p);
        }
      };
      push_track(pa.track);
      push_track(pb.track);
      if (bad || cam_points.size() < 3) {
        ++s->stat_frag_reject_degenerate;
        continue;
      }
      Eigen::Vector3d X;
      if (!colmap::TriangulateMultiViewPoint(
              colmap::span<const Eigen::Matrix3x4d>(cams_from_world.data(),
                                                    cams_from_world.size()),
              colmap::span<const Eigen::Vector2d>(cam_points.data(),
                                                  cam_points.size()),
              &X)) {
        ++s->stat_frag_reject_degenerate;
        continue;
      }
      PolishPointGN(imgs, cams, px, &X);

      // Acceptance 1: EVERY union observation in front of its camera and
      // within the reproj gate of the refit position.
      bool ok = true;
      for (size_t o = 0; o < imgs.size(); ++o) {
        const Eigen::Vector3d xc = imgs[o]->CamFromWorld() * X;
        if (xc.z() <= 0.0) {
          ok = false;
          break;
        }
        const std::optional<Eigen::Vector2d> pp = cams[o]->ImgFromCam(xc);
        if (!pp || (*pp - px[o]).norm() > kMaxReprojPx) {
          ok = false;
          break;
        }
      }
      if (!ok) {
        ++s->stat_frag_reject_reproj;
        continue;
      }
      // Acceptance 2: the union's θ_max at the refit must STRICTLY beat both
      // fragments' current θ_max.
      const double th_a = theta_max(pa.track, pa.xyz);
      const double th_b = theta_max(pb.track, pb.xyz);
      double th_union = 0.0;
      for (size_t i2 = 0; i2 < imgs.size(); ++i2) {
        const Eigen::Vector3d ci =
            imgs[i2]->CamFromWorld().TgtOriginInSrc();
        for (size_t j2 = i2 + 1; j2 < imgs.size(); ++j2) {
          th_union = std::max(
              th_union,
              colmap::CalculateTriangulationAngle(
                  ci, imgs[j2]->CamFromWorld().TgtOriginInSrc(), X));
        }
      }
      if (th_union <= std::max(th_a, th_b)) {
        ++s->stat_frag_reject_theta;
        continue;
      }
      // [P2-FRAG-MERGE-REPRICE] Acceptance 3: the union must LEAVE the
      // low-parallax ambiguity band, not merely rise inside it — a merged
      // point still below the floor keeps the depth-noise position that
      // builds the coherent ghost layer (cap47 verdict). Off by default.
      if (kMinThetaRad > 0.0 && th_union < kMinThetaRad) {
        ++s->stat_frag_reject_min_theta;
        continue;
      }

      const size_t union_len = imgs.size();
      const colmap::point3D_t merged = reconstruction->MergePoints3D(a, b);
      // Install the refit position (the one the gates validated), not
      // MergePoints3D's length-weighted average of two noisy fragments.
      reconstruction->Point3D(merged).xyz = X;
      redirect[a] = merged;
      redirect[b] = merged;
      ++s->stat_frag_accepted;
      s->stat_frag_obs_merged += static_cast<int64_t>(union_len);
    }

    // 6) Post-pass distribution + the conservation invariant.
    summarize(&s->stat_frag_post_npts, &s->stat_frag_post_2view,
              &s->stat_frag_post_lt3, &s->frag_theta_p50_post_deg);
    s->frag_ms = NowMs() - t0;
    const bool conserved =
        s->stat_frag_post_npts + s->stat_frag_accepted ==
        s->stat_frag_pre_npts;
    LOG(WARNING) << "[aether_sfm] frag-merge: links=" << s->stat_frag_links
                 << " attempted=" << s->stat_frag_attempted
                 << " accepted=" << s->stat_frag_accepted
                 << " obs_merged=" << s->stat_frag_obs_merged
                 << " rej{reproj=" << s->stat_frag_reject_reproj
                 << " theta=" << s->stat_frag_reject_theta
                 << " min_theta=" << s->stat_frag_reject_min_theta
                 << " degen=" << s->stat_frag_reject_degenerate << "} pre{n="
                 << s->stat_frag_pre_npts << " 2view="
                 << s->stat_frag_pre_2view << " lt3=" << s->stat_frag_pre_lt3
                 << " theta_p50=" << s->frag_theta_p50_pre_deg
                 << "deg} post{n=" << s->stat_frag_post_npts << " 2view="
                 << s->stat_frag_post_2view << " lt3="
                 << s->stat_frag_post_lt3 << " theta_p50="
                 << s->frag_theta_p50_post_deg << "deg} conservation="
                 << (conserved ? "OK" : "VIOLATED") << " in "
                 << static_cast<int64_t>(s->frag_ms) << "ms";
  } catch (const std::exception& e) {
    // Enhancement pass only — never take the finalize down.
    s->frag_ms = NowMs() - t0;
    LOG(WARNING) << "[aether_sfm] frag-merge aborted: " << e.what();
  }
}

std::string ArkitPoseStorePath(const aether_sfm_session& session) {
  return session.db_path + ".arkit_pose_v1";
}

aether::sfm::ArkitPoseRecordV1 ArkitPoseRecordFromFrame(
    const FrameRecord& frame) {
  aether::sfm::ArkitPoseRecordV1 record;
  record.frame_id = frame.frame_id;
  record.image_id = static_cast<uint32_t>(frame.persisted_image_id);
  record.active = frame.image_id != 0;
  record.frame_identity_digest = frame.frame_identity_digest;
  record.cam_from_world_q_xyzw = {
      frame.cam_from_world.rotation().x(), frame.cam_from_world.rotation().y(),
      frame.cam_from_world.rotation().z(), frame.cam_from_world.rotation().w()};
  record.cam_from_world_t_xyz = {frame.cam_from_world.translation().x(),
                                 frame.cam_from_world.translation().y(),
                                 frame.cam_from_world.translation().z()};
  record.gravity_cam_xyz = {frame.gravity_cam.x(), frame.gravity_cam.y(),
                            frame.gravity_cam.z()};
  return record;
}

bool PersistArkitPoseSnapshot(const aether_sfm_session& session,
                              const FrameRecord& pending) {
  std::vector<aether::sfm::ArkitPoseRecordV1> records;
  records.reserve(session.frames.size() + 1);
  for (const FrameRecord& frame : session.frames) {
    records.push_back(ArkitPoseRecordFromFrame(frame));
  }
  records.push_back(ArkitPoseRecordFromFrame(pending));
  return aether::sfm::WriteArkitPoseStoreV1(ArkitPoseStorePath(session),
                                            records) ==
         aether::sfm::ArkitPoseStoreStatusV1::kOk;
}

// Write-ahead variant: persists the snapshot with `withdrawn_frame_id` already
// marked inactive WITHOUT mutating the session. remove_frame calls this before
// it destroys the frame's db matches, so a crash or io error in the destructive
// half can never leave the pair "sidecar still says active / db rows already
// gone" — which on resume restores the frame as a live starved frame and
// re-matches a photo the user explicitly deleted.
bool PersistArkitPoseSnapshotWithWithdrawal(const aether_sfm_session& session,
                                            int withdrawn_frame_id) {
  if (withdrawn_frame_id < 0 ||
      withdrawn_frame_id >= static_cast<int>(session.frames.size())) {
    return false;
  }
  std::vector<aether::sfm::ArkitPoseRecordV1> records;
  records.reserve(session.frames.size());
  for (const FrameRecord& frame : session.frames) {
    records.push_back(ArkitPoseRecordFromFrame(frame));
  }
  records[static_cast<size_t>(withdrawn_frame_id)].active = false;
  return aether::sfm::WriteArkitPoseStoreV1(ArkitPoseStorePath(session),
                                            records) ==
         aether::sfm::ArkitPoseStoreStatusV1::kOk;
}

bool PersistCurrentArkitPoseSnapshot(const aether_sfm_session& session) {
  std::vector<aether::sfm::ArkitPoseRecordV1> records;
  records.reserve(session.frames.size());
  for (const FrameRecord& frame : session.frames) {
    records.push_back(ArkitPoseRecordFromFrame(frame));
  }
  return aether::sfm::WriteArkitPoseStoreV1(ArkitPoseStorePath(session),
                                            records) ==
         aether::sfm::ArkitPoseStoreStatusV1::kOk;
}

// ── Mandatory ARKit recovery ────────────────────────────────────────────────
// A recovery session is allowed to exist only when the atomic sidecar has one
// valid ARKit pose and camera-frame gravity vector for every DB image. The old
// path rebuilt unposed frames and silently entered COLMAP registration (P3P).
// That path is intentionally gone: any missing/corrupt/count-mismatched sidecar
// blocks recovery. A valid snapshot recreates the registered reconstruction at
// the persisted ARKit poses and triangulates only from already-verified TVGs.
bool RebuildFrameRecordsForResume(aether_sfm_session* s) {
  if (!s || !s->db) return false;
  if (!s->frames.empty()) return true;
  try {
    std::vector<aether::sfm::ArkitPoseRecordV1> pose_records;
    if (aether::sfm::ReadArkitPoseStoreV1(ArkitPoseStorePath(*s),
                                         &pose_records) !=
        aether::sfm::ArkitPoseStoreStatusV1::kOk) {
      return false;
    }
    std::vector<colmap::Image> images = s->db->ReadAllImages();
    if (images.empty() || images.size() != pose_records.size()) return false;
    std::sort(images.begin(), images.end(),
              [](const colmap::Image& a, const colmap::Image& b) {
                return a.ImageId() < b.ImageId();
              });
    auto restored = std::make_shared<colmap::Reconstruction>();
    std::vector<FrameRecord> frames;
    frames.reserve(images.size());
    std::vector<colmap::image_t> image_ids;
    image_ids.reserve(images.size());
    aether_ba_clear_gravity_priors();
    for (size_t i = 0; i < images.size(); ++i) {
      const colmap::Image& image = images[i];
      const aether::sfm::ArkitPoseRecordV1& pose = pose_records[i];
      if (pose.frame_id != static_cast<int32_t>(i) ||
          pose.image_id != static_cast<uint32_t>(image.ImageId())) {
        return false;
      }
      char expected_name[64];
      std::snprintf(expected_name, sizeof(expected_name), "frame_%06zu.jpg", i);
      if (image.Name() != expected_name) return false;

      FrameRecord rec;
      rec.image_id = image.ImageId();
      rec.persisted_image_id = image.ImageId();
      rec.camera_id = image.CameraId();
      rec.camera = s->db->ReadCamera(image.CameraId());
      rec.frame_id = pose.frame_id;
      const colmap::FeatureKeypoints keypoints =
          s->db->ReadKeypoints(image.ImageId());
      const colmap::FeatureDescriptors descriptors =
          s->db->ReadDescriptors(image.ImageId());
      rec.n_keypoints = static_cast<int>(keypoints.size());
      rec.points = colmap::FeatureKeypointsToPointsVector(keypoints);
      rec.descriptors.assign(descriptors.data.data(),
                             descriptors.data.data() + descriptors.data.size());
      rec.frame_identity_digest = FrameIdentityDigestV1(
          image.Name(), rec.camera, rec.points, rec.descriptors);
      if (rec.frame_identity_digest != pose.frame_identity_digest) return false;
      rec.cam_from_world = colmap::Rigid3d(
          Eigen::Quaterniond(pose.cam_from_world_q_xyzw[3],
                             pose.cam_from_world_q_xyzw[0],
                             pose.cam_from_world_q_xyzw[1],
                             pose.cam_from_world_q_xyzw[2]),
          Eigen::Vector3d(pose.cam_from_world_t_xyz[0],
                          pose.cam_from_world_t_xyz[1],
                          pose.cam_from_world_t_xyz[2]));
      rec.gravity_cam = Eigen::Vector3d(pose.gravity_cam_xyz[0],
                                        pose.gravity_cam_xyz[1],
                                        pose.gravity_cam_xyz[2]);
      rec.has_pose = true;

      if (!pose.active) {
        // [WITHDRAWN-PARITY 2026-08-04] Reproduce EVERY mutation that live
        // aether_sfm_remove_frame applies to a withdrawn frame, not just
        // image_id. remove_frame also drops descriptors/points and zeroes
        // n_keypoints; restoring image_id=0 alone left the frame looking fully
        // featured, and FinalizeRematchStarvedFrames gates candidates on
        // n_keypoints only. The withdrawn frame was therefore re-admitted to
        // rematching and its pairs written as WriteMatches(0, other) /
        // WriteTwoViewGeometry(0, other). Those rows insert silently (no
        // foreign keys, and ImagePairToPairId accepts 0), then abort stage-2 in
        // DatabaseCache::Load -> image_to_frame_id.at(0) with std::out_of_range,
        // which RefineGlobalBA turns into RefineFailClosed. The poisoned rows
        // persist, so every later finalize AND resume dies at the same place and
        // the capture can never produce a point cloud again.
        rec.image_id = 0;
        rec.descriptors.clear();
        rec.descriptors.shrink_to_fit();
        rec.points.clear();
        rec.points.shrink_to_fit();
        rec.n_keypoints = 0;
        frames.push_back(std::move(rec));
        continue;
      }
      if (!restored->ExistsCamera(rec.camera_id)) {
        restored->AddCameraWithTrivialRig(rec.camera);
      }
      colmap::Image restored_image;
      restored_image.SetImageId(rec.image_id);
      restored_image.SetName(image.Name());
      restored_image.SetCameraId(rec.camera_id);
      restored_image.SetPoints2D(rec.points);
      restored->AddImageWithTrivialFrame(std::move(restored_image),
                                         rec.cam_from_world);
      const double gravity[3] = {rec.gravity_cam.x(), rec.gravity_cam.y(),
                                 rec.gravity_cam.z()};
      // ⚠️ Same unvalidated 0.5 deg as the live ingest path — see the
      // PROVENANCE GAP note at the other kGravityBaSigmaRad definition. These
      // two constants must be changed together or resume and live capture will
      // anchor at different stiffnesses for the same project.
      constexpr double kGravityBaSigmaRad =
          0.5 * 3.14159265358979323846 / 180.0;
      if (!aether_ba_set_gravity_prior(image.Name().c_str(), gravity,
                                       kGravityBaSigmaRad)) {
        return false;
      }
      image_ids.push_back(rec.image_id);
      frames.push_back(std::move(rec));
    }

    if (image_ids.empty()) return false;
    colmap::DatabaseCache::Options cache_options;
    cache_options.min_num_matches = 15;
    cache_options.load_all_images = true;
    auto cache = colmap::DatabaseCache::Create(*s->db, cache_options);
    colmap::IncrementalPipelineOptions options;
    options.min_num_matches = 15;
    options.load_all_images = true;
    options.triangulation.ignore_two_view_tracks = TriIgnoreTwoViewTracks();
    ApplyBirthGateAB(&options);  // [BIRTH-GATE-AB 2026-08-07]
    colmap::IncrementalMapper mapper(cache);
    mapper.BeginReconstruction(restored);
    for (const colmap::image_t image_id : image_ids) {
      mapper.TriangulateImage(options.Triangulation(), image_id);
    }
    mapper.CompleteAndMergeTracks(options.Triangulation());
    mapper.EndReconstruction(/*discard=*/false);

    s->camera_id = frames.front().camera_id;
    s->frames = std::move(frames);
    s->reg_order = std::move(image_ids);
    s->live_recon = std::move(restored);
    s->live_recon_ready = true;
    return true;
  } catch (const std::exception& e) {
    LOG(ERROR) << "[aether_sfm] mandatory ARKit recovery blocked: "
               << e.what();
    s->frames.clear();
    s->reg_order.clear();
    s->live_recon.reset();
    s->live_recon_ready = false;
    return false;
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
  // [SIGNED 2026-07-26] Un-gated from kProductionOfficialEndpointOnly. This
  // pass is pair GENERATION + matching under colmap-DEFAULT
  // TwoViewGeometryOptions — it only WriteMatches/WriteTwoViewGeometry, never
  // touches a Point3D — i.e. the same official-semantics classification that
  // re-enabled the quadratic pass. It exists to repay the debt the thermal
  // throttle creates: the shipped plugin opts into OFFICIAL_AETHER_LIVE_CAND_K_HOT=6
  // whose "delivery-lossless by construction" promise depends on THIS
  // function re-matching the throttled frames' missing temporal-window pairs
  // at finish time. With the gate in place that promise was silently dead:
  // a 149-frame capture with 118 thermal-serious frames delivered ~20% fewer
  // points on device than the same db replayed with full matching. All 3D
  // geometry remains with the official mapper/triangulator/BA downstream.
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
    // Withdrawn frames all carry image_id == 0, so indexing them here would
    // collapse every one of them onto the same key and let the last writer win.
    for (int i = 0; i < num_frames; ++i) {
      if (s->frames[i].image_id == 0) continue;
      idx_of[s->frames[i].image_id] = i;
    }

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
      // [THERMAL-THROTTLE 2026-07-11] Frames fed with a reduced live K
      // (thermal serious → 12→6) are ALWAYS treated as starved: they may sit
      // above the valid-pair gate (6 healthy pairs > 4) yet still miss half
      // their temporal window. Re-matching restores the full K topology at
      // finish time, which is what keeps the throttle delivery-lossless.
      if (s->frames[i].n_keypoints > 0 &&
          (win_valid[i] < kRematchMinValidWindowPairs ||
           s->frames[i].fed_throttled)) {
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
        // A withdrawn frame is never a rematch candidate. AddOfficialQuadraticPairs
        // already gates on this; the gate is repeated here so the two pair-writing
        // paths cannot drift apart again.
        if (s->frames[j].image_id == 0 || s->frames[f].image_id == 0) continue;
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
        s->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.8;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    std::vector<uint32_t> pair_buf;
    size_t done = 0;
    for (const auto& [j, f] : todo) {
      // [P1-ENRICH-BUDGET] Same time gate as VerifySpatialPair: stop STARTING
      // new re-match attempts once the budget is exhausted; the remaining
      // (least-valuable — todo is gap-ascending) pairs are counted and left
      // for a future finalize retry. No-op unless a budget is armed.
      if (EnrichBudgetExhausted(s)) {
        const int64_t remaining = static_cast<int64_t>(todo.size() - done);
        s->stat_enrich_budget_stopped += remaining;
        LOG(WARNING) << "[aether_sfm] finalize re-match stopped by the "
                        "enrichment time budget: "
                     << remaining << " of " << todo.size()
                     << " candidate pairs left unattempted";
        break;
      }
      ++done;
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
      // [P1-RC7-RETRY] rc=7 gets two backoff retries (cap46: 93/336 finalize
      // re-match pairs failed rc=7 on the still-hot GPU and were lost).
      const int mrc =
          gpu_avail
              ? GpuMatchGemmPairsRetry(s, s->frames[j].frame_id, fa->desc,
                                       fa->n, s->frames[f].frame_id, fb->desc,
                                       fb->n, ratio, pair_buf.data(), cap,
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
      const auto tvg = EstimateMandatoryFrameTwoViewGeometry(
          s->frames[j], *fa->pts, s->frames[f], *fb->pts, matches,
          tvg_options);
      if (!MandatoryGravityTvgPersistable(tvg)) {
        // Do not create an ExistsMatches tombstone: the pair remains debt and
        // may be retried after more correspondences become available.
        continue;
      }
      s->db->WriteMatches(s->frames[j].image_id, s->frames[f].image_id,
                          matches);
      const colmap::TwoViewGeometry& geometry = tvg.geometry;
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
    // [ENRICH-JSONL 2026-07-26, signed] Pullable summary — glog is invisible
    // in release builds, and the K6 lossless promise must be verifiable from
    // the sidecar alone (written > 0 on a throttled capture, unattempted 0).
    {
      char rline[288];
      std::snprintf(rline, sizeof(rline),
                    "{\"t\":%lld,\"type\":\"finalize_rematch_summary\","
                    "\"starved_frames\":%lld,\"candidates\":%lld,"
                    "\"attempted\":%lld,\"written\":%lld,\"inliers\":%lld,"
                    "\"failed\":%lld,\"unattempted\":%lld}",
                    static_cast<long long>(EpochMs()),
                    (long long)n_starved,
                    (long long)s->stat_finalize_rematch_candidates,
                    (long long)s->stat_finalize_rematch_attempted,
                    (long long)s->stat_finalize_rematch_written,
                    (long long)s->stat_finalize_rematch_inliers,
                    (long long)s->stat_finalize_rematch_failed,
                    (long long)(todo.size() - done));
      AppendMatchFailJsonl(s, rline);
    }
  } catch (const std::exception& e) {
    // Enhancement pass only — a failure here must never take finalize down.
    LOG(WARNING) << "[aether_sfm] finalize re-match aborted: " << e.what();
  }
}

// [OFFICIAL-QUADRATIC 2026-07-25] Faithful port of COLMAP's sequential
// quadratic-overlap pair generation.
//
// Upstream: SequentialPairingOptions{overlap = 10, quadratic_overlap = true}
// (colmap/controllers/pairing.h:88-91) and SequentialPairGenerator::Next
// (pairing.cc:519-527), which emits, for every image i, the pairs
// (i, i + 2^k) for k = 0 .. overlap-1 — i.e. gaps 1,2,4,...,512.
//
// WHY: the capture-time K-window (SelectStreamCandidates, K=12) covers only
// near gaps, and the ARKit spatial-revisit pass is disabled at the official
// endpoint, so the shipped binary produces NO long-range edges at all. Those
// edges (i+128 / i+256 / i+512) are exactly what keeps a several-hundred-frame
// sequence from drifting, which upstream enables by default.
//
// This is pair SELECTION only — as upstream, candidates are matched with the
// shipped matcher, verified by colmap::EstimateTwoViewGeometry under COLMAP
// DEFAULT TwoViewGeometryOptions, and appended to the matches /
// two_view_geometries tables. No Point3D or observation is touched: all
// geometry is left to the official mapper / triangulator / global BA that
// consume the db next, so the delivered model is still the official endpoint.
//
// Deliberately NOT gated by kProductionOfficialEndpointOnly: that constant
// disables the SELF-DEVELOPED passes, one of which (RestoreTemporalDetail)
// runs AFTER the final global BA. This pass is upstream COLMAP behaviour and
// runs strictly BEFORE it. Kill switch: OFFICIAL_AETHER_QUADRATIC_OVERLAP=0.
int OfficialQuadraticOverlap() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_QUADRATIC_OVERLAP")) {
      const int v = std::atoi(e);
      if (v >= 0) return v;
    }
    return 10;  // colmap SequentialPairingOptions::overlap default
  }();
  return cached;
}

void AddOfficialQuadraticPairs(aether_sfm_session* s) {
  const int overlap = OfficialQuadraticOverlap();
  if (overlap <= 0) return;
  if (!s || !s->db || s->frames.size() < 2 || s->camera_id == 0) return;
  const bool gpu_avail =
      s->options.use_gpu_match && (aether_gpu_match_gemm_pairs != nullptr);
  // Same fail-closed policy as the rest of finalize: a requested-but-missing
  // Metal matcher never degrades into O(N^2) CPU matching.
  if (s->options.use_gpu_match && !gpu_avail) return;
  const double t0 = NowMs();
  try {
    const int num_frames = static_cast<int>(s->frames.size());

    // 1) Upstream pair set: (i, i + 2^k), k = 0..overlap-1. Pairs already in
    //    the db (capture-time K-window) are skipped — re-matching identical
    //    descriptors at the same ratio would only rewrite the same rows.
    std::vector<std::pair<int, int>> todo;
    for (int i = 0; i < num_frames; ++i) {
      for (int k = 0; k < overlap; ++k) {
        const int64_t j64 = static_cast<int64_t>(i) + (1ll << k);
        if (j64 >= num_frames) break;
        const int j = static_cast<int>(j64);
        const colmap::image_t img1 = s->frames[i].image_id;
        const colmap::image_t img2 = s->frames[j].image_id;
        if (img1 == 0 || img2 == 0 || img1 == img2) continue;
        if (s->db->ExistsMatches(img1, img2) ||
            s->db->ExistsTwoViewGeometry(img1, img2)) {
          continue;
        }
        todo.emplace_back(i, j);
      }
    }
    // [QUAD-PREPAY 2026-07-26] No early return on an empty todo: the
    // capture-idle prepay may have paid the whole debt, and the pullable
    // summary below must land either way so a device run stays verifiable
    // from the sidecar alone.
    // [ENRICH-ORDER 2026-07-26] Gap-ascending so a budget stop sheds the
    // LEAST valuable tail first: measured on cap_1785066707194992, gap-16
    // pairs average ~130 inliers while gap-128 pairs average 0.7 — the
    // original i-major order interleaves them and a mid-pass stop loses
    // high-value near pairs while having paid for far garbage.
    std::stable_sort(todo.begin(), todo.end(),
                     [](const std::pair<int, int>& a,
                        const std::pair<int, int>& b) {
                       return (a.second - a.first) < (b.second - b.first);
                     });

    // 2) Feature access: borrow the in-memory FrameRecord (live sessions) or
    //    load keypoints+descriptors from the db (resume sessions). Unlike the
    //    K-windowed re-match, the reach here is up to 512 frames, so db loads
    //    use a bounded LRU instead of a sliding window. Borrowed entries own
    //    no memory and are never evicted; `pin` protects the partner frame of
    //    the pair currently being matched.
    struct QuadFeat {
      const uint8_t* desc = nullptr;
      const std::vector<Eigen::Vector2d>* pts = nullptr;
      int n = 0;
      bool loaded = false;  // owns desc_store/pts_store
      uint64_t last_use = 0;
      std::vector<uint8_t> desc_store;
      std::vector<Eigen::Vector2d> pts_store;
    };
    constexpr int kQuadMaxLoadedFrames = 64;  // ~1 MB/frame at 8192 features
    std::unordered_map<int, QuadFeat> cache;
    uint64_t use_clock = 0;
    int loaded_count = 0;
    const auto get_feat = [&](int i, int pin) -> const QuadFeat* {
      auto it = cache.find(i);
      if (it != cache.end()) {
        it->second.last_use = ++use_clock;
        return it->second.n > 0 ? &it->second : nullptr;
      }
      const FrameRecord& fr = s->frames[i];
      if (!fr.descriptors.empty() && !fr.points.empty()) {
        QuadFeat& feat = cache[i];
        feat.desc = fr.descriptors.data();
        feat.pts = &fr.points;
        feat.n = fr.n_keypoints;
        feat.last_use = ++use_clock;
        return feat.n > 0 ? &feat : nullptr;
      }
      if (loaded_count >= kQuadMaxLoadedFrames) {
        int victim = -1;
        uint64_t oldest = UINT64_MAX;
        for (const auto& [idx, f] : cache) {
          if (f.loaded && idx != pin && f.last_use < oldest) {
            oldest = f.last_use;
            victim = idx;
          }
        }
        // unordered_map erase only invalidates references to the erased
        // element, and `pin` is excluded above, so the caller's held pointer
        // stays valid.
        if (victim >= 0) {
          cache.erase(victim);
          --loaded_count;
        }
      }
      QuadFeat& feat = cache[i];
      feat.last_use = ++use_clock;
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
      feat.loaded = true;
      ++loaded_count;
      return &feat;
    };

    // 3) Match + verify + persist. Same matcher chain and ratio as add_frame;
    //    COLMAP-DEFAULT two-view geometry options (no guided re-match, no
    //    tightened inlier gates) so what lands in sqlite is what upstream
    //    would have written for the same pair.
    const double ratio =
        s->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.8;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    std::vector<uint32_t> pair_buf;
    int64_t written = 0;
    int64_t budget_stopped = 0;
    size_t done = 0;
    // [QUAD-PIPELINE 2026-07-26, signed] Order-preserving prefetch (see
    // QuadPipelineEnabled for provenance). Eligibility: GPU matcher present
    // and every todo frame's features in memory (live sessions always;
    // resume sessions fall back to the serial loop below because the
    // db-load LRU cache must not be read across threads).
    bool quad_pipeline = QuadPipelineEnabled() && gpu_avail;
    if (quad_pipeline) {
      for (const auto& [pi, pj] : todo) {
        if (s->frames[pi].descriptors.empty() ||
            s->frames[pj].descriptors.empty()) {
          quad_pipeline = false;
          break;
        }
      }
    }
    if (quad_pipeline) {
      struct QuadMatchResult {
        int i = 0, j = 0;
        bool ran_matcher = false;
        int mrc = 1;
        int num_matches = 0;
        std::vector<uint32_t> pairs;
      };
      std::mutex q_mu;
      std::condition_variable q_cv;
      std::deque<QuadMatchResult> q;
      bool producer_done = false;
      bool consumer_abort = false;
      constexpr size_t kQuadPipelineDepth = 3;  // ≤3×64KB result lookahead
      std::thread producer([&] {
#if defined(__APPLE__)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
        for (const auto& [pi, pj] : todo) {
          {
            std::unique_lock<std::mutex> lk(q_mu);
            q_cv.wait(lk, [&] {
              return q.size() < kQuadPipelineDepth || consumer_abort;
            });
            if (consumer_abort) break;
          }
          QuadMatchResult r;
          r.i = pi;
          r.j = pj;
          const FrameRecord& fa = s->frames[pi];
          const FrameRecord& fb = s->frames[pj];
          const int cap =
              fa.n_keypoints < fb.n_keypoints ? fa.n_keypoints : fb.n_keypoints;
          if (cap > 0) {
            r.pairs.resize(static_cast<size_t>(cap) * 2);
            r.ran_matcher = true;
            // Deterministic Metal matcher + mutual cross-check — no PRNG on
            // this thread; the RANSAC stream stays on the consumer.
            // [EPI-PRIOR 2026-07-27] experiment arm first (default OFF).
            if (EpiPriorMatchEnabled() &&
                ArkitGuidedMatchPair(s, fa, fb, pj - pi, ratio,
                                     r.pairs.data(), cap, &r.num_matches)) {
              r.mrc = 0;
            } else {
              r.mrc = GpuMatchGemmPairsRetry(
                  s, fa.frame_id, fa.descriptors.data(), fa.n_keypoints,
                  fb.frame_id, fb.descriptors.data(), fb.n_keypoints, ratio,
                  r.pairs.data(), cap, &r.num_matches);
            }
          }
          std::lock_guard<std::mutex> lk(q_mu);
          q.push_back(std::move(r));
          q_cv.notify_all();
        }
        std::lock_guard<std::mutex> lk(q_mu);
        producer_done = true;
        q_cv.notify_all();
      });
      // Consumer = THIS thread: budget gate, stats, TVG, and db writes in
      // exact todo order — the same sequence the serial loop produces.
      for (size_t idx = 0; idx < todo.size(); ++idx) {
        QuadMatchResult r;
        {
          std::unique_lock<std::mutex> lk(q_mu);
          q_cv.wait(lk, [&] { return !q.empty() || producer_done; });
          if (q.empty()) break;  // producer ended early
          r = std::move(q.front());
          q.pop_front();
          q_cv.notify_all();
        }
        if (EnrichBudgetExhausted(s)) {
          budget_stopped = static_cast<int64_t>(todo.size() - done);
          s->stat_enrich_budget_stopped += budget_stopped;
          LOG(WARNING) << "[aether_sfm] official quadratic overlap stopped by "
                          "the enrichment time budget: "
                       << budget_stopped << " of " << todo.size()
                       << " candidate pairs left unattempted";
          break;
        }
        ++done;
        if (!r.ran_matcher) continue;  // cap<=0 (serial: skipped pre-attempt)
        ++s->stat_spatial_quadratic_attempted;
        if (r.mrc != 0) continue;
        if (r.num_matches <= 0) continue;
        colmap::FeatureMatches matches(r.num_matches);
        for (int m = 0; m < r.num_matches; ++m) {
          matches[m].point2D_idx1 = r.pairs[2 * m];
          matches[m].point2D_idx2 = r.pairs[2 * m + 1];
        }
        const colmap::image_t img1 = s->frames[r.i].image_id;
        const colmap::image_t img2 = s->frames[r.j].image_id;
        const auto tvg = EstimateMandatoryFrameTwoViewGeometry(
            s->frames[r.i], s->frames[r.i].points, s->frames[r.j],
            s->frames[r.j].points, matches, tvg_options);
        if (!MandatoryGravityTvgPersistable(tvg)) continue;
        s->db->WriteMatches(img1, img2, matches);
        s->db->WriteTwoViewGeometry(img1, img2, tvg.geometry);
        ++s->stat_spatial_quadratic_written;
        ++written;
      }
      {
        std::lock_guard<std::mutex> lk(q_mu);
        consumer_abort = true;
        q_cv.notify_all();
      }
      producer.join();
    } else
    for (const auto& [i, j] : todo) {
      // [ENRICH-ORDER 2026-07-26] Same per-pair budget gate as the starved-
      // frame re-match: stop STARTING new pairs once the enrichment budget is
      // exhausted (no-op unless armed). With the gap-ascending order above,
      // the unattempted remainder is the least-valuable far tail.
      if (EnrichBudgetExhausted(s)) {
        budget_stopped = static_cast<int64_t>(todo.size() - done);
        s->stat_enrich_budget_stopped += budget_stopped;
        LOG(WARNING) << "[aether_sfm] official quadratic overlap stopped by "
                        "the enrichment time budget: "
                     << budget_stopped << " of " << todo.size()
                     << " candidate pairs left unattempted";
        break;
      }
      ++done;
      const QuadFeat* fa = get_feat(i, /*pin=*/-1);
      if (!fa) continue;
      const QuadFeat* fb = get_feat(j, /*pin=*/i);
      if (!fb) continue;
      const int cap = fa->n < fb->n ? fa->n : fb->n;
      if (cap <= 0) continue;
      pair_buf.resize(static_cast<size_t>(cap) * 2);
      int num_matches = 0;
      ++s->stat_spatial_quadratic_attempted;
      // [EPI-PRIOR 2026-07-27] experiment arm first (default OFF); any
      // failure falls through to the unchanged full-GEMM path.
      int mrc = 1;
      if (EpiPriorMatchEnabled() && gpu_avail &&
          ArkitGuidedMatchPair(s, s->frames[i], s->frames[j], j - i, ratio,
                               pair_buf.data(), cap, &num_matches)) {
        mrc = 0;
      }
      // [P1-RC7-RETRY] transient rc=7 on a hot GPU gets two backoff retries.
      if (mrc != 0) {
        mrc =
            gpu_avail ? GpuMatchGemmPairsRetry(
                            s, s->frames[i].frame_id, fa->desc, fa->n,
                            s->frames[j].frame_id, fb->desc, fb->n, ratio,
                            pair_buf.data(), cap, &num_matches)
                      : aether_sift_match_pairs(fa->desc, fa->n, fb->desc,
                                                fb->n, ratio, pair_buf.data(),
                                                cap, &num_matches);
      }
      if (mrc != 0) continue;          // still hot / unavailable: skip the pair
      if (num_matches <= 0) continue;  // legitimate zero-match pair

      colmap::FeatureMatches matches(num_matches);
      for (int m = 0; m < num_matches; ++m) {
        matches[m].point2D_idx1 = pair_buf[2 * m];
        matches[m].point2D_idx2 = pair_buf[2 * m + 1];
      }
      const colmap::image_t img1 = s->frames[i].image_id;
      const colmap::image_t img2 = s->frames[j].image_id;
      const auto tvg = EstimateMandatoryFrameTwoViewGeometry(
          s->frames[i], *fa->pts, s->frames[j], *fb->pts, matches,
          tvg_options);
      if (!MandatoryGravityTvgPersistable(tvg)) continue;
      s->db->WriteMatches(img1, img2, matches);
      s->db->WriteTwoViewGeometry(img1, img2, tvg.geometry);
      ++s->stat_spatial_quadratic_written;
      ++written;
    }
    LOG(WARNING) << "[aether_sfm] official quadratic overlap: overlap="
                 << overlap << " candidates=" << todo.size()
                 << " written=" << written << " in " << (NowMs() - t0)
                 << " ms";
    // [ENRICH-JSONL 2026-07-26, signed] glog is invisible in release builds
    // (DeviceLog only carries Dart lines), so the pass summary goes to the
    // pullable sidecar — verifying a device run must not require pulling the
    // 200 MB db to count pair gaps.
    {
      char qline[288];
      std::snprintf(qline, sizeof(qline),
                    "{\"t\":%lld,\"type\":\"quadratic_summary\","
                    "\"candidates\":%zu,\"written\":%lld,"
                    "\"budget_stopped\":%lld,\"ms\":%.0f,"
                    "\"prepaid_attempted\":%lld,\"prepaid_written\":%lld}",
                    static_cast<long long>(EpochMs()), todo.size(),
                    (long long)written, (long long)budget_stopped,
                    NowMs() - t0, (long long)s->stat_prepay_attempted,
                    (long long)s->stat_prepay_written);
      AppendMatchFailJsonl(s, qline);
    }
    // [EPI-PRIOR 2026-07-27] experiment-arm accounting (absent when off).
    if (EpiPriorMatchEnabled()) {
      char eline[224];
      std::snprintf(eline, sizeof(eline),
                    "{\"t\":%lld,\"type\":\"epi_summary\","
                    "\"attempted\":%lld,\"fallback\":%lld,"
                    "\"band_base\":%.0f,\"band_per_gap\":%.0f,"
                    "\"band_max\":%.0f,\"fallback_min\":%d}",
                    static_cast<long long>(EpochMs()),
                    (long long)s->stat_epi_attempted,
                    (long long)s->stat_epi_fallback, EpiBandBasePx(),
                    EpiBandPerGapPx(), EpiBandMaxPx(), EpiFallbackMinMatches());
      AppendMatchFailJsonl(s, eline);
    }
  } catch (const std::exception& e) {
    LOG(WARNING) << "[aether_sfm] official quadratic overlap aborted: "
                 << e.what();
  } catch (...) {
    LOG(WARNING) << "[aether_sfm] official quadratic overlap aborted";
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
// tested. Unset -> the shipped 2.0° (T20 2026-07-11, scan-matrix verdict —
// moved in lock-step with the two streaming gates, see
// LiveCreateTriMinAngleRad).
double TriMinAngleDeg(const char* env_name) {
  const char* e = std::getenv(env_name);
  if (e && e[0]) {
    const double d = std::atof(e);
    if (d > 0.0) return d;
  }
  return 2.0;
}

// [TRI-TRANSITIVITY 2026-08-05] IncrementalTriangulator::Options::
// max_transitivity —— 搜索对应关系时的**传递深度**。上游默认 1(只看直接匹配
// 过的帧对);抬到 2 会多走一层传递:A↔B、B↔C 已匹配但 A↔C 未建立时,也把
// A、C 的观测纳入同一 track 考察。
//
// 为什么打这个靶:我方 146 帧真机采集实测 track 长度 **61.3% 是 2-view**
// (p50=2 / p90=5)。分层实测显示 2-view 的代价是真的:σ_depth p50 5.89mm vs
// 7+ 视 1.14mm(5.2×),且 31.7% 的 2-view 视差不足 5°。而我方全部采集都是
// out-and-back(净绕行 ≤0.37 圈、无一回到起点),三元组"缺边"正是短 track 的
// 结构性来源 —— 传递搜索直接补这类缺口,且**零 GPU、零新增匹配、零热**
// (只在已匹配的对应图上多走一层,不跑 matcher)。
//
// ⚠️ 上游同结构体里 complete_max_transitivity 默认已是 5(Complete 步早就走
// 多层),所以把 Triangulate/Retriangulate 的深度从 1 抬到 2 是与上游自身设计
// 一致的方向,不是发明新机制。
// ⚠️ 代价未知:传递搜索的对应集会变大 → 三角化候选更多 → CPU 上升幅度需实测。
// 因此**默认关**(unset ⇒ 返回上游默认 1,逐字节复现现状),仅
// OFFICIAL_AETHER_TRI_TRANSITIVITY=2 时生效,便于单变量 A/B。
int TriMaxTransitivity() {
  const char* e = std::getenv("OFFICIAL_AETHER_TRI_TRANSITIVITY");
  if (e && e[0]) {
    const int v = std::atoi(e);
    if (v >= 1 && v <= 5) return v;
  }
  return 1;  // 上游默认
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
// experiments: OFFICIAL_AETHER_BA_MIXED=1 (+OFFICIAL_AETHER_BA_MIXED_REFINE=N, default 3).
// Capture-time LOCAL BA is never touched either way.
bool BaMixedEnabled() {
  const char* e = std::getenv("OFFICIAL_AETHER_BA_MIXED");
  return e && e[0] == '1';
}

// [AETHER BA-THREADS 2026-07-11] Finalize BA ceres thread budget. Previous
// behavior was num_threads=-1 -> hardware_concurrency (host M3 Pro 12, A16 6)
// for every solve above the 6000-residual floor. New default = min(6, hw-2):
// leaves headroom for the rest of the process (GPU-matcher CPU side, db I/O,
// Dart/UI on device) instead of saturating every core with Schur workers —
// A16: 4 threads (2P+2E stay free), host M3 Pro: 6. Env OFFICIAL_AETHER_BA_THREADS
// overrides (any positive integer). The stage-1 overlap window still halves
// whatever this returns (enrichment is the critical path there); stage 2 and
// the full re-run run the full budget.
int FinalizeBaThreads() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_BA_THREADS")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    // [BA-THREADS-POST 2026-07-28] min(6, hw-2) → min(6, hw). The finalize
    // runs strictly AFTER capture: the camera is off, so the two-core camera
    // reserve is dead weight — the same rationale as the matcher sprint mode
    // and the signed stage-1 full-thread knife. Quality: thread count was
    // proven bit-equal 07-11 (signed, min(6,hw-2) knife) and re-proven
    // 2026-07-28 on host (_host_fixtures/prepay_threads_exact: T4/T6 ×2
    // delivered PLYs byte-identical, iteration counts identical; finalize
    // wall −16.1%/−12.8%). Device: A16 4 → 6. The capture-period windowed
    // incremental BA keeps its own reserve via LiveBaThreads() below.
    const int hw = static_cast<int>(std::thread::hardware_concurrency());
    return std::max(1, std::min(6, hw));
  }();
  return cached;
}

// Capture-period thread budget (windowed incremental global BA): the camera,
// GPU-matcher CPU side, and Dart UI are live — keep the two-core reserve.
int LiveBaThreads() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_LIVE_BA_THREADS")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    const int hw = static_cast<int>(std::thread::hardware_concurrency());
    return std::max(1, std::min(6, hw - 2));
  }();
  return cached;
}

// [LIVE-LBA-THREADS 2026-07-29] Capture-time LOCAL BA thread knobs.
//
// The streaming path builds its OWN IncrementalPipelineOptions (see the
// add_frame body) and never touched either of these, so it silently inherited
// the two upstream defaults:
//   num_threads = -1                                   → every core
//   ba_min_num_residuals_for_cpu_multi_threading = 50000
// and bundle_adjustment_ceres.cc forces num_threads=1 whenever the problem is
// UNDER that floor. Our 6-image window carries ~39k residuals, i.e. under it —
// measured on cap7_day_A: 240 solves at threads=1 vs 102 at threads=12. So the
// hot path oscillates between fully serial and fully saturating, and never sits
// at the deliberate LiveBaThreads() reserve that exists precisely to keep the
// camera/UI alive mid-capture (the reserve is only wired to the periodic
// incremental GLOBAL BA).
//
// [AETHER-T2 profile] the Ceres minimizer is 92.6% of the solve and the solve is
// 81.5% of local BA, so thread count is the largest LOSSLESS lever available.
//
// Both knobs default to "leave the upstream value alone" so an unset
// environment is byte-identical to the shipped binary — the arm stays a clean
// single variable.
int LiveLocalBaThreadsOverride() {  // <=0 → don't touch
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_LIVE_LBA_THREADS")) {
      const int v = std::atoi(e);
      if (v > 0) return v;
    }
    return 0;
  }();
  return cached;
}

int LiveLocalBaMtFloorOverride() {  // <0 → don't touch
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_LIVE_LBA_MT_FLOOR")) {
      const int v = std::atoi(e);
      if (v >= 0) return v;
    }
    return -1;
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
    pipeline_opts->triangulation.ignore_two_view_tracks = TriIgnoreTwoViewTracks();
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
    //  - keep-CAUCHY local pass-2 (incremental_mapper.cc) + lnum=6: better preview
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
    // (OFFICIAL_AETHER_BA_THREADS override; default min(6, hw-2), was -1 -> all
    // cores; quality equal to baseline to 4 decimals on every 9-gate metric,
    // host A/B). Mixed precision stays OFF unless OFFICIAL_AETHER_BA_MIXED=1
    // (A/B-vetoed default, see BaMixedEnabled). num_threads also feeds the
    // local-BA solves of this batch path — intended: same headroom
    // rationale, and the live capture-time local BA does NOT go through here
    // (hand-built options in the streaming path).
    pipeline_opts->ba_global_mixed_precision = BaMixedEnabled();
    pipeline_opts->num_threads = FinalizeBaThreads();
    pipeline_opts->mapper.ba_local_num_images = 6;
    // Each image already carries the calibrated intrinsics of its exact ARFrame.
    // Keep those values constant throughout mapper registration and every BA.
    pipeline_opts->ba_refine_focal_length = false;
    pipeline_opts->ba_refine_principal_point = false;
    pipeline_opts->ba_refine_extra_params = false;
    // [TRI-ANGLE 2026-07-11] Creation parallax gate 1.5°(colmap default)→2.0°
    // (first shipped at 3.0°, re-priced to 2.0° by the T20 scan-matrix verdict),
    // aligned with BOTH streaming creation gates (add_frame kMinTriAngleRad and
    // RestoreTemporalDetail — 2.0° each). The delivered cloud's low-parallax
    // tail was born HERE: the mapper's IncrementalTriangulator created tracks
    // down to 1.5° pairwise parallax (cap47 attribution: 25.9% of native
    // 2-view delivered points sat below 3° — depth-ambiguous fuzz around thin
    // structures). Creation-only: filter_min_tri_angle stays at its default,
    // so BA may still keep an existing point that drifts into [1.5°, 3°) —
    // same semantics as the live path. init_min_tri_angle (initial pair) is
    // far above both and unaffected (incremental_pipeline.cc:459 overrides
    // min_angle for the init pair only).
    pipeline_opts->triangulation.min_angle =
        TriMinAngleDeg("OFFICIAL_AETHER_TRI_MIN_ANGLE");
    // [BIRTH-GATE-AB 2026-08-07] env 设置时覆盖上面的出生门 + filter 门。
    ApplyBirthGateAB(pipeline_opts.get());
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

// Final refinement is fail-closed. A db-driven full rerun would register
// cameras through unconstrained absolute pose (P3P), discarding the mandatory
// ARKit gravity identity. That historical fallback is intentionally removed:
// an exception is reported as ERROR and the immutable db + pose sidecar remain
// available for an exact known-pose retry.
// [GHOST-MASK 2026-07-12] defined after WriteFinalizeSegments below.
void MaybeWriteGhostMask(aether_sfm_session* s,
                         const colmap::Reconstruction& recon);

void RefineFailClosed(aether_sfm_session* s, const char* why) {
  LOG(ERROR) << "[aether_sfm] mandatory-ARKit refine blocked (" << why
             << "); no P3P/full-rerun fallback is permitted";
  s->finalize_status.store(3);  // AETHER_SFM_FINALIZE_ERROR
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
  popts->triangulation.ignore_two_view_tracks = TriIgnoreTwoViewTracks();
  popts->min_num_matches = 15;
  popts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
  popts->ba_global_loss_type = 2;              // CAUCHY (was defaulting to 0=TRIVIAL)
  popts->ba_global_loss_scale = 1.0;
  popts->ba_global_function_tolerance = 1e-6;  // converge-stop
  popts->ba_global_max_refinements = 5;
  popts->ba_global_max_num_iterations = 50;
  popts->ba_refine_focal_length = false;
  popts->ba_refine_principal_point = false;
  popts->ba_refine_extra_params = false;
  // [AETHER BA-MIXED/THREADS 2026-07-11] Finalize phase-2 (stage 1 + stage 2)
  // global BA: the finalize thread budget (default min(6, hw-2),
  // OFFICIAL_AETHER_BA_THREADS override; quality equal to baseline to 4 decimals on
  // every 9-gate metric, host A/B). Mixed precision stays OFF unless
  // OFFICIAL_AETHER_BA_MIXED=1 (A/B-vetoed default, see BaMixedEnabled). Stage 1
  // additionally halves the budget during the enrichment overlap window (see
  // RefineGlobalBA).
  popts->ba_global_mixed_precision = BaMixedEnabled();
  popts->num_threads = FinalizeBaThreads();
  // [TRI-ANGLE 2026-07-11] Same 2.0° (T20) creation gate as RunIncremental:
  // IterativeGlobalRefinement's CompleteAndMergeTracks/retriangulation reads
  // Triangulation() too — keep phase 2 from re-admitting the <2° tail that
  // phase 1 now refuses to create.
  popts->triangulation.min_angle = TriMinAngleDeg("OFFICIAL_AETHER_TRI_MIN_ANGLE_P2");
  // [BIRTH-GATE-AB 2026-08-07] env 设置时覆盖上面的出生门 + filter 门。
  ApplyBirthGateAB(popts.get());
  // ⛔ [TRI-TRANSITIVITY 2026-08-05 已撤回] 这里曾设 triangulation.max_transitivity,
  // **在 finalize 路径上完全无效**,host A/B 两臂逐位相同(n_points/track3plus/
  // n_obs/reproj 全等)。根因:finalize 的 IterativeGlobalRefinement 只跑
  // CompleteAndMergeTracks + Retriangulate,而
  //   · Retriangulate 遍历 obs_manager_->ImagePairs(),只处理**已匹配过**的欠重建
  //     帧对,源码里根本不读 max_transitivity;
  //   · 读 max_transitivity 的是 IncrementalTriangulator::TriangulateImage
  //     (incremental_triangulator.cc:133/213),那只在**增量注册新图**时跑。
  // finalize 阶段所有图早已注册完 ⇒ 该旋钮在此处是死代码。
  // 正确位置是拍摄期的 TriangulateImage 调用点(本文件 4659/7644/8615),
  // 但那直接撞热预算,需先 host 量代价再定。
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

// [AETHER FINALIZE-SEGMENTS 2026-07-11] Persist the finalize worker's phase-2
// internal segment timings + BA-solver observability as ONE JSON object at
// <db_dir>/official_finalize_segments.json. Motivation (cap44): these numbers only ever
// reached stderr, which a detached (unplugged) device run loses entirely —
// the 105 s single-core finalize tail was unattributable. The Dart layer reads
// this file after REFINED and forwards it into telemetry_dart.jsonl.
// Telemetry-only: zero algorithm changes; best-effort (failures are logged and
// swallowed). Written BEFORE finalize_status flips to REFINED so the Dart
// reader never races a partial file (write-to-temp + atomic rename).
void WriteFinalizeSegments(aether_sfm_session* s, bool live_reuse,
                           double cache_pre_ms, double enrich_ms,
                           double stage1_ms, int stage1_rounds,
                           const char* stage1_state, double stage2_ms,
                           int stage2_rounds_budget, double temporal_ms,
                           double total_ms) {
  try {
    const std::filesystem::path dir =
        std::filesystem::path(s->db_path).parent_path();
    const std::filesystem::path tmp = dir / "official_finalize_segments.json.tmp";
    const std::filesystem::path dst = dir / "official_finalize_segments.json";
    std::string solver_used, sparse_backend, dense_backend;
    int mixed = 0, threads = 0;
    colmap::AetherLastBaSolveInfo(&solver_used, &sparse_backend, &mixed,
                                  &threads, &dense_backend);
    const int64_t epoch_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch())
            .count();
    char buf[3520];  // [PROBE-GATE/IDLE-PREPAY 2026-08-07] +6 fields headroom
    const int n = std::snprintf(
        buf, sizeof(buf),
        "{\"t\":%lld,\"live_reuse\":%d,"
        "\"cache_pre_ms\":%lld,\"enrich_ms\":%lld,"
        "\"stage1_ms\":%lld,\"stage1_rounds\":%d,\"stage1_state\":\"%s\","
        "\"stage2_ms\":%lld,\"stage2_rounds_budget\":%d,"
        "\"temporal_ms\":%lld,\"total_ms\":%lld,"
        "\"rematch_starved_frames\":%lld,\"rematch_candidates\":%lld,"
        "\"rematch_attempted\":%lld,\"rematch_written\":%lld,"
        "\"rematch_inliers\":%lld,\"rematch_failed\":%lld,"
        "\"rematch_budget\":%d,"
        // [P1 2026-07-11] finalize-speedup package attribution: idle repay /
        // rc=7 retry / enrichment time-budget truncation.
        "\"repay_calls\":%lld,\"repay_attempted\":%lld,"
        "\"repay_written\":%lld,\"repay_inliers\":%lld,"
        "\"repay_failed\":%lld,\"repay_skipped_thermal\":%lld,"
        // [IDLE-PREPAY 2026-08-07] idle-channel starved-window repay ticks.
        "\"idle_prepay_ticks\":%lld,"
        // [PROBE-GATE 2026-08-07] live probe pre-scoring attribution (all
        // zero unless OFFICIAL_AETHER_PROBE_GATE_MIN > 0).
        "\"probe_attempted\":%lld,\"probe_skipped\":%lld,"
        "\"probe_passed\":%lld,\"probe_fail_open\":%lld,\"probe_ms\":%lld,"
        "\"gpu_retry_attempts\":%lld,\"gpu_retry_recovered\":%lld,"
        "\"enrich_budget_mode\":%d,\"enrich_budget_stopped\":%lld,"
        // [KNIFE-A 2026-07-11] 2-view upgrade attribution (all zero when the
        // three env opt-ins are unset).
        "\"grow_refit_attempted\":%lld,\"grow_refit_accepted\":%lld,"
        "\"grow_refit_saved\":%lld,\"grow_refit_min_theta_rej\":%lld,"
        "\"upgrade_eligible\":%lld,\"upgrade_attempted\":%lld,"
        "\"upgrade_accepted\":%lld,\"upgrade_obs_added\":%lld,"
        "\"upgrade_ms\":%lld,"
        "\"theta_pre_n\":%lld,\"theta_pre_2view\":%lld,"
        "\"theta_pre_lt3\":%lld,\"theta_pre_p50_deg\":%.3f,"
        "\"theta_post_n\":%lld,\"theta_post_2view\":%lld,"
        "\"theta_post_lt3\":%lld,\"theta_post_p50_deg\":%.3f,"
        "\"enrich_targeted_tracks\":%lld,\"enrich_targeted_scored\":%lld,"
        // [P2-FRAG-MERGE 2026-07-11] fragment-merge attribution (all zero
        // unless OFFICIAL_AETHER_FRAG_MERGE=1).
        "\"frag_links\":%lld,\"frag_attempted\":%lld,"
        "\"frag_accepted\":%lld,\"frag_obs_merged\":%lld,"
        "\"frag_reject_reproj\":%lld,\"frag_reject_theta\":%lld,"
        "\"frag_reject_min_theta\":%lld,"
        "\"frag_reject_degenerate\":%lld,\"frag_ms\":%lld,"
        "\"frag_pre_n\":%lld,\"frag_pre_2view\":%lld,\"frag_pre_lt3\":%lld,"
        "\"frag_pre_p50_deg\":%.3f,"
        "\"frag_post_n\":%lld,\"frag_post_2view\":%lld,"
        "\"frag_post_lt3\":%lld,\"frag_post_p50_deg\":%.3f,"
        // [GUIDED-TEMPORAL 2026-07-12] live guided-temporal attribution
        // (all zero unless OFFICIAL_AETHER_GUIDED_TEMPORAL=1).
        "\"guided_temporal_attempted\":%lld,"
        "\"guided_temporal_upgraded\":%lld,"
        "\"guided_temporal_extra_inliers\":%lld,"
        "\"solver_used\":\"%s\",\"sparse_backend\":\"%s\","
        "\"dense_backend\":\"%s\","
        "\"mixed\":%d,\"threads\":%d}\n",
        static_cast<long long>(epoch_ms), live_reuse ? 1 : 0,
        static_cast<long long>(cache_pre_ms),
        static_cast<long long>(enrich_ms), static_cast<long long>(stage1_ms),
        stage1_rounds, stage1_state, static_cast<long long>(stage2_ms),
        stage2_rounds_budget, static_cast<long long>(temporal_ms),
        static_cast<long long>(total_ms),
        static_cast<long long>(s->stat_finalize_rematch_starved_frames),
        static_cast<long long>(s->stat_finalize_rematch_candidates),
        static_cast<long long>(s->stat_finalize_rematch_attempted),
        static_cast<long long>(s->stat_finalize_rematch_written),
        static_cast<long long>(s->stat_finalize_rematch_inliers),
        static_cast<long long>(s->stat_finalize_rematch_failed),
        kFinalizeRematchMaxPairs,
        static_cast<long long>(s->stat_repay_calls),
        static_cast<long long>(s->stat_repay_attempted),
        static_cast<long long>(s->stat_repay_written),
        static_cast<long long>(s->stat_repay_inliers),
        static_cast<long long>(s->stat_repay_failed),
        static_cast<long long>(s->stat_repay_skipped_thermal),
        static_cast<long long>(s->stat_idle_prepay_ticks),
        static_cast<long long>(s->stat_probe_attempted),
        static_cast<long long>(s->stat_probe_skipped),
        static_cast<long long>(s->stat_probe_passed),
        static_cast<long long>(s->stat_probe_fail_open),
        static_cast<long long>(s->stat_probe_ms),
        static_cast<long long>(s->stat_gpu_retry_attempts),
        static_cast<long long>(s->stat_gpu_retry_recovered),
        static_cast<int>(EnrichBudgetModeOf()),
        static_cast<long long>(s->stat_enrich_budget_stopped),
        static_cast<long long>(s->stat_td_grow_refit_attempted),
        static_cast<long long>(s->stat_td_grow_refit_accepted),
        static_cast<long long>(s->stat_td_grow_refit_saved),
        static_cast<long long>(s->stat_td_grow_refit_min_theta_rej),
        static_cast<long long>(s->stat_upgrade_eligible),
        static_cast<long long>(s->stat_upgrade_attempted),
        static_cast<long long>(s->stat_upgrade_accepted),
        static_cast<long long>(s->stat_upgrade_obs_added),
        static_cast<long long>(s->upgrade_ms),
        static_cast<long long>(s->stat_upgrade_pre_npts),
        static_cast<long long>(s->stat_upgrade_pre_2view),
        static_cast<long long>(s->stat_upgrade_pre_lt3),
        s->upgrade_theta_p50_pre_deg,
        static_cast<long long>(s->stat_upgrade_post_npts),
        static_cast<long long>(s->stat_upgrade_post_2view),
        static_cast<long long>(s->stat_upgrade_post_lt3),
        s->upgrade_theta_p50_post_deg,
        static_cast<long long>(s->stat_enrich_targeted_tracks),
        static_cast<long long>(s->stat_enrich_targeted_scored),
        static_cast<long long>(s->stat_frag_links),
        static_cast<long long>(s->stat_frag_attempted),
        static_cast<long long>(s->stat_frag_accepted),
        static_cast<long long>(s->stat_frag_obs_merged),
        static_cast<long long>(s->stat_frag_reject_reproj),
        static_cast<long long>(s->stat_frag_reject_theta),
        static_cast<long long>(s->stat_frag_reject_min_theta),
        static_cast<long long>(s->stat_frag_reject_degenerate),
        static_cast<long long>(s->frag_ms),
        static_cast<long long>(s->stat_frag_pre_npts),
        static_cast<long long>(s->stat_frag_pre_2view),
        static_cast<long long>(s->stat_frag_pre_lt3),
        s->frag_theta_p50_pre_deg,
        static_cast<long long>(s->stat_frag_post_npts),
        static_cast<long long>(s->stat_frag_post_2view),
        static_cast<long long>(s->stat_frag_post_lt3),
        s->frag_theta_p50_post_deg,
        static_cast<long long>(s->stat_guided_temporal_attempted),
        static_cast<long long>(s->stat_guided_temporal_upgraded),
        static_cast<long long>(s->stat_guided_temporal_extra_inliers),
        solver_used.c_str(), sparse_backend.c_str(), dense_backend.c_str(),
        mixed, threads);
    if (n <= 0 || n >= static_cast<int>(sizeof(buf))) return;
    FILE* f = std::fopen(tmp.string().c_str(), "w");
    if (!f) return;
    const size_t written = std::fwrite(buf, 1, static_cast<size_t>(n), f);
    std::fclose(f);
    if (written != static_cast<size_t>(n)) {
      std::remove(tmp.string().c_str());
      return;
    }
    std::error_code ec;
    std::filesystem::rename(tmp, dst, ec);  // atomic on the same volume
    if (ec) std::remove(tmp.string().c_str());
  } catch (...) {
    // Telemetry only — never take the finalize down.
  }
}

// [GHOST-MASK 2026-07-12] Env-gated (OFFICIAL_AETHER_GHOST_MASK=1, default OFF) ghost
// layer display-mask sidecar. Runs the aether_ghost_mask.h pass (Phase0
// D band @1.5cm + per-cell bimodal detector, parity-gated bit-identical to the
// Python reference on the cap46/47 device clouds) over the finalize model and
// writes per-point flag bytes to <db_dir>/ghost_mask.bin plus a stats JSON to
// <db_dir>/ghost_mask.json. DISPLAY-ONLY metadata for the selection-view
// render gate (L2) and the L1 CasDiffMVS arbitration: NO point is deleted or
// moved, the delivered PLY/db stay byte-identical (全量交付铁律).
//  - flag order == Points3D() iteration order == aether_sfm_get_points /
//    get_points_tracked enumeration (the map is not mutated after REFINED, so
//    a later getter sees the same order; the Dart PLY writer preserves it).
//  - coordinates are float32-cast first (the delivered-PLY quantization) so
//    the flags match what PLY-based tooling recomputes bit-for-bit.
//  - best-effort: failures are logged and swallowed; never blocks finalize.
// [L1-PLAN 2026-07-12] Alongside the mask sidecar, write the CasDiffMVS L1
// arbitration inputs into the run_dir: arbitration_plan.json (Swift runner /
// Mac harness), arbitration_plan.bin (C++ arbitration twin) and
// arbitration_points.bin (per in-region point sd/local_off). "按面积挑" ref
// scheduling: budgeted greedy set-cover over the band15-marked cells (env
// OFFICIAL_AETHER_L1_BUDGET_MS / 960ms-per-ref), sources via covis_select, dv from the
// ref's own observed sparse depths — see aether_l1_plan.h. Best-effort like
// the mask itself: failures are logged and swallowed.
void WriteL1PlanSidecars(aether_sfm_session* s,
                         const colmap::Reconstruction& recon,
                         const std::vector<double>& cloud_xyz,
                         const std::vector<uint8_t>& flags,
                         const aether_ghost::GhostMaskStats& st,
                         const aether_ghost::GhostMaskIntermediates& inter) {
  const double t0 = NowMs();
  const std::filesystem::path dir =
      std::filesystem::path(s->db_path).parent_path();
  // frameId -> saved color JPEG (Dart facade sidecar, one JSON line per fed
  // frame). Hand-rolled field scan — the file is produced by our own
  // _persistFedMeta with plain container paths (no escapes beyond \/).
  std::unordered_map<int, std::string> jpeg_of;
  {
    std::ifstream jf(dir / "official_sfm_fed_frames.jsonl");
    std::string line;
    while (std::getline(jf, line)) {
      const size_t fpos = line.find("\"frameId\":");
      const size_t jpos = line.find("\"jpegPath\":\"");
      if (fpos == std::string::npos || jpos == std::string::npos) continue;
      const int fid = std::atoi(line.c_str() + fpos + 10);
      std::string path;
      for (size_t i = jpos + 12; i < line.size() && line[i] != '"'; ++i) {
        if (line[i] == '\\' && i + 1 < line.size()) ++i;  // \/ or \" escapes
        path.push_back(line[i]);
      }
      if (fid >= 0 && !path.empty()) jpeg_of[fid] = std::move(path);
    }
  }
  if (jpeg_of.empty()) {
    LOG(WARNING) << "[aether_sfm] l1_plan: official_sfm_fed_frames.jsonl missing/empty "
                    "— no JPEG mapping, plan skipped";
    return;
  }
  // registered frames -> L1Frame (pose, model-res K, jpeg), ordered by
  // frame_id for determinism.
  std::vector<aether_l1::L1Frame> frames;
  std::unordered_map<colmap::image_t, int> frame_of_image;
  {
    std::vector<const colmap::Image*> imgs;
    for (const auto& [iid, image] : recon.Images()) {
      if (image.HasPose()) imgs.push_back(&image);
    }
    std::sort(imgs.begin(), imgs.end(),
              [](const colmap::Image* a, const colmap::Image* b) {
                return a->ImageId() < b->ImageId();
              });
    for (const colmap::Image* image : imgs) {
      int fid = -1;
      if (std::sscanf(image->Name().c_str(), "frame_%d.jpg", &fid) != 1) {
        continue;
      }
      aether_l1::L1Frame fr;
      fr.frame_id = fid;
      const auto jit = jpeg_of.find(fid);
      if (jit != jpeg_of.end()) fr.jpeg = jit->second;
      const Eigen::Matrix3x4d m = image->CamFromWorld().ToMatrix();
      for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 4; ++c) fr.w2c[r * 4 + c] = m(r, c);
      fr.w2c[15] = 1.0;
      const colmap::Camera& cam = *image->CameraPtr();
      const double sx = static_cast<double>(aether_l1::kProcW) /
                        static_cast<double>(cam.width);
      const double sy = static_cast<double>(aether_l1::kProcH) /
                        static_cast<double>(cam.height);
      fr.k[0] = cam.FocalLengthX() * sx;
      fr.k[1] = cam.FocalLengthY() * sy;
      fr.k[2] = cam.PrincipalPointX() * sx;
      fr.k[3] = cam.PrincipalPointY() * sy;
      frame_of_image[image->ImageId()] = static_cast<int>(frames.size());
      frames.push_back(std::move(fr));
    }
  }
  // per-frame observed point rows + the full-precision track points, in the
  // SAME Points3D iteration order the flags were computed from.
  std::vector<double> pts;
  pts.reserve(cloud_xyz.size());
  {
    int32_t row = 0;
    for (const auto& [pid, pt] : recon.Points3D()) {
      pts.push_back(pt.xyz.x());
      pts.push_back(pt.xyz.y());
      pts.push_back(pt.xyz.z());
      for (const auto& el : pt.track.Elements()) {
        const auto it = frame_of_image.find(el.image_id);
        if (it != frame_of_image.end())
          frames[static_cast<size_t>(it->second)].obs.push_back(row);
      }
      ++row;
    }
  }
  int budget_ms = aether_l1::kDefaultBudgetMs;
  if (const char* b = std::getenv("OFFICIAL_AETHER_L1_BUDGET_MS")) {
    const int v = std::atoi(b);
    if (v > 0) budget_ms = v;
  }
  aether_l1::L1Plan plan;
  if (!aether_l1::BuildL1Plan(cloud_xyz.data(), flags.data(),
                              cloud_xyz.size() / 3, st.plane_n, st.plane_d,
                              pts.data(), pts.size() / 3, frames, budget_ms,
                              &plan)) {
    LOG(WARNING) << "[aether_sfm] l1_plan: BuildL1Plan failed";
    return;
  }
  if (plan.refs.empty()) {
    // No marked cells / no eligible refs: leave no stale plan behind.
    std::error_code ec;
    std::filesystem::remove(dir / "arbitration_plan.json", ec);
    std::filesystem::remove(dir / "arbitration_plan.bin", ec);
    std::filesystem::remove(dir / "arbitration_points.bin", ec);
    LOG(WARNING) << "[aether_sfm] l1_plan: no refs (marked_cells="
                 << plan.n_marked_cells << ") — plan not written";
    return;
  }
  const bool ok =
      aether_l1::WriteL1PlanJson((dir / "arbitration_plan.json").string(),
                                 plan, frames) &&
      aether_l1::WriteL1PlanBin((dir / "arbitration_plan.bin").string(), plan,
                                frames) &&
      aether_l1::WriteL1PointsSidecar(
          (dir / "arbitration_points.bin").string(), cloud_xyz.data(),
          flags.data(), cloud_xyz.size() / 3, inter.sd, inter.local_off);
  LOG(WARNING) << "[aether_sfm] l1_plan: refs=" << plan.refs.size() << "/"
               << plan.budget_refs << " marked_cells=" << plan.n_marked_cells
               << " cov2=" << plan.n_cells_cov2
               << " cov1=" << plan.n_cells_cov1
               << " cov0=" << plan.n_cells_cov0
               << " dropped_srcs=" << plan.n_refs_dropped_srcs
               << " missing_jpeg=" << plan.n_frames_missing_jpeg
               << " write=" << (ok ? "ok" : "FAILED") << " ("
               << static_cast<int>(NowMs() - t0) << "ms)";
}

void MaybeWriteGhostMask(aether_sfm_session* s,
                         const colmap::Reconstruction& recon) {
  const char* e = std::getenv("OFFICIAL_AETHER_GHOST_MASK");
  if (!e || e[0] != '1') return;
  try {
    const double t0 = NowMs();
    const auto& pts = recon.Points3D();
    std::vector<double> xyz;
    xyz.reserve(pts.size() * 3);
    for (const auto& [pid, pt] : pts) {
      xyz.push_back(static_cast<double>(static_cast<float>(pt.xyz.x())));
      xyz.push_back(static_cast<double>(static_cast<float>(pt.xyz.y())));
      xyz.push_back(static_cast<double>(static_cast<float>(pt.xyz.z())));
    }
    std::vector<uint8_t> flags;
    aether_ghost::GhostMaskStats st;
    aether_ghost::GhostMaskIntermediates inter;
    if (!aether_ghost::ComputeGhostMask(xyz.data(), xyz.size() / 3, &flags,
                                        &st, &inter)) {
      LOG(WARNING) << "[aether_sfm] ghost_mask: degenerate cloud ("
                   << xyz.size() / 3 << " pts) — no sidecar";
      return;
    }
    const std::filesystem::path dir =
        std::filesystem::path(s->db_path).parent_path();
    {
      const std::filesystem::path tmp = dir / "ghost_mask.bin.tmp";
      FILE* f = std::fopen(tmp.string().c_str(), "wb");
      if (!f) return;
      const size_t w = std::fwrite(flags.data(), 1, flags.size(), f);
      std::fclose(f);
      if (w != flags.size()) {
        std::remove(tmp.string().c_str());
        return;
      }
      std::error_code ec;
      std::filesystem::rename(tmp, dir / "ghost_mask.bin", ec);
      if (ec) {
        std::remove(tmp.string().c_str());
        return;
      }
    }
    char buf[768];
    const int n = std::snprintf(
        buf, sizeof(buf),
        "{\"version\":1,\"n_points\":%lld,\"n_region\":%lld,"
        "\"n_band15\":%lld,\"n_band10\":%lld,\"n_cell_ghost\":%lld,"
        "\"n_clean\":%lld,\"n_bim_cells\":%lld,\"n_floor_cells\":%lld,"
        "\"plane_n\":[%.17g,%.17g,%.17g],\"plane_d\":%.17g,"
        "\"pass_ms\":%lld,"
        "\"bits\":\"0:in_region,1:band15,2:cell_ghost,3:in_clean,"
        "4:band10\",\"order\":\"points3d_iteration==get_points\"}\n",
        static_cast<long long>(st.n_points),
        static_cast<long long>(st.n_region),
        static_cast<long long>(st.n_band15),
        static_cast<long long>(st.n_band10),
        static_cast<long long>(st.n_cell_ghost),
        static_cast<long long>(st.n_clean),
        static_cast<long long>(st.n_bim_cells),
        static_cast<long long>(st.n_floor_cells), st.plane_n[0], st.plane_n[1],
        st.plane_n[2], st.plane_d, static_cast<long long>(NowMs() - t0));
    if (n > 0 && n < static_cast<int>(sizeof(buf))) {
      const std::filesystem::path tmp = dir / "ghost_mask.json.tmp";
      FILE* f = std::fopen(tmp.string().c_str(), "w");
      if (f) {
        const size_t w = std::fwrite(buf, 1, static_cast<size_t>(n), f);
        std::fclose(f);
        std::error_code ec;
        if (w == static_cast<size_t>(n)) {
          std::filesystem::rename(tmp, dir / "ghost_mask.json", ec);
        }
        if (w != static_cast<size_t>(n) || ec)
          std::remove(tmp.string().c_str());
      }
    }
    LOG(WARNING) << "[aether_sfm] ghost_mask: n=" << st.n_points
                 << " region=" << st.n_region << " band15=" << st.n_band15
                 << " cell_ghost=" << st.n_cell_ghost
                 << " bim_cells=" << st.n_bim_cells << "/"
                 << st.n_floor_cells << " (" << static_cast<int>(NowMs() - t0)
                 << "ms)";
    // [L1-PLAN 2026-07-12] CasDiffMVS arbitration inputs (same env gate; the
    // enclosing try swallows any failure so finalize is never blocked).
    WriteL1PlanSidecars(s, recon, xyz, flags, st, inter);
  } catch (const std::exception& ex) {
    LOG(WARNING) << "[aether_sfm] ghost_mask failed (swallowed): "
                 << ex.what();
  } catch (...) {
    LOG(WARNING) << "[aether_sfm] ghost_mask failed (swallowed)";
  }
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
// ±2%, reproj ±0.02); OFFICIAL_AETHER_FINALIZE_NO_OVERLAP=1 is the same-binary revert
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
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] finalize worker 入口打点
    // [AETHER FINALIZE-SEGMENTS 2026-07-11] Drop any segments file from a
    // previous finalize of this run_dir (resume retries) so the Dart reader
    // can never pick up a stale record if this attempt ends in the fallback.
    try {
      std::filesystem::remove(std::filesystem::path(s->db_path).parent_path() /
                              "official_finalize_segments.json");
    } catch (...) {
    }
    auto popts = MakePhase2Options(s);
    // [INCREMENTAL-GLOBAL-BA 2026-07-13] If the rolling capture-time global BA
    // ran this session, live_recon's poses are already near the global optimum, so
    // the finalize global solve COLLAPSES: cap the round budget (default 2 — the
    // "1-2 轮收尾"). Both stage 1 and stage 2 still run CompleteAndMergeTracks +
    // Retriangulate every round, so the ≥1-track-completion requirement holds and
    // the finalize free-gauge solve still closes revisit pairs that only appear in
    // the enrichment (which the capture-time sliding window could not — see
    // MaybeIncrementalGlobalRefine's quality note). The converge-stop usually
    // breaks after round 1 anyway; this cap is the belt-and-suspenders lever the
    // cap51 A/B sweeps (OFFICIAL_AETHER_INCREMENTAL_FINALIZE_ROUNDS). Default OFF is
    // preserved: incremental_global_ba_ran is only set when the env-gated trigger
    // actually fired, so shipped captures are byte-for-byte unchanged.
    if (s->incremental_global_ba_ran) {
      const int cap = std::max(1, IncrementalFinalizeRounds());
      const int before = popts->ba_global_max_refinements;
      popts->ba_global_max_refinements = std::min(before, cap);
      LOG(WARNING) << "[aether_sfm] finalize collapse: incremental global BA ran ("
                   << s->stat_incremental_refines << " refines) → global-BA rounds "
                   << before << " → " << popts->ba_global_max_refinements;
    }
    std::shared_ptr<colmap::Reconstruction> refined;
    double enrich_ms = 0.0, cache_pre_ms = 0.0, stage1_ms = 0.0;
    int stage1_rounds = 0;
    const char* stage1_state = "off";
    // [PROVENANCE 2026-07-26] Diagnostic only — no geometry is touched.
    // The delivered cloud inherits the live model (Reconstruction::Load never
    // touches points3D_), so every point the hand-written live create/grow/
    // merge admitted under its 10 px / 14 px / 8 px / 2.0 deg gates survives
    // into the PLY unless official filtering drops it. Point3D ids are stable
    // and monotonically assigned, so the id set at this instant IS the
    // self-developed origin set; anything the official Retriangulate /
    // CompleteAndMergeTracks adds afterwards carries a fresh id. Counting the
    // two groups at publish time answers the question that decides whether
    // swapping the live triangulator for colmap's is worth anything at all.
    std::unordered_set<colmap::point3D_t> live_origin_ids;
    if (live_reuse && model) {
      live_origin_ids.reserve(model->NumPoints3D() * 2);
      for (const auto& [pid, _] : model->Points3D()) live_origin_ids.insert(pid);
    }
    if (live_reuse) {
      refined = std::move(model);  // in place — nothing else holds this model
      // [KNIFE-A ③ 2026-07-11] Snapshot the enrichment-targeting hint from
      // the (still-untouched) live model BEFORE the enrichment thread spawns
      // and before stage 1 starts mutating `refined` — the enrichment thread
      // must never read the model itself. Env-gated; nullptr = legacy
      // distance ordering in the top-up.
      if (EnrichTargetedEnabled() && s->frames.size() >= 3) {
        try {
          s->enrich_hint = BuildEnrichTargetHint(*s, *refined);
        } catch (...) {
          s->enrich_hint.reset();
        }
      }
      // Kill switch: OFFICIAL_AETHER_FINALIZE_NO_OVERLAP=1 restores the serial order
      // (enrichment first, then one full refinement over the enriched db).
      static const bool no_overlap = [] {
        const char* e = std::getenv("OFFICIAL_AETHER_FINALIZE_NO_OVERLAP");
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
      // [P1-ENRICH-BUDGET] Arm the time gate for this run: AUTO arms only
      // when a stage-1 window exists (cache_pre); FIXED always. Armed runs
      // pay the most valuable debt first (starved-frame re-match before the
      // spatial pass); unarmed runs keep the legacy order bit-identically.
      const bool budget_armed = EnrichBudgetArmed(cache_pre != nullptr);
      s->enrich_stage1_done.store(false, std::memory_order_relaxed);
      s->enrich_start_ms = 0.0;
      const double t_enrich0 = NowMs();
      std::thread enrich([s, &enrich_ms, &enrich_done, t_enrich0,
                          budget_armed] {
#if defined(__APPLE__)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
        s->enrich_start_ms = NowMs();
        try {
          // [ENRICH-ORDER 2026-07-26, signed] Armed (budgeted) runs pay the
          // MOST VALUABLE debt first. cap_1785066707194992 (156 frames, 115
          // thermal-serious) proved the old "quadratic first, unbudgeted"
          // order inverts that: the quadratic pass spent the whole 30s kAuto
          // budget on long-range pairs (gap-128 pairs averaged 0.7 inliers)
          // and FinalizeRematchStarvedFrames — whose near-field pairs average
          // ~190-270 inliers and are the other half of the K6 throttle's
          // "delivery-lossless" promise — was budget-stopped at zero, leaving
          // ~100 throttled frames without gaps 7-12 (551 pts/frame delivered).
          // Armed order is therefore rematch → quadratic (now budget-gated,
          // gap-ascending) → spatial. Unarmed runs keep the legacy order
          // bit-identically.
          // [GPU-HANG-B1] enrichment(GPU matcher)各 pass 边界打点。
          if (budget_armed) {
            s->gpu_watchdog.InProgress();
            FinalizeRematchStarvedFrames(s);
            s->gpu_watchdog.InProgress();
            AddOfficialQuadraticPairs(s);
            s->gpu_watchdog.InProgress();
            AddSpatialRevisitMatches(s);
            s->gpu_watchdog.InProgress();
          } else {
            s->gpu_watchdog.InProgress();
            AddOfficialQuadraticPairs(s);
            s->gpu_watchdog.InProgress();
            AddSpatialRevisitMatches(s);
            s->gpu_watchdog.InProgress();
            FinalizeRematchStarvedFrames(s);
            s->gpu_watchdog.InProgress();
          }
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
        // [BA-STAGE1-FULL 2026-07-26, signed] That premise inverted (see
        // Stage1UtilityQosLegacy) — stage-1 now stays USER_INITIATED unless
        // the legacy env restores the cap43 posture.
        if (Stage1UtilityQosLegacy()) {
          pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        }
#endif
        aether_ba_ring_reset();  // [AETHER BA-RING] attribute stage-1 solves
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
          // budget (min(6, hw-2) / OFFICIAL_AETHER_BA_THREADS) instead of raw
          // hardware_concurrency: overlap window = budget/2, exclusive
          // stage 2 = full budget.
          if (ba_opts.ceres) {
            const int full =
                ba_opts.ceres->solver_options.num_threads > 0
                    ? ba_opts.ceres->solver_options.num_threads
                    : static_cast<int>(std::thread::hardware_concurrency());
            // [BA-STAGE1-FULL 2026-07-26, signed] Full threads by default —
            // thread count is signed bit-equal (Ceres 两刀定案), and cap5
            // measured the halved rounds at 22.4s vs 10.8s full speed while
            // the enrichment they were protecting had 11s of slack. Legacy
            // halving one env away for the heavy-revisit shape.
            ba_opts.ceres->solver_options.num_threads =
                Stage1HalfThreadsLegacy() ? std::max(1, full / 2) : full;
            // [P1-STAGE1-RECIPE] optional stage-1-only ftol override (stage 2
            // keeps the shipped ba_global_function_tolerance untouched).
            if (Stage1FtolOverride() > 0.0) {
              ba_opts.ceres->solver_options.function_tolerance =
                  Stage1FtolOverride();
            }
          }
          // Window checks between the sub-steps too: a healthy capture whose
          // enrichment finishes in seconds must not pay for a full merge +
          // retriangulate pass it gains nothing from (stage 2 redoes both on
          // the enriched graph).
          if (!enrich_done.load()) mapper.CompleteAndMergeTracks(tri_opts);
          if (!enrich_done.load()) mapper.Retriangulate(tri_opts);
          // [P1-STAGE1-RECIPE] optional round cap: ends stage 1 — and, via
          // the AUTO enrich gate keyed on enrich_stage1_done, the enrichment
          // window — after N rounds. The stage-2 remainder formula below
          // hands the unused rounds back to stage 2 unchanged.
          const int s1_rounds_max =
              Stage1RoundsCap() > 0
                  ? std::min(popts->ba_global_max_refinements,
                             Stage1RoundsCap())
                  : popts->ba_global_max_refinements;
          for (int i = 0; i < s1_rounds_max; ++i) {
            if (enrich_done.load()) break;  // window closed
            s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] stage-1 逐轮打点
            const size_t num_obs = refined->ComputeNumObservations();
            // [AETHER-T1] stage-1 per-part attribution (our own loop).
            const double t_s1ba = NowMs();
            mapper.AdjustGlobalBundle(mapper_opts, ba_opts);
            s->t1_stage1_ba_ms += NowMs() - t_s1ba;
            const double t_s1mg = NowMs();
            size_t num_changed = mapper.CompleteAndMergeTracks(tri_opts);
            num_changed += mapper.FilterPoints(mapper_opts);
            s->t1_stage1_merge_ms += NowMs() - t_s1mg;
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
        s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] stage-1 结束打点
        AppendBaRingJsonl(s, 1);  // [AETHER BA-RING] stage-1 per-solve drain
        // [P1-ENRICH-BUDGET] AUTO-mode window signal: stage 1 is over, so any
        // further enrichment wall time is pure critical path. The enrichment
        // thread stops STARTING new matcher attempts once it sees this (past
        // the healthy-capture floor); its in-flight pair still completes.
        s->enrich_stage1_done.store(true, std::memory_order_relaxed);
        cache_pre.reset();  // free the snapshot before stage 2 loads its own
#if defined(__APPLE__)
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
      }
      // [AETHER-T1] Time the join: with the quadratic prepaid this should be
      // ~0; anything left is enrichment blocking the critical path.
      const double t_join = NowMs();
      enrich.join();
      s->t1_enrich_gate_wait_ms = NowMs() - t_join;
      s->enrich_hint.reset();  // [KNIFE-A ③] snapshot no longer needed
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
    // [AETHER-T1] Attribute stage-2's interior via the vendored-mapper hooks.
    aether_igr_pre_ms = 0.0;
    aether_igr_ba_ms = 0.0;
    aether_igr_merge_ms = 0.0;
    aether_igr_rounds = 0;
    aether_ba_ring_reset();  // [AETHER BA-RING] attribute stage-2 solves
    auto manager = std::make_shared<colmap::ReconstructionManager>();
    colmap::IncrementalPipeline pipeline(
        popts, colmap::Database::Open(s->db_path), manager);
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] stage-2 入口打点
    pipeline.RefineReconstruction(refined);
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] stage-2 结束打点
    const double stage2_ms = NowMs() - t_s2;
    // [AETHER-T1] Pullable split record — the p1_done→refined stretch used to
    // be a 78s zero-log black box (56% of the total wait).
    {
      char sline[320];
      std::snprintf(
          sline, sizeof(sline),
          "{\"t\":%lld,\"type\":\"finalize_split\",\"stage1_ba_ms\":%.0f,"
          "\"stage1_merge_ms\":%.0f,\"enrich_gate_wait_ms\":%.0f,"
          "\"s2_pre_ms\":%.0f,\"s2_ba_ms\":%.0f,\"s2_merge_ms\":%.0f,"
          "\"s2_rounds\":%d,\"s2_other_ms\":%.0f}",
          static_cast<long long>(EpochMs()), s->t1_stage1_ba_ms,
          s->t1_stage1_merge_ms, s->t1_enrich_gate_wait_ms, aether_igr_pre_ms,
          aether_igr_ba_ms, aether_igr_merge_ms, aether_igr_rounds,
          stage2_ms - aether_igr_pre_ms - aether_igr_ba_ms -
              aether_igr_merge_ms);
      AppendMatchFailJsonl(s, sline);
    }
    AppendBaRingJsonl(s, 2);  // [AETHER BA-RING] stage-2 per-solve drain
    // [A1B-ASYNC-PVBA] experiment-arm accounting (absent when off/idle).
    if (s->stat_apvba_kicks > 0) {
      char aline[512];
      std::snprintf(aline, sizeof(aline),
                    "{\"t\":%lld,\"type\":\"apvba_summary\","
                    "\"kicks\":%lld,\"merges\":%lld,\"dropped\":%lld,"
                    "\"last_ba_ms\":%.0f,\"merge_ms_total\":%.0f,"
                    "\"copy_ms_total\":%.0f,\"corr_mm\":%.2f,"
                    "\"corr_deg\":%.3f,\"propagate\":%d,\"match_cadence\":%d,"
                    "\"param_only\":%d,\"last_error\":\"%s\"}",
                    static_cast<long long>(EpochMs()),
                    (long long)s->stat_apvba_kicks,
                    (long long)s->stat_apvba_merges,
                    (long long)s->stat_apvba_dropped,
                    s->stat_apvba_last_ba_ms, s->stat_apvba_merge_ms_total,
                    s->stat_apvba_copy_ms_total, s->stat_apvba_last_corr_mm,
                    s->stat_apvba_last_corr_deg,
                    AsyncPreviewBaPropagate() ? 1 : 0,
                    AsyncPreviewBaMatchCadence() ? 1 : 0,
                    AsyncPreviewBaParamOnly() ? 1 : 0,
                    JsonSafe(s->apvba_last_error.c_str(), 96).c_str());
      AppendMatchFailJsonl(s, aline);
    }
    const double t_td = NowMs();
    RestoreTemporalDetail(s, refined.get());
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] temporal-detail 结束打点
    const double temporal_ms = NowMs() - t_td;
    // [KNIFE-A ② 2026-07-11] Finalize-tail 2-view upgrade over the delivered
    // model (env-gated no-op by default; sets s->upgrade_ms + stat_upgrade_*).
    UpgradeLowParallaxTracks(s, refined.get());
    // [P2-FRAG-MERGE 2026-07-11] Finalize-tail duplicate-fragment merge
    // (env-gated no-op by default; sets s->frag_ms + stat_frag_*).
    MergeFragmentTracks(s, refined.get());
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] finalize 尾部 pass 结束打点
    // [GHOST-MASK 2026-07-12] Display-mask sidecar over the delivered model
    // (env-gated no-op by default; runs AFTER every pass that can move/merge
    // points so the flags describe exactly what the getters will serve).
    MaybeWriteGhostMask(s, *refined);
    LOG(WARNING) << "[aether_sfm] finalize worker: cache_pre="
                 << static_cast<int64_t>(cache_pre_ms)
                 << "ms enrich=" << static_cast<int64_t>(enrich_ms)
                 << "ms stage1=" << static_cast<int64_t>(stage1_ms) << "ms ("
                 << stage1_state << ", rounds=" << stage1_rounds
                 << ") stage2=" << static_cast<int64_t>(stage2_ms)
                 << "ms (rounds<=" << popts->ba_global_max_refinements
                 << ") temporal=" << static_cast<int64_t>(temporal_ms)
                 << "ms upgrade=" << static_cast<int64_t>(s->upgrade_ms)
                 << "ms total=" << static_cast<int64_t>(NowMs() - t0) << "ms";
    // [AETHER FINALIZE-SEGMENTS 2026-07-11] Same numbers into the persistent
    // run_dir JSON (stderr double-write stays above) — BEFORE the status flips
    // to REFINED so the Dart forwarder always sees a complete file.
    WriteFinalizeSegments(s, live_reuse, cache_pre_ms, enrich_ms, stage1_ms,
                          stage1_rounds, stage1_state, stage2_ms,
                          popts->ba_global_max_refinements, temporal_ms,
                          NowMs() - t0);
    // [PROVENANCE 2026-07-26] Split the delivered points by origin. Purely a
    // measurement: it decides whether the hand-written live triangulator is
    // actually authoring the delivered cloud or whether official
    // Retriangulate has already replaced most of it.
    if (live_reuse && refined) {
      int64_t from_live = 0, from_official = 0;
      for (const auto& [pid, _] : refined->Points3D()) {
        if (live_origin_ids.count(pid)) ++from_live;
        else ++from_official;
      }
      const int64_t live_dropped =
          static_cast<int64_t>(live_origin_ids.size()) - from_live;
      LOG(WARNING) << "[aether_sfm] delivered-point provenance: live-created="
                   << from_live << " official-retriangulated=" << from_official
                   << " live-dropped-by-official-filtering=" << live_dropped
                   << " (live model had " << live_origin_ids.size()
                   << "; capture-time official TriangulateImage added "
                   << s->stat_official_tri_added << " obs)";
      char pline[256];
      std::snprintf(pline, sizeof(pline),
                    "{\"t\":%lld,\"type\":\"point_provenance\",\"live\":%lld,"
                    "\"official\":%lld,\"live_dropped\":%lld,\"live_total\":%zu}",
                    static_cast<long long>(EpochMs()), (long long)from_live,
                    (long long)from_official, (long long)live_dropped,
                    live_origin_ids.size());
      AppendMatchFailJsonl(s, pline);
    }
    {
      std::lock_guard<std::mutex> lk(s->recon_mutex);
      s->recon = refined;
      s->refine_ms = NowMs() - t0;
    }
    s->finalize_status.store(2);  // AETHER_SFM_FINALIZE_REFINED
  } catch (const std::exception& e) {
    RefineFailClosed(s, e.what());
  } catch (...) {
    RefineFailClosed(s, "unknown exception");
  }
}

}  // namespace

extern "C" {

void aether_sfm_options_default(aether_sfm_options_t* out) {
  if (!out) return;
  out->max_features = 2048;
  out->image_width = 0;
  out->image_height = 0;
  out->match_max_ratio = 0.8f;
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
  // Batch/reference inputs do not carry the mandatory per-frame ARKit gravity
  // contract. Never let a previous streaming session's registry leak into a
  // batch solve in the same process.
  aether_ba_clear_gravity_priors();
  const aether_sfm_result_t rc = RunIncremental(
      db_path, image_path, opts, &manager, &recon, out_json, out_cap);
  if (rc != AETHER_SFM_OK) return rc;

  if (out_session) {
    auto* s = new aether_sfm_session();
    aether_preclamp_instr_v1::ResetOfficialSessionRecords(s);
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
    if (DescriptorResidencyEnabledCore()) {
      s->descriptor_residency_nonce = NewDescriptorResidencySessionNonce();
    }
#endif
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
    aether_ba_clear_gravity_priors();
    auto* s = new aether_sfm_session();
    aether_preclamp_instr_v1::ResetOfficialSessionRecords(s);
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
    if (DescriptorResidencyEnabledCore()) {
      s->descriptor_residency_nonce = NewDescriptorResidencySessionNonce();
    }
#endif
    s->gpu_timestamp_run_id = NewGpuTimestampRunId();
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
    TailCacheInitialize(s);
    // [AETHER-T3 2026-07-26] Build stamp into the pullable sidecar: twice in
    // one day a capture was analysed against code that was written AFTER it
    // ("代码态被当成真机态" — cap3/cap4 both needed after-the-fact forensics
    // to notice). One line per session pins which binary produced the run.
    {
      char bline[160];
      std::snprintf(bline, sizeof(bline),
                    "{\"t\":%lld,\"type\":\"build_stamp\","
                    "\"built\":\"%s %s\"}",
                    static_cast<long long>(EpochMs()), __DATE__, __TIME__);
      AppendMatchFailJsonl(s, bline);
    }
    // [GPU-HANG-B1] 启动巡逻线程。回调只读 s->db_path(create 后不变),
    // AppendMatchFailJsonl 本身 open-append-close、异常自吞,巡逻线程安全。
    // s 的生命期由 aether_sfm_free 先 Stop() 后 delete 保证。
    s->gpu_watchdog.Start([s](const std::string& line) {
      AppendMatchFailJsonl(s, line);
    });
    *out_session = s;
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    return AETHER_SFM_ERR_DB;
  }
}

// [INCREMENTAL-GLOBAL-BA 2026-07-13] Rolling capture-time global BA over
// live_recon. DEFAULT OFF (OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1). Called from the tail
// of AddFrameFeaturesImpl on the capture-worker isolate — the SAME thread that
// owns live_recon — so it takes no lock (mirrors aether_sfm_global_refine's
// threading contract). Fires only every IncrementalGlobalBaEveryN() registered
// frames; a single call must stay well under the ~2s per-frame SLA or it stalls
// the next frame and drops the capture frame-rate (the device A/B measures this).
//
// LIGHT CONFIG (deliberately weaker than the finalize solve): ONE pose-correcting
// global BA pass — no structure-only stage 2 (that is left to finalize) — CAUCHY,
// iter 10, observation-capped to the longest (revisit-spanning) tracks so cost is
// DECOUPLED from total point count. Focal/pp fixed (trust the ARKit-seeded shared
// camera), exactly like aether_sfm_global_refine stage 1.
//
// LOCAL-GLOBAL HYBRID (the bounded-cost trick): only frames registered in the
// most-recent IncrementalGlobalBaWindow() get FREE poses; every older frame is
// added as a SetConstantRigFromWorldPose ANCHOR. Fixed anchors pin the gauge (no
// FixGauge needed) AND — because a revisit-spanning long track links a fresh free
// frame to an OLD fixed frame — the solve pulls the fresh pose onto the already-
// corrected anchor, collapsing the accumulating double-wall drift a window at a
// time. Free-pose count ≈ window and points are obs-capped, so cost stays bounded
// regardless of N (frozen anchors add residuals but no parameters).
//
// ⚠️ QUALITY CONSEQUENCE — WHY THIS MUST BE HOST-VALIDATED BEFORE DEFAULT-ON:
//  (1) Freezing old poses makes this an EXPANDING SLIDING-WINDOW BA, not a full
//      free-gauge global solve. Drift baked into an anchor before it was frozen is
//      not re-optimized here; the design bet (standard incremental SLAM) is that
//      correcting drift while it is still local keeps cumulative live_recon ≈ the
//      one-shot finalize global solve. Unproven until the cap51 A/B.
//  (2) The double-wall only closes for tracks that EXIST during capture (temporal
//      + live-spatial matches). Revisit pairs that materialize only in the finalize
//      enrichment (AddSpatialRevisitMatches) never existed here, so finalize's
//      free-gauge solve + track completion remain REQUIRED (see RefineGlobalBA).
// THERMAL-GATED (safe-fail): thermal>=3 (critical) skips entirely to give the
// camera/GPU the device; thermal>=2 (serious) doubles the effective cadence. A
// cold device does the full cadence; a hot device degrades toward current behavior
// and never crashes (every failure is caught → the windowed cloud is untouched).
static void MaybeIncrementalGlobalRefine(aether_sfm_session* s) {
  if (!IncrementalGlobalBaEnabled()) return;
  if (!s || !s->live_recon_ready || !s->live_recon) return;
  const int thermal_now = s->thermal_state.load(std::memory_order_relaxed);
  if (thermal_now >= 3) return;  // critical: hand the device to camera/GPU
  const size_t n_reg = s->reg_order.size();
  if (n_reg < 3) return;
  const size_t every = static_cast<size_t>(IncrementalGlobalBaEveryN()) *
                       (thermal_now >= 2 ? 2 : 1);  // serious → half the cadence
  if (n_reg < s->last_global_refine_reg + every) return;

  const double t0 = NowMs();
  try {
    // ---- Free-pose sliding window: recent frames free, older frames frozen ----
    const size_t window = static_cast<size_t>(IncrementalGlobalBaWindow());
    const size_t free_from = n_reg > window ? n_reg - window : 0;
    colmap::BundleAdjustmentConfig cfg;
    size_t n_frozen = 0;
    for (size_t i = 0; i < n_reg; ++i) {
      const colmap::image_t img = s->reg_order[i];
      cfg.AddImage(img);
      if (i < free_from) {
        // Frozen anchor: its observations of the variable points still constrain
        // the free poses, but its own world pose does not move.
        cfg.SetConstantRigFromWorldPose(s->live_recon->Image(img).FrameId());
        ++n_frozen;
      }
    }
    if (free_from == 0)  // whole capture inside one window → pin the gauge
      cfg.FixGauge(colmap::BundleAdjustmentGauge::THREE_POINTS);
    SetAllCameraIntrinsicsConstant(*s->live_recon, s->reg_order, cfg);

    // Observation cap: rank tracks longest-first (longest = revisit-spanning) and
    // add as variable points until the budget is hit — same bound as
    // aether_sfm_global_refine, so cost is decoupled from total point count.
    const size_t kMaxObs =
        std::min<size_t>(400000, std::max<size_t>(80000, n_reg * 120));
    std::vector<std::pair<int, colmap::point3D_t>> ranked;
    ranked.reserve(s->live_recon->NumPoints3D());
    for (const auto& [pid, pt] : s->live_recon->Points3D())
      ranked.emplace_back(static_cast<int>(pt.track.Length()), pid);
    std::sort(ranked.begin(), ranked.end(),
              std::greater<std::pair<int, colmap::point3D_t>>());
    size_t obs_budget = 0;
    for (const auto& [len, pid] : ranked) {
      if (obs_budget >= kMaxObs) break;
      cfg.AddVariablePoint(pid);
      obs_budget += static_cast<size_t>(len);
    }

    colmap::BundleAdjustmentOptions opt;
    opt.refine_rig_from_world = true;    // non-anchor poses redistribute drift
    opt.refine_points3D = true;
    opt.refine_focal_length = false;     // trust each image's ARKit calibration
    opt.refine_principal_point = false;
    opt.print_summary = false;
    opt.ceres->loss_function_type =
        colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
    opt.ceres->loss_function_scale = 1.0;
    opt.ceres->solver_options.max_num_iterations = 10;  // light (vs 25 finalize)
    // Leave core headroom for the camera / GPU matcher / UI mid-capture; the exact
    // thread count is a device-A/B tuning knob (A16 → 4, host M3 Pro → 6).
    // [BA-THREADS-POST 2026-07-28] capture-period budget split off from the
    // finalize budget (which no longer reserves cores — camera is off there).
    opt.ceres->solver_options.num_threads = LiveBaThreads();
    colmap::CreateDefaultBundleAdjuster(opt, cfg, *s->live_recon)->Solve();

    s->last_global_refine_reg = n_reg;
    s->incremental_global_ba_ran = true;
    ++s->stat_incremental_refines;
    LOG(WARNING) << "[aether_sfm] incremental global BA #"
                 << s->stat_incremental_refines << " reg=" << n_reg
                 << " free=" << (n_reg - n_frozen) << " frozen=" << n_frozen
                 << " varpts_obs<=" << kMaxObs << " thermal=" << thermal_now
                 << " took=" << static_cast<int64_t>(NowMs() - t0) << "ms";
    // NOTE: no preview re-publish here — the unconditional preview snapshot right
    // after the caller's windowed-BA block already reads this refined live_recon.
  } catch (const std::exception& e) {
    // Safe-fail: keep the windowed cloud; advance the counter so a persistent
    // failure does not retry (and stall) every subsequent frame.
    s->last_global_refine_reg = n_reg;
    LOG(WARNING) << "[aether_sfm] incremental global BA skipped (" << e.what()
                 << ") — windowed cloud kept";
  }
}

// Shared core of aether_sfm_add_frame (extraction upstream) and
// aether_sfm_add_frame_features (features injected — host replay/verification
// of the streaming path from a pulled sfm_live.db). Everything from the shared
// camera write onward is identical between the two entries; extract_ms is the
// caller-measured extraction time (0 for injected features).
//
// [SCALE-PERSIST 2026-08-06] `scales` (optional, may be NULL): n per-keypoint
// detection scales from the _v2 extractor. When present, keypoints persist
// with their true scale via the official 4-parameter
// colmap::FeatureKeypoint(x, y, scale, orientation) constructor (orientation
// 0 — scale is what Projection-Accuracy-style filtering consumes); when NULL,
// the pre-change unit-affine FeatureKeypoint(x, y) write is reproduced
// byte-for-byte. Keypoint AFFINE COLUMNS ONLY: xy, descriptors, matches, TVG,
// rec.points and FrameIdentityDigestV1 (xy+desc-derived) are unaffected.
static aether_sfm_result_t AddFrameFeaturesImpl(
    aether_sfm_session_t* s, const float* xy, const uint8_t* desc,
    const float* scales, int n, int width, int height, float fx, float fy,
    float cx, float cy, const double pose_qwxyz[4], const double pose_t[3],
    double extract_ms, int* out_frame_id) {
  try {
    // Production capture is an ARKit `.gravity` route. Validate and convert
    // the required pose before the first database or reconstruction mutation;
    // missing/invalid gravity identity is not permission to create an unposed
    // frame and later fall back to P3P.
    aether::sfm::MandatoryArkitGravityPoseV1 gravity_pose;
    const aether::sfm::MandatoryArkitGravityPoseStatusV1 gravity_pose_status =
        aether::sfm::BuildMandatoryArkitGravityPoseV1(pose_qwxyz, pose_t,
                                                      &gravity_pose);
    if (gravity_pose_status !=
        aether::sfm::MandatoryArkitGravityPoseStatusV1::kOk) {
      // [VIO-TELEMETRY 2026-08-04] Deliberately distinguishable. A rejection
      // here is a pose-supply/VIO failure, which is a completely different
      // condition from the "not enough texture" outcome the capture UI reports
      // — yet before this tag the two were indistinguishable in a device log,
      // so a VIO dropout got diagnosed as a scene problem and the user was told
      // to re-shoot. The status code says which validator rejected the frame.
      LOG(WARNING) << "[aether_sfm][ARKIT-POSE-REJECT] frame rejected before "
                      "any db write, status="
                   << static_cast<int>(gravity_pose_status);
      return AETHER_SFM_ERR_INVALID_ARG;
    }

    // 2) One official COLMAP PINHOLE camera per 12 MP image, populated from
    //    the exact same high-resolution ARFrame as the JPEG. Autofocus stays
    //    enabled; per-frame calibration preserves the resulting focal change.
    if (width <= 0 || height <= 0 || !std::isfinite(fx) ||
        !std::isfinite(fy) || !std::isfinite(cx) || !std::isfinite(cy) ||
        fx <= 0.0f || fy <= 0.0f || cx < 0.0f || cy < 0.0f ||
        cx >= static_cast<float>(width) || cy >= static_cast<float>(height)) {
      return AETHER_SFM_ERR_INVALID_ARG;
    }
    colmap::Camera camera = colmap::Camera::CreateFromModelId(
        colmap::kInvalidCameraId, colmap::PinholeCameraModel::model_id,
        /*focal_length=*/fx, width, height);
    camera.SetFocalLengthX(fx);
    camera.SetFocalLengthY(fy);
    camera.SetPrincipalPointX(cx);
    camera.SetPrincipalPointY(cy);
    const colmap::camera_t camera_id = s->db->WriteCamera(camera);
    camera.camera_id = camera_id;
    if (s->camera_id == 0) s->camera_id = camera_id;
    // Each camera needs its own trivial rig before its image enters the live
    // reconstruction.
    if (s->live_recon) {
      s->live_recon->AddCameraWithTrivialRig(camera);
      s->live_recon_ready = true;
    }

    // 3) Write image + keypoints + descriptors.
    const int frame_id = static_cast<int>(s->frames.size());
    colmap::Image image;
    char name[64];
    std::snprintf(name, sizeof(name), "frame_%06d.jpg", frame_id);
    image.SetName(name);
    image.SetCameraId(camera_id);
    const colmap::image_t image_id = s->db->WriteImage(image);

    // [ORDINAL-GUARD 2026-08-04] The db row for this ordinal now exists and
    // COLMAP exposes no DeleteImage to take it back. frame_id is derived from
    // s->frames.size(), so if this call returns early OR throws before the
    // record is pushed, the NEXT frame regenerates this exact
    // "frame_%06d.jpg" and dies on the images.name UNIQUE constraint — and so
    // does every frame after it, i.e. one transient fault bricks the whole live
    // capture instead of costing a single frame.
    // REPRODUCED ON HOST 2026-08-04 (E3 replay, cap7_day): a single transient
    // "database is locked" at frame 7 killed frames 8..145 of a 146-frame
    // capture. The earlier fix covered only the pose-snapshot failure path;
    // this guard covers EVERY exit path, exceptions included.
    struct OrdinalGuardV1 {
      aether_sfm_session* session = nullptr;
      int frame_id = -1;
      colmap::image_t image_id = 0;
      colmap::camera_t camera_id = 0;
      bool committed = false;
      ~OrdinalGuardV1() {
        if (committed || session == nullptr) return;
        // Runs during stack unwinding too, so it must never throw.
        try {
          FrameRecord withdrawn;
          withdrawn.frame_id = frame_id;
          withdrawn.image_id = 0;  // withdrawn: excluded from every pair path
          withdrawn.persisted_image_id = image_id;
          withdrawn.camera_id = camera_id;
          withdrawn.n_keypoints = 0;
          session->frames.push_back(std::move(withdrawn));
          LOG(ERROR) << "[aether_sfm][ORDINAL-GUARD] frame " << frame_id
                     << " aborted after its db row was created; the ordinal is "
                        "consumed so the capture continues on the next frame";
          // Restore db/sidecar count parity that recovery checks. Best effort:
          // if this also fails, recovery stays blocked but the LIVE capture
          // survives, which is the whole point of the guard.
          (void)PersistCurrentArkitPoseSnapshot(*session);
        } catch (...) {
        }
      }
    } ordinal_guard{s, frame_id, image_id, camera_id, false};

    colmap::FeatureKeypoints kps(n);
    for (int i = 0; i < n; ++i) {
      // [SCALE-PERSIST 2026-08-06] official 4-param constructor
      // FeatureKeypoint(x, y, scale, orientation) — colmap/feature/types.cc:43
      // (it THROW_CHECKs scale >= 0, hence the finite/positive guard; a
      // non-finite extractor value degrades that keypoint to the legacy unit
      // affine instead of aborting the frame).
      if (scales != nullptr && std::isfinite(scales[i]) && scales[i] > 0.0f) {
        kps[i] =
            colmap::FeatureKeypoint(xy[2 * i], xy[2 * i + 1], scales[i], 0);
      } else {
        kps[i] = colmap::FeatureKeypoint(xy[2 * i], xy[2 * i + 1]);
      }
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
    rec.persisted_image_id = image_id;
    rec.camera_id = camera_id;
    rec.camera = camera;
    rec.n_keypoints = n;
    rec.descriptors.assign(desc, desc + static_cast<size_t>(n) * 128);
    rec.points = colmap::FeatureKeypointsToPointsVector(kps);
    rec.frame_identity_digest =
        FrameIdentityDigestV1(name, camera, rec.points, rec.descriptors);
    TailCacheMirrorImage(s, camera, image_id, name, rec.points);

    rec.cam_from_world = colmap::Rigid3d(
        Eigen::Quaterniond(gravity_pose.cam_from_world_qwxyz[0],
                           gravity_pose.cam_from_world_qwxyz[1],
                           gravity_pose.cam_from_world_qwxyz[2],
                           gravity_pose.cam_from_world_qwxyz[3]),
        Eigen::Vector3d(gravity_pose.cam_from_world_t_xyz[0],
                        gravity_pose.cam_from_world_t_xyz[1],
                        gravity_pose.cam_from_world_t_xyz[2]));
    rec.gravity_cam = Eigen::Vector3d(gravity_pose.gravity_cam_xyz[0],
                                      gravity_pose.gravity_cam_xyz[1],
                                      gravity_pose.gravity_cam_xyz[2]);
    rec.has_pose = true;

    const double gravity_cam_xyz[3] = {rec.gravity_cam.x(),
                                       rec.gravity_cam.y(),
                                       rec.gravity_cam.z()};
    // ⚠️ PROVENANCE GAP (2026-08-04): 0.5 deg has no cited source. It is the
    // stddev of an attitude ANCHOR, not of a gravity measurement (see
    // gravity_ba_prior_v1.h). Two facts bound it and neither has been reconciled
    // with this number: our own reconstruction-vs-ARKit rotation drift measures
    // under 1 deg, i.e. up to 2 sigma of coherent, same-signed error across all
    // frames; and RealityCapture ships its comparable orientation prior
    // (sfmCameraPriorAccuracyYaw/Pitch/Roll) at 10.0, twenty times looser. Do
    // not treat 0.5 as validated. Changing it changes reconstruction output and
    // therefore requires an on-device A/B, not a host run.
    constexpr double kGravityBaSigmaRad =
        0.5 * 3.14159265358979323846 / 180.0;
    if (!aether_ba_set_gravity_prior(name, gravity_cam_xyz,
                                     kGravityBaSigmaRad)) {
      // This path is constructionally unreachable after the mandatory ingest
      // validator, but it remains fail-closed if the registry contract ever
      // drifts. No BA is allowed to silently proceed without this frame's
      // gravity observation.
      return AETHER_SFM_ERR_INVALID_ARG;
    }
    if (!PersistArkitPoseSnapshot(*s, rec)) {
      // The DB image now exists but there is no complete matching pose
      // snapshot. Stop immediately: on relaunch the count mismatch is an
      // explicit blocked recovery, never permission to invoke P3P.
      //
      // The ordinal is consumed by OrdinalGuardV1 on the way out (it covers this
      // return and every other exit path, including exceptions), so this branch
      // only has to report.
      LOG(ERROR) << "[aether_sfm][ARKIT-PERSIST-FAIL] frame " << rec.frame_id
                 << " dropped from the reconstruction: pose snapshot write "
                    "failed. Live capture continues on the next ordinal.";
      return AETHER_SFM_ERR_INTERNAL;
    }

    // Register this frame into the live Reconstruction with its ARKit pose.
    // Trivial rig/frame (frame_id == image_id); the 2-arg overload sets the
    // pose AND RegisterFrame()s it in one call.
    if (s->live_recon_ready) {
      colmap::Image rimg;
      rimg.SetImageId(image_id);
      rimg.SetName(name);
      rimg.SetCameraId(rec.camera_id);
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
    //    [THERMAL-THROTTLE 2026-07-11] Live candidate K is now RUNTIME-tunable:
    //      • base K: env OFFICIAL_AETHER_LIVE_CAND_K overrides options.k_neighbors
    //        (production 12);
    //      • hot K: when the platform-pushed thermal state is serious/critical
    //        (>= 2, aether_sfm_set_thermal_state) the window drops to
    //        OFFICIAL_AETHER_LIVE_CAND_K_HOT — halving the per-frame Metal matcher load
    //        to give the camera/system GPU room (cap45 freeze: thermal-serious
    //        GPU saturation → MTLCommandBufferStatusError → ARSession frame
    //        stall ~2 min).
    //    Throttled frames are marked fed_throttled and
    //    FinalizeRematchStarvedFrames re-matches their missing temporal-window
    //    pairs at finish time.
    //    ⚠️ DEFAULT OFF (2026-07-11 host A/B verdict): the quality gate was
    //    final points ±2% / reproj ±0.02 / registered ==. cap44 (109f) passed
    //    (−0.36% / +0.0024 / 109==109), but cap45 (47f) exceeded the points
    //    band in the POSITIVE direction on both K6 (+2.36%) and the K8 retry
    //    (+2.69%) — the finalize backfill (temporal window) adds pairs the
    //    live spatial-first K12 baseline never attempts, so the throttled arm
    //    delivers MORE points (reproj in band, registered equal, baseline
    //    rerun bit-identical ⇒ systematic, not noise). More-not-fewer is not
    //    a loss, but it is outside the pre-agreed band → per the sign-off
    //    rule the throttle ships DISABLED; OFFICIAL_AETHER_LIVE_CAND_K_HOT=<k> (e.g. 6)
    //    is the opt-in knob pending a user decision on the new band.
    static const int env_base_k = [] {
      if (const char* e = std::getenv("OFFICIAL_AETHER_LIVE_CAND_K")) {
        const int v = std::atoi(e);
        if (v > 0) return v;
      }
      return 0;  // 0 = use options.k_neighbors
    }();
    static const int hot_k = [] {
      if (const char* e = std::getenv("OFFICIAL_AETHER_LIVE_CAND_K_HOT")) {
        return std::atoi(e);  // >0 enables the thermal throttle at that K
      }
      return 0;  // DEFAULT OFF (A/B verdict above)
    }();
    const int base_k = env_base_k > 0
                           ? env_base_k
                           : (s->options.k_neighbors > 0 ? s->options.k_neighbors
                                                         : 6);
    const int thermal_now = s->thermal_state.load(std::memory_order_relaxed);
    const bool throttled = thermal_now >= 2 && hot_k > 0 && hot_k < base_k;
    const int k = throttled ? hot_k : base_k;
    if (throttled) {
      rec.fed_throttled = true;
      ++s->stat_thermal_throttled_frames;
    }
    if (throttled != s->throttle_active_logged) {
      s->throttle_active_logged = throttled;
      LOG(WARNING) << "[aether_sfm] thermal throttle "
                   << (throttled ? "ON" : "OFF") << " at frame " << frame_id
                   << " (thermal=" << thermal_now << ", live K "
                   << (throttled ? base_k : hot_k) << "→"
                   << (throttled ? hot_k : base_k)
                   << "); finalize re-match restores the pair topology.";
      char tline[160];
      std::snprintf(tline, sizeof(tline),
                    "{\"t\":%lld,\"type\":\"thermal_throttle\",\"on\":%d,"
                    "\"frame\":%d,\"thermal\":%d,\"k\":%d}",
                    static_cast<long long>(EpochMs()), throttled ? 1 : 0,
                    frame_id, thermal_now, k);
      AppendMatchFailJsonl(s, tline);
    }
    int cand_spatial = 0, cand_temporal = 0;
    std::vector<int> candidates =
        SelectSpatialK20TemporalT2Candidates(
            *s, rec, frame_id, throttled, k, &cand_spatial, &cand_temporal);
    // [VISUAL-LOOP V1] Every tenth valid frame, retrieve at most four remote
    // candidates after excluding S20/T2 and any pair already in sqlite. The
    // index is integer-only and platform neutral; failures are fail-closed to
    // the already selected S20/T2 graph.
    try {
      const std::vector<aether::sfm::VisualLoopCandidateV1> loop_candidates =
          s->visual_loop_index.QueryAndAdd(
              frame_id, rec.descriptors.data(), rec.n_keypoints, candidates);
      for (const aether::sfm::VisualLoopCandidateV1& loop : loop_candidates) {
        if (loop.frame_id < 0 || loop.frame_id >= frame_id) continue;
        const FrameRecord& previous = s->frames[loop.frame_id];
        if (previous.image_id == 0 ||
            s->db->ExistsMatches(previous.image_id, image_id) ||
            s->db->ExistsTwoViewGeometry(previous.image_id, image_id)) {
          continue;
        }
        candidates.push_back(loop.frame_id);
      }
      std::sort(candidates.begin(), candidates.end());
      candidates.erase(std::unique(candidates.begin(), candidates.end()),
                       candidates.end());
    } catch (...) {
      // Retrieval is an insurance source, never a capture blocker.
    }
    AppendTailMatchCandidatesV1(
        s, frame_id, static_cast<int>(candidates.size()), candidates);
    s->stat_cand_spatial_first_pairs += cand_spatial;
    s->stat_cand_temporal_fallback_pairs += cand_temporal;
    const double ratio = s->options.match_max_ratio > 0
                             ? s->options.match_max_ratio
                             : 0.7;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    const double t_match0 = NowMs();
    // [AETHER-T2 2026-07-26] Five-way split of the (historically monolithic)
    // match= wall: GPU pairing / TVG+db writes / official triangulation /
    // windowed local BA / everything else. Pure observation, emitted as one
    // frame_split jsonl line per frame — the serious-state 3.6x match=
    // inflation was unattributable without it.
    double t2_gpu_ms = 0.0, t2_tvg_ms = 0.0, t2_tri_ms = 0.0, t2_lba_ms = 0.0;
    const bool tail_cache_observed = TailCacheTraceEnabled();
    double t2_cache_ms = 0.0;
    int tail_cache_reused = 0;
    uint64_t tail_cache_generation = 0;
    int n_cand = 0, gpu_matches = 0, cpu_matches = 0;
    std::vector<uint32_t> pair_buf;
    // Live-preview triangulation scratch. Triangulate each NEW-frame keypoint at
    // most once per add_frame (cheap dedup: a keypoint matched across several
    // prev frames would otherwise emit several near-duplicate 3D points).
    // Points created or grown in the live Reconstruction this frame → the
    // variable set for the windowed local BA below.
    std::unordered_set<colmap::point3D_t> touched;
    // [SCAN-MATRIX ENV ①②] creation parallax + grow reproj gates, env-tunable
    // (OFFICIAL_AETHER_LIVE_TRI_MIN_ANGLE degrees / OFFICIAL_AETHER_GROW_REPROJ_PX px);
    // defaults = shipped 2.0° (T20) / 14 px.
    const double kMinTriAngleRad = LiveCreateTriMinAngleRad();
    const double kMaxCreateReprojPx = LiveCreateMaxReprojPx();  // new-point gate
    const bool kSelfDevTri = SelfDevLiveTriangulationEnabled();
    const double kMaxGrowReprojPx = LiveGrowMaxReprojPx();  // TVG-inlier grow absorbs ARKit drift
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
    // [PROBE-GATE 2026-08-07] Build the NEW frame's even-stride 512-row
    // descriptor subset ONCE per add_frame (64 KB memcpy) — reused against
    // every candidate below. Only armed when the gate is on AND the frame
    // actually has more rows than the probe (otherwise probe == full match
    // and the gate could only add cost).
    const int probe_gate_min = ProbeGateMin();
    std::vector<uint8_t> probe_desc_buf;
    std::vector<uint32_t> probe_pair_buf;
    int probe_rows = 0;
    if (probe_gate_min > 0 && rec.n_keypoints > kProbeGateRows) {
      probe_rows = kProbeGateRows;
      const int probe_step = rec.n_keypoints / probe_rows;  // >= 1
      probe_desc_buf.resize(static_cast<size_t>(probe_rows) * 128);
      for (int r = 0; r < probe_rows; ++r) {
        std::memcpy(probe_desc_buf.data() + static_cast<size_t>(r) * 128,
                    rec.descriptors.data() +
                        static_cast<size_t>(r) * probe_step * 128,
                    128);
      }
      probe_pair_buf.resize(static_cast<size_t>(probe_rows) * 2);
    }
    int frame_probe_attempted = 0, frame_probe_skipped = 0;
    double frame_probe_ms = 0.0;
    std::unordered_set<PointIdPair, PointIdPairHash> merge_trials;
    for (const int j : candidates) {
      const FrameRecord& prev = s->frames[j];
      ++n_cand;
      s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] match 调用前打点
      // [PROBE-GATE 2026-08-07] Cheap 512×n probe first: score = mutual
      // cross-checked match count of the subset at the production ratio. A
      // score below the threshold predicts (AUC 0.95) the full pair would die
      // in TVG anyway → skip the full GEMM + TVG + db write. Fail-open on any
      // probe error: the pair proceeds exactly as without the gate. Skipped
      // pairs are NOT marked live_pairs_done, so idle repay / finalize
      // re-match can still recover any misprediction.
      if (probe_rows > 0 && prev.n_keypoints > 0 &&
          !prev.descriptors.empty()) {
        const double t_p0 = NowMs();
        int probe_matches = 0;
        // No rc=7 backoff for the probe (a hot-GPU transient must not add
        // 150 ms to a gate whose whole point is saving time) and no
        // descriptor-residency route (the resident matrix is the FULL frame,
        // not this subset) — hence the direct entry, not
        // GpuMatchGemmPairsRetry.
        const int prc =
            gpu_match_avail
                ? aether_gpu_match_gemm_pairs(
                      probe_desc_buf.data(), probe_rows,
                      prev.descriptors.data(), prev.n_keypoints, ratio,
                      probe_pair_buf.data(), probe_rows, &probe_matches)
                : aether_sift_match_pairs(
                      probe_desc_buf.data(), probe_rows,
                      prev.descriptors.data(), prev.n_keypoints, ratio,
                      probe_pair_buf.data(), probe_rows, &probe_matches);
        const double probe_ms = NowMs() - t_p0;
        frame_probe_ms += probe_ms;
        s->stat_probe_ms += probe_ms;
        ++s->stat_probe_attempted;
        ++frame_probe_attempted;
        if (prc == 0) {
          if (probe_matches < probe_gate_min) {
            ++s->stat_probe_skipped;
            ++frame_probe_skipped;
            continue;  // predicted-dead pair: full match skipped
          }
          ++s->stat_probe_passed;
        } else {
          ++s->stat_probe_fail_open;  // probe unavailable → gate inert
        }
      }
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
      // [EPI-PRIOR 2026-07-27] Experiment arm (default OFF): ARKit epipolar
      // band first; any failure/collapse falls through to the unchanged
      // full-GEMM path below.
      if (EpiPriorMatchEnabled() && gpu_match_avail) {
        const double t2_m0 = NowMs();
        const int gap = static_cast<int>(s->frames.size()) - j;
        const bool ok = ArkitGuidedMatchPair(s, prev, rec, gap, ratio,
                                             pair_buf.data(), cap,
                                             &num_matches);
        t2_gpu_ms += NowMs() - t2_m0;
        if (ok) {
          mrc = 0;
          used_gpu = true;
          s->gpu_match_fail_streak = 0;
          ++s->gpu_pairs_since_rc7;
        }
      }
      if (mrc != 0 && gpu_match_avail) {
        // [P1-RC7-RETRY] transient rc=7 gets two backoff retries in-line
        // (worst case +~150 ms on a dead pair, bounded) before the pair
        // fails closed into the repay/finalize debt.
        const double t2_m0 = NowMs();
        mrc = GpuMatchGemmPairsRetry(
            s, prev.frame_id, prev.descriptors.data(), prev.n_keypoints,
            rec.frame_id, rec.descriptors.data(), rec.n_keypoints, ratio,
            pair_buf.data(), cap, &num_matches);
        t2_gpu_ms += NowMs() - t2_m0;
        if (mrc != 0) {
          // [MATCH-FAIL TELEMETRY 2026-07-11] Same fail-closed skip as before
          // (no CPU fallback on device — a Metal failure used to stall the
          // queue for minutes), but no longer SILENT: rc-bucketed counters +
          // segment warning make a thermal matcher collapse visible, and the
          // idle-repay + finalize re-match passes repair the db afterwards.
          NoteGpuMatchFailure(s, mrc, j, frame_id);
          continue;
        }
        s->gpu_match_fail_streak = 0;  // healthy pair ends a failure segment
        ++s->gpu_pairs_since_rc7;      // [P1-REPAY-THERMAL2] clean history
        used_gpu = true;
      } else if (!gpu_match_avail) {
        const double t2_m0 = NowMs();
        mrc = aether_sift_match_pairs(
            prev.descriptors.data(), prev.n_keypoints, rec.descriptors.data(),
            rec.n_keypoints, ratio, pair_buf.data(), cap, &num_matches);
        t2_gpu_ms += NowMs() - t2_m0;
      }
      s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] match 调用后打点
      if (mrc != 0) continue;
      if (num_matches <= 0) continue;
      if (used_gpu) gpu_matches += num_matches; else cpu_matches += num_matches;

      const double t2_v0 = NowMs();  // [AETHER-T2] TVG + db-write section
      colmap::FeatureMatches matches(num_matches);
      for (int m = 0; m < num_matches; ++m) {
        matches[m].point2D_idx1 = pair_buf[2 * m];
        matches[m].point2D_idx2 = pair_buf[2 * m + 1];
      }

      colmap::TwoViewGeometry two_view_geometry;
      // [GUIDED-TEMPORAL 2026-07-12] Weak-texture recall lever, DEFAULT OFF.
      // These frames carry ARKit poses (rec.has_pose / prev.has_pose set above),
      // so the pair has an epipolar prior; but rather than derive E from the
      // (drift-prone) ARKit poses, we reuse the exact chain the spatial-
      // enrichment path already ships and verifies: estimate the seed geometry
      // from the raw cross-checked matches, then re-match INSIDE that E/F band
      // at the relaxed ratio (0.8, vs the temporal 0.7). Epipolar
      // disambiguation rescues the repetitive/low-texture correspondences the
      // plain Lowe ratio judges to death (2nd-NN ≈ 1st-NN).
      // RED LINE: guided candidates are NOT trusted. They pass a fresh TVG
      // RANSAC and are adopted ONLY when their inlier count STRICTLY exceeds the
      // raw pair's, so nothing downstream is relaxed — the same TVG geometry,
      // tri-angle (2.0°), reproj, ghost L1/L2, and finalize min_num_matches=15
      // gates run unchanged, and view-dependent reflection matches (appearance
      // wrong, epipolar can't fix) still fall exactly as before.
      if (GuidedTemporalEnabled() && gpu_match_avail &&
          aether_gpu_match_gemm_pairs_guided != nullptr) {
        const auto initial_tvg = EstimateMandatoryFrameTwoViewGeometry(
            prev, prev.points, rec, rec.points, matches, tvg_options);
        if (!MandatoryGravityTvgPersistable(initial_tvg)) continue;
        two_view_geometry = initial_tvg.geometry;
        colmap::FeatureMatches guided;
        if (RunGuidedMatch(s, prev, rec, two_view_geometry, &guided) &&
            !guided.empty()) {
          ++s->stat_guided_temporal_attempted;
          const auto guided_tvg = EstimateMandatoryFrameTwoViewGeometry(
              prev, prev.points, rec, rec.points, guided, tvg_options);
          if (MandatoryGravityTvgPersistable(guided_tvg) &&
              guided_tvg.geometry.inlier_matches.size() >
              two_view_geometry.inlier_matches.size()) {
            ++s->stat_guided_temporal_upgraded;
            s->stat_guided_temporal_extra_inliers +=
                static_cast<int64_t>(
                    guided_tvg.geometry.inlier_matches.size()) -
                static_cast<int64_t>(two_view_geometry.inlier_matches.size());
            matches = std::move(guided);
            num_matches = static_cast<int>(matches.size());
            two_view_geometry = guided_tvg.geometry;
          }
        }
      } else {
        const auto tvg = EstimateMandatoryFrameTwoViewGeometry(
            prev, prev.points, rec, rec.points, matches, tvg_options);
        if (!MandatoryGravityTvgPersistable(tvg)) continue;
        two_view_geometry = tvg.geometry;
      }
      const bool tail_pair_first_write =
          TailCacheBeginPairWrite(s, prev.image_id, image_id);
      s->db->WriteMatches(prev.image_id, image_id, matches);
      s->db->WriteTwoViewGeometry(prev.image_id, image_id, two_view_geometry);
      TailCacheCommitPair(s, prev.image_id, image_id, two_view_geometry,
                          tail_pair_first_write);
      // A pair becomes resolved only after an upright-valid/planar TVG is
      // persisted. Pending geometry stays eligible for idle/finalize retry.
      s->live_pairs_done.insert(FramePairKey(frame_id, j));
      t2_tvg_ms += NowMs() - t2_v0;
      // [P1-LIVE-REPAY] Per-frame valid-window-pair counters, mirroring the
      // FinalizeRematchStarvedFrames win_valid rule (gap <= production K,
      // TVG inliers >= gate) so the idle repay pass can detect starvation
      // without a db scan.
      {
        if (static_cast<int>(s->live_win_valid.size()) <= frame_id) {
          s->live_win_valid.resize(frame_id + 1, 0);
        }
        const int window_k =
            s->options.k_neighbors > 0 ? s->options.k_neighbors : 12;
        if (frame_id - j <= window_k &&
            static_cast<int>(two_view_geometry.inlier_matches.size()) >=
                kRematchValidInlierGate) {
          ++s->live_win_valid[j];
          ++s->live_win_valid[frame_id];
        }
      }

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
        const colmap::FeatureMatches& inliers =
            two_view_geometry.inlier_matches;
        const int grow_n = static_cast<int>(inliers.size());
        s->stat_tvg_inlier_pairs += grow_n;
        for (int mm = 0; mm < grow_n; ++mm) {
          const uint32_t i1 = inliers[mm].point2D_idx1;
          const uint32_t i2 = inliers[mm].point2D_idx2;
          if (i1 >= prev.points.size() || i2 >= rec.points.size()) continue;
          // [OFFICIAL-TRIANGULATE ARM 2026-07-26] Everything above this line —
          // candidate selection, matching, WriteMatches/WriteTwoViewGeometry —
          // still runs, because the upstream triangulator feeds on exactly
          // those correspondences. Only the hand-written authoring below is
          // skipped, so the arm is a clean swap of WHO creates the points.
          if (!kSelfDevTri) continue;
          const colmap::Point2D& o1 = s->live_recon->Image(prev.image_id).Point2D(i1);
          const colmap::Point2D& o2 = s->live_recon->Image(image_id).Point2D(i2);
          const bool has1 = o1.HasPoint3D();
          const bool has2 = o2.HasPoint3D();

          // Both assigned: same track = nothing; different tracks = try a
          // conservative live MergePoints3D. This directly attacks duplicate
          // fragmented tracks without a finish-time global BA. The loop's
          // input is now unconditionally the mandatory upright-TVG inlier set;
          // there is no raw-match fallback that could glue unrelated texture.
          if (has1 && has2) {
            if (o1.point3D_id == o2.point3D_id) ++s->stat_already_assigned;
            else {
              ++s->stat_merge_needed;
              const PointIdPair key =
                  CanonicalPointPair(o1.point3D_id, o2.point3D_id);
              if (!merge_trials.insert(key).second) continue;
              Eigen::Vector3d refit_xyz;
              const MergeReject verdict = CanMergeLivePoints(
                  *s->live_recon, key.a, key.b, kMaxMergeReprojPx,
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
            const colmap::Camera& gcamera = has1 ? rec.camera : prev.camera;
            const Eigen::Vector2d& gkp = has1 ? rec.points[i2] : prev.points[i1];
            const Eigen::Vector3d Xg = gcfw * s->live_recon->Point3D(pid).xyz;
            if (Xg.z() <= 0.0) {
              ++s->stat_grow_rejected;
              ++s->stat_grow_reject_cheirality;
              continue;
            }
            const std::optional<Eigen::Vector2d> pg = gcamera.ImgFromCam(Xg);
            const double grow_gate = kMaxGrowReprojPx;
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
          const std::optional<Eigen::Vector2d> nn1 =
              prev.camera.CamFromImg(prev.points[i1]);
          const std::optional<Eigen::Vector2d> nn2 =
              rec.camera.CamFromImg(rec.points[i2]);
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
          const std::optional<Eigen::Vector2d> rr1 =
              prev.camera.ImgFromCam(X_prev);
          const std::optional<Eigen::Vector2d> rr2 =
              rec.camera.ImgFromCam(X_cur);
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

    // ── Official COLMAP local refinement ───────────────────────────────────
    // Run the upstream mapper's two-round local refinement. It selects the six
    // most-connected images (not the six most recent frames), completes/merges
    // tracks, filters observations, and keeps every per-image ARKit PINHOLE
    // intrinsic fixed while optimizing poses and 3D points.
    if (rec.has_pose && s->live_recon_ready && s->live_recon->NumRegImages() >= 3 &&
        StreamingLocalBaEnabled() &&
        (frame_id % StreamingLocalBaPeriod(s->ba_every_n)) == 0) {
      try {
        colmap::DatabaseCache::Options cache_options;
        cache_options.min_num_matches = 15;
        cache_options.load_all_images = true;
        const double t2_cache0 = tail_cache_observed ? NowMs() : 0.0;
        std::shared_ptr<colmap::DatabaseCache> cache;
        std::shared_ptr<colmap::DatabaseCache> tail_shadow_cache;
        std::unique_lock<std::mutex> tail_cache_use_lock;
        if (TailCacheMode() == TailCacheModeV1::kOn) {
          tail_cache_use_lock =
              std::unique_lock<std::mutex>(s->tail_cache_mutex);
          if (!s->tail_cache_master || !s->tail_cache_epoch.readable()) {
            if (s->tail_cache_epoch.state() !=
                aether::sfm::TailCacheEpochStateV1::kDirty) {
              TailCacheMarkDirtyLockedV1(
                  s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency);
            }
            TailCacheRebuildLocked(s);
          }
          if (s->tail_cache_master && s->tail_cache_epoch.readable()) {
            cache = s->tail_cache_master;
            tail_cache_reused = 1;
            tail_cache_generation = s->tail_cache_epoch.generation();
          }
        }
        if (!cache) {
          cache = colmap::DatabaseCache::Create(*s->db, cache_options);
          if (TailCacheMode() == TailCacheModeV1::kShadow) {
            std::lock_guard<std::mutex> shadow_lock(s->tail_cache_mutex);
            if (!s->tail_cache_master || !s->tail_cache_epoch.readable()) {
              if (s->tail_cache_epoch.state() !=
                  aether::sfm::TailCacheEpochStateV1::kDirty) {
                TailCacheMarkDirtyLockedV1(
                    s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency);
              }
              TailCacheRebuildLocked(s);
            }
            tail_cache_generation = s->tail_cache_epoch.generation();
            if (s->tail_cache_master && s->tail_cache_epoch.readable()) {
              tail_shadow_cache = s->tail_cache_master;
            }
          }
        }
        if (tail_cache_observed) t2_cache_ms += NowMs() - t2_cache0;

        colmap::IncrementalPipelineOptions official_options;
        official_options.min_num_matches = 15;
        official_options.triangulation.ignore_two_view_tracks =
            TriIgnoreTwoViewTracks();
        official_options.load_all_images = true;
        official_options.ba_refine_focal_length = false;
        official_options.ba_refine_principal_point = false;
        official_options.ba_refine_extra_params = false;
        official_options.mapper.ba_local_num_images =
            s->ba_window > 0 ? s->ba_window : 6;
        // [LIVE-LBA-THREADS 2026-07-29 SHIPPED] Host A/B on cap7_day, four arms,
        // all four BYTE-IDENTICAL in geometry (n_points 141758 / track3plus
        // 53239 / n_obs 411770 / mean_reproj 1.0553 on every arm — thread count
        // is provably lossless here, matching the finalize-side precedent):
        //   all-single (two independent routes)  35.8s  ← noise band 0.4%
        //   shipped default (floor 50k, -1)      34.9s  -2.5%
        //   LiveBaThreads()==4 + floor 6000      26.4s  -26.2%   ← ship
        //   all cores (host 12) + floor 6000     31.0s  -13.4%
        // ⚠️ MORE THREADS IS WORSE: 12 gives back half the gain to sync
        // overhead on a 6-image window. Do not "improve" this to -1.
        // The 4 that won on host is also exactly LiveBaThreads() on an A16
        // (min(6, hw-2)), i.e. the same value that deliberately reserves two
        // cores for the camera/GPU-matcher/UI mid-capture — the speed optimum
        // and the thermal/camera-safety choice coincide. Device must still
        // confirm the optimum on 6 cores; env overrides both knobs.
        official_options.num_threads = LiveBaThreads();
        official_options.ba_min_num_residuals_for_cpu_multi_threading = 6000;
        if (const int t = LiveLocalBaThreadsOverride(); t > 0) {
          official_options.num_threads = t;
        }
        if (const int f = LiveLocalBaMtFloorOverride(); f >= 0) {
          official_options.ba_min_num_residuals_for_cpu_multi_threading = f;
        }
        ApplyBirthGateAB(&official_options);  // [BIRTH-GATE-AB 2026-08-07]

        colmap::IncrementalMapper mapper(cache);
        mapper.BeginReconstruction(s->live_recon);
        // [OFFICIAL-TRIANGULATE 2026-07-26] Upstream calls TriangulateImage on
        // a freshly registered image BEFORE the local refinement
        // (controllers/incremental_pipeline.cc:817). We never have: this route
        // registers via AddImageWithTrivialFrame instead of RegisterNextImage,
        // so the official point-CREATION entry was simply never reached and the
        // hand-written create/grow/merge filled that hole. The triangulator does
        // not care where a pose came from — it triangulates this image's
        // observations against the already-registered images using whatever
        // poses the model holds, which here are ARKit's. Env-gated so the arm is
        // a clean single variable; unset == byte-identical to the shipped path.
        if (OfficialTriangulateImageEnabled()) {
          const double t2_t0 = NowMs();
          const size_t n_off =
              mapper.TriangulateImage(official_options.Triangulation(), image_id);
          s->stat_official_tri_added += static_cast<int64_t>(n_off);
          t2_tri_ms += NowMs() - t2_t0;
        }
        // [TAIL-CACHE-FIRST V1] In shadow mode, run the mutable cache on an
        // isolated Reconstruction copy and a dedicated thread before the
        // authoritative fresh-cache refinement. The copy prevents output
        // mutation; the dedicated thread prevents its thread_local PRNG state
        // from advancing the production caller. Shadow is diagnostic-only and
        // intentionally receives no speed credit.
        LocalBundleTraceSnapshotV1 tail_shadow_trace;
        bool tail_shadow_executed = false;
        bool tail_shadow_failed = false;
        if (tail_shadow_cache) {
          auto tail_shadow_recon =
              std::make_shared<colmap::Reconstruction>(*s->live_recon);
          ResetLocalBundleTraceV1();
          std::thread shadow_thread([&] {
            try {
              colmap::IncrementalMapper shadow_mapper(tail_shadow_cache);
              shadow_mapper.BeginReconstruction(tail_shadow_recon);
              shadow_mapper.IterativeLocalRefinement(
                  official_options.ba_local_max_refinements,
                  official_options.ba_local_max_refinement_change,
                  official_options.Mapper(),
                  official_options.LocalBundleAdjustment(),
                  official_options.Triangulation(), image_id);
              shadow_mapper.EndReconstruction(/*discard=*/false);
              tail_shadow_executed = true;
            } catch (...) {
              tail_shadow_failed = true;
            }
          });
          shadow_thread.join();
          tail_shadow_trace = CaptureLocalBundleTraceV1();
        }

        // [AETHER-T2 2026-07-29] Zero the local-path counters for THIS frame,
        // then drain them into the frame_split record below. Pure observation.
        aether_ilr_find_ms = aether_ilr_setup_ms = aether_ilr_solve_ms = 0.0;
        aether_ilr_merge_ms = aether_ilr_filter_ms = 0.0;
        aether_ilr_preproc_ms = aether_ilr_minim_ms = aether_ilr_postproc_ms =
            0.0;
        aether_ilr_rounds = aether_ilr_solves = aether_ilr_iters = 0;
        aether_ilr_term_conv = aether_ilr_term_nocnv = aether_ilr_term_other =
            0;
        ResetLocalBundleTraceV1();
        const double t2_l0 = NowMs();
        mapper.IterativeLocalRefinement(
            official_options.ba_local_max_refinements,
            official_options.ba_local_max_refinement_change,
            official_options.Mapper(),
            official_options.LocalBundleAdjustment(),
            official_options.Triangulation(), image_id);
        t2_lba_ms += NowMs() - t2_l0;
        const LocalBundleTraceSnapshotV1 fresh_trace =
            CaptureLocalBundleTraceV1();
        AppendTailLocalBundleTraceV1(s, frame_id, tail_cache_reused,
                                     tail_cache_generation, "fresh",
                                     fresh_trace);
        if (tail_shadow_cache) {
          AppendTailLocalBundleTraceV1(s, frame_id, /*cache_reused=*/1,
                                       tail_cache_generation, "mutable",
                                       tail_shadow_trace);
          const bool exact = tail_shadow_executed && !tail_shadow_failed &&
                             LocalBundleTraceExactV1(fresh_trace,
                                                     tail_shadow_trace);
          std::string compare_line =
              "{\"t\":" +
              std::to_string(static_cast<long long>(EpochMs())) +
              ",\"type\":\"tail_shadow_compare_v1\",\"fid\":" +
              std::to_string(frame_id) + ",\"status\":\"" +
              (exact ? "EXACT" : "INVALID_TAIL_BUNDLE_SEQUENCE") +
              "\",\"fresh_calls\":" +
              std::to_string(fresh_trace.raw_calls) +
              ",\"mutable_calls\":" +
              std::to_string(tail_shadow_trace.raw_calls) + "}";
          AppendMatchFailJsonl(s, compare_line);
          if (!exact) {
            TailCacheMarkDirty(
                s, aether::sfm::TailCacheDirtyReasonV1::kCacheInconsistency);
          }
        }
        mapper.EndReconstruction(/*discard=*/false);
      } catch (const std::exception&) {
        // A degenerate local bundle must not kill capture. The next accepted
        // frame retries through the same official path.
        TailCacheMarkDirty(
            s, aether::sfm::TailCacheDirtyReasonV1::kExceptionRetry);
      }
    }

    // [INCREMENTAL-GLOBAL-BA 2026-07-13] Rolling capture-time global BA over
    // live_recon (DEFAULT OFF; OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1). No-op unless the
    // env switch is on and the cadence/thermal gates pass; mutates live_recon in
    // place, so the unconditional preview snapshot just below reflects it.
    MaybeIncrementalGlobalRefine(s);

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
    // The real record now owns this ordinal; the guard must not add a
    // placeholder for it.
    ordinal_guard.committed = true;
    s->last_extract_ms = extract_ms;
    s->last_match_ms = NowMs() - t_match0;
    // [AETHER-T2] frame_split: one compact pullable line per frame (~150 B;
    // a 155-frame capture adds ~25 KB to the sidecar).
    {
      const double t2_total = s->last_match_ms;
      char fline[1024];
      const double* ex = s->last_extract_stages;
      const int active_components = CountActiveComponentsV1(*s);
      const double t2_tail_ms =
          t2_total - t2_gpu_ms - t2_tvg_ms - t2_tri_ms - t2_lba_ms;
      // Keep the absent-flag record byte-schema identical to the established
      // frame_split. Cache fields are emitted only for explicit off/shadow/on
      // experiment launches, so installing the dormant code does not enlarge
      // every production-frame log.
      if (tail_cache_observed) {
        std::snprintf(
            fline, sizeof(fline),
            "{\"t\":%lld,\"type\":\"frame_split\",\"fid\":%d,"
            "\"cand\":%d,\"comp\":%d,\"gpu_ms\":%.0f,\"tvg_ms\":%.0f,"
            "\"tri_ms\":%.0f,\"lba_ms\":%.0f,\"tail_ms\":%.0f,"
            "\"cache_ms\":%.1f,\"tail_cache\":%d,\"tail_gen\":%llu,"
            "\"ex\":[%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f],"
            "\"ilr_find\":%.1f,\"ilr_setup\":%.1f,\"ilr_solve\":%.1f,"
            "\"ilr_merge\":%.1f,\"ilr_filter\":%.1f,"
            "\"ilr_pre\":%.1f,\"ilr_min\":%.1f,\"ilr_post\":%.1f,"
            "\"ilr_rounds\":%d,\"ilr_solves\":%d,\"ilr_iters\":%d,"
            "\"ilr_conv\":%d,\"ilr_nocnv\":%d,\"ilr_oth\":%d}",
            static_cast<long long>(EpochMs()), frame_id, n_cand,
            active_components, t2_gpu_ms,
            t2_tvg_ms, t2_tri_ms, t2_lba_ms, t2_tail_ms, t2_cache_ms,
            tail_cache_reused,
            static_cast<unsigned long long>(tail_cache_generation), ex[0],
            ex[1], ex[2], ex[3], ex[4], ex[5], ex[6], ex[7], ex[8],
            aether_ilr_find_ms, aether_ilr_setup_ms, aether_ilr_solve_ms,
            aether_ilr_merge_ms, aether_ilr_filter_ms, aether_ilr_preproc_ms,
            aether_ilr_minim_ms, aether_ilr_postproc_ms, aether_ilr_rounds,
            aether_ilr_solves, aether_ilr_iters, aether_ilr_term_conv,
            aether_ilr_term_nocnv, aether_ilr_term_other);
      } else {
        std::snprintf(
            fline, sizeof(fline),
            "{\"t\":%lld,\"type\":\"frame_split\",\"fid\":%d,"
            "\"cand\":%d,\"comp\":%d,\"gpu_ms\":%.0f,\"tvg_ms\":%.0f,"
            "\"tri_ms\":%.0f,\"lba_ms\":%.0f,\"tail_ms\":%.0f,"
            "\"ex\":[%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f],"
            "\"ilr_find\":%.1f,\"ilr_setup\":%.1f,\"ilr_solve\":%.1f,"
            "\"ilr_merge\":%.1f,\"ilr_filter\":%.1f,"
            "\"ilr_pre\":%.1f,\"ilr_min\":%.1f,\"ilr_post\":%.1f,"
            "\"ilr_rounds\":%d,\"ilr_solves\":%d,\"ilr_iters\":%d,"
            "\"ilr_conv\":%d,\"ilr_nocnv\":%d,\"ilr_oth\":%d}",
            static_cast<long long>(EpochMs()), frame_id, n_cand,
            active_components, t2_gpu_ms,
            t2_tvg_ms, t2_tri_ms, t2_lba_ms, t2_tail_ms, ex[0], ex[1], ex[2],
            ex[3], ex[4], ex[5], ex[6], ex[7], ex[8], aether_ilr_find_ms,
            aether_ilr_setup_ms, aether_ilr_solve_ms, aether_ilr_merge_ms,
            aether_ilr_filter_ms, aether_ilr_preproc_ms, aether_ilr_minim_ms,
            aether_ilr_postproc_ms, aether_ilr_rounds, aether_ilr_solves,
            aether_ilr_iters, aether_ilr_term_conv, aether_ilr_term_nocnv,
            aether_ilr_term_other);
      }
      AppendMatchFailJsonl(s, fline);
    }
    // [PROBE-GATE 2026-08-07] One compact per-frame gate record, emitted only
    // when the gate is armed so the default-off sidecar stays byte-identical.
    if (probe_gate_min > 0) {
      char pline[224];
      std::snprintf(pline, sizeof(pline),
                    "{\"t\":%lld,\"type\":\"probe_gate\",\"fid\":%d,"
                    "\"min\":%d,\"att\":%d,\"skip\":%d,\"probe_ms\":%.1f,"
                    "\"cum_att\":%lld,\"cum_skip\":%lld}",
                    static_cast<long long>(EpochMs()), frame_id,
                    probe_gate_min, frame_probe_attempted, frame_probe_skipped,
                    frame_probe_ms,
                    static_cast<long long>(s->stat_probe_attempted),
                    static_cast<long long>(s->stat_probe_skipped));
      AppendMatchFailJsonl(s, pline);
    }
    AppendGpuTimestampFrameRecord(s, frame_id);
    // [IDLE-PREPAY 2026-08-07] frame-idle clock for the idle-prepay leg.
    s->last_add_frame_done_ms = NowMs();
    s->last_n_cand = n_cand;
    s->last_gpu_matches = gpu_matches;
    s->last_cpu_matches = cpu_matches;
    const int accepted_thermal =
        s->thermal_state.load(std::memory_order_relaxed);
    const bool accepted_thermal_valid =
        accepted_thermal >= 0 && accepted_thermal <= 3;
    aether_preclamp_instr_v1::FrameCounts preclamp_row;
    if (aether_preclamp_instr_v1::FinalizeAcceptedFrame(
            frame_id, static_cast<uint32_t>(s->frames.size()),
            accepted_thermal_valid
                ? aether_preclamp_instr_v1::FieldStatus::kValid
                : aether_preclamp_instr_v1::FieldStatus::kUnavailable,
            accepted_thermal_valid ? accepted_thermal : -1,
            &preclamp_row)) {
      (void)aether_preclamp_instr_v1::AppendSessionRecord(
          &s->preclamp_instr_records, preclamp_row);
    }
    // ⛔ [SPATIAL-REVIVE 2026-08-05 已撤回] 此处曾加一段"每帧打印描述子驻留命中率"
    // 的日志,**构造性永不执行**,已删。
    // 根因(nm 实测):`aether_gpu_match_descriptor_residency_stats` 在出货
    // PWOfficialSfm.framework 里是 **`t` = 本地符号,未导出** —— 按 ABI 边界
    // 设计如此:README 明确"exactly the frozen 26-symbol public surface,
    // **no exported self/internal symbols**",而 `pwofficial_abi_symbols.txt`
    // 那 26 个里没有任何 `aether_gpu_match_*`。所以产品核这侧的 weak 引用恒为
    // nullptr,日志块永远被跳过。
    // ⚠️ 别据此以为"驻留没实现":同一份 framework 内 `nm -a` 可见 33 个驻留
    // 符号(DescriptorResidencyPolicyV1 / MetalSessionV1 / LRU 全在)。
    // **驻留在 framework 内部完整工作,只是统计不跨边界。**
    // 合法的跨边界通道是 env(`OFFICIAL_AETHER_*` 配置命名空间),已在插件设
    // `OFFICIAL_AETHER_DESCRIPTOR_RESIDENCY_V1=1` 启用。
    // ⇒ 要观测驻留效果,只能看**外部效应**(每帧匹配耗时、热曲线),不能靠内部计数器。
    if (out_frame_id) *out_frame_id = frame_id;
    return AETHER_SFM_OK;
  } catch (const std::exception&) {
    TailCacheMarkDirty(
        s, aether::sfm::TailCacheDirtyReasonV1::kExceptionRetry);
    return AETHER_SFM_ERR_INTERNAL;
  } catch (...) {
    TailCacheMarkDirty(
        s, aether::sfm::TailCacheDirtyReasonV1::kExceptionRetry);
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
  aether_preclamp_instr_v1::DiscardPending(
      aether_preclamp_instr_v1::PendingDiscardReason::kSessionRejected);
  if (!s || !s->db || !gray || width <= 0 || height <= 0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  // pose_qwxyz/pose_t = ARKit CamFromWorld (world->camera), quaternion [w,x,y,z],
  // ARKit camera axes (+X right, +Y up, -Z forward). Consumed by the impl to
  // build the throwaway live-preview cloud only; the authoritative finalize
  // still self-estimates CamFromWorld (this prior does NOT feed the v1 solve).
  try {
    // [GPU-HANG-B1] add_frame 入口 Arm、所有出口(含异常)Disarm(RAII)。
    aether_gpu_watchdog_v1::WatchdogV1::ArmScope watchdog_armed(
        s->gpu_watchdog);
    s->gpu_timestamp_pending_frame_ready = false;
    const int max_features =
        s->options.max_features > 0 ? s->options.max_features : 2048;

    // 1) DSP-SIFT extraction. use_gpu_extract routes to the GPU DSP-SIFT
    //    (Dawn/WGSL, f16 on A16) which is output-equivalent (xy/128-d/UBC/
    //    RootSIFT) and falls back to the CPU _threaded path IN-ABI on any GPU
    //    failure — so this call site is unaware which path ran. Default = CPU.
    //    [SCALE-PERSIST 2026-08-06] prefer the _v2 exits (extra per-keypoint
    //    detection-scale output). GPU: gpu_v2 when the linked archive has it,
    //    else the old symbol without scales (unit-affine persist — the
    //    pre-change behaviour, so a new core over an old carrier only loses
    //    the new column, never correctness). CPU: _v2 is in this same target
    //    (official_dsp_sift_c.cc), always available.
    std::vector<float> xy(static_cast<size_t>(max_features) * 2);
    std::vector<uint8_t> desc(static_cast<size_t>(max_features) * 128);
    std::vector<float> scales(static_cast<size_t>(max_features));
    int n = 0;
    const bool gpu_v2_avail = s->options.use_gpu_extract &&
                              (aether_dsp_sift_extract_gpu_v2 != nullptr);
    const bool gpu_avail =
        s->options.use_gpu_extract && (aether_dsp_sift_extract_gpu != nullptr);
    const double t_extract0 = NowMs();
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] extract 调用前打点
    int erc;
    bool have_scales;
    if (gpu_v2_avail) {
      erc = aether_dsp_sift_extract_gpu_v2(
          gray, width, height, max_features, /*num_threads=*/0, xy.data(),
          desc.data(), scales.data(), /*out_orientations=*/nullptr,
          max_features, &n);
      have_scales = (erc == 0);
    } else if (gpu_avail) {
      erc = aether_dsp_sift_extract_gpu(gray, width, height, max_features,
                                        /*num_threads=*/0, xy.data(),
                                        desc.data(), max_features, &n);
      have_scales = false;
    } else {
      erc = aether_dsp_sift_extract_v2(
          gray, width, height, max_features, xy.data(), desc.data(),
          scales.data(), /*out_orientations=*/nullptr, max_features, &n);
      have_scales = (erc == 0);
    }
    const double extract_ms = NowMs() - t_extract0;
    s->gpu_watchdog.InProgress();  // [GPU-HANG-B1] extract 调用后打点
    // [AETHER-T-EXTRACT] Stash the extractor's per-stage split for the
    // frame_split record (zeroed when the CPU path / old archive ran).
    for (double& v : s->last_extract_stages) v = 0.0;
    if ((gpu_v2_avail || gpu_avail) && erc == 0 &&
        aether_sed_last_stages != nullptr) {
      aether_sed_last_stages(s->last_extract_stages, 9);
    }
    if (gpu_v2_avail || gpu_avail) {
      PullGpuTimestampAfterExtraction(s);
    }
    if (erc != 0 || n <= 0) {
      // Record the (possibly large) extract time even on failure so the log
      // reflects a stalled/fallback extractor; zero the match-side counters.
      s->last_extract_ms = extract_ms;
      s->last_match_ms = 0.0;
      s->last_n_cand = s->last_gpu_matches = s->last_cpu_matches = 0;
      return AETHER_SFM_ERR_EXTRACT;
    }

    const aether_sfm_result_t add_result = AddFrameFeaturesImpl(
        s, xy.data(), desc.data(), have_scales ? scales.data() : nullptr, n,
        width, height, fx, fy, cx, cy, pose_qwxyz, pose_t, extract_ms,
        out_frame_id);
    if (add_result != AETHER_SFM_OK) {
      aether_preclamp_instr_v1::DiscardPending(
          aether_preclamp_instr_v1::PendingDiscardReason::kSessionRejected);
    }
    return add_result;
  } catch (const std::exception& e) {
    aether_preclamp_instr_v1::DiscardPending(
        aether_preclamp_instr_v1::PendingDiscardReason::kSessionRejected);
    // [DIAG 2026-07-26] This catch used to swallow the message, so a device
    // capture that lost 25 consecutive frames to errInternal (every one of
    // them surfaced to the user as a red "unconnected photo, reshoot nearby"
    // card) left no evidence of WHAT threw. Log it: the reason is the whole
    // difference between a genuine coverage problem and an internal fault.
    LOG(WARNING) << "[aether_sfm] add_frame threw: " << e.what();
    {
      // Also land it in the pull-able jsonl next to the db: detached device
      // runs lose stderr/os_log, and this is exactly the forensic that was
      // missing.
      char line[512];
      std::snprintf(line, sizeof(line),
                    "{\"t\":%lld,\"type\":\"add_frame_throw\",\"what\":\"%.300s\"}",
                    static_cast<long long>(EpochMs()), e.what());
      AppendMatchFailJsonl(s, line);
    }
    return AETHER_SFM_ERR_INTERNAL;
  } catch (...) {
    aether_preclamp_instr_v1::DiscardPending(
        aether_preclamp_instr_v1::PendingDiscardReason::kSessionRejected);
    LOG(WARNING) << "[aether_sfm] add_frame threw a non-std exception";
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
  aether_preclamp_instr_v1::DiscardPending(
      aether_preclamp_instr_v1::PendingDiscardReason::kNonGpuRoute);
  if (!s || !s->db || !xy || !desc || n_keypoints <= 0 || width <= 0 ||
      height <= 0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  s->gpu_timestamp_pending_frame_ready = false;
  // [SCALE-PERSIST 2026-08-06] injection ABI carries no scales (host replay
  // feeds xy+desc only) — scales=nullptr reproduces the unit-affine write.
  return AddFrameFeaturesImpl(s, xy, desc, /*scales=*/nullptr, n_keypoints,
                              width, height, fx, fy, cx, cy, pose_qwxyz,
                              pose_t, /*extract_ms=*/0.0, out_frame_id);
}

// [REMOVE-FRAME 2026-07-20] 用户删照片 → 撤回该帧的全部重建贡献。
// 用户签决:"照片删了,那数据也必须删了"(拍虚/有人经过的照片产生的不良点云
// 本来就该被纠正)。三步全部是 COLMAP 现成操作,本函数只做转发,零算法。
aether_sfm_result_t aether_sfm_remove_frame(aether_sfm_session_t* s,
                                            int frame_id, char* out_json,
                                            int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    // frame_id 是 add_frame 返回的序号 = s->frames 下标。
    if (frame_id < 0 || frame_id >= static_cast<int>(s->frames.size())) {
      return AETHER_SFM_ERR_INVALID_ARG;
    }
    const colmap::image_t image_id = s->frames[frame_id].image_id;
    if (image_id == 0) return AETHER_SFM_ERR_INVALID_ARG;
    // [WRITE-AHEAD 2026-08-04] Durably record the withdrawal BEFORE any
    // destructive step. The snapshot write is the only fallible part of this
    // function, and it used to run last — after the reconstruction had been
    // de-registered and the db matches deleted. A failure there (or a kill in
    // that window) left the sidecar claiming the frame was still active while
    // its geometry was already gone, so recovery resurrected a deleted photo.
    // Marking first is the safe direction: if the destructive half is
    // interrupted, the frame stays withdrawn and the leftover match rows are
    // inert (the frame is excluded from every candidate and rematch path).
    if (!PersistArkitPoseSnapshotWithWithdrawal(*s, frame_id)) {
      LOG(WARNING) << "[aether_sfm] remove_frame aborted: could not persist the "
                      "withdrawal marker for frame " << frame_id;
      return AETHER_SFM_ERR_INTERNAL;
    }
    // Keep the portable visual-retrieval state consistent with the production
    // frame lifecycle. Existing call-site checks remain defense in depth, but
    // a removed frame is no longer scored or returned by the index itself.
    s->visual_loop_index.RemoveFrame(frame_id);
    TailCacheMarkDirty(s,
                       aether::sfm::TailCacheDirtyReasonV1::kRemoveFrame);

    size_t removed_obs = 0, deleted_points = 0, cleared_pairs = 0;

    // ① 重建侧:ObservationManager::DeRegisterFrame 一次做完撤观测 + 删孤儿点
    //    (track 只剩 2 元时整点删除,见 observation_manager.h 的文档)+ 维护
    //    correspondence-graph 可见计数 + 取消注册。图以 trivial rig 加入,
    //    frame_id == image_id(见 AddImageWithTrivialFrame 处注释)。
    if (s->live_recon && s->live_recon_ready) {
      const size_t pts_before = s->live_recon->NumPoints3D();
      const colmap::frame_t fid = static_cast<colmap::frame_t>(image_id);
      if (s->live_recon->ExistsFrame(fid) &&
          s->live_recon->Frame(fid).HasPose()) {
        if (s->live_recon->ExistsImage(image_id)) {
          removed_obs = s->live_recon->Image(image_id).NumPoints3D();
        }
        colmap::ObservationManager obs_mgr(*s->live_recon);
        obs_mgr.DeRegisterFrame(fid);
      }
      const size_t pts_after = s->live_recon->NumPoints3D();
      deleted_points = pts_before > pts_after ? pts_before - pts_after : 0;
      // reg_order 是窗口 BA 的输入,必须同步剔除,否则窗口会引用已注销帧。
      s->reg_order.erase(
          std::remove(s->reg_order.begin(), s->reg_order.end(), image_id),
          s->reg_order.end());
    }

    // ② db 侧:COLMAP 没有"删单张图"接口(只有 ClearImages 清空全部),
    //    官方支持的等价做法是把它孤立 —— 删掉所有涉及它的配对,任何 db 驱动
    //    的重建(断点续跑 / refine 失败的 full-rerun 兜底)都无法再注册它。
    //    图行留着但完全惰性;不写任何裸 SQL。
    if (s->db) {
      for (const auto& other : s->frames) {
        if (other.image_id == 0 || other.image_id == image_id) continue;
        const colmap::image_t a = image_id, b = other.image_id;
        // ExistsMatches 有,但没有对应的 ExistsTwoViewGeometry 查询接口;
        // DeleteTwoViewGeometry 是 SQL DELETE,对不存在的行本就是空操作,
        // 无条件调用即可。cleared_pairs 只统计确实存在过的原始匹配对。
        if (s->db->ExistsMatches(a, b)) {
          s->db->DeleteMatches(a, b);
          ++cleared_pairs;
        }
        s->db->DeleteTwoViewGeometry(a, b);
      }
    }

    // ③ 先使该帧的设备端描述子失效，再释放 host storage。这样相同
    //    frame ordinal 不会在撤回后继续命中旧的 Metal buffer。
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
    if (aether_gpu_match_descriptor_residency_invalidate != nullptr &&
        s->descriptor_residency_nonce != 0) {
      aether_gpu_match_descriptor_residency_invalidate(
          s->descriptor_residency_nonce, static_cast<uint32_t>(frame_id));
    }
#endif

    // ④ 标记该帧已撤回,后续 add_frame 的候选选择不得再选它。
    s->frames[frame_id].image_id = 0;
    s->frames[frame_id].descriptors.clear();
    s->frames[frame_id].descriptors.shrink_to_fit();
    s->frames[frame_id].points.clear();
    s->frames[frame_id].points.shrink_to_fit();
    s->frames[frame_id].n_keypoints = 0;
    // The withdrawal marker is already durable (write-ahead at the top of this
    // function) and the in-memory mutation above reproduces exactly what that
    // snapshot recorded, so there is deliberately no second persist here — a
    // failure at this point would have nothing left to roll back.

    if (out_json && out_cap > 0) {
      std::snprintf(
          out_json, static_cast<size_t>(out_cap),
          "{\"removed_obs\":%zu,\"deleted_points\":%zu,\"cleared_pairs\":%zu,"
          "\"n_registered\":%zu,\"n_points3d\":%zu}",
          removed_obs, deleted_points, cleared_pairs,
          s->live_recon ? s->live_recon->NumRegImages() : 0,
          s->live_recon ? s->live_recon->NumPoints3D() : 0);
    }
    return AETHER_SFM_OK;
  } catch (const std::exception& e) {
    LOG(WARNING) << "[aether_sfm] remove_frame failed: " << e.what();
    return AETHER_SFM_ERR_INTERNAL;
  } catch (...) {
    return AETHER_SFM_ERR_INTERNAL;
  }
}

aether_sfm_result_t aether_sfm_finalize(aether_sfm_session_t* s, char* out_json,
                                        int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    TailCacheMarkDirty(
        s, aether::sfm::TailCacheDirtyReasonV1::kFinalizeMove);
    if (!RebuildFrameRecordsForResume(s) || !s->live_recon_ready ||
        !s->live_recon || s->live_recon->NumRegImages() < 2 ||
        s->live_recon->NumPoints3D() == 0) {
      return AETHER_SFM_ERR_NOT_REGISTERED;
    }
    const double t0 = NowMs();
    std::shared_ptr<colmap::Reconstruction> work = std::move(s->live_recon);
    s->live_recon_ready = false;
    work->UpdatePoint3DErrors();
    // The same known-pose refinement used by the async production route. It
    // may triangulate and optimize, but it never calls RegisterNextImage or a
    // P3P-based absolute-pose solver.
    RefineGlobalBA(s, std::move(work), /*live_reuse=*/true);
    std::shared_ptr<const colmap::Reconstruction> recon;
    {
      std::lock_guard<std::mutex> lock(s->recon_mutex);
      recon = s->recon;
    }
    if (!recon || s->finalize_status.load() != 2) {
      return AETHER_SFM_ERR_NOT_REGISTERED;
    }
    if (out_json && out_cap > 0) {
      std::snprintf(out_json, out_cap,
                    "{\"solve_ms\":%.1f,\"n_models\":1,"
                    "\"n_registered\":%zu,\"n_points3d\":%zu,"
                    "\"reproj_px\":%.4f,\"track_len\":%.3f,"
                    "\"phase1\":\"mandatory_arkit_reuse\"}",
                    NowMs() - t0, recon->NumRegImages(), recon->NumPoints3D(),
                    recon->ComputeMeanReprojectionError(),
                    recon->ComputeMeanTrackLength());
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
// RESUME sessions must restore the mandatory ARKit pose snapshot and rebuild a
// registered live model. Missing or invalid pose identity blocks explicitly;
// the historical db-driven P3P reconstruction fallback is forbidden.
aether_sfm_result_t aether_sfm_finalize_async(aether_sfm_session_t* s,
                                              char* out_json, int out_cap) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  if (s->refine_thread.joinable()) s->refine_thread.join();  // drain prior run
  try {
    TailCacheMarkDirty(
        s, aether::sfm::TailCacheDirtyReasonV1::kFinalizeMove);
    const double t_enter = NowMs();
    if (!RebuildFrameRecordsForResume(s)) {
      s->finalize_status.store(3);
      return AETHER_SFM_ERR_NOT_REGISTERED;
    }

    // ── Normal completion path: live recon in memory → reuse it. ──
    // A degenerate restored model is blocked. It must never be repaired by
    // silently discarding the mandatory ARKit pose contract.
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
    if (s->live_recon_ready && s->live_recon &&
        s->live_recon->NumRegImages() >= 2 &&
        s->live_recon->NumPoints3D() > 0) {
      TailCacheMarkDirty(
          s, aether::sfm::TailCacheDirtyReasonV1::kFinalizeMove);
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
    s->finalize_status.store(3);
    return AETHER_SFM_ERR_NOT_REGISTERED;
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

// [DELIVER-TRI-ANGLE 2026-08-05 用户签决"3°签装机"] 交付层视差角过滤。
// 现象:成品 3D viewer 里主体外围一圈散点壳(cap_1785934283657550 实测壳带
// 1.3-2.0m 占 9.46%)。逐点元数据实测(host 重放,201 帧):三个候选判据里
// 只有"track 内最大成对视差角"有判别力(AUC 0.647;track 长度 0.326 反向、
// 重投影误差 0.456 无信号,SOR/半径滤波已判死——壳自撑 k=20 邻域)。
// 阈值 3.0° 不是本项目自标定:AliceVision 官方默认 minAngleForTriangulation
// =3.0°,OpenMVG 硬编码 2.0°,RC 的 ill flag("apical angle is smaller than
// a minimal requirement")同口径。两臂真彩并排页用户肉眼终审后签 3°。
// 语义:纯交付层(显示层≠求解层,同 08-04 AR 稳定性裁决)——只影响
// s->recon 的两个 finalize 导出口(get_points / get_points_tracked);
// points3D、BA、流式路径、live 预览(previewTracked sibling)、DB、resume
// 一概不动。回滚 = env 设 0 或删本块。
// ⚠️ 与"全量交付铁律"(ghost-mask 注释/feedback_no_downsampled_pointcloud_
// delivery)的关系:该铁律禁的是降采样/性能性删点;本过滤是用户签决的质量
// 性交付口径(RC/Metashape/COLMAP GUI 同做法)。若未来重开 GHOST_MASK
// (E25-C 已停用),其 flag 序按全量模型枚举,与过滤后交付序不对齐,须一并改。
double DeliverMinTriAngleDeg() {
  static const double cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_DELIVER_MIN_TRI_ANGLE");
    if (e && e[0]) return std::atof(e);  // <=0 关闭过滤
    return 3.0;
  }();
  return cached;
}

// 判定:track 内任意两个观测相机对该点的夹角(顶角)达到阈值即通过。
// min_cos = cos(阈值);夹角越大 cos 越小,所以判据是 dot <= min_cos。
// 有效观测 <2(理论不该存在)按不通过处理——与标定用的 python 口径一致。
static bool DeliverPointPassesTriAngle(const colmap::Reconstruction& recon,
                                       const colmap::Point3D& point,
                                       double min_cos) {
  // track 长度 p50=2、p90=5,栈上小缓冲足够;超长 track 截断到 32 个观测
  // (夹角最大的对极大概率已在其中;截断只可能漏杀不会误杀)。
  constexpr int kMaxObs = 32;
  Eigen::Vector3d dirs[kMaxObs];
  int k = 0;
  for (const auto& el : point.track.Elements()) {
    if (k >= kMaxObs) break;
    if (!recon.ExistsImage(el.image_id)) continue;
    const auto& image = recon.Image(el.image_id);
    if (!image.HasPose()) continue;
    const Eigen::Vector3d v = image.ProjectionCenter() - point.xyz;
    const double norm = v.norm();
    if (!(norm > 0.0)) continue;
    dirs[k++] = v / norm;
  }
  if (k < 2) return false;
  for (int i = 0; i < k; ++i) {
    for (int j = i + 1; j < k; ++j) {
      if (dirs[i].dot(dirs[j]) <= min_cos) return true;  // 早退:一对够开即过
    }
  }
  return false;
}

// [MIRROR-GHOST V1 2026-08-06 用户网页并排批准] 反光地板镜像鬼点过滤,算法
// 单一事实源在 official_mirror_ghost.h(host parity 工具与产品共用同一份头,
// cap5 逐点 52/52 一致)。跑在视差角过滤幸存者上,与两个交付入口同口径。
// 开关:OFFICIAL_AETHER_MIRROR_GHOST=0 关闭。
bool MirrorGhostEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_MIRROR_GHOST");
    return !(e && e[0] == '0');
  }();
  return cached;
}

// 视差角幸存者集合上算判虚 point_id 集;date 每次交付调用重算(与视差角
// 过滤同一"无状态、同口径"契约:count-only 与全量必然一致)。
std::unordered_set<colmap::point3D_t> MirrorGhostKillSet(
    aether_sfm_session* s, const colmap::Reconstruction& recon, bool filter_on,
    double min_cos) {
  std::unordered_set<colmap::point3D_t> killed;
  if (!MirrorGhostEnabled()) return killed;
  const auto& pts = recon.Points3D();
  std::vector<aether_mirror_ghost::P3> mp;
  std::vector<colmap::point3D_t> ids;
  mp.reserve(pts.size());
  ids.reserve(pts.size());
  for (const auto& [pid, point] : pts) {
    if (filter_on && !DeliverPointPassesTriAngle(recon, point, min_cos)) {
      continue;
    }
    mp.push_back({static_cast<float>(point.xyz.x()),
                  static_cast<float>(point.xyz.y()),
                  static_cast<float>(point.xyz.z())});
    ids.push_back(pid);
  }
  const auto res = aether_mirror_ghost::Detect(mp);
  for (const uint32_t i : res.kill) killed.insert(ids[i]);
  const int nk = static_cast<int>(killed.size());
  if (s && nk != s->stat_mirror_ghost_logged) {
    s->stat_mirror_ghost_logged = nk;
    char line[256];
    std::snprintf(line, sizeof(line),
                  "{\"t\":%lld,\"type\":\"mirror_ghost_summary\",\"floor_y\":%.3f,"
                  "\"candidates\":%d,\"clusters\":%d,\"killed_clusters\":%d,"
                  "\"killed\":%d}",
                  static_cast<long long>(NowMs()), res.floor_y, res.candidates,
                  res.clusters, res.killed_clusters, nk);
    AppendMatchFailJsonl(s, line);
  }
  return killed;
}

// [ISOLATED-FLOATER 2026-08-07 用户签决装机] 孤立浮点过滤(最强安全版),算法
// 单一事实源在 official_isolated_floater.h(host parity 工具与产品共用同一份
// 头)。与镜像鬼点并列的第二把交付层刀:同样只跑在视差角幸存者上,两把刀的
// kill 集取并,在 get_points / get_points_tracked 两个入口同口径生效。
// 开关:OFFICIAL_AETHER_ISOLATED_FLOATER=0 关闭。
bool IsolatedFloaterEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ISOLATED_FLOATER");
    return !(e && e[0] == '0');
  }();
  return cached;
}

// 视差角幸存者集合上算判浮 point_id 集。每个点还要一条"平均视线":遍历
// track 的 image_id → recon.Image(id).ProjectionCenter() → 单位化 (C − X)
// 求均值再单位化。无有效观测 ⇒ 零向量,该点 cos 记 0(fail-safe:算不出
// 方向就不按方向删)。注意这里**不做** DeliverPointPassesTriAngle 的 32 观测
// 截断 —— 那个截断只是视差角判据的早退优化,平均视线要用全部观测。
std::unordered_set<colmap::point3D_t> IsolatedFloaterKillSet(
    aether_sfm_session* s, const colmap::Reconstruction& recon, bool filter_on,
    double min_cos) {
  std::unordered_set<colmap::point3D_t> killed;
  if (!IsolatedFloaterEnabled()) return killed;
  const auto& pts = recon.Points3D();
  std::vector<aether_isolated_floater::P3> mp, vd;
  std::vector<colmap::point3D_t> ids;
  mp.reserve(pts.size());
  vd.reserve(pts.size());
  ids.reserve(pts.size());
  for (const auto& [pid, point] : pts) {
    if (filter_on && !DeliverPointPassesTriAngle(recon, point, min_cos)) {
      continue;
    }
    Eigen::Vector3d acc = Eigen::Vector3d::Zero();
    for (const auto& el : point.track.Elements()) {
      if (!recon.ExistsImage(el.image_id)) continue;
      const auto& image = recon.Image(el.image_id);
      if (!image.HasPose()) continue;
      const Eigen::Vector3d v = image.ProjectionCenter() - point.xyz;
      const double nrm = v.norm();
      if (!(nrm > 0.0)) continue;
      acc += v / nrm;
    }
    const double an = acc.norm();
    aether_isolated_floater::P3 dir{0.0f, 0.0f, 0.0f};
    if (an > 0.0) {
      dir = {static_cast<float>(acc.x() / an), static_cast<float>(acc.y() / an),
             static_cast<float>(acc.z() / an)};
    }
    mp.push_back({static_cast<float>(point.xyz.x()),
                  static_cast<float>(point.xyz.y()),
                  static_cast<float>(point.xyz.z())});
    vd.push_back(dir);
    ids.push_back(pid);
  }
  const auto res = aether_isolated_floater::Detect(mp, vd);
  for (const uint32_t i : res.kill) killed.insert(ids[i]);
  const int nk = static_cast<int>(killed.size());
  if (s && nk != s->stat_isolated_floater_logged) {
    s->stat_isolated_floater_logged = nk;
    char line[256];
    std::snprintf(line, sizeof(line),
                  "{\"t\":%lld,\"type\":\"isolated_floater_summary\","
                  "\"eps\":%.6f,\"main\":%d,\"clusters\":%d,"
                  "\"killed_clusters\":%d,\"killed\":%d}",
                  static_cast<long long>(NowMs()), res.eps, res.main_size,
                  res.clusters, res.killed_clusters, nk);
    AppendMatchFailJsonl(s, line);
  }
  return killed;
}

// 两把交付层刀的 kill 集取并(get_points / get_points_tracked 共用,保证
// 两个入口 count-only 与全量四处完全同口径)。
std::unordered_set<colmap::point3D_t> DeliverKillSet(
    aether_sfm_session* s, const colmap::Reconstruction& recon, bool filter_on,
    double min_cos, int* out_mg, int* out_if) {
  auto kill = MirrorGhostKillSet(s, recon, filter_on, min_cos);
  if (out_mg) *out_mg = static_cast<int>(kill.size());
  const auto fl = IsolatedFloaterKillSet(s, recon, filter_on, min_cos);
  if (out_if) *out_if = static_cast<int>(fl.size());
  kill.insert(fl.begin(), fl.end());
  return kill;
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

  // [DELIVER-TRI-ANGLE] 交付层过滤;count-only 与全量查询必须同口径。
  const double thr_deg = DeliverMinTriAngleDeg();
  const bool filter_on = thr_deg > 0.0;
  const double min_cos = std::cos(thr_deg * M_PI / 180.0);
  int n_mg = 0, n_if = 0;
  const auto mg_kill = DeliverKillSet(s, *recon, filter_on, min_cos, &n_mg, &n_if);

  int n = 0;
  for (const auto& [point_id, point] : pts) {
    if ((!filter_on || DeliverPointPassesTriAngle(*recon, point, min_cos)) &&
        !mg_kill.count(point_id)) {
      ++n;
    }
  }
  *out_count = n;
  if (!out_points) return AETHER_SFM_OK;  // count-only query

  auto* arr = static_cast<aether_sfm_point_t*>(
      std::malloc(static_cast<size_t>(n) * sizeof(aether_sfm_point_t)));
  if (!arr && n > 0) return AETHER_SFM_ERR_INTERNAL;
  int i = 0;
  for (const auto& [point_id, point] : pts) {
    if (filter_on && !DeliverPointPassesTriAngle(*recon, point, min_cos)) {
      continue;
    }
    if (mg_kill.count(point_id)) continue;
    aether_sfm_point_t& o = arr[i++];
    o.x = static_cast<float>(point.xyz.x());
    o.y = static_cast<float>(point.xyz.y());
    o.z = static_cast<float>(point.xyz.z());
    o.r = point.color(0);
    o.g = point.color(1);
    o.b = point.color(2);
    o._pad[0] = o._pad[1] = 0;
  }
  if (filter_on || !mg_kill.empty()) {
    LOG(WARNING) << "[aether_sfm] deliver-filter(get_points): kept " << n
                 << "/" << pts.size() << " (min_tri_angle=" << thr_deg
                 << "deg, mirror_ghost=" << n_mg << ", isolated_floater=" << n_if
                 << ", killed_union=" << mg_kill.size() << ")";
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

  // [DELIVER-TRI-ANGLE] 交付层过滤;与 get_points 完全同口径。
  const double thr_deg = DeliverMinTriAngleDeg();
  const bool filter_on = thr_deg > 0.0;
  const double min_cos = std::cos(thr_deg * M_PI / 180.0);
  int n_mg = 0, n_if = 0;
  const auto mg_kill = DeliverKillSet(s, *recon, filter_on, min_cos, &n_mg, &n_if);

  int n = 0;
  int64_t total_obs = 0;
  for (const auto& [point_id, point] : pts) {
    if (filter_on && !DeliverPointPassesTriAngle(*recon, point, min_cos)) {
      continue;
    }
    if (mg_kill.count(point_id)) continue;
    ++n;
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
    if (filter_on && !DeliverPointPassesTriAngle(*recon, point, min_cos)) {
      continue;
    }
    if (mg_kill.count(point_id)) continue;
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
  if (filter_on || !mg_kill.empty()) {
    LOG(WARNING) << "[aether_sfm] deliver-filter(get_points_tracked): kept "
                 << n << "/" << pts.size() << " (min_tri_angle=" << thr_deg
                 << "deg, mirror_ghost=" << n_mg << ", isolated_floater=" << n_if
                 << ", killed_union=" << mg_kill.size() << ")";
  }
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

// Official COLMAP iterative global refinement over the streaming model.
// This is the inner solver used by the RS-style V20 / +10% outer schedule:
// CompleteAndMergeTracks, Retriangulate, global BA, point filtering, and frame
// filtering use the pinned COLMAP implementation and defaults. Per-image ARKit
// [A1B-ASYNC-PVBA 2026-07-27, experiment arm, DEFAULT OFF] Async preview BA.
// Provenance: [调查 lever A1b] the streaming-BA publish is a SERIAL
// checkpoint inside the worker's frame event and its cost is superlinear in
// registered poses (measured 495ms@20 → 9.5s@140 → 15.7s@145; ~40s
// extrapolated at 300 frames — the single blocker for the signed 20-300
// frame range). This arm keeps the SAME BA (same DatabaseCache options,
// same IterativeGlobalRefinement arguments) but runs it on a SNAPSHOT COPY
// on a background thread; the worker merges the refined result back at the
// next publish trigger (poses for frames both sides know, xyz for point ids
// both sides know — ids created/deleted by either side are left alone to
// avoid id-collision hazards; finalize re-derives everything anyway).
// Classification: NOISE-BAND (the live model receives each global
// refinement a few frames late = shifted linearization points) — ships only
// through the host matrix + sign-off, like every arm before it.
//   OFFICIAL_AETHER_ASYNC_PREVIEW_BA=1        master switch (default OFF)
//   OFFICIAL_AETHER_ASYNC_PREVIEW_BA_THREADS  bg ceres threads (default 2 —
//                                             the worker keeps feeding)
bool AsyncPreviewBaEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ASYNC_PREVIEW_BA");
    return e && e[0] == '1';
  }();
  return cached;
}
int AsyncPreviewBaThreads() {
  static const int cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_ASYNC_PREVIEW_BA_THREADS");
    const int v = e ? std::atoi(e) : 2;
    return v > 0 ? v : 2;
  }();
  return cached;
}
// [A1B-V5] Propagate / cadence knobs are defined earlier in this TU (next to
// TriIgnoreTwoViewTracks) because the finalize apvba_summary emit needs them.

// [A1B-V2 WHOLESALE 2026-07-27] Worker-side harvest, whole-model variant.
//
// The v1 field-merge (adopt poses + xyz for ids both sides know) was killed
// by its own matrix: it silently DISCARDED the background pass's deletion
// decisions (FilterFrames / FilterPoints), so the live model kept growing on
// frames the BA had already judged dead — cap3_eve delivered -5.65%/-6.33%
// points against a 0.059% noise band, and the arm's own repeatability
// (B<->B2 2.9% on 3+-view tracks) was worse than the band it had to fit in.
//
// This variant ADOPTS THE REFINED MODEL WHOLESALE — every BA decision,
// deletions included — and then re-registers the frames the worker accepted
// while the background pass was running, through the SAME official path
// add_frame uses (per-image PINHOLE + trivial rig, AddImageWithTrivialFrame
// with the ARKit pose, then IncrementalMapper::TriangulateImage over the db
// matches). Nothing is hand-merged; the post-snapshot frames are simply
// replayed onto the refined model exactly as they were first registered.
// Their point ids are re-issued, which is fine: nothing outside the live
// model keys on them (the finalize provenance census is telemetry).
bool AdoptAsyncPreviewRefinement(aether_sfm_session* s,
                                 std::shared_ptr<colmap::Reconstruction> refined,
                                 int snapshot_nframes) {
  if (!refined) return false;
  const int n_now = static_cast<int>(s->frames.size());
  // 1) Wholesale adopt (the whole point of this variant).
  TailCacheMarkDirty(
      s, aether::sfm::TailCacheDirtyReasonV1::kModelReplacement);
  s->live_recon = std::move(refined);
  if (snapshot_nframes >= n_now) return true;  // nothing to replay
  // [A1B-V4] Correction propagation (ORB-SLAM2's merge rule, adapted).
  //
  // The background pass moved the frames it optimized; the frames accepted
  // while it ran still carry their raw ARKit poses. Replaying them as-is
  // (v2/v3) leaves a SEAM: one side of the model is BA-corrected, the other
  // is not, so their relative geometry is wrong by exactly the correction.
  // ORB-SLAM2 solves this by "propagating the correction of updated
  // keyframes (i.e. the transformation from the non-optimized to the
  // optimized pose) to non-updated keyframes"; the reference is the
  // spanning-tree parent (max shared observations), which in a sequential
  // K-window capture is simply the newest frame the pass did optimize.
  //
  // Algebra (colmap Rigid3d, cam_from_world, A*B = apply B then A):
  //   reference r has C_old (pre-BA) and C_new (post-BA)
  //   world_new_from_world_old  S = C_new^-1 * C_old
  //   a new frame's corrected pose  C' = C * S^-1 = C * (C_old^-1 * C_new)
  // Sanity: substituting the reference itself gives C_old * C_old^-1 * C_new
  // = C_new, as it must.
  std::optional<colmap::Rigid3d> world_old_from_world_new;
  for (int i = AsyncPreviewBaPropagate() ? snapshot_nframes - 1 : -1; i >= 0;
       --i) {
    const colmap::frame_t fid = static_cast<colmap::frame_t>(
        s->frames[i].image_id);  // trivial frames: frame_id == image_id
    const auto snap_it = s->apvba_snapshot_poses.find(fid);
    if (snap_it == s->apvba_snapshot_poses.end()) continue;
    if (!s->live_recon->ExistsFrame(fid)) continue;  // filtered by the BA
    const colmap::Frame& refined_ref = s->live_recon->Frame(fid);
    if (!refined_ref.HasPose()) continue;
    world_old_from_world_new =
        colmap::Inverse(snap_it->second) * refined_ref.RigFromWorld();
    const Eigen::Vector3d t = world_old_from_world_new->translation();
    s->stat_apvba_last_corr_mm = t.norm() * 1000.0;
    const double qw = std::abs(world_old_from_world_new->rotation().w());
    s->stat_apvba_last_corr_deg =
        2.0 * std::acos(std::min(1.0, qw)) * 180.0 / M_PI;
    break;
  }
  // 2) Replay the frames accepted during the background pass.
  std::vector<colmap::image_t> replayed;
  replayed.reserve(static_cast<size_t>(n_now - snapshot_nframes));
  for (int i = snapshot_nframes; i < n_now; ++i) {
    const FrameRecord& rec = s->frames[i];
    if (!rec.has_pose || rec.image_id == 0) continue;
    if (s->live_recon->ExistsImage(rec.image_id)) continue;
    s->live_recon->AddCameraWithTrivialRig(rec.camera);
    colmap::Image rimg;
    rimg.SetImageId(rec.image_id);
    char name[64];
    std::snprintf(name, sizeof(name), "frame_%06d.jpg", rec.frame_id);
    rimg.SetName(name);
    rimg.SetCameraId(rec.camera_id);
    rimg.SetPoints2D(rec.points);
    // [A1B-V4] The ARKit pose carried into the BA's corrected world frame.
    // Without this the frame lands in the pre-BA frame and the seam is the
    // whole error. s->frames keeps the RAW ARKit prior untouched — it is the
    // candidate-selection and gravity-align record, not a model pose.
    const colmap::Rigid3d pose =
        world_old_from_world_new
            ? rec.cam_from_world * (*world_old_from_world_new)
            : rec.cam_from_world;
    s->live_recon->AddImageWithTrivialFrame(std::move(rimg), pose);
    replayed.push_back(rec.image_id);
  }
  if (replayed.empty()) return true;
  // 3) Official triangulation for the replayed frames (one mapper pass; the
  //    matches are already in the db, so this is the same work add_frame did).
  colmap::DatabaseCache::Options cache_options;
  cache_options.min_num_matches = 15;
  cache_options.load_all_images = true;
  auto cache = colmap::DatabaseCache::Create(*s->db, cache_options);
  colmap::IncrementalPipelineOptions official_options;
  official_options.min_num_matches = 15;
  official_options.triangulation.ignore_two_view_tracks =
      TriIgnoreTwoViewTracks();
  official_options.load_all_images = true;
  ApplyBirthGateAB(&official_options);  // [BIRTH-GATE-AB 2026-08-07]
  colmap::IncrementalMapper mapper(cache);
  mapper.BeginReconstruction(s->live_recon);
  for (const colmap::image_t image_id : replayed) {
    mapper.TriangulateImage(official_options.Triangulation(), image_id);
  }
  mapper.EndReconstruction(/*discard=*/false);
  return true;
}

#if defined(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)
// Host replay only. This symbol is intentionally absent from every default
// and device build. It drives the real production invalidation paths without
// mutating the source fixture, so the next bundle read must rebuild from the
// session DB and can be compared with the fresh oracle.
int aether_sfm_test_tail_cache_inject_v1(aether_sfm_session_t* s, int kind) {
  if (!s || !TailCacheActive()) return -1;
  if (kind == 1) {  // overwrite an already-seen pair
    colmap::image_pair_t pair_id = 0;
    {
      std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
      if (s->tail_cache_seen_db_pairs.empty()) return -2;
      pair_id = *s->tail_cache_seen_db_pairs.begin();
    }
    const auto [image1, image2] = colmap::PairIdToImagePair(pair_id);
    return TailCacheBeginPairWrite(s, image1, image2) ? -3 : 0;
  }
  if (kind == 2) {  // admit a previously unseen pair as a late write
    colmap::image_t image1 = 0;
    colmap::image_t image2 = 0;
    {
      std::lock_guard<std::mutex> lock(s->tail_cache_mutex);
      for (size_t i = 0; i < s->frames.size() && image1 == 0; ++i) {
        for (size_t j = i + 1; j < s->frames.size(); ++j) {
          const colmap::image_t a = s->frames[i].image_id;
          const colmap::image_t b = s->frames[j].image_id;
          if (a == 0 || b == 0 || a == b) continue;
          const colmap::image_pair_t candidate =
              colmap::ImagePairToPairId(a, b);
          if (s->tail_cache_seen_db_pairs.count(candidate) == 0) {
            image1 = a;
            image2 = b;
            break;
          }
        }
      }
    }
    if (image1 == 0 || image2 == 0) return -4;
    return TailCacheBeginPairWrite(s, image1, image2,
                                   /*late_write=*/true)
               ? 0
               : -5;
  }
  if (kind == 3) {  // exercise the real wholesale model-adoption path
    if (!s->live_recon) return -6;
    auto exact_copy =
        std::make_shared<colmap::Reconstruction>(*s->live_recon);
    return AdoptAsyncPreviewRefinement(
               s, std::move(exact_copy), static_cast<int>(s->frames.size()))
               ? 0
               : -7;
  }
  if (kind == 4) {  // exercise the shared production exception-retry path
    TailCacheMarkDirty(
        s, aether::sfm::TailCacheDirtyReasonV1::kExceptionRetry);
    return 0;
  }
  return -8;
}
#endif  // AETHER_TAIL_CACHE_FAULT_TEST_HOOKS

aether_sfm_result_t AsyncPreviewBaTick(aether_sfm_session_t* s) {
  // 1) HARVEST a finished background run (worker thread owns live_recon, so
  //    the merge is race-free by construction).
  bool merged = false;
  if (s->async_pvba_done.load(std::memory_order_acquire)) {
    std::shared_ptr<colmap::Reconstruction> refined;
    {
      std::lock_guard<std::mutex> lk(s->async_pvba_mutex);
      refined.swap(s->async_pvba_result);
    }
    if (s->async_pvba_thread.joinable()) s->async_pvba_thread.join();
    s->async_pvba_done.store(false, std::memory_order_relaxed);
    s->async_pvba_running.store(false, std::memory_order_relaxed);
    if (refined) {
      const double t_m = NowMs();
      try {
        merged = AdoptAsyncPreviewRefinement(s, std::move(refined),
                                             s->apvba_snapshot_nframes);
      } catch (...) {
        // Adoption failed mid-replay: the live model may be the refined one
        // without its replayed frames — those frames' matches are all in the
        // db, so finalize still sees them; count it and carry on.
        merged = false;
      }
      s->stat_apvba_merge_ms_total += NowMs() - t_m;
      if (merged) {
        ++s->stat_apvba_merges;
        s->apvba_consecutive_drops = 0;
        // [A1B-V5] A successful harvest publishes, which resets the Dart
        // publish policy's growth baselines — that is exactly the moment the
        // sync arm would be allowed to start its next BA.
        s->apvba_kick_armed = true;
      } else {
        ++s->stat_apvba_dropped;
        ++s->apvba_consecutive_drops;
      }
    } else {
      ++s->stat_apvba_dropped;
      ++s->apvba_consecutive_drops;
    }
    // [A1B-V3] Back off after repeated drops instead of re-kicking every
    // frame: 2 consecutive drops ⇒ skip the next 2 kick opportunities, 3+ ⇒
    // skip 4. Breaks v2's failure→retry→contention→failure loop.
    if (s->apvba_consecutive_drops >= 3) {
      s->apvba_skip_kicks = 4;
    } else if (s->apvba_consecutive_drops == 2) {
      s->apvba_skip_kicks = 2;
    }
  }
  // 2) KICK a fresh run when idle: snapshot copy on the worker, solve on a
  //    background thread with its OWN db read connection (WAL concurrent
  //    reads are safe against the worker's writes).
  if (s->apvba_skip_kicks > 0) {
    --s->apvba_skip_kicks;  // [A1B-V3] backoff window
  } else if (AsyncPreviewBaMatchCadence() && !s->apvba_kick_armed) {
    // [A1B-V5] cadence-matched: one background pass per publish, no more.
  } else if (!s->async_pvba_running.load(std::memory_order_relaxed)) {
    try {
      const double t_c = NowMs();
      auto snap_model =
          std::make_shared<colmap::Reconstruction>(*s->live_recon);
      s->stat_apvba_copy_ms_total += NowMs() - t_c;
      // [A1B-V2] Frames present at snapshot time; anything accepted after
      // this index is replayed onto the refined model at harvest.
      s->apvba_snapshot_nframes = static_cast<int>(s->frames.size());
      // [A1B-V4] Pre-BA poses for the correction propagation at harvest.
      s->apvba_snapshot_poses.clear();
      for (const auto& [fid, frame] : snap_model->Frames()) {
        if (frame.HasPose()) s->apvba_snapshot_poses[fid] = frame.RigFromWorld();
      }
      s->async_pvba_running.store(true, std::memory_order_relaxed);
      s->apvba_kick_armed = false;  // [A1B-V5] consumed by this kick
      ++s->stat_apvba_kicks;
      // [A1B-V3 2026-07-27] The cache is built HERE, on the worker, from the
      // worker's own db connection — the background thread never touches
      // sqlite. v2 had it call Database::Open itself and the resulting lock
      // contention with the worker's writes silently ate 4 frames
      // (add_frame_features ... ERR_INTERNAL), which is a P0 against
      // "采集必出点云". Build cost is the finalize-measured cache_pre
      // (19-52 ms) and it is serialized with add_frame by construction.
      colmap::DatabaseCache::Options kick_cache_options;
      kick_cache_options.min_num_matches = 15;
      kick_cache_options.load_all_images = true;
      auto kick_cache = colmap::DatabaseCache::Create(*s->db,
                                                      kick_cache_options);
      s->async_pvba_thread = std::thread([s, snap_model, kick_cache] {
#if defined(__APPLE__)
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
        const double t0 = NowMs();
        try {
          auto cache = kick_cache;
          colmap::IncrementalPipelineOptions official_options;
          official_options.min_num_matches = 15;
          official_options.triangulation.ignore_two_view_tracks =
              TriIgnoreTwoViewTracks();
          official_options.load_all_images = true;
          official_options.ba_refine_focal_length = false;
          official_options.ba_refine_principal_point = false;
          official_options.ba_refine_extra_params = false;
          official_options.mapper.ba_local_num_images = 6;
          official_options.mapper.ba_global_ignore_redundant_points3D = true;
          ApplyBirthGateAB(&official_options);  // [BIRTH-GATE-AB 2026-08-07]
          auto ba_opts = official_options.GlobalBundleAdjustment();
          if (ba_opts.ceres) {
            ba_opts.ceres->solver_options.num_threads = AsyncPreviewBaThreads();
          }
          colmap::IncrementalMapper mapper(cache);
          mapper.BeginReconstruction(snap_model);
          if (AsyncPreviewBaParamOnly()) {
            // [A1B-V6] parameters only: one official global solve, zero
            // structural mutation (see the knob's provenance comment).
            mapper.AdjustGlobalBundle(official_options.Mapper(), ba_opts);
          } else {
            mapper.IterativeGlobalRefinement(
                official_options.ba_global_max_refinements,
                official_options.ba_global_max_refinement_change,
                official_options.Mapper(), ba_opts,
                official_options.Triangulation(),
                /*normalize_reconstruction=*/false);
            mapper.FilterFrames(official_options.Mapper());
          }
          mapper.EndReconstruction(/*discard=*/false);
          snap_model->UpdatePoint3DErrors();
          {
            std::lock_guard<std::mutex> lk(s->async_pvba_mutex);
            s->async_pvba_result = snap_model;
          }
        } catch (const std::exception& e) {
          // [A1B-V3] v2 swallowed the type: 8-11 of its drops had no evidence
          // at all. Record it so a drop is diagnosable from the sidecar.
          std::lock_guard<std::mutex> lk(s->async_pvba_mutex);
          s->apvba_last_error = e.what();
        } catch (...) {
          std::lock_guard<std::mutex> lk(s->async_pvba_mutex);
          s->apvba_last_error = "(non-std exception)";
        }
        s->stat_apvba_last_ba_ms = NowMs() - t0;
        s->async_pvba_done.store(true, std::memory_order_release);
      });
    } catch (...) {
      s->async_pvba_running.store(false, std::memory_order_relaxed);
    }
  }
  if (!merged) return AETHER_SFM_ERR_NOT_REGISTERED;  // Dart: "stable cloud
                                                      // unchanged", no publish
  // 3) Republish preview_points from the merged live model (sync-path tail).
  std::vector<Eigen::Vector3d> snap;
  snap.reserve(s->live_recon->NumPoints3D());
  for (const auto& [pid, pt] : s->live_recon->Points3D()) snap.push_back(pt.xyz);
  {
    std::lock_guard<std::mutex> lk(s->preview_mutex);
    s->preview_points.swap(snap);
  }
  return AETHER_SFM_OK;
}

// PINHOLE intrinsics stay fixed; poses and 3D points remain free.
//
// Refines live_recon in place and republishes preview_points atomically. On any
// failure the previous stable AR cloud remains visible and the next frame retries.
// THREADING: like get_preview_tracked, must run on the capture worker isolate
// (mutates live_recon); the getter is called after this returns.
aether_sfm_result_t aether_sfm_global_refine(aether_sfm_session_t* s) {
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  if (!s->live_recon_ready || !s->live_recon ||
      s->live_recon->NumRegImages() < 3)
    return AETHER_SFM_ERR_NOT_REGISTERED;
  // [A1B-ASYNC-PVBA 2026-07-27] Experiment arm (default OFF): kick/harvest
  // instead of the in-line solve. Unset env ⇒ the sync body below runs
  // byte-identically.
  if (AsyncPreviewBaEnabled()) return AsyncPreviewBaTick(s);
  try {
    colmap::DatabaseCache::Options cache_options;
    cache_options.min_num_matches = 15;
    cache_options.load_all_images = true;
    auto cache = colmap::DatabaseCache::Create(*s->db, cache_options);

    colmap::IncrementalPipelineOptions official_options;
    official_options.min_num_matches = 15;
    official_options.triangulation.ignore_two_view_tracks =
        TriIgnoreTwoViewTracks();
    official_options.load_all_images = true;
    official_options.ba_refine_focal_length = false;
    official_options.ba_refine_principal_point = false;
    official_options.ba_refine_extra_params = false;
    official_options.mapper.ba_local_num_images = 6;
    // [OOM-126 2026-07-26] Upstream's own global-BA size reducer, ON for the
    // capture-time solve. IncrementalMapper::AdjustGlobalBundle (upstream
    // sfm/incremental_mapper.cc:1131-1141, 1174-1181) then splits one whole-
    // model problem into (a) a joint solve over the cameras plus only the
    // non-redundant points — FindRedundantPoints3D drops points whose
    // coverage gain is below the threshold — and (b) a second pass that
    // optimizes the dropped points alone with every other parameter fixed.
    // Nothing is discarded, so this is lossless by construction; it exists to
    // keep the joint Jacobian / Schur workspace small, which is exactly the
    // block that OOM-killed a 126-frame capture on device. Upstream gates it
    // behind >=10 registered frames (kMinNumRegFramesForFastBA), and this
    // solve only runs from 20 frames up, so the gate is always satisfied.
    official_options.mapper.ba_global_ignore_redundant_points3D = true;
    ApplyBirthGateAB(&official_options);  // [BIRTH-GATE-AB 2026-08-07]

    colmap::IncrementalMapper mapper(cache);
    mapper.BeginReconstruction(s->live_recon);
    mapper.IterativeGlobalRefinement(
        official_options.ba_global_max_refinements,
        official_options.ba_global_max_refinement_change,
        official_options.Mapper(), official_options.GlobalBundleAdjustment(),
        official_options.Triangulation(),
        /*normalize_reconstruction=*/false);
    mapper.FilterFrames(official_options.Mapper());
    mapper.EndReconstruction(/*discard=*/false);
    s->live_recon->UpdatePoint3DErrors();

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
// the pwofficial_gpu_match.mm return code (bucket 0 = out-of-range rc). Nullable.
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

// [THERMAL-THROTTLE 2026-07-11] Platform push of the ProcessInfo thermal
// bucket (0 nominal · 1 fair · 2 serious · 3 critical). The Dart worker calls
// this right before each add_frame; state >= 2 halves the live match
// candidate window (see add_frame; env OFFICIAL_AETHER_LIVE_CAND_K_HOT tunes/disables).
// Values outside [0,3] are treated as unknown and never throttle. Safe on any
// thread; no-op on a null session.
void aether_sfm_set_thermal_state(aether_sfm_session_t* s, int state) {
  if (!s) return;
  s->thermal_state.store((state >= 0 && state <= 3) ? state : -1,
                         std::memory_order_relaxed);
}

// [THERMAL-THROTTLE 2026-07-11] Telemetry: frames fed with a reduced live K
// this capture (0 = throttle never engaged). Same threading contract as
// aether_sfm_stream_stats.
void aether_sfm_thermal_throttle_stats(aether_sfm_session_t* s,
                                       int64_t* throttled_frames) {
  if (throttled_frames) *throttled_frames = s ? s->stat_thermal_throttled_frames : 0;
}

// [P1-LIVE-REPAY 2026-07-11] Capture-idle debt repayment. The worker calls
// this from the SAME thread as add_frame whenever its queue has slack (offer
// interval > processing time); the pass re-matches up to max_pairs missing
// temporal-window pairs of currently-starved frames through the SAME matcher
// route add_frame used, and persists them with the exact WriteMatches →
// EstimateTwoViewGeometry → WriteTwoViewGeometry sequence — i.e. it prepays
// the debt FinalizeRematchStarvedFrames would otherwise pay at ~410 ms/pair
// on a hot finish-time GPU (cap46: 336 pairs → 137.9 s enrichment). A healthy
// capture-time GPU pair costs ~16 ms, so repaying during idle windows is an
// order of magnitude cheaper than repaying at finalize.
//
// Rules:
//   - thermal critical (state >= 3) → refuses outright;
//   - thermal serious (state == 2) → conditional repayment:
//     [P1-REPAY-THERMAL2 2026-07-11 · PHASE-A 2026-07-12] the old ">= 2
//     refuses outright" rule never repaid anything in practice — on cap47 the
//     device sat at thermal=2 from min 2 of a 6.5-min capture (采集常态), so
//     all 140 repay offers were refused and the whole debt hit the finalize
//     re-match at ~410 ms/pair on a hot GPU. serious+idle with a HEALTHY
//     matcher is exactly the cheap window; serious+struggling GPU is the
//     freeze precondition (rc=7 forensic). Gate: allowed when the last
//     kRepayThermal2CleanN(=4) GPU pairs all succeeded (gpu_pairs_since_rc7,
//     rc=7 resets — i.e. recent no rc=7), budget clamped to
//     kRepayThermal2MaxPairs(=8) per call, and ANY matcher failure aborts the
//     pass on the spot (heat self-throttles the yield; failure is safe —
//     healthy takes the full budget, struggling degrades to the old
//     finalize-debt path). Kill switch: OFFICIAL_AETHER_REPAY_THERMAL2_CLEAN_N=0
//     restores the old full refusal; N>0 overrides the clean-history length;
//   - starved = the live win_valid mirror of the finalize rule (< 4 valid
//     window pairs, or fed_throttled), candidates = missing window pairs
//     (gap <= K, either side starved; gap <= 2 chain holes always),
//     gap-ascending — identical topology to the finalize re-match;
//   - each pair is attempted AT MOST once by repay (failed pairs are left
//     for the finalize pass, which re-attempts anything still missing);
//   - db-only: the pass never touches the live preview reconstruction, so
//     the delivered model is identical whether a pair was repaid live or at
//     finalize (same descriptors, same matcher, same write sequence).
// Returns pairs written this call (0 = nothing to do / refused), -1 on bad
// args. Counters via aether_sfm_repair_stats.
// [P1-REPAY-THERMAL2] thermal=2 conditional-repay knobs.
// [PHASE-A 2026-07-12] AGGRESSIVE-REPAY re-tuning (即时出云战役 Phase A):
// the original 2-pair / 16-clean gate almost never fired — cap47 sat at
// thermal=2 (采集常态) from min 2 of a 6.5-min capture, so the debt (112 s of
// finalize re-match at ~410 ms/pair on a hot GPU) was never prepaid. serious +
// a HEALTHY matcher (recent no rc=7) IS the cheap idle window; the freeze
// precondition is serious + a STRUGGLING GPU (rc=7 forensic), which the
// per-pair rc=7 reset + first-failure abort still catch. So Phase A widens the
// per-call clamp 2→8 (~130 ms healthy GPU, still << the 2 s single-call red
// line) and shortens the required clean run 16→4 (recent-no-rc=7 rather than a
// long streak). MaxPairs is the per-call budget clamp at serious; CleanN is
// the required healthy-GPU run since the last rc=7 (0 = thermal=2 refuses
// outright, the old rule; env OFFICIAL_AETHER_REPAY_THERMAL2_CLEAN_N overrides).
constexpr int kRepayThermal2MaxPairs = 8;
int RepayThermal2CleanN() {
  static const int cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_REPAY_THERMAL2_CLEAN_N")) {
      const int v = std::atoi(e);
      if (v >= 0) return v;
    }
    return 4;  // recent-no-rc=7: ≥4 consecutive healthy GPU pairs since rc=7
  }();
  return cached;
}

// ── [QUAD-PREPAY 2026-07-26, signed] Capture-idle official quadratic prepay
// OFFICIAL_AETHER_QUADRATIC_PREPAY=0 kills the prepay; the finalize
// AddOfficialQuadraticPairs pass is the unconditional backstop either way
// (it skips pairs that already exist in the db).
static bool QuadraticPrepayEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_QUADRATIC_PREPAY");
    return !(e && e[0] == '0');
  }();
  return cached;
}

// Prepays the upstream quadratic-overlap pairs (i, i+2^k), 2^k > live K
// window — the EXACT candidate set, matcher, ratio, and colmap-DEFAULT
// TwoViewGeometry verification the finalize AddOfficialQuadraticPairs pass
// would run at finish time, just executed earlier, in capture idle gaps
// (the Dart facade only drives this when the frame queue is empty).
// Union(prepaid, finalize backstop) is the same pair set with identical
// per-pair results — descriptors are frozen at extraction — so finish-time
// work shrinks without any data change. Writes are db-only: the live
// in-memory mapper is not fed (same classification as the finalize
// enrichment passes; the periodic capture-time global BA rebuilds its
// DatabaseCache from the db, so prepaid long-range edges reach the preview
// solve earlier — the signed FINALIZE-OVERLAP semantics, one stage earlier).
// Returns matcher invocations consumed (0 = nothing due / disabled), so the
// idle driver can chain calls while work remains.
static int PrepayQuadraticTick(aether_sfm_session* s, int max_pairs) {
  if (!QuadraticPrepayEnabled()) return 0;
  if (!s || !s->db || max_pairs <= 0) return 0;
  const int overlap = OfficialQuadraticOverlap();
  if (overlap <= 0 || s->camera_id == 0 || s->frames.size() < 2) return 0;
  // Never add GPU load at thermal critical. Serious is normal operating
  // condition for the paced matcher (cap_1785070530166049: K12 with 112
  // serious frames, zero rc=7).
  if (s->thermal_state.load(std::memory_order_relaxed) >= 3) return 0;
  const bool gpu_avail =
      s->options.use_gpu_match && (aether_gpu_match_gemm_pairs != nullptr);
  // Fail-closed parity with the finalize pass: GPU requested but absent →
  // never degrade into O(N²) CPU matching.
  if (s->options.use_gpu_match && !gpu_avail) return 0;
  int attempted = 0;
  try {
    // 1) Extend the due queue with newly arrived frames' pairs. The live
    //    window already matches gaps 1..K, so only 2^k > K is due here;
    //    anything the live window missed is the finalize passes' job.
    const int K = s->options.k_neighbors > 0 ? s->options.k_neighbors : 12;
    const int n = static_cast<int>(s->frames.size());
    for (; s->prepay_scan < static_cast<size_t>(n); ++s->prepay_scan) {
      const int j = static_cast<int>(s->prepay_scan);
      for (int k = 0; k < overlap; ++k) {
        const int64_t gap = 1ll << k;
        if (gap <= K) continue;
        if (gap > j) break;  // larger k ⇒ larger gap ⇒ also out of range
        s->prepay_due.emplace_back(j - static_cast<int>(gap), j);
      }
    }
    // 2) Attempt up to max_pairs (budget = matcher invocations). Pair
    //    orientation, options, and persistence mirror the finalize pass
    //    exactly.
    const double ratio =
        s->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.8;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    std::vector<uint32_t> pair_buf;
    while (attempted < max_pairs && !s->prepay_due.empty()) {
      const auto [i, j] = s->prepay_due.front();
      s->prepay_due.pop_front();
      const FrameRecord& fa = s->frames[i];
      const FrameRecord& fb = s->frames[j];
      const colmap::image_t img1 = fa.image_id;
      const colmap::image_t img2 = fb.image_id;
      if (img1 == 0 || img2 == 0 || img1 == img2) continue;
      if (fa.descriptors.empty() || fb.descriptors.empty() ||
          fa.n_keypoints <= 0 || fb.n_keypoints <= 0) {
        continue;  // no in-memory features (resume-style) → finalize backstop
      }
      if (s->db->ExistsMatches(img1, img2) ||
          s->db->ExistsTwoViewGeometry(img1, img2)) {
        continue;
      }
      const int cap =
          fa.n_keypoints < fb.n_keypoints ? fa.n_keypoints : fb.n_keypoints;
      pair_buf.resize(static_cast<size_t>(cap) * 2);
      int num_matches = 0;
      ++attempted;
      ++s->stat_prepay_attempted;
      // [P1-RC7-RETRY] transient rc=7 on a hot GPU gets two backoff retries.
      const int mrc =
          gpu_avail
              ? GpuMatchGemmPairsRetry(
                    s, fa.frame_id, fa.descriptors.data(), fa.n_keypoints,
                    fb.frame_id, fb.descriptors.data(), fb.n_keypoints, ratio,
                    pair_buf.data(), cap, &num_matches)
              : aether_sift_match_pairs(fa.descriptors.data(), fa.n_keypoints,
                                        fb.descriptors.data(), fb.n_keypoints,
                                        ratio, pair_buf.data(), cap,
                                        &num_matches);
      if (mrc != 0) continue;          // struggling now: finalize backstop
      if (num_matches <= 0) continue;  // legitimate zero-match pair
      colmap::FeatureMatches matches(num_matches);
      for (int m = 0; m < num_matches; ++m) {
        matches[m].point2D_idx1 = pair_buf[2 * m];
        matches[m].point2D_idx2 = pair_buf[2 * m + 1];
      }
      const auto tvg = EstimateMandatoryFrameTwoViewGeometry(
          fa, fa.points, fb, fb.points, matches, tvg_options);
      if (!MandatoryGravityTvgPersistable(tvg)) continue;
      const bool tail_pair_first_write =
          TailCacheBeginPairWrite(s, img1, img2, /*late_write=*/true);
      s->db->WriteMatches(img1, img2, matches);
      s->db->WriteTwoViewGeometry(img1, img2, tvg.geometry);
      TailCacheCommitPair(s, img1, img2, tvg.geometry,
                          tail_pair_first_write);
      ++s->stat_prepay_written;
    }
  } catch (const std::exception& e) {
    // Prepay is opportunistic — a failure must never take the worker down.
    LOG(WARNING) << "[aether_sfm] quadratic prepay aborted: " << e.what();
  } catch (...) {
    LOG(WARNING) << "[aether_sfm] quadratic prepay aborted";
  }
  return attempted;
}

// [IDLE-PREPAY 2026-08-07] Root cause of stat_repay_calls == 0 in every
// production capture: aether_sfm_live_repay (the only caller of the
// starved-window repay below) short-circuits at the production official
// endpoint into PrepayQuadraticTick and RETURNS — the starved-window pass
// became unreachable by construction when [QUAD-PREPAY 2026-07-26] claimed
// the idle channel. The quadratic debt is small (gaps 16/32/… only) and
// drains in a few ticks, after which every remaining idle window was thrown
// away while the starved-frame debt still hit FinalizeRematchStarvedFrames at
// ~410 ms/pair on a hot finish-time GPU. Fix: once the quadratic tick reports
// nothing due, spend the same (facade-verified: spool empty + nothing in
// flight) idle window on the starved-window repay — but only when the worker
// has ALSO been frame-idle for a while and the device is cool:
//   - OFFICIAL_AETHER_IDLE_PREPAY=0 kills the leg (default ON);
//   - frame-idle gate: NowMs() - last_add_frame_done_ms >
//     OFFICIAL_AETHER_IDLE_PREPAY_IDLE_MS (default 2000 ms) — a queue that is
//     momentarily empty between shutter frames does NOT count as idle, so the
//     leg cannot add tail latency to a keyframe cadence that is keeping up;
//   - thermal serious+ never prepays from this leg (counted via the existing
//     stat_repay_skipped_thermal) — stricter than the legacy conditional
//     clean-history rule, because idle prepay is pure opportunism;
//   - per-call budget clamped to kRepayThermal2MaxPairs (= 8) pairs.
// Sessions that never fed a frame (resume-from-db) keep
// last_add_frame_done_ms == 0 and are refused outright — and the resume
// bench never drives the repay channel at all, so resume output is unchanged
// by construction.
static bool IdlePrepayEnabled() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_IDLE_PREPAY");
    return !(e && e[0] == '0');
  }();
  return cached;
}
static double IdlePrepayIdleMs() {
  static const double cached = [] {
    if (const char* e = std::getenv("OFFICIAL_AETHER_IDLE_PREPAY_IDLE_MS")) {
      const double v = std::atof(e);
      if (v >= 0.0) return v;
    }
    return 2000.0;
  }();
  return cached;
}

// [IDLE-PREPAY 2026-08-07] The pre-existing starved-window repay body,
// extracted verbatim from aether_sfm_live_repay so both the legacy endpoint
// and the new idle-prepay leg share one implementation. Thermal rules,
// counters, and per-pair semantics are unchanged.
static int LiveRepayStarvedWindowTick(aether_sfm_session_t* s, int max_pairs) {
  if (s->frames.size() < 3 || s->camera_id == 0) return 0;
  const int thermal_entry =
      s->thermal_state.load(std::memory_order_relaxed);
  bool thermal2_mode = false;
  if (thermal_entry >= 3) {  // critical: never add GPU load
    ++s->stat_repay_skipped_thermal;
    return 0;
  }
  if (thermal_entry == 2) {
    const int clean_n = RepayThermal2CleanN();
    if (clean_n <= 0 || s->gpu_pairs_since_rc7 < clean_n) {
      ++s->stat_repay_skipped_thermal;
      return 0;
    }
    thermal2_mode = true;
    max_pairs = std::min(max_pairs, kRepayThermal2MaxPairs);
  }
  const bool gpu_avail =
      s->options.use_gpu_match && (aether_gpu_match_gemm_pairs != nullptr);
  // Fail-closed parity with the finalize pass: GPU requested but absent →
  // never degrade into CPU brute force.
  if (s->options.use_gpu_match && !gpu_avail) return 0;
  ++s->stat_repay_calls;
  int written = 0;
  try {
    const int num_frames = static_cast<int>(s->frames.size());
    const int K = s->options.k_neighbors > 0 ? s->options.k_neighbors : 12;
    const auto starved = [&](int i) {
      const int valid = i < static_cast<int>(s->live_win_valid.size())
                            ? s->live_win_valid[i]
                            : 0;
      return s->frames[i].n_keypoints > 0 &&
             (valid < kRematchMinValidWindowPairs ||
              s->frames[i].fed_throttled);
    };
    const double ratio =
        s->options.match_max_ratio > 0 ? s->options.match_max_ratio : 0.8;
    const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults
    std::vector<uint32_t> pair_buf;
    int attempted = 0;
    for (int gap = 1; gap <= K && attempted < max_pairs; ++gap) {
      for (int f = gap; f < num_frames && attempted < max_pairs; ++f) {
        const int j = f - gap;
        if (gap > kRematchNearGap && !starved(f) && !starved(j)) continue;
        const FrameRecord& fj = s->frames[j];
        const FrameRecord& ff = s->frames[f];
        if (fj.n_keypoints <= 0 || ff.n_keypoints <= 0) continue;
        if (fj.descriptors.empty() || ff.descriptors.empty()) continue;
        const uint64_t key = FramePairKey(f, j);
        if (s->live_pairs_done.count(key)) continue;
        if (s->db->ExistsMatches(fj.image_id, ff.image_id)) {
          s->live_pairs_done.insert(key);
          continue;
        }
        // Mid-call thermal check: a state push can arrive between pairs.
        // critical always aborts; a cool→serious transition aborts too (the
        // thermal2 clean-history gate was not evaluated for this call) —
        // only a call that ENTERED at serious keeps its small clamped budget.
        {
          const int th_now =
              s->thermal_state.load(std::memory_order_relaxed);
          if (th_now >= 3 || (th_now >= 2 && !thermal2_mode)) {
            ++s->stat_repay_skipped_thermal;
            return written;
          }
        }
        ++attempted;
        ++s->stat_repay_attempted;
        const int cap =
            fj.n_keypoints < ff.n_keypoints ? fj.n_keypoints : ff.n_keypoints;
        pair_buf.resize(static_cast<size_t>(cap) * 2);
        int num_matches = 0;
        const int mrc =
            gpu_avail
                ? GpuMatchGemmPairsRetry(
                      s, fj.frame_id, fj.descriptors.data(), fj.n_keypoints,
                      ff.frame_id, ff.descriptors.data(), ff.n_keypoints,
                      ratio, pair_buf.data(), cap, &num_matches)
                : aether_sift_match_pairs(fj.descriptors.data(),
                                          fj.n_keypoints,
                                          ff.descriptors.data(),
                                          ff.n_keypoints, ratio,
                                          pair_buf.data(), cap, &num_matches);
        if (mrc != 0) {
          ++s->stat_repay_failed;
          if (gpu_avail && mrc == 7) s->gpu_pairs_since_rc7 = 0;
          // [P1-REPAY-THERMAL2] at serious, the FIRST struggling pair ends
          // the pass — repay must never become the load that tips a hot GPU.
          if (thermal2_mode) return written;
          continue;
        }
        if (gpu_avail) ++s->gpu_pairs_since_rc7;
        if (num_matches <= 0) continue;  // legitimate empty pair — resolved
        colmap::FeatureMatches matches(num_matches);
        for (int m = 0; m < num_matches; ++m) {
          matches[m].point2D_idx1 = pair_buf[2 * m];
          matches[m].point2D_idx2 = pair_buf[2 * m + 1];
        }
        const auto tvg = EstimateMandatoryFrameTwoViewGeometry(
            fj, fj.points, ff, ff.points, matches, tvg_options);
        if (!MandatoryGravityTvgPersistable(tvg)) continue;
        const bool tail_pair_first_write =
            TailCacheBeginPairWrite(s, fj.image_id, ff.image_id,
                                    /*late_write=*/true);
        s->db->WriteMatches(fj.image_id, ff.image_id, matches);
        s->db->WriteTwoViewGeometry(fj.image_id, ff.image_id, tvg.geometry);
        TailCacheCommitPair(s, fj.image_id, ff.image_id, tvg.geometry,
                            tail_pair_first_write);
        s->live_pairs_done.insert(key);
        ++written;
        ++s->stat_repay_written;
        s->stat_repay_inliers +=
            static_cast<int64_t>(tvg.geometry.inlier_matches.size());
        if (static_cast<int>(tvg.geometry.inlier_matches.size()) >=
            kRematchValidInlierGate) {
          if (static_cast<int>(s->live_win_valid.size()) <= f) {
            s->live_win_valid.resize(f + 1, 0);
          }
          ++s->live_win_valid[j];
          ++s->live_win_valid[f];
        }
      }
    }
    return written;
  } catch (const std::exception& e) {
    LOG(WARNING) << "[aether_sfm] live repay aborted: " << e.what();
    return written;
  }
}

int aether_sfm_live_repay(aether_sfm_session_t* s, int max_pairs) {
  if (!s || !s->db) return -1;
  if (max_pairs <= 0) return 0;
  // [QUAD-PREPAY 2026-07-26, signed] At the official endpoint the idle
  // channel performs the OFFICIAL quadratic-overlap prepay (pair generation
  // + matching + colmap-default TVG, db-only — the same official-semantics
  // classification that un-gated the quadratic and re-match passes) first.
  if (kProductionOfficialEndpointOnly) {
    const int consumed = PrepayQuadraticTick(s, max_pairs);
    if (consumed > 0) return consumed;
    // [IDLE-PREPAY 2026-08-07] Quadratic debt clear → same idle window pays
    // the starved-window debt (rationale + gates: block comment above
    // IdlePrepayEnabled). Default ON; OFFICIAL_AETHER_IDLE_PREPAY=0 kills.
    if (!IdlePrepayEnabled()) return 0;
    if (s->last_add_frame_done_ms <= 0.0 ||
        NowMs() - s->last_add_frame_done_ms < IdlePrepayIdleMs()) {
      return 0;  // not frame-idle (or never fed) — never touch the matcher
    }
    if (s->thermal_state.load(std::memory_order_relaxed) >= 2) {
      ++s->stat_repay_skipped_thermal;  // serious+: idle leg never prepays
      return 0;
    }
    ++s->stat_idle_prepay_ticks;
    const int64_t attempted_before = s->stat_repay_attempted;
    const int64_t written_before = s->stat_repay_written;
    const int n =
        LiveRepayStarvedWindowTick(s, std::min(max_pairs,
                                               kRepayThermal2MaxPairs));
    if (s->stat_repay_attempted != attempted_before) {
      char line[224];
      std::snprintf(
          line, sizeof(line),
          "{\"t\":%lld,\"type\":\"idle_prepay\",\"tick\":%lld,"
          "\"attempted\":%lld,\"written\":%lld,\"cum_written\":%lld}",
          static_cast<long long>(EpochMs()),
          static_cast<long long>(s->stat_idle_prepay_ticks),
          static_cast<long long>(s->stat_repay_attempted - attempted_before),
          static_cast<long long>(s->stat_repay_written - written_before),
          static_cast<long long>(s->stat_repay_written));
      AppendMatchFailJsonl(s, line);
    }
    return n;
  }
  return LiveRepayStarvedWindowTick(s, max_pairs);
}

// [P1 2026-07-11] Finalize-speedup package counters: idle repay, rc=7 retry,
// enrichment time-budget truncation. Same threading contract as
// aether_sfm_stream_stats. All out-params nullable.
void aether_sfm_repair_stats(aether_sfm_session_t* s, int64_t* repay_calls,
                             int64_t* repay_attempted, int64_t* repay_written,
                             int64_t* repay_inliers, int64_t* repay_failed,
                             int64_t* repay_skipped_thermal,
                             int64_t* gpu_retry_attempts,
                             int64_t* gpu_retry_recovered,
                             int64_t* enrich_budget_stopped) {
  if (!s) return;
  if (repay_calls) *repay_calls = s->stat_repay_calls;
  if (repay_attempted) *repay_attempted = s->stat_repay_attempted;
  if (repay_written) *repay_written = s->stat_repay_written;
  if (repay_inliers) *repay_inliers = s->stat_repay_inliers;
  if (repay_failed) *repay_failed = s->stat_repay_failed;
  if (repay_skipped_thermal)
    *repay_skipped_thermal = s->stat_repay_skipped_thermal;
  if (gpu_retry_attempts) *gpu_retry_attempts = s->stat_gpu_retry_attempts;
  if (gpu_retry_recovered) *gpu_retry_recovered = s->stat_gpu_retry_recovered;
  if (enrich_budget_stopped)
    *enrich_budget_stopped = s->stat_enrich_budget_stopped;
}

// [L1-ARBITRATE 2026-07-12] Ghost-layer L1 CasDiffMVS 1-bit arbitration —
// fully FILE-driven over the session's run_dir: consumes the finalize-tail
// sidecars (arbitration_plan.bin + arbitration_points.bin + ghost_mask.bin,
// written when OFFICIAL_AETHER_GHOST_MASK=1) plus the per-ref depth bins the platform
// CoreML runner wrote (l1_depth_<frameId>.bin), applies the calibrated
// terminal rules (height-domain per-view votes, 3x3-patch median reads,
// SUP>=2/SEE=0 hysteresis, mirror defense: below-floor evidence never
// rescues, abstain -> visible), and rewrites ghost_mask.bin with the
// kFlagL1Rescued / kFlagL1Confirmed bits + a ghost_arbitration.json stats
// sidecar. The session is only the run_dir carrier — no reconstruction state
// is touched, so this is safe on any thread once the runner finished.
// Returns NOT_REGISTERED when the inputs are absent (plan not written /
// runner never ran) — the caller treats that as a no-op, never an error.
aether_sfm_result_t aether_sfm_arbitrate(aether_sfm_session_t* s,
                                         char* out_json, int out_cap) {
  if (out_json && out_cap > 0) out_json[0] = '\0';
  if (!s) return AETHER_SFM_ERR_INVALID_ARG;
  try {
    const double t0 = NowMs();
    const std::string dir =
        std::filesystem::path(s->db_path).parent_path().string();
    aether_l1::ArbStats st;
    std::string err;
    if (!aether_l1::RunArbitration(dir, &st, &err)) {
      LOG(WARNING) << "[aether_sfm] l1_arbitrate: " << err;
      const bool absent = err.find("missing") != std::string::npos;
      return absent ? AETHER_SFM_ERR_NOT_REGISTERED : AETHER_SFM_ERR_INTERNAL;
    }
    st.pass_ms = NowMs() - t0;
    LOG(WARNING) << "[aether_sfm] l1_arbitrate: refs=" << st.n_refs_used << "/"
                 << st.n_refs_planned << " band=" << st.n_band
                 << " rescue=" << st.n_rescue << " confirm=" << st.n_confirm
                 << " abstain=" << st.n_abstain
                 << " degraded=" << (st.degraded ? 1 : 0) << " ("
                 << static_cast<int>(st.pass_ms) << "ms)";
    if (out_json && out_cap > 0) {
      std::snprintf(
          out_json, static_cast<size_t>(out_cap),
          "{\"refs_planned\":%d,\"refs_used\":%d,\"n_band\":%d,"
          "\"rescue\":%d,\"confirm\":%d,\"abstain\":%d,"
          "\"delta_mm\":%.3f,\"delta_ray_mm\":%.3f,\"degraded\":%s,"
          "\"pass_ms\":%d}",
          st.n_refs_planned, st.n_refs_used, st.n_band, st.n_rescue,
          st.n_confirm, st.n_abstain, st.delta_mm, st.delta_ray_mm,
          st.degraded ? "true" : "false", static_cast<int>(st.pass_ms));
    }
    return AETHER_SFM_OK;
  } catch (const std::exception& e) {
    LOG(WARNING) << "[aether_sfm] l1_arbitrate failed: " << e.what();
    return AETHER_SFM_ERR_INTERNAL;
  } catch (...) {
    return AETHER_SFM_ERR_INTERNAL;
  }
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
  // [A1B-ASYNC-PVBA 2026-07-27] Same rule for the async preview-BA thread
  // (experiment arm, default OFF): it captures `s` for the result handoff.
  if (s->async_pvba_thread.joinable()) s->async_pvba_thread.join();
  // [GPU-HANG-B1] worker 线程都收完了再停巡逻线程(finalize 期间它要在岗);
  // 必须先于 delete —— 回调捕获了 s。
  s->gpu_watchdog.Stop();
  // Snapshot counters before clearing the backend-owned buffers. The record is
  // emitted for both experiment states, so a default-off build is explicit.
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
  AppendDescriptorResidencyStats(s);
#endif
  TailCacheMarkDirty(
      s, aether::sfm::TailCacheDirtyReasonV1::kDeviceReset);
  AppendTailCacheStats(s);
#if AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
  if (aether_gpu_match_descriptor_residency_clear_session != nullptr &&
      s->descriptor_residency_nonce != 0) {
    aether_gpu_match_descriptor_residency_clear_session(
        s->descriptor_residency_nonce);
  }
#endif
  if (s->db) {
    try {
      s->db->Close();
    } catch (...) {
    }
  }
  if (s->owns_db_file && !s->db_path.empty()) {
    std::remove(s->db_path.c_str());
  }
  aether_ba_clear_gravity_priors();
  delete s;
}

}  // extern "C"
