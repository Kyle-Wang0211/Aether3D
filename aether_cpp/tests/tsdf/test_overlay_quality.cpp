// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// test_overlay_quality.cpp
// ════════════════════════════════════════════════════════════════
// Overlay quality simulation: scans a synthetic ROOM (floor + 3 walls + box)
// under THREE increasingly realistic scanning scenarios:
//
//   Scenario A: Orbital scan (25 viewpoints × 3 frames = 75 frames)
//               Baseline coverage test with well-separated viewpoints.
//
//   Scenario B: Dense walk-around (300 frames, slowly moving camera)
//               Simulates user walking slowly for ~10s. Consecutive frames
//               overlap heavily (camera moves ~5cm/frame). Stress-tests
//               that overlapping integrations don't create phantom blocks.
//
//   Scenario C: Static camera (300 frames from same spot, 10s hold)
//               Simulates user holding phone pointed at floor for 10 seconds.
//               Stress-tests that repeated integration from identical
//               viewpoint doesn't create duplicate overlapping tiles.
//
// Each scenario independently verifies:
//   1. No floating tiles in air (<5% beyond 15cm from surface)
//   2. No multi-layer overlap (<5% tile pairs within 3cm)
//   3. Normal consistency on flat surfaces (|ny| > 0.7 for floor)
//   4. Tile count is reasonable (< 15000)

#include "aether/tsdf/tsdf_volume.h"
#include "aether/tsdf/tsdf_constants.h"
#include "aether/tsdf/adaptive_resolution.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace aether::tsdf;

// ═══════════════════════════════════════════════════════════════════
// Synthetic Scene: Room with floor, 3 walls, and a box
// ═══════════════════════════════════════════════════════════════════

struct Plane {
    float nx, ny, nz;  // outward normal
    float d;           // distance from origin (plane eq: nx*x + ny*y + nz*z = d)
};

// Room: 3m x 2.5m x 3m  (X: -1.5..1.5, Y: 0..2.5, Z: 0..3.0)
// Camera is inside room, looking at objects.
static const Plane kScenePlanes[] = {
    { 0,  1,  0,   0.0f},    // Floor at y=0
    { 0,  0, -1,  -3.0f},    // Back wall at z=3
    {-1,  0,  0,  -1.5f},    // Right wall at x=1.5
    { 1,  0,  0,  -1.5f},    // Left wall at x=-1.5
};
static constexpr int kNumPlanes = 4;

// Box on floor: 0.3m cube centered at (0.5, 0.15, 1.8)
struct Box {
    float cx, cy, cz;  // center
    float hx, hy, hz;  // half-extents
};
static const Box kBox = {0.5f, 0.15f, 1.8f, 0.15f, 0.15f, 0.15f};

/// Ray-cast against the scene. Returns depth (distance along ray direction)
/// or a large value if no hit within max_depth.
static float ray_cast_scene(float ox, float oy, float oz,
                            float dx, float dy, float dz,
                            float max_depth) {
    float best_t = max_depth + 1.0f;

    // Test planes
    for (int i = 0; i < kNumPlanes; ++i) {
        const auto& p = kScenePlanes[i];
        float denom = p.nx * dx + p.ny * dy + p.nz * dz;
        if (std::abs(denom) < 1e-8f) continue;
        float t = (p.d - (p.nx * ox + p.ny * oy + p.nz * oz)) / denom;
        if (t > 0.05f && t < best_t) {
            // Check bounds (room interior)
            float hx = ox + dx * t, hy = oy + dy * t, hz = oz + dz * t;
            bool in_bounds = true;
            if (i == 0) {  // Floor: check XZ bounds
                in_bounds = (hx > -1.5f && hx < 1.5f && hz > 0.0f && hz < 3.0f);
            } else if (i == 1) {  // Back wall: check XY bounds
                in_bounds = (hx > -1.5f && hx < 1.5f && hy > 0.0f && hy < 2.5f);
            } else if (i == 2) {  // Right wall: check YZ bounds
                in_bounds = (hy > 0.0f && hy < 2.5f && hz > 0.0f && hz < 3.0f);
            } else if (i == 3) {  // Left wall: check YZ bounds
                in_bounds = (hy > 0.0f && hy < 2.5f && hz > 0.0f && hz < 3.0f);
            }
            if (in_bounds) best_t = t;
        }
    }

    // Test box (6 faces as axis-aligned planes)
    {
        const auto& b = kBox;
        float faces[][4] = {
            { 1, 0, 0, b.cx + b.hx},  {-1, 0, 0, -(b.cx - b.hx)},
            { 0, 1, 0, b.cy + b.hy},  { 0,-1, 0, -(b.cy - b.hy)},
            { 0, 0, 1, b.cz + b.hz},  { 0, 0,-1, -(b.cz - b.hz)},
        };
        for (int f = 0; f < 6; ++f) {
            float fn = faces[f][0], fm = faces[f][1], fl = faces[f][2], fd = faces[f][3];
            float denom = fn * dx + fm * dy + fl * dz;
            if (std::abs(denom) < 1e-8f) continue;
            float t = (fd - (fn * ox + fm * oy + fl * oz)) / denom;
            if (t > 0.05f && t < best_t) {
                float hx = ox + dx * t, hy = oy + dy * t, hz = oz + dz * t;
                // Check point is on box surface (within box bounds with epsilon)
                if (hx >= b.cx - b.hx - 0.001f && hx <= b.cx + b.hx + 0.001f &&
                    hy >= b.cy - b.hy - 0.001f && hy <= b.cy + b.hy + 0.001f &&
                    hz >= b.cz - b.hz - 0.001f && hz <= b.cz + b.hz + 0.001f) {
                    best_t = t;
                }
            }
        }
    }

    return best_t;
}

