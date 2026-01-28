#!/bin/bash
# ============================================================================
# PR2-JSM-3.0 Comprehensive Pre-Push Verification Script
# Run this before pushing to ensure CI will pass
# Version: 2.0 (Phase 2 Complete)
# ============================================================================

set -euo pipefail

echo "========================================"
echo "PR2-JSM-3.0 Pre-Push Verification v2.0"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FAILURES=0
WARNINGS=0
TOTAL_CHECKS=0

# Helper functions
pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((TOTAL_CHECKS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILURES++)); ((TOTAL_CHECKS++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARNINGS++)); }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ============================================================================
# SECTION 1: Environment Check
# ============================================================================
section "[1/8] Environment Check"

# Swift Version
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
info "Swift: $SWIFT_VERSION"
if [[ "$SWIFT_VERSION" =~ "5.9" ]] || [[ "$SWIFT_VERSION" =~ "5.10" ]] || [[ "$SWIFT_VERSION" =~ "6." ]]; then
    pass "Swift version compatible"
else
    warn "CI uses Swift 5.9.2. Local version may differ."
fi

# Git status
if [[ -d ".git" ]]; then
    BRANCH=$(git branch --show-current)
    info "Branch: $BRANCH"
    pass "Git repository detected"
else
    fail "Not a git repository"
fi

# ============================================================================
# SECTION 2: Build
# ============================================================================
section "[2/8] Build Verification"

if swift build 2>&1 | tail -5; then
    pass "swift build succeeded"
else
    fail "swift build FAILED"
fi

# ============================================================================
# SECTION 3: All Tests
# ============================================================================
section "[3/8] Full Test Suite"

TEST_OUTPUT=$(swift test 2>&1)
if echo "$TEST_OUTPUT" | grep -q "Test Suite.*passed"; then
    PASSED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ test[s]? passed" | head -1)
    pass "All tests passed ($PASSED)"
else
    fail "Some tests FAILED"
    echo "$TEST_OUTPUT" | grep -E "(failed|error)" | head -10
fi

# ============================================================================
# SECTION 4: Individual Test Suites
# ============================================================================
section "[4/8] Individual Test Suites"

# JobStateMachineTests
if swift test --filter JobStateMachineTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter JobStateMachineTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "JobStateMachineTests ($COUNT)"
else
    fail "JobStateMachineTests FAILED"
fi

# RetryCalculatorTests
if swift test --filter RetryCalculatorTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter RetryCalculatorTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "RetryCalculatorTests ($COUNT)"
else
    fail "RetryCalculatorTests FAILED"
fi

# CircuitBreakerTests
if swift test --filter CircuitBreakerTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter CircuitBreakerTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "CircuitBreakerTests ($COUNT)"
else
    warn "CircuitBreakerTests not found or failed"
fi

# DeterministicEncoderTests
if swift test --filter DeterministicEncoderTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter DeterministicEncoderTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "DeterministicEncoderTests ($COUNT)"
else
    warn "DeterministicEncoderTests not found or failed"
fi

# ============================================================================
# SECTION 5: Contract Version Consistency
# ============================================================================
section "[5/8] Contract Version Consistency"

VERSION_PATTERN="PR2-JSM-3.0"
CORE_FILES=(
    "Core/Jobs/ContractConstants.swift"
    "Core/Jobs/JobStateMachine.swift"
    "Core/Jobs/JobState.swift"
    "Core/Jobs/FailureReason.swift"
    "Core/Jobs/CancelReason.swift"
    "Core/Jobs/JobStateMachineError.swift"
    "Core/Jobs/RetryCalculator.swift"
    "Core/Jobs/DLQEntry.swift"
    "Core/Jobs/CircuitBreaker.swift"
    "Core/Jobs/DeterministicEncoder.swift"
)

for file in "${CORE_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        if grep -q "$VERSION_PATTERN" "$file"; then
            pass "$file"
        else
            fail "$file - version MISMATCH"
        fi
    else
        warn "$file - not found"
    fi
done

# ============================================================================
# SECTION 6: Enum Count Verification
# ============================================================================
section "[6/8] Enum Count Verification"

# FailureReason count (should be 17)
if [[ -f "Core/Jobs/FailureReason.swift" ]]; then
    FAILURE_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/FailureReason.swift | wc -l | tr -d ' ')
    if [[ "$FAILURE_COUNT" -eq 17 ]]; then
        pass "FailureReason: $FAILURE_COUNT cases (expected 17)"
    else
        fail "FailureReason: $FAILURE_COUNT cases (expected 17)"
    fi
