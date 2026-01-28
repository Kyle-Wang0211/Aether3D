#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running all CI checks..."

echo "[1/4] Prohibit fatal patterns"
"$DIR/02_prohibit_fatal_patterns.sh"

echo "[2/4] Validate snapshot"
"$DIR/04_validate_snapshot.sh"

echo "[3/4] Document sync check"
"$DIR/05_doc_code_sync.sh"

echo "[4/4] Build and test"
"$DIR/01_build_and_test.sh"

echo ""
echo "==> All CI checks passed! ✅"
