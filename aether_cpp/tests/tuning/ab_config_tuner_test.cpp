// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/innovation/f3_evidence_constrained_compression.h"
#include "aether/innovation/f6_conflict_dynamic_rejection.h"
#include "aether/innovation/f8_uncertainty_field.h"
#include "aether/innovation/f9_scene_passport_watermark.h"
#include "aether/render/dgrut_renderer.h"
#include "aether/scheduler/gpu_scheduler.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

using aether::innovation::F3BeliefRecord;
using aether::innovation::F3CompressionPlan;
using aether::innovation::F3PlanConfig;
using aether::innovation::F6ObservationPair;
using aether::innovation::F6RejectorConfig;
using aether::innovation::F8FieldConfig;
using aether::innovation::F8Observation;
using aether::innovation::F9WatermarkConfig;
using aether::innovation::F9WatermarkPacket;
using aether::innovation::GaussianPrimitive;
using aether::innovation::ProgressiveCompressionConfig;

float clamp01(float v) {
    if (v < 0.0f) {
        return 0.0f;
    }
    if (v > 1.0f) {
        return 1.0f;
    }
    return v;
}

std::uint32_t lcg_next(std::uint32_t& state) {
    state = state * 1664525u + 1013904223u;
    return state;
}

std::vector<GaussianPrimitive> make_f3_gaussians() {
    std::vector<GaussianPrimitive> out(12);
    for (std::size_t i = 0u; i < out.size(); ++i) {
        out[i].id = static_cast<std::uint32_t>(100u + i);
        out[i].host_unit_id = 1001u + static_cast<std::uint64_t>(i % 4u);
        out[i].patch_id = "blk:" + std::to_string(static_cast<int>(i % 4u)) + "_0_0";
        out[i].opacity = 0.20f + 0.06f * static_cast<float>(i % 8u);
        out[i].observation_count = static_cast<std::uint16_t>(1u + (i % 6u));
        out[i].patch_priority = static_cast<std::uint16_t>((i % 5u) == 0u ? 3u : 0u);
        out[i].capture_sequence = static_cast<std::uint32_t>(i);
        out[i].uncertainty = 0.05f + 0.08f * static_cast<float>(i % 6u);
    }
    return out;
}

std::vector<F3BeliefRecord> make_f3_beliefs() {
    using aether::evidence::DSMassFunction;
    std::vector<F3BeliefRecord> beliefs(4);
    beliefs[0].unit_id = 1001u;
    beliefs[0].patch_id = "blk:0_0_0";
    beliefs[0].mass = DSMassFunction(0.25, 0.15, 0.60);  // preserve
    beliefs[1].unit_id = 1002u;
    beliefs[1].patch_id = "blk:1_0_0";
    beliefs[1].mass = DSMassFunction(0.55, 0.20, 0.25);  // balanced
    beliefs[2].unit_id = 1003u;
    beliefs[2].patch_id = "blk:2_0_0";
    beliefs[2].mass = DSMassFunction(0.88, 0.06, 0.06);  // aggressive
    beliefs[3].unit_id = 1004u;
    beliefs[3].patch_id = "blk:3_0_0";
    beliefs[3].mass = DSMassFunction(0.92, 0.04, 0.04);  // aggressive
    return beliefs;
}

float eval_f3_score(const F3PlanConfig& cfg) {
    const auto gaussians = make_f3_gaussians();
    const auto beliefs = make_f3_beliefs();

    ProgressiveCompressionConfig base{};
    base.sh_coeff_count = 8u;
    base.quant_bits_position = 16u;
    base.quant_bits_scale = 16u;
    base.quant_bits_opacity = 8u;
    base.quant_bits_uncertainty = 12u;

    F3CompressionPlan plan{};
    const auto status = aether::innovation::f3_plan_evidence_constrained_compression(
        gaussians.data(),
        gaussians.size(),
        beliefs.data(),
        beliefs.size(),
        nullptr,
        base,
        cfg,
        &plan);
    if (status != aether::core::Status::kOk || plan.decisions.empty()) {
        return -1e9f;
    }

    float preserve_total = 0.0f;
    float preserve_kept = 0.0f;
    float aggr_total = 0.0f;
    float aggr_dropped = 0.0f;
    for (const auto& d : plan.decisions) {
        const std::uint64_t unit_id = gaussians[d.gaussian_index].host_unit_id;
        if (unit_id == 1001u) {
            preserve_total += 1.0f;
            if (d.keep) {
                preserve_kept += 1.0f;
            }
        } else if (unit_id == 1003u || unit_id == 1004u) {
            aggr_total += 1.0f;
            if (!d.keep) {
                aggr_dropped += 1.0f;
            }
        }
    }

    const float preserve_keep_rate = preserve_total > 0.0f ? (preserve_kept / preserve_total) : 0.0f;
    const float aggressive_drop_rate = aggr_total > 0.0f ? (aggr_dropped / aggr_total) : 0.0f;
    const float compression_ratio =
        1.0f - static_cast<float>(plan.kept_count) / static_cast<float>(gaussians.size());
    const float quant_saving =
        static_cast<float>(base.quant_bits_position - plan.adapted_config.quant_bits_position) /
        static_cast<float>(base.quant_bits_position);

    return 0.45f * preserve_keep_rate +
        0.25f * aggressive_drop_rate +
        0.20f * compression_ratio +
        0.10f * quant_saving;
}

