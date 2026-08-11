// sfm_replay_bench.cc — [INCREMENTAL-GLOBAL-BA A/B 2026-07-13] HOST-ONLY driver
// that replays a pulled device sfm_live.db through the streaming SfM ABI so the
// capture-time rolling global BA (AETHER_INCREMENTAL_GLOBAL_BA) can be A/B'd
// against the finalize output WITHOUT a device.
//
// It is the FIRST caller of aether_sfm_add_frame_features (the feature-injection
// sibling of add_frame, built exactly for this — see aether_sfm_c.h:110). Per
// frame it reads the db's keypoints + RootSIFT descriptors + shared camera
// intrinsics and the ARKit CamFromWorld pose prior from the sidecar
// sfm_fed_frames.jsonl, then:
//     aether_sfm_create
//   → aether_sfm_add_frame_features × N        (CPU match, use_gpu_match=0)
//   → aether_sfm_finalize_async → poll REFINED  (this is the SHIPPING finalize:
//        the sync aether_sfm_finalize rebuilds from the db and never touches the
//        in-memory live_recon that the rolling global BA refines, so only the
//        async live_reuse path exercises the incremental-BA finalize collapse.)
//
// The rolling global BA runs during add_frame_features (MaybeIncrementalGlobalRefine,
// gated on AETHER_INCREMENTAL_GLOBAL_BA=1); the finalize collapse runs in the
// RefineGlobalBA worker. Run twice — env unset (OFF) vs =1 (ON) — and diff the
// finalize sparse cloud (dumped as cloud.ply + COLMAP bin model) + reproj/point
// counts + streaming/finalize wall time.
//
// usage: sfm_replay_bench_exe <src_sfm_live.db> <poses.jsonl> <out_dir>
//        [--k=12] [--max-frames=0]
//        [--tail-fault-remove-frame=-1] [--tail-fault-after-frame=-1]
//        [--tail-fault-kind=pair_overwrite|late_pair|model_replacement|exception_retry]
//
// Both arms MUST use identical args; the only intended variable is the
// AETHER_INCREMENTAL_GLOBAL_BA env (and its cadence/window/rounds knobs).

#include "aether_sfm_c.h"

#include "colmap/feature/types.h"
#include "colmap/scene/camera.h"
#include "colmap/scene/database.h"
#include "colmap/scene/image.h"

#include <glog/logging.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <cstdint>
#include <unordered_map>
#include <vector>

// ─── host GPU-symbol stubs ──────────────────────────────────────────
// aether_sfm_c.cc references the platform Metal TUs (pwsfm_gpu_match.mm /
// dsp_sift_gpu_c) as __attribute__((weak)) so device links them real and host
// resolves them to null. But this exe is the FIRST host caller to pull
// aether_sfm_c.cc.o out of libglomap_full.a, and macOS ld64 rejects a plain
// weak *reference* with no definition ("Undefined symbols"). Provide no-op
// host definitions (production source untouched). use_gpu_match=0 gates every
// call site off, so these never actually run — they exist only to link.
extern "C" int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int,
                                           float*, uint8_t*, int, int*) {
  return -1;  // "GPU extractor unavailable" → add_frame falls back to CPU
}
// [SCALE-PERSIST 2026-08-06] _v2 sibling, same no-op host stub rationale.
extern "C" int aether_dsp_sift_extract_gpu_v2(const uint8_t*, int, int, int,
                                              int, float*, uint8_t*, float*,
                                              float*, int, int*) {
  return -1;  // unavailable → add_frame stays on the CPU _v2 route
}
// [2026-08-10] official_aether_sfm_c.cc 新增的两个 weak 引用(他人改动引入,
// 设备真链、host 需 no-op 桩)。放在 #if 外:official bench 定义了
// AETHER_REPLAY_LINK_REAL_GPU_MATCH,但 host 的真 GPU-match TU 并不含这两个
// 符号,无条件补桩才两条路都能链。
extern "C" void aether_gpu_match_set_preview_fps30(int) {}
extern "C" const char* aether_sed_last_fail_reason(void) { return nullptr; }

