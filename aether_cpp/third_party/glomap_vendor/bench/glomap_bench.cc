// glomap_bench.cc — on-device benchmark of GLOMAP's global-mapper core
// (rotation averaging + global positioning + global BA). Feeds a COLMAP
// database (db_50.db), runs GlobalMapper::Solve, reports per-stage + total
// wall time and reconstruction size. C ABI for Dart FFI; main() for standalone.

#include "colmap/scene/database.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/util/timer.h"
// Low-level BA (NOT the controller/OptionManager path): colmap's OptionManager and
// controllers/bundle_adjustment TUs are excluded from the iOS colmap subset, so we
// replicate BundleAdjustmentController::Run() directly with the estimator API, which
// IS in libglomap_full.a. Same result, no CLI-parsing dependency.
#include "colmap/estimators/bundle_adjustment.h"
#include "colmap/estimators/bundle_adjustment_ceres.h"
#include "glomap/io/pose_io.h"  // CeresBundleAdjustmentOptions (CAUCHY loss / num_threads)
#include "colmap/sfm/observation_manager.h"
#include "colmap/util/file.h"

#include "glomap/controllers/global_mapper.h"
#include "glomap/io/colmap_converter.h"
#include "glomap/io/colmap_io.h"
#include "glomap/scene/types.h"

#include <glog/logging.h>

#include <algorithm>
#include <chrono>
#include <optional>
#include <vector>
#include <utility>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unordered_map>

// [ODR FIX] Removed the local RetriangulateTracks stub that used to live here.
// It was a strong definition in this TU, so at final link it SHADOWED the real
// 140-line implementation in libglomap_full.a (track_retriangulation.cc.o) —
// the linker, having satisfied the symbol from this object, never pulled the
// archive member. Net effect: options.skip_retriangulation=false was a no-op and
// GLOMAP's internal retriangulation NEVER ran on device. Deleting the stub lets
// the link resolve RetriangulateTracks to the genuine implementation.

static double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

#include <mach/mach.h>
// [AETHER OPT-CUT2] phase-tagged RSS: attribute the process peak to a pipeline
// phase (sampler gives the max but not WHERE). phys_footprint, macOS + iOS.
// [AETHER PROGRESS] staged progress hooks (impl: glomap-src/controllers/aether_progress.cc)
extern "C" void aether_progress_stage(int stage);
extern "C" void aether_progress_items(int stage, long done, long total);
extern "C" int aether_progress_permille(void);
extern "C" int aether_progress_stage_get(void);

static void aether_phase_rss(const char* tag) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  double mb = -1;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) ==
      KERN_SUCCESS)
    mb = info.phys_footprint / (1024.0 * 1024.0);
  fprintf(stderr, "[AETHER RSS] %s = %.0fMB prog=%d stage=%d\n", tag, mb,
          aether_progress_permille(), aether_progress_stage_get());
  fflush(stderr);
}