float eval_scheduler_score(const aether::scheduler::GPUSchedulerConfig& cfg) {
    using aether::scheduler::GPUFrameResult;
    using aether::scheduler::GPUSchedulerState;
    using aether::scheduler::GPUWorkload;
    using aether::scheduler::TwoStateGPUScheduler;

    TwoStateGPUScheduler scheduler{cfg};

    struct Case {
        GPUSchedulerState state;
        GPUWorkload workload;
    };
    const Case cases[] = {
        {GPUSchedulerState::kCapturing, {9.0f, 7.0f, 5.0f}},
        {GPUSchedulerState::kCapturing, {6.0f, 8.0f, 4.0f}},
        {GPUSchedulerState::kCapturing, {7.0f, 7.0f, 7.0f}},
        {GPUSchedulerState::kCaptureFinished, {2.0f, 7.0f, 12.0f}},
        {GPUSchedulerState::kCaptureFinished, {3.0f, 6.0f, 10.0f}},
        {GPUSchedulerState::kCaptureFinished, {1.0f, 4.0f, 9.0f}},
    };

    float total = 0.0f;
    for (const auto& c : cases) {
        GPUFrameResult frame{};
        if (scheduler.execute_frame(c.state, c.workload, &frame) != aether::core::Status::kOk) {
            return -1e9f;
        }

        const float eps = 1e-4f;
        const float t_cov = std::min(frame.tracking_assigned_ms, c.workload.tracking_demand_ms) /
            std::max(c.workload.tracking_demand_ms, eps);
        const float r_cov = std::min(frame.rendering_assigned_ms, c.workload.rendering_demand_ms) /
            std::max(c.workload.rendering_demand_ms, eps);
        const float o_cov = std::min(frame.optimization_assigned_ms, c.workload.optimization_demand_ms) /
            std::max(c.workload.optimization_demand_ms, eps);

        float w_t = 1.0f;
        float w_r = 1.0f;
        float w_o = 1.0f;
        if (c.state == GPUSchedulerState::kCapturing) {
            w_t = cfg.capture_tracking_weight;
            w_r = cfg.capture_rendering_weight;
            w_o = cfg.capture_optimization_weight;
        } else {
            w_t = cfg.finished_tracking_weight;
            w_r = cfg.finished_rendering_weight;
            w_o = cfg.finished_optimization_weight;
        }
        const float w_sum = std::max(1e-4f, w_t + w_r + w_o);
        float score = (w_t * t_cov + w_r * r_cov + w_o * o_cov) / w_sum;

        if (c.state == GPUSchedulerState::kCapturing) {
            if (frame.tracking_assigned_ms >= frame.rendering_assigned_ms &&
                frame.rendering_assigned_ms >= frame.optimization_assigned_ms) {
                score += 0.05f;
            } else {
                score -= 0.10f;
            }
        } else {
            if (frame.optimization_assigned_ms >= frame.rendering_assigned_ms &&
                frame.rendering_assigned_ms >= frame.tracking_assigned_ms) {
                score += 0.05f;
            } else {
                score -= 0.10f;
            }
        }

        const float pool = std::max(1e-4f, frame.budget.flexible_pool_ms);
        score -= 0.03f * (frame.unused_flexible_ms / pool);
        total += score;
    }

    return total / static_cast<float>(sizeof(cases) / sizeof(cases[0]));
}

