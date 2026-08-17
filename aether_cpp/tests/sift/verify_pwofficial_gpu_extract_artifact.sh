#!/bin/sh
set -eu

EXPECTED_DAWN_REVISION="git:12ee391c7411285895f4289a3d889a182c093014"
EXPECTED_DAWN_SHA256="625cf65dded708ad1abd3dc92f3b47c3c90c384f508676b56303f9341d301b42"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/path/to/libpwofficial_gpu_extract.a" >&2
  exit 2
fi

artifact=$1
case "$artifact" in
  /*) ;;
  *)
    echo "FAIL: artifact path must be absolute" >&2
    exit 2
    ;;
esac
if [ ! -f "$artifact" ]; then
  echo "FAIL: artifact does not exist: $artifact" >&2
  exit 1
fi

archs=$(xcrun -sdk iphoneos lipo -archs "$artifact")
if [ "$archs" != "arm64" ]; then
  echo "FAIL: expected arm64-only archive, got: $archs" >&2
  exit 1
fi

expected_members='__.SYMDEF
sift_affine_shape_wgsl.o
sift_dog_detect_wgsl.o
sift_dsp_descriptor_f16_wgsl.o
sift_dsp_descriptor_par_wgsl.o
sift_dsp_descriptor_wgsl.o
sift_dsp_mean_wgsl.o
sift_gray_to_f32_wgsl.o
sift_gss_blur_wgsl.o
sift_gss_resample_wgsl.o
sift_nonextrema_suppress_wgsl.o
sift_orientation_wgsl.o
canonical_feature_selector_v1.o
dsp_sift_gpu_c.o
dawn_kernel_harness.o
sift_extract_dawn.o
sift_pyramid_dawn.o'
actual_members=$(xcrun -sdk iphoneos ar -t "$artifact")
# Xcode/libtool may preserve the prior insertion order for an incremental
# archive while a clean archive uses a different order. Static-library member
# order is not part of this carrier's ABI; the exact multiset is. Sorting both
# sides still rejects missing, extra, or duplicate members without making a
# clean build fail solely because its insertion order differs.
expected_members_sorted=$(printf '%s\n' "$expected_members" | LC_ALL=C sort)
actual_members_sorted=$(printf '%s\n' "$actual_members" | LC_ALL=C sort)
if [ "$actual_members_sorted" != "$expected_members_sorted" ]; then
  echo "FAIL: archive-member manifest differs" >&2
  printf '%s\n' "$actual_members" >&2
  exit 1
fi

defined_symbols=$(xcrun -sdk iphoneos nm -gU "$artifact")
for symbol in \
  _aether_dsp_sift_extract_gpu \
  _aether_sed_gpu_timestamp_probe_v1 \
  _aether_sed_last_gpu_timestamp_frame_v1 \
  _aether_dsp_sift_take_last_gpu_timestamp_frame_v1
do
  count=$(
    printf '%s\n' "$defined_symbols" |
      /usr/bin/awk -v symbol="$symbol" '$3 == symbol { count += 1 } END { print count + 0 }'
  )
  if [ "$count" -ne 1 ]; then
    echo "FAIL: expected exactly one definition of $symbol, got $count" >&2
    exit 1
  fi
done

require_exact_string_count() {
  expected_count=$1
  needle=$2
  actual_count=$(strings "$artifact" | /usr/bin/grep -F -x -c "$needle" || true)
  if [ "$actual_count" -ne "$expected_count" ]; then
    echo "FAIL: expected $expected_count exact '$needle' string(s), got $actual_count" >&2
    exit 1
  fi
}

require_exact_string_count 1 "OFFICIAL_AETHER_GPU_TIMESTAMPS"
require_exact_string_count 0 "AETHER_GPU_TIMESTAMPS"
require_exact_string_count 1 "OFFICIAL_AETHER_FEATURE_SELECTION_POLICY"
require_exact_string_count 0 "AETHER_FEATURE_SELECTION_POLICY"
require_exact_string_count 1 "legacy_colmap_group_v1"
require_exact_string_count 1 "canonical_exact_8192_v1"
require_exact_string_count 1 "coverage_exact_8192_v1"
require_exact_string_count 1 "$EXPECTED_DAWN_REVISION"
require_exact_string_count 1 "$EXPECTED_DAWN_SHA256"

artifact_sha=$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{ print $1 }')
echo "PASS: pwofficial GPU carrier artifact SHA-256 $artifact_sha"
