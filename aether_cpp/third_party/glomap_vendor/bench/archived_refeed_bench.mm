// archived_refeed_bench.mm — HOST 台架:从**存档照片**重建。
//
// [2026-09-08] 「未完成」项目的真正成因已定罪:拍摄被杀时 db 一个字节的有效
// 内容都没落盘(跑完 finalize 的 db=41MB/wal=0;被杀的 db=4096 一页、malformed、
// `.recover` 抢不出表)。⇒「开始训练」与「补拍」都必然 errDb,因为两者都建立在
// "db 里有东西"这个前提上。**但照片和每张的 ARKit 位姿/内参都完整留着** ——
// 所以解药是把存档照片重新喂一遍。本台架就是在 Mac 上先验这条路成不成立。
//
// 走的是**与设备端同一条**代码路径,而且是同一组**符号**:Dart 经 dlsym 调的
// 是 `pwofficial_*`(见 official_sfm_c.h),所以这里也只调 `pwofficial_*`,
// 不去碰核里的 `aether_sfm_*` 原名 —— 换一层名字就等于换了一条路。
//   pwofficial_create → pwofficial_add_jpeg_frame ×N → pwofficial_finalize_async
// 解码用的是出货那份 `vendor/official_sfm/src/pwofficial_jpeg_decode.mm`
// (整个 TU 原样编进来,不抄不改):解码差一点,特征点就不一样,台架结论也就作废。
//
// 输入 manifest 每行(由 tools/archived_refeed_manifest.py 从 sidecar 生成):
//   <jpegPath> <w> <h> <fx> <fy> <cx> <cy> <qw> <qx> <qy> <qz> <tx> <ty> <tz> <t>
// 位姿是 **CamFromWorld**(sidecar 的 extrinsic 是列主序 camera-to-world,要求逆)。
// 该约定不是推断:拿 official_sfm_fed_frames.jsonl 里**已知约定**的记录对拍,
// 4/4 张误差 0.000000,反着解释差 1.29–1.40。换算在生成脚本里做,台架只透传。
//
// usage: archived_refeed_bench_exe <manifest> <out_dir>

#include "official_sfm_io_c.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

// ── host 链接桩 ─────────────────────────────────────────────────────────────
// 两类,理由不同,都不许静默变成"跑了个别的东西":
//
// (A) GPU 提取器:核以 weak 引用它,设备真链、主机没有。返回 -1 = "不可用",
//     ABI 就地走 CPU 提取(与 sfm_replay_bench.cc:64 同一套桩、同一个返回值)。
//     返回 0 会被当成"成功但零特征",那才是静默毁掉结果的写法。
// (B) phase-B 重放:`pwofficial_jpeg_decode.mm` 在 !TARGET_OS_SIMULATOR 分支里
//     引用它们(住在 iOS-only 的 libpwofficial_gpu_extract.a)。本台架从不调
//     phase-B,只用 DecodeOfficialJpegGray + add_jpeg_frame,所以补桩即可 ——
//     但桩子被真调到必须**当场炸**,不能假装成功。
extern "C" {

// [REAL-GPU-EXTRACT 2026-09-10] 定义 AETHER_REFEED_REAL_GPU_EXTRACT 时改链真正的
// Dawn 提取器(dsp_sift_gpu_c.cc 提供这两个符号),于是**主机上提取与匹配抢同一块
// GPU** —— 那正是 08-09 判决书给提取流水点名的风险(「提取 Dawn ∥ 匹配 Metal 同
// GPU,占空比风险」),补桩版永远复现不出来。此时 use_gpu_extract 可以置 1。
#ifndef AETHER_REFEED_REAL_GPU_EXTRACT
int aether_dsp_sift_extract_gpu(const uint8_t*, int, int, int, int, float*,
                                uint8_t*, int, int*) {
  return -1;  // 不可用 → CPU 兜底
}
int aether_dsp_sift_extract_gpu_v2(const uint8_t*, int, int, int, int, float*,
                                   uint8_t*, float*, float*, int, int*) {
  return -1;  // 同上(_v2 兄弟)
}
#endif
void aether_gpu_match_set_preview_fps30(int) {}
#ifndef AETHER_REFEED_REAL_GPU_EXTRACT
const char* aether_sed_last_fail_reason(void) { return nullptr; }
#endif
// GPU 提取器的分段计时读回口。主机上没有 GPU 提取器,所以**显式清零**而不是
// 空函数体 —— 空函数体会把调用方栈上的垃圾当成"耗时"读走。
#ifndef AETHER_REFEED_REAL_GPU_EXTRACT
void aether_sed_last_stages(double* out, int cap) {
  if (out != nullptr && cap > 0) std::memset(out, 0, sizeof(double) * (size_t)cap);
}
#endif


[[noreturn]] static void PhaseBStub(const char* fn) {
  std::fprintf(stderr, "FATAL: phase-B stub %s called on host\n", fn);
  std::abort();
}
uint32_t aether_preclamp_phase_b_replay_create_v1(const char*, const int64_t*,
                                                  const char* const*, uint32_t,
                                                  void**) {
  PhaseBStub("replay_create_v1");
}
uint32_t aether_preclamp_phase_b_replay_add_gray_v1(
    void*, const uint8_t*, int, int, int64_t, const char*, uint32_t, int32_t,
    int (*)(const uint8_t*, int, int, int, int, float*, uint8_t*, int, int*)) {
  PhaseBStub("replay_add_gray_v1");
}
uint32_t aether_preclamp_phase_b_replay_seal_v1(void*, void*) {
  PhaseBStub("replay_seal_v1");
}
void aether_preclamp_phase_b_replay_destroy_v1(void*) {
  PhaseBStub("replay_destroy_v1");
}

}  // extern "C"

