#include "bundle_adjustment.h"

#include <colmap/estimators/cost_functions/manifold.h>
#include <colmap/estimators/cost_functions/reprojection_error.h>
#include <colmap/sensor/models.h>
#include <colmap/util/cuda.h>
#include <colmap/util/misc.h>

#include <cstdlib>  // std::getenv (AETHER_BA_SPARSE solver A/B switch)

// [AETHER PROGRESS] staged progress hooks (impl: controllers/aether_progress.cc)
extern "C" void aether_progress_items(int stage, long done, long total);
namespace {
struct AetherProgressIterCB : public ceres::IterationCallback {
  int stage; int max_iter;
  AetherProgressIterCB(int s, int m) : stage(s), max_iter(m) {}
  ceres::CallbackReturnType operator()(const ceres::IterationSummary& is) override {
    aether_progress_items(stage, is.iteration + 1, max_iter);
    return ceres::SOLVER_CONTINUE;
  }
};
}  // namespace

namespace glomap {

bool BundleAdjuster::Solve(std::unordered_map<rig_t, Rig>& rigs,
                           std::unordered_map<camera_t, Camera>& cameras,
                           std::unordered_map<frame_t, Frame>& frames,
                           std::unordered_map<image_t, Image>& images,
                           std::unordered_map<track_t, Track>& tracks) {
  // Check if the input data is valid
  if (images.empty()) {
    LOG(ERROR) << "Number of images = " << images.size();
    return false;
  }
  if (tracks.empty()) {
    LOG(ERROR) << "Number of tracks = " << tracks.size();
    return false;
  }

  // Reset the problem
  Reset();

  // Add the constraints that the point tracks impose on the problem
  AddPointToCameraConstraints(rigs, cameras, frames, images, tracks);

  // Add the cameras and points to the parameter groups for schur-based
  // optimization
  AddCamerasAndPointsToParameterGroups(rigs, cameras, frames, tracks);

  // Parameterize the variables
  ParameterizeVariables(rigs, cameras, frames, tracks);

  // Set the solver options.
  ceres::Solver::Summary summary;

  int num_images = images.size();
#ifdef GLOMAP_CUDA_ENABLED
  bool cuda_solver_enabled = false;

#if (CERES_VERSION_MAJOR >= 3 ||                                \
     (CERES_VERSION_MAJOR == 2 && CERES_VERSION_MINOR >= 2)) && \
    !defined(CERES_NO_CUDA)
  if (options_.use_gpu && num_images >= options_.min_num_images_gpu_solver) {
    cuda_solver_enabled = true;
    options_.solver_options.dense_linear_algebra_library_type = ceres::CUDA;
  }
#else
  if (options_.use_gpu) {
    LOG_FIRST_N(WARNING, 1)
        << "Requested to use GPU for bundle adjustment, but Ceres was "
           "compiled without CUDA support. Falling back to CPU-based dense "
           "solvers.";
  }
#endif

#if (CERES_VERSION_MAJOR >= 3 ||                                \
     (CERES_VERSION_MAJOR == 2 && CERES_VERSION_MINOR >= 3)) && \
    !defined(CERES_NO_CUDSS)
  if (options_.use_gpu && num_images >= options_.min_num_images_gpu_solver) {
    cuda_solver_enabled = true;
    options_.solver_options.sparse_linear_algebra_library_type =
        ceres::CUDA_SPARSE;
  }
#else
  if (options_.use_gpu) {
    LOG_FIRST_N(WARNING, 1)
        << "Requested to use GPU for bundle adjustment, but Ceres was "
           "compiled without cuDSS support. Falling back to CPU-based sparse "
           "solvers.";
  }
#endif

  if (cuda_solver_enabled) {
    const std::vector<int> gpu_indices =
        colmap::CSVToVector<int>(options_.gpu_index);
    THROW_CHECK_GT(gpu_indices.size(), 0);
    colmap::SetBestCudaDevice(gpu_indices[0]);
  }
