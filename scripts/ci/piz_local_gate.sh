#!/usr/bin/env bash
set -euo pipefail

echo "=== PIZ LOCAL GATE (no-skip policy) ==="

echo "[1/4] lint_piz_thresholds"
bash scripts/ci/lint_piz_thresholds.sh

echo "[2/4] swift test --filter PIZ"
swift test --filter PIZ

echo "[3/4] PIZFixtureDumper"
mkdir -p artifacts/piz
PIZ_FIXTURES_PATH="${PIZ_FIXTURES_PATH:-fixtures/piz/nominal}"
PIZ_CANON_OUTPUT="${PIZ_CANON_OUTPUT:-artifacts/piz/piz_canon_full.jsonl}"
export PIZ_FIXTURES_PATH PIZ_CANON_OUTPUT
swift run PIZFixtureDumper

echo "[4/4] PIZSealingEvidence"
swift run PIZSealingEvidence

echo "✅ ALL LOCAL GATES PASSED"