namespace {

struct Row {
  std::string path;
  int w = 0, h = 0;
  double fx = 0, fy = 0, cx = 0, cy = 0;
  double q[4] = {1, 0, 0, 0};
  double t[3] = {0, 0, 0};
  double capture_t = 0;
};

double NowMs() {
  return std::chrono::duration<double, std::milli>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void WritePly(const std::string& path, const aether_sfm_point_t* pts, int n) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (f == nullptr) return;
  std::fprintf(f,
               "ply\nformat ascii 1.0\nelement vertex %d\n"
               "property float x\nproperty float y\nproperty float z\n"
               "property uchar red\nproperty uchar green\nproperty uchar blue\n"
               "end_header\n",
               n);
  for (int i = 0; i < n; ++i) {
    std::fprintf(f, "%.6f %.6f %.6f %d %d %d\n", pts[i].x, pts[i].y, pts[i].z,
                 pts[i].r, pts[i].g, pts[i].b);
  }
  std::fclose(f);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s <manifest> <out_dir>\n", argv[0]);
    return 1;
  }
  const std::string manifest = argv[1];
  const std::string out_dir = argv[2];

  std::vector<Row> rows;
  {
    FILE* f = std::fopen(manifest.c_str(), "r");
    if (f == nullptr) {
      std::fprintf(stderr, "cannot open manifest %s\n", manifest.c_str());
      return 1;
    }
    char buf[4096];
    while (std::fgets(buf, sizeof(buf), f) != nullptr) {
      if (buf[0] == '#' || buf[0] == '\n') continue;
      Row r;
      char p[2048];
      const int n = std::sscanf(
          buf, "%2047s %d %d %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf",
          p, &r.w, &r.h, &r.fx, &r.fy, &r.cx, &r.cy, &r.q[0], &r.q[1], &r.q[2],
          &r.q[3], &r.t[0], &r.t[1], &r.t[2], &r.capture_t);
      if (n != 15) {
        // 失败必须留痕:少喂一张就少救一张,而调用方无从察觉。
        std::fprintf(stderr, "SKIP malformed manifest line (parsed %d/15)\n", n);
        continue;
      }
      r.path = p;
      rows.push_back(r);
    }
    std::fclose(f);
  }
  std::printf("MANIFEST rows=%zu\n", rows.size());
  if (rows.empty()) return 2;

