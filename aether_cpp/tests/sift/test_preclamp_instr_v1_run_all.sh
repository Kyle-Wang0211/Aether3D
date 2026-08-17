#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CXX=${CXX:-c++}
OUT_DIR=${PRECLAMP_TEST_OUT_DIR:-/private/tmp/preclamp_instr_v1_tests}
IMPLEMENTATION="$SCRIPT_DIR/../../official_pipeline/src/official_preclamp_instr_v1.cc"
SHA256_IMPLEMENTATION="$SCRIPT_DIR/../../src/crypto/sha256.cpp"
AETHER_INCLUDE="$SCRIPT_DIR/../../include"
SOURCE_CLOSURE_MANIFEST="$SCRIPT_DIR/../../../openspec/changes/portable-sfm-speedup-v1/strict8192-stage-b-source-closure-inputs.sha256"
SOURCE_CLOSURE=$(/usr/bin/shasum -a 256 "$SOURCE_CLOSURE_MANIFEST" | /usr/bin/awk '{print $1}')
mkdir -p "$OUT_DIR"

run_cc() {
  source=$1
  name=$(basename "$source" .cc)
  "$CXX" -std=c++17 -Wall -Wextra -Werror -pthread \
    -DAETHER_PRECLAMP_INSTR_ENV_SELFTEST=1 \
    -DAETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1=\"$SOURCE_CLOSURE\" \
    -I"$AETHER_INCLUDE" \
    "$source" "$IMPLEMENTATION" "$SHA256_IMPLEMENTATION" \
    -o "$OUT_DIR/$name"
  "$OUT_DIR/$name"
}

run_driver_cc() {
  source=$1
  name=$(basename "$source" .cc)
  "$CXX" -std=c++17 -Wall -Wextra -Werror -pthread \
    -DAETHER_PRECLAMP_INSTR_ENV_SELFTEST=1 \
    -DAETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1=\"$SOURCE_CLOSURE\" \
    -I"$AETHER_INCLUDE" \
    "$source" \
    "$SCRIPT_DIR/../../official_pipeline/src/official_preclamp_replay_driver_v1.cc" \
    "$IMPLEMENTATION" "$SHA256_IMPLEMENTATION" \
    -o "$OUT_DIR/$name"
  "$OUT_DIR/$name"
}

run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_off_contract.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r1_thread_ownership.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r2_zero_guard.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r3_noncontiguous.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r4_duplicate_tie.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r5_replay_identity.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r6_union_superset.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r7_fixed12288.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r8_union_mapping.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r9_missing_descriptor.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_p1_lifecycle.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_p1_output_cap_seal.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_p1_replay_amendment.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_p1_descriptor_conflict.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r22_phase_b_headroom.cc"
run_driver_cc "$SCRIPT_DIR/test_preclamp_replay_driver_v1_off.cc"
run_driver_cc "$SCRIPT_DIR/test_preclamp_replay_driver_v1_on.cc"
run_driver_cc "$SCRIPT_DIR/test_preclamp_replay_bridge_v1_off.cc"
run_driver_cc "$SCRIPT_DIR/test_preclamp_replay_bridge_v1_on.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r10_capacity.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r11_resume.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r12_transaction.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r13_corruption.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r13_noncanonical_promotion.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r14_promotion.cc"
run_cc "$SCRIPT_DIR/test_preclamp_instr_v1_r15_exact_comparator.cc"
/bin/sh "$SCRIPT_DIR/test_preclamp_instr_v1_r1_source_contract.sh"
/bin/sh "$SCRIPT_DIR/test_preclamp_instr_v1_r2_zero_guard.sh"
/bin/sh "$SCRIPT_DIR/test_preclamp_instr_v1_p1_source_chain.sh"
/bin/sh "$SCRIPT_DIR/test_preclamp_instr_v1_p1_symbol_contract.sh"
/bin/sh "$SCRIPT_DIR/test_preclamp_instr_v1_r12_io_retry_source_contract.sh"

echo "PASS preclamp instrumentation R1(host/source) and R2-R15"
