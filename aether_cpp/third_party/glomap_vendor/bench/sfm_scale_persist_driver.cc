// sfm_scale_persist_driver.cc — [SCALE-PERSIST 2026-08-06] host verification
// driver for the DSP-SIFT keypoint-scale persistence campaign.
//
// Feeds REAL device-captured photos (PIL-decoded grayscale raws, CGImage
// row-major top-down convention) through the PRODUCTION streaming entry
// aether_sfm_add_frame (CPU DSP-SIFT extraction inside the core), with the
// REAL ARKit poses + per-frame intrinsics of the same capture (read from the
// pulled official_sfm_live.db + official_sfm_fed_frames.jsonl). The produced
// session.db keypoints table is then inspected off-line (sqlite) for the
// written affine columns: unit affine (pre-change) vs true detection scale
// (post-change).
//
// --inject-from=<db>: replay arm — instead of extracting, reads keypoints
// (xy only) + descriptors back from a previously produced session.db and
// feeds them through aether_sfm_add_frame_features (the injection ABI, which
// persists UNIT affine by contract). Used for the scale-vs-unit A/B on
// byte-identical features.
//
// usage: sfm_scale_persist_driver_exe <fed_frames.jsonl> <gray_dir>
//            <src_live_db> <out_dir> [--max-frames=10] [--inject-from=<db>]

#include "aether_sfm_c.h"

#include "colmap/feature/types.h"
#include "colmap/scene/camera.h"
#include "colmap/scene/database.h"
#include "colmap/scene/image.h"

#include <glog/logging.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

// ─── host GPU-symbol stubs(逐字取自 sfm_replay_bench.cc,理由同)────
extern "C" int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int,
                                           float*, uint8_t*, int, int*) {
  return -1;  // GPU extractor unavailable → add_frame falls back to CPU
}
// [SCALE-PERSIST 2026-08-06] _v2 sibling, same no-op host stub rationale.
extern "C" int aether_dsp_sift_extract_gpu_v2(const uint8_t*, int, int, int,
                                              int, float*, uint8_t*, float*,
                                              float*, int, int*) {
  return -1;  // unavailable → add_frame stays on the CPU _v2 route
}
extern "C" void aether_sed_last_stages(double*, int) {}

namespace {

std::string ArgS(int argc, char** argv, const char* key, const char* def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i)
    if (std::strncmp(argv[i], key, kl) == 0) {
      const char* eq = std::strchr(argv[i], '=');
      if (eq) return std::string(eq + 1);
    }
  return std::string(def);
}

// minimal jsonl frame parser (same format as sfm_replay_bench.cc, plus the
// jpegPath basename + gray dims the extraction arm needs).
struct FedFrame {
  int frame_id = -1;
  std::string jpeg_basename;
  int gray_w = 0, gray_h = 0;
  bool pose_ok = false;
  std::array<double, 4> q{1, 0, 0, 0};
  std::array<double, 3> t{0, 0, 0};
};

bool ParseArray(const std::string& line, const char* key, double* out, int n) {
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

bool ParseInt(const std::string& line, const char* key, int* out) {
  const size_t k = line.find(key);
  if (k == std::string::npos) return false;
  *out = std::atoi(line.c_str() + k + std::strlen(key));
  return true;
}

std::vector<FedFrame> LoadFedFrames(const std::string& path) {
  std::vector<FedFrame> frames;
  std::ifstream in(path);
  std::string line;
  while (std::getline(in, line)) {
    FedFrame f;
    if (!ParseInt(line, "\"frameId\":", &f.frame_id)) continue;
    ParseInt(line, "\"grayW\":", &f.gray_w);
    ParseInt(line, "\"grayH\":", &f.gray_h);
    const size_t jp = line.find("\"jpegPath\":\"");
    if (jp != std::string::npos) {
      const size_t v0 = jp + std::strlen("\"jpegPath\":\"");
      const size_t v1 = line.find('"', v0);
      if (v1 != std::string::npos) {
        const std::string full = line.substr(v0, v1 - v0);
        const size_t slash = full.find_last_of('/');
        f.jpeg_basename =
            slash == std::string::npos ? full : full.substr(slash + 1);
      }
    }
    const bool okq =
        ParseArray(line, "\"arkitCamFromWorldQwxyz\":", f.q.data(), 4);
    const bool okt =
        ParseArray(line, "\"arkitCamFromWorldTxyz\":", f.t.data(), 3);
    f.pose_ok = okq && okt;
    frames.push_back(std::move(f));
  }
  return frames;
}

}  // namespace

