#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"

echo "==> Running all CI checks..."

echo "[1/11] Swift 6.2.3 pinning gate"
bash "$DIR/validate_swift_623_pinning.sh"

echo "[2/11] Prohibit fatal patterns"
"$DIR/02_prohibit_fatal_patterns.sh"

echo "[3/11] Validate snapshot"
"$DIR/04_validate_snapshot.sh"

echo "[4/11] Document sync check"
"$DIR/05_doc_code_sync.sh"

echo "[5/11] Legacy track retention"
"$DIR/validate_legacy_tracks_retention.sh"

echo "[6/11] Build and test"
"$DIR/01_build_and_test.sh"

echo "[7/11] Duplicate algorithm guard"
"$DIR/duplicate_algorithm_guard.sh"

echo "[8/11] Golden replay guard"
python3 "$REPO_ROOT/governance/scripts/golden_replay_guard.py"

echo "[9/11] Shadow dual-run guard"
python3 "$REPO_ROOT/governance/scripts/run_shadow_cutover.py" --require-guard-pass

echo "[10/11] C++ sanitizer matrix"
"$DIR/run_cpp_sanitizer_matrix.sh" --strict-if-ci

echo "[11/11] Third-party compliance gate"
"$DIR/validate_third_party_compliance.sh"

echo ""
echo "==> All CI checks passed! ✅"
