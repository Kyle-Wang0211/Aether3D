#!/usr/bin/env bash
# build_warp.sh — standalone build of the GPU DSP-SIFT descriptor WARP-SETUP
# parity harness (bench/parity_warp.cc), Stage S5b, WITHOUT a full project CMake
# configure.
#
# Mirrors build_descriptor.sh (S3): links the PREBUILT host Dawn archive (no Dawn
# rebuild) + the VLFeat .c subset the descriptor + warp-setup path needs
# (detector + patch + polar gradient + raw SIFT descriptor + svd2 + math). Run
# from aether_cpp/ root. Unique obj dir /tmp/parity_warp_obj so it never collides
# with the S1/S3/S4 harnesses.
set -euo pipefail

# Prebuilt host Dawn from the production tree (NEVER written to — read-only).
DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/parity_warp_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — detector + patch + gradient + raw descriptor + svd2.
for f in generic host random mathop imopv scalespace covdet sift; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (tool TU; webgpu_cpp.h RAII path) — READ-ONLY reuse.
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -o "$OBJ/dawn_kernel_harness.o"

# Parity harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/parity_warp.cc" \
  -o "$OBJ/parity_warp.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks (from the S1/S3 harness).
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/parity_warp.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/sift.o" "$OBJ/imopv.o" \
  "$OBJ/mathop.o" "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/parity_warp_exe"

echo "built: $OBJ/parity_warp_exe"
echo "run (from $ROOT):"
echo "  $OBJ/parity_warp_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    shaders/wgsl/sift_dsp_descriptor.wgsl \\"
echo "    shaders/wgsl/sift_descriptor_warp.wgsl [kp_cap]"