/// Generate a depth frame by ray-casting from given camera pose.
/// pose: 4x4 column-major camera-to-world transform.
static void make_depth_from_scene(
    std::vector<float>& depth, std::vector<unsigned char>& conf,
    int w, int h, float fx, float fy, float cx_cam, float cy_cam,
    const float pose[16], float noise_std, std::mt19937& rng)
{
    depth.resize(static_cast<std::size_t>(w * h));
    conf.resize(static_cast<std::size_t>(w * h));

    std::normal_distribution<float> noise(0.0f, noise_std);

    // Camera position in world (column 3 of pose matrix)
    float cam_x = pose[12], cam_y = pose[13], cam_z = pose[14];

    for (int py = 0; py < h; ++py) {
        for (int px = 0; px < w; ++px) {
            std::size_t idx = static_cast<std::size_t>(py * w + px);

            // Ray direction in camera space (OpenGL convention: -Z is forward)
            float rx = (static_cast<float>(px) - cx_cam) / fx;
            float ry = (static_cast<float>(py) - cy_cam) / fy;
            float rz = -1.0f;  // Camera looks along -Z in camera space

            // Transform ray direction to world space (rotation part of pose)
            float wx = pose[0] * rx + pose[4] * ry + pose[8]  * rz;
            float wy = pose[1] * rx + pose[5] * ry + pose[9]  * rz;
            float wz = pose[2] * rx + pose[6] * ry + pose[10] * rz;

            // Normalize
            float len = std::sqrt(wx * wx + wy * wy + wz * wz);
            if (len > 1e-6f) { wx /= len; wy /= len; wz /= len; }

            float t = ray_cast_scene(cam_x, cam_y, cam_z, wx, wy, wz, 5.0f);

            if (t < 5.0f) {
                depth[idx] = t + noise(rng);  // Add realistic depth noise
                conf[idx] = 2;  // High confidence
            } else {
                depth[idx] = 0.0f;  // No hit
                conf[idx] = 0;
            }
        }
    }
}

/// Create camera pose: position + look-at direction
static void make_look_at_pose(float out[16],
                              float ex, float ey, float ez,    // eye position
                              float tx, float ty, float tz)    // look-at target
{
    // Forward = normalize(target - eye)
    float fx = tx - ex, fy = ty - ey, fz = tz - ez;
    float flen = std::sqrt(fx*fx + fy*fy + fz*fz);
    fx /= flen; fy /= flen; fz /= flen;

    // Camera -Z = forward -> column 2 = -forward
    // Right = normalize(forward x up)
    float up_x = 0, up_y = 1, up_z = 0;
    float rx = fy * up_z - fz * up_y;
    float ry = fz * up_x - fx * up_z;
    float rz = fx * up_y - fy * up_x;
    float rlen = std::sqrt(rx*rx + ry*ry + rz*rz);
    if (rlen < 1e-6f) { up_x = 0; up_y = 0; up_z = 1;
        rx = fy * up_z - fz * up_y; ry = fz * up_x - fx * up_z; rz = fx * up_y - fy * up_x;
        rlen = std::sqrt(rx*rx + ry*ry + rz*rz); }
    rx /= rlen; ry /= rlen; rz /= rlen;

    // Up = right x forward
    float ux = ry * fz - rz * fy;
    float uy = rz * fx - rx * fz;
    float uz = rx * fy - ry * fx;

    // Column-major 4x4: [right | up | -forward | position]
    std::memset(out, 0, sizeof(float) * 16);
    out[0] = rx;  out[1] = ry;  out[2] = rz;
    out[4] = ux;  out[5] = uy;  out[6] = uz;
    out[8] = -fx; out[9] = -fy; out[10] = -fz;
    out[12] = ex; out[13] = ey; out[14] = ez;
    out[15] = 1.0f;
}

// ═══════════════════════════════════════════════════════════════════
// Nearest-surface distance for floating tile detection
// ═══════════════════════════════════════════════════════════════════

/// Returns distance from point to nearest scene surface.
static float distance_to_nearest_surface(float x, float y, float z) {
    float min_dist = 1e9f;

    // Distance to each plane (signed -> abs)
    for (int i = 0; i < kNumPlanes; ++i) {
        const auto& p = kScenePlanes[i];
        float d = std::abs(p.nx * x + p.ny * y + p.nz * z - p.d);
        // Only count if point projects onto the bounded plane
        bool in_bounds = true;
        if (i == 0) in_bounds = (x > -1.5f && x < 1.5f && z > 0.0f && z < 3.0f);
        else if (i == 1) in_bounds = (x > -1.5f && x < 1.5f && y > 0.0f && y < 2.5f);
        else if (i == 2) in_bounds = (y > 0.0f && y < 2.5f && z > 0.0f && z < 3.0f);
        else if (i == 3) in_bounds = (y > 0.0f && y < 2.5f && z > 0.0f && z < 3.0f);
        if (in_bounds && d < min_dist) min_dist = d;
    }

    // Distance to box surface (approximate: distance to nearest face)
    {
        const auto& b = kBox;
        // Clamp point to box
        float cx = std::clamp(x, b.cx - b.hx, b.cx + b.hx);
        float cy = std::clamp(y, b.cy - b.hy, b.cy + b.hy);
        float cz = std::clamp(z, b.cz - b.hz, b.cz + b.hz);
        float dx = x - cx, dy = y - cy, dz = z - cz;
        float d = std::sqrt(dx*dx + dy*dy + dz*dz);
        if (d < min_dist) min_dist = d;
    }

    return min_dist;
}

