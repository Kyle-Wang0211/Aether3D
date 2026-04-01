// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Unified C API tests: TSDF + innovation + scheduler.

#include "aether_tsdf_c.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

bool approx(float a, float b, float eps) {
    return std::fabs(a - b) <= eps;
}

void make_identity_pose(float out_pose[16]) {
    if (out_pose == nullptr) {
        return;
    }
    for (int i = 0; i < 16; ++i) {
        out_pose[i] = 0.0f;
    }
    out_pose[0] = 1.0f;
    out_pose[5] = 1.0f;
    out_pose[10] = 1.0f;
    out_pose[15] = 1.0f;
}

void set_pose_translation(float pose[16], float tx, float ty, float tz) {
    if (pose == nullptr) {
        return;
    }
    pose[12] = tx;
    pose[13] = ty;
    pose[14] = tz;
}

std::string hex_of_bytes(const uint8_t* bytes, std::size_t count) {
    static constexpr char kHex[] = "0123456789abcdef";
    std::string out;
    out.resize(count * 2u);
    for (std::size_t i = 0; i < count; ++i) {
        const uint8_t b = bytes[i];
        out[i * 2u] = kHex[(b >> 4u) & 0x0Fu];
        out[i * 2u + 1u] = kHex[b & 0x0Fu];
    }
    return out;
}

int test_tsdf_api() {
    int failed = 0;

    if (std::abs(aether_tsdf_voxel_size_near() - 0.005f) > 1e-6f) {
        std::fprintf(stderr, "aether_tsdf_voxel_size_near mismatch\n");
        failed++;
    }
    if (aether_tsdf_block_size() != 8) {
        std::fprintf(stderr, "aether_tsdf_block_size mismatch\n");
        failed++;
    }

    {
        aether_integration_result_t result{};
        int rc = aether_tsdf_integrate(nullptr, &result);
        if (rc == 0) {
            std::fprintf(stderr, "expected null input to fail\n");
            failed++;
        }
    }

    {
        aether_integration_input_t input{};
        input.depth_width = 8;
        input.depth_height = 8;
        int rc = aether_tsdf_integrate(&input, nullptr);
        if (rc == 0) {
            std::fprintf(stderr, "expected null result to fail\n");
            failed++;
        }
    }

    {
        std::vector<float> depth(1, 0.5f);
        float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        aether_integration_input_t input{};
        input.depth_data = depth.data();
        input.depth_width = 0;
        input.depth_height = 0;
        input.fx = 500.f;
        input.fy = 500.f;
        input.cx = 0.f;
        input.cy = 0.f;
        input.voxel_size = 0.01f;
        input.view_matrix = identity;
        aether_integration_result_t result{};
        int rc = aether_tsdf_integrate(&input, &result);
        if (rc == 0) {
            std::fprintf(stderr, "expected zero dimensions to fail\n");
            failed++;
        }
    }

    {
        std::vector<float> depth(64, 0.5f);
        float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        aether_integration_input_t input{};
        input.depth_data = depth.data();
        input.depth_width = 8;
        input.depth_height = 8;
        input.fx = 500.f;
        input.fy = 500.f;
        input.cx = 4.f;
        input.cy = 4.f;
        input.voxel_size = 0.01f;
        input.view_matrix = identity;

        aether_integration_result_t result{};
        int rc = aether_tsdf_integrate(&input, &result);
        if (rc != 0 || result.success != 1) {
            std::fprintf(stderr, "aether_tsdf_integrate failed: rc=%d success=%d\n", rc, result.success);
            failed++;
        }
        if (result.voxels_integrated <= 0 || result.blocks_updated <= 0) {
            std::fprintf(stderr, "expected non-zero output: voxels=%d blocks=%d\n",
                result.voxels_integrated, result.blocks_updated);
            failed++;
        }
    }

    {
        aether_tsdf_volume_t* volume = nullptr;
        if (aether_tsdf_volume_create(&volume) != 0 || volume == nullptr) {
            std::fprintf(stderr, "tsdf volume create failed\n");
            failed++;
        } else {
            aether_tsdf_runtime_state_t state{};
            if (aether_tsdf_volume_get_runtime_state(volume, &state) != 0) {
                std::fprintf(stderr, "tsdf get runtime state failed\n");
                failed++;
            } else if (state.current_integration_skip < 1 || state.system_thermal_ceiling < 1) {
                std::fprintf(stderr, "tsdf runtime state baseline invalid\n");
                failed++;
            }

            state.current_integration_skip = 3;
            state.system_thermal_ceiling = 4;
            state.consecutive_rejections = 9;
            state.current_max_blocks_per_extraction = 133;
            state.consecutive_good_meshing_cycles = 2;
            state.forgiveness_window_remaining = 4;
            state.consecutive_teleport_count = 1;
            state.last_angular_velocity = 12.5f;
            state.recent_pose_count = 6;
            state.last_idle_check_time_s = 42.0;
            state.memory_water_level = 2;
            state.memory_pressure_ratio = 0.80f;
            state.last_memory_pressure_change_time_s = 9.0;
            state.free_block_slot_count = 3;
            state.last_evicted_blocks = 5;
            if (aether_tsdf_volume_set_runtime_state(volume, &state) != 0) {
                std::fprintf(stderr, "tsdf set runtime state failed\n");
                failed++;
            } else {
                aether_tsdf_runtime_state_t verify{};
                if (aether_tsdf_volume_get_runtime_state(volume, &verify) != 0) {
                    std::fprintf(stderr, "tsdf verify runtime state failed\n");
                    failed++;
                } else if (verify.current_integration_skip != 3 ||
                           verify.system_thermal_ceiling != 4 ||
                           verify.consecutive_rejections != 9 ||
                           verify.current_max_blocks_per_extraction != 133 ||
                           verify.consecutive_good_meshing_cycles != 2 ||
                           verify.forgiveness_window_remaining != 4 ||
                           verify.consecutive_teleport_count != 1 ||
                           !approx(verify.last_angular_velocity, 12.5f, 1e-6f) ||
                           verify.recent_pose_count != 6 ||
                           std::fabs(verify.last_idle_check_time_s - 42.0) > 1e-9 ||
                           verify.memory_water_level != 2 ||
                           !approx(verify.memory_pressure_ratio, 0.80f, 1e-6f) ||
                           std::fabs(verify.last_memory_pressure_change_time_s - 9.0) > 1e-9 ||
                           verify.last_evicted_blocks != 5) {
                    std::fprintf(stderr, "tsdf runtime state roundtrip mismatch\n");
                    failed++;
                }
            }

            if (aether_tsdf_volume_apply_frame_feedback(volume, 16.0) != 0) {
                std::fprintf(stderr, "tsdf apply frame feedback failed\n");
                failed++;
            } else {
                aether_tsdf_runtime_state_t after_feedback{};
                if (aether_tsdf_volume_get_runtime_state(volume, &after_feedback) != 0) {
                    std::fprintf(stderr, "tsdf runtime state read after feedback failed\n");
                    failed++;
                } else if (after_feedback.current_integration_skip < 3 ||
                           after_feedback.current_integration_skip > 4) {
                    std::fprintf(stderr, "tsdf feedback skip out of expected range\n");
                    failed++;
                }
            }

            if (aether_tsdf_volume_handle_memory_pressure_ratio(volume, 0.93f) != 0) {
                std::fprintf(stderr, "tsdf handle memory pressure ratio failed\n");
                failed++;
            } else {
                aether_tsdf_runtime_state_t after_ratio{};
                if (aether_tsdf_volume_get_runtime_state(volume, &after_ratio) != 0) {
                    std::fprintf(stderr, "tsdf runtime state read after ratio failed\n");
                    failed++;
                } else if (after_ratio.memory_water_level < 3 ||
                           after_ratio.memory_pressure_ratio < 0.9f) {
                    std::fprintf(stderr, "tsdf memory ratio control did not update state\n");
                    failed++;
                }
            }

            if (aether_tsdf_volume_handle_memory_pressure_ratio(volume, NAN) == 0) {
                std::fprintf(stderr, "tsdf memory pressure ratio NaN expected failure\n");
                failed++;
            }

            if (aether_tsdf_volume_apply_frame_feedback(volume, -1.0) == 0) {
                std::fprintf(stderr, "tsdf apply frame feedback negative time expected failure\n");
                failed++;
            }

            if (aether_tsdf_volume_destroy(volume) != 0) {
                std::fprintf(stderr, "tsdf volume destroy failed\n");
                failed++;
            }
        }
    }

    return failed;
}

int test_p6_mesh_stability_c_api() {
    int failed = 0;

    aether_tsdf_volume_t* volume = nullptr;
    if (aether_tsdf_volume_create(&volume) != 0 || volume == nullptr) {
        std::fprintf(stderr, "mesh stability volume create failed\n");
        return 1;
    }

    std::vector<float> depth(1u, 0.5f);
    std::vector<unsigned char> confidence(1u, 2u);
    float identity[16] = {1, 0, 0, 0,
                          0, 1, 0, 0,
                          0, 0, 1, 0,
                          0, 0, 0, 1};

    aether_integration_input_t input{};
    input.depth_data = depth.data();
    input.depth_width = 1;
    input.depth_height = 1;
    input.confidence_data = confidence.data();
    input.voxel_size = 0.01f;
    input.fx = 500.0f;
    input.fy = 500.0f;
    input.cx = 0.0f;
    input.cy = 0.0f;
    input.view_matrix = identity;
    input.timestamp = 10.0;
    input.tracking_state = 2;

    aether_integration_result_t integrate_result{};
    int rc = aether_tsdf_volume_integrate(volume, &input, &integrate_result);
    if (rc != 0 || integrate_result.success != 1 || integrate_result.blocks_updated <= 0) {
        std::fprintf(stderr, "mesh stability precondition integrate failed rc=%d success=%d blocks=%d\n",
            rc, integrate_result.success, integrate_result.blocks_updated);
        failed++;
    }

    aether_mesh_stability_query_t query{};
    // depth=0.5m at identity pose → world z = -0.5 → block_z = floor(-0.5/0.08) = -7
    query.block_x = 0;
    query.block_y = 0;
    query.block_z = -7;
    query.last_mesh_generation = 0u;

    aether_mesh_stability_result_t result{};
    rc = aether_query_mesh_stability(&query, 1, 2u, 5u, 5.0, &result);
    if (rc != 0) {
        std::fprintf(stderr, "mesh stability query failed rc=%d\n", rc);
        failed++;
    } else {
        if (result.current_integration_generation == 0u) {
            std::fprintf(stderr, "mesh stability expected non-zero integration generation\n");
            failed++;
        }
        if (result.needs_re_extraction != 1) {
            std::fprintf(stderr, "mesh stability expected needs_re_extraction=1\n");
            failed++;
        }
        if (!approx(result.fade_in_alpha, 0.0f, 1e-6f)) {
            std::fprintf(stderr, "mesh stability expected fade_in_alpha=0, got %.6f\n", result.fade_in_alpha);
            failed++;
        }
        if (result.eviction_weight < 0.99f || result.eviction_weight > 1.0f) {
            std::fprintf(stderr, "mesh stability expected fresh eviction weight, got %.6f\n", result.eviction_weight);
            failed++;
        }
    }

    query.last_mesh_generation = result.current_integration_generation;
    aether_mesh_stability_result_t settled{};
    rc = aether_query_mesh_stability(&query, 1, 8u, 5u, 5.0, &settled);
    if (rc != 0) {
        std::fprintf(stderr, "mesh stability settled query failed rc=%d\n", rc);
        failed++;
    } else {
        if (settled.needs_re_extraction != 0) {
            std::fprintf(stderr, "mesh stability expected needs_re_extraction=0 after mesh catch-up\n");
            failed++;
        }
        if (settled.current_integration_generation != query.last_mesh_generation) {
            std::fprintf(stderr, "mesh stability generation mismatch current=%u expected=%u\n",
                settled.current_integration_generation, query.last_mesh_generation);
            failed++;
        }
        if (settled.fade_in_alpha < 0.99f || settled.fade_in_alpha > 1.0f) {
            std::fprintf(stderr, "mesh stability expected full fade_in_alpha, got %.6f\n", settled.fade_in_alpha);
            failed++;
        }
        if (settled.eviction_weight < 0.99f || settled.eviction_weight > 1.0f) {
            std::fprintf(stderr, "mesh stability expected fresh eviction weight after catch-up, got %.6f\n",
                settled.eviction_weight);
            failed++;
        }
    }

    aether_tsdf_runtime_state_t runtime{};
    rc = aether_tsdf_volume_get_runtime_state(volume, &runtime);
    if (rc != 0) {
        std::fprintf(stderr, "mesh stability runtime read failed rc=%d\n", rc);
        failed++;
    } else {
        runtime.last_timestamp = 20.0;
        rc = aether_tsdf_volume_set_runtime_state(volume, &runtime);
        if (rc != 0) {
            std::fprintf(stderr, "mesh stability runtime write failed rc=%d\n", rc);
            failed++;
        } else {
            aether_mesh_stability_result_t stale{};
            rc = aether_query_mesh_stability(&query, 1, 8u, 5u, 5.0, &stale);
            if (rc != 0) {
                std::fprintf(stderr, "mesh stability stale query failed rc=%d\n", rc);
                failed++;
            } else if (stale.eviction_weight > 1e-6f) {
                std::fprintf(stderr, "mesh stability expected stale eviction_weight=0, got %.6f\n",
                    stale.eviction_weight);
                failed++;
            }
        }
    }

    if (aether_query_mesh_stability(&query, 1, 8u, 5u, -0.1, &result) == 0) {
        std::fprintf(stderr, "mesh stability negative staleness threshold expected failure\n");
        failed++;
    }

    if (aether_tsdf_volume_destroy(volume) != 0) {
        std::fprintf(stderr, "mesh stability volume destroy failed\n");
        failed++;
    }

    return failed;
}

int test_p6_confidence_decay_c_api() {
    int failed = 0;

    aether_gaussian_t gaussians[2]{};
    gaussians[0].id = 900001u;
    gaussians[0].opacity = 0.8f;
    gaussians[0].uncertainty = 0.41f;
    gaussians[1].id = 900002u;
    gaussians[1].opacity = 0.25f;
    gaussians[1].uncertainty = 0.73f;

    aether_confidence_decay_config_t cfg{};
    cfg.decay_per_frame = 0.2f;
    cfg.min_confidence = 0.0f;
    cfg.observation_boost = 0.1f;
    cfg.max_confidence = 1.0f;
    cfg.grace_frames = 1u;

    int frustum[2] = {0, 1};
    int rc = aether_decay_confidence(gaussians, 2, frustum, 100u, &cfg);
    if (rc != 0) {
        std::fprintf(stderr, "confidence decay call #1 failed rc=%d\n", rc);
        failed++;
    } else {
        if (!approx(gaussians[0].opacity, 0.8f, 1e-6f)) {
            std::fprintf(stderr, "confidence decay #1 g0 opacity mismatch %.6f\n", gaussians[0].opacity);
            failed++;
        }
        if (!approx(gaussians[1].opacity, 0.35f, 1e-6f)) {
            std::fprintf(stderr, "confidence decay #1 g1 opacity mismatch %.6f\n", gaussians[1].opacity);
            failed++;
        }
    }

    frustum[0] = 0;
    frustum[1] = 0;
    rc = aether_decay_confidence(gaussians, 2, frustum, 102u, &cfg);
    if (rc != 0) {
        std::fprintf(stderr, "confidence decay call #2 failed rc=%d\n", rc);
        failed++;
    } else {
        if (!approx(gaussians[0].opacity, 0.6f, 1e-6f)) {
            std::fprintf(stderr, "confidence decay #2 g0 opacity mismatch %.6f\n", gaussians[0].opacity);
            failed++;
        }
        if (!approx(gaussians[1].opacity, 0.15f, 1e-6f)) {
            std::fprintf(stderr, "confidence decay #2 g1 opacity mismatch %.6f\n", gaussians[1].opacity);
            failed++;
        }
    }

    frustum[0] = 1;
    frustum[1] = 0;
    rc = aether_decay_confidence(gaussians, 2, frustum, 103u, &cfg);
    if (rc != 0) {
        std::fprintf(stderr, "confidence decay call #3 failed rc=%d\n", rc);
        failed++;
    } else {
        if (!approx(gaussians[0].opacity, 0.7f, 1e-6f)) {
            std::fprintf(stderr, "confidence decay #3 g0 opacity mismatch %.6f\n", gaussians[0].opacity);
            failed++;
        }
        if (!approx(gaussians[1].opacity, 0.0f, 1e-6f)) {
            std::fprintf(stderr, "confidence decay #3 g1 opacity mismatch %.6f\n", gaussians[1].opacity);
            failed++;
        }
    }

    if (!approx(gaussians[0].uncertainty, 0.41f, 1e-6f) ||
        !approx(gaussians[1].uncertainty, 0.73f, 1e-6f)) {
        std::fprintf(stderr, "confidence decay should not overwrite uncertainty\n");
        failed++;
    }

    if (aether_decay_confidence(nullptr, 1, frustum, 104u, &cfg) == 0) {
        std::fprintf(stderr, "confidence decay null gaussians expected failure\n");
        failed++;
    }
    if (aether_decay_confidence(gaussians, -1, frustum, 104u, &cfg) == 0) {
        std::fprintf(stderr, "confidence decay negative count expected failure\n");
        failed++;
    }

    return failed;
}