  // 会话的 image_width/height 必须等于喂进去的灰度尺寸(生产端就是这么建的:
  // sfm_live_recon.dart:1927 用第一张关键帧的 w/h 懒建会话)。这里同样取第一行,
  // 并对其余行做一致性检查 —— 尺寸混用不会报错,只会让内参对不上。
  const int sw = rows[0].w, sh = rows[0].h;
  for (const Row& r : rows) {
    if (r.w != sw || r.h != sh) {
      std::fprintf(stderr, "FATAL: mixed image sizes %dx%d vs %dx%d (%s)\n", sw,
                   sh, r.w, r.h, r.path.c_str());
      return 2;
    }
  }

  aether_sfm_options_t opts;
  pwofficial_options_default(&opts);
  // 逐项对齐生产:official_aether_sfm_ffi.dart 的 create()。
  // 13312 不是随手填的 —— 8192 那套数字在 09-06 已被"生产不会用"否决过一次。
  opts.max_features = 13312;   // AetherSfmStreamSession.researchMaxFeatures
  opts.k_neighbors = 12;       // researchKNeighbors
  opts.match_max_ratio = 0.8f; // defaultMatchMaxRatio
  opts.image_width = sw;
  opts.image_height = sh;
  opts.use_gpu_match = 1;      // 主机链真 Metal 匹配器(与 official_replay_bench 同)
  // 🔴 与设备的**唯一**已知口径差:提取器走 CPU。
  // 原因不是"想省事":核里 gpu_avail = use_gpu_extract && (符号非空),而 macOS
  // ld64 不接受"弱引用且无定义",所以主机必须给这两个符号补桩 ⇒ 符号必然非空。
  // 于是 use_gpu_extract=1 时核会去调那个只会返回 -1 的桩,而这一段**没有** CPU
  // 兜底(erc!=0 直接 ERR_EXTRACT,见 official_aether_sfm_c.cc:10779)——
  // 实测 12/12 全废、每张 43ms(解码完就死)。置 0 才走 aether_dsp_sift_extract_v2。
  // 影响范围:特征点由 CPU 提取器产出,与设备 GPU 提取器不逐位相同,所以本台架
  // 的点数/耗时不能当设备预测值;它验的是**这条恢复路成不成立**,不是性能。
#ifdef AETHER_REFEED_REAL_GPU_EXTRACT
  // [REAL-GPU-EXTRACT 2026-09-10] 本目标链的是真 Dawn 提取器(不是返回 -1 的桩),
  // 所以可以、也必须置 1 —— 只有这样主机上才会出现「提取与匹配抢同一块 GPU」。
  // 仍留 env 退回:OFFICIAL_AETHER_REFEED_GPU_EXTRACT=0 走 CPU 提取当对照臂。
  {
    const char* e = std::getenv("OFFICIAL_AETHER_REFEED_GPU_EXTRACT");
    opts.use_gpu_extract = (e && e[0] == '0' && e[1] == '\0') ? 0 : 1;
    std::fprintf(stderr, "[REFEED] use_gpu_extract=%d (real Dawn extractor linked)\n",
                 opts.use_gpu_extract);
  }
#else
  opts.use_gpu_extract = 0;
#endif

  const std::string db_path = out_dir + "/refeed.db";
  std::remove(db_path.c_str());
  aether_sfm_session_t* s = nullptr;
  const aether_sfm_result_t crc = pwofficial_create(db_path.c_str(), &opts, &s);
  if (crc != AETHER_SFM_OK || s == nullptr) {
    std::fprintf(stderr, "pwofficial_create failed rc=%d\n", (int)crc);
    return 3;
  }
  std::printf("CREATED %dx%d max_features=%d k=%d db=%s\n", sw, sh,
              opts.max_features, opts.k_neighbors, db_path.c_str());
  std::fflush(stdout);

