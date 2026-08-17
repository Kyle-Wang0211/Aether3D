#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
HEADER="$AETHER_CPP/official_pipeline/src/official_preclamp_instr_v1.h"
IMPLEMENTATION="$AETHER_CPP/official_pipeline/src/official_preclamp_instr_v1.cc"
SHA256_IMPLEMENTATION="$AETHER_CPP/src/crypto/sha256.cpp"
EXTRACTOR="$AETHER_CPP/tools/sift_extract_dawn.cc"
PUBLIC_HEADER="$AETHER_CPP/official_pipeline/include/aether_sfm_c.h"
EXPECTED_LEGACY_CLAMP_SHA=855efe5d30732cf18b762d3e84c072b36c84931a97561d907a163c684dec7024
CXX=${CXX:-c++}
TMP=$(mktemp -d /private/tmp/preclamp-r1.XXXXXX)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

require_text() {
  needle=$1
  file=$2
  if ! /usr/bin/grep -F -q "$needle" "$file"; then
    echo "FAIL R1: missing '$needle' in $file" >&2
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
[ "$actual_clamp_sha" = "$EXPECTED_LEGACY_CLAMP_SHA" ] || {
  echo "FAIL R1: legacy clamp block drifted: $actual_clamp_sha" >&2
  exit 1
}

require_text '#include "../official_pipeline/src/official_preclamp_instr_v1.h"' "$EXTRACTOR"
require_text '#if defined(AETHER_FEATURE_SELECTION_ENV_OFFICIAL)' "$EXTRACTOR"
require_text '#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1' "$EXTRACTOR"
require_text '#elif defined(AETHER_FEATURE_SELECTION_ENV_SELFTEST)' "$EXTRACTOR"
require_text '#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1' "$EXTRACTOR"
require_text 'PendingDiscardReason::kZeroCandidate' "$EXTRACTOR"
require_text 'aether_preclamp_instr_v1::BeginLegacyClamp(n_oriented);' "$EXTRACTOR"
require_text 'aether_preclamp_instr_v1::UpdateLegacyClampResult(n_desc);' "$EXTRACTOR"
require_text 'static thread_local ThreadState state;' "$IMPLEMENTATION"
if /usr/bin/grep -F -q 'thread_local' "$HEADER"; then
  echo "FAIL R1: header exposes TLS state" >&2
  exit 1
fi

if /usr/bin/grep -E -q 'harness\.(dispatch|readback|upload)|copy_to_staging|read_u32\(|wgpu::' "$HEADER"; then
  echo "FAIL R1: instrumentation module contains GPU dispatch/readback surface" >&2
  exit 1
fi
if /usr/bin/grep -F -q 'preclamp_instr' "$PUBLIC_HEADER"; then
  echo "FAIL R1: instrumentation leaked into stable public C ABI" >&2
  exit 1
fi

cat >"$TMP/official.cc" <<EOF
#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1
#include "$HEADER"
#include <cstring>
int main() { return std::strcmp(aether_preclamp_instr_v1::EnvKey(),
                                "OFFICIAL_AETHER_PRECLAMP_INSTR_V1"); }
EOF
cat >"$TMP/selftest.cc" <<EOF
#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "$HEADER"
#include <cstring>
int main() { return std::strcmp(aether_preclamp_instr_v1::EnvKey(),
                                "AETHER_PRECLAMP_INSTR_V1"); }
EOF
cat >"$TMP/both.cc" <<EOF
#define AETHER_PRECLAMP_INSTR_ENV_OFFICIAL 1
#define AETHER_PRECLAMP_INSTR_ENV_SELFTEST 1
#include "$HEADER"
int main() { return 0; }
EOF
cat >"$TMP/neither.cc" <<EOF
#include "$HEADER"
int main() { return 0; }
EOF

"$CXX" -std=c++17 -O0 -DAETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1 \
  -I"$AETHER_CPP/include" \
  "$TMP/official.cc" "$IMPLEMENTATION" "$SHA256_IMPLEMENTATION" \
  -o "$TMP/official"
"$CXX" -std=c++17 -O0 -DAETHER_PRECLAMP_INSTR_ENV_SELFTEST=1 \
  -I"$AETHER_CPP/include" \
  "$TMP/selftest.cc" "$IMPLEMENTATION" "$SHA256_IMPLEMENTATION" \
  -o "$TMP/selftest"
"$TMP/official"
"$TMP/selftest"
if "$CXX" -std=c++17 -c "$TMP/both.cc" -o "$TMP/both.o" 2>/dev/null; then
  echo "FAIL R1: both env namespaces compiled" >&2
  exit 1
fi
if "$CXX" -std=c++17 -c "$TMP/neither.cc" -o "$TMP/neither.o" 2>/dev/null; then
  echo "FAIL R1: absent env namespace compiled" >&2
  exit 1
fi
if /usr/bin/strings "$TMP/official" | /usr/bin/grep -Fx -q 'AETHER_PRECLAMP_INSTR_V1'; then
  echo "FAIL R1: official artifact contains selftest env key" >&2
  exit 1
fi
if /usr/bin/strings "$TMP/selftest" | /usr/bin/grep -F -q 'OFFICIAL_AETHER_PRECLAMP_INSTR_V1'; then
  echo "FAIL R1: selftest artifact contains official env key" >&2
  exit 1
fi

echo "PASS R1 source/artifact contract; production ordered matches/DB/PLY equivalence is P3-pending"
