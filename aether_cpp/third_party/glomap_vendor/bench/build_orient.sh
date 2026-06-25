#!/usr/bin/env bash
# build_orient.sh — standalone build of the GPU DSP-SIFT S4b orientation parity
# harness (bench/parity_orient.cc) WITHOUT a full project CMake configure.
#
# Links the PREBUILT host Dawn archive (no Dawn rebuild) + the minimal VLFeat .c
# subset (arm64 scalar path) + the read-only tools/dawn_kernel_harness.cpp. This
# is the worktree-only fast path (mirrors build_gpuparity.sh); unique obj dir so
# it never collides with the other harnesses' objects.
#
# Run from anywhere; paths self-locate to the aether_cpp/ root.
set -euo pipefail

# Prebuilt host Dawn from the production tree (NEVER written to — read-only).
DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/parity_orient_obj}"             # UNIQUE obj dir (task spec)
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — the units the gss + affine-shape + orientation need:
#   covdet (orientation/affine), scalespace (gss), imopv (gradient/smooth),
#   mathop (svd2/dlasv2), generic/host/random (runtime).
for f in generic host random mathop imopv scalespace covdet; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (tool TU; webgpu_cpp.h RAII path). READ-ONLY source.
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -o "$OBJ/dawn_kernel_harness.o"

# Orientation parity harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/parity_orient.cc" \
  -o "$OBJ/parity_orient.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks (same set the existing
# Dawn smokes / extract_gpuparity link against).
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first \
  -Wl,-headerpad_max_install_names \
  "$OBJ/parity_orient.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/imopv.o" "$OBJ/mathop.o" \
  "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/parity_orient_exe"

echo "built: $OBJ/parity_orient_exe"
echo "run (from $ROOT):"
echo "  $OBJ/parity_orient_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    shaders/wgsl/sift_orientation.wgsl"