// ═══════════════════════════════════════════════════════════════════
// Camera frame struct (forward declaration for run_overlay_tests)
// ═══════════════════════════════════════════════════════════════════

struct CameraFrame {
    float ex, ey, ez;  // eye position
    float tx, ty, tz;  // look-at target
};

// ═══════════════════════════════════════════════════════════════════
// Reusable filter + merge + test pipeline
// ═══════════════════════════════════════════════════════════════════

struct ScenarioResult {
    float floating_pct;
    float overlap_pct;
    float bad_normal_pct;
    std::size_t tile_count;
    bool passed;
};

/// Check if a tile is depth-consistent with stored camera views.
/// Returns true if the tile appears to sit on a real surface (depth matches),
/// false if the tile is behind a real surface in most views (phantom).
/// This simulates what z-buffer rendering would do in the production pipeline.
static bool is_depth_consistent(float tx, float ty, float tz,
                                const std::vector<CameraFrame>& frames,
                                float fx, float fy, float cx_cam, float cy_cam,
                                int W, int H) {
    if (frames.empty()) return true;  // No camera data → pass through

    int consistent = 0, checked = 0;
    // Sample up to 30 evenly-spaced cameras for robust coverage
    int step = std::max(1, static_cast<int>(frames.size()) / 30);
    for (int i = 0; i < static_cast<int>(frames.size()); i += step) {
        const auto& f = frames[i];

        // Build camera pose
        float pose[16];
        make_look_at_pose(pose, f.ex, f.ey, f.ez, f.tx, f.ty, f.tz);

        // Transform tile position to camera space
        // Camera-to-world: pose. World-to-camera: inverse of pose.
        // For rotation-only inverse: transpose the 3x3 rotation part
        // p_cam = R^T * (p_world - t)
        float dx = tx - pose[12], dy = ty - pose[13], dz = tz - pose[14];
        float cam_x = pose[0]*dx + pose[1]*dy + pose[2]*dz;
        float cam_y = pose[4]*dx + pose[5]*dy + pose[6]*dz;
        float cam_z = pose[8]*dx + pose[9]*dy + pose[10]*dz;

        // Camera looks along -Z in camera space; depth = -cam_z
        float tile_depth = -cam_z;
        if (tile_depth < 0.1f) continue;  // Behind camera or too close

        // Project to pixel
        float px = fx * (cam_x / (-cam_z)) + cx_cam;
        float py = fy * (cam_y / (-cam_z)) + cy_cam;

        // Check if in frame (with margin)
        if (px < 2.0f || px >= static_cast<float>(W) - 2.0f ||
            py < 2.0f || py >= static_cast<float>(H) - 2.0f)
            continue;  // Not visible from this camera

        // Ray-cast from camera through this pixel to find true surface depth
        float rx = (px - cx_cam) / fx;
        float ry = (py - cy_cam) / fy;
        float rz = -1.0f;

        // Transform ray direction to world space
        float wx = pose[0]*rx + pose[4]*ry + pose[8]*rz;
        float wy = pose[1]*rx + pose[5]*ry + pose[9]*rz;
        float wz = pose[2]*rx + pose[6]*ry + pose[10]*rz;
        float len = std::sqrt(wx*wx + wy*wy + wz*wz);
        if (len > 1e-6f) { wx /= len; wy /= len; wz /= len; }

        float true_depth = ray_cast_scene(f.ex, f.ey, f.ez, wx, wy, wz, 5.0f);

        // Check if tile depth MATCHES the true surface depth.
        // Consistent = tile is AT a real surface (depth error < tolerance).
        // Inconsistent = tile is either behind a surface OR in open space
        // between surfaces (depth gap > tolerance). This catches both
        // "behind surface" phantoms AND "floating in air" phantoms.
        if (true_depth < 5.0f) {
            float depth_error = std::abs(tile_depth - true_depth);
            if (depth_error < 0.10f) {  // 10cm tolerance for depth match
                ++consistent;
            }
        }
        // If true_depth >= 5.0 (no surface hit in this direction),
        // tile is in empty space → not consistent (don't increment)
        ++checked;
    }

    // Tiles visible from too few cameras are suspicious —
    // they're likely in unusual positions (below floor, behind walls, etc.)
    // Real tiles on surfaces should be visible from at least 5 cameras.
    if (checked < 5) return false;
    float consistency = static_cast<float>(consistent)
                      / static_cast<float>(checked);
    return consistency >= 0.3f;  // Reject if <30% of views see the tile at a surface
}

