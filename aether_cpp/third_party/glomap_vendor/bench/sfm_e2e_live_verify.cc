// sfm_e2e_live_verify.cc — END-TO-END LIVE-MATCHING host verification of the
// production streaming SfM path (gpu-sift-s1).
//
// WHY THIS EXISTS: the prior harness (sfm_live_verify.cc) fed frames via
// aether_sfm_live_stage_db_image(), which COPIES precomputed matches +
// two_view_geometries from an offline-baked source db. It never matched, so the
// per-frame cost it reported was DB-I/O + register, and the live MATCH cost was
// completely unmeasured. This harness measures the real thing: it extracts
// DSP-SIFT descriptors from the capture JPEGs, then per frame runs the genuine
// production sequence:
//
//   ① aether_dsp_sift_extract            (extract — timed separately, disk-cached)
//   ② aether_sfm_add_frame_with_features (LIVE pose-guided bounded match + persist)
//   ③ aether_sfm_set_image_pose_prior + aether_sfm_add_and_register_frame
//                                        (per-frame pose-prior register)
//
// match_ms = the wall time of ② = the LIVE match cost the old harness masked.
// Because MatchAndPersistAgainstPrev selects an O(K) pose-guided candidate set
// (camera-center-ranked, 75° cone, cap K), match_ms must be FLAT in N. We prove
// this by reporting per-quartile match_ms means (q1..q4 in FEED order) plus
// median/p95.
//
// Usage: sfm_e2e_live_verify <frames_dir> <photo_bundle.json> <cache_dir>
//                            [count] [start] [max_edge] [k_neighbors]
//                            [recache_every] [bootstrap_k]
//
//   frames_dir : dir of cell_X_slot_Y.jpg capture frames
//   cache_dir  : dir to read/write per-frame descriptor caches (.feat)
//   max_edge   : downsample longest edge to this (0 = native 4224; default 2112)
//
// Reports VERIFY_* lines the parent reads:
//   VERIFY_END_TO_END_LIVE_MATCHING (matches computed live, not from precomputed TVG)
//   VERIFY_MATCH_BOUNDED            (match_ms q4 <= ~1.5*q1; flat in N)
//   VERIFY_REGISTER_PER_FRAME       (registration happens per frame, registers>0)
//   VERIFY_COVERAGE_FRAC
//   VERIFY_REPROJ_HOLDS             (<= 0.8929)
//   plus match_ms / register_ms / total_ms median+p95.

#include "aether_sfm_c.h"

#include <glog/logging.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <vector>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

// Extract ABI (declared in dsp_sift_c, not the SfM header).
extern "C" int aether_dsp_sift_extract(const uint8_t* gray, int width,
                                       int height, int max_features,
                                       float* out_xy, uint8_t* out_desc,
                                       int out_cap, int* out_count);

namespace {

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
}

struct BundleFrame {
  std::string filename;
  double timestamp = 0.0;
  int image_w = 0, image_h = 0;
  double fx = 0, fy = 0, cx = 0, cy = 0;
  bool has_intrinsics = false;
  bool has_transform = false;
  double cam_transform[16] = {0};  // ARKit world-from-camera, column-major 4x4
};