#else
  if (options_.use_gpu) {
    LOG_FIRST_N(WARNING, 1)
        << "Requested to use GPU for bundle adjustment, but COLMAP was "
           "compiled without CUDA support. Falling back to CPU-based "
           "solvers.";
  }
#endif  // GLOMAP_CUDA_ENABLED

  // [AETHER] iOS solver routing (mirrors COLMAP). The indefinite/near-singular Schur
  // complement from robust-reweighted normal equations only crashes Apple Accelerate's
  // sparse Cholesky (SparseFactorizationFailed) -- NOT sparse Cholesky in general.
  // Forcing EIGEN_SPARSE (Eigen SimplicialLDLT) factorizes it fine and is FASTER than
  // ITERATIVE_SCHUR (COLMAP path: SPARSE+EIGEN 509-538s vs ITERATIVE 679-879s on the
  // same 396-frame problem). So reclaim GLOMAP's fast SPARSE_SCHUR, iOS-safe:
  //   <=200 frames -> DENSE_SCHUR (fastest at small scale)
  //   >200         -> SPARSE_SCHUR + EIGEN_SPARSE (full-capture; CLUSTER_JACOBI was an
  //                   ITERATIVE preconditioner, irrelevant for a direct sparse solve)
  int aether_dense_max = 200;
  if (const char* dm = std::getenv("AETHER_DENSE_MAX"))
    aether_dense_max = atoi(dm);  // [AETHER LAPACK spike] threshold sweep knob
  if (num_images <= aether_dense_max) {
    options_.solver_options.linear_solver_type = ceres::DENSE_SCHUR;
    // [AETHER 2026-07-12] value-parsed to match the colmap router's tier
    // routing contract (=1 force LAPACK, =0 force EIGEN) — one env, one
    // semantics; "set means LAPACK" would silently flip =0 into LAPACK.
    if (const char* f = std::getenv("AETHER_DENSE_LAPACK")) {
      if (atoi(f) != 0)
        options_.solver_options.dense_linear_algebra_library_type =
            ceres::LAPACK;
    }
  } else if (std::getenv("AETHER_BA_ITER")) {
    // Former certified default (ITERATIVE_SCHUR+SCHUR_JACOBI), kept as an
    // env fallback after the 2026-07-05 retrial flipped the default to
    // SPARSE (below).
    options_.solver_options.linear_solver_type = ceres::ITERATIVE_SCHUR;
    options_.solver_options.preconditioner_type = ceres::SCHUR_JACOBI;
  } else if (std::getenv("AETHER_BA_CJ")) {
    // ITERATIVE + CLUSTER_JACOBI: FAILED the gate on dense-414 (SV 0.0623,
    // T2 run). Debug switch only.
    options_.solver_options.linear_solver_type = ceres::ITERATIVE_SCHUR;
    options_.solver_options.preconditioner_type = ceres::CLUSTER_JACOBI;
  } else {
    // [AETHER DEFAULT — RETRIAL VERDICT 2026-07-05, family-adjudicated]
    // SPARSE_SCHUR + EIGEN_SPARSE. The 2026-07-04 "SPARSE = worse SV basin"
    // conviction was a small-n mirage: interleaved families (SB n=4 vs C n=6,
    // same #4354 binary, idle host) are indistinguishable on ALL 9 metrics
    // (ARKit-position fully overlapping 9.385-9.412 vs 9.279-9.500; weak-track
    // slightly BETTER) while solve is -27% (median 734.7s vs ~1006s, families
    // cleanly separated). SV 0.060-0.063 is the certified run-noise band.
    options_.solver_options.linear_solver_type = ceres::SPARSE_SCHUR;
    options_.solver_options.sparse_linear_algebra_library_type =
        ceres::EIGEN_SPARSE;
    // [AETHER KNIFE9 — same solver family, faster preconditioner apply]
    // Explicit Schur complement materializes the (tiny at ~414 cams) reduced
    // system for the SCHUR_JACOBI preconditioner instead of implicit products:
    // measured 2.1x on the extra BA (316->147s) with a full gate PASS (run C).
    // Same ITERATIVE_SCHUR+SCHUR_JACOBI math -> expected same basin; the
    // [KNIFE9 VERDICT 2026-07-04: REJECTED] E2/E2b replicates were wildly
    // inconsistent (solve 223s vs 497s; E2 exploded 4 metrics + numeric blowup,
    // E2b fell back to the bad-basin SV band 0.0624). Explicit SC perturbs the
    // CG path enough to leave the certified implicit-SJ basin. Debug opt-in.
    if (std::getenv("AETHER_INT_SC")) {
      options_.solver_options.use_explicit_schur_complement = true;
    }
    // [SPSE VERDICT 2026-07-05: REJECTED, see global_positioning.cc]
    // [AETHER SPSE spike 2026-07-04] see global_positioning.cc — same knob,
    // internal-BA ITERATIVE path. NOTE post-verdict context: the SV
    // "basin" story above is superseded — SV 0.060-0.063 was re-anchored as
    // the run-noise band (stats + NN 0.00012 + user blind test); the gate now
    // uses the band ceiling, not 3% off one lucky draw.
    if (const char* e = std::getenv("AETHER_SPSE")) {
      options_.solver_options.preconditioner_type =
          ceres::SCHUR_POWER_SERIES_EXPANSION;
      if (e[0] == '2')
        options_.solver_options.use_spse_initialization = true;
    }
  }

  // [AETHER FTOL knife 2026-07-05] converge-stop sweep knob (default 1e-5
  // from optimization_base.h; the gftol=1e-6 precedent on the COLMAP finalize
  // bought -30% at zero quality loss). Gate-verified before any adoption.
  options_.solver_options.function_tolerance = 1e-4;  // [CERTIFIED 2026-07-05]
  if (const char* e = std::getenv("AETHER_FTOL_BA"))
    options_.solver_options.function_tolerance = atof(e);
  options_.solver_options.minimizer_progress_to_stdout = VLOG_IS_ON(2);
  AetherProgressIterCB aether_cb(5, options_.solver_options.max_num_iterations);
  options_.solver_options.callbacks.push_back(&aether_cb);
  ceres::Solve(options_.solver_options, problem_.get(), &summary);
  options_.solver_options.callbacks.pop_back();
  if (VLOG_IS_ON(2))
    LOG(INFO) << summary.FullReport();
  else
    LOG(INFO) << summary.BriefReport();

  return summary.IsSolutionUsable();
}

