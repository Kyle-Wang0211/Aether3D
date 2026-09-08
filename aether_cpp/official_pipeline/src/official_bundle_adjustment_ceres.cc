// Copyright (c), ETH Zurich and UNC Chapel Hill.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
//     * Neither the name of ETH Zurich and UNC Chapel Hill nor the names of
//       its contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include "colmap/estimators/bundle_adjustment_ceres.h"

#include <atomic>
#include <cstdlib>

#include "colmap/estimators/alignment.h"
#include "colmap/estimators/cost_functions/manifold.h"
#include "colmap/estimators/cost_functions/pose_prior.h"
#include "colmap/estimators/cost_functions/reprojection_error.h"
#include "colmap/estimators/cost_functions/utils.h"
#include "colmap/util/cuda.h"
#include "colmap/util/misc.h"
#include "colmap/util/threading.h"

#include "gravity_ba_prior_v1.h"
#include "aether_ba_solve_policy_v1.h"

#include <iomanip>

// [AETHER position-prior spike 2026-07-10]
#include <cmath>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <Eigen/Geometry>  // Eigen::umeyama

namespace aether::official::ba {
}  // namespace aether::official::ba

namespace colmap {

// [AETHER FINALIZE-SEGMENTS 2026-07-11] Telemetry-only stash of the LAST ceres
// solve's observability fields (the same values the "[AETHER] solver_used="
// log line prints). stderr is LOST when the device runs detached (cap44:
// 13:11:36→13:14:08 log vacuum), so aether_sfm_c.cc's finalize worker reads
// this stash and persists it into official_finalize_segments.json. Written after every
// SolveWithGpuFallback; zero effect on the solve itself.
namespace {
// [ANALYTIC-JAC-PROBE 2026-08-13 诊断旋钮,默认关] 上游 CreateCameraCostFunction
// 内部有 `if constexpr`:当 functor 是 ReprojErrorCostFunctor /
// ReprojErrorConstantPoseCostFunctor 且相机模型 has_img_from_cam_with_jac 时,
// **自动换成解析 Jacobian 版**(reprojection_error.h:456)。我们的相机是 PINHOLE
// (has_jac=true)且单相机走平凡帧路径 ⇒ 解析版应当**早已在跑**。
// 但"读代码得出的结论"不算数(08-13 假 config_echo 教训),这个开关强制走自动
// 微分,用 ba_rounds 的 jac_s 实测差值证明解析版确实在生效、并量出它值多少。
// OFFICIAL_AETHER_BA_FORCE_AUTODIFF=1 开启;默认行为逐位不变。
bool ForceAutoDiffJacobians() {
  static const bool cached = [] {
    const char* e = std::getenv("OFFICIAL_AETHER_BA_FORCE_AUTODIFF");
    return e != nullptr && e[0] == '1';
  }();
  return cached;
}

// CreateCameraCostFunction 的"永远自动微分"孪生体:同一套 model_id 分发,
// 但不走那段 if constexpr,直接 Create()。仅供上面的诊断旋钮使用。
template <template <typename> class CostFunctor, typename... Args>
ceres::CostFunction* CreateAutoDiffOnlyCameraCostFunction(
    const CameraModelId camera_model_id, Args&&... args) {
  switch (camera_model_id) {
#define CAMERA_MODEL_CASE(CameraModel) \
  case CameraModel::model_id:          \
    return CostFunctor<CameraModel>::Create(std::forward<Args>(args)...);

    CAMERA_MODEL_SWITCH_CASES

#undef CAMERA_MODEL_CASE
  }
  return nullptr;
}

std::mutex& AetherLastSolveMutex() {
  static std::mutex m;
  return m;
}
std::string g_aether_last_solver_used;     // e.g. "SPARSE_SCHUR"
std::string g_aether_last_sparse_backend;  // e.g. "EIGEN_SPARSE"
std::string g_aether_last_dense_backend;   // e.g. "LAPACK" (Accelerate) / "EIGEN"
int g_aether_last_mixed = 0;
int g_aether_last_threads = 0;

// Monotonic process identity only. Receipt storage itself is session-owned.
std::atomic<uint64_t> g_aether_ba_solve_seq{1};

// [AETHER DENSE-BACKEND TIER ROUTING 2026-07-12] Default num_images threshold
// at/above which DENSE_SCHUR routes its dense Cholesky to LAPACK (Accelerate)
// instead of Eigen LLT. Host inflection scan (2026-07-12, M-series host,
// finalize CAUCHY BA replayed on the same pre-BA model, E/L alternated 2+2
// rounds per tier, same process, quiet machine):
//   n_img : 50      121     150     200     250     300     396
//   gain  : -1.9%*  -1.3%*  -4.0%   -5.3%   -5.0%   -5.4%   -8.1%   (*=noise)
//   real GLOMAP models: 299 imgs -11.0%, 414 imgs -16.5%
// Quality: final_cost/reproj identical E vs L at every tier. Inflection = 150
// (first tier with all-round E/L separation); threshold = 150 + 20% margin,
// rounded to tens = 180. Overridable at runtime via
// OFFICIAL_AETHER_DENSE_LAPACK_MIN_IMAGES; OFFICIAL_AETHER_DENSE_LAPACK=0/1 force-overrides.
// ⚠️ The 07-05 "-65%" memory anchor did NOT reproduce as a dense-E vs dense-L
// comparison — it almost certainly measured LAPACK dense against a different
// (sparse/deeper-converged) baseline. Host large-scene dense E->L gain is
// -8..-16.5%.
// ⚠️ On-device (A16) large-scene gain is INFERRED from the same-library/
// same-mechanism argument (Accelerate on both), not yet measured on a real
// large capture — host cap47 (121 imgs) showed no gain, which is exactly why
// small scenes stay on Eigen.
constexpr int kAetherDenseLapackMinImagesDefault = 180;
}  // namespace

void AetherLastBaSolveInfo(std::string* solver_used,
                           std::string* sparse_backend,
                           int* mixed,
                           int* threads,
                           std::string* dense_backend) {
  std::lock_guard<std::mutex> lk(AetherLastSolveMutex());
  if (solver_used) *solver_used = g_aether_last_solver_used;
  if (sparse_backend) *sparse_backend = g_aether_last_sparse_backend;
  if (mixed) *mixed = g_aether_last_mixed;
  if (threads) *threads = g_aether_last_threads;
  if (dense_backend) *dense_backend = g_aether_last_dense_backend;
}

namespace {

BundleAdjustmentTerminationType CeresTerminationTypeToTerminationType(
    ceres::TerminationType ceres_type) {
  switch (ceres_type) {
    case ceres::CONVERGENCE:
      return BundleAdjustmentTerminationType::CONVERGENCE;
    case ceres::NO_CONVERGENCE:
      return BundleAdjustmentTerminationType::NO_CONVERGENCE;
    case ceres::FAILURE:
      return BundleAdjustmentTerminationType::FAILURE;
    case ceres::USER_SUCCESS:
      return BundleAdjustmentTerminationType::USER_SUCCESS;
    case ceres::USER_FAILURE:
      return BundleAdjustmentTerminationType::USER_FAILURE;
  }
  LOG(FATAL_THROW) << "Unknown Ceres termination type: " << ceres_type;
  return BundleAdjustmentTerminationType::FAILURE;
}

std::unique_ptr<ceres::LossFunction> CreateLossFunction(
    CeresBundleAdjustmentOptions::LossFunctionType loss_function_type,
    double loss_function_scale) {
  switch (loss_function_type) {
    case CeresBundleAdjustmentOptions::LossFunctionType::TRIVIAL:
      return std::make_unique<ceres::TrivialLoss>();
    case CeresBundleAdjustmentOptions::LossFunctionType::SOFT_L1:
      return std::make_unique<ceres::SoftLOneLoss>(loss_function_scale);
    case CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY:
      return std::make_unique<ceres::CauchyLoss>(loss_function_scale);
    case CeresBundleAdjustmentOptions::LossFunctionType::HUBER:
      return std::make_unique<ceres::HuberLoss>(loss_function_scale);
  }
  return nullptr;
}

}  // namespace

// ─────────────────────────────────────────────────────────────────────────────
// [AETHER position-prior spike 2026-07-10] Soft per-frame camera-CENTER priors
// from ARKit (metric, gravity-aligned) injected as extra residual blocks into
// EVERY DefaultBundleAdjuster problem. Purpose: the streaming capture's double
// wall is a two-pass ~2-3cm systematic offset that reprojection residuals alone
// cannot pull together (cross-pass bridges are only ~3% of observations); ARKit
// centers carry the missing INTER-PASS consistency. Design:
//   cost = Huber( (C_colmap(frame) - C_prior_aligned(frame)) / sigma )
// where C_prior_aligned = Sim3(metric->colmap) * C_arkit, re-estimated from the
// CURRENT reconstruction centers every time a problem is built (COLMAP scale is
// arbitrary and Normalize() runs between global BAs). sigma_colmap = sigma_m *
// sim3_scale. A Sim3 has only 7 DOF, so it cannot absorb the per-pass relative
// offset — the priors split the alignment error across the passes and pull the
// two walls onto each other. Registry is process-global, set via the C entry
// aether_ba_set_position_priors() (bench: colmap_bench --arkit=JSONL). Empty
// registry (the default) = exact stock behavior.
namespace {

struct AetherPositionPriorRegistry {
  std::mutex mutex;
  // image name (e.g. "frame_000012.jpg") -> ARKit camera center [m], world.
  std::unordered_map<std::string, Eigen::Vector3d> centers_metric;
  double sigma_m = 0.03;
};

struct AetherGravityPriorRegistry {
  std::mutex mutex;
  // image name -> measured physical-down vector in that camera frame.
  std::unordered_map<std::string, Eigen::Vector3d> gravity_cam;
  // Strong roll/pitch constraint. Yaw remains completely unconstrained by the
  // rank-two cross-product residual.
  double sigma_rad = 0.5 * 3.14159265358979323846 / 180.0;
};

AetherPositionPriorRegistry& GetAetherPositionPriorRegistry() {
  static auto* registry = new AetherPositionPriorRegistry();
  return *registry;
}

AetherGravityPriorRegistry& GetAetherGravityPriorRegistry() {
  static auto* registry = new AetherGravityPriorRegistry();
  return *registry;
}

}  // namespace

// C ABI: register per-image metric camera-center priors (replaces any previous
// set). names[i] must equal the COLMAP image name; xyz is packed x,y,z per
// image; sigma_m is the isotropic prior stddev in METERS. n<=0 clears.
extern "C" void aether_ba_set_position_priors(const char* const* names,
                                              const double* xyz,
                                              int n,
                                              double sigma_m) {
  auto& reg = GetAetherPositionPriorRegistry();
  std::lock_guard<std::mutex> lock(reg.mutex);
  reg.centers_metric.clear();
  for (int i = 0; i < n; ++i) {
    reg.centers_metric[names[i]] =
        Eigen::Vector3d(xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
  }
  if (sigma_m > 0) reg.sigma_m = sigma_m;
}

extern "C" void aether_ba_clear_position_priors() {
  auto& reg = GetAetherPositionPriorRegistry();
  std::lock_guard<std::mutex> lock(reg.mutex);
  reg.centers_metric.clear();
}

// Mandatory production gravity prior. The streaming owner calls this once per
// accepted ARKit frame before any BA can observe that image. Invalid gravity is
// rejected instead of being installed as an optional/no-op prior.
// [GRAVITY-RA 2026-08-10] Read-back for the finalize rotation-averaging pass:
// per-image gravity_cam (physical-down in camera frame) as registered by the
// mandatory live/resume ingest. Returns 0 when the image has no entry.
extern "C" int aether_ba_get_gravity_prior(const char* name,
                                           double* out_gravity_cam_xyz) {
  if (name == nullptr || out_gravity_cam_xyz == nullptr || name[0] == '\0') {
    return 0;
  }
  auto& registry = GetAetherGravityPriorRegistry();
  std::lock_guard<std::mutex> lock(registry.mutex);
  const auto it = registry.gravity_cam.find(name);
  if (it == registry.gravity_cam.end()) return 0;
  out_gravity_cam_xyz[0] = it->second.x();
  out_gravity_cam_xyz[1] = it->second.y();
  out_gravity_cam_xyz[2] = it->second.z();
  return 1;
}

extern "C" int aether_ba_set_gravity_prior(const char* name,
                                            const double* gravity_cam_xyz,
                                            double sigma_rad) {
  if (name == nullptr || gravity_cam_xyz == nullptr || name[0] == '\0') {
    return 0;
  }
  const Eigen::Vector3d gravity(gravity_cam_xyz[0], gravity_cam_xyz[1],
                                gravity_cam_xyz[2]);
  if (!aether::sfm::IsValidGravityBaPriorV1(gravity)) {
    return 0;
  }
  auto& reg = GetAetherGravityPriorRegistry();
  std::lock_guard<std::mutex> lock(reg.mutex);
  reg.gravity_cam[name] = gravity.normalized();
  if (std::isfinite(sigma_rad) && sigma_rad > 0.0) {
    reg.sigma_rad = sigma_rad;
  }
  return 1;
}

extern "C" void aether_ba_clear_gravity_priors() {
  auto& reg = GetAetherGravityPriorRegistry();
  std::lock_guard<std::mutex> lock(reg.mutex);
  reg.gravity_cam.clear();
}

std::shared_ptr<CeresBundleAdjustmentSummary>
CeresBundleAdjustmentSummary::Create(ceres::Solver::Summary ceres_summary) {
  auto summary = std::make_shared<CeresBundleAdjustmentSummary>();
  summary->termination_type =
      CeresTerminationTypeToTerminationType(ceres_summary.termination_type);
  summary->num_residuals = ceres_summary.num_residuals_reduced;
  summary->ceres_summary = std::move(ceres_summary);
  return summary;
}

std::string CeresBundleAdjustmentSummary::BriefReport() const {
  return ceres_summary.BriefReport();
}

////////////////////////////////////////////////////////////////////////////////
// CeresBundleAdjustmentOptions
////////////////////////////////////////////////////////////////////////////////

CeresBundleAdjustmentOptions::CeresBundleAdjustmentOptions() {
  solver_options.function_tolerance = 0.0;
  solver_options.gradient_tolerance = 1e-4;
  solver_options.parameter_tolerance = 0.0;
  solver_options.logging_type = ceres::LoggingType::SILENT;
  solver_options.max_num_iterations = 100;
  solver_options.max_linear_solver_iterations = 200;
  solver_options.max_num_consecutive_invalid_steps = 10;
  solver_options.max_consecutive_nonmonotonic_steps = 10;
  solver_options.num_threads = -1;
#if CERES_VERSION_MAJOR < 2
  solver_options.num_linear_solver_threads = -1;
#endif  // CERES_VERSION_MAJOR
}

std::unique_ptr<ceres::LossFunction>
CeresBundleAdjustmentOptions::CreateLossFunction() const {
  return colmap::CreateLossFunction(loss_function_type, loss_function_scale);
}

ceres::Solver::Options CeresBundleAdjustmentOptions::CreateSolverOptions(
    const BundleAdjustmentConfig& config, const ceres::Problem& problem) const {
  ceres::Solver::Options custom_solver_options = solver_options;
  if (VLOG_IS_ON(2)) {
    custom_solver_options.minimizer_progress_to_stdout = true;
    custom_solver_options.logging_type =
        ceres::LoggingType::PER_MINIMIZER_ITERATION;
  }

  const int num_images = config.NumImages();
  const bool has_sparse =
      custom_solver_options.sparse_linear_algebra_library_type !=
      ceres::NO_SPARSE;

  int max_num_images_direct_dense_solver =
      max_num_images_direct_dense_cpu_solver;
  int max_num_images_direct_sparse_solver =
      max_num_images_direct_sparse_cpu_solver;

#ifdef COLMAP_CUDA_ENABLED
  bool cuda_solver_enabled = false;

#if (CERES_VERSION_MAJOR >= 3 ||                                \
     (CERES_VERSION_MAJOR == 2 && CERES_VERSION_MINOR >= 2)) && \
    !defined(CERES_NO_CUDA)
  if (use_gpu && num_images >= min_num_images_gpu_solver) {
    cuda_solver_enabled = true;
    custom_solver_options.dense_linear_algebra_library_type = ceres::CUDA;
    max_num_images_direct_dense_solver = max_num_images_direct_dense_gpu_solver;
  }
#else
  if (use_gpu) {
    LOG_FIRST_N(WARNING, 1)
        << "Requested to use GPU for bundle adjustment, but Ceres was "
           "compiled without CUDA support. Falling back to CPU-based dense "
           "solvers.";
  }
#endif

#if (CERES_VERSION_MAJOR >= 3 ||                                \
     (CERES_VERSION_MAJOR == 2 && CERES_VERSION_MINOR >= 3)) && \
    !defined(CERES_NO_CUDSS)
  if (use_gpu && num_images >= min_num_images_gpu_solver) {
    cuda_solver_enabled = true;
    custom_solver_options.sparse_linear_algebra_library_type =
        ceres::CUDA_SPARSE;
    max_num_images_direct_sparse_solver =
        max_num_images_direct_sparse_gpu_solver;
  }
#else
  if (use_gpu) {
    LOG_FIRST_N(WARNING, 1)
        << "Requested to use GPU for bundle adjustment, but Ceres was "
           "compiled without cuDSS support. Falling back to CPU-based sparse "
           "solvers.";
  }
#endif

