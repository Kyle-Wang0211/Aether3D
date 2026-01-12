#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Running all CI checks..."

echo "[1/5] Prohibit fatal patterns"
"$DIR/02_prohibit_fatal_patterns.sh"

echo "[2/5] SSOT declaration check"
"$DIR/03_require_ssot_declaration.sh"

echo "[3/5] Validate snapshot"
"$DIR/04_validate_snapshot.sh"

echo "[4/5] Document sync check"
"$DIR/05_doc_code_sync.sh"

echo "[5/5] Build and test"
"$DIR/01_build_and_test.sh"

echo ""
echo "==> All CI checks passed! ✅"