void BundleAdjuster::Reset() {
  ceres::Problem::Options problem_options;
  problem_options.loss_function_ownership = ceres::DO_NOT_TAKE_OWNERSHIP;
  problem_ = std::make_unique<ceres::Problem>(problem_options);
  loss_function_ = options_.CreateLossFunction();
}

void BundleAdjuster::AddPointToCameraConstraints(
    std::unordered_map<rig_t, Rig>& rigs,
    std::unordered_map<camera_t, Camera>& cameras,
    std::unordered_map<frame_t, Frame>& frames,
    std::unordered_map<image_t, Image>& images,
    std::unordered_map<track_t, Track>& tracks) {
  for (auto& [track_id, track] : tracks) {
    if (track.observations.size() < options_.min_num_view_per_track) continue;

    // [AETHER BA-COVGAIN 2026-07-06] coverage-gain redundant tracks are left
    // out of the problem entirely (no residual blocks -> no parameter block;
    // the HasParameterBlock guards downstream keep them out of ordering /
    // manifold setup automatically). nullptr (default) = zero behavior change.
    if (options_.aether_exclude_tracks != nullptr &&
        options_.aether_exclude_tracks->count(track_id) > 0)
      continue;

    for (const auto& observation : tracks[track_id].observations) {
      if (images.find(observation.first) == images.end()) continue;

      Image& image = images[observation.first];
      Frame* frame_ptr = image.frame_ptr;
      camera_t camera_id = image.camera_id;
      image_t rig_id = image.frame_ptr->RigId();

      ceres::CostFunction* cost_function = nullptr;
      // if (image_id_to_camera_rig_index_.find(observation.first) ==
      //     image_id_to_camera_rig_index_.end()) {
      if (image.HasTrivialFrame()) {
        cost_function =
            colmap::CreateCameraCostFunction<colmap::ReprojErrorCostFunctor>(
                cameras[image.camera_id].model_id,
                image.features[observation.second]);
        // [4.0.4] ReprojErrorCostFunctor now takes 3 blocks: point3D(3),
        // cam_from_world as a SINGLE contiguous 7-param pose (params.data()),
        // camera_params. (3.14 split pose into separate rotation/translation.)
        problem_->AddResidualBlock(
            cost_function,
            loss_function_.get(),
            tracks[track_id].xyz.data(),
            frame_ptr->RigFromWorld().params.data(),
            cameras[image.camera_id].params.data());
      } else if (!options_.optimize_rig_poses) {
        const Rigid3d& cam_from_rig = rigs[rig_id].SensorFromRig(
            sensor_t(SensorType::CAMERA, image.camera_id));
        cost_function = colmap::CreateCameraCostFunction<
            colmap::RigReprojErrorConstantRigCostFunctor>(
            cameras[image.camera_id].model_id,
            image.features[observation.second],
            cam_from_rig);
        // [4.0.4] 3 blocks: point3D(3), rig_from_world(7 combined), cam_params.
        problem_->AddResidualBlock(
            cost_function,
            loss_function_.get(),
            tracks[track_id].xyz.data(),
            frame_ptr->RigFromWorld().params.data(),
            cameras[image.camera_id].params.data());
      } else {
        // If the image is part of a camera rig, use the RigBATA error
        // Down weight the uncalibrated cameras
        Rigid3d& cam_from_rig = rigs[rig_id].SensorFromRig(
            sensor_t(SensorType::CAMERA, image.camera_id));
        cost_function =
            colmap::CreateCameraCostFunction<colmap::RigReprojErrorCostFunctor>(
                cameras[image.camera_id].model_id,
                image.features[observation.second]);
        // [4.0.4] 4 blocks: point3D(3), cam_from_rig(7), rig_from_world(7),
        // camera_params. (3.14 split each pose into rotation+translation.)
        problem_->AddResidualBlock(
            cost_function,
            loss_function_.get(),
            tracks[track_id].xyz.data(),
            cam_from_rig.params.data(),
            frame_ptr->RigFromWorld().params.data(),
            cameras[image.camera_id].params.data());
      }

      if (cost_function != nullptr) {
      } else {
        LOG(ERROR) << "Camera model not supported: "
                   << colmap::CameraModelIdToName(
                          cameras[image.camera_id].model_id);
      }
    }
  }
}

