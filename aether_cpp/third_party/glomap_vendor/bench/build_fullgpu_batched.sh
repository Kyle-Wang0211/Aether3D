#!/usr/bin/env bash
# build_fullgpu_batched.sh — standalone build of the BATCHED orchestration harness
# (bench/extract_fullgpu_batched.cc): the full-GPU DSP-SIFT pipeline re-architected
# to ONE command buffer + INDIRECT dispatch + hoisted pipeline compilation. Mirrors
# build_fullgpu_fused.sh exactly; unique obj dir /tmp/fullgpu_batched_obj. Reuses
# the prebuilt host Dawn + the VLFeat .c subset + tools/dawn_kernel_harness.cpp
# READ-ONLY. Run from aether_cpp/ root.
set -euo pipefail

DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/fullgpu_batched_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

for f in generic host random mathop imopv scalespace covdet sift; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -o "$OBJ/dawn_kernel_harness.o"

c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/extract_fullgpu_batched.cc" \
  -o "$OBJ/extract_fullgpu_batched.o"

c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/extract_fullgpu_batched.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/sift.o" "$OBJ/imopv.o" \
  "$OBJ/mathop.o" "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/extract_fullgpu_batched_exe"

echo "built: $OBJ/extract_fullgpu_batched_exe"
echo "run (from $ROOT):"
echo "  $OBJ/extract_fullgpu_batched_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg"
