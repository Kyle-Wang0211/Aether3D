cmake_minimum_required(VERSION 3.22)
project(glomap_core LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Host-only corruption/fault injection for the tail-cache exactness gate.
# Default OFF is a product invariant: device archives must not expose these
# symbols.  The option is enabled only in the isolated host replay build.
option(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS
       "Enable host-only tail-cache fault-injection hooks" OFF)
option(AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1
       "Compile the descriptor-residency experiment into the official core" ON)

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
  # [GRAVITY-RA 2026-08-10 用户签决] rotation_averaging_impl.cc 解封:原排除
  # 理由(#include <Eigen/CholmodSupport> = SuiteSparse/GPL)已过期 —— 本树
  # optim/sparse_cholesky.h:36 已把 Cholmod 关进 COLMAP_CHOLMOD_ENABLED(未定义),
  # fallback 纯 Eigen SimplicialLDLT,impl.cc 本身零 Cholmod include(grep 核实)。
  # finalize 的重力对齐 RA pass(official_aether_sfm_c.cc)需要它。
  # [MIGRATION 4.1.0] Caspar GPU BA backend: the TU guards only its #include with
  # CASPAR_ENABLED, not the implementation (upstream compiles it conditionally in
  # their CMake). CASPAR_ENABLED is undefined here and every call site
  # (bundle_adjustment.cc, incremental_pipeline.cc) is itself #ifdef-guarded, so
  # the TU is dead for our build -> exclude (same pattern as rotation_averaging).
  ${COLMAP}/colmap/estimators/bundle_adjustment_caspar.cc)
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

# [LICENSE RED LINE 2026-08-17] Two vendored directories must NEVER be compiled
# into anything that ships (license audit, see NOTICE):
#   thirdparty/LSD     — this tree carries the AGPL-3.0 ORIGINAL (upstream later
#                        swapped in a BSD reimplementation; ours predates that).
#                        Sole in-tree user is colmap/image/line.cc, which no
#                        glob includes today — adding colmap/image/*.cc to any
#                        source list silently AGPL-contaminates every binary.
#   thirdparty/SiftGPU — UNC license, commercial use requires a separate
#                        agreement. Referenced by feature/sift.cc only inside
#                        #if defined(COLMAP_GPU_ENABLED), which stays undefined.
# Configure-time tripwire: every shipped target (pwofficial_core, glomap_core,
# glomap_full) derives its COLMAP sources from COLMAP_SRC, so one check here
# covers them all.
foreach(_lic_src IN LISTS COLMAP_SRC)
  if(_lic_src MATCHES "thirdparty/(LSD|SiftGPU)/"
     OR _lic_src MATCHES "colmap/image/line\\.cc$")
    message(FATAL_ERROR "License red line: ${_lic_src} is AGPL/UNC-licensed "
      "and must not be compiled into any target. See the 2026-08-17 license "
      "audit note above.")
  endif()
endforeach()
if(DEFINED COLMAP_GPU_ENABLED AND COLMAP_GPU_ENABLED)
  message(FATAL_ERROR "License red line: COLMAP_GPU_ENABLED compiles SiftGPU "
    "(UNC license, commercial use needs a separate agreement).")
endif()

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

# ---- Pocketworld independent "official" capture route -----------------------
#
# This target is a physical source copy of the shipping streaming-SfM core.  It
# intentionally shares only third-party COLMAP/PoseLib sources with glomap_core;
# all app-owned adapter/extractor sources live under aether_cpp/official_pipeline.
# The final iOS dynamic framework hides this target's complete C/C++ surface and
# exposes only the separate pwofficial_* forwarding ABI.
set(PWOFFICIAL_PIPELINE ${V}/../../official_pipeline)
set(AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1 "" CACHE STRING
    "Reviewed strict-8192 private source-closure SHA-256 marker")
set(AETHER_FROZEN_PWOFFICIAL_CORE_SHA256
    "1ac64d0a138f47f6285c36e6b4b257832ac3932264b8df664797cbeb2217bb04")
set(PWOFFICIAL_COLMAP_SRC ${COLMAP_SRC})
list(REMOVE_ITEM PWOFFICIAL_COLMAP_SRC
  ${V}/bench/aether_threaded_extract.cc
  ${V}/bench/aether_sfm_c.cc
  ${V}/bench/dsp_sift_c.cc
  ${COLMAP}/colmap/controllers/incremental_pipeline.cc
  ${COLMAP}/colmap/estimators/bundle_adjustment_ceres.cc)
