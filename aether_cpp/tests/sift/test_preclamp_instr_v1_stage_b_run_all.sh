#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
MANIFEST="$ROOT/openspec/changes/portable-sfm-speedup-v1/strict8192-stage-b-source-closure-inputs.sha256"
CORE="$ROOT/aether_cpp/official_pipeline/src/official_preclamp_instr_v1.cc"
DRIVER="$ROOT/aether_cpp/official_pipeline/src/official_preclamp_replay_driver_v1.cc"
SHA="$ROOT/aether_cpp/src/crypto/sha256.cpp"
SHIM="$ROOT/aether_cpp/official_pipeline/src/pwofficial_export_shim.c"
GATE="$ROOT/aether_cpp/official_pipeline/cmake/ValidateStageBSourceClosure.cmake"
EXPORTS="$SCRIPT_DIR/strict8192-stage-b-export-shim-baseline.exports"
BUILD_DIR=$(mktemp -d /private/tmp/preclamp-stage-b-run-all.XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

if [[ ! -f "$MANIFEST" ]]; then
  echo "FAIL: missing frozen Stage-B source-closure manifest: $MANIFEST" >&2
  exit 1
fi
(cd "$ROOT" && shasum -a 256 -c "${MANIFEST#$ROOT/}")
SOURCE_CLOSURE=$(shasum -a 256 "$MANIFEST" | awk '{print $1}')
if [[ ! "$SOURCE_CLOSURE" =~ ^[0-9a-f]{64}$ ]]; then
  echo "FAIL: invalid computed source-closure digest" >&2
  exit 1
fi

CXX=${CXX:-c++}
CC=${CC:-clang}
COMMON=(
  -std=c++17 -Wall -Wextra -Werror -pthread
  -DAETHER_PRECLAMP_INSTR_ENV_SELFTEST=1
  -DAETHER_PRECLAMP_INSTR_TEST_HOOKS=1
  "-DAETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1=\"$SOURCE_CLOSURE\""
  -I"$ROOT/aether_cpp/include"
  -I"$ROOT/aether_cpp/official_pipeline/src"
)

TESTS=(
  off
  eligibility
  writer
  parser
  parser_rejections
  join
  join_rejections
  seal
  sequence_races
  identity_paths
  io_faults
  zero_rows
  rework_stale_tls
  rework_negative_zero
  rework_inode_pin
  bridge
  bridge_off
)

for name in "${TESTS[@]}"; do
  source="$SCRIPT_DIR/test_preclamp_instr_v1_stage_b_${name}.cc"
  binary="$BUILD_DIR/test_${name}"
  if [[ ! -f "$source" ]]; then
    echo "FAIL: runner enumerates missing test: $source" >&2
    exit 1
  fi
  "$CXX" "${COMMON[@]}" "$source" "$CORE" "$SHA" -o "$binary"
  "$binary"
done

MAC_SDK=$(xcrun --sdk macosx --show-sdk-path)
"$CC" -std=c11 -Wall -Wextra -Werror -isysroot "$MAC_SDK" \
  -I"$ROOT/aether_cpp/official_pipeline/include" -c "$SHIM" \
  -o "$BUILD_DIR/pwofficial_export_shim.o"
"$CXX" "${COMMON[@]}" \
  "$SCRIPT_DIR/test_preclamp_instr_v1_stage_b_export_shim.cc" \
  "$CORE" "$SHA" "$BUILD_DIR/pwofficial_export_shim.o" \
  -Wl,-undefined,dynamic_lookup -o "$BUILD_DIR/test_export_shim"
"$BUILD_DIR/test_export_shim"

nm -g "$BUILD_DIR/pwofficial_export_shim.o" |
  awk '/ T _pwofficial_/ {sub(/^.* _/, ""); print}' | sort -u \
  > "$BUILD_DIR/current.exports"
diff -u "$EXPORTS" "$BUILD_DIR/current.exports"

SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
"$CC" -target arm64-apple-ios14.0-simulator -std=c11 \
  -Wall -Wextra -Werror -isysroot "$SIM_SDK" \
  -I"$ROOT/aether_cpp/official_pipeline/include" -c "$SHIM" \
  -o "$BUILD_DIR/pwofficial_export_shim_simulator.o"
if nm -u "$BUILD_DIR/pwofficial_export_shim_simulator.o" |
    rg 'aether_preclamp_stage_b_bridge'; then
  echo "FAIL: simulator shim has unresolved Stage-B bridge symbols" >&2
  exit 1
fi

"$CXX" "${COMMON[@]}" -fvisibility=hidden -fvisibility-inlines-hidden \
  -c "$CORE" -o "$BUILD_DIR/stage_b_private.o"
for symbol in create thermal pre_add add remove finalize free; do
  if ! nm -m "$BUILD_DIR/stage_b_private.o" |
      rg -q "private external _aether_preclamp_stage_b_bridge_${symbol}$"; then
    echo "FAIL: bridge symbol is not hidden: $symbol" >&2
    exit 1
  fi
done

"$CXX" "${COMMON[@]}" -fvisibility=hidden -fvisibility-inlines-hidden \
  -c "$DRIVER" -o "$BUILD_DIR/phase_b_replay_driver.o"
for symbol in create add_gray seal destroy; do
  if ! nm -m "$BUILD_DIR/phase_b_replay_driver.o" |
      rg -q "private external _aether_preclamp_phase_b_replay_${symbol}_v1$"; then
    echo "FAIL: replay C bridge symbol is not hidden: $symbol" >&2
    exit 1
  fi
done

for value in __UNSET__ '' abc \
  AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
  if [[ "$value" == __UNSET__ ]]; then
    if cmake -P "$GATE" >"$BUILD_DIR/gate-invalid.log" 2>&1; then
      echo "FAIL: source-closure gate accepted missing value" >&2
      exit 1
    fi
  elif cmake -DAETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1="$value" \
      -P "$GATE" >"$BUILD_DIR/gate-invalid.log" 2>&1; then
    echo "FAIL: source-closure gate accepted invalid value: $value" >&2
    exit 1
  fi
done
cmake -DAETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1="$SOURCE_CLOSURE" \
  -P "$GATE"
bash "$SCRIPT_DIR/test_preclamp_instr_v1_stage_b_build_isolation.sh"

echo "PASS Stage-B fail-fast suite source_closure=$SOURCE_CLOSURE"