  int ok = 0, fail = 0;
  const double t_stream0 = NowMs();
  for (size_t i = 0; i < rows.size(); ++i) {
    const Row& r = rows[i];
    int frame_id = -1;
    // [PF-HINT 2026-09-10] 生产里 Dart facade 在派发第 N 帧之前先发第 N+1 帧的
    // 预取提示,提取流水才有前瞻;台架此前从不发,于是 pf 永远是 3(未命中转发)
    // —— 那等于把提取挪到另一个线程再同步等它,结构上不可能有收益。补上之后
    // 这条链才真正能给「提取 ∥ 匹配」定价。manifest 有序,下一帧完全已知。
    // 预取入口自身按 env + 排空门判断要不要真做,这里无条件发提示即可。
    // 🔴 位置必须在 add_frame **之前**(与生产 facade 一致):这样 prefetch(N+1)
    // 与 add_frame(N) 的整段处理并行,线程有时间算完。实测放到 add_frame 之后
    // 会让 N+1 到达时 valid=0 ⇒ 全部落到未命中。返回码落账:0=入队 1=关 2=busy。
    if (i + 1 < rows.size()) {
      const int prc = pwofficial_prefetch_jpeg_frame(s, rows[i + 1].path.c_str());
      std::printf("PFHINT %zu rc=%d\n", i + 1, prc);
      std::fflush(stdout);
    }
    const double t0 = NowMs();
    const aether_sfm_result_t rc = pwofficial_add_jpeg_frame(
        s, r.path.c_str(), r.capture_t, (float)r.fx, (float)r.fy, (float)r.cx,
        (float)r.cy, r.q, r.t, &frame_id);
    // 逐张报告:哪张进去了、哪张没进去,一张都不许静默跳过。
    std::printf("FEED %zu/%zu rc=%d frame_id=%d ms=%.0f %s\n", i + 1,
                rows.size(), (int)rc, frame_id, NowMs() - t0, r.path.c_str());
    std::fflush(stdout);
    if (rc == AETHER_SFM_OK) {
      ++ok;
    } else {
      ++fail;
    }
  }
  const double stream_ms = NowMs() - t_stream0;
  std::printf("FED ok=%d fail=%d stream_ms=%.0f\n", ok, fail, stream_ms);
  std::fflush(stdout);
  if (ok == 0) {
    pwofficial_free(s);
    return 4;
  }

  char fj[1024] = {0};
  const double t_fin0 = NowMs();
  const aether_sfm_result_t frc = pwofficial_finalize_async(s, fj, sizeof(fj));
  if (frc != AETHER_SFM_OK) {
    std::fprintf(stderr, "finalize_async failed rc=%d\n", (int)frc);
    pwofficial_free(s);
    return 5;
  }
  std::printf("FINALIZE_ASYNC phase1=%s\n", fj);
  std::fflush(stdout);

  int status = pwofficial_finalize_status(s);
  while (status != AETHER_SFM_FINALIZE_REFINED &&
         status != AETHER_SFM_FINALIZE_ERROR) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    status = pwofficial_finalize_status(s);
  }
  const double finalize_ms = NowMs() - t_fin0;
  if (status == AETHER_SFM_FINALIZE_ERROR) {
    std::fprintf(stderr, "finalize refine ERROR\n");
    pwofficial_free(s);
    return 6;
  }
  std::printf("REFINED finalize_ms=%.0f\n", finalize_ms);
  std::fflush(stdout);

  // 判据不是"没崩",而是**这些照片被注册进同一个模型了几张**:注册数才是
  // "这条恢复路救回了多少"。只报点数会让"注册 2 张、点云是两张的碎片"看着像成功。
  std::vector<aether_sfm_pose_t> poses(rows.size());
  int n_pose = 0;
  pwofficial_get_poses(s, poses.data(), (int)poses.size(), &n_pose);
  int n_reg = 0;
  for (int i = 0; i < n_pose; ++i) {
    if (poses[i].registered != 0) ++n_reg;
  }

  aether_sfm_point_t* pts = nullptr;
  int n_pts = 0;
  const aether_sfm_result_t prc = pwofficial_get_points(s, &pts, &n_pts);
  if (prc == AETHER_SFM_OK && pts != nullptr) {
    WritePly(out_dir + "/cloud.ply", pts, n_pts);
    pwofficial_points_free(pts);
  } else {
    std::fprintf(stderr, "get_points rc=%d\n", (int)prc);
    n_pts = -1;
  }

  std::printf(
      "RESULT fed=%d/%zu n_reg=%d/%d n_points=%d stream_ms=%.0f "
      "finalize_ms=%.0f\n",
      ok, rows.size(), n_reg, n_pose, n_pts, stream_ms, finalize_ms);
  std::fflush(stdout);

  pwofficial_free(s);
  return 0;
}
