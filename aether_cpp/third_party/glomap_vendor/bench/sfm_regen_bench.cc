// sfm_regen_bench.cc — [B1 DB 全配方化 2026-08-10] HOST-ONLY driver that
// rebuilds a streaming-SfM db FROM IMAGES through the exact production ABI:
//     aether_sfm_create → aether_sfm_add_frame × N → aether_sfm_finalize_async
// (CPU extract + CPU match on host; the on-device recipe uses the same entry
// points with device GPU flags). Purpose:
//   V4 determinism — run twice with identical inputs, diff sfm_live.db bytes;
//   V5 quality     — run the orig-JPEG arm vs the PWVA-decoded arm, compare
//                    finalize clouds (n_registered / n_points3d / reproj_px).
//
// Image decode mirrors pwofficial_jpeg_decode.mm's DecodeOfficialJpegGray
// (ImageIO → DeviceGray, kCGInterpolationNone, no crop/resize/flip) minus the
// 4032x3024 gate so host 4K test frames pass. PNG input decodes through the
// same ImageIO path.
//
// usage: sfm_regen_bench_exe <meta.txt> <out_dir> [--k=12] [--max-frames=0]
// meta.txt per line (whitespace):
//   <image_path> <fx> <fy> <cx> <cy> <qw> <qx> <qy> <qz> <tx> <ty> <tz>
// (pose = world->cam prior, production convention as fed by the app)

#include "aether_sfm_c.h"

#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// ─── host GPU-symbol stubs (same rationale as sfm_replay_bench.cc) ──
extern "C" int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int,
                                           float*, uint8_t*, int, int*) {
  return -1;
}
extern "C" int aether_dsp_sift_extract_gpu_v2(const uint8_t*, int, int, int,
                                              int, float*, uint8_t*, float*,
                                              float*, int, int*) {
  return -1;
}
extern "C" void aether_gpu_match_set_preview_fps30(int) {}
extern "C" const char* aether_sed_last_fail_reason(void) { return nullptr; }
#if !defined(AETHER_REPLAY_LINK_REAL_GPU_MATCH)
extern "C" int aether_gpu_match_gemm_pairs(const uint8_t*, int, const uint8_t*,
                                           int, double, uint32_t*, int, int*) {
  return 2;
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
    uint64_t, uint64_t*, uint64_t*, uint64_t*, uint64_t*, uint64_t*, uint64_t*,
    uint64_t*, uint64_t*, uint64_t*) {
  return 0;
}
extern "C" int aether_gpu_match_last_error(char*, int) { return 0; }
#endif  // !AETHER_REPLAY_LINK_REAL_GPU_MATCH
extern "C" void aether_sed_last_stages(double*, int) {}

namespace {

struct FrameMeta {
  std::string path;
  float fx, fy, cx, cy;
  double q[4];
  double t[3];
};

bool DecodeGray(const char* path, std::vector<uint8_t>* gray, int* w, int* h) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(path),
      static_cast<CFIndex>(std::strlen(path)), false);
  if (!url) return false;
  CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
  CFRelease(url);
  if (!source) return false;
  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  CFRelease(source);
  if (!image) return false;
  const size_t width = CGImageGetWidth(image);
  const size_t height = CGImageGetHeight(image);
  gray->assign(width * height, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
  CGContextRef ctx = CGBitmapContextCreate(gray->data(), width, height, 8,
                                           width, cs, kCGImageAlphaNone);
  CGColorSpaceRelease(cs);
  if (!ctx) {
    CGImageRelease(image);
    return false;
  }
  CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
  CGContextDrawImage(ctx,
                     CGRectMake(0, 0, static_cast<CGFloat>(width),
                                static_cast<CGFloat>(height)),
                     image);
  CGContextRelease(ctx);
  CGImageRelease(image);
  *w = static_cast<int>(width);
  *h = static_cast<int>(height);
  return true;
}

