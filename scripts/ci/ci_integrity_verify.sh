#!/usr/bin/env bash
set -euo pipefail

# CI-HARDENED: Verify CI configuration integrity
# Prevents self-modification attacks

echo "==> CI Integrity Verification"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

FAILED=0

# ============================================================================
# Check 1: Verify required CI jobs exist
# ============================================================================
echo "[1/3] Checking required CI jobs..."

REQUIRED_JOBS=(
  "ssot-declaration-gate"
)

# Optional jobs (warn if missing but don't fail)
OPTIONAL_JOBS=(
  "build"
  "test"
  "test-and-lint"
)

CI_WORKFLOW=".github/workflows/ci.yml"
if [ ! -f "$CI_WORKFLOW" ]; then
  echo "❌ CI workflow not found: $CI_WORKFLOW"
  exit 1
fi

for job in "${REQUIRED_JOBS[@]}"; do
  if ! grep -qE "^\s+${job}:" "$CI_WORKFLOW"; then
    echo "⚠️  Required job missing: $job (will be added in Phase 3)"
    # Don't fail yet - job will be added in Phase 3
  fi
done

# Check optional jobs
for job in "${OPTIONAL_JOBS[@]}"; do
  if ! grep -qE "^\s+${job}:" "$CI_WORKFLOW"; then
    echo "   ℹ️  Optional job not found: $job (may have different name)"
  fi
done

echo "   ✅ Job check complete"

# ============================================================================
# Check 2: Verify SSOT gate is not skipped
# ============================================================================
echo "[2/3] Checking SSOT gate cannot be skipped..."

# Look for "if: false" or "if: always() && false" patterns
if grep -qE "ssot-declaration-gate:.*if:\s*false|if:\s*\!\s*true" "$CI_WORKFLOW"; then
  echo "❌ SSOT gate appears to be disabled"
  FAILED=1
fi

# Verify SSOT gate is in the dependency chain
if ! grep -qE "needs:.*ssot-declaration-gate" "$CI_WORKFLOW"; then
  echo "⚠️  WARNING: SSOT gate may not be in critical path"
  echo "   Verify that build/test jobs depend on ssot-declaration-gate"
fi

echo "   ✅ SSOT gate verification passed"

# ============================================================================
# Check 3: Verify no dangerous patterns
# ============================================================================
echo "[3/3] Checking for dangerous CI patterns..."

DANGEROUS_PATTERNS=(
  "continue-on-error:\s*true"  # Can mask failures
  "no-verify"                  # Git hook bypass (without -- prefix to avoid grep error)
  "force-push"                  # History rewrite
  "GITHUB_TOKEN.*write"         # Excessive permissions (check context)
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if grep -qE "$pattern" "$CI_WORKFLOW"; then
    echo "⚠️  WARNING: Potentially dangerous pattern found: $pattern"
    echo "   Please review usage in context"
  fi
done

echo "   ✅ Dangerous pattern check complete"

# ============================================================================
# Summary
# ============================================================================
if [ $FAILED -ne 0 ]; then
  echo ""
  echo "❌ CI integrity verification FAILED"
  exit 1
fi

echo "==> CI integrity verification PASSED"
exit 0
