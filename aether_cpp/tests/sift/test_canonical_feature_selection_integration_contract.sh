#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
EXTRACTOR="$AETHER_CPP/tools/sift_extract_dawn.cc"
EXTRACTOR_HEADER="$AETHER_CPP/tools/sift_extract_dawn.h"
ENV_HEADER="$AETHER_CPP/tools/feature_selection_environment_v1.h"
BENCH_EMITTER="$AETHER_CPP/third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc"
OFFICIAL_EMITTER="$AETHER_CPP/official_pipeline/src/official_dsp_sift_gpu_c.cc"
ROOT_CMAKE="$AETHER_CPP/CMakeLists.txt"
VENDOR_CMAKE="$AETHER_CPP/third_party/glomap_vendor/CMakeLists.txt"
EXPECTED_LEGACY_CLAMP_SHA="855efe5d30732cf18b762d3e84c072b36c84931a97561d907a163c684dec7024"

require_text() {
  needle=$1
  file=$2
  if ! /usr/bin/grep -F -q "$needle" "$file"; then
    echo "FAIL: missing '$needle' in $file" >&2
    exit 1
  fi
}

actual_clamp_sha=$(
  /usr/bin/awk '
    /COLMAP clamp BEFORE descriptor/ { in_block = 1 }
    in_block { print }
    in_block && /mark\("clamp \(pre-desc\)"\);/ { exit }
  ' "$EXTRACTOR" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
)
if [ "$actual_clamp_sha" != "$EXPECTED_LEGACY_CLAMP_SHA" ]; then
  echo "FAIL: legacy clamp block drifted: $actual_clamp_sha" >&2
  exit 1
fi

require_text "FeatureSelectionPolicyV1 selection_policy" "$EXTRACTOR_HEADER"
require_text "FeatureSelectionPolicyReasonV1 selection_policy_reason" "$EXTRACTOR_HEADER"
require_text "feature_selection_policy()" "$EXTRACTOR_HEADER"
require_text "defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL) &&" "$ENV_HEADER"
require_text "defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)" "$ENV_HEADER"
require_text "OFFICIAL_AETHER_FEATURE_SELECTION_POLICY" "$ENV_HEADER"
require_text "AETHER_FEATURE_SELECTION_POLICY" "$ENV_HEADER"
require_text "BuildCanonicalCandidatesFromSidecarV1" "$EXTRACTOR"
require_text "SelectCanonicalFeaturesV1" "$EXTRACTOR"
require_text "SelectCoverageFeaturesV1" "$EXTRACTOR"
require_text "GatherSelectedSidecarByRowsV1" "$EXTRACTOR"
require_text "GatherCanonicalRowsV1" "$EXTRACTOR"
require_text "dawn_failed(\"affine\")" "$EXTRACTOR"
require_text "dawn_failed(\"orientation\")" "$EXTRACTOR"
require_text "out->raw_desc.clear()" "$EXTRACTOR"
require_text "static_cast<uint32_t>(candidates.size())" "$EXTRACTOR"
require_text "wgpu::BufferUsage::CopySrc" "$EXTRACTOR"
require_text "FeatureSelectionPolicyV1::kLegacyColmapGroup" "$BENCH_EMITTER"
require_text "deterministic_selection_requested" "$BENCH_EMITTER"
require_text "selector_policy=%u" "$BENCH_EMITTER"
require_text "selector_reason=%u" "$BENCH_EMITTER"
require_text "kCanonicalGpuUnavailable" "$BENCH_EMITTER"
require_text "std::iota" "$BENCH_EMITTER"
require_text "src/sfm/canonical_feature_selector_v1.cc" "$ROOT_CMAKE"
require_text "AETHER_FEATURE_SELECTION_ENV_OFFICIAL=1" "$ROOT_CMAKE"
require_text "canonical_feature_selector_v1.cc" "$VENDOR_CMAKE"

if ! /usr/bin/cmp -s "$BENCH_EMITTER" "$OFFICIAL_EMITTER"; then
  echo "FAIL: official and bench DSP-SIFT emitters diverged" >&2
  exit 1
fi

/bin/sh "$SCRIPT_DIR/test_feature_selection_environment_namespaces.sh"

echo "PASS canonical feature-selection integration source contract"