  if (cuda_solver_enabled) {
    const std::vector<int> gpu_indices = CSVToVector<int>(gpu_index);
    THROW_CHECK_GT(gpu_indices.size(), 0);
    SetBestCudaDevice(gpu_indices[0]);
  }
#else
  if (use_gpu) {
    LOG_FIRST_N(WARNING, 1)
        << "Requested to use GPU for bundle adjustment, but COLMAP was "
           "compiled without CUDA support. Falling back to CPU-based "
           "solvers.";
  }
#endif  // COLMAP_CUDA_ENABLED

  // [AETHER] Force EIGEN_SPARSE (Eigen SimplicialLDLT) for the CPU sparse path. Apple
  // Accelerate's sparse Cholesky FAILS (SparseFactorizationFailed) on the indefinite/
  // near-singular CAUCHY-reweighted Schur complement; Eigen's LDLT factorization handles
  // it. THIS is the real fix -- the earlier ITERATIVE_SCHUR forcing was a workaround for
  // using the wrong (Accelerate, default-priority) backend, not an algorithm limit.
  if (!use_gpu) {
    custom_solver_options.sparse_linear_algebra_library_type = ceres::EIGEN_SPARSE;
  }

  // [AETHER LAPACK spike 2026-07-05] env override wins over ALL routing below
  // (the vendored routing ignores caller options by design; this hook lets a
  // bench/device A/B force DENSE_SCHUR at any size). The dense BACKEND choice
  // (Eigen LLT vs Accelerate LAPACK) moved to the tier-routing block below,
  // which applies to EVERY route that lands on DENSE_SCHUR (this hook AND the
  // auto-selected production finalize path).
  // [B案-BA做快 2026-08-09 实验臂,默认不存在=零影响] 两张最后的牌的
  // host 测量旋钮(近似解/松绑类 —— 改结果,上桌必须用户签质量带):
  //   OFFICIAL_AETHER_EXTRA_SPSE=1  ITERATIVE_SCHUR + SPSE 预条件子
  //   OFFICIAL_AETHER_EXTRA_SPSE=2  SPSE 作线性求解器(PoBA 形态,Ceres 文档配方)
  //   OFFICIAL_AETHER_GLOBAL_PTOL=<x> is applied immediately before a
  //   ceres::Solve only while an explicit ScopedGlobalBaSolveV1 is active.
  //   Keeping the override out of this shared local/global option factory is
  //   what prevents the global experiment from leaking into local BA.
  if (const char* spse = std::getenv("OFFICIAL_AETHER_EXTRA_SPSE")) {
    custom_solver_options.linear_solver_type = ceres::ITERATIVE_SCHUR;
    if (spse[0] == '2') {
      custom_solver_options.preconditioner_type = ceres::IDENTITY;
      custom_solver_options.use_spse_initialization = true;
      custom_solver_options.max_num_spse_iterations = 5;
      custom_solver_options.spse_tolerance = 0.1;
      custom_solver_options.max_linear_solver_iterations = 0;
    } else {
      custom_solver_options.preconditioner_type =
          ceres::SCHUR_POWER_SERIES_EXPANSION;
    }
  } else
  if (std::getenv("OFFICIAL_AETHER_EXTRA_DENSE")) {
    custom_solver_options.linear_solver_type = ceres::DENSE_SCHUR;
  } else if (std::getenv("OFFICIAL_AETHER_EXTRA_SS")) {
    // [AETHER gold-fingerprint probe] SPARSE_SCHUR + SuiteSparse/CHOLMOD —
    // the June gold finalize ran inside the pycolmap wheel whose ceres links
    // SuiteSparse; finalize backend numerics visibly affect dense edge
    // sharpness (user eyeball: DENSE/LAPACK > SPARSE/EIGEN). Host homebrew
    // ceres has SuiteSparse; iOS would NOT ship this (GPL-adjacent CHOLMOD),
    // probe-only knob.
    custom_solver_options.linear_solver_type = ceres::SPARSE_SCHUR;
    custom_solver_options.sparse_linear_algebra_library_type =
        ceres::SUITE_SPARSE;
  } else
  // Auto-select solver type based on problem size, unless disabled.
  if (auto_select_solver_type) {
    if (num_images <= max_num_images_direct_dense_solver) {
      custom_solver_options.linear_solver_type = ceres::DENSE_SCHUR;
    } else if (has_sparse &&
               num_images <= max_num_images_direct_sparse_solver) {
      custom_solver_options.linear_solver_type = ceres::SPARSE_SCHUR;
    } else {  // Indirect sparse (preconditioned CG) solver.
      custom_solver_options.linear_solver_type = ceres::ITERATIVE_SCHUR;
      // [AETHER] A1 quality-neutral speedup: CLUSTER_JACOBI is a stronger preconditioner
      // than SCHUR_JACOBI -> fewer CG inner iterations -> faster convergence to the SAME
      // optimum (no quality change). Matters for the full-scene (>200 img) ITERATIVE path
      // that CAUCHY forces on iOS (Accelerate can't do SPARSE on robust-reweighted eqns).
      custom_solver_options.preconditioner_type = ceres::CLUSTER_JACOBI;
    }
  }

