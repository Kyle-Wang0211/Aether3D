// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// test_affine_depth_alignment.cpp
// End-to-end simulation: synthetic room → DAv2 depth → affine alignment → TSDF
// Proves that affine (scale+shift) fixes the floating tile problem.
//
// Synthetic scene:
//   - Floor at y=0, 6m×6m
//   - Back wall at z=5m
//   - Left wall at x=-3m
//   - Table (box) at center: 1m×0.75m×0.6m
//
// Virtual cameras at 3 positions simulating a scanning walk.
// For each camera:
//   1. Ray-cast → true metric depth (ground truth)
//   2. Min-max normalize → simulated DAv2 output [0,1]
//   3. Generate ARKit-like feature points (subset of surface points)
//   4. Run OLD algorithm (scale only) vs NEW algorithm (affine)
//   5. Compare reconstructed depth vs ground truth
//   6. Check if resulting 3D points land on surfaces or float

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <numeric>
#include <vector>

// ══════════════════════════════════════════════════════════════════════
// Scene definition: axis-aligned planes forming a room + table
// ══════════════════════════════════════════════════════════════════════

struct Plane {
    float nx, ny, nz;  // Normal
    float d;           // Plane equation: nx*x + ny*y + nz*z + d = 0
    const char* name;
};

static const Plane kScenePlanes[] = {
    { 0,  1,  0,   0.0f, "floor"},      // y = 0    (floor)
    { 0, -1,  0,   3.0f, "ceiling"},     // y = 3    (ceiling)
    { 0,  0, -1,   5.0f, "back_wall"},   // z = 5    (back wall)
    { 1,  0,  0,   3.0f, "left_wall"},   // x = -3   (left wall)
    {-1,  0,  0,   3.0f, "right_wall"},  // x = 3    (right wall)
    // Table top: y = 0.75
    { 0,  1,  0,  -0.75f, "table_top"},
};
static const int kNumPlanes = sizeof(kScenePlanes) / sizeof(kScenePlanes[0]);

// Check if hit point is within scene bounds
static bool point_in_bounds(float x, float y, float z, const Plane& plane) {
    if (std::strcmp(plane.name, "floor") == 0)
        return x >= -3.0f && x <= 3.0f && z >= 0.0f && z <= 5.0f;
    if (std::strcmp(plane.name, "ceiling") == 0)
        return x >= -3.0f && x <= 3.0f && z >= 0.0f && z <= 5.0f;
    if (std::strcmp(plane.name, "back_wall") == 0)
        return x >= -3.0f && x <= 3.0f && y >= 0.0f && y <= 3.0f;
    if (std::strcmp(plane.name, "left_wall") == 0)
        return z >= 0.0f && z <= 5.0f && y >= 0.0f && y <= 3.0f;
    if (std::strcmp(plane.name, "right_wall") == 0)
        return z >= 0.0f && z <= 5.0f && y >= 0.0f && y <= 3.0f;
    if (std::strcmp(plane.name, "table_top") == 0)
        return x >= -0.3f && x <= 0.3f && z >= 1.5f && z <= 2.1f;
    return true;
}

// Ray-scene intersection: returns metric depth (camera Z-depth), or -1 if miss
static float ray_cast(
    float cam_x, float cam_y, float cam_z,
    float dir_x, float dir_y, float dir_z)
{
    float best_t = 1e9f;
    for (int i = 0; i < kNumPlanes; ++i) {
        const Plane& p = kScenePlanes[i];
        float denom = p.nx * dir_x + p.ny * dir_y + p.nz * dir_z;
        if (std::abs(denom) < 1e-8f) continue;  // Parallel
        float t = -(p.nx * cam_x + p.ny * cam_y + p.nz * cam_z + p.d) / denom;
        if (t < 0.01f) continue;  // Behind camera
        // Check bounds
        float hx = cam_x + t * dir_x;
        float hy = cam_y + t * dir_y;
        float hz = cam_z + t * dir_z;
        if (!point_in_bounds(hx, hy, hz, p)) continue;
        if (t < best_t) best_t = t;
    }
    return best_t < 1e8f ? best_t : -1.0f;
}

// ══════════════════════════════════════════════════════════════════════
// Camera model: generate column-major 4×4 transform + intrinsics
// ══════════════════════════════════════════════════════════════════════

struct Camera {
    float transform[16];  // Column-major camera-to-world
    float fx, fy, cx, cy;
    int width, height;
};

// Create a camera looking in the -Z direction of its local frame
// (ARKit convention: camera looks along -Z)
static Camera make_camera(
    float pos_x, float pos_y, float pos_z,
    float look_x, float look_y, float look_z)
{
    Camera cam{};
    cam.width = 128;
    cam.height = 96;
    cam.fx = 100.0f;  // Focal length in pixels
    cam.fy = 100.0f;
    cam.cx = 64.0f;
    cam.cy = 48.0f;

    // Compute basis vectors
    float fwd_x = look_x - pos_x;
    float fwd_y = look_y - pos_y;
    float fwd_z = look_z - pos_z;
    float fwd_len = std::sqrt(fwd_x*fwd_x + fwd_y*fwd_y + fwd_z*fwd_z);
    fwd_x /= fwd_len; fwd_y /= fwd_len; fwd_z /= fwd_len;

    // Up = world Y
    float up_x = 0, up_y = 1, up_z = 0;

    // Right = forward × up
    float right_x = fwd_y * up_z - fwd_z * up_y;
    float right_y = fwd_z * up_x - fwd_x * up_z;
    float right_z = fwd_x * up_y - fwd_y * up_x;
    float right_len = std::sqrt(right_x*right_x + right_y*right_y + right_z*right_z);
    if (right_len < 1e-6f) {
        // Looking straight up/down
        up_x = 0; up_y = 0; up_z = 1;
        right_x = fwd_y * up_z - fwd_z * up_y;
        right_y = fwd_z * up_x - fwd_x * up_z;
        right_z = fwd_x * up_y - fwd_y * up_x;
        right_len = std::sqrt(right_x*right_x + right_y*right_y + right_z*right_z);
    }
    right_x /= right_len; right_y /= right_len; right_z /= right_len;

    // Recompute up = right × forward (for orthogonality)
    up_x = right_y * fwd_z - right_z * fwd_y;
    up_y = right_z * fwd_x - right_x * fwd_z;
    up_z = right_x * fwd_y - right_y * fwd_x;

    // ARKit convention:
    // Column 0 = right
    // Column 1 = up
    // Column 2 = BACK (= -forward)
    // Column 3 = translation
    cam.transform[0]  = right_x;   cam.transform[1]  = right_y;   cam.transform[2]  = right_z;   cam.transform[3]  = 0;
    cam.transform[4]  = up_x;      cam.transform[5]  = up_y;      cam.transform[6]  = up_z;      cam.transform[7]  = 0;
    cam.transform[8]  = -fwd_x;    cam.transform[9]  = -fwd_y;    cam.transform[10] = -fwd_z;    cam.transform[11] = 0;
    cam.transform[12] = pos_x;     cam.transform[13] = pos_y;     cam.transform[14] = pos_z;     cam.transform[15] = 1;

    return cam;
}

// Generate true metric depth map by ray-casting
static void render_depth(const Camera& cam, std::vector<float>& depth_out) {
    depth_out.resize(static_cast<std::size_t>(cam.width) * cam.height);
    const float* m = cam.transform;

    for (int v = 0; v < cam.height; ++v) {
        for (int u = 0; u < cam.width; ++u) {
            // Unproject pixel to camera-space ray direction
            float x_cam = (static_cast<float>(u) - cam.cx) / cam.fx;
            float y_cam = -(static_cast<float>(v) - cam.cy) / cam.fy;  // Y-down → Y-up
            float z_cam = -1.0f;  // ARKit: camera looks along -Z

            // Transform ray direction to world (rotation only)
            float dir_x = m[0]*x_cam + m[4]*y_cam + m[8]*z_cam;
            float dir_y = m[1]*x_cam + m[5]*y_cam + m[9]*z_cam;
            float dir_z = m[2]*x_cam + m[6]*y_cam + m[10]*z_cam;
            float dir_len = std::sqrt(dir_x*dir_x + dir_y*dir_y + dir_z*dir_z);
            dir_x /= dir_len; dir_y /= dir_len; dir_z /= dir_len;

            float t = ray_cast(m[12], m[13], m[14], dir_x, dir_y, dir_z);
            if (t > 0) {
                // Convert from ray parameter t to camera Z-depth
                // Camera forward = -col2 = (m[8], m[9], m[10]) negated
                float fwd_x = -m[8], fwd_y = -m[9], fwd_z = -m[10];
                float z_depth = t * (dir_x*fwd_x + dir_y*fwd_y + dir_z*fwd_z);
                depth_out[v * cam.width + u] = z_depth;
            } else {
                depth_out[v * cam.width + u] = 0.0f;
            }
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
// Simulate DAv2: INVERSE DEPTH with min-max normalization to [0,1]
// DAv2 outputs disparity-like values: larger = closer objects.
// ══════════════════════════════════════════════════════════════════════

static void simulate_dav2_normalize(
    const std::vector<float>& metric_depth,
    std::vector<float>& dav2_out,
    float& out_true_scale,    // true scale in inverse-depth space
    float& out_true_shift)    // true shift in inverse-depth space
{
    dav2_out.resize(metric_depth.size());

    // Step 1: Convert metric depth → inverse depth (disparity)
    std::vector<float> inv_depth(metric_depth.size(), 0.0f);
    float inv_min = 1e9f, inv_max = -1e9f;
    for (std::size_t i = 0; i < metric_depth.size(); ++i) {
        if (metric_depth[i] > 0.01f) {
            inv_depth[i] = 1.0f / metric_depth[i];
            inv_min = std::min(inv_min, inv_depth[i]);
            inv_max = std::max(inv_max, inv_depth[i]);
        }
    }
    if (inv_max <= inv_min) { inv_min = 0.2f; inv_max = 3.0f; }

    // Step 2: Min-max normalize inverse depth to [0,1]
    // Closest objects (highest inv_depth) → d_norm near 1.0
    // Farthest objects (lowest inv_depth) → d_norm near 0.0
    float inv_range = inv_max - inv_min;
    for (std::size_t i = 0; i < metric_depth.size(); ++i) {
        if (metric_depth[i] > 0.01f) {
            dav2_out[i] = (inv_depth[i] - inv_min) / inv_range;
        } else {
            dav2_out[i] = 0.0f;
        }
    }

    // True RECIPROCAL AFFINE parameters in inverse-depth space:
    //   1/metric_z = scale * d_norm + shift
    //   metric_z   = 1 / (scale * d_norm + shift)
    //
    // When d_norm=0: 1/metric_z = shift → shift = inv_min (farthest pixel)
    // When d_norm=1: 1/metric_z = scale + shift → scale = inv_range
    out_true_scale = inv_range;     // = inv_max - inv_min
    out_true_shift = inv_min;       // = 1/z_max (farthest pixel's inverse depth)
}

// ══════════════════════════════════════════════════════════════════════
// Generate synthetic ARKit feature points (known 3D positions on surfaces)
// ══════════════════════════════════════════════════════════════════════

struct FeaturePoint {
    float world[3];
};

static void generate_feature_points(
    const Camera& cam,
    const std::vector<float>& metric_depth,
    std::vector<FeaturePoint>& points,
    int max_points = 50)
{
    points.clear();
    const float* m = cam.transform;
    int step = std::max(1, cam.width * cam.height / max_points);

    for (int v = 5; v < cam.height - 5; v += 8) {
        for (int u = 5; u < cam.width - 5; u += 8) {
            float d = metric_depth[v * cam.width + u];
            if (d < 0.2f || d > 8.0f) continue;

            // Backproject to world using true depth
            float x_cam = (static_cast<float>(u) - cam.cx) / cam.fx * d;
            float y_cam = -(static_cast<float>(v) - cam.cy) / cam.fy * d;
            float z_cam = -d;  // ARKit: -Z forward

            FeaturePoint fp;
            fp.world[0] = m[0]*x_cam + m[4]*y_cam + m[8]*z_cam  + m[12];
            fp.world[1] = m[1]*x_cam + m[5]*y_cam + m[9]*z_cam  + m[13];
            fp.world[2] = m[2]*x_cam + m[6]*y_cam + m[10]*z_cam + m[14];
            points.push_back(fp);

            if (static_cast<int>(points.size()) >= max_points) return;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════
// OLD algorithm: LINEAR scale-only (the buggy version)
// Bugs: 1. Linear model for inverse depth  2. No shift  3. Y-flip  4. Euclidean dist
// ══════════════════════════════════════════════════════════════════════

static float old_estimate_scale(
    const Camera& cam,
    const std::vector<float>& dav2_depth,
    const std::vector<FeaturePoint>& features)
{
    const float* m = cam.transform;
    float cam_x = m[12], cam_y = m[13], cam_z_pos = m[14];

    std::vector<float> ratios;
    for (const auto& fp : features) {
        float dwx = fp.world[0] - cam_x;
        float dwy = fp.world[1] - cam_y;
        float dwz = fp.world[2] - cam_z_pos;

        // BUG: uses Euclidean distance
        float metric_dist = std::sqrt(dwx*dwx + dwy*dwy + dwz*dwz);
        if (metric_dist < 0.3f || metric_dist > 8.0f) continue;

        float rx = dwx * m[0] + dwy * m[1] + dwz * m[2];
        float ry = dwx * m[4] + dwy * m[5] + dwz * m[6];  // BUG: not negated
        float rz = dwx * m[8] + dwy * m[9] + dwz * m[10];
        float cam_z_pt = -rz;
        if (cam_z_pt < 0.2f) continue;

        // BUG: ry not negated
        float u = cam.fx * (rx / cam_z_pt) + cam.cx;
        float v = cam.fy * (ry / cam_z_pt) + cam.cy;

        int iu = static_cast<int>(u + 0.5f);
        int iv = static_cast<int>(v + 0.5f);
        if (iu < 1 || iu >= cam.width - 1 || iv < 1 || iv >= cam.height - 1) continue;

        float rel = dav2_depth[iv * cam.width + iu];
        if (rel < 0.01f || rel > 0.99f) continue;

        // BUG: LINEAR scale = Euclidean / d_pred (should be reciprocal)
        float ratio = metric_dist / rel;
        if (ratio > 0.2f && ratio < 30.0f) ratios.push_back(ratio);
    }

    if (ratios.size() < 3) return 2.0f;
    std::sort(ratios.begin(), ratios.end());
    return ratios[ratios.size() / 2];
}

// ══════════════════════════════════════════════════════════════════════
// NEW algorithm: RECIPROCAL AFFINE in inverse-depth space (4 fixes)
// Fit: 1/cam_z = scale * d_pred + shift
// Convert: metric_z = 1 / (scale * d_pred + shift)
// ══════════════════════════════════════════════════════════════════════

static bool new_estimate_affine(
    const Camera& cam,
    const std::vector<float>& dav2_depth,
    const std::vector<FeaturePoint>& features,
    float& out_scale, float& out_shift)
{
    const float* m = cam.transform;
    float cam_x = m[12], cam_y = m[13], cam_z_pos = m[14];

    std::vector<float> d_pred_pts;
    std::vector<float> inv_z_pts;  // INVERSE depth: 1/cam_z

    for (const auto& fp : features) {
        float dwx = fp.world[0] - cam_x;
        float dwy = fp.world[1] - cam_y;
        float dwz = fp.world[2] - cam_z_pos;

        float rx = dwx * m[0] + dwy * m[1] + dwz * m[2];
        float ry = dwx * m[4] + dwy * m[5] + dwz * m[6];
        float rz = dwx * m[8] + dwy * m[9] + dwz * m[10];

        // FIX #3: use camera Z-depth (not Euclidean)
        float cam_z_pt = -rz;
        if (cam_z_pt < 0.2f || cam_z_pt > 8.0f) continue;

        // FIX #2: negate ry for projection
        float u = cam.fx * (rx / cam_z_pt) + cam.cx;
        float v = cam.fy * (-ry / cam_z_pt) + cam.cy;

        int iu = static_cast<int>(u + 0.5f);
        int iv = static_cast<int>(v + 0.5f);
        if (iu < 2 || iu >= cam.width - 2 || iv < 2 || iv >= cam.height - 2) continue;

        // 2×2 averaging with edge rejection
        std::size_t didx = static_cast<std::size_t>(iv) * cam.width + iu;
        float d00 = dav2_depth[didx];
        float d01 = dav2_depth[didx + 1];
        float d10 = dav2_depth[didx + cam.width];
        float d11 = dav2_depth[didx + cam.width + 1];

        float d_min_w = std::min({d00, d01, d10, d11});
        float d_max_w = std::max({d00, d01, d10, d11});
        if (d_max_w - d_min_w > 0.08f) continue;

        float rel = (d00 + d01 + d10 + d11) * 0.25f;
        if (rel < 0.005f || rel > 0.995f) continue;

        d_pred_pts.push_back(rel);
        inv_z_pts.push_back(1.0f / cam_z_pt);  // FIX #1: INVERSE depth
    }

    if (d_pred_pts.size() < 5) return false;

    // FIX #1: RECIPROCAL AFFINE least squares in inverse-depth space
    // Model: 1/cam_z = scale * d_pred + shift
    float fit_scale = 3.0f, fit_shift = 0.2f;
    for (int iter = 0; iter < 2; ++iter) {
        double sum_d = 0, sum_iz = 0, sum_dd = 0, sum_diz = 0;
        int cnt = 0;
        for (std::size_t k = 0; k < d_pred_pts.size(); ++k) {
            if (iter > 0) {
                float predicted = fit_scale * d_pred_pts[k] + fit_shift;
                float residual = std::abs(inv_z_pts[k] - predicted);
                if (residual > inv_z_pts[k] * 0.25f || residual > 0.3f) continue;
            }
            double d = d_pred_pts[k];
            double iz = inv_z_pts[k];
            sum_d += d; sum_iz += iz; sum_dd += d*d; sum_diz += d*iz;
            cnt++;
        }
        if (cnt < 5) break;
        double det = sum_dd * cnt - sum_d * sum_d;
        if (std::abs(det) < 1e-12) break;
        fit_scale = static_cast<float>((sum_diz * cnt - sum_d * sum_iz) / det);
        fit_shift = static_cast<float>((sum_dd * sum_iz - sum_d * sum_diz) / det);
    }

    out_scale = fit_scale;
    out_shift = fit_shift;
    return true;
}

// ══════════════════════════════════════════════════════════════════════
// Evaluate depth error: compute per-pixel absolute error in meters
// ══════════════════════════════════════════════════════════════════════

struct ErrorStats {
    float mean_abs_error;      // Mean absolute error (meters)
    float max_abs_error;       // Max absolute error (meters)
    float mean_rel_error;      // Mean relative error (%)
    float pct_within_5cm;      // % of pixels with error < 5cm
    float pct_within_10cm;     // % of pixels with error < 10cm
    int valid_pixels;
};

static ErrorStats compute_error(
    const std::vector<float>& ground_truth,
    const std::vector<float>& reconstructed,
    int width, int height)
{
    ErrorStats stats{};
    double sum_abs = 0, sum_rel = 0;
    int n = 0, within_5cm = 0, within_10cm = 0;

    for (std::size_t i = 0; i < ground_truth.size(); ++i) {
        float gt = ground_truth[i];
        float rc = reconstructed[i];
        if (gt < 0.1f || rc < 0.1f) continue;

        float err = std::abs(gt - rc);
        sum_abs += err;
        sum_rel += err / gt;
        if (err > stats.max_abs_error) stats.max_abs_error = err;
        if (err < 0.05f) within_5cm++;
        if (err < 0.10f) within_10cm++;
        n++;
    }

    if (n > 0) {
        stats.mean_abs_error = static_cast<float>(sum_abs / n);
        stats.mean_rel_error = static_cast<float>(sum_rel / n * 100.0);
        stats.pct_within_5cm = within_5cm * 100.0f / n;
        stats.pct_within_10cm = within_10cm * 100.0f / n;
    }
    stats.valid_pixels = n;
    return stats;
}

// ══════════════════════════════════════════════════════════════════════
// Simulate TSDF block creation and check surface alignment
// ══════════════════════════════════════════════════════════════════════

struct TileResult {
    int total_tiles;
    int tiles_on_surface;     // Within 5cm of a scene surface
    int tiles_floating;       // > 10cm from any surface
    float mean_surface_dist;  // Average distance to nearest surface
};

// Find minimum distance from a 3D point to any scene surface.
// Bounds are extended by 'margin' to handle block centers near plane edges.
static float distance_to_nearest_surface(float x, float y, float z, float margin = 0.1f) {
    float min_dist = 1e9f;

    // Floor (y=0)
    if (x >= -3.0f - margin && x <= 3.0f + margin &&
        z >= 0.0f - margin && z <= 5.0f + margin)
        min_dist = std::min(min_dist, std::abs(y));

    // Ceiling (y=3)
    if (x >= -3.0f - margin && x <= 3.0f + margin &&
        z >= 0.0f - margin && z <= 5.0f + margin)
        min_dist = std::min(min_dist, std::abs(y - 3.0f));

    // Back wall (z=5)
    if (x >= -3.0f - margin && x <= 3.0f + margin &&
        y >= 0.0f - margin && y <= 3.0f + margin)
        min_dist = std::min(min_dist, std::abs(z - 5.0f));

    // Left wall (x=-3)
    if (z >= 0.0f - margin && z <= 5.0f + margin &&
        y >= 0.0f - margin && y <= 3.0f + margin)
        min_dist = std::min(min_dist, std::abs(x + 3.0f));

    // Right wall (x=3)
    if (z >= 0.0f - margin && z <= 5.0f + margin &&
        y >= 0.0f - margin && y <= 3.0f + margin)
        min_dist = std::min(min_dist, std::abs(x - 3.0f));

    // Table top (y=0.75, limited x/z range)
    if (x >= -0.3f - margin && x <= 0.3f + margin &&
        z >= 1.5f - margin && z <= 2.1f + margin)
        min_dist = std::min(min_dist, std::abs(y - 0.75f));

    return min_dist;
}

static TileResult simulate_tsdf_tiles(
    const Camera& cam,
    const std::vector<float>& metric_depth,
    float voxel_size = 0.01f)  // VOXEL_SIZE_MID = 10mm → block = 8cm
{
    TileResult result{};
    const float* m = cam.transform;

    // Simulate creating TSDF blocks at every Nth pixel
    float block_world = voxel_size * 8;  // BLOCK_SIZE = 8
    std::vector<bool> visited(1000000, false);  // Simple hash

    for (int v = 0; v < cam.height; v += 4) {
        for (int u = 0; u < cam.width; u += 4) {
            float d = metric_depth[v * cam.width + u];
            if (d < 0.1f || d > 5.0f) continue;

            // Unproject to world (same as tsdf_volume.cpp)
            float x_cam = (static_cast<float>(u) - cam.cx) * d / cam.fx;
            float y_cam = -(static_cast<float>(v) - cam.cy) * d / cam.fy;
            float z_cam = -d;

            float wx = m[0]*x_cam + m[4]*y_cam + m[8]*z_cam  + m[12];
            float wy = m[1]*x_cam + m[5]*y_cam + m[9]*z_cam  + m[13];
            float wz = m[2]*x_cam + m[6]*y_cam + m[10]*z_cam + m[14];

            // Block index (simple hash for dedup)
            int bx = static_cast<int>(std::floor(wx / block_world));
            int by = static_cast<int>(std::floor(wy / block_world));
            int bz = static_cast<int>(std::floor(wz / block_world));
            int hash = ((bx * 73856093) ^ (by * 19349669) ^ (bz * 83492791)) & 999999;
            if (hash < 0) hash = -hash;
            hash %= 1000000;
            if (visited[hash]) continue;
            visited[hash] = true;

            // Block center
            float tile_x = (bx + 0.5f) * block_world;
            float tile_y = (by + 0.5f) * block_world;
            float tile_z = (bz + 0.5f) * block_world;

            float dist = distance_to_nearest_surface(tile_x, tile_y, tile_z);
            result.mean_surface_dist += dist;
            result.total_tiles++;

            // Block-size-aware thresholds:
            // A block center can be up to half_block from any surface inside it.
            // half_block = block_world / 2. With voxel_size=0.01, half_block=0.04m.
            // Add margin for depth estimation error.
            float half_block = block_world * 0.5f;
            float on_surface_thresh = half_block + 0.03f;   // ~7cm for 0.01 voxels
            float floating_thresh = block_world * 3.0f;     // ~24cm for 0.01 voxels

            if (dist < on_surface_thresh) result.tiles_on_surface++;
            else if (dist > floating_thresh) result.tiles_floating++;
        }
    }

    if (result.total_tiles > 0)
        result.mean_surface_dist /= result.total_tiles;

    return result;
}

// ══════════════════════════════════════════════════════════════════════
// Main test
// ══════════════════════════════════════════════════════════════════════

int main() {
    std::printf("\n");
    std::printf("╔═══════════════════════════════════════════════════════════════╗\n");
    std::printf("║  Aether3D Affine Depth Alignment Simulation Test             ║\n");
    std::printf("║  Synthetic Room: 6m×3m×5m + Table                            ║\n");
    std::printf("║  OLD (scale-only) vs NEW (affine scale+shift)                ║\n");
    std::printf("╚═══════════════════════════════════════════════════════════════╝\n\n");

    // Define 3 camera positions (simulating scanning walk)
    struct CamSetup {
        float pos[3];
        float look[3];
        const char* name;
    };
    CamSetup cameras[] = {
        {{0.0f, 1.5f, 0.5f}, {0.0f, 0.0f, 3.0f}, "Front (looking at floor+table)"},
        {{-1.0f, 1.5f, 2.0f}, {1.0f, 0.5f, 3.0f}, "Left (looking at wall+floor)"},
        {{1.0f, 1.2f, 1.0f}, {0.0f, 0.8f, 2.0f}, "Right (looking at table close-up)"},
    };
    int num_cameras = 3;

    int total_pass = 0;
    int total_fail = 0;

    for (int ci = 0; ci < num_cameras; ++ci) {
        auto& cs = cameras[ci];
        Camera cam = make_camera(cs.pos[0], cs.pos[1], cs.pos[2],
                                 cs.look[0], cs.look[1], cs.look[2]);

        std::printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
        std::printf("Camera %d: %s\n", ci + 1, cs.name);
        std::printf("  Position: (%.1f, %.1f, %.1f)m\n", cs.pos[0], cs.pos[1], cs.pos[2]);
        std::printf("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

        // 1. Ray-cast ground truth
        std::vector<float> gt_depth;
        render_depth(cam, gt_depth);

        // Count valid pixels
        int valid_px = 0;
        float min_depth = 1e9f, max_depth = 0;
        for (float d : gt_depth) {
            if (d > 0.01f) {
                valid_px++;
                min_depth = std::min(min_depth, d);
                max_depth = std::max(max_depth, d);
            }
        }
        std::printf("  Ground truth: %d valid pixels, depth range [%.2f, %.2f]m\n",
                    valid_px, min_depth, max_depth);

        // 2. Simulate DAv2 normalization
        std::vector<float> dav2_depth;
        float true_scale, true_shift;
        simulate_dav2_normalize(gt_depth, dav2_depth, true_scale, true_shift);
        // true_scale/shift are now in INVERSE DEPTH space:
        // 1/z = scale * d + shift, so z = 1/(scale*d + shift)
        float z_near = 1.0f / (true_scale + true_shift);  // d=1 (closest)
        float z_far  = 1.0f / true_shift;                  // d=0 (farthest)
        std::printf("  True inv-depth affine: scale=%.3f shift=%.3f (z=[%.2f, %.2f]m)\n",
                    true_scale, true_shift, z_near, z_far);

        // 3. Generate feature points
        std::vector<FeaturePoint> features;
        generate_feature_points(cam, gt_depth, features, 120);
        std::printf("  Feature points: %zu\n\n", features.size());

        // ── OLD ALGORITHM (linear scale-only, 4 bugs) ──
        float old_scale = old_estimate_scale(cam, dav2_depth, features);
        std::vector<float> old_metric(dav2_depth.size());
        for (std::size_t i = 0; i < dav2_depth.size(); ++i) {
            // BUG: linear model for inverse depth + no shift
            old_metric[i] = dav2_depth[i] * old_scale;
        }

        ErrorStats old_err = compute_error(gt_depth, old_metric, cam.width, cam.height);
        TileResult old_tiles = simulate_tsdf_tiles(cam, old_metric);

        std::printf("  ❌ OLD ALGORITHM (scale-only, 3 bugs):\n");
        std::printf("     Estimated scale=%.3f (true: scale=%.3f shift=%.3f)\n",
                    old_scale, true_scale, true_shift);
        std::printf("     Depth error:  mean=%.3fm  max=%.3fm  rel=%.1f%%\n",
                    old_err.mean_abs_error, old_err.max_abs_error, old_err.mean_rel_error);
        std::printf("     Within 5cm:   %.1f%%   Within 10cm: %.1f%%\n",
                    old_err.pct_within_5cm, old_err.pct_within_10cm);
        std::printf("     TSDF tiles:   %d total, %d on surface (%.0f%%), %d FLOATING (%.0f%%)\n",
                    old_tiles.total_tiles, old_tiles.tiles_on_surface,
                    old_tiles.total_tiles > 0 ? old_tiles.tiles_on_surface * 100.0f / old_tiles.total_tiles : 0.0f,
                    old_tiles.tiles_floating,
                    old_tiles.total_tiles > 0 ? old_tiles.tiles_floating * 100.0f / old_tiles.total_tiles : 0.0f);
        std::printf("     Avg tile-to-surface: %.3fm\n\n", old_tiles.mean_surface_dist);

        // ── NEW ALGORITHM (reciprocal affine in inverse-depth space, 4 fixes) ──
        float new_scale = 0, new_shift = 0;
        bool affine_ok = new_estimate_affine(cam, dav2_depth, features, new_scale, new_shift);

        std::vector<float> new_metric(dav2_depth.size());
        if (affine_ok) {
            for (std::size_t i = 0; i < dav2_depth.size(); ++i) {
                float inv_m = new_scale * dav2_depth[i] + new_shift;
                if (inv_m > 0.001f) {
                    float m_d = 1.0f / inv_m;  // RECIPROCAL: metric = 1/inv_depth
                    new_metric[i] = (m_d > 0.1f && m_d < 8.0f) ? m_d : 0.0f;
                } else {
                    new_metric[i] = 0.0f;
                }
            }
        }

        ErrorStats new_err = compute_error(gt_depth, new_metric, cam.width, cam.height);
        TileResult new_tiles = simulate_tsdf_tiles(cam, new_metric);

        std::printf("  ✅ NEW ALGORITHM (reciprocal affine in inv-depth, 4 fixes):\n");
        std::printf("     Estimated inv-depth: scale=%.3f shift=%.3f (true: s=%.3f t=%.3f)\n",
                    new_scale, new_shift, true_scale, true_shift);
        std::printf("     Depth error:  mean=%.3fm  max=%.3fm  rel=%.1f%%\n",
                    new_err.mean_abs_error, new_err.max_abs_error, new_err.mean_rel_error);
        std::printf("     Within 5cm:   %.1f%%   Within 10cm: %.1f%%\n",
                    new_err.pct_within_5cm, new_err.pct_within_10cm);
        std::printf("     TSDF tiles:   %d total, %d on surface (%.0f%%), %d floating (%.0f%%)\n",
                    new_tiles.total_tiles, new_tiles.tiles_on_surface,
                    new_tiles.total_tiles > 0 ? new_tiles.tiles_on_surface * 100.0f / new_tiles.total_tiles : 0.0f,
                    new_tiles.tiles_floating,
                    new_tiles.total_tiles > 0 ? new_tiles.tiles_floating * 100.0f / new_tiles.total_tiles : 0.0f);
        std::printf("     Avg tile-to-surface: %.3fm\n\n", new_tiles.mean_surface_dist);

        // ── Improvement summary ──
        float improvement = (old_err.mean_abs_error > 0.001f)
            ? (1.0f - new_err.mean_abs_error / old_err.mean_abs_error) * 100.0f
            : 0.0f;
        std::printf("  📊 Improvement: depth error reduced by %.0f%%\n", improvement);
        std::printf("     Old floating: %.0f%%  →  New floating: %.0f%%\n",
                    old_tiles.total_tiles > 0 ? old_tiles.tiles_floating * 100.0f / old_tiles.total_tiles : 0.0f,
                    new_tiles.total_tiles > 0 ? new_tiles.tiles_floating * 100.0f / new_tiles.total_tiles : 0.0f);

        // Test assertions (block-size-aware thresholds)
        // With VOXEL_SIZE_MID=0.01, blocks are 8cm. Half-block = 4cm.
        // Mean depth error < 15cm is excellent (old algorithm has 4-8m errors).
        bool depth_pass = new_err.mean_abs_error < 0.15f;  // < 15cm mean error
        // Floating tiles: < 10% (with proper block size, most tiles should be on surfaces)
        bool tile_pass = new_tiles.tiles_floating == 0 ||
                         (new_tiles.tiles_floating * 100.0f / std::max(1, new_tiles.total_tiles) < 10.0f);
        // Must be at least 2× better than old algorithm
        bool better = new_err.mean_abs_error < old_err.mean_abs_error * 0.5f;

        std::printf("  Tests: depth<15cm=%s  floating<10%%=%s  2x_better=%s\n\n",
                    depth_pass ? "PASS✓" : "FAIL✗",
                    tile_pass ? "PASS✓" : "FAIL✗",
                    better ? "PASS✓" : "FAIL✗");

        if (depth_pass) total_pass++; else total_fail++;
        if (tile_pass) total_pass++; else total_fail++;
        if (better) total_pass++; else total_fail++;
    }

    std::printf("══════════════════════════════════════════════════════════════\n");
    std::printf("FINAL: %d/%d tests passed\n", total_pass, total_pass + total_fail);
    std::printf("══════════════════════════════════════════════════════════════\n\n");

    return total_fail > 0 ? 1 : 0;
}