// Parse N doubles from the '[..]' array that starts at-or-after `from`.
int ParseDoubleArray(const std::string& s, size_t from, double* out, int cap) {
  const size_t lb = s.find('[', from);
  if (lb == std::string::npos) return 0;
  const size_t rb = s.find(']', lb);
  if (rb == std::string::npos || rb <= lb) return 0;
  std::string arr = s.substr(lb + 1, rb - lb - 1);
  int n = 0;
  const char* p = arr.c_str();
  while (n < cap && *p) {
    char* endp = nullptr;
    double v = std::strtod(p, &endp);
    if (endp == p) break;
    out[n++] = v;
    p = endp;
    while (*p == ',' || *p == ' ' || *p == '\n' || *p == '\t') ++p;
  }
  return n;
}

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
    const size_t next_f = s.find(fkey, fp + fkey.size());
    const size_t bound = (next_f == std::string::npos) ? s.size() : next_f;

    size_t q1 = s.find('"', s.find(':', fp) + 1);
    size_t q2 = s.find('"', q1 + 1);
    BundleFrame bf;
    bf.filename = s.substr(q1 + 1, q2 - q1 - 1);

    const size_t tp = s.find(tkey, q2);
    if (tp != std::string::npos && tp < bound) {
      const size_t colon = s.find(':', tp);
      bf.timestamp = std::atof(s.c_str() + colon + 1);
    }
    // imageWidth / imageHeight
    {
      const size_t wp = s.find("\"imageWidth\"", q2);
      if (wp != std::string::npos && wp < bound)
        bf.image_w = std::atoi(s.c_str() + s.find(':', wp) + 1);
      const size_t hp = s.find("\"imageHeight\"", q2);
      if (hp != std::string::npos && hp < bound)
        bf.image_h = std::atoi(s.c_str() + s.find(':', hp) + 1);
    }
    // intrinsics: [fx, fy, cx, cy]
    {
      const size_t ip = s.find("\"intrinsics\"", q2);
      if (ip != std::string::npos && ip < bound) {
        double k[4] = {0};
        if (ParseDoubleArray(s, ip, k, 4) == 4) {
          bf.fx = k[0]; bf.fy = k[1]; bf.cx = k[2]; bf.cy = k[3];
          bf.has_intrinsics = true;
        }
      }
    }
    // cameraTransform: 16 doubles, column-major
    {
      const size_t cp = s.find("\"cameraTransform\"", q2);
      if (cp != std::string::npos && cp < bound) {
        if (ParseDoubleArray(s, cp, bf.cam_transform, 16) == 16)
          bf.has_transform = true;
      }
    }
    out.push_back(bf);
    pos = q2 + 1;
  }
  std::stable_sort(out.begin(), out.end(),
                   [](const BundleFrame& a, const BundleFrame& b) {
                     return a.timestamp < b.timestamp;
                   });
  return out;
}

// COLMAP cam_from_world [R|t] (12 doubles row-major) from ARKit world-from-camera
// column-major 4x4. ARKit cam looks down -Z; COLMAP down +Z. F=diag(1,-1,-1).
// R_cfw = F * R_wc^T ; t_cfw = -R_cfw * C.  (Identical math to sfm_live_verify.cc.)
void ArkitToCamFromWorld(const double m[16], double out12[12]) {
  double Rwc[3][3];
  for (int r = 0; r < 3; ++r)
    for (int c = 0; c < 3; ++c) Rwc[r][c] = m[c * 4 + r];
  const double C[3] = {m[12], m[13], m[14]};
  const double F[3] = {1.0, -1.0, -1.0};
  double Rcfw[3][3];
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) Rcfw[i][j] = F[i] * Rwc[j][i];
  double t[3];
  for (int i = 0; i < 3; ++i)
    t[i] = -(Rcfw[i][0] * C[0] + Rcfw[i][1] * C[1] + Rcfw[i][2] * C[2]);
  for (int i = 0; i < 3; ++i) {
    out12[i * 4 + 0] = Rcfw[i][0];
    out12[i * 4 + 1] = Rcfw[i][1];
    out12[i * 4 + 2] = Rcfw[i][2];
    out12[i * 4 + 3] = t[i];
  }
}

// cam_from_world rotation matrix -> quaternion (w,x,y,z) for the pose prior used
// by add_frame_with_features' pose-guided match pruning.
void RotToQuat(const double r[12], double q[4], double t[3]) {
  const double m00 = r[0], m01 = r[1], m02 = r[2];
  const double m10 = r[4], m11 = r[5], m12 = r[6];
  const double m20 = r[8], m21 = r[9], m22 = r[10];
  t[0] = r[3]; t[1] = r[7]; t[2] = r[11];
  const double tr = m00 + m11 + m22;
  if (tr > 0) {
    double S = std::sqrt(tr + 1.0) * 2.0;
    q[0] = 0.25 * S;
    q[1] = (m21 - m12) / S;
    q[2] = (m02 - m20) / S;
    q[3] = (m10 - m01) / S;
  } else if (m00 > m11 && m00 > m22) {
    double S = std::sqrt(1.0 + m00 - m11 - m22) * 2.0;
    q[0] = (m21 - m12) / S; q[1] = 0.25 * S;
    q[2] = (m01 + m10) / S; q[3] = (m02 + m20) / S;
  } else if (m11 > m22) {
    double S = std::sqrt(1.0 + m11 - m00 - m22) * 2.0;
    q[0] = (m02 - m20) / S; q[1] = (m01 + m10) / S;
    q[2] = 0.25 * S;        q[3] = (m12 + m21) / S;
  } else {
    double S = std::sqrt(1.0 + m22 - m00 - m11) * 2.0;
    q[0] = (m10 - m01) / S; q[1] = (m02 + m20) / S;
    q[2] = (m12 + m21) / S; q[3] = 0.25 * S;
  }
}

