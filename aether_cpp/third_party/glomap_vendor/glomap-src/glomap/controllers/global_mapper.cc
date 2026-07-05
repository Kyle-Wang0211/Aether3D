#include "global_mapper.h"

#include "glomap/controllers/rotation_averager.h"
#include "glomap/io/colmap_converter.h"
#include "glomap/processors/image_pair_inliers.h"
#include "glomap/processors/image_undistorter.h"
#include "glomap/processors/reconstruction_normalizer.h"
#include "glomap/processors/reconstruction_pruning.h"
#include "glomap/processors/relpose_filter.h"
#include "glomap/processors/track_filter.h"
#include "glomap/processors/view_graph_manipulation.h"

#include <array>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <queue>
#include <sstream>
#include <unordered_set>

#include <colmap/util/file.h>
#include <colmap/util/timer.h>

// [AETHER PROGRESS] staged progress hooks (impl: controllers/aether_progress.cc)
extern "C" void aether_progress_stage(int stage);

namespace glomap {

namespace {

// [AETHER BA-COVGAIN 2026-07-06] Faithful port of colmap 4.0.4
// scene/reconstruction_pruning.cc FindRedundantPoints3D onto glomap
// structures. Upstream idea: greedily select points by marginal image-tile
// coverage gain (8x8 tiles per image, gain per observation =
// 1/sqrt(n) - 1/sqrt(n+1) with n = 1 + #selected points already covering that
// tile, lazy-greedy priority queue); points whose marginal gain drops to
// <= min_coverage_gain are "redundant" for pose estimation. Upstream prunes
// them from the reconstruction before BA and re-triangulates after; here we
// only EXCLUDE them from the internal-BA problem (see
// BundleAdjusterOptions::aether_exclude_tracks) — same two-step equivalence,
// and our pipeline already runs retriangulation + full-set finishing BAs.
//
// Universe = tracks that would actually enter the BA problem
// (observations >= min_num_view_per_track, observation image present), so the
// exclusion ratio is measured against real BA participants.
constexpr int kAetherCovTilesPerDim = 8;  // upstream kNumImageTilesPerDim
constexpr int kAetherCovTiles = kAetherCovTilesPerDim * kAetherCovTilesPerDim;

std::unordered_set<track_t> AetherFindRedundantTracks(
    const double min_coverage_gain,
    const std::unordered_map<camera_t, Camera>& cameras,
    const std::unordered_map<image_t, Image>& images,
    const std::unordered_map<track_t, Track>& tracks,
    const int min_num_view_per_track) {
  // Per-track (image_id, tile_idx) pairs, precomputed once (upstream
  // precomputes per-image tile idx arrays; same math: distorted keypoint px
  // over camera width/height).
  std::vector<track_t> track_ids;
  std::vector<std::vector<std::pair<image_t, int>>> track_tiles;
  track_ids.reserve(tracks.size());
  track_tiles.reserve(tracks.size());
  // #selected tracks covering each image tile (value-initialized to zeros).
  std::unordered_map<image_t, std::array<int, kAetherCovTiles>> tile_counts;
  tile_counts.reserve(images.size());

  for (const auto& [track_id, track] : tracks) {
    if (static_cast<int>(track.observations.size()) < min_num_view_per_track)
      continue;
    std::vector<std::pair<image_t, int>> tiles;
    tiles.reserve(track.observations.size());
    for (const auto& obs : track.observations) {
      const auto img_it = images.find(obs.first);
      if (img_it == images.end()) continue;
      const Image& image = img_it->second;
      if (obs.second >= image.features.size()) continue;
      const auto cam_it = cameras.find(image.camera_id);
      if (cam_it == cameras.end()) continue;
      const Camera& camera = cam_it->second;
      if (camera.width == 0 || camera.height == 0) continue;
      const Eigen::Vector2d& xy = image.features[obs.second];
      const int tile_x = std::min(
          std::max<int>(kAetherCovTilesPerDim * xy(0) / camera.width, 0),
          kAetherCovTilesPerDim - 1);
      const int tile_y = std::min(
          std::max<int>(kAetherCovTilesPerDim * xy(1) / camera.height, 0),
          kAetherCovTilesPerDim - 1);
      tiles.emplace_back(obs.first,
                         tile_x * kAetherCovTilesPerDim + tile_y);
      tile_counts[obs.first];  // ensure zero-filled entry exists
    }
    if (tiles.empty()) continue;
    track_ids.push_back(track_id);
    track_tiles.push_back(std::move(tiles));
  }

  const auto compute_gain =
      [&tile_counts](const std::vector<std::pair<image_t, int>>& tiles) {
        double gain = 0;
        for (const auto& [image_id, tile_idx] : tiles) {
          const int n = 1 + tile_counts.at(image_id)[tile_idx];
          gain += 1. / std::sqrt(static_cast<double>(n)) -
                  1. / std::sqrt(static_cast<double>(1 + n));
        }
        return gain;
      };

  struct TrackCovInfo {
    size_t idx;  // into track_ids / track_tiles
    double gain;
  };
  const auto has_left_smaller_gain = [&track_ids](const TrackCovInfo& left,
                                                  const TrackCovInfo& right) {
    return std::tie(left.gain, track_ids[left.idx]) <
           std::tie(right.gain, track_ids[right.idx]);
  };
  std::priority_queue<TrackCovInfo, std::vector<TrackCovInfo>,
                      decltype(has_left_smaller_gain)>
      priority_queue(has_left_smaller_gain);
  for (size_t i = 0; i < track_ids.size(); ++i) {
    priority_queue.push({i, compute_gain(track_tiles[i])});
  }

  std::vector<bool> selected(track_ids.size(), false);
  size_t num_selected = 0;
  while (!priority_queue.empty()) {
    auto info = priority_queue.top();
    priority_queue.pop();

    if (info.gain <= min_coverage_gain) break;

    // Lazy-greedy: another selection sharing an image tile may have lowered
    // this track's gain; recompute and re-queue if stale (upstream verbatim).
    const double updated_gain = compute_gain(track_tiles[info.idx]);
    if (updated_gain < info.gain) {
      info.gain = updated_gain;
      priority_queue.push(info);
      continue;
    }

    for (const auto& [image_id, tile_idx] : track_tiles[info.idx]) {
      tile_counts.at(image_id)[tile_idx]++;
    }
    selected[info.idx] = true;
    ++num_selected;
  }

  std::unordered_set<track_t> redundant;
  redundant.reserve(track_ids.size() - num_selected);
  for (size_t i = 0; i < track_ids.size(); ++i) {
    if (!selected[i]) redundant.insert(track_ids[i]);
  }
  return redundant;
}

}  // namespace

// TODO: Rig normalizaiton has not be done
bool GlobalMapper::Solve(const colmap::Database& database,
                         ViewGraph& view_graph,
                         std::unordered_map<rig_t, Rig>& rigs,
                         std::unordered_map<camera_t, Camera>& cameras,
                         std::unordered_map<frame_t, Frame>& frames,
                         std::unordered_map<image_t, Image>& images,
                         std::unordered_map<track_t, Track>& tracks) {
  // 0. Preprocessing
  if (!options_.skip_preprocessing) {
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running preprocessing ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;

    colmap::Timer run_timer;
    run_timer.Start();
    // If camera intrinsics seem to be good, force the pair to use essential
    // matrix
    ViewGraphManipulater::UpdateImagePairsConfig(view_graph, cameras, images);
    ViewGraphManipulater::DecomposeRelPose(view_graph, cameras, images);
    run_timer.PrintSeconds();
  }

  // 1. Run view graph calibration
  if (!options_.skip_view_graph_calibration) {
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running view graph calibration ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;
    ViewGraphCalibrator vgcalib_engine(options_.opt_vgcalib);
    if (!vgcalib_engine.Solve(view_graph, cameras, images)) {
      return false;
    }
  }

  // 2. Run relative pose estimation
  //   TODO: Use generalized relative pose estimation for rigs.
  if (!options_.skip_relative_pose_estimation) {
    aether_progress_stage(1);  // [AETHER PROGRESS] relpose
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running relative pose estimation ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;

    colmap::Timer run_timer;
    run_timer.Start();
    // Relative pose relies on the undistorted images
    UndistortImages(cameras, images, true);
    EstimateRelativePoses(view_graph, cameras, images, options_.opt_relpose);

    InlierThresholdOptions inlier_thresholds = options_.inlier_thresholds;
    // Undistort the images and filter edges by inlier number
    ImagePairsInlierCount(view_graph, cameras, images, inlier_thresholds, true);

    RelPoseFilter::FilterInlierNum(view_graph,
                                   options_.inlier_thresholds.min_inlier_num);
    RelPoseFilter::FilterInlierRatio(
        view_graph, options_.inlier_thresholds.min_inlier_ratio);

    if (view_graph.KeepLargestConnectedComponents(frames, images) == 0) {
      LOG(ERROR) << "no connected components are found";
      return false;
    }

    run_timer.PrintSeconds();
  }

  // 3. Run rotation averaging for three times
  if (!options_.skip_rotation_averaging) {
    aether_progress_stage(2);  // [AETHER PROGRESS] rotation averaging
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running rotation averaging ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;

    colmap::Timer run_timer;
    run_timer.Start();

    // The first run is for filtering
    SolveRotationAveraging(view_graph, rigs, frames, images, options_.opt_ra);

    RelPoseFilter::FilterRotations(
        view_graph, images, options_.inlier_thresholds.max_rotation_error);
    if (view_graph.KeepLargestConnectedComponents(frames, images) == 0) {
      LOG(ERROR) << "no connected components are found";
      return false;
    }

    // The second run is for final estimation
    if (!SolveRotationAveraging(
            view_graph, rigs, frames, images, options_.opt_ra)) {
      return false;
    }
    RelPoseFilter::FilterRotations(
        view_graph, images, options_.inlier_thresholds.max_rotation_error);
    image_t num_img = view_graph.KeepLargestConnectedComponents(frames, images);
    if (num_img == 0) {
      LOG(ERROR) << "no connected components are found";
      return false;
    }
    LOG(INFO) << num_img << " / " << images.size()
              << " images are within the connected component." << std::endl;

    run_timer.PrintSeconds();
  }

  // 4. Track establishment and selection
  if (!options_.skip_track_establishment) {
    aether_progress_stage(3);  // [AETHER PROGRESS] track establishment
    colmap::Timer run_timer;
    run_timer.Start();

    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running track establishment ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;
    TrackEngine track_engine(view_graph, images, options_.opt_track);
    std::unordered_map<track_t, Track> tracks_full;
    track_engine.EstablishFullTracks(tracks_full);

    // Filter the tracks
    track_t num_tracks = track_engine.FindTracksForProblem(tracks_full, tracks);
    LOG(INFO) << "Before filtering: " << tracks_full.size()
              << ", after filtering: " << num_tracks << std::endl;

    // [AETHER] iOS memory: release the pre-filter track superset NOW (only the
    // filtered `tracks` feed global positioning/BA downstream). At 396-frame dense
    // this superset is ~2x the filtered set (88736 vs 43025) -> frees the peak before
    // the global-positioning Ceres problem (the 3.2GB hotspot) is built.
    { std::unordered_map<track_t, Track>().swap(tracks_full); }

    // [AETHER OPT-CUT2] Track establishment was the LAST reader of the per-pair
    // raw match matrices (verified: after this point no glomap-src code touches
    // ImagePair::matches; pruning/tree only read pair.inliers, which we KEEP).
    // At dense-414 (85k pairs) these matrices are ~hundreds of MB held straight
    // through the GP 3.2GB peak — free them before that problem is built.
    for (auto& [pair_id, pair] : view_graph.image_pairs) {
      pair.matches = Eigen::MatrixXi();
    }

    run_timer.PrintSeconds();
  }

  // 5. Global positioning
  if (!options_.skip_global_positioning) {
    aether_progress_stage(4);  // [AETHER PROGRESS] global positioning
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running global positioning ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;

    if (options_.opt_gp.constraint_type !=
        GlobalPositionerOptions::ConstraintType::ONLY_POINTS) {
      LOG(ERROR) << "Only points are used for solving camera positions";
      return false;
    }

    colmap::Timer run_timer;
    run_timer.Start();
    // Undistort images in case all previous steps are skipped
    // Skip images where an undistortion already been done
    UndistortImages(cameras, images, false);

    // [AETHER GP WARM-START 2026-07-05] upstream leaves the door open:
    // generate_random_positions=false makes GP consume the frames' existing
    // poses as the position init (upstream default init is UNIFORM RANDOM in
    // [-100,100]^3). AETHER_GP_INIT=<txt: name qw qx qy qz cx cy cz per line,
    // ARKit world-to-cam rotation + camera center> loads ARKit priors,
    // chordal-aligns the ARKit world to the post-RA GLOMAP world (mean of
    // R_ra^T * R_ark over images, SVD-projected to SO(3)), and seeds every
    // registered frame's position. Gauge/scale free for GP; gate-verified
    // before any adoption.
    GlobalPositionerOptions aether_gp_opts = options_.opt_gp;
    if (const char* gpini = std::getenv("AETHER_GP_INIT")) {
      std::ifstream fin(gpini);
      std::unordered_map<std::string, std::pair<Eigen::Quaterniond,
                                                Eigen::Vector3d>> ark;
      std::string nm; double qw, qx, qy, qz, cx, cy, cz;
      while (fin >> nm >> qw >> qx >> qy >> qz >> cx >> cy >> cz)
        ark[nm] = {Eigen::Quaterniond(qw, qx, qy, qz),
                   Eigen::Vector3d(cx, cy, cz)};
      Eigen::Matrix3d acc = Eigen::Matrix3d::Zero();
      int n_hit = 0;
      for (auto& [iid, img] : images) {
        auto it = ark.find(img.file_name);
        if (it == ark.end() || img.frame_ptr == nullptr) continue;
        const Eigen::Matrix3d R_ra =
            img.frame_ptr->RigFromWorld().rotation().toRotationMatrix();
        acc += R_ra.transpose() * it->second.first.toRotationMatrix();
        n_hit++;
      }
      if (n_hit >= 3) {
        Eigen::JacobiSVD<Eigen::Matrix3d> svd(
            acc, Eigen::ComputeFullU | Eigen::ComputeFullV);
        Eigen::Matrix3d R_align = svd.matrixU() * svd.matrixV().transpose();
        if (R_align.determinant() < 0) {
          Eigen::Matrix3d U = svd.matrixU();
          U.col(2) *= -1;
          R_align = U * svd.matrixV().transpose();
        }
        int n_seed = 0;
        for (auto& [iid, img] : images) {
          auto it = ark.find(img.file_name);
          if (it == ark.end() || img.frame_ptr == nullptr) continue;
          const Eigen::Vector3d C = R_align * it->second.second;
          const Eigen::Matrix3d R_ra =
              img.frame_ptr->RigFromWorld().rotation().toRotationMatrix();
          img.frame_ptr->RigFromWorld().translation() = -(R_ra * C);
          n_seed++;
        }
        aether_gp_opts.generate_random_positions = false;
        LOG(INFO) << "[AETHER] GP warm-start: seeded " << n_seed << "/"
                  << images.size() << " frames from ARKit priors";
      } else {
        LOG(WARNING) << "[AETHER] GP warm-start: only " << n_hit
                     << " name matches — falling back to random init";
      }
    }
    GlobalPositioner gp_engine(aether_gp_opts);

    // TODO: consider to support other modes as well
    if (!gp_engine.Solve(view_graph, rigs, cameras, frames, images, tracks)) {
      return false;
    }
    // Filter tracks based on the estimation
    TrackFilter::FilterTracksByAngle(
        view_graph,
        cameras,
        images,
        tracks,
        options_.inlier_thresholds.max_angle_error);

    // Filter tracks based on triangulation angle and reprojection error
    TrackFilter::FilterTrackTriangulationAngle(
        view_graph,
        images,
        tracks,
        options_.inlier_thresholds.min_triangulation_angle);
    // Set the threshold to be larger to avoid removing too many tracks
    TrackFilter::FilterTracksByReprojection(
        view_graph,
        cameras,
        images,
        tracks,
        10 * options_.inlier_thresholds.max_reprojection_error);
    // Normalize the structure
    // If the camera rig is used, the structure do not need to be normalized
    NormalizeReconstruction(rigs, cameras, frames, images, tracks);

    run_timer.PrintSeconds();
  }

  // 6. Bundle adjustment
  if (!options_.skip_bundle_adjustment) {
    aether_progress_stage(5);  // [AETHER PROGRESS] internal BA
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running bundle adjustment ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;
    LOG(INFO) << "Bundle adjustment start" << std::endl;

    colmap::Timer run_timer;
    run_timer.Start();

    for (int ite = 0; ite < options_.num_iteration_bundle_adjustment; ite++) {
      BundleAdjuster ba_engine(options_.opt_ba);

      BundleAdjusterOptions& ba_engine_options_inner = ba_engine.GetOptions();
      // [AETHER LOSS-ANNEAL 2026-07-05] per-round robust-kernel tightening
      // (e.g. AETHER_LOSS_ANNEAL="2,1,0.5"): principled version of the
      // measured "early-stop preserves edges" effect — later rounds commit to
      // a tighter consensus without over-smoothing. Gate + dense eyeball
      // before adoption.
      if (const char* ann = std::getenv("AETHER_LOSS_ANNEAL")) {
        std::vector<double> scales;
        std::stringstream ss_(ann);
        std::string tok;
        while (std::getline(ss_, tok, ',')) scales.push_back(atof(tok.c_str()));
        if (!scales.empty()) {
          const double sc = scales[std::min<size_t>(ite, scales.size() - 1)];
          ba_engine_options_inner.thres_loss_function = sc;
          LOG(INFO) << "[AETHER] BA round " << ite + 1
                    << " loss scale annealed to " << sc;
        }
      }

      // [AETHER BA-COVGAIN 2026-07-06] env knife AETHER_BA_COVGAIN=<min_gain>
      // (e.g. 0.05, upstream colmap prune default): per BA round, compute the
      // coverage-gain-redundant track set (port of colmap 4.0.4
      // FindRedundantPoints3D, helper above) and exclude those tracks from
      // BOTH stages of this round's problem. Recomputed each round because
      // track filtering mutates the map between rounds. The set outlives both
      // Solve() calls (scoped to this loop iteration). Unset env = the
      // exclusion pointer stays nullptr = exact upstream behavior.
      //
      // [COVGAIN VERDICT 2026-07-06: REJECTED — debug switch only]
      // dense-414 interleaved A/B (CG1/CT1/CG2 + CG3), all vs B_glomapCAUCHY:
      //  * thinned round-1 stage-2 is BISTABLE: identical deterministic
      //    exclusion (176,536/205,523 = 85.9%), CG1 collapsed to a degenerate
      //    basin (cost 8.3e5->940 ~ 0.05px RMS, an order below the feature
      //    noise floor) -> round-end filter nuked 205k/232k tracks -> retri
      //    could not rebuild -> 19/414 images, 168 points. CG2 (same config)
      //    landed healthy (8.3e5->4.3e5) and delivered 205,720 pts BUT failed
      //    the SV gate (0.0655 > 0.0630 certified noise-band ceiling).
      //  * +FREEZE_INTR (CG3) kills the collapse and the filter slaughter
      //    (round-2 eligible stays ~202k) and is fastest (solve -23%), but
      //    retriangulation then runs on never-refined intrinsics: only
      //    178,380 pts (< red-line 198,312), weak-track% 7.78 (2x), SV 0.0745.
      //  * control CT1 = PASS 9/9, zero covgain log lines, cost trajectory
      //    bit-comparable to pre-knife R3b -> env-off is provably zero-change.
      // Speed prize was real (CG2 solve -16%, CG3 -23%) but the quality
      // red-lines don't hold. Do NOT enable in production.
      std::unordered_set<track_t> aether_covgain_redundant;
      if (const char* cg = std::getenv("AETHER_BA_COVGAIN")) {
        const double min_coverage_gain = atof(cg);
        colmap::Timer covgain_timer;
        covgain_timer.Start();
        aether_covgain_redundant = AetherFindRedundantTracks(
            min_coverage_gain, cameras, images, tracks,
            options_.opt_ba.min_num_view_per_track);
        size_t num_ba_eligible = 0;
        for (const auto& [track_id, track] : tracks) {
          if (static_cast<int>(track.observations.size()) >=
              options_.opt_ba.min_num_view_per_track)
            ++num_ba_eligible;
        }
        ba_engine_options_inner.aether_exclude_tracks =
            &aether_covgain_redundant;
        // [AETHER BA-COVGAIN_FREEZE_INTR] CG1 post-mortem sub-knife: round-1
        // stage-2 on the thinned problem collapsed to a degenerate basin
        // (cost 8.3e5 -> 940 ~= 0.05px RMS, far below the feature noise
        // floor), after which the round-end normalized-image filter nuked
        // 205k/232k tracks and retriangulation could not recover (19/414
        // images survived pruning). Suspected channel: per-camera intrinsics
        // (f,k free per image) overfitting on ~560 obs/cam once rotations are
        // freed. This flag freezes intrinsics during covgain-thinned rounds;
        // they still get their full refinement in the full-set retri-BA and
        // the extra CAUCHY BA downstream.
        if (std::getenv("AETHER_BA_COVGAIN_FREEZE_INTR"))
          ba_engine_options_inner.optimize_intrinsics = false;
        LOG(INFO) << "[AETHER] BA round " << ite + 1 << " covgain("
                  << min_coverage_gain << "): excluding "
                  << aether_covgain_redundant.size() << " / "
                  << num_ba_eligible << " BA-eligible tracks ("
                  << (num_ba_eligible > 0
                          ? 100.0 * aether_covgain_redundant.size() /
                                num_ba_eligible
                          : 0.0)
                  << "%), selection took " << covgain_timer.ElapsedSeconds()
                  << "s";
      }

      // Staged bundle adjustment
      // 6.1. First stage: optimize positions only
      ba_engine_options_inner.optimize_rotations = false;
      if (!ba_engine.Solve(rigs, cameras, frames, images, tracks)) {
        return false;
      }
      LOG(INFO) << "Global bundle adjustment iteration " << ite + 1 << " / "
                << options_.num_iteration_bundle_adjustment
                << ", stage 1 finished (position only)";
      run_timer.PrintSeconds();

      // 6.2. Second stage: optimize rotations if desired
      ba_engine_options_inner.optimize_rotations =
          options_.opt_ba.optimize_rotations;
      if (ba_engine_options_inner.optimize_rotations &&
          !ba_engine.Solve(rigs, cameras, frames, images, tracks)) {
        return false;
      }
      LOG(INFO) << "Global bundle adjustment iteration " << ite + 1 << " / "
                << options_.num_iteration_bundle_adjustment
                << ", stage 2 finished";
      if (ite != options_.num_iteration_bundle_adjustment - 1)
        run_timer.PrintSeconds();

      // Normalize the structure
      NormalizeReconstruction(rigs, cameras, frames, images, tracks);

      // 6.3. Filter tracks based on the estimation
      // For the filtering, in each round, the criteria for outlier is
      // tightened. If only few tracks are changed, no need to start bundle
      // adjustment right away. Instead, use a more strict criteria to filter
      UndistortImages(cameras, images, true);
      LOG(INFO) << "Filtering tracks by reprojection ...";

      bool status = true;
      size_t filtered_num = 0;
      while (status && ite < options_.num_iteration_bundle_adjustment) {
        double scaling = std::max(3 - ite, 1);
        filtered_num += TrackFilter::FilterTracksByReprojection(
            view_graph,
            cameras,
            images,
            tracks,
            scaling * options_.inlier_thresholds.max_reprojection_error);

        if (filtered_num > 1e-3 * tracks.size()) {
          status = false;
        } else
          ite++;
      }
      if (status) {
        LOG(INFO) << "fewer than 0.1% tracks are filtered, stop the iteration.";
        break;
      }
    }

    // Filter tracks based on the estimation
    UndistortImages(cameras, images, true);
    LOG(INFO) << "Filtering tracks by reprojection ...";
    TrackFilter::FilterTracksByReprojection(
        view_graph,
        cameras,
        images,
        tracks,
        options_.inlier_thresholds.max_reprojection_error);
    TrackFilter::FilterTrackTriangulationAngle(
        view_graph,
        images,
        tracks,
        options_.inlier_thresholds.min_triangulation_angle);

    run_timer.PrintSeconds();
  }

  // 7. Retriangulation
  if (!options_.skip_retriangulation) {
    aether_progress_stage(6);  // [AETHER PROGRESS] retriangulation
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running retriangulation ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;
    for (int ite = 0; ite < options_.num_iteration_retriangulation; ite++) {
      colmap::Timer run_timer;
      run_timer.Start();
      RetriangulateTracks(options_.opt_triangulator,
                          database,
                          rigs,
                          cameras,
                          frames,
                          images,
                          tracks);
      run_timer.PrintSeconds();

      std::cout << "-------------------------------------" << std::endl;
      std::cout << "Running bundle adjustment ..." << std::endl;
      std::cout << "-------------------------------------" << std::endl;
      LOG(INFO) << "Bundle adjustment start" << std::endl;
      BundleAdjuster ba_engine(options_.opt_ba);
      if (!ba_engine.Solve(rigs, cameras, frames, images, tracks)) {
        return false;
      }

      // Filter tracks based on the estimation
      UndistortImages(cameras, images, true);
      LOG(INFO) << "Filtering tracks by reprojection ...";
      TrackFilter::FilterTracksByReprojection(
          view_graph,
          cameras,
          images,
          tracks,
          options_.inlier_thresholds.max_reprojection_error);
      if (!ba_engine.Solve(rigs, cameras, frames, images, tracks)) {
        return false;
      }
      run_timer.PrintSeconds();
    }

    // Normalize the structure
    NormalizeReconstruction(rigs, cameras, frames, images, tracks);

    // Filter tracks based on the estimation
    UndistortImages(cameras, images, true);
    LOG(INFO) << "Filtering tracks by reprojection ...";
    TrackFilter::FilterTracksByReprojection(
        view_graph,
        cameras,
        images,
        tracks,
        options_.inlier_thresholds.max_reprojection_error);
    TrackFilter::FilterTrackTriangulationAngle(
        view_graph,
        images,
        tracks,
        options_.inlier_thresholds.min_triangulation_angle);
  }

  // 8. Reconstruction pruning
  if (!options_.skip_pruning) {
    std::cout << "-------------------------------------" << std::endl;
    std::cout << "Running postprocessing ..." << std::endl;
    std::cout << "-------------------------------------" << std::endl;

    colmap::Timer run_timer;
    run_timer.Start();

    // Prune weakly connected images
    PruneWeaklyConnectedImages(frames, images, tracks);

    run_timer.PrintSeconds();
  }

  return true;
}

}  // namespace glomap
