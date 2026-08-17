#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
CMAKE_FILE="$SCRIPT_DIR/../../CMakeLists.txt"
INPUT_MANIFEST="$REPO_ROOT/openspec/changes/portable-sfm-speedup-v1/p3a1-carrier-inputs.sha256"
BEGIN_MARKER="# P3a1 OFFICIAL GPU CARRIER BEGIN"
END_MARKER="# P3a1 OFFICIAL GPU CARRIER END"
EXPECTED_DAWN_REVISION="12ee391c7411285895f4289a3d889a182c093014"
EXPECTED_DAWN_SHA256="625cf65dded708ad1abd3dc92f3b47c3c90c384f508676b56303f9341d301b42"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--source-only" ]; }; then
  echo "usage: $0 [--source-only]" >&2
  exit 2
fi

if [ ! -f "$INPUT_MANIFEST" ]; then
  echo "FAIL: missing frozen carrier-input manifest: $INPUT_MANIFEST" >&2
  exit 1
fi
if ! (CDPATH= cd -- "$REPO_ROOT" && /usr/bin/shasum -a 256 -c "$INPUT_MANIFEST"); then
  echo "FAIL: frozen carrier input changed" >&2
  exit 1
fi

if ! /usr/bin/grep -F -x -q \
  'option(AETHER_ALLOW_TEST_ASSET_DOWNLOADS "Allow configure-time download of optional test assets" ON)' \
  "$CMAKE_FILE"; then
  echo "FAIL: missing sealed-build test-asset download option" >&2
  exit 1
fi
if ! /usr/bin/grep -F -x -q \
  '    if(AETHER_ALLOW_TEST_ASSET_DOWNLOADS AND NOT EXISTS ${AETHER_DAMAGED_HELMET_PATH})' \
  "$CMAKE_FILE"; then
  echo "FAIL: DamagedHelmet configure-time download is not gated" >&2
  exit 1
fi

if ! /usr/bin/grep -F -x -q "$BEGIN_MARKER" "$CMAKE_FILE"; then
  echo "FAIL: missing pwofficial_gpu_extract target marker" >&2
  exit 1
fi

block=$(
  /usr/bin/awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    $0 == begin { in_block = 1 }
    in_block { print }
    $0 == end { found_end = 1; exit }
    END {
      if (!in_block || !found_end) {
        exit 1
      }
    }
  ' "$CMAKE_FILE"
)

require_exact_count() {
  expected_count=$1
  needle=$2
  actual_count=$(printf '%s\n' "$block" | /usr/bin/grep -F -c "$needle" || true)
  if [ "$actual_count" -ne "$expected_count" ]; then
    echo "FAIL: expected $expected_count occurrence(s) of '$needle', got $actual_count" >&2
    exit 1
  fi
}

require_exact_count 1 "add_library(pwofficial_gpu_extract STATIC"
require_exact_count 1 "if(CMAKE_SYSTEM_NAME STREQUAL \"iOS\")"
require_exact_count 1 "AETHER_FEATURE_SELECTION_ENV_OFFICIAL=1"
require_exact_count 1 "AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL=1"
require_exact_count 1 "AETHER_GPU_TIMESTAMP_DAWN_REVISION=\"$EXPECTED_DAWN_REVISION\""
require_exact_count 1 "AETHER_GPU_TIMESTAMP_DAWN_ARTIFACT_SHA256=\"$EXPECTED_DAWN_SHA256\""
require_exact_count 1 "add_dependencies(pwofficial_gpu_extract aether_bake_wgsl)"
require_exact_count 1 "OUTPUT_NAME pwofficial_gpu_extract"
require_exact_count 1 "set(AETHER_PWOFFICIAL_DAWN_GEN_INCLUDE_DIR"
require_exact_count 1 "build-ios-device-dawn/third_party/dawn/gen/include"
require_exact_count 3 "\${AETHER_PWOFFICIAL_DAWN_GEN_INCLUDE_DIR}"

for source in \
  third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc \
  src/sfm/canonical_feature_selector_v1.cc \
  tools/sift_extract_dawn.cc \
  tools/sift_pyramid_dawn.cc \
  tools/dawn_kernel_harness.cpp \
  sift_gray_to_f32_wgsl.cpp \
  sift_gss_blur_wgsl.cpp \
  sift_gss_resample_wgsl.cpp \
  sift_dog_detect_wgsl.cpp \
  sift_nonextrema_suppress_wgsl.cpp \
  sift_affine_shape_wgsl.cpp \
  sift_orientation_wgsl.cpp \
  sift_dsp_descriptor_wgsl.cpp \
  sift_dsp_descriptor_f16_wgsl.cpp \
  sift_dsp_descriptor_par_wgsl.cpp \
  sift_dsp_mean_wgsl.cpp
do
  require_exact_count 1 "$source"
done

for forbidden in \
  "AETHER_FEATURE_SELECTION_ENV_SELFTEST" \
  "AETHER_GPU_TIMESTAMPS_ENV_SELFTEST" \
  "target_link_libraries(pwofficial_gpu_extract" \
  "libpwsfm_gpu_extract" \
  "vendor/aether_ffi" \
  "build_gpu_extract_archive.sh"
do
  if printf '%s\n' "$block" | /usr/bin/grep -F -q "$forbidden"; then
    echo "FAIL: official carrier target references forbidden self-route token: $forbidden" >&2
    exit 1
  fi
done

source_count=$(
  printf '%s\n' "$block" |
    /usr/bin/awk '
      /third_party\/glomap_vendor\/bench\/dsp_sift_gpu_c\.cc/ ||
      /src\/sfm\/canonical_feature_selector_v1\.cc/ ||
      /tools\/sift_extract_dawn\.cc/ ||
      /tools\/sift_pyramid_dawn\.cc/ ||
      /tools\/dawn_kernel_harness\.cpp/ ||
      /sift_.*_wgsl\.cpp/ { count += 1 }
      END { print count + 0 }
    '
)
if [ "$source_count" -ne 16 ]; then
  echo "FAIL: expected exactly 16 official carrier source entries, got $source_count" >&2
  exit 1
fi

echo "PASS: pwofficial_gpu_extract source contract"