  // [AETHER DENSE-BACKEND TIER ROUTING 2026-07-12 — user-signed] Whenever the
  // routed solver is DENSE_SCHUR (production finalize: threshold 1000 in
  // incremental_pipeline.cc; bench: OFFICIAL_AETHER_EXTRA_DENSE), pick the dense
  // Cholesky backend by problem size:
  //   small scenes  -> EIGEN  (Eigen LLT: zero dispatch overhead; host scan
  //                            shows Accelerate has NO gain at <=200 imgs)
  //   large scenes  -> LAPACK (Apple Accelerate dpotrf/dpotrs, AMX-backed;
  //                            host 07-05 anchor: ~400 cams extra BA -65%)
  // Threshold = host inflection scan + 20% safety margin, rounded to tens —
  // see OFFICIAL_AETHER_DENSE_LAPACK_MIN_IMAGES default below. Env contract:
  //   OFFICIAL_AETHER_DENSE_LAPACK=1          force LAPACK (any size)
  //   OFFICIAL_AETHER_DENSE_LAPACK=0          force EIGEN  (any size)
  //   OFFICIAL_AETHER_DENSE_LAPACK_MIN_IMAGES override the auto threshold
  // Builds whose ceres lacks LAPACK (CERES_NO_LAPACK, e.g. Android/HarmonyOS)
  // stay on EIGEN — availability-guarded, never a hard failure. The
  // "[AETHER] solver_used=" log + finalize_segments dense_backend field report
  // whatever ceres ACTUALLY used (read back from the solve summary), so any
  // routing here stays observable end to end.
  if (custom_solver_options.linear_solver_type == ceres::DENSE_SCHUR &&
      custom_solver_options.dense_linear_algebra_library_type ==
          ceres::EIGEN) {
    bool want_lapack = false;
    if (const char* force = std::getenv("OFFICIAL_AETHER_DENSE_LAPACK")) {
      want_lapack = std::atoi(force) != 0;
    } else {
      int min_images = kAetherDenseLapackMinImagesDefault;
      if (const char* t = std::getenv("OFFICIAL_AETHER_DENSE_LAPACK_MIN_IMAGES"))
        min_images = std::atoi(t);
      want_lapack = min_images > 0 && num_images >= min_images;
    }
    if (want_lapack) {
      if (ceres::IsDenseLinearAlgebraLibraryTypeAvailable(ceres::LAPACK)) {
        custom_solver_options.dense_linear_algebra_library_type =
            ceres::LAPACK;
      } else {
        LOG_FIRST_N(WARNING, 1)
            << "[AETHER] dense tier routing wants LAPACK (num_images="
            << num_images << ") but this ceres build has no LAPACK support; "
               "staying on EIGEN.";
      }
    }
  }

  // [AETHER mixed-precision spike 2026-07-07] Factorize/solve the reduced camera
  // (Schur) system in float32, then run iterative refinement back to double.
  // Ceres 2.2 supports this for the CPU DENSE and EIGEN_SPARSE backends this
  // build uses (DENSE_SCHUR <=1000 frames, EIGEN_SPARSE fallback) — halves the
  // dominant dense-Cholesky cost. Near-lossless: refinement recovers double
  // accuracy. Env-gated for A/B; applies on top of whatever solver was routed.
  if (std::getenv("OFFICIAL_AETHER_MIXED_PREC")) {
    custom_solver_options.use_mixed_precision_solves = true;
    const char* refine = std::getenv("OFFICIAL_AETHER_MIXED_REFINE");
    custom_solver_options.max_num_refinement_iterations = refine ? std::atoi(refine) : 2;
  }

  // [AETHER BA-MIXED 2026-07-11] Finalize global BA mixed precision (opted in
  // per-options via use_mixed_precision_if_direct — set by the finalize
  // builders in aether_sfm_c.cc ONLY when OFFICIAL_AETHER_BA_MIXED=1; ⚠️ default OFF,
  // the 2026-07-11 host A/B vetoed default-on: +9.2% points / +0.027 reproj /
  // 9-gate 4/9 — see BaMixedEnabled() in aether_sfm_c.cc for the full
  // verdict). fp32 factorization + fp32 solve of the reduced camera system,
  // then OFFICIAL_AETHER_BA_MIXED_REFINE (default 3) fp64 iterative-refinement steps.
  // Gated on the ROUTED solver type:
  //   DENSE_SCHUR            -> FloatEigenDenseCholesky (+RefinedDenseCholesky)
  //   SPARSE_SCHUR non-SS    -> fp32 sparse Cholesky (+RefinedSparseCholesky)
  //   ITERATIVE_SCHUR        -> NOT supported (IsValid rejects) — stays fp64.
  if (use_mixed_precision_if_direct &&
      !custom_solver_options.use_mixed_precision_solves) {
    const ceres::LinearSolverType routed =
        custom_solver_options.linear_solver_type;
    const bool mixed_supported =
        routed == ceres::DENSE_SCHUR ||
        ((routed == ceres::SPARSE_SCHUR ||
          routed == ceres::SPARSE_NORMAL_CHOLESKY) &&
         custom_solver_options.sparse_linear_algebra_library_type !=
             ceres::SUITE_SPARSE);
    if (mixed_supported) {
      custom_solver_options.use_mixed_precision_solves = true;
      const char* refine = std::getenv("OFFICIAL_AETHER_BA_MIXED_REFINE");
      const int n_refine = refine ? std::atoi(refine) : 3;
      custom_solver_options.max_num_refinement_iterations =
          n_refine > 0 ? n_refine : 3;
    }
  }

  // [AETHER inner-iterations spike 2026-07-07] Variable-projection: each outer LM
  // step analytically re-optimizes the 3D point blocks given the current cameras.
  // The problem is point-dominated (~25k-250k points vs ~50-400 cameras), the
  // regime where inner iterations cut outer LM steps (fewer expensive Schur
  // solves) at the SAME optimum. No EvaluationCallback installed here (checked),
  // so it is compatible. Env-gated for A/B.
  if (std::getenv("OFFICIAL_AETHER_INNER_ITER")) {
    custom_solver_options.use_inner_iterations = true;
  }

  if (problem.NumResiduals() < min_num_residuals_for_cpu_multi_threading) {
    custom_solver_options.num_threads = 1;
#if CERES_VERSION_MAJOR < 2
    custom_solver_options.num_linear_solver_threads = 1;
#endif  // CERES_VERSION_MAJOR
  } else {
    custom_solver_options.num_threads =
        GetEffectiveNumThreads(custom_solver_options.num_threads);
#if CERES_VERSION_MAJOR < 2
    custom_solver_options.num_linear_solver_threads =
        GetEffectiveNumThreads(custom_solver_options.num_linear_solver_threads);
#endif  // CERES_VERSION_MAJOR
  }

  std::string solver_error;
  THROW_CHECK(custom_solver_options.IsValid(&solver_error)) << solver_error;
  return custom_solver_options;
}

bool CeresBundleAdjustmentOptions::Check() const {
  CHECK_OPTION_GE(loss_function_scale, 0);
  CHECK_OPTION_LT(max_num_images_direct_dense_cpu_solver,
                  max_num_images_direct_sparse_cpu_solver);
  CHECK_OPTION_LT(max_num_images_direct_dense_gpu_solver,
                  max_num_images_direct_sparse_gpu_solver);
  return true;
}

bool CeresPosePriorBundleAdjustmentOptions::Check() const {
  CHECK_OPTION_GT(prior_position_loss_scale, 0);
  return true;
}

