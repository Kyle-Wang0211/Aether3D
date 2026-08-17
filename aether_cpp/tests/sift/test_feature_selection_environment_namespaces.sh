#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AETHER_CPP=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SOURCE="$SCRIPT_DIR/test_feature_selection_environment_namespace_compile.cpp"
CXX_BIN=${CXX:-c++}
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aether-feature-selection-env.XXXXXX")

compile_arm() {
  name=$1
  shift
  "$CXX_BIN" -std=c++20 -I"$AETHER_CPP/tools" "$@" \
    "$SOURCE" -c -o "$TMP_DIR/$name.o"
}

compile_arm official -DAETHER_FEATURE_SELECTION_ENV_OFFICIAL=1
compile_arm selftest -DAETHER_FEATURE_SELECTION_ENV_SELFTEST=1

if compile_arm both \
    -DAETHER_FEATURE_SELECTION_ENV_OFFICIAL=1 \
    -DAETHER_FEATURE_SELECTION_ENV_SELFTEST=1 >/dev/null 2>&1; then
  echo "FAIL: both feature-selection namespaces compiled" >&2
  exit 1
fi

if compile_arm neither >/dev/null 2>&1; then
  echo "FAIL: missing feature-selection namespace compiled" >&2
  exit 1
fi

echo "PASS feature-selection environment namespace compile contract"
