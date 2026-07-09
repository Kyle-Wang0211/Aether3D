// arkit_ba_bench.cc — HOST-ONLY fixture: feed ARKit camera poses (instead of
// COLMAP's own incremental registration) into COLMAP 4.0.4 bundle adjustment
// and measure whether reprojection error still converges to ~1.0 px. This
// validates the planned STREAMING local-BA approach (pose-primed BA) offline,
// before building it into the app.
//
// Pipeline:
//   1. Parse argv: <db> <arkit_poses.json> [--fixposes] [--fixintrin]
//      [--loss=cauchy|trivial] [--scale=F] [--gate=F]
//   2. Database::Open + DatabaseCache::Create  -> cameras/images(+Point2D)/
//      rigs/frames + a *finalized* CorrespondenceGraph (finalize-once offline
//      is fine for a fixture; the finalized_ guard only blocks live streaming).
//   3. Reconstruction::Load(cache) -> populates rigs/cameras/frames/images.
//   4. For every image: parse frameId from name "frame_%06d.jpg", look up its
//      ARKit c2w (column-major), convert to COLMAP cam_from_world with the
//      exact app flip, set the frame pose, RegisterFrame.
//   5. Build tracks by union-find over the correspondence graph, triangulate
//      each track (multi-view DLT) from the ARKit poses, gate on cheirality +
//      a loose reproj threshold, AddPoint3D.
//   6. Report mean reproj BEFORE BA.
//   7. Global BA (Cauchy loss, TWO_CAMS_FROM_WORLD gauge) — mirrors
//      colmap/controllers/bundle_adjustment.cc.
//   8. Report mean reproj AFTER BA. Print one-line JSON.
//
// POSE CONVENTION (the landmine — matches the app's S3 preview triangulation):
//   ext[16] = ARKit camera transform = camera-to-world (c2w), COLUMN-MAJOR
//   (Dart vector_math Matrix4.fromList). Eigen is column-major by default, so
//   Eigen::Map<const Matrix4d>(ext) reconstructs c2w directly:
//     R_c2w = c2w.topLeftCorner<3,3>(); t_c2w = c2w.block<3,1>(0,3)  (= ext[12..14])
//     R_w2c = R_c2w^T;  t_w2c = -R_w2c * t_c2w
//     C = diag(1,-1,-1)  (ARKit -> COLMAP camera-axis flip)
//     R_col = C*R_w2c;   t_col = C*t_w2c
//     cam_from_world = Rigid3d(Quaterniond(R_col), t_col)

#include "colmap/estimators/bundle_adjustment.h"
#include "colmap/estimators/bundle_adjustment_ceres.h"  // CeresBundleAdjustmentOptions::LossFunctionType
#include "colmap/geometry/rigid3.h"
#include "colmap/geometry/triangulation.h"
#include "colmap/scene/camera.h"
#include "colmap/scene/correspondence_graph.h"
#include "colmap/scene/database.h"
#include "colmap/scene/database_cache.h"
#include "colmap/scene/frame.h"
#include "colmap/scene/image.h"
#include "colmap/scene/point2d.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/track.h"
#include "colmap/sfm/observation_manager.h"
#include "colmap/util/types.h"  // colmap::span, Eigen::Matrix3x4d, Eigen::Vector7d

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <glog/logging.h>

#include <array>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// argv helpers
// ---------------------------------------------------------------------------
bool HasFlag(int argc, char** argv, const char* key) {
  for (int i = 1; i < argc; ++i)
    if (std::strcmp(argv[i], key) == 0) return true;
  return false;
}
double ArgD(int argc, char** argv, const char* key, double def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], key, kl) == 0) {
      const char* eq = std::strchr(argv[i], '=');
      if (eq) return std::atof(eq + 1);
    }
  return def;
}
std::string ArgS(int argc, char** argv, const char* key, const char* def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], key, kl) == 0) {
      const char* eq = std::strchr(argv[i], '=');
      if (eq) return std::string(eq + 1);
    }
  return std::string(def);
}