namespace {

struct FixedGaugeWithThreePoints {
  // The number of fixed points for the Gauge.
  Eigen::Index num_fixed_points = 0;
  // The coordinates of the fixed points as columns.
  Eigen::Matrix3d fixed_points = Eigen::Matrix3d::Zero();
  bool MaybeAddFixedPoint(const Eigen::Vector3d& point) {
    if (num_fixed_points >= 3) {
      return false;
    }
    fixed_points.col(num_fixed_points) = point;
    if (fixed_points.colPivHouseholderQr().rank() > num_fixed_points) {
      ++num_fixed_points;
      return true;
    } else {
      fixed_points.col(num_fixed_points).setZero();
      return false;
    }
  }
};

void FixGaugeWithThreePoints(
    const std::unordered_map<point3D_t, size_t>& point3D_num_observations,
    Reconstruction& reconstruction,
    ceres::Problem& problem) {
  FixedGaugeWithThreePoints fixed_gauge;

  // First check if we already fixed enough points in the problem.
  for (const auto& [point3D_id, num_observations] : point3D_num_observations) {
    const Point3D& point3D = reconstruction.Point3D(point3D_id);
    if (problem.IsParameterBlockConstant(point3D.xyz.data()) &&
        fixed_gauge.MaybeAddFixedPoint(point3D.xyz) &&
        fixed_gauge.num_fixed_points >= 3) {
      return;
    }
  }

  // Otherwise, fix sufficient points in the problem.
  for (const auto& [point3D_id, num_observations] : point3D_num_observations) {
    Point3D& point3D = reconstruction.Point3D(point3D_id);
    if (!problem.IsParameterBlockConstant(point3D.xyz.data()) &&
        fixed_gauge.MaybeAddFixedPoint(point3D.xyz)) {
      problem.SetParameterBlockConstant(point3D.xyz.data());
      if (fixed_gauge.num_fixed_points >= 3) {
        return;
      }
    }
  }

  LOG(WARNING)
      << "Failed to fix Gauge due to insufficient number of fixed points: "
      << fixed_gauge.num_fixed_points;
}

// Note that the following implementation does not handle all degenerate edge
// cases well, e.g., where the selected two cameras are not well constrained
// with respect to each other with shared observations. Furthermore, the
// implementation could be more sophisticated for multi-camera rigs by selecting
// camera pairs within a rig, etc.
void FixGaugeWithTwoCamsFromWorld(
    const BundleAdjustmentOptions& options,
    const BundleAdjustmentConfig& config,
    const std::set<image_t>& image_ids,
    const std::unordered_map<point3D_t, size_t>& point3D_num_observations,
    Reconstruction& reconstruction,
    ceres::Problem& problem) {
  // No need to fix the Gauge if all frames are constant.
  if (!options.refine_rig_from_world) {
    return;
  }

  Image* image1 = nullptr;
  Image* image2 = nullptr;

  // Check if a sensor is either a reference sensor, or a non-reference sensor
  // with sensor_from_rig fixed.
  auto IsParameterizedConstSensor =
      [&problem, &config, &options](const Image& image) {
        const sensor_t sensor_id = image.CameraPtr()->SensorId();
        if (image.FramePtr()->RigPtr()->IsRefSensor(sensor_id)) {
          return true;
        }
        const Rigid3d& sensor_from_rig =
            image.FramePtr()->RigPtr()->SensorFromRig(sensor_id);
        if (problem.HasParameterBlock(sensor_from_rig.params.data()) &&
            problem.IsParameterBlockConstant(sensor_from_rig.params.data())) {
          return true;
        }
        // Cover corner case when ReprojErrorConstantPoseCostFunctor is used
        if (config.HasConstantSensorFromRigPose(sensor_id) ||
            !options.refine_sensor_from_rig) {
          return true;
        }
        return false;
      };

  // First, search through the already fixed cameras in the problem.
  for (const image_t image_id : image_ids) {
    Image& image = reconstruction.Image(image_id);
    if (config.HasConstantRigFromWorldPose(image.FrameId()) &&
        IsParameterizedConstSensor(image)) {
      if (image1 == nullptr) {
        image1 = &image;
      } else if (image1 != nullptr && image1->FrameId() != image.FrameId()) {
        // No need to fix the Gauge if two frames are already fixed.
        return;
      }
    }
  }

  // Otherwise, search through the variable cameras in the problem.
  int frame2_from_world_fixed_dim = 0;
  for (const image_t image_id : image_ids) {
    Image& image = reconstruction.Image(image_id);
    const Rigid3d& rig_from_world = image.FramePtr()->RigFromWorld();
    if (image1 == nullptr && IsParameterizedConstSensor(image)) {
      image1 = &image;
    } else if (image1 != nullptr && image1->FrameId() != image.FrameId() &&
               IsParameterizedConstSensor(image) &&
               problem.HasParameterBlock(rig_from_world.params.data())) {
      // Check if one of the baseline dimensions is large enough and
      // choose it as the fixed coordinate. If there is no such pair of
      // frames, then the scale is not constrained well.
      const Eigen::Vector3d baseline =
          (image1->FramePtr()->RigFromWorld() *
           Inverse(image.FramePtr()->RigFromWorld()))
              .translation();
      Eigen::Index max_coeff_idx = 0;
      if (baseline.cwiseAbs().maxCoeff(&max_coeff_idx) > 1e-9) {
        image2 = &image;
        frame2_from_world_fixed_dim = max_coeff_idx;
        break;
      }
    }
  }

  // TODO(jsch): Notice that we could alternatively fall back to fixing the
  // Gauge between two cameras in the same frame or in different frames. Since
  // there are many different combinations to iterate through, we instead fall
  // back to fixing the Gauge with three points for simplicity. Furthermore,
  // once we support IMUs or other sensors, we should fix the Gauge differently.
  if (image1 == nullptr || image2 == nullptr) {
    LOG(WARNING) << "Failed to fix Gauge with two cameras. "
                    "Falling back to fixing Gauge with three points.";
    FixGaugeWithThreePoints(point3D_num_observations, reconstruction, problem);
    return;
  }

  if (!config.HasConstantRigFromWorldPose(image1->FrameId())) {
    const Rigid3d& frame1_from_world = image1->FramePtr()->RigFromWorld();
    problem.SetParameterBlockConstant(frame1_from_world.params.data());
  }

  if (!config.HasConstantRigFromWorldPose(image2->FrameId())) {
    Rigid3d& frame2_from_world = image2->FramePtr()->RigFromWorld();
    if (options.constant_rig_from_world_rotation) {
      SetManifold(&problem,
                  frame2_from_world.params.data(),
                  CreateSubsetManifold(
                      7, {0, 1, 2, 3, 4 + frame2_from_world_fixed_dim}));
    } else {
      SetManifold(&problem,
                  frame2_from_world.params.data(),
                  CreateProductManifold(
                      CreateEigenQuaternionManifold(),
                      CreateSubsetManifold(3, {frame2_from_world_fixed_dim})));
    }
  }
}

void ParameterizeCameras(const BundleAdjustmentOptions& options,
                         const BundleAdjustmentConfig& config,
                         const std::set<camera_t>& camera_ids,
                         Reconstruction& reconstruction,
                         ceres::Problem& problem) {
  const bool constant_camera = !options.refine_focal_length &&
                               !options.refine_principal_point &&
                               !options.refine_extra_params;
  for (const camera_t camera_id : camera_ids) {
    Camera& camera = reconstruction.Camera(camera_id);

    if (constant_camera || config.HasConstantCamIntrinsics(camera_id)) {
      problem.SetParameterBlockConstant(camera.params.data());
    } else {
      std::vector<int> const_camera_params;
      const_camera_params.reserve(camera.params.size());

      {
        // Metadata parameters (e.g. the (w, h) image dimensions of spherical
        // models) are sensor properties and are never optimized.
        const span<const size_t> params_idxs = camera.MetaDataParamsIdxs();
        const_camera_params.insert(
            const_camera_params.end(), params_idxs.begin(), params_idxs.end());
      }
      if (!options.refine_focal_length) {
        const span<const size_t> params_idxs = camera.FocalLengthIdxs();
        const_camera_params.insert(
            const_camera_params.end(), params_idxs.begin(), params_idxs.end());
      }
      if (!options.refine_principal_point) {
        const span<const size_t> params_idxs = camera.PrincipalPointIdxs();
        const_camera_params.insert(
            const_camera_params.end(), params_idxs.begin(), params_idxs.end());
      }
      if (!options.refine_extra_params) {
        const span<const size_t> params_idxs = camera.ExtraParamsIdxs();
        const_camera_params.insert(
            const_camera_params.end(), params_idxs.begin(), params_idxs.end());
      }

      if (const_camera_params.size() == camera.params.size()) {
        problem.SetParameterBlockConstant(camera.params.data());
      } else if (!const_camera_params.empty()) {
        SetManifold(
            &problem,
            camera.params.data(),
            CreateSubsetManifold(camera.params.size(), const_camera_params));
      }
    }
  }
}

void ParameterizeRigsAndFrames(const BundleAdjustmentOptions& options,
                               const BundleAdjustmentConfig& config,
                               const std::set<image_t>& image_ids,
                               Reconstruction& reconstruction,
                               ceres::Problem& problem) {
  std::unordered_set<rig_t> parameterized_rig_ids;
  std::unordered_set<sensor_t> parameterized_sensor_ids;
  std::unordered_set<frame_t> parameterized_frame_ids;
  for (const image_t image_id : image_ids) {
    Image& image = reconstruction.Image(image_id);
    parameterized_rig_ids.insert(image.FramePtr()->RigId());

    // Parameterize sensor_from_rig.
    const sensor_t sensor_id = image.CameraPtr()->SensorId();
    const bool not_parameterized_before =
        parameterized_sensor_ids.insert(sensor_id).second;
    if (not_parameterized_before && !image.IsRefInFrame()) {
      Rigid3d& sensor_from_rig =
          image.FramePtr()->RigPtr()->SensorFromRig(sensor_id);
      // CostFunction assumes unit quaternions.
      sensor_from_rig.rotation().normalize();
      if (problem.HasParameterBlock(sensor_from_rig.params.data())) {
        SetManifold(&problem,
                    sensor_from_rig.params.data(),
                    CreateProductManifold(CreateEigenQuaternionManifold(),
                                          CreateEuclideanManifold<3>()));
        if (!options.refine_sensor_from_rig ||
            config.HasConstantSensorFromRigPose(sensor_id)) {
          problem.SetParameterBlockConstant(sensor_from_rig.params.data());
        }
      }
    }

    // Parameterize rig_from_world.
    if (parameterized_frame_ids.insert(image.FrameId()).second) {
      Rigid3d& rig_from_world = image.FramePtr()->RigFromWorld();
      // CostFunction assumes unit quaternions.
      rig_from_world.rotation().normalize();
      if (problem.HasParameterBlock(rig_from_world.params.data())) {
        if (!options.refine_rig_from_world ||
            config.HasConstantRigFromWorldPose(image.FrameId())) {
          problem.SetParameterBlockConstant(rig_from_world.params.data());
        } else if (options.constant_rig_from_world_rotation) {
          SetManifold(&problem,
                      rig_from_world.params.data(),
                      CreateSubsetManifold(7, {0, 1, 2, 3}));
        } else {
          SetManifold(&problem,
                      rig_from_world.params.data(),
                      CreateProductManifold(CreateEigenQuaternionManifold(),
                                            CreateEuclideanManifold<3>()));
        }
      }
    }
  }

  // Set the rig poses as constant, if the reference sensor is not part of the
  // problem. Otherwise, the relative pose between the sensors is not well
  // constrained. Notice that this does not handle degenerate configurations and
  // assumes the observations in the problem constrain the relative poses
  // sufficiently.
  for (const rig_t rig_id : parameterized_rig_ids) {
    Rig& rig = reconstruction.Rig(rig_id);
    if (parameterized_sensor_ids.count(rig.RefSensorId()) != 0) {
      continue;
    }
    for (auto& [sensor_id, sensor_from_rig] : rig.NonRefSensors()) {
      THROW_CHECK(sensor_from_rig.has_value());
      if (problem.HasParameterBlock(sensor_from_rig->params.data())) {
        problem.SetParameterBlockConstant(sensor_from_rig->params.data());
      }
    }
  }
}

void ParameterizePoints(
    const BundleAdjustmentOptions& options,
    const BundleAdjustmentConfig& config,
    const std::unordered_map<point3D_t, size_t>& point3D_num_observations,
    Reconstruction& reconstruction,
    ceres::Problem& problem) {
  for (const auto& [point3D_id, num_observations] : point3D_num_observations) {
    Point3D& point3D = reconstruction.Point3D(point3D_id);
    if (!options.refine_points3D || point3D.track.Length() > num_observations) {
      problem.SetParameterBlockConstant(point3D.xyz.data());
    }
  }

  for (const point3D_t point3D_id : config.ConstantPoints()) {
    Point3D& point3D = reconstruction.Point3D(point3D_id);
    problem.SetParameterBlockConstant(point3D.xyz.data());
  }
}

std::shared_ptr<CeresBundleAdjustmentSummary> CreateSummaryAndLogFailure(
    ceres::Solver::Summary ceres_summary, const std::string& context) {
  auto summary = CeresBundleAdjustmentSummary::Create(std::move(ceres_summary));
  if (!summary->IsSolutionUsable()) {
    LOG(ERROR) << context << " failed: " << summary->ceres_summary.message;
  }
  return summary;
}

void AppendAetherBaSolveReceiptV1(
    uint64_t solve_seq,
    aether::official::ba::SolveScopeV1 scope,
    const aether::official::ba::GlobalPtolResolutionV1& ptol,
    bool gpu_fallback,
    const ceres::Solver::Summary& ceres_summary) {
  aether::official::ba::BaSolveReceiptV1 r;
  r.total_s = ceres_summary.total_time_in_seconds;
  r.jac_s = ceres_summary.jacobian_evaluation_time_in_seconds;
  r.lin_s = ceres_summary.linear_solver_time_in_seconds;
  r.res_s = ceres_summary.residual_evaluation_time_in_seconds;
  r.pre_s = ceres_summary.preprocessor_time_in_seconds;
  r.min_s = ceres_summary.minimizer_time_in_seconds;
  r.post_s = ceres_summary.postprocessor_time_in_seconds;
  r.iters = ceres_summary.num_successful_steps +
            ceres_summary.num_unsuccessful_steps;
  r.term = static_cast<int>(ceres_summary.termination_type);
  r.threads = ceres_summary.num_threads_used;
  r.solve_seq = solve_seq;
  r.scope = scope;
  r.ptol = ptol;
  r.gpu_fallback = gpu_fallback;
  if (!aether::official::ba::RecordBaSessionSolveReceiptV1(r)) {
    LOG(ERROR) << "[AETHER][PTOL] unbound ceres::Solve receipt seq="
               << solve_seq << " scope="
               << aether::official::ba::SolveScopeNameV1(scope);
  }
}

// [AETHER BA-ORDERING 观测 2026-09-08] 生效自证必须落盘。
// 教训:第一版只把 blocks/pts/cams/proven 打到 stderr,而 detached 的真机运行会丢
// stderr(SOP §1 早写过),结果 build 117 装上去之后根本无法从设备侧证明这把刀跑没跑,
// 只能靠跨场归一化猜 —— 那不是判据。计数器随 ilr_* 一起进 frame_split。
extern "C" int aether_ilr_ord_applied = 0;   // 本帧真正设上 ordering 的求解次数
extern "C" int aether_ilr_ord_skipped = 0;   // 守卫不通过 / 旋钮关掉 而未设的次数

ceres::Solver::Summary SolveWithGpuFallback(
    const BundleAdjustmentOptions& options,
    const BundleAdjustmentConfig& config,
    ceres::Problem* problem) {
  ceres::Solver::Options solver_options =
      options.ceres->CreateSolverOptions(config, *problem);
  // [AETHER BA-ORDERING 2026-09-07 默认开;回退 OFFICIAL_AETHER_BA_NOORDERING=1]
  // COLMAP 的 BA 从不设 linear_solver_ordering(全仓 grep:只有 glomap
  // global_positioning.cc:277 设),所以每次 Solve() Ceres 都自己重推 Schur 消元序。
  // 那正是 [AETHER-T2] ilr_pre 量到的段:host 10.3 ms/帧、A16 17.6 ms/帧(局部 BA 6.3%),
  // 而 IterativeLocalRefinement 每帧跑 2 轮 => 每帧付两次。
  // 出处:Ceres 自己的 examples/bundle_adjuster.cc 的 SetOrdering()(点=消元组 0、
  // 相机=组 1);同款写法本仓已有先例(global_positioning.cc:277)。
  // 同样的数学 —— 只是把 Ceres 本来要搜的答案直接递给它。
  // host 配对交替 x3:ilr_pre -45%、局部 BA -5.9%,cloud.ply sha 与 RESULT 全同。
  //
  // 分类的正确性靠证明,不靠"块大小==3"这个猜:
  //   前置 A:内参不可变(refine_focal_length/principal_point/extra_params 全 false)
  //     => 内参块是常量块,被 IsParameterBlockConstant 排除,3 维可变块只可能是点 xyz。
  //   前置 B:组 1 的块全是 7 维(Rigid3d:四元数 4 + 平移 3 连续存)
  //     => 位姿没有被拆成 quat(4)/trans(3) 两块 => 3 维可变块只可能是点 xyz
  //     => 组 0 恰好是全部可变点;BA 里任意两个 3D 点不共享残差 => 独立集成立。
  //   (最初写的是 n_pts == config.NumVariablePoints(),错的:那 4398 个点块是
  //    AddImageToProblem 加残差时隐式带进来的,VariablePoints() 只数显式标记的。)
  // 有一条不成立就不设 ordering,退回 Ceres 自搜(fail-safe,行为=改动前)。
  const bool ord_enabled =
      std::getenv("OFFICIAL_AETHER_BA_NOORDERING") == nullptr &&
      !options.refine_focal_length && !options.refine_principal_point &&
      !options.refine_extra_params;
  if (!ord_enabled) { ++aether_ilr_ord_skipped; }
  if (ord_enabled) {
    auto ordering = std::make_shared<ceres::ParameterBlockOrdering>();
    std::vector<double*> blocks;
    problem->GetParameterBlocks(&blocks);
    size_t n_pts = 0, n_cam = 0;
    bool all_g1_are_poses = true;
    for (double* pb : blocks) {
      if (problem->IsParameterBlockConstant(pb)) continue;
      const int sz = problem->ParameterBlockSize(pb);
      if (sz == 3) {
        ordering->AddElementToGroup(pb, 0);
        ++n_pts;
      } else {
        // Rigid3d(四元数 4 + 平移 3 连续存)= 7。任何别的尺寸都说明这棵树里
        // 位姿被拆开存了(quat 4 / trans 3),那时 3 维块不再只可能是点 => 不敢用。
        if (sz != 7) all_g1_are_poses = false;
        ordering->AddElementToGroup(pb, 1);
        ++n_cam;
      }
    }
    const bool proven = all_g1_are_poses && n_pts > 0 && n_cam > 0;
    if (proven) { ++aether_ilr_ord_applied; } else { ++aether_ilr_ord_skipped; }
    static std::atomic<int> ord_logged{0};
    if (ord_logged.fetch_add(1) < 3) {
      std::fprintf(stderr,
                   "[AETHER BA-ORDERING] blocks=%zu pts(g0)=%zu cams(g1)=%zu "
                   "g1_all_pose=%d proven=%d\n",
                   blocks.size(), n_pts, n_cam, all_g1_are_poses ? 1 : 0,
                   proven ? 1 : 0);
    }
    if (proven) {
      solver_options.linear_solver_ordering = std::move(ordering);
    }
  }
  const aether::official::ba::SolveScopeV1 scope =
      aether::official::ba::CurrentBaSolveScopeV1();
  const aether::official::ba::GlobalPtolResolutionV1 ptol =
      aether::official::ba::ResolveGlobalPtolV1(
          std::getenv("OFFICIAL_AETHER_GLOBAL_PTOL"),
          scope,
          solver_options.parameter_tolerance);
  solver_options.parameter_tolerance = ptol.effective;

  ceres::Solver::Summary ceres_summary;
  const uint64_t solve_seq =
      g_aether_ba_solve_seq.fetch_add(1, std::memory_order_relaxed);
  ceres::Solve(solver_options, problem, &ceres_summary);
  AppendAetherBaSolveReceiptV1(
      solve_seq, scope, ptol, /*gpu_fallback=*/false, ceres_summary);

  if (ceres_summary.termination_type == ceres::FAILURE &&
      options.ceres->use_gpu) {
    const std::string& msg = ceres_summary.message;
    if (msg.find("CUDA initialization failed") != std::string::npos ||
        msg.find("non-numeric") != std::string::npos ||
        msg.find("Unable to create Jacobian") != std::string::npos) {
      LOG(WARNING) << "GPU bundle adjustment failed (" << msg
                   << "), retrying with CPU.";
      auto cpu_options =
          std::make_shared<CeresBundleAdjustmentOptions>(*options.ceres);
      cpu_options->use_gpu = false;
      ceres::Solver::Options cpu_solver_options =
          cpu_options->CreateSolverOptions(config, *problem);
      const aether::official::ba::GlobalPtolResolutionV1 cpu_ptol =
          aether::official::ba::ResolveGlobalPtolV1(
              std::getenv("OFFICIAL_AETHER_GLOBAL_PTOL"),
              scope,
              cpu_solver_options.parameter_tolerance);
      cpu_solver_options.parameter_tolerance = cpu_ptol.effective;
      const uint64_t cpu_solve_seq =
          g_aether_ba_solve_seq.fetch_add(1, std::memory_order_relaxed);
      ceres::Solve(cpu_solver_options, problem, &ceres_summary);
      AppendAetherBaSolveReceiptV1(
          cpu_solve_seq, scope, cpu_ptol, /*gpu_fallback=*/true, ceres_summary);
    }
  }

  // [AETHER] Unconditionally log which linear solver + sparse backend Ceres ACTUALLY
  // used. Confirms the iOS EIGEN_SPARSE fix: for the full-capture CAUCHY finalize this
  // must read SPARSE_SCHUR + EIGEN_SPARSE (NOT ITERATIVE_SCHUR, NOT SUITE_SPARSE/
  // ACCELERATE which crash on the indefinite Schur complement).
  LOG(INFO) << "[AETHER] solver_used="
            << ceres::LinearSolverTypeToString(ceres_summary.linear_solver_type_used)
            << " sparse_backend=" << ceres::SparseLinearAlgebraLibraryTypeToString(
                   ceres_summary.sparse_linear_algebra_library_type)
            // [AETHER LAPACK 2026-07-12] dense backend (EIGEN vs LAPACK/
            // Accelerate) — device A/B for the OFFICIAL_AETHER_DENSE_LAPACK switch.
            << " dense_backend=" << ceres::DenseLinearAlgebraLibraryTypeToString(
                   ceres_summary.dense_linear_algebra_library_type)
            // [AETHER BA-MIXED/THREADS 2026-07-11] A/B verification fields.
            << " mixed=" << (ceres_summary.mixed_precision_solves_used ? 1 : 0)
            << " threads=" << ceres_summary.num_threads_used;

  // [AETHER FINALIZE-SEGMENTS 2026-07-11] Same fields into the process-wide
  // stash (AetherLastBaSolveInfo) so the finalize worker can persist them —
  // the LOG line above only reaches stderr, which detached device runs lose.
  {
    std::lock_guard<std::mutex> lk(AetherLastSolveMutex());
    g_aether_last_solver_used = ceres::LinearSolverTypeToString(
        ceres_summary.linear_solver_type_used);
    g_aether_last_sparse_backend =
        ceres::SparseLinearAlgebraLibraryTypeToString(
            ceres_summary.sparse_linear_algebra_library_type);
    g_aether_last_dense_backend =
        ceres::DenseLinearAlgebraLibraryTypeToString(
            ceres_summary.dense_linear_algebra_library_type);
    g_aether_last_mixed = ceres_summary.mixed_precision_solves_used ? 1 : 0;
    g_aether_last_threads = ceres_summary.num_threads_used;
  }

  return ceres_summary;
}

class DefaultBundleAdjuster : public CeresBundleAdjuster {
 public:
  DefaultBundleAdjuster(const BundleAdjustmentOptions& options,
                        const BundleAdjustmentConfig& config,
                        Reconstruction& reconstruction)
      : CeresBundleAdjuster(options, config),
        loss_function_(options_.ceres->CreateLossFunction()) {
    ceres::Problem::Options problem_options;
    problem_options.loss_function_ownership = ceres::DO_NOT_TAKE_OWNERSHIP;
    // [AETHER BA-FASTPROBLEM 2026-09-07 默认开;回退 OFFICIAL_AETHER_BA_NOFASTPROBLEM=1]
    // ceres::Problem::Options::disable_all_safety_checks —— Ceres 文档的性能开关,
    // 跳过每次 AddResidualBlock 的逐次校验。局部 BA 每轮建 ~36k 残差块、每帧 2 轮;
    // [AETHER-T2] ilr_setup 占局部 BA 的 11.2%(host)/7.8%(A16)。同样的数学。
    // host 配对交替 x3:ilr_setup -15%,cloud.ply sha 与 RESULT 全同。
    if (std::getenv("OFFICIAL_AETHER_BA_NOFASTPROBLEM") == nullptr) {
      problem_options.disable_all_safety_checks = true;
    }
    problem_ = std::make_shared<ceres::Problem>(problem_options);

    // Verify that reconstruction is internally consistent.
    THROW_CHECK(reconstruction.IsValid());

    // Set up problem.
    // Warning: AddPointsToProblem assumes that AddImageToProblem is called
    // first. Do not change order of instructions!
    for (const image_t image_id : config_.Images()) {
      AddImageToProblem(image_id, reconstruction);
    }
    for (const auto point3D_id : config_.VariablePoints()) {
      AddPointToProblem(point3D_id, reconstruction);
    }
    for (const auto point3D_id : config_.ConstantPoints()) {
      AddPointToProblem(point3D_id, reconstruction);
    }

    ParameterizeCameras(options_,
                        config_,
                        parameterized_camera_ids_,
                        reconstruction,
                        *problem_);
    ParameterizeRigsAndFrames(
        options_, config_, parameterized_image_ids_, reconstruction, *problem_);
    ParameterizePoints(options_,
                       config_,
                       point3D_num_observations_,
                       reconstruction,
                       *problem_);

    switch (config_.FixedGauge()) {
      case BundleAdjustmentGauge::UNSPECIFIED:
        break;
      case BundleAdjustmentGauge::TWO_CAMS_FROM_WORLD:
        FixGaugeWithTwoCamsFromWorld(options_,
                                     config_,
                                     parameterized_image_ids_,
                                     point3D_num_observations_,
                                     reconstruction,
                                     *problem_);
        break;
      case BundleAdjustmentGauge::THREE_POINTS:
        FixGaugeWithThreePoints(
            point3D_num_observations_, reconstruction, *problem_);
        break;
      default:
        LOG(FATAL_THROW) << "Unknown BundleAdjustmentGauge";
    }

    // [AETHER position-prior spike 2026-07-10] optional soft camera-center
    // priors (no-op when the global registry is empty).
    MaybeAddAetherPositionPriors(reconstruction);

    // [MANDATORY ARKIT GRAVITY V1] Every production frame contributes a
    // roll/pitch residual. Unlike the historical position-prior experiment,
    // this is not an optional quality arm: the streaming ingest path refuses
    // frames without a valid gravity-aligned ARKit pose.
    MaybeAddAetherGravityPriors(reconstruction);
  }