int test_scan_interaction_kernels_c_api() {
    int failed = 0;

    // Patch identity matching: low-display transient observations should snap to
    // nearby high-display anchors.
    aether_patch_identity_sample_t anchors[2]{};
    anchors[0].patch_key = 111u;
    anchors[0].centroid = aether_float3_t{0.0f, 0.0f, 0.0f};
    anchors[0].display = 0.9f;
    anchors[1].patch_key = 222u;
    anchors[1].centroid = aether_float3_t{0.6f, 0.0f, 0.0f};
    anchors[1].display = 0.95f;

    aether_patch_identity_sample_t observations[3]{};
    observations[0].patch_key = 1001u;
    observations[0].centroid = aether_float3_t{0.01f, 0.0f, 0.0f};
    observations[0].display = 0.01f;
    observations[1].patch_key = 1002u;
    observations[1].centroid = aether_float3_t{0.58f, 0.0f, 0.0f};
    observations[1].display = 0.02f;
    observations[2].patch_key = 1003u;
    observations[2].centroid = aether_float3_t{0.20f, 0.0f, 0.0f};
    observations[2].display = 0.4f;  // above lock threshold: keep self

    uint64_t resolved[3]{0, 0, 0};
    int rc = aether_match_patch_identities(
        observations,
        3,
        anchors,
        2,
        0.05f,
        0.05f,
        0.02f,
        resolved);
    if (rc != 0) {
        std::fprintf(stderr, "patch identity matching failed rc=%d\n", rc);
        failed++;
    } else {
        if (resolved[0] != 111u || resolved[1] != 222u || resolved[2] != 1003u) {
            std::fprintf(stderr, "patch identity result mismatch [%llu,%llu,%llu]\n",
                static_cast<unsigned long long>(resolved[0]),
                static_cast<unsigned long long>(resolved[1]),
                static_cast<unsigned long long>(resolved[2]));
            failed++;
        }
    }

    if (aether_match_patch_identities(observations, 1, anchors, 2, 0.05f, 0.05f, 0.02f, nullptr) == 0) {
        std::fprintf(stderr, "patch identity null output expected failure\n");
        failed++;
    }

    // Stable render triangle selection.
    aether_render_triangle_candidate_t candidates[4]{};
    candidates[0].patch_key = 10u;
    candidates[0].centroid = aether_float3_t{5.0f, 0.0f, 0.0f};
    candidates[0].display = 0.9f;  // completion boost
    candidates[0].stability_fade_alpha = 0.2f;
    candidates[0].residency_until_frame = 0;

    candidates[1].patch_key = 11u;
    candidates[1].centroid = aether_float3_t{0.2f, 0.0f, 0.0f};
    candidates[1].display = 0.4f;
    candidates[1].stability_fade_alpha = 0.0f;
    candidates[1].residency_until_frame = 0;

    candidates[2].patch_key = 12u;
    candidates[2].centroid = aether_float3_t{0.1f, 0.0f, 0.0f};
    candidates[2].display = 0.1f;
    candidates[2].stability_fade_alpha = 0.0f;
    candidates[2].residency_until_frame = 0;

    candidates[3].patch_key = 13u;
    candidates[3].centroid = aether_float3_t{0.4f, 0.0f, 0.0f};
    candidates[3].display = 0.2f;
    candidates[3].stability_fade_alpha = 0.0f;
    candidates[3].residency_until_frame = 100;

    aether_render_selection_config_t cfg{};
    cfg.current_frame = 50;
    cfg.max_triangles = 2;
    cfg.camera_position = aether_float3_t{0.0f, 0.0f, 0.0f};
    cfg.completion_threshold = 0.75f;
    cfg.distance_bias = 0.05f;
    cfg.display_weight = 2.0f;
    cfg.residency_boost = 0.75f;
    cfg.completion_boost = 1000.0f;
    cfg.stability_weight = 0.3f;

    int32_t selected[4]{-1, -1, -1, -1};
    int selected_count = 0;
    rc = aether_select_stable_render_triangles(
        candidates,
        4,
        &cfg,
        selected,
        &selected_count);
    if (rc != 0) {
        std::fprintf(stderr, "stable render selection failed rc=%d\n", rc);
        failed++;
    } else if (selected_count != 2 ||
               selected[0] != 0 ||
               selected[1] != 3) {
        std::fprintf(stderr, "stable render selection mismatch count=%d [%d,%d]\n",
            selected_count, selected[0], selected[1]);
        failed++;
    }

    // Full selection path should sort by patch key deterministically.
    aether_render_triangle_candidate_t sorted_candidates[3]{};
    sorted_candidates[0].patch_key = 30u;
    sorted_candidates[1].patch_key = 10u;
    sorted_candidates[2].patch_key = 20u;
    cfg.max_triangles = 8;
    int32_t sorted_indices[3]{-1, -1, -1};
    selected_count = 0;
    rc = aether_select_stable_render_triangles(
        sorted_candidates,
        3,
        &cfg,
        sorted_indices,
        &selected_count);
    if (rc != 0) {
        std::fprintf(stderr, "stable render full selection failed rc=%d\n", rc);
        failed++;
    } else if (selected_count != 3 ||
               sorted_indices[0] != 1 ||
               sorted_indices[1] != 2 ||
               sorted_indices[2] != 0) {
        std::fprintf(stderr, "stable render deterministic order mismatch [%d,%d,%d]\n",
            sorted_indices[0], sorted_indices[1], sorted_indices[2]);
        failed++;
    }

    // Render snapshot should remain monotonic with respect to base display.
    aether_render_snapshot_input_t snapshot_inputs[3]{};
    snapshot_inputs[0].base_display = 0.90f;
    snapshot_inputs[0].confidence_display = 0.95f;
    snapshot_inputs[0].has_stability = 1;
    snapshot_inputs[0].fade_in_alpha = 0.1f;
    snapshot_inputs[0].eviction_weight = 0.1f;

    snapshot_inputs[1].base_display = 0.60f;
    snapshot_inputs[1].confidence_display = 0.90f;
    snapshot_inputs[1].has_stability = 1;
    snapshot_inputs[1].fade_in_alpha = 0.5f;
    snapshot_inputs[1].eviction_weight = 0.5f;

    snapshot_inputs[2].base_display = 0.20f;
    snapshot_inputs[2].confidence_display = 0.60f;
    snapshot_inputs[2].has_stability = 0;
    snapshot_inputs[2].fade_in_alpha = 0.0f;
    snapshot_inputs[2].eviction_weight = 0.0f;

    float rendered[3]{0.0f, 0.0f, 0.0f};
    aether_render_snapshot_config_t snapshot_cfg{};
    snapshot_cfg.s3_to_s4_threshold = 0.75f;
    snapshot_cfg.s4_to_s5_threshold = 0.88f;
    rc = aether_compute_render_snapshot(snapshot_inputs, 3, &snapshot_cfg, rendered);
    if (rc != 0) {
        std::fprintf(stderr, "render snapshot failed rc=%d\n", rc);
        failed++;
    } else {
        if (!approx(rendered[0], 0.95f, 1e-6f) ||
            !approx(rendered[1], 0.60f, 1e-6f) ||
            !approx(rendered[2], 0.60f, 1e-6f)) {
            std::fprintf(stderr, "render snapshot mismatch [%.6f,%.6f,%.6f]\n",
                rendered[0], rendered[1], rendered[2]);
            failed++;
        }
    }

    if (aether_compute_render_snapshot(snapshot_inputs, 1, &snapshot_cfg, nullptr) == 0) {
        std::fprintf(stderr, "render snapshot null output expected failure\n");
        failed++;
    }

    return failed;
}