std::string ArgS(int argc, char** argv, const char* key, const char* def) {
  const size_t kl = std::strlen(key);
  for (int i = 1; i < argc; ++i) {
    if (std::strncmp(argv[i], key, kl) == 0 && argv[i][kl] == '=') {
      return std::string(argv[i] + kl + 1);
    }
  }
  return def;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <meta.txt> <out_dir> [--k=12] [--max-frames=0]\n",
                 argv[0]);
    return 1;
  }
  const std::string meta_path = argv[1];
  const std::string out_dir = argv[2];
  const int k = std::atoi(ArgS(argc, argv, "--k", "12").c_str());
  const int max_frames = std::atoi(ArgS(argc, argv, "--max-frames", "0").c_str());
  // 生产 Dart create() 显式 matchMaxRatio=0.8;--ratio<0 = 保持 options 默认。
  const double ratio = std::atof(ArgS(argc, argv, "--ratio", "-1").c_str());
  // --resume-db=<path>:跳过喂帧,把既有 db 复制进 out_dir 后直接 finalize
  // (=产品"重新重建"路径;meta 仍需提供帧路径供真彩取色)。
  const std::string resume_db = ArgS(argc, argv, "--resume-db", "");

  std::vector<FrameMeta> frames;
  {
    std::ifstream in(meta_path);
    if (!in) {
      std::fprintf(stderr, "cannot open %s\n", meta_path.c_str());
      return 1;
    }
    std::string line;
    while (std::getline(in, line)) {
      if (line.empty()) continue;
      std::istringstream ss(line);
      FrameMeta m;
      ss >> m.path >> m.fx >> m.fy >> m.cx >> m.cy >> m.q[0] >> m.q[1] >>
          m.q[2] >> m.q[3] >> m.t[0] >> m.t[1] >> m.t[2];
      if (ss.fail()) {
        std::fprintf(stderr, "bad meta line: %s\n", line.c_str());
        return 1;
      }
      frames.push_back(m);
      if (max_frames > 0 && static_cast<int>(frames.size()) >= max_frames) break;
    }
  }
  std::printf("REGEN meta=%s out=%s frames=%zu k=%d ratio=%.2f\n", meta_path.c_str(),
              out_dir.c_str(), frames.size(), k, ratio > 0 ? ratio : -1.0);
  std::fflush(stdout);

  aether_sfm_options_t opt;
  aether_sfm_options_default(&opt);
  opt.use_gpu_match = 0;
  opt.use_gpu_extract = 0;
  opt.k_neighbors = k;
  if (ratio > 0) opt.match_max_ratio = (float)ratio;
  if (!resume_db.empty() && !frames.empty()) {
    // resume 不喂帧,会话尺寸取自 meta(Dart create 同款显式设置)。
    std::vector<uint8_t> probe;
    int pw = 0, ph = 0;
    if (DecodeGray(frames[0].path.c_str(), &probe, &pw, &ph)) {
      opt.image_width = pw;
      opt.image_height = ph;
    }
  }

  const std::string sess_db = out_dir + "/sfm_live.db";
  std::remove(sess_db.c_str());
  if (!resume_db.empty()) {
    // db + .arkit_pose_v1 侧车(RebuildFrameRecordsForResume 的身份链)。
    for (const char* suffix : {"", ".arkit_pose_v1"}) {
      std::ifstream in(resume_db + suffix, std::ios::binary);
      std::ofstream out(sess_db + suffix, std::ios::binary);
      if (!in || !out) {
        std::fprintf(stderr, "resume-db copy failed (%s)\n", suffix);
        return 1;
      }
      out << in.rdbuf();
    }
  }
  aether_sfm_session_t* s = nullptr;
  aether_sfm_result_t rc = aether_sfm_create(sess_db.c_str(), &opt, &s);
  if (rc != AETHER_SFM_OK) {
    std::fprintf(stderr, "aether_sfm_create failed: %d\n", rc);
    return 1;
  }

  const auto t0 = std::chrono::steady_clock::now();
  int fed = 0;
  if (!resume_db.empty()) goto finalize_now;
  for (const auto& m : frames) {
    std::vector<uint8_t> gray;
    int w = 0, h = 0;
    if (!DecodeGray(m.path.c_str(), &gray, &w, &h)) {
      std::fprintf(stderr, "decode failed: %s\n", m.path.c_str());
      return 1;
    }
    int frame_id = -1;
    rc = aether_sfm_add_frame(s, gray.data(), w, h, m.fx, m.fy, m.cx, m.cy,
                              m.q, m.t, &frame_id);
    if (rc != AETHER_SFM_OK) {
      std::fprintf(stderr, "add_frame %d failed: %d (%s)\n", fed, rc,
                   m.path.c_str());
      return 1;
    }
    fed++;
    if (fed % 16 == 0) {
      std::printf("FED %d/%zu\n", fed, frames.size());
      std::fflush(stdout);
    }
  }