extern "C" int glomap_bench(const char* db_path, char* out_json, int out_cap) {
  using namespace glomap;
  try {
    const double t_load0 = NowMs();
    auto database = colmap::Database::Open(db_path);

    ViewGraph view_graph;
    std::unordered_map<rig_t, Rig> rigs;
    std::unordered_map<camera_t, Camera> cameras;
    std::unordered_map<frame_t, Frame> frames;
    std::unordered_map<image_t, Image> images;
    std::unordered_map<track_t, Track> tracks;

    ConvertDatabaseToGlomap(*database, view_graph, rigs, cameras, frames,
                            images);
    const double t_load_ms = NowMs() - t_load0;
    const size_t n_pairs = view_graph.image_pairs.size();

    if (view_graph.image_pairs.empty()) {
      std::snprintf(out_json, out_cap, "{\"error\":\"no image pairs\"}");
      return 1;
    }

    GlobalMapperOptions options;
    // [AETHER] full GLOMAP (RA + GP + BA + retriangulation + pruning) so reproj is
    // directly comparable to the COLMAP incremental path. (Core-only RA+GP+BA gave an
    // unfairly high reproj 1.35 because it skips track refinement.)
    options.skip_retriangulation = false;
    options.skip_pruning = false;
    // [AETHER RETRI knobs 2026-07-05] rounds (default 1) and complete/merge
    // reproj thresholds (default 15px, loose); tightening ~8px + second pass
    // = round-3 research lead #5 (longer purer tracks on refined poses).
    if (const char* rr = std::getenv("AETHER_RETRI_ROUNDS"))
      options.num_iteration_retriangulation = atoi(rr);
    if (const char* tr = std::getenv("AETHER_TRI_REPROJ")) {
      options.opt_triangulator.tri_complete_max_reproj_error = atof(tr);
      options.opt_triangulator.tri_merge_max_reproj_error = atof(tr);
    }
    GlobalMapper global_mapper(options);

    const double t_solve0 = NowMs();
    global_mapper.Solve(*database, view_graph, rigs, cameras, frames, images,
                        tracks);
    const double t_solve_ms = NowMs() - t_solve0;

    size_t n_reg = 0;
    for (const auto& [id, img] : images)
      if (img.IsRegistered()) ++n_reg;

    // [AETHER] mean reprojection error (glomap_bench previously didn't output it, so
    // GLOMAP runs had no reproj for the COLMAP-vs-GLOMAP comparison). Convert the GLOMAP
    // result to a colmap::Reconstruction and reuse COLMAP's reproj computation so the
    // number is directly comparable to the COLMAP path.
    double mean_reproj = -1.0;
    char reproj_err[256] = "";
    size_t recon_points = 0, recon_imgs = 0;
    try {
      colmap::Reconstruction recon;
      // include_image_points=true so the colmap Reconstruction actually has the
      // 2D observations needed to compute reprojection error (default false only
      // copies poses+3D points, giving no residuals -> reproj undefined).
      ConvertGlomapToColmap(rigs, cameras, frames, images, tracks, recon,
                            /*cluster_id=*/-1, /*include_image_points=*/true);
      recon_points = recon.NumPoints3D();
      recon_imgs = recon.NumRegImages();
      mean_reproj = recon.ComputeMeanReprojectionError();
    } catch (const std::exception& e) {
      mean_reproj = -1.0;
      std::snprintf(reproj_err, sizeof(reproj_err), "%s", e.what());
    }

    std::snprintf(out_json, out_cap,
                  "{\"db_load_ms\":%.1f,\"solve_ms\":%.1f,\"n_images\":%zu,"
                  "\"n_registered\":%zu,\"n_pairs\":%zu,\"n_tracks\":%zu,"
                  "\"n_cameras\":%zu,\"reproj\":%.4f,\"recon_pts\":%zu,"
                  "\"recon_imgs\":%zu,\"reproj_err\":\"%s\"}",
                  t_load_ms, t_solve_ms, images.size(), n_reg, n_pairs,
                  tracks.size(), cameras.size(), mean_reproj, recon_points,
                  recon_imgs, reproj_err);
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

// FULL post-capture pipeline on-device: GLOMAP (rotation avg + global positioning +
// internal global BA + retriangulation + post-retri BA + pruning) THEN one extra
// COLMAP global bundle_adjuster — the exact host chain that gives 1.28px. Reports
// BOTH reproj_glomap (~host sparse_glomap/0 = 1.59) and reproj_ba (~host 1.28), each
// via colmap::ComputeMeanReprojectionError (same metric host model_analyzer prints),
// plus solve/BA wall times. Writes the final post-BA colmap model to out_dir/0.
extern "C" int glomap_bench_write(const char* db_path, const char* out_dir,
                                  char* out_json, int out_cap) {
  using namespace glomap;
  try {
    const double t0 = NowMs();
    auto database = colmap::Database::Open(db_path);
    ViewGraph view_graph;
    std::unordered_map<rig_t, Rig> rigs;
    std::unordered_map<camera_t, Camera> cameras;
    std::unordered_map<frame_t, Frame> frames;
    std::unordered_map<image_t, Image> images;
    std::unordered_map<track_t, Track> tracks;
    ConvertDatabaseToGlomap(*database, view_graph, rigs, cameras, frames, images);
    if (view_graph.image_pairs.empty()) {
      std::snprintf(out_json, out_cap, "{\"error\":\"no image pairs\"}");
      return 1;
    }
    GlobalMapperOptions options;
    // [AETHER GRAVITY 2026-07-05] per-image ARKit gravity into rotation
    // averaging (3-DoF -> 1-DoF per image; GLOMAP-author lineage, ECCV24).
    // File format per pose_io.h: IMAGE_NAME GX GY GZ with
    // cam_from_world * [0,1,0]^T = g. Flip-fix (#4225 backport) applied in
    // global_rotation_averaging.cc. Gate + dense eyeball before adoption.
    if (const char* gpath = std::getenv("AETHER_GRAVITY")) {
      glomap::ReadGravity(gpath, images);
      int n_g = 0;
      for (auto& [iid, img] : images)
        if (img.frame_ptr && img.frame_ptr->gravity_info.has_gravity) n_g++;
      options.opt_ra.use_gravity = true;
      fprintf(stderr, "[AETHER] gravity: %d/%zu images seeded, use_gravity=1\n",
              n_g, images.size());
    }
    options.skip_retriangulation = false;
    options.skip_pruning = false;
    // [AETHER RETRI knobs 2026-07-05] (write path — the one production/bench
    // actually runs) rounds + complete/merge reproj thresholds, see fn above.
    if (const char* rr = std::getenv("AETHER_RETRI_ROUNDS"))
      options.num_iteration_retriangulation = atoi(rr);
    if (const char* tr = std::getenv("AETHER_TRI_REPROJ")) {
      options.opt_triangulator.tri_complete_max_reproj_error = atof(tr);
      options.opt_triangulator.tri_merge_max_reproj_error = atof(tr);
    }
    // [AETHER OOM salvage] Reduce the global-positioning / BA problem SIZE — the
    // real memory driver (the full-capture problem is ~224k tracks -> ~1.5M scale
    // vars + residual blocks; even ITERATIVE_SCHUR peaked at 3.3GB host / OOM'd at
    // 3068MB on device). Cap tracks and/or raise min-views-per-track so fewer/
    // stronger tracks enter the Ceres problem. Env-overridable so host can sweep
    // without recompiling. Defaults preserve upstream behavior (10M / 3).
    if (const char* s = std::getenv("AETHER_MAX_TRACKS"))
      options.opt_track.max_num_tracks = std::atoi(s);
    if (const char* s = std::getenv("AETHER_MIN_VIEWS")) {
      const int mv = std::atoi(s);
      options.opt_track.min_num_view_per_track = mv;
      options.opt_gp.min_num_view_per_track = mv;
    }
    // [AETHER OPT-CUT3] Internal-BA round de-redundancy. Ceres reports on the
    // dense-414 full chain show round 1 does ALL the real work (cost 2.41e6 ->
    // 1.08e6 @113 iters) while rounds 2/3 are marginal polish (0.02% cost
    // change, 15/2/15/28 iters) that the retri-BA + final CAUCHY BA redo
    // [ROUNDS VERDICT 2026-07-05: knife-3 (rounds=1) REVOKED] rounds=1 caused
    // a dense-level edge-softness regression INVISIBLE to the 9-metric gate
    // (user blind-tested CasDiffMVS dense outputs; counterfactual R3 restored
    // gold sharpness and is the gold model's nearest dense neighbor at 2.09mm).
    // Default back to upstream 3; with the ftol knives rounds 2-3 converge in
    // ~15 iters each so the cost is only ~+1.8min on dense-414 host.
    // Gated by the full metrics_v2 battery like every cut.
    options.num_iteration_bundle_adjustment = 3;
    if (const char* s = std::getenv("AETHER_BA_ROUNDS"))
      options.num_iteration_bundle_adjustment = std::atoi(s);
    // [AETHER KNIFE4 — exploratory, env-gated OFF] Skip the relative-pose
    // re-estimation stage (~7min device / ~2-4min host). Preprocessing already
    // runs DecomposeRelPose (R,t from the db's stored E + inlier cheirality);
    // the skipped stage is a refinement pass. Whether RA/GP survive on
    // decomposed-only poses without quality loss is EXACTLY what the full
    // metrics_v2 battery gate decides. db qvec/tvec are NULL here, so this
    // relies on DecomposeRelPose, not stored poses.
    if (std::getenv("AETHER_SKIP_RELPOSE"))
      options.skip_relative_pose_estimation = true;
    // [AETHER KNIFE6 — skip internal full-BA stage2] The pipeline runs THREE
    // BA polishing passes (internal stage2 ~609s host = 45% of solve, then
    // retri-BA, then the final full-param CAUCHY BA). Setting
    // opt_ba.optimize_rotations=false skips stage2 (and makes retri-BA
    // position-only); rotations then get their full refinement exactly once,
    // in the final CAUCHY BA. Whether that loses quality is decided by the
    // replicated 9-metric gate — env-gated for the A/B.
    if (std::getenv("AETHER_BA_POSONLY"))
      options.opt_ba.optimize_rotations = false;
    GlobalMapper global_mapper(options);
    const double t_solve0 = NowMs();
    global_mapper.Solve(*database, view_graph, rigs, cameras, frames, images,
                        tracks);
    const double t_solve_ms = NowMs() - t_solve0;

    size_t n_reg = 0;
    for (const auto& [id, img] : images) if (img.IsRegistered()) ++n_reg;
    fprintf(stderr, "[AETHER] solve done: n_reg=%zu n_tracks=%zu "
            "(max_tracks=%d min_views=%d ba_rounds=%d)\n", n_reg, tracks.size(),
            options.opt_track.max_num_tracks,
            options.opt_track.min_num_view_per_track,
            options.num_iteration_bundle_adjustment); fflush(stderr);

    // [AETHER KNIFE2 — memory lifetime] Everything below only needs
    // rigs/cameras/frames/images/tracks. The view graph (85k ImagePair structs
    // with inlier index vectors) and the sqlite database handle are dead weight
    // from here on; free them BEFORE the convert/extra-BA phase where peak RSS
    // occurs. Pure lifetime management — zero effect on results.
    view_graph.image_pairs.clear();
    view_graph.image_pairs.rehash(0);
    database.reset();

    // ── FULL POST-CAPTURE PIPELINE (apples-to-apples with host) ──────────────
    // GlobalMapper::Solve above ALREADY runs GLOMAP's internal pipeline: global
    // rotation averaging + positioning + N iterations of global BA + (now that the
    // ODR stub is gone) RetriangulateTracks + a post-retri BA + pruning. That is
    // exactly what the host `glomap` CLI writes as sparse_glomap/0 -> 1.59px.
    //
    // The host "full chain" then layers ONE extra COLMAP global bundle_adjuster on
    // top of that model (sparse_glomap -> colmap bundle_adjuster -> 1.28px). We
    // replicate that here on-device so the final number is directly comparable.
    // Convert to a colmap::Reconstruction (include_image_points=true so it has the
    // 2D observations needed for BA + ComputeMeanReprojectionError, the SAME metric
    // host model_analyzer prints).
    // [AETHER 414db FIX] Pre-sanitize BEFORE conversion. When pruning deregisters
    // an image (e.g. 413/414 registered), glomap tracks can still hold observations
    // of the unregistered image; ConvertGlomapToColmap(include_image_points=true)
    // then throws "Image with ID N does not exist" INSIDE the conversion, so the
    // post-conversion sanitize below never runs. Drop those observations first;
    // drop tracks that fall under 2 observations.
    {
      size_t dropped_obs = 0, dropped_tracks = 0;
      for (auto it = tracks.begin(); it != tracks.end();) {
        auto& obs = it->second.observations;
        const size_t before = obs.size();
        obs.erase(std::remove_if(obs.begin(), obs.end(),
                                 [&](const Observation& o) {
                                   auto im = images.find(o.first);
                                   return im == images.end() ||
                                          !im->second.IsRegistered();
                                 }),
                  obs.end());
        dropped_obs += before - obs.size();
        if (obs.size() < 2) {
          it = tracks.erase(it);
          ++dropped_tracks;
        } else {
          ++it;
        }
      }
      fprintf(stderr, "[AETHER] pre-convert sanitize: dropped %zu obs, %zu tracks\n",
              dropped_obs, dropped_tracks);
      fflush(stderr);
    }
    // [AETHER OPT-CUT2] lifecycle clears + phase-tagged RSS attribution.
    aether_phase_rss("post_solve");
    const size_t n_tracks_final = tracks.size();
    // view_graph is dead after Solve (converter never reads it): 85k ImagePair
    // nodes + metadata. features_undist was GP-only (converter uses .features).
    { auto tmp = ViewGraph(); std::swap(view_graph.image_pairs, tmp.image_pairs); }
    for (auto& [iid, img] : images) {
      std::vector<Eigen::Vector3d>().swap(img.features_undist);
    }
    aether_phase_rss("pre_convert(cleared vg+undist)");

    auto recon = std::make_shared<colmap::Reconstruction>();
    ConvertGlomapToColmap(rigs, cameras, frames, images, tracks, *recon,
                          /*cluster_id=*/-1, /*include_image_points=*/true);
    aether_phase_rss("post_convert");
    // glomap-side structures are fully superseded by `recon` from here on
    // (reproj/BA/write all operate on recon). Free them before the extra BA.
    { std::unordered_map<track_t, Track>().swap(tracks); }
    { std::unordered_map<image_t, Image>().swap(images); }
    { std::unordered_map<frame_t, Frame>().swap(frames); }
    aether_phase_rss("post_glomap_free");

    // [AETHER] Sanitize dangling references. GLOMAP's final reconstruction_pruning
    // deregisters weakly-connected frames/images; ConvertGlomapToColmap then removes
    // those images, but Point3D tracks can still hold TrackElements pointing at the
    // removed image ids. That makes the reconstruction non-self-consistent and any
    // downstream colmap op (BA / ComputeMeanReprojectionError) throws
    // "Image with ID N does not exist". Drop those dangling track elements; delete
    // points that fall below 2 observations afterwards.
    {
      std::vector<colmap::point3D_t> to_delete;
      for (const auto& [pid, p3d] : recon->Points3D()) {
        std::vector<colmap::TrackElement> dangling;
        for (const auto& el : p3d.track.Elements())
          if (!recon->ExistsImage(el.image_id)) dangling.push_back(el);
        if (dangling.empty()) continue;
        colmap::Track& tr = recon->Point3D(pid).track;
        for (const auto& el : dangling) tr.DeleteElement(el.image_id, el.point2D_idx);
        if (tr.Length() < 2) to_delete.push_back(pid);
      }
      for (colmap::point3D_t pid : to_delete) recon->DeletePoint3D(pid);
    }

    // [AETHER KNIFE2 — memory lifetime] The colmap Reconstruction is now
    // self-contained; the GLOMAP-side containers (204k tracks with observation
    // vectors + per-image feature arrays) are dead weight during the extra BA /
    // write phase where peak RSS lives. Free them. Zero effect on results.
    tracks.clear();
    images.clear();
    frames.clear();
    rigs.clear();
    cameras.clear();

    fprintf(stderr, "[AETHER] convert ok: recon_imgs(reg)=%zu recon_frames(reg)=%zu pts=%zu\n",
            recon->NumRegImages(), recon->NumRegFrames(), recon->NumPoints3D());
    fflush(stderr);

    const size_t recon_pts = recon->NumPoints3D();
    const size_t recon_imgs = recon->NumRegImages();
    // reproj of GLOMAP-only model (should ~match host sparse_glomap/0 = 1.59).
    double reproj_glomap = -1.0;
    try { reproj_glomap = recon->ComputeMeanReprojectionError(); } catch (...) {}

    // ── extra COLMAP global BA — replicates BundleAdjustmentController::Run() with
    // the low-level estimator API (colmap CLI defaults = default-constructed
    // BundleAdjustmentOptions, exactly what host `colmap bundle_adjuster` uses). ──
    double t_ba_ms = -1.0;
    double reproj_ba = -1.0;
    const char* ba_status = "no";
    try {
      if (recon->NumRegFrames() == 0) throw std::runtime_error("no reg frames");
      aether_progress_stage(7);  // [AETHER PROGRESS] extra CAUCHY BA
      const double t_ba0 = NowMs();
      // Avoid degeneracies (same as controller).
      colmap::ObservationManager(*recon).FilterObservationsWithNegativeDepth();
      colmap::BundleAdjustmentOptions ba_options;
      // [AETHER] Apply the COLMAP-validated ship recipe to the GLOMAP chain:
      // CAUCHY@1.0 robust loss on the extra global BA (host: reproj 1.17 -> 1.03 in
      // one pass, replaces a separate CAUCHY pass). Solver auto-routes to
      // SPARSE_SCHUR (414 <= 1000 direct-sparse cap) and the vendored
      // bundle_adjustment_ceres.cc [AETHER] fix forces EIGEN_SPARSE on CPU
      // (Accelerate sparse Cholesky fails on CAUCHY-reweighted Schur) — confirm at
      // runtime via its "[AETHER] solver_used=" log line.
      ba_options.ceres->loss_function_type =
          colmap::CeresBundleAdjustmentOptions::LossFunctionType::CAUCHY;
      ba_options.ceres->loss_function_scale = 1.0;
      // Use all device cores (A16 = 6). Effective only above the 50k-residual
      // multithreading floor, which a dense 414-frame problem clears easily.
      ba_options.ceres->solver_options.num_threads =
          (int)std::thread::hardware_concurrency();
      // [AETHER UNIVERSAL — user decision 2026-07-03] Single code path, no
      // content/size-dependent solver routing. Extra BA uses the auto-routed
      // direct sparse path: SPARSE_SCHUR + (vendored bundle_adjustment_ceres.cc
      // forces EIGEN_SPARSE on CPU — Accelerate crashes on CAUCHY-reweighted
      // Schur). This is the gate-PASS config (host: extra BA 316s, peak base
      // ~2880MiB, all 9 metrics PASS as run A). Faster variants exist
      // (ITERATIVE+explicitSC: 147s, 2842MiB, also gate-PASS) but were
      // intentionally not adopted to keep one universal path; see session
      // notes. Implicit ITERATIVE_SCHUR FAILED the surface_variation gate —
      // never route the extra BA there.
      // Tolerances untouched.
      // [AETHER KNIFE7] Explicit-SC ITERATIVE for the extra BA: 316->147s and
      // full 9-metric gate PASS (run C). Single unconditional path (no
      // routing). Opt-in via AETHER_EXTRA_SC=1 pending the E3 gate verdict.
      if (std::getenv("AETHER_EXTRA_SC")) {
        ba_options.ceres->auto_select_solver_type = false;
        ba_options.ceres->solver_options.linear_solver_type =
            ceres::ITERATIVE_SCHUR;
        ba_options.ceres->solver_options.preconditioner_type =
            ceres::SCHUR_JACOBI;
        ba_options.ceres->solver_options.use_explicit_schur_complement = true;
      }
      // [AETHER FTOL knife 2026-07-05] extra BA hit its 100-iteration cap
      // NO_CONVERGENCE with the tail iterations moving cost only 0.4713->
      // 0.4613 px — a finite ftol should cut the tail at zero quality cost.
      // [CERTIFIED 2026-07-05] extra-BA converge-stop default 1e-5 (R3/R3b
      // family: 9/9 gates + dense eyeball PASS at -59%); env still overrides.
      ba_options.ceres->solver_options.function_tolerance = 1e-5;
      if (const char* e = std::getenv("AETHER_EXTRA_FTOL"))
        ba_options.ceres->solver_options.function_tolerance = atof(e);
      colmap::BundleAdjustmentConfig ba_config;
      for (const colmap::image_t image_id : recon->RegImageIds())
        ba_config.AddImage(image_id);
      // Fix the gauge with two cameras (controller default).
      ba_config.FixGauge(colmap::BundleAdjustmentGauge::TWO_CAMS_FROM_WORLD);
      // [AETHER PROGRESS] iteration-level progress for the extra BA (stage 7)
      struct AetherExtraBACB : public ceres::IterationCallback {
        int max_iter;
        explicit AetherExtraBACB(int m) : max_iter(m) {}
        ceres::CallbackReturnType operator()(
            const ceres::IterationSummary& is) override {
          aether_progress_items(7, is.iteration + 1, max_iter);
          return ceres::SOLVER_CONTINUE;
        }
      } aether_extra_cb(ba_options.ceres->solver_options.max_num_iterations);
      ba_options.ceres->solver_options.callbacks.push_back(&aether_extra_cb);
      std::unique_ptr<colmap::BundleAdjuster> bundle_adjuster =
          colmap::CreateDefaultBundleAdjuster(ba_options, ba_config, *recon);
      bundle_adjuster->Solve();
      recon->UpdatePoint3DErrors();
      t_ba_ms = NowMs() - t_ba0;
      reproj_ba = recon->ComputeMeanReprojectionError();
      ba_status = "ok";
    } catch (const std::exception& e) {
      ba_status = "throw";
      // reproj_glomap already captured; the +BA number just stays -1.
    }

    // write the FINAL (post-BA) colmap model via colmap's native writer -> out_dir/0.
    aether_progress_stage(8);  // [AETHER PROGRESS] write
    const char* wrote = "no";
    try {
      std::string m0 = std::string(out_dir) + "/0";
      colmap::CreateDirIfNotExists(m0, /*recursive=*/true);
      recon->Write(m0);
      wrote = "yes";
    } catch (const std::exception&) { wrote = "throw"; }
    aether_progress_stage(9);  // [AETHER PROGRESS] done

    std::snprintf(out_json, out_cap,
                  "{\"solve_ms\":%.1f,\"ba_ms\":%.1f,\"n_registered\":%zu,"
                  "\"n_tracks\":%zu,\"recon_pts\":%zu,\"recon_imgs\":%zu,"
                  "\"reproj_glomap\":%.4f,\"reproj_ba\":%.4f,"
                  "\"ba_status\":\"%s\",\"wrote\":\"%s\"}",
                  t_solve_ms, t_ba_ms, n_reg, n_tracks_final, recon_pts, recon_imgs,
                  reproj_glomap, reproj_ba, ba_status, wrote);
    (void)t0;
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

#ifdef GLOMAP_BENCH_MAIN
int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = 1;
  FLAGS_minloglevel = 0;
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <db_path> [out_dir]\n", argv[0]);
    return 1;
  }
  char out[1024] = {0};
  int rc;
  if (argc >= 3) {
    // FULL chain (GLOMAP + retri + extra COLMAP BA), same code path as device.
    rc = glomap_bench_write(argv[1], argv[2], out, sizeof(out));
  } else {
    rc = glomap_bench(argv[1], out, sizeof(out));
  }
  std::printf("RESULT %s\n", out);
  return rc;
}
#endif
