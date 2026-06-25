#!/usr/bin/env bash
# build_hybrid_timing_s2.sh — standalone build of the S2 hybrid GPU->CPU
# DSP-SIFT extractor + e2e timing harness (bench/extract_hybrid_timing_s2.cc).
#
# S2 = finish DETECTION on GPU (Newton refine + peak/edge gates via task A's
# sift_refine_gate.wgsl) so the GPU outputs FINAL keypoints; the CPU continuation
# starts at affine-shape (seeded via vl_covdet_append_feature). Same worktree-only
# fast path as build_hybrid_timing.sh: links the PREBUILT host Dawn archive (no
# Dawn rebuild) + the VLFeat .c subset. Run from aether_cpp/ root.
# See glomap_vendor/GPU_DSP_SIFT_PLAN.md S2.
set -euo pipefail

DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/hybrid_timing_s2_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — same units the S1 hybrid extractor needs.
for f in generic host random mathop imopv scalespace covdet sift; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (tool TU; webgpu_cpp.h RAII path).
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" -o "$OBJ/dawn_kernel_harness.o"

# S2 hybrid timing harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/extract_hybrid_timing_s2.cc" \
  -o "$OBJ/extract_hybrid_timing_s2.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks.
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/extract_hybrid_timing_s2.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/imopv.o" "$OBJ/mathop.o" \
  "$OBJ/sift.o" "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/extract_hybrid_timing_s2_exe"

echo "built: $OBJ/extract_hybrid_timing_s2_exe"
echo "run (from $ROOT):"
echo "  $OBJ/extract_hybrid_timing_s2_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg [num_threads]"
