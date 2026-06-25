#!/usr/bin/env bash
# build_gpu_sift_module_verify.sh — build the reusable GpuSiftExtractor module
# (src/gpu/gpu_sift_extractor.cc) + its verification driver
# (bench/gpu_sift_module_verify.cc). Mirrors build_fullgpu_batched.sh exactly;
# unique obj dir /tmp/gpu_sift_module_obj. Reuses the prebuilt host Dawn + the
# VLFeat .c subset + tools/dawn_kernel_harness.cpp READ-ONLY.
# Run from aether_cpp/ root.
set -euo pipefail

DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/gpu_sift_module_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

for f in generic host random mathop imopv scalespace covdet sift; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -o "$OBJ/dawn_kernel_harness.o"

# The reusable module.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/src/gpu" \
  -c "$ROOT/src/gpu/gpu_sift_extractor.cc" \
  -o "$OBJ/gpu_sift_extractor.o"

# The verification driver.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" -I "$ROOT/src/gpu" \
  -c "$ROOT/third_party/glomap_vendor/bench/gpu_sift_module_verify.cc" \
  -o "$OBJ/gpu_sift_module_verify.o"

c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/gpu_sift_module_verify.o" "$OBJ/gpu_sift_extractor.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/sift.o" "$OBJ/imopv.o" \
  "$OBJ/mathop.o" "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/gpu_sift_module_verify_exe"

echo "built: $OBJ/gpu_sift_module_verify_exe"
echo "run (from $ROOT):"
echo "  $OBJ/gpu_sift_module_verify_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg --frames 5"
