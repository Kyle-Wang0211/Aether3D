// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_structural_plane_fit_c.h"
#include "../../third_party/glomap_vendor/bench/aether_ghost_mask.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

constexpr int32_t kOk = 0;
constexpr int32_t kBadArgs = 1;
constexpr int32_t kBufferTooSmall = 4;
constexpr std::array<double, 5> kCertificationOffsets = {
    -0.10, -0.05, 0.0, 0.05, 0.10};
constexpr double kFloorHistogramStepM = 0.02;

struct Vec3 {
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

Vec3 add(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec3 scale(Vec3 a, double s) { return {a.x * s, a.y * s, a.z * s}; }
double dot(Vec3 a, Vec3 b) {
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
    const double xy = a.x * b.x + a.y * b.y;
    return xy + a.z * b.z;
}
Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x};
}
double norm(Vec3 a) { return std::sqrt(dot(a, a)); }
Vec3 normalized(Vec3 a) {
    const double length = norm(a);
    return length > 0.0 ? scale(a, 1.0 / length) : Vec3{};
}

Vec3 subtract(Vec3 a, Vec3 b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

double percentile(std::vector<double> values, double q) {
    if (values.empty() || !(q >= 0.0 && q <= 1.0)) {
        return std::numeric_limits<double>::quiet_NaN();
    }
    std::sort(values.begin(), values.end());
    const double position = q * static_cast<double>(values.size() - 1);
    const std::size_t lower = static_cast<std::size_t>(std::floor(position));
    const std::size_t upper = static_cast<std::size_t>(std::ceil(position));
    const double fraction = position - static_cast<double>(lower);
    return values[lower] * (1.0 - fraction) + values[upper] * fraction;
}

double median(std::vector<double> values) { return percentile(std::move(values), 0.5); }

double numpy_percentile(std::vector<double> values, double q) {
    if (values.empty() || !(q >= 0.0 && q <= 1.0)) {
        return std::numeric_limits<double>::quiet_NaN();
    }
    std::sort(values.begin(), values.end());
    return aether_ghost::detail::PercentileSorted(values, q * 100.0);
}

double numpy_median(std::vector<double> values) {
    return values.empty()
        ? std::numeric_limits<double>::quiet_NaN()
        : aether_ghost::detail::Median1D(std::move(values));
}

struct Cell {
    std::int64_t a;
    std::int64_t b;
    bool operator==(const Cell& other) const { return a == other.a && b == other.b; }
};

struct CellHash {
    std::size_t operator()(const Cell& value) const {
        const std::uint64_t a = static_cast<std::uint64_t>(value.a);
        const std::uint64_t b = static_cast<std::uint64_t>(value.b);
        return static_cast<std::size_t>(
            (a * UINT64_C(0x9e3779b97f4a7c15)) ^
            (b + UINT64_C(0x9e3779b97f4a7c15) + (a << 6) + (a >> 2)));
    }
};

int32_t cell_count(const std::vector<double>& a,
                   const std::vector<double>& b,
                   double cell) {
    if (a.size() != b.size() || !(cell > 0.0)) return 0;
    std::unordered_set<Cell, CellHash> cells;
    cells.reserve(a.size());
    for (std::size_t index = 0; index < a.size(); ++index) {
        cells.insert({static_cast<std::int64_t>(std::floor(a[index] / cell)),
                      static_cast<std::int64_t>(std::floor(b[index] / cell))});
    }
    return static_cast<int32_t>(cells.size());
}

std::vector<int32_t> histogram(const std::vector<double>& values,
                               double low,
                               double high,
                               double step) {
    if (!(high > low) || !(step > 0.0)) return {};
    const int32_t bins = static_cast<int32_t>(std::ceil((high - low) / step));
    if (bins <= 0) return {};
    std::vector<int32_t> counts(static_cast<std::size_t>(bins), 0);
    for (const double value : values) {
        int32_t index = static_cast<int32_t>(std::floor((value - low) / step));
        if (value == high) index = bins - 1;
        if (index >= 0 && index < bins) ++counts[static_cast<std::size_t>(index)];
    }
    return counts;
}

std::vector<int32_t> top_histogram_indices(const std::vector<int32_t>& counts,
                                           int32_t maximum) {
    std::vector<int32_t> indices(counts.size());
    for (std::size_t i = 0; i < counts.size(); ++i) {
        indices[i] = static_cast<int32_t>(i);
    }
    std::stable_sort(indices.begin(), indices.end(), [&](int32_t a, int32_t b) {
        return counts[static_cast<std::size_t>(a)] <
               counts[static_cast<std::size_t>(b)];
    });
    if (indices.size() > static_cast<std::size_t>(maximum)) {
        indices.erase(indices.begin(), indices.end() - maximum);
    }
    return indices;
}

struct Candidate {
    int32_t theta_deg = 0;
    double value = 0.0;
    int32_t support = 0;
    int32_t cells = 0;
    double score = 0.0;
    std::array<double, 2> tangent_bounds{};
    std::array<double, 2> height_bounds{};
    double tangent_span = 0.0;
    double height_span = 0.0;
};

struct FloorProposal {
    Vec3 normal;
    double value = 0.0;
    Vec3 basis_u;
    Vec3 basis_v;
    std::array<double, 2> bounds_u{};
    std::array<double, 2> bounds_v{};
    int32_t support = 0;
    int32_t cells = 0;
    double rms = 0.0;
    double tilt_deg = 0.0;
    double prior_score = 0.0;
};

struct EnvelopeCandidate {
    double theta_deg = 0.0;
    double value = 0.0;
    Vec3 normal;
    Vec3 tangent;
    int32_t support = 0;
    int32_t cells = 0;
    double score = 0.0;
    std::array<double, 2> tangent_bounds{};
    std::array<double, 2> height_bounds{};
    double camera_distance_min = 0.0;
    double camera_distance_max = 0.0;
    double camera_clearance_min_abs = 0.0;
};

double fit_ceiling_height(const std::vector<double>& heights,
                          const std::vector<double>& coordinates_u,
                          const std::vector<double>& coordinates_v) {
    const double upper = percentile(heights, 0.998);
    std::vector<double> plausible;
    plausible.reserve(heights.size());
    for (const double height : heights) {
        if (height >= 1.80 && height <= upper) plausible.push_back(height);
    }
    if (plausible.size() < 100) return std::numeric_limits<double>::quiet_NaN();
    const double step = 0.01;
    const double maximum = *std::max_element(plausible.begin(), plausible.end());
    const int32_t bins = static_cast<int32_t>(std::ceil((maximum - 1.80) / step));
    if (bins <= 0) return std::numeric_limits<double>::quiet_NaN();
    const double high = 1.80 + static_cast<double>(bins) * step;
    const auto counts = histogram(plausible, 1.80, high, step);
    const auto candidates = top_histogram_indices(counts, 32);
    double best_score = -1.0;
    std::vector<double> best_heights;
    for (const int32_t index : candidates) {
        const double center = 1.80 + (static_cast<double>(index) + 0.5) * step;
        std::vector<double> chosen_h;
        std::vector<double> chosen_u;
        std::vector<double> chosen_v;
        for (std::size_t point = 0; point < heights.size(); ++point) {
            if (std::abs(heights[point] - center) <= 0.035) {
                chosen_h.push_back(heights[point]);
                chosen_u.push_back(coordinates_u[point]);
                chosen_v.push_back(coordinates_v[point]);
            }
        }
        if (chosen_h.size() < 100) continue;
        const int32_t cells = cell_count(chosen_u, chosen_v, 0.10);
        const double score = static_cast<double>(chosen_h.size()) *
                             std::sqrt(static_cast<double>(std::max(cells, 1)));
        if (score > best_score) {
            best_score = score;
            best_heights = std::move(chosen_h);
        }
    }
    return best_heights.empty()
        ? std::numeric_limits<double>::quiet_NaN()
        : median(std::move(best_heights));
}

void copy_vec(Vec3 value, double output[3]) {
    output[0] = value.x;
    output[1] = value.y;
    output[2] = value.z;
}

bool refine_floor_proposal(
    const std::vector<Vec3>& world_points,
    const std::vector<double>& local_xyz,
    const std::vector<uint8_t>& keep,
    Vec3 local_axis_x,
    Vec3 up,
    Vec3 local_axis_z,
    double anchor,
    const aether_structural_floor_proposal_options_t& options,
    FloorProposal* out) {
    if (!out || world_points.size() * 3 != local_xyz.size() ||
        keep.size() != world_points.size()) {
        return false;
    }
    int32_t anchor_support = 0;
    for (std::size_t index = 0; index < world_points.size(); ++index) {
        if (keep[index] &&
            std::abs(local_xyz[index * 3 + 1] - anchor) <
                options.refinement_band_m) {
            ++anchor_support;
        }
    }
    if (anchor_support < 20) return false;

    // Reuse the parity-calibrated three-pass least-squares refiner. Its local
    // Y axis is the supplied gravity hint, so the same routine works for every
    // platform/world convention.
    double local_normal[3] = {0.0, 1.0, 0.0};
    double local_d = 0.0;
    aether_ghost::FitFloorPlane(local_xyz.data(), world_points.size(),
                                local_normal, &local_d, &anchor);
    if (!std::isfinite(local_normal[0]) || !std::isfinite(local_normal[1]) ||
        !std::isfinite(local_normal[2]) || !std::isfinite(local_d)) {
        return false;
    }
    Vec3 normal = normalized(
        add(add(scale(local_axis_x, local_normal[0]),
                scale(up, local_normal[1])),
            scale(local_axis_z, local_normal[2])));
    double value = -local_d;
    if (dot(normal, up) < 0.0) {
        normal = scale(normal, -1.0);
        value = -value;
    }
    const double cosine = std::clamp(dot(normal, up), -1.0, 1.0);
    const double tilt_deg = std::acos(cosine) * 180.0 / M_PI;
    if (tilt_deg > options.maximum_tilt_deg) return false;

    Vec3 seed{1.0, 0.0, 0.0};
    if (std::abs(dot(seed, normal)) > 0.9) seed = {0.0, 0.0, 1.0};
    const Vec3 basis_u = normalized(subtract(seed, scale(normal, dot(seed, normal))));
    const Vec3 basis_v = normalized(cross(normal, basis_u));
    std::vector<double> support_u;
    std::vector<double> support_v;
    std::vector<double> coverage_u;
    std::vector<double> coverage_v;
    support_u.reserve(world_points.size());
    support_v.reserve(world_points.size());
    coverage_u.reserve(world_points.size());
    coverage_v.reserve(world_points.size());
    double squared_error = 0.0;
    for (const Vec3 point : world_points) {
        const double residual = dot(point, normal) - value;
        if (std::abs(residual) > options.support_band_m) continue;
        squared_error += residual * residual;
        support_u.push_back(dot(point, basis_u));
        support_v.push_back(dot(point, basis_v));
        // The experiment contract defines coverage in the fixed horizontal
        // gravity basis rather than in the slightly tilted fitted plane.
        coverage_u.push_back(dot(point, local_axis_x));
        coverage_v.push_back(dot(point, local_axis_z));
    }
    const int32_t support = static_cast<int32_t>(support_u.size());
    if (support < options.minimum_support_points) return false;
    const int32_t cells = cell_count(coverage_u, coverage_v, 0.10);
    if (cells < options.minimum_coverage_cells_10cm) return false;

    out->normal = normal;
    out->value = value;
    out->basis_u = basis_u;
    out->basis_v = basis_v;
    out->bounds_u = {percentile(support_u, 0.02) - 0.05,
                     percentile(support_u, 0.98) + 0.05};
    out->bounds_v = {percentile(support_v, 0.02) - 0.05,
                     percentile(support_v, 0.98) + 0.05};
    out->support = support;
    out->cells = cells;
    out->rms = std::sqrt(squared_error / static_cast<double>(support));
    out->tilt_deg = tilt_deg;
    out->prior_score = static_cast<double>(support) *
                       std::sqrt(static_cast<double>(cells));
    return true;
}

std::array<double, 2> smallest_eigenvector_2x2(double a,
                                                double b,
                                                double c) {
    const double lambda =
        0.5 * (a + c - std::hypot(a - c, 2.0 * b));
    double x = b;
    double y = lambda - a;
    if (std::abs(x) + std::abs(y) < 1e-30) {
        x = lambda - c;
        y = b;
    }
    if (std::abs(x) + std::abs(y) < 1e-30) {
        return a <= c ? std::array<double, 2>{1.0, 0.0}
                      : std::array<double, 2>{0.0, 1.0};
    }
    const double length = std::hypot(x, y);
    return {x / length, y / length};
}

void camera_distances(const std::vector<Vec3>& cameras,
                      Vec3 normal,
                      double value,
                      double* minimum,
                      double* maximum,
                      double* minimum_abs) {
    *minimum = std::numeric_limits<double>::infinity();
    *maximum = -std::numeric_limits<double>::infinity();
    *minimum_abs = std::numeric_limits<double>::infinity();
    for (const Vec3 camera : cameras) {
        const double distance = dot(camera, normal) - value;
        *minimum = std::min(*minimum, distance);
        *maximum = std::max(*maximum, distance);
        *minimum_abs = std::min(*minimum_abs, std::abs(distance));
    }
}

}  // namespace

extern "C" {

void aether_structural_plane_fit_options_default(
    aether_structural_plane_fit_options_t* out_options) {
    if (!out_options) return;
    out_options->max_walls = 6;
    out_options->theta_step_deg = 2;
    out_options->minimum_height_m = 0.15;
    out_options->wall_fit_band_m = 0.035;
    out_options->rho_step_m = 0.03;
    out_options->minimum_tangent_span_m = 0.60;
    out_options->minimum_height_span_m = 0.60;
    out_options->preliminary_minimum_support = 120;
    out_options->certified_minimum_support = 500;
    out_options->certified_minimum_cells = 50;
}

void aether_structural_floor_proposal_options_default(
    aether_structural_floor_proposal_options_t* out_options) {
    if (!out_options) return;
    out_options->maximum_candidates = 16;
    out_options->histogram_step_m = 0.02;
    out_options->minimum_peak_support = 20;
    out_options->refinement_band_m = 0.01;
    out_options->support_band_m = 0.02;
    out_options->minimum_support_points = 100;
    out_options->minimum_coverage_cells_10cm = 30;
    out_options->maximum_tilt_deg = 12.0;
    out_options->minimum_camera_clearance_m = 0.05;
    out_options->distinct_plane_value_m = 0.03;
}

void aether_structural_envelope_wall_options_default(
    aether_structural_envelope_wall_options_t* out_options) {
    if (!out_options) return;
    out_options->maximum_candidates = 32;
    out_options->theta_step_deg = 2;
    out_options->minimum_height_m = 0.15;
    out_options->maximum_height_percentile = 0.995;
    out_options->rho_step_m = 0.03;
    out_options->fit_band_m = 0.035;
    out_options->minimum_support = 120;
    out_options->minimum_tangent_span_m = 0.60;
    out_options->minimum_height_span_m = 0.60;
    out_options->camera_crossing_tolerance_m = 0.05;
    out_options->duplicate_angle_deg = 4;
    out_options->duplicate_plane_value_m = 0.10;
}

int32_t aether_structural_propose_floors(
    const float* points_xyz,
    int32_t point_count,
    const double up_hint_xyz[3],
    double minimum_camera_height,
    const aether_structural_floor_proposal_options_t* options,
    aether_structural_floor_proposal_t* out_proposals,
    int32_t proposal_capacity,
    int32_t* out_proposal_count) {
    if (!points_xyz || point_count < 100 || !up_hint_xyz || !options ||
        !out_proposal_count || options->maximum_candidates <= 0 ||
        !(options->histogram_step_m > 0.0) ||
        options->minimum_peak_support < 1 ||
        !(options->refinement_band_m > 0.0) ||
        !(options->support_band_m > 0.0) ||
        options->minimum_support_points < 20 ||
        options->minimum_coverage_cells_10cm < 1 ||
        !(options->maximum_tilt_deg > 0.0) ||
        !(options->minimum_camera_clearance_m >= 0.0) ||
        !(options->distinct_plane_value_m >= 0.0) ||
        !std::isfinite(minimum_camera_height) || proposal_capacity < 0) {
        return kBadArgs;
    }
    *out_proposal_count = 0;
    const Vec3 up = normalized({up_hint_xyz[0], up_hint_xyz[1], up_hint_xyz[2]});
    if (!(norm(up) > 0.0)) return kBadArgs;
    Vec3 axis_x{1.0, 0.0, 0.0};
    if (std::abs(dot(axis_x, up)) > 0.9) axis_x = {0.0, 0.0, 1.0};
    axis_x = normalized(subtract(axis_x, scale(up, dot(axis_x, up))));
    const Vec3 axis_z = normalized(cross(axis_x, up));

    std::vector<Vec3> points;
    std::vector<double> local_xyz;
    points.reserve(static_cast<std::size_t>(point_count));
    local_xyz.reserve(static_cast<std::size_t>(point_count) * 3);
    for (int32_t index = 0; index < point_count; ++index) {
        const Vec3 point{points_xyz[index * 3], points_xyz[index * 3 + 1],
                         points_xyz[index * 3 + 2]};
        if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
            !std::isfinite(point.z)) {
            continue;
        }
        points.push_back(point);
        local_xyz.push_back(dot(point, axis_x));
        local_xyz.push_back(dot(point, up));
        local_xyz.push_back(dot(point, axis_z));
    }
    if (points.size() < 100) return kBadArgs;

    std::array<double, 3> low{};
    std::array<double, 3> high{};
    std::array<double, 3> lower{};
    std::array<double, 3> upper{};
    for (int axis = 0; axis < 3; ++axis) {
        std::vector<double> values;
        values.reserve(points.size());
        for (std::size_t index = 0; index < points.size(); ++index) {
            values.push_back(local_xyz[index * 3 + axis]);
        }
        low[axis] = percentile(values, 0.02);
        high[axis] = percentile(std::move(values), 0.98);
        lower[axis] = low[axis] - 0.5 * (high[axis] - low[axis]);
        upper[axis] = high[axis] + 0.5 * (high[axis] - low[axis]);
    }
    std::vector<uint8_t> keep(points.size(), 0);
    std::vector<double> heights;
    heights.reserve(points.size());
    for (std::size_t index = 0; index < points.size(); ++index) {
        bool inside = true;
        for (int axis = 0; axis < 3; ++axis) {
            const double value = local_xyz[index * 3 + axis];
            inside = inside && value >= lower[axis] && value <= upper[axis];
        }
        if (!inside) continue;
        keep[index] = 1;
        heights.push_back(local_xyz[index * 3 + 1]);
    }
    if (heights.size() < 100) return kBadArgs;
    const double minimum = *std::min_element(heights.begin(), heights.end());
    const double maximum = std::min(
        {*std::max_element(heights.begin(), heights.end()),
         low[1] + 0.25 * (high[1] - low[1]),
         minimum_camera_height - options->minimum_camera_clearance_m});
    if (!(maximum > minimum)) return kBadArgs;
    const auto edges = aether_ghost::detail::Arange(
        minimum, maximum + options->histogram_step_m * 1.001,
        options->histogram_step_m);
    if (edges.size() < 2) return kBadArgs;
    const auto counts = aether_ghost::detail::Histogram(heights, edges);
    std::vector<FloorProposal> raw;
    for (std::size_t index = 0; index < counts.size(); ++index) {
        const int64_t count = counts[index];
        const int64_t left = index == 0 ? -1 : counts[index - 1];
        const int64_t right = index + 1 < counts.size() ? counts[index + 1] : -1;
        if (count < options->minimum_peak_support || count < left || count < right) {
            continue;
        }
        const double anchor = (edges[index] + edges[index + 1]) * 0.5;
        FloorProposal proposal;
        if (refine_floor_proposal(points, local_xyz, keep, axis_x, up, axis_z,
                                  anchor, *options, &proposal)) {
            raw.push_back(proposal);
        }
    }
    std::stable_sort(raw.begin(), raw.end(), [](const FloorProposal& a,
                                                const FloorProposal& b) {
        return a.prior_score > b.prior_score;
    });
    std::vector<FloorProposal> distinct;
    for (const FloorProposal& proposal : raw) {
        bool duplicate = false;
        for (const FloorProposal& prior : distinct) {
            if (std::abs(proposal.value - prior.value) <
                options->distinct_plane_value_m) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        distinct.push_back(proposal);
        if (distinct.size() >=
            static_cast<std::size_t>(options->maximum_candidates)) {
            break;
        }
    }
    std::stable_sort(distinct.begin(), distinct.end(),
                     [](const FloorProposal& a, const FloorProposal& b) {
                         return a.value < b.value;
                     });
    *out_proposal_count = static_cast<int32_t>(distinct.size());
    if (proposal_capacity < *out_proposal_count ||
        (!out_proposals && *out_proposal_count > 0)) {
        return kBufferTooSmall;
    }
    for (std::size_t index = 0; index < distinct.size(); ++index) {
        const FloorProposal& source = distinct[index];
        aether_structural_floor_proposal_t output{};
        output.proposal_index = static_cast<int32_t>(index);
        output.support_points_20mm = source.support;
        output.coverage_cells_10cm = source.cells;
        copy_vec(source.normal, output.normal_xyz);
        output.value_n_dot_x = source.value;
        copy_vec(source.basis_u, output.basis_u_xyz);
        copy_vec(source.basis_v, output.basis_v_xyz);
        output.bounds_u_m[0] = source.bounds_u[0];
        output.bounds_u_m[1] = source.bounds_u[1];
        output.bounds_v_m[0] = source.bounds_v[0];
        output.bounds_v_m[1] = source.bounds_v[1];
        output.rms_error_m = source.rms;
        output.tilt_deg = source.tilt_deg;
        output.prior_score = source.prior_score;
        out_proposals[index] = output;
    }
    return kOk;
}

int32_t aether_structural_propose_envelope_walls(
    const float* points_xyz,
    int32_t point_count,
    const double* camera_centers_xyz,
    int32_t camera_count,
    const double floor_normal_xyz[3],
    double floor_value_n_dot_x,
    const aether_structural_envelope_wall_options_t* options,
    aether_structural_envelope_wall_t* out_walls,
    int32_t wall_capacity,
    int32_t* out_wall_count) {
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
    if (!points_xyz || point_count < 100 || !camera_centers_xyz ||
        camera_count < 3 || !floor_normal_xyz || !options || !out_wall_count ||
        options->maximum_candidates <= 0 || options->theta_step_deg <= 0 ||
        180 % options->theta_step_deg != 0 ||
        !(options->minimum_height_m >= 0.0) ||
        !(options->maximum_height_percentile > 0.0 &&
          options->maximum_height_percentile <= 1.0) ||
        !(options->rho_step_m > 0.0) || !(options->fit_band_m > 0.0) ||
        options->minimum_support < 1 ||
        !(options->minimum_tangent_span_m > 0.0) ||
        !(options->minimum_height_span_m > 0.0) ||
        !(options->camera_crossing_tolerance_m >= 0.0) ||
        options->duplicate_angle_deg < 0 ||
        !(options->duplicate_plane_value_m >= 0.0) ||
        !std::isfinite(floor_value_n_dot_x) || wall_capacity < 0) {
        return kBadArgs;
    }
    *out_wall_count = 0;
    const Vec3 up = normalized(
        {floor_normal_xyz[0], floor_normal_xyz[1], floor_normal_xyz[2]});
    if (!(norm(up) > 0.0)) return kBadArgs;
    Vec3 seed{1.0, 0.0, 0.0};
    if (std::abs(dot(seed, up)) > 0.9) seed = {0.0, 0.0, 1.0};
    const Vec3 axis_u = normalized(subtract(seed, scale(up, dot(seed, up))));
    const Vec3 axis_v = normalized(cross(up, axis_u));

    std::vector<Vec3> cameras;
    cameras.reserve(static_cast<std::size_t>(camera_count));
    for (int32_t index = 0; index < camera_count; ++index) {
        const Vec3 camera{camera_centers_xyz[index * 3],
                          camera_centers_xyz[index * 3 + 1],
                          camera_centers_xyz[index * 3 + 2]};
        if (!std::isfinite(camera.x) || !std::isfinite(camera.y) ||
            !std::isfinite(camera.z)) {
            return kBadArgs;
        }
        cameras.push_back(camera);
    }

    std::vector<Vec3> finite_points;
    std::vector<double> finite_heights;
    finite_points.reserve(static_cast<std::size_t>(point_count));
    finite_heights.reserve(static_cast<std::size_t>(point_count));
    std::vector<double> supported_heights;
    for (int32_t index = 0; index < point_count; ++index) {
        const Vec3 point{points_xyz[index * 3], points_xyz[index * 3 + 1],
                         points_xyz[index * 3 + 2]};
        if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
            !std::isfinite(point.z)) {
            continue;
        }
        const double height = dot(point, up) - floor_value_n_dot_x;
        finite_points.push_back(point);
        finite_heights.push_back(height);
        if (height >= options->minimum_height_m) {
            supported_heights.push_back(height);
        }
    }
    if (supported_heights.size() < 100) return kBadArgs;
    const double maximum_height =
        numpy_percentile(std::move(supported_heights),
                         options->maximum_height_percentile);
    std::vector<Vec3> points;
    std::vector<double> heights;
    std::vector<double> coordinate_u;
    std::vector<double> coordinate_v;
    for (std::size_t index = 0; index < finite_points.size(); ++index) {
        if (finite_heights[index] < options->minimum_height_m ||
            finite_heights[index] > maximum_height) {
            continue;
        }
        const Vec3 point = finite_points[index];
        points.push_back(point);
        heights.push_back(finite_heights[index]);
        coordinate_u.push_back(dot(point, axis_u));
        coordinate_v.push_back(dot(point, axis_v));
    }
    if (points.size() < 100) return kBadArgs;

    std::vector<EnvelopeCandidate> raw;
    for (int32_t theta_deg = 0; theta_deg < 180;
         theta_deg += options->theta_step_deg) {
        // Match Python math.radians exactly: multiply by the already-divided
        // conversion constant. `(degrees * pi) / 180` differs by one ULP for
        // some integer angles and can flip finite-domain boundary points.
        const double theta =
            static_cast<double>(theta_deg) * (M_PI / 180.0);
        const double cosine = std::cos(theta);
        const double sine = std::sin(theta);
        std::vector<double> rho;
        rho.reserve(points.size());
        for (std::size_t index = 0; index < points.size(); ++index) {
            rho.push_back(coordinate_u[index] * cosine +
                          coordinate_v[index] * sine);
        }
        const double low = std::floor(numpy_percentile(rho, 0.005) /
                                      options->rho_step_m) *
                           options->rho_step_m;
        const double high = std::ceil(numpy_percentile(rho, 0.995) /
                                       options->rho_step_m) *
                            options->rho_step_m;
        const auto edges = aether_ghost::detail::Arange(
            low, high + options->rho_step_m * 1.01, options->rho_step_m);
        if (edges.size() < 2) continue;
        const auto counts = aether_ghost::detail::Histogram(rho, edges);
        for (std::size_t bin = 0; bin < counts.size(); ++bin) {
            const int64_t count = counts[bin];
            const int64_t left = bin == 0 ? -1 : counts[bin - 1];
            const int64_t right = bin + 1 < counts.size() ? counts[bin + 1] : -1;
            if (count < options->minimum_support || count < left ||
                count < right) {
                continue;
            }
            const double initial = (edges[bin] + edges[bin + 1]) * 0.5;
            std::vector<double> preliminary;
            for (const double value : rho) {
                if (std::abs(value - initial) <= options->fit_band_m) {
                    preliminary.push_back(value);
                }
            }
            if (preliminary.size() <
                static_cast<std::size_t>(options->minimum_support)) {
                continue;
            }
            const double value = numpy_median(std::move(preliminary));
            std::vector<double> tangent_inlier;
            std::vector<double> height_inlier;
            for (std::size_t index = 0; index < rho.size(); ++index) {
                if (std::abs(rho[index] - value) > options->fit_band_m) continue;
                tangent_inlier.push_back(-coordinate_u[index] * sine +
                                          coordinate_v[index] * cosine);
                height_inlier.push_back(heights[index]);
            }
            const double tangent_span = numpy_percentile(tangent_inlier, 0.98) -
                                        numpy_percentile(tangent_inlier, 0.02);
            const double height_span = numpy_percentile(height_inlier, 0.98) -
                                       numpy_percentile(height_inlier, 0.02);
            if (tangent_span < options->minimum_tangent_span_m ||
                height_span < options->minimum_height_span_m) {
                continue;
            }
            // axis_u/axis_v are orthonormal and cosine/sine lie on the unit
            // circle.  Keep the same arithmetic path as the NumPy reference:
            // a second normalization only adds cross-platform ULP drift at
            // finite-domain boundaries without changing the geometry.
            const Vec3 normal =
                add(scale(axis_u, cosine), scale(axis_v, sine));
            const Vec3 tangent =
                add(scale(axis_u, -sine), scale(axis_v, cosine));
            double camera_min = 0.0;
            double camera_max = 0.0;
            double camera_min_abs = 0.0;
            camera_distances(cameras, normal, value, &camera_min, &camera_max,
                             &camera_min_abs);
            if (!(camera_min >= -options->camera_crossing_tolerance_m ||
                  camera_max <= options->camera_crossing_tolerance_m)) {
                continue;
            }
            const int32_t cells = cell_count(tangent_inlier, height_inlier, 0.10);
            raw.push_back({
                static_cast<double>(theta_deg), value, normal, tangent,
                static_cast<int32_t>(tangent_inlier.size()), cells,
                static_cast<double>(cells) *
                    std::sqrt(static_cast<double>(tangent_inlier.size())),
                {numpy_percentile(tangent_inlier, 0.01),
                 numpy_percentile(tangent_inlier, 0.99)},
                {numpy_percentile(height_inlier, 0.01),
                 numpy_percentile(height_inlier, 0.99)},
                camera_min, camera_max, camera_min_abs});
        }
    }
    std::stable_sort(raw.begin(), raw.end(), [](const EnvelopeCandidate& a,
                                                const EnvelopeCandidate& b) {
        return a.score > b.score;
    });
    std::vector<EnvelopeCandidate> selected;
    for (const EnvelopeCandidate& candidate : raw) {
        bool duplicate = false;
        for (const EnvelopeCandidate& prior : selected) {
            double angle = std::abs(candidate.theta_deg - prior.theta_deg);
            angle = std::min(angle, 180.0 - angle);
            if (angle <= static_cast<double>(options->duplicate_angle_deg) &&
                std::abs(candidate.value - prior.value) <
                    options->duplicate_plane_value_m) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        selected.push_back(candidate);
        if (selected.size() >=
            static_cast<std::size_t>(options->maximum_candidates)) {
            break;
        }
    }

    for (std::size_t candidate_index = 0; candidate_index < selected.size();
         ++candidate_index) {
        EnvelopeCandidate& candidate = selected[candidate_index];
        std::vector<std::size_t> local;
        double mean_u = 0.0;
        double mean_v = 0.0;
        for (std::size_t index = 0; index < points.size(); ++index) {
            const double tangent_coordinate = dot(points[index], candidate.tangent);
            if (heights[index] < candidate.height_bounds[0] ||
                heights[index] > candidate.height_bounds[1] ||
                tangent_coordinate < candidate.tangent_bounds[0] ||
                tangent_coordinate > candidate.tangent_bounds[1] ||
                std::abs(dot(points[index], candidate.normal) - candidate.value) >
                    options->fit_band_m) {
                continue;
            }
            local.push_back(index);
            mean_u += coordinate_u[index];
            mean_v += coordinate_v[index];
        }
        if (local.size() < static_cast<std::size_t>(options->minimum_support)) {
            continue;
        }
        mean_u /= static_cast<double>(local.size());
        mean_v /= static_cast<double>(local.size());
        double covariance_uu = 0.0;
        double covariance_uv = 0.0;
        double covariance_vv = 0.0;
        for (const std::size_t index : local) {
            const double du = coordinate_u[index] - mean_u;
            const double dv = coordinate_v[index] - mean_v;
            covariance_uu += du * du;
            covariance_uv += du * dv;
            covariance_vv += dv * dv;
        }
        auto refined = smallest_eigenvector_2x2(
            covariance_uu, covariance_uv, covariance_vv);
        const std::array<double, 2> original = {
            dot(candidate.normal, axis_u), dot(candidate.normal, axis_v)};
        if (refined[0] * original[0] + refined[1] * original[1] < 0.0) {
            refined[0] = -refined[0];
            refined[1] = -refined[1];
        }
        const double cosine = refined[0];
        const double sine = refined[1];
        const Vec3 normal =
            add(scale(axis_u, cosine), scale(axis_v, sine));
        const Vec3 tangent =
            add(scale(axis_u, -sine), scale(axis_v, cosine));
        std::vector<double> values;
        values.reserve(local.size());
        for (const std::size_t index : local) {
            values.push_back(dot(points[index], normal));
        }
        const double value = numpy_median(std::move(values));
        double camera_min = 0.0;
        double camera_max = 0.0;
        double camera_min_abs = 0.0;
        camera_distances(cameras, normal, value, &camera_min, &camera_max,
                         &camera_min_abs);
        if (!(camera_min >= -options->camera_crossing_tolerance_m ||
              camera_max <= options->camera_crossing_tolerance_m)) {
            continue;
        }
        std::vector<double> tangent_values;
        std::vector<double> local_heights;
        tangent_values.reserve(local.size());
        local_heights.reserve(local.size());
        for (const std::size_t index : local) {
            tangent_values.push_back(dot(points[index], tangent));
            local_heights.push_back(heights[index]);
        }
        double theta = std::atan2(sine, cosine) * 180.0 / M_PI;
        if (theta < 0.0) theta += 180.0;
        candidate.theta_deg = theta;
        candidate.value = value;
        candidate.normal = normal;
        candidate.tangent = tangent;
        candidate.support = static_cast<int32_t>(local.size());
        candidate.cells = cell_count(tangent_values, local_heights, 0.10);
        candidate.score = static_cast<double>(candidate.cells) *
                          std::sqrt(static_cast<double>(candidate.support));
        candidate.tangent_bounds = {numpy_percentile(tangent_values, 0.01),
                                    numpy_percentile(tangent_values, 0.99)};
        candidate.height_bounds = {numpy_percentile(local_heights, 0.01),
                                   numpy_percentile(local_heights, 0.99)};
        candidate.camera_distance_min = camera_min;
        candidate.camera_distance_max = camera_max;
        candidate.camera_clearance_min_abs = camera_min_abs;
    }

    *out_wall_count = static_cast<int32_t>(selected.size());
    if (wall_capacity < *out_wall_count ||
        (!out_walls && *out_wall_count > 0)) {
        return kBufferTooSmall;
    }
    for (std::size_t index = 0; index < selected.size(); ++index) {
        const EnvelopeCandidate& source = selected[index];
        aether_structural_envelope_wall_t output{};
        output.proposal_index = static_cast<int32_t>(index);
        output.support_points_35mm = source.support;
        output.coverage_cells_10cm = source.cells;
        output.theta_deg = source.theta_deg;
        copy_vec(source.normal, output.normal_xyz);
        copy_vec(source.tangent, output.basis_u_xyz);
        copy_vec(up, output.basis_v_xyz);
        output.plane_value_n_dot_x = source.value;
        output.bounds_u_m[0] = source.tangent_bounds[0];
        output.bounds_u_m[1] = source.tangent_bounds[1];
        output.bounds_height_m[0] = source.height_bounds[0];
        output.bounds_height_m[1] = source.height_bounds[1];
        output.score = source.score;
        output.camera_distance_min_m = source.camera_distance_min;
        output.camera_distance_max_m = source.camera_distance_max;
        output.camera_clearance_min_abs_m = source.camera_clearance_min_abs;
        out_walls[index] = output;
    }
    return kOk;
}

int32_t aether_structural_fit_floor(
    const float* points_xyz,
    int32_t point_count,
    const double up_hint_xyz[3],
    aether_structural_floor_t* out_floor) {
    if (!points_xyz || point_count < 100 || !up_hint_xyz || !out_floor) {
        return kBadArgs;
    }
    *out_floor = {};
    Vec3 up = normalized({up_hint_xyz[0], up_hint_xyz[1], up_hint_xyz[2]});
    if (!(norm(up) > 0.0)) return kBadArgs;

    // Reuse the production ghost-mask floor fitter instead of maintaining a
    // second peak selector. Rotate into a gravity-aligned frame so the exact
    // existing Y-up implementation remains the single source of truth.
    Vec3 axis_x{1.0, 0.0, 0.0};
    if (std::abs(dot(axis_x, up)) > 0.9) axis_x = {0.0, 0.0, 1.0};
    axis_x = normalized(subtract(axis_x, scale(up, dot(axis_x, up))));
    const Vec3 axis_z = normalized(cross(axis_x, up));

    std::vector<Vec3> points;
    std::vector<double> local_xyz;
    points.reserve(static_cast<std::size_t>(point_count));
    local_xyz.reserve(static_cast<std::size_t>(point_count) * 3);
    for (int32_t index = 0; index < point_count; ++index) {
        const Vec3 point{points_xyz[index * 3], points_xyz[index * 3 + 1],
                         points_xyz[index * 3 + 2]};
        if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
            !std::isfinite(point.z)) {
            continue;
        }
        points.push_back(point);
        local_xyz.push_back(dot(point, axis_x));
        local_xyz.push_back(dot(point, up));
        local_xyz.push_back(dot(point, axis_z));
    }
    if (points.size() < 100) return kBadArgs;

    // The raw histogram maximum is unstable when a nearby parallel layer has
    // slightly more points but covers much less physical area. Keep only
    // gravity-low candidates, then score support together with 10cm spatial
    // coverage. This strengthens peak ownership without adding another
    // reconstruction stage or consuming image/model/depth inputs.
    std::array<double, 3> low{};
    std::array<double, 3> high{};
    std::array<double, 3> lower_bound{};
    std::array<double, 3> upper_bound{};
    for (int axis = 0; axis < 3; ++axis) {
        std::vector<double> values;
        values.reserve(points.size());
        for (std::size_t index = 0; index < points.size(); ++index) {
            values.push_back(local_xyz[index * 3 + axis]);
        }
        low[axis] = percentile(values, 0.02);
        high[axis] = percentile(std::move(values), 0.98);
        lower_bound[axis] = low[axis] - (high[axis] - low[axis]) * 0.5;
        upper_bound[axis] = high[axis] + (high[axis] - low[axis]) * 0.5;
    }
    std::vector<uint8_t> kept(points.size(), 0);
    std::vector<double> kept_height;
    kept_height.reserve(points.size());
    for (std::size_t index = 0; index < points.size(); ++index) {
        bool inside = true;
        for (int axis = 0; axis < 3; ++axis) {
            const double value = local_xyz[index * 3 + axis];
            inside = inside && value >= lower_bound[axis] &&
                     value <= upper_bound[axis];
        }
        if (!inside) continue;
        kept[index] = 1;
        kept_height.push_back(local_xyz[index * 3 + 1]);
    }
    if (kept_height.size() < 100) return kBadArgs;
    const double minimum_height =
        *std::min_element(kept_height.begin(), kept_height.end());
    const double maximum_height =
        *std::max_element(kept_height.begin(), kept_height.end());
    const auto counts = histogram(kept_height, minimum_height,
                                  maximum_height + kFloorHistogramStepM,
                                  kFloorHistogramStepM);
    const auto candidates = top_histogram_indices(counts, 32);
    const double maximum_floor_height =
        low[1] + 0.25 * (high[1] - low[1]);
    double best_score = -1.0;
    double floor_anchor = std::numeric_limits<double>::quiet_NaN();
    for (const int32_t candidate : candidates) {
        const double center = minimum_height +
            (static_cast<double>(candidate) + 0.5) * kFloorHistogramStepM;
        if (center > maximum_floor_height) continue;
        std::vector<double> support_x;
        std::vector<double> support_z;
        for (std::size_t index = 0; index < points.size(); ++index) {
            if (!kept[index] ||
                std::abs(local_xyz[index * 3 + 1] - center) > 0.02) {
                continue;
            }
            support_x.push_back(local_xyz[index * 3]);
            support_z.push_back(local_xyz[index * 3 + 2]);
        }
        if (support_x.size() < 100) continue;
        const int32_t cells = cell_count(support_x, support_z, 0.10);
        const double score = static_cast<double>(support_x.size()) *
                             std::sqrt(static_cast<double>(std::max(cells, 1)));
        if (score > best_score ||
            (score == best_score && center < floor_anchor)) {
            best_score = score;
            floor_anchor = center;
        }
    }
    if (!std::isfinite(floor_anchor)) return kBadArgs;
    // Adjacent 2cm bins can be samples of the same mildly tilted floor. The
    // broad-window score selects the physical peak cluster; retain the raw
    // histogram maximum inside that cluster as the LSQ anchor so a slope does
    // not bias the plane toward the cluster's lower edge.
    int32_t anchor_bin = -1;
    int32_t anchor_count = -1;
    for (std::size_t index = 0; index < counts.size(); ++index) {
        const double center = minimum_height +
            (static_cast<double>(index) + 0.5) * kFloorHistogramStepM;
        if (std::abs(center - floor_anchor) > 0.05 ||
            center > maximum_floor_height) {
            continue;
        }
        if (counts[index] > anchor_count) {
            anchor_count = counts[index];
            anchor_bin = static_cast<int32_t>(index);
        }
    }
    if (anchor_bin < 0) return kBadArgs;
    floor_anchor = minimum_height +
        (static_cast<double>(anchor_bin) + 0.5) * kFloorHistogramStepM;
    double local_normal[3] = {0.0, 1.0, 0.0};
    double local_d = 0.0;
    aether_ghost::FitFloorPlane(local_xyz.data(), points.size(), local_normal,
                                &local_d, &floor_anchor);
    Vec3 normal = add(add(scale(axis_x, local_normal[0]),
                          scale(up, local_normal[1])),
                      scale(axis_z, local_normal[2]));
    normal = normalized(normal);
    if (dot(normal, up) < 0.0) {
        normal = scale(normal, -1.0);
        local_d = -local_d;
    }
    if (dot(normal, up) < std::cos(12.0 * M_PI / 180.0)) return kBadArgs;
    const double value = -local_d;

    std::vector<double> support_u;
    std::vector<double> support_v;
    support_u.reserve(points.size());
    support_v.reserve(points.size());
    double squared_error = 0.0;
    int32_t support_points = 0;
    for (const Vec3 point : points) {
        const double error = dot(point, normal) - value;
        if (std::abs(error) > 0.02) continue;
        squared_error += error * error;
        support_u.push_back(dot(point, axis_x));
        support_v.push_back(dot(point, axis_z));
        ++support_points;
    }
    if (support_points < 100) return kBadArgs;
    const int32_t cells = cell_count(support_u, support_v, 0.10);
    const double rms =
        std::sqrt(squared_error / static_cast<double>(support_points));
    out_floor->support_points = support_points;
    out_floor->coverage_cells_10cm = cells;
    copy_vec(normal, out_floor->normal_xyz);
    out_floor->value_n_dot_x = value;
    out_floor->rms_error_m = rms;
    out_floor->certified =
        support_points >= 500 && cells >= 50 && rms <= 0.02 ? 1 : 0;
    return kOk;
}

