#!/usr/bin/env bash
# build_suppress.sh — standalone build of the GPU nonExtremaSuppression parity
# harness (bench/parity_suppress.cc) for Stage S2b of the GPU DSP-SIFT port.
#
# Mirrors bench/build_gpuparity.sh: links the PREBUILT host Dawn archive (NO Dawn
# rebuild) + the minimal VLFeat .c subset (arm64 scalar) + the read-only
# tools/dawn_kernel_harness.cpp. Uses a UNIQUE obj dir (/tmp/parity_suppress_obj)
# so it never collides with the other harnesses. Run from the aether_cpp/ root.
set -euo pipefail

# Prebuilt host Dawn from the production tree (NEVER written to — read-only).
DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/parity_suppress_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — exactly the units the detector + suppression need.
for f in generic host random mathop imopv scalespace covdet; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (tool TU; webgpu_cpp.h RAII path) — read-only reuse.
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" -o "$OBJ/dawn_kernel_harness.o"

# Suppression parity harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/parity_suppress.cc" \
  -o "$OBJ/parity_suppress.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks (same set as the gss
# parity harness).
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/parity_suppress.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/imopv.o" "$OBJ/mathop.o" \
  "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/parity_suppress_exe"

echo "built: $OBJ/parity_suppress_exe"
echo "run (from $ROOT):"
echo "  $OBJ/parity_suppress_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    shaders/wgsl/sift_nonextrema_suppress.wgsl"