list(APPEND PWOFFICIAL_COLMAP_SRC
  ${PWOFFICIAL_PIPELINE}/src/official_aether_threaded_extract.cc
  ${PWOFFICIAL_PIPELINE}/src/official_aether_sfm_c.cc
  ${PWOFFICIAL_PIPELINE}/src/mandatory_arkit_gravity_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/upright_relative_pose_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/mandatory_gravity_tvg_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/arkit_pose_store_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/pair_selection_v2.cc
  ${PWOFFICIAL_PIPELINE}/src/pair_policy_v2_c.cc
  ${PWOFFICIAL_PIPELINE}/src/visual_loop_index_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/official_gpu_timestamp_writer_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/official_gpu_timestamp_weak_stubs_v1.cc
  ${PWOFFICIAL_PIPELINE}/src/official_dsp_sift_c.cc
  ${PWOFFICIAL_PIPELINE}/src/official_incremental_pipeline.cc
  ${PWOFFICIAL_PIPELINE}/src/official_bundle_adjustment_ceres.cc)

add_library(pwofficial_core STATIC ${PWOFFICIAL_COLMAP_SRC} ${POSELIB_SRC})
target_include_directories(pwofficial_core PUBLIC
  ${PWOFFICIAL_PIPELINE}/include
  ${PWOFFICIAL_PIPELINE}/../include
  ${COLMAP} ${POSELIB} ${V}/stubs
  ${GLOG}
  ${CERES}/include ${CERESB}/include ${CERES}/config
  ${EIGEN}
  /opt/homebrew/include)
target_compile_definitions(pwofficial_core PRIVATE
  EIGEN_MPL2_ONLY
  GLOG_USE_GLOG_EXPORT
  GLOG_NO_ABBREVIATED_SEVERITIES
  GLOG_VERSION_MAJOR=0
  GLOG_VERSION_MINOR=7
  GLOMAP_CUDA_DISABLED
  AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL=1
  VL_DISABLE_SSE2 VL_DISABLE_AVX)
set_source_files_properties(
  ${PWOFFICIAL_PIPELINE}/src/official_aether_sfm_c.cc
  PROPERTIES COMPILE_DEFINITIONS
    AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1=$<BOOL:${AETHER_COMPILE_DESCRIPTOR_RESIDENCY_V1}>)
if(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)
  target_compile_definitions(pwofficial_core PRIVATE
    AETHER_TAIL_CACHE_FAULT_TEST_HOOKS=1)
endif()
target_compile_options(pwofficial_core PRIVATE -w)
set_target_properties(pwofficial_core PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN YES)

# PTOL policy and production-wiring regression gates. Keep these as persistent
# CTest targets instead of ad-hoc shell compiles. The policy target explicitly
# carries -ffast-math because the shipping iOS core gets that mode from its
# toolchain; non-finite parsing must remain correct under the same optimizer
# assumptions on every host verification build.
include(CTest)
if(BUILD_TESTING)
  find_package(Threads REQUIRED)
  add_executable(global_ptol_policy_test
    ${PWOFFICIAL_PIPELINE}/tests/global_ptol_policy_test.cc)
  target_include_directories(global_ptol_policy_test PRIVATE
    ${PWOFFICIAL_PIPELINE}/src)
  target_compile_options(global_ptol_policy_test PRIVATE
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-O3>
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-ffast-math>
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wall>
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wextra>
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Werror>)
  target_link_libraries(global_ptol_policy_test PRIVATE Threads::Threads)
  add_test(NAME global_ptol_policy_test COMMAND global_ptol_policy_test)

  add_executable(global_ptol_integration_contract_test
    ${PWOFFICIAL_PIPELINE}/tests/global_ptol_integration_contract_test.cc)
  target_compile_options(global_ptol_integration_contract_test PRIVATE
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wall>
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wextra>
    $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Werror>)
  add_test(NAME global_ptol_integration_contract_test
    COMMAND global_ptol_integration_contract_test ${PWOFFICIAL_PIPELINE})
endif()

# The phone-window bridge/writer is an isolated private object alongside the
# byte-frozen official core archive; it is never inserted into or used to
# rebuild that archive. Enabling this production-only overlay is fail-fast:
# the reviewed source closure must exist before compilation and is embedded in
# this private object only.
option(AETHER_BUILD_PRECLAMP_STAGE_B_PRIVATE
       "Build the private strict-8192 Stage-B overlay" OFF)
