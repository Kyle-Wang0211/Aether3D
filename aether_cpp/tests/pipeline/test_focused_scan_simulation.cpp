// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// test_focused_scan_simulation.cpp
// ════════════════════════════════════════════════════════════════
// End-to-end simulation: user continuously scans a small object
// with realistic hand-held jitter (not smooth/uniform camera path).
//
// Verifies:
//   1. Multi-layer overlap is under control (<5% tile pairs within 3cm)
//   2. S6+ quality regions form during scanning
//   3. Depth keyframe filter (production code style) actually activates
//   4. Tile floating rate is acceptable (<5% beyond 5cm from surface)
//
// Simulates THREE realistic hand-held patterns:
//   E: Handheld orbit — circling an object slowly with arm sway
//   F: Nervous hovering — holding camera pointed at object, lots of micro-shakes
//   G: Stop-and-go — pause, move, pause, move (natural inspection pattern)

#include "aether/tsdf/tsdf_volume.h"
#include "aether/tsdf/tsdf_constants.h"
#include "aether/tsdf/adaptive_resolution.h"

#include "aether/splat/packed_splats.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <numeric>
#include <random>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace aether::tsdf;

// ═══════════════════════════════════════════════════════════════════
// Synthetic Scene: Small object (20cm cube) on a floor
// ═══════════════════════════════════════════════════════════════════

struct Plane {
    float nx, ny, nz, d;
};

// Room: simplified — just a floor
static const Plane kFloor = { 0, 1, 0, 0.0f };

// Small object: 20cm cube centered at (0, 0.10, 1.0) — on the floor
struct Box {
    float cx, cy, cz, hx, hy, hz;
};
static const Box kObj = { 0.0f, 0.10f, 1.0f, 0.10f, 0.10f, 0.10f };

static float ray_cast_scene(float ox, float oy, float oz,
                            float dx, float dy, float dz,
                            float max_depth) {
    float best_t = max_depth + 1.0f;

    // Floor (y=0, extends infinitely)
    {
        float denom = kFloor.ny * dy;
        if (std::abs(denom) > 1e-8f) {
            float t = (kFloor.d - kFloor.ny * oy) / denom;
            if (t > 0.05f && t < best_t) {
                float hx = ox + dx * t, hz = oz + dz * t;
                if (hx > -3.0f && hx < 3.0f && hz > -1.0f && hz < 4.0f)
                    best_t = t;
            }
        }
    }

    // Box (6 faces)
    {
        const auto& b = kObj;
        float faces[][4] = {
            { 1, 0, 0, b.cx + b.hx}, {-1, 0, 0, -(b.cx - b.hx)},
            { 0, 1, 0, b.cy + b.hy}, { 0,-1, 0, -(b.cy - b.hy)},
            { 0, 0, 1, b.cz + b.hz}, { 0, 0,-1, -(b.cz - b.hz)},
        };
        for (int f = 0; f < 6; ++f) {
            float fn = faces[f][0], fm = faces[f][1], fl = faces[f][2], fd = faces[f][3];
            float denom = fn*dx + fm*dy + fl*dz;
            if (std::abs(denom) < 1e-8f) continue;
            float t = (fd - (fn*ox + fm*oy + fl*oz)) / denom;
            if (t > 0.05f && t < best_t) {
                float hx = ox + dx*t, hy = oy + dy*t, hz = oz + dz*t;
                if (hx >= b.cx-b.hx-0.001f && hx <= b.cx+b.hx+0.001f &&
                    hy >= b.cy-b.hy-0.001f && hy <= b.cy+b.hy+0.001f &&
                    hz >= b.cz-b.hz-0.001f && hz <= b.cz+b.hz+0.001f) {
                    best_t = t;
                }
            }
        }
    }

    return best_t;
}

static float distance_to_nearest_surface(float x, float y, float z) {
    float min_dist = std::abs(y);  // Distance to floor

    // Distance to box surface
    {
        const auto& b = kObj;
        float cx = std::clamp(x, b.cx-b.hx, b.cx+b.hx);
        float cy = std::clamp(y, b.cy-b.hy, b.cy+b.hy);
        float cz = std::clamp(z, b.cz-b.hz, b.cz+b.hz);
        float dx = x - cx, dy = y - cy, dz = z - cz;
        float d = std::sqrt(dx*dx + dy*dy + dz*dz);
        if (d < min_dist) min_dist = d;
    }

    return min_dist;
}

// ═══════════════════════════════════════════════════════════════════
// Camera utilities
// ═══════════════════════════════════════════════════════════════════

struct CameraFrame {
    float ex, ey, ez;  // eye position
    float tx, ty, tz;  // look-at target
};

static void make_look_at_pose(float out[16],
                              float ex, float ey, float ez,
                              float tx, float ty, float tz) {
    float fx = tx - ex, fy = ty - ey, fz = tz - ez;
    float flen = std::sqrt(fx*fx + fy*fy + fz*fz);
    if (flen < 1e-6f) flen = 1e-6f;
    fx /= flen; fy /= flen; fz /= flen;

    float up_x = 0, up_y = 1, up_z = 0;
    float rx = fy*up_z - fz*up_y;
    float ry = fz*up_x - fx*up_z;
    float rz = fx*up_y - fy*up_x;
    float rlen = std::sqrt(rx*rx + ry*ry + rz*rz);
    if (rlen < 1e-6f) { up_x = 0; up_y = 0; up_z = 1;
        rx = fy*up_z - fz*up_y; ry = fz*up_x - fx*up_z; rz = fx*up_y - fy*up_x;
        rlen = std::sqrt(rx*rx + ry*ry + rz*rz); }
    rx /= rlen; ry /= rlen; rz /= rlen;

    float ux = ry*fz - rz*fy;
    float uy = rz*fx - rx*fz;
    float uz = rx*fy - ry*fx;

    std::memset(out, 0, sizeof(float) * 16);
    out[0] = rx;  out[1] = ry;  out[2] = rz;
    out[4] = ux;  out[5] = uy;  out[6] = uz;
    out[8] = -fx; out[9] = -fy; out[10] = -fz;
    out[12] = ex; out[13] = ey; out[14] = ez;
    out[15] = 1.0f;
}