  std::shared_ptr<BundleAdjustmentSummary> Solve() override {
    if (problem_->NumResiduals() == 0) {
      return std::make_shared<BundleAdjustmentSummary>();
    }

    ceres::Solver::Summary ceres_summary =
        SolveWithGpuFallback(options_, config_, problem_.get());

    if (options_.print_summary || VLOG_IS_ON(1)) {
      PrintSolverSummary(ceres_summary, "Bundle adjustment report");
    }

    return CreateSummaryAndLogFailure(std::move(ceres_summary),
                                      "Bundle adjustment");
  }

  std::shared_ptr<ceres::Problem>& Problem() override { return problem_; }

  const std::set<image_t>& ParameterizedImageIds() const {
    return parameterized_image_ids_;
  }

  void AddImageToProblem(const image_t image_id,
                         Reconstruction& reconstruction) {
    Image& image = reconstruction.Image(image_id);

    if (image.IsRefInFrame()) {
      AddImageWithTrivialFrame(image, reconstruction);
    } else {
      AddImageWithNonTrivialFrame(image, reconstruction);
    }
  }

  void AddImageWithTrivialFrame(Image& image, Reconstruction& reconstruction) {
    Camera& camera = *image.CameraPtr();

    const bool constant_cam_from_world =
        !options_.refine_rig_from_world ||
        config_.HasConstantRigFromWorldPose(image.FrameId());

    THROW_CHECK(image.IsRefInFrame());
    Rigid3d& rig_from_world = image.FramePtr()->RigFromWorld();

    // Add residuals to bundle adjustment problem.
    size_t num_observations = 0;
    for (const Point2D& point2D : image.Points2D()) {
      if (!point2D.HasPoint3D() || config_.IsIgnoredPoint(point2D.point3D_id)) {
        continue;
      }

      Point3D& point3D = reconstruction.Point3D(point2D.point3D_id);
      THROW_CHECK_GT(point3D.track.Length(), 1);

      // Skip points with track length below minimum.
      if (options_.min_track_length > 0 &&
          static_cast<int>(point3D.track.Length()) <
              options_.min_track_length) {
        continue;
      }

      num_observations += 1;
      point3D_num_observations_[point2D.point3D_id] += 1;

      if (constant_cam_from_world) {
        problem_->AddResidualBlock(
            CreateCameraCostFunction<ReprojErrorConstantPoseCostFunctor>(
                camera.model_id, point2D.xy, rig_from_world),
            loss_function_.get(),
            point3D.xyz.data(),
            camera.params.data());
      } else {
        // [ANALYTIC-JAC-PROBE] 默认分支 = 工厂自动选解析版(PINHOLE 命中);
        // 诊断开关强制自动微分,用于量解析版的真实收益。
        problem_->AddResidualBlock(
            ForceAutoDiffJacobians()
                ? CreateAutoDiffOnlyCameraCostFunction<ReprojErrorCostFunctor>(
                      camera.model_id, point2D.xy)
                : CreateCameraCostFunction<ReprojErrorCostFunctor>(
                      camera.model_id, point2D.xy),
            loss_function_.get(),
            point3D.xyz.data(),
            rig_from_world.params.data(),
            camera.params.data());
      }
    }

    if (num_observations > 0) {
      parameterized_camera_ids_.insert(image.CameraId());
      parameterized_image_ids_.insert(image.ImageId());
    }
  }

