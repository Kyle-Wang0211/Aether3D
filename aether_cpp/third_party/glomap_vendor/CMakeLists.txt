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
  ${COLMAP}/colmap/optim/*.cc)
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
  ${COLMAP}/colmap/util/testing.cc)            # test helpers
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

# ---- glomap pipeline ----
file(GLOB_RECURSE GLOMAP_SRC ${GLOMAP}/glomap/*.cc)
# exclude: exe main, lib entry, CLI option_manager (boost::program_options), retriangulation (colmap incremental triangulator), tests
list(FILTER GLOMAP_SRC EXCLUDE REGEX "(/exe/|_test\\.cc$|/glomap\\.cc$|option_manager\\.cc$|track_retriangulation\\.cc$)")

# ---- PoseLib (Eigen-only) ----
file(GLOB_RECURSE POSELIB_SRC ${POSELIB}/PoseLib/*.cc ${POSELIB}/PoseLib/*.cpp)
list(FILTER POSELIB_SRC EXCLUDE REGEX "_test")

add_library(glomap_core STATIC ${COLMAP_SRC} ${GLOMAP_SRC} ${POSELIB_SRC})

target_include_directories(glomap_core PUBLIC
  ${COLMAP} ${GLOMAP} ${POSELIB} ${V}/stubs
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

# ---- benchmark executable (link test + standalone run) ----
option(BUILD_BENCH "Build glomap_bench executable" ON)
if(BUILD_BENCH)
  find_library(ACCELERATE_FW Accelerate)
  add_executable(glomap_bench_exe bench/glomap_bench.cc bench/colmap_bench.cc
    bench/dsp_sift_c.cc)  # aether_threaded_extract.cc is in glomap_core
  target_include_directories(glomap_bench_exe PRIVATE ${V}/stubs)
  target_compile_definitions(glomap_bench_exe PRIVATE
    GLOMAP_BENCH_MAIN EIGEN_MPL2_ONLY GLOG_USE_GLOG_EXPORT
    GLOG_VERSION_MAJOR=0 GLOG_VERSION_MINOR=7)
  target_compile_options(glomap_bench_exe PRIVATE -w)
  target_link_libraries(glomap_bench_exe PRIVATE
    glomap_core
    /opt/homebrew/lib/libceres.dylib    # [AETHER] host ceres (was iOS ${CERESB} -> arch mismatch); glomap_bench_exe is HOST-only
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})

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
    glomap_core
    /opt/homebrew/lib/libceres.dylib
    /opt/homebrew/lib/libglog.dylib
    "-lsqlite3"
    ${ACCELERATE_FW})
endif()
