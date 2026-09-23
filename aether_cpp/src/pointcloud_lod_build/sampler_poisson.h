// Portions of this file are derived from PotreeConverter 2.0
// (https://github.com/potree/PotreeConverter), used under this licence,
// reproduced verbatim as its clause 1 requires:
//
// Copyright 2020 Markus Schütz
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Port of PotreeConverter 2.0 @ 8bfad98 (BSD-2-Clause):
// Converter/include/sampler_poisson.h -- bottom-up Poisson-disk subsampling of a
// local octree. Each inner node takes, from the points of its children sorted by
// distance to the node centre, every point that is at least `spacing` away from
// all points it already took; the rest stay in the child. Points are MOVED, never
// copied (accepted + rejected == points of the children, :250-312).
//
// Changes (DEVIATIONS.md):
//   D11 `thread_local vector<Point> dbgAccepted(1'000'000)` (:113) is written
//       without a bounds check. It is replaced by a per-call vector that grows.
//       Reads are unchanged (only indices < dbgNumAccepted are ever read), so the
//       result is identical whenever upstream stays in bounds, and defined when it
//       would not.
//   D12 std::sort(std::execution::par_unseq, ...) (:183-204) -> std::sort(...).
//       Same comparator. The order among points at exactly equal distance is
//       unspecified in both; measured effect in DEVIATIONS.md.
//   D13 the per-node `seed` (:111) is computed but never used upstream; dropped.
//   D5  VBufferPool / VBuffer commit failures are reported (D2).
#pragma once

#include <algorithm>
#include <cmath>

#include "upstream_base.h"

namespace aether::pointcloud_lod_build::pc {

struct SamplerPoisson : public Sampler {
  ErrorState* error = nullptr;

  explicit SamplerPoisson(ErrorState* error_) : error(error_) {}

