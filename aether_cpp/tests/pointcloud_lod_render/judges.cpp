// See judges.h. Bodies are pw_lod_bench.cpp @ b792d57's, with `g.` -> the
// GpuCtx argument and Readback taking a texture (R1, R9).
#include "judges.h"

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <unordered_map>

namespace pwlod_judges {

using namespace aether::pointcloud_lod;

// FNV-1a 64 -- image identity for determinism checks (not a security hash).
uint64_t Fnv1a(const uint8_t* p, size_t n) {
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ull; }
  return h;
}

// ─── camera (row-major, WebGPU clip z in [0,1]) ─────────────────────────
// lookAt / perspective are the LOD library's own test helpers
// (tests/pointcloud_lod/test_select.cpp), so the bench and the library's
// host tests hand selectVisible() the identical convention.
Vec3 Norm(Vec3 v) { const double l = v.length(); return l > 0 ? Vec3{v.x/l, v.y/l, v.z/l} : v; }
Vec3 Cross(Vec3 a, Vec3 b) { return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}; }
double Dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
Vec3 Lerp(Vec3 a, Vec3 b, double t) { return a + (b - a) * t; }

plr::CamState MakeCam(const Pose& ps, int w, int h, double zn, double zf) {
  plr::CamState cs;
  const double fov = 60.0;
  const Vec3 f = Norm(ps.target - ps.eye);
  const Vec3 s = Norm(Cross(f, {0, 1, 0}));
  const Vec3 u = Cross(s, f);
  const double v[16] = { s.x,  s.y,  s.z, -Dot(s, ps.eye),
                         u.x,  u.y,  u.z, -Dot(u, ps.eye),
                        -f.x, -f.y, -f.z,  Dot(f, ps.eye),
                         0, 0, 0, 1};
  const double t = 1.0 / std::tan(fov * kPi / 180.0 / 2.0);
  const double aspect = double(w) / double(h);
  const double p[16] = { t/aspect, 0, 0, 0,
                         0, t, 0, 0,
                         0, 0, zf/(zn - zf), zn*zf/(zn - zf),
                         0, 0, -1, 0};
  plr::Mul(p, v, cs.vp);
  cs.cam.position = ps.eye;
  cs.cam.fovYDegrees = fov;
  cs.cam.screenHeightPx = h;
  std::memcpy(cs.cam.viewProj, cs.vp, sizeof cs.vp);
  cs.cam_dist = (ps.target - ps.eye).length();
  return cs;
}

// Same view, three.js Matrix4.makeOrthographic WebGPUCoordinateSystem branch
// (src/math/Matrix4.js:1200-1244 @ 6101189ee28b; row-major here, D4), with a
// symmetric frustum: right - left = ortho_h * w / h, top - bottom = ortho_h.
plr::CamState MakeOrthoCam(const Pose& ps, int w, int h, double ortho_h, double zn, double zf) {
  plr::CamState cs = MakeCam(ps, w, h, zn, zf);
  const Vec3 f = Norm(ps.target - ps.eye);
  const Vec3 s = Norm(Cross(f, {0, 1, 0}));
  const Vec3 u = Cross(s, f);
  const double v[16] = { s.x,  s.y,  s.z, -Dot(s, ps.eye),
                         u.x,  u.y,  u.z, -Dot(u, ps.eye),
                        -f.x, -f.y, -f.z,  Dot(f, ps.eye),
                         0, 0, 0, 1};
  const double ow = ortho_h * double(w) / double(h);
  const double x = 2.0 / ow, y = 2.0 / ortho_h;               // :1204-1205
  const double c = -1.0 / (zf - zn), d = -zn / (zf - zn);      // :1226-1227 (a = b = 0: symmetric)
  const double p[16] = { x, 0, 0, 0,
                         0, y, 0, 0,
                         0, 0, c, d,
                         0, 0, 0, 1};
  plr::Mul(p, v, cs.vp);
  std::memcpy(cs.cam.viewProj, cs.vp, sizeof cs.vp);
  cs.cam.orthographic = true;
  cs.cam.orthoWidth = ow;
  cs.cam.orthoHeight = ortho_h;
  cs.cam.screenWidthPx = w;
  return cs;
}

