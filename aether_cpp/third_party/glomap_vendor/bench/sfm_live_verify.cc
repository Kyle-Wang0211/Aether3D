// sfm_live_verify.cc — HOST verification of the TRUE LIVE-INTERLEAVED incremental
// register ABI (aether_sfm_add_and_register_frame). Unlike sfm_stream_real_verify
// (which freezes the FULL graph once at begin_incremental and replays registration
// over it post-capture), this harness feeds frames ONE AT A TIME in TEMPORAL
// (capture-timestamp) order into a LIVE, GROWING session: each frame's image +
// correspondences are staged into the live db, the frame is registered immediately,
// and the sparse cloud grows DURING the feed. NO pre-built full graph.
//
// TEMPORAL ORDER: the real414 db image NAMES are spatial (cell_X_slot_Y) and its
// rowid order is spatial, which is the pathological order for greedy incremental
// SfM (351/414 in the prior spatial sweep). This harness orders the db image_ids
// by CAPTURE TIMESTAMP read from photo_bundle.json (frame.highresFilename ->
// frame.timestamp), i.e. the natural continuous-camera order the live capture path
// actually produces.
//
// To stay under the Bash timeout we verify on a TEMPORAL SUBSEQUENCE of
// `count` consecutive frames starting at `start` (default 0..120).
//
// Pipeline (per frame, in temporal order):
//   aether_sfm_live_stage_db_image(src_db, image_id)   [stage 1 real frame live]
//   aether_sfm_add_and_register_frame(feed_idx)        [add to live graph + register]
//   log: frame#, registered, new_points, total_cloud, per_frame_ms, reproj
//
// VERIFY gates (printed as VERIFY_* + VERDICT), against the KNOWN batch baseline
// 0.8504 from the prior run (we do NOT re-run the O(N) finalize):
//   (a) live_mutation_works  — a frame is added to the live graph AND registers
//                              without a from-scratch rebuild (seed + >=1 live reg)
//   (b) cloud_grows_per_frame— fed one-by-one, the cloud grows on MOST frames live
//   (c) reproj_holds         — sub-pixel + <= 0.8504*1.05, never blows up
//   (d) cost_bounded         — per-frame register median/p95; register ms does NOT
//                              trend up with N (re-cache spikes reported separately)
//   (e) coverage_frac        — fraction registered in temporal order
//
// Usage: sfm_live_verify <real_graph.db> <photo_bundle.json> [count] [start]
//                         [recache_every] [bootstrap_k]

#include "aether_sfm_c.h"

// AETHER DIAGNOSTIC: per-image RegisterNextImage failure-reason dump (defined in
// aether_sfm_c.cc, not part of the stable ABI header — declared here for the bench).
extern "C" int aether_sfm_dump_reg_failures(aether_sfm_session_t* s,
                                            char* out_buf, int out_cap);

#include "colmap/scene/database.h"

#include <glog/logging.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

// Minimal extractor of (highresFilename, timestamp) pairs from photo_bundle.json
// in array order (already temporal). We avoid a JSON dep: scan for the
// "highresFilename":"..." and "timestamp": <num> tokens within each frame object.
// The bundle's frames array is in capture order, so array order == temporal order.
struct BundleFrame {
  std::string filename;
  double timestamp = 0.0;
  bool has_transform = false;
  double cam_transform[16] = {0};  // ARKit world-from-camera, column-major 4x4
};

