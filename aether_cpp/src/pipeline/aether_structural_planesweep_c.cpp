// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_structural_planesweep_c.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <utility>
#include <vector>

#if defined(AETHER_ENABLE_DAWN)
#include "aether/render/dawn_gpu_device.h"
#include "aether/render/gpu_command.h"
#include "aether/render/gpu_device.h"
#include "aether/shaders/wgsl_sources.h"
#endif

namespace {

constexpr float kNegativeInfinity = -std::numeric_limits<float>::infinity();
constexpr double kNccDecisionUnitsPerOne = 1000.0;
constexpr double kDecoderStableNccTieBand = 0.001;

bool finite_positive(float value) {
    return std::isfinite(value) && value > 0.0f;
}

double median(std::vector<double> values) {
    if (values.empty()) return kNegativeInfinity;
    std::sort(values.begin(), values.end());
    const std::size_t middle = values.size() / 2;
    return values.size() % 2 == 1
        ? values[middle]
        : 0.5 * (values[middle - 1] + values[middle]);
}

struct Clique {
    std::vector<int> members;
    double median_ncc = -std::numeric_limits<double>::infinity();
};

double max_parallax_degrees(const std::vector<int>& selected_views,
                            const float* camera_centers_xyz,
                            const float* point_xyz);

std::int32_t canonical_ncc_units(double value);

Clique largest_consistent_clique(const std::vector<double>& ncc,
                                 int count,
                                 double threshold,
                                 int minimum,
                                 const std::function<bool(
                                     const std::vector<int>&)>& admissible = {},
                                 bool canonical_edge_threshold = false) {
    Clique best;
    if (minimum < 2 || count < minimum || count > 63 ||
        ncc.size() != static_cast<std::size_t>(count * count)) {
        return best;
    }
    std::vector<std::uint64_t> neighbors(static_cast<std::size_t>(count), 0);
    // NCC thresholds are positive. For non-negative values,
    // lround(edge * 1000) >= K is exactly the inclusive cutoff
    // edge >= (K - 0.5) / 1000. Precompute that cutoff once so preserving a
    // backend-stable competitor costs the same single comparison per edge as
    // the raw center path; do not call lround in the clique hot loop.
    const double effective_threshold = canonical_edge_threshold
        ? (static_cast<double>(canonical_ncc_units(threshold)) - 0.5) /
            kNccDecisionUnitsPerOne
        : threshold;
    for (int row = 0; row < count; ++row) {
        for (int column = 0; column < count; ++column) {
            const double edge =
                ncc[static_cast<std::size_t>(row * count + column)];
            if (row != column && edge >= effective_threshold) {
                neighbors[static_cast<std::size_t>(row)] |=
                    std::uint64_t{1} << column;
            }
        }
    }
    std::vector<int> current;
    const auto consider = [&]() {
        if (current.size() < static_cast<std::size_t>(minimum) ||
            current.size() < best.members.size()) {
            return;
        }
        if (admissible && !admissible(current)) return;
        std::vector<double> pairs;
        for (std::size_t a = 0; a < current.size(); ++a) {
            for (std::size_t b = a + 1; b < current.size(); ++b) {
                pairs.push_back(ncc[static_cast<std::size_t>(
                    current[a] * count + current[b])]);
            }
        }
        const double score = median(std::move(pairs));
        if (current.size() > best.members.size() || score > best.median_ncc) {
            best.members = current;
            best.median_ncc = score;
        }
    };
    std::function<void(std::uint64_t)> search = [&](std::uint64_t candidates) {
        const std::size_t required =
            std::max<std::size_t>(minimum, best.members.size());
        if (current.size() + static_cast<std::size_t>(
                __builtin_popcountll(candidates)) < required) {
            return;
        }
        if (candidates == 0) {
            consider();
            return;
        }
        std::uint64_t remaining = candidates;
        while (remaining != 0) {
            const std::size_t loop_required =
                std::max<std::size_t>(minimum, best.members.size());
            if (current.size() + static_cast<std::size_t>(
                    __builtin_popcountll(remaining)) < loop_required) {
                break;
            }
            const std::uint64_t lowest = remaining & (~remaining + 1);
            const int vertex = __builtin_ctzll(lowest);
            current.push_back(vertex);
            search(remaining & neighbors[static_cast<std::size_t>(vertex)]);
            current.pop_back();
            remaining &= ~lowest;
        }
    };
    search((std::uint64_t{1} << count) - 1);
    return best;
}

std::int32_t canonical_ncc_units(double value) {
    return static_cast<std::int32_t>(std::lround(
        std::clamp(value, -1.0, 1.0) * kNccDecisionUnitsPerOne));
}

std::int32_t canonical_ncc_margin_units(float value) {
    return static_cast<std::int32_t>(std::ceil(
        std::max(0.0, static_cast<double>(value)) *
            kNccDecisionUnitsPerOne -
        1.0e-9));
}

double max_parallax_degrees(const std::vector<int>& selected_views,
                            const float* camera_centers_xyz,
                            const float* point_xyz) {
    double maximum = 0.0;
    for (std::size_t a = 0; a < selected_views.size(); ++a) {
        const float* camera_a = camera_centers_xyz + selected_views[a] * 3;
        double ray_a[3] = {
            static_cast<double>(point_xyz[0] - camera_a[0]),
            static_cast<double>(point_xyz[1] - camera_a[1]),
            static_cast<double>(point_xyz[2] - camera_a[2]),
        };
        const double norm_a = std::sqrt(
            ray_a[0] * ray_a[0] + ray_a[1] * ray_a[1] + ray_a[2] * ray_a[2]);
        if (!(norm_a > 0.0)) continue;
        for (std::size_t b = a + 1; b < selected_views.size(); ++b) {
            const float* camera_b = camera_centers_xyz + selected_views[b] * 3;
            double ray_b[3] = {
                static_cast<double>(point_xyz[0] - camera_b[0]),
                static_cast<double>(point_xyz[1] - camera_b[1]),
                static_cast<double>(point_xyz[2] - camera_b[2]),
            };
            const double norm_b = std::sqrt(
                ray_b[0] * ray_b[0] + ray_b[1] * ray_b[1] + ray_b[2] * ray_b[2]);
            if (!(norm_b > 0.0)) continue;
            const double cosine = std::clamp(
                (ray_a[0] * ray_b[0] + ray_a[1] * ray_b[1] +
                 ray_a[2] * ray_b[2]) / (norm_a * norm_b),
                -1.0, 1.0);
            maximum = std::max(maximum, std::acos(cosine) * 180.0 / M_PI);
        }
    }
    return maximum;
}

Clique select_parallax_stable_clique(
    const std::vector<double>& ncc,
    int count,
    const std::vector<int>& candidate_views,
    double threshold,
    int minimum,
    double minimum_parallax_deg,
    const float* camera_centers_xyz,
    const float* point_xyz,
    bool allow_equal_strength_parallax_alternate = true,
    bool canonical_edge_threshold = false) {
    const Clique strongest = largest_consistent_clique(
        ncc, count, threshold, minimum, {}, canonical_edge_threshold);
    const auto mapped_views = [&](const std::vector<int>& members) {
        std::vector<int> selected;
        selected.reserve(members.size());
        for (const int member : members) {
            selected.push_back(candidate_views[member]);
        }
        return selected;
    };
    if (strongest.members.size() >= static_cast<std::size_t>(minimum) &&
        max_parallax_degrees(
            mapped_views(strongest.members), camera_centers_xyz, point_xyz) >=
            minimum_parallax_deg) {
        return strongest;
    }
    if (!allow_equal_strength_parallax_alternate) return {};
    const auto clears_parallax = [&](const std::vector<int>& members) {
        return max_parallax_degrees(
                   mapped_views(members), camera_centers_xyz, point_xyz) >=
            minimum_parallax_deg;
    };
    const Clique alternate = largest_consistent_clique(
        ncc, count, threshold, minimum, clears_parallax,
        canonical_edge_threshold);
    if (alternate.members.size() == strongest.members.size() &&
        alternate.members.size() >= static_cast<std::size_t>(minimum) &&
        strongest.median_ncc - alternate.median_ncc <=
            kDecoderStableNccTieBand + 1.0e-12) {
        return alternate;
    }
    return {};
}

int32_t score_scale_with_hypothesis_roles(
    const float* normalized_patches,
    const std::uint8_t* valid,
    const std::uint8_t* candidate_view_mask,
    const float* camera_centers_xyz,
    const float* points_xyz,
    int32_t view_count,
    int32_t point_count,
    int32_t sample_count,
    int32_t hypotheses_per_candidate,
    const aether_planesweep_birth_options_t* options,
    int32_t* out_supporting_views,
    float* out_median_ncc,
    float* out_max_parallax_deg,
    std::uint8_t* out_valid_score) {
    if (!normalized_patches || !valid || !camera_centers_xyz || !points_xyz ||
        !options || !out_supporting_views || !out_median_ncc ||
        !out_max_parallax_deg || !out_valid_score || view_count <= 0 ||
        point_count <= 0 || sample_count <= 0 ||
        hypotheses_per_candidate <= 0 ||
        point_count % hypotheses_per_candidate != 0 ||
        options->minimum_views < 2 || !finite_positive(options->ncc_min) ||
        !finite_positive(options->minimum_parallax_deg)) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    for (int32_t point = 0; point < point_count; ++point) {
        out_supporting_views[point] = 0;
        out_median_ncc[point] = kNegativeInfinity;
        out_max_parallax_deg[point] = 0.0f;
        out_valid_score[point] = 0;
        std::vector<int> candidates;
        for (int32_t view = 0; view < view_count; ++view) {
            const std::size_t valid_index =
                static_cast<std::size_t>(view) * point_count + point;
            const bool selected = !candidate_view_mask ||
                candidate_view_mask[
                    static_cast<std::size_t>(point) * view_count + view] != 0;
            if (selected && valid[valid_index] != 0) candidates.push_back(view);
        }
        if (candidates.size() < static_cast<std::size_t>(options->minimum_views) ||
            candidates.size() > 63) {
            continue;
        }
        const int count = static_cast<int>(candidates.size());
        std::vector<double> ncc(static_cast<std::size_t>(count * count), 1.0);
        for (int a = 0; a < count; ++a) {
            const std::size_t base_a =
                (static_cast<std::size_t>(candidates[a]) * point_count + point) *
                sample_count;
            for (int b = a + 1; b < count; ++b) {
                const std::size_t base_b =
                    (static_cast<std::size_t>(candidates[b]) * point_count +
                     point) * sample_count;
                double dot = 0.0;
                for (int32_t sample = 0; sample < sample_count; ++sample) {
                    dot += static_cast<double>(normalized_patches[base_a + sample]) *
                        normalized_patches[base_b + sample];
                }
                ncc[static_cast<std::size_t>(a * count + b)] = dot;
                ncc[static_cast<std::size_t>(b * count + a)] = dot;
            }
        }
        // A center hypothesis keeps the exact configured NCC threshold, so
        // backend tolerance can never create a new product birth. Parallel
        // depth competitors use the same canonical millincc decision units as
        // the ownership margin: a decoder/interpolation perturbation smaller
        // than half a unit must not erase ambiguity and turn the margin into
        // +infinity. Competitors still cannot use the center-only parallax tie
        // rescue, so weaker alternate cliques do not suppress the real plane.
        const bool is_center = point % hypotheses_per_candidate == 0;
        const Clique clique = select_parallax_stable_clique(
            ncc, count, candidates, options->ncc_min,
            options->minimum_views, options->minimum_parallax_deg,
            camera_centers_xyz, points_xyz + point * 3, is_center,
            /*canonical_edge_threshold=*/!is_center);
        if (clique.members.size() <
            static_cast<std::size_t>(options->minimum_views)) {
            continue;
        }
        std::vector<int> selected_views;
        selected_views.reserve(clique.members.size());
        for (const int member : clique.members) {
            selected_views.push_back(candidates[member]);
        }
        const double parallax = max_parallax_degrees(
            selected_views, camera_centers_xyz, points_xyz + point * 3);
        if (parallax < options->minimum_parallax_deg) continue;
        out_supporting_views[point] =
            static_cast<int32_t>(selected_views.size());
        out_median_ncc[point] = static_cast<float>(clique.median_ncc);
        out_max_parallax_deg[point] = static_cast<float>(parallax);
        out_valid_score[point] = 1;
    }
    return AETHER_PLANESWEEP_OK;
}

#if defined(AETHER_ENABLE_DAWN)

using aether::render::GPUBufferDesc;
using aether::render::GPUBufferHandle;
using aether::render::GPUBufferUsage;
using aether::render::GPUComputePipelineHandle;
using aether::render::GPUDevice;
using aether::render::GPUShaderStage;
using aether::render::GPUStorageMode;

std::size_t align256(std::size_t value) {
    return (value + 255u) & ~std::size_t{255u};
}

GPUBufferHandle make_buffer(GPUDevice& device,
                            std::size_t bytes,
                            GPUBufferUsage usage,
                            GPUStorageMode storage,
                            const char* label) {
    GPUBufferDesc desc{};
    desc.size_bytes = bytes;
    desc.storage = storage;
    desc.usage_mask = static_cast<std::uint8_t>(usage);
    desc.label = label;
    return device.create_buffer(desc);
}

bool readback(GPUDevice& device,
              GPUBufferHandle source,
              std::size_t bytes,
              std::vector<std::uint8_t>* output) {
    if (!output) return false;
    const auto staging = make_buffer(device, bytes, GPUBufferUsage::kStaging,
                                     GPUStorageMode::kShared,
                                     "planesweep_readback");
    if (!staging.valid() ||
        !aether::render::dawn_copy_buffer_to_buffer(
            device, source, staging, bytes)) {
        if (staging.valid()) device.destroy_buffer(staging);
        return false;
    }
    void* mapped = device.map_buffer(staging);
    if (!mapped) {
        device.destroy_buffer(staging);
        return false;
    }
    output->resize(bytes);
    std::memcpy(output->data(), mapped, bytes);
    device.unmap_buffer(staging);
    device.destroy_buffer(staging);
    return true;
}

struct alignas(16) PatchParams {
    std::uint32_t point_count;
    std::uint32_t patch_n;
    std::uint32_t width;
    std::uint32_t height;
    float patch_radius;
    float min_std_u8;
    float padding0;
    float padding1;
    float basis_u[4];
    float basis_v[4];
    float projection0[4];
    float projection1[4];
    float projection2[4];
};
static_assert(sizeof(PatchParams) == 112);

struct StructuralPlaneSweepRuntime {
    std::mutex execution_mutex;
    std::unique_ptr<GPUDevice> device;
    GPUComputePipelineHandle pipeline{};