  void AddImageWithNonTrivialFrame(Image& image,
                                   Reconstruction& reconstruction) {
    Camera& camera = *image.CameraPtr();
    const sensor_t sensor_id = camera.SensorId();

    const bool constant_sensor_from_rig =
        !options_.refine_sensor_from_rig ||
        config_.HasConstantSensorFromRigPose(sensor_id);
    const bool constant_rig_from_world =
        !options_.refine_rig_from_world ||
        config_.HasConstantRigFromWorldPose(image.FrameId());

    THROW_CHECK(!image.IsRefInFrame());
    Rigid3d& sensor_from_rig =
        image.FramePtr()->RigPtr()->SensorFromRig(sensor_id);
    Rigid3d& rig_from_world = image.FramePtr()->RigFromWorld();
    const std::optional<Rigid3d> cam_from_world =
        (constant_sensor_from_rig && constant_rig_from_world)
            ? std::make_optional<Rigid3d>(sensor_from_rig * rig_from_world)
            : std::nullopt;

    // Add residuals to bundle adjustment problem.
    size_t num_observations = 0;
    for (const Point2D& point2D : image.Points2D()) {
      if (!point2D.HasPoint3D() || config_.IsIgnoredPoint(point2D.point3D_id)) {
        continue;
      }

      Point3D& point3D = reconstruction.Point3D(point2D.point3D_id);
      THROW_CHECK_GT(point3D.track.Length(), 1);

      // Skip points with track length below minimum.
      if (options_.min_track_length > 0 &&
          static_cast<int>(point3D.track.Length()) <
              options_.min_track_length) {
        continue;
      }

      num_observations += 1;
      point3D_num_observations_[point2D.point3D_id] += 1;

      // The !constant_sensor_from_rig && constant_rig_from_world is
      // rare enough that we do not have a specialized cost function for it.
      if (constant_sensor_from_rig && constant_rig_from_world) {
        problem_->AddResidualBlock(
            CreateCameraCostFunction<ReprojErrorConstantPoseCostFunctor>(
                camera.model_id, point2D.xy, cam_from_world.value()),
            loss_function_.get(),
            point3D.xyz.data(),
            camera.params.data());
      } else if (!constant_rig_from_world && constant_sensor_from_rig) {
        problem_->AddResidualBlock(
            CreateCameraCostFunction<RigReprojErrorConstantRigCostFunctor>(
                camera.model_id, point2D.xy, sensor_from_rig),
            loss_function_.get(),
            point3D.xyz.data(),
            rig_from_world.params.data(),
            camera.params.data());
      } else {
        problem_->AddResidualBlock(
            CreateCameraCostFunction<RigReprojErrorCostFunctor>(camera.model_id,
                                                                point2D.xy),
            loss_function_.get(),
            point3D.xyz.data(),
            sensor_from_rig.params.data(),
            rig_from_world.params.data(),
            camera.params.data());
      }
    }

    if (num_observations > 0) {
      parameterized_camera_ids_.insert(image.CameraId());
      parameterized_image_ids_.insert(image.ImageId());
    }
  }