int32_t aether_structural_fit_walls(
    const float* points_xyz,
    int32_t point_count,
    const double floor_normal_xyz[3],
    double floor_value_n_dot_x,
    const aether_structural_plane_fit_options_t* options,
    aether_structural_wall_t* out_walls,
    int32_t wall_capacity,
    int32_t* out_wall_count) {
    if (!points_xyz || point_count < 100 || !floor_normal_xyz || !options ||
        !out_wall_count || options->max_walls <= 0 ||
        options->theta_step_deg <= 0 || 180 % options->theta_step_deg != 0 ||
        !(options->wall_fit_band_m > 0.0) || !(options->rho_step_m > 0.0) ||
        wall_capacity < 0) {
        return kBadArgs;
    }
    *out_wall_count = 0;
    const Vec3 up = normalized(
        {floor_normal_xyz[0], floor_normal_xyz[1], floor_normal_xyz[2]});
    if (!(norm(up) > 0.0) || !std::isfinite(floor_value_n_dot_x)) return kBadArgs;
    Vec3 seed{1.0, 0.0, 0.0};
    if (std::abs(dot(seed, up)) > 0.9) seed = {0.0, 0.0, 1.0};
    const Vec3 axis_u = normalized(add(seed, scale(up, -dot(seed, up))));
    const Vec3 axis_v = normalized(cross(up, axis_u));

    std::vector<Vec3> points;
        std::vector<double> heights;
        std::vector<double> coordinate_u;
        std::vector<double> coordinate_v;
        points.reserve(static_cast<std::size_t>(point_count));
        heights.reserve(static_cast<std::size_t>(point_count));
        coordinate_u.reserve(static_cast<std::size_t>(point_count));
        coordinate_v.reserve(static_cast<std::size_t>(point_count));
        for (int32_t index = 0; index < point_count; ++index) {
            const Vec3 point{points_xyz[index * 3], points_xyz[index * 3 + 1],
                             points_xyz[index * 3 + 2]};
            if (!std::isfinite(point.x) || !std::isfinite(point.y) ||
                !std::isfinite(point.z)) {
                continue;
            }
            points.push_back(point);
            heights.push_back(dot(point, up) - floor_value_n_dot_x);
            coordinate_u.push_back(dot(point, axis_u));
            coordinate_v.push_back(dot(point, axis_v));
        }
        if (points.size() < 100) return kBadArgs;

        double wall_height_limit = fit_ceiling_height(
            heights, coordinate_u, coordinate_v);
        if (!std::isfinite(wall_height_limit)) {
            std::vector<double> supported;
            for (const double height : heights) {
                if (height >= options->minimum_height_m) supported.push_back(height);
            }
            if (supported.size() < 100) return kBadArgs;
            wall_height_limit = percentile(std::move(supported), 0.995) + 0.10;
        }

        std::vector<std::size_t> room_indices;
        for (std::size_t index = 0; index < points.size(); ++index) {
            if (heights[index] >= options->minimum_height_m &&
                heights[index] <= wall_height_limit - 0.10) {
                room_indices.push_back(index);
            }
        }
        if (room_indices.size() < 100) return kBadArgs;

        std::vector<Candidate> raw;
        for (int32_t theta_deg = 0; theta_deg < 180;
             theta_deg += options->theta_step_deg) {
            const double theta = static_cast<double>(theta_deg) * M_PI / 180.0;
            const double cosine = std::cos(theta);
            const double sine = std::sin(theta);
            std::vector<double> rho;
            rho.reserve(room_indices.size());
            for (const std::size_t index : room_indices) {
                rho.push_back(coordinate_u[index] * cosine +
                              coordinate_v[index] * sine);
            }
            const double low = std::floor(percentile(rho, 0.005) /
                                          options->rho_step_m) *
                               options->rho_step_m;
            const double high = std::ceil(percentile(rho, 0.995) /
                                           options->rho_step_m) *
                                options->rho_step_m;
            const auto counts = histogram(rho, low, high, options->rho_step_m);
            for (const int32_t bin : top_histogram_indices(counts, 8)) {
                const double initial = low +
                    (static_cast<double>(bin) + 0.5) * options->rho_step_m;
                std::vector<double> preliminary;
                for (const double value : rho) {
                    if (std::abs(value - initial) <= options->wall_fit_band_m) {
                        preliminary.push_back(value);
                    }
                }
                if (preliminary.size() < static_cast<std::size_t>(
                        options->preliminary_minimum_support)) {
                    continue;
                }
                const double value = median(std::move(preliminary));
                std::vector<double> tangent_values;
                std::vector<double> height_values;
                for (std::size_t local = 0; local < rho.size(); ++local) {
                    if (std::abs(rho[local] - value) > options->wall_fit_band_m) {
                        continue;
                    }
                    const std::size_t point = room_indices[local];
                    tangent_values.push_back(
                        -coordinate_u[point] * sine + coordinate_v[point] * cosine);
                    height_values.push_back(heights[point]);
                }
                const double tangent_span = percentile(tangent_values, 0.98) -
                                            percentile(tangent_values, 0.02);
                const double height_span = percentile(height_values, 0.98) -
                                           percentile(height_values, 0.02);
                if (tangent_span < options->minimum_tangent_span_m ||
                    height_span < options->minimum_height_span_m) {
                    continue;
                }
                const int32_t cells = cell_count(tangent_values, height_values, 0.10);
                raw.push_back({theta_deg,
                               value,
                               static_cast<int32_t>(tangent_values.size()),
                               cells,
                               static_cast<double>(cells) *
                                   std::sqrt(static_cast<double>(tangent_values.size())),
                               {percentile(tangent_values, 0.01),
                                percentile(tangent_values, 0.99)},
                               {percentile(height_values, 0.01),
                                percentile(height_values, 0.99)},
                               tangent_span,
                               height_span});
            }
        }
        std::stable_sort(raw.begin(), raw.end(), [](const Candidate& a,
                                                    const Candidate& b) {
            return a.score > b.score;
        });
        std::vector<Candidate> selected;
        for (const Candidate& candidate : raw) {
            int32_t same_orientation = 0;
            bool duplicate_layer = false;
            for (const Candidate& prior : selected) {
                int32_t angle = std::abs(candidate.theta_deg - prior.theta_deg);
                angle = std::min(angle, 180 - angle);
                if (angle <= 10) {
                    ++same_orientation;
                    if (std::abs(candidate.value - prior.value) <= 0.75) {
                        duplicate_layer = true;
                    }
                }
            }
            if (duplicate_layer || same_orientation >= 2) continue;
            selected.push_back(candidate);
            if (selected.size() >= static_cast<std::size_t>(options->max_walls)) {
                break;
            }
        }
        *out_wall_count = static_cast<int32_t>(selected.size());
        if (wall_capacity < *out_wall_count || (!out_walls && *out_wall_count > 0)) {
            return kBufferTooSmall;
        }
        for (std::size_t wall_index = 0; wall_index < selected.size(); ++wall_index) {
            const Candidate& candidate = selected[wall_index];
            const double theta = static_cast<double>(candidate.theta_deg) * M_PI / 180.0;
            const Vec3 normal = normalized(add(scale(axis_u, std::cos(theta)),
                                               scale(axis_v, std::sin(theta))));
            const Vec3 tangent = normalized(add(scale(axis_u, -std::sin(theta)),
                                                scale(axis_v, std::cos(theta))));
            aether_structural_wall_t wall{};
            wall.wall_index = static_cast<int32_t>(wall_index);
            wall.theta_deg = candidate.theta_deg;
            wall.support_points_35mm = candidate.support;
            wall.coverage_cells_10cm = candidate.cells;
            wall.plane_value_n_dot_x = candidate.value;
            wall.bounds_u_m[0] = candidate.tangent_bounds[0];
            wall.bounds_u_m[1] = candidate.tangent_bounds[1];
            wall.bounds_height_m[0] = candidate.height_bounds[0];
            wall.bounds_height_m[1] = candidate.height_bounds[1];
            wall.score = candidate.score;
            copy_vec(normal, wall.normal_xyz);
            copy_vec(tangent, wall.basis_u_xyz);
            copy_vec(up, wall.basis_v_xyz);

            for (std::size_t offset_index = 0;
                 offset_index < kCertificationOffsets.size(); ++offset_index) {
                std::vector<double> accepted_u;
                std::vector<double> accepted_height;
                for (std::size_t point = 0; point < points.size(); ++point) {
                    const double tangent_coordinate = dot(points[point], tangent);
                    if (tangent_coordinate < wall.bounds_u_m[0] ||
                        tangent_coordinate > wall.bounds_u_m[1] ||
                        heights[point] < wall.bounds_height_m[0] ||
                        heights[point] > wall.bounds_height_m[1]) {
                        continue;
                    }
                    if (offset_index == 0) ++wall.domain_points;
                    const double target = candidate.value +
                                          kCertificationOffsets[offset_index];
                    if (std::abs(dot(points[point], normal) - target) <= 0.020) {
                        accepted_u.push_back(tangent_coordinate);
                        accepted_height.push_back(heights[point]);
                    }
                }
                wall.support_points_20mm[offset_index] =
                    static_cast<int32_t>(accepted_u.size());
                wall.support_cells_10cm[offset_index] =
                    cell_count(accepted_u, accepted_height, 0.10);
            }
            const int32_t center_points = wall.support_points_20mm[2];
            const int32_t near_points = std::max(wall.support_points_20mm[1],
                                                 wall.support_points_20mm[3]);
            const int32_t far_points = std::max(wall.support_points_20mm[0],
                                                wall.support_points_20mm[4]);
            const int32_t center_cells = wall.support_cells_10cm[2];
            const int32_t near_cells = std::max(wall.support_cells_10cm[1],
                                                wall.support_cells_10cm[3]);
            wall.support_prominence_vs_5cm =
                static_cast<double>(center_points) / std::max(near_points, 1);
            wall.coverage_prominence_vs_5cm =
                static_cast<double>(center_cells) / std::max(near_cells, 1);
            wall.certified =
                center_points >= options->certified_minimum_support &&
                center_cells >= options->certified_minimum_cells &&
                static_cast<double>(center_points) >=
                    static_cast<double>(near_points) * 1.05 &&
                static_cast<double>(center_cells) >=
                    static_cast<double>(near_cells) * 0.95 &&
                static_cast<double>(center_points) >=
                    static_cast<double>(far_points) * 1.25;
            out_walls[wall_index] = wall;
        }
    return kOk;
}

}  // extern "C"
