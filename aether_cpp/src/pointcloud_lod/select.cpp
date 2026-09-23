#include "aether/pointcloud_lod/select.h"

#include <algorithm>
#include <cmath>
#include <queue>

namespace aether::pointcloud_lod {
namespace {

// M_PI is a POSIX extension, not ISO C++; spell it out for every toolchain.
constexpr double kPi = 3.14159265358979323846;

Plane normalized(double nx, double ny, double nz, double d) {
  const double len = std::sqrt(nx * nx + ny * ny + nz * nz);
  if (len == 0.0) return {0, 0, 0, 0};
  return {nx / len, ny / len, nz / len, d / len};
}

double distanceToPoint(const Plane& p, double x, double y, double z) {
  return p.nx * x + p.ny * y + p.nz * z + p.d;
}

}  // namespace

// three.js Frustum.js:230-252.
bool Frustum::intersectsBox(const Box3& b) const {
  for (const auto& p : planes) {
    // corner at max distance
    const double x = p.nx > 0 ? b.max.x : b.min.x;
    const double y = p.ny > 0 ? b.max.y : b.min.y;
    const double z = p.nz > 0 ? b.max.z : b.min.z;
    if (distanceToPoint(p, x, y, z) < 0) return false;
  }
  return true;
}

// three.js Frustum.js:95-135, WebGPUCoordinateSystem branch (:124).
// three.js stores column-major; this takes ROW-MAJOR, so m[r*4+c] here is
// three.js's me[c*4+r]. Written out with row/column names to keep it checkable.
Frustum frustumFromViewProjectionWebGPU(const double m[16]) {
  auto R = [&](int r, int c) { return m[r * 4 + c]; };
  Frustum f;
  // planes[0] right, [1] left, [2] bottom, [3] top, [4] far, [5] near
  f.planes[0] = normalized(R(3,0)-R(0,0), R(3,1)-R(0,1), R(3,2)-R(0,2), R(3,3)-R(0,3));
  f.planes[1] = normalized(R(3,0)+R(0,0), R(3,1)+R(0,1), R(3,2)+R(0,2), R(3,3)+R(0,3));
  f.planes[2] = normalized(R(3,0)+R(1,0), R(3,1)+R(1,1), R(3,2)+R(1,2), R(3,3)+R(1,3));
  f.planes[3] = normalized(R(3,0)-R(1,0), R(3,1)-R(1,1), R(3,2)-R(1,2), R(3,3)-R(1,3));
  f.planes[4] = normalized(R(3,0)-R(2,0), R(3,1)-R(2,1), R(3,2)-R(2,2), R(3,3)-R(2,3));
  // WebGPU clip space has z in [0,1], so the near plane is row 2 alone.
  f.planes[5] = normalized(R(2,0), R(2,1), R(2,2), R(2,3));
  return f;
}

namespace {

// One walk for both overloads. `res == nullptr` is the original (non-streaming)
// behaviour: every node counts as a tree node, nothing is promoted or queued.
Selection selectImpl(const Octree& oct, const Camera& cam, const SelectParams& p,
                     const Residency* res) {
  Selection out;
  if (oct.nodes.empty()) return out;

  const Frustum frustum = frustumFromViewProjectionWebGPU(cam.viewProj);

  struct Item {
    int32_t node;
    double weight;
    bool parentDrawable;   // Potree carries `parent` in the element (:161) for the :299 test
    bool operator<(const Item& o) const { return weight < o.weight; }  // max-heap
  };
  // Potree_update_visibility.js:40 -- ordered by 1/weight, i.e. largest first.
  std::priority_queue<Item> pq;
  pq.push({0, std::numeric_limits<double>::max(), true});  // :79 root gets MAX_VALUE; :299 `!parent`
  int loadedToGPUThisFrame = 0;                              // :122

  const double fovRad = cam.fovYDegrees * kPi / 180.0;   // :368
  const double slope = std::tan(fovRad / 2.0);            // :369
  const double halfH = 0.5 * static_cast<double>(cam.screenHeightPx);

  while (!pq.empty()) {
    const Item it = pq.top();
    pq.pop();
    const Node& node = oct.nodes[static_cast<size_t>(it.node)];
    out.nodesConsidered++;

    // Potree_update_visibility.js:175-182
    const bool insideFrustum = frustum.intersectsBox(node.box);
    bool visible = insideFrustum;
    visible = visible && !(out.numPoints + node.numPoints > p.pointBudget);
    visible = visible && node.level < p.maxLevel;
    visible = visible || node.level <= 2;   // :182 -- the first three levels are pinned

    // :282-283 -- hard stop, before the visibility test.
    if (out.numPoints + node.numPoints > p.pointBudget) {
      out.hitBudget = true;
      break;
    }
    if (!visible) continue;

    if (node.spacing > 0) out.lowestSpacing = std::min(out.lowestSpacing, node.spacing);

    out.numPoints += node.numPoints;

    // :299-309 -- which visible nodes are actually drawn this frame.
    bool drawable = true;
    if (res) {
      const NodeState st = res->state(it.node, res->ctx);
      drawable = (st == NodeState::Drawable);
      if (!drawable && it.parentDrawable) {                       // :299
        if (st == NodeState::Loaded && loadedToGPUThisFrame < res->maxPromotionsPerFrame) {  // :300
          drawable = true;                                        // :301 toTreeNode
          loadedToGPUThisFrame++;                                 // :302
          out.promoted.push_back(it.node);
        } else {
          out.unloaded.push_back(it.node);                        // :304
        }
      }
    }
    if (drawable && node.numPoints > 0) out.nodes.push_back(it.node);   // :309-315

    // :347-392 -- push children with their screen-space weight.
    for (int c = 0; c < 8; c++) {
      const int32_t ci = node.children[c];
      if (ci < 0) continue;
      const Node& child = oct.nodes[static_cast<size_t>(ci)];

      const Vec3 center = child.box.center();
      const double dx = cam.position.x - center.x;
      const double dy = cam.position.y - center.y;
      const double dz = cam.position.z - center.z;
      const double distance = std::sqrt(dx * dx + dy * dy + dz * dz);
      const double radius = child.box.boundingSphereRadius();

      const double projFactor = halfH / (slope * distance);   // :370
      const double screenPixelRadius = radius * projFactor;   // :371

      if (screenPixelRadius < p.minimumNodePixelSize) continue;  // :373-375

      double weight = screenPixelRadius;                      // :377
      if (distance - radius < 0) weight = std::numeric_limits<double>::max();  // :379-381

      pq.push({ci, weight, drawable});   // :392 -- pushed whether or not `node` is drawn
    }
  }
  return out;
}

}  // namespace

Selection selectVisible(const Octree& oct, const Camera& cam, const SelectParams& p) {
  return selectImpl(oct, cam, p, nullptr);
}

Selection selectVisible(const Octree& oct, const Camera& cam, const SelectParams& p,
                        const Residency& residency) {
  if (!residency.state) return Selection{};
  return selectImpl(oct, cam, p, &residency);
}

// CesiumJS Cesium3DTileset.js:3005-3037, with frame time as the error signal
// in place of memory (deviation D10). Step and clamp are Cesium's.
double QualityController::onFrame(double frameMs) {
  if (frameMs > cfg_.targetFrameMs) {
    // too slow -> coarser, the shape of increaseScreenSpaceError (:3023)
    px_ = std::min(px_ * cfg_.step, cfg_.maxPixelSize);
  } else if (frameMs < cfg_.targetFrameMs * cfg_.growBelowFraction) {
    // headroom -> finer, the shape of decreaseScreenSpaceError (:3032-3034)
    px_ = std::max(px_ / cfg_.step, cfg_.minPixelSize);
  }
  return px_;
}

}  // namespace aether::pointcloud_lod