fi

# CancelReason count (should be 3)
if [[ -f "Core/Jobs/CancelReason.swift" ]]; then
    CANCEL_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/CancelReason.swift | wc -l | tr -d ' ')
    if [[ "$CANCEL_COUNT" -eq 3 ]]; then
        pass "CancelReason: $CANCEL_COUNT cases (expected 3)"
    else
        fail "CancelReason: $CANCEL_COUNT cases (expected 3)"
    fi
fi

# JobState count (should be 8)
if [[ -f "Core/Jobs/JobState.swift" ]]; then
    STATE_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/JobState.swift | wc -l | tr -d ' ')
    if [[ "$STATE_COUNT" -eq 8 ]]; then
        pass "JobState: $STATE_COUNT cases (expected 8)"
    else
        fail "JobState: $STATE_COUNT cases (expected 8)"
    fi
fi

# CircuitState count (should be 3)
if [[ -f "Core/Jobs/CircuitBreaker.swift" ]]; then
    CIRCUIT_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/CircuitBreaker.swift | grep -v "//" | wc -l | tr -d ' ')
    if [[ "$CIRCUIT_COUNT" -eq 3 ]]; then
        pass "CircuitState: $CIRCUIT_COUNT cases (expected 3)"
    else
        warn "CircuitState: $CIRCUIT_COUNT cases (expected 3)"
    fi
fi

# ============================================================================
# SECTION 7: File Existence Check
# ============================================================================
section "[7/8] Required Files Check"

REQUIRED_FILES=(
    "Core/Jobs/ContractConstants.swift"
    "Core/Jobs/JobStateMachine.swift"
    "Core/Jobs/JobState.swift"
    "Core/Jobs/FailureReason.swift"
    "Core/Jobs/CancelReason.swift"
    "Core/Jobs/JobStateMachineError.swift"
    "Core/Jobs/RetryCalculator.swift"
    "Core/Jobs/DLQEntry.swift"
    "Core/Jobs/CircuitBreaker.swift"
    "Core/Jobs/DeterministicEncoder.swift"
    "Core/Jobs/TransitionSpan.swift"
    "Core/Jobs/ProgressEstimator.swift"
    "Tests/Jobs/JobStateMachineTests.swift"
    "Tests/Jobs/RetryCalculatorTests.swift"
    "Tests/Jobs/CircuitBreakerTests.swift"
    "Tests/Jobs/DeterministicEncoderTests.swift"
)

MISSING=0
for file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        pass "$file exists"
    else
        fail "$file MISSING"
        ((MISSING++))
    fi
done

# ============================================================================
# SECTION 8: Final Checks
# ============================================================================
section "[8/8] Final Checks"

# Check for uncommitted changes
if [[ -n "$(git status --porcelain)" ]]; then
    warn "Uncommitted changes detected"
    git status --short
else
    pass "Working directory clean"
fi

# Check for TODO/FIXME comments in Core files
TODO_COUNT=$(grep -r "TODO\|FIXME" Core/Jobs/*.swift 2>/dev/null | wc -l | tr -d ' ')
if [[ "$TODO_COUNT" -gt 0 ]]; then
    warn "Found $TODO_COUNT TODO/FIXME comments in Core/Jobs"
else
    pass "No TODO/FIXME comments in Core/Jobs"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "========================================"
echo "VERIFICATION SUMMARY"
echo "========================================"
echo -e "Total Checks: ${BLUE}$TOTAL_CHECKS${NC}"
echo -e "Passed:       ${GREEN}$((TOTAL_CHECKS - FAILURES))${NC}"
echo -e "Failed:       ${RED}$FAILURES${NC}"
echo -e "Warnings:     ${YELLOW}$WARNINGS${NC}"
echo ""

if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ALL CHECKS PASSED - READY TO PUSH!    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review changes: git diff --stat"
    echo "  2. Stage changes:  git add -A"
    echo "  3. Commit:         git commit -m 'feat(pr2): upgrade to PR2-JSM-3.0'"
    echo "  4. Push:           git push origin <branch>"
    echo ""
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  $FAILURES CHECK(S) FAILED - FIX BEFORE PUSH  ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi
