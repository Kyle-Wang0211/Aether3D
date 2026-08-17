#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CPP_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/pw-live-cloud-v2.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT HUP INT TERM

"${CXX:-c++}" \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$CPP_ROOT/third_party/eigen-install/include/eigen3" \
  "$SCRIPT_DIR/live_cloud_snapshot_diagnostics_v2_test.cc" \
  -o "$TEST_TMP/live_cloud_snapshot_diagnostics_v2_test"

"$TEST_TMP/live_cloud_snapshot_diagnostics_v2_test"
python3 "$SCRIPT_DIR/live_cloud_snapshot_diagnostics_v2_integration_test.py"