// ─── trajectory ──────────────────────────────────────────────────────────
double Smooth(double t) { t = std::min(std::max(t, 0.0), 1.0); return t*t*(3 - 2*t); }

Pose LogDolly(Vec3 t0, double d0, Vec3 t1, double d1, double s) {
  const Vec3 tg = Lerp(t0, t1, s);
  const double d = std::exp(std::log(d0) + (std::log(d1) - std::log(d0)) * s);
  return {tg + Vec3{0, 0, d}, tg};
}

Pose PoseAt(const Traj& T, double t, const char** seg) {
  const Vec3 c = T.c; const double R = T.R;
  const Pose over{c + Vec3{0, 0, 2.0 * R}, c};
  const Pose leafp{T.leaf_c + Vec3{0, 0, 3.0 * T.leaf_r}, T.leaf_c};
  const Pose orb0{c + Vec3{0, 0, 0.6 * R}, c};
  const Pose pan0{c + Vec3{-0.5 * R, 0, 0.35 * R}, c + Vec3{-0.5 * R, 0, 0}};
  const Pose pan1{c + Vec3{ 0.5 * R, 0, 0.35 * R}, c + Vec3{ 0.5 * R, 0, 0}};
  auto seg_t = [&](double a, double b) { return (t - a) / (b - a); };
  if (t < 0.10) { *seg = "hold_overview"; return over; }
  if (t < 0.30) { *seg = "push_in";
    return LogDolly(c, 2.0 * R, T.leaf_c, 3.0 * T.leaf_r, Smooth(seg_t(0.10, 0.30))); }
  if (t < 0.40) { *seg = "hold_leaf"; return leafp; }
  if (t < 0.48) { *seg = "pull_out";
    return LogDolly(T.leaf_c, 3.0 * T.leaf_r, c, 0.6 * R, Smooth(seg_t(0.40, 0.48))); }
  if (t < 0.73) { *seg = "orbit";
    const double th = 2.0 * kPi * seg_t(0.48, 0.73);
    return {c + Vec3{0.6 * R * std::sin(th), 0, 0.6 * R * std::cos(th)}, c}; }
  if (t < 0.78) { *seg = "to_pan";
    const double s = Smooth(seg_t(0.73, 0.78));
    return {Lerp(orb0.eye, pan0.eye, s), Lerp(orb0.target, pan0.target, s)}; }
  if (t < 0.93) { *seg = "pan";
    const double s = seg_t(0.78, 0.93);
    return {Lerp(pan0.eye, pan1.eye, s), Lerp(pan0.target, pan1.target, s)}; }
  *seg = "back_to_overview";
  const double s = Smooth(seg_t(0.93, 1.0));
  return {Lerp(pan1.eye, over.eye, s), Lerp(pan1.target, over.target, s)};
}

void NearFar(const Traj& T, const Pose& p, double* zn, double* zf) {
  const double d = (p.target - p.eye).length();
  *zn = std::max(1e-4 * T.R, 0.01 * d);
  *zf = 20.0 * T.R;                                 // test_select.cpp's R*20
}

void ContentFrame(const Octree& oct, Vec3* c, double* R) {
  int L = 0;
  for (const Node& n : oct.nodes) L = std::max(L, n.level);
  L = std::min(L, 4);
  std::unordered_map<int32_t, double> w;
  for (size_t i = 0; i < oct.nodes.size(); ++i) {
    int32_t a = (int32_t)i;
    while (a >= 0 && oct.nodes[(size_t)a].level > L) a = oct.nodes[(size_t)a].parent;
    if (a >= 0 && oct.nodes[(size_t)a].level == L) w[a] += oct.nodes[i].numPoints;
  }
  std::vector<std::pair<int32_t, double>> v(w.begin(), w.end());
  double tot = 0;
  for (auto& x : v) tot += x.second;
  auto wmedian = [&](int axis) {
    std::vector<std::pair<double, double>> s;
    for (auto& x : v) {
      const Vec3 cc = oct.nodes[(size_t)x.first].box.center();
      s.push_back({axis == 0 ? cc.x : axis == 1 ? cc.y : cc.z, x.second});
    }
    std::sort(s.begin(), s.end());
    double acc = 0;
    for (auto& e : s) { acc += e.second; if (acc >= 0.5 * tot) return e.first; }
    return s.empty() ? 0.0 : s.back().first;
  };
  *c = {wmedian(0), wmedian(1), wmedian(2)};
  std::vector<std::pair<double, double>> dist;
  for (auto& x : v) {
    const Node& n = oct.nodes[(size_t)x.first];
    dist.push_back({(n.box.center() - *c).length() + n.box.boundingSphereRadius(), x.second});
  }
  std::sort(dist.begin(), dist.end());
  double acc = 0; *R = dist.empty() ? 1.0 : dist.back().first;
  for (auto& e : dist) { acc += e.second; if (acc >= 0.9 * tot) { *R = e.first; break; } }
}

