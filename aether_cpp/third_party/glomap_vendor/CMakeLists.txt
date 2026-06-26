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
# iOS stubs (Bitmap without FreeImage)
list(APPEND COLMAP_SRC ${V}/stubs/colmap_ios_stubs.cc)
# threaded DSP-SIFT extractor — MUST live in glomap_core so it compiles with the
# SAME flags (esp. -ffast-math from the iOS toolchain) as colmap/feature/sift.cc;
# otherwise the cloned keypoint/descriptor FP arithmetic diverges -> not bit-identical.
list(APPEND COLMAP_SRC ${V}/bench/aether_threaded_extract.cc)

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
    "-lsqlite3"
    ${ACCELERATE_FW})

  # [gpu-sift-s1] HOST verification harness for the GPU-feature injection +
  # match-persist path (GAP 1+2+3). Links glomap_core (has VLFeat extractor +
  # CPU matcher + incremental SfM) + the two streaming-ABI TUs + the driver.
  # Drives aether_sfm_create -> aether_sfm_add_frame_with_features (injection)
  # -> aether_sfm_finalize (incremental mapper) over real DSP-SIFT features read
  # from a prebuilt bench db, proving streamed frames REGISTER.
  add_executable(sfm_inject_verify_exe
    bench/sfm_inject_verify.cc
    bench/aether_sfm_c.cc
    bench/dsp_sift_c.cc)
  target_include_directories(sfm_inject_verify_exe PRIVATE
    ${V}/stubs ${AT}/../include)         # aether_sfm_c.h lives in aether_cpp/include
  target_compile_definitions(sfm_inject_verify_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED VL_DISABLE_SSE2 VL_DISABLE_AVX)
  target_compile_options(sfm_inject_verify_exe PRIVATE -w)
  target_link_libraries(sfm_inject_verify_exe PRIVATE
    glomap_core                          # VLFeat + matcher + incremental SfM
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})

  # [gpu-sift-s1] HOST verification of the TRUE per-frame incremental register
  # ABI (aether_sfm_begin_incremental + aether_sfm_register_next_frame). Drives
  # the IncrementalMapper directly, one frame per call, over a real capture
  # sequence; gates the per-frame cloud growth + cost + reproj against the batch
  # finalize baseline on the SAME injected db.
  add_executable(sfm_stream_verify_exe
    bench/sfm_stream_verify.cc
    bench/aether_sfm_c.cc
    bench/dsp_sift_c.cc)
  target_include_directories(sfm_stream_verify_exe PRIVATE
    ${V}/stubs ${AT}/../include)
  target_compile_definitions(sfm_stream_verify_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED VL_DISABLE_SSE2 VL_DISABLE_AVX)
  target_compile_options(sfm_stream_verify_exe PRIVATE -w)
  target_link_libraries(sfm_stream_verify_exe PRIVATE
    glomap_core
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})

  # [gpu-sift-s1] HOST verification of the per-frame register ABI over a REAL
  # production correspondence graph (the real414 research db: real keypoints +
  # real matches + real two-view geometries, descriptors stripped). Attaches the
  # frozen graph (aether_sfm_attach_db_frames) and streams register_next_frame —
  # no descriptor re-injection. The faithful streaming proof on real capture data.
  add_executable(sfm_stream_real_verify_exe
    bench/sfm_stream_real_verify.cc
    bench/aether_sfm_c.cc
    bench/dsp_sift_c.cc)
  target_include_directories(sfm_stream_real_verify_exe PRIVATE
    ${V}/stubs ${AT}/../include)
  target_compile_definitions(sfm_stream_real_verify_exe PRIVATE
    EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7
    GLOMAP_CUDA_DISABLED VL_DISABLE_SSE2 VL_DISABLE_AVX)
  target_compile_options(sfm_stream_real_verify_exe PRIVATE -w)
  target_link_libraries(sfm_stream_real_verify_exe PRIVATE
    glomap_core
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})
endif()
