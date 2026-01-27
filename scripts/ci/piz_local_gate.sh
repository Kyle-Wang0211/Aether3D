#!/usr/bin/env bash
# piz_local_gate.sh
# PR1 PIZ Detection - Local Pre-Push Gate
# **Rule ID:** PIZ_CI_FAILURE_TAXONOMY_001
#
# This script runs all PIZ-related checks locally before allowing a push.
# It must pass completely (exit 0) for the push to proceed.
#
# Checks:
# 1. Lint PIZ thresholds (no inline thresholds, no forbidden imports)
# 2. Run PIZ tests (all tests must pass)
# 3. Generate canonical JSON output (PIZFixtureDumper)
# 4. Generate sealing evidence (PIZSealingEvidence)
#
# Usage: bash scripts/ci/piz_local_gate.sh
# Exit code: 0 if all checks pass, 1 if any check fails

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

FAILURES=0
ERRORS=()

echo "=== PR1 PIZ Local Pre-Push Gate ==="
echo ""

# Check 1: Lint PIZ thresholds
echo "[1/4] Running PIZ lint checks..."
if ! bash scripts/ci/lint_piz_thresholds.sh; then
    ERRORS+=("Lint checks failed")
    FAILURES=$((FAILURES + 1))
    echo "[PIZ_SPEC_VIOLATION] [1/4] Lint checks FAILED"
else
    echo "✅ [1/4] Lint checks passed"
fi
echo ""

# Check 2: Run PIZ tests
echo "[2/4] Running PIZ tests..."
if ! swift test --filter PIZ 2>&1 | tee /tmp/piz_test_output.log; then
    ERRORS+=("PIZ tests failed")
    FAILURES=$((FAILURES + 1))
    echo "[PIZ_SPEC_VIOLATION] [2/4] PIZ tests FAILED"
    echo "Last 20 lines of test output:"
    tail -20 /tmp/piz_test_output.log || true
else
    echo "✅ [2/4] PIZ tests passed"
fi
echo ""

# Check 3: Generate canonical JSON output
echo "[3/4] Running PIZFixtureDumper..."
mkdir -p artifacts/piz
if ! swift run PIZFixtureDumper 2>&1 | tee /tmp/piz_dumper_output.log; then
    ERRORS+=("PIZFixtureDumper failed")
    FAILURES=$((FAILURES + 1))
    echo "[PIZ_SPEC_VIOLATION] [3/4] PIZFixtureDumper FAILED"
    echo "Last 20 lines of dumper output:"
    tail -20 /tmp/piz_dumper_output.log || true
else
    if [ ! -f artifacts/piz/piz_canon_full.jsonl ]; then
        ERRORS+=("Canonical JSON file not generated")
        FAILURES=$((FAILURES + 1))
        echo "[PIZ_SPEC_VIOLATION] [3/4] Canonical JSON file missing"
    else
        echo "✅ [3/4] PIZFixtureDumper passed (file exists)"
    fi
fi
echo ""

# Check 4: Generate sealing evidence
echo "[4/4] Running PIZSealingEvidence..."
# Prepare artifacts for cross-platform comparison (simulate CI environment)
mkdir -p artifacts/macos artifacts/linux
if [ -f artifacts/piz/piz_canon_full.jsonl ]; then
    cp artifacts/piz/piz_canon_full.jsonl artifacts/macos/piz_canon_full.jsonl
    cp artifacts/piz/piz_canon_full.jsonl artifacts/linux/piz_canon_full.jsonl
fi

if ! swift run PIZSealingEvidence 2>&1 | tee /tmp/piz_evidence_output.log; then
    ERRORS+=("PIZSealingEvidence failed")
    FAILURES=$((FAILURES + 1))
    echo "[PIZ_SPEC_VIOLATION] [4/4] PIZSealingEvidence FAILED"
    echo "Last 20 lines of evidence output:"
    tail -20 /tmp/piz_evidence_output.log || true
else
    if [ ! -f artifacts/piz/sealing_evidence.json ] || [ ! -f artifacts/piz/sealing_evidence.md ]; then
        ERRORS+=("Sealing evidence files not generated")
        FAILURES=$((FAILURES + 1))
        echo "[PIZ_SPEC_VIOLATION] [4/4] Sealing evidence files missing"
    else
        echo "✅ [4/4] PIZSealingEvidence passed (files exist)"
    fi
fi
echo ""

# Summary
echo "=== Gate Summary ==="
if [ $FAILURES -eq 0 ]; then
    echo "PIZ local gate: PASS"
    exit 0
else
    echo "[PIZ_SPEC_VIOLATION] PIZ local gate: FAILED ($FAILURES check(s) failed)"
    echo ""
    echo "Failed checks:"
    for error in "${ERRORS[@]}"; do
        echo "  - $error"
    done
    echo ""
    echo "Please fix the issues above before pushing."
    echo "To bypass this gate (not recommended), use: git push --no-verify"
    exit 1
fi
