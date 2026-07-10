// pose_hash_grid.h — streaming spatial hash over camera centers for
// O(1)-amortized insert + O(k)-average EXACT k-nearest queries.
//
// The streaming SfM front-end (aether_sfm_c.cc add_frame) matches each new
// frame against pose-nearest earlier frames to keep the match graph connected
// (prevents n_models>1 fragmentation). A brute-force nearest scan is O(N) per
// frame → O(N^2) over a capture; captures have NO frame cap, so this indexes
// the ARKit camera centers (metric world) in a uniform voxel hash instead.
//
// Correctness is independent of cell size: the k-nearest query expands cubic
// shells outward and stops only once the next unvisited shell cannot contain
// anything closer than the current k-th neighbour — so it returns the EXACT
// k nearest for ANY cell size (cell size affects speed, not the result). For
// a camera trajectory (continuous motion → roughly uniform center density)
// the query touches O(k) points on average.
//
// Header-only + templated on a center accessor so it carries no dependency on
// the caller's frame struct and can be unit-tested standalone
// (pose_hash_grid_test.cc) against a brute-force oracle.

#ifndef AETHER_POSE_HASH_GRID_H
#define AETHER_POSE_HASH_GRID_H

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <queue>
#include <unordered_map>
#include <vector>

#include <Eigen/Core>

namespace aether {

class PoseHashGrid {
 public:
  // cell: voxel edge length in the pose units (ARKit gravity world = metres).
  explicit PoseHashGrid(double cell) : cell_(cell), inv_(1.0 / cell) {}

  void insert(const Eigen::Vector3d& center, int frame) {
    cells_[keyOf(center)].push_back(frame);
    frames_.push_back(frame);  // flat list for the brute-force safety net
    ++count_;
  }

  int size() const { return count_; }

  // Shell radius past which we bail to a brute-force scan. A well-matched cell
  // size (≈ point spacing) prunes at r≈1-3, so this only trips on a
  // pathologically small cell (cell ≪ spacing → empty-shell blowup); then the
  // brute scan keeps the result EXACT and the cost bounded at O(N). Never
  // hangs, never wrong, regardless of scale.
  static constexpr int kMaxShell = 48;

  // Exact k frames nearest to q, nearest-first. `at(j)` returns frame j's
  // center (Eigen::Vector3d). Never returns more than were inserted.
  template <class CenterAt>
  std::vector<int> knn(const Eigen::Vector3d& q, int k, CenterAt at) const {
    std::vector<int> out;
    if (k <= 0 || count_ == 0) return out;
    const int cx = ci(q.x()), cy = ci(q.y()), cz = ci(q.z());
    // Max-heap (largest distance on top) capped at k → O(1) prune check.
    std::priority_queue<std::pair<double, int>> heap;
    int seen = 0;
    bool bail = false;
    for (int r = 0; r <= kMaxShell; ++r) {
      for (int dx = -r; dx <= r; ++dx) {
        for (int dy = -r; dy <= r; ++dy) {
          // Only the SURFACE of the cube of Chebyshev-radius r (shell): if
          // neither dx nor dy is at the extreme, dz must be ±r; else dz spans.
          const int adx = std::abs(dx), ady = std::abs(dy);
          const bool edge = (adx == r || ady == r);
          for (int dz = -r; dz <= r; ++dz) {
            if (!edge && std::abs(dz) != r) continue;
            const auto it = cells_.find(key(cx + dx, cy + dy, cz + dz));
            if (it == cells_.end()) continue;
            for (const int j : it->second) {
              const double d2 = (at(j) - q).squaredNorm();
              ++seen;
              if (static_cast<int>(heap.size()) < k) {
                heap.emplace(d2, j);
              } else if (d2 < heap.top().first) {
                heap.pop();
                heap.emplace(d2, j);
              }
            }
          }
        }
      }
      if (seen >= count_) break;  // scanned every inserted point → exact
      if (static_cast<int>(heap.size()) >= k) {
        // Min distance to any point in an unvisited shell (>= r+1) is r*cell.
        const double next_min = static_cast<double>(r) * cell_;
        if (next_min * next_min >= heap.top().first) break;  // can't be beaten
      }
      if (r == kMaxShell) bail = true;  // cell too fine — brute-force fallback
    }
    if (bail) {  // exact brute scan (bounded O(N)); shells never covered it all
      std::priority_queue<std::pair<double, int>> bh;
      for (const int j : frames_) {
        const double d2 = (at(j) - q).squaredNorm();
        if (static_cast<int>(bh.size()) < k) {
          bh.emplace(d2, j);
        } else if (d2 < bh.top().first) {
          bh.pop();
          bh.emplace(d2, j);
        }
      }
      heap.swap(bh);
    }
    out.resize(heap.size());
    for (int i = static_cast<int>(heap.size()) - 1; i >= 0; --i) {
      out[i] = heap.top().second;
      heap.pop();
    }
    return out;  // nearest first
  }

 private:
  double cell_, inv_;
  int count_ = 0;
  std::unordered_map<int64_t, std::vector<int>> cells_;
  std::vector<int> frames_;  // every inserted frame index (brute-force fallback)

  int ci(double v) const {
    return static_cast<int>(std::floor(v * inv_));
  }
  int64_t keyOf(const Eigen::Vector3d& c) const {
    return key(ci(c.x()), ci(c.y()), ci(c.z()));
  }
  // Pack three 21-bit signed cell indices (±2^20 range) into 63 bits.
  static int64_t key(int x, int y, int z) {
    const int64_t X = (static_cast<int64_t>(x) + (1 << 20)) & 0x1FFFFF;
    const int64_t Y = (static_cast<int64_t>(y) + (1 << 20)) & 0x1FFFFF;
    const int64_t Z = (static_cast<int64_t>(z) + (1 << 20)) & 0x1FFFFF;
    return (X << 42) | (Y << 21) | Z;
  }
};

}  // namespace aether

#endif  // AETHER_POSE_HASH_GRID_H