    ~StructuralPlaneSweepRuntime() {
        if (device && pipeline.valid()) {
            device->destroy_compute_pipeline(pipeline);
        }
    }
};

std::shared_ptr<StructuralPlaneSweepRuntime> acquire_structural_runtime() {
    // [DETOX 2026-08-07 用户签决"摘三装机"] plane-sweep 判死残留摘除:
    // known_plane_patch_normalize shader 已不再烘焙(源移入
    // shaders/wgsl_attic_planesweep/),GPU runtime 永久不可用。走既有
    // 优雅失败路径 return {} —— C ABI 保留,调用方拿到 unavailable。
    return {};
}

#endif  // AETHER_ENABLE_DAWN

}  // namespace

struct aether_planesweep_session {
    aether_planesweep_session_options_t options{};
    std::vector<float> points_xyz;
    std::vector<float> camera_centers_xyz;
    std::vector<std::uint8_t> camera_center_written;
    std::vector<std::uint8_t> slot_written;
    std::vector<float> center_rgb;
    std::mutex mutex;
#if defined(AETHER_ENABLE_DAWN)
    std::shared_ptr<StructuralPlaneSweepRuntime> runtime;
    GPUBufferHandle points{};
    GPUBufferHandle patches{};
    GPUBufferHandle valid{};
    GPUBufferHandle stddev{};
    std::size_t patch_slice_bytes = 0;
    std::size_t valid_slice_bytes = 0;
    std::size_t patch_stride_bytes = 0;
    std::size_t valid_stride_bytes = 0;
#endif
};