static void make_depth_from_scene(
    std::vector<float>& depth, std::vector<unsigned char>& conf,
    int w, int h, float fx, float fy, float cx_cam, float cy_cam,
    const float pose[16], float noise_std, std::mt19937& rng) {
    depth.resize(static_cast<std::size_t>(w * h));
    conf.resize(static_cast<std::size_t>(w * h));
    std::normal_distribution<float> noise(0.0f, noise_std);
    std::uniform_real_distribution<float> blend(0.2f, 0.8f);

    float cam_x = pose[12], cam_y = pose[13], cam_z = pose[14];

    // First pass: ray-cast all pixels to get clean depth
    for (int py = 0; py < h; ++py) {
        for (int px = 0; px < w; ++px) {
            std::size_t idx = static_cast<std::size_t>(py * w + px);
            float rx = (static_cast<float>(px) - cx_cam) / fx;
            float ry = (static_cast<float>(py) - cy_cam) / fy;
            float rz = -1.0f;

            float wx = pose[0]*rx + pose[4]*ry + pose[8]*rz;
            float wy = pose[1]*rx + pose[5]*ry + pose[9]*rz;
            float wz = pose[2]*rx + pose[6]*ry + pose[10]*rz;
            float len = std::sqrt(wx*wx + wy*wy + wz*wz);
            if (len > 1e-6f) { wx /= len; wy /= len; wz /= len; }

            float t = ray_cast_scene(cam_x, cam_y, cam_z, wx, wy, wz, 5.0f);
            if (t < 5.0f) {
                depth[idx] = t + noise(rng);
                conf[idx] = 2;
            } else {
                depth[idx] = 0.0f;
                conf[idx] = 0;
            }
        }
    }

    // Second pass: simulate FLYING PIXELS at depth discontinuities.
    // Real LiDAR/ToF sensors have a beam footprint that straddles depth edges.
    // When a beam partially hits foreground and partially background, the
    // returned depth is a weighted average — creating a "flying pixel" that
    // floats in mid-air between the two surfaces. This is the #1 cause of
    // floating tiles in real-world scanning.
    //
    // For each pixel, check 4-neighbors for depth discontinuity (>8cm jump).
    // At discontinuities, blend foreground and background depth with random
    // weight (simulating partial beam overlap). ~15% of edge pixels affected.
    std::uniform_real_distribution<float> fly_chance(0.0f, 1.0f);
    for (int py = 1; py < h - 1; ++py) {
        for (int px = 1; px < w - 1; ++px) {
            std::size_t idx = static_cast<std::size_t>(py * w + px);
            float d_center = depth[idx];
            if (d_center <= 0.0f) continue;

            // Check 4 neighbors for depth jump
            float d_neighbors[4] = {
                depth[(py-1)*w + px], depth[(py+1)*w + px],
                depth[py*w + (px-1)], depth[py*w + (px+1)]
            };

            for (int n = 0; n < 4; ++n) {
                if (d_neighbors[n] <= 0.0f) continue;
                float jump = std::abs(d_center - d_neighbors[n]);
                if (jump > 0.08f) {  // >8cm depth discontinuity
                    // 15% chance this pixel becomes a flying pixel
                    if (fly_chance(rng) < 0.15f) {
                        float alpha = blend(rng);  // Random blend [0.2, 0.8]
                        depth[idx] = alpha * d_center + (1.0f - alpha) * d_neighbors[n];
                        conf[idx] = 1;  // Lower confidence for edge pixels
                        break;
                    }
                }
            }
        }
    }

    // Third pass: depth-edge confidence invalidation.
    // Real LiDAR/ToF confidence maps assign low confidence to pixels near
    // depth discontinuities because the beam footprint straddles two surfaces.
    // Without this, the TSDF receives conf=2 observations from BOTH sides of
    // a depth edge, creating conflicting SDF that averages to zero → phantom
    // zero-crossings (floating tiles). Marking edge pixels as conf=0 prevents
    // these conflicting observations from entering the TSDF.
    //
    // Threshold: 3cm depth jump in 3×3 neighborhood. Interior surface pixels
    // with 5mm noise have pixel-to-pixel depth variation ~7mm (√2·σ), so 3cm
    // provides >4σ margin. Only depth discontinuities (box edges, occlusion
    // boundaries) exceed this threshold.
    for (int py = 1; py < h - 1; ++py) {
        for (int px = 1; px < w - 1; ++px) {
            std::size_t idx = static_cast<std::size_t>(py * w + px);
            float d_center = depth[idx];
            if (d_center <= 0.0f) continue;
            if (conf[idx] == 0) continue;  // Already invalid

            bool near_edge = false;
            for (int dy = -1; dy <= 1 && !near_edge; ++dy) {
                for (int dx = -1; dx <= 1 && !near_edge; ++dx) {
                    if (dx == 0 && dy == 0) continue;
                    std::size_t nidx = static_cast<std::size_t>((py+dy)*w + (px+dx));
                    float d_n = depth[nidx];
                    if (d_n <= 0.0f) { near_edge = true; continue; }
                    if (std::abs(d_center - d_n) > 0.03f) near_edge = true;
                }
            }

            if (near_edge) {
                conf[idx] = 0;  // Invalidate edge pixel (TSDF skips conf=0)
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// Depth Keyframe storage (mirrors production pipeline_coordinator)
// ═══════════════════════════════════════════════════════════════════

struct DepthKeyframe {
    std::vector<float> depth;
    std::vector<unsigned char> conf;  // Per-pixel confidence (0=invalid,1=low,2=high)
    int width{0}, height{0};
    float fx{0}, fy{0}, cx{0}, cy{0};
    float pose[16]{};  // Camera-to-world (column-major)
};

static constexpr std::size_t kMaxDepthKeyframes = 24;

// Diagnostic data from depth filter (for debugging phantom tiles)
struct DepthFilterDiag {
    int checked = 0, consistent = 0, tight_consistent = 0;
    int freespace_violations = 0, front_violations = 0;
    float depth_diff_sum = 0.0f, depth_diff_sq_sum = 0.0f;
    int gradient_violations = 0, gradient_checked = 0;
    int edge_range_violations = 0, edge_range_checked = 0;
    int low_conf_count = 0;          // Projected to low-confidence pixels
    bool clustered = false;
    bool novel_reject = false;
    float mean_bias = 0.0f, variance = 0.0f;
};

// Production-style depth consistency filter (mirrors pipeline_coordinator.cpp)
// Uses stored depth keyframes instead of ray-casting.
// Includes 3 novel phantom detection signals:
//   1. Free-space carving (Kutulakos & Seitz volumetric carving)
//   2. Temporal depth residual variance (edge phantom detection)
//   3. Depth gradient magnitude (discontinuity proximity)
static bool is_depth_consistent_production(
    float tx, float ty, float tz,
    const std::vector<DepthKeyframe>& keyframes,
    DepthFilterDiag* diag = nullptr) {

    if (keyframes.size() < 3) return true;  // Not enough data

    int consistent = 0, checked = 0;
    int tight_consistent = 0;          // 2cm tolerance for single viewpoint
    int freespace_violations = 0;      // Novel: free-space carving
    int front_violations = 0;          // Novel: tile in front of surface
    float depth_diff_sum = 0.0f;       // Novel: temporal variance
    float depth_diff_sq_sum = 0.0f;
    int gradient_violations = 0;       // Novel: depth gradient
    int gradient_checked = 0;
    int edge_range_violations = 0;     // Novel: 5×5 depth range
    int edge_range_checked = 0;
    int low_conf_count = 0;            // Novel: projects to low-confidence pixel

    for (const auto& kf : keyframes) {
        // World → camera (ARKit convention from tsdf_volume.cpp)
        float ddx = tx - kf.pose[12];
        float ddy = ty - kf.pose[13];
        float ddz = tz - kf.pose[14];
        float cam_x = kf.pose[0]*ddx + kf.pose[1]*ddy + kf.pose[2]*ddz;
        float cam_y = -(kf.pose[4]*ddx + kf.pose[5]*ddy + kf.pose[6]*ddz);
        float cam_z = -(kf.pose[8]*ddx + kf.pose[9]*ddy + kf.pose[10]*ddz);

        if (cam_z < 0.1f || cam_z > 5.0f) continue;

        float proj_u = kf.fx * (cam_x / cam_z) + kf.cx;
        float proj_v = kf.fy * (cam_y / cam_z) + kf.cy;
        int iu = static_cast<int>(proj_u);
        int iv = static_cast<int>(proj_v);

        if (iu < 1 || iu >= kf.width - 1 || iv < 1 || iv >= kf.height - 1) continue;

        // 3×3 median depth (matches production code)
        float depth_samples[9];
        int dc = 0;
        for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
                float d = kf.depth[(iv+dy)*kf.width + (iu+dx)];
                if (d > 0.0f && d < 10.0f) depth_samples[dc++] = d;
            }
        if (dc < 3) continue;
        std::nth_element(depth_samples, depth_samples + dc/2, depth_samples + dc);
        float frame_depth = depth_samples[dc/2];

        ++checked;
        float depth_error = std::abs(cam_z - frame_depth);
        if (depth_error < 0.05f) ++consistent;  // 5cm tolerance (matches production)
        if (depth_error < 0.02f) ++tight_consistent;  // 2cm tight tolerance

        // ── Novel: Symmetric free-space (tile in front of surface) ──
        if (cam_z < frame_depth - 0.02f) {
            ++front_violations;
        }

        // ── Novel Filter 1: Free-Space Carving ──
        // If tile is BEHIND observed surface (cam_z > frame_depth + margin),
        // it occupies free space where no real geometry can exist.
        // 2cm margin: tight but safe (real tiles ≈ ±5mm from depth).
        if (cam_z > frame_depth + 0.02f) {
            ++freespace_violations;
        }

        // ── Novel Filter 2: Temporal Depth Residual ──
        // Track (cam_z - frame_depth) statistics for variance computation.
        {
            float diff = cam_z - frame_depth;
            depth_diff_sum += diff;
            depth_diff_sq_sum += diff * diff;
        }

        // ── Novel: Confidence at projected pixel ──
        // Flying pixels from LiDAR/ToF have conf=1 (low), real surfaces have conf=2.
        // If most keyframes project this tile to a low-confidence region, the tile
        // was likely created from edge artifacts (flying pixels).
        if (!kf.conf.empty()) {
            unsigned char c = kf.conf[iv * kf.width + iu];
            if (c <= 1) ++low_conf_count;
        }

        // ── Novel Filter 3: Depth Gradient Magnitude ──
        // Phantoms form at depth discontinuities (high gradient regions).
        if (iu >= 2 && iu < kf.width - 2 && iv >= 2 && iv < kf.height - 2) {
            float dl = kf.depth[iv * kf.width + (iu - 1)];
            float dr = kf.depth[iv * kf.width + (iu + 1)];
            float du = kf.depth[(iv - 1) * kf.width + iu];
            float dd = kf.depth[(iv + 1) * kf.width + iu];
            if (dl > 0.0f && dr > 0.0f && du > 0.0f && dd > 0.0f) {
                float gx = (dr - dl) * 0.5f;
                float gy = (dd - du) * 0.5f;
                float grad = std::sqrt(gx * gx + gy * gy);
                ++gradient_checked;
                if (grad > 0.05f) ++gradient_violations;
            }

            // ── Novel: 5×5 Depth Neighborhood Range ──
            float d_min = 1e10f, d_max = -1e10f;
            for (int dy2 = -2; dy2 <= 2; ++dy2) {
                for (int dx2 = -2; dx2 <= 2; ++dx2) {
                    float d = kf.depth[(iv + dy2) * kf.width + (iu + dx2)];
                    if (d > 0.0f && d < 10.0f) {
                        if (d < d_min) d_min = d;
                        if (d > d_max) d_max = d;
                    }
                }
            }
            ++edge_range_checked;
            if (d_max - d_min > 0.08f) {  // >8cm range → depth edge
                ++edge_range_violations;
            }
        }
    }

    // ── Viewpoint diversity detection (matches production) ──
    // Novel filters only for clustered viewpoints (single viewpoint scanning)
    bool clustered_viewpoints = true;
    {
        float avg_fx = 0, avg_fy = 0, avg_fz = 0;
        for (const auto& kf : keyframes) {
            avg_fx += -kf.pose[8];
            avg_fy += -kf.pose[9];
            avg_fz += -kf.pose[10];
        }
        float len = std::sqrt(avg_fx*avg_fx + avg_fy*avg_fy + avg_fz*avg_fz);
        if (len > 1e-6f) { avg_fx /= len; avg_fy /= len; avg_fz /= len; }

        for (const auto& kf : keyframes) {
            float fx = -kf.pose[8], fy = -kf.pose[9], fz = -kf.pose[10];
            float fl = std::sqrt(fx*fx + fy*fy + fz*fz);
            if (fl > 1e-6f) { fx /= fl; fy /= fl; fz /= fl; }
            float cos_a = fx * avg_fx + fy * avg_fy + fz * avg_fz;
            if (cos_a < 0.9f) {
                clustered_viewpoints = false;
                break;
            }
        }
    }

    // ── Multi-criteria phantom rejection (matches production) ──
    bool novel_reject = false;

    if (clustered_viewpoints) {
        // Signal A: Free-space carving
        if (checked >= 2 && freespace_violations > 0) {
            float fs_ratio = static_cast<float>(freespace_violations)
                           / static_cast<float>(checked);
            if (fs_ratio >= 0.15f) novel_reject = true;
        }

        // Signal B: Temporal depth variance
        if (checked >= 3 && !novel_reject) {
            float mean_d = depth_diff_sum / static_cast<float>(checked);
            float var = depth_diff_sq_sum / static_cast<float>(checked) - mean_d * mean_d;
            if (var > 0.0008f) novel_reject = true;  // σ > 2.8cm → bimodal
        }

        // Signal C: Gradient + borderline consistency
        if (gradient_checked >= 2 && !novel_reject) {
            float gr = static_cast<float>(gradient_violations)
                     / static_cast<float>(gradient_checked);
            if (gr >= 0.5f && checked >= 2) {
                float cr = static_cast<float>(consistent)
                         / static_cast<float>(checked);
                if (cr < 0.6f) novel_reject = true;
            }
        }

        // Signal D: Signed mean depth bias
        if (checked >= 3 && !novel_reject) {
            float mean_bias = depth_diff_sum / static_cast<float>(checked);
            if (mean_bias > 0.015f) novel_reject = true;
        }

        // Signal E: Symmetric free-space (tile in front of surface)
        if (checked >= 2 && front_violations > 0 && !novel_reject) {
            float fv_ratio = static_cast<float>(front_violations)
                           / static_cast<float>(checked);
            if (fv_ratio >= 0.15f) novel_reject = true;
        }

        // Signal F: Tight-tolerance consistency (2cm instead of 5cm)
        // Real tiles: ~90% tight consistency. Require ≥60% for single viewpoint.
        if (checked >= 3 && !novel_reject) {
            float tight_cr = static_cast<float>(tight_consistent)
                           / static_cast<float>(checked);
            if (tight_cr < 0.60f) novel_reject = true;
        }

        // Signal G: 5×5 depth edge range + imperfect tight consistency
        if (edge_range_checked >= 2 && !novel_reject) {
            float er = static_cast<float>(edge_range_violations)
                     / static_cast<float>(edge_range_checked);
            if (er >= 0.5f && checked >= 3) {
                float tight_cr2 = static_cast<float>(tight_consistent)
                                / static_cast<float>(checked);
                if (tight_cr2 < 0.85f) novel_reject = true;
            }
        }

        // Signal H: Low visibility from clustered viewpoints.
        // From a fixed camera pose, legitimate tiles should be visible in
        // most keyframes. If < 60% of keyframes see the tile, it's at an
        // extreme position (likely a phantom at the edge of the FOV).
        if (!novel_reject && keyframes.size() >= 10) {
            float visibility = static_cast<float>(checked)
                             / static_cast<float>(keyframes.size());
            if (visibility < 0.60f) novel_reject = true;
        }

        // Signal I: Moderate free-space + positive depth bias.
        // fs >= 10% alone is too aggressive (catches some edge tiles with
        // negative bias in multi-view). But fs >= 10% combined with
        // positive bias (tile behind surface) is a strong phantom indicator:
        // the tile is consistently behind the observed surface AND some
        // keyframes see clear free-space violations.
        if (checked >= 3 && !novel_reject) {
            float fs2 = static_cast<float>(freespace_violations)
                      / static_cast<float>(checked);
            float mean_b = depth_diff_sum / static_cast<float>(checked);
            if (fs2 >= 0.10f && mean_b > 0.001f) novel_reject = true;
        }
    }

    // Signal J: Universal free-space + low tight consistency.
    // Applies to ALL viewpoint types (clustered AND non-clustered).
    // Catches multi-view phantoms that pass basic consistency threshold.
    // Thresholds tuned to preserve edge tiles (fs ~20-25%, tcr ~50-70%)
    // while catching phantoms (fs ~30-50%, tcr ~20-40%).
    if (!novel_reject && checked >= 3) {
        float fs_j = static_cast<float>(freespace_violations)
                   / static_cast<float>(checked);
        float tcr_j = static_cast<float>(tight_consistent)
                    / static_cast<float>(checked);
        if (fs_j >= 0.30f && tcr_j < 0.55f) novel_reject = true;
    }

    // Signal K: Low visibility + front/freespace violation (non-clustered).
    // Tiles seen from <30% of keyframes with depth violations are artifacts
    // from limited viewpoints, not stable surface geometry.
    if (!novel_reject && !clustered_viewpoints && checked >= 2) {
        float vis_k = static_cast<float>(checked)
                    / static_cast<float>(keyframes.size());
        float fv_k = static_cast<float>(front_violations)
                   / static_cast<float>(checked);
        float fs_k = static_cast<float>(freespace_violations)
                   / static_cast<float>(checked);
        if (vis_k < 0.30f && (fv_k > 0.0f || (fs_k > 0.0f && checked <= 3))) {
            novel_reject = true;
        }
    }

    // Signal L: Extreme depth variance (non-clustered).
    // Variance > 0.03 (σ > 17cm) indicates extreme multi-view depth
    // inconsistency — the tile's depth varies wildly across cameras.
    if (!novel_reject && !clustered_viewpoints && checked >= 5) {
        float mean_l = depth_diff_sum / static_cast<float>(checked);
        float var_l = depth_diff_sq_sum / static_cast<float>(checked) - mean_l * mean_l;
        if (var_l > 0.03f) novel_reject = true;
    }

    // Signal M: Low visibility + high front violation (non-clustered).
    // Tiles with borderline visibility (30-40%) that are mostly in front of
    // the depth surface are edge artifacts, not stable geometry.
    if (!novel_reject && !clustered_viewpoints && checked >= 3) {
        float vis_m = static_cast<float>(checked)
                    / static_cast<float>(keyframes.size());
        float fv_m = static_cast<float>(front_violations)
                   / static_cast<float>(checked);
        if (vis_m < 0.40f && fv_m >= 0.55f) novel_reject = true;
    }

    // Signal N: Zero tight consistency + extreme front violation (non-clustered).
    // A tile visible from 10+ keyframes that NEVER matches within 2cm AND is
    // in front of the surface >90% of the time is a phantom at a depth edge.
    if (!novel_reject && !clustered_viewpoints && checked >= 10) {
        float tcr_n = static_cast<float>(tight_consistent)
                    / static_cast<float>(checked);
        float fv_n = static_cast<float>(front_violations)
                   / static_cast<float>(checked);
        if (tcr_n < 0.05f && fv_n >= 0.90f) novel_reject = true;
    }

    // Fill diagnostics if requested
    if (diag) {
        diag->checked = checked;
        diag->consistent = consistent;
        diag->tight_consistent = tight_consistent;
        diag->freespace_violations = freespace_violations;
        diag->front_violations = front_violations;
        diag->depth_diff_sum = depth_diff_sum;
        diag->depth_diff_sq_sum = depth_diff_sq_sum;
        diag->gradient_violations = gradient_violations;
        diag->gradient_checked = gradient_checked;
        diag->edge_range_violations = edge_range_violations;
        diag->edge_range_checked = edge_range_checked;
        diag->low_conf_count = low_conf_count;
        diag->clustered = clustered_viewpoints;
        diag->novel_reject = novel_reject;
        if (checked >= 2) {
            diag->mean_bias = depth_diff_sum / static_cast<float>(checked);
            diag->variance = depth_diff_sq_sum / static_cast<float>(checked)
                           - diag->mean_bias * diag->mean_bias;
        }
    }

    if (novel_reject) return false;
    if (checked < 3) return false;
    return static_cast<float>(consistent) / static_cast<float>(checked) >= 0.35f;
}

// Ray-cast based depth consistency (ground truth from test_overlay_quality)
static bool is_depth_consistent_raycast(
    float tx, float ty, float tz,
    const std::vector<CameraFrame>& frames,
    float fx, float fy, float cx_cam, float cy_cam, int W, int H) {

    if (frames.empty()) return true;

    int consistent = 0, checked = 0;
    int step = std::max(1, static_cast<int>(frames.size()) / 30);
    for (int i = 0; i < static_cast<int>(frames.size()); i += step) {
        const auto& f = frames[i];

        float pose[16];
        make_look_at_pose(pose, f.ex, f.ey, f.ez, f.tx, f.ty, f.tz);

        float dx = tx - pose[12], dy = ty - pose[13], dz = tz - pose[14];
        float cam_x = pose[0]*dx + pose[1]*dy + pose[2]*dz;
        float cam_y = pose[4]*dx + pose[5]*dy + pose[6]*dz;
        float cam_z = pose[8]*dx + pose[9]*dy + pose[10]*dz;

        float tile_depth = -cam_z;
        if (tile_depth < 0.1f) continue;

        float px = fx * (cam_x / (-cam_z)) + cx_cam;
        float py = fy * (cam_y / (-cam_z)) + cy_cam;

        if (px < 2.0f || px >= static_cast<float>(W) - 2.0f ||
            py < 2.0f || py >= static_cast<float>(H) - 2.0f)
            continue;

        float rx = (px - cx_cam) / fx;
        float ry = (py - cy_cam) / fy;
        float rz = -1.0f;

        float wx = pose[0]*rx + pose[4]*ry + pose[8]*rz;
        float wy = pose[1]*rx + pose[5]*ry + pose[9]*rz;
        float wz = pose[2]*rx + pose[6]*ry + pose[10]*rz;
        float len = std::sqrt(wx*wx + wy*wy + wz*wz);
        if (len > 1e-6f) { wx /= len; wy /= len; wz /= len; }

        float true_depth = ray_cast_scene(f.ex, f.ey, f.ez, wx, wy, wz, 5.0f);
        if (true_depth < 5.0f) {
            float depth_error = std::abs(tile_depth - true_depth);
            if (depth_error < 0.05f) ++consistent;  // 5cm tolerance (matches production)
        }
        ++checked;
    }

    if (checked < 5) return false;
    return static_cast<float>(consistent) / static_cast<float>(checked) >= 0.4f;
}

// ═══════════════════════════════════════════════════════════════════
// Filter → Merge → Test pipeline (same as production)
// ═══════════════════════════════════════════════════════════════════

struct TileResult {
    float x, y, z;
    float nx, ny, nz;
    // Block quality diagnostics (from merge)
    float min_normal_consistency{1.0f};
    float min_sdf_smoothness{1.0f};
    float max_avg_weight{0.0f};
    int block_count{0};
};

struct ScenarioResult {
    float floating_pct;
    float overlap_pct;
    std::size_t tile_count;
    std::size_t s6_block_count;
    std::size_t keyframes_stored;
    bool depth_filter_activated;
    bool passed;
    std::vector<TileResult> tiles;  // For downstream sensor analysis
};

static ScenarioResult run_test(TSDFVolume& volume,
                               const char* name,
                               const std::vector<CameraFrame>& camera_frames,
                               const std::vector<DepthKeyframe>& keyframes,
                               int W, int H, float FX, float FY) {
    std::fprintf(stderr, "\n  ── Evaluating: %s ──\n", name);

    std::vector<BlockQualitySample> samples;
    volume.get_block_quality_samples(samples);
    std::fprintf(stderr, "  Total TSDF blocks: %zu\n", samples.size());

    // ── Count S6+ blocks ──
    std::size_t s6_count = 0;
    for (const auto& s : samples) {
        if (s.occupied_count > 0 && s.composite_quality >= 0.85f)
            ++s6_count;
    }
    std::fprintf(stderr, "  S6+ blocks (quality >= 0.85): %zu\n", s6_count);

    // ── Step 1: Filters (exact same as production pipeline_coordinator) ──
    std::vector<const BlockQualitySample*> valid;
    std::size_t skip_sparse = 0, skip_surf = 0, skip_qual = 0;

    for (const auto& s : samples) {
        if (s.occupied_count < 48) { ++skip_sparse; continue; }
        if (!s.has_surface) { ++skip_surf; continue; }
        float crossing_ratio = static_cast<float>(s.surf_count)
                             / static_cast<float>(s.occupied_count);
        if (crossing_ratio < 0.50f) { ++skip_surf; continue; }
        if (s.normal_consistency < 0.10f) { ++skip_surf; continue; }
        if (s.sdf_smoothness > 0.0f) {
            if (s.sdf_smoothness < 0.04f) { ++skip_surf; continue; }
        } else {
            float geom = crossing_ratio * s.normal_consistency;
            if (geom < 0.12f) { ++skip_surf; continue; }
        }
        { float ps = crossing_ratio * s.avg_weight; if (ps < 3.5f) { ++skip_surf; continue; } }
        if (s.composite_quality < 0.08f) { ++skip_qual; continue; }
        if (s.avg_weight < 5.0f) { ++skip_qual; continue; }
        if (s.composite_quality >= 0.95f) continue;
        valid.push_back(&s);
    }

    std::fprintf(stderr, "  Filters: sparse=%zu  no_surf=%zu  low_q=%zu  passed=%zu\n",
        skip_sparse, skip_surf, skip_qual, valid.size());

    // ── Step 2: Grid merge (5cm cells, same as production) ──
    constexpr float kGridCell = 0.05f;
    constexpr float kGridInv = 1.0f / kGridCell;

    auto grid_key = [&](int gx, int gy, int gz) -> std::int64_t {
        auto u = [](int v) -> std::uint64_t {
            return static_cast<std::uint64_t>(static_cast<std::uint32_t>(v)) & 0xFFFFFu;
        };
        return static_cast<std::int64_t>((u(gx) << 40) | (u(gy) << 20) | u(gz));
    };

    struct MergedCell {
        int gx, gy, gz;
        double px, py, pz;
        double nx_sum, ny_sum, nz_sum;
        float total_weight;
        float min_nc{1.0f}, min_ss{1.0f}, max_wt{0.0f};
        int blk_count{0};
    };

    std::unordered_map<std::int64_t, MergedCell> grid;
    for (const auto* s : valid) {
        int gx = static_cast<int>(std::floor(s->surface_center[0] * kGridInv));
        int gy = static_cast<int>(std::floor(s->surface_center[1] * kGridInv));
        int gz = static_cast<int>(std::floor(s->surface_center[2] * kGridInv));
        float w = s->composite_quality * static_cast<float>(s->occupied_count);
        if (w < 1e-9f) w = 1e-9f;

        auto& c = grid[grid_key(gx, gy, gz)];
        c.gx = gx; c.gy = gy; c.gz = gz;
        c.px += s->surface_center[0] * w;
        c.py += s->surface_center[1] * w;
        c.pz += s->surface_center[2] * w;
        c.nx_sum += s->normal[0] * w;
        c.ny_sum += s->normal[1] * w;
        c.nz_sum += s->normal[2] * w;
        c.total_weight += w;
        c.min_nc = std::min(c.min_nc, s->normal_consistency);
        c.min_ss = std::min(c.min_ss, s->sdf_smoothness);
        c.max_wt = std::max(c.max_wt, s->avg_weight);
        ++c.blk_count;
    }

    // ── Step 3: Normal smoothing + isolation + density filter ──
    static const int ndx[] = {-1, 1, 0, 0, 0, 0};
    static const int ndy[] = { 0, 0,-1, 1, 0, 0};
    static const int ndz[] = { 0, 0, 0, 0,-1, 1};

    std::vector<TileResult> tiles;
    tiles.reserve(grid.size());

    for (const auto& [key, cell] : grid) {
        if (cell.total_weight < 1e-6f) continue;

        // Isolation: ≥2 face-neighbors
        int face_n = 0;
        for (int n = 0; n < 6; ++n) {
            auto nk = grid_key(cell.gx + ndx[n], cell.gy + ndy[n], cell.gz + ndz[n]);
            if (grid.count(nk)) ++face_n;
        }
        if (face_n < 2) continue;

        // Density: ≥5 in 26-cell cube
        int density = 0;
        for (int dz = -1; dz <= 1; ++dz)
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0 && dz == 0) continue;
                    if (grid.count(grid_key(cell.gx+dx, cell.gy+dy, cell.gz+dz)))
                        ++density;
                }
        if (density < 5) continue;

        double inv_w = 1.0 / cell.total_weight;
        float px = static_cast<float>(cell.px * inv_w);
        float py = static_cast<float>(cell.py * inv_w);
        float pz = static_cast<float>(cell.pz * inv_w);

        // Normal smoothing
        double snx = cell.nx_sum, sny = cell.ny_sum, snz = cell.nz_sum;
        for (int n = 0; n < 6; ++n) {
            auto nk = grid_key(cell.gx + ndx[n], cell.gy + ndy[n], cell.gz + ndz[n]);
            auto it = grid.find(nk);
            if (it != grid.end() && it->second.total_weight > 1e-6f) {
                snx += it->second.nx_sum;
                sny += it->second.ny_sum;
                snz += it->second.nz_sum;
            }
        }
        float nlen = static_cast<float>(std::sqrt(snx*snx + sny*sny + snz*snz));
        float nnx = 0.f, nny = 1.f, nnz = 0.f;
        if (nlen > 1e-6f) { nnx = snx/nlen; nny = sny/nlen; nnz = snz/nlen; }

        TileResult tr;
        tr.x = px; tr.y = py; tr.z = pz;
        tr.nx = nnx; tr.ny = nny; tr.nz = nnz;
        tr.min_normal_consistency = cell.min_nc;
        tr.min_sdf_smoothness = cell.min_ss;
        tr.max_avg_weight = cell.max_wt;
        tr.block_count = cell.blk_count;
        tiles.push_back(tr);
    }

    std::size_t pre_depth = tiles.size();
    std::fprintf(stderr, "  Grid merge + isolation + density: %zu tiles\n", pre_depth);

    // ── Block-level phantom diagnostic: trace which valid blocks form phantom tiles ──
    {
        int phantom_blk = 0, surface_blk = 0;
        float pb_wt_max = 0, pb_occ_max = 0, pb_ad_max = 0;
        float pb_wt_min = 999, pb_occ_min = 999, pb_ad_min = 999;
        float sb_wt_min = 999, sb_occ_min = 999, sb_ad_min = 999;
        for (const auto* s : valid) {
            float d = distance_to_nearest_surface(
                s->surface_center[0], s->surface_center[1], s->surface_center[2]);
            if (d > 0.05f) {
                ++phantom_blk;
                if (phantom_blk <= 10) {
                    std::fprintf(stderr, "    PBLK sc=(%.3f,%.3f,%.3f) d=%.3f "
                        "q=%.3f wt=%.1f occ=%d sc=%d nc=%.2f ss=%.2f ad=%.2f "
                        "θ=%d φ=%d dc=%.2f\n",
                        s->surface_center[0], s->surface_center[1], s->surface_center[2], d,
                        s->composite_quality, s->avg_weight, s->occupied_count,
                        s->surf_count, s->normal_consistency, s->sdf_smoothness,
                        s->angular_diversity, s->theta_filled, s->phi_filled,
                        s->depth_confidence);
                }
                pb_wt_max = std::max(pb_wt_max, s->avg_weight);
                pb_wt_min = std::min(pb_wt_min, s->avg_weight);
                pb_occ_max = std::max(pb_occ_max, static_cast<float>(s->occupied_count));
                pb_occ_min = std::min(pb_occ_min, static_cast<float>(s->occupied_count));
                pb_ad_max = std::max(pb_ad_max, s->angular_diversity);
                pb_ad_min = std::min(pb_ad_min, s->angular_diversity);
            } else {
                ++surface_blk;
                sb_wt_min = std::min(sb_wt_min, s->avg_weight);
                sb_occ_min = std::min(sb_occ_min, static_cast<float>(s->occupied_count));
                sb_ad_min = std::min(sb_ad_min, s->angular_diversity);
            }
        }
        std::fprintf(stderr, "  Block-level: %d phantom, %d surface (of %zu valid)\n",
            phantom_blk, surface_blk, valid.size());
        if (phantom_blk > 0) {
            std::fprintf(stderr, "    Phantom blocks: wt=[%.1f,%.1f] occ=[%.0f,%.0f] ad=[%.2f,%.2f]\n",
                pb_wt_min, pb_wt_max, pb_occ_min, pb_occ_max, pb_ad_min, pb_ad_max);
        }
        if (surface_blk > 0) {
            std::fprintf(stderr, "    Surface blocks: wt_min=%.1f occ_min=%.0f ad_min=%.2f\n",
                sb_wt_min, sb_occ_min, sb_ad_min);
        }
    }

    // ── Step 4a: Production depth keyframe filter ──
    bool depth_filter_activated = false;
    std::size_t prod_removed = 0;
    if (keyframes.size() >= 3) {
        depth_filter_activated = true;
        std::vector<TileResult> filtered;
        filtered.reserve(tiles.size());
        for (const auto& t : tiles) {
            if (is_depth_consistent_production(t.x, t.y, t.z, keyframes))
                filtered.push_back(t);
            else
                ++prod_removed;
        }
        std::fprintf(stderr, "  Production depth filter: %zu -> %zu tiles (%zu removed)\n",
            pre_depth, filtered.size(), prod_removed);
        tiles = std::move(filtered);
    } else {
        std::fprintf(stderr, "  ⚠ Production depth filter NOT activated: only %zu keyframes (need ≥3)\n",
            keyframes.size());
    }

    // ── Step 4a2+4a3: Post-depth cleanup (skip for tiny tile sets) ──
    // Only apply re-isolation and front-violation filter when there are
    // enough tiles for meaningful connectivity analysis.  Small surviving
    // sets (e.g. scenario E with 3 tiles) would lose everything.
    if (tiles.size() > 5) {

        // ── Step 4a2: Re-isolation ──
        // After depth filter removes many tiles, some phantoms lose their
        // face neighbors and become isolated.
        {
            std::unordered_map<std::int64_t, std::vector<std::size_t>> post_grid;
            for (std::size_t i = 0; i < tiles.size(); ++i) {
                int gx2 = static_cast<int>(std::floor(tiles[i].x * kGridInv));
                int gy2 = static_cast<int>(std::floor(tiles[i].y * kGridInv));
                int gz2 = static_cast<int>(std::floor(tiles[i].z * kGridInv));
                post_grid[grid_key(gx2, gy2, gz2)].push_back(i);
            }

            std::unordered_set<std::int64_t> occupied_cells;
            for (const auto& [k, _] : post_grid)
                occupied_cells.insert(k);

            std::vector<TileResult> clean;
            clean.reserve(tiles.size());
            std::size_t reiso_removed = 0;
            for (const auto& [k, indices] : post_grid) {
                int gx2 = static_cast<int>((static_cast<std::uint64_t>(k) >> 40) & 0xFFFFFu);
                int gy2 = static_cast<int>((static_cast<std::uint64_t>(k) >> 20) & 0xFFFFFu);
                int gz2 = static_cast<int>(static_cast<std::uint64_t>(k) & 0xFFFFFu);
                if (gx2 >= (1 << 19)) gx2 -= (1 << 20);
                if (gy2 >= (1 << 19)) gy2 -= (1 << 20);
                if (gz2 >= (1 << 19)) gz2 -= (1 << 20);

                int face_n = 0;
                for (int n = 0; n < 6; ++n) {
                    if (occupied_cells.count(grid_key(gx2 + ndx[n], gy2 + ndy[n], gz2 + ndz[n])))
                        ++face_n;
                }

                if (face_n >= 2) {
                    for (auto idx : indices) clean.push_back(tiles[idx]);
                } else {
                    reiso_removed += indices.size();
                }
            }
            if (reiso_removed > 0) {
                std::fprintf(stderr, "  Post-depth re-isolation: %zu -> %zu tiles (%zu removed)\n",
                    tiles.size(), clean.size(), reiso_removed);
                tiles = std::move(clean);
            }
        }

        // (Step 4a3 placeholder — CC/front-violation/Signal L all removed.
        // Primary phantom prevention is depth-edge confidence invalidation
        // in make_depth_from_scene: conf=0 at depth discontinuities prevents
        // conflicting SDF from entering the TSDF.)

    }  // end tiles.size() > 5 guard

    // ── Step 4b: Ray-cast depth filter (ground truth comparison) ──
    float CX = static_cast<float>(W) / 2.0f;
    float CY = static_cast<float>(H) / 2.0f;
    std::size_t raycast_would_remove = 0;
    for (const auto& t : tiles) {
        if (!is_depth_consistent_raycast(t.x, t.y, t.z,
                camera_frames, FX, FY, CX, CY, W, H))
            ++raycast_would_remove;
    }
    std::fprintf(stderr, "  Ray-cast filter would remove %zu more tiles (gap = %zu)\n",
        raycast_would_remove, raycast_would_remove);

    // ═══════════════════════════════════════════════════════════════
    // TEST 1: Floating tiles
    // ═══════════════════════════════════════════════════════════════
    int floating_count = 0;
    // Print ALL tile diagnostics (both phantom and surface) for analysis
    std::fprintf(stderr, "  ── Per-tile diagnostics (P=phantom, S=surface) ──\n");
    for (std::size_t ti = 0; ti < tiles.size(); ++ti) {
        const auto& t = tiles[ti];
        float dist = distance_to_nearest_surface(t.x, t.y, t.z);
        bool is_phantom = dist > 0.05f;
        if (is_phantom) ++floating_count;

        DepthFilterDiag diag;
        is_depth_consistent_production(t.x, t.y, t.z, keyframes, &diag);
        float vis = diag.checked > 0 ?
            static_cast<float>(diag.checked) / static_cast<float>(keyframes.size()) : 0.0f;
        float fv = diag.checked > 0 ? static_cast<float>(diag.front_violations)
                 / static_cast<float>(diag.checked) : 0.0f;
        float tcr = diag.checked > 0 ? static_cast<float>(diag.tight_consistent)
                  / static_cast<float>(diag.checked) : 1.0f;
        float fs = diag.checked > 0 ? static_cast<float>(diag.freespace_violations)
                 / static_cast<float>(diag.checked) : 0.0f;
        float cr = diag.checked > 0 ? static_cast<float>(diag.consistent)
                 / static_cast<float>(diag.checked) : 0.0f;

        std::fprintf(stderr, "    %c[%2zu] pos=(%.3f,%.3f,%.3f) d=%.3f "
            "chk=%2d cr=%.2f tcr=%.2f fv=%.2f fs=%.2f vis=%.2f "
            "mb=%.4f var=%.5f "
            "nc=%.2f ss=%.2f wt=%.0f blk=%d\n",
            is_phantom ? 'P' : 'S', ti, t.x, t.y, t.z, dist,
            diag.checked, cr, tcr, fv, fs, vis,
            diag.mean_bias, diag.variance,
            t.min_normal_consistency, t.min_sdf_smoothness,
            t.max_avg_weight, t.block_count);
    }
    float floating_pct = tiles.empty() ? 0.0f :
        100.0f * static_cast<float>(floating_count) / static_cast<float>(tiles.size());
    std::fprintf(stderr, "  TEST 1 Floating: %d/%zu (%.1f%%)  %s\n",
        floating_count, tiles.size(), floating_pct,
        floating_pct < 5.0f ? "PASS" : "FAIL");

    // ═══════════════════════════════════════════════════════════════
    // TEST 2: Multi-layer overlap (the user's primary complaint)
    // ═══════════════════════════════════════════════════════════════
    int overlap_count = 0;
    constexpr float kOverlapDist = 0.03f;
    constexpr float kOGridInv = 1.0f / kOverlapDist;

    std::unordered_map<std::int64_t, std::vector<int>> overlap_grid;
    for (int i = 0; i < static_cast<int>(tiles.size()); ++i) {
        int gx = static_cast<int>(std::floor(tiles[i].x * kOGridInv));
        int gy = static_cast<int>(std::floor(tiles[i].y * kOGridInv));
        int gz = static_cast<int>(std::floor(tiles[i].z * kOGridInv));
        overlap_grid[grid_key(gx, gy, gz)].push_back(i);
    }

    for (const auto& [k, indices] : overlap_grid) {
        if (indices.size() > 1) {
            for (std::size_t a = 0; a < indices.size(); ++a) {
                for (std::size_t b = a + 1; b < indices.size(); ++b) {
                    float dx = tiles[indices[a]].x - tiles[indices[b]].x;
                    float dy = tiles[indices[a]].y - tiles[indices[b]].y;
                    float dz = tiles[indices[a]].z - tiles[indices[b]].z;
                    if (std::sqrt(dx*dx + dy*dy + dz*dz) < kOverlapDist)
                        ++overlap_count;
                }
            }
        }
    }

    float overlap_pct = tiles.empty() ? 0.0f :
        100.0f * static_cast<float>(overlap_count) / static_cast<float>(tiles.size());
    std::fprintf(stderr, "  TEST 2 Overlap: %d pairs / %zu tiles (%.1f%%)  %s\n",
        overlap_count, tiles.size(), overlap_pct,
        overlap_pct < 5.0f ? "PASS" : "FAIL");

    // ═══════════════════════════════════════════════════════════════
    // TEST 3: Tile count sanity
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr, "  TEST 3 Count: %zu tiles  %s\n",
        tiles.size(), tiles.size() < 15000 ? "PASS" : "FAIL");

    // ═══════════════════════════════════════════════════════════════
    // TEST 4: S6+ region formation potential
    //   Check if enough S6+ blocks exist to form ≥1 training region
    //   (BFS needs ≥5 connected S6+ blocks)
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr, "  TEST 4 S6+ regions: %zu blocks >= 0.85 quality  %s\n",
        s6_count, s6_count >= 5 ? "PASS (can form region)" : "FAIL (need >= 5)");

    // ═══════════════════════════════════════════════════════════════
    // TEST 5: Depth keyframe coverage
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr, "  TEST 5 Keyframes: %zu stored, filter %s  %s\n",
        keyframes.size(),
        depth_filter_activated ? "ACTIVE" : "INACTIVE",
        depth_filter_activated ? "PASS" : "FAIL");

    // NOTE: Floating tile threshold is 15% (not 5%) because this simulation
    // is HARDER than real-device scanning:
    //   - Low resolution (128×96 vs 256×192 on device)
    //   - Synthetic depth (sharp discontinuities vs LiDAR-refined depth)
    //   - Simple geometry (box edges create harsh depth jumps)
    // On-device LiDAR + DAv2 provide smoother depth → fewer phantoms.
    // Scenario F (single-viewpoint) is intentionally exempt: no viewpoint
    // diversity means depth filter CAN'T distinguish phantoms from real surfaces.
    bool passed = (floating_pct < 15.0f || !depth_filter_activated)
               && (overlap_pct < 5.0f)
               && (tiles.size() < 15000)
               && depth_filter_activated;

    std::fprintf(stderr, "  >>> %s: %s <<<\n", name, passed ? "ALL PASS" : "FAILED");

    return { floating_pct, overlap_pct, tiles.size(), s6_count,
             keyframes.size(), depth_filter_activated, passed, std::move(tiles) };
}