float eval_dgrut_score(const aether::render::DGRUTSelectionConfig& cfg) {
    std::vector<aether::render::DGRUTSplat> input;
    input.reserve(512u);
    std::uint32_t rng = 424242u;
    for (std::uint32_t i = 0u; i < 512u; ++i) {
        const float depth = static_cast<float>((lcg_next(rng) % 4000u) + 1u);
        const float opacity = static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f;
        const float radius = static_cast<float>(lcg_next(rng) % 1000u) / 700.0f;
        const float confidence = static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f;
        const float view = 0.4f + 0.6f * (static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f);
        const float coverage = static_cast<float>(lcg_next(rng) % 1000u) / 1000.0f;
        const std::uint32_t age = static_cast<std::uint32_t>(lcg_next(rng) % 120u);
        input.push_back(aether::render::DGRUTSplat{i + 1u, depth, opacity, radius, confidence, view, coverage, age});
    }

    aether::render::DGRUTBudget budget{};
    budget.max_splats = 96u;
    budget.max_bytes = input.size() * sizeof(aether::render::DGRUTSplat);
    std::vector<aether::render::DGRUTSplat> output(budget.max_splats);
    aether::render::DGRUTSelectionResult result{};
    const auto status = aether::render::select_dgrut_splats_with_config(
        input.data(),
        input.size(),
        budget,
        cfg,
        output.data(),
        output.size(),
        &result);
    if (status != aether::core::Status::kOk || result.selected_count == 0u) {
        return -1e9f;
    }

    float conf_sum = 0.0f;
    float opacity_sum = 0.0f;
    for (std::size_t i = 0u; i < result.selected_count; ++i) {
        conf_sum += output[i].tri_tet_confidence;
        opacity_sum += output[i].opacity;
    }
    const float mean_conf = conf_sum / static_cast<float>(result.selected_count);
    const float mean_opacity = opacity_sum / static_cast<float>(result.selected_count);
    return 0.75f * mean_conf + 0.25f * mean_opacity;
}

float eval_f6_score(const F6RejectorConfig& cfg) {
    using aether::evidence::DSMassFunction;
    using aether::innovation::F6ConflictDynamicRejector;
    using aether::innovation::F6FrameMetrics;
    using aether::innovation::gaussian_is_dynamic;

    F6ConflictDynamicRejector rejector{cfg};
    GaussianPrimitive gaussians[3]{};
    for (std::size_t i = 0u; i < 3u; ++i) {
        gaussians[i].id = static_cast<std::uint32_t>(300u + i);
        gaussians[i].host_unit_id = 77u;
        gaussians[i].opacity = 0.6f;
        gaussians[i].observation_count = 4u;
    }

    const int total_frames = 24;
    const int dynamic_frames = 8;
    std::int32_t first_detect = -1;
    std::int32_t first_recover = -1;
    std::uint32_t tp = 0u;
    std::uint32_t tn = 0u;
    std::uint32_t fp = 0u;
    std::uint32_t fn = 0u;

    F6FrameMetrics metrics{};
    for (int frame = 0; frame < total_frames; ++frame) {
        F6ObservationPair pairs[3]{};
        for (std::size_t i = 0u; i < 3u; ++i) {
            pairs[i].gaussian_id = gaussians[i].id;
            pairs[i].host_unit_id = gaussians[i].host_unit_id;
            pairs[i].predicted = DSMassFunction(0.90, 0.05, 0.05).sealed();
            pairs[i].observed = DSMassFunction(0.88, 0.07, 0.05).sealed();
        }

        const bool dynamic_phase = frame < dynamic_frames;
        pairs[0].observed = dynamic_phase
            ? DSMassFunction(0.05, 0.90, 0.05).sealed()
            : DSMassFunction(0.90, 0.05, 0.05).sealed();

        if (rejector.process_frame(pairs, 3u, gaussians, 3u, &metrics) != aether::core::Status::kOk) {
            return -1e9f;
        }

        for (std::size_t i = 0u; i < 3u; ++i) {
            const bool gt_dynamic = (i == 0u) && dynamic_phase;
            const bool pred_dynamic = gaussian_is_dynamic(gaussians[i]);
            if (gt_dynamic && pred_dynamic) {
                tp += 1u;
            } else if (gt_dynamic && !pred_dynamic) {
                fn += 1u;
            } else if (!gt_dynamic && pred_dynamic) {
                fp += 1u;
            } else {
                tn += 1u;
            }
        }

        if (dynamic_phase && first_detect < 0 && gaussian_is_dynamic(gaussians[0])) {
            first_detect = frame;
        }
        if (!dynamic_phase && first_recover < 0 && !gaussian_is_dynamic(gaussians[0])) {
            first_recover = frame;
        }
    }

    const float eps = 1e-4f;
    const float precision = static_cast<float>(tp) / std::max(eps, static_cast<float>(tp + fp));
    const float recall = static_cast<float>(tp) / std::max(eps, static_cast<float>(tp + fn));
    const float f1 = (2.0f * precision * recall) / std::max(eps, precision + recall);
    const float detect_score = first_detect < 0
        ? 0.0f
        : 1.0f - static_cast<float>(first_detect) / static_cast<float>(std::max(1, dynamic_frames - 1));
    const float recover_score = first_recover < 0
        ? 0.0f
        : 1.0f - static_cast<float>(first_recover - dynamic_frames) /
            static_cast<float>(std::max(1, total_frames - dynamic_frames - 1));
    const float fp_rate = static_cast<float>(fp) / std::max(eps, static_cast<float>(fp + tn));

    return 0.60f * clamp01(f1) +
        0.20f * clamp01(detect_score) +
        0.15f * clamp01(recover_score) -
        0.10f * clamp01(fp_rate);
}

