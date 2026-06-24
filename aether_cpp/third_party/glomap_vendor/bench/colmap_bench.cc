// colmap_bench.cc — on-device benchmark of COLMAP *incremental* SfM
// (register one image at a time + repeated local/global BA), for apples-to-
// apples comparison vs the GLOMAP global mapper on the same db_50.
// C ABI for Dart FFI / native harness.

#include "colmap/controllers/incremental_pipeline.h"
#include "colmap/scene/reconstruction.h"
#include "colmap/scene/reconstruction_manager.h"

#include <glog/logging.h>

#include <mach/mach.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

static double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}
static double RssMB() {
  mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info,
                &count) != KERN_SUCCESS)
    return 0;
  return info.resident_size / 1048576.0;
}

extern "C" int colmap_bench(const char* db_path,
                            const char* image_path,
                            char* out_json,
                            int out_cap) {
  try {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    auto recon_manager = std::make_shared<colmap::ReconstructionManager>();

    const double t0 = NowMs();
    colmap::IncrementalPipeline pipeline(options, image_path, db_path,
                                         recon_manager);
    pipeline.Run();
    const double solve_ms = NowMs() - t0;

    // pick the largest reconstruction; report its quality (incl. reproj error —
    // COLMAP incremental triangulates + retriangulates natively, so this IS the
    // "with re-tri" quality number).
    size_t best_reg = 0, best_pts = 0;
    double best_reproj = 0.0, best_track = 0.0;
    for (size_t i = 0; i < recon_manager->Size(); ++i) {
      const auto& recon = recon_manager->Get(i);
      if (recon->NumRegImages() > best_reg) {
        best_reg = recon->NumRegImages();
        best_pts = recon->NumPoints3D();
        best_reproj = recon->ComputeMeanReprojectionError();
        best_track = recon->ComputeMeanTrackLength();
      }
    }

    std::snprintf(out_json, out_cap,
                  "{\"solve_ms\":%.1f,\"n_models\":%zu,\"n_registered\":%zu,"
                  "\"n_points3d\":%zu,\"reproj_px\":%.4f,\"track_len\":%.3f}",
                  solve_ms, recon_manager->Size(), best_reg, best_pts, best_reproj,
                  best_track);
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

// Per-frame incremental cost: record a cumulative timestamp every time the
// incremental pipeline registers an image, via COLMAP's registration callbacks.
// Deltas between consecutive stamps = cost to register that image (incl. the
// local/global BA fired in between) -> validates "can it keep up with capture".
extern "C" int colmap_bench_perframe(const char* db_path,
                                     const char* image_path,
                                     char* out_json,
                                     int out_cap) {
  try {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    auto recon_manager = std::make_shared<colmap::ReconstructionManager>();
    colmap::IncrementalPipeline pipeline(options, image_path, db_path,
                                         recon_manager);
    std::vector<double> stamps;
    const double t0 = NowMs();
    pipeline.AddCallback(
        colmap::IncrementalPipeline::INITIAL_IMAGE_PAIR_REG_CALLBACK,
        [&]() { stamps.push_back(NowMs() - t0); });
    pipeline.AddCallback(
        colmap::IncrementalPipeline::NEXT_IMAGE_REG_CALLBACK,
        [&]() { stamps.push_back(NowMs() - t0); });
    pipeline.Run();
    const double total = NowMs() - t0;

    std::string arr = "[";
    for (size_t i = 0; i < stamps.size(); ++i) {
      char b[24];
      std::snprintf(b, sizeof(b), "%s%.0f", i ? "," : "", stamps[i]);
      arr += b;
    }
    arr += "]";
    std::snprintf(out_json, out_cap,
                  "{\"total_ms\":%.0f,\"n_steps\":%zu,\"cum_ms\":%s}", total,
                  stamps.size(), arr.c_str());
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

// On-DEVICE per-frame SLA bench: run the incremental pipeline on a prebuilt db
// (features + matches already inside; extract_colors OFF so no images needed)
// and return the PER-FRAME registration deltas — the real-hardware BA cost the
// desktop sweep could only extrapolate. defer=1 mirrors the shipped device
// config (all in-loop global BA deferred -> per-frame == local-BA only).
extern "C" int aether_perframe_bench(const char* db_path,
                                     const char* image_path,
                                     int defer, int lnum, int liter, int mt,
                                     int gref, int giter,
                                     double* out_deltas_ms, int max_deltas,
                                     int* out_n_deltas, double* out_reproj,
                                     int* out_n_reg, double* out_total_ms) {
  try {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    options->min_num_matches = 15;
    options->extract_colors = false;  // db-only; no images on device
    options->defer_global_ba = (defer != 0);
    if (lnum > 0) options->mapper.ba_local_num_images = lnum;
    if (liter > 0) options->ba_local_max_num_iterations = liter;
    if (mt > 0) options->ba_min_num_residuals_for_cpu_multi_threading = mt;
    // PER-FRAME deltas (the BA-factor signal) are independent of the finalize
    // caps — finalize runs AFTER the last NEXT_IMAGE_REG callback. So for the
    // device TIMING run we may cap the finalize (gref1/giter15) to finish faster;
    // reproj is then the capped value (ignore — full-finalize reproj is the
    // desktop 1.1455). Pass gref/giter <=0 to keep the full defaults (5/50).
    if (gref > 0) options->ba_global_max_refinements = gref;
    if (giter > 0) options->ba_global_max_num_iterations = giter;

    auto recon_manager = std::make_shared<colmap::ReconstructionManager>();
    std::vector<double> stamps;
    const double t0 = NowMs();
    colmap::IncrementalPipeline pipeline(options, image_path, db_path,
                                         recon_manager);
    pipeline.AddCallback(
        colmap::IncrementalPipeline::INITIAL_IMAGE_PAIR_REG_CALLBACK,
        [&]() { stamps.push_back(NowMs() - t0); });
    pipeline.AddCallback(colmap::IncrementalPipeline::NEXT_IMAGE_REG_CALLBACK,
                         [&]() { stamps.push_back(NowMs() - t0); });
    pipeline.Run();
    const double total = NowMs() - t0;

    size_t best_reg = 0;
    double best_reproj = 0.0;
    for (size_t i = 0; i < recon_manager->Size(); ++i) {
      const auto& r = recon_manager->Get(i);
      if (r->NumRegImages() > best_reg) {
        best_reg = r->NumRegImages();
        best_reproj = r->ComputeMeanReprojectionError();
      }
    }
    int nd = 0;
    for (size_t i = 1; i < stamps.size() && nd < max_deltas; ++i, ++nd) {
      out_deltas_ms[nd] = stamps[i] - stamps[i - 1];
    }
    if (out_n_deltas) *out_n_deltas = nd;
    if (out_reproj) *out_reproj = best_reproj;
    if (out_n_reg) *out_n_reg = static_cast<int>(best_reg);
    if (out_total_ms) *out_total_ms = total;
    return 0;
  } catch (const std::exception& e) {
    if (out_n_deltas) *out_n_deltas = 0;
    return 2;
  }
}

// On-DEVICE async-finalize validation: exercise the SAME two-phase primitives the
// production ABI (aether_sfm_finalize_async) uses — (1) skip_finalize_global_ba
// for an instant LOCAL recon, (2) the heavy global BA on a WORKER thread via the
// pipeline's public TriangulateReconstruction, splice-swapping the refined model.
// Reports local time/reproj (what the UI sees instantly) vs refined time/reproj
// (the background payoff). Proves the global BA is off the per-frame path.
extern "C" int aether_async_bench(const char* db_path, const char* image_path,
                                  int gref, int giter, int gloss,
                                  int (*thermal_fn)(),
                                  char* out_json, int out_cap) {
  try {
    const int thermal_start = thermal_fn ? thermal_fn() : -1;
    // ── phase 1: LOCAL-only (defer + skip_finalize) — instant ─────────
    auto opts = std::make_shared<colmap::IncrementalPipelineOptions>();
    opts->min_num_matches = 15;
    opts->extract_colors = false;
    opts->defer_global_ba = true;
    opts->skip_finalize_global_ba = true;
    // [AETHER] CAUCHY@1.0 local (shipped config)
    opts->ba_local_loss_type = 2;
    opts->ba_local_loss_scale = 1.0;
    opts->ba_local_max_num_iterations = 15;
    opts->ba_min_num_residuals_for_cpu_multi_threading = 6000;
    auto mgr = std::make_shared<colmap::ReconstructionManager>();
    const double t0 = NowMs();
    colmap::IncrementalPipeline p1(opts, image_path, db_path, mgr);
    p1.Run();
    const double local_ms = NowMs() - t0;
    const int thermal_local = thermal_fn ? thermal_fn() : -1;
    std::shared_ptr<colmap::Reconstruction> local;
    size_t best = 0;
    for (size_t i = 0; i < mgr->Size(); ++i) {
      if (mgr->Get(i)->NumRegImages() >= best) {
        best = mgr->Get(i)->NumRegImages();
        local = mgr->Get(i);
      }
    }
    if (!local) {
      std::snprintf(out_json, out_cap, "{\"error\":\"no local recon\"}");
      return 2;
    }
    const double local_reproj = local->ComputeMeanReprojectionError();
    const int local_reg = static_cast<int>(local->NumRegImages());
    const int local_pts = static_cast<int>(local->NumPoints3D());

    // ── phase 2: global BA on a WORKER thread (off the critical path) ──
    auto refined = std::make_shared<colmap::Reconstruction>(*local);
    std::atomic<int> done{0};
    double refine_ms = 0.0;
    std::thread worker([&]() {
      try {
        const double tr = NowMs();
        auto o2 = std::make_shared<colmap::IncrementalPipelineOptions>();
        o2->min_num_matches = 15;
        o2->extract_colors = false;
        // [AETHER] global loss configurable (gloss: 0=TRIVIAL 1=SOFT_L1 2=CAUCHY) +
        // finalize iteration cap. Non-CAUCHY unlocks the fast direct SPARSE_SCHUR.
        o2->ba_global_loss_type = gloss;
        o2->ba_global_loss_scale = 1.0;
        if (gref > 0) o2->ba_global_max_refinements = gref;
        if (giter > 0) o2->ba_global_max_num_iterations = giter;
        o2->ba_min_num_residuals_for_cpu_multi_threading = 6000;
        auto m2 = std::make_shared<colmap::ReconstructionManager>();
        colmap::IncrementalPipeline p2(o2, image_path, db_path, m2);
        p2.RefineReconstruction(refined);
        refine_ms = NowMs() - tr;
        done.store(1);
      } catch (...) {
        done.store(2);
      }
    });
    worker.join();  // bench waits; in production the UI thread is free meanwhile
    const int thermal_refine = thermal_fn ? thermal_fn() : -1;
    const bool ok = done.load() == 1;
    const double refined_reproj = ok ? refined->ComputeMeanReprojectionError() : 0;
    const int refined_reg = ok ? static_cast<int>(refined->NumRegImages()) : 0;
    const int refined_pts = ok ? static_cast<int>(refined->NumPoints3D()) : 0;

    std::snprintf(
        out_json, out_cap,
        "{\"local_ms\":%.0f,\"local_reproj\":%.4f,\"local_reg\":%d,"
        "\"local_pts\":%d,\"refine_ms\":%.0f,\"refined_reproj\":%.4f,"
        "\"refined_reg\":%d,\"refined_pts\":%d,\"gref\":%d,\"giter\":%d,"
        "\"gloss\":%d,\"th_start\":%d,\"th_local\":%d,\"th_refine\":%d,\"done\":%d}",
        local_ms, local_reproj, local_reg, local_pts, refine_ms, refined_reproj,
        refined_reg, refined_pts, gref, giter, gloss,
        thermal_start, thermal_local, thermal_refine, done.load());
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

// REAL-SCENARIO streaming sim: drive the incremental pipeline frame-by-frame
// from a prebuilt db (features+matches inside), but PACE it like a live capture
// — after each frame's register+BA, sleep so the inter-frame interval is
// frame_interval_ms (the user moving the phone to the next shot). Logs per-frame
// processing time + RSS + thermal so we SEE the real N-dependent growth + the
// periodic-global-BA freeze spikes + the thermal curve over a ~13min capture,
// instead of extrapolating from a back-to-back batch. defer=0/skipfin=0 =
// full-SfM+periodic-global-BA; defer=1 = local-per-frame + global-at-finalize.
extern "C" int aether_realsim_bench(const char* db_path, const char* image_path,
                                    int defer, int skipfin, int frame_interval_ms,
                                    int local_loss_type, double local_loss_scale,
                                    int global_loss_type, double global_loss_scale,
                                    int (*thermal_fn)(), char* out_json,
                                    int out_cap) {
  try {
    auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
    options->min_num_matches = 15;
    options->extract_colors = false;
    options->defer_global_ba = (defer != 0);
    options->skip_finalize_global_ba = (skipfin != 0);
    // [AETHER] combo A/B: 0=TRIVIAL 1=SOFT_L1 2=CAUCHY (stock=1,1.0,0,1.0)
    options->ba_local_loss_type = local_loss_type;
    options->ba_local_loss_scale = local_loss_scale;
    options->ba_global_loss_type = global_loss_type;
    options->ba_global_loss_scale = global_loss_scale;
    options->ba_local_max_num_iterations = 15;
    options->ba_min_num_residuals_for_cpu_multi_threading = 6000;
    auto mgr = std::make_shared<colmap::ReconstructionManager>();

    int frame_idx = 0;
    double peak_rss = 0, max_proc = 0;
    int n_over_2s = 0;
    double frame_start = NowMs();
    colmap::IncrementalPipeline pipeline(options, image_path, db_path, mgr);
    auto cb = [&]() {
      const double proc_ms = NowMs() - frame_start;
      const double rss = RssMB();
      peak_rss = std::max(peak_rss, rss);
      max_proc = std::max(max_proc, proc_ms);
      if (proc_ms > 2000) ++n_over_2s;
      const int thermal = thermal_fn ? thermal_fn() : -1;
      std::printf("  REALSIM defer=%d i=%d proc=%.0fms rss=%.0fMB thermal=%d\n",
                  defer, frame_idx, proc_ms, rss, thermal);
      std::fflush(stdout);
      ++frame_idx;
      const double remain = frame_interval_ms - proc_ms;  // pace to interval
      if (remain > 0)
        std::this_thread::sleep_for(
            std::chrono::milliseconds(static_cast<int>(remain)));
      frame_start = NowMs();
    };
    pipeline.AddCallback(
        colmap::IncrementalPipeline::INITIAL_IMAGE_PAIR_REG_CALLBACK, cb);
    pipeline.AddCallback(colmap::IncrementalPipeline::NEXT_IMAGE_REG_CALLBACK, cb);
    const double t0 = NowMs();
    pipeline.Run();
    const double total = NowMs() - t0;

    size_t best_reg = 0;
    double best_reproj = 0;
    for (size_t i = 0; i < mgr->Size(); ++i)
      if (mgr->Get(i)->NumRegImages() > best_reg) {
        best_reg = mgr->Get(i)->NumRegImages();
        best_reproj = mgr->Get(i)->ComputeMeanReprojectionError();
      }
    std::snprintf(out_json, out_cap,
                  "{\"lt\":%d,\"ls\":%.1f,\"gt\":%d,\"gs\":%.1f,"
                  "\"defer\":%d,\"skipfin\":%d,\"frames\":%d,\"n_reg\":%zu,"
                  "\"reproj\":%.4f,\"peak_rss_mb\":%.0f,\"max_proc_ms\":%.0f,"
                  "\"frames_over_2s\":%d,\"total_s\":%.0f}",
                  local_loss_type, local_loss_scale, global_loss_type,
                  global_loss_scale, defer, skipfin, frame_idx, best_reg,
                  best_reproj, peak_rss, max_proc, n_over_2s, total / 1000);
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(out_json, out_cap, "{\"error\":\"%s\"}", e.what());
    return 2;
  }
}

#ifdef COLMAP_BENCH_MAIN
// Parameterized desktop driver: sweep the global/local BA option fields via argv
// + report the PER-FRAME registration deltas (the SLA growth curve) + reproj.
// Run many configs in parallel against the same read-only db (host ceres).
//   usage: colmap_bench_exe <db> <image_path> [--gref=N --giter=N --gratio=F
//          --liter=N --lref=N --mt=N]
#include <cstdlib>
#include <cstring>

static int g_arg_i(int argc, char** argv, const char* key, int def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], key, kl) == 0) {
      const char* eq = std::strchr(argv[i], '=');
      if (eq) return std::atoi(eq + 1);
    }
  return def;
}
static double g_arg_d(int argc, char** argv, const char* key, double def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], key, kl) == 0) {
      const char* eq = std::strchr(argv[i], '=');
      if (eq) return std::atof(eq + 1);
    }
  return def;
}