finalize_now:;
  const auto t1 = std::chrono::steady_clock::now();

  char fj[1024] = {0};
  {
  rc = aether_sfm_finalize_async(s, fj, sizeof(fj));
  if (rc != AETHER_SFM_OK) {
    std::fprintf(stderr, "finalize_async failed: %d\n", rc);
    return 1;
  }
  int status = aether_sfm_finalize_status(s);
  while (status != AETHER_SFM_FINALIZE_REFINED &&
         status != AETHER_SFM_FINALIZE_ERROR) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    status = aether_sfm_finalize_status(s);
  }
  if (status == AETHER_SFM_FINALIZE_ERROR) {
    std::fprintf(stderr, "finalize refinement failed\n");
    return 1;
  }
  }
  const auto t2 = std::chrono::steady_clock::now();

  // 真彩:track 首观测采样源图 RGB(COLMAP extract_colors 同款语义——
  // 观测即可见性证明,遮挡安全)。
  aether_sfm_point_t* points = nullptr;
  int n_points = 0;
  int32_t* obs_offsets = nullptr;
  aether_sfm_track_obs_t* obs = nullptr;
  int64_t obs_count = 0;
  if (aether_sfm_get_points_tracked(s, &points, &n_points, &obs_offsets,
                                    &obs, &obs_count) != AETHER_SFM_OK) {
    aether_sfm_get_points(s, &points, &n_points);
  } else {
    // 按帧分组首观测,逐帧解码 RGB 采样。
    std::vector<std::vector<int>> byFrame(frames.size());
    std::vector<std::pair<float, float>> firstXY(n_points, {-1.f, -1.f});
    std::vector<int> firstFrame(n_points, -1);
    for (int i = 0; i < n_points; ++i) {
      if (obs_offsets[i] < obs_offsets[i + 1]) {
        const auto& o = obs[obs_offsets[i]];
        if (o.frame_id >= 0 && o.frame_id < (int)frames.size()) {
          firstFrame[i] = o.frame_id;
          firstXY[i] = {o.x, o.y};
          byFrame[o.frame_id].push_back(i);
        }
      }
    }
    for (size_t f = 0; f < frames.size(); ++f) {
      if (byFrame[f].empty()) continue;
      CFURLRef url = CFURLCreateFromFileSystemRepresentation(
          kCFAllocatorDefault, (const UInt8*)frames[f].path.c_str(),
          (CFIndex)frames[f].path.size(), false);
      CGImageSourceRef src2 = url ? CGImageSourceCreateWithURL(url, nullptr) : nullptr;
      if (url) CFRelease(url);
      CGImageRef img = src2 ? CGImageSourceCreateImageAtIndex(src2, 0, nullptr) : nullptr;
      if (src2) CFRelease(src2);
      if (!img) continue;
      const size_t iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
      std::vector<uint8_t> rgba(iw * ih * 4);
      CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
      CGContextRef ctx2 = CGBitmapContextCreate(rgba.data(), iw, ih, 8, iw * 4,
          cs2, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
      CGColorSpaceRelease(cs2);
      if (ctx2) {
        CGContextSetInterpolationQuality(ctx2, kCGInterpolationNone);
        CGContextDrawImage(ctx2, CGRectMake(0, 0, (CGFloat)iw, (CGFloat)ih), img);
        CGContextRelease(ctx2);
        for (int pi : byFrame[f]) {
          int x = (int)(firstXY[pi].first + 0.5f);
          int y = (int)(firstXY[pi].second + 0.5f);
          if (x < 0) x = 0; if (x >= (int)iw) x = (int)iw - 1;
          if (y < 0) y = 0; if (y >= (int)ih) y = (int)ih - 1;
          const uint8_t* px = &rgba[(size_t)y * iw * 4 + (size_t)x * 4];
          points[pi].r = px[0]; points[pi].g = px[1]; points[pi].b = px[2];
        }
      }
      CGImageRelease(img);
    }
    aether_sfm_track_obs_free(obs_offsets, obs);
  }
  aether_sfm_pose_t poses_buf[4096];
  int n_poses = 0;
  int n_registered = 0;
  aether_sfm_get_poses(s, poses_buf, 4096, &n_poses);
  for (int i = 0; i < n_poses && i < 4096; ++i) {
    if (poses_buf[i].registered) n_registered++;
  }

  {
    const std::string ply = out_dir + "/cloud.ply";
    std::FILE* f = std::fopen(ply.c_str(), "wb");
    if (f) {
      std::fprintf(f,
                   "ply\nformat binary_little_endian 1.0\nelement vertex %d\n"
                   "property float x\nproperty float y\nproperty float z\n"
                   "property uchar red\nproperty uchar green\nproperty uchar "
                   "blue\nend_header\n",
                   n_points);
      for (int i = 0; i < n_points; ++i) {
        std::fwrite(&points[i].x, 4, 3, f);
        std::fwrite(&points[i].r, 1, 3, f);
      }
      std::fclose(f);
    }
  }
  if (points) aether_sfm_points_free(points);

  const double stream_ms =
      std::chrono::duration<double, std::milli>(t1 - t0).count();
  const double fin_ms =
      std::chrono::duration<double, std::milli>(t2 - t1).count();
  std::printf(
      "DONE fed=%d n_poses=%d n_registered=%d n_points=%d stream_ms=%.0f "
      "finalize_ms=%.0f finalize_json=%s\n",
      fed, n_poses, n_registered, n_points, stream_ms, fin_ms, fj);
  aether_sfm_free(s);
  return 0;
}
