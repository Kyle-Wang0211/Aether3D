// Per-frame LOD selection + the adaptive point-budget controller.
//
// Pure C++ (C++17 or later). No graphics API, no vendor API, no platform #ifdef.
//
// Replicated, not invented:
//   selection   potree/src/Potree_update_visibility.js
//                 :40      priority queue ordered by 1/weight
//                 :175-182 visibility gate, and "level <= 2 is always visible"
//                 :282-283 hard break once the budget would be exceeded
//                 :352-381 node weight = screen-space pixel radius
//               potree/src/Potree.js:101          pointBudget = 1'000'000
//               potree/src/PointCloudOctree.js:113 minimumNodePixelSize = 150
//   frustum     three.js src/math/Frustum.js:95-135 (setFromProjectionMatrix)
//               three.js src/math/Frustum.js:230-252 (intersectsBox)
//               NOTE: the WebGPU branch (:124) is used -- clip z in [0,1].
//   controller  CesiumJS Cesium3DTileset.js:3005-3037
//                 multiplicative *1.02 / /1.02 with a clamp.
//               Deviation D10: the error signal is frame time, not memory.
#pragma once

#include <cstdint>
#include <limits>
#include <vector>

#include "aether/pointcloud_lod/octree.h"

namespace aether::pointcloud_lod {

struct Plane { double nx, ny, nz, d; };

struct Frustum {
  Plane planes[6];
  bool intersectsBox(const Box3& b) const;
};

// `viewProj` is ROW-MAJOR: viewProj[r * 4 + c]. World space -> clip space.
Frustum frustumFromViewProjectionWebGPU(const double viewProj[16]);

struct Camera {
  Vec3 position;            // in the point cloud's own coordinate space
  double viewProj[16]{};    // row-major
  double fovYDegrees = 60;  // vertical field of view
  int screenHeightPx = 1080;
};

struct SelectParams {
  int64_t pointBudget = 1000 * 1000;   // Potree.js:101
  double minimumNodePixelSize = 150.0; // PointCloudOctree.js:113
  int maxLevel = std::numeric_limits<int>::max();
};

struct Selection {
  std::vector<int32_t> nodes;   // accepted nodes, most important first
  int64_t numPoints = 0;
  int64_t nodesConsidered = 0;
  double lowestSpacing = std::numeric_limits<double>::infinity();
  bool hitBudget = false;       // true if the budget break stopped the walk

  // Filled only by the streaming overload below (empty otherwise).
  // `nodes` then holds only nodes that are drawable this frame.
  std::vector<int32_t> promoted;  // Loaded -> Drawable this frame (<= maxPromotionsPerFrame), also in `nodes`
  std::vector<int32_t> unloaded;  // Potree's unloadedGeometry, priority order: hand to AsyncNodeLoader::request
};

Selection selectVisible(const Octree& oct, const Camera& cam, const SelectParams& p);

// ---------------------------------------------------------------------------
// Streaming selection: Potree's updateVisibility with its node states.
//
//   potree/src/Potree_update_visibility.js @ 5636cd471d9eb464969e758be45c44d7613d3859
//     :122      loadedToGPUThisFrame = 0
//     :299-307  a geometry node whose parent is a tree node is promoted to a
//               tree node if it is loaded and fewer than 2 were promoted this
//               frame; otherwise it goes to unloadedGeometry
//     :309-315  only tree nodes are drawn (visibleNodes)
//     :347-393  children are pushed for EVERY visible node, loaded or not, so
//               the point budget accounts for the whole visible cut
//
// Why nothing is ever a hole: a node can only become drawable while its parent
// is drawable (:299), and Potree's octree is additive -- a parent's points are
// a subsample of its whole subtree, drawn alongside the children. While a child
// is still loading, its region is covered by the parent's (coarser) points that
// are already on screen; the frame loses density there, never coverage.
enum class NodeState : uint8_t {
  Unloaded = 0,  // !isLoaded()                        (OctreeGeometry.js:44-46)
  Loaded = 1,    // isGeometryNode() && isLoaded()     -- decoded, not yet on the GPU
  Drawable = 2,  // isTreeNode()                       -- on the GPU (PointCloudOctree.js:205 toTreeNode)
};

using NodeStateFn = NodeState (*)(int32_t node, void* ctx);

struct Residency {
  NodeStateFn state = nullptr;     // required
  void* ctx = nullptr;
  int maxPromotionsPerFrame = 2;   // Potree_update_visibility.js:300 `loadedToGPUThisFrame < 2`
};

// The caller must actually upload `promoted` this frame: the returned `nodes`
// already treat them as drawable, exactly as Potree does after toTreeNode (:301).
Selection selectVisible(const Octree& oct, const Camera& cam, const SelectParams& p,
                        const Residency& residency);

// ---------------------------------------------------------------------------
// Adaptive quality. CesiumJS's controller shape with frame time as the signal.
//
// Cesium adjusts a screen-space ERROR THRESHOLD and treats memory as a ceiling
// (Cesium3DTileset.js:3005-3037). We do the same: the controller moves
// `minimumNodePixelSize` -- Potree's analogue of that threshold -- and the point
// budget is only a hard ceiling. Measured A/B (test_ab_knob) on both a 36M and a
// 216M cloud: driving the threshold beats driving the budget at 10 of 12
// viewpoints and ties at the other 2, at the same 30 fps. Driving the budget
// leaves up to 98% of the frame unused at moderate distances (39,558 points in
// 0.6 ms of a 33.3 ms frame) because the fixed 150 px stops the descent long
// before the budget binds.
class QualityController {
 public:
  struct Config {
    double targetFrameMs = 1000.0 / 30.0;  // the requirement: stable 30 fps
    double step = 1.02;                    // Cesium3DTileset.js:3023, 3032
    // A node smaller than 1 screen pixel is not worth a draw; 4000 px is
    // effectively "root only" on any phone.
    double minPixelSize = 1.0;
    double maxPixelSize = 4000.0;
    // Grow quality only with real headroom, so the loop does not oscillate.
    double growBelowFraction = 0.85;
  };

  // Two overloads rather than a defaulted Config parameter: a default argument
  // of `Config{}` would need Config complete inside its own enclosing class.
  explicit QualityController() : px_(150.0), cfg_() {}          // Potree's start
  explicit QualityController(const Config& cfg) : px_(150.0), cfg_(cfg) {}

  // Feed the measured duration of the frame just rendered; returns the
  // minimumNodePixelSize to use for the next one.
  double onFrame(double frameMs);
  double pixelSize() const { return px_; }

 private:
  double px_;
  Config cfg_;
};

}  // namespace aether::pointcloud_lod