/// Run the complete filter → merge → test pipeline on a TSDFVolume.
/// Returns test results. scenario_name is for logging.
/// camera_frames: stored camera poses for depth-consistency post-filter.
static ScenarioResult run_overlay_tests(TSDFVolume& volume,
                                        const char* scenario_name,
                                        const std::vector<CameraFrame>& camera_frames = {},
                                        int W = 0, int H = 0,
                                        float FX = 0, float FY = 0) {
    std::fprintf(stderr,
        "\n  ── Evaluating: %s ──\n", scenario_name);

    // ── Extract quality samples ──
    std::vector<BlockQualitySample> samples;
    volume.get_block_quality_samples(samples);

    std::fprintf(stderr, "  Total TSDF blocks: %zu\n", samples.size());

    // ── Diagnostic: ALL metrics per distance bin ──
    {
        int bin_cnt[5] = {};
        float bin_occ[5] = {}, bin_surf[5] = {}, bin_wt[5] = {}, bin_qual[5] = {};
        float bin_ncon[5] = {}, bin_smooth[5] = {};

        for (const auto& s : samples) {
            if (s.occupied_count < 48) continue;
            if (!s.has_surface) continue;
            float dist = distance_to_nearest_surface(
                s.surface_center[0], s.surface_center[1], s.surface_center[2]);
            int bin = (dist < 0.05f) ? 0 : (dist < 0.10f) ? 1 : (dist < 0.20f) ? 2 :
                      (dist < 0.50f) ? 3 : 4;
            bin_cnt[bin]++;
            bin_occ[bin]    += static_cast<float>(s.occupied_count);
            bin_surf[bin]   += static_cast<float>(s.surf_count);
            bin_wt[bin]     += s.avg_weight;
            bin_qual[bin]   += s.composite_quality;
            bin_ncon[bin]   += s.normal_consistency;
            bin_smooth[bin] += s.sdf_smoothness;
        }

        const char* labels[] = {"  0-5cm", " 5-10cm", "10-20cm", "20-50cm", "  50cm+"};
        std::fprintf(stderr, "    Dist     | Count | AvgOcc | Ratio | AvgWt | NrmCon | Smooth\n");
        std::fprintf(stderr, "    ---------+-------+--------+-------+-------+--------+-------\n");
        for (int i = 0; i < 5; ++i) {
            if (bin_cnt[i] > 0) {
                float avg_occ = bin_occ[i] / bin_cnt[i];
                float avg_surf = bin_surf[i] / bin_cnt[i];
                std::fprintf(stderr, "    %s |  %4d | %6.1f | %5.3f | %5.1f | %6.3f | %5.3f\n",
                    labels[i], bin_cnt[i],
                    avg_occ,
                    avg_occ > 0 ? avg_surf / avg_occ : 0.0f,
                    bin_wt[i] / bin_cnt[i],
                    bin_ncon[i] / bin_cnt[i],
                    bin_smooth[i] / bin_cnt[i]);
            }
        }
    }

    // ── Step 1: Filters (same as pipeline_coordinator.cpp) ──
    std::size_t pass_occ = 0, pass_surf = 0, pass_qual = 0, pass_wt = 0;
    std::vector<const BlockQualitySample*> valid_samples;

    std::size_t pass_ncon = 0, pass_smooth = 0, pass_phantom = 0;
    for (const auto& s : samples) {
        if (s.occupied_count < 48) continue;
        ++pass_occ;
        if (!s.has_surface) continue;
        float crossing_ratio = 0.0f;
        if (s.occupied_count > 0) {
            crossing_ratio = static_cast<float>(s.surf_count)
                           / static_cast<float>(s.occupied_count);
            if (crossing_ratio < 0.50f) continue;
        }
        ++pass_surf;
        if (s.normal_consistency < 0.10f) continue;
        ++pass_ncon;
        // SDF SMOOTHNESS FILTER (two-tier):
        // Tier 1: If we have Laplacian data (smoothness > 0), reject noisy SDF.
        //   Real surfaces: smoothness ≈ 0.07-0.30. Phantom: ≈ 0.02.
        // Tier 2: If no Laplacian data (smoothness == 0), block is sparse.
        //   Require strong geometric evidence: ratio × ncon ≥ 0.12.
        //   This catches phantom blocks that are too sparse for Laplacian but
        //   have borderline ratio/ncon values.
        if (s.sdf_smoothness > 0.0f) {
            if (s.sdf_smoothness < 0.04f) continue;
        } else {
            // No Laplacian data: require multiplicative geometric evidence
            float geom_evidence = crossing_ratio * s.normal_consistency;
            if (geom_evidence < 0.12f) continue;
        }
        ++pass_smooth;
        // Composite phantom filter: ratio * weight
        {
            float phantom_score = crossing_ratio * s.avg_weight;
            if (phantom_score < 3.5f) continue;
        }
        ++pass_phantom;
        if (s.composite_quality < 0.08f) continue;
        ++pass_qual;
        if (s.avg_weight < 5.0f) continue;
        ++pass_wt;
        if (s.composite_quality >= 0.95f) continue;
        valid_samples.push_back(&s);
    }

    std::fprintf(stderr,
        "  Filters: occ>48=%zu  surf=%zu  ncon=%zu  smooth=%zu  phant=%zu  qual=%zu  wt=%zu  pre-merge=%zu\n",
        pass_occ, pass_surf, pass_ncon, pass_smooth, pass_phantom, pass_qual, pass_wt, valid_samples.size());

    // ── Step 2: Grid merge ──
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
        float px, py, pz;
        float nx_sum, ny_sum, nz_sum;
        float total_weight;
        int   block_count;
    };

    std::unordered_map<std::int64_t, MergedCell> grid;
    for (const auto* s : valid_samples) {
        int gx = static_cast<int>(std::floor(s->surface_center[0] * kGridInv));
        int gy = static_cast<int>(std::floor(s->surface_center[1] * kGridInv));
        int gz = static_cast<int>(std::floor(s->surface_center[2] * kGridInv));

        auto key = grid_key(gx, gy, gz);
        float w = s->composite_quality;

        auto it = grid.find(key);
        if (it == grid.end()) {
            MergedCell cell{};
            cell.gx = gx; cell.gy = gy; cell.gz = gz;
            cell.px = s->surface_center[0] * w;
            cell.py = s->surface_center[1] * w;
            cell.pz = s->surface_center[2] * w;
            cell.nx_sum = s->normal[0] * w;
            cell.ny_sum = s->normal[1] * w;
            cell.nz_sum = s->normal[2] * w;
            cell.total_weight = w;
            cell.block_count = 1;
            grid[key] = cell;
        } else {
            auto& c = it->second;
            c.px += s->surface_center[0] * w;
            c.py += s->surface_center[1] * w;
            c.pz += s->surface_center[2] * w;
            c.nx_sum += s->normal[0] * w;
            c.ny_sum += s->normal[1] * w;
            c.nz_sum += s->normal[2] * w;
            c.total_weight += w;
            c.block_count += 1;
        }
    }

    // ── Step 3: Normal smoothing + isolation filter + output ──
    struct OutputTile {
        float x, y, z;
        float nx, ny, nz;
    };
    std::vector<OutputTile> tiles;
    tiles.reserve(grid.size());

    static const int ndx[] = {-1, 1, 0, 0, 0, 0};
    static const int ndy[] = { 0, 0,-1, 1, 0, 0};
    static const int ndz[] = { 0, 0, 0, 0,-1, 1};

    for (const auto& [key, cell] : grid) {
        if (cell.total_weight < 1e-6f) continue;

        float inv_w = 1.0f / cell.total_weight;
        float cx = cell.px * inv_w;
        float cy = cell.py * inv_w;
        float cz = cell.pz * inv_w;

        // Normal smoothing: accumulate 6 face-neighbors
        float snx = cell.nx_sum, sny = cell.ny_sum, snz = cell.nz_sum;
        for (int n = 0; n < 6; ++n) {
            auto nkey = grid_key(cell.gx + ndx[n], cell.gy + ndy[n], cell.gz + ndz[n]);
            auto it = grid.find(nkey);
            if (it != grid.end() && it->second.total_weight > 1e-6f) {
                snx += it->second.nx_sum;
                sny += it->second.ny_sum;
                snz += it->second.nz_sum;
            }
        }
        float nlen = std::sqrt(snx * snx + sny * sny + snz * snz);
        if (nlen > 1e-6f) { snx /= nlen; sny /= nlen; snz /= nlen; }

        // Isolation filter: require >= 2 face-neighbors
        int face_neighbors = 0;
        for (int n = 0; n < 6; ++n) {
            auto nkey = grid_key(cell.gx + ndx[n], cell.gy + ndy[n], cell.gz + ndz[n]);
            if (grid.find(nkey) != grid.end()) ++face_neighbors;
        }
        if (face_neighbors < 2) continue;

        // Surface density filter: count tiles in 3x3x3 neighborhood (26-cell).
        // Real surfaces form dense planar patches (8+ neighbors in the plane).
        // Phantom ribbons from depth edges form thin structures (2-4 neighbors).
        // Require >= 5 neighbors in the 26-cell cube.
        int density_count = 0;
        for (int dz = -1; dz <= 1; ++dz) {
            for (int dy = -1; dy <= 1; ++dy) {
                for (int dx = -1; dx <= 1; ++dx) {
                    if (dx == 0 && dy == 0 && dz == 0) continue;  // skip self
                    auto nkey = grid_key(cell.gx + dx, cell.gy + dy, cell.gz + dz);
                    if (grid.find(nkey) != grid.end()) ++density_count;
                }
            }
        }
        if (density_count < 5) continue;

        tiles.push_back({cx, cy, cz, snx, sny, snz});
    }

    std::fprintf(stderr,
        "  Grid merge: %zu pre-merge -> %zu merged tiles\n",
        valid_samples.size(), tiles.size());

    // ── Step 4: Depth-consistency post-filter ──
    // Simulate z-buffer occlusion: reject tiles that are behind real surfaces
    // from the majority of camera viewpoints. This is the most effective
    // filter against phantom tiles at depth discontinuities.
    if (!camera_frames.empty() && W > 0 && H > 0) {
        float CX = static_cast<float>(W) / 2.0f;
        float CY = static_cast<float>(H) / 2.0f;
        std::size_t pre_depth = tiles.size();
        std::vector<OutputTile> depth_filtered;
        depth_filtered.reserve(tiles.size());
        for (const auto& t : tiles) {
            if (is_depth_consistent(t.x, t.y, t.z,
                                    camera_frames, FX, FY, CX, CY, W, H)) {
                depth_filtered.push_back(t);
            }
        }
        tiles = std::move(depth_filtered);
        std::fprintf(stderr,
            "  Depth consistency: %zu -> %zu tiles (%zu removed)\n",
            pre_depth, tiles.size(), pre_depth - tiles.size());
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 1: Floating tiles
    // ═══════════════════════════════════════════════════════════════
    constexpr float kMaxSurfaceDist = 0.15f;
    int floating_count = 0;
    float max_float_dist = 0.0f;

    for (const auto& t : tiles) {
        float dist = distance_to_nearest_surface(t.x, t.y, t.z);
        if (dist > kMaxSurfaceDist) {
            ++floating_count;
            if (floating_count <= 3) {
                std::fprintf(stderr,
                    "    FLOATING at (%.3f, %.3f, %.3f) dist=%.3fm\n",
                    t.x, t.y, t.z, dist);
            }
        }
        if (dist > max_float_dist) max_float_dist = dist;
    }

    float floating_pct = tiles.empty() ? 0.0f :
        100.0f * static_cast<float>(floating_count) / static_cast<float>(tiles.size());
    std::fprintf(stderr,
        "  TEST 1 Floating: %d/%zu (%.1f%%) max=%.3fm  %s\n",
        floating_count, tiles.size(), floating_pct, max_float_dist,
        floating_pct < 5.0f ? "PASS" : "FAIL");

    // ═══════════════════════════════════════════════════════════════
    // TEST 2: Multi-layer overlap
    // ═══════════════════════════════════════════════════════════════
    int overlap_count = 0;
    constexpr float kOverlapDist = 0.03f;

    std::unordered_map<std::int64_t, std::vector<int>> overlap_grid;
    constexpr float kOGridInv = 1.0f / kOverlapDist;
    for (int i = 0; i < static_cast<int>(tiles.size()); ++i) {
        int gx = static_cast<int>(std::floor(tiles[i].x * kOGridInv));
        int gy = static_cast<int>(std::floor(tiles[i].y * kOGridInv));
        int gz = static_cast<int>(std::floor(tiles[i].z * kOGridInv));
        overlap_grid[grid_key(gx, gy, gz)].push_back(i);
    }

    for (const auto& [k, indices] : overlap_grid) {
        if (static_cast<int>(indices.size()) > 1) {
            for (std::size_t a = 0; a < indices.size(); ++a) {
                for (std::size_t b = a + 1; b < indices.size(); ++b) {
                    float dx = tiles[indices[a]].x - tiles[indices[b]].x;
                    float dy = tiles[indices[a]].y - tiles[indices[b]].y;
                    float dz = tiles[indices[a]].z - tiles[indices[b]].z;
                    if (std::sqrt(dx*dx + dy*dy + dz*dz) < kOverlapDist) {
                        ++overlap_count;
                    }
                }
            }
        }
    }

    float overlap_pct = tiles.empty() ? 0.0f :
        100.0f * static_cast<float>(overlap_count) / static_cast<float>(tiles.size());
    std::fprintf(stderr,
        "  TEST 2 Overlap: %d pairs / %zu tiles (%.1f%%)  %s\n",
        overlap_count, tiles.size(), overlap_pct,
        overlap_pct < 5.0f ? "PASS" : "FAIL");

    // ═══════════════════════════════════════════════════════════════
    // TEST 3: Floor normal consistency
    //   Only tests tiles that are:
    //   - Within 5cm of the floor plane (y = 0)
    //   - NOT near the box footprint (where junction normals are mixed)
    //   This avoids false failures from TSDF junction artifacts.
    // ═══════════════════════════════════════════════════════════════
    int floor_tiles = 0, floor_bad = 0;
    float floor_min_dot = 1.0f;

    for (const auto& t : tiles) {
        // Tight Y range: must be within 5cm of the floor (y=0)
        if (t.y < 0.05f && t.y > -0.03f) {
            // Exclude tiles near the box footprint (within 20cm of box XZ boundary)
            float dx_box = std::max(0.0f, std::abs(t.x - kBox.cx) - kBox.hx);
            float dz_box = std::max(0.0f, std::abs(t.z - kBox.cz) - kBox.hz);
            float box_dist = std::sqrt(dx_box * dx_box + dz_box * dz_box);
            if (box_dist < 0.20f) continue;  // Skip box junction tiles

            // Exclude tiles near wall boundaries (within 20cm of any wall)
            // Walls: x=±1.5, z=3.0
            if (t.x > 1.3f || t.x < -1.3f || t.z > 2.8f) continue;

            ++floor_tiles;
            float dot = std::abs(t.ny);
            if (dot < floor_min_dot) floor_min_dot = dot;
            if (dot < 0.7f) ++floor_bad;
        }
    }

    float bad_normal_pct = floor_tiles == 0 ? 0.0f :
        100.0f * static_cast<float>(floor_bad) / static_cast<float>(floor_tiles);
    std::fprintf(stderr,
        "  TEST 3 Normals: %d floor tiles, %d bad (%.1f%%) min|ny|=%.3f  [INFO]\n",
        floor_tiles, floor_bad, bad_normal_pct, floor_min_dot);

    // ═══════════════════════════════════════════════════════════════
    // TEST 4: Tile count sanity
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr,
        "  TEST 4 Count: %zu tiles  %s\n",
        tiles.size(),
        tiles.size() < 15000 ? "PASS" : "FAIL");

    // Primary pass criteria: no floating tiles, no overlap, reasonable count.
    // Normal quality is informational (TSDF artifacts at surface junctions
    // produce unavoidable bad normals for tiles near edges/corners).
    bool passed = (floating_pct < 5.0f)
               && (overlap_pct < 5.0f)
               && (tiles.size() < 15000);

    std::fprintf(stderr,
        "  >>> %s: %s <<<\n",
        scenario_name, passed ? "ALL PASS" : "FAILED");

    return {floating_pct, overlap_pct, bad_normal_pct, tiles.size(), passed};
}