#if !defined(AETHER_REPLAY_LINK_REAL_GPU_MATCH)
extern "C" int aether_gpu_match_gemm_pairs(const uint8_t*, int, const uint8_t*,
                                           int, double, uint32_t*, int, int*) {
  return 2;  // "Metal unavailable" (rc bucket 2) → pair skipped if ever called
}
extern "C" int aether_gpu_match_gemm_pairs_guided(
    const uint8_t*, int, const float*, const uint8_t*, int, const float*,
    double, const float*, const float*, int, float, uint32_t*, int, int*) {
  return 2;
}
extern "C" int aether_gpu_match_gemm_pairs_resident(
    uint64_t, uint32_t, uint32_t, const uint8_t*, int, uint32_t, uint32_t,
    const uint8_t*, int, double, uint32_t*, int, int*) {
  return 2;
}
extern "C" void aether_gpu_match_descriptor_residency_invalidate(uint64_t,
                                                                   uint32_t) {}
extern "C" void aether_gpu_match_descriptor_residency_clear_session(uint64_t) {}
extern "C" int aether_gpu_match_descriptor_residency_stats(
    uint64_t, uint64_t*, uint64_t*, uint64_t*, uint64_t*, uint64_t*,
    uint64_t*, uint64_t*, uint64_t*, uint64_t*) {
  return 0;
}
extern "C" int aether_gpu_match_last_error(char*, int) { return 0; }
#endif  // !AETHER_REPLAY_LINK_REAL_GPU_MATCH
extern "C" void aether_sed_last_stages(double*, int) {}
#if defined(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)
extern "C" int aether_sfm_test_tail_cache_inject_v1(aether_sfm_session_t*, int);
#endif

namespace {

double NowMs() {
  using namespace std::chrono;
  return duration<double, std::milli>(steady_clock::now().time_since_epoch())
      .count();
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

// ─── minimal jsonl pose parser ──────────────────────────────────────
// Each line: {"frameId":N, ... "arkitCamFromWorldQwxyz":[qw,qx,qy,qz],
//             "arkitCamFromWorldTxyz":[tx,ty,tz], ...}
struct Pose {
  bool ok = false;
  std::array<double, 4> q{1, 0, 0, 0};  // CamFromWorld qw,qx,qy,qz
  std::array<double, 3> t{0, 0, 0};     // CamFromWorld tx,ty,tz
};

// Parse the N doubles inside the "[...]" that follows `key` in `line`.
static bool ParseArray(const std::string& line, const char* key, double* out,
                       int n) {
  const size_t k = line.find(key);
  if (k == std::string::npos) return false;
  const size_t lb = line.find('[', k);
  if (lb == std::string::npos) return false;
  const char* p = line.c_str() + lb + 1;
  char* end = nullptr;
  for (int i = 0; i < n; ++i) {
    out[i] = std::strtod(p, &end);
    if (end == p) return false;
    p = end;
    while (*p == ',' || *p == ' ') ++p;
  }
  return true;
}

std::unordered_map<int, Pose> LoadPoses(const std::string& path) {
  std::unordered_map<int, Pose> poses;
  std::ifstream in(path);
  std::string line;
  while (std::getline(in, line)) {
    const size_t fk = line.find("\"frameId\":");
    if (fk == std::string::npos) continue;
    const int fid = std::atoi(line.c_str() + fk + 10);
    Pose p;
    const bool okq =
        ParseArray(line, "\"arkitCamFromWorldQwxyz\":", p.q.data(), 4);
    const bool okt =
        ParseArray(line, "\"arkitCamFromWorldTxyz\":", p.t.data(), 3);
    p.ok = okq && okt;
    poses[fid] = p;
  }
  return poses;
}

void WritePly(const std::string& path, const aether_sfm_point_t* pts, int n) {
  std::ofstream out(path, std::ios::binary);
  out << "ply\nformat binary_little_endian 1.0\n";
  out << "element vertex " << n << "\n";
  out << "property float x\nproperty float y\nproperty float z\n";
  out << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
  out << "end_header\n";
  for (int i = 0; i < n; ++i) {
    out.write(reinterpret_cast<const char*>(&pts[i].x), sizeof(float) * 3);
    out.write(reinterpret_cast<const char*>(&pts[i].r), 1);
    out.write(reinterpret_cast<const char*>(&pts[i].g), 1);
    out.write(reinterpret_cast<const char*>(&pts[i].b), 1);
  }
}

}  // namespace

int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = 1;
  if (argc < 4) {
    std::fprintf(stderr,
                 "usage: %s <src_sfm_live.db> <poses.jsonl> <out_dir> "
                 "[--k=12] [--max-frames=0] "
                 "[--tail-fault-remove-frame=-1] "
                 "[--tail-fault-after-frame=-1] "
                 "[--tail-fault-kind=pair_overwrite|late_pair|model_replacement|exception_retry]\n",
                 argv[0]);
    return 1;
  }
  const std::string src_db = argv[1];
  const std::string poses_path = argv[2];
  const std::string out_dir = argv[3];
  const int k = std::atoi(ArgS(argc, argv, "--k", "12").c_str());
  const int max_frames =
      std::atoi(ArgS(argc, argv, "--max-frames", "0").c_str());
  const int tail_fault_remove_frame = std::atoi(
      ArgS(argc, argv, "--tail-fault-remove-frame", "-1").c_str());
  const int tail_fault_after_frame = std::atoi(
      ArgS(argc, argv, "--tail-fault-after-frame", "-1").c_str());
  const std::string tail_fault_kind =
      ArgS(argc, argv, "--tail-fault-kind", "");
  const bool remove_fault = tail_fault_remove_frame >= 0;
  const bool injected_fault = !tail_fault_kind.empty();
  if ((remove_fault && injected_fault) ||
      (remove_fault != (tail_fault_after_frame >= 0) && !injected_fault) ||
      (remove_fault && tail_fault_remove_frame >= tail_fault_after_frame) ||
      (injected_fault && tail_fault_after_frame < 0)) {
    std::fprintf(stderr,
                 "invalid tail fault args: kind=%s remove=%d after=%d\n",
                 tail_fault_kind.c_str(), tail_fault_remove_frame,
                 tail_fault_after_frame);
    return 1;
  }
#if !defined(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)
  if (injected_fault) {
    std::fprintf(stderr, "tail fault hooks are not compiled into this binary\n");
    return 1;
  }
#endif
  // A/B knob: Lowe ratio on the temporal/live match path. Default 0.7 = the
  // aether_sfm_options_default value (aether_sfm_c.cc:4429), so omitting the
  // flag reproduces the untouched baseline byte-for-byte.
  const double ratio =
      std::atof(ArgS(argc, argv, "--ratio", "0.7").c_str());