// ---------------------------------------------------------------------------
// Minimal JSON parser for {"<frameId>": [16 floats], ...}. No JSON lib linked.
// The only quoted tokens at any depth are the integer keys, so we can scan:
// read a quoted key, then read the 16 doubles between the following '[' and ']'.
// ---------------------------------------------------------------------------
bool ParseArkitPoses(const std::string& path,
                     std::unordered_map<int, std::array<double, 16>>* out) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return false;
  std::stringstream ss;
  ss << f.rdbuf();
  const std::string s = ss.str();
  const char* p = s.c_str();
  const char* end = p + s.size();
  while (p < end) {
    // Find the opening quote of a key.
    while (p < end && *p != '"') ++p;
    if (p >= end) break;
    ++p;
    const char* ks = p;
    while (p < end && *p != '"') ++p;
    if (p >= end) break;
    std::string key(ks, p);
    ++p;  // past closing quote
    // Find '['.
    while (p < end && *p != '[' && *p != '"') ++p;
    if (p >= end || *p != '[') continue;  // not an array value; skip
    ++p;
    std::array<double, 16> m{};
    int n = 0;
    while (p < end && *p != ']' && n < 16) {
      while (p < end && *p != ']' &&
             !(std::isdigit((unsigned char)*p) || *p == '-' || *p == '+' ||
               *p == '.'))
        ++p;
      if (p >= end || *p == ']') break;
      char* ep = nullptr;
      const double v = std::strtod(p, &ep);
      if (ep == p) {
        ++p;
        continue;
      }
      m[n++] = v;
      p = ep;
    }
    while (p < end && *p != ']') ++p;
    if (p < end && *p == ']') ++p;
    if (n == 16) {
      const int fid = std::atoi(key.c_str());
      (*out)[fid] = m;
    }
  }
  return !out->empty();
}

// name "frame_%06d.jpg" -> frameId (0-based). Returns -1 on failure.
int FrameIdFromName(const std::string& name) {
  int fid = -1;
  if (std::sscanf(name.c_str(), "frame_%d", &fid) == 1) return fid;
  return -1;
}

// ARKit c2w (column-major 16) -> COLMAP cam_from_world (the exact app flip).
colmap::Rigid3d ArkitToCamFromWorld(const std::array<double, 16>& ext) {
  // Eigen is column-major by default: Map reconstructs c2w directly.
  const Eigen::Map<const Eigen::Matrix4d> c2w(ext.data());
  const Eigen::Matrix3d R_c2w = c2w.topLeftCorner<3, 3>();
  const Eigen::Vector3d t_c2w = c2w.block<3, 1>(0, 3);  // == (ext[12],ext[13],ext[14])
  const Eigen::Matrix3d R_w2c = R_c2w.transpose();
  const Eigen::Vector3d t_w2c = -R_w2c * t_c2w;
  Eigen::Matrix3d C = Eigen::Matrix3d::Identity();
  C(1, 1) = -1.0;
  C(2, 2) = -1.0;
  const Eigen::Matrix3d R_col = C * R_w2c;
  const Eigen::Vector3d t_col = C * t_w2c;
  const Eigen::Quaterniond q(R_col);
  return colmap::Rigid3d(q.normalized(), t_col);
}

// Union-find over correspondence-graph observations.
struct UnionFind {
  std::vector<int> parent, rank_;
  int Make() {
    parent.push_back((int)parent.size());
    rank_.push_back(0);
    return (int)parent.size() - 1;
  }
  int Find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }
  void Union(int a, int b) {
    a = Find(a);
    b = Find(b);
    if (a == b) return;
    if (rank_[a] < rank_[b]) std::swap(a, b);
    parent[b] = a;
    if (rank_[a] == rank_[b]) ++rank_[a];
  }
};

}  // namespace