void BundleAdjuster::AddCamerasAndPointsToParameterGroups(
    std::unordered_map<rig_t, Rig>& rigs,
    std::unordered_map<camera_t, Camera>& cameras,
    std::unordered_map<frame_t, Frame>& frames,
    std::unordered_map<track_t, Track>& tracks) {
  if (tracks.size() == 0) return;

  // Create a custom ordering for Schur-based problems.
  options_.solver_options.linear_solver_ordering.reset(
      new ceres::ParameterBlockOrdering);
  ceres::ParameterBlockOrdering* parameter_ordering =
      options_.solver_options.linear_solver_ordering.get();
  // Add point parameters to group 0.
  for (auto& [track_id, track] : tracks) {
    if (problem_->HasParameterBlock(track.xyz.data()))
      parameter_ordering->AddElementToGroup(track.xyz.data(), 0);
  }

  // Add frame parameters to group 1. [4.0.4] pose is one 7-param block.
  for (auto& [frame_id, frame] : frames) {
    if (!frame.HasPose()) continue;
    if (problem_->HasParameterBlock(frame.RigFromWorld().params.data())) {
      parameter_ordering->AddElementToGroup(
          frame.RigFromWorld().params.data(), 1);
    }
  }

  // Add the cam_from_rigs to be estimated into the parameter group
  for (auto& [rig_id, rig] : rigs) {
    for (const auto& [sensor_id, sensor] : rig.NonRefSensors()) {
      if (sensor_id.type == SensorType::CAMERA) {
        Rigid3d& sensor_from_rig = rig.SensorFromRig(sensor_id);
        if (problem_->HasParameterBlock(sensor_from_rig.params.data())) {
          parameter_ordering->AddElementToGroup(
              sensor_from_rig.params.data(), 1);
        }
      }
    }
  }

  // Add camera parameters to group 1.
  for (auto& [camera_id, camera] : cameras) {
    if (problem_->HasParameterBlock(camera.params.data()))
      parameter_ordering->AddElementToGroup(camera.params.data(), 1);
  }
}