struct aether_planesweep_image {
    int32_t width = 0;
    int32_t height = 0;
    std::vector<std::uint32_t> packed_rgba8;
    std::mutex mutex;
#if defined(AETHER_ENABLE_DAWN)
    std::shared_ptr<StructuralPlaneSweepRuntime> runtime;
    GPUBufferHandle gpu_image{};
#endif
};

#if defined(AETHER_ENABLE_DAWN)

namespace {

std::vector<int> exact_clique_views_for_point(
    const float* normalized_patches,
    const std::uint8_t* valid,
    const std::uint8_t* candidate_view_mask,
    int32_t view_count,
    int32_t point_count,
    int32_t sample_count,
    int32_t point,
    const float* camera_centers_xyz,
    const float* point_xyz,
    const aether_planesweep_birth_options_t& options) {
    std::vector<int> candidates;
    for (int32_t view = 0; view < view_count; ++view) {
        const std::size_t valid_index =
            static_cast<std::size_t>(view) * point_count + point;
        const bool selected = !candidate_view_mask ||
            candidate_view_mask[static_cast<std::size_t>(point) * view_count +
                                view] != 0;
        if (selected && valid[valid_index] != 0) candidates.push_back(view);
    }
    if (candidates.size() < static_cast<std::size_t>(options.minimum_views) ||
        candidates.size() > 63) {
        return {};
    }

    const int count = static_cast<int>(candidates.size());
    std::vector<double> ncc(static_cast<std::size_t>(count * count), 1.0);
    for (int a = 0; a < count; ++a) {
        const std::size_t base_a =
            (static_cast<std::size_t>(candidates[a]) * point_count + point) *
            sample_count;
        for (int b = a + 1; b < count; ++b) {
            const std::size_t base_b =
                (static_cast<std::size_t>(candidates[b]) * point_count + point) *
                sample_count;
            double dot = 0.0;
            for (int32_t sample = 0; sample < sample_count; ++sample) {
                dot += static_cast<double>(normalized_patches[base_a + sample]) *
                    normalized_patches[base_b + sample];
            }
            ncc[static_cast<std::size_t>(a * count + b)] = dot;
            ncc[static_cast<std::size_t>(b * count + a)] = dot;
        }
    }
    const Clique clique = select_parallax_stable_clique(
        ncc, count, candidates, options.ncc_min, options.minimum_views,
        options.minimum_parallax_deg, camera_centers_xyz, point_xyz);
    std::vector<int> selected_views;
    selected_views.reserve(clique.members.size());
    for (const int member : clique.members) {
        selected_views.push_back(candidates[member]);
    }
    return selected_views;
}

int32_t planesweep_finish_impl(
    aether_planesweep_session_t* session,
    const uint8_t* candidate_view_masks,
    const aether_planesweep_birth_options_t* scale_options,
    int32_t scale_options_count,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity,
    uint8_t* out_rgb,
    int32_t rgb_capacity_bytes) {
    if (!session || !scale_options ||
        scale_options_count != session->options.scale_count || !out_results ||
        result_capacity < session->options.candidate_count) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    const int32_t required_rgb_bytes = session->options.candidate_count * 3;
    if ((out_rgb == nullptr && rgb_capacity_bytes != 0) ||
        (out_rgb != nullptr && rgb_capacity_bytes < required_rgb_bytes)) {
        return out_rgb != nullptr
            ? AETHER_PLANESWEEP_ERR_BUFFER_TOO_SMALL
            : AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    std::lock_guard<std::mutex> execution_lock(
        session->runtime->execution_mutex);
    auto& device = *session->runtime->device;
    const std::size_t slots =
        static_cast<std::size_t>(session->options.scale_count) *
        session->options.max_views;
    std::vector<std::uint8_t> raw_patches;
    std::vector<std::uint8_t> raw_valid;
    if (!readback(device, session->patches,
                  session->patch_stride_bytes * slots, &raw_patches) ||
        !readback(device, session->valid,
                  session->valid_stride_bytes * slots, &raw_valid)) {
        return AETHER_PLANESWEEP_ERR_GPU;
    }
    std::memset(out_results, 0,
                static_cast<std::size_t>(result_capacity) * sizeof(*out_results));
    if (out_rgb) {
        std::memset(out_rgb, 0, static_cast<std::size_t>(required_rgb_bytes));
    }
    for (int32_t candidate = 0;
         candidate < session->options.candidate_count; ++candidate) {
        out_results[candidate].median_ncc = kNegativeInfinity;
        out_results[candidate].observed_depth_margin = kNegativeInfinity;
    }
    const int32_t point_count = session->options.point_count;
    const int32_t view_count = session->options.max_views;
    const int32_t sample_count =
        session->options.patch_n * session->options.patch_n;
    std::vector<float> scale_patches(
        static_cast<std::size_t>(view_count) * point_count * sample_count);
    std::vector<std::uint8_t> scale_valid(
        static_cast<std::size_t>(view_count) * point_count, 0);
    std::vector<int32_t> supporting(point_count);
    std::vector<float> ncc(point_count);
    std::vector<float> parallax(point_count);
    std::vector<std::uint8_t> score_valid(point_count);

    for (int32_t scale = 0; scale < session->options.scale_count; ++scale) {
        std::fill(scale_valid.begin(), scale_valid.end(), 0);
        for (int32_t view = 0; view < view_count; ++view) {
            const std::size_t slot =
                static_cast<std::size_t>(scale) * view_count + view;
            if (session->slot_written[slot] == 0) continue;
            std::memcpy(
                scale_patches.data() +
                    static_cast<std::size_t>(view) * point_count * sample_count,
                raw_patches.data() + slot * session->patch_stride_bytes,
                session->patch_slice_bytes);
            const auto* valid_u32 = reinterpret_cast<const std::uint32_t*>(
                raw_valid.data() + slot * session->valid_stride_bytes);
            for (int32_t point = 0; point < point_count; ++point) {
                scale_valid[static_cast<std::size_t>(view) * point_count + point] =
                    valid_u32[point] != 0 ? 1 : 0;
            }
        }
        const std::uint8_t* mask = candidate_view_masks
            ? candidate_view_masks +
                static_cast<std::size_t>(scale) * point_count * view_count
            : nullptr;
        const int32_t score_rc = score_scale_with_hypothesis_roles(
            scale_patches.data(), scale_valid.data(), mask,
            session->camera_centers_xyz.data(), session->points_xyz.data(),
            view_count, point_count, sample_count,
            session->options.hypotheses_per_candidate, &scale_options[scale],
            supporting.data(), ncc.data(), parallax.data(), score_valid.data());
        if (score_rc != AETHER_PLANESWEEP_OK) return score_rc;

        std::vector<std::uint8_t> accepted_before;
        if (out_rgb) {
            accepted_before.resize(session->options.candidate_count, 0);
            for (int32_t candidate = 0;
                 candidate < session->options.candidate_count; ++candidate) {
                accepted_before[candidate] =
                    out_results[candidate].accepted != 0 ? 1 : 0;
            }
        }
        const int32_t ownership_rc = aether_planesweep_apply_unique_depth(
            session->options.candidate_count,
            session->options.hypotheses_per_candidate,
            supporting.data(), ncc.data(), parallax.data(), score_valid.data(),
            &scale_options[scale], out_results, result_capacity,
            /*rescue_only=*/scale > 0 ? 1 : 0);
        if (ownership_rc != AETHER_PLANESWEEP_OK) return ownership_rc;
        if (!out_rgb) continue;

        for (int32_t candidate = 0;
             candidate < session->options.candidate_count; ++candidate) {
            if (accepted_before[candidate] != 0 ||
                out_results[candidate].accepted == 0) {
                continue;
            }
            const int32_t center =
                candidate * session->options.hypotheses_per_candidate;
            const std::vector<int> clique_views = exact_clique_views_for_point(
                scale_patches.data(), scale_valid.data(), mask, view_count,
                point_count, sample_count, center,
                session->camera_centers_xyz.data(),
                session->points_xyz.data() + center * 3,
                scale_options[scale]);
            if (clique_views.size() != static_cast<std::size_t>(
                    out_results[candidate].supporting_views)) {
                return AETHER_PLANESWEEP_ERR_INTERNAL;
            }
            for (int channel = 0; channel < 3; ++channel) {
                std::vector<double> values;
                values.reserve(clique_views.size());
                for (const int view : clique_views) {
                    const std::size_t slot =
                        static_cast<std::size_t>(scale) * view_count + view;
                    const std::size_t color_index =
                        (slot * point_count + center) * 3 + channel;
                    values.push_back(session->center_rgb[color_index]);
                }
                const double value = std::clamp(
                    std::nearbyint(median(std::move(values))), 0.0, 255.0);
                out_rgb[static_cast<std::size_t>(candidate) * 3 + channel] =
                    static_cast<std::uint8_t>(value);
            }
        }
    }
    return AETHER_PLANESWEEP_OK;
}

}  // namespace

#endif  // AETHER_ENABLE_DAWN

extern "C" {

void aether_planesweep_session_options_default(
    aether_planesweep_session_options_t* out_options) {
    if (!out_options) return;
    std::memset(out_options, 0, sizeof(*out_options));
    out_options->patch_n = 9;
    out_options->max_views = 10;
    out_options->scale_count = 1;
}

void aether_planesweep_birth_options_default(
    aether_planesweep_birth_options_t* out_options) {
    if (!out_options) return;
    out_options->minimum_views = 3;
    out_options->ncc_min = 0.70f;
    out_options->minimum_parallax_deg = 5.0f;
    out_options->unique_depth_margin = 0.02f;
    out_options->post_min_ncc = 0.0f;
    out_options->post_minimum_views = 0;
    out_options->post_minimum_parallax_deg = 0.0f;
}

int32_t aether_planesweep_score_scale(
    const float* normalized_patches,
    const uint8_t* valid,
    const uint8_t* candidate_view_mask,
    const float* camera_centers_xyz,
    const float* points_xyz,
    int32_t view_count,
    int32_t point_count,
    int32_t sample_count,
    const aether_planesweep_birth_options_t* options,
    int32_t* out_supporting_views,
    float* out_median_ncc,
    float* out_max_parallax_deg,
    uint8_t* out_valid_score) {
    // Standalone callers score independent center hypotheses. Session finish
    // supplies the real candidate grouping so parallel competitors cannot use
    // the center-only parallax tie rescue.
    return score_scale_with_hypothesis_roles(
        normalized_patches, valid, candidate_view_mask, camera_centers_xyz,
        points_xyz, view_count, point_count, sample_count,
        /*hypotheses_per_candidate=*/1, options, out_supporting_views,
        out_median_ncc, out_max_parallax_deg, out_valid_score);
}

int32_t aether_planesweep_score_scale_grouped(
    const float* normalized_patches,
    const uint8_t* valid,
    const uint8_t* candidate_view_mask,
    const float* camera_centers_xyz,
    const float* points_xyz,
    int32_t view_count,
    int32_t point_count,
    int32_t sample_count,
    int32_t hypotheses_per_candidate,
    const aether_planesweep_birth_options_t* options,
    int32_t* out_supporting_views,
    float* out_median_ncc,
    float* out_max_parallax_deg,
    uint8_t* out_valid_score) {
    return score_scale_with_hypothesis_roles(
        normalized_patches, valid, candidate_view_mask, camera_centers_xyz,
        points_xyz, view_count, point_count, sample_count,
        hypotheses_per_candidate, options, out_supporting_views,
        out_median_ncc, out_max_parallax_deg, out_valid_score);
}

int32_t aether_planesweep_apply_unique_depth(
    int32_t candidate_count,
    int32_t hypotheses_per_candidate,
    const int32_t* supporting_views,
    const float* median_ncc,
    const float* max_parallax_deg,
    const uint8_t* valid_score,
    const aether_planesweep_birth_options_t* options,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity,
    int32_t rescue_only) {
    if (candidate_count <= 0 || hypotheses_per_candidate <= 0 ||
        !supporting_views || !median_ncc || !max_parallax_deg ||
        !valid_score || !options || !out_results ||
        result_capacity < candidate_count ||
        !std::isfinite(options->ncc_min) || options->ncc_min <= 0.0f ||
        options->ncc_min > 1.0f ||
        !std::isfinite(options->minimum_parallax_deg) ||
        options->minimum_parallax_deg <= 0.0f ||
        options->minimum_parallax_deg > 180.0f ||
        !std::isfinite(options->unique_depth_margin) ||
        options->unique_depth_margin < 0.0f ||
        options->unique_depth_margin > 2.0f ||
        !std::isfinite(options->post_min_ncc) ||
        options->post_min_ncc < 0.0f || options->post_min_ncc > 1.0f ||
        options->post_minimum_views < 0 ||
        !std::isfinite(options->post_minimum_parallax_deg) ||
        options->post_minimum_parallax_deg < 0.0f ||
        options->post_minimum_parallax_deg > 180.0f) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    for (int32_t candidate = 0; candidate < candidate_count; ++candidate) {
        if (rescue_only != 0 && out_results[candidate].accepted != 0) continue;
        const int32_t center = candidate * hypotheses_per_candidate;
        if (valid_score[center] == 0 ||
            supporting_views[center] <= 0 ||
            !std::isfinite(median_ncc[center]) ||
            median_ncc[center] < -1.0f || median_ncc[center] > 1.0f ||
            !std::isfinite(max_parallax_deg[center]) ||
            max_parallax_deg[center] < 0.0f ||
            max_parallax_deg[center] > 180.0f ||
            median_ncc[center] < options->post_min_ncc ||
            supporting_views[center] < options->post_minimum_views ||
            max_parallax_deg[center] < options->post_minimum_parallax_deg) {
            continue;
        }
        bool unique = true;
        float best_alternative = kNegativeInfinity;
        std::int32_t best_alternative_units =
            std::numeric_limits<std::int32_t>::min();
        const std::int32_t center_units =
            canonical_ncc_units(median_ncc[center]);
        const std::int32_t margin_units =
            canonical_ncc_margin_units(options->unique_depth_margin);
        for (int32_t hypothesis = 1;
             hypothesis < hypotheses_per_candidate; ++hypothesis) {
            const int32_t point = center + hypothesis;
            if (valid_score[point] == 0) continue;
            if (supporting_views[point] <= 0 ||
                !std::isfinite(median_ncc[point]) ||
                median_ncc[point] < -1.0f || median_ncc[point] > 1.0f ||
                !std::isfinite(max_parallax_deg[point]) ||
                max_parallax_deg[point] < 0.0f ||
                max_parallax_deg[point] > 180.0f) {
                unique = false;
                continue;
            }
            best_alternative = std::max(best_alternative, median_ncc[point]);
            const std::int32_t alternative_units =
                canonical_ncc_units(median_ncc[point]);
            best_alternative_units =
                std::max(best_alternative_units, alternative_units);
            const std::int32_t required_units =
                alternative_units + margin_units;
            // Millincc units absorb decoder/backend noise. Only the exact
            // canonical boundary is resolved with the raw evidence. When two
            // decoders straddle that boundary by at most the frozen decoder
            // band, independently strong geometry may break the tie; an
            // ordinary low-parallax rounded-up margin still fails closed.
            const double raw_margin =
                static_cast<double>(median_ncc[center]) -
                static_cast<double>(median_ncc[point]);
            const bool strong_geometry_boundary =
                center_units == required_units &&
                raw_margin + kDecoderStableNccTieBand >=
                    static_cast<double>(options->unique_depth_margin) &&
                static_cast<double>(max_parallax_deg[center]) >=
                    2.0 * static_cast<double>(options->minimum_parallax_deg);
            const bool clears_depth_margin =
                center_units > required_units ||
                (center_units == required_units &&
                 (raw_margin >=
                      static_cast<double>(options->unique_depth_margin) ||
                  strong_geometry_boundary));
            if (supporting_views[center] < supporting_views[point] ||
                !clears_depth_margin) {
                unique = false;
            }
        }
        if (!unique) continue;
        auto& result = out_results[candidate];
        result.accepted = 1;
        result.supporting_views = supporting_views[center];
        result.median_ncc = median_ncc[center];
        result.max_parallax_deg = max_parallax_deg[center];
        result.observed_depth_margin = std::isfinite(best_alternative)
            ? static_cast<float>(center_units - best_alternative_units) /
                static_cast<float>(kNccDecisionUnitsPerOne)
            : std::numeric_limits<float>::infinity();
    }
    return AETHER_PLANESWEEP_OK;
}

int32_t aether_planesweep_session_create(
    const aether_planesweep_session_options_t* options,
    const float* points_xyz,
    aether_planesweep_session_t** out_session) {
    if (!options || !points_xyz || !out_session || options->point_count <= 0 ||
        options->candidate_count <= 0 ||
        options->hypotheses_per_candidate <= 0 ||
        options->point_count !=
            options->candidate_count * options->hypotheses_per_candidate ||
        options->patch_n <= 0 || options->patch_n > 9 ||
        options->max_views <= 0 || options->scale_count <= 0) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    *out_session = nullptr;
#if !defined(AETHER_ENABLE_DAWN)
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    std::unique_ptr<aether_planesweep_session> session(
        new (std::nothrow) aether_planesweep_session());
    if (!session) return AETHER_PLANESWEEP_ERR_INTERNAL;
    session->options = *options;
    session->points_xyz.assign(
        points_xyz, points_xyz + static_cast<std::size_t>(options->point_count) * 3);
    session->camera_centers_xyz.assign(
        static_cast<std::size_t>(options->max_views) * 3,
        std::numeric_limits<float>::quiet_NaN());
    session->camera_center_written.assign(options->max_views, 0);
    session->slot_written.assign(
        static_cast<std::size_t>(options->scale_count) * options->max_views, 0);
    session->center_rgb.assign(
        static_cast<std::size_t>(options->scale_count) * options->max_views *
            options->point_count * 3,
        0.0f);
    session->runtime = acquire_structural_runtime();
    if (!session->runtime) return AETHER_PLANESWEEP_ERR_GPU;
    std::lock_guard<std::mutex> execution_lock(
        session->runtime->execution_mutex);
    auto& device = *session->runtime->device;

    std::vector<float> points4(
        static_cast<std::size_t>(options->point_count) * 4, 1.0f);
    for (int32_t point = 0; point < options->point_count; ++point) {
        std::memcpy(points4.data() + point * 4,
                    points_xyz + point * 3,
                    3 * sizeof(float));
    }
    session->points = make_buffer(
        device, points4.size() * sizeof(float),
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "planesweep_points");
    if (!session->points.valid()) return AETHER_PLANESWEEP_ERR_GPU;
    device.update_buffer(
        session->points, points4.data(), 0, points4.size() * sizeof(float));

    const std::size_t samples =
        static_cast<std::size_t>(options->patch_n) * options->patch_n;
    session->patch_slice_bytes =
        static_cast<std::size_t>(options->point_count) * samples * sizeof(float);
    session->valid_slice_bytes =
        static_cast<std::size_t>(options->point_count) * sizeof(std::uint32_t);
    session->patch_stride_bytes = align256(session->patch_slice_bytes);
    session->valid_stride_bytes = align256(session->valid_slice_bytes);
    const std::size_t slots =
        static_cast<std::size_t>(options->scale_count) * options->max_views;
    session->patches = make_buffer(
        device, session->patch_stride_bytes * slots,
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "planesweep_patches");
    session->valid = make_buffer(
        device, session->valid_stride_bytes * slots,
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "planesweep_valid");
    session->stddev = make_buffer(
        device, session->valid_stride_bytes * slots,
        GPUBufferUsage::kStorage, GPUStorageMode::kPrivate,
        "planesweep_stddev");
    if (!session->patches.valid() || !session->valid.valid() ||
        !session->stddev.valid()) {
        return AETHER_PLANESWEEP_ERR_GPU;
    }
    *out_session = session.release();
    return AETHER_PLANESWEEP_OK;
#endif
}

int32_t aether_planesweep_session_add_view(
    aether_planesweep_session_t* session,
    int32_t scale_index,
    int32_t view_index,
    const uint32_t* packed_rgba8,
    int32_t width,
    int32_t height,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    float patch_radius_m,
    float min_std_u8) {
    if (!session || !packed_rgba8 || !projection_row_major_3x4 ||
        !camera_center_xyz || scale_index < 0 ||
        scale_index >= session->options.scale_count || view_index < 0 ||
        view_index >= session->options.max_views || width <= 1 || height <= 1 ||
        !finite_positive(patch_radius_m) || !finite_positive(min_std_u8)) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
#if !defined(AETHER_ENABLE_DAWN)
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    std::lock_guard<std::mutex> lock(session->mutex);
    std::lock_guard<std::mutex> execution_lock(
        session->runtime->execution_mutex);
    auto& device = *session->runtime->device;
    const std::size_t slot =
        static_cast<std::size_t>(scale_index) * session->options.max_views + view_index;
    if (session->slot_written[slot] != 0) return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    if (session->camera_center_written[view_index] != 0) {
        for (int axis = 0; axis < 3; ++axis) {
            const float old_value =
                session->camera_centers_xyz[static_cast<std::size_t>(view_index) * 3 + axis];
            if (std::abs(old_value - camera_center_xyz[axis]) > 1e-5f) {
                return AETHER_PLANESWEEP_ERR_BAD_ARGS;
            }
        }
    } else {
        std::memcpy(
            session->camera_centers_xyz.data() +
                static_cast<std::size_t>(view_index) * 3,
            camera_center_xyz, 3 * sizeof(float));
        session->camera_center_written[view_index] = 1;
    }
    // Retain only the projected center color for each hypothesis. Full decoded
    // pixels are released after this call; the later finish_rgb uses these
    // values only for views that independently passed the full patch/texture
    // and all-pairs clique gates.
    const auto* rgba_bytes = reinterpret_cast<const std::uint8_t*>(packed_rgba8);
    const std::size_t color_base =
        slot * static_cast<std::size_t>(session->options.point_count) * 3;
    for (int32_t point = 0; point < session->options.point_count; ++point) {
        const float* xyz = session->points_xyz.data() + point * 3;
        const float q0 = projection_row_major_3x4[0] * xyz[0] +
                         projection_row_major_3x4[1] * xyz[1] +
                         projection_row_major_3x4[2] * xyz[2] +
                         projection_row_major_3x4[3];
        const float q1 = projection_row_major_3x4[4] * xyz[0] +
                         projection_row_major_3x4[5] * xyz[1] +
                         projection_row_major_3x4[6] * xyz[2] +
                         projection_row_major_3x4[7];
        const float q2 = projection_row_major_3x4[8] * xyz[0] +
                         projection_row_major_3x4[9] * xyz[1] +
                         projection_row_major_3x4[10] * xyz[2] +
                         projection_row_major_3x4[11];
        if (!(q2 > 0.05f)) continue;
        const float x = q0 / q2;
        const float y = q1 / q2;
        const int32_t x0 = static_cast<int32_t>(std::floor(x));
        const int32_t y0 = static_cast<int32_t>(std::floor(y));
        const int32_t x1 = x0 + 1;
        const int32_t y1 = y0 + 1;
        if (x0 < 0 || y0 < 0 || x1 >= width || y1 >= height) continue;
        const float dx = x - static_cast<float>(x0);
        const float dy = y - static_cast<float>(y0);
        const float weights[4] = {
            (1.0f - dx) * (1.0f - dy), dx * (1.0f - dy),
            (1.0f - dx) * dy, dx * dy};
        const int32_t xs[4] = {x0, x1, x0, x1};
        const int32_t ys[4] = {y0, y0, y1, y1};
        for (int channel = 0; channel < 3; ++channel) {
            float value = 0.0f;
            for (int corner = 0; corner < 4; ++corner) {
                const std::size_t pixel =
                    (static_cast<std::size_t>(ys[corner]) * width + xs[corner]) * 4;
                value += weights[corner] * rgba_bytes[pixel + channel];
            }
            session->center_rgb[color_base + static_cast<std::size_t>(point) * 3 +
                                channel] = value;
        }
    }
    const std::size_t image_bytes =
        static_cast<std::size_t>(width) * height * sizeof(std::uint32_t);
    const auto image = make_buffer(
        device, image_bytes, GPUBufferUsage::kStorage,
        GPUStorageMode::kPrivate, "planesweep_image");
    const auto params_buffer = make_buffer(
        device, sizeof(PatchParams), GPUBufferUsage::kUniform,
        GPUStorageMode::kPrivate, "planesweep_params");
    if (!image.valid() || !params_buffer.valid()) {
        if (image.valid()) device.destroy_buffer(image);
        if (params_buffer.valid()) device.destroy_buffer(params_buffer);
        return AETHER_PLANESWEEP_ERR_GPU;
    }
    device.update_buffer(image, packed_rgba8, 0, image_bytes);
    PatchParams params{};
    params.point_count = static_cast<std::uint32_t>(session->options.point_count);
    params.patch_n = static_cast<std::uint32_t>(session->options.patch_n);
    params.width = static_cast<std::uint32_t>(width);
    params.height = static_cast<std::uint32_t>(height);
    params.patch_radius = patch_radius_m;
    params.min_std_u8 = min_std_u8;
    std::memcpy(params.basis_u, session->options.basis_u_xyz, 3 * sizeof(float));
    std::memcpy(params.basis_v, session->options.basis_v_xyz, 3 * sizeof(float));
    std::memcpy(params.projection0, projection_row_major_3x4, 4 * sizeof(float));
    std::memcpy(params.projection1, projection_row_major_3x4 + 4, 4 * sizeof(float));
    std::memcpy(params.projection2, projection_row_major_3x4 + 8, 4 * sizeof(float));
    device.update_buffer(params_buffer, &params, 0, sizeof(params));

    auto command = device.create_command_buffer();
    auto* encoder = command ? command->make_compute_encoder() : nullptr;
    if (!encoder) {
        device.destroy_buffer(image);
        device.destroy_buffer(params_buffer);
        return AETHER_PLANESWEEP_ERR_GPU;
    }
    encoder->set_pipeline(session->runtime->pipeline);
    encoder->set_buffer(image, 0, 0);
    encoder->set_buffer(session->points, 0, 1);
    encoder->set_buffer(params_buffer, 0, 2);
    encoder->set_buffer(
        session->patches,
        static_cast<std::uint32_t>(slot * session->patch_stride_bytes), 3);
    encoder->set_buffer(
        session->valid,
        static_cast<std::uint32_t>(slot * session->valid_stride_bytes), 4);
    encoder->set_buffer(
        session->stddev,
        static_cast<std::uint32_t>(slot * session->valid_stride_bytes), 5);
    encoder->dispatch_1d(
        static_cast<std::uint32_t>(session->options.point_count), 64);
    encoder->end_encoding();
    command->commit();
    command->wait_until_completed();
    const bool ok = !command->had_error();
    device.destroy_buffer(image);
    device.destroy_buffer(params_buffer);
    if (!ok) return AETHER_PLANESWEEP_ERR_GPU;
    session->slot_written[slot] = 1;
    return AETHER_PLANESWEEP_OK;
#endif
}

int32_t aether_planesweep_image_create_rgba(
    const uint32_t* packed_rgba8,
    int32_t width,
    int32_t height,
    aether_planesweep_image_t** out_image) {
    if (out_image) *out_image = nullptr;
    if (!packed_rgba8 || width <= 1 || height <= 1 || !out_image) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    const std::size_t pixel_count =
        static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    if (pixel_count / static_cast<std::size_t>(width) !=
        static_cast<std::size_t>(height)) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    std::unique_ptr<aether_planesweep_image> image(
        new (std::nothrow) aether_planesweep_image());
    if (!image) return AETHER_PLANESWEEP_ERR_INTERNAL;
    try {
        image->packed_rgba8.assign(
            packed_rgba8, packed_rgba8 + pixel_count);
    } catch (...) {
        return AETHER_PLANESWEEP_ERR_INTERNAL;
    }
    image->width = width;
    image->height = height;
    *out_image = image.release();
    return AETHER_PLANESWEEP_OK;
}

int32_t aether_planesweep_session_add_image_view_scales(
    aether_planesweep_session_t* session,
    int32_t view_index,
    aether_planesweep_image_t* image,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    const float* patch_radius_m_by_scale,
    const float* min_std_u8_by_scale,
    int32_t scale_count) {
    if (!session || !image || image->packed_rgba8.empty() ||
        !projection_row_major_3x4 ||
        !camera_center_xyz || !patch_radius_m_by_scale ||
        !min_std_u8_by_scale || scale_count != session->options.scale_count ||
        view_index < 0 || view_index >= session->options.max_views ||
        image->width <= 1 || image->height <= 1) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    for (int32_t scale = 0; scale < scale_count; ++scale) {
        if (!finite_positive(patch_radius_m_by_scale[scale]) ||
            !finite_positive(min_std_u8_by_scale[scale])) {
            return AETHER_PLANESWEEP_ERR_BAD_ARGS;
        }
    }
#if !defined(AETHER_ENABLE_DAWN)
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    const auto* packed_rgba8 = image->packed_rgba8.data();
    const int32_t width = image->width;
    const int32_t height = image->height;
    // Keep the exact same per-scale dispatches while sharing one image buffer
    // and one command buffer. The decoded image can also be reused across
    // independent tile sessions, but output slots remain disjoint.
    std::lock_guard<std::mutex> lock(session->mutex);
    std::lock_guard<std::mutex> image_lock(image->mutex);
    std::lock_guard<std::mutex> execution_lock(
        session->runtime->execution_mutex);
    auto& device = *session->runtime->device;

    if (image->runtime && image->runtime != session->runtime) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    if (!image->runtime) image->runtime = session->runtime;
    if (!image->gpu_image.valid()) {
        const std::size_t image_bytes =
            static_cast<std::size_t>(width) * height * sizeof(std::uint32_t);
        image->gpu_image = make_buffer(
            device, image_bytes, GPUBufferUsage::kStorage,
            GPUStorageMode::kPrivate, "planesweep_shared_image");
        if (!image->gpu_image.valid()) return AETHER_PLANESWEEP_ERR_GPU;
        device.update_buffer(
            image->gpu_image, packed_rgba8, 0, image_bytes);
    }

    for (int32_t scale = 0; scale < scale_count; ++scale) {
        const std::size_t slot =
            static_cast<std::size_t>(scale) * session->options.max_views +
            view_index;
        if (session->slot_written[slot] != 0) {
            return AETHER_PLANESWEEP_ERR_BAD_ARGS;
        }
    }
    if (session->camera_center_written[view_index] != 0) {
        for (int axis = 0; axis < 3; ++axis) {
            const float old_value = session->camera_centers_xyz[
                static_cast<std::size_t>(view_index) * 3 + axis];
            if (std::abs(old_value - camera_center_xyz[axis]) > 1e-5f) {
                return AETHER_PLANESWEEP_ERR_BAD_ARGS;
            }
        }
    } else {
        std::memcpy(
            session->camera_centers_xyz.data() +
                static_cast<std::size_t>(view_index) * 3,
            camera_center_xyz, 3 * sizeof(float));
        session->camera_center_written[view_index] = 1;
    }

    // Center colour is independent of quality scale. Compute it once using
    // the same bilinear arithmetic as add_view, then copy the identical values
    // into each scale slot used by finish_rgb.
    const auto* rgba_bytes =
        reinterpret_cast<const std::uint8_t*>(packed_rgba8);
    const std::size_t colour_values =
        static_cast<std::size_t>(session->options.point_count) * 3;
    std::vector<float> centre_rgb(colour_values, 0.0f);
    for (int32_t point = 0; point < session->options.point_count; ++point) {
        const float* xyz = session->points_xyz.data() + point * 3;
        const float q0 = projection_row_major_3x4[0] * xyz[0] +
                         projection_row_major_3x4[1] * xyz[1] +
                         projection_row_major_3x4[2] * xyz[2] +
                         projection_row_major_3x4[3];
        const float q1 = projection_row_major_3x4[4] * xyz[0] +
                         projection_row_major_3x4[5] * xyz[1] +
                         projection_row_major_3x4[6] * xyz[2] +
                         projection_row_major_3x4[7];
        const float q2 = projection_row_major_3x4[8] * xyz[0] +
                         projection_row_major_3x4[9] * xyz[1] +
                         projection_row_major_3x4[10] * xyz[2] +
                         projection_row_major_3x4[11];
        if (!(q2 > 0.05f)) continue;
        const float x = q0 / q2;
        const float y = q1 / q2;
        const int32_t x0 = static_cast<int32_t>(std::floor(x));
        const int32_t y0 = static_cast<int32_t>(std::floor(y));
        const int32_t x1 = x0 + 1;
        const int32_t y1 = y0 + 1;
        if (x0 < 0 || y0 < 0 || x1 >= width || y1 >= height) continue;
        const float dx = x - static_cast<float>(x0);
        const float dy = y - static_cast<float>(y0);
        const float weights[4] = {
            (1.0f - dx) * (1.0f - dy), dx * (1.0f - dy),
            (1.0f - dx) * dy, dx * dy};
        const int32_t xs[4] = {x0, x1, x0, x1};
        const int32_t ys[4] = {y0, y0, y1, y1};
        for (int channel = 0; channel < 3; ++channel) {
            float value = 0.0f;
            for (int corner = 0; corner < 4; ++corner) {
                const std::size_t pixel =
                    (static_cast<std::size_t>(ys[corner]) * width +
                     xs[corner]) * 4;
                value += weights[corner] * rgba_bytes[pixel + channel];
            }
            centre_rgb[static_cast<std::size_t>(point) * 3 + channel] = value;
        }
    }
    for (int32_t scale = 0; scale < scale_count; ++scale) {
        const std::size_t slot =
            static_cast<std::size_t>(scale) * session->options.max_views +
            view_index;
        std::memcpy(
            session->center_rgb.data() + slot * colour_values,
            centre_rgb.data(), colour_values * sizeof(float));
    }

    const std::size_t params_stride = align256(sizeof(PatchParams));
    const auto params_buffer = make_buffer(
        device, params_stride * static_cast<std::size_t>(scale_count),
        GPUBufferUsage::kUniform, GPUStorageMode::kPrivate,
        "planesweep_params_multiscale");
    if (!params_buffer.valid()) {
        return AETHER_PLANESWEEP_ERR_GPU;
    }

    auto command = device.create_command_buffer();
    auto* encoder = command ? command->make_compute_encoder() : nullptr;
    if (!encoder) {
        device.destroy_buffer(params_buffer);
        return AETHER_PLANESWEEP_ERR_GPU;
    }
    encoder->set_pipeline(session->runtime->pipeline);
    encoder->set_buffer(image->gpu_image, 0, 0);
    encoder->set_buffer(session->points, 0, 1);
    for (int32_t scale = 0; scale < scale_count; ++scale) {
        const std::size_t slot =
            static_cast<std::size_t>(scale) * session->options.max_views +
            view_index;
        PatchParams params{};
        params.point_count =
            static_cast<std::uint32_t>(session->options.point_count);
        params.patch_n = static_cast<std::uint32_t>(session->options.patch_n);
        params.width = static_cast<std::uint32_t>(width);
        params.height = static_cast<std::uint32_t>(height);
        params.patch_radius = patch_radius_m_by_scale[scale];
        params.min_std_u8 = min_std_u8_by_scale[scale];
        std::memcpy(
            params.basis_u, session->options.basis_u_xyz, 3 * sizeof(float));
        std::memcpy(
            params.basis_v, session->options.basis_v_xyz, 3 * sizeof(float));
        std::memcpy(
            params.projection0, projection_row_major_3x4, 4 * sizeof(float));
        std::memcpy(
            params.projection1, projection_row_major_3x4 + 4,
            4 * sizeof(float));
        std::memcpy(
            params.projection2, projection_row_major_3x4 + 8,
            4 * sizeof(float));
        const std::size_t params_offset =
            static_cast<std::size_t>(scale) * params_stride;
        device.update_buffer(
            params_buffer, &params, params_offset, sizeof(params));
        encoder->set_buffer(
            params_buffer, static_cast<std::uint32_t>(params_offset), 2);
        encoder->set_buffer(
            session->patches,
            static_cast<std::uint32_t>(slot * session->patch_stride_bytes), 3);
        encoder->set_buffer(
            session->valid,
            static_cast<std::uint32_t>(slot * session->valid_stride_bytes), 4);
        encoder->set_buffer(
            session->stddev,
            static_cast<std::uint32_t>(slot * session->valid_stride_bytes), 5);
        encoder->dispatch_1d(
            static_cast<std::uint32_t>(session->options.point_count), 64);
    }
    encoder->end_encoding();
    command->commit();
    command->wait_until_completed();
    const bool ok = !command->had_error();
    device.destroy_buffer(params_buffer);
    if (!ok) return AETHER_PLANESWEEP_ERR_GPU;
    for (int32_t scale = 0; scale < scale_count; ++scale) {
        const std::size_t slot =
            static_cast<std::size_t>(scale) * session->options.max_views +
            view_index;
        session->slot_written[slot] = 1;
    }
    return AETHER_PLANESWEEP_OK;
#endif
}

int32_t aether_planesweep_session_add_view_scales(
    aether_planesweep_session_t* session,
    int32_t view_index,
    const uint32_t* packed_rgba8,
    int32_t width,
    int32_t height,
    const float projection_row_major_3x4[12],
    const float camera_center_xyz[3],
    const float* patch_radius_m_by_scale,
    const float* min_std_u8_by_scale,
    int32_t scale_count) {
    aether_planesweep_image_t* image = nullptr;
    const int32_t create_rc = aether_planesweep_image_create_rgba(
        packed_rgba8, width, height, &image);
    if (create_rc != AETHER_PLANESWEEP_OK) return create_rc;
    const int32_t add_rc = aether_planesweep_session_add_image_view_scales(
        session, view_index, image, projection_row_major_3x4,
        camera_center_xyz, patch_radius_m_by_scale, min_std_u8_by_scale,
        scale_count);
    aether_planesweep_image_free(image);
    return add_rc;
}

void aether_planesweep_image_free(aether_planesweep_image_t* image) {
    if (!image) return;
#if defined(AETHER_ENABLE_DAWN)
    std::lock_guard<std::mutex> image_lock(image->mutex);
    if (image->runtime && image->gpu_image.valid()) {
        std::lock_guard<std::mutex> execution_lock(
            image->runtime->execution_mutex);
        image->runtime->device->destroy_buffer(image->gpu_image);
        image->gpu_image = GPUBufferHandle{};
    }
#endif
    delete image;
}

int32_t aether_planesweep_session_debug_readback(
    aether_planesweep_session_t* session,
    float* out_normalized,
    int32_t normalized_capacity,
    uint8_t* out_valid,
    int32_t valid_capacity,
    float* out_stddev_u8,
    int32_t stddev_capacity) {
    if (!session || !out_normalized || !out_valid || !out_stddev_u8 ||
        normalized_capacity < 0 || valid_capacity < 0 ||
        stddev_capacity < 0) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
#if !defined(AETHER_ENABLE_DAWN)
    (void)normalized_capacity;
    (void)valid_capacity;
    (void)stddev_capacity;
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    const int32_t point_count = session->options.point_count;
    const int32_t sample_count =
        session->options.patch_n * session->options.patch_n;
    const int32_t slot_count =
        session->options.scale_count * session->options.max_views;
    const int64_t required_normalized =
        static_cast<int64_t>(slot_count) * point_count * sample_count;
    const int64_t required_values =
        static_cast<int64_t>(slot_count) * point_count;
    if (normalized_capacity < required_normalized ||
        valid_capacity < required_values ||
        stddev_capacity < required_values) {
        return AETHER_PLANESWEEP_ERR_BUFFER_TOO_SMALL;
    }

    std::lock_guard<std::mutex> lock(session->mutex);
    std::lock_guard<std::mutex> execution_lock(
        session->runtime->execution_mutex);
    auto& device = *session->runtime->device;
    std::vector<std::uint8_t> raw_patches;
    std::vector<std::uint8_t> raw_valid;
    std::vector<std::uint8_t> raw_stddev;
    if (!readback(device, session->patches,
                  session->patch_stride_bytes * slot_count, &raw_patches) ||
        !readback(device, session->valid,
                  session->valid_stride_bytes * slot_count, &raw_valid) ||
        !readback(device, session->stddev,
                  session->valid_stride_bytes * slot_count, &raw_stddev)) {
        return AETHER_PLANESWEEP_ERR_GPU;
    }
    std::fill_n(out_normalized, required_normalized, 0.0f);
    std::fill_n(out_valid, required_values, std::uint8_t{0});
    std::fill_n(out_stddev_u8, required_values, 0.0f);
    for (int32_t slot = 0; slot < slot_count; ++slot) {
        if (session->slot_written[slot] == 0) continue;
        const std::size_t dense_patch_offset =
            static_cast<std::size_t>(slot) * point_count * sample_count;
        const std::size_t dense_value_offset =
            static_cast<std::size_t>(slot) * point_count;
        std::memcpy(
            out_normalized + dense_patch_offset,
            raw_patches.data() +
                static_cast<std::size_t>(slot) * session->patch_stride_bytes,
            session->patch_slice_bytes);
        const auto* valid_u32 = reinterpret_cast<const std::uint32_t*>(
            raw_valid.data() +
                static_cast<std::size_t>(slot) * session->valid_stride_bytes);
        for (int32_t point = 0; point < point_count; ++point) {
            out_valid[dense_value_offset + point] =
                valid_u32[point] != 0 ? 1 : 0;
        }
        std::memcpy(
            out_stddev_u8 + dense_value_offset,
            raw_stddev.data() +
                static_cast<std::size_t>(slot) * session->valid_stride_bytes,
            static_cast<std::size_t>(point_count) * sizeof(float));
    }
    return AETHER_PLANESWEEP_OK;
#endif
}

int32_t aether_planesweep_session_finish(
    aether_planesweep_session_t* session,
    const uint8_t* candidate_view_masks,
    const aether_planesweep_birth_options_t* scale_options,
    int32_t scale_options_count,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity) {
#if !defined(AETHER_ENABLE_DAWN)
    if (!session || !scale_options || !out_results) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    (void)candidate_view_masks;
    (void)scale_options_count;
    (void)result_capacity;
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    return planesweep_finish_impl(
        session, candidate_view_masks, scale_options, scale_options_count,
        out_results, result_capacity, nullptr, 0);
#endif
}

int32_t aether_planesweep_session_finish_rgb(
    aether_planesweep_session_t* session,
    const uint8_t* candidate_view_masks,
    const aether_planesweep_birth_options_t* scale_options,
    int32_t scale_options_count,
    aether_planesweep_candidate_result_t* out_results,
    int32_t result_capacity,
    uint8_t* out_rgb,
    int32_t rgb_capacity_bytes) {
#if !defined(AETHER_ENABLE_DAWN)
    if (!session || !scale_options || !out_results || !out_rgb) {
        return AETHER_PLANESWEEP_ERR_BAD_ARGS;
    }
    (void)candidate_view_masks;
    (void)scale_options_count;
    (void)result_capacity;
    (void)rgb_capacity_bytes;
    return AETHER_PLANESWEEP_ERR_UNSUPPORTED;
#else
    return planesweep_finish_impl(
        session, candidate_view_masks, scale_options, scale_options_count,
        out_results, result_capacity, out_rgb, rgb_capacity_bytes);
#endif
}

void aether_planesweep_session_free(aether_planesweep_session_t* session) {
    if (!session) return;
#if defined(AETHER_ENABLE_DAWN)
    if (session->runtime) {
        std::lock_guard<std::mutex> execution_lock(
            session->runtime->execution_mutex);
        auto& device = *session->runtime->device;
        if (session->points.valid()) device.destroy_buffer(session->points);
        if (session->patches.valid()) device.destroy_buffer(session->patches);
        if (session->valid.valid()) device.destroy_buffer(session->valid);
        if (session->stddev.valid()) device.destroy_buffer(session->stddev);
    }
#endif
    delete session;
}

const char* aether_planesweep_result_str(int32_t rc) {
    switch (rc) {
        case AETHER_PLANESWEEP_OK: return "ok";
        case AETHER_PLANESWEEP_ERR_BAD_ARGS: return "bad_args";
        case AETHER_PLANESWEEP_ERR_UNSUPPORTED: return "unsupported";
        case AETHER_PLANESWEEP_ERR_GPU: return "gpu";
        case AETHER_PLANESWEEP_ERR_BUFFER_TOO_SMALL: return "buffer_too_small";
        case AETHER_PLANESWEEP_ERR_INTERNAL: return "internal";
        default: return "unknown";
    }
}

}  // extern "C"