  void AddPointToProblem(const point3D_t point3D_id,
                         Reconstruction& reconstruction) {
    THROW_CHECK(!config_.IsIgnoredPoint(point3D_id));
    Point3D& point3D = reconstruction.Point3D(point3D_id);

    // Skip points with track length below minimum.
    if (options_.min_track_length > 0 &&
        static_cast<int>(point3D.track.Length()) < options_.min_track_length) {
      return;
    }

    size_t& num_observations = point3D_num_observations_[point3D_id];

    // Is 3D point already fully contained in the problem? I.e. its entire
    // track is contained in `variable_image_ids`, `constant_image_ids`,
    // `constant_x_image_ids`.
    if (num_observations == point3D.track.Length()) {
      return;
    }

    for (const auto& track_el : point3D.track.Elements()) {
      // Skip observations that were already added in `FillImages`.
      if (config_.HasImage(track_el.image_id)) {
        continue;
      }

      num_observations += 1;

      Image& image = reconstruction.Image(track_el.image_id);
      Camera& camera = *image.CameraPtr();
      const Point2D& point2D = image.Point2D(track_el.point2D_idx);

      if (image.IsRefInFrame()) {
        Rigid3d& cam_from_world = image.FramePtr()->RigFromWorld();

        problem_->AddResidualBlock(
            CreateCameraCostFunction<ReprojErrorConstantPoseCostFunctor>(
                camera.model_id, point2D.xy, cam_from_world),
            loss_function_.get(),
            point3D.xyz.data(),
            camera.params.data());
      } else {
        Rigid3d& cam_from_rig = image.FramePtr()->RigPtr()->SensorFromRig(
            image.CameraPtr()->SensorId());
        Rigid3d& rig_from_world = image.FramePtr()->RigFromWorld();

        problem_->AddResidualBlock(
            CreateCameraCostFunction<ReprojErrorConstantPoseCostFunctor>(
                camera.model_id, point2D.xy, cam_from_rig * rig_from_world),
            loss_function_.get(),
            point3D.xyz.data(),
            camera.params.data());
      }

      // Do not optimize intrinsics if th corresponding images
      // were not included explicitly in the config.
      if (parameterized_camera_ids_.insert(image.CameraId()).second) {
        config_.SetConstantCamIntrinsics(image.CameraId());
      }
    }
  }

  // [AETHER position-prior spike 2026-07-10] Inject soft camera-center priors
  // for every parameterized image whose name is in the global registry.
  // Alignment (Sim3, metric ARKit -> current COLMAP frame) is re-estimated per
  // problem from the CURRENT reconstruction centers via Eigen::umeyama; sigma
  // is scaled by the estimated Sim3 scale. Only trivial-frame (ref-in-frame)
  // images with a VARIABLE rig_from_world block get a residual; needs >= 6
  // matched frames so tiny problems (initial pair BA, single-image pose
  // refinement) and degenerate umeyama fits are skipped.
  void MaybeAddAetherPositionPriors(Reconstruction& reconstruction) {
    auto& reg = GetAetherPositionPriorRegistry();
    std::lock_guard<std::mutex> lock(reg.mutex);
    if (reg.centers_metric.empty()) {
      return;
    }

    struct MatchedPrior {
      Image* image;
      Eigen::Vector3d center_metric;
    };
    std::vector<MatchedPrior> matched;
    matched.reserve(parameterized_image_ids_.size());
    for (const image_t image_id : parameterized_image_ids_) {
      Image& image = reconstruction.Image(image_id);
      if (!image.IsRefInFrame()) {
        continue;  // capture rig is trivial frames; skip non-ref sensors
      }
      const auto it = reg.centers_metric.find(image.Name());
      if (it == reg.centers_metric.end()) {
        continue;
      }
      matched.push_back({&image, it->second});
    }
    if (matched.size() < 6) {
      return;
    }

    Eigen::Matrix3Xd src(3, matched.size());
    Eigen::Matrix3Xd dst(3, matched.size());
    for (size_t i = 0; i < matched.size(); ++i) {
      src.col(i) = matched[i].center_metric;
      dst.col(i) = matched[i].image->ProjectionCenter();
    }
    const Eigen::Matrix4d tform =
        Eigen::umeyama(src, dst, /*with_scaling=*/true);
    const Eigen::Matrix3d scaled_rot = tform.topLeftCorner<3, 3>();
    const Eigen::Vector3d translation = tform.topRightCorner<3, 1>();
    const double scale = std::cbrt(scaled_rot.determinant());
    if (!std::isfinite(scale) || scale <= 1e-12) {
      return;
    }
    const double sigma_colmap = reg.sigma_m * scale;
    const Eigen::Matrix3d prior_cov =
        sigma_colmap * sigma_colmap * Eigen::Matrix3d::Identity();

    if (!aether_prior_loss_) {
      // Huber in units of sigma: quadratic inside 1 sigma, linear beyond.
      aether_prior_loss_ = std::make_unique<ceres::HuberLoss>(1.0);
    }

    int num_added = 0;
    double align_sq_sum = 0.0;
    for (const auto& m : matched) {
      Rigid3d& rig_from_world = m.image->FramePtr()->RigFromWorld();
      double* pose_params = rig_from_world.params.data();
      if (!problem_->HasParameterBlock(pose_params) ||
          problem_->IsParameterBlockConstant(pose_params)) {
        continue;  // constant pose: prior would be a no-op
      }
      const Eigen::Vector3d prior_in_colmap =
          scaled_rot * m.center_metric + translation;
      align_sq_sum +=
          (prior_in_colmap - m.image->ProjectionCenter()).squaredNorm();
      problem_->AddResidualBlock(
          CovarianceWeightedCostFunctor<AbsolutePosePositionPriorCostFunctor>::
              Create(prior_cov, prior_in_colmap),
          aether_prior_loss_.get(),
          pose_params);
      ++num_added;
    }
    if (num_added > 0) {
      LOG(INFO) << "[AETHER prior] injected " << num_added << "/"
                << matched.size()
                << " center priors, sim3_scale=" << scale
                << " sigma_colmap=" << sigma_colmap << " align_rms="
                << std::sqrt(align_sq_sum / num_added) << " ("
                << std::sqrt(align_sq_sum / num_added) / scale << " m)";
    }
  }

  void MaybeAddAetherGravityPriors(Reconstruction& reconstruction) {
    auto& reg = GetAetherGravityPriorRegistry();
    std::lock_guard<std::mutex> lock(reg.mutex);
    if (reg.gravity_cam.empty() || !std::isfinite(reg.sigma_rad) ||
        reg.sigma_rad <= 0.0) {
      return;
    }

    int num_added = 0;
    int num_eligible = 0;
    int num_missing = 0;
    int num_inconsistent = 0;
    const double inverse_sigma = 1.0 / reg.sigma_rad;
    for (const image_t image_id : parameterized_image_ids_) {
      Image& image = reconstruction.Image(image_id);
      if (!image.IsRefInFrame()) {
        continue;
      }
      ++num_eligible;
      const auto it = reg.gravity_cam.find(image.Name());
      if (it == reg.gravity_cam.end() ||
          !aether::sfm::IsValidGravityBaPriorV1(it->second)) {
        // Ingest is fail-closed: no frame reaches the db without a registered
        // prior. Reaching this line therefore means the registry lost an entry
        // that must exist — the process-global table is keyed by image name
        // alone, so a second session that reuses "frame_%06d.jpg" can overwrite
        // or clear it while this solve is still running. That used to be
        // completely silent (skip, and no log at all when nothing was added),
        // so the "mandatory" constraint could vanish with zero evidence.
        ++num_missing;
        continue;
      }
      Rigid3d& rig_from_world = image.FramePtr()->RigFromWorld();
      double* pose_params = rig_from_world.params.data();
      if (!problem_->HasParameterBlock(pose_params) ||
          problem_->IsParameterBlockConstant(pose_params)) {
        continue;
      }
      // [ANCHOR-CONSISTENCY 2026-08-04] The registered vector is derived from
      // the very ARKit quaternion that seeded this frame's pose, so at ingest
      // R_cam_from_world * (0,-1,0) IS the registered vector and the residual
      // is identically zero. That makes the anchor self-checkable: recompute it
      // from the pose we are about to constrain. A gross mismatch cannot come
      // from optimization drift (roll/pitch stays well under a degree); it means
      // either the process-global, name-keyed registry handed us an entry
      // belonging to another capture session that reused "frame_%06d.jpg", or
      // the ARKit->COLMAP conversion regressed. Because the residual starts at
      // zero, neither failure is observable from residual magnitudes alone —
      // this is the only place they can be caught.
      constexpr double kMinAnchorConsistencyCos = 0.866;  // 30 degrees
      const Eigen::Vector3d predicted_gravity =
          rig_from_world.rotation() * Eigen::Vector3d(0.0, -1.0, 0.0);
      if (predicted_gravity.norm() <= 0.0 ||
          predicted_gravity.normalized().dot(it->second.normalized()) <
              kMinAnchorConsistencyCos) {
        ++num_inconsistent;
        continue;
      }
      problem_->AddResidualBlock(
          new ceres::AutoDiffCostFunction<aether::sfm::GravityBaPriorCostV1,
                                          3,
                                          7>(
              new aether::sfm::GravityBaPriorCostV1(it->second,
                                                    inverse_sigma)),
          // Robustified, exactly like the position prior above. This term is
          // an attitude anchor onto a VIO measurement that can be transiently
          // wrong (thermal throttling, relocalization jumps), and it is applied
          // to every frame at a tight sigma, so an unrobustified squared cost
          // let one bad frame pull the whole solve. The asymmetry with the
          // position prior was not deliberate.
          aether_prior_loss_.get(),
          pose_params);
      ++num_added;
    }
    if (num_eligible > 0) {
      // Always log the denominator: "injected N" alone cannot distinguish a
      // healthy solve from one where the registry was silently emptied.
      LOG(INFO) << "[AETHER gravity] injected " << num_added << "/"
                << num_eligible << " roll/pitch anchors, sigma_rad="
                << reg.sigma_rad;
    }
    if (num_missing > 0) {
      LOG(ERROR) << "[AETHER gravity] MISSING " << num_missing << "/"
                 << num_eligible
                 << " gravity priors for parameterized frames; the mandatory "
                    "attitude anchor is NOT fully applied to this solve";
    }
    if (num_inconsistent > 0) {
      LOG(ERROR) << "[AETHER gravity] INCONSISTENT " << num_inconsistent << "/"
                 << num_eligible
                 << " anchors disagreed with the pose they anchor by >30 deg "
                    "and were dropped; suspect a cross-session registry "
                    "collision or an ARKit->COLMAP conversion regression";
    }
  }

