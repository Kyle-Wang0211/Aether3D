#!/usr/bin/env bash
# build_fullgpu_fused.sh — standalone build of the S5c FUSION harness
# (bench/extract_fullgpu_fused.cc): the full-GPU DSP-SIFT pipeline with the
# descriptor stage collapsed into ONE fused kernel (sift_descriptor_fused.wgsl,
# task A) — no ~3.4 GB intermediate plane buffer. Mirrors build_fullgpu_s5b.sh
# exactly; unique obj dir /tmp/fullgpu_fused_obj so it never collides with the
# s5b / per-stage harnesses. Run from aether_cpp/ root.
set -euo pipefail

# Prebuilt host Dawn from the production tree (NEVER written to — read-only).
DAWN_BUILD="${DAWN_BUILD:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build}"
DAWN_SRC="${DAWN_SRC:-/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp}"
DAWN_LIB="$DAWN_BUILD/third_party/dawn/src/dawn/native/libwebgpu_dawn.a"
DAWN_INC_SRC="$DAWN_SRC/third_party/dawn/include"
DAWN_INC_GEN="$DAWN_BUILD/third_party/dawn/gen/include"

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # -> aether_cpp/
VLF="$ROOT/third_party/glomap_vendor/colmap-src/thirdparty/VLFeat"
OBJ="${OBJ:-/tmp/fullgpu_fused_obj}"
mkdir -p "$OBJ"

VLDEFS="-DVL_DISABLE_SSE2 -DVL_DISABLE_AVX -DVL_DISABLE_OPENMP"

# VLFeat (arm64 scalar) — full pipeline units.
for f in generic host random mathop imopv scalespace covdet sift; do
  cc -std=c11 -arch arm64 -O2 $VLDEFS -I "$VLF" -c "$VLF/$f.c" -o "$OBJ/$f.o"
done

# Dawn kernel harness (tool TU) — READ-ONLY reuse.
c++ -std=c++20 -arch arm64 -O2 -c "$ROOT/tools/dawn_kernel_harness.cpp" \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -o "$OBJ/dawn_kernel_harness.o"

# S5c fusion harness TU.
c++ -std=c++20 -arch arm64 -O2 \
  -I "$ROOT/tools" -I "$DAWN_INC_SRC" -I "$DAWN_INC_GEN" \
  -I "$VLF" -I "$ROOT/third_party/stb" \
  -c "$ROOT/third_party/glomap_vendor/bench/extract_fullgpu_fused.cc" \
  -o "$OBJ/extract_fullgpu_fused.o"

# Link: monolithic libwebgpu_dawn.a + system frameworks.
c++ -std=c++20 -arch arm64 -g -Wl,-search_paths_first -Wl,-headerpad_max_install_names \
  "$OBJ/extract_fullgpu_fused.o" "$OBJ/dawn_kernel_harness.o" \
  "$OBJ/covdet.o" "$OBJ/scalespace.o" "$OBJ/sift.o" "$OBJ/imopv.o" \
  "$OBJ/mathop.o" "$OBJ/generic.o" "$OBJ/host.o" "$OBJ/random.o" \
  "$DAWN_LIB" \
  -framework CoreFoundation -framework Foundation -framework IOSurface \
  -framework QuartzCore -framework Cocoa -framework IOKit -framework Metal \
  -o "$OBJ/extract_fullgpu_fused_exe"

echo "built: $OBJ/extract_fullgpu_fused_exe"
echo "run (from $ROOT):"
echo "  # FUSED single-kernel descriptor (default):"
echo "  $OBJ/extract_fullgpu_fused_exe \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg"
echo "  # host fp64 warp-setup REFERENCE (the ~3.4 GB concat-plane baseline):"
echo "  $OBJ/extract_fullgpu_fused_exe --host-warp \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test.jpg \\"
echo "    third_party/glomap_vendor/iosapp/Resources/sift_test2.jpg"