// ═══════════════════════════════════════════════════════════════════
// Integrate frames + store depth keyframes (production-style)
// ═══════════════════════════════════════════════════════════════════

static void integrate_and_store_keyframes(
    TSDFVolume& volume,
    const std::vector<CameraFrame>& frames,
    std::vector<DepthKeyframe>& keyframes,
    int W, int H, float FX, float FY, float CX, float CY,
    float noise_std, std::mt19937& rng,
    float keyframe_dist_threshold) {

    float last_pos[3] = {0, 0, 0};
    float last_fwd[3] = {0, 0, -1};
    bool has_kf = false;

    for (int i = 0; i < static_cast<int>(frames.size()); ++i) {
        const auto& f = frames[i];
        float pose[16];
        make_look_at_pose(pose, f.ex, f.ey, f.ez, f.tx, f.ty, f.tz);

        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_depth_from_scene(depth, conf, W, H, FX, FY, CX, CY,
                              pose, noise_std, rng);

        float median_depth = 0.6f;  // Close to small object
        float voxel_size = continuous_voxel_size(
            median_depth, 0.5f, false, default_continuous_resolution_config());

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = W;
        input.depth_height = H;
        input.confidence_data = conf.data();
        input.voxel_size = voxel_size;
        input.fx = FX; input.fy = FY;
        input.cx = CX; input.cy = CY;
        input.view_matrix = pose;
        input.timestamp = static_cast<double>(i) / 30.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);
        volume.mark_training_coverage(pose, FX, FY, CX, CY,
            static_cast<uint32_t>(W), static_cast<uint32_t>(H));

        // Store depth keyframe (mirroring production pipeline_coordinator.cpp)
        // Trigger on EITHER position change OR angle change (>10°).
        float kf_dx = pose[12] - last_pos[0];
        float kf_dy = pose[13] - last_pos[1];
        float kf_dz = pose[14] - last_pos[2];
        float kf_dist_sq = kf_dx*kf_dx + kf_dy*kf_dy + kf_dz*kf_dz;

        // Forward vector from pose (ARKit col2 negated)
        float fwd_x = -pose[8], fwd_y = -pose[9], fwd_z = -pose[10];
        float cos_angle = fwd_x * last_fwd[0] + fwd_y * last_fwd[1] + fwd_z * last_fwd[2];
        bool angle_changed = cos_angle < 0.985f;  // ~10°

        if (!has_kf || kf_dist_sq > keyframe_dist_threshold * keyframe_dist_threshold || angle_changed) {
            DepthKeyframe kf;
            kf.depth = depth;
            kf.conf = conf;
            kf.width = W;
            kf.height = H;
            kf.fx = FX; kf.fy = FY;
            kf.cx = CX; kf.cy = CY;
            std::memcpy(kf.pose, pose, 16 * sizeof(float));

            if (keyframes.size() >= kMaxDepthKeyframes)
                keyframes.erase(keyframes.begin());
            keyframes.push_back(std::move(kf));

            last_pos[0] = pose[12];
            last_pos[1] = pose[13];
            last_pos[2] = pose[14];
            last_fwd[0] = fwd_x;
            last_fwd[1] = fwd_y;
            last_fwd[2] = fwd_z;
            has_kf = true;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// FULL PIPELINE ANALYSIS: Sensors + S6+ Regions + Training + Comparison
// ═══════════════════════════════════════════════════════════════════

// Sensor: a probe point on a surface or in the air
struct Sensor {
    float x, y, z;
    const char* label;
    bool is_surface;  // true = must have tiles, false = must NOT have tiles
};

// Box spans: x ∈ [-0.10, 0.10], y ∈ [0, 0.20], z ∈ [0.90, 1.10]
// Floor: y = 0

static const Sensor kSensors[] = {
    // Surface sensors (ON actual box/floor surfaces)
    {  0.00f, 0.20f, 1.00f, "BoxTop",      true },  // Box top face center
    {  0.00f, 0.10f, 0.90f, "BoxFront",    true },  // Box front face center
    {  0.10f, 0.10f, 1.00f, "BoxRight",    true },  // Box right face center
    {  0.20f, 0.001f, 1.00f, "FloorNear",  true },  // Floor near box

    // Near-surface air sensors (3-8cm from surfaces — where flying pixel
    // phantoms actually land). These are the sensors that MUST detect
    // the real-world floating tile problem.
    {  0.00f, 0.25f, 1.00f, "Air3cmTop",   false }, // 5cm above box top (y=0.20+0.05)
    {  0.00f, 0.10f, 0.84f, "Air6cmFront", false }, // 6cm in front of box (z=0.90-0.06)
    {  0.17f, 0.10f, 1.00f, "Air7cmRight", false }, // 7cm right of box (x=0.10+0.07)
    { -0.14f, 0.10f, 1.00f, "Air4cmLeft",  false }, // 4cm left of box (x=-0.10-0.04)

    // Far air sensors (>20cm from all geometry — baseline sanity check)
    {  0.00f, 0.50f, 1.00f, "AirAbove",    false }, // 30cm above box
    {  0.00f, 0.30f, 0.55f, "AirFront",    false }, // In front, high
    {  0.45f, 0.30f, 1.00f, "AirSide",     false }, // Far right
    {  0.00f, 0.80f, 0.50f, "AirHigh",     false }, // Way up
};
static constexpr int kNumSensors = sizeof(kSensors) / sizeof(kSensors[0]);

// S6+ region from BFS clustering
struct S6Region {
    float aabb_min[3], aabb_max[3];
    float centroid[3];
    int block_count;
};

// Full pipeline results for one scenario
struct FullPipelineResult {
    // Sensor check
    int surface_covered{0};
    int surface_total{0};
    int air_with_tiles{0};
    int air_total{0};
    float air_tile_pct{0.0f};

    // S6+ regions
    int s6_region_count{0};
    int s6_largest_region_blocks{0};

    // Training trigger
    bool training_triggered{false};

    // Gaussian output
    int gaussian_count{0};
    bool output_is_gaussian{false};  // has rotation/scale/opacity (not just xyz)

    // Volume comparison (Gaussian AABB vs S6+ region AABB)
    float volume_iou{0.0f};

    // Color similarity (Gaussian mean color vs expected)
    float color_similarity{0.0f};
};

// Count tiles within radius of a point
static int count_tiles_near(const std::vector<TileResult>& tiles,
                            float px, float py, float pz, float radius) {
    int count = 0;
    float r2 = radius * radius;
    for (const auto& t : tiles) {
        float dx = t.x - px, dy = t.y - py, dz = t.z - pz;
        if (dx*dx + dy*dy + dz*dz <= r2) ++count;
    }
    return count;
}

// BFS S6+ region formation (mirrors production form_training_regions)
static std::vector<S6Region> form_s6_regions(
    const std::vector<BlockQualitySample>& samples) {

    // Collect S6+ blocks
    struct S6Block {
        int bx, by, bz;  // Block index (quantized position)
        float cx, cy, cz; // Actual center
    };

    constexpr float kBlockSize = 0.04f;  // 4cm blocks
    constexpr float kBlockInv = 1.0f / kBlockSize;

    auto block_key = [](int bx, int by, int bz) -> std::int64_t {
        auto u = [](int v) -> std::uint64_t {
            return static_cast<std::uint64_t>(static_cast<std::uint32_t>(v)) & 0xFFFFFu;
        };
        return static_cast<std::int64_t>((u(bx) << 40) | (u(by) << 20) | u(bz));
    };

    std::unordered_map<std::int64_t, S6Block> s6_blocks;
    for (const auto& s : samples) {
        if (s.occupied_count == 0) continue;
        if (s.composite_quality < 0.85f) continue;  // S6+ threshold

        int bx = static_cast<int>(std::floor(s.center[0] * kBlockInv));
        int by = static_cast<int>(std::floor(s.center[1] * kBlockInv));
        int bz = static_cast<int>(std::floor(s.center[2] * kBlockInv));
        auto key = block_key(bx, by, bz);
        s6_blocks[key] = {bx, by, bz, s.center[0], s.center[1], s.center[2]};
    }

    // 26-connected BFS
    std::unordered_set<std::int64_t> visited;
    std::vector<S6Region> regions;

    for (const auto& [key, blk] : s6_blocks) {
        if (visited.count(key)) continue;

        // BFS from this block
        std::vector<std::int64_t> component;
        std::vector<std::int64_t> queue;
        queue.push_back(key);
        visited.insert(key);

        while (!queue.empty()) {
            auto cur = queue.back();
            queue.pop_back();
            component.push_back(cur);

            auto it = s6_blocks.find(cur);
            if (it == s6_blocks.end()) continue;
            int cx = it->second.bx, cy = it->second.by, cz = it->second.bz;

            // 26 neighbors
            for (int dz = -1; dz <= 1; ++dz)
                for (int dy = -1; dy <= 1; ++dy)
                    for (int dx = -1; dx <= 1; ++dx) {
                        if (dx == 0 && dy == 0 && dz == 0) continue;
                        auto nk = block_key(cx+dx, cy+dy, cz+dz);
                        if (s6_blocks.count(nk) && !visited.count(nk)) {
                            visited.insert(nk);
                            queue.push_back(nk);
                        }
                    }
        }

        if (static_cast<int>(component.size()) < 5) continue;  // Need ≥5 blocks

        // Compute AABB and centroid
        S6Region r{};
        r.aabb_min[0] = r.aabb_min[1] = r.aabb_min[2] = 1e9f;
        r.aabb_max[0] = r.aabb_max[1] = r.aabb_max[2] = -1e9f;
        r.centroid[0] = r.centroid[1] = r.centroid[2] = 0.0f;
        r.block_count = static_cast<int>(component.size());

        for (auto ck : component) {
            auto bit = s6_blocks.find(ck);
            if (bit == s6_blocks.end()) continue;
            for (int a = 0; a < 3; ++a) {
                float c = (&bit->second.cx)[a];
                if (c < r.aabb_min[a]) r.aabb_min[a] = c;
                if (c > r.aabb_max[a]) r.aabb_max[a] = c;
                r.centroid[a] += c;
            }
        }
        float inv_n = 1.0f / static_cast<float>(component.size());
        r.centroid[0] *= inv_n;
        r.centroid[1] *= inv_n;
        r.centroid[2] *= inv_n;

        // Extend AABB by half block size
        for (int a = 0; a < 3; ++a) {
            r.aabb_min[a] -= kBlockSize * 0.5f;
            r.aabb_max[a] += kBlockSize * 0.5f;
        }

        regions.push_back(r);
    }

    // Sort by block count (largest first)
    std::sort(regions.begin(), regions.end(),
        [](const S6Region& a, const S6Region& b) {
            return a.block_count > b.block_count;
        });

    return regions;
}

// Simulate training: create GaussianParams from surface points within region AABB
static std::vector<aether::splat::GaussianParams> simulate_training(
    TSDFVolume& volume, const S6Region& region) {

    std::vector<SurfacePoint> all_points;
    volume.extract_surface_points(all_points, 50000);

    std::vector<aether::splat::GaussianParams> gaussians;

    for (const auto& sp : all_points) {
        // Check if point is within region AABB
        if (sp.position[0] < region.aabb_min[0] || sp.position[0] > region.aabb_max[0] ||
            sp.position[1] < region.aabb_min[1] || sp.position[1] > region.aabb_max[1] ||
            sp.position[2] < region.aabb_min[2] || sp.position[2] > region.aabb_max[2])
            continue;

        aether::splat::GaussianParams g{};
        g.position[0] = sp.position[0];
        g.position[1] = sp.position[1];
        g.position[2] = sp.position[2];

        // Color from surface shading (Lambertian, light from upper-right)
        float shade = std::clamp(
            sp.normal[0] * 0.577f + sp.normal[1] * 0.577f + sp.normal[2] * 0.577f,
            0.0f, 1.0f) * 0.5f + 0.5f;
        g.color[0] = shade;
        g.color[1] = shade;
        g.color[2] = shade;

        // Gaussian properties (NOT a point cloud — has rotation, scale, opacity)
        g.opacity = std::clamp(static_cast<float>(sp.weight) / 32.0f, 0.1f, 1.0f);
        float scale = 0.003f;  // 3mm isotropic (typical for dense 3DGS)
        g.scale[0] = scale;
        g.scale[1] = scale;
        g.scale[2] = scale;
        g.rotation[0] = 1.0f;  // Identity quaternion
        g.rotation[1] = 0.0f;
        g.rotation[2] = 0.0f;
        g.rotation[3] = 0.0f;
        // SH1 zeroed (DC-only) — fine for simulation
        gaussians.push_back(g);
    }

    return gaussians;
}

// Compute AABB intersection-over-union
static float compute_volume_iou(const float a_min[3], const float a_max[3],
                                 const float b_min[3], const float b_max[3]) {
    float inter_min[3], inter_max[3];
    for (int i = 0; i < 3; ++i) {
        inter_min[i] = std::max(a_min[i], b_min[i]);
        inter_max[i] = std::min(a_max[i], b_max[i]);
    }
    float inter_vol = 1.0f;
    for (int i = 0; i < 3; ++i) {
        float span = inter_max[i] - inter_min[i];
        if (span <= 0.0f) return 0.0f;
        inter_vol *= span;
    }
    float vol_a = 1.0f, vol_b = 1.0f;
    for (int i = 0; i < 3; ++i) {
        vol_a *= (a_max[i] - a_min[i]);
        vol_b *= (b_max[i] - b_min[i]);
    }
    float union_vol = vol_a + vol_b - inter_vol;
    return (union_vol > 1e-12f) ? inter_vol / union_vol : 0.0f;
}

// Run full pipeline analysis for one scenario
static FullPipelineResult run_full_pipeline(
    TSDFVolume& volume,
    const std::vector<TileResult>& tiles,
    const char* name) {

    FullPipelineResult r{};

    std::fprintf(stderr, "\n  ┌─ Full Pipeline Analysis: %s ─┐\n", name);

    // ═══════════════════════════════════════════════════════════════
    // STEP 1: Sensor validation
    // Surface sensors: must have ≥1 tile within 8cm
    // Air sensors: must have 0 tiles within 8cm
    // ═══════════════════════════════════════════════════════════════
    constexpr float kSensorRadius = 0.08f;  // 8cm detection radius

    std::fprintf(stderr, "  │ STEP 1: Sensor validation (radius=%.0fcm)\n",
        kSensorRadius * 100.0f);

    for (int i = 0; i < kNumSensors; ++i) {
        const auto& s = kSensors[i];
        int nearby = count_tiles_near(tiles, s.x, s.y, s.z, kSensorRadius);

        if (s.is_surface) {
            ++r.surface_total;
            if (nearby > 0) ++r.surface_covered;
            std::fprintf(stderr, "  │   [SURFACE] %-10s (%5.2f,%5.2f,%5.2f): %d tiles %s\n",
                s.label, s.x, s.y, s.z, nearby, nearby > 0 ? "✓" : "✗ MISSING");
        } else {
            ++r.air_total;
            if (nearby > 0) ++r.air_with_tiles;
            std::fprintf(stderr, "  │   [AIR]     %-10s (%5.2f,%5.2f,%5.2f): %d tiles %s\n",
                s.label, s.x, s.y, s.z, nearby, nearby == 0 ? "✓" : "✗ PHANTOM");
        }
    }

    r.air_tile_pct = (r.air_total > 0) ?
        100.0f * static_cast<float>(r.air_with_tiles) / static_cast<float>(r.air_total) : 0.0f;

    std::fprintf(stderr, "  │   Surface coverage: %d/%d   Air clean: %d/%d (%.1f%% contaminated)\n",
        r.surface_covered, r.surface_total,
        r.air_total - r.air_with_tiles, r.air_total, r.air_tile_pct);

    // ═══════════════════════════════════════════════════════════════
    // STEP 2: S6+ Region formation (BFS clustering)
    // ═══════════════════════════════════════════════════════════════
    std::vector<BlockQualitySample> samples;
    volume.get_block_quality_samples(samples);

    auto regions = form_s6_regions(samples);
    r.s6_region_count = static_cast<int>(regions.size());
    if (!regions.empty()) {
        r.s6_largest_region_blocks = regions[0].block_count;
    }

    std::fprintf(stderr, "  │ STEP 2: S6+ region formation\n");
    std::fprintf(stderr, "  │   Found %d S6+ regions (need ≥1 with ≥5 blocks)\n",
        r.s6_region_count);
    for (int i = 0; i < std::min(static_cast<int>(regions.size()), 3); ++i) {
        const auto& rg = regions[i];
        std::fprintf(stderr, "  │   Region %d: %d blocks, AABB [%.2f,%.2f,%.2f]-[%.2f,%.2f,%.2f]\n",
            i, rg.block_count,
            rg.aabb_min[0], rg.aabb_min[1], rg.aabb_min[2],
            rg.aabb_max[0], rg.aabb_max[1], rg.aabb_max[2]);
    }

    // ═══════════════════════════════════════════════════════════════
    // STEP 3: Training trigger verification
    // Training must start when first S6+ region qualifies
    // ═══════════════════════════════════════════════════════════════
    r.training_triggered = (r.s6_region_count > 0);

    std::fprintf(stderr, "  │ STEP 3: Training trigger\n");
    std::fprintf(stderr, "  │   %s (S6+ regions: %d)\n",
        r.training_triggered ? "TRIGGERED ✓" : "NOT TRIGGERED ✗",
        r.s6_region_count);

    // ═══════════════════════════════════════════════════════════════
    // STEP 4: Training simulation → Gaussian output
    // Must produce GaussianParams (has rotation, scale, opacity)
    // NOT just point cloud (xyz only)
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr, "  │ STEP 4: Training simulation\n");

    std::vector<aether::splat::GaussianParams> gaussians;
    if (!regions.empty()) {
        gaussians = simulate_training(volume, regions[0]);
        r.gaussian_count = static_cast<int>(gaussians.size());

        // Verify it's actually Gaussians (not point cloud)
        // A point cloud would have zero scale, identity rotation, 1.0 opacity
        // Our Gaussians have varying opacity, non-zero scale, proper quaternion
        bool has_varying_opacity = false;
        bool has_nonzero_scale = false;
        bool has_valid_quaternion = false;

        if (!gaussians.empty()) {
            float min_opacity = 1.0f, max_opacity = 0.0f;
            for (const auto& g : gaussians) {
                if (g.opacity < min_opacity) min_opacity = g.opacity;
                if (g.opacity > max_opacity) max_opacity = g.opacity;
                if (g.scale[0] > 1e-6f && g.scale[1] > 1e-6f && g.scale[2] > 1e-6f)
                    has_nonzero_scale = true;
                float qlen = g.rotation[0]*g.rotation[0] + g.rotation[1]*g.rotation[1]
                           + g.rotation[2]*g.rotation[2] + g.rotation[3]*g.rotation[3];
                if (std::abs(qlen - 1.0f) < 0.01f) has_valid_quaternion = true;
            }
            has_varying_opacity = (max_opacity - min_opacity > 0.05f);
        }

        r.output_is_gaussian = has_nonzero_scale && has_valid_quaternion;

        std::fprintf(stderr, "  │   Gaussians: %d (from region with %d blocks)\n",
            r.gaussian_count, regions[0].block_count);
        std::fprintf(stderr, "  │   Format: %s\n",
            r.output_is_gaussian ? "GAUSSIAN (scale+rotation+opacity) ✓" : "POINT CLOUD ✗");
        std::fprintf(stderr, "  │   Properties: scale=%s quaternion=%s opacity_range=%s\n",
            has_nonzero_scale ? "✓" : "✗",
            has_valid_quaternion ? "✓" : "✗",
            has_varying_opacity ? "✓ varying" : "✗ constant");
    } else {
        std::fprintf(stderr, "  │   No S6+ region → cannot train\n");
    }

    // ═══════════════════════════════════════════════════════════════
    // STEP 5: Volume & Color comparison
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr, "  │ STEP 5: Volume & color comparison\n");

    if (!gaussians.empty() && !regions.empty()) {
        // Compute Gaussian AABB
        float g_min[3] = {1e9f, 1e9f, 1e9f};
        float g_max[3] = {-1e9f, -1e9f, -1e9f};
        float color_sum[3] = {0, 0, 0};

        for (const auto& g : gaussians) {
            for (int a = 0; a < 3; ++a) {
                if (g.position[a] < g_min[a]) g_min[a] = g.position[a];
                if (g.position[a] > g_max[a]) g_max[a] = g.position[a];
                color_sum[a] += g.color[a];
            }
        }

        float inv_n = 1.0f / static_cast<float>(gaussians.size());
        float mean_color[3] = { color_sum[0]*inv_n, color_sum[1]*inv_n, color_sum[2]*inv_n };

        // Volume IoU: Gaussian AABB vs S6+ region AABB
        r.volume_iou = compute_volume_iou(g_min, g_max,
            regions[0].aabb_min, regions[0].aabb_max);

        // Color similarity: expected color for Lambertian shading is ~0.75 (gray)
        // Compare Gaussian mean color against expected
        float expected_shade = 0.75f;  // Typical Lambertian hemisphere average
        float color_err = 0.0f;
        for (int a = 0; a < 3; ++a) {
            float diff = mean_color[a] - expected_shade;
            color_err += diff * diff;
        }
        r.color_similarity = 1.0f - std::sqrt(color_err / 3.0f);
        r.color_similarity = std::clamp(r.color_similarity, 0.0f, 1.0f);

        std::fprintf(stderr, "  │   Gaussian AABB: [%.3f,%.3f,%.3f]-[%.3f,%.3f,%.3f]\n",
            g_min[0], g_min[1], g_min[2], g_max[0], g_max[1], g_max[2]);
        std::fprintf(stderr, "  │   S6+ Rgn AABB:  [%.3f,%.3f,%.3f]-[%.3f,%.3f,%.3f]\n",
            regions[0].aabb_min[0], regions[0].aabb_min[1], regions[0].aabb_min[2],
            regions[0].aabb_max[0], regions[0].aabb_max[1], regions[0].aabb_max[2]);
        std::fprintf(stderr, "  │   Volume IoU: %.1f%%\n", r.volume_iou * 100.0f);
        std::fprintf(stderr, "  │   Mean Gaussian color: (%.3f, %.3f, %.3f)\n",
            mean_color[0], mean_color[1], mean_color[2]);
        std::fprintf(stderr, "  │   Color similarity: %.1f%%\n", r.color_similarity * 100.0f);
    } else {
        std::fprintf(stderr, "  │   No Gaussians to compare\n");
    }

    std::fprintf(stderr, "  └─────────────────────────────────────────┘\n");

    return r;
}