int main(int argc, char** argv) {
  google::InitGoogleLogging(argv[0]);
  FLAGS_logtostderr = 1;
  if (argc < 5) {
    std::fprintf(stderr,
                 "usage: %s <fed_frames.jsonl> <gray_dir> <src_live_db> "
                 "<out_dir> [--max-frames=10] [--inject-from=<db>]\n",
                 argv[0]);
    return 1;
  }
  const std::string jsonl = argv[1];
  const std::string gray_dir = argv[2];
  const std::string src_db_path = argv[3];
  const std::string out_dir = argv[4];
  const int max_frames =
      std::atoi(ArgS(argc, argv, "--max-frames", "10").c_str());
  const std::string inject_from = ArgS(argc, argv, "--inject-from", "");

  const std::vector<FedFrame> frames = LoadFedFrames(jsonl);
  std::printf("SCALE_PERSIST frames_in_jsonl=%zu max_frames=%d mode=%s\n",
              frames.size(), max_frames,
              inject_from.empty() ? "extract" : "inject");
  std::fflush(stdout);

  // src db: per-frame PINHOLE intrinsics of the real capture (camera row per
  // image; image_id = frame_id + 1 by the streaming ABI).
  auto src_db = colmap::Database::Open(src_db_path);
  std::shared_ptr<colmap::Database> inj_db;
  if (!inject_from.empty()) inj_db = colmap::Database::Open(inject_from);

  aether_sfm_options_t opt;
  aether_sfm_options_default(&opt);
  opt.use_gpu_extract = 0;  // host: CPU DSP-SIFT (production fallback path)
  // [SCALE-KNIFE 2026-08-07] AETHER_SCALE_DRIVER_GPU_MATCH=1 routes matching
  // through the real host Metal GPU matcher (this exe already links it via
  // AETHER_REPLAY_LINK_REAL_GPU_MATCH — production shipping matcher, mutual
  // crosscheck, bit-identical parity 15/15). Default stays 0 (CPU brute-force,
  // the original deterministic A/B arm). Needed because a 201-frame 8192-kp
  // full replay is ~8 h on the CPU matcher.
  const char* gm = std::getenv("AETHER_SCALE_DRIVER_GPU_MATCH");
  opt.use_gpu_match = (gm && gm[0] == '1') ? 1 : 0;
  opt.k_neighbors = 12;     // production capture value (spatial-first)
  opt.max_features = 8192;  // production capture value (device db rows=8192)

  const std::string sess_db = out_dir + "/session.db";
  std::remove(sess_db.c_str());
  aether_sfm_session_t* s = nullptr;
  aether_sfm_result_t rc = aether_sfm_create(sess_db.c_str(), &opt, &s);
  if (rc != AETHER_SFM_OK || !s) {
    std::fprintf(stderr, "aether_sfm_create failed: %s\n",
                 aether_sfm_result_str(rc));
    return 2;
  }

  int fed = 0;
  for (const FedFrame& f : frames) {
    if (fed >= max_frames) break;
    if (!f.pose_ok) {
      std::fprintf(stderr, "frame %d: missing pose — skipped\n", f.frame_id);
      continue;
    }
    const colmap::image_t image_id =
        static_cast<colmap::image_t>(f.frame_id + 1);
    const colmap::Image img = src_db->ReadImage(image_id);
    const colmap::Camera cam = src_db->ReadCamera(img.CameraId());
    const float fx = static_cast<float>(cam.FocalLengthX());
    const float fy = static_cast<float>(cam.FocalLengthY());
    const float cx = static_cast<float>(cam.PrincipalPointX());
    const float cy = static_cast<float>(cam.PrincipalPointY());

    int out_fid = -1;
    if (inject_from.empty()) {
      // extraction arm: PIL grayscale raw, row-major top-down (CGImage order)
      const std::string gray_path = gray_dir + "/" + f.jpeg_basename + ".gray";
      std::ifstream gin(gray_path, std::ios::binary);
      if (!gin) {
        std::fprintf(stderr, "frame %d: missing gray raw %s\n", f.frame_id,
                     gray_path.c_str());
        aether_sfm_free(s);
        return 3;
      }
      std::vector<uint8_t> gray(static_cast<size_t>(f.gray_w) * f.gray_h);
      gin.read(reinterpret_cast<char*>(gray.data()),
               static_cast<std::streamsize>(gray.size()));
      if (gin.gcount() != static_cast<std::streamsize>(gray.size())) {
        std::fprintf(stderr, "frame %d: short gray raw %s\n", f.frame_id,
                     gray_path.c_str());
        aether_sfm_free(s);
        return 3;
      }
      rc = aether_sfm_add_frame(s, gray.data(), f.gray_w, f.gray_h, fx, fy,
                                cx, cy, f.q.data(), f.t.data(), &out_fid);
    } else {
      // injection arm: byte-identical features back through the injection ABI
      const colmap::FeatureKeypoints kps = inj_db->ReadKeypoints(image_id);
      const colmap::FeatureDescriptors desc = inj_db->ReadDescriptors(image_id);
      const int n = static_cast<int>(kps.size());
      if (n == 0 || desc.data.rows() != n || desc.data.cols() != 128) {
        std::fprintf(stderr, "frame %d: bad kp/desc in inject db\n",
                     f.frame_id);
        aether_sfm_free(s);
        return 3;
      }
      std::vector<float> xy(static_cast<size_t>(n) * 2);
      for (int i = 0; i < n; ++i) {
        xy[2 * i] = kps[i].x;
        xy[2 * i + 1] = kps[i].y;
      }
      rc = aether_sfm_add_frame_features(s, xy.data(), desc.data.data(), n,
                                         f.gray_w, f.gray_h, fx, fy, cx, cy,
                                         f.q.data(), f.t.data(), &out_fid);
    }
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "frame %d: add failed: %s\n", f.frame_id,
                   aether_sfm_result_str(rc));
      aether_sfm_free(s);
      return 4;
    }
    ++fed;
    std::printf("  fed frame %d (out_fid=%d)\n", f.frame_id, out_fid);
    std::fflush(stdout);
  }

  std::printf("SCALE_PERSIST_DONE fed=%d db=%s\n", fed, sess_db.c_str());
  aether_sfm_free(s);
  return 0;
}