// Deepest level, most points; ties broken by node index. Deterministic.
int32_t PickLeaf(const Octree& oct) {
  int best = -1; int best_lv = -1; uint32_t best_n = 0;
  for (size_t i = 0; i < oct.nodes.size(); ++i) {
    const Node& n = oct.nodes[i];
    const bool has_child = std::any_of(n.children.begin(), n.children.end(),
                                       [](int32_t x) { return x >= 0; });
    if (has_child || n.numPoints == 0) continue;
    if (n.level > best_lv || (n.level == best_lv && n.numPoints > best_n)) {
      best = (int)i; best_lv = n.level; best_n = n.numPoints;
    }
  }
  return best;
}

// ─── image readback + criteria that can fail ─────────────────────────────
Img Readback(const plr::GpuCtx& g, WGPUTexture tex, uint32_t w, uint32_t h) {
  Img im; im.w = w; im.h = h;
  const uint32_t bpr = ((w * 4u) + 255u) / 256u * 256u;
  const uint64_t bytes = (uint64_t)bpr * h;
  WGPUBuffer stage = plr::MakeBuffer(g, bytes, (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
  src.texture = tex;
  WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
  dst.buffer = stage; dst.layout.offset = 0;
  dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = h;
  WGPUExtent3D ext{w, h, 1};
  wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &ext);
  WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
  wgpuCommandEncoderRelease(enc);
  wgpuQueueSubmit(g.queue, 1, &cb);
  wgpuCommandBufferRelease(cb);
  bool ok = false;
  WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  mi.mode = WGPUCallbackMode_WaitAnyOnly;
  mi.callback = [](WGPUMapAsyncStatus s, WGPUStringView, void* u, void*) {
    *static_cast<bool*>(u) = (s == WGPUMapAsyncStatus_Success);
  };
  mi.userdata1 = &ok;
  plr::WaitFuture(g, wgpuBufferMapAsync(stage, WGPUMapMode_Read, 0, bytes, mi));
  if (ok) {
    const uint8_t* p = static_cast<const uint8_t*>(wgpuBufferGetConstMappedRange(stage, 0, bytes));
    if (p) {
      im.px.resize((size_t)w * h * 4);
      for (uint32_t y = 0; y < h; ++y)
        std::memcpy(im.px.data() + (size_t)y * w * 4, p + (size_t)y * bpr, (size_t)w * 4);
    }
    wgpuBufferUnmap(stage);
  }
  wgpuBufferDestroy(stage);
  wgpuBufferRelease(stage);
  return im;
}

ImgStat Stat(const Img& im) {
  ImgStat s;
  if (im.px.empty()) return s;
  s.hash = Fnv1a(im.px.data(), im.px.size());
  const size_t n = (size_t)im.w * im.h;
  double s1[3] = {0, 0, 0}, s2[3] = {0, 0, 0}, sat = 0;
  size_t cov = 0;
  for (size_t i = 0; i < n; ++i) {
    const uint8_t* q = &im.px[i * 4];
    for (int c = 0; c < 3; ++c) { s1[c] += q[c]; s2[c] += (double)q[c] * q[c]; }
    if (q[3]) {
      ++cov;
      const int mx = std::max(q[0], std::max(q[1], q[2]));
      const int mn = std::min(q[0], std::min(q[1], q[2]));
      if (mx > 0) sat += double(mx - mn) / double(mx);
    }
  }
  s.cover = double(cov) / double(n);
  s.sat_mean = cov ? sat / double(cov) : 0.0;
  for (int c = 0; c < 3; ++c) {
    s.mean[c] = s1[c] / double(n);
    const double v = s2[c] / double(n) - s.mean[c] * s.mean[c];
    s.sd[c] = v > 0 ? std::sqrt(v) : 0.0;
  }
  return s;
}

// frac: pixels differing by >8 in any channel (or in coverage); psnr: full
// resolution; psnr4: after 4x4 box averaging (structure, not 1-px sprite noise).
Diff ImgDiff(const Img& a, const Img& b) {
  Diff d;
  if (a.px.size() != b.px.size() || a.px.empty()) { d.frac = 1; return d; }
  const size_t n = (size_t)a.w * a.h;
  {
    const uint32_t bw = a.w / 4, bh = a.h / 4;
    double se4 = 0;
    for (uint32_t by = 0; by < bh; ++by)
      for (uint32_t bx = 0; bx < bw; ++bx)
        for (int c = 0; c < 3; ++c) {
          double sa = 0, sb = 0;
          for (uint32_t y = 0; y < 4; ++y)
            for (uint32_t x = 0; x < 4; ++x) {
              const size_t o = ((size_t)(by * 4 + y) * a.w + bx * 4 + x) * 4 + c;
              sa += a.px[o]; sb += b.px[o];
            }
          const double v = (sa - sb) / 16.0;
          se4 += v * v;
        }
    const double mse4 = se4 / (double(bw) * bh * 3);
    d.psnr4 = mse4 > 0 ? 10.0 * std::log10(255.0 * 255.0 / mse4) : 99.0;
  }
  double se = 0;
  for (size_t i = 0; i < n; ++i) {
    bool any = false;
    for (int c = 0; c < 3; ++c) {
      const int v = (int)a.px[i*4+c] - (int)b.px[i*4+c];
      se += double(v) * v;
      if (std::abs(v) > 8) any = true;
    }
    if (a.px[i*4+3] != b.px[i*4+3]) any = true;
    if (any) ++d.pixels;
  }
  d.frac = double(d.pixels) / double(n);
  const double mse = se / double(n * 3);
  d.psnr = mse > 0 ? 10.0 * std::log10(255.0 * 255.0 / mse) : 99.0;
  return d;
}

bool DetailPreserved(const Diff& lod, const Diff& fl) {
  return lod.frac <= std::max(1.25 * fl.frac, fl.frac + 0.005) && lod.psnr >= fl.psnr - 1.0;
}

// Depth32Float readback (aspect DepthOnly) -> NDC depth per pixel.
std::vector<float> ReadDepth(const plr::GpuCtx& g, const plr::Pipe& P) {
  std::vector<float> out;
  const uint32_t bpr = ((P.w * 4u) + 255u) / 256u * 256u;
  const uint64_t bytes = (uint64_t)bpr * P.h;
  WGPUBuffer stage = plr::MakeBuffer(g, bytes, (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
  WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
  WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
  src.texture = P.depth;
  src.aspect = WGPUTextureAspect_DepthOnly;
  WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
  dst.buffer = stage; dst.layout.offset = 0;
  dst.layout.bytesPerRow = bpr; dst.layout.rowsPerImage = P.h;
  WGPUExtent3D ext{P.w, P.h, 1};
  wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &ext);
  WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
  WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
  wgpuCommandEncoderRelease(enc);
  wgpuQueueSubmit(g.queue, 1, &cb);
  wgpuCommandBufferRelease(cb);
  bool ok = false;
  WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  mi.mode = WGPUCallbackMode_WaitAnyOnly;
  mi.callback = [](WGPUMapAsyncStatus s2, WGPUStringView, void* u, void*) {
    *static_cast<bool*>(u) = (s2 == WGPUMapAsyncStatus_Success);
  };
  mi.userdata1 = &ok;
  plr::WaitFuture(g, wgpuBufferMapAsync(stage, WGPUMapMode_Read, 0, bytes, mi));
  if (ok) {
    const uint8_t* p = static_cast<const uint8_t*>(wgpuBufferGetConstMappedRange(stage, 0, bytes));
    if (p) {
      out.resize((size_t)P.w * P.h);
      for (uint32_t y = 0; y < P.h; ++y)
        std::memcpy(out.data() + (size_t)y * P.w, p + (size_t)y * bpr, (size_t)P.w * 4);
    }
    wgpuBufferUnmap(stage);
  }
  wgpuBufferDestroy(stage);
  wgpuBufferRelease(stage);
  return out;
}

// "See-through" judge. Over the pixels the REFERENCE covers: a hole = the test
// frame has nothing there; see-through = the test frame shows a surface more
// than 5% farther than the reference's (i.e. something behind the true front
// surface). Depth is linearised from NDC with the pose's near/far.
SeeThrough SeeThroughVs(const Img& ti, const std::vector<float>& td, const Img& ri,
                        const std::vector<float>& rd, double zn, double zf) {
  SeeThrough r;
  if (ti.px.size() != ri.px.size() || td.size() != rd.size() || rd.empty()) { r.bad = 1; return r; }
  auto lin = [&](float ndc) { return zf * zn / (zf - (double)ndc * (zf - zn)); };
  uint64_t hole = 0, far = 0;
  for (size_t i = 0; i < rd.size(); ++i) {
    if (!ri.px[i * 4 + 3]) continue;
    r.ref_px++;
    if (!ti.px[i * 4 + 3]) { hole++; continue; }
    if (lin(td[i]) > lin(rd[i]) * 1.05) far++;
  }
  if (r.ref_px) {
    r.hole = double(hole) / double(r.ref_px);
    r.farther = double(far) / double(r.ref_px);
    r.bad = double(hole + far) / double(r.ref_px);
  }
  return r;
}

std::string StatJson(const ImgStat& s) {
  char b[400];
  std::snprintf(b, sizeof b,
      "{\"hash\":\"%016llx\",\"coverage\":%.6f,\"sat_mean\":%.4f,\"mean_rgb\":[%.2f,%.2f,%.2f],"
      "\"sd_rgb\":[%.2f,%.2f,%.2f]}",
      (unsigned long long)s.hash, s.cover, s.sat_mean, s.mean[0], s.mean[1], s.mean[2],
      s.sd[0], s.sd[1], s.sd[2]);
  return b;
}

double SdMin(const ImgStat& s) { return std::min(s.sd[0], std::min(s.sd[1], s.sd[2])); }

// Pre-registered image criteria (see LOD_DEVICE_PLAN_20260923.md §4.2)
bool ImageNonTrivial(const ImgStat& s) {
  return s.cover > 0.01 && s.sat_mean > 0.05 && SdMin(s) > 10.0;
}
bool ImageMatchesRef(const ImgStat& s, const ImgStat& ref) {
  auto ratio_ok = [](double a, double b) { return b > 0 && a / b >= 0.8 && a / b <= 1.25; };
  return ratio_ok(s.sat_mean, ref.sat_mean) && ratio_ok(SdMin(s), SdMin(ref));
}

// ─── getLOD verification ────────────────────────────────────────────────
// Three-way check of the adaptive point size's LOD lookup on real drawn nodes:
//   cpu_vs_bruteforce  CPU transliteration of getLOD (table + index arithmetic)
//                      vs walking the octree's own child boxes and asking the
//                      drawn set directly -- independent formulations
//   gpu_vs_cpu         the WGSL getLOD run in a compute shader vs the CPU copy
//   neg_masks_zeroed   the same CPU check with every child mask cleared: must
//                      disagree with the brute force (the judge can fail)
LodCheck VerifyGetLOD(const plr::GpuCtx& g, plr::Lod* L, plr::Pipe* P,
                      const std::vector<int32_t>& drawn, const plr::DrawParams& dp) {
  LodCheck out;
  const Octree& oct = *L->oct;
  const plr::VNTable t = plr::BuildVisibleNodeTable(oct, drawn, L->gpu);
  plr::VNTable neg = t;
  for (size_t i = 0; i < neg.data.size(); i += 4) neg.data[i] = 0;
  std::unordered_map<int32_t, bool> inTable;
  for (auto& kv : t.offset) inTable[kv.first] = true;
  if (!t.data.empty()) wgpuQueueWriteBuffer(g.queue, P->vn, 0, t.data.data(), t.data.size() * 4);

  WGPUBuffer nub = plr::MakeBuffer(g, sizeof(plr::NodeU), (WGPUBufferUsage)(WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst));
  const size_t kNodes = std::min<size_t>(drawn.size(), 24);
  for (size_t k = 0; k < kNodes; ++k) {
    const int32_t n = drawn[k];
    const Node& nd = oct.nodes[(size_t)n];
    const NodePoints* np = L->loader ? L->loader->cache().get(n) : L->aloader->touch(n);
    auto git = L->gpu.find(n);
    if (!np || git == L->gpu.end() || np->count() == 0) continue;
    out.nodes++;
    const float half = (float)(0.5 * nd.box.size().x);
    const int vnStart = (int)t.offset.at(n);
    const size_t cnt = np->count();
    std::vector<float> cpu(cnt);
    for (size_t i = 0; i < cnt; ++i) {
      const float pm[3] = {np->xyz[i*3+0] + half, np->xyz[i*3+1] + half, np->xyz[i*3+2] + half};
      cpu[i] = plr::CpuGetLOD(t, (float)dp.octree_size, (float)nd.level, vnStart, pm);
      const float cneg = plr::CpuGetLOD(neg, (float)dp.octree_size, (float)nd.level, vnStart, pm);
      // brute force: descend through the octree's own child boxes while the
      // child that contains the point is in the drawn set (table).
      const Vec3 w{np->origin.x + np->xyz[i*3+0], np->origin.y + np->xyz[i*3+1], np->origin.z + np->xyz[i*3+2]};
      int32_t cur = n;
      for (;;) {
        const Node& cn = oct.nodes[(size_t)cur];
        const Vec3 c = cn.box.center();
        const int oc = ((w.x >= c.x) ? 4 : 0) | ((w.y >= c.y) ? 2 : 0) | ((w.z >= c.z) ? 1 : 0);
        const int32_t ch = cn.children[(size_t)oc];
        if (ch >= 0 && inTable.count(ch)) cur = ch; else break;
      }
      const float bf = (float)oct.nodes[(size_t)cur].level +
                       ((float)t.data[(size_t)t.offset.at(cur) * 4 + 2] / 10.0f - 10.0f);
      if (std::fabs(cpu[i] - bf) > 1e-4f) out.cpu_bf_mismatch++;
      if (std::fabs(cneg - bf) > 1e-4f) out.neg_mismatch++;
      out.points++;
    }
    // GPU: same getLOD text in a compute shader
    plr::NodeU nu{};
    nu.level = (float)nd.level; nu.vn_start = (float)vnStart; nu.half_size = half;
    wgpuQueueWriteBuffer(g.queue, nub, 0, &nu, sizeof nu);
    const uint64_t ob = (uint64_t)cnt * 4;
    WGPUBuffer outb = plr::MakeBuffer(g, ob, (WGPUBufferUsage)(WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc));
    WGPUBuffer stg = plr::MakeBuffer(g, ob, (WGPUBufferUsage)(WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst));
    WGPUBindGroupEntry be[5];
    for (auto& x : be) x = WGPU_BIND_GROUP_ENTRY_INIT;
    be[0].binding = 0; be[0].buffer = P->frame_u; be[0].size = sizeof(plr::FrameU);
    be[1].binding = 1; be[1].buffer = nub;        be[1].size = sizeof(plr::NodeU);
    be[2].binding = 2; be[2].buffer = git->second.buf; be[2].size = git->second.bytes;
    be[3].binding = 3; be[3].buffer = P->vn;      be[3].size = (uint64_t)plr::kMaxVN * 16;
    be[4].binding = 4; be[4].buffer = outb;       be[4].size = ob;
    WGPUBindGroupDescriptor bd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    WGPUBindGroupLayout bgl = wgpuComputePipelineGetBindGroupLayout(P->lodcheck, 0);
    bd.layout = bgl; bd.entryCount = 5; bd.entries = be;
    WGPUBindGroup bg = wgpuDeviceCreateBindGroup(g.device, &bd);
    WGPUCommandEncoderDescriptor ed = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(g.device, &ed);
    WGPUComputePassDescriptor cpd = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
    WGPUComputePassEncoder cp = wgpuCommandEncoderBeginComputePass(enc, &cpd);
    wgpuComputePassEncoderSetPipeline(cp, P->lodcheck);
    wgpuComputePassEncoderSetBindGroup(cp, 0, bg, 0, nullptr);
    wgpuComputePassEncoderDispatchWorkgroups(cp, (uint32_t)((cnt + 63) / 64), 1, 1);
    wgpuComputePassEncoderEnd(cp);
    wgpuComputePassEncoderRelease(cp);
    wgpuCommandEncoderCopyBufferToBuffer(enc, outb, 0, stg, 0, ob);
    WGPUCommandBufferDescriptor cbd = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish(enc, &cbd);
    wgpuCommandEncoderRelease(enc);
    wgpuQueueSubmit(g.queue, 1, &cb);
    wgpuCommandBufferRelease(cb);
    bool ok = false;
    WGPUBufferMapCallbackInfo mi = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mi.mode = WGPUCallbackMode_WaitAnyOnly;
    mi.callback = [](WGPUMapAsyncStatus st, WGPUStringView, void* u, void*) {
      *static_cast<bool*>(u) = (st == WGPUMapAsyncStatus_Success);
    };
    mi.userdata1 = &ok;
    plr::WaitFuture(g, wgpuBufferMapAsync(stg, WGPUMapMode_Read, 0, ob, mi));
    if (ok) {
      const float* gp = static_cast<const float*>(wgpuBufferGetConstMappedRange(stg, 0, ob));
      if (gp) for (size_t i = 0; i < cnt; ++i) {
        const double d = std::fabs((double)gp[i] - (double)cpu[i]);
        out.gpu_max_abs = std::max(out.gpu_max_abs, d);
        if (d > 1e-4) out.gpu_cpu_mismatch++;
        out.gpu_checked++;
      }
      wgpuBufferUnmap(stg);
    }
    wgpuBindGroupRelease(bg);
    wgpuBindGroupLayoutRelease(bgl);
    wgpuBufferDestroy(outb); wgpuBufferRelease(outb);
    wgpuBufferDestroy(stg); wgpuBufferRelease(stg);
  }
  wgpuBufferDestroy(nub); wgpuBufferRelease(nub);
  return out;
}

OwnedTarget MakeTarget(const plr::GpuCtx& g, uint32_t w, uint32_t h, WGPUTextureFormat f) {
  OwnedTarget t;
  WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
  td.dimension = WGPUTextureDimension_2D;
  td.size = WGPUExtent3D{w, h, 1};
  td.format = f;
  td.mipLevelCount = 1; td.sampleCount = 1;
  td.usage = (WGPUTextureUsage)(WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc);
  t.tex = wgpuDeviceCreateTexture(g.device, &td);
  WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
  t.view = wgpuTextureCreateView(t.tex, &vd);
  return t;
}

void ReleaseTarget(OwnedTarget* t) {
  if (t->view) wgpuTextureViewRelease(t->view);
  if (t->tex) { wgpuTextureDestroy(t->tex); wgpuTextureRelease(t->tex); }
  *t = OwnedTarget();
}

void Report::check(const char* name, bool ok, const std::string& detail) {
  std::printf("  %-4s %-60s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
  std::fflush(stdout);
  if (!ok) fail++;
}
void Report::skipped(const char* name, const std::string& why) {
  std::printf("  %-4s %-60s %s\n", "SKIP", name, why.c_str());
  std::fflush(stdout);
  skip++;
}
int Report::finish() {
  std::printf("\n==== %s ====\n", fail == 0 ? (skip ? "PASS (with skips)" : "ALL PASS") : "FAILED");
  return fail == 0 ? 0 : 1;
}

std::string Fmt(const char* fmt, ...) {
  char b[1024];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  return b;
}

}  // namespace pwlod_judges
