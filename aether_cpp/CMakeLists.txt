cmake_minimum_required(VERSION 3.22)

project(aether3d_cpp_core VERSION 0.1.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(AETHER_BUILD_MINIMAL_WHITEBOX_TESTS "Build only the minimal whitebox native tests" OFF)
option(AETHER_ENABLE_DAWN "Build Dawn (WebGPU) integration + hello sample" ON)

# Strict flags — applied per-target via target_compile_options below.
# Was previously add_compile_options(...) at directory scope, which would
# pollute third_party/dawn. Refactored 2026-04-25 for Dawn integration.
set(AETHER_STRICT_COMPILE_OPTIONS
    -ffp-contract=off
    -fno-fast-math
    -Wall
    -Wextra
    -Werror
    -fno-exceptions
    -fno-rtti
)

# ============================================================================
# Dawn (WebGPU) integration
# Submodule at third_party/dawn — see aether_cpp/PHASE3_BLOCKER.md for context
# ============================================================================
if(AETHER_ENABLE_DAWN AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dawn/CMakeLists.txt")
    set(DAWN_FETCH_DEPENDENCIES ON CACHE BOOL "" FORCE)
    set(DAWN_BUILD_SAMPLES OFF CACHE BOOL "" FORCE)
    set(DAWN_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    set(DAWN_BUILD_NODE_BINDINGS OFF CACHE BOOL "" FORCE)
    set(DAWN_BUILD_PROTOBUF OFF CACHE BOOL "" FORCE)
    set(DAWN_BUILD_FUZZERS OFF CACHE BOOL "" FORCE)
    set(DAWN_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
    set(DAWN_USE_GLFW OFF CACHE BOOL "" FORCE)
    set(TINT_BUILD_CMD_TOOLS OFF CACHE BOOL "" FORCE)
    set(TINT_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    add_subdirectory(third_party/dawn EXCLUDE_FROM_ALL)
endif()

find_package(ZLIB REQUIRED)

set(AETHER_CORE_SOURCES
    src/tsdf_volume.cpp
    src/core/canonicalize.cpp
    src/core/numeric_guard.cpp
    src/core/version.cpp
    src/crypto/sha256.cpp
    src/evidence/smart_anti_boost_smoother.cpp
    src/memory/arena.cpp
    src/render/shader_source.cpp
    src/trainer/da3_depth_fuser.cpp
    src/trainer/noise_aware_trainer.cpp
    src/tsdf/pose_stabilizer.cpp
    src/tsdf/spatial_hash_table.cpp
    src/splat/spz_decoder.cpp
    src/splat/splat_render_engine.cpp
    src/pipeline/streaming_pipeline.cpp
    src/pipeline/local_preview_runtime.cpp
    src/pipeline/local_preview_seeding.cpp
    src/pipeline/local_subject_first_capture_overlay.cpp
    src/pipeline/local_subject_first_export_snapshot.cpp
    src/pipeline/local_subject_first_fallback_seeding.cpp
    src/pipeline/local_subject_first_ingest.cpp
    src/pipeline/local_subject_first_refine.cpp
    src/pipeline/local_subject_first_training.cpp
    src/pipeline/runtime_tsdf_gaussian_augmentation.cpp
    src/pipeline/pipeline_coordinator.cpp
    src/pipeline/depth_inference_coreml.mm
    src/pipeline/coordinator_c_api.cpp
    src/pipeline/streaming_c_api.cpp
    src/thermal/thermal_predictor.cpp
    src/training/gaussian_training_engine.cpp
    src/render/metal_gpu_device.mm
    src/render/metal_c_api.mm
)

set(AETHER_C_API_SOURCES
    src/mobile_whitebox_c_api.cpp
    src/splat/splat_c_api.cpp
)

add_library(aether3d_core STATIC ${AETHER_CORE_SOURCES})
target_include_directories(aether3d_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(aether3d_core PUBLIC ZLIB::ZLIB)
target_compile_options(aether3d_core PRIVATE ${AETHER_STRICT_COMPILE_OPTIONS})

if(APPLE)
    target_link_libraries(aether3d_core PUBLIC
        "-framework Foundation"
        "-framework Metal"
        "-framework CoreML"
    )
    set_source_files_properties(
        src/pipeline/depth_inference_coreml.mm
        src/render/metal_gpu_device.mm
        src/render/metal_c_api.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
    )
endif()

add_library(aether3d_c STATIC ${AETHER_C_API_SOURCES})
target_include_directories(aether3d_c PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(aether3d_c PUBLIC aether3d_core ZLIB::ZLIB)
target_compile_options(aether3d_c PRIVATE ${AETHER_STRICT_COMPILE_OPTIONS})

# ============================================================================
# Dawn hello samples (Phase 1.4 / 1.5 / 1.7): print GPU info, compute, render
#
# Each hello is a single-translation-unit smoke test for one Dawn feature
# layer. They're intentionally self-contained (no shared headers) so a
# failing hello points at exactly one layer.
#
# Note: these targets do NOT inherit AETHER_STRICT_COMPILE_OPTIONS. Dawn's
# webgpu_cpp.h uses patterns that conflict with -fno-exceptions / -fno-rtti.
# ============================================================================
if(AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn)
    function(aether_dawn_hello_sample target src)
        add_executable(${target} ${src})
        target_link_libraries(${target} PRIVATE dawn::webgpu_dawn)
        target_compile_features(${target} PRIVATE cxx_std_20)
    endfunction()

    aether_dawn_hello_sample(aether_dawn_hello          tools/aether_dawn_hello.cpp)           # P1.4 adapter info
    aether_dawn_hello_sample(aether_dawn_hello_compute  tools/aether_dawn_hello_compute.cpp)   # P1.5 compute roundtrip
    aether_dawn_hello_sample(aether_dawn_hello_triangle tools/aether_dawn_hello_triangle.cpp)  # P1.7 graphics roundtrip (PPM out)
endif()

# ============================================================================
# Phase 3.3 C ABI smoke test (no Dawn dependency, just aether3d_core)
# ============================================================================
add_executable(aether_version_test tools/aether_version_test.cpp)
target_link_libraries(aether_version_test PRIVATE aether3d_core)
target_compile_features(aether_version_test PRIVATE cxx_std_20)

if(AETHER_BUILD_MINIMAL_WHITEBOX_TESTS)
    enable_testing()

    macro(aether_test test_name test_src)
        add_executable(${test_name} ${test_src})
        target_link_libraries(${test_name} PRIVATE aether3d_core)
        target_compile_options(${test_name} PRIVATE ${AETHER_STRICT_COMPILE_OPTIONS})
        add_test(NAME ${test_name} COMMAND ${test_name})
    endmacro()

    aether_test(status_tests tests/status_tests.cpp)
    aether_test(canonicalize_test tests/core/canonicalize_test.cpp)
    aether_test(sha256_test tests/crypto/sha256_test.cpp)
    aether_test(arena_test tests/memory/arena_test.cpp)
    aether_test(thermal_predictor_test tests/thermal/thermal_predictor_test.cpp)
    aether_test(da3_depth_fuser_test tests/trainer/da3_depth_fuser_test.cpp)
    aether_test(noise_aware_trainer_test tests/trainer/noise_aware_trainer_test.cpp)
    aether_test(spatial_hash_table_test tests/tsdf/spatial_hash_table_test.cpp)
endif()
