cmake_minimum_required(VERSION 3.16)

project(aether3d_cpp_core VERSION 0.1.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(AETHER_BUILD_MINIMAL_WHITEBOX_TESTS "Build only the minimal whitebox native tests" OFF)

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

find_package(ZLIB REQUIRED)

set(AETHER_CORE_SOURCES
    src/tsdf_volume.cpp
    src/core/canonicalize.cpp
    src/core/numeric_guard.cpp
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

if(AETHER_BUILD_MINIMAL_WHITEBOX_TESTS)
    enable_testing()

    macro(aether_test test_name test_src)
        add_executable(${test_name} ${test_src})
        target_link_libraries(${test_name} PRIVATE aether3d_core)
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
