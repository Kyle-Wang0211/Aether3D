#!/usr/bin/env bash
# build_affine.sh — standalone build of the GPU DSP-SIFT S4a affine-shape parity
# harness (bench/parity_affine.cc) WITHOUT a full project CMake configure.
#
# Sibling of bench/build_gpuparity.sh: links the PREBUILT host Dawn archive (no
# Dawn rebuild) + the minimal VLFeat .c subset (arm64 scalar path) + the
# read-only tools/dawn_kernel_harness.cpp. Unique OBJ dir /tmp/parity_affine_obj
# so it never collides with the gpuparity harness objects. Run from the
# aether_cpp/ root. See glomap_vendor/GPU_DSP_SIFT_PLAN.md "S4 / Parity harness".
set -euo pipefail

# Prebuilt host Dawn from the production tree (NEVER written to — read-only).
DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/parity_affine_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — covdet (affine-shape + extract_patch_helper), mathop
# (vl_svd2 / dlasv2 / solve_2), imopv (vl_imgradient_f), scalespace + the runtime
# units (generic/host/random) the gss build needs.
for f in generic host random mathop imopv scalespace covdet; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (read-only tool TU; webgpu_cpp.h RAII path).
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -o "$OBJ/dawn_kernel_harness.o"

# Parity harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/parity_affine.cc" \
  -o "$OBJ/parity_affine.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks (same set as the
# existing Dawn smokes / the gpuparity harness).
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/parity_affine.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/imopv.o" "$OBJ/mathop.o" \
  "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/parity_affine_exe"

echo "built: $OBJ/parity_affine_exe"
echo "run (from $ROOT):"
echo "  $OBJ/parity_affine_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    shaders/wgsl/sift_affine_shape.wgsl"