void BundleAdjuster::ParameterizeVariables(
    std::unordered_map<rig_t, Rig>& rigs,
    std::unordered_map<camera_t, Camera>& cameras,
    std::unordered_map<frame_t, Frame>& frames,
    std::unordered_map<track_t, Track>& tracks) {
  frame_t center;

  // Parameterize rotations, and set rotations and translations to be constant
  // if desired FUTURE: Consider fix the scale of the reconstruction
  int counter = 0;
  for (auto& [frame_id, frame] : frames) {
    if (!frame.HasPose()) continue;
    // [4.0.4] pose is now a single 7-param block (params.data()); use the
    // product manifold (quaternion(4) x Euclidean(3)) matching colmap's own BA.
    if (problem_->HasParameterBlock(frame.RigFromWorld().params.data())) {
      colmap::SetManifold(problem_.get(),
                          frame.RigFromWorld().params.data(),
                          colmap::CreateProductManifold(
                              colmap::CreateEigenQuaternionManifold(),
                              colmap::CreateEuclideanManifold<3>()));

      // The combined block is atomic: if rotation OR translation must be held
      // (gauge fix on the first frame, or global disable), fix the whole pose.
      if (!options_.optimize_rotations || !options_.optimize_translation ||
          counter == 0)
        problem_->SetParameterBlockConstant(
            frame.RigFromWorld().params.data());

      counter++;
    }
  }

  // Parameterize the camera parameters, or set them to be constant if desired
  if (options_.optimize_intrinsics && !options_.optimize_principal_point) {
    for (auto& [camera_id, camera] : cameras) {
      if (problem_->HasParameterBlock(camera.params.data())) {
        std::vector<int> principal_point_idxs;
        for (auto idx : camera.PrincipalPointIdxs()) {
          principal_point_idxs.push_back(idx);
        }
        colmap::SetManifold(
            problem_.get(),
            camera.params.data(),
            colmap::CreateSubsetManifold(camera.params.size(),
                                         principal_point_idxs));
      }
    }
  } else if (!options_.optimize_intrinsics &&
             !options_.optimize_principal_point) {
    for (auto& [camera_id, camera] : cameras) {
      if (problem_->HasParameterBlock(camera.params.data())) {
        problem_->SetParameterBlockConstant(camera.params.data());
      }
    }
  }

  // If we optimize the rig poses, then parameterize them
  if (options_.optimize_rig_poses) {
    for (auto& [rig_id, rig] : rigs) {
      for (const auto& [sensor_id, sensor] : rig.NonRefSensors()) {
        if (sensor_id.type == SensorType::CAMERA) {
          Rigid3d& sensor_from_rig = rig.SensorFromRig(sensor_id);
          if (problem_->HasParameterBlock(sensor_from_rig.params.data())) {
            colmap::SetManifold(problem_.get(),
                                sensor_from_rig.params.data(),
                                colmap::CreateProductManifold(
                                    colmap::CreateEigenQuaternionManifold(),
                                    colmap::CreateEuclideanManifold<3>()));
          }
        }
      }
    }
  }

  if (!options_.optimize_points) {
    for (auto& [track_id, track] : tracks) {
      if (problem_->HasParameterBlock(track.xyz.data())) {
        problem_->SetParameterBlockConstant(track.xyz.data());
      }
    }
  }
}

}  // namespace glomap