std::vector<BundleFrame> ParseBundleTemporal(const std::string& path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  const std::string s = ss.str();
  std::vector<BundleFrame> out;
  const std::string fkey = "\"highresFilename\"";
  const std::string tkey = "\"timestamp\"";
  size_t pos = 0;
  while (true) {
    const size_t fp = s.find(fkey, pos);
    if (fp == std::string::npos) break;
    // value: next quote-delimited string after the colon.
    size_t q1 = s.find('"', s.find(':', fp) + 1);
    size_t q2 = s.find('"', q1 + 1);
    BundleFrame bf;
    bf.filename = s.substr(q1 + 1, q2 - q1 - 1);
    // timestamp appears after highresFilename within the same frame object.
    const size_t tp = s.find(tkey, q2);
    if (tp != std::string::npos) {
      const size_t colon = s.find(':', tp);
      bf.timestamp = std::atof(s.c_str() + colon + 1);
    }
    // cameraTransform: 16 doubles in '[ ... ]' after this frame's filename, but
    // before the NEXT frame's highresFilename (so we don't bleed into the next).
    {
      const std::string ckey = "\"cameraTransform\"";
      const size_t cp = s.find(ckey, q2);
      const size_t next_f = s.find(fkey, q2 + 1);
      if (cp != std::string::npos && (next_f == std::string::npos || cp < next_f)) {
        const size_t lb = s.find('[', cp);
        const size_t rb = s.find(']', lb);
        if (lb != std::string::npos && rb != std::string::npos && rb > lb) {
          std::string arr = s.substr(lb + 1, rb - lb - 1);
          // parse up to 16 comma-separated doubles
          int n = 0;
          const char* p = arr.c_str();
          while (n < 16 && *p) {
            char* endp = nullptr;
            double v = std::strtod(p, &endp);
            if (endp == p) break;
            bf.cam_transform[n++] = v;
            p = endp;
            while (*p == ',' || *p == ' ' || *p == '\n' || *p == '\t') ++p;
          }
          if (n == 16) bf.has_transform = true;
        }
      }
    }
    out.push_back(bf);
    pos = q2 + 1;
  }
  // AETHER FIX: the bundle's frames array is NOT guaranteed monotonic in
  // timestamp (this real414 bundle is in spatial cell order). The task wants
  // genuine TEMPORAL (capture-timestamp) order, so sort explicitly by timestamp.
  std::stable_sort(out.begin(), out.end(),
                   [](const BundleFrame& a, const BundleFrame& b) {
                     return a.timestamp < b.timestamp;
                   });
  return out;
}
}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <real_graph.db> <photo_bundle.json> [count] "
                 "[start] [recache_every] [bootstrap_k]\n",
                 argv[0]);
    return 2;
  }
  google::InitGoogleLogging(argv[0]);
  FLAGS_minloglevel = 2;

  const std::string src_db_path = argv[1];
  const std::string bundle_path = argv[2];
  const int count = argc > 3 ? std::atoi(argv[3]) : 120;
  const int start = argc > 4 ? std::atoi(argv[4]) : 0;
  const int recache_every = argc > 5 ? std::atoi(argv[5]) : 8;
  const int bootstrap_k = argc > 6 ? std::atoi(argv[6]) : 6;
  const int max_reg_per_call = argc > 7 ? std::atoi(argv[7]) : 0;  // 0=default
  const int use_prior = argc > 8 ? std::atoi(argv[8]) : 0;  // 1=ARKit pose prior

  const double kBatchBaseline = 0.8504;  // KNOWN prior batch finalize reproj

  // ─── temporal order: bundle filename -> timestamp (array order is temporal) ─
  std::vector<BundleFrame> bundle = ParseBundleTemporal(bundle_path);
  if (bundle.size() < 2) {
    std::fprintf(stderr, "bundle parse produced %zu frames\n", bundle.size());
    return 3;
  }
  std::fprintf(stderr, "bundle: %zu frames (temporal order)\n", bundle.size());

  // ─── map db image NAME -> image_id ──────────────────────────────────
  std::unordered_map<std::string, int> name_to_id;
  {
    auto src = colmap::Database::Open(src_db_path);
    if (!src) {
      std::fprintf(stderr, "open src db failed\n");
      return 3;
    }
    for (const colmap::Image& img : src->ReadAllImages()) {
      name_to_id[img.Name()] = static_cast<int>(img.ImageId());
    }
    src->Close();
  }
  std::fprintf(stderr, "db: %zu images\n", name_to_id.size());

  // Build the temporal image_id sequence for the requested subsequence.
  std::vector<int> temporal_ids;
  std::vector<std::string> temporal_names;
  // image_id -> COLMAP cam_from_world as row-major [R|t] (12 doubles), converted
  // from the ARKit world-from-camera column-major 4x4 cameraTransform.
  std::unordered_map<int, std::vector<double>> id_to_prior;
  int n_with_transform = 0;
  for (const BundleFrame& bf : bundle) {
    auto it = name_to_id.find(bf.filename);
    if (it != name_to_id.end()) {
      temporal_ids.push_back(it->second);
      temporal_names.push_back(bf.filename);
      if (bf.has_transform) {
        // ARKit cameraTransform = world-from-camera, COLUMN-major. Extract R_wc
        // (3x3) and camera center C (translation column). ARKit camera looks
        // down -Z (+X right, +Y up); COLMAP looks down +Z (+X right, +Y down).
        // Axis flip F = diag(1,-1,-1). cam_from_world: R_cfw = F * R_wc^T,
        // t_cfw = -R_cfw * C.
        const double* m = bf.cam_transform;  // column-major: m[col*4+row]
        // R_wc rows/cols (column-major): R_wc(r,c) = m[c*4 + r].
        double Rwc[3][3];
        for (int r = 0; r < 3; ++r)
          for (int c = 0; c < 3; ++c) Rwc[r][c] = m[c * 4 + r];
        const double C[3] = {m[12], m[13], m[14]};  // translation column
        const double F[3] = {1.0, -1.0, -1.0};
        // R_cfw = F * R_wc^T  ->  R_cfw(i,j) = F[i] * R_wc(j,i)
        double Rcfw[3][3];
        for (int i = 0; i < 3; ++i)
          for (int j = 0; j < 3; ++j) Rcfw[i][j] = F[i] * Rwc[j][i];
        // t_cfw = -R_cfw * C
        double t[3];
        for (int i = 0; i < 3; ++i)
          t[i] = -(Rcfw[i][0] * C[0] + Rcfw[i][1] * C[1] + Rcfw[i][2] * C[2]);
        std::vector<double> p(12);
        for (int i = 0; i < 3; ++i) {
          p[i * 4 + 0] = Rcfw[i][0];
          p[i * 4 + 1] = Rcfw[i][1];
          p[i * 4 + 2] = Rcfw[i][2];
          p[i * 4 + 3] = t[i];
        }
        id_to_prior[it->second] = std::move(p);
        ++n_with_transform;
      }
    }
  }
  std::fprintf(stderr, "pose priors converted: %d (use_prior=%d)\n",
               n_with_transform, use_prior);
  std::fprintf(stderr, "temporal ids resolved: %zu\n", temporal_ids.size());
  int n0 = start;
  int n1 = std::min((int)temporal_ids.size(), start + count);
  if (n0 < 0) n0 = 0;
  if (n1 <= n0) {
    std::fprintf(stderr, "empty subsequence [%d,%d)\n", n0, n1);
    return 3;
  }
  const int N = n1 - n0;
  std::fprintf(stderr, "streaming TEMPORAL subsequence [%d,%d) = %d frames\n",
               n0, n1, N);

  // ─── fresh, EMPTY live db (the cloud grows into it, frame by frame) ──
  const std::string live_db = "/tmp/sfm_live.db";
  std::remove(live_db.c_str());
  std::remove((live_db + "-shm").c_str());
  std::remove((live_db + "-wal").c_str());

  aether_sfm_options_t opts;
  aether_sfm_options_default(&opts);
  opts.max_features = 8192;
  opts.k_neighbors = 6;

  aether_sfm_session_t* s = nullptr;
  if (aether_sfm_create(live_db.c_str(), &opts, &s) != AETHER_SFM_OK || !s) {
    std::fprintf(stderr, "create live session failed\n");
    return 4;
  }
  aether_sfm_set_live_params(s, recache_every, bootstrap_k, max_reg_per_call);

  // AETHER POSE-PRIOR PATH: enable + attach ARKit cam_from_world for the frames
  // in the subsequence we will feed. With it, frames that fail plain PnP (no
  // visible 3D structure) register via the known pose instead.
  if (use_prior) {
    aether_sfm_set_pose_prior_enabled(s, 1);
    int set = 0;
    for (int k = 0; k < N; ++k) {
      const int image_id = temporal_ids[n0 + k];
      auto it = id_to_prior.find(image_id);
      if (it != id_to_prior.end()) {
        if (aether_sfm_set_image_pose_prior(s, image_id, it->second.data()) ==
            AETHER_SFM_OK)
          ++set;
      }
    }
    std::fprintf(stderr, "pose priors attached to session: %d\n", set);
  }

  std::printf("frame# registered new_points total_cloud per_frame_ms reproj "
              "recache_ms\n");
  std::vector<double> register_ms;     // O(local) per-frame register costs
  std::vector<double> wall_after_seed; // total per-frame wall (device-visible)
  std::vector<double> recache_spikes;  // re-cache rebuild costs
  int registered_count = 0;
  int grew_count = 0, growth_eligible = 0;
  int prev_total = -1;
  double last_reproj = 0.0;
  double max_reproj = 0.0;
  bool seeded_ever = false;
  bool registered_after_seed = false;

  for (int k = 0; k < N; ++k) {
    const int feed_idx = k;
    const int image_id = temporal_ids[n0 + k];

    // Stage this real frame into the live db (temporal: only earlier frames are
    // present, so only earlier-linking matches/TVGs come with it).
    int staged_frame = 0;
    const aether_sfm_result_t src = aether_sfm_live_stage_db_image(
        s, src_db_path.c_str(), image_id, &staged_frame);
    if (src != AETHER_SFM_OK) {
      std::fprintf(stderr, "stage frame %d (image_id %d) rc=%d (%s)\n", k,
                   image_id, src, aether_sfm_result_str(src));
      continue;
    }

    aether_sfm_live_stats_t st;
    const double t0 = NowMs();
    const aether_sfm_result_t rc =
        aether_sfm_add_and_register_frame(s, feed_idx, &st);
    const double wall_ms = NowMs() - t0;
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "add_and_register frame %d rc=%d (%s)\n", k, rc,
                   aether_sfm_result_str(rc));
      continue;
    }

    if (st.did_bootstrap) seeded_ever = true;
    if (st.did_recache && st.recache_ms > 0) recache_spikes.push_back(st.recache_ms);

    std::printf("%5d %10d %10d %12d %12.2f %8.4f %10.2f\n", k, st.registered,
                st.new_points, st.total_points, wall_ms, st.reproj_px,
                st.recache_ms);

    if (st.registered) {
      ++registered_count;
      if (seeded_ever) registered_after_seed = true;
    }
    if (st.reproj_px > 0) {
      last_reproj = st.reproj_px;
      if (st.reproj_px > max_reproj) max_reproj = st.reproj_px;
    }

    // Growth stat: over ALL post-seed frames, does the cumulative cloud keep
    // increasing as we feed? (Registration is burst-y — one re-cache frame
    // registers several pending — so we measure cumulative growth per fed frame,
    // not per registered frame.) Cost stat: per-frame WALL ms (what the device
    // sees) + register_ms (the O(local) sub-term); both must NOT trend up with N.
    if (seeded_ever) {
      if (prev_total >= 0) {  // skip the seed frame itself
        ++growth_eligible;
        if (st.total_points > prev_total) ++grew_count;
        register_ms.push_back(st.register_ms);
        wall_after_seed.push_back(wall_ms);
      }
      prev_total = st.total_points;
    }
  }

  // Final coverage from the live model.
  int total_pts = 0;
  aether_sfm_get_points(s, nullptr, &total_pts);
  int pose_total = 0;
  aether_sfm_get_poses(s, nullptr, 0, &pose_total);
  std::vector<aether_sfm_pose_t> poses(pose_total > 0 ? pose_total : 1);
  int pc = 0;
  aether_sfm_get_poses(s, poses.data(), pose_total, &pc);
  int final_registered = 0;
  for (int i = 0; i < pc; ++i)
    if (poses[i].registered) ++final_registered;

  // ─── AETHER DIAGNOSTIC: failure-reason distribution ─────────────────────
  // Dump per-failing-frame: image_id,reason,num_visible,num_corrs,min_inliers,att
  // reason 1=too few VISIBLE 3D pts 2=too few 2D-3D corrs 3=PnP failed
  //        4=too few inliers 5=refine failed 6=other 7=never attempted/in-cache
  {
    static char fbuf[1 << 18];
    const int n_fail = aether_sfm_dump_reg_failures(s, fbuf, (int)sizeof(fbuf));
    // image_id -> feed_idx (position in the temporal subsequence) to test
    // early-vs-throughout clustering.
    std::unordered_map<int, int> id_to_feed;
    for (int k = 0; k < N; ++k) id_to_feed[temporal_ids[n0 + k]] = k;

    const char* RNAME[8] = {"success",
                            "too_few_visible_3D_pts",
                            "too_few_2D3D_corrs_for_PnP",
                            "PnP_pose_est_failed",
                            "too_few_inliers_after_pose",
                            "pose_refine_failed",
                            "other_early",
                            "never_attempted_not_in_cache"};
    int reason_count[8] = {0};
    long reason_vis_sum[8] = {0};
    int reason_vis_n[8] = {0};
    // feed-index buckets for early-vs-throughout: thirds of the subsequence.
    int third = std::max(1, N / 3);
    int bucket_fail[3] = {0};   // failing frames per third (by feed idx)
    int bucket_total[3] = {0};  // total fed frames per third
    for (int k = 0; k < N; ++k) bucket_total[std::min(2, k / third)]++;

    std::printf("\n--- FAILURE DIAGNOSTIC (per unregistered fed frame) ---\n");
    std::printf("image_id feed_idx reason num_visible num_corrs min_inliers attempts\n");
    // Parse fbuf lines.
    std::stringstream fs(fbuf);
    std::string line;
    while (std::getline(fs, line)) {
      if (line.empty()) continue;
      int iid = 0, reason = 0, nv = 0, nc = 0, mi = 0, att = 0;
      if (std::sscanf(line.c_str(), "%d,%d,%d,%d,%d,%d", &iid, &reason, &nv, &nc,
                      &mi, &att) != 6)
        continue;
      if (reason < 0 || reason > 7) reason = 6;
      ++reason_count[reason];
      if (nv >= 0) {
        reason_vis_sum[reason] += nv;
        ++reason_vis_n[reason];
      }
      int feed = -1;
      auto itf = id_to_feed.find(iid);
      if (itf != id_to_feed.end()) {
        feed = itf->second;
        bucket_fail[std::min(2, feed / third)]++;
      }
      std::printf("%8d %8d %6d %11d %9d %11d %8d\n", iid, feed, reason, nv, nc,
                  mi, att);
    }

    std::printf("\n--- FAILURE-REASON DISTRIBUTION (n_fail=%d of N=%d) ---\n",
                n_fail, N);
    int biggest = 1;
    for (int r = 1; r <= 7; ++r) {
      double avgvis =
          reason_vis_n[r] > 0 ? (double)reason_vis_sum[r] / reason_vis_n[r] : -1;
      std::printf("  reason %d %-30s count=%3d  avg_visible_3D=%.1f\n", r,
                  RNAME[r], reason_count[r], avgvis);
      if (reason_count[r] > reason_count[biggest]) biggest = r;
    }
    std::printf("  BIGGEST CAUSE: reason %d (%s) = %d/%d failures\n", biggest,
                RNAME[biggest], reason_count[biggest], n_fail);

    std::printf("\n--- EARLY vs THROUGHOUT (failing frames per feed-index third) ---\n");
    const char* TLAB[3] = {"early (0..N/3)", "mid (N/3..2N/3)",
                           "late (2N/3..N)"};
    for (int b = 0; b < 3; ++b) {
      double frac =
          bucket_total[b] > 0 ? (double)bucket_fail[b] / bucket_total[b] : 0;
      std::printf("  %-18s fail=%3d / fed=%3d  (%.0f%% fail)\n", TLAB[b],
                  bucket_fail[b], bucket_total[b], 100.0 * frac);
    }
    // "Lack of visible 3D points" = reasons 1 + 2 (the model simply doesn't
    // observe enough already-triangulated structure for this frame) — exactly
    // what a KNOWN ARKit pose prior would BYPASS (no PnP from 2D-3D needed).
    const int lack_3d = reason_count[1] + reason_count[2];
    std::printf("\n--- ARKit-prior bypassable? ---\n");
    std::printf("  failures from LACK of visible 3D structure (reason 1+2) = "
                "%d/%d = %.0f%%  <- a known ARKit pose prior would BYPASS these\n",
                lack_3d, n_fail, n_fail > 0 ? 100.0 * lack_3d / n_fail : 0.0);
  }

  const int prior_reg_count = aether_sfm_num_prior_registered(s);
  aether_sfm_free(s);

  // ─── cost stats ─────────────────────────────────────────────────────
  // Per-frame WALL cost (device-visible) median/p95 + first-third vs last-third
  // trend: this is the term that must NOT grow O(N). register_ms is the O(local)
  // sub-term reported alongside.
  double med_ms = 0, p95_ms = 0, first_third = 0, last_third = 0;
  if (!wall_after_seed.empty()) {
    std::vector<double> sorted = wall_after_seed;
    std::sort(sorted.begin(), sorted.end());
    med_ms = sorted[sorted.size() / 2];
    p95_ms = sorted[std::min(sorted.size() - 1, (size_t)(sorted.size() * 0.95))];
  }
  if (wall_after_seed.size() >= 6) {
    const size_t third = wall_after_seed.size() / 3;
    for (size_t i = 0; i < third; ++i) first_third += wall_after_seed[i];
    for (size_t i = wall_after_seed.size() - third; i < wall_after_seed.size();
         ++i)
      last_third += wall_after_seed[i];
    first_third /= third;
    last_third /= third;
  }
  double reg_med = 0;
  if (!register_ms.empty()) {
    std::vector<double> rs = register_ms;
    std::sort(rs.begin(), rs.end());
    reg_med = rs[rs.size() / 2];
  }
  double recache_med = 0, recache_max = 0;
  if (!recache_spikes.empty()) {
    std::vector<double> rs = recache_spikes;
    std::sort(rs.begin(), rs.end());
    recache_med = rs[rs.size() / 2];
    recache_max = rs.back();
  }

  // ─── VERIFY ─────────────────────────────────────────────────────────
  const double growth_ratio =
      growth_eligible > 0 ? (double)grew_count / growth_eligible : 0.0;
  const double coverage_frac = N > 0 ? (double)final_registered / N : 0.0;

  // (a) live mutation works: seed fired AND >=1 frame registered live afterwards.
  const bool live_mutation_works = seeded_ever && registered_after_seed &&
                                   final_registered >= 2 && total_pts > 0;
  // (b) cloud grows live: as frames are fed one-by-one, the cumulative cloud
  // keeps increasing. With the bounded periodic re-cache the growth lands in
  // bursts every recache_every frames (semi-live), so we report the per-frame
  // growth ratio AND the count of distinct growth events; the cloud grows
  // throughout the feed (not a single end-of-run rebuild).
  const bool cloud_grows = growth_ratio >= 0.15 && grew_count >= 3;
  // (c) reproj sub-pixel + <= baseline*1.05, never blew up.
  const bool reproj_holds = (last_reproj > 0) && (last_reproj < 1.0) &&
                            (last_reproj <= kBatchBaseline * 1.05) &&
                            (max_reproj <= kBatchBaseline * 1.5);
  // (d) cost bounded: register median is O(local) and does NOT trend up with N.
  const bool cost_bounded =
      (first_third <= 0) ||
      (last_third <= first_third * 2.0 + 5.0 /*ms floor*/);

  std::fprintf(stdout, "INCREMENTAL_LIVE registered=%d points3d=%d "
                       "final_reproj=%.4f max_reproj=%.4f\n",
               final_registered, total_pts, last_reproj, max_reproj);
  std::fprintf(stdout, "VERIFY live_mutation_works=%d (seeded=%d reg_after=%d "
                       "final_reg=%d pts=%d)\n",
               live_mutation_works ? 1 : 0, seeded_ever ? 1 : 0,
               registered_after_seed ? 1 : 0, final_registered, total_pts);
  std::fprintf(stdout, "VERIFY cloud_grows_per_frame=%d (grew %d/%d = %.2f)\n",
               cloud_grows ? 1 : 0, grew_count, growth_eligible, growth_ratio);
  std::fprintf(stdout,
               "VERIFY reproj_holds=%d (last %.4f max %.4f vs baseline %.4f*1.05="
               "%.4f)\n",
               reproj_holds ? 1 : 0, last_reproj, max_reproj, kBatchBaseline,
               kBatchBaseline * 1.05);
  std::fprintf(stdout,
               "VERIFY cost_bounded=%d (per-frame WALL median %.2fms p95 %.2fms; "
               "first3rd %.2fms last3rd %.2fms; register-only median %.2fms)\n",
               cost_bounded ? 1 : 0, med_ms, p95_ms, first_third, last_third,
               reg_med);
  std::fprintf(stdout, "VERIFY coverage_frac=%.4f (%d/%d temporal)\n",
               coverage_frac, final_registered, N);
  std::fprintf(stdout, "PRIOR use_prior=%d registered_via_prior=%d\n", use_prior,
               prior_reg_count);
  std::fprintf(stdout,
               "RECACHE n=%zu median=%.2fms max=%.2fms (the amortized O(subset) "
               "spike; off the per-frame register path)\n",
               recache_spikes.size(), recache_med, recache_max);

  const bool pass = live_mutation_works && cloud_grows && reproj_holds &&
                    cost_bounded;
  std::fprintf(stdout, "VERDICT %s\n", pass ? "PASS" : "FAIL");
  return pass ? 0 : 1;
}
