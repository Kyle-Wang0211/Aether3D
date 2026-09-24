// Host-test support for the LOD render pass: the PWLodBench correctness
// judges, moved from pw_splat_ab_bench Sources/lod/pw_lod_bench.cpp @ b792d57
// (readback, image statistics, the jitter-floor diff, the see-through judge,
// the three-way getLOD check, the content frame / target leaf / trajectory)
// with the global device replaced by a GpuCtx and the readback taking any
// texture (R1, R9 in src/pointcloud_lod_render/DEVIATIONS.md).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "aether/pointcloud_lod_render/lod_render.h"

namespace pwlod_judges {

namespace plr = aether::pointcloud_lod_render;
namespace lod = aether::pointcloud_lod;

constexpr double kPi = 3.14159265358979323846;

uint64_t Fnv1a(const uint8_t* p, size_t n);

// ─── camera (row-major, WebGPU clip z in [0,1]) ─────────────────────────
lod::Vec3 Norm(lod::Vec3 v);
lod::Vec3 Cross(lod::Vec3 a, lod::Vec3 b);
double Dot(lod::Vec3 a, lod::Vec3 b);
lod::Vec3 Lerp(lod::Vec3 a, lod::Vec3 b, double t);

struct Pose { lod::Vec3 eye, target; };
plr::CamState MakeCam(const Pose& ps, int w, int h, double zn, double zf);
// WebGPU orthographic camera over the same view (test helper for the D17/R6
// judges): frustum width x height in world units centred on the view axis.
plr::CamState MakeOrthoCam(const Pose& ps, int w, int h, double ortho_h, double zn, double zf);

struct Traj {
  lod::Vec3 c; double R = 1;
  lod::Vec3 leaf_c; double leaf_r = 0.01;
  int32_t leaf = -1;
};
Pose PoseAt(const Traj& T, double t, const char** seg);
void NearFar(const Traj& T, const Pose& p, double* zn, double* zf);
void ContentFrame(const lod::Octree& oct, lod::Vec3* c, double* R);
int32_t PickLeaf(const lod::Octree& oct);

// ─── images ─────────────────────────────────────────────────────────────
struct Img {
  std::vector<uint8_t> px;   // tightly packed RGBA, w*h*4
  uint32_t w = 0, h = 0;
};
struct ImgStat {
  uint64_t hash = 0;
  double cover = 0, sat_mean = 0;
  double mean[3] = {0, 0, 0}, sd[3] = {0, 0, 0};
};
Img Readback(const plr::GpuCtx& g, WGPUTexture tex, uint32_t w, uint32_t h);
std::vector<float> ReadDepth(const plr::GpuCtx& g, const plr::Pipe& P);
ImgStat Stat(const Img& im);
struct Diff { double frac = 0; double psnr = 0; double psnr4 = 0; uint64_t pixels = 0; };
Diff ImgDiff(const Img& a, const Img& b);
bool DetailPreserved(const Diff& lod, const Diff& fl);
double SdMin(const ImgStat& s);
bool ImageNonTrivial(const ImgStat& s);
bool ImageMatchesRef(const ImgStat& s, const ImgStat& ref);
std::string StatJson(const ImgStat& s);

struct SeeThrough { double hole = 0, farther = 0, bad = 0; uint64_t ref_px = 0; };
SeeThrough SeeThroughVs(const Img& ti, const std::vector<float>& td, const Img& ri,
                        const std::vector<float>& rd, double zn, double zf);

struct LodCheck {
  int64_t points = 0, cpu_bf_mismatch = 0, gpu_cpu_mismatch = 0, neg_mismatch = 0, gpu_checked = 0;
  double gpu_max_abs = 0;
  int nodes = 0;
};
LodCheck VerifyGetLOD(const plr::GpuCtx& g, plr::Lod* L, plr::Pipe* P,
                      const std::vector<int32_t>& drawn, const plr::DrawParams& dp);

// A colour texture like the bench's own P->color (RGBA8Unorm, RenderAttachment | CopySrc).
struct OwnedTarget {
  WGPUTexture tex = nullptr;
  WGPUTextureView view = nullptr;
  plr::Target target() const { plr::Target t; t.texture = tex; t.view = view; return t; }
};
OwnedTarget MakeTarget(const plr::GpuCtx& g, uint32_t w, uint32_t h,
                       WGPUTextureFormat f = WGPUTextureFormat_RGBA8Unorm);
void ReleaseTarget(OwnedTarget* t);

// ─── reporting (the house style of tests/pointcloud_lod) ────────────────
struct Report {
  int fail = 0, skip = 0;
  void check(const char* name, bool ok, const std::string& detail);
  void skipped(const char* name, const std::string& why);
  int finish();
};
std::string Fmt(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

}  // namespace pwlod_judges
