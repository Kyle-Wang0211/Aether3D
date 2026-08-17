#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMAKE="$SCRIPT_DIR/../../third_party/glomap_vendor/CMakeLists.txt"
EXPECTED_CORE_SHA=1ac64d0a138f47f6285c36e6b4b257832ac3932264b8df664797cbeb2217bb04

core_block=$(awk '
  /set\(PWOFFICIAL_COLMAP_SRC/ {in_core=1}
  in_core {print}
  /VISIBILITY_INLINES_HIDDEN YES\)/ && in_core {exit}
' "$CMAKE")
overlay_block=$(awk '
  /option\(AETHER_BUILD_PRECLAMP_STAGE_B_PRIVATE/ {in_overlay=1}
  in_overlay {print}
  /^endif\(\)$/ && in_overlay {exit}
' "$CMAKE")

if grep -Eq 'official_preclamp_(instr|replay_driver)_v1\.cc|src/crypto/sha256\.cpp|AETHER_PRECLAMP_' \
    <<<"$core_block"; then
  echo "FAIL: Stage-B module, SHA, or definitions leak into pwofficial_core" >&2
  exit 1
fi
[[ $(grep -F -c 'official_preclamp_instr_v1.cc' <<<"$overlay_block") -eq 1 ]]
[[ $(grep -F -c 'official_preclamp_replay_driver_v1.cc' <<<"$overlay_block") -eq 1 ]]
[[ $(grep -F -c 'src/crypto/sha256.cpp' <<<"$overlay_block") -eq 1 ]]
[[ $(grep -F -c 'AETHER_PRECLAMP_INSTR_ENV_OFFICIAL=1' <<<"$overlay_block") -eq 1 ]]
[[ $(grep -F -c 'AETHER_PRECLAMP_SOURCE_CLOSURE_SHA256_V1=' <<<"$overlay_block") -eq 1 ]]
grep -Fq 'add_library(pwofficial_stage_b_private STATIC EXCLUDE_FROM_ALL' \
  <<<"$overlay_block"
grep -Fq '"Build the private strict-8192 Stage-B overlay" OFF' "$CMAKE"
grep -Fq "$EXPECTED_CORE_SHA" "$CMAKE"

echo "PASS Stage-B overlay is unique, option-gated, not-ALL, and external to frozen core"
