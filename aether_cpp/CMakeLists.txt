cmake_minimum_required(VERSION 3.22)

project(aether3d_cpp_core VERSION 0.1.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(AETHER_BUILD_MINIMAL_WHITEBOX_TESTS "Build only the minimal whitebox native tests" OFF)
option(AETHER_ENABLE_DAWN "Build Dawn (WebGPU) integration + hello sample" ON)
option(AETHER_FFI_BUILD_STATIC "Build aether3d_ffi as static archive (set ON for iOS xcframework so codesign isn't required; default OFF builds .dylib for macOS Dart CLI smoke tests)" OFF)

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

# ═══════════════════════════════════════════════════════════════════════
# Phase 6.4a — WGSL bake (build-time .wgsl → .cpp constexpr)
# ═══════════════════════════════════════════════════════════════════════
# Each .wgsl file in shaders/wgsl/ is baked into a .cpp file with an
# `extern const char NAME_wgsl[]` definition. The .cpp files are linked
# into aether3d_core. Production binaries (DawnGPUDevice path) reference
# these baked sources via include/aether/shaders/wgsl_sources.h, with
# zero filesystem dependency at runtime.
#
# Smoke binaries in tools/ continue to read .wgsl from disk via
# register_wgsl_from_file() — they're development tools, not production,
# and disk reads make iteration faster (no rebake / relink).
#
# Re-bake trigger: .wgsl source change (CMake DEPENDS). Adding a new
# .wgsl requires (1) drop the file in shaders/wgsl/, (2) add extern in
# include/aether/shaders/wgsl_sources.h, (3) add register_wgsl_source
# call in dawn_gpu_device.cpp's register_baked_wgsl_into_device(),
# (4) cmake reconfigure. Step 2 missing = link error (loud failure).

set(AETHER_WGSL_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/shaders/wgsl)
set(AETHER_WGSL_GENERATED_DIR ${CMAKE_BINARY_DIR}/generated/aether/shaders)

file(MAKE_DIRECTORY ${AETHER_WGSL_GENERATED_DIR})

file(GLOB AETHER_WGSL_FILES "${AETHER_WGSL_SOURCE_DIR}/*.wgsl")
list(LENGTH AETHER_WGSL_FILES AETHER_WGSL_FILE_COUNT)
if(AETHER_WGSL_FILE_COUNT EQUAL 0)
    message(FATAL_ERROR "No .wgsl files found in ${AETHER_WGSL_SOURCE_DIR} — bake needs source files")
endif()
message(STATUS "Aether3D: baking ${AETHER_WGSL_FILE_COUNT} .wgsl files → "
        "${AETHER_WGSL_GENERATED_DIR}")

set(AETHER_WGSL_GENERATED_CPPS "")
foreach(wgsl ${AETHER_WGSL_FILES})
    get_filename_component(wgsl_name ${wgsl} NAME_WE)
    set(generated_cpp ${AETHER_WGSL_GENERATED_DIR}/${wgsl_name}_wgsl.cpp)
    add_custom_command(
        OUTPUT ${generated_cpp}
        COMMAND ${CMAKE_COMMAND}
            -DINPUT=${wgsl}
            -DOUTPUT=${generated_cpp}
            -DNAME=${wgsl_name}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/scripts/bake_one_wgsl.cmake
        DEPENDS ${wgsl} ${CMAKE_CURRENT_SOURCE_DIR}/scripts/bake_one_wgsl.cmake
        COMMENT "Baking WGSL: ${wgsl_name}.wgsl → ${wgsl_name}_wgsl.cpp"
        VERBATIM
    )
    list(APPEND AETHER_WGSL_GENERATED_CPPS ${generated_cpp})
endforeach()

# ALL target so the bake runs even if a clean build hasn't yet touched
# aether3d_core (e.g. a tools-only build still gets fresh WGSL for any
# header-only consumers).
add_custom_target(aether_bake_wgsl ALL DEPENDS ${AETHER_WGSL_GENERATED_CPPS})

add_library(aether3d_core STATIC ${AETHER_CORE_SOURCES} ${AETHER_WGSL_GENERATED_CPPS})
target_include_directories(aether3d_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(aether3d_core PUBLIC ZLIB::ZLIB)
target_compile_options(aether3d_core PRIVATE ${AETHER_STRICT_COMPILE_OPTIONS})
add_dependencies(aether3d_core aether_bake_wgsl)

# ─── Phase 6.2: Dawn backend source conditionally included ─────────────
# When AETHER_ENABLE_DAWN is ON, link the DawnGPUDevice C++ implementation
# into aether3d_core. Uses Dawn's raw C webgpu.h (NOT webgpu_cpp.h) so the
# strict -fno-exceptions / -fno-rtti flags stay in effect on this TU.
if(AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn)
    target_sources(aether3d_core PRIVATE src/render/dawn_gpu_device.cpp)
    target_compile_definitions(aether3d_core PRIVATE AETHER_ENABLE_DAWN=1)
    target_link_libraries(aether3d_core PUBLIC dawn::webgpu_dawn)
endif()

# ─── Phase 6.4b: GLB loader (cgltf + stb_image) ────────────────────────
# Vendored single-header libs in third_party/cgltf, third_party/stb.
# glb_loader.cpp does the IMPL define for both — must be exactly one TU
# in the build, so we make sure no other source file defines the impls.
if(AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn)
    target_sources(aether3d_core PRIVATE src/pocketworld/glb_loader.cpp)
    target_include_directories(aether3d_core PRIVATE
        third_party/cgltf
        third_party/stb)
    # cgltf is C99; under -Wall -Wextra it produces a few warnings (unused
    # static functions, missing-prototypes for internal helpers). Suppress
    # for that ONE source file so the rest of aether3d_core stays strict.
    set_source_files_properties(src/pocketworld/glb_loader.cpp PROPERTIES
        COMPILE_OPTIONS "-Wno-unused-function;-Wno-missing-prototypes;-Wno-double-promotion")
endif()

if(APPLE)
    target_link_libraries(aether3d_core PUBLIC
        "-framework Foundation"
        "-framework Metal"
        "-framework CoreML"
        "-framework CoreVideo"
        "-framework IOSurface"
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
        # cxx_std_20 inherited from top-level CMAKE_CXX_STANDARD; explicit
        # target_compile_features() breaks under iphonesimulator sysroot
        # (CMake compiler-feature probe returns empty) — see commit history.

        # Phase 6.0 (2026-04-26): iOS requires every executable to be an
        # .app bundle with a bundle identifier. Without these properties,
        # iOS build fails with "Bundle identifier is missing.
        # <target> doesn't have a bundle identifier." On macOS desktop /
        # CLI build, MACOSX_BUNDLE=FALSE keeps the executables as plain
        # binaries (which is what the existing P1.4/1.5/1.7 PPM workflow
        # expects). On iOS, MACOSX_BUNDLE=TRUE makes them .app bundles
        # under com.kyle.aether.<target>.
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            set_target_properties(${target} PROPERTIES
                MACOSX_BUNDLE TRUE
                XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.kyle.aether.${target}"
                XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "iPhone Developer"
                XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "26AH7V448L"
            )
        endif()
    endfunction()

    aether_dawn_hello_sample(aether_dawn_hello          tools/aether_dawn_hello.cpp)           # P1.4 adapter info
    aether_dawn_hello_sample(aether_dawn_hello_compute  tools/aether_dawn_hello_compute.cpp)   # P1.5 compute roundtrip
    aether_dawn_hello_sample(aether_dawn_hello_triangle tools/aether_dawn_hello_triangle.cpp)  # P1.7 graphics roundtrip (PPM out)

    # ─── Phase 6.3 / Plan B refinement — reusable Dawn kernel-smoke harness ─
    # Per-kernel smoke binaries validate Brush WGSL → naga_oil → Tint → Metal
    # works in isolation BEFORE DawnGPUDevice (6.2.H/I/J/K) wraps them.
    # Bug bisection range collapses by removing the wrapper layer from the
    # validation chain. See aether_cpp/tools/dawn_kernel_harness.h header.
    add_library(aether_dawn_kernel_harness STATIC tools/dawn_kernel_harness.cpp)
    target_include_directories(aether_dawn_kernel_harness PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/tools)
    target_link_libraries(aether_dawn_kernel_harness PUBLIC dawn::webgpu_dawn)

    function(aether_dawn_smoke_test target src)
        add_executable(${target} ${src})
        target_link_libraries(${target} PRIVATE aether_dawn_kernel_harness dawn::webgpu_dawn)
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            set_target_properties(${target} PROPERTIES
                MACOSX_BUNDLE TRUE
                XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.kyle.aether.${target}"
                XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "iPhone Developer"
                XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "26AH7V448L"
            )
        endif()
    endfunction()

    # ─── 6.3a viewer kernels ───
    aether_dawn_smoke_test(aether_dawn_splat_smoke_project_forward
                            tools/aether_dawn_splat_smoke_project_forward.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_project_visible
                            tools/aether_dawn_splat_smoke_project_visible.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_map_gaussian_to_intersects
                            tools/aether_dawn_splat_smoke_map_gaussian_to_intersects.cpp)
    # Step 4 v3: Aether3D-original splat_render.wgsl (vertex+fragment +
    # instanced quads). Final viewer kernel — replaces Brush rasterize.wgsl
    # for viewer flow. Brush rasterize* retained for training (Step 6).
    aether_dawn_smoke_test(aether_dawn_splat_smoke_render
                            tools/aether_dawn_splat_smoke_render.cpp)

    # ─── Step 5a: Brush 4-bit-per-pass radix sort (5 kernels) ───
    # Each smoke chains the prior kernels in the pipeline so the FINAL
    # smoke (sort_scatter) exercises the full 5-kernel chain end-to-end
    # with multiset / monotone / element-conservation verification.
    aether_dawn_smoke_test(aether_dawn_splat_smoke_sort_count
                            tools/aether_dawn_splat_smoke_sort_count.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_sort_reduce
                            tools/aether_dawn_splat_smoke_sort_reduce.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_sort_scan
                            tools/aether_dawn_splat_smoke_sort_scan.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_sort_scan_add
                            tools/aether_dawn_splat_smoke_sort_scan_add.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_sort_scatter
                            tools/aether_dawn_splat_smoke_sort_scatter.cpp)

    # ─── Step 5b: Brush 3-stage prefix-sum kernels ───
    # Used by training-side accumulation passes (gradient sums, hit counts).
    # Each smoke verifies one stage's invariant against a hand-crafted input.
    aether_dawn_smoke_test(aether_dawn_splat_smoke_prefix_sum_scan
                            tools/aether_dawn_splat_smoke_prefix_sum_scan.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_prefix_sum_scan_sums
                            tools/aether_dawn_splat_smoke_prefix_sum_scan_sums.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_prefix_sum_add_scanned_sums
                            tools/aether_dawn_splat_smoke_prefix_sum_add_scanned_sums.cpp)

    # ─── Step 6: Brush rasterize compute kernels (training path) ───
    # Phase 6 viewer uses splat_render.wgsl (vert+frag); Brush rasterize
    # is retained for Phase 7+ on-device training. Smokes prove the
    # compute path still functional on Dawn iOS Metal.
    aether_dawn_smoke_test(aether_dawn_splat_smoke_rasterize
                            tools/aether_dawn_splat_smoke_rasterize.cpp)
    aether_dawn_smoke_test(aether_dawn_splat_smoke_rasterize_backwards
                            tools/aether_dawn_splat_smoke_rasterize_backwards.cpp)

    # ─── Step 7: Brush project_backwards (last training kernel) ───
    aether_dawn_smoke_test(aether_dawn_splat_smoke_project_backwards
                            tools/aether_dawn_splat_smoke_project_backwards.cpp)

    # ─── 6.5 prelude: cross-validate Brush compute vs Aether3D vert+frag ───
    # Same input through both rasterizers; assert pixel diff ≤ 1 LSB.
    # Regression catcher for Brush re-pin / naga_oil drift / Tint optimizer.
    aether_dawn_smoke_test(aether_dawn_splat_smoke_cross_validate
                            tools/aether_dawn_splat_smoke_cross_validate.cpp)

    # ─── 6.2.G-K production-path smokes ───
    # These link against aether3d_core (production DawnGPUDevice path),
    # NOT the harness library. They migrate harness-validated kernels
    # through the GPUDevice virtual API to prove the wrapper path is
    # equivalent. Phase 6.4 integration code can model itself on these.
    function(aether_dawn_device_smoke target src)
        add_executable(${target} ${src})
        target_link_libraries(${target} PRIVATE aether3d_core)
        target_include_directories(${target} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tools)
        if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
            set_target_properties(${target} PROPERTIES
                MACOSX_BUNDLE TRUE
                XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.kyle.aether.${target}"
                XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "iPhone Developer"
                XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "26AH7V448L"
            )
        endif()
    endfunction()

    aether_dawn_device_smoke(aether_dawn_gpu_device_smoke
                              tools/aether_dawn_gpu_device_smoke.cpp)
    aether_dawn_device_smoke(aether_dawn_splat_smoke_project_forward_via_device
                              tools/aether_dawn_splat_smoke_project_forward_via_device.cpp)
    aether_dawn_device_smoke(aether_dawn_splat_smoke_render_via_device
                              tools/aether_dawn_splat_smoke_render_via_device.cpp)
    aether_dawn_device_smoke(aether_dawn_splat_smoke_cross_validate_via_device
                              tools/aether_dawn_splat_smoke_cross_validate_via_device.cpp)
    # Phase 6.4a Q1 verification — baked WGSL path bit-exact vs file path.
    aether_dawn_device_smoke(aether_dawn_baked_wgsl_smoke
                              tools/aether_dawn_baked_wgsl_smoke.cpp)

    # Phase 6.4b — DamagedHelmet.glb asset (KhronosGroup glTF-Sample-Models).
    # Downloaded once at configure time, reused across builds. Decision
    # pin 20: KhronosGroup standard test models. Source repo is MIT-
    # adjacent (CC0/CC-BY licensing per model — see Sample-Models LICENSE).
    set(AETHER_TEST_ASSETS_DIR ${CMAKE_BINARY_DIR}/test_assets)
    set(AETHER_DAMAGED_HELMET_PATH ${AETHER_TEST_ASSETS_DIR}/DamagedHelmet.glb)
    if(NOT EXISTS ${AETHER_DAMAGED_HELMET_PATH})
        file(MAKE_DIRECTORY ${AETHER_TEST_ASSETS_DIR})
        message(STATUS "Aether3D: downloading DamagedHelmet.glb test asset...")
        file(DOWNLOAD
            "https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/DamagedHelmet/glTF-Binary/DamagedHelmet.glb"
            ${AETHER_DAMAGED_HELMET_PATH}
            SHOW_PROGRESS
            STATUS dl_status
            EXPECTED_HASH SHA256=a1e3b04de97b11de564ce6e53b95f02954a297f0008183ac63a4f5974f6b32d8
        )
        list(GET dl_status 0 dl_code)
        # Hash mismatch is acceptable for now (KhronosGroup may re-issue
        # without notice); just warn rather than fail. Production would
        # vendor the asset under aether_cpp/test_assets/ with LFS or
        # explicit checked-in checksum, deferred to Phase 6.5+.
        if(NOT dl_code EQUAL 0)
            message(WARNING "DamagedHelmet.glb download failed: ${dl_status} — "
                "smoke will fail until manually placed at ${AETHER_DAMAGED_HELMET_PATH}")
        endif()
    endif()

    # Phase 6.4b smoke — exercise GLB loader against DamagedHelmet.
    if(EXISTS ${AETHER_DAMAGED_HELMET_PATH})
        aether_dawn_device_smoke(aether_glb_loader_smoke
                                 tools/aether_glb_loader_smoke.cpp)
    endif()

    # Phase 6.4b smoke — Filament-style PBR shader compile via Tint.
    aether_dawn_device_smoke(aether_mesh_render_compile_smoke
                             tools/aether_mesh_render_compile_smoke.cpp)

    if(APPLE)
        aether_dawn_device_smoke(aether_dawn_iosurface_rgba16f_smoke
                                 tools/aether_dawn_iosurface_rgba16f_smoke.mm)
    endif()

    # Phase 6.4a smoke (aether_splat_iosurface_renderer_smoke) was deleted
    # in the Phase 6.4 cleanup along with the legacy splat-only renderer
    # (Phase 6.4b stage 2 superseded it with scene_iosurface_renderer).
    # Per-frame visual coverage is now via the macOS PocketWorld app
    # itself; if the IOSurface bridge ever needs unit-level coverage
    # again, write it against scene_iosurface_renderer (with mesh=none)
    # instead of resurrecting the old smoke.
endif()

# ============================================================================
# Phase 3.3 C ABI smoke test (no Dawn dependency, just aether3d_core)
# ============================================================================
add_executable(aether_version_test tools/aether_version_test.cpp)
target_link_libraries(aether_version_test PRIVATE aether3d_core)
# cxx_std_20 inherited from top-level CMAKE_CXX_STANDARD.

add_executable(aether_render_policy_smoke
    tools/aether_render_policy_smoke.cpp
    src/pocketworld/render_policy.cpp)
target_include_directories(aether_render_policy_smoke PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_options(aether_render_policy_smoke PRIVATE ${AETHER_STRICT_COMPILE_OPTIONS})

# ============================================================================
# Phase 3.4: aether3d_ffi shared library — dart:ffi-loadable surface
#
# This is a thin .dylib (.so on Linux, .dll on Windows) containing only the
# public C ABI symbols meant for foreign-function interface consumption.
# Currently just version.cpp; future FFI exports get added here, NOT mixed
# into aether3d_core (which is an internal-implementation static lib).
#
# Linking strategy:
#   - PRIVATE link against aether3d_core when FFI functions need internals.
#   - For now, version.cpp has no dependencies, so we don't link core yet
#     (keeps the .dylib at kilobytes for the macOS Dart CLI smoke test).
# ============================================================================
set(AETHER_FFI_SOURCES
    src/core/version.cpp
    src/pocketworld/background_download.cpp
    src/pocketworld/render_policy.cpp
    src/pocketworld/training_checkpoint.cpp
)

# Phase 6.4b: PocketWorld scene IOSurface renderer (mesh PBR + splat
# overlay) with refcount-managed shared DawnGPUDevice singleton for
# memory pressure recovery. Phase 6.4 cleanup dropped the legacy splat-
# only renderer (scene_renderer covers the no-mesh case via the splat
# overlay pass alone). Only included when Dawn is available; impls are
# no-op otherwise so the FFI symbols still exist (link-time stability).
if(AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn)
    list(APPEND AETHER_FFI_SOURCES
        src/pocketworld/dawn_device_singleton.cpp
        src/pocketworld/scene_iosurface_renderer.cpp)
endif()

if(AETHER_FFI_BUILD_STATIC)
    add_library(aether3d_ffi STATIC ${AETHER_FFI_SOURCES})
else()
    add_library(aether3d_ffi SHARED ${AETHER_FFI_SOURCES})
endif()
target_include_directories(aether3d_ffi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
# Phase 6.4b: scene_iosurface_renderer needs DawnGPUDevice internals
# (the import_iosurface free function is in aether3d_core, plus the
# narrow internal:: accessors declared in src/render/dawn_gpu_device_internal.h).
if(AETHER_ENABLE_DAWN AND TARGET dawn::webgpu_dawn)
    target_link_libraries(aether3d_ffi PRIVATE aether3d_core)
    target_compile_definitions(aether3d_ffi PRIVATE AETHER_ENABLE_DAWN=1)
endif()
# cxx_std_20 inherited from top-level CMAKE_CXX_STANDARD.

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