  const char* incr = std::getenv("AETHER_INCREMENTAL_GLOBAL_BA");
  std::printf("REPLAY src_db=%s poses=%s out=%s k=%d max_frames=%d ratio=%.3f "
              "AETHER_INCREMENTAL_GLOBAL_BA=%s\n",
              src_db.c_str(), poses_path.c_str(), out_dir.c_str(), k,
              max_frames, ratio, incr ? incr : "(unset)");
  std::fflush(stdout);

  // ── source db (read-only): keypoints + descriptors + shared camera ──
  auto db = colmap::Database::Open(src_db);
  std::vector<colmap::Image> images = db->ReadAllImages();
  std::sort(images.begin(), images.end(),
            [](const colmap::Image& a, const colmap::Image& b) {
              return a.ImageId() < b.ImageId();
            });
  const auto poses = LoadPoses(poses_path);
  std::printf("SOURCE n_images=%zu n_poses=%zu\n", images.size(), poses.size());
  std::fflush(stdout);

  // [C2 ORDER A/B 2026-08-06] BENCH-ONLY feed-order knob (product core
  // untouched). OFFICIAL_AETHER_REPLAY_ORDER=latest_first_sim simulates the
  // planned capture-time backpressure (worker latest-wins, shelved frames
  // backfilled after capture ends): with the worker STRIDE× slower than the
  // shutter, the worker sees every STRIDE-th frame during capture
  // (0, S, 2S, ...) and the skipped frames are fed afterwards in ascending
  // order. Env unset reproduces the prior strictly-sequential bench feed
  // byte-for-byte (the vector is left untouched).
  const char* order_env = std::getenv("OFFICIAL_AETHER_REPLAY_ORDER");
  const std::string order = order_env ? order_env : "";
  if (order == "latest_first_sim") {
    const char* stride_env =
        std::getenv("OFFICIAL_AETHER_REPLAY_ORDER_STRIDE");
    int stride = stride_env ? std::atoi(stride_env) : 4;
    if (stride < 2) stride = 2;
    std::vector<colmap::Image> reordered;
    reordered.reserve(images.size());
    for (size_t i = 0; i < images.size(); i += stride)
      reordered.push_back(images[i]);  // live pass: worker keeps up 1-in-S
    for (size_t i = 0; i < images.size(); ++i)
      if (i % stride != 0) reordered.push_back(images[i]);  // backfill pass
    images = std::move(reordered);
    std::printf("REPLAY_ORDER latest_first_sim stride=%d (live=%zu backfill=%zu)\n",
                stride, (images.size() + stride - 1) / stride,
                images.size() - (images.size() + stride - 1) / stride);
    std::fflush(stdout);
  } else if (!order.empty()) {
    std::fprintf(stderr, "unknown OFFICIAL_AETHER_REPLAY_ORDER=%s\n",
                 order.c_str());
    return 1;
  }