int test_da3_depth_c_api() {
    int failed = 0;

    aether_da3_depth_sample_t unknown{};
    unknown.depth_from_vision = 1.0f;
    unknown.depth_from_tsdf = 2.0f;
    unknown.sigma2_vision = 1.0f;
    unknown.sigma2_tsdf = 1.0f;
    unknown.tri_tet_class = static_cast<std::uint8_t>(AETHER_TRI_TET_CLASS_UNKNOWN);

    aether_da3_depth_sample_t measured = unknown;
    measured.tri_tet_class = static_cast<std::uint8_t>(AETHER_TRI_TET_CLASS_MEASURED);

    float fused_unknown = 0.0f;
    float confidence_unknown = 0.0f;
    int rc = aether_da3_fuse_depth(&unknown, &fused_unknown, &confidence_unknown);
    if (rc != 0) {
        std::fprintf(stderr, "da3 fuse unknown failed rc=%d\n", rc);
        failed++;
    }

    float fused_measured = 0.0f;
    float confidence_measured = 0.0f;
    rc = aether_da3_fuse_depth(&measured, &fused_measured, &confidence_measured);
    if (rc != 0) {
        std::fprintf(stderr, "da3 fuse measured failed rc=%d\n", rc);
        failed++;
    }

    if (!(fused_measured > fused_unknown)) {
        std::fprintf(stderr, "da3 fused depth ordering mismatch measured=%.6f unknown=%.6f\n",
            fused_measured, fused_unknown);
        failed++;
    }
    if (!(confidence_measured > confidence_unknown)) {
        std::fprintf(stderr, "da3 confidence ordering mismatch measured=%.6f unknown=%.6f\n",
            confidence_measured, confidence_unknown);
        failed++;
    }
    if (aether_da3_fuse_depth(nullptr, &fused_unknown, &confidence_unknown) == 0) {
        std::fprintf(stderr, "da3 null sample expected failure\n");
        failed++;
    }

    float relative_depth[4] = {1.0f, 2.0f, 3.0f, 4.0f};
    float metric_depth[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float camera_pose[16];
    make_identity_pose(camera_pose);
    set_pose_translation(camera_pose, 0.2f, 0.0f, 0.0f);
    float history_poses[32];
    make_identity_pose(history_poses + 0);
    set_pose_translation(history_poses + 0, 0.0f, 0.0f, 0.0f);
    make_identity_pose(history_poses + 16);
    set_pose_translation(history_poses + 16, 0.1f, 0.0f, 0.0f);
    float scale = 0.0f;
    rc = aether_monocular_depth_to_metric(
        relative_depth,
        2,
        2,
        camera_pose,
        history_poses,
        2,
        metric_depth,
        &scale);
    if (rc != 0) {
        std::fprintf(stderr, "monocular depth to metric failed rc=%d\n", rc);
        failed++;
    } else {
        if (!(scale >= 0.05f && scale <= 20.0f)) {
            std::fprintf(stderr, "monocular scale out of range %.6f\n", scale);
            failed++;
        }
        if (!(metric_depth[0] > 0.0f &&
              metric_depth[1] > metric_depth[0] &&
              metric_depth[2] > metric_depth[1] &&
              metric_depth[3] > metric_depth[2])) {
            std::fprintf(stderr, "monocular metric depth monotonicity mismatch\n");
            failed++;
        }
    }

    if (aether_monocular_depth_to_metric(
            relative_depth,
            0,
            2,
            camera_pose,
            history_poses,
            2,
            metric_depth,
            &scale) == 0) {
        std::fprintf(stderr, "monocular depth invalid dimensions expected failure\n");
        failed++;
    }

    return failed;
}

int test_pure_vision_runtime_c_api() {
    int failed = 0;

    aether_outlier_cross_validation_input_t outlier_in{};
    outlier_in.rule_inlier = 1;
    outlier_in.ml_inlier_score = 0.9;
    outlier_in.ml_inlier_threshold = 0.8;
    aether_cross_validation_outcome_t outlier_out{};
    int rc = aether_cross_validation_evaluate_outlier(&outlier_in, &outlier_out);
    if (rc != 0 ||
        outlier_out.decision != AETHER_CROSS_VALIDATION_KEEP ||
        outlier_out.reason_code != AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_INLIER) {
        std::fprintf(stderr, "pure vision outlier keep mismatch rc=%d decision=%d reason=%d\n",
            rc, outlier_out.decision, outlier_out.reason_code);
        failed++;
    }

    outlier_in.rule_inlier = 0;
    outlier_in.ml_inlier_score = 0.1;
    outlier_in.ml_inlier_threshold = 0.8;
    rc = aether_cross_validation_evaluate_outlier(&outlier_in, &outlier_out);
    if (rc != 0 || outlier_out.decision != AETHER_CROSS_VALIDATION_REJECT) {
        std::fprintf(stderr, "pure vision outlier reject mismatch rc=%d decision=%d\n",
            rc, outlier_out.decision);
        failed++;
    }

    aether_calibration_cross_validation_input_t calib_in{};
    calib_in.baseline_error_cm = 0.8;
    calib_in.ml_error_cm = 0.9;
    calib_in.max_allowed_error_cm = 1.0;
    calib_in.max_divergence_cm = 0.5;
    aether_cross_validation_outcome_t calib_out{};
    rc = aether_cross_validation_evaluate_calibration(&calib_in, &calib_out);
    if (rc != 0 ||
        calib_out.decision != AETHER_CROSS_VALIDATION_KEEP ||
        calib_out.reason_code != AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_PASS) {
        std::fprintf(stderr, "pure vision calibration keep mismatch rc=%d decision=%d reason=%d\n",
            rc, calib_out.decision, calib_out.reason_code);
        failed++;
    }

    aether_pure_vision_runtime_metrics_t metrics{};
    metrics.baseline_pixels = 5.0;
    metrics.blur_laplacian = 210.0;
    metrics.orb_features = 650;
    metrics.parallax_ratio = 0.25;
    metrics.depth_sigma_meters = 0.01;
    metrics.closure_ratio = 0.98;
    metrics.unknown_voxel_ratio = 0.01;
    metrics.thermal_celsius = 35.0;
    aether_pure_vision_gate_result_t gate_results[AETHER_PURE_VISION_GATE_COUNT]{};
    int gate_count = AETHER_PURE_VISION_GATE_COUNT;
    rc = aether_pure_vision_evaluate_gates(&metrics, nullptr, gate_results, &gate_count);
    if (rc != 0 || gate_count != AETHER_PURE_VISION_GATE_COUNT) {
        std::fprintf(stderr, "pure vision gate eval baseline failed rc=%d count=%d\n", rc, gate_count);
        failed++;
    } else {
        for (int i = 0; i < gate_count; ++i) {
            if (gate_results[i].passed == 0) {
                std::fprintf(stderr, "pure vision gate %d unexpectedly failed\n", i);
                failed++;
            }
        }
    }

    metrics.blur_laplacian = 120.0;
    metrics.thermal_celsius = 50.0;
    int failed_gate_ids[8]{};
    int failed_gate_count = 8;
    rc = aether_pure_vision_failed_gate_ids(&metrics, nullptr, failed_gate_ids, &failed_gate_count);
    if (rc != 0) {
        std::fprintf(stderr, "pure vision failed gate ids failed rc=%d\n", rc);
        failed++;
    } else {
        bool has_blur = false;
        bool has_thermal = false;
        for (int i = 0; i < failed_gate_count; ++i) {
            has_blur = has_blur || (failed_gate_ids[i] == AETHER_PURE_VISION_GATE_BLUR_LAPLACIAN);
            has_thermal = has_thermal || (failed_gate_ids[i] == AETHER_PURE_VISION_GATE_THERMAL_CELSIUS);
        }
        if (!has_blur || !has_thermal) {
            std::fprintf(stderr, "pure vision failed gate set missing blur/thermal\n");
            failed++;
        }
    }

    int tiny_count = 1;
    rc = aether_pure_vision_evaluate_gates(&metrics, nullptr, gate_results, &tiny_count);
    if (rc == 0 || tiny_count != AETHER_PURE_VISION_GATE_COUNT) {
        std::fprintf(stderr, "pure vision gate capacity check mismatch rc=%d count=%d\n", rc, tiny_count);
        failed++;
    }

    if (aether_cross_validation_evaluate_outlier(nullptr, &outlier_out) == 0) {
        std::fprintf(stderr, "pure vision outlier null input expected failure\n");
        failed++;
    }

    return failed;
}

int test_zero_fabrication_c_api() {
    int failed = 0;

    aether_zero_fabrication_context_t context{};
    context.confidence_class = AETHER_ZERO_FAB_CONFIDENCE_MEASURED;
    context.has_direct_observation = 1;
    context.requested_point_displacement_meters = 0.0f;
    context.requested_new_geometry_count = 0;

    aether_zero_fabrication_decision_t decision{};
    int rc = aether_zero_fabrication_evaluate(
        AETHER_ZERO_FAB_MODE_FORENSIC_STRICT,
        0.0f,
        AETHER_ZERO_FAB_ACTION_TEXTURE_INPAINT,
        &context,
        &decision);
    if (rc != 0 || decision.allowed != 0 ||
        decision.reason_code != AETHER_ZERO_FAB_REASON_BLOCK_GENERATIVE_ACTION) {
        std::fprintf(stderr, "zero fabrication generative block mismatch rc=%d allowed=%d reason=%d\n",
            rc, decision.allowed, decision.reason_code);
        failed++;
    }

    context.requested_point_displacement_meters = 0.001f;
    rc = aether_zero_fabrication_evaluate(
        AETHER_ZERO_FAB_MODE_FORENSIC_STRICT,
        0.02f,
        AETHER_ZERO_FAB_ACTION_MULTI_VIEW_DENOISE,
        &context,
        &decision);
    if (rc != 0 || decision.allowed != 0 ||
        decision.reason_code != AETHER_ZERO_FAB_REASON_BLOCK_COORDINATE_REWRITE) {
        std::fprintf(stderr, "zero fabrication strict denoise mismatch rc=%d allowed=%d reason=%d\n",
            rc, decision.allowed, decision.reason_code);
        failed++;
    }

    rc = aether_zero_fabrication_evaluate(
        AETHER_ZERO_FAB_MODE_RESEARCH_RELAXED,
        0.02f,
        AETHER_ZERO_FAB_ACTION_MULTI_VIEW_DENOISE,
        &context,
        &decision);
    if (rc != 0 || decision.allowed == 0 ||
        decision.reason_code != AETHER_ZERO_FAB_REASON_ALLOW_DENOISE) {
        std::fprintf(stderr, "zero fabrication relaxed denoise mismatch rc=%d allowed=%d reason=%d\n",
            rc, decision.allowed, decision.reason_code);
        failed++;
    }

    context.confidence_class = AETHER_ZERO_FAB_CONFIDENCE_UNKNOWN;
    context.has_direct_observation = 0;
    rc = aether_zero_fabrication_evaluate(
        AETHER_ZERO_FAB_MODE_FORENSIC_STRICT,
        0.0f,
        AETHER_ZERO_FAB_ACTION_UNKNOWN_REGION_GROWTH,
        &context,
        &decision);
    if (rc != 0 || decision.allowed != 0 ||
        decision.reason_code != AETHER_ZERO_FAB_REASON_BLOCK_UNKNOWN_GROWTH) {
        std::fprintf(stderr, "zero fabrication unknown growth mismatch rc=%d allowed=%d reason=%d\n",
            rc, decision.allowed, decision.reason_code);
        failed++;
    }

    if (aether_zero_fabrication_evaluate(
            AETHER_ZERO_FAB_MODE_FORENSIC_STRICT,
            0.0f,
            AETHER_ZERO_FAB_ACTION_OUTLIER_REJECTION,
            nullptr,
            &decision) == 0) {
        std::fprintf(stderr, "zero fabrication null context expected failure\n");
        failed++;
    }

    return failed;
}

int test_geometry_ml_c_api() {
    int failed = 0;

    aether_pure_vision_runtime_metrics_t runtime{};
    runtime.baseline_pixels = 12.0;
    runtime.blur_laplacian = 320.0;
    runtime.orb_features = 680;
    runtime.parallax_ratio = 0.34;
    runtime.depth_sigma_meters = 0.008;
    runtime.closure_ratio = 0.99;
    runtime.unknown_voxel_ratio = 0.01;
    runtime.thermal_celsius = 34.0;

    aether_geometry_ml_tri_tet_report_t tri_tet{};
    tri_tet.has_report = 1;
    tri_tet.combined_score = 0.91f;
    tri_tet.measured_count = 8;
    tri_tet.estimated_count = 1;
    tri_tet.unknown_count = 1;

    aether_geometry_ml_cross_validation_stats_t cv{};
    cv.keep_count = 3;
    cv.downgrade_count = 0;
    cv.reject_count = 0;

    aether_geometry_ml_capture_signals_t capture{};
    capture.motion_score = 0.18;
    capture.overexposure_ratio = 0.03;
    capture.underexposure_ratio = 0.02;
    capture.has_large_blown_region = 0;

    aether_geometry_ml_evidence_signals_t evidence{};
    evidence.coverage_score = 0.92;
    evidence.soft_evidence_score = 0.86;
    evidence.persistent_piz_region_count = 1;
    evidence.invariant_violation_count = 0;
    evidence.replay_stable_rate = 1.0;
    evidence.tri_tet_binding_coverage = 1.0;
    evidence.merkle_proof_coverage = 1.0;
    evidence.occlusion_excluded_area_ratio = 0.0;
    evidence.provenance_gap_count = 0;

    aether_geometry_ml_transport_signals_t transport{};
    transport.bandwidth_mbps = 120.0;
    transport.rtt_ms = 85.0;
    transport.loss_rate = 0.01;
    transport.chunk_size_bytes = 2 * 1024 * 1024;
    transport.dedup_savings_ratio = 0.29;
    transport.compression_savings_ratio = 0.21;
    transport.byzantine_coverage = 1.0;
    transport.merkle_proof_success_rate = 1.0;
    transport.proof_of_possession_success_rate = 1.0;
    transport.chunk_hmac_mismatch_rate = 0.0;
    transport.circuit_breaker_open_ratio = 0.0;
    transport.retry_exhaustion_rate = 0.0;
    transport.resume_corruption_rate = 0.0;

    aether_geometry_ml_security_signals_t security{};
    security.code_signature_valid = 1;
    security.runtime_integrity_valid = 1;
    security.telemetry_hmac_valid = 1;
    security.debugger_detected = 0;
    security.environment_tampered = 0;
    security.certificate_pin_mismatch_count = 0;
    security.boot_chain_validated = 1;
    security.request_signer_valid_rate = 1.0;
    security.secure_enclave_available = 1;

    aether_geometry_ml_thresholds_t thresholds{};
    thresholds.min_fusion_score = 0.72;
    thresholds.max_risk_score = 0.26;
    thresholds.min_tri_tet_measured_ratio = 0.45;
    thresholds.min_cross_validation_keep_ratio = 0.70;
    thresholds.max_motion_score = 0.60;
    thresholds.max_exposure_penalty = 0.35;
    thresholds.min_coverage_score = 0.75;
    thresholds.max_persistent_piz_regions = 3;
    thresholds.max_evidence_invariant_violations = 1;
    thresholds.min_evidence_replay_stable_rate = 0.99;
    thresholds.min_tri_tet_binding_coverage = 0.90;
    thresholds.min_evidence_merkle_proof_coverage = 0.95;
    thresholds.max_evidence_occlusion_excluded_ratio = 0.30;
    thresholds.max_evidence_provenance_gap_count = 1;
    thresholds.max_upload_loss_rate = 0.05;
    thresholds.max_upload_rtt_ms = 400.0;
    thresholds.min_upload_byzantine_coverage = 0.95;
    thresholds.min_upload_merkle_proof_success_rate = 0.97;
    thresholds.min_upload_pop_success_rate = 0.98;
    thresholds.max_upload_hmac_mismatch_rate = 0.01;
    thresholds.max_upload_circuit_breaker_open_ratio = 0.08;
    thresholds.max_upload_retry_exhaustion_rate = 0.03;
    thresholds.max_upload_resume_corruption_rate = 0.015;
    thresholds.max_certificate_pin_mismatch_count = 1;
    thresholds.min_request_signer_valid_rate = 0.98;
    thresholds.max_security_penalty = 0.20;

    aether_geometry_ml_weights_t weights{};
    weights.geometry = 0.28;
    weights.cross_validation = 0.22;
    weights.capture = 0.20;
    weights.evidence = 0.15;
    weights.transport = 0.10;
    weights.security = 0.05;

    aether_upload_cdc_thresholds_t upload_thresholds{};
    upload_thresholds.min_chunk_size = 256 * 1024;
    upload_thresholds.avg_chunk_size = 2 * 1024 * 1024;
    upload_thresholds.max_chunk_size = 5242880;
    upload_thresholds.dedup_min_savings_ratio = 0.20;
    upload_thresholds.compression_min_savings_ratio = 0.10;

    aether_geometry_ml_result_t result{};
    int rc = aether_geometry_ml_evaluate(
        &runtime,
        &tri_tet,
        &cv,
        &capture,
        &evidence,
        &transport,
        &security,
        &thresholds,
        &weights,
        &upload_thresholds,
        &result);
    if (rc != 0 || result.passes == 0 || result.reason_mask != 0u) {
        std::fprintf(stderr, "geometry ml healthy profile mismatch rc=%d passes=%d mask=%llu\n",
            rc, result.passes, static_cast<unsigned long long>(result.reason_mask));
        failed++;
    }

    cv.keep_count = 0;
    cv.downgrade_count = 1;
    cv.reject_count = 1;
    capture.motion_score = 0.75;
    security.code_signature_valid = 0;
    security.runtime_integrity_valid = 0;
    security.telemetry_hmac_valid = 0;
    security.debugger_detected = 1;
    security.environment_tampered = 1;

    rc = aether_geometry_ml_evaluate(
        &runtime,
        &tri_tet,
        &cv,
        &capture,
        &evidence,
        &transport,
        &security,
        &thresholds,
        &weights,
        &upload_thresholds,
        &result);
    if (rc != 0 || result.passes != 0) {
        std::fprintf(stderr, "geometry ml degraded profile mismatch rc=%d passes=%d\n",
            rc, result.passes);
        failed++;
    } else {
        const std::uint64_t reject_present_bit =
            (1ull << AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_REJECT_PRESENT);
        const std::uint64_t security_penalty_bit =
            (1ull << AETHER_GEOMETRY_ML_REASON_SECURITY_PENALTY_EXCEEDED);
        if ((result.reason_mask & reject_present_bit) == 0u ||
            (result.reason_mask & security_penalty_bit) == 0u) {
            std::fprintf(stderr, "geometry ml missing expected reason bits mask=%llu\n",
                static_cast<unsigned long long>(result.reason_mask));
            failed++;
        }
    }

    if (aether_geometry_ml_evaluate(
            nullptr,
            &tri_tet,
            &cv,
            &capture,
            &evidence,
            &transport,
            &security,
            &thresholds,
            &weights,
            &upload_thresholds,
            &result) == 0) {
        std::fprintf(stderr, "geometry ml null runtime expected failure\n");
        failed++;
    }

    return failed;
}

int test_patch_display_kernel_c_api() {
    int failed = 0;

    aether_patch_display_kernel_config_t cfg{};
    cfg.patch_display_alpha = 0.2;
    cfg.patch_display_locked_acceleration = 1.5;
    cfg.color_evidence_local_weight = 0.7;
    cfg.color_evidence_global_weight = 0.3;

    aether_patch_display_step_result_t r0{};
    int rc = aether_patch_display_step(0.5, 0.5, 10, 0.3, 0, &cfg, &r0);
    if (rc != 0) {
        std::fprintf(stderr, "patch display step #1 failed rc=%d\n", rc);
        failed++;
    } else {
        if (r0.display + 1e-12 < 0.5) {
            std::fprintf(stderr, "patch display monotonicity violation display=%.6f\n", r0.display);
            failed++;
        }
    }

    aether_patch_display_step_result_t unlocked{};
    aether_patch_display_step_result_t locked{};
    rc = aether_patch_display_step(0.2, 0.2, 1, 0.8, 0, &cfg, &unlocked);
    rc |= aether_patch_display_step(0.2, 0.2, 1, 0.8, 1, &cfg, &locked);
    if (rc != 0) {
        std::fprintf(stderr, "patch display step lock compare failed rc=%d\n", rc);
        failed++;
    } else if (locked.display + 1e-12 < unlocked.display) {
        std::fprintf(stderr, "patch locked acceleration mismatch locked=%.6f unlocked=%.6f\n",
            locked.display, unlocked.display);
        failed++;
    }

    double color = -1.0;
    rc = aether_patch_color_evidence(0.6, 0.4, &cfg, &color);
    if (rc != 0 || std::fabs(color - 0.54) > 1e-9) {
        std::fprintf(stderr, "patch color evidence mismatch rc=%d color=%.6f\n", rc, color);
        failed++;
    }

    if (aether_patch_display_step(0.0, 0.0, 0, 0.5, 0, &cfg, nullptr) == 0) {
        std::fprintf(stderr, "patch display null output expected failure\n");
        failed++;
    }

    return failed;
}

int test_visual_style_state_c_api() {
    int failed = 0;

    aether_visual_style_state_input_t style_in{};
    style_in.has_previous = 0;
    style_in.is_frozen = 0;
    style_in.current_display = 0.40f;
    style_in.current_metallic = 0.25f;
    style_in.current_roughness = 0.70f;
    style_in.current_thickness = 0.0060f;
    style_in.smoothing_alpha = 0.2f;
    style_in.freeze_threshold = 0.75f;
    style_in.min_thickness = 0.0005f;
    style_in.max_thickness = 0.0080f;

    aether_visual_style_state_output_t style_out{};
    int rc = aether_resolve_visual_style_state(&style_in, &style_out);
    if (rc != 0) {
        std::fprintf(stderr, "visual style resolve #1 failed rc=%d\n", rc);
        failed++;
    } else if (!(style_out.metallic >= 0.0f && style_out.metallic <= 1.0f &&
                 style_out.roughness >= 0.0f && style_out.roughness <= 1.0f &&
                 style_out.thickness >= style_in.min_thickness &&
                 style_out.thickness <= style_in.max_thickness &&
                 style_out.should_freeze == 0)) {
        std::fprintf(stderr, "visual style resolve #1 range mismatch m=%.6f r=%.6f t=%.6f freeze=%d\n",
            style_out.metallic, style_out.roughness, style_out.thickness, style_out.should_freeze);
        failed++;
    }

    aether_visual_style_state_input_t style_in2{};
    style_in2.has_previous = 1;
    style_in2.is_frozen = 0;
    style_in2.previous_display = style_in.current_display;
    style_in2.previous_metallic = style_out.metallic;
    style_in2.previous_roughness = style_out.roughness;
    style_in2.previous_thickness = style_out.thickness;
    style_in2.current_display = 0.85f;
    style_in2.current_metallic = 0.05f;   // tries to regress
    style_in2.current_roughness = 0.95f;  // tries to regress
    style_in2.current_thickness = 0.0075f; // tries to regress
    style_in2.smoothing_alpha = 0.2f;
    style_in2.freeze_threshold = 0.75f;
    style_in2.min_thickness = 0.0005f;
    style_in2.max_thickness = 0.0080f;

    aether_visual_style_state_output_t style_out2{};
    rc = aether_resolve_visual_style_state(&style_in2, &style_out2);
    if (rc != 0) {
        std::fprintf(stderr, "visual style resolve #2 failed rc=%d\n", rc);
        failed++;
    } else {
        if (style_out2.metallic + 1e-6f < style_out.metallic) {
            std::fprintf(stderr, "visual style metallic rollback %.6f -> %.6f\n",
                style_out.metallic, style_out2.metallic);
            failed++;
        }
        if (style_out2.roughness - 1e-6f > style_out.roughness) {
            std::fprintf(stderr, "visual style roughness rollback %.6f -> %.6f\n",
                style_out.roughness, style_out2.roughness);
            failed++;
        }
        if (style_out2.thickness - 1e-6f > style_out.thickness) {
            std::fprintf(stderr, "visual style thickness rollback %.6f -> %.6f\n",
                style_out.thickness, style_out2.thickness);
            failed++;
        }
        if (style_out2.should_freeze == 0) {
            std::fprintf(stderr, "visual style expected freeze at high display\n");
            failed++;
        }
    }

    aether_border_style_state_input_t border_in{};
    border_in.has_previous = 1;
    border_in.is_frozen = 0;
    border_in.previous_display = 0.50f;
    border_in.previous_width = 4.0f;
    border_in.current_display = 0.80f;
    border_in.current_width = 6.0f;
    border_in.freeze_threshold = 0.75f;
    border_in.min_width = 1.0f;
    border_in.max_width = 12.0f;

    aether_border_style_state_output_t border_out{};
    rc = aether_resolve_border_style_state(&border_in, &border_out);
    if (rc != 0) {
        std::fprintf(stderr, "border style resolve failed rc=%d\n", rc);
        failed++;
    } else {
        if (border_out.width - 1e-6f > border_in.previous_width) {
            std::fprintf(stderr, "border width rollback %.6f -> %.6f\n",
                border_in.previous_width, border_out.width);
            failed++;
        }
        if (border_out.should_freeze == 0) {
            std::fprintf(stderr, "border style expected freeze at high display\n");
            failed++;
        }
    }

    // Even if display drops later, style must not roll back.
    aether_visual_style_state_input_t style_in3{};
    style_in3.has_previous = 1;
    style_in3.is_frozen = 0;
    style_in3.previous_display = style_in2.current_display;
    style_in3.previous_metallic = style_out2.metallic;
    style_in3.previous_roughness = style_out2.roughness;
    style_in3.previous_thickness = style_out2.thickness;
    style_in3.current_display = 0.20f;      // regressed display input
    style_in3.current_metallic = 0.01f;     // tries to regress
    style_in3.current_roughness = 0.99f;    // tries to regress
    style_in3.current_thickness = 0.0080f;  // tries to regress
    style_in3.smoothing_alpha = 0.2f;
    style_in3.freeze_threshold = 0.75f;
    style_in3.min_thickness = 0.0005f;
    style_in3.max_thickness = 0.0080f;

    aether_visual_style_state_output_t style_out3{};
    rc = aether_resolve_visual_style_state(&style_in3, &style_out3);
    if (rc != 0) {
        std::fprintf(stderr, "visual style resolve #3 failed rc=%d\n", rc);
        failed++;
    } else {
        if (style_out3.metallic + 1e-6f < style_out2.metallic) {
            std::fprintf(stderr, "visual style rollback on display drop (metallic)\n");
            failed++;
        }
        if (style_out3.roughness - 1e-6f > style_out2.roughness) {
            std::fprintf(stderr, "visual style rollback on display drop (roughness)\n");
            failed++;
        }
        if (style_out3.thickness - 1e-6f > style_out2.thickness) {
            std::fprintf(stderr, "visual style rollback on display drop (thickness)\n");
            failed++;
        }
    }

    aether_border_style_state_input_t border_in2{};
    border_in2.has_previous = 1;
    border_in2.is_frozen = 0;
    border_in2.previous_display = border_in.current_display;
    border_in2.previous_width = border_out.width;
    border_in2.current_display = 0.10f;  // regressed display input
    border_in2.current_width = 8.0f;     // tries to regress
    border_in2.freeze_threshold = 0.75f;
    border_in2.min_width = 1.0f;
    border_in2.max_width = 12.0f;

    aether_border_style_state_output_t border_out2{};
    rc = aether_resolve_border_style_state(&border_in2, &border_out2);
    if (rc != 0) {
        std::fprintf(stderr, "border style resolve #2 failed rc=%d\n", rc);
        failed++;
    } else if (border_out2.width - 1e-6f > border_out.width) {
        std::fprintf(stderr, "border width rollback on display drop %.6f -> %.6f\n",
            border_out.width, border_out2.width);
        failed++;
    }

    if (aether_resolve_visual_style_state(nullptr, &style_out) == 0 ||
        aether_resolve_border_style_state(nullptr, &border_out) == 0) {
        std::fprintf(stderr, "visual/border style null input expected failure\n");
        failed++;
    }

    return failed;
}

int test_style_state_batch_c_api() {
    int failed = 0;

    aether_visual_style_state_input_t visual_inputs[2]{};
    visual_inputs[0].has_previous = 1;
    visual_inputs[0].is_frozen = 0;
    visual_inputs[0].previous_display = 0.4f;
    visual_inputs[0].previous_metallic = 0.3f;
    visual_inputs[0].previous_roughness = 0.6f;
    visual_inputs[0].previous_thickness = 0.006f;
    visual_inputs[0].current_display = 0.9f;
    visual_inputs[0].current_metallic = 0.8f;
    visual_inputs[0].current_roughness = 0.2f;
    visual_inputs[0].current_thickness = 0.003f;
    visual_inputs[0].smoothing_alpha = 0.2f;
    visual_inputs[0].freeze_threshold = 0.75f;
    visual_inputs[0].min_thickness = 0.0005f;
    visual_inputs[0].max_thickness = 0.008f;

    visual_inputs[1] = visual_inputs[0];
    visual_inputs[1].current_display = 0.2f;
    visual_inputs[1].current_metallic = 0.1f;
    visual_inputs[1].current_roughness = 0.9f;
    visual_inputs[1].current_thickness = 0.007f;

    aether_visual_style_state_output_t visual_batch_out[2]{};
    int rc = aether_resolve_visual_style_state_batch(visual_inputs, 2, visual_batch_out);
    if (rc != 0) {
        std::fprintf(stderr, "visual style batch failed rc=%d\n", rc);
        failed++;
    } else {
        for (int i = 0; i < 2; ++i) {
            aether_visual_style_state_output_t single_out{};
            rc = aether_resolve_visual_style_state(&visual_inputs[i], &single_out);
            if (rc != 0 ||
                !approx(single_out.metallic, visual_batch_out[i].metallic, 1e-6f) ||
                !approx(single_out.roughness, visual_batch_out[i].roughness, 1e-6f) ||
                !approx(single_out.thickness, visual_batch_out[i].thickness, 1e-6f) ||
                single_out.should_freeze != visual_batch_out[i].should_freeze) {
                std::fprintf(stderr, "visual style batch mismatch idx=%d\n", i);
                failed++;
            }
        }
    }

    aether_border_style_state_input_t border_inputs[2]{};
    border_inputs[0].has_previous = 1;
    border_inputs[0].is_frozen = 0;
    border_inputs[0].previous_display = 0.6f;
    border_inputs[0].previous_width = 4.0f;
    border_inputs[0].current_display = 0.9f;
    border_inputs[0].current_width = 6.0f;
    border_inputs[0].freeze_threshold = 0.75f;
    border_inputs[0].min_width = 1.0f;
    border_inputs[0].max_width = 12.0f;
    border_inputs[1] = border_inputs[0];
    border_inputs[1].current_display = 0.2f;
    border_inputs[1].current_width = 2.0f;

    aether_border_style_state_output_t border_batch_out[2]{};
    rc = aether_resolve_border_style_state_batch(border_inputs, 2, border_batch_out);
    if (rc != 0) {
        std::fprintf(stderr, "border style batch failed rc=%d\n", rc);
        failed++;
    } else {
        for (int i = 0; i < 2; ++i) {
            aether_border_style_state_output_t single_out{};
            rc = aether_resolve_border_style_state(&border_inputs[i], &single_out);
            if (rc != 0 ||
                !approx(single_out.width, border_batch_out[i].width, 1e-6f) ||
                single_out.should_freeze != border_batch_out[i].should_freeze) {
                std::fprintf(stderr, "border style batch mismatch idx=%d\n", i);
                failed++;
            }
        }
    }

    if (aether_resolve_visual_style_state_batch(nullptr, 1, visual_batch_out) == 0 ||
        aether_resolve_border_style_state_batch(nullptr, 1, border_batch_out) == 0) {
        std::fprintf(stderr, "style batch null input expected failure\n");
        failed++;
    }

    return failed;
}

int test_capture_style_runtime_c_api() {
    int failed = 0;

    aether_capture_style_runtime_config_t config{};
    int rc = aether_capture_style_runtime_default_config(&config);
    if (rc != 0) {
        std::fprintf(stderr, "capture style default config failed rc=%d\n", rc);
        return failed + 1;
    }

    aether_capture_style_runtime_t* runtime = nullptr;
    rc = aether_capture_style_runtime_create(&config, &runtime);
    if (rc != 0 || runtime == nullptr) {
        std::fprintf(stderr, "capture style runtime create failed rc=%d\n", rc);
        return failed + 1;
    }

    aether_capture_style_input_t high{};
    high.patch_key = 0x1234ULL;
    high.display = 0.90f;
    high.area_sq_m = 0.5f;
    aether_capture_style_output_t out_high{};
    rc = aether_capture_style_runtime_resolve(runtime, &high, 1, &out_high);
    if (rc != 0) {
        std::fprintf(stderr, "capture style runtime resolve #1 failed rc=%d\n", rc);
        failed++;
    }

    aether_capture_style_input_t dropped{};
    dropped.patch_key = 0x1234ULL;
    dropped.display = 0.20f;
    dropped.area_sq_m = 0.5f;
    aether_capture_style_output_t out_dropped{};
    rc = aether_capture_style_runtime_resolve(runtime, &dropped, 1, &out_dropped);
    if (rc != 0) {
        std::fprintf(stderr, "capture style runtime resolve #2 failed rc=%d\n", rc);
        failed++;
    } else {
        if (out_dropped.resolved_display + 1e-6f < out_high.resolved_display) {
            std::fprintf(stderr, "capture style display rollback %.6f -> %.6f\n",
                out_high.resolved_display, out_dropped.resolved_display);
            failed++;
        }
        if (out_dropped.metallic + 1e-6f < out_high.metallic) {
            std::fprintf(stderr, "capture style metallic rollback %.6f -> %.6f\n",
                out_high.metallic, out_dropped.metallic);
            failed++;
        }
        if (out_dropped.roughness - 1e-6f > out_high.roughness) {
            std::fprintf(stderr, "capture style roughness rollback %.6f -> %.6f\n",
                out_high.roughness, out_dropped.roughness);
            failed++;
        }
        if (out_dropped.thickness - 1e-6f > out_high.thickness) {
            std::fprintf(stderr, "capture style thickness rollback %.6f -> %.6f\n",
                out_high.thickness, out_dropped.thickness);
            failed++;
        }
        if (out_dropped.border_width - 1e-6f > out_high.border_width) {
            std::fprintf(stderr, "capture style border rollback %.6f -> %.6f\n",
                out_high.border_width, out_dropped.border_width);
            failed++;
        }
        if (out_dropped.grayscale + 1e-6f < out_high.grayscale) {
            std::fprintf(stderr, "capture style grayscale rollback %.6f -> %.6f\n",
                out_high.grayscale, out_dropped.grayscale);
            failed++;
        }
    }

    rc = aether_capture_style_runtime_reset(runtime);
    if (rc != 0) {
        std::fprintf(stderr, "capture style runtime reset failed rc=%d\n", rc);
        failed++;
    } else {
        aether_capture_style_output_t out_after_reset{};
        aether_capture_style_input_t low_after_reset{};
        low_after_reset.patch_key = 0x1234ULL;
        low_after_reset.display = 0.10f;
        low_after_reset.area_sq_m = 0.5f;
        rc = aether_capture_style_runtime_resolve(runtime, &low_after_reset, 1, &out_after_reset);
        if (rc != 0) {
            std::fprintf(stderr, "capture style runtime resolve after reset failed rc=%d\n", rc);
            failed++;
        } else if (!approx(out_after_reset.resolved_display, 0.10f, 1e-4f)) {
            std::fprintf(stderr, "capture style reset expected fresh display, got %.6f\n",
                out_after_reset.resolved_display);
            failed++;
        }
    }

    if (aether_capture_style_runtime_default_config(nullptr) == 0 ||
        aether_capture_style_runtime_create(nullptr, nullptr) == 0 ||
        aether_capture_style_runtime_resolve(nullptr, &high, 1, &out_high) == 0 ||
        aether_capture_style_runtime_resolve(runtime, nullptr, 1, &out_high) == 0 ||
        aether_capture_style_runtime_resolve(runtime, &high, 1, nullptr) == 0) {
        std::fprintf(stderr, "capture style runtime null input expected failure\n");
        failed++;
    }

    rc = aether_capture_style_runtime_destroy(runtime);
    if (rc != 0) {
        std::fprintf(stderr, "capture style runtime destroy failed rc=%d\n", rc);
        failed++;
    }

    return failed;
}

int test_geometry_utils_c_api() {
    int failed = 0;

    {
        const std::string patch = "patch-42";
        uint32_t hash32 = 0;
        uint64_t hash64 = 0;
        int rc32 = aether_hash_fnv1a32(
            reinterpret_cast<const uint8_t*>(patch.data()),
            static_cast<int>(patch.size()),
            &hash32);
        int rc64 = aether_hash_fnv1a64(
            reinterpret_cast<const uint8_t*>(patch.data()),
            static_cast<int>(patch.size()),
            &hash64);
        if (rc32 != 0 || rc64 != 0) {
            std::fprintf(stderr, "hash fnv1a call failed rc32=%d rc64=%d\n", rc32, rc64);
            failed++;
        } else {
            uint32_t expected32 = 2166136261u;
            uint64_t expected64 = 1469598103934665603ull;
            for (const unsigned char byte : patch) {
                expected32 ^= static_cast<uint32_t>(byte);
                expected32 *= 16777619u;
                expected64 ^= static_cast<uint64_t>(byte);
                expected64 *= 1099511628211ull;
            }
            if (hash32 != expected32 || hash64 != expected64) {
                std::fprintf(stderr, "hash fnv1a mismatch h32=%u e32=%u h64=%llu e64=%llu\n",
                    hash32,
                    expected32,
                    static_cast<unsigned long long>(hash64),
                    static_cast<unsigned long long>(expected64));
                failed++;
            }
        }
        if (aether_hash_fnv1a32(nullptr, 1, &hash32) == 0 ||
            aether_hash_fnv1a64(nullptr, 1, &hash64) == 0 ||
            aether_hash_fnv1a64(reinterpret_cast<const uint8_t*>(patch.data()), -1, &hash64) == 0) {
            std::fprintf(stderr, "hash fnv1a null/invalid input expected failure\n");
            failed++;
        }
    }

    {
        aether_scan_triangle_t tri{};
        tri.a = aether_float3_t{0.0f, 0.0f, 0.0f};
        tri.b = aether_float3_t{2.0f, 0.0f, 0.0f};
        tri.c = aether_float3_t{0.0f, 1.0f, 0.0f};

        aether_float3_t start{};
        aether_float3_t end{};
        float length_sq = 0.0f;
        const int rc = aether_scan_triangle_longest_edge(&tri, &start, &end, &length_sq);
        if (rc != 0) {
            std::fprintf(stderr, "scan triangle longest edge failed rc=%d\n", rc);
            failed++;
        } else {
            const float edge_len = std::sqrt(length_sq);
            if (!approx(edge_len, std::sqrt(5.0f), 1e-5f)) {
                std::fprintf(stderr, "scan triangle longest edge length mismatch %.6f\n", edge_len);
                failed++;
            }
            const bool oriented01 =
                approx(start.x, tri.b.x, 1e-6f) && approx(start.y, tri.b.y, 1e-6f) &&
                approx(end.x, tri.c.x, 1e-6f) && approx(end.y, tri.c.y, 1e-6f);
            const bool oriented10 =
                approx(start.x, tri.c.x, 1e-6f) && approx(start.y, tri.c.y, 1e-6f) &&
                approx(end.x, tri.b.x, 1e-6f) && approx(end.y, tri.b.y, 1e-6f);
            if (!oriented01 && !oriented10) {
                std::fprintf(stderr, "scan triangle longest edge endpoints mismatch\n");
                failed++;
            }
        }
        if (aether_scan_triangle_longest_edge(nullptr, &start, &end, &length_sq) == 0 ||
            aether_scan_triangle_longest_edge(&tri, nullptr, &end, &length_sq) == 0 ||
            aether_scan_triangle_longest_edge(&tri, &start, nullptr, &length_sq) == 0) {
            std::fprintf(stderr, "scan triangle longest edge null input expected failure\n");
            failed++;
        }
    }

    {
        int normal_count = 0;
        int rc = aether_compute_bevel_normals(
            aether_float3_t{0.0f, 0.0f, 1.0f},
            aether_float3_t{0.0f, 1.0f, 0.0f},
            2,
            nullptr,
            &normal_count);
        if (rc != -3 || normal_count != 3) {
            std::fprintf(stderr, "bevel normals count query failed rc=%d count=%d\n", rc, normal_count);
            failed++;
        } else {
            std::vector<aether_float3_t> normals(static_cast<std::size_t>(normal_count));
            rc = aether_compute_bevel_normals(
                aether_float3_t{0.0f, 0.0f, 1.0f},
                aether_float3_t{0.0f, 1.0f, 0.0f},
                2,
                normals.data(),
                &normal_count);
            if (rc != 0 || normal_count != 3) {
                std::fprintf(stderr, "bevel normals build failed rc=%d count=%d\n", rc, normal_count);
                failed++;
            } else {
                if (!approx(normals[0].x, 0.0f, 1e-5f) ||
                    !approx(normals[0].y, 0.0f, 1e-5f) ||
                    !approx(normals[0].z, 1.0f, 1e-5f) ||
                    !approx(normals[2].x, 0.0f, 1e-5f) ||
                    !approx(normals[2].y, 1.0f, 1e-5f) ||
                    !approx(normals[2].z, 0.0f, 1e-5f)) {
                    std::fprintf(stderr, "bevel normals endpoints mismatch\n");
                    failed++;
                }
                for (int i = 0; i < normal_count; ++i) {
                    const float len = std::sqrt(
                        normals[static_cast<std::size_t>(i)].x * normals[static_cast<std::size_t>(i)].x +
                        normals[static_cast<std::size_t>(i)].y * normals[static_cast<std::size_t>(i)].y +
                        normals[static_cast<std::size_t>(i)].z * normals[static_cast<std::size_t>(i)].z);
                    if (!std::isfinite(len) || std::fabs(len - 1.0f) > 1e-3f) {
                        std::fprintf(stderr, "bevel normal not unit at index=%d len=%.6f\n", i, len);
                        failed++;
                        break;
                    }
                }
            }
        }
        if (aether_compute_bevel_normals(
                aether_float3_t{0.0f, 0.0f, 1.0f},
                aether_float3_t{0.0f, 1.0f, 0.0f},
                -1,
                nullptr,
                &normal_count) == 0 ||
            aether_compute_bevel_normals(
                aether_float3_t{0.0f, 0.0f, 1.0f},
                aether_float3_t{0.0f, 1.0f, 0.0f},
                1,
                nullptr,
                nullptr) == 0) {
            std::fprintf(stderr, "bevel normals invalid input expected failure\n");
            failed++;
        }
    }

    return failed;
}

int test_wedge_geometry_c_api() {
    int failed = 0;

    aether_wedge_input_triangle_t triangle{};
    triangle.v0 = aether_float3_t{0.0f, 0.0f, 0.0f};
    triangle.v1 = aether_float3_t{1.0f, 0.0f, 0.0f};
    triangle.v2 = aether_float3_t{0.0f, 1.0f, 0.0f};
    triangle.normal = aether_float3_t{0.0f, 0.0f, 1.0f};
    triangle.metallic = 0.4f;
    triangle.roughness = 0.5f;
    triangle.display = 0.6f;
    triangle.thickness = 0.005f;
    triangle.triangle_id = 7u;

    int vertex_count = 0;
    int index_count = 0;
    int rc = aether_generate_wedge_geometry(
        &triangle,
        1,
        2,
        nullptr,
        &vertex_count,
        nullptr,
        &index_count);
    if (rc != -3 || vertex_count != 4 || index_count != 9) {
        std::fprintf(stderr, "wedge low-lod count query failed rc=%d v=%d i=%d\n",
            rc, vertex_count, index_count);
        failed++;
    }

    std::vector<aether_wedge_vertex_t> vertices(static_cast<std::size_t>(vertex_count));
    std::vector<uint32_t> indices(static_cast<std::size_t>(index_count));
    rc = aether_generate_wedge_geometry(
        &triangle,
        1,
        2,
        vertices.data(),
        &vertex_count,
        indices.data(),
        &index_count);
    if (rc != 0 || vertex_count != 4 || index_count != 9) {
        std::fprintf(stderr, "wedge low-lod build failed rc=%d v=%d i=%d\n",
            rc, vertex_count, index_count);
        failed++;
    } else {
        for (int i = 0; i < vertex_count; ++i) {
            const aether_wedge_vertex_t& v = vertices[static_cast<std::size_t>(i)];
            if (!std::isfinite(v.position.x) || !std::isfinite(v.position.y) || !std::isfinite(v.position.z) ||
                !std::isfinite(v.normal.x) || !std::isfinite(v.normal.y) || !std::isfinite(v.normal.z)) {
                std::fprintf(stderr, "wedge produced non-finite vertex at %d\n", i);
                failed++;
                break;
            }
        }
        for (int i = 0; i < index_count; ++i) {
            if (indices[static_cast<std::size_t>(i)] >= static_cast<uint32_t>(vertex_count)) {
                std::fprintf(stderr, "wedge produced out-of-range index at %d\n", i);
                failed++;
                break;
            }
        }
    }

    int full_vertices = 0;
    int full_indices = 0;
    rc = aether_generate_wedge_geometry(
        &triangle,
        1,
        0,
        nullptr,
        &full_vertices,
        nullptr,
        &full_indices);
    if (rc != -3 || full_vertices != 7 || full_indices != 21) {
        std::fprintf(stderr, "wedge full-lod count query failed rc=%d v=%d i=%d\n",
            rc, full_vertices, full_indices);
        failed++;
    }

    if (aether_generate_wedge_geometry(&triangle, 1, 99, nullptr, &vertex_count, nullptr, &index_count) == 0) {
        std::fprintf(stderr, "wedge invalid lod expected failure\n");
        failed++;
    }
    if (aether_generate_wedge_geometry(nullptr, 1, 2, nullptr, &vertex_count, nullptr, &index_count) == 0) {
        std::fprintf(stderr, "wedge null triangle input expected failure\n");
        failed++;
    }

    return failed;
}

int test_smart_smoother_c_api() {
    int failed = 0;

    aether_smart_smoother_config_t cfg{};
    cfg.window_size = 5;
    cfg.jitter_band = 0.05;
    cfg.anti_boost_factor = 0.3;
    cfg.normal_improve_factor = 0.7;
    cfg.degrade_factor = 1.0;
    cfg.max_consecutive_invalid = 3;
    cfg.worst_case_fallback = 0.0;

    aether_smart_smoother_t* smoother = nullptr;
    int rc = aether_smart_smoother_create(&cfg, &smoother);
    if (rc != 0 || smoother == nullptr) {
        std::fprintf(stderr, "smart smoother create failed rc=%d\n", rc);
        return 1;
    }

    double s0 = 0.0;
    double s1 = 0.0;
    double s2 = 0.0;
    rc = aether_smart_smoother_add(smoother, 0.5, &s0);
    rc |= aether_smart_smoother_add(smoother, 0.52, &s1);
    rc |= aether_smart_smoother_add(smoother, 0.7, &s2);
    if (rc != 0) {
        std::fprintf(stderr, "smart smoother add failed rc=%d\n", rc);
        failed++;
    } else {
        if (!(s2 > s1 && s2 < 0.7)) {
            std::fprintf(stderr, "smart smoother anti-boost mismatch s1=%.6f s2=%.6f\n", s1, s2);
            failed++;
        }
    }

    double invalid0 = 0.0;
    double invalid1 = 0.0;
    double invalid2 = 0.0;
    rc = aether_smart_smoother_add(smoother, NAN, &invalid0);
    rc |= aether_smart_smoother_add(smoother, NAN, &invalid1);
    rc |= aether_smart_smoother_add(smoother, NAN, &invalid2);
    if (rc != 0) {
        std::fprintf(stderr, "smart smoother invalid path failed rc=%d\n", rc);
        failed++;
    } else if (std::fabs(invalid2 - cfg.worst_case_fallback) > 1e-12) {
        std::fprintf(stderr, "smart smoother fallback mismatch %.6f\n", invalid2);
        failed++;
    }

    if (aether_smart_smoother_reset(smoother) != 0) {
        std::fprintf(stderr, "smart smoother reset failed\n");
        failed++;
    }
    if (aether_smart_smoother_destroy(smoother) != 0) {
        std::fprintf(stderr, "smart smoother destroy failed\n");
        failed++;
    }
    if (aether_smart_smoother_add(nullptr, 0.5, &s0) == 0) {
        std::fprintf(stderr, "smart smoother null handle expected failure\n");
        failed++;
    }

    return failed;
}

int test_flip_animation_c_api() {
    int failed = 0;

    aether_flip_easing_config_t cfg{};
    cfg.duration_s = 0.5f;
    cfg.cp1x = 0.34f;
    cfg.cp1y = 1.56f;
    cfg.cp2x = 0.64f;
    cfg.cp2y = 1.0f;
    cfg.stagger_delay_s = 0.03f;
    cfg.max_concurrent = 20;

    const float eased = aether_flip_easing(0.6f, &cfg);
    if (!(eased > 1.0f && eased < 1.2f)) {
        std::fprintf(stderr, "flip easing overshoot mismatch eased=%.6f\n", eased);
        failed++;
    }

    aether_flip_animation_state_t in{};
    in.start_time_s = 0.0f;
    in.flip_axis_origin = aether_float3_t{0.0f, 0.0f, 0.0f};
    in.flip_axis_direction = aether_float3_t{0.0f, 1.0f, 0.0f};
    in.rotated_normal = aether_float3_t{0.0f, 0.0f, 1.0f};

    aether_flip_animation_state_t out{};
    aether_float3_t rest_normal = {0.0f, 0.0f, 1.0f};
    int rc = aether_compute_flip_states(
        &in,
        1,
        0.25f,
        &cfg,
        &rest_normal,
        &out);
    if (rc != 0) {
        std::fprintf(stderr, "flip compute states failed rc=%d\n", rc);
        failed++;
    } else {
        if (!(out.flip_angle > 0.0f && out.flip_angle <= 3.141593f)) {
            std::fprintf(stderr, "flip angle out of range angle=%.6f\n", out.flip_angle);
            failed++;
        }
        if (!std::isfinite(out.rotated_normal.x) ||
            !std::isfinite(out.rotated_normal.y) ||
            !std::isfinite(out.rotated_normal.z)) {
            std::fprintf(stderr, "flip rotated normal non-finite\n");
            failed++;
        }
    }

    if (aether_compute_flip_states(nullptr, 1, 0.25f, &cfg, nullptr, &out) == 0) {
        std::fprintf(stderr, "flip null input expected failure\n");
        failed++;
    }

    return failed;
}

int test_ripple_c_api() {
    int failed = 0;

    const uint32_t tri_indices[6] = {
        0u, 1u, 2u,
        1u, 3u, 2u,
    };

    uint32_t offsets[3] = {0u, 0u, 0u};
    uint32_t neighbors[8] = {0u};
    int neighbor_count = 0;
    int rc = aether_ripple_build_adjacency(
        tri_indices,
        2,
        offsets,
        neighbors,
        8,
        &neighbor_count);
    if (rc != 0 || neighbor_count <= 0) {
        std::fprintf(stderr, "ripple build adjacency failed rc=%d count=%d\n", rc, neighbor_count);
        failed++;
        return failed;
    }

    int required_neighbors = 0;
    rc = aether_ripple_build_adjacency(
        tri_indices,
        2,
        offsets,
        nullptr,
        0,
        &required_neighbors);
    if (rc != -2 || required_neighbors <= 0) {
        std::fprintf(stderr, "ripple expected capacity failure rc=%d required=%d\n", rc, required_neighbors);
        failed++;
    }

    const uint32_t triggers[1] = {0u};
    const float starts[1] = {0.0f};
    float amplitudes[2] = {0.0f, 0.0f};

    aether_ripple_config_t cfg{};
    cfg.damping = 0.85f;
    cfg.max_hops = 4;
    cfg.delay_per_hop_s = 0.0f;

    rc = aether_compute_ripple_amplitudes(
        offsets,
        neighbors,
        2,
        triggers,
        1,
        starts,
        0.1f,
        &cfg,
        amplitudes);
    if (rc != 0) {
        std::fprintf(stderr, "ripple amplitude compute failed rc=%d\n", rc);
        failed++;
    } else if (!(amplitudes[0] > 0.9f && amplitudes[1] > 0.0f && amplitudes[1] < amplitudes[0])) {
        std::fprintf(stderr, "ripple amplitude mismatch a0=%.6f a1=%.6f\n",
            amplitudes[0], amplitudes[1]);
        failed++;
    }

    if (aether_compute_ripple_amplitudes(
            offsets,
            neighbors,
            2,
            triggers,
            1,
            starts,
            0.1f,
            &cfg,
            nullptr) == 0) {
        std::fprintf(stderr, "ripple null output expected failure\n");
        failed++;
    }

    return failed;
}

int test_flip_runtime_c_api() {
    int failed = 0;

    aether_flip_runtime_config_t cfg{};
    int rc = aether_flip_runtime_default_config(&cfg);
    if (rc != 0) {
        std::fprintf(stderr, "flip runtime default config failed rc=%d\n", rc);
        return failed + 1;
    }

    aether_flip_runtime_t* runtime = nullptr;
    rc = aether_flip_runtime_create(&cfg, &runtime);
    if (rc != 0 || runtime == nullptr) {
        std::fprintf(stderr, "flip runtime create failed rc=%d\n", rc);
        return failed + 1;
    }

    aether_flip_runtime_observation_t obs{};
    obs.patch_key = 0xA11CEu;
    obs.previous_display = 0.05f;
    obs.current_display = 0.15f;  // crosses S0->S1
    obs.triangle_id = 7;
    obs.axis_start = aether_float3_t{0.0f, 0.0f, 0.0f};
    obs.axis_end = aether_float3_t{1.0f, 0.0f, 0.0f};

    int32_t crossed_ids[1] = {-1};
    int crossed_count = 1;
    const double now_s = 100.0;
    rc = aether_flip_runtime_ingest(
        runtime,
        &obs,
        1,
        now_s,
        crossed_ids,
        &crossed_count);
    if (rc != 0 || crossed_count != 1 || crossed_ids[0] != 7) {
        std::fprintf(stderr, "flip runtime ingest failed rc=%d count=%d id=%d\n",
            rc, crossed_count, crossed_ids[0]);
        failed++;
    }

    int32_t sample_ids[2] = {7, 77};
    float sample_angles[2] = {0.0f, 0.0f};
    aether_float3_t axis_origins[2]{};
    aether_float3_t axis_dirs[2]{};
    rc = aether_flip_runtime_sample(
        runtime,
        sample_ids,
        2,
        now_s + 0.1,
        sample_angles,
        axis_origins,
        axis_dirs);
    if (rc != 0) {
        std::fprintf(stderr, "flip runtime sample failed rc=%d\n", rc);
        failed++;
    } else {
        if (!(sample_angles[0] > 0.0f && sample_angles[0] < 3.141593f)) {
            std::fprintf(stderr, "flip runtime expected active angle in (0,pi), got %.6f\n", sample_angles[0]);
            failed++;
        }
        if (!approx(sample_angles[1], 0.0f, 1e-6f)) {
            std::fprintf(stderr, "flip runtime unknown id should return 0 angle, got %.6f\n", sample_angles[1]);
            failed++;
        }
        if (!approx(axis_origins[0].x, 0.0f, 1e-6f) ||
            !approx(axis_origins[0].y, 0.0f, 1e-6f) ||
            !approx(axis_origins[0].z, 0.0f, 1e-6f)) {
            std::fprintf(stderr, "flip runtime axis origin mismatch\n");
            failed++;
        }
        if (!approx(axis_dirs[0].x, 1.0f, 1e-6f) ||
            !approx(axis_dirs[0].y, 0.0f, 1e-6f) ||
            !approx(axis_dirs[0].z, 0.0f, 1e-6f)) {
            std::fprintf(stderr, "flip runtime axis direction mismatch\n");
            failed++;
        }
    }

    // Existing active triangle should not be re-added.
    crossed_ids[0] = -1;
    crossed_count = 1;
    rc = aether_flip_runtime_ingest(
        runtime,
        &obs,
        1,
        now_s + 0.2,
        crossed_ids,
        &crossed_count);
    if (rc != 0 || crossed_count != 0) {
        std::fprintf(stderr, "flip runtime re-ingest expected no new crossings rc=%d count=%d\n",
            rc, crossed_count);
        failed++;
    }

    float tick_angles[1] = {0.0f};
    int tick_count = 1;
    rc = aether_flip_runtime_tick(runtime, now_s + 1.0, tick_angles, &tick_count);
    if (rc != 0 || tick_count != 1 || !approx(tick_angles[0], 3.141593f, 1e-4f)) {
        std::fprintf(stderr, "flip runtime tick completion mismatch rc=%d count=%d angle=%.6f\n",
            rc, tick_count, tick_angles[0]);
        failed++;
    }

    tick_count = 1;
    rc = aether_flip_runtime_tick(runtime, now_s + 1.1, tick_angles, &tick_count);
    if (rc != 0 || tick_count != 0) {
        std::fprintf(stderr, "flip runtime second tick expected empty active set rc=%d count=%d\n",
            rc, tick_count);
        failed++;
    }

    // Capacity query path.
    crossed_count = 0;
    rc = aether_flip_runtime_ingest(
        runtime,
        &obs,
        1,
        now_s + 2.0,
        nullptr,
        &crossed_count);
    if (rc != -3 || crossed_count != 1) {
        std::fprintf(stderr, "flip runtime expected capacity query failure rc=%d count=%d\n",
            rc, crossed_count);
        failed++;
    }

    if (aether_flip_runtime_reset(runtime) != 0) {
        std::fprintf(stderr, "flip runtime reset failed\n");
        failed++;
    }
    if (aether_flip_runtime_default_config(nullptr) == 0 ||
        aether_flip_runtime_create(nullptr, nullptr) == 0 ||
        aether_flip_runtime_ingest(nullptr, &obs, 1, now_s, crossed_ids, &crossed_count) == 0 ||
        aether_flip_runtime_tick(nullptr, now_s, tick_angles, &tick_count) == 0 ||
        aether_flip_runtime_sample(nullptr, sample_ids, 1, now_s, sample_angles, axis_origins, axis_dirs) == 0) {
        std::fprintf(stderr, "flip runtime null input expected failure\n");
        failed++;
    }

    rc = aether_flip_runtime_destroy(runtime);
    if (rc != 0) {
        std::fprintf(stderr, "flip runtime destroy failed rc=%d\n", rc);
        failed++;
    }
    return failed;
}

int test_ripple_runtime_c_api() {
    int failed = 0;

    aether_ripple_runtime_config_t cfg{};
    int rc = aether_ripple_runtime_default_config(&cfg);
    if (rc != 0) {
        std::fprintf(stderr, "ripple runtime default config failed rc=%d\n", rc);
        return failed + 1;
    }

    aether_ripple_runtime_t* runtime = nullptr;
    rc = aether_ripple_runtime_create(&cfg, &runtime);
    if (rc != 0 || runtime == nullptr) {
        std::fprintf(stderr, "ripple runtime create failed rc=%d\n", rc);
        return failed + 1;
    }

    // Two-triangle undirected edge: 0 <-> 1.
    const uint32_t offsets[3] = {0u, 1u, 2u};
    const uint32_t neighbors[2] = {1u, 0u};
    rc = aether_ripple_runtime_set_adjacency(runtime, offsets, neighbors, 2);
    if (rc != 0) {
        std::fprintf(stderr, "ripple runtime set adjacency failed rc=%d\n", rc);
        failed++;
    }

    int spawned = 0;
    const double t0 = 50.0;
    rc = aether_ripple_runtime_spawn(runtime, 0, t0, &spawned);
    if (rc != 0 || spawned != 1) {
        std::fprintf(stderr, "ripple runtime spawn failed rc=%d spawned=%d\n", rc, spawned);
        failed++;
    }

    int32_t tri_ids[2] = {0, 1};
    float amps[2] = {0.0f, 0.0f};
    rc = aether_ripple_runtime_sample(runtime, tri_ids, 2, t0 + 0.1, amps);
    if (rc != 0) {
        std::fprintf(stderr, "ripple runtime sample failed rc=%d\n", rc);
        failed++;
    } else if (!(amps[0] > 0.0f && amps[1] > 0.0f && amps[1] < amps[0])) {
        std::fprintf(stderr, "ripple runtime amplitude mismatch a0=%.6f a1=%.6f\n", amps[0], amps[1]);
        failed++;
    }

    // Debounce: second spawn too soon should be ignored.
    spawned = 1;
    rc = aether_ripple_runtime_spawn(runtime, 0, t0 + 0.1, &spawned);
    if (rc != 0 || spawned != 0) {
        std::fprintf(stderr, "ripple runtime debounce mismatch rc=%d spawned=%d\n", rc, spawned);
        failed++;
    }

    int tick_count = 0;
    rc = aether_ripple_runtime_tick(runtime, t0 + 0.1, nullptr, &tick_count);
    if (rc != -3 || tick_count != 2) {
        std::fprintf(stderr, "ripple runtime capacity query mismatch rc=%d count=%d\n", rc, tick_count);
        failed++;
    }

    tick_count = 2;
    float tick_amps[2] = {0.0f, 0.0f};
    rc = aether_ripple_runtime_tick(runtime, t0 + 1.0, tick_amps, &tick_count);
    if (rc != 0 || tick_count != 2) {
        std::fprintf(stderr, "ripple runtime tick failed rc=%d count=%d\n", rc, tick_count);
        failed++;
    }
    // After completion cleanup, subsequent tick should remain zeros.
    tick_count = 2;
    rc = aether_ripple_runtime_tick(runtime, t0 + 1.2, tick_amps, &tick_count);
    if (rc != 0 || tick_count != 2 || !approx(tick_amps[0], 0.0f, 1e-6f) || !approx(tick_amps[1], 0.0f, 1e-6f)) {
        std::fprintf(stderr, "ripple runtime cleanup mismatch rc=%d count=%d a0=%.6f a1=%.6f\n",
            rc, tick_count, tick_amps[0], tick_amps[1]);
        failed++;
    }

    if (aether_ripple_runtime_default_config(nullptr) == 0 ||
        aether_ripple_runtime_create(nullptr, nullptr) == 0 ||
        aether_ripple_runtime_set_adjacency(nullptr, offsets, neighbors, 2) == 0 ||
        aether_ripple_runtime_spawn(nullptr, 0, t0, &spawned) == 0 ||
        aether_ripple_runtime_sample(nullptr, tri_ids, 2, t0, amps) == 0 ||
        aether_ripple_runtime_tick(nullptr, t0, tick_amps, &tick_count) == 0) {
        std::fprintf(stderr, "ripple runtime null input expected failure\n");
        failed++;
    }

    rc = aether_ripple_runtime_destroy(runtime);
    if (rc != 0) {
        std::fprintf(stderr, "ripple runtime destroy failed rc=%d\n", rc);
        failed++;
    }

    return failed;
}

int test_pose_stabilizer_c_api() {
    int failed = 0;

    aether_pose_stabilizer_t* stabilizer = nullptr;
    aether_pose_stabilizer_config_t config{};
    config.translation_alpha = 0.22f;
    config.rotation_alpha = 0.18f;
    config.max_prediction_horizon_s = 0.15f;
    config.bias_alpha = 0.03f;
    config.init_frames = 4u;
    config.fast_init = 1;
    config.use_ieskf = 0;

    int rc = aether_pose_stabilizer_create(&config, &stabilizer);
    if (rc != 0 || stabilizer == nullptr) {
        std::fprintf(stderr, "pose stabilizer create failed rc=%d\n", rc);
        return 1;
    }

    float pose0[16];
    make_identity_pose(pose0);
    float gyro0[3] = {0.0f, 0.0f, 0.0f};
    float accel0[3] = {0.0f, 0.0f, 9.81f};
    float stabilized0[16]{};
    float quality0 = -1.0f;
    rc = aether_pose_stabilizer_update(
        stabilizer,
        pose0,
        gyro0,
        accel0,
        1'000'000'000ULL,
        stabilized0,
        &quality0);
    if (rc != 0) {
        std::fprintf(stderr, "pose stabilizer first update failed rc=%d\n", rc);
        failed++;
    }

    float pose1[16];
    make_identity_pose(pose1);
    set_pose_translation(pose1, 0.01f, 0.0f, 0.0f);
    float gyro1[3] = {0.0f, 0.2f, 0.0f};
    float accel1[3] = {0.0f, 0.0f, 9.81f};
    float stabilized1[16]{};
    float quality1 = -1.0f;
    rc = aether_pose_stabilizer_update(
        stabilizer,
        pose1,
        gyro1,
        accel1,
        1'016'666'667ULL,
        stabilized1,
        &quality1);
    if (rc != 0) {
        std::fprintf(stderr, "pose stabilizer second update failed rc=%d\n", rc);
        failed++;
    } else {
        if (!(quality1 >= 0.0f && quality1 <= 1.0f)) {
            std::fprintf(stderr, "pose stabilizer quality out of range %.6f\n", quality1);
            failed++;
        }
        if (!(stabilized1[12] > 0.0f && stabilized1[12] <= 0.01f + 1e-4f)) {
            std::fprintf(stderr, "pose stabilizer translation smoothing mismatch %.6f\n", stabilized1[12]);
            failed++;
        }
    }

    float predicted[16]{};
    rc = aether_pose_stabilizer_predict(
        stabilizer,
        1'024'000'000ULL,
        predicted);
    if (rc != 0) {
        std::fprintf(stderr, "pose stabilizer predict failed rc=%d\n", rc);
        failed++;
    } else if (!(predicted[12] >= stabilized1[12] - 1e-5f)) {
        std::fprintf(stderr, "pose stabilizer prediction mismatch predicted=%.6f stable=%.6f\n",
            predicted[12], stabilized1[12]);
        failed++;
    }

    rc = aether_pose_stabilizer_reset(stabilizer);
    if (rc != 0) {
        std::fprintf(stderr, "pose stabilizer reset failed rc=%d\n", rc);
        failed++;
    }

    if (aether_pose_stabilizer_update(
            nullptr,
            pose1,
            gyro1,
            accel1,
            1'030'000'000ULL,
            stabilized1,
            &quality1) == 0) {
        std::fprintf(stderr, "pose stabilizer null handle expected failure\n");
        failed++;
    }

    rc = aether_pose_stabilizer_destroy(stabilizer);
    if (rc != 0) {
        std::fprintf(stderr, "pose stabilizer destroy failed rc=%d\n", rc);
        failed++;
    }

    return failed;
}

int test_erasure_c_api() {
    int failed = 0;

    constexpr int kBlockCount = 6;
    constexpr int kBlockSize = 8;
    std::vector<uint8_t> input(static_cast<std::size_t>(kBlockCount * kBlockSize), 0u);
    std::vector<uint32_t> offsets(static_cast<std::size_t>(kBlockCount + 1), 0u);
    for (int i = 0; i < kBlockCount; ++i) {
        offsets[static_cast<std::size_t>(i)] = static_cast<uint32_t>(i * kBlockSize);
        for (int j = 0; j < kBlockSize; ++j) {
            input[static_cast<std::size_t>(i * kBlockSize + j)] =
                static_cast<uint8_t>((i + 1) * (j + 3));
        }
    }
    offsets[static_cast<std::size_t>(kBlockCount)] = static_cast<uint32_t>(input.size());

    constexpr int kOutBlockCapacity = 16;
    std::vector<uint8_t> out_data_rs(512u, 0u);
    std::vector<uint8_t> out_data_rq(512u, 0u);
    std::vector<uint32_t> out_offsets_rs(static_cast<std::size_t>(kOutBlockCapacity + 1), 0u);
    std::vector<uint32_t> out_offsets_rq(static_cast<std::size_t>(kOutBlockCapacity + 1), 0u);
    int out_block_count_rs = 0;
    int out_block_count_rq = 0;
    uint32_t out_size_rs = 0u;
    uint32_t out_size_rq = 0u;

    int rc = aether_erasure_encode_with_mode(
        input.data(),
        offsets.data(),
        kBlockCount,
        0.5,
        0,
        0,
        out_data_rs.data(),
        static_cast<uint32_t>(out_data_rs.size()),
        out_offsets_rs.data(),
        kOutBlockCapacity,
        &out_block_count_rs,
        &out_size_rs);
    if (rc != 0 || out_block_count_rs <= kBlockCount) {
        std::fprintf(stderr, "erasure encode rs failed rc=%d blocks=%d\n", rc, out_block_count_rs);
        failed++;
    }

    rc = aether_erasure_encode_with_mode(
        input.data(),
        offsets.data(),
        kBlockCount,
        0.5,
        1,
        0,
        out_data_rq.data(),
        static_cast<uint32_t>(out_data_rq.size()),
        out_offsets_rq.data(),
        kOutBlockCapacity,
        &out_block_count_rq,
        &out_size_rq);
    if (rc != 0 || out_block_count_rq <= kBlockCount) {
        std::fprintf(stderr, "erasure encode raptorq failed rc=%d blocks=%d\n", rc, out_block_count_rq);
        failed++;
    }

    if (out_size_rs == out_size_rq && out_size_rs > static_cast<uint32_t>(input.size())) {
        const bool same = std::equal(
            out_data_rs.begin() + static_cast<std::ptrdiff_t>(input.size()),
            out_data_rs.begin() + static_cast<std::ptrdiff_t>(out_size_rs),
            out_data_rq.begin() + static_cast<std::ptrdiff_t>(input.size()));
        if (same) {
            std::fprintf(stderr, "erasure mode-specific parity unexpectedly identical\n");
            failed++;
        }
    }

    std::vector<uint8_t> present_rs(static_cast<std::size_t>(out_block_count_rs), 1u);
    std::vector<uint8_t> decoded_rs(512u, 0u);
    std::vector<uint32_t> decoded_offsets_rs(static_cast<std::size_t>(kBlockCount + 1), 0u);
    int decoded_block_count_rs = 0;
    uint32_t decoded_size_rs = 0u;
    rc = aether_erasure_decode_systematic_with_mode(
        out_data_rs.data(),
        out_offsets_rs.data(),
        present_rs.data(),
        out_block_count_rs,
        kBlockCount,
        0,
        0,
        decoded_rs.data(),
        static_cast<uint32_t>(decoded_rs.size()),
        decoded_offsets_rs.data(),
        kBlockCount,
        &decoded_block_count_rs,
        &decoded_size_rs);
    if (rc != 0 || decoded_size_rs != input.size() ||
        !std::equal(input.begin(), input.end(), decoded_rs.begin())) {
        std::fprintf(stderr, "erasure decode rs failed rc=%d size=%u\n", rc, decoded_size_rs);
        failed++;
    }

    std::vector<uint8_t> present_rq(static_cast<std::size_t>(out_block_count_rq), 1u);
    std::vector<uint8_t> decoded_rq(512u, 0u);
    std::vector<uint32_t> decoded_offsets_rq(static_cast<std::size_t>(kBlockCount + 1), 0u);
    int decoded_block_count_rq = 0;
    uint32_t decoded_size_rq = 0u;
    rc = aether_erasure_decode_systematic_with_mode(
        out_data_rq.data(),
        out_offsets_rq.data(),
        present_rq.data(),
        out_block_count_rq,
        kBlockCount,
        1,
        0,
        decoded_rq.data(),
        static_cast<uint32_t>(decoded_rq.size()),
        decoded_offsets_rq.data(),
        kBlockCount,
        &decoded_block_count_rq,
        &decoded_size_rq);
    if (rc != 0 || decoded_size_rq != input.size() ||
        !std::equal(input.begin(), input.end(), decoded_rq.begin())) {
        std::fprintf(stderr, "erasure decode raptorq failed rc=%d size=%u\n", rc, decoded_size_rq);
        failed++;
    }

    // RaptorQ mode must recover missing systematic blocks from parity equations.
    std::vector<uint8_t> present_rq_missing(static_cast<std::size_t>(out_block_count_rq), 1u);
    if (out_block_count_rq > kBlockCount) {
        present_rq_missing[2] = 0u;
        if (out_block_count_rq > kBlockCount + 1) {
            present_rq_missing[static_cast<std::size_t>(kBlockCount)] = 0u;
        }
    }
    std::fill(decoded_rq.begin(), decoded_rq.end(), 0u);
    std::fill(decoded_offsets_rq.begin(), decoded_offsets_rq.end(), 0u);
    decoded_block_count_rq = 0;
    decoded_size_rq = 0u;
    rc = aether_erasure_decode_systematic_with_mode(
        out_data_rq.data(),
        out_offsets_rq.data(),
        present_rq_missing.data(),
        out_block_count_rq,
        kBlockCount,
        1,
        0,
        decoded_rq.data(),
        static_cast<uint32_t>(decoded_rq.size()),
        decoded_offsets_rq.data(),
        kBlockCount,
        &decoded_block_count_rq,
        &decoded_size_rq);
    if (rc != 0 || decoded_size_rq != input.size() ||
        !std::equal(input.begin(), input.end(), decoded_rq.begin())) {
        std::fprintf(stderr, "erasure decode raptorq missing-systematic recovery failed rc=%d size=%u\n", rc, decoded_size_rq);
        failed++;
    }

    rc = aether_erasure_encode_with_mode(
        input.data(),
        offsets.data(),
        kBlockCount,
        0.5,
        7,
        0,
        out_data_rs.data(),
        static_cast<uint32_t>(out_data_rs.size()),
        out_offsets_rs.data(),
        kOutBlockCapacity,
        &out_block_count_rs,
        &out_size_rs);
    if (rc == 0) {
        std::fprintf(stderr, "erasure encode invalid mode expected failure\n");
        failed++;
    }

    return failed;
}

int test_volume_controller_hysteresis_c_api() {
    int failed = 0;

    aether_volume_controller_state_t state{};
    state.frame_counter = 0u;
    state.integration_skip_rate = 2;
    state.consecutive_good_frames = 0;
    state.consecutive_bad_frames = 0;
    state.consecutive_good_time_s = 0.0;
    state.consecutive_bad_time_s = 0.0;
    state.system_thermal_ceiling = 1;
    state.memory_skip_floor = 1;
    state.last_update_s = 0.0;

    aether_volume_controller_signals_t signals{};
    signals.thermal_level = 0;
    signals.thermal_headroom = 1.0f;
    signals.memory_water_level = 0;
    signals.thermal.level = 0;
    signals.thermal.headroom = 1.0f;
    signals.thermal.confidence = 1.0f;
    signals.memory_pressure = 0;
    signals.tracking_state = 2;
    const float identity_pose[16] = {
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    };
    std::copy(identity_pose, identity_pose + 16, signals.camera_pose);
    signals.angular_velocity = 0.0f;
    signals.valid_pixel_count = 100;
    signals.total_pixel_count = 100;

    aether_volume_controller_decision_t decision{};

    // 5s sustained good frames -> recover by one step.
    // First frame uses fallback dt before timestamp history is initialized.
    signals.frame_actual_duration_ms = 4.0f;
    for (int i = 0; i < 10; ++i) {
        signals.timestamp_s = static_cast<double>(i + 1);
        const int rc = aether_volume_controller_decide(&signals, &state, &decision);
        if (rc != 0) {
            std::fprintf(stderr, "volume controller good-phase step failed rc=%d\n", rc);
            failed++;
            return failed;
        }
    }
    if (state.integration_skip_rate != 2) {
        std::fprintf(stderr, "volume controller recovered too early skip=%d\n", state.integration_skip_rate);
        failed++;
    }
    signals.timestamp_s = 11.0;
    if (aether_volume_controller_decide(&signals, &state, &decision) != 0) {
        std::fprintf(stderr, "volume controller good-phase threshold step failed\n");
        failed++;
    } else if (state.integration_skip_rate != 1) {
        std::fprintf(
            stderr,
            "volume controller 5s recover mismatch skip=%d good_time=%.3f bad_time=%.3f\n",
            state.integration_skip_rate,
            state.consecutive_good_time_s,
            state.consecutive_bad_time_s);
        failed++;
    }

    // 10s sustained bad frames -> degrade by one step.
    signals.frame_actual_duration_ms = 12.0f;
    for (int i = 0; i < 19; ++i) {
        signals.timestamp_s = 12.0 + static_cast<double>(i);
        const int rc = aether_volume_controller_decide(&signals, &state, &decision);
        if (rc != 0) {
            std::fprintf(stderr, "volume controller bad-phase step failed rc=%d\n", rc);
            failed++;
            return failed;
        }
    }
    if (state.integration_skip_rate != 1) {
        std::fprintf(stderr, "volume controller degraded too early skip=%d\n", state.integration_skip_rate);
        failed++;
    }
    signals.timestamp_s = 31.0;
    if (aether_volume_controller_decide(&signals, &state, &decision) != 0) {
        std::fprintf(stderr, "volume controller bad-phase threshold step failed\n");
        failed++;
    } else if (state.integration_skip_rate != 2) {
        std::fprintf(
            stderr,
            "volume controller 10s degrade mismatch skip=%d good_time=%.3f bad_time=%.3f\n",
            state.integration_skip_rate,
            state.consecutive_good_time_s,
            state.consecutive_bad_time_s);
        failed++;
    }

    return failed;
}

int test_pr1_admission_kernel_c_api() {
    int failed = 0;

    aether_pr1_admission_input_t input{};
    input.current_mode = AETHER_PR1_BUILD_MODE_NORMAL;
    input.ig_min_soft = 0.1;
    input.novelty_min_soft = 0.1;
    input.eeb_min_quantum = 1.0;

    aether_pr1_admission_decision_t out{};
    int rc = aether_pr1_admission_evaluate(&input, &out);
    if (rc != 0 ||
        out.classification != AETHER_PR1_CLASSIFICATION_ACCEPTED ||
        out.reason != AETHER_PR1_REJECT_REASON_NONE) {
        std::fprintf(stderr, "pr1 accepted path mismatch rc=%d\n", rc);
        failed++;
    }

    input.is_duplicate = 1;
    input.hard_trigger = AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD;
    rc = aether_pr1_admission_evaluate(&input, &out);
    if (rc != 0 ||
        out.classification != AETHER_PR1_CLASSIFICATION_DUPLICATE_REJECTED ||
        out.reason != AETHER_PR1_REJECT_REASON_DUPLICATE ||
        out.hard_fuse_trigger != AETHER_PR1_HARD_FUSE_NONE) {
        std::fprintf(stderr, "pr1 duplicate priority mismatch rc=%d\n", rc);
        failed++;
    }

    input.is_duplicate = 0;
    input.hard_trigger = AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD;
    rc = aether_pr1_admission_evaluate(&input, &out);
    if (rc != 0 ||
        out.classification != AETHER_PR1_CLASSIFICATION_REJECTED ||
        out.reason != AETHER_PR1_REJECT_REASON_HARD_CAP ||
        out.build_mode != AETHER_PR1_BUILD_MODE_SATURATED ||
        out.guidance_signal != AETHER_PR1_GUIDANCE_STATIC_OVERLAY ||
        out.hard_fuse_trigger != AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD) {
        std::fprintf(stderr, "pr1 hard fuse mismatch rc=%d\n", rc);
        failed++;
    }

    input.hard_trigger = AETHER_PR1_HARD_FUSE_NONE;
    input.should_trigger_soft_limit = 1;
    input.info_gain = 0.05;
    input.novelty = 0.9;
    input.current_mode = AETHER_PR1_BUILD_MODE_DAMPING;
    rc = aether_pr1_admission_evaluate(&input, &out);
    if (rc != 0 ||
        out.classification != AETHER_PR1_CLASSIFICATION_REJECTED ||
        out.reason != AETHER_PR1_REJECT_REASON_LOW_GAIN_SOFT ||
        out.guidance_signal != AETHER_PR1_GUIDANCE_HEAT_COOL_COVERAGE) {
        std::fprintf(stderr, "pr1 soft reject mismatch rc=%d\n", rc);
        failed++;
    }

    input.info_gain = 0.9;
    input.novelty = 0.9;
    rc = aether_pr1_admission_evaluate(&input, &out);
    if (rc != 0 ||
        out.classification != AETHER_PR1_CLASSIFICATION_ACCEPTED ||
        out.reason != AETHER_PR1_REJECT_REASON_NONE ||
        out.guidance_signal != AETHER_PR1_GUIDANCE_DIRECTIONAL_AFFORDANCE) {
        std::fprintf(stderr, "pr1 soft accept mismatch rc=%d\n", rc);
        failed++;
    }

    if (aether_pr1_admission_evaluate(nullptr, &out) == 0) {
        std::fprintf(stderr, "pr1 null input expected failure\n");
        failed++;
    }

    return failed;
}

int test_pr1_capacity_state_c_api() {
    int failed = 0;

    aether_pr1_capacity_state_input_t input{};
    input.patch_count_shadow = 0;
    input.eeb_remaining = 9000.0;
    input.current_mode = AETHER_PR1_BUILD_MODE_NORMAL;
    input.saturated_latched = 0;
    input.soft_limit_patch_count = 5000;
    input.soft_budget_threshold = 3000.0;
    input.hard_limit_patch_count = 8000;
    input.hard_budget_threshold = 1500.0;

    aether_pr1_capacity_state_output_t out{};
    int rc = aether_pr1_capacity_state_step(&input, &out);
    if (rc != 0 ||
        out.should_trigger_soft_limit != 0 ||
        out.hard_trigger != AETHER_PR1_HARD_FUSE_NONE ||
        out.next_mode != AETHER_PR1_BUILD_MODE_NORMAL ||
        out.should_latch_saturated != 0) {
        std::fprintf(stderr, "pr1 capacity baseline mismatch rc=%d\n", rc);
        failed++;
    }

    input.patch_count_shadow = 5000;
    input.eeb_remaining = 9000.0;
    rc = aether_pr1_capacity_state_step(&input, &out);
    if (rc != 0 ||
        out.should_trigger_soft_limit != 1 ||
        out.hard_trigger != AETHER_PR1_HARD_FUSE_NONE ||
        out.next_mode != AETHER_PR1_BUILD_MODE_DAMPING) {
        std::fprintf(stderr, "pr1 capacity soft-trigger mismatch rc=%d\n", rc);
        failed++;
    }

    input.patch_count_shadow = 8000;
    rc = aether_pr1_capacity_state_step(&input, &out);
    if (rc != 0 ||
        out.hard_trigger != AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD ||
        out.next_mode != AETHER_PR1_BUILD_MODE_SATURATED ||
        out.should_latch_saturated != 1) {
        std::fprintf(stderr, "pr1 capacity hard-trigger mismatch rc=%d\n", rc);
        failed++;
    }

    input.patch_count_shadow = 10;
    input.eeb_remaining = 1200.0;
    rc = aether_pr1_capacity_state_step(&input, &out);
    if (rc != 0 ||
        out.hard_trigger != AETHER_PR1_HARD_FUSE_EEB_HARD ||
        out.next_mode != AETHER_PR1_BUILD_MODE_SATURATED) {
        std::fprintf(stderr, "pr1 capacity eeb hard-trigger mismatch rc=%d\n", rc);
        failed++;
    }

    input.saturated_latched = 1;
    input.eeb_remaining = 9000.0;
    input.patch_count_shadow = 0;
    input.current_mode = AETHER_PR1_BUILD_MODE_NORMAL;
    rc = aether_pr1_capacity_state_step(&input, &out);
    if (rc != 0 ||
        out.next_mode != AETHER_PR1_BUILD_MODE_SATURATED ||
        out.should_latch_saturated != 0) {
        std::fprintf(stderr, "pr1 capacity latched saturation mismatch rc=%d\n", rc);
        failed++;
    }

    if (aether_pr1_capacity_state_step(nullptr, &out) == 0) {
        std::fprintf(stderr, "pr1 capacity null input expected failure\n");
        failed++;
    }

    return failed;
}

int test_pr1_information_gain_c_api() {
    int failed = 0;

    aether_pr1_patch_descriptor_t patch{};
    patch.pose_x = 1.0f;
    patch.pose_y = 2.0f;
    patch.pose_z = 3.0f;
    patch.coverage_x = 10;
    patch.coverage_y = 12;
    patch.radiance_x = 0.6f;
    patch.radiance_y = 0.3f;
    patch.radiance_z = 0.1f;

    constexpr int kGridSize = 128;
    std::vector<std::uint8_t> grid(static_cast<std::size_t>(kGridSize) * static_cast<std::size_t>(kGridSize), 0u);
    const std::size_t center_idx =
        static_cast<std::size_t>(patch.coverage_y) * static_cast<std::size_t>(kGridSize) +
        static_cast<std::size_t>(patch.coverage_x);
    grid[center_idx] = static_cast<std::uint8_t>(2u);

    double info_gain = 0.0;
    int rc = aether_pr1_compute_info_gain(&patch, grid.data(), kGridSize, &info_gain);
    if (rc != 0 || !std::isfinite(info_gain) || info_gain < 0.0 || info_gain > 1.0) {
        std::fprintf(stderr, "pr1 compute info gain failed: rc=%d value=%f\n", rc, info_gain);
        failed++;
    }

    aether_pr1_info_gain_config_t cfg{};
    if (aether_pr1_info_gain_default_config(&cfg) != 0) {
        std::fprintf(stderr, "pr1 default config failed\n");
        failed++;
    } else {
        cfg.info_gain_strategy = AETHER_PR1_INFO_GAIN_STRATEGY_ENTROPY_FRONTIER;
        double info_gain_entropy = 0.0;
        rc = aether_pr1_compute_info_gain_with_config(&patch, grid.data(), kGridSize, &cfg, &info_gain_entropy);
        if (rc != 0 || !std::isfinite(info_gain_entropy) || info_gain_entropy < 0.0 || info_gain_entropy > 1.0) {
            std::fprintf(stderr, "pr1 compute info gain (entropy) failed: rc=%d value=%f\n", rc, info_gain_entropy);
            failed++;
        } else if (info_gain_entropy + 1e-9 < info_gain) {
            std::fprintf(stderr, "pr1 entropy strategy expected >= legacy in sparse-white neighborhood\n");
            failed++;
        }
    }

    std::vector<aether_pr1_patch_descriptor_t> existing(2u);
    existing[0] = patch;
    existing[1] = patch;
    existing[1].pose_x += 10.0f;
    existing[1].pose_y += 10.0f;
    existing[1].pose_z += 10.0f;
    existing[1].coverage_x += 40;
    existing[1].coverage_y += 40;
    existing[1].radiance_x = 0.1f;
    existing[1].radiance_y = 0.9f;
    existing[1].radiance_z = 0.9f;

    double novelty_same = 0.0;
    rc = aether_pr1_compute_novelty(&patch, existing.data(), 1, 0.01, &novelty_same);
    if (rc != 0 || novelty_same < 0.0 || novelty_same > 1.0 || novelty_same > 0.05) {
        std::fprintf(stderr, "pr1 novelty (same) mismatch: rc=%d value=%f\n", rc, novelty_same);
        failed++;
    }

    double novelty_far = 0.0;
    rc = aether_pr1_compute_novelty(&patch, &existing[1], 1, 0.01, &novelty_far);
    if (rc != 0 || novelty_far < 0.0 || novelty_far > 1.0 || novelty_far < novelty_same) {
        std::fprintf(stderr, "pr1 novelty (far) mismatch: rc=%d same=%f far=%f\n", rc, novelty_same, novelty_far);
        failed++;
    }

    if (aether_pr1_info_gain_default_config(&cfg) != 0) {
        std::fprintf(stderr, "pr1 default config (novelty) failed\n");
        failed++;
    } else {
        cfg.novelty_strategy = AETHER_PR1_NOVELTY_STRATEGY_KERNEL_ROBUST;
        double novelty_robust = 0.0;
        rc = aether_pr1_compute_novelty_with_config(&patch, &existing[1], 1, &cfg, &novelty_robust);
        if (rc != 0 || !std::isfinite(novelty_robust) || novelty_robust < 0.0 || novelty_robust > 1.0) {
            std::fprintf(stderr, "pr1 novelty robust mismatch: rc=%d value=%f\n", rc, novelty_robust);
            failed++;
        }
    }

    if (aether_pr1_compute_info_gain(nullptr, grid.data(), kGridSize, &info_gain) == 0) {
        std::fprintf(stderr, "pr1 compute info gain null patch expected failure\n");
        failed++;
    }
    if (aether_pr1_compute_novelty(&patch, existing.data(), -1, 0.01, &novelty_far) == 0) {
        std::fprintf(stderr, "pr1 compute novelty negative count expected failure\n");
        failed++;
    }
    if (aether_pr1_compute_info_gain_with_config(&patch, grid.data(), kGridSize, nullptr, nullptr) == 0) {
        std::fprintf(stderr, "pr1 compute info gain with config null output expected failure\n");
        failed++;
    }

    return failed;
}

int test_coverage_estimator_c_api() {
    int failed = 0;

    aether_coverage_estimator_config_t cfg{};
    if (aether_coverage_estimator_default_config(&cfg) != 0) {
        std::fprintf(stderr, "coverage default config failed\n");
        return 1;
    }
    cfg.use_custom_level_weights = 1;
    for (int i = 0; i < 7; ++i) {
        cfg.level_weights[i] = 0.0;
    }
    cfg.level_weights[0] = 0.0;
    cfg.level_weights[6] = 1.0;
    cfg.use_fisher_weights = 0;  // exercise deterministic discrete level_weights path
    cfg.ema_alpha = 1.0;
    cfg.max_coverage_delta_per_sec = 100.0;
    cfg.view_diversity_boost = 0.0;

    aether_coverage_estimator_t* estimator = nullptr;
    if (aether_coverage_estimator_create(&cfg, &estimator) != 0 || estimator == nullptr) {
        std::fprintf(stderr, "coverage estimator create failed\n");
        return 1;
    }

    aether_coverage_cell_observation_t cells[2]{};
    cells[0].level = 0u;
    cells[0].occupied = 1.0;
    cells[0].free_mass = 0.0;
    cells[0].unknown = 0.0;
    cells[0].area_weight = 1.0;
    cells[0].excluded = 0;
    cells[0].view_count = 0u;
    cells[1] = cells[0];
    cells[1].level = 6u;

    aether_coverage_result_t result{};
    int rc = aether_coverage_estimator_update(estimator, cells, 2, 1000, &result);
    if (rc != 0) {
        std::fprintf(stderr, "coverage update failed: rc=%d\n", rc);
        failed++;
    } else {
        if (std::fabs(result.raw_coverage - 0.5) > 1e-6) {
            std::fprintf(stderr, "coverage raw mismatch: %.6f\n", result.raw_coverage);
            failed++;
        }
        if (result.breakdown_counts[0] != 1u || result.breakdown_counts[6] != 1u) {
            std::fprintf(stderr, "coverage breakdown mismatch\n");
            failed++;
        }
    }

    rc = aether_coverage_estimator_update(estimator, nullptr, 1, 1001, &result);
    if (rc == 0) {
        std::fprintf(stderr, "coverage expected invalid argument for null cells\n");
        failed++;
    }

    rc = aether_coverage_estimator_update(estimator, cells, 2, 900, &result);
    if (rc != 0) {
        std::fprintf(stderr, "coverage non-monotonic timestamp update failed: rc=%d\n", rc);
        failed++;
    } else if (result.non_monotonic_time_count <= 0) {
        std::fprintf(stderr, "coverage non-monotonic counter did not increment\n");
        failed++;
    }

    double last = -1.0;
    if (aether_coverage_estimator_last_coverage(estimator, &last) != 0 || last < 0.0 || last > 1.0) {
        std::fprintf(stderr, "coverage last_coverage invalid\n");
        failed++;
    }

    int non_mono = -1;
    if (aether_coverage_estimator_non_monotonic_count(estimator, &non_mono) != 0 || non_mono < 1) {
        std::fprintf(stderr, "coverage non_monotonic_count invalid\n");
        failed++;
    }

    if (aether_coverage_estimator_reset(estimator) != 0) {
        std::fprintf(stderr, "coverage reset failed\n");
        failed++;
    }

    if (aether_coverage_estimator_destroy(estimator) != 0) {
        std::fprintf(stderr, "coverage destroy failed\n");
        failed++;
    }
    return failed;
}

int test_ds_mass_c_api() {
    int failed = 0;

    aether_ds_mass_t raw{};
    raw.occupied = 0.5;
    raw.free_mass = 0.5;
    raw.unknown = 0.5;
    aether_ds_mass_t sealed{};
    int rc = aether_ds_mass_sealed(&raw, &sealed);
    if (rc != 0) {
        std::fprintf(stderr, "ds sealed failed: rc=%d\n", rc);
        failed++;
    } else {
        const double sum = sealed.occupied + sealed.free_mass + sealed.unknown;
        if (std::fabs(sum - 1.0) > 1e-9) {
            std::fprintf(stderr, "ds sealed invariant mismatch: sum=%.12f\n", sum);
            failed++;
        }
    }

    aether_ds_mass_t m_occ{};
    m_occ.occupied = 1.0;
    m_occ.free_mass = 0.0;
    m_occ.unknown = 0.0;
    aether_ds_mass_t m_free{};
    m_free.occupied = 0.0;
    m_free.free_mass = 1.0;
    m_free.unknown = 0.0;

    aether_ds_combine_result_t dempster{};
    rc = aether_ds_combine_dempster(&m_occ, &m_free, &dempster);
    if (rc != 0) {
        std::fprintf(stderr, "ds dempster failed: rc=%d\n", rc);
        failed++;
    } else if (dempster.used_yager != 1 || dempster.conflict < 0.999999) {
        std::fprintf(stderr, "ds dempster fallback mismatch: used_yager=%d conflict=%.6f\n",
            dempster.used_yager, dempster.conflict);
        failed++;
    }

    aether_ds_mass_t auto_combined{};
    rc = aether_ds_combine_auto(&m_occ, &m_free, &auto_combined);
    if (rc != 0) {
        std::fprintf(stderr, "ds auto combine failed: rc=%d\n", rc);
        failed++;
    } else if (auto_combined.unknown < 0.999999) {
        std::fprintf(stderr, "ds auto combine expected unknown~1, got %.6f\n", auto_combined.unknown);
        failed++;
    }

    aether_ds_mass_t discounted{};
    rc = aether_ds_discount(&m_occ, 0.5, &discounted);
    if (rc != 0) {
        std::fprintf(stderr, "ds discount failed: rc=%d\n", rc);
        failed++;
    } else if (std::fabs(discounted.occupied - 0.5) > 1e-6 || std::fabs(discounted.unknown - 0.5) > 1e-6) {
        std::fprintf(stderr, "ds discount mismatch: occ=%.6f unk=%.6f\n",
            discounted.occupied, discounted.unknown);
        failed++;
    }

    aether_ds_mass_t from_delta{};
    rc = aether_ds_from_delta_multiplier(1.0, &from_delta);
    if (rc != 0 || from_delta.occupied < 0.79 || from_delta.occupied > 0.81) {
        std::fprintf(stderr, "ds from_delta mismatch: rc=%d occ=%.6f\n", rc, from_delta.occupied);
        failed++;
    }

    return failed;
}

int test_admission_primitives_c_api() {
    int failed = 0;

    aether_token_bucket_t* limiter = nullptr;
    if (aether_token_bucket_create(&limiter) != 0 || limiter == nullptr) {
        std::fprintf(stderr, "token bucket create failed\n");
        return 1;
    }
    int consumed = 0;
    int rc = aether_token_bucket_try_consume(limiter, "patch-a", 1000, &consumed);
    if (rc != 0 || consumed != 0) {
        std::fprintf(stderr, "token bucket initial consume mismatch rc=%d consumed=%d\n", rc, consumed);
        failed++;
    }
    double tokens = 0.0;
    rc = aether_token_bucket_available_tokens(limiter, "patch-a", 2000, &tokens);
    if (rc != 0 || tokens < 1.9 || tokens > 2.1) {
        std::fprintf(stderr, "token bucket refill mismatch rc=%d tokens=%.4f\n", rc, tokens);
        failed++;
    }
    rc = aether_token_bucket_try_consume(limiter, "patch-a", 2000, &consumed);
    if (rc != 0 || consumed == 0) {
        std::fprintf(stderr, "token bucket consume after refill mismatch rc=%d consumed=%d\n", rc, consumed);
        failed++;
    }
    aether_token_bucket_destroy(limiter);

    aether_view_diversity_tracker_t* diversity = nullptr;
    if (aether_view_diversity_create(&diversity) != 0 || diversity == nullptr) {
        std::fprintf(stderr, "view diversity create failed\n");
        return failed + 1;
    }
    double diversity_score_0 = 0.0;
    rc = aether_view_diversity_add_observation(diversity, "patch-a", 0.0, 1000, &diversity_score_0);
    if (rc != 0 || diversity_score_0 <= 0.0 || diversity_score_0 > 1.0) {
        std::fprintf(stderr, "view diversity first observation mismatch rc=%d score=%.4f\n", rc, diversity_score_0);
        failed++;
    }
    double diversity_score_1 = 0.0;
    rc = aether_view_diversity_add_observation(diversity, "patch-a", 180.0, 1100, &diversity_score_1);
    if (rc != 0 || diversity_score_1 <= 0.0 || diversity_score_1 > 1.0) {
        std::fprintf(stderr, "view diversity second observation mismatch rc=%d score=%.4f\n", rc, diversity_score_1);
        failed++;
    }
    aether_view_diversity_destroy(diversity);

    aether_spam_protection_t* spam = nullptr;
    if (aether_spam_protection_create(&spam) != 0 || spam == nullptr) {
        std::fprintf(stderr, "spam protection create failed\n");
        return failed + 1;
    }
    int allowed = 0;
    rc = aether_spam_protection_should_allow_update(spam, "patch-a", 1000, &allowed);
    if (rc != 0 || allowed == 0) {
        std::fprintf(stderr, "spam should_allow initial mismatch rc=%d allowed=%d\n", rc, allowed);
        failed++;
    }
    double frequency_scale = 0.0;
    rc = aether_spam_protection_frequency_scale(spam, "patch-a", 1000, &frequency_scale);
    if (rc != 0) {
        std::fprintf(stderr, "spam frequency scale update failed rc=%d\n", rc);
        failed++;
    }
    rc = aether_spam_protection_should_allow_update(spam, "patch-a", 1010, &allowed);
    if (rc != 0 || allowed != 0) {
        std::fprintf(stderr, "spam should_allow density mismatch rc=%d allowed=%d\n", rc, allowed);
        failed++;
    }
    double novelty_scale = 0.0;
    rc = aether_spam_protection_novelty_scale(spam, 0.0, &novelty_scale);
    if (rc != 0 || std::fabs(novelty_scale - 0.7) > 1e-6) {
        std::fprintf(stderr, "spam novelty scale mismatch rc=%d scale=%.6f\n", rc, novelty_scale);
        failed++;
    }
    aether_spam_protection_destroy(spam);

    aether_admission_controller_t* admission = nullptr;
    if (aether_admission_controller_create(&admission) != 0 || admission == nullptr) {
        std::fprintf(stderr, "admission controller create failed\n");
        return failed + 1;
    }
    aether_admission_decision_t decision{};
    rc = aether_admission_controller_check(admission, "patch-b", 30.0, 2000, &decision);
    if (rc != 0 || decision.allowed == 0) {
        std::fprintf(stderr, "admission first check mismatch rc=%d allowed=%d\n", rc, decision.allowed);
        failed++;
    }
    rc = aether_admission_controller_check(admission, "patch-b", 31.0, 2010, &decision);
    if (rc != 0 || decision.allowed != 0 || decision.hard_blocked == 0 ||
        (decision.reason_mask & (1u << AETHER_ADMISSION_REASON_TIME_DENSITY_SAME_PATCH)) == 0u) {
        std::fprintf(stderr, "admission density hard block mismatch rc=%d mask=%u hard=%d\n",
            rc, decision.reason_mask, decision.hard_blocked);
        failed++;
    }
    rc = aether_admission_controller_check_confirmed_spam(
        admission, "patch-b", 0.99, 0.95, &decision);
    if (rc != 0 || decision.allowed != 0 ||
        (decision.reason_mask & (1u << AETHER_ADMISSION_REASON_CONFIRMED_SPAM)) == 0u) {
        std::fprintf(stderr, "admission confirmed spam mismatch rc=%d mask=%u\n", rc, decision.reason_mask);
        failed++;
    }
    aether_admission_controller_destroy(admission);

    return failed;
}

int test_sha_merkle_evidence_c_api() {
    int failed = 0;

    // SHA256 known vector: "abc"
    {
        const uint8_t abc[] = {'a', 'b', 'c'};
        uint8_t digest[AETHER_SHA256_DIGEST_BYTES]{};
        char digest_hex[AETHER_SHA256_HEX_BYTES]{};
        int rc = aether_sha256(abc, 3, digest);
        if (rc != 0) {
            std::fprintf(stderr, "sha256 digest failed rc=%d\n", rc);
            failed++;
        }
        rc = aether_sha256_hex(abc, 3, digest_hex);
        if (rc != 0) {
            std::fprintf(stderr, "sha256 hex failed rc=%d\n", rc);
            failed++;
        }
        const std::string expected =
            "ba7816bf8f01cfea414140de5dae2223"
            "b00361a396177a9cb410ff61f20015ad";
        if (std::string(digest_hex) != expected || hex_of_bytes(digest, 32u) != expected) {
            std::fprintf(stderr, "sha256 vector mismatch\n");
            failed++;
        }
    }

    // Evidence canonical JSON bridge.
    {
        aether_evidence_patch_snapshot_t patches[2]{};
        patches[0].patch_id = "patch_b";
        patches[0].evidence = 0.6;
        patches[0].last_update_ms = 2000;
        patches[0].observation_count = 10;
        patches[0].best_frame_id = "frame_5";
        patches[0].error_count = 1;
        patches[0].error_streak = 0;
        patches[0].has_last_good_update_ms = 1;
        patches[0].last_good_update_ms = 2000;
        patches[1].patch_id = "patch_a";
        patches[1].evidence = 0.3;
        patches[1].last_update_ms = 1000;
        patches[1].observation_count = 5;
        patches[1].best_frame_id = "frame_2";
        patches[1].error_count = 0;
        patches[1].error_streak = 0;
        patches[1].has_last_good_update_ms = 1;
        patches[1].last_good_update_ms = 1000;

        aether_evidence_state_input_t input{};
        input.patches = patches;
        input.patch_count = 2;
        input.gate_display = 0.5;
        input.soft_display = 0.45;
        input.last_total_display = 0.475;
        input.schema_version = "3.0";
        input.exported_at_ms = 1234567890;

        int json_capacity = 0;
        int rc = aether_evidence_state_encode_canonical_json(&input, nullptr, &json_capacity);
        if (rc != -3 || json_capacity <= 0) {
            std::fprintf(stderr, "evidence canonical size query failed rc=%d cap=%d\n", rc, json_capacity);
            failed++;
        } else {
            std::vector<char> json(static_cast<std::size_t>(json_capacity), 0);
            rc = aether_evidence_state_encode_canonical_json(&input, json.data(), &json_capacity);
            if (rc != 0) {
                std::fprintf(stderr, "evidence canonical encode failed rc=%d\n", rc);
                failed++;
            } else {
                const std::string encoded(json.data());
                const std::size_t a_pos = encoded.find("\"patch_a\"");
                const std::size_t b_pos = encoded.find("\"patch_b\"");
                if (a_pos == std::string::npos || b_pos == std::string::npos || a_pos > b_pos) {
                    std::fprintf(stderr, "evidence canonical ordering mismatch\n");
                    failed++;
                }

                char canonical_hex[AETHER_SHA256_HEX_BYTES]{};
                rc = aether_evidence_state_canonical_sha256_hex(&input, canonical_hex);
                if (rc != 0) {
                    std::fprintf(stderr, "evidence canonical sha256 failed rc=%d\n", rc);
                    failed++;
                } else {
                    char raw_hex[AETHER_SHA256_HEX_BYTES]{};
                    rc = aether_sha256_hex(
                        reinterpret_cast<const uint8_t*>(encoded.data()),
                        static_cast<int>(encoded.size()),
                        raw_hex);
                    if (rc != 0 || std::string(raw_hex) != std::string(canonical_hex)) {
                        std::fprintf(stderr, "evidence canonical hash mismatch\n");
                        failed++;
                    }
                }
            }
        }
    }

    // RFC9162 Merkle bridge.
    {
        aether_merkle_tree_t* tree = nullptr;
        int rc = aether_merkle_tree_create(&tree);
        if (rc != 0 || tree == nullptr) {
            std::fprintf(stderr, "merkle tree create failed rc=%d\n", rc);
            return failed + 1;
        }

        const uint8_t leaf_a[] = {'A'};
        const uint8_t leaf_b[] = {'B'};
        rc = aether_merkle_tree_append(tree, leaf_a, 1);
        if (rc != 0) {
            std::fprintf(stderr, "merkle append A failed rc=%d\n", rc);
            failed++;
        }
        rc = aether_merkle_tree_append(tree, leaf_b, 1);
        if (rc != 0) {
            std::fprintf(stderr, "merkle append B failed rc=%d\n", rc);
            failed++;
        }

        uint64_t tree_size = 0;
        rc = aether_merkle_tree_size(tree, &tree_size);
        if (rc != 0 || tree_size != 2u) {
            std::fprintf(stderr, "merkle size mismatch rc=%d size=%llu\n", rc,
                static_cast<unsigned long long>(tree_size));
            failed++;
        }

        uint8_t root_hash[AETHER_MERKLE_HASH_BYTES]{};
        rc = aether_merkle_tree_root_hash(tree, root_hash);
        if (rc != 0) {
            std::fprintf(stderr, "merkle root hash failed rc=%d\n", rc);
            failed++;
        }

        aether_merkle_inclusion_proof_t proof{};
        rc = aether_merkle_tree_inclusion_proof(tree, 0u, &proof);
        if (rc != 0) {
            std::fprintf(stderr, "merkle inclusion proof failed rc=%d\n", rc);
            failed++;
        } else {
            int valid = 0;
            rc = aether_merkle_verify_inclusion(&proof, root_hash, &valid);
            if (rc != 0 || valid == 0) {
                std::fprintf(stderr, "merkle inclusion verify failed rc=%d valid=%d\n", rc, valid);
                failed++;
            }
            rc = aether_merkle_verify_inclusion_with_leaf_data(&proof, leaf_a, 1, root_hash, &valid);
            if (rc != 0 || valid == 0) {
                std::fprintf(stderr, "merkle inclusion data verify failed rc=%d valid=%d\n", rc, valid);
                failed++;
            }
        }

        aether_merkle_consistency_proof_t consistency{};
        rc = aether_merkle_tree_consistency_proof(tree, 1u, 2u, &consistency);
        if (rc != 0) {
            std::fprintf(stderr, "merkle consistency proof failed rc=%d\n", rc);
            failed++;
        } else {
            uint8_t first_root[AETHER_MERKLE_HASH_BYTES]{};
            rc = aether_merkle_tree_root_at_size(tree, 1u, first_root);
            if (rc != 0) {
                std::fprintf(stderr, "merkle root_at_size failed rc=%d\n", rc);
                failed++;
            } else {
                int valid = 0;
                rc = aether_merkle_verify_consistency(&consistency, first_root, root_hash, &valid);
                if (rc != 0 || valid == 0) {
                    std::fprintf(stderr, "merkle consistency verify failed rc=%d valid=%d\n", rc, valid);
                    failed++;
                }
            }
        }

        aether_merkle_tree_destroy(tree);
    }

    return failed;
}

void fill_test_gaussians(std::vector<aether_gaussian_t>* out_gaussians) {
    out_gaussians->clear();
    out_gaussians->resize(4);
    for (std::size_t i = 0u; i < out_gaussians->size(); ++i) {
        auto& g = (*out_gaussians)[i];
        g.id = static_cast<uint32_t>(10u + i);
        g.position = aether_float3_t{0.2f + static_cast<float>(i) * 0.1f, 0.2f, 2.0f};
        g.scale = aether_float3_t{0.03f, 0.03f, 0.03f};
        g.opacity = 0.8f;
        g.host_unit_id = (i < 2u) ? 1001u : 1002u;
        g.observation_count = static_cast<uint16_t>(3u + i);
        g.patch_priority = static_cast<uint16_t>(i < 2u ? 2u : 1u);
        g.capture_sequence = static_cast<uint32_t>(i + 1u);
        g.first_observed_frame_id = (i < 2u) ? 100u : 120u;
        g.first_observed_ms = (i < 2u) ? 1000 : 1200;
        g.flags = 0u;
        g.lod_level = 0u;
        g.binding_state = 1u;
        g.uncertainty = 0.2f;
        g.patch_id = (i < 2u) ? "p0" : "p1";
        for (int c = 0; c < 16; ++c) {
            g.sh_coeffs[c] = (c == 0) ? 0.5f : 0.2f;
        }
    }
}

int test_f1_c_api() {
    int failed = 0;

    std::vector<aether_scaffold_unit_t> units(2);
    units[0].unit_id = 1001u;
    units[0].v0 = 0u;
    units[0].v1 = 1u;
    units[0].v2 = 2u;
    units[0].area = 0.2f;
    units[0].normal = aether_float3_t{0.0f, 0.0f, 1.0f};
    units[1].unit_id = 1002u;
    units[1].v0 = 1u;
    units[1].v1 = 3u;
    units[1].v2 = 2u;
    units[1].area = 1.0f;
    units[1].normal = aether_float3_t{0.0f, 0.0f, 1.0f};

    std::vector<aether_scaffold_vertex_t> vertices(4);
    vertices[0].id = 0u; vertices[0].position = aether_float3_t{0.0f, 0.0f, 2.0f};
    vertices[1].id = 1u; vertices[1].position = aether_float3_t{1.0f, 0.0f, 2.0f};
    vertices[2].id = 2u; vertices[2].position = aether_float3_t{0.0f, 1.0f, 2.0f};
    vertices[3].id = 3u; vertices[3].position = aether_float3_t{1.0f, 1.0f, 2.0f};

    std::vector<aether_gaussian_t> gaussians;
    fill_test_gaussians(&gaussians);

    std::vector<aether_camera_trajectory_entry_t> trajectory(2);
    trajectory[0].frame_id = 100u;
    trajectory[0].position = aether_float3_t{-0.5f, 0.0f, 1.8f};
    trajectory[0].forward = aether_float3_t{0.5f, 0.0f, 1.0f};
    trajectory[0].up = aether_float3_t{0.0f, 1.0f, 0.0f};
    trajectory[0].timestamp_ms = 1000;
    trajectory[1].frame_id = 120u;
    trajectory[1].position = aether_float3_t{1.5f, 0.2f, 1.8f};
    trajectory[1].forward = aether_float3_t{-0.5f, 0.0f, 1.0f};
    trajectory[1].up = aether_float3_t{0.0f, 1.0f, 0.0f};
    trajectory[1].timestamp_ms = 1200;

    aether_f1_time_mirror_config_t cfg{};
    aether_f1_default_time_mirror_config(&cfg);
    cfg.start_offset_meters = 0.3f;
    cfg.min_flight_duration_s = 0.3f;
    cfg.max_flight_duration_s = 0.8f;
    cfg.appear_stagger_s = 0.015f;
    cfg.area_duration_power = 0.5f;
    cfg.opacity_ramp_ratio = 0.3f;
    cfg.sh_crossfade_start_ratio = 0.8f;

    // Allocate enough space for all possible fragments (one per unit max)
    int fragment_count = static_cast<int>(units.size()) * 2;
    std::vector<aether_f1_fragment_flight_t> fragments(static_cast<std::size_t>(fragment_count));
    int rc = aether_f1_build_fragment_queue(
        units.data(), static_cast<int>(units.size()),
        vertices.data(), static_cast<int>(vertices.size()),
        gaussians.data(), static_cast<int>(gaussians.size()),
        nullptr,
        trajectory.data(), static_cast<int>(trajectory.size()),
        &cfg,
        fragments.data(),
        &fragment_count);
    if (rc != 0) {
        std::fprintf(stderr, "F1 build queue failed: rc=%d count=%d\n", rc, fragment_count);
        failed++;
        return failed;
    }
    fragments.resize(static_cast<std::size_t>(fragment_count));
    if (fragments.size() >= 2 &&
        (fragments[0].priority_boost < fragments[1].priority_boost ||
         fragments[0].earliest_capture_sequence > fragments[1].earliest_capture_sequence)) {
        std::fprintf(stderr, "F1 fragment ordering metadata mismatch\n");
        failed++;
    }

    float total_time = 0.0f;
    for (const auto& f : fragments) {
        total_time = std::max(total_time, f.appear_offset_s + f.flight_duration_s);
    }

    std::vector<aether_gaussian_t> animated(gaussians.size());
    int animated_count = static_cast<int>(animated.size());
    aether_f1_animation_metrics_t metrics{};
    rc = aether_f1_animate_frame(
        gaussians.data(),
        static_cast<int>(gaussians.size()),
        fragments.data(),
        static_cast<int>(fragments.size()),
        nullptr,
        &cfg,
        total_time,
        total_time,
        animated.data(),
        &animated_count,
        &metrics);
    if (rc != 0) {
        std::fprintf(stderr, "F1 animate failed: rc=%d\n", rc);
        failed++;
        return failed;
    }
    for (std::size_t i = 0u; i < gaussians.size(); ++i) {
        if (!approx(animated[i].position.x, gaussians[i].position.x, 1e-4f) ||
            !approx(animated[i].position.y, gaussians[i].position.y, 1e-4f) ||
            !approx(animated[i].position.z, gaussians[i].position.z, 1e-4f)) {
            std::fprintf(stderr, "F1 final position mismatch at %zu\n", i);
            failed++;
            break;
        }
    }
    if (!approx(metrics.completion_ratio, 1.0f, 1e-4f)) {
        std::fprintf(stderr, "F1 completion ratio mismatch\n");
        failed++;
    }
    return failed;
}

int test_f3_c_api() {
    int failed = 0;

    std::vector<aether_gaussian_t> gaussians;
    fill_test_gaussians(&gaussians);

    std::vector<aether_f3_belief_record_t> beliefs(2);
    beliefs[0].unit_id = 1001u;
    beliefs[0].patch_id = "p0";
    beliefs[0].mass.occupied = 0.2;
    beliefs[0].mass.free_mass = 0.2;
    beliefs[0].mass.unknown = 0.6;
    beliefs[1].unit_id = 1002u;
    beliefs[1].patch_id = "p1";
    beliefs[1].mass.occupied = 0.85;
    beliefs[1].mass.free_mass = 0.1;
    beliefs[1].mass.unknown = 0.05;

    aether_f3_plan_config_t cfg{};
    aether_f3_default_plan_config(&cfg);
    cfg.preserve_threshold = 0.4;
    cfg.aggressive_threshold = 0.75;
    cfg.target_byte_budget = 0;
    cfg.min_observation_keep = 2;
    cfg.patch_priority_boost = 0.15f;
    cfg.preserve_quant_bits = 16;
    cfg.balanced_quant_bits = 12;
    cfg.aggressive_quant_bits = 8;

    int decision_count = static_cast<int>(gaussians.size());
    std::vector<aether_f3_gaussian_decision_t> decisions(static_cast<std::size_t>(decision_count));
    aether_f3_compression_plan_t plan{};
    int rc = aether_f3_plan_compression(
        gaussians.data(),
        static_cast<int>(gaussians.size()),
        beliefs.data(),
        static_cast<int>(beliefs.size()),
        nullptr,
        nullptr,
        &cfg,
        decisions.data(),
        &decision_count,
        &plan);
    if (rc != 0) {
        std::fprintf(stderr, "F3 plan failed: rc=%d\n", rc);
        failed++;
        return failed;
    }
    if (plan.kept_count <= 0 || plan.estimated_bytes <= 0) {
        std::fprintf(stderr, "F3 plan invalid\n");
        failed++;
    }
    return failed;
}

int test_f5_c_api() {
    int failed = 0;

    aether_f5_chain_t* chain = aether_f5_chain_create();
    if (chain == nullptr) {
        std::fprintf(stderr, "F5 chain create failed\n");
        return 1;
    }

    aether_gaussian_t g{};
    g.id = 33u;
    g.position = aether_float3_t{0.0f, 0.0f, 1.0f};
    g.scale = aether_float3_t{0.03f, 0.03f, 0.03f};
    g.opacity = 0.8f;
    g.host_unit_id = 1001u;
    g.capture_sequence = 1u;
    g.observation_count = 5u;
    g.patch_priority = 1u;

    aether_f5_patch_receipt_t receipt{};
    int rc = aether_f5_chain_append_patch(
        chain,
        &g, 1,
        nullptr, 0,
        nullptr, 0,
        nullptr, 0,
        1000.0,
        &receipt);
    if (rc != 0) {
        std::fprintf(stderr, "F5 append patch failed: rc=%d\n", rc);
        failed++;
    }
    if (receipt.version != 1u) {
        std::fprintf(stderr, "F5 receipt invalid\n");
        failed++;
    }

    uint64_t latest = 0;
    if (aether_f5_chain_latest_version(chain, &latest) != 0 || latest != 1u) {
        std::fprintf(stderr, "F5 latest version mismatch\n");
        failed++;
    }

    aether_f5_chain_destroy(chain);
    return failed;
}

int test_f6_c_api() {
    int failed = 0;

    std::vector<aether_gaussian_t> gaussians;
    fill_test_gaussians(&gaussians);

    aether_f6_config_t cfg{};
    aether_f6_default_config(&cfg);
    cfg.conflict_threshold = 0.1;
    cfg.release_ratio = 0.6;
    cfg.sustain_frames = 1;
    cfg.recover_frames = 2;
    aether_f6_rejector_t* rejector = aether_f6_create(&cfg);
    if (rejector == nullptr) {
        std::fprintf(stderr, "F6 rejector create failed\n");
        return 1;
    }

    std::vector<aether_f6_observation_pair_t> pairs(2);
    pairs[0].gaussian_id = gaussians[0].id;
    pairs[0].host_unit_id = gaussians[0].host_unit_id;
    pairs[0].predicted.occupied = 0.9;
    pairs[0].predicted.free_mass = 0.05;
    pairs[0].predicted.unknown = 0.05;
    pairs[0].observed.occupied = 0.05;
    pairs[0].observed.free_mass = 0.9;
    pairs[0].observed.unknown = 0.05;
    pairs[1] = pairs[0];
    pairs[1].gaussian_id = gaussians[1].id;

    aether_f6_frame_metrics_t metrics{};
    int rc = aether_f6_process_frame(
        rejector,
        pairs.data(),
        static_cast<int>(pairs.size()),
        gaussians.data(),
        static_cast<int>(gaussians.size()),
        &metrics);
    if (rc != 0) {
        std::fprintf(stderr, "F6 process frame failed: rc=%d\n", rc);
        failed++;
    }
    if (metrics.marked_dynamic_count <= 0) {
        std::fprintf(stderr, "F6 expected dynamic marking\n");
        failed++;
    }

    aether_f6_destroy(rejector);
    return failed;
}

int test_scheduler_c_api() {
    int failed = 0;
    aether_gpu_scheduler_t* scheduler = nullptr;
    aether_gpu_scheduler_config_t cfg{};
    cfg.total_frame_budget_ms = 16.6f;
    cfg.system_reserve_ms = 3.5f;
    cfg.capture_tracking_min_ms = 4.0f;
    cfg.capture_rendering_min_ms = 4.0f;
    cfg.capture_optimization_min_ms = 1.0f;
    cfg.finished_tracking_min_ms = 0.0f;
    cfg.finished_rendering_min_ms = 2.0f;
    cfg.finished_optimization_min_ms = 7.0f;
    if (aether_gpu_scheduler_create(&cfg, &scheduler) != 0 || scheduler == nullptr) {
        std::fprintf(stderr, "scheduler create failed\n");
        return 1;
    }

    aether_gpu_budget_t budget{};
    if (aether_gpu_scheduler_allocate_budget(scheduler, 0, &budget) != 0) {
        std::fprintf(stderr, "scheduler allocate capture budget failed\n");
        failed++;
    } else if (!approx(budget.flexible_pool_ms, 4.1f, 1e-4f)) {
        std::fprintf(stderr, "scheduler capture flexible pool mismatch\n");
        failed++;
    }

    aether_gpu_workload_t workload{};
    workload.tracking_demand_ms = 8.0f;
    workload.rendering_demand_ms = 7.0f;
    workload.optimization_demand_ms = 6.0f;
    aether_gpu_frame_result_t result{};
    if (aether_gpu_scheduler_execute_frame(scheduler, 0, &workload, &result) != 0) {
        std::fprintf(stderr, "scheduler execute frame failed\n");
        failed++;
    } else if (result.tracking_assigned_ms < result.rendering_assigned_ms) {
        std::fprintf(stderr, "scheduler capture priority mismatch\n");
        failed++;
    }

    aether_gpu_scheduler_destroy(scheduler);
    return failed;
}

}  // namespace