int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <db> <arkit_poses.json> "
                 "[--fixposes] [--fixintrin] [--loss=cauchy|trivial] "
                 "[--scale=1.0] [--gate=4.0]\n",
                 argv[0]);
    return 1;
  }
  const std::string db_path = argv[1];
  const std::string json_path = argv[2];
  const bool fix_poses = HasFlag(argc, argv, "--fixposes");
  const bool fix_intrin = HasFlag(argc, argv, "--fixintrin");
  const std::string loss = ArgS(argc, argv, "--loss", "cauchy");
  const double loss_scale = ArgD(argc, argv, "--scale", 1.0);
  const double reproj_gate = ArgD(argc, argv, "--gate", 4.0);

  try {
    // ----- 1. ARKit poses -----
    std::unordered_map<int, std::array<double, 16>> arkit;
    if (!ParseArkitPoses(json_path, &arkit)) {
      std::fprintf(stderr, "{\"error\":\"failed to parse %s\"}\n",
                   json_path.c_str());
      return 2;
    }
    LOG(INFO) << "Parsed " << arkit.size() << " ARKit poses.";

    // ----- 2. Database + cache (finalized correspondence graph) -----
    auto database = colmap::Database::Open(db_path);
    colmap::DatabaseCache::Options cache_opts;
    cache_opts.min_num_matches = 15;   // matches the shipped mapper gate
    cache_opts.ignore_watermarks = false;
    auto cache = colmap::DatabaseCache::Create(*database, cache_opts);
    auto graph = cache->CorrespondenceGraph();  // shared_ptr, already Finalize()d
    LOG(INFO) << "Cache: " << cache->NumImages() << " images, "
              << cache->NumCameras() << " cameras.";

    // ----- 3. Reconstruction::Load -----
    colmap::Reconstruction recon;
    recon.Load(*cache);

    // ----- 4. Set ARKit poses + register frames -----
    std::unordered_set<colmap::image_t> reg_image_ids;
    size_t n_pose_missing = 0;
    for (const auto& [image_id, image] : recon.Images()) {
      const int fid = FrameIdFromName(image.Name());
      auto it = (fid >= 0) ? arkit.find(fid) : arkit.end();
      if (it == arkit.end()) {
        ++n_pose_missing;
        continue;
      }
      const colmap::Rigid3d cam_from_world = ArkitToCamFromWorld(it->second);
      const colmap::frame_t frame_id = image.FrameId();
      recon.Frame(frame_id).SetRigFromWorld(cam_from_world);
      recon.RegisterFrame(frame_id);
      reg_image_ids.insert(image_id);
    }
    LOG(INFO) << "Registered " << reg_image_ids.size() << " / "
              << recon.NumImages() << " images (" << n_pose_missing
              << " missing ARKit pose).";
    if (reg_image_ids.size() < 2) {
      std::fprintf(stderr, "{\"error\":\"fewer than 2 registered images\"}\n");
      return 2;
    }

    // ----- 5. Build tracks (union-find over correspondence graph) -----
    UnionFind uf;
    std::unordered_map<uint64_t, int> node_of;  // (image_id<<32|point2D_idx) -> node
    std::vector<uint64_t> node_key;             // node -> key
    auto key_of = [](colmap::image_t img, colmap::point2D_t idx) -> uint64_t {
      return (static_cast<uint64_t>(img) << 32) | static_cast<uint64_t>(idx);
    };
    auto get_node = [&](colmap::image_t img, colmap::point2D_t idx) -> int {
      const uint64_t k = key_of(img, idx);
      auto f = node_of.find(k);
      if (f != node_of.end()) return f->second;
      const int nid = uf.Make();
      node_of.emplace(k, nid);
      node_key.push_back(k);
      return nid;
    };

    for (const colmap::image_t image_id : reg_image_ids) {
      const auto& image = recon.Image(image_id);
      const colmap::point2D_t num2d = image.NumPoints2D();
      for (colmap::point2D_t idx = 0; idx < num2d; ++idx) {
        const auto range = graph->FindCorrespondences(image_id, idx);
        if (range.beg == range.end) continue;
        const int a = get_node(image_id, idx);
        for (const auto* c = range.beg; c != range.end; ++c) {
          if (reg_image_ids.count(c->image_id) == 0) continue;
          const int b = get_node(c->image_id, c->point2D_idx);
          uf.Union(a, b);
        }
      }
    }

    // Group nodes by root.
    std::unordered_map<int, std::vector<int>> groups;
    for (int nid = 0; nid < (int)node_key.size(); ++nid)
      groups[uf.Find(nid)].push_back(nid);

    // ----- 5b. Triangulate + gate -----
    size_t n_tracks_seen = 0, n_added = 0;
    for (const auto& [root, members] : groups) {
      if (members.size() < 2) continue;
      ++n_tracks_seen;

      // Collect at most one observation per image (dedupe within track).
      std::unordered_set<colmap::image_t> seen_imgs;
      std::vector<colmap::image_t> obs_img;
      std::vector<colmap::point2D_t> obs_idx;
      for (int nid : members) {
        const uint64_t k = node_key[nid];
        const colmap::image_t img = (colmap::image_t)(k >> 32);
        const colmap::point2D_t idx = (colmap::point2D_t)(k & 0xffffffffu);
        if (!seen_imgs.insert(img).second) continue;  // keep first per image
        obs_img.push_back(img);
        obs_idx.push_back(idx);
      }
      if (obs_img.size() < 2) continue;

      // Assemble multi-view triangulation inputs.
      std::vector<Eigen::Matrix3x4d> cams_from_world;
      std::vector<Eigen::Vector2d> cam_points;
      cams_from_world.reserve(obs_img.size());
      cam_points.reserve(obs_img.size());
      bool ok_norm = true;
      for (size_t i = 0; i < obs_img.size(); ++i) {
        const auto& image = recon.Image(obs_img[i]);
        const auto& camera = recon.Camera(image.CameraId());
        const auto& xy = image.Point2D(obs_idx[i]).xy;
        const auto cam_pt = camera.CamFromImg(xy);  // std::optional
        if (!cam_pt) {
          ok_norm = false;
          break;
        }
        cams_from_world.push_back(image.CamFromWorld().ToMatrix());
        cam_points.push_back(*cam_pt);
      }
      if (!ok_norm || cam_points.size() < 2) continue;

      Eigen::Vector3d xyz;
      if (!colmap::TriangulateMultiViewPoint(
              colmap::span<const Eigen::Matrix3x4d>(cams_from_world.data(),
                                                    cams_from_world.size()),
              colmap::span<const Eigen::Vector2d>(cam_points.data(),
                                                  cam_points.size()),
              &xyz)) {
        continue;
      }

      // Per-observation cheirality + reproj gate -> inlier track.
      colmap::Track track;
      int n_inl = 0;
      for (size_t i = 0; i < obs_img.size(); ++i) {
        const auto& image = recon.Image(obs_img[i]);
        const auto& camera = recon.Camera(image.CameraId());
        const colmap::Rigid3d cfw = image.CamFromWorld();
        const Eigen::Vector3d p_cam = cfw * xyz;  // Rigid3d * point
        if (p_cam.z() <= 0.0) continue;           // cheirality
        const auto proj = camera.ImgFromCam(p_cam);
        if (!proj) continue;
        const double err = (*proj - image.Point2D(obs_idx[i]).xy).norm();
        if (err > reproj_gate) continue;
        track.AddElement(obs_img[i], obs_idx[i]);
        ++n_inl;
      }
      if (n_inl < 2) continue;

      // Re-triangulate from inliers only for a cleaner point.
      std::vector<Eigen::Matrix3x4d> in_cams;
      std::vector<Eigen::Vector2d> in_pts;
      for (const auto& el : track.Elements()) {
        const auto& image = recon.Image(el.image_id);
        const auto& camera = recon.Camera(image.CameraId());
        const auto cam_pt = camera.CamFromImg(image.Point2D(el.point2D_idx).xy);
        if (!cam_pt) {
          in_cams.clear();
          break;
        }
        in_cams.push_back(image.CamFromWorld().ToMatrix());
        in_pts.push_back(*cam_pt);
      }
      Eigen::Vector3d xyz_final = xyz;
      if (in_cams.size() >= 2) {
        Eigen::Vector3d xyz2;
        if (colmap::TriangulateMultiViewPoint(
                colmap::span<const Eigen::Matrix3x4d>(in_cams.data(),
                                                      in_cams.size()),
                colmap::span<const Eigen::Vector2d>(in_pts.data(),
                                                    in_pts.size()),
                &xyz2)) {
          xyz_final = xyz2;
        }
      }

      recon.AddPoint3D(xyz_final, std::move(track), Eigen::Vector3ub::Zero());
      ++n_added;
    }

    // ----- 6. Reproj BEFORE BA -----
    // Drop any negative-depth observations that slipped through, so the number
    // is comparable to COLMAP's (mirrors controllers/bundle_adjustment.cc).
    colmap::ObservationManager(recon).FilterObservationsWithNegativeDepth();
    recon.UpdatePoint3DErrors();
    const double reproj_before = recon.ComputeMeanReprojectionError();
    const size_t n_pts_before = recon.NumPoints3D();
    LOG(INFO) << "Tracks: " << n_tracks_seen << " candidate, " << n_added
              << " added; reproj_before=" << reproj_before
              << " over " << n_pts_before << " points.";

    // ----- 7. Global BA (Cauchy, TWO_CAMS_FROM_WORLD gauge) -----
    colmap::BundleAdjustmentOptions ba_options;
    ba_options.refine_focal_length = !fix_intrin;
    ba_options.refine_principal_point = false;
    ba_options.refine_extra_params = !fix_intrin;
    ba_options.refine_rig_from_world = !fix_poses;
    ba_options.refine_points3D = true;
    ba_options.print_summary = true;
    // ba_options.ceres is always allocated by BundleAdjustmentBackendOptions().
    ba_options.ceres->loss_function_type =
        (loss == "trivial")
            ? colmap::CeresBundleAdjustmentOptions::LossFunctionType::TRIVIAL
            : colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
    ba_options.ceres->loss_function_scale = loss_scale;
    // Solver routing is handled by the vendored CreateSolverOptions (forces
    // EIGEN_SPARSE for the CPU sparse path; auto-selects SPARSE_SCHUR here).

    colmap::BundleAdjustmentConfig ba_config;
    for (const colmap::image_t image_id : recon.RegImageIds())
      ba_config.AddImage(image_id);
    ba_config.FixGauge(colmap::BundleAdjustmentGauge::TWO_CAMS_FROM_WORLD);

    auto ba = colmap::CreateDefaultBundleAdjuster(ba_options, ba_config, recon);
    auto summary = ba->Solve();
    recon.UpdatePoint3DErrors();

    // ----- 8. Reproj AFTER BA -----
    const double reproj_after = recon.ComputeMeanReprojectionError();
    const size_t n_pts_after = recon.NumPoints3D();
    const size_t n_reg = recon.NumRegImages();

    std::printf(
        "{\"reproj_before\":%.4f,\"reproj_after\":%.4f,\"n_pts\":%zu,"
        "\"n_reg\":%zu,\"loss\":\"%s\",\"scale\":%.3f,\"fixposes\":%d,"
        "\"fixintrin\":%d,\"ba_usable\":%d}\n",
        reproj_before, reproj_after, n_pts_after, n_reg, loss.c_str(),
        loss_scale, fix_poses ? 1 : 0, fix_intrin ? 1 : 0,
        summary && summary->IsSolutionUsable() ? 1 : 0);
    (void)n_pts_before;
    return 0;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "{\"error\":\"%s\"}\n", e.what());
    return 2;
  }
}