 private:
  std::shared_ptr<ceres::Problem> problem_;
  std::unique_ptr<ceres::LossFunction> loss_function_;
  // [AETHER position-prior spike] Huber for the center priors; problem uses
  // DO_NOT_TAKE_OWNERSHIP, so it must outlive problem_.
  std::unique_ptr<ceres::LossFunction> aether_prior_loss_;

  std::set<camera_t> parameterized_camera_ids_;
  std::set<image_t> parameterized_image_ids_;
  std::unordered_map<point3D_t, size_t> point3D_num_observations_;
};

class PosePriorBundleAdjuster : public CeresBundleAdjuster {
 public:
  PosePriorBundleAdjuster(const BundleAdjustmentOptions& options,
                          const PosePriorBundleAdjustmentOptions& prior_options,
                          const BundleAdjustmentConfig& config,
                          std::vector<PosePrior> pose_priors,
                          Reconstruction& reconstruction)
      : CeresBundleAdjuster(options, config),
        prior_options_(prior_options),
        pose_priors_(std::move(pose_priors)),
        reconstruction_(reconstruction) {
    THROW_CHECK(prior_options_.Check());

    // Filter irrelevant pose priors.
    pose_priors_.erase(
        std::remove_if(pose_priors_.begin(),
                       pose_priors_.end(),
                       [this](const auto& pose_prior) {
                         return !pose_prior.HasPosition() ||
                                pose_prior.corr_data_id.sensor_id.type !=
                                    SensorType::CAMERA ||
                                !config_.HasImage(pose_prior.corr_data_id.id);
                       }),
        pose_priors_.end());

    const bool use_prior_position = AlignReconstruction();

    // Fix 7-DOFs of BA problem if not enough valid pose priors.
    if (use_prior_position) {
      // Normalize the reconstruction to avoid any numerical instability but
      // do not transform priors as they will be transformed when added to
      // ceres::Problem.
      normalized_from_metric_ = reconstruction_.Normalize(/*fixed_scale=*/true);
    } else {
      config_.FixGauge(BundleAdjustmentGauge::THREE_POINTS);
    }

    // WARNING: Do not move this above the reconstruction normalization.
    default_bundle_adjuster_ = std::make_unique<DefaultBundleAdjuster>(
        options_, config_, reconstruction);

    if (use_prior_position) {
      prior_loss_function_ = CreateLossFunction(
          prior_options_.ceres->prior_position_loss_function_type,
          prior_options_.ceres->prior_position_loss_scale);

      // Only consider parameterized images for pose priors. Notice that some
      // images may be configured to be included in the BA problem but have no
      // reprojection constraints, etc.
      const std::set<image_t>& parameterized_image_ids =
          default_bundle_adjuster_->ParameterizedImageIds();
      for (const auto& pose_prior : pose_priors_) {
        if (parameterized_image_ids.count(pose_prior.corr_data_id.id) > 0) {
          AddImagePosePriorToProblem(
              pose_prior.corr_data_id.id, pose_prior, reconstruction);
        }
      }
    }
  }

  std::shared_ptr<BundleAdjustmentSummary> Solve() override {
    std::shared_ptr<ceres::Problem> problem =
        default_bundle_adjuster_->Problem();
    if (problem->NumResiduals() == 0) {
      return std::make_shared<BundleAdjustmentSummary>();
    }

    ceres::Solver::Summary ceres_summary =
        SolveWithGpuFallback(options_, config_, problem.get());

    reconstruction_.Transform(Inverse(normalized_from_metric_));

    if (options_.print_summary || VLOG_IS_ON(1)) {
      PrintSolverSummary(ceres_summary, "Pose Prior Bundle adjustment report");
    }

    return CreateSummaryAndLogFailure(std::move(ceres_summary),
                                      "Pose prior bundle adjustment");
  }

  std::shared_ptr<ceres::Problem>& Problem() override {
    return default_bundle_adjuster_->Problem();
  }

  void AddImagePosePriorToProblem(image_t image_id,
                                  const PosePrior& pose_prior,
                                  Reconstruction& reconstruction) {
    Image& image = reconstruction.Image(image_id);

    const bool constant_sensor_from_rig =
        !options_.refine_sensor_from_rig ||
        config_.HasConstantSensorFromRigPose(image.CameraPtr()->SensorId());
    const bool constant_rig_from_world =
        !options_.refine_rig_from_world ||
        config_.HasConstantRigFromWorldPose(image.FrameId());
    if (constant_sensor_from_rig && constant_rig_from_world) {
      return;
    }

    ceres::Problem& problem = *default_bundle_adjuster_->Problem();
    Frame& frame = *image.FramePtr();

    Rigid3d& rig_from_world = frame.RigFromWorld();

    const Eigen::Vector3d normalized_position =
        normalized_from_metric_ * pose_prior.position;
    const Eigen::Matrix3d normalized_from_metric_scaled_rotation =
        normalized_from_metric_.scale() *
        normalized_from_metric_.rotation().toRotationMatrix();
    const Eigen::Matrix3d position_cov =
        pose_prior.HasPositionCov()
            ? pose_prior.position_covariance
            : (prior_options_.prior_position_fallback_stddev *
               prior_options_.prior_position_fallback_stddev *
               Eigen::Matrix3d::Identity());
    const Eigen::Matrix3d normalized_position_cov =
        normalized_from_metric_scaled_rotation * position_cov *
        normalized_from_metric_scaled_rotation.transpose();

    if (image.IsRefInFrame()) {
      problem.AddResidualBlock(
          CovarianceWeightedCostFunctor<AbsolutePosePositionPriorCostFunctor>::
              Create(normalized_position_cov, normalized_position),
          prior_loss_function_.get(),
          rig_from_world.params.data());
    } else {
      Rigid3d& cam_from_rig =
          frame.RigPtr()->SensorFromRig(image.CameraPtr()->SensorId());
      problem.AddResidualBlock(
          CovarianceWeightedCostFunctor<
              AbsoluteRigPosePositionPriorCostFunctor>::
              Create(normalized_position_cov, normalized_position),
          prior_loss_function_.get(),
          cam_from_rig.params.data(),
          rig_from_world.params.data());
    }
  }

  bool AlignReconstruction() {
    RANSACOptions ransac_options = prior_options_.alignment_ransac_options;
    if (ransac_options.max_error <= 0) {
      std::vector<double> rms_vars;
      rms_vars.reserve(pose_priors_.size());
      for (const auto& pose_prior : pose_priors_) {
        const double trace = pose_prior.position_covariance.trace();
        if (trace <= 0.0) {
          continue;
        }
        rms_vars.push_back(trace / 3.0);
      }

      if (rms_vars.empty()) {
        LOG(WARNING) << "No pose priors with valid covariance found.";
        rms_vars.push_back(prior_options_.prior_position_fallback_stddev *
                           prior_options_.prior_position_fallback_stddev);
      }

      // Set max error using the median RMS variance of valid pose priors.
      // Scaled by sqrt(chi-square 95% quantile, 3 DOF) to approximate a 95%
      // confidence radius.
      ransac_options.max_error =
          std::sqrt(kChiSquare95ThreeDof * Median(rms_vars));
    }

    VLOG(2) << "Robustly aligning reconstruction with max_error="
            << ransac_options.max_error;

    Sim3d metric_from_orig;
    if (!AlignReconstructionToPosePriors(
            reconstruction_, pose_priors_, ransac_options, &metric_from_orig)) {
      LOG(WARNING) << "Alignment w.r.t. prior positions failed";
      return false;
    }
    reconstruction_.Transform(metric_from_orig);

    // Compute alignment error w.r.t. prior positions.
    if (VLOG_IS_ON(2)) {
      std::vector<double> verr2_wrt_prior;
      verr2_wrt_prior.reserve(config_.NumImages());
      for (const auto& pose_prior : pose_priors_) {
        const auto& image = reconstruction_.Image(pose_prior.corr_data_id.id);
        verr2_wrt_prior.push_back(
            (image.ProjectionCenter() - pose_prior.position).squaredNorm());
      }
      VLOG(2) << "Alignment error w.r.t. prior positions:\n"
              << "  - rmse:   " << std::sqrt(Mean(verr2_wrt_prior)) << '\n'
              << "  - median: " << std::sqrt(Median(verr2_wrt_prior)) << '\n';
    }

    return true;
  }

 private:
  PosePriorBundleAdjustmentOptions prior_options_;
  std::vector<PosePrior> pose_priors_;
  Reconstruction& reconstruction_;

  std::unique_ptr<DefaultBundleAdjuster> default_bundle_adjuster_;
  std::unique_ptr<ceres::LossFunction> prior_loss_function_;

  Sim3d normalized_from_metric_;
};

}  // namespace

std::unique_ptr<CeresBundleAdjuster> CreateDefaultCeresBundleAdjuster(
    const BundleAdjustmentOptions& options,
    const BundleAdjustmentConfig& config,
    Reconstruction& reconstruction) {
  return std::make_unique<DefaultBundleAdjuster>(
      options, config, reconstruction);
}

std::unique_ptr<CeresBundleAdjuster> CreatePosePriorCeresBundleAdjuster(
    const BundleAdjustmentOptions& options,
    const PosePriorBundleAdjustmentOptions& prior_options,
    const BundleAdjustmentConfig& config,
    std::vector<PosePrior> pose_priors,
    Reconstruction& reconstruction) {
  return std::make_unique<PosePriorBundleAdjuster>(
      options, prior_options, config, std::move(pose_priors), reconstruction);
}

void PrintSolverSummary(const ceres::Solver::Summary& summary,
                        const std::string& header) {
  if (VLOG_IS_ON(3)) {
    LOG(INFO) << summary.FullReport();
  }

  std::ostringstream log;
  log << header << '\n';
  log << std::right << std::setw(16) << "Residuals : ";
  log << std::left << summary.num_residuals_reduced << '\n';

  log << std::right << std::setw(16) << "Parameters : ";
  log << std::left << summary.num_effective_parameters_reduced << '\n';

  log << std::right << std::setw(16) << "Iterations : ";
  log << std::left
      << summary.num_successful_steps + summary.num_unsuccessful_steps << '\n';

  log << std::right << std::setw(16) << "Time : ";
  log << std::left << summary.total_time_in_seconds << " [s]\n";

  log << std::right << std::setw(16) << "Initial cost : ";
  log << std::right << std::setprecision(6)
      << std::sqrt(summary.initial_cost / summary.num_residuals_reduced)
      << " [px]\n";

  log << std::right << std::setw(16) << "Final cost : ";
  log << std::right << std::setprecision(6)
      << std::sqrt(summary.final_cost / summary.num_residuals_reduced)
      << " [px]\n";

  log << std::right << std::setw(16) << "Termination : ";
  log << std::right << ceres::TerminationTypeToString(summary.termination_type)
      << "\n\n";
  LOG(INFO) << log.str();
}

}  // namespace colmap