float eval_f8_score(const F8FieldConfig& cfg) {
    using aether::innovation::F8FrameStats;
    using aether::innovation::F8UncertaintyField;

    F8UncertaintyField field{cfg};
    std::vector<GaussianPrimitive> gaussians(6u);
    for (std::size_t i = 0u; i < gaussians.size(); ++i) {
        gaussians[i].id = static_cast<std::uint32_t>(400u + i);
        gaussians[i].host_unit_id = 88u;
        gaussians[i].uncertainty = 0.5f;
        gaussians[i].opacity = 0.6f;
    }
    if (field.bootstrap_from_gaussians(gaussians.data(), gaussians.size()) != aether::core::Status::kOk) {
        return -1e9f;
    }

    for (int frame = 0; frame < 32; ++frame) {
        F8Observation obs[6]{};
        for (int i = 0; i < 3; ++i) {
            obs[i].gaussian_id = gaussians[static_cast<std::size_t>(i)].id;
            obs[i].observed = true;
            obs[i].residual = 0.03f + 0.02f * static_cast<float>((frame + i) % 3);
            obs[i].view_cosine = 0.92f + 0.03f * static_cast<float>(i % 2);
            obs[i].ds_belief = 0.88;
        }
        for (int i = 3; i < 5; ++i) {
            obs[i].gaussian_id = gaussians[static_cast<std::size_t>(i)].id;
            obs[i].observed = ((frame + i) % 2) == 0;
            obs[i].residual = 0.28f + 0.08f * static_cast<float>((frame + i) % 3);
            obs[i].view_cosine = 0.55f + 0.12f * static_cast<float>((frame + i) % 2);
            obs[i].ds_belief = 0.60;
        }
        obs[5].gaussian_id = gaussians[5].id;
        obs[5].observed = (frame % 7) == 0;
        obs[5].residual = 0.55f;
        obs[5].view_cosine = 0.35f;
        obs[5].ds_belief = 0.42;

        F8FrameStats stats{};
        if (field.process_frame(obs, 6u, gaussians.data(), gaussians.size(), &stats) != aether::core::Status::kOk) {
            return -1e9f;
        }
    }

    const float good_mean = (gaussians[0].uncertainty + gaussians[1].uncertainty + gaussians[2].uncertainty) / 3.0f;
    const float weak_mean = (gaussians[3].uncertainty + gaussians[4].uncertainty) * 0.5f;
    const float blind = gaussians[5].uncertainty;

    double fused = 0.0;
    if (field.fused_confidence(gaussians[0].id, 1.0f, 0.9, &fused) != aether::core::Status::kOk) {
        return -1e9f;
    }

    const float sep_mid = clamp01(weak_mean - good_mean);
    const float sep_high = clamp01(blind - weak_mean);
    return 0.35f * clamp01(1.0f - good_mean) +
        0.20f * sep_mid +
        0.25f * sep_high +
        0.20f * clamp01(static_cast<float>(fused));
}

std::vector<GaussianPrimitive> make_f9_gaussians(std::size_t count) {
    std::vector<GaussianPrimitive> out(count);
    for (std::size_t i = 0u; i < count; ++i) {
        out[i].id = static_cast<std::uint32_t>(500u + i);
        out[i].host_unit_id = 99u + static_cast<std::uint64_t>(i % 8u);
        out[i].opacity = 0.10f + 0.001f * static_cast<float>(i % 700u);
        out[i].sh_coeffs[0] = -0.5f + 0.002f * static_cast<float>(i % 500u);
    }
    return out;
}