  // ── streaming session ──
  aether_sfm_options_t opt;
  aether_sfm_options_default(&opt);
#if defined(AETHER_REPLAY_LINK_REAL_GPU_MATCH)
  // [TAIL-CACHE HOST 2026-08-02] real Metal matcher TU linked on host; the
  // tail-cache arms only require the matcher be identical across arms, and
  // the GPU path is both ~50x faster and closer to production semantics.
  opt.use_gpu_match = 1;
#else
  opt.use_gpu_match = 0;   // host: CPU brute-force (weak GPU symbol is null)
#endif
  opt.use_gpu_extract = 0;
  opt.k_neighbors = k;     // production capture uses 12 (spatial-first)
  opt.match_max_ratio = (float)ratio;  // A/B: temporal-path Lowe ratio
  const std::string sess_db = out_dir + "/session.db";
  std::remove(sess_db.c_str());
  aether_sfm_session_t* s = nullptr;
  aether_sfm_result_t rc = aether_sfm_create(sess_db.c_str(), &opt, &s);
  if (rc != AETHER_SFM_OK || !s) {
    std::fprintf(stderr, "aether_sfm_create failed: %s\n",
                 aether_sfm_result_str(rc));
    return 2;
  }

  int fed = 0, missing_pose = 0;
  bool tail_fault_done = false;
  // [AR-DISPLAY PROBE 2026-08-04] Per-frame previewTracked probe (see the probe
  // block inside the loop). Off unless OFFICIAL_AETHER_PREVIEW_PROBE=1.
  const char* preview_probe_env = std::getenv("OFFICIAL_AETHER_PREVIEW_PROBE");
  const bool preview_probe = preview_probe_env && preview_probe_env[0] == '1';
  FILE* preview_probe_fp = nullptr;
  if (preview_probe) {
    const std::string probe_path = out_dir + "/preview_probe.jsonl";
    preview_probe_fp = std::fopen(probe_path.c_str(), "w");
    if (!preview_probe_fp) {
      std::fprintf(stderr, "preview probe: cannot open %s\n",
                   probe_path.c_str());
      return 2;
    }
  }
  const double t_stream0 = NowMs();
  for (const colmap::Image& img : images) {
    const colmap::image_t image_id = img.ImageId();
    const int frame_id = static_cast<int>(image_id) - 1;  // ABI: frame_id = id-1
    const colmap::FeatureKeypoints kps = db->ReadKeypoints(image_id);
    const colmap::FeatureDescriptors desc = db->ReadDescriptors(image_id);
    const int n = static_cast<int>(kps.size());
    if (n == 0 || desc.data.rows() != n || desc.data.cols() != 128) {
      std::fprintf(stderr, "frame %d: bad kp/desc (n=%d rows=%ld cols=%ld)\n",
                   frame_id, n, (long)desc.data.rows(), (long)desc.data.cols());
      continue;
    }
    const colmap::Camera cam = db->ReadCamera(img.CameraId());
    const float fx = static_cast<float>(cam.FocalLengthX());
    const float fy = static_cast<float>(cam.FocalLengthY());
    const float cx = static_cast<float>(cam.PrincipalPointX());
    const float cy = static_cast<float>(cam.PrincipalPointY());
    const int w = static_cast<int>(cam.width);
    const int h = static_cast<int>(cam.height);

    std::vector<float> xy(static_cast<size_t>(n) * 2);
    for (int i = 0; i < n; ++i) {
      xy[2 * i] = kps[i].x;
      xy[2 * i + 1] = kps[i].y;
    }

    auto it = poses.find(frame_id);
    const double* q = nullptr;
    const double* t = nullptr;
    if (it != poses.end() && it->second.ok) {
      q = it->second.q.data();
      t = it->second.t.data();
    } else {
      ++missing_pose;  // add_frame_features accepts NULL pose (falls to no-prior)
    }

    int out_fid = -1;
    rc = aether_sfm_add_frame_features(s, xy.data(), desc.data.data(), n, w, h,
                                       fx, fy, cx, cy, q, t, &out_fid);
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "add_frame_features frame %d failed: %s\n", frame_id,
                   aether_sfm_result_str(rc));
      continue;
    }
    ++fed;
    // [IDLE-REPAY SIM 2026-08-08] BENCH-ONLY. The device gets real idle gaps
    // between shutter presses, so aether_sfm_live_repay actually runs there and
    // drains the probe-debt ledger DURING capture. This bench feeds frames
    // back-to-back, so that leg never fired and every host run reported
    // probe_debt_repaid_live == 0 — i.e. the host measured the WORST case for
    // the live cloud. This hook simulates the device's inter-shutter idle so the
    // repay path can be exercised and measured on host.
    // Env: AETHER_REPLAY_LIVE_REPAY=<max_pairs per frame>, unset/0 == the prior
    // strictly-back-to-back feed (bit-identical). Pair it with
    // OFFICIAL_AETHER_IDLE_PREPAY_IDLE_MS=0 so the frame-idle gate passes.
    {
      static const int kReplayRepayPairs = [] {
        if (const char* e = std::getenv("AETHER_REPLAY_LIVE_REPAY")) {
          const int v = std::atoi(e);
          if (v > 0) return v;
        }
        return 0;
      }();
      if (kReplayRepayPairs > 0) {
        (void)aether_sfm_live_repay(s, kReplayRepayPairs);
      }
    }
    // [E1/AR-DISPLAY PROBE 2026-08-04] Per-frame previewTracked probe. Proves
    // the premise of the "push previewTracked every frame, skip globalRefine"
    // display rework: that the live local-BA cloud (get_preview_tracked reads
    // live_recon.Points3D() directly) exists and grows every accepted frame,
    // with NO globalRefine() called (this bench never calls it). Off unless
    // OFFICIAL_AETHER_PREVIEW_PROBE=1; when off this block is skipped entirely,
    // so an unset env reproduces the prior bench behaviour exactly.
    if (preview_probe) {
      aether_sfm_point_t* ppts = nullptr;
      int32_t* poffs = nullptr;
      aether_sfm_track_obs_t* pobs = nullptr;
      int pcount = 0;
      int64_t pobs_count = 0;
      const aether_sfm_result_t prc = aether_sfm_get_preview_tracked(
          s, &ppts, &pcount, &poffs, &pobs, &pobs_count);
      // NOT_REGISTERED before the first successful two-view is expected, not an
      // error — the cloud simply does not exist yet. Log it as count 0.
      std::fprintf(preview_probe_fp,
                   "{\"fid\":%d,\"fed\":%d,\"preview_count\":%d,"
                   "\"preview_obs\":%lld,\"rc\":\"%s\"}\n",
                   frame_id, fed, (prc == AETHER_SFM_OK ? pcount : 0),
                   static_cast<long long>(prc == AETHER_SFM_OK ? pobs_count : 0),
                   aether_sfm_result_str(prc));
      if (prc == AETHER_SFM_OK) aether_sfm_points_free(ppts);
      std::free(poffs);
      std::free(pobs);
    }
    if (!tail_fault_done && tail_fault_after_frame >= 0 &&
        frame_id == tail_fault_after_frame) {
      if (remove_fault) {
        char remove_json[512] = {0};
        const aether_sfm_result_t remove_rc = aether_sfm_remove_frame(
            s, tail_fault_remove_frame, remove_json, sizeof(remove_json));
        if (remove_rc != AETHER_SFM_OK) {
          std::fprintf(stderr,
                       "TAIL_FAULT_REMOVE_FAILED remove=%d after=%d rc=%s\n",
                       tail_fault_remove_frame, tail_fault_after_frame,
                       aether_sfm_result_str(remove_rc));
          aether_sfm_free(s);
          return 5;
        }
        std::printf("TAIL_FAULT_REMOVE_OK remove=%d after=%d result=%s\n",
                    tail_fault_remove_frame, tail_fault_after_frame,
                    remove_json);
      } else {
#if defined(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)
        int kind = 0;
        if (tail_fault_kind == "pair_overwrite") kind = 1;
        if (tail_fault_kind == "late_pair") kind = 2;
        if (tail_fault_kind == "model_replacement") kind = 3;
        if (tail_fault_kind == "exception_retry") kind = 4;
        const int inject_rc =
            kind == 0 ? -9 : aether_sfm_test_tail_cache_inject_v1(s, kind);
        if (inject_rc != 0) {
          std::fprintf(stderr,
                       "TAIL_FAULT_INJECT_FAILED kind=%s after=%d rc=%d\n",
                       tail_fault_kind.c_str(), tail_fault_after_frame,
                       inject_rc);
          aether_sfm_free(s);
          return 5;
        }
        std::printf("TAIL_FAULT_INJECT_OK kind=%s after=%d\n",
                    tail_fault_kind.c_str(), tail_fault_after_frame);
#endif
      }
      tail_fault_done = true;
      std::fflush(stdout);
    }
    if (max_frames > 0 && fed >= max_frames) break;
    if (fed % 25 == 0) {
      std::printf("  fed %d/%zu frames (last n_kp=%d)\n", fed, images.size(), n);
      std::fflush(stdout);
    }
  }
  const double stream_ms = NowMs() - t_stream0;
  if (preview_probe_fp) {
    std::fclose(preview_probe_fp);
    preview_probe_fp = nullptr;
    std::printf("PREVIEW_PROBE written %s/preview_probe.jsonl\n",
                out_dir.c_str());
  }
  if (tail_fault_after_frame >= 0 && !tail_fault_done) {
    std::fprintf(stderr,
                 "TAIL_FAULT_NOT_TRIGGERED kind=%s remove=%d after=%d fed=%d\n",
                 tail_fault_kind.c_str(), tail_fault_remove_frame,
                 tail_fault_after_frame, fed);
    aether_sfm_free(s);
    return 6;
  }
  std::printf("STREAMED fed=%d missing_pose=%d stream_ms=%.1f\n", fed,
              missing_pose, stream_ms);
  std::fflush(stdout);

  // ── finalize (async live_reuse path = shipping finalize) ──
  char fj[512] = {0};
  const double t_fin0 = NowMs();
  rc = aether_sfm_finalize_async(s, fj, sizeof(fj));
  if (rc != AETHER_SFM_OK) {
    std::fprintf(stderr, "finalize_async failed: %s\n",
                 aether_sfm_result_str(rc));
    aether_sfm_free(s);
    return 3;
  }
  std::printf("FINALIZE_ASYNC phase1=%s\n", fj);
  std::fflush(stdout);

  // Poll to REFINED (2) or ERROR (3).
  int status = aether_sfm_finalize_status(s);
  while (status != 2 && status != 3) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    status = aether_sfm_finalize_status(s);
  }
  const double finalize_ms = NowMs() - t_fin0;
  if (status == 3) {
    std::fprintf(stderr, "finalize refine ERROR\n");
    aether_sfm_free(s);
    return 4;
  }
  std::printf("REFINED finalize_ms=%.1f\n", finalize_ms);
  std::fflush(stdout);

  // ── outputs: diag + poses + points ──
  double reproj = -1;
  int64_t npts = 0, ntrack3 = 0, nobs = 0;
  aether_sfm_final_diag(s, &reproj, &npts, &ntrack3, &nobs);

  std::vector<aether_sfm_pose_t> poses_out(images.size());
  int n_pose = 0;
  aether_sfm_get_poses(s, poses_out.data(), (int)poses_out.size(), &n_pose);
  int n_reg = 0;
  for (int i = 0; i < n_pose; ++i)
    if (poses_out[i].registered) ++n_reg;

  aether_sfm_point_t* pts = nullptr;
  int n_pts = 0;
  aether_sfm_get_points(s, &pts, &n_pts);
  WritePly(out_dir + "/cloud.ply", pts, n_pts);
  aether_sfm_points_free(pts);

  aether_sfm_debug_dump_model(s, out_dir.c_str());

  std::printf(
      "RESULT incr=%s n_reg=%d n_points=%lld track3plus=%lld n_obs=%lld "
      "mean_reproj_px=%.4f stream_ms=%.1f finalize_ms=%.1f total_ms=%.1f\n",
      incr ? incr : "off", n_reg, (long long)npts, (long long)ntrack3,
      (long long)nobs, reproj, stream_ms, finalize_ms, stream_ms + finalize_ms);
  std::fflush(stdout);

  aether_sfm_free(s);
  return 0;
}
