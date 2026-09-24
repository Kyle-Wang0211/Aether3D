// A deterministic sweep of selectVisible calls, shared by the host tests that
// must prove a change to select.cpp left the SELECTION untouched.
//
// SweepHash() hashes, for every call, everything a Selection returns EXCEPT
// lowestSpacing: the node list in order, numPoints, nodesConsidered, hitBudget,
// and -- for the streaming overload with a synthetic residency -- promoted and
// unloaded in order. The sweep: 400 poses (every third one orthographic, every
// seventh one standing just in front of a node) x minimumNodePixelSize
// {150, 30, 8.16, 1} x point budget {1M, 3.63M, 20M} x both overloads.
//
// Only API that existed before the change under test is used, so the same
// header compiles against the old select.{h,cpp} to produce the golden value.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>

#include "aether/pointcloud_lod/select.h"

namespace pwlod_sweep {

using namespace aether::pointcloud_lod;

inline void Mix(uint64_t* h, const void* p, size_t n) {
  const uint8_t* b = static_cast<const uint8_t*>(p);
  for (size_t i = 0; i < n; ++i) { *h ^= b[i]; *h *= 1099511628211ull; }
}

inline Camera SweepCamera(const Octree& oct, int i) {
  constexpr double kPi = 3.14159265358979323846;
  const Vec3 c = oct.nodes[0].box.center();
  const double R = oct.nodes[0].box.boundingSphereRadius();
  const double th = i * 0.137, k = 0.05 + (i % 40) * 0.1;
  Vec3 e{c.x + R * k * std::sin(th), c.y + R * 0.3 * std::cos(th * 1.7), c.z + R * k * std::cos(th)};
  Vec3 t{c.x + R * 0.2 * std::sin(th * 3), c.y, c.z};
  if (i % 7 == 0) {
    const Node& n = oct.nodes[(size_t)(i * 131) % oct.nodes.size()];
    t = n.box.center();
    e = t + Vec3{0, 0, n.box.boundingSphereRadius() * 3};
  }
  const int W = 1170, H = 2532;
  const double fov = 40 + (i % 5) * 10, zn = R * 1e-4, zf = R * 20;
  auto norm = [](Vec3 v) { const double l = v.length(); return l > 0 ? Vec3{v.x / l, v.y / l, v.z / l} : v; };
  auto cross = [](Vec3 a, Vec3 b) { return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; };
  auto dot = [](Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
  const Vec3 f = norm(t - e), s = norm(cross(f, {0, 1, 0})), u = cross(s, f);
  const double v[16] = {s.x, s.y, s.z, -dot(s, e), u.x, u.y, u.z, -dot(u, e),
                        -f.x, -f.y, -f.z, dot(f, e), 0, 0, 0, 1};
  double p[16] = {0};
  Camera cam;
  cam.position = e;
  cam.fovYDegrees = fov;
  cam.screenHeightPx = H;
  if (i % 3 == 1) {   // three.js Matrix4.makeOrthographic, WebGPU branch (D17 tests)
    const double oh = 2.0 * (t - e).length() * std::tan(fov * kPi / 360.0), ow = oh * W / H;
    p[0] = 2.0 / ow; p[5] = 2.0 / oh; p[10] = -1.0 / (zf - zn); p[11] = -zn / (zf - zn); p[15] = 1;
    cam.orthographic = true;
    cam.orthoWidth = ow;
    cam.orthoHeight = oh;
    cam.screenWidthPx = W;
  } else {
    const double tt = 1.0 / std::tan(fov * kPi / 360.0), a = double(W) / H;
    p[0] = tt / a; p[5] = tt; p[10] = zf / (zn - zf); p[11] = zn * zf / (zn - zf); p[14] = -1;
  }
  for (int r = 0; r < 4; r++)
    for (int cc = 0; cc < 4; cc++) {
      double acc = 0;
      for (int kk = 0; kk < 4; kk++) acc += p[r * 4 + kk] * v[kk * 4 + cc];
      cam.viewProj[r * 4 + cc] = acc;
    }
  return cam;
}

inline NodeState SyntheticState(int32_t n, void*) { return (NodeState)((n * 2654435761u >> 7) % 3); }

// visit(cam, params, selection, streaming) is called after every call (may be empty).
inline uint64_t SweepHash(const Octree& oct, long* calls,
                          const std::function<void(const Camera&, const SelectParams&, const Selection&, bool)>& visit = nullptr) {
  uint64_t h = 1469598103934665603ull;
  long n = 0;
  for (int i = 0; i < 400; ++i) {
    const Camera cam = SweepCamera(oct, i);
    for (double px : {150.0, 30.0, 8.16, 1.0})
      for (long long b : {1000000LL, 3630000LL, 20000000LL}) {
        SelectParams p;
        p.pointBudget = b;
        p.minimumNodePixelSize = px;
        const Selection s = selectVisible(oct, cam, p);
        Mix(&h, s.nodes.data(), s.nodes.size() * 4);
        Mix(&h, &s.numPoints, 8);
        Mix(&h, &s.nodesConsidered, 8);
        Mix(&h, &s.hitBudget, 1);
        if (visit) visit(cam, p, s, false);
        Residency r;
        r.state = &SyntheticState;
        const Selection s2 = selectVisible(oct, cam, p, r);
        Mix(&h, s2.nodes.data(), s2.nodes.size() * 4);
        Mix(&h, s2.promoted.data(), s2.promoted.size() * 4);
        Mix(&h, s2.unloaded.data(), s2.unloaded.size() * 4);
        Mix(&h, &s2.numPoints, 8);
        Mix(&h, &s2.nodesConsidered, 8);
        Mix(&h, &s2.hitBudget, 1);
        if (visit) visit(cam, p, s2, true);
        n += 2;
      }
  }
  *calls = n;
  return h;
}

}  // namespace pwlod_sweep