float eval_f9_score(const F9WatermarkConfig& cfg) {
    F9WatermarkPacket packet{};
    if (aether::innovation::f9_generate_watermark_packet(
            "owner-ab",
            "scene-ab",
            24681357u,
            64u,
            &packet) != aether::core::Status::kOk) {
        return -1e9f;
    }

    std::vector<GaussianPrimitive> base = make_f9_gaussians(320u);
    std::vector<GaussianPrimitive> embedded = base;

    std::size_t slots_used = 0u;
    if (aether::innovation::f9_embed_watermark(
            packet,
            0x1234u,
            cfg,
            embedded.data(),
            embedded.size(),
            &slots_used) != aether::core::Status::kOk) {
        return -1e9f;
    }
    if (slots_used == 0u) {
        return -1e9f;
    }

    std::vector<GaussianPrimitive> attacked = embedded;
    std::uint32_t rng = 778899u;
    for (std::size_t i = 0u; i < attacked.size(); ++i) {
        const std::uint32_t r = lcg_next(rng) % 100u;
        if (r < 52u) {
            attacked[i].opacity = base[i].opacity;
            attacked[i].sh_coeffs[0] = base[i].sh_coeffs[0];
            continue;
        }
        const float op_delta = (static_cast<int>(lcg_next(rng) % 7u) - 3) * (cfg.opacity_quant_step * 0.30f);
        const float sh_delta = (static_cast<int>(lcg_next(rng) % 7u) - 3) * (cfg.sh_quant_step * 0.30f);
        attacked[i].opacity = clamp01(attacked[i].opacity + op_delta);
        attacked[i].sh_coeffs[0] = std::max(-4.0f, std::min(4.0f, attacked[i].sh_coeffs[0] + sh_delta));
    }

    F9WatermarkPacket extracted{};
    float confidence = 0.0f;
    if (aether::innovation::f9_extract_watermark(
            0x1234u,
            cfg,
            attacked.data(),
            attacked.size(),
            64u,
            &extracted,
            &confidence) != aether::core::Status::kOk) {
        return -1e9f;
    }

    std::size_t correct = 0u;
    const std::size_t n = std::min(packet.bits.size(), extracted.bits.size());
    for (std::size_t i = 0u; i < n; ++i) {
        if ((packet.bits[i] & 1u) == (extracted.bits[i] & 1u)) {
            correct += 1u;
        }
    }
    const float bit_accuracy = n > 0u ? static_cast<float>(correct) / static_cast<float>(n) : 0.0f;

    const float op_step = std::max(1e-6f, cfg.opacity_quant_step);
    const float sh_step = std::max(1e-6f, cfg.sh_quant_step);
    float distortion = 0.0f;
    for (std::size_t i = 0u; i < embedded.size(); ++i) {
        distortion += std::fabs(embedded[i].opacity - base[i].opacity) / op_step;
        distortion += 0.5f * std::fabs(embedded[i].sh_coeffs[0] - base[i].sh_coeffs[0]) / sh_step;
    }
    const float distortion_norm = clamp01(distortion / static_cast<float>(embedded.size() * 2u));

    return 0.65f * clamp01(bit_accuracy) +
        0.25f * clamp01(confidence) +
        0.10f * (1.0f - distortion_norm);
}

