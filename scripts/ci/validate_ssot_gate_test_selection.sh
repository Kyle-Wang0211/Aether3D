#!/bin/bash
# validate_ssot_gate_test_selection.sh
# Ensures SSOT CI gates only run explicitly selected tests
# Prevents accidental "run all tests" that would include non-SSOT failures

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

echo "🔒 Validating SSOT Gate Test Selection"
echo "Ensuring gates only run explicitly selected tests"
echo ""

ERRORS=0

# Check Gate 1
echo "Checking Gate 1 (Constitutional)..."
GATE1_SECTION=$(sed -n '/Run Gate 1 Tests/,/echo.*Gate 1 PASSED/p' "$WORKFLOW_FILE")
GATE1_FILTER_COUNT=$(echo "$GATE1_SECTION" | grep -c "\\--filter" || echo "0")

if [ "$GATE1_FILTER_COUNT" -ge 3 ]; then
    echo "  ✅ Gate 1 uses explicit --filter selectors ($GATE1_FILTER_COUNT filters)"
else
    echo "  ❌ Gate 1 has insufficient filters (found $GATE1_FILTER_COUNT, need >= 3)"
    ERRORS=$((ERRORS + 1))
fi

# Verify it's not a generic test command
if echo "$GATE1_SECTION" | grep -q "swift test.*-c.*build_config" && ! echo "$GATE1_SECTION" | grep -q "\\--filter"; then
    echo "  ❌ Gate 1 has 'swift test' without --filter (risks running all tests)"
    ERRORS=$((ERRORS + 1))
fi

# Check Gate 2
echo "Checking Gate 2 (Determinism & Trust)..."
GATE2_SECTION=$(sed -n '/Run Gate 2 Tests/,/echo.*Gate 2 PASSED/p' "$WORKFLOW_FILE")
GATE2_FILTER_COUNT=$(echo "$GATE2_SECTION" | grep -c "\\--filter" || echo "0")

if [ "$GATE2_FILTER_COUNT" -ge 5 ]; then
    echo "  ✅ Gate 2 uses explicit --filter selectors ($GATE2_FILTER_COUNT filters)"
else
    echo "  ❌ Gate 2 has insufficient filters (found $GATE2_FILTER_COUNT, need >= 5)"
    ERRORS=$((ERRORS + 1))
fi

# Verify it's not a generic test command
if echo "$GATE2_SECTION" | grep -q "swift test.*-c.*build_config" && ! echo "$GATE2_SECTION" | grep -q "\\--filter"; then
    echo "  ❌ Gate 2 has 'swift test' without --filter (risks running all tests)"
    ERRORS=$((ERRORS + 1))
fi

# Check for dangerous patterns
echo "Checking for dangerous patterns..."
if grep -q "swift test[^-]*$" "$WORKFLOW_FILE" || grep -q "swift test -c.*$" "$WORKFLOW_FILE" | grep -v "\\--filter"; then
    echo "  ⚠️  Warning: Found 'swift test' without --filter (may be in comments or other jobs)"
fi

# Ensure no generic test commands
if grep -q "swift test -c.*build_config.*$" "$WORKFLOW_FILE" | grep -v "\\--filter"; then
    echo "  ❌ Found generic 'swift test' without --filter in SSOT gates"
    ERRORS=$((ERRORS + 1))
fi

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ SSOT gates use explicit test selection (safe)"
    exit 0
else
    echo "❌ Found $ERRORS issue(s) with test selection"
    echo ""
    echo "Fix: Ensure all 'swift test' commands in Gate 1 and Gate 2 use --filter"
    echo "This prevents accidental execution of non-SSOT tests"
    exit 1
fi