  // subsample a local octree from bottom up
  void sample(Node* node, Attributes attributes, double baseSpacing,
              function<void(Node*)> onNodeCompleted,
              function<void(Node*)> onNodeDiscarded) override {
    struct Point {
      double x;
      double y;
      double z;
      int32_t pointIndex;
      int32_t childIndex;
    };

    function<void(Node*, const function<void(Node*)>&)> traversePost =
        [&traversePost](Node* n, const function<void(Node*)>& callback) {
          for (auto child : n->children) {
            if (child != nullptr && !child->sampled) traversePost(child.get(), callback);
          }
          callback(n);
        };

    ErrorState* err = error;

    traversePost(node, [baseSpacing, &onNodeCompleted, &onNodeDiscarded, &attributes, err](Node* node_) {
      if (err->failed()) return;
      node_->sampled = true;

      auto scale = attributes.posScale;
      auto offset = attributes.posOffset;

      bool isLeaf = node_->isLeaf();
      if (isLeaf) return;

      // =================================================================
      // SAMPLING
      // =================================================================
      //
      // first, check for each point whether it's accepted or rejected
      // save result in an array with one element for each point

      int64_t numPointsInChildren = 0;
      for (auto child : node_->children) {
        if (child == nullptr) continue;
        numPointsInChildren += child->numPoints;
      }

      vector<Point> points;
      points.reserve(static_cast<size_t>(numPointsInChildren));

      vector<vector<int8_t>> acceptedChildPointFlags;
      vector<int64_t> numRejectedPerChild(8, 0);
      int64_t numAccepted = 0;

      for (int64_t childIndex = 0; childIndex < 8; childIndex++) {
        auto child = node_->children[static_cast<size_t>(childIndex)];

        if (child == nullptr) {
          acceptedChildPointFlags.push_back({});
          numRejectedPerChild.push_back({});
          continue;
        }

        vector<int8_t> acceptedFlags(static_cast<size_t>(child->numPoints), 0);
        acceptedChildPointFlags.push_back(acceptedFlags);

        for (int64_t i = 0; i < child->numPoints; i++) {
          int64_t pointOffset = i * attributes.bytes;
          int32_t xyz[3];
          std::memcpy(xyz, child->points->ptr + pointOffset, 12);

          double x = (xyz[0] * scale.x) + offset.x;
          double y = (xyz[1] * scale.y) + offset.y;
          double z = (xyz[2] * scale.z) + offset.z;

          Point point = {x, y, z, int32_t(i), int32_t(childIndex)};

          points.push_back(point);
        }
      }

      vector<Point> dbgAccepted;  // D11
      dbgAccepted.reserve(std::min<size_t>(points.size(), 1'000'000));
      int64_t dbgNumAccepted = 0;
      double spacing = baseSpacing / std::pow(2.0, double(node_->level()));
      double squaredSpacing = spacing * spacing;

      auto squaredDistance = [](const Point& a, const Point& b) {
        double dx = a.x - b.x;
        double dy = a.y - b.y;
        double dz = a.z - b.z;

        double dd = dx * dx + dy * dy + dz * dz;

        return dd;
      };

      auto center = (node_->min + node_->max) * 0.5;

      auto checkAccept = [&dbgAccepted, &dbgNumAccepted, spacing, squaredSpacing, &squaredDistance,
                          center](const Point& candidate) {
        auto cx = candidate.x - center.x;
        auto cy = candidate.y - center.y;
        auto cz = candidate.z - center.z;
        auto cdd = cx * cx + cy * cy + cz * cz;
        auto cd = std::sqrt(cdd);
        auto limit = (cd - spacing);
        auto limitSquared = limit * limit;

        int64_t j = 0;
        for (int64_t i = dbgNumAccepted - 1; i >= 0; i--) {
          auto& point = dbgAccepted[static_cast<size_t>(i)];

          // check distance to center
          auto px = point.x - center.x;
          auto py = point.y - center.y;
          auto pz = point.z - center.z;
          auto pdd = px * px + py * py + pz * pz;

          // stop when differences to center between candidate and accepted exceeds the spacing
          // any other previously accepted point will be even closer to the center.
          if (pdd < limitSquared) return true;

          double dd = squaredDistance(point, candidate);

          if (dd < squaredSpacing) return false;

          j++;

          // also put a limit at x distance checks
          if (j > 10'000) return true;
        }

        return true;
      };

      std::sort(points.begin(), points.end(), [center](const Point& a, const Point& b) -> bool {  // D12
        auto ax = a.x - center.x;
        auto ay = a.y - center.y;
        auto az = a.z - center.z;
        auto add = ax * ax + ay * ay + az * az;

        auto bx = b.x - center.x;
        auto by = b.y - center.y;
        auto bz = b.z - center.z;
        auto bdd = bx * bx + by * by + bz * bz;

        // sort by distance to center
        return add < bdd;
      });

      for (const Point& point : points) {
        bool isAccepted = checkAccept(point);

        if (isAccepted) {
          dbgAccepted.push_back(point);  // D11: was dbgAccepted[dbgNumAccepted] = point;
          dbgNumAccepted++;
          numAccepted++;
        } else {
          numRejectedPerChild[static_cast<size_t>(point.childIndex)]++;
        }

        acceptedChildPointFlags[static_cast<size_t>(point.childIndex)][static_cast<size_t>(point.pointIndex)] =
            isAccepted ? 1 : 0;
      }

      auto accepted = VBufferPool::acquire();
      if (!accepted->commit(numAccepted * attributes.bytes)) {
        err->fail("out of memory (sampler accepted)");
        return;
      }
      int64_t numAcceptedProcessed = 0;
      for (int64_t childIndex = 0; childIndex < 8; childIndex++) {
        auto child = node_->children[static_cast<size_t>(childIndex)];

        if (child == nullptr) continue;

        auto numRejected = numRejectedPerChild[static_cast<size_t>(childIndex)];
        auto& acceptedFlags = acceptedChildPointFlags[static_cast<size_t>(childIndex)];
        auto rejected = VBufferPool::acquire();
        if (!rejected->commit(numRejected * attributes.bytes)) {
          err->fail("out of memory (sampler rejected)");
          return;
        }
        int64_t numRejectedProcessed = 0;

        for (int64_t i = 0; i < child->numPoints; i++) {
          auto isAccepted = acceptedFlags[static_cast<size_t>(i)];
          int64_t pointOffset = i * attributes.bytes;

          if (isAccepted) {
            std::memcpy(accepted->ptr + numAcceptedProcessed * attributes.bytes,
                        child->points->ptr + pointOffset, static_cast<size_t>(attributes.bytes));
            numAcceptedProcessed++;
          } else {
            std::memcpy(rejected->ptr + numRejectedProcessed * attributes.bytes,
                        child->points->ptr + pointOffset, static_cast<size_t>(attributes.bytes));
            numRejectedProcessed++;
          }
        }

        // :289-310, including upstream's missing `else` after the first branch
        if (numRejected == 0 && child->isLeaf()) {
          onNodeDiscarded(child.get());

          node_->children[static_cast<size_t>(childIndex)] = nullptr;
        }
        if (numRejected > 0) {
          VBufferPool::release(child->points);
          child->points = rejected;
          child->numPoints = numRejected;

          onNodeCompleted(child.get());
        } else if (numRejected == 0) {
          // the parent has taken all points from this child,
          // so make this child an empty inner node.
          // Otherwise, the hierarchy file will claim that
          // this node has points but because it doesn't have any,
          // decompressing the nonexistent point buffer fails
          // https://github.com/potree/potree/issues/1125
          VBufferPool::release(child->points);
          child->points = nullptr;
          child->numPoints = 0;
          onNodeCompleted(child.get());
        }
      }

      VBufferPool::release(node_->points);
      node_->points = accepted;
      node_->numPoints = numAccepted;
    });
  }
};

}  // namespace aether::pointcloud_lod_build::pc
