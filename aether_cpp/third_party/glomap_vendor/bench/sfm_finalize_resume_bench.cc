// [FLOATER-VERIFY 2026-08-06] Finalize-only resume bench: run the product
// core's crash-resume finalize path over a REAL device capture db (with its
// .arkit_pose_v1 sidecar), skipping the streaming feed/re-match entirely.
// This consumes the device's actual on-capture match graph — the closest host
// reproduction of the "real surgery" — unlike sfm_replay_bench.cc which
// re-matches every pair and diverges ~20% in point count.
//
// usage: sfm_finalize_resume_bench_exe <session_db> <out_dir>
//   <session_db> must sit next to <session_db>.arkit_pose_v1 and be a
//   WRITABLE COPY (finalize enrichment writes into it).
//   Dumps: <out_dir>/cloud.ply + COLMAP bin model (points3D 含 track,供
//   离线计算每点视差角). Filter via OFFICIAL_AETHER_DELIVER_MIN_TRI_ANGLE env.
#include "aether_sfm_c.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>

// ─── host GPU-symbol stubs(逐字取自 sfm_replay_bench.cc,理由同)────
extern "C" int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int,
                                           float*, uint8_t*, int, int*) {
  return -1;  // GPU extractor unavailable → CPU fallback
}
// [SCALE-PERSIST 2026-08-06] _v2 sibling, same no-op host stub rationale.
extern "C" int aether_dsp_sift_extract_gpu_v2(const uint8_t*, int, int, int,
                                              int, float*, uint8_t*, float*,
                                              float*, int, int*) {
  return -1;  // unavailable → add_frame stays on the CPU _v2 route
}
extern "C" void aether_sed_last_stages(double*, int) {}

static void WritePly(const std::string& path, const aether_sfm_point_t* pts,
                     int n) {
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

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <session_db> <out_dir>\n", argv[0]);
    return 1;
  }
  const std::string db = argv[1];
  const std::string out_dir = argv[2];

  aether_sfm_options_t opt;
  aether_sfm_options_default(&opt);
  // Finalize-resume only consumes the db; extractor/matcher options matter
  // only for the finish-time enrichment re-match (GPU on host, same as
  // replay bench).
  opt.use_gpu_match = 1;

  aether_sfm_session_t* s = nullptr;
  aether_sfm_result_t rc = aether_sfm_create(db.c_str(), &opt, &s);
  if (rc != AETHER_SFM_OK || !s) {
    std::fprintf(stderr, "aether_sfm_create failed: %d\n", (int)rc);
    return 2;
  }

  char json[8192] = {0};
  rc = aether_sfm_finalize_async(s, json, sizeof(json));
  if (rc != AETHER_SFM_OK) {
    std::fprintf(stderr, "finalize_async failed: %d (%s)\n", (int)rc, json);
    return 3;
  }
  std::printf("phase1: %s\n", json);

  const auto t0 = std::chrono::steady_clock::now();
  for (;;) {
    const int st = aether_sfm_finalize_status(s);
    if (st == AETHER_SFM_FINALIZE_REFINED) break;
    if (st == AETHER_SFM_FINALIZE_ERROR) {
      std::fprintf(stderr, "finalize worker ERROR\n");
      return 4;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
  const double secs =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - t0)
          .count();

  aether_sfm_point_t* pts = nullptr;
  int n = 0;
  rc = aether_sfm_get_points(s, &pts, &n);
  if (rc != AETHER_SFM_OK) {
    std::fprintf(stderr, "get_points failed: %d\n", (int)rc);
    return 5;
  }
  WritePly(out_dir + "/cloud.ply", pts, n);
  aether_sfm_points_free(pts);
  aether_sfm_debug_dump_model(s, out_dir.c_str());
  std::printf("RESUME_FINALIZE_RESULT n_points_delivered=%d finalize_s=%.1f\n",
              n, secs);
  aether_sfm_free(s);
  return 0;
}
