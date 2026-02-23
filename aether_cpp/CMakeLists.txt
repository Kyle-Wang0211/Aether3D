cmake_minimum_required(VERSION 3.16)

project(aether3d_cpp_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    add_compile_options(
        -ffp-contract=off
        -fno-fast-math
        -Wall
        -Wextra
        -Werror
        -fno-exceptions
        -fno-rtti
    )
endif()

# ===========================================================================
# Core library — all non-C-API source files
# ===========================================================================
add_library(aether3d_core STATIC
    src/tsdf_volume.cpp
    # core
    src/core/canonicalize.cpp
    src/core/numeric_guard.cpp
    # crypto
    src/crypto/sha256.cpp
    # memory
    src/memory/arena.cpp
    # merkle
    src/merkle/merkle_tree_hash.cpp
    src/merkle/merkle_tree.cpp
    src/merkle/inclusion_proof.cpp
    src/merkle/consistency_proof.cpp
    # evidence
    src/evidence/admission_controller.cpp
    src/evidence/coverage_estimator.cpp
    src/evidence/deterministic_json.cpp
    src/evidence/ds_mass_function.cpp
    src/evidence/patch_display_kernel.cpp
    src/evidence/pr1_admission_kernel.cpp
    src/evidence/pr1_information_gain.cpp
    src/evidence/replay_engine.cpp
    src/evidence/pr_math.cpp
    src/evidence/evidence_state_machine.cpp
    src/evidence/smart_anti_boost_smoother.cpp
    # innovation
    src/innovation/core_types.cpp
    src/innovation/f1_progressive_compression.cpp
    src/innovation/f1_time_mirror.cpp
    src/innovation/f2_scaffold_collision.cpp
    src/innovation/f3_evidence_constrained_compression.cpp
    src/innovation/f5_delta_patch_chain.cpp
    src/innovation/f6_conflict_dynamic_rejection.cpp
    src/innovation/f7_shaderml_decode.cpp
    src/innovation/f8_uncertainty_field.cpp
    src/innovation/f9_scene_passport_watermark.cpp
    src/innovation/scaffold_patch_map.cpp
    # quality
    src/quality/deterministic_triangulator.cpp
    src/quality/geometry_ml_fusion.cpp
    src/quality/image_metrics.cpp
    src/quality/motion_analyzer.cpp
    src/quality/photometric_checker.cpp
    src/quality/pure_vision_runtime.cpp
    src/quality/spatial_hash_adjacency.cpp
    src/quality/zero_fabrication_policy.cpp
    # render
    src/render/color_correction.cpp
    src/render/confidence_decay.cpp
    src/render/dgrut_renderer.cpp
    src/render/flip_animation.cpp
    src/render/flip_animation_gpu.cpp
    src/render/fracture_display_mesh.cpp
    src/render/frustum_culler.cpp
    src/render/meshlet_builder.cpp
    src/render/ripple_propagation.cpp
    src/render/screen_detail_selector.cpp
    src/render/shader_source.cpp
    src/render/tri_tet_splat_projector.cpp
    src/render/two_pass_culler.cpp
    src/render/wedge_geometry.cpp
    # scheduler
    src/scheduler/gpu_scheduler.cpp
    # trainer
    src/trainer/da3_depth_fuser.cpp
    src/trainer/noise_aware_trainer.cpp
    # tsdf
    src/tsdf/depth_filter.cpp
    src/tsdf/icp_registration.cpp
    src/tsdf/isotropic_remesher.cpp
    src/tsdf/loop_detector.cpp
    src/tsdf/marching_cubes.cpp
    src/tsdf/mesh_extraction_scheduler.cpp
    src/tsdf/mesh_fiedler.cpp
    src/tsdf/mesh_topology.cpp
    src/tsdf/pose_graph.cpp
    src/tsdf/pose_stabilizer.cpp
    src/tsdf/soft_eviction.cpp
    src/tsdf/spatial_hash_table.cpp
    src/tsdf/spatial_quantizer.cpp
    src/tsdf/thermal_engine.cpp
    src/tsdf/tri_tet_consistency.cpp
    src/tsdf/tri_tet_mapping.cpp
    src/tsdf/volume_controller.cpp
    # upload
    src/upload/erasure_coding.cpp
    src/upload/kalman_bandwidth.cpp
    # geo
    src/geo/altitude_engine.cpp
    src/geo/asc_cell.cpp
    src/geo/cross_temporal_gs.cpp
    src/geo/geo_cluster.cpp
    src/geo/geo_indexer.cpp
    src/geo/geo_privacy.cpp
    src/geo/haversine.cpp
    src/geo/map_globe_projection.cpp
    src/geo/map_label_sdf.cpp
    src/geo/map_renderer.cpp
    src/geo/map_terrain.cpp
    src/geo/map_tile_mesh.cpp
    src/geo/map_tile_source.cpp
    src/geo/rtree.cpp
    src/geo/sol_illumination.cpp
    src/geo/spoof_detector.cpp
    src/geo/temporal_cluster.cpp
    src/geo/temporal_index.cpp
)
target_include_directories(aether3d_core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# ===========================================================================
# C API library
# ===========================================================================
add_library(aether3d_c STATIC
    src/c_api.cpp
    src/geo_c_api.cpp
)
target_include_directories(aether3d_c
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)
target_link_libraries(aether3d_c
    PUBLIC
        aether3d_core
)
set_target_properties(aether3d_c PROPERTIES OUTPUT_NAME "aether3d_c")

# ===========================================================================
# Tests
# ===========================================================================
enable_testing()

# Helper macro: add test with standard link to aether3d_core
macro(aether_test test_name test_src)
    add_executable(${test_name} ${test_src})
    target_link_libraries(${test_name} PRIVATE aether3d_core)
    add_test(NAME ${test_name} COMMAND ${test_name})
endmacro()

# Helper macro: add test linked to aether3d_c (for C API tests)
macro(aether_c_test test_name test_src)
    add_executable(${test_name} ${test_src})
    target_link_libraries(${test_name} PRIVATE aether3d_c)
    add_test(NAME ${test_name} COMMAND ${test_name})
endmacro()

# -- Top-level tests --
aether_test(status_tests tests/status_tests.cpp)
aether_c_test(c_api_tests tests/c_api_tests.cpp)
aether_c_test(fixture_replay_tests tests/fixture_replay_tests.cpp)
target_compile_definitions(fixture_replay_tests PRIVATE AETHER_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# -- Core --
aether_test(canonicalize_test tests/core/canonicalize_test.cpp)

# -- Crypto --
aether_test(sha256_test tests/crypto/sha256_test.cpp)

# -- Memory --
aether_test(arena_test tests/memory/arena_test.cpp)

# -- Merkle --
aether_test(merkle_tree_hash_test tests/merkle/merkle_tree_hash_test.cpp)
aether_test(inclusion_proof_test tests/merkle/inclusion_proof_test.cpp)
aether_test(consistency_proof_test tests/merkle/consistency_proof_test.cpp)
aether_test(rfc9162_vectors_test tests/merkle/rfc9162_vectors_test.cpp)
target_compile_definitions(rfc9162_vectors_test PRIVATE AETHER_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# -- Evidence --
aether_test(admission_controller_test tests/evidence/admission_controller_test.cpp)
aether_test(coverage_estimator_test tests/evidence/coverage_estimator_test.cpp)
aether_test(deterministic_json_test tests/evidence/deterministic_json_test.cpp)
target_compile_definitions(deterministic_json_test PRIVATE AETHER_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")
aether_test(ds_mass_function_test tests/evidence/ds_mass_function_test.cpp)
aether_test(pr_math_test tests/evidence/pr_math_test.cpp)
aether_test(pr1_admission_kernel_test tests/evidence/pr1_admission_kernel_test.cpp)
aether_test(pr1_information_gain_test tests/evidence/pr1_information_gain_test.cpp)
aether_test(evidence_state_machine_test tests/evidence/evidence_state_machine_test.cpp)
aether_test(replay_engine_test tests/evidence/replay_engine_test.cpp)
target_compile_definitions(replay_engine_test PRIVATE AETHER_REPO_ROOT="${CMAKE_CURRENT_SOURCE_DIR}/..")

# -- Innovation --
aether_test(f1_progressive_compression_test tests/innovation/f1_progressive_compression_test.cpp)
aether_test(f1_time_mirror_test tests/innovation/f1_time_mirror_test.cpp)
aether_test(f2_scaffold_collision_test tests/innovation/f2_scaffold_collision_test.cpp)
aether_test(f3_evidence_constrained_compression_test tests/innovation/f3_evidence_constrained_compression_test.cpp)
aether_test(f5_delta_patch_chain_test tests/innovation/f5_delta_patch_chain_test.cpp)
aether_test(f6_conflict_dynamic_rejection_test tests/innovation/f6_conflict_dynamic_rejection_test.cpp)
aether_test(f7_shaderml_decode_test tests/innovation/f7_shaderml_decode_test.cpp)
aether_test(f8_uncertainty_field_test tests/innovation/f8_uncertainty_field_test.cpp)
aether_test(f9_scene_passport_watermark_test tests/innovation/f9_scene_passport_watermark_test.cpp)
aether_test(scaffold_patch_map_test tests/innovation/scaffold_patch_map_test.cpp)

# -- Quality --
aether_test(deterministic_triangulator_test tests/quality/deterministic_triangulator_test.cpp)
aether_test(image_metrics_test tests/quality/image_metrics_test.cpp)
aether_test(motion_analyzer_test tests/quality/motion_analyzer_test.cpp)
aether_test(photometric_checker_test tests/quality/photometric_checker_test.cpp)
aether_test(pure_vision_runtime_test tests/quality/pure_vision_runtime_test.cpp)
aether_test(spatial_hash_adjacency_test tests/quality/spatial_hash_adjacency_test.cpp)

# -- Render --
aether_test(dgrut_renderer_test tests/render/dgrut_renderer_test.cpp)
aether_test(flip_animation_gpu_test tests/render/flip_animation_gpu_test.cpp)
aether_test(meshlet_builder_test tests/render/meshlet_builder_test.cpp)
aether_test(test_confidence_decay tests/render/test_confidence_decay.cpp)
aether_test(test_flip_animation tests/render/test_flip_animation.cpp)
aether_test(test_fracture_display tests/render/test_fracture_display.cpp)
aether_test(test_frustum_culler tests/render/test_frustum_culler.cpp)
aether_test(test_ripple_propagation tests/render/test_ripple_propagation.cpp)
aether_test(test_screen_detail tests/render/test_screen_detail.cpp)
aether_test(test_shader_source tests/render/test_shader_source.cpp)
aether_test(tri_tet_splat_projector_test tests/render/tri_tet_splat_projector_test.cpp)
aether_test(two_pass_culler_test tests/render/two_pass_culler_test.cpp)
aether_c_test(gpu_resource_test tests/render/gpu_resource_test.cpp)

# -- Scheduler --
aether_test(gpu_scheduler_test tests/scheduler/gpu_scheduler_test.cpp)

# -- Trainer --
aether_test(da3_depth_fuser_test tests/trainer/da3_depth_fuser_test.cpp)
aether_test(noise_aware_trainer_test tests/trainer/noise_aware_trainer_test.cpp)

# -- TSDF --
aether_test(marching_cubes_test tests/tsdf/marching_cubes_test.cpp)
aether_test(spatial_hash_table_test tests/tsdf/spatial_hash_table_test.cpp)
aether_test(test_continuous_resolution tests/tsdf/test_continuous_resolution.cpp)
aether_test(test_isotropic_remesher tests/tsdf/test_isotropic_remesher.cpp)
aether_test(test_marching_cubes_normals tests/tsdf/test_marching_cubes_normals.cpp)
aether_test(test_mesh_extraction_scheduler tests/tsdf/test_mesh_extraction_scheduler.cpp)
aether_test(test_spatial_quantizer tests/tsdf/test_spatial_quantizer.cpp)
aether_test(test_mesh_topology tests/tsdf/test_mesh_topology.cpp)
aether_test(test_mesh_fiedler tests/tsdf/test_mesh_fiedler.cpp)
aether_test(test_surface_stability tests/tsdf/test_surface_stability.cpp)
aether_test(test_tri_tet_consistency tests/tsdf/test_tri_tet_consistency.cpp)
aether_test(spatial_quantizer_test tests/tsdf/spatial_quantizer_test.cpp)
aether_test(tri_tet_mapping_test tests/tsdf/tri_tet_mapping_test.cpp)

# -- Tuning --
aether_test(ab_config_tuner_test tests/tuning/ab_config_tuner_test.cpp)

# -- Upload --
aether_test(erasure_coding_test tests/upload/erasure_coding_test.cpp)
aether_test(kalman_bandwidth_test tests/upload/kalman_bandwidth_test.cpp)

# -- Geo --
aether_test(altitude_engine_test tests/geo/altitude_engine_test.cpp)
aether_test(asc_cell_test tests/geo/asc_cell_test.cpp)
aether_test(cross_temporal_gs_test tests/geo/cross_temporal_gs_test.cpp)
aether_test(geo_cluster_test tests/geo/geo_cluster_test.cpp)
aether_test(geo_indexer_test tests/geo/geo_indexer_test.cpp)
aether_test(geo_privacy_test tests/geo/geo_privacy_test.cpp)
aether_test(haversine_test tests/geo/haversine_test.cpp)
aether_test(map_globe_projection_test tests/geo/map_globe_projection_test.cpp)
aether_test(map_label_sdf_test tests/geo/map_label_sdf_test.cpp)
aether_test(map_renderer_test tests/geo/map_renderer_test.cpp)
aether_test(map_terrain_test tests/geo/map_terrain_test.cpp)
aether_test(map_tile_mesh_test tests/geo/map_tile_mesh_test.cpp)
aether_test(map_tile_source_test tests/geo/map_tile_source_test.cpp)
aether_test(rtree_test tests/geo/rtree_test.cpp)
aether_test(sol_illumination_test tests/geo/sol_illumination_test.cpp)
aether_test(spoof_detector_test tests/geo/spoof_detector_test.cpp)
aether_test(temporal_cluster_test tests/geo/temporal_cluster_test.cpp)
aether_test(temporal_index_test tests/geo/temporal_index_test.cpp)
aether_c_test(geo_c_api_test tests/geo/geo_c_api_test.cpp)