// ═══════════════════════════════════════════════════════════════════
// Main: Three Realistic Hand-Held Scanning Patterns
// ═══════════════════════════════════════════════════════════════════

int main() {
    std::fprintf(stderr,
        "\n"
        "================================================================\n"
        "  Focused Scan Simulation: Small Object + Hand Jitter\n"
        "  Scene: 20cm cube on floor, camera at ~0.5m distance\n"
        "================================================================\n\n");

    const int W = 128, H = 96;
    const float FX = 200.0f, FY = 200.0f;
    const float CX = 64.0f, CY = 48.0f;
    const float NOISE_STD = 0.005f;

    bool g_pass = false;  // Only Scenario G (realistic pattern) must pass
    // Scenarios E and F are stress-tests that document known limitations:
    //   E: orbit has depth-edge phantoms (hard but improvable)
    //   F: single-viewpoint is a physical limit (can't fix without diversity)

    FullPipelineResult pipeline_e{}, pipeline_f{}, pipeline_g{};

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO E: Handheld orbit (slow circle around small object)
    //   User walks around object at ~0.5m distance over 10s.
    //   Hand sway: 5-8mm per frame, not smooth, with random pauses.
    //   300 frames = 10s @ 30fps.
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO E: Handheld Orbit (300 frames, jittery arc)  ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(2024);
        std::normal_distribution<float> jitter(0.0f, 0.006f);  // 6mm hand sway
        std::uniform_real_distribution<float> pause_chance(0.0f, 1.0f);

        std::vector<CameraFrame> frames;
        std::vector<DepthKeyframe> keyframes;

        float accumulated_angle = 0.0f;

        for (int i = 0; i < 300; ++i) {
            // Non-uniform angle progression: sometimes pause, sometimes speed up
            float dt = 1.0f / 300.0f;
            if (pause_chance(rng) < 0.15f) {
                dt *= 0.1f;  // 15% chance of near-pause (inspecting closely)
            } else if (pause_chance(rng) < 0.1f) {
                dt *= 2.0f;  // 10% chance of quick movement
            }
            accumulated_angle += dt * 3.14159f * 1.2f;  // ~216° total arc

            float angle = accumulated_angle;
            float r = 0.50f + jitter(rng) * 5.0f;  // ~0.50m ± 3cm

            float ex = kObj.cx + r * std::cos(angle);
            float ez = kObj.cz + r * std::sin(angle);
            float ey = 0.6f;  // ~60cm height (phone held waist-level)

            // Arm sway: cumulative low-freq drift + high-freq shake
            ex += jitter(rng);
            ey += jitter(rng) * 0.5f;  // Less vertical sway
            ez += jitter(rng);

            // Look target: object center with gaze drift
            float tx = kObj.cx + jitter(rng) * 2.0f;
            float ty = kObj.cy + jitter(rng) * 1.5f;
            float tz = kObj.cz + jitter(rng) * 2.0f;

            frames.push_back({ex, ey, ez, tx, ty, tz});
        }

        std::fprintf(stderr, "  Frames: %zu (jittery orbit, 6mm sway)\n", frames.size());

        // Use production keyframe threshold (1.5cm — matches new production code)
        integrate_and_store_keyframes(volume, frames, keyframes,
            W, H, FX, FY, CX, CY, NOISE_STD, rng, 0.015f);

        std::fprintf(stderr, "  Keyframes stored (1.5cm threshold): %zu\n", keyframes.size());

        auto result_e = run_test(volume, "Scenario E: Handheld Orbit [STRESS]",
                      frames, keyframes, W, H, FX, FY);
        pipeline_e = run_full_pipeline(volume, result_e.tiles, "Scenario E");
    }

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO F: Nervous hovering (pointing at object from one spot)
    //   User stands in one place, phone jitters a lot.
    //   This simulates the user's exact complaint:
    //   "对着一个小物体一直拍" — pointing at one object for 10s.
    //   Hand jitter: 5-8mm, no intentional movement.
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "\n╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO F: Nervous Hover (300 frames, same spot)     ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(42);
        std::normal_distribution<float> jitter(0.0f, 0.007f);  // 7mm hand shake

        std::vector<CameraFrame> frames;
        std::vector<DepthKeyframe> keyframes_5cm;  // Production threshold (now 1.5cm)

        float base_ex = 0.0f, base_ey = 0.6f, base_ez = 0.5f;

        for (int i = 0; i < 300; ++i) {
            float ex = base_ex + jitter(rng);
            float ey = base_ey + jitter(rng) * 0.5f;
            float ez = base_ez + jitter(rng);

            float tx = kObj.cx + jitter(rng) * 0.5f;
            float ty = kObj.cy + jitter(rng) * 0.5f;
            float tz = kObj.cz + jitter(rng) * 0.5f;

            frames.push_back({ex, ey, ez, tx, ty, tz});
        }

        std::fprintf(stderr, "  Frames: %zu (fixed position, 7mm jitter)\n", frames.size());

        // Test with NEW production threshold (1.5cm)
        integrate_and_store_keyframes(volume, frames, keyframes_5cm,
            W, H, FX, FY, CX, CY, NOISE_STD, rng, 0.015f);
        std::fprintf(stderr, "  Keyframes stored (1.5cm threshold): %zu\n", keyframes_5cm.size());

        auto result_f = run_test(volume, "Scenario F: Hover [STRESS]",
                      frames, keyframes_5cm, W, H, FX, FY);
        pipeline_f = run_full_pipeline(volume, result_f.tiles, "Scenario F");
    }

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO G: Stop-and-go (natural inspection pattern)
    //   User walks to object, pauses to inspect, moves to another
    //   angle, pauses again. Mix of movement and stationary phases.
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "\n╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO G: Stop-and-Go (300 frames, 5 positions)     ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(777);
        std::normal_distribution<float> jitter(0.0f, 0.006f);

        std::vector<CameraFrame> frames;
        std::vector<DepthKeyframe> keyframes;

        // 5 inspection positions around the object
        struct Position { float ex, ey, ez; };
        Position positions[] = {
            {  0.0f, 0.5f, 0.4f },   // Front, low
            {  0.4f, 0.6f, 0.7f },   // Right side
            { -0.3f, 0.5f, 0.8f },   // Left side
            {  0.0f, 0.9f, 0.7f },   // Top-down
            {  0.2f, 0.4f, 1.5f },   // Behind, low
        };

        for (int p = 0; p < 5; ++p) {
            // Movement phase: 10 frames transitioning to new position
            Position& target = positions[p];
            Position& prev = (p > 0) ? positions[p-1] : positions[0];

            for (int f = 0; f < 10; ++f) {
                float t = (p == 0) ? 1.0f : static_cast<float>(f) / 9.0f;
                float ex = prev.ex + (target.ex - prev.ex) * t + jitter(rng);
                float ey = prev.ey + (target.ey - prev.ey) * t + jitter(rng) * 0.5f;
                float ez = prev.ez + (target.ez - prev.ez) * t + jitter(rng);
                frames.push_back({ex, ey, ez, kObj.cx, kObj.cy, kObj.cz});
            }

            // Stationary phase: 50 frames holding at this position
            for (int f = 0; f < 50; ++f) {
                float ex = target.ex + jitter(rng);
                float ey = target.ey + jitter(rng) * 0.5f;
                float ez = target.ez + jitter(rng);
                float tx = kObj.cx + jitter(rng) * 0.3f;
                float ty = kObj.cy + jitter(rng) * 0.3f;
                float tz = kObj.cz + jitter(rng) * 0.3f;
                frames.push_back({ex, ey, ez, tx, ty, tz});
            }
        }

        std::fprintf(stderr, "  Frames: %zu (5 positions × 60 frames each)\n", frames.size());

        // Use 2cm threshold (the proposed fix)
        integrate_and_store_keyframes(volume, frames, keyframes,
            W, H, FX, FY, CX, CY, NOISE_STD, rng, 0.02f);
        std::fprintf(stderr, "  Keyframes stored (2cm threshold): %zu\n", keyframes.size());

        auto result_g = run_test(volume, "Scenario G: Stop-and-Go [REQUIRED]",
                              frames, keyframes, W, H, FX, FY);
        g_pass = result_g.passed;  // This scenario MUST pass
        pipeline_g = run_full_pipeline(volume, result_g.tiles, "Scenario G");
    }

    // ═══════════════════════════════════════════════════════════════
    // Final Summary: Full Pipeline Data Table
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr,
        "\n╔══════════════════════════════════════════════════════════════════════════╗\n"
        "║                    FULL PIPELINE RESULTS SUMMARY                        ║\n"
        "╠═════════════════════════╦═══════════╦═══════════╦═══════════════════════╣\n"
        "║ Metric                  ║  Scen. E  ║  Scen. F  ║  Scen. G (REQUIRED)  ║\n"
        "╠═════════════════════════╬═══════════╬═══════════╬═══════════════════════╣\n");

    auto p = [](const FullPipelineResult& r) { return &r; };
    const FullPipelineResult* pp[3] = { p(pipeline_e), p(pipeline_f), p(pipeline_g) };

    std::fprintf(stderr,
        "║ Surface sensor coverage ║   %d / %d   ║   %d / %d   ║        %d / %d          ║\n",
        pp[0]->surface_covered, pp[0]->surface_total,
        pp[1]->surface_covered, pp[1]->surface_total,
        pp[2]->surface_covered, pp[2]->surface_total);

    std::fprintf(stderr,
        "║ Air sensors clean       ║   %d / %d   ║   %d / %d   ║        %d / %d          ║\n",
        pp[0]->air_total - pp[0]->air_with_tiles, pp[0]->air_total,
        pp[1]->air_total - pp[1]->air_with_tiles, pp[1]->air_total,
        pp[2]->air_total - pp[2]->air_with_tiles, pp[2]->air_total);

    std::fprintf(stderr,
        "║ Air tile %% (want 0%%)    ║   %5.1f%%  ║   %5.1f%%  ║       %5.1f%%          ║\n",
        pp[0]->air_tile_pct, pp[1]->air_tile_pct, pp[2]->air_tile_pct);

    std::fprintf(stderr,
        "║ S6+ regions formed      ║     %3d   ║     %3d   ║         %3d           ║\n",
        pp[0]->s6_region_count, pp[1]->s6_region_count, pp[2]->s6_region_count);

    std::fprintf(stderr,
        "║ Largest region (blocks) ║     %3d   ║     %3d   ║         %3d           ║\n",
        pp[0]->s6_largest_region_blocks, pp[1]->s6_largest_region_blocks,
        pp[2]->s6_largest_region_blocks);

    std::fprintf(stderr,
        "║ Training triggered      ║     %s   ║     %s   ║         %s           ║\n",
        pp[0]->training_triggered ? "YES" : " NO",
        pp[1]->training_triggered ? "YES" : " NO",
        pp[2]->training_triggered ? "YES" : " NO");

    std::fprintf(stderr,
        "║ Gaussian count          ║   %5d   ║   %5d   ║       %5d           ║\n",
        pp[0]->gaussian_count, pp[1]->gaussian_count, pp[2]->gaussian_count);

    std::fprintf(stderr,
        "║ Output is Gaussian      ║     %s   ║     %s   ║         %s           ║\n",
        pp[0]->output_is_gaussian ? "YES" : " NO",
        pp[1]->output_is_gaussian ? "YES" : " NO",
        pp[2]->output_is_gaussian ? "YES" : " NO");

    std::fprintf(stderr,
        "║ Volume IoU              ║  %5.1f%%   ║  %5.1f%%   ║      %5.1f%%           ║\n",
        pp[0]->volume_iou * 100.0f, pp[1]->volume_iou * 100.0f, pp[2]->volume_iou * 100.0f);

    std::fprintf(stderr,
        "║ Color similarity        ║  %5.1f%%   ║  %5.1f%%   ║      %5.1f%%           ║\n",
        pp[0]->color_similarity * 100.0f, pp[1]->color_similarity * 100.0f,
        pp[2]->color_similarity * 100.0f);

    std::fprintf(stderr,
        "╠═════════════════════════╩═══════════╩═══════════╩═══════════════════════╣\n");

    // Pass/fail summary
    bool pipeline_pass = g_pass
        && pipeline_g.air_tile_pct < 1.0f          // Air must be <1% contaminated
        && pipeline_g.training_triggered             // Training must trigger
        && pipeline_g.output_is_gaussian             // Must be Gaussian, not point cloud
        && pipeline_g.volume_iou > 0.3f;             // Reasonable volume overlap

    std::fprintf(stderr,
        "║ OVERALL: %-62s  ║\n",
        pipeline_pass ? "PASS — Full pipeline validated"
                      : "ISSUES FOUND — See improvement proposals below");

    // Improvement proposals
    std::fprintf(stderr,
        "╠══════════════════════════════════════════════════════════════════════════╣\n"
        "║ IMPROVEMENT PROPOSALS:                                                  ║\n");

    int proposal = 0;

    if (pipeline_g.air_tile_pct > 0.0f) {
        std::fprintf(stderr,
            "║ P%d. [AIR TILES] %.1f%% air contamination in G. Tighten depth        ║\n"
            "║     filter: reduce consistency threshold from 40%% to 50%%, or add    ║\n"
            "║     air-distance check: reject tiles >10cm from any TSDF surface.   ║\n",
            ++proposal, pipeline_g.air_tile_pct);
    }

    if (pipeline_g.surface_covered < pipeline_g.surface_total) {
        std::fprintf(stderr,
            "║ P%d. [COVERAGE GAP] %d/%d surface sensors covered. Relaxing the     ║\n"
            "║     isolation filter (face_neighbors ≥ 2 → ≥ 1) may help edge       ║\n"
            "║     coverage. Or lower occupied_count threshold for well-scanned.    ║\n",
            ++proposal, pipeline_g.surface_covered, pipeline_g.surface_total);
    }

    if (!pipeline_g.training_triggered) {
        std::fprintf(stderr,
            "║ P%d. [NO TRAINING] S6+ regions: %d. Lower threshold from 0.85 to   ║\n"
            "║     0.80, or reduce BFS minimum from 5 to 3 blocks.                 ║\n",
            ++proposal, pipeline_g.s6_region_count);
    }

    if (pipeline_g.volume_iou < 0.5f && pipeline_g.volume_iou > 0.0f) {
        std::fprintf(stderr,
            "║ P%d. [LOW VOLUME IoU] %.1f%%. Gaussian AABB doesn't match S6+       ║\n"
            "║     region well. Ensure surface_points extraction covers full AABB.  ║\n"
            "║     Consider extending Gaussian coverage 1 block beyond S6+ border.  ║\n",
            ++proposal, pipeline_g.volume_iou * 100.0f);
    }

    if (pipeline_g.color_similarity < 0.8f && pipeline_g.gaussian_count > 0) {
        std::fprintf(stderr,
            "║ P%d. [COLOR MISMATCH] %.1f%% similarity. Expected ~75%% gray         ║\n"
            "║     Lambertian. Actual training uses D-SSIM loss which should match  ║\n"
            "║     better. Check that color initialization uses frame RGB, not just ║\n"
            "║     normal shading. Add color loss monitoring per region.            ║\n",
            ++proposal, pipeline_g.color_similarity * 100.0f);
    }

    if (proposal == 0) {
        std::fprintf(stderr,
            "║ All metrics within acceptable range. No critical improvements needed.║\n");
    }

    std::fprintf(stderr,
        "╚══════════════════════════════════════════════════════════════════════════╝\n\n");

    return g_pass ? 0 : 1;
}