int main() {
    int failed = 0;
    failed += test_tsdf_api();
    failed += test_p6_mesh_stability_c_api();
    failed += test_p6_confidence_decay_c_api();
    failed += test_scan_interaction_kernels_c_api();
    failed += test_da3_depth_c_api();
    failed += test_pure_vision_runtime_c_api();
    failed += test_zero_fabrication_c_api();
    failed += test_geometry_ml_c_api();
    failed += test_patch_display_kernel_c_api();
    failed += test_visual_style_state_c_api();
    failed += test_style_state_batch_c_api();
    failed += test_capture_style_runtime_c_api();
    failed += test_geometry_utils_c_api();
    failed += test_wedge_geometry_c_api();
    failed += test_smart_smoother_c_api();
    failed += test_flip_animation_c_api();
    failed += test_flip_runtime_c_api();
    failed += test_ripple_c_api();
    failed += test_ripple_runtime_c_api();
    failed += test_pose_stabilizer_c_api();
    failed += test_erasure_c_api();
    failed += test_volume_controller_hysteresis_c_api();
    failed += test_pr1_admission_kernel_c_api();
    failed += test_pr1_capacity_state_c_api();
    failed += test_pr1_information_gain_c_api();
    failed += test_ds_mass_c_api();
    failed += test_admission_primitives_c_api();
    failed += test_sha_merkle_evidence_c_api();
    failed += test_coverage_estimator_c_api();
    failed += test_f1_c_api();
    failed += test_f3_c_api();
    failed += test_f5_c_api();
    failed += test_f6_c_api();
    failed += test_scheduler_c_api();
    return failed;
}