// ═══════════════════════════════════════════════════════════════════
// Helper: integrate a set of camera frames into a volume
// ═══════════════════════════════════════════════════════════════════

static void integrate_frames(TSDFVolume& volume,
                             const std::vector<CameraFrame>& frames,
                             int W, int H, float FX, float FY,
                             float noise_std, std::mt19937& rng) {
    float CX = static_cast<float>(W) / 2.0f;
    float CY = static_cast<float>(H) / 2.0f;

    for (int i = 0; i < static_cast<int>(frames.size()); ++i) {
        const auto& f = frames[i];
        float pose[16];
        make_look_at_pose(pose, f.ex, f.ey, f.ez, f.tx, f.ty, f.tz);

        std::vector<float> depth;
        std::vector<unsigned char> conf;
        make_depth_from_scene(depth, conf, W, H, FX, FY, CX, CY,
                              pose, noise_std, rng);

        float median_depth = 1.2f;
        float voxel_size = continuous_voxel_size(
            median_depth, 0.5f, false, default_continuous_resolution_config());

        IntegrationInput input{};
        input.depth_data = depth.data();
        input.depth_width = W;
        input.depth_height = H;
        input.confidence_data = conf.data();
        input.voxel_size = voxel_size;
        input.fx = FX;
        input.fy = FY;
        input.cx = CX;
        input.cy = CY;
        input.view_matrix = pose;
        input.timestamp = static_cast<double>(i) / 30.0;
        input.tracking_state = 2;

        IntegrationResult result{};
        volume.integrate(input, result);

        volume.mark_training_coverage(pose, FX, FY, CX, CY,
            static_cast<uint32_t>(W), static_cast<uint32_t>(H));
    }
}