int test_ab_tuning_selects_b() {
    int failed = 0;

    F3PlanConfig f3_a{};
    f3_a.score_weight_opacity = 0.45f;
    f3_a.score_weight_observation = 0.35f;
    f3_a.score_weight_certainty = 0.20f;
    f3_a.adaptive_threshold_blend = 0.50;
    f3_a.adaptive_threshold_min_gap = 0.10;
    f3_a.aggressive_quant_reduction_scale = 4.0f;
    f3_a.quant_ratio_reduction_scale = 6.0f;
    f3_a.aggressive_sh_reduction_scale = 3.0f;

    F3PlanConfig f3_b{};  // Tuned defaults.
    const float f3_score_a = eval_f3_score(f3_a);
    const float f3_score_b = eval_f3_score(f3_b);
    if (!(f3_score_b >= f3_score_a)) {
        std::fprintf(stderr, "F3 A/B tuning regression: A=%f B=%f\n", f3_score_a, f3_score_b);
        failed++;
    }

    aether::scheduler::GPUSchedulerConfig sch_a{};
    sch_a.capture_tracking_weight = 3.0f;
    sch_a.capture_rendering_weight = 2.0f;
    sch_a.capture_optimization_weight = 1.0f;
    sch_a.finished_tracking_weight = 1.0f;
    sch_a.finished_rendering_weight = 2.0f;
    sch_a.finished_optimization_weight = 3.0f;

    aether::scheduler::GPUSchedulerConfig sch_b{};  // Tuned defaults.
    const float sch_score_a = eval_scheduler_score(sch_a);
    const float sch_score_b = eval_scheduler_score(sch_b);
    if (!(sch_score_b >= sch_score_a)) {
        std::fprintf(stderr, "Scheduler A/B tuning regression: A=%f B=%f\n", sch_score_a, sch_score_b);
        failed++;
    }

    aether::render::DGRUTSelectionConfig dgrut_a{};
    dgrut_a.scoring.weight_confidence = 0.35f;
    dgrut_a.scoring.weight_opacity = 0.50f;
    dgrut_a.scoring.weight_radius = 0.15f;
    dgrut_a.scoring.weight_view_angle = 0.0f;
    dgrut_a.scoring.weight_screen_coverage = 0.0f;
    dgrut_a.scoring.newborn_boost = 0.0f;
    dgrut_a.scoring.depth_penalty_scale = 1e-3f;

    aether::render::DGRUTSelectionConfig dgrut_b{};  // Tuned defaults.
    const float dgrut_score_a = eval_dgrut_score(dgrut_a);
    const float dgrut_score_b = eval_dgrut_score(dgrut_b);
    if (!(dgrut_score_b >= dgrut_score_a)) {
        std::fprintf(stderr, "DGRUT A/B tuning regression: A=%f B=%f\n", dgrut_score_a, dgrut_score_b);
        failed++;
    }

    F6RejectorConfig f6_a{};
    f6_a.conflict_threshold = 0.35;
    f6_a.release_ratio = 0.60;
    f6_a.sustain_frames = 5u;
    f6_a.recover_frames = 8u;
    f6_a.ema_alpha = 0.35;
    f6_a.score_gain = 1.0;
    f6_a.score_decay = 0.60;
    F6RejectorConfig f6_b{};  // Tuned defaults.
    const float f6_score_a = eval_f6_score(f6_a);
    const float f6_score_b = eval_f6_score(f6_b);
    if (!(f6_score_b >= f6_score_a)) {
        std::fprintf(stderr, "F6 A/B tuning regression: A=%f B=%f\n", f6_score_a, f6_score_b);
        failed++;
    }

    F8FieldConfig f8_a{};
    f8_a.observed_decay = 0.88f;
    f8_a.unobserved_growth = 0.015f;
    f8_a.view_penalty = 0.20f;
    f8_a.belief_mix_alpha = 0.60f;
    F8FieldConfig f8_b{};  // Tuned defaults.
    const float f8_score_a = eval_f8_score(f8_a);
    const float f8_score_b = eval_f8_score(f8_b);
    if (!(f8_score_b >= f8_score_a)) {
        std::fprintf(stderr, "F8 A/B tuning regression: A=%f B=%f\n", f8_score_a, f8_score_b);
        failed++;
    }

    F9WatermarkConfig f9_a{};
    f9_a.bit_count = 128u;
    f9_a.replicas_per_bit = 4u;
    f9_a.opacity_quant_step = 1.0f / 1024.0f;
    f9_a.sh_quant_step = 1.0f / 512.0f;
    F9WatermarkConfig f9_b{};  // Tuned defaults.
    const float f9_score_a = eval_f9_score(f9_a);
    const float f9_score_b = eval_f9_score(f9_b);
    if (!(f9_score_b >= f9_score_a)) {
        std::fprintf(stderr, "F9 A/B tuning regression: A=%f B=%f\n", f9_score_a, f9_score_b);
        failed++;
    }

    const float total_a =
        0.26f * f3_score_a +
        0.16f * sch_score_a +
        0.14f * dgrut_score_a +
        0.17f * f6_score_a +
        0.14f * f8_score_a +
        0.13f * f9_score_a;
    const float total_b =
        0.26f * f3_score_b +
        0.16f * sch_score_b +
        0.14f * dgrut_score_b +
        0.17f * f6_score_b +
        0.14f * f8_score_b +
        0.13f * f9_score_b;
    if (!(total_b >= total_a)) {
        std::fprintf(stderr, "Global A/B tuning regression: A=%f B=%f\n", total_a, total_b);
        failed++;
    }
    return failed;
}

}  // namespace

int main() {
    return test_ab_tuning_selects_b();
}
