cmake_minimum_required(VERSION 3.22)
project(glomap_core LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(V    ${CMAKE_CURRENT_SOURCE_DIR})
set(COLMAP  ${V}/colmap-src)
set(GLOMAP  ${V}/glomap-src)
set(POSELIB ${V}/poselib-src)
set(AT   ${V}/..)                      # aether_cpp/third_party
set(CERES   ${AT}/ceres)
set(CERESB  ${AT}/ceres-build-ios)
set(EIGEN   ${AT}/eigen-install/include/eigen3)
set(GLOG    ${AT}/glog-install/include)

# ---- colmap subset (global-mapper math only) ----
file(GLOB COLMAP_SRC
  ${COLMAP}/colmap/util/*.cc
  ${COLMAP}/colmap/math/*.cc
  ${COLMAP}/colmap/geometry/*.cc
  ${COLMAP}/colmap/sensor/*.cc
  ${COLMAP}/colmap/scene/*.cc
  ${COLMAP}/colmap/estimators/*.cc
  ${COLMAP}/colmap/estimators/solvers/*.cc   # [MIGRATION 4.0.4] NEW: minimal-solver impls
  ${COLMAP}/colmap/optim/*.cc)
# [MIGRATION 4.0.4] upstream now ships *_test.cc + *_matchers files inline in these dirs
# (gmock-dependent); the glob would compile them. Drop all test TUs (same as GLOMAP/POSELIB).
list(FILTER COLMAP_SRC EXCLUDE REGEX "_test\\.cc$")
# excludes (explicit paths). KEEP scene/database.cc + database_sqlite.cc (sqlite3 db-input path).
set(COLMAP_EXCLUDE
  ${COLMAP}/colmap/sensor/bitmap.cc            # FreeImage IO
  ${COLMAP}/colmap/sensor/database.cc          # CameraDatabase (camera specs), unused
  ${COLMAP}/colmap/math/graph_cut.cc           # boost::graph + metis
  ${COLMAP}/colmap/estimators/coordinate_frame.cc  # pulls FreeImage via image/line
  ${COLMAP}/colmap/scene/synthetic.cc          # FreeImage + test data gen
  ${COLMAP}/colmap/scene/scene_clustering.cc   # graph_cut
  ${COLMAP}/colmap/util/cuda.cc
  ${COLMAP}/colmap/util/cudacc.cc
  ${COLMAP}/colmap/util/gtest_main.cc          # test runner (needs gmock)
  ${COLMAP}/colmap/util/testing.cc             # test helpers
  # [MIGRATION 4.0.4] COLMAP 4.0 added a native global-SfM module in estimators/.
  # rotation_averaging_impl.cc #includes <Eigen/CholmodSupport> (SuiteSparse/GPL, no
  # cholmod.h here). It is reached ONLY by sfm/global_mapper.cc, which is NOT in our
  # explicit sfm/ source list (we vendor incremental SfM only). colmap_bench uses the
  # incremental pipeline, so this TU is dead for our build -> exclude (matches 3.14's
  # CHOLMOD-stripped iOS vendoring).
  ${COLMAP}/colmap/estimators/rotation_averaging_impl.cc)
list(REMOVE_ITEM COLMAP_SRC ${COLMAP_EXCLUDE})
# feature/types.cc: defines FeatureKeypoint (needed by scene/database); clean (no FreeImage)
list(APPEND COLMAP_SRC ${COLMAP}/colmap/feature/types.cc)
# DSP-SIFT on-device extraction: VLFeat (CPU covariant SIFT) + feature/sift.cc.
# GPU/SiftGPU stays #if-guarded out (COLMAP_GPU_ENABLED undefined). x86 SIMD .c excluded.
file(GLOB VLFEAT_SRC ${COLMAP}/thirdparty/VLFeat/*.c)
list(FILTER VLFEAT_SRC EXCLUDE REGEX "(imopv_sse2|mathop_sse2|mathop_avx)\\.c$")
list(APPEND COLMAP_SRC ${VLFEAT_SRC}
  ${COLMAP}/colmap/feature/sift.cc
  ${COLMAP}/colmap/feature/extractor.cc
  ${COLMAP}/colmap/feature/matcher.cc   # FeatureMatchingOptions + FeatureMatcher base (CPU match)
  ${COLMAP}/colmap/feature/utils.cc)
# colmap INCREMENTAL SfM (for colmap_bench): sfm/ + incremental controllers (clean, no FreeImage)
list(APPEND COLMAP_SRC
  ${COLMAP}/colmap/sfm/incremental_mapper.cc
  ${COLMAP}/colmap/sfm/incremental_mapper_impl.cc
  ${COLMAP}/colmap/sfm/incremental_triangulator.cc
  ${COLMAP}/colmap/sfm/observation_manager.cc
  ${COLMAP}/colmap/controllers/incremental_pipeline.cc
  ${COLMAP}/colmap/controllers/bundle_adjustment.cc)
# NOTE: COLMAP's exhaustive/spatial feature matcher + retrieval (feature_matching*,
# matcher_cache, pairing, retrieval/*) is DELIBERATELY NOT here — it drags in FAISS
# + OpenMP (<omp.h>), which the iOS toolchain lacks, and would break the device
# glomap_core build. It exists ONLY for the HOST colmap_bench --match prototype and
# is appended to COLMAP_ONLY_SRC below. Production streaming SfM uses its OWN GPU
# matcher (aether_sfm_c.cc); the global-BA double-wall fix needs no re-matching.
# iOS stubs (Bitmap without FreeImage)
list(APPEND COLMAP_SRC ${V}/stubs/colmap_ios_stubs.cc)
# threaded DSP-SIFT extractor — MUST live in glomap_core so it compiles with the
# SAME flags (esp. -ffast-math from the iOS toolchain) as colmap/feature/sift.cc;
# otherwise the cloned keypoint/descriptor FP arithmetic diverges -> not bit-identical.
list(APPEND COLMAP_SRC ${V}/bench/aether_threaded_extract.cc)

# [membench] compile the C ABI (aether_sfm_run/create/finalize) + DSP-SIFT into
# glomap_core for the iOS lib build (BUILD_BENCH off -> host bench exes not built,
# so no duplicate symbols). Lets a harness link only glomap_core+ceres+glog.
if(NOT BUILD_BENCH)
  list(APPEND COLMAP_SRC ${V}/bench/aether_sfm_c.cc ${V}/bench/dsp_sift_c.cc)
endif()

# [MIGRATION 4.0.4 / STEP 5] GLOMAP DROPPED from glomap_core. Production iOS runs
# colmap INCREMENTAL SfM only (see aether_sfm_c.cc); GLOMAP's global mapper is
# dead weight on device (device-infeasible per e7ef7cf8) and is the only piece
# still on the 3.14 API. glomap-src/ is left in the tree but no longer compiled.

# ---- PoseLib (Eigen-only) ----
file(GLOB_RECURSE POSELIB_SRC ${POSELIB}/PoseLib/*.cc ${POSELIB}/PoseLib/*.cpp)
list(FILTER POSELIB_SRC EXCLUDE REGEX "_test")

add_library(glomap_core STATIC ${COLMAP_SRC} ${POSELIB_SRC})

target_include_directories(glomap_core PUBLIC
  ${COLMAP} ${POSELIB} ${V}/stubs
  ${V}/../../include                    # [membench] aether_sfm_c.h / dsp_sift_c.h
  ${GLOG}                               # real glog (BSD-3), not miniglog
  ${CERES}/include ${CERESB}/include ${CERES}/config
  ${EIGEN}
  /opt/homebrew/include)                # boost headers (header-only: preprocessor/predef/algorithm/graph)

target_compile_definitions(glomap_core PRIVATE
  EIGEN_MPL2_ONLY
  GLOG_USE_GLOG_EXPORT
  GLOG_NO_ABBREVIATED_SEVERITIES
  GLOG_VERSION_MAJOR=0                 # glog 0.7.1 omits these; colmap logging.h
  GLOG_VERSION_MINOR=7                 # branches on them -> tell it we're on 0.7
  GLOMAP_CUDA_DISABLED
  VL_DISABLE_SSE2 VL_DISABLE_AVX)      # VLFeat: arm64 has no x86 SIMD
  # NOTE: COLMAP_CUDA_ENABLED / COLMAP_GUI_ENABLED / COLMAP_DOWNLOAD_ENABLED / COLMAP_CHOLMOD_ENABLED
  # all intentionally UNDEFINED -> optional features compile out.

target_compile_options(glomap_core PRIVATE -w)   # silence warnings during bring-up

# [MIGRATION 4.0.4] colmap-only static lib for colmap_bench_exe. The 3.14->4.0.4
# colmap migration is independent of glomap-src / poselib-src / the DSP-SIFT threaded
# extractor, which are STILL 3.14-API (glomap-src uses CamFromWorld().rotation; the
# extractor uses the 3.14 VLFeat covdet API, whereas 4.0.4 vendored a different VLFeat).
# colmap_bench reads a prebuilt database and runs incremental SfM only — it links ZERO
# glomap/VLFeat/extractor symbols. Building a colmap-only lib lets colmap_bench_exe link
# clean on 4.0.4 without dragging in those un-migrated 3.14 TUs. glomap_core is left
# intact for glomap_bench_exe (out of scope for this migration step).
set(COLMAP_ONLY_SRC ${COLMAP_SRC})
list(REMOVE_ITEM COLMAP_ONLY_SRC ${V}/bench/aether_threaded_extract.cc)
# [AETHER] HOST-ONLY exhaustive/spatial matcher + retrieval for the colmap_bench
# --match prototype (needs FAISS + OpenMP; see the note in COLMAP_SRC above). Kept
# out of the iOS glomap_core; colmap_only already adds libomp/faiss include dirs.
list(APPEND COLMAP_ONLY_SRC
  ${COLMAP}/colmap/controllers/feature_matching.cc
  ${COLMAP}/colmap/controllers/feature_matching_utils.cc
  ${COLMAP}/colmap/controllers/matcher_cache.cc
  ${COLMAP}/colmap/controllers/pairing.cc
  ${COLMAP}/colmap/retrieval/resources.cc
  ${COLMAP}/colmap/retrieval/visual_index.cc
  ${COLMAP}/colmap/retrieval/geometry.cc
  ${COLMAP}/colmap/retrieval/vote_and_verify.cc)
# [MIGRATION 4.0.4] COLMAP 4.0 now calls PoseLib minimal solvers directly (via
# estimators/solvers/poselib_utils.cc + the solver wrappers) -> colmap depends on
# poselib::p3p / gp3p / p4pf / Camera. PoseLib is Eigen-only and compiles clean, so
# bundle it into colmap_only too (it was already in glomap_core).
add_library(colmap_only STATIC ${COLMAP_ONLY_SRC} ${POSELIB_SRC})
target_include_directories(colmap_only PUBLIC
  ${COLMAP} ${POSELIB} ${V}/stubs
  ${GLOG}
  ${CERES}/include ${CERESB}/include ${CERES}/config
  ${EIGEN}
  /opt/homebrew/opt/libomp/include   # [AETHER] pairing.cc needs omp.h (host --match)
  /opt/homebrew/include/faiss             # [AETHER] pairing.cc SpatialPairGenerator
  /opt/homebrew/include)
target_compile_definitions(colmap_only PRIVATE
  EIGEN_MPL2_ONLY
  GLOG_USE_GLOG_EXPORT
  GLOG_NO_ABBREVIATED_SEVERITIES
  GLOG_VERSION_MAJOR=0
  GLOG_VERSION_MINOR=7
  GLOMAP_CUDA_DISABLED
  VL_DISABLE_SSE2 VL_DISABLE_AVX)
target_compile_options(colmap_only PRIVATE -w)

# ---- benchmark executable (link test + standalone run) ----
option(BUILD_BENCH "Build glomap_bench executable" ON)
if(BUILD_BENCH)
  find_library(ACCELERATE_FW Accelerate)
  # [MIGRATION 4.0.4 / STEP 5] glomap_bench_exe DROPPED: it is the only consumer of
  # GLOMAP's GlobalMapper / colmap_converter symbols, which were removed from
  # glomap_core when GLOMAP was dropped. Its bench/glomap_bench.cc is now dead.

  # desktop correctness gate for the threaded extractor (bit-identical check).
  # Extraction-only path: needs glog (host, brew 0.7.1 == iOS glog 0.7 ABI) but
  # NOT ceres (no BA pulled from glomap_core for the selfcheck). HOST build only.
  add_executable(extract_selfcheck_exe bench/extract_selfcheck.cc
    bench/dsp_sift_c.cc)  # aether_threaded_extract.cc is in glomap_core
  target_include_directories(extract_selfcheck_exe PRIVATE ${V}/stubs)
  target_compile_definitions(extract_selfcheck_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7)
  target_compile_options(extract_selfcheck_exe PRIVATE -w)
  target_link_libraries(extract_selfcheck_exe PRIVATE
    glomap_core
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})

  # ─── GPU DSP-SIFT M1 Stage C scope probe: affine patch-warp octave usage ───
  # affine_octave_probe_exe answers whether octave-0 affine-shape estimation can
  # run with ONLY the octave-0 GSS resident. No Dawn — pure CPU VLFeat. HOST only.
  add_executable(affine_octave_probe_exe bench/affine_octave_probe.cc)
  target_include_directories(affine_octave_probe_exe PRIVATE
    ${V}/stubs ${AT}/stb ${COLMAP}/thirdparty/VLFeat)
  target_compile_definitions(affine_octave_probe_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    VL_DISABLE_SSE2 VL_DISABLE_AVX)
  target_compile_options(affine_octave_probe_exe PRIVATE -w)
  target_link_libraries(affine_octave_probe_exe PRIVATE
    glomap_core
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})

  # parameterized incremental-SfM bench (HOST ceres 2.2.0 + glog) — per-frame
  # registration cost curve + reproj for the <=2s@frame-300 SLA lever sweeps.
  # BA option fields via argv -> run many configs in parallel on a read-only db.
  add_executable(colmap_bench_exe bench/colmap_bench.cc)
  target_include_directories(colmap_bench_exe PRIVATE ${V}/stubs)
  target_compile_definitions(colmap_bench_exe PRIVATE
    COLMAP_BENCH_MAIN EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7)
  target_compile_options(colmap_bench_exe PRIVATE -w)
  target_link_libraries(colmap_bench_exe PRIVATE
    colmap_only                          # [MIGRATION 4.0.4] colmap-only (no glomap/VLFeat)
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    /opt/homebrew/opt/libomp/lib/libomp.dylib   # [AETHER] pairing.cc omp symbols
    /opt/homebrew/lib/libfaiss.dylib            # [AETHER] pairing.cc FAISS symbols
    "-lsqlite3"
    ${ACCELERATE_FW})

  # ─── ARKit-pose-primed BA fixture (validate streaming local-BA off-device) ───
  add_executable(arkit_ba_bench_exe bench/arkit_ba_bench.cc)
  target_include_directories(arkit_ba_bench_exe PRIVATE ${V}/stubs)
  target_compile_definitions(arkit_ba_bench_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7)
  target_compile_options(arkit_ba_bench_exe PRIVATE -w)
  target_link_libraries(arkit_ba_bench_exe PRIVATE
    colmap_only
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})

  # ─── GPU DSP-SIFT M0: GSS pyramid parity gate (GPU Dawn vs CPU VLFeat) ───
  # gss_parity_exe builds the GPU GSS pyramid (tools/sift_pyramid_dawn) and the
  # CPU VLFeat reference with the identical covdet-DOG geometry, then compares
  # every level (max-rel <= 1e-3, RMS <= 2e-4). HOST build only.
  #
  # This standalone glomap project does NOT configure Dawn (that lives in the
  # top-level aether_cpp build). We link the PREBUILT Dawn artifacts from there:
  #   - libaether_dawn_kernel_harness.a  (the harness static lib)
  #   - libwebgpu_dawn.a                 (monolithic, self-contained Dawn+Tint)
  # plus the Dawn include dirs + the macOS frameworks Dawn's Metal backend needs.
  # Override AETHER_HOST_BUILD_DIR if the host build lives elsewhere.
  set(AETHER_HOST_BUILD_DIR "${AT}/../build" CACHE PATH
      "Top-level aether_cpp host build dir (provides prebuilt Dawn + harness)")
  set(_DAWN_HARNESS_LIB "${AETHER_HOST_BUILD_DIR}/libaether_dawn_kernel_harness.a")
  set(_WEBGPU_DAWN_LIB  "${AETHER_HOST_BUILD_DIR}/third_party/dawn/src/dawn/native/libwebgpu_dawn.a")
  set(_DAWN_INC_STATIC  "${AT}/dawn/include")
  set(_DAWN_INC_GEN     "${AETHER_HOST_BUILD_DIR}/third_party/dawn/gen/include")

  if(EXISTS "${_DAWN_HARNESS_LIB}" AND EXISTS "${_WEBGPU_DAWN_LIB}")
    add_executable(gss_parity_exe
      bench/gss_parity.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    # webgpu_cpp.h needs C++20 (the rest of glomap_core is C++17; scope it here).
    set_target_properties(gss_parity_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gss_parity_exe PRIVATE
      ${V}/stubs
      ${AT}/../tools                       # sift_pyramid_dawn.h + dawn_kernel_harness.h
      ${AT}/stb                            # stb_image.h
      ${COLMAP}/thirdparty/VLFeat          # scalespace.h (CPU reference)
      ${_DAWN_INC_STATIC}
      ${_DAWN_INC_GEN})
    target_compile_definitions(gss_parity_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      VL_DISABLE_SSE2 VL_DISABLE_AVX
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gss_parity_exe PRIVATE -w)
    find_library(COCOA_FW Cocoa)
    find_library(IOKIT_FW IOKit)
    find_library(IOSURFACE_FW IOSurface)
    find_library(METAL_FW Metal)
    find_library(QUARTZCORE_FW QuartzCore)
    find_library(FOUNDATION_FW Foundation)
    find_library(COREFOUNDATION_FW CoreFoundation)
    target_link_libraries(gss_parity_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M1 Stage A: dispatch_indirect harness self-test ───
    # indirect_selftest_exe exercises DawnKernelHarness::dispatch_indirect +
    # alloc_indirect_args via a trivial atomic-counter → indirect-args →
    # indirect-consume pipeline (the keypoint-sparse-collection plumbing,
    # GPU_DSP_SIFT_PLAN_AFFINE_OFF.md §3-①). No glomap_core / VLFeat needed —
    # pure harness + Dawn. HOST build only, same EXISTS gate as gss_parity_exe.
    add_executable(indirect_selftest_exe
      bench/indirect_selftest.cc)
    set_target_properties(indirect_selftest_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(indirect_selftest_exe PRIVATE
      ${AT}/../tools                       # dawn_kernel_harness.h
      ${_DAWN_INC_STATIC}
      ${_DAWN_INC_GEN})
    target_compile_definitions(indirect_selftest_exe PRIVATE
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(indirect_selftest_exe PRIVATE -w)
    target_link_libraries(indirect_selftest_exe PRIVATE
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M1 Stage B: octave-0 keypoint detect parity gate ───
    # dog_detect_parity_exe runs the GPU S2 DoG + S3 extrema/refine/cull pass
    # (sift_dog_detect.wgsl) and compares octave-0 keypoints against the CPU
    # VLFeat covdet (first_octave=0, PRE-affine, o==0 slice). Needs glomap_core
    # for the VLFeat covdet symbols. Same EXISTS gate as gss_parity_exe.
    add_executable(dog_detect_parity_exe
      bench/dog_detect_parity.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(dog_detect_parity_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(dog_detect_parity_exe PRIVATE
      ${V}/stubs
      ${AT}/../tools
      ${AT}/stb
      ${COLMAP}/thirdparty/VLFeat
      ${_DAWN_INC_STATIC}
      ${_DAWN_INC_GEN})
    target_compile_definitions(dog_detect_parity_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      VL_DISABLE_SSE2 VL_DISABLE_AVX
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(dog_detect_parity_exe PRIVATE -w)
    target_link_libraries(dog_detect_parity_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M1 Stage C: affine-shape ellipse parity gate ───
    # affine_shape_parity_exe feeds identical pre-affine frames to the GPU affine
    # kernel (sift_affine_shape.wgsl, cross-octave warp via pack_levels) and CPU
    # VLFeat (vl_covdet_extract_affine_shape_for_frame), comparing output ellipses.
    add_executable(affine_shape_parity_exe
      bench/affine_shape_parity.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(affine_shape_parity_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(affine_shape_parity_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb ${COLMAP}/thirdparty/VLFeat
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(affine_shape_parity_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      VL_DISABLE_SSE2 VL_DISABLE_AVX
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(affine_shape_parity_exe PRIVATE -w)
    target_link_libraries(affine_shape_parity_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M1 Stage D: dominant-orientation parity gate ───
    # orientation_parity_exe feeds identical affine-adapted frames to the GPU
    # orientation kernel (sift_orientation.wgsl) and CPU VLFeat
    # (vl_covdet_extract_orientations_for_frame), comparing orientation angles.
    add_executable(orientation_parity_exe
      bench/orientation_parity.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(orientation_parity_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(orientation_parity_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb ${COLMAP}/thirdparty/VLFeat
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(orientation_parity_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      VL_DISABLE_SSE2 VL_DISABLE_AVX
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(orientation_parity_exe PRIVATE -w)
    target_link_libraries(orientation_parity_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M1 Stage E: DSP descriptor parity gate (M1 FINAL) ───
    # dsp_descriptor_parity_exe feeds identical oriented frames to the GPU
    # descriptor kernel (sift_dsp_descriptor.wgsl) and the CPU three-stage loop,
    # then compares RootSIFT descriptors by cosine + match-recall (reuses
    # aether_sift_match from dsp_sift_c.cc).
    add_executable(dsp_descriptor_parity_exe
      bench/dsp_descriptor_parity.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(dsp_descriptor_parity_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(dsp_descriptor_parity_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb ${COLMAP}/thirdparty/VLFeat
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(dsp_descriptor_parity_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      VL_DISABLE_SSE2 VL_DISABLE_AVX
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(dsp_descriptor_parity_exe PRIVATE -w)
    target_link_libraries(dsp_descriptor_parity_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M3-①: clamp-before-descriptor bit-faithfulness gate ───
    # clamp_parity_exe verifies the descriptor-cost optimization (clamp the 1→K
    # oriented set to ≤max_features BEFORE the descriptor stage) leaves every
    # surviving keypoint's descriptor BYTE-IDENTICAL. No glomap_core needed.
    add_executable(clamp_parity_exe
      bench/clamp_parity.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(clamp_parity_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(clamp_parity_exe PRIVATE
      ${AT}/../tools ${AT}/stb ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(clamp_parity_exe PRIVATE
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(clamp_parity_exe PRIVATE -w)
    target_link_libraries(clamp_parity_exe PRIVATE
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M2: full-pipeline orchestrator + C ABI + e2e smoke ───
    # gpu_extract_e2e_exe runs the WHOLE GPU chain connected (SiftExtractDawn)
    # via aether_dsp_sift_extract_gpu, and compares against the CPU _threaded
    # baseline (dsp_sift_c.cc) by descriptor match-recall + count. NOTE: NO
    # VLFeat include dir here — dsp_sift_c.cc + the Dawn TUs coexist only when
    # VLFeat's float.h does not shadow the system <cfloat>.
    add_executable(gpu_extract_e2e_exe
      bench/gpu_extract_e2e.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(gpu_extract_e2e_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gpu_extract_e2e_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(gpu_extract_e2e_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gpu_extract_e2e_exe PRIVATE -w)
    target_link_libraries(gpu_extract_e2e_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT: per-frame timing (persistent-harness / pipeline-cache) ──
    # gpu_extract_timing_exe calls aether_dsp_sift_extract_gpu N times on one
    # image to measure cold (frame 0: Dawn init + pipeline compiles) vs warm
    # (frame 1+: cached pipelines) per-frame cost — quantifies the recompile+init
    # tax removed by the persistent harness.
    add_executable(gpu_extract_timing_exe
      bench/gpu_extract_timing.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(gpu_extract_timing_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gpu_extract_timing_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(gpu_extract_timing_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gpu_extract_timing_exe PRIVATE -w)
    target_link_libraries(gpu_extract_timing_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT: batch extractor for the GPU->SfM->9-gate validation ──
    add_executable(gpu_extract_batch_exe
      bench/gpu_extract_batch.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(gpu_extract_batch_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gpu_extract_batch_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(gpu_extract_batch_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gpu_extract_batch_exe PRIVATE -w)
    target_link_libraries(gpu_extract_batch_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M2-3: two-view end-to-end matching gate ───
    # gpu_extract_twoview_exe extracts a real image PAIR with the GPU pipeline +
    # CPU fo=0 baseline, cross-matches each track, and compares inlier geometry.
    # (The 50-frame reproj fixture's source frames are absent on this machine;
    # this is the available end-to-end signal — cross-image matching is what
    # reproj ultimately depends on.)
    add_executable(gpu_extract_twoview_exe
      bench/gpu_extract_twoview.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(gpu_extract_twoview_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gpu_extract_twoview_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(gpu_extract_twoview_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gpu_extract_twoview_exe PRIVATE -w)
    target_link_libraries(gpu_extract_twoview_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # ─── GPU DSP-SIFT M2-3: dual-track end-to-end reproj gate (M2 FINAL) ───
    # reproj_e2e_exe builds two COLMAP dbs (GPU vs CPU fo=0 features) from the
    # SAME 50-frame trajectory, runs exhaustive matching + incremental SfM on
    # each, and compares registered frames + mean reproj. Needs ceres (SfM) +
    # glomap_core (colmap controllers) + Dawn (GPU extractor).
    add_executable(reproj_e2e_exe
      bench/reproj_e2e.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(reproj_e2e_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(reproj_e2e_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(reproj_e2e_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(reproj_e2e_exe PRIVATE -w)
    target_link_libraries(reproj_e2e_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libceres.dylib
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})
  else()
    message(STATUS "gss_parity_exe skipped: prebuilt Dawn not found at "
                   "${AETHER_HOST_BUILD_DIR} (build the top-level aether_cpp "
                   "host target with AETHER_ENABLE_DAWN=ON first)")
  endif()
endif()

# ══════════════════════════════════════════════════════════════════════════
# [RE-ENABLE GLOMAP — iOS] glomap_full = colmap subset + glomap-src (GlobalMapper),
# glomap-src migrated 3.14->4.0.4 to match the VENDORED colmap-src (NOT homebrew).
# Isolated target/dir; the shipping glomap_core/colmap_only are untouched.
file(GLOB_RECURSE GLOMAP_SRC ${GLOMAP}/glomap/*.cc)
list(FILTER GLOMAP_SRC EXCLUDE REGEX "(_test|/exe/|glomap\\.cc)")
add_library(glomap_full STATIC ${COLMAP_SRC} ${POSELIB_SRC} ${GLOMAP_SRC})
# CRITICAL: vendored colmap-src FIRST so <colmap/...> resolves to the 4.0.4
# vendored tree, NOT /opt/homebrew/include/colmap (which is a different colmap
# and does not exist on iOS anyway). glomap-src include dir next, then deps.
target_include_directories(glomap_full BEFORE PUBLIC
  ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs
  ${V}/../../include
  ${GLOG}
  ${CERES}/include ${CERESB}/include ${CERES}/config
  ${EIGEN})
# boost headers (header-only) come LAST so they don't shadow colmap.
target_include_directories(glomap_full PUBLIC /opt/homebrew/include)
target_compile_definitions(glomap_full PRIVATE
  EIGEN_MPL2_ONLY
  GLOG_USE_GLOG_EXPORT
  GLOG_NO_ABBREVIATED_SEVERITIES
  GLOG_VERSION_MAJOR=0
  GLOG_VERSION_MINOR=7
  GLOMAP_CUDA_DISABLED
  COLMAP_CUDA_ENABLED=0
  VL_DISABLE_SSE2 VL_DISABLE_AVX)
target_compile_options(glomap_full PRIVATE -w)

# ══════════════════════════════════════════════════════════════════════════
# [HOST GLOMAP FULL-CHAIN BENCH — memory/quality baseline, OFF by default]
# A host executable that runs the SAME bench/glomap_bench.cc full chain
# (GLOMAP + retri + extra COLMAP BA) as the iOS GlomapBench2 app, so peak RSS
# and reproj are apples-to-apples with the device. Isolated, host-only, guarded
# by an option; the iOS glomap_full / shipping targets are untouched. Links the
# same glomap_full static lib + host ceres/glog.
option(AETHER_HOST_GLOMAP_BENCH "Build host full-chain glomap bench exe" OFF)
if(AETHER_HOST_GLOMAP_BENCH)
  add_executable(glomap_bench_full_exe ${V}/bench/glomap_bench.cc)
  target_compile_definitions(glomap_bench_full_exe PRIVATE
    GLOMAP_BENCH_MAIN
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0)
  target_include_directories(glomap_bench_full_exe BEFORE PRIVATE
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_include_directories(glomap_bench_full_exe PRIVATE /opt/homebrew/include)
  target_link_libraries(glomap_bench_full_exe
    glomap_full
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(glomap_bench_full_exe PRIVATE -w)
endif()
