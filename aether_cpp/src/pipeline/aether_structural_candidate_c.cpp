// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_structural_candidate_c.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numeric>
#include <vector>

namespace {

constexpr int32_t kOk = 0;
constexpr int32_t kBadArgs = 1;
constexpr int32_t kBufferTooSmall = 4;

struct Vec3 {
    double x;
    double y;
    double z;
};

bool finite_scalar(double value) { return std::isfinite(value); }

bool finite3(const double values[3]) {
    return values != nullptr && finite_scalar(values[0]) &&
           finite_scalar(values[1]) && finite_scalar(values[2]);
}

Vec3 load3(const double values[3]) {
    return {values[0], values[1], values[2]};
}

Vec3 add(Vec3 a, Vec3 b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 subtract(Vec3 a, Vec3 b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 scale(Vec3 value, double factor) {
    return {value.x * factor, value.y * factor, value.z * factor};
}

double dot(Vec3 a, Vec3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

double norm(Vec3 value) { return std::sqrt(dot(value, value)); }

bool normalized(Vec3 value, Vec3* out) {
    const double length = norm(value);
    if (!(length > 1e-12) || !finite_scalar(length) || out == nullptr) {
        return false;
    }
    *out = scale(value, 1.0 / length);
    return true;
}

bool valid_spec(const aether_structural_grid_spec_t& spec) {
    return finite3(spec.normal_xyz) && finite3(spec.basis_u_xyz) &&
           finite3(spec.basis_v_xyz) &&
           finite_scalar(spec.plane_value_n_dot_x) &&
           finite_scalar(spec.basis_v_origin_value) &&
           finite_scalar(spec.u_min) && finite_scalar(spec.u_max) &&
           finite_scalar(spec.v_min) && finite_scalar(spec.v_max) &&
           finite_scalar(spec.grid_m) && spec.grid_m > 0.0 &&
           spec.u_max >= spec.u_min && spec.v_max >= spec.v_min;
}

bool axis_count(double minimum, double maximum, double step, int32_t* out) {
    if (out == nullptr) {
        return false;
    }
    const double inclusive_limit = maximum + step * 0.25;
    const double raw = std::floor((inclusive_limit - minimum) / step) + 1.0;
    if (!(raw >= 1.0) || raw > static_cast<double>(INT32_MAX)) {
        return false;
    }
    *out = static_cast<int32_t>(raw);
    return true;
}

bool checked_product(int32_t a, int32_t b, int32_t* out) {
    if (a < 0 || b < 0 || out == nullptr) {
        return false;
    }
    const std::int64_t value = static_cast<std::int64_t>(a) * b;
    if (value > INT32_MAX) {
        return false;
    }
    *out = static_cast<int32_t>(value);
    return true;
}

Vec3 load_point(const double* values, int32_t index) {
    const std::size_t offset = static_cast<std::size_t>(index) * 3;
    return {values[offset], values[offset + 1], values[offset + 2]};
}

bool valid_point_array(const double* values, int32_t count) {
    if (values == nullptr || count <= 0) {
        return false;
    }
    const std::size_t value_count = static_cast<std::size_t>(count) * 3;
    for (std::size_t index = 0; index < value_count; ++index) {
        if (!finite_scalar(values[index])) {
            return false;
        }
    }
    return true;
}

struct ProjectionResult {
    bool visible = false;
    double head_on = 0.0;
};

ProjectionResult project(
    Vec3 point,
    const aether_structural_frame_t& frame,
    Vec3 unit_normal,
    double margin,
    double minimum_cosine) {
    const double* matrix = frame.projection_row_major_3x4;
    const double homogeneous_x =
        matrix[0] * point.x + matrix[1] * point.y +
        matrix[2] * point.z + matrix[3];
    const double homogeneous_y =
        matrix[4] * point.x + matrix[5] * point.y +
        matrix[6] * point.z + matrix[7];
    const double depth =
        matrix[8] * point.x + matrix[9] * point.y +
        matrix[10] * point.z + matrix[11];
    const Vec3 ray = subtract(point, load3(frame.camera_center_xyz));
    const double head_on = std::abs(dot(ray, unit_normal)) / (norm(ray) + 1e-12);
    if (!(depth > 0.05) || !finite_scalar(depth) ||
        !finite_scalar(head_on)) {
        return {false, head_on};
    }
    const double x = homogeneous_x / depth;
    const double y = homogeneous_y / depth;
    const bool visible = finite_scalar(x) && finite_scalar(y) && x > margin &&
                         x < static_cast<double>(frame.width - 1) - margin &&
                         y > margin &&
                         y < static_cast<double>(frame.height - 1) - margin &&
                         head_on > minimum_cosine;
    return {visible, head_on};
}

bool valid_frame(const aether_structural_frame_t& frame) {
    if (frame.width <= 0 || frame.height <= 0 ||
        !finite3(frame.camera_center_xyz)) {
        return false;
    }
    for (double value : frame.projection_row_major_3x4) {
        if (!finite_scalar(value)) {
            return false;
        }
    }
    return true;
}

}  // namespace

extern "C" {

void aether_structural_view_options_default(
    aether_structural_view_options_t* out_options) {
    if (out_options == nullptr) {
        return;
    }
    out_options->maximum_views = 8;
    out_options->image_margin_px = 2.0;
    out_options->maximum_graze_deg = 72.0;
    out_options->mode = AETHER_STRUCTURAL_VIEWS_PER_POINT;
}

int32_t aether_structural_grid_count(
    const aether_structural_grid_spec_t* spec,
    int32_t* out_candidate_count) {
    if (spec == nullptr || out_candidate_count == nullptr || !valid_spec(*spec)) {
        return kBadArgs;
    }
    int32_t u_count = 0;
    int32_t v_count = 0;
    if (!axis_count(spec->u_min, spec->u_max, spec->grid_m, &u_count) ||
        !axis_count(spec->v_min, spec->v_max, spec->grid_m, &v_count) ||
        !checked_product(u_count, v_count, out_candidate_count)) {
        return kBadArgs;
    }
    return kOk;
}

int32_t aether_structural_grid_build(
    const aether_structural_grid_spec_t* spec,
    const double* depth_offsets_m,
    int32_t hypotheses_per_candidate,
    double* out_centers_xyz,
    int32_t center_capacity_doubles,
    double* out_points_xyz,
    int32_t point_capacity_doubles) {
    int32_t candidate_count = 0;
    if (spec == nullptr || depth_offsets_m == nullptr ||
        hypotheses_per_candidate <= 0 || out_centers_xyz == nullptr ||
        out_points_xyz == nullptr ||
        aether_structural_grid_count(spec, &candidate_count) != kOk ||
        !finite_scalar(depth_offsets_m[0]) ||
        std::abs(depth_offsets_m[0]) > 1e-12) {
        return kBadArgs;
    }
    for (int32_t index = 0; index < hypotheses_per_candidate; ++index) {
        if (!finite_scalar(depth_offsets_m[index])) {
            return kBadArgs;
        }
    }
    int32_t center_required = 0;
    int32_t point_count = 0;
    int32_t point_required = 0;
    if (!checked_product(candidate_count, 3, &center_required) ||
        !checked_product(candidate_count, hypotheses_per_candidate, &point_count) ||
        !checked_product(point_count, 3, &point_required)) {
        return kBadArgs;
    }
    if (center_capacity_doubles < center_required ||
        point_capacity_doubles < point_required) {
        return kBufferTooSmall;
    }
    Vec3 normal{};
    Vec3 basis_u{};
    Vec3 basis_v{};
    if (!normalized(load3(spec->normal_xyz), &normal) ||
        !normalized(load3(spec->basis_u_xyz), &basis_u) ||
        !normalized(load3(spec->basis_v_xyz), &basis_v)) {
        return kBadArgs;
    }
    int32_t u_count = 0;
    int32_t v_count = 0;
    if (!axis_count(spec->u_min, spec->u_max, spec->grid_m, &u_count) ||
        !axis_count(spec->v_min, spec->v_max, spec->grid_m, &v_count)) {
        return kBadArgs;
    }
    const Vec3 origin = add(
        scale(normal, spec->plane_value_n_dot_x),
        scale(basis_v, spec->basis_v_origin_value));
    int32_t candidate = 0;
    for (int32_t u_index = 0; u_index < u_count; ++u_index) {
        const double u = spec->u_min + spec->grid_m * u_index;
        for (int32_t v_index = 0; v_index < v_count; ++v_index) {
            const double v = spec->v_min + spec->grid_m * v_index;
            const Vec3 center = add(add(origin, scale(basis_u, u)), scale(basis_v, v));
            const std::size_t center_offset = static_cast<std::size_t>(candidate) * 3;
            out_centers_xyz[center_offset] = center.x;
            out_centers_xyz[center_offset + 1] = center.y;
            out_centers_xyz[center_offset + 2] = center.z;
            for (int32_t hypothesis = 0;
                 hypothesis < hypotheses_per_candidate;
                 ++hypothesis) {
                const Vec3 point = add(
                    center, scale(normal, depth_offsets_m[hypothesis]));
                const std::size_t point_offset =
                    (static_cast<std::size_t>(candidate) *
                         hypotheses_per_candidate +
                     hypothesis) *
                    3;
                out_points_xyz[point_offset] = point.x;
                out_points_xyz[point_offset + 1] = point.y;
                out_points_xyz[point_offset + 2] = point.z;
            }
            ++candidate;
        }
    }
    return candidate == candidate_count ? kOk : kBadArgs;
}

int32_t aether_structural_prepare_views(
    const double* centers_xyz,
    int32_t candidate_count,
    const double* points_xyz,
    int32_t point_count,
    const aether_structural_frame_t* frames,
    int32_t frame_count,
    const double normal_xyz[3],
    const aether_structural_view_options_t* options,
    uint8_t* out_hypothesis_visible,
    int32_t visible_capacity_bytes,
    int32_t* out_selected_indices,
    int32_t selected_capacity_ints,
    int32_t* out_selected_counts,
    int32_t selected_count_capacity) {
    if (!valid_point_array(centers_xyz, candidate_count) ||
        !valid_point_array(points_xyz, point_count) || frames == nullptr ||
        frame_count <= 0 || !finite3(normal_xyz) || options == nullptr ||
        options->maximum_views <= 0 ||
        options->maximum_views > frame_count ||
        !finite_scalar(options->image_margin_px) ||
        options->image_margin_px < 0.0 ||
        !finite_scalar(options->maximum_graze_deg) ||
        !(options->maximum_graze_deg > 0.0 &&
          options->maximum_graze_deg < 90.0) ||
        (options->mode != AETHER_STRUCTURAL_VIEWS_PER_POINT &&
         options->mode != AETHER_STRUCTURAL_VIEWS_PER_TILE) ||
        out_hypothesis_visible == nullptr || out_selected_indices == nullptr ||
        out_selected_counts == nullptr) {
        return kBadArgs;
    }
    for (int32_t frame = 0; frame < frame_count; ++frame) {
        if (!valid_frame(frames[frame])) {
            return kBadArgs;
        }
    }
    int32_t visible_required = 0;
    int32_t selected_required = 0;
    if (!checked_product(point_count, frame_count, &visible_required) ||
        !checked_product(
            candidate_count, options->maximum_views, &selected_required)) {
        return kBadArgs;
    }
    if (visible_capacity_bytes < visible_required ||
        selected_capacity_ints < selected_required ||
        selected_count_capacity < candidate_count) {
        return kBufferTooSmall;
    }
    Vec3 normal{};
    if (!normalized(load3(normal_xyz), &normal)) {
        return kBadArgs;
    }
    const double radians =
        options->maximum_graze_deg * std::acos(-1.0) / 180.0;
    const double minimum_cosine = std::cos(radians);
    std::fill(
        out_selected_indices,
        out_selected_indices + selected_required,
        -1);
    std::fill(
        out_hypothesis_visible,
        out_hypothesis_visible + visible_required,
        static_cast<uint8_t>(0));

    for (int32_t point = 0; point < point_count; ++point) {
        const Vec3 world = load_point(points_xyz, point);
        for (int32_t frame = 0; frame < frame_count; ++frame) {
            const ProjectionResult result = project(
                world,
                frames[frame],
                normal,
                options->image_margin_px,
                minimum_cosine);
            out_hypothesis_visible[
                static_cast<std::size_t>(point) * frame_count + frame] =
                result.visible ? 1 : 0;
        }
    }

    std::vector<uint8_t> center_visible(
        static_cast<std::size_t>(candidate_count) * frame_count, 0);
    std::vector<double> center_head_on(
        static_cast<std::size_t>(candidate_count) * frame_count, 0.0);
    for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
        const Vec3 center = load_point(centers_xyz, candidate);
        for (int32_t frame = 0; frame < frame_count; ++frame) {
            const ProjectionResult result = project(
                center,
                frames[frame],
                normal,
                options->image_margin_px,
                minimum_cosine);
            const std::size_t index =
                static_cast<std::size_t>(candidate) * frame_count + frame;
            center_visible[index] = result.visible ? 1 : 0;
            center_head_on[index] = result.head_on;
        }
    }

    if (options->mode == AETHER_STRUCTURAL_VIEWS_PER_POINT) {
        std::vector<int32_t> candidates;
        candidates.reserve(static_cast<std::size_t>(frame_count));
        for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
            candidates.clear();
            const std::size_t base =
                static_cast<std::size_t>(candidate) * frame_count;
            for (int32_t frame = 0; frame < frame_count; ++frame) {
                if (center_visible[base + frame] != 0) {
                    candidates.push_back(frame);
                }
            }
            std::sort(
                candidates.begin(),
                candidates.end(),
                [&](int32_t left, int32_t right) {
                    const double left_score = center_head_on[base + left];
                    const double right_score = center_head_on[base + right];
                    if (left_score != right_score) {
                        return left_score > right_score;
                    }
                    return left < right;
                });
            const int32_t count = std::min(
                static_cast<int32_t>(candidates.size()), options->maximum_views);
            out_selected_counts[candidate] = count;
            for (int32_t index = 0; index < count; ++index) {
                out_selected_indices[
                    static_cast<std::size_t>(candidate) *
                        options->maximum_views +
                    index] = candidates[index];
            }
        }
        return kOk;
    }

    std::vector<int32_t> frame_indices(static_cast<std::size_t>(frame_count));
    std::iota(frame_indices.begin(), frame_indices.end(), 0);
    std::vector<int32_t> coverage(static_cast<std::size_t>(frame_count), 0);
    std::vector<double> incidence(static_cast<std::size_t>(frame_count), 0.0);
    for (int32_t frame = 0; frame < frame_count; ++frame) {
        double sum = 0.0;
        for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
            const std::size_t index =
                static_cast<std::size_t>(candidate) * frame_count + frame;
            if (center_visible[index] != 0) {
                ++coverage[frame];
                sum += center_head_on[index];
            }
        }
        if (coverage[frame] > 0) {
            incidence[frame] = sum / coverage[frame];
        }
    }
    std::sort(
        frame_indices.begin(),
        frame_indices.end(),
        [&](int32_t left, int32_t right) {
            if (coverage[left] != coverage[right]) {
                return coverage[left] > coverage[right];
            }
            if (incidence[left] != incidence[right]) {
                return incidence[left] > incidence[right];
            }
            return left < right;
        });
    std::vector<int32_t> selected;
    selected.reserve(static_cast<std::size_t>(options->maximum_views));
    for (int32_t frame : frame_indices) {
        if (coverage[frame] <= 0) {
            break;
        }
        selected.push_back(frame);
        if (static_cast<int32_t>(selected.size()) == options->maximum_views) {
            break;
        }
    }
    for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
        out_selected_counts[candidate] = static_cast<int32_t>(selected.size());
        for (std::size_t index = 0; index < selected.size(); ++index) {
            out_selected_indices[
                static_cast<std::size_t>(candidate) * options->maximum_views +
                index] = selected[index];
        }
    }
    return kOk;
}

}  // extern "C"
