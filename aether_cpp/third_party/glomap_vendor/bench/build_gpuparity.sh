#!/usr/bin/env bash
# build_gpuparity.sh — standalone build of the GPU DSP-SIFT gss parity harness
# (bench/extract_gpuparity.cc) WITHOUT a full project CMake configure.
#
# Links the PREBUILT host Dawn archive (no Dawn rebuild) + the minimal VLFeat
# .c subset (arm64 scalar path). Run from the aether_cpp/ root. See
# glomap_vendor/GPU_DSP_SIFT_PLAN.md "Parity harness".
#
# The CMake target `extract_gpuparity_exe` (top-level aether_cpp/CMakeLists.txt,
# guarded by AETHER_ENABLE_DAWN) builds the same thing inside the project; this
# script is the worktree-only fast path that reuses the production build's Dawn.
set -euo pipefail

# Prebuilt host Dawn from the production tree (NEVER written to — read-only).
DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/gpuparity_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — exactly the units the gss needs.
for f in generic host random mathop imopv scalespace covdet; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (tool TU; webgpu_cpp.h RAII path).
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" -o "$OBJ/dawn_kernel_harness.o"

# Parity harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/extract_gpuparity.cc" \
  -o "$OBJ/extract_gpuparity.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks (from the build's
# link.txt for the existing Dawn smokes).
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/extract_gpuparity.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/imopv.o" "$OBJ/mathop.o" \
  "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/extract_gpuparity_exe"

echo "built: $OBJ/extract_gpuparity_exe"
echo "run (from $ROOT):"
echo "  $OBJ/extract_gpuparity_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    shaders/wgsl/sift_gss_blur.wgsl [octave] [level_s]"
