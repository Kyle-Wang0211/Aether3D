#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$AETHER_CPP/.." && pwd)
BUILD_DIR=${AETHER_PRECLAMP_HOST_BUILD_DIR:-$AETHER_CPP/third_party/glomap_vendor/build-host}
TARGET=preclamp_instr_v1_production_integration_exe
EXE="$BUILD_DIR/$TARGET"
MANIFEST="$REPO_ROOT/openspec/changes/portable-sfm-speedup-v1/strict8192-instrumentation-p1-full-linkage-inputs.sha256"

[ -f "$MANIFEST" ] || {
  echo "FAIL P1 full link: missing instrumentation manifest $MANIFEST" >&2
  exit 1
}
(CDPATH= cd -- "$REPO_ROOT" && /usr/bin/shasum -a 256 -c "$MANIFEST")

cmake --build "$BUILD_DIR" --target "$TARGET" -j 8

for mode in overshoot isolation fallback canonical zero reject; do
  "$EXE" "$mode"
done

if /usr/bin/nm -u "$EXE" | /usr/bin/c++filt | \
    /usr/bin/grep -F -q 'preclamp_instr'; then
  echo "FAIL P1 full link: unresolved instrumentation function" >&2
  exit 1
fi
if /usr/bin/nm -gU "$EXE" | /usr/bin/c++filt | \
    /usr/bin/grep -F -q 'preclamp_instr'; then
  echo "FAIL P1 full link: public instrumentation symbol" >&2
  exit 1
fi
if ! /usr/bin/strings "$EXE" | \
    /usr/bin/grep -F -x -q 'OFFICIAL_AETHER_PRECLAMP_INSTR_V1'; then
  echo "FAIL P1 full link: official instrumentation environment key absent" >&2
  exit 1
fi
if /usr/bin/strings "$EXE" | \
    /usr/bin/grep -F -x -q 'AETHER_PRECLAMP_INSTR_V1'; then
  echo "FAIL P1 full link: self-test environment key leaked" >&2
  exit 1
fi

/usr/bin/cmp -s \
  "$AETHER_CPP/official_pipeline/src/official_dsp_sift_gpu_c.cc" \
  "$AETHER_CPP/third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc" || {
  echo "FAIL P1 full link: GPU source copies differ" >&2
  exit 1
}

echo "PASS instrumentation manifest, actual production chain, and full-link closure"