if(AETHER_BUILD_PRECLAMP_STAGE_B_PRIVATE)
  include(${PWOFFICIAL_PIPELINE}/cmake/ValidateStageBSourceClosure.cmake)
  add_library(pwofficial_stage_b_private STATIC EXCLUDE_FROM_ALL
    ${PWOFFICIAL_PIPELINE}/src/official_preclamp_instr_v1.cc
    ${PWOFFICIAL_PIPELINE}/src/official_preclamp_replay_driver_v1.cc
    ${PWOFFICIAL_PIPELINE}/../src/crypto/sha256.cpp)
  target_include_directories(pwofficial_stage_b_private PRIVATE
    ${PWOFFICIAL_PIPELINE}/src
    ${PWOFFICIAL_PIPELINE}/../include)
  target_compile_definitions(pwofficial_stage_b_private PRIVATE
    AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1
    AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1="${AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1}")
  target_compile_features(pwofficial_stage_b_private PRIVATE cxx_std_17)
  set_target_properties(pwofficial_stage_b_private PROPERTIES
    POSITION_INDEPENDENT_CODE ON
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES)
endif()

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
  # Source-independent executable contract for the shipping COLMAP clamp's
  # post-push stopping rule. The separate shell contract hashes the production
  # source block so this copied loop cannot be mistaken for production linkage.
  add_executable(legacy_group_clamp_contract_exe
    bench/legacy_group_clamp_contract.cc)

  # RED-first contract for the portable canonical exact selector. The initial
  # contract was first observed failing at link with the implementation absent.
  add_executable(canonical_feature_selector_v1_contract_exe
    ${AT}/../tests/sift/test_canonical_feature_selector_v1.cpp
    ${AT}/../src/sfm/canonical_feature_selector_v1.cc)
  set_target_properties(canonical_feature_selector_v1_contract_exe
    PROPERTIES CXX_STANDARD 20)
  target_include_directories(canonical_feature_selector_v1_contract_exe PRIVATE
    ${AT}/../include)

  # Private timestamp sidecar contract. The fixture links the production
  # official core and calls the same internal serializer used by frame_split;
  # no diagnostic type or test seam enters the stable C ABI.
  add_executable(official_gpu_timestamp_writer_contract_exe
    bench/official_gpu_timestamp_writer_contract.cc)
  target_include_directories(official_gpu_timestamp_writer_contract_exe PRIVATE
    ${PWOFFICIAL_PIPELINE}/src)
  target_compile_definitions(official_gpu_timestamp_writer_contract_exe PRIVATE
    AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL=1)
  target_link_libraries(official_gpu_timestamp_writer_contract_exe PRIVATE
    pwofficial_core
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(official_gpu_timestamp_writer_contract_exe PRIVATE -w)

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

  # ─── [GHOST-MASK 2026-07-12] parity gate for aether_ghost_mask.h ───
  # ghost_mask_parity_exe runs the ghost-layer display-mask pass (D band @1.5cm
  # + per-cell bimodal detector) over a device sparse PLY and dumps the flag
  # bytes; the gate is `cmp`-identical vs the Python Phase0 reference
  # (scratchpad/ghost_l1/gen_ref_flags.py). Header-only pass, zero deps.
  # -ffp-contract=off: the pass mirrors NumPy non-fused arithmetic bit-for-bit.
  add_executable(ghost_mask_parity_exe bench/ghost_mask_parity.cc)
  set_target_properties(ghost_mask_parity_exe PROPERTIES CXX_STANDARD 17)
  target_compile_options(ghost_mask_parity_exe PRIVATE -w -ffp-contract=off)

  # ─── [L1 2026-07-12] Mac end-to-end harness for the ghost L1 arbitration ───
  # l1_ghost_tool_exe drives the EXACT production headers (aether_l1_plan.h +
  # aether_l1_arbitrate.h) over the cap46/47 device fixtures: `plan` writes the
  # budgeted set-cover arbitration plan + points sidecar, `arbitrate` consumes
  # the CoreML depth bins and rewrites ghost_mask.bin bits 5/6. Header-only,
  # zero deps; -ffp-contract=off mirrors the ghost-mask parity contract.
  add_executable(l1_ghost_tool_exe bench/l1_ghost_tool.cc)
  set_target_properties(l1_ghost_tool_exe PROPERTIES CXX_STANDARD 17)
  target_compile_options(l1_ghost_tool_exe PRIVATE -w -ffp-contract=off)

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

    # Focused legacy-clamp count contract. Uses the exact gpu_extract_e2e
    # synthetic fixture and extraction calls, then exits before O(N^2) recall.
    add_executable(gpu_extract_count_contract_exe
      bench/gpu_extract_count_contract.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(gpu_extract_count_contract_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gpu_extract_count_contract_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(gpu_extract_count_contract_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gpu_extract_count_contract_exe PRIVATE -w)
    target_link_libraries(gpu_extract_count_contract_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # [SCALE-PERSIST 2026-08-06] host smoke for the _v2 GPU/CPU exits: real
    # Dawn chain via aether_dsp_sift_extract_gpu_v2; checks out_scales /
    # out_orientations are populated and sane. Same TU/link set as the count
    # contract above.
    add_executable(gpu_scale_v2_smoke_exe
      bench/gpu_scale_v2_smoke.cc
      bench/dsp_sift_gpu_c.cc
      bench/dsp_sift_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc)
    set_target_properties(gpu_scale_v2_smoke_exe PROPERTIES CXX_STANDARD 20)
    target_include_directories(gpu_scale_v2_smoke_exe PRIVATE
      ${V}/stubs ${AT}/../tools ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(gpu_scale_v2_smoke_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(gpu_scale_v2_smoke_exe PRIVATE -w)
    target_link_libraries(gpu_scale_v2_smoke_exe PRIVATE
      glomap_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libglog.dylib
      "-lsqlite3"
      ${ACCELERATE_FW}
      ${COCOA_FW} ${IOKIT_FW} ${IOSURFACE_FW} ${METAL_FW}
      ${QUARTZCORE_FW} ${FOUNDATION_FW} ${COREFOUNDATION_FW})

    # Strict-8192 P1 production-chain gate: the real Dawn extractor and GPU C
    # entry feed the real official streaming session with out_cap=max_features.
    add_executable(preclamp_instr_v1_production_integration_exe
      bench/preclamp_instr_v1_production_integration.cc
      bench/dsp_sift_gpu_c.cc
      ${AT}/../tools/sift_extract_dawn.cc
      ${AT}/../tools/sift_pyramid_dawn.cc
      ${AT}/../src/sfm/canonical_feature_selector_v1.cc)
    set_target_properties(preclamp_instr_v1_production_integration_exe
      PROPERTIES CXX_STANDARD 20)
    target_include_directories(preclamp_instr_v1_production_integration_exe PRIVATE
      ${PWOFFICIAL_PIPELINE}/include
      ${PWOFFICIAL_PIPELINE}/src
      ${V}/stubs ${AT}/../tools ${AT}/../include ${AT}/stb
      ${_DAWN_INC_STATIC} ${_DAWN_INC_GEN})
    target_compile_definitions(preclamp_instr_v1_production_integration_exe PRIVATE
      EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
      GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7 GLOMAP_CUDA_DISABLED
      AETHER_FEATURE_SELECTION_ENV_OFFICIAL=1
      AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1
      AETHER_PRECLAMP_INSTR_TEST_HOOKS=1
      AETHER_WGSL_DIR="${AT}/../shaders/wgsl")
    target_compile_options(preclamp_instr_v1_production_integration_exe PRIVATE
      -w -UNDEBUG)
    target_link_libraries(preclamp_instr_v1_production_integration_exe PRIVATE
      pwofficial_core
      ${_DAWN_HARNESS_LIB}
      ${_WEBGPU_DAWN_LIB}
      /opt/homebrew/lib/libceres.dylib
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

    # Every host extractor target compiles the same portable selector TU and
    # the self-test-only environment namespace. The official iOS carrier uses
    # the separate compile definition in the top-level CMake target.
    foreach(target IN ITEMS
        clamp_parity_exe
        gpu_extract_e2e_exe
        gpu_extract_count_contract_exe
        gpu_scale_v2_smoke_exe
        gpu_extract_timing_exe
        gpu_extract_batch_exe
        gpu_extract_twoview_exe
        reproj_e2e_exe)
      target_sources(${target} PRIVATE
        ${AT}/../src/sfm/canonical_feature_selector_v1.cc
        ${AT}/../official_pipeline/src/official_preclamp_instr_v1.cc
        ${AT}/../src/crypto/sha256.cpp)
      target_include_directories(${target} PRIVATE
        ${AT}/../include
        ${AT}/../official_pipeline/src)
      target_compile_definitions(${target} PRIVATE
        AETHER_FEATURE_SELECTION_ENV_SELFTEST=1)
    endforeach()
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

  # [AETHER LAPACK-TIER SCAN 2026-07-12] finalize-BA-only replay harness: loads
  # the pre-extra-BA model dumped by glomap_bench (AETHER_PREBA_DIR) and
  # re-runs the CAUCHY finalize BA back-to-back with E/L/D dense-backend
  # alternation in one process (heat-controlled timing). Host-only.
  add_executable(ba_replay_bench_exe ${V}/bench/ba_replay_bench.cc)
  target_compile_definitions(ba_replay_bench_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0)
  target_include_directories(ba_replay_bench_exe BEFORE PRIVATE
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_link_libraries(ba_replay_bench_exe
    glomap_full
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(ba_replay_bench_exe PRIVATE -w)

  # [INCREMENTAL-GLOBAL-BA A/B 2026-07-13] HOST replay of a pulled device
  # sfm_live.db through the streaming ABI (aether_sfm_add_frame_features →
  # finalize_async), to A/B AETHER_INCREMENTAL_GLOBAL_BA (capture-time rolling
  # global BA + finalize collapse) against the finalize sparse cloud. Links
  # glomap_full (COLMAP_SRC includes aether_sfm_c.cc when BUILD_BENCH=OFF).
  add_executable(sfm_replay_bench_exe ${V}/bench/sfm_replay_bench.cc)
  target_compile_definitions(sfm_replay_bench_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0)
  target_include_directories(sfm_replay_bench_exe BEFORE PRIVATE
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_link_libraries(sfm_replay_bench_exe
    glomap_full
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(sfm_replay_bench_exe PRIVATE -w)

  # [BUILD-GRAPH FIX 2026-08-17] official_gpu_match_host.o used to be a
  # hand-compiled orphan: the four official_* bench targets below link the
  # literal ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o but nothing
  # in the build graph knew how to produce it — `rm -rf build-*` bricked them
  # with a bare "file not found". This rule reproduces the manual command;
  # verified by external-symbol parity against the surviving 2026-08-11
  # object in build-host-fullbench/ (sole diff = one clang-version weak
  # template instantiation).
  #   The -D rename is load-bearing: sfm_{replay,regen,finalize_resume}_bench
  # .cc each carry their own strong no-op stub of
  # aether_gpu_match_set_preview_fps30, and pwofficial_core only weak-imports
  # it — linking the .mm's un-renamed strong definition would be a
  # duplicate-symbol error against those stubs.
  add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o
    COMMAND ${CMAKE_CXX_COMPILER} -std=c++17 -fobjc-arc -O3
      -I${V}/../../include
      -Daether_gpu_match_set_preview_fps30=aether_gpu_match_set_preview_fps30_hostimpl
      -c ${PWOFFICIAL_PIPELINE}/src/official_gpu_match.mm
      -o ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o
    DEPENDS ${PWOFFICIAL_PIPELINE}/src/official_gpu_match.mm
      ${V}/../../include/aether/sfm/descriptor_residency_policy_v1.h
    COMMENT "Compiling official_gpu_match_host.o (host Metal matcher for official_* benches)")
  add_custom_target(official_gpu_match_host_obj
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o)

  # [OFFICIAL-QUADRATIC A/B 2026-07-25] The same host replay driver, linked
  # against pwofficial_core so the OFFICIAL route's finalize is what runs —
  # including AddOfficialQuadraticPairs (upstream COLMAP quadratic overlap).
  # Run twice over one pulled db, changing only the environment:
  #     (unset)                             -> overlap = 10 (upstream default)
  #     OFFICIAL_AETHER_QUADRATIC_OVERLAP=0 -> pass disabled (baseline)
  # and diff the finalize sparse cloud. The GPU matcher/extractor symbols are
  # weak, so both arms fall back to the identical CPU matcher on host.
  add_executable(official_replay_bench_exe ${V}/bench/sfm_replay_bench.cc
    # [TAIL-CACHE HOST 2026-08-02] the Stage-B probe writer TU is part of the
    # official core's source closure on device; the host bench must link it
    # too now that official_aether_sfm_c.cc references DiscardPending().
    ${PWOFFICIAL_PIPELINE}/src/official_preclamp_instr_v1.cc
    ${V}/../../src/crypto/sha256.cpp)
  target_compile_definitions(official_replay_bench_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0
    AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1
    AETHER_REPLAY_LINK_REAL_GPU_MATCH=1)
  if(AETHER_TAIL_CACHE_FAULT_TEST_HOOKS)
    target_compile_definitions(official_replay_bench_exe PRIVATE
      AETHER_TAIL_CACHE_FAULT_TEST_HOOKS=1)
  endif()
  target_include_directories(official_replay_bench_exe BEFORE PRIVATE
    ${PWOFFICIAL_PIPELINE}/include
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_link_libraries(official_replay_bench_exe
    pwofficial_core
    ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o
    "-framework Metal" "-framework Foundation"
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(official_replay_bench_exe PRIVATE -w)

  # [FLOATER-VERIFY 2026-08-06] Finalize-only resume bench: reruns the product
  # crash-resume finalize over a REAL device db (+ .arkit_pose_v1 sidecar),
  # consuming the device's actual on-capture match graph. Same link closure as
  # official_replay_bench_exe.
  add_executable(sfm_finalize_resume_bench_exe
    ${V}/bench/sfm_finalize_resume_bench.cc
    ${PWOFFICIAL_PIPELINE}/src/official_preclamp_instr_v1.cc
    ${V}/../../src/crypto/sha256.cpp)
  target_compile_definitions(sfm_finalize_resume_bench_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0
    AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1
    AETHER_REPLAY_LINK_REAL_GPU_MATCH=1)
  target_include_directories(sfm_finalize_resume_bench_exe BEFORE PRIVATE
    ${PWOFFICIAL_PIPELINE}/include
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_link_libraries(sfm_finalize_resume_bench_exe
    pwofficial_core
    ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o
    "-framework Metal" "-framework Foundation"
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(sfm_finalize_resume_bench_exe PRIVATE -w)

  # [SCALE-PERSIST 2026-08-06] Host verification driver for keypoint-scale
  # persistence: real photos (PIL grayscale raws) through the PRODUCTION
  # aether_sfm_add_frame CPU-extraction path against pwofficial_core. Same
  # link closure as official_replay_bench_exe.
  add_executable(sfm_scale_persist_driver_exe
    ${V}/bench/sfm_scale_persist_driver.cc
    ${PWOFFICIAL_PIPELINE}/src/official_preclamp_instr_v1.cc
    ${V}/../../src/crypto/sha256.cpp)
  target_compile_definitions(sfm_scale_persist_driver_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0
    AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1
    AETHER_REPLAY_LINK_REAL_GPU_MATCH=1)
  target_include_directories(sfm_scale_persist_driver_exe BEFORE PRIVATE
    ${PWOFFICIAL_PIPELINE}/include
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_link_libraries(sfm_scale_persist_driver_exe
    pwofficial_core
    ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o
    "-framework Metal" "-framework Foundation"
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(sfm_scale_persist_driver_exe PRIVATE -w)

  # [FLOATER-COV 2026-08-07] Per-point BA covariance dump: computes the
  # conditional 3D-point covariance (colmap covariance.cc, Params::POINTS) on
  # a saved bin model for offline shell-band AUC validation. Host-only bench,
  # same link closure as sfm_finalize_resume_bench_exe.
  add_executable(sfm_point_cov_dump_exe
    ${V}/bench/sfm_point_cov_dump.cc)
  target_compile_definitions(sfm_point_cov_dump_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT GLOG_NO_ABBREVIATED_SEVERITIES
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED COLMAP_CUDA_ENABLED=0)
  target_include_directories(sfm_point_cov_dump_exe BEFORE PRIVATE
    ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs ${V}/../../include
    /opt/homebrew/include /opt/homebrew/include/eigen3)
  target_link_libraries(sfm_point_cov_dump_exe
    pwofficial_core
    ${CMAKE_CURRENT_BINARY_DIR}/official_gpu_match_host.o
    "-framework Metal" "-framework Foundation"
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    sqlite3)
  target_compile_options(sfm_point_cov_dump_exe PRIVATE -w)

  # [BUILD-GRAPH FIX 2026-08-17] Hook the generated .o into every consumer so
  # a clean build dir produces it before the first link.
  foreach(_gpu_match_consumer official_replay_bench_exe
      sfm_finalize_resume_bench_exe sfm_scale_persist_driver_exe
      sfm_point_cov_dump_exe)
    add_dependencies(${_gpu_match_consumer} official_gpu_match_host_obj)
  endforeach()

endif()