int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <db> <image_path> [--gref=N --giter=N --gratio=F "
                 "--liter=N --lref=N --mt=N]\n",
                 argv[0]);
    return 1;
  }
  const char* db_path = argv[1];
  const char* image_path = argv[2];
  auto options = std::make_shared<colmap::IncrementalPipelineOptions>();
  options->min_num_matches = 15;
  options->ba_global_max_refinements =
      g_arg_i(argc, argv, "--gref", options->ba_global_max_refinements);
  options->ba_global_max_num_iterations =
      g_arg_i(argc, argv, "--giter", options->ba_global_max_num_iterations);
  options->ba_global_frames_ratio =
      g_arg_d(argc, argv, "--gratio", options->ba_global_frames_ratio);
  options->ba_local_max_num_iterations =
      g_arg_i(argc, argv, "--liter", options->ba_local_max_num_iterations);
  options->ba_local_max_refinements =
      g_arg_i(argc, argv, "--lref", options->ba_local_max_refinements);
  options->ba_min_num_residuals_for_cpu_multi_threading =
      g_arg_i(argc, argv, "--mt",
              options->ba_min_num_residuals_for_cpu_multi_threading);
  options->mapper.ba_local_num_images =
      g_arg_i(argc, argv, "--lnum", options->mapper.ba_local_num_images);
  options->defer_global_ba =
      g_arg_i(argc, argv, "--defer", options->defer_global_ba ? 1 : 0) != 0;
  options->skip_finalize_global_ba =
      g_arg_i(argc, argv, "--skipfin",
              options->skip_finalize_global_ba ? 1 : 0) != 0;
  // [AETHER] R1/P4 loss sweeps (defaults reproduce stock COLMAP)
  options->ba_local_loss_scale =
      g_arg_d(argc, argv, "--localscale", options->ba_local_loss_scale);
  options->ba_local_loss_type =
      g_arg_i(argc, argv, "--localtype", options->ba_local_loss_type);
  options->ba_global_loss_scale =
      g_arg_d(argc, argv, "--globalscale", options->ba_global_loss_scale);
  options->ba_global_loss_type =
      g_arg_i(argc, argv, "--globaltype", options->ba_global_loss_type);
  std::string out_dir;  // [AETHER] --out=DIR -> WriteText best recon (for GT ATE)
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], "--out=", 6) == 0) out_dir = argv[i] + 6;
  std::fprintf(stderr,
               "[cfg] localscale=%.3f localtype=%d globalscale=%.3f "
               "globaltype=%d defer=%d lnum=%d\n",
               options->ba_local_loss_scale, options->ba_local_loss_type,
               options->ba_global_loss_scale, options->ba_global_loss_type,
               options->defer_global_ba ? 1 : 0,
               options->mapper.ba_local_num_images);

  // [AETHER] --async: production-exact two-phase (instant local + RefineReconstruction
  // finalize). Reports local_reproj (the FLOOR the finalize must beat) AND
  // refined_reproj per cap, so we can verify capping never makes refined >= local.
  if (g_arg_i(argc, argv, "--async", 0) != 0) {
    char j[1024];
    j[0] = 0;
    int gref = g_arg_i(argc, argv, "--gref", 5);
    int giter = g_arg_i(argc, argv, "--giter", 50);
    int gloss = g_arg_i(argc, argv, "--gloss", 2);  // 0=TRIVIAL 1=SOFT_L1 2=CAUCHY
    aether_async_bench(db_path, image_path, gref, giter, gloss, nullptr, j,
                       (int)sizeof(j));
    std::printf("ASYNC %s\n", j);
    return 0;
  }

  auto recon_manager = std::make_shared<colmap::ReconstructionManager>();
  std::vector<double> stamps;
  const double t0 = NowMs();
  colmap::IncrementalPipeline pipeline(options, image_path, db_path,
                                       recon_manager);
  pipeline.AddCallback(
      colmap::IncrementalPipeline::INITIAL_IMAGE_PAIR_REG_CALLBACK,
      [&]() { stamps.push_back(NowMs() - t0); });
  pipeline.AddCallback(colmap::IncrementalPipeline::NEXT_IMAGE_REG_CALLBACK,
                       [&]() { stamps.push_back(NowMs() - t0); });
  pipeline.Run();
  const double total = NowMs() - t0;

  size_t best_reg = 0, best_pts = 0, best_obs = 0;
  double best_reproj = 0.0, best_track = 0.0;
  std::shared_ptr<colmap::Reconstruction> best_recon;
  for (size_t i = 0; i < recon_manager->Size(); ++i) {
    const auto& r = recon_manager->Get(i);
    if (r->NumRegImages() > best_reg) {
      best_reg = r->NumRegImages();
      best_pts = r->NumPoints3D();
      best_reproj = r->ComputeMeanReprojectionError();
      best_obs = r->ComputeNumObservations();        // [AETHER] anti-gaming: observation retention
      best_track = r->ComputeMeanTrackLength();
      best_recon = r;
    }
  }
  if (!out_dir.empty() && best_recon) {              // [AETHER] export poses for GT ATE
    best_recon->WriteText(out_dir);
    std::fprintf(stderr, "[out] wrote recon (%zu imgs) to %s\n", best_reg,
                 out_dir.c_str());
  }
  std::printf(
      "CFG gref=%d giter=%d gratio=%.2f liter=%d lref=%d mt=%d lnum=%d "
      "defer=%d\n",
      options->ba_global_max_refinements, options->ba_global_max_num_iterations,
      options->ba_global_frames_ratio, options->ba_local_max_num_iterations,
      options->ba_local_max_refinements,
      options->ba_min_num_residuals_for_cpu_multi_threading,
      options->mapper.ba_local_num_images, options->defer_global_ba ? 1 : 0);
  std::printf(
      "RESULT total_ms=%.0f n_reg=%zu n_pts=%zu n_obs=%zu track_len=%.3f "
      "reproj=%.4f n_steps=%zu\n",
      total, best_reg, best_pts, best_obs, best_track, best_reproj,
      stamps.size());
  // per-frame registration deltas = the SLA growth curve; report the worst step.
  double maxd = 0;
  size_t maxi = 0;
  std::printf("PERFRAME_DELTAS_MS");
  for (size_t i = 1; i < stamps.size(); ++i) {
    const double d = stamps[i] - stamps[i - 1];
    if (d > maxd) { maxd = d; maxi = i; }
    std::printf(" %.0f", d);
  }
  std::printf("\nMAX_PERFRAME_MS=%.0f at_step=%zu of %zu\n", maxd, maxi,
              stamps.size());
  return 0;
}
#endif