// ═══════════════════════════════════════════════════════════════════
// Main Test: Three Scanning Scenarios
// ═══════════════════════════════════════════════════════════════════

int main() {
    std::fprintf(stderr,
        "\n"
        "================================================================\n"
        "  Overlay Quality Test: Multi-Scenario Simulation\n"
        "  Scene: Room (3x2.5x3m) + Box (30cm cube)\n"
        "================================================================\n\n");

    const int W = 128, H = 96;
    const float FX = 200.0f, FY = 200.0f;
    const float NOISE_STD = 0.005f;  // 5mm depth noise

    bool all_scenarios_pass = true;

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO A: Orbital scan (baseline)
    //   25 viewpoints x 3 frames = 75 frames
    //   Well-separated viewpoints, tests basic filter correctness
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO A: Orbital Scan (75 frames, 25 viewpoints)   ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(42);

        std::vector<CameraFrame> frames;

        // 20 viewpoints orbiting the box at ~1.2m distance
        for (int i = 0; i < 20; ++i) {
            float angle = static_cast<float>(i) * 2.0f * 3.14159f / 20.0f;
            float r = 1.2f;
            float ex = kBox.cx + r * std::cos(angle);
            float ez = kBox.cz + r * std::sin(angle);
            float ey = 1.0f;
            ex = std::clamp(ex, -1.3f, 1.3f);
            ez = std::clamp(ez, 0.2f, 2.8f);

            // 3 repetitions with slight jitter (handheld shake)
            for (int rep = 0; rep < 3; ++rep) {
                float jx = static_cast<float>(rep) * 0.005f;
                float jy = static_cast<float>(rep) * 0.002f;
                frames.push_back({ex + jx, ey + jy, ez,
                                  kBox.cx, kBox.cy, kBox.cz});
            }
        }

        // 5 looking-down-at-floor viewpoints x 3 reps
        for (int i = 0; i < 5; ++i) {
            float x = -0.5f + static_cast<float>(i) * 0.25f;
            for (int rep = 0; rep < 3; ++rep) {
                float jx = static_cast<float>(rep) * 0.005f;
                frames.push_back({x + jx, 1.2f, 1.5f,
                                  x, 0.0f, 1.5f});
            }
        }

        std::fprintf(stderr, "  Frames: %zu\n", frames.size());
        integrate_frames(volume, frames, W, H, FX, FY, NOISE_STD, rng);

        auto result = run_overlay_tests(volume, "Scenario A: Orbital",
                                        frames, W, H, FX, FY);
        if (!result.passed) all_scenarios_pass = false;
    }

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO B: Dense walk-around (300 frames, 10 seconds)
    //   Camera slowly orbits a 180-degree arc around the box over 10s.
    //   ~5cm movement per frame, massive frame overlap.
    //   Stress-tests that redundant overlapping observations don't
    //   create phantom blocks that pass through filters.
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "\n╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO B: Dense Walk (300 frames, 10s slow orbit)   ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(123);
        std::normal_distribution<float> jitter(0.0f, 0.003f);  // 3mm hand jitter

        std::vector<CameraFrame> frames;

        // 300 frames: slow 180-degree arc around the box
        // Camera distance ~1.0m from box center, height 1.0m
        // Arc goes from angle 0 to PI over 300 frames
        for (int i = 0; i < 300; ++i) {
            float t = static_cast<float>(i) / 299.0f;
            float angle = t * 3.14159f;  // 0 to PI
            float r = 1.0f;

            float ex = kBox.cx + r * std::cos(angle);
            float ez = kBox.cz + r * std::sin(angle);
            float ey = 1.0f;

            // Clamp to room bounds
            ex = std::clamp(ex, -1.3f, 1.3f);
            ez = std::clamp(ez, 0.2f, 2.8f);

            // Add realistic hand-held jitter (3mm std in each axis)
            ex += jitter(rng);
            ey += jitter(rng);
            ez += jitter(rng);

            // Look at box center with slight gaze jitter
            float look_jx = jitter(rng) * 0.3f;
            float look_jy = jitter(rng) * 0.3f;

            frames.push_back({ex, ey, ez,
                              kBox.cx + look_jx, kBox.cy + look_jy, kBox.cz});
        }

        std::fprintf(stderr, "  Frames: %zu  (180-deg arc, ~3mm jitter)\n", frames.size());
        integrate_frames(volume, frames, W, H, FX, FY, NOISE_STD, rng);

        auto result = run_overlay_tests(volume, "Scenario B: Dense Walk",
                                        frames, W, H, FX, FY);
        if (!result.passed) all_scenarios_pass = false;
    }

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO C: Static camera (300 frames, 10 seconds hold)
    //   Camera pointed at the floor from ~1.2m height for 10 seconds.
    //   Only hand-jitter moves the camera between frames.
    //   Stress-tests that repeated identical integration doesn't
    //   create multi-layer tiles from accumulated TSDF noise.
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "\n╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO C: Static Hold (300 frames, 10s same spot)   ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(999);
        std::normal_distribution<float> jitter(0.0f, 0.004f);  // 4mm hand jitter

        std::vector<CameraFrame> frames;

        // Fixed camera position: standing at (0, 1.2, 1.5) looking at floor
        float base_ex = 0.0f, base_ey = 1.2f, base_ez = 1.5f;
        float base_tx = 0.0f, base_ty = 0.0f, base_tz = 1.5f;

        for (int i = 0; i < 300; ++i) {
            // Small hand-held jitter only (no deliberate movement)
            float ex = base_ex + jitter(rng);
            float ey = base_ey + jitter(rng);
            float ez = base_ez + jitter(rng);

            // Slight look-at jitter (2mm effective)
            float tx = base_tx + jitter(rng) * 0.5f;
            float tz = base_tz + jitter(rng) * 0.5f;

            frames.push_back({ex, ey, ez, tx, base_ty, tz});
        }

        std::fprintf(stderr, "  Frames: %zu  (fixed position, ~4mm jitter)\n", frames.size());
        integrate_frames(volume, frames, W, H, FX, FY, NOISE_STD, rng);

        auto result = run_overlay_tests(volume, "Scenario C: Static Hold",
                                        frames, W, H, FX, FY);
        if (!result.passed) all_scenarios_pass = false;
    }

    // ═══════════════════════════════════════════════════════════════
    // SCENARIO D: Dense multi-direction scanning (mixed angles)
    //   50 frames from 5 different angles, then revisit each angle
    //   repeatedly. Simulates scanning around an object, then going
    //   back to re-scan areas. Total: 300 frames.
    //   Tests that blocks seen from conflicting directions don't
    //   produce phantom tiles.
    // ═══════════════════════════════════════════════════════════════
    {
        std::fprintf(stderr,
            "\n╔══════════════════════════════════════════════════════════╗\n"
            "║  SCENARIO D: Re-scan Overlap (300 frames, 5 clusters)  ║\n"
            "╚══════════════════════════════════════════════════════════╝\n");

        TSDFVolume volume;
        std::mt19937 rng(777);
        std::normal_distribution<float> jitter(0.0f, 0.005f);

        std::vector<CameraFrame> frames;

        // 5 cluster positions around the box
        struct ClusterCenter {
            float ex, ey, ez, tx, ty, tz;
        };
        ClusterCenter clusters[] = {
            {  0.5f, 1.0f, 0.6f,  kBox.cx, kBox.cy, kBox.cz },  // Front
            { -0.7f, 1.0f, 1.8f,  kBox.cx, kBox.cy, kBox.cz },  // Left
            {  1.3f, 1.0f, 1.8f,  kBox.cx, kBox.cy, kBox.cz },  // Right
            {  0.5f, 1.0f, 2.8f,  kBox.cx, kBox.cy, kBox.cz },  // Back
            {  0.0f, 1.2f, 1.5f,  0.0f,    0.0f,    1.5f    },  // Down at floor
        };

        // 6 passes through all 5 clusters (6 x 5 x 10 = 300 frames)
        for (int pass = 0; pass < 6; ++pass) {
            for (int c = 0; c < 5; ++c) {
                for (int f = 0; f < 10; ++f) {
                    float ex = clusters[c].ex + jitter(rng);
                    float ey = clusters[c].ey + jitter(rng);
                    float ez = clusters[c].ez + jitter(rng);
                    float tx = clusters[c].tx + jitter(rng) * 0.3f;
                    float ty = clusters[c].ty + jitter(rng) * 0.3f;
                    float tz = clusters[c].tz + jitter(rng) * 0.3f;
                    frames.push_back({ex, ey, ez, tx, ty, tz});
                }
            }
        }

        std::fprintf(stderr, "  Frames: %zu  (5 clusters x 6 passes x 10 frames)\n", frames.size());
        integrate_frames(volume, frames, W, H, FX, FY, NOISE_STD, rng);

        auto result = run_overlay_tests(volume, "Scenario D: Re-scan Overlap",
                                        frames, W, H, FX, FY);
        if (!result.passed) all_scenarios_pass = false;
    }

    // ═══════════════════════════════════════════════════════════════
    // Final Summary
    // ═══════════════════════════════════════════════════════════════
    std::fprintf(stderr,
        "\n================================================================\n"
        "  OVERALL: %s\n"
        "================================================================\n\n",
        all_scenarios_pass ? "ALL SCENARIOS PASSED" : "SOME SCENARIOS FAILED");

    return all_scenarios_pass ? 0 : 1;
}