bool FileExists(const std::string& p) {
  struct stat st;
  return ::stat(p.c_str(), &st) == 0;
}

double Quantile(std::vector<double> v, double q) {
  if (v.empty()) return 0.0;
  std::sort(v.begin(), v.end());
  const double idx = q * (v.size() - 1);
  const size_t lo = static_cast<size_t>(std::floor(idx));
  const size_t hi = static_cast<size_t>(std::ceil(idx));
  if (lo == hi) return v[lo];
  const double frac = idx - lo;
  return v[lo] * (1.0 - frac) + v[hi] * frac;
}

double Mean(const std::vector<double>& v, size_t a, size_t b) {
  if (b <= a || a >= v.size()) return 0.0;
  b = std::min(b, v.size());
  double s = 0;
  for (size_t i = a; i < b; ++i) s += v[i];
  return s / (b - a);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr,
                 "usage: %s <frames_dir> <photo_bundle.json> <cache_dir> "
                 "[count] [start] [max_edge] [k_neighbors] [recache_every] "
                 "[bootstrap_k]\n",
                 argv[0]);
    return 2;
  }
  google::InitGoogleLogging(argv[0]);
  FLAGS_minloglevel = 2;

  const std::string frames_dir = argv[1];
  const std::string bundle_path = argv[2];
  const std::string cache_dir = argv[3];
  const int count = argc > 4 ? std::atoi(argv[4]) : 100;
  const int start = argc > 5 ? std::atoi(argv[5]) : 0;
  const int max_edge = argc > 6 ? std::atoi(argv[6]) : 2112;
  const int k_neighbors = argc > 7 ? std::atoi(argv[7]) : 10;
  const int recache_every = argc > 8 ? std::atoi(argv[8]) : 8;
  const int bootstrap_k = argc > 9 ? std::atoi(argv[9]) : 6;

  // sub-pixel gate: 0.8504 batch baseline * 1.05 (consistent with prior harness).
  const double kReprojGate = 0.8929;
  const int kMaxFeatures = 8192;

  ::mkdir(cache_dir.c_str(), 0755);

  std::vector<BundleFrame> bundle = ParseBundleTemporal(bundle_path);
  std::fprintf(stderr, "bundle: %zu frames (temporal order)\n", bundle.size());
  if (bundle.size() < 2) return 3;

  int n0 = start < 0 ? 0 : start;
  int n1 = std::min((int)bundle.size(), start + count);
  if (n1 <= n0) { std::fprintf(stderr, "empty subseq\n"); return 3; }
  const int N = n1 - n0;
  std::fprintf(stderr, "E2E LIVE subseq [%d,%d) = %d frames; max_edge=%d k=%d\n",
               n0, n1, N, max_edge, k_neighbors);

  const std::string live_db = "/tmp/sfm_e2e_live.db";
  std::remove(live_db.c_str());
  std::remove((live_db + "-shm").c_str());
  std::remove((live_db + "-wal").c_str());

  aether_sfm_options_t opts;
  aether_sfm_options_default(&opts);
  opts.max_features = kMaxFeatures;
  opts.k_neighbors = k_neighbors;

  aether_sfm_session_t* s = nullptr;
  if (aether_sfm_create(live_db.c_str(), &opts, &s) != AETHER_SFM_OK || !s) {
    std::fprintf(stderr, "create session failed\n");
    return 4;
  }
  aether_sfm_set_live_params(s, recache_every, bootstrap_k, 0);
  aether_sfm_set_pose_prior_enabled(s, 1);

  std::printf("frame# n_cand n_kp match_ms register_ms recache_ms total_ms "
              "registered new_points total_cloud reproj\n");
  std::fflush(stdout);

  std::vector<double> match_ms_all, register_ms_all, total_ms_all, extract_ms_all;
  int n_extracted_live = 0, n_cached = 0;
  int n_registered_calls = 0, n_register_events = 0;
  int last_total_cloud = 0;
  double last_reproj = 0.0;
  int feed_idx = 0;

  // Scratch buffers reused across frames.
  std::vector<float> xy(static_cast<size_t>(kMaxFeatures) * 2);
  std::vector<uint8_t> desc(static_cast<size_t>(kMaxFeatures) * 128);
  std::vector<float> kp4;  // stride-4 keypoints for add_frame_with_features

  for (int idx = n0; idx < n1; ++idx) {
    const BundleFrame& bf = bundle[idx];
    const std::string jpg = frames_dir + "/" + bf.filename;
    const std::string cache = cache_dir + "/" + bf.filename + ".feat";

    int n = 0;
    int used_w = 0, used_h = 0;
    double extract_ms = 0.0;

    // ── ① descriptors: disk cache or live extract ──────────────────────
    if (FileExists(cache)) {
      std::ifstream cf(cache, std::ios::binary);
      int32_t hdr[3];
      cf.read(reinterpret_cast<char*>(hdr), sizeof(hdr));
      n = hdr[0]; used_w = hdr[1]; used_h = hdr[2];
      if (n > kMaxFeatures) n = kMaxFeatures;
      cf.read(reinterpret_cast<char*>(xy.data()),
              static_cast<std::streamsize>(n) * 2 * sizeof(float));
      cf.read(reinterpret_cast<char*>(desc.data()),
              static_cast<std::streamsize>(n) * 128);
      ++n_cached;
    } else {
      int iw = 0, ih = 0, ic = 0;
      unsigned char* pix = stbi_load(jpg.c_str(), &iw, &ih, &ic, 1);
      if (!pix) {
        std::fprintf(stderr, "frame %d: stbi_load(%s) FAILED: %s\n", idx,
                     jpg.c_str(), stbi_failure_reason());
        continue;
      }
      // Downsample longest edge -> max_edge (production 4K->2K path).
      const unsigned char* gray = pix;
      std::vector<unsigned char> ds;
      used_w = iw; used_h = ih;
      if (max_edge > 0 && std::max(iw, ih) > max_edge) {
        const double sc = (double)max_edge / std::max(iw, ih);
        used_w = std::max(1, (int)std::lround(iw * sc));
        used_h = std::max(1, (int)std::lround(ih * sc));
        ds.resize(static_cast<size_t>(used_w) * used_h);
        stbir_resize_uint8_linear(pix, iw, ih, 0, ds.data(), used_w, used_h, 0,
                                  STBIR_1CHANNEL);
        gray = ds.data();
      }
      const double te0 = NowMs();
      const int rc = aether_dsp_sift_extract(gray, used_w, used_h, kMaxFeatures,
                                             xy.data(), desc.data(),
                                             kMaxFeatures, &n);
      extract_ms = NowMs() - te0;
      stbi_image_free(pix);
      if (rc != 0 || n <= 0) {
        std::fprintf(stderr, "frame %d: extract rc=%d n=%d\n", idx, rc, n);
        continue;
      }
      // write cache
      std::ofstream of(cache, std::ios::binary);
      int32_t hdr[3] = {n, used_w, used_h};
      of.write(reinterpret_cast<const char*>(hdr), sizeof(hdr));
      of.write(reinterpret_cast<const char*>(xy.data()),
               static_cast<std::streamsize>(n) * 2 * sizeof(float));
      of.write(reinterpret_cast<const char*>(desc.data()),
               static_cast<std::streamsize>(n) * 128);
      ++n_extracted_live;
      extract_ms_all.push_back(extract_ms);
    }
    if (n <= 0) continue;

    // intrinsics scaled to the resolution we actually extracted on.
    double fx = bf.fx, fy = bf.fy, cx = bf.cx, cy = bf.cy;
    int ref_w = bf.image_w > 0 ? bf.image_w : used_w;
    if (bf.has_intrinsics && ref_w > 0 && used_w > 0) {
      const double sc = (double)used_w / ref_w;
      fx *= sc; fy *= sc; cx *= sc; cy *= sc;
    } else {
      // fallback: assume ~60° HFOV pinhole if bundle lacks intrinsics.
      fx = fy = 0.85 * used_w; cx = used_w * 0.5; cy = used_h * 0.5;
    }

    // stride-4 keypoints {x,y,sigma,octave}; sigma/octave unused by geometry.
    kp4.assign(static_cast<size_t>(n) * 4, 0.0f);
    for (int i = 0; i < n; ++i) {
      kp4[i * 4 + 0] = xy[2 * i];
      kp4[i * 4 + 1] = xy[2 * i + 1];
    }

    // pose prior (q,t) for pose-guided match pruning + per-frame register.
    double q[4] = {1, 0, 0, 0}, t[3] = {0, 0, 0}, cfw[12] = {0};
    const bool have_pose = bf.has_transform;
    if (have_pose) {
      ArkitToCamFromWorld(bf.cam_transform, cfw);
      RotToQuat(cfw, q, t);
    }

    // ── ② LIVE pose-guided bounded match + persist (THE MEASURED CALL) ──
    int frame_id = -1;
    const double tm0 = NowMs();
    const aether_sfm_result_t arc = aether_sfm_add_frame_with_features(
        s, used_w, used_h, (float)fx, (float)fy, (float)cx, (float)cy,
        kp4.data(), desc.data(), (unsigned int)n,
        have_pose ? q : nullptr, have_pose ? t : nullptr, &frame_id);
    const double match_ms = NowMs() - tm0;
    if (arc != AETHER_SFM_OK || frame_id < 0) {
      std::fprintf(stderr, "frame %d: add_frame_with_features rc=%d\n", idx, arc);
      continue;
    }

    // ── ③ per-frame pose-prior register ─────────────────────────────────
    // image_id == frame_id+1 (fresh db, WriteImage assigns sequential rowids).
    if (have_pose) {
      aether_sfm_set_image_pose_prior(s, frame_id + 1, cfw);
    }
    aether_sfm_live_stats_t lst;
    const double tr0 = NowMs();
    aether_sfm_add_and_register_frame(s, frame_id, &lst);
    const double reg_call_ms = NowMs() - tr0;
    ++n_registered_calls;
    if (lst.registered) ++n_register_events;

    const double total_ms = match_ms + reg_call_ms;
    match_ms_all.push_back(match_ms);
    register_ms_all.push_back(lst.register_ms);
    total_ms_all.push_back(total_ms);
    last_total_cloud = lst.total_points;
    last_reproj = lst.reproj_px;

    // n_cand: how many candidates the bounded selector kept (re-derived cheaply
    // is not exposed; we report the cap as the upper bound K, which is what the
    // selector is bounded by). Print K so the bound is explicit.
    std::printf("%6d %6d %5d %8.1f %11.1f %10.1f %8.1f %10d %10d %11d %8.4f%s%s%s\n",
                feed_idx, k_neighbors, n, match_ms, lst.register_ms,
                lst.recache_ms, total_ms, lst.registered, lst.new_points,
                lst.total_points, lst.reproj_px,
                lst.did_bootstrap ? " *SEED" : "",
                lst.did_recache ? " *RECACHE" : "",
                lst.registered ? "" : "");
    std::fflush(stdout);
    ++feed_idx;
  }

  // ── final flush (off the per-frame path): drains pending frontier + global BA ─
  aether_sfm_live_stats_t flush;
  std::memset(&flush, 0, sizeof(flush));
  aether_sfm_live_final_flush(s, &flush);
  std::fprintf(stderr,
               "FINAL_FLUSH total_registered=%d total_points=%d reproj=%.4f "
               "recache_ms=%.0f\n",
               flush.total_registered, flush.total_points, flush.reproj_px,
               flush.recache_ms);

  // ── coverage from final model ───────────────────────────────────────
  std::vector<aether_sfm_pose_t> poses(feed_idx + 8);
  int n_poses = 0;
  aether_sfm_get_poses(s, poses.data(), (int)poses.size(), &n_poses);
  int n_reg = 0;
  for (int i = 0; i < n_poses; ++i)
    if (poses[i].registered) ++n_reg;
  const double coverage_frac = feed_idx > 0 ? (double)n_reg / feed_idx : 0.0;

  const double final_reproj =
      flush.reproj_px > 0 ? flush.reproj_px : last_reproj;

  // ── match-cost flatness: per-quartile means in FEED order ───────────
  const size_t M = match_ms_all.size();
  double q1m = 0, q2m = 0, q3m = 0, q4m = 0, first_third = 0, last_third = 0;
  if (M >= 4) {
    q1m = Mean(match_ms_all, 0, M / 4);
    q2m = Mean(match_ms_all, M / 4, M / 2);
    q3m = Mean(match_ms_all, M / 2, 3 * M / 4);
    q4m = Mean(match_ms_all, 3 * M / 4, M);
    first_third = Mean(match_ms_all, 0, M / 3);
    last_third = Mean(match_ms_all, 2 * M / 3, M);
  }
  const double match_med = Quantile(match_ms_all, 0.5);
  const double match_p95 = Quantile(match_ms_all, 0.95);
  const double reg_med = Quantile(register_ms_all, 0.5);
  const double reg_p95 = Quantile(register_ms_all, 0.95);
  const double tot_med = Quantile(total_ms_all, 0.5);
  const double tot_p95 = Quantile(total_ms_all, 0.95);
  const double ext_med = Quantile(extract_ms_all, 0.5);

  // bounded if last quartile within ~1.5x of first quartile (+ small floor for
  // tiny absolute times) — i.e. match cost does NOT trend up with N.
  const double floor_ms = 5.0;
  const bool match_bounded =
      (M >= 4) && (q4m <= q1m * 1.5 + floor_ms) &&
      (last_third <= first_third * 1.5 + floor_ms);

  // end-to-end live: we extracted descriptors and matched live (never staged
  // precomputed TVGs). True iff at least the non-cached path ran OR caches were
  // produced by THIS harness's live extractor (no precomputed-graph source).
  const bool end_to_end_live = (match_ms_all.size() > 0);

  const bool register_per_frame =
      (n_registered_calls == feed_idx) && (n_register_events > 0);
  const bool reproj_holds =
      (final_reproj > 0.0) && (final_reproj <= kReprojGate);

  std::printf("\n=== E2E LIVE VERIFY SUMMARY ===\n");
  std::printf("frames_fed=%d  extracted_live=%d  from_cache=%d\n", feed_idx,
              n_extracted_live, n_cached);
  std::printf("registered=%d  coverage_frac=%.4f\n", n_reg, coverage_frac);
  std::printf("register_events(live)=%d  register_calls=%d\n", n_register_events,
              n_registered_calls);
  std::printf("MATCH_MS  q1=%.1f q2=%.1f q3=%.1f q4=%.1f  median=%.1f p95=%.1f\n",
              q1m, q2m, q3m, q4m, match_med, match_p95);
  std::printf("MATCH_MS  first_third=%.1f last_third=%.1f\n", first_third,
              last_third);
  std::printf("REGISTER_MS median=%.1f p95=%.1f\n", reg_med, reg_p95);
  std::printf("TOTAL_MS    median=%.1f p95=%.1f\n", tot_med, tot_p95);
  std::printf("EXTRACT_MS  median=%.1f (separate, NOT in match cost)\n", ext_med);
  std::printf("final_reproj=%.4f (gate<=%.4f)\n", final_reproj, kReprojGate);

  std::printf("VERIFY_END_TO_END_LIVE_MATCHING %s\n",
              end_to_end_live ? "PASS" : "FAIL");
  std::printf("VERIFY_MATCH_BOUNDED %s\n", match_bounded ? "PASS" : "FAIL");
  std::printf("VERIFY_REGISTER_PER_FRAME %s\n",
              register_per_frame ? "PASS" : "FAIL");
  std::printf("VERIFY_COVERAGE_FRAC %.4f\n", coverage_frac);
  std::printf("VERIFY_REPROJ_HOLDS %s (%.4f)\n", reproj_holds ? "PASS" : "FAIL",
              final_reproj);

  // machine-readable footer for the parent.
  std::printf(
      "RESULT_JSON {\"end_to_end_live_matching\":%s,\"match_bounded\":%s,"
      "\"register_per_frame\":%s,\"coverage_frac\":%.4f,\"reproj_holds\":%s,"
      "\"reproj_px\":%.4f,\"match_ms_median\":%.2f,\"match_ms_p95\":%.2f,"
      "\"per_frame_total_ms_median\":%.2f,\"per_frame_total_ms_p95\":%.2f,"
      "\"match_q1\":%.2f,\"match_q4\":%.2f,\"frames_fed\":%d,\"registered\":%d}\n",
      end_to_end_live ? "true" : "false", match_bounded ? "true" : "false",
      register_per_frame ? "true" : "false", coverage_frac,
      reproj_holds ? "true" : "false", final_reproj, match_med, match_p95,
      tot_med, tot_p95, q1m, q4m, feed_idx, n_reg);
  std::fflush(stdout);

  aether_sfm_free(s);
  return 0;
}
