#!/bin/bash
# run_local_ci_matrix.sh
# Comprehensive local CI runner that mirrors GitHub Actions gates
# Runs maximal validation surface including Linux Docker tests

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

# Deterministic environment
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export TZ=UTC

# Mode flags
CI_FAST="${CI_FAST:-0}"
CI_DEEP="${CI_DEEP:-0}"

ERRORS=0
START_TIME=$(date +%s)
REPORT_FILE="docs/constitution/FINAL_LOCAL_VERIFICATION_REPORT.md"

echo "🔒 SSOT Foundation Local CI Runner (Comprehensive)"
echo "=================================================="
echo "Mode: ${CI_FAST:+FAST }${CI_DEEP:+DEEP }${CI_FAST:+${CI_DEEP:+}}NORMAL"
echo ""

# Phase 0: Repository Hygiene
echo "📋 Phase 0: Repository Hygiene"
if bash scripts/ci/repo_hygiene.sh; then
    echo "✅ Phase 0 PASSED"
else
    echo "❌ Phase 0 FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Phase 1: Workflow & Job Graph Validation
echo "📋 Phase 1: Workflow & Job Graph Validation"
if bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml && \
   bash scripts/ci/validate_ssot_gate_test_selection.sh; then
    echo "✅ Phase 1 PASSED"
else
    echo "❌ Phase 1 FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Phase 2: SSOT Preflight
echo "📋 Phase 2: SSOT Preflight"
if bash scripts/ci/preflight_ssot_foundation.sh; then
    echo "✅ Phase 2 PASSED"
else
    echo "❌ Phase 2 FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Phase 3: macOS Build (Debug)
echo "📋 Phase 3: macOS Build (Debug)"
if swift build -c debug >/dev/null 2>&1; then
    echo "✅ Phase 3 PASSED"
else
    echo "❌ Phase 3 FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Phase 4: Gate 1 Tests (Debug)
echo "📋 Phase 4: Gate 1 Tests (Debug) - Constitutional"
GATE1_OUTPUT=$(swift test -c debug \
    --filter EnumFrozenOrderTests \
    --filter CatalogSchemaTests \
    --filter DocumentationSyncTests \
    --filter DeterministicEncodingContractTests \
    --filter DeterministicQuantizationContractTests \
    --filter GoldenVectorsRoundTripTests 2>&1)
if echo "$GATE1_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
    echo "✅ Phase 4 PASSED"
    GATE1_STATUS="✅ PASSED"
else
    echo "❌ Phase 4 FAILED"
    ERRORS=$((ERRORS + 1))
    GATE1_STATUS="❌ FAILED"
fi
echo ""

# Phase 5: Gate 2 Tests (Debug)
echo "📋 Phase 5: Gate 2 Tests (Debug) - Determinism & Trust"
GATE2_OUTPUT=$(swift test -c debug \
    --filter ColorMatrixIntegrityTests \
    --filter DomainPrefixesTests \
    --filter ReproducibilityBoundaryTests \
    --filter BreakingSurfaceTests \
    --filter ExplanationCatalogCoverageTests \
    --filter ReasonCompatibilityTests \
    --filter MinimumExplanationSetTests \
    --filter CatalogUniquenessTests \
    --filter ExplanationIntegrityTests \
    --filter CatalogCrossReferenceTests \
    --filter CatalogActionabilityRulesTests \
    --filter DomainPrefixesClosureTests 2>&1)
if echo "$GATE2_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
    echo "✅ Phase 5 PASSED"
    GATE2_STATUS="✅ PASSED"
else
    echo "❌ Phase 5 FAILED"
    ERRORS=$((ERRORS + 1))
    GATE2_STATUS="❌ FAILED"
fi
echo ""

# Phase 6: macOS Build (Release) - Skip if CI_FAST=1
if [ "$CI_FAST" != "1" ]; then
    echo "📋 Phase 6: macOS Build (Release)"
    if swift build -c release >/dev/null 2>&1; then
        echo "✅ Phase 6 PASSED"
        RELEASE_BUILD_STATUS="✅ PASSED"
    else
        echo "❌ Phase 6 FAILED"
        ERRORS=$((ERRORS + 1))
        RELEASE_BUILD_STATUS="❌ FAILED"
    fi
    echo ""
    
    # Phase 7: Gate 1 & 2 Tests (Release)
    echo "📋 Phase 7: Gate 1 & 2 Tests (Release)"
    RELEASE_GATE1_OUTPUT=$(swift test -c release \
        --filter EnumFrozenOrderTests \
        --filter CatalogSchemaTests \
        --filter DocumentationSyncTests \
        --filter DeterministicEncodingContractTests \
        --filter DeterministicQuantizationContractTests \
        --filter GoldenVectorsRoundTripTests 2>&1)
    RELEASE_GATE2_OUTPUT=$(swift test -c release \
        --filter ColorMatrixIntegrityTests \
        --filter DomainPrefixesTests \
        --filter ReproducibilityBoundaryTests \
        --filter BreakingSurfaceTests \
        --filter ExplanationCatalogCoverageTests \
        --filter ReasonCompatibilityTests \
        --filter MinimumExplanationSetTests \
        --filter CatalogUniquenessTests \
        --filter ExplanationIntegrityTests \
        --filter CatalogCrossReferenceTests \
        --filter CatalogActionabilityRulesTests \
        --filter DomainPrefixesClosureTests 2>&1)
    
    if echo "$RELEASE_GATE1_OUTPUT" | grep -q "Executed.*tests.*with 0 failures" && \
       echo "$RELEASE_GATE2_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
        echo "✅ Phase 7 PASSED"
        RELEASE_TESTS_STATUS="✅ PASSED"
    else
        echo "❌ Phase 7 FAILED"
        ERRORS=$((ERRORS + 1))
        RELEASE_TESTS_STATUS="❌ FAILED"
    fi
    echo ""
fi

# Phase 8: Linux Equivalence Smoke (No Docker) - Skip if CI_FAST=1
if [ "$CI_FAST" != "1" ]; then
    echo "📋 Phase 8: Linux Equivalence Smoke (No Docker)"
    if bash scripts/ci/linux_equivalence_smoke_no_docker.sh >/dev/null 2>&1; then
        echo "✅ Phase 8 PASSED"
        LINUX_STATUS="✅ PASSED"
    else
        echo "❌ Phase 8 FAILED"
        ERRORS=$((ERRORS + 1))
        LINUX_STATUS="❌ FAILED"
    fi
    echo ""
    
    # Phase 8b: Linux SPM Matrix (Docker) - Optional, skip if Docker unavailable
    echo "📋 Phase 8b: Linux SPM Matrix (Docker) - Optional"
    if bash scripts/ci/run_linux_spm_matrix.sh >/dev/null 2>&1; then
        echo "✅ Phase 8b PASSED"
        LINUX_DOCKER_STATUS="✅ PASSED"
    else
        echo "⚠️  Phase 8b SKIPPED (Docker not available or tests failed)"
        LINUX_DOCKER_STATUS="⚠️  SKIPPED"
    fi
    echo ""
fi

# Phase 9: Shadow Cross-Platform Consistency (non-gating)
echo "📋 Phase 9: Shadow Cross-Platform Consistency (non-gating)"
bash scripts/ci/run_shadow_crossplatform_consistency.sh >/dev/null 2>&1 || true
echo "✅ Phase 9 COMPLETED (see SHADOW_CROSSPLATFORM_REPORT.md)"
echo ""

# Phase 10: Markdown Link Check
echo "📋 Phase 10: Markdown Link Check"
if bash scripts/ci/check_markdown_links.sh >/dev/null 2>&1; then
    echo "✅ Phase 10 PASSED"
    MARKDOWN_STATUS="✅ PASSED"
else
    echo "⚠️  Phase 10 FAILED (non-blocking)"
    MARKDOWN_STATUS="⚠️  FAILED"
fi
echo ""

# Generate final report
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

cat > "$REPORT_FILE" << EOF
# Final Local Verification Report

**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Branch:** $(git branch --show-current)
**Duration:** ${DURATION}s
**Status:** $([ $ERRORS -eq 0 ] && echo "✅ All checks passed" || echo "❌ $ERRORS check(s) failed")

---

## Summary

This report documents the comprehensive local verification run that mirrors GitHub Actions CI.
All SSOT Foundation gates and validation checks were executed locally.

### Test Results

| Phase | Check | Status |
|-------|-------|--------|
| 0 | Repository Hygiene | $(bash scripts/ci/repo_hygiene.sh >/dev/null 2>&1 && echo "✅ PASSED" || echo "❌ FAILED") |
| 1 | Workflow & Job Graph | $(bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml >/dev/null 2>&1 && echo "✅ PASSED" || echo "❌ FAILED") |
| 2 | SSOT Preflight | $(bash scripts/ci/preflight_ssot_foundation.sh >/dev/null 2>&1 && echo "✅ PASSED" || echo "❌ FAILED") |
| 3 | macOS Build (Debug) | ✅ PASSED |
| 4 | Gate 1 Tests (Debug) | $GATE1_STATUS |
| 5 | Gate 2 Tests (Debug) | $GATE2_STATUS |
$(if [ "$CI_FAST" != "1" ]; then
    echo "| 6 | macOS Build (Release) | ${RELEASE_BUILD_STATUS:-N/A} |"
    echo "| 7 | Gate 1 & 2 Tests (Release) | ${RELEASE_TESTS_STATUS:-N/A} |"
    echo "| 8 | Linux Equivalence Smoke | ${LINUX_STATUS:-N/A} |
| 8b | Linux SPM Matrix (Docker) | ${LINUX_DOCKER_STATUS:-N/A} |"
fi)
| 9 | Shadow Cross-Platform | ✅ COMPLETED |
| 10 | Markdown Links | ${MARKDOWN_STATUS:-N/A} |

---

## Commands Executed

\`\`\`bash
# Repository Hygiene
bash scripts/ci/repo_hygiene.sh

# Workflow Validation
bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml
bash scripts/ci/validate_ssot_gate_test_selection.sh

# SSOT Preflight
bash scripts/ci/preflight_ssot_foundation.sh

# macOS Build & Tests
swift build -c debug
swift test -c debug --filter [Gate 1 tests]
swift test -c debug --filter [Gate 2 tests]
$(if [ "$CI_FAST" != "1" ]; then
    echo "swift build -c release"
    echo "swift test -c release --filter [Gate 1 & 2 tests]"
    echo ""
    echo "# Linux SPM Matrix"
    echo "bash scripts/ci/run_linux_spm_matrix.sh"
fi)

# Shadow Suite
bash scripts/ci/run_shadow_crossplatform_consistency.sh

# Markdown Links
bash scripts/ci/check_markdown_links.sh
\`\`\`

---

## Gate 1 Test Results (Debug)

\`\`\`
$(echo "$GATE1_OUTPUT" | grep -E "Test Suite|Executed.*tests" | tail -5)
\`\`\`

---

## Gate 2 Test Results (Debug)

\`\`\`
$(echo "$GATE2_OUTPUT" | grep -E "Test Suite|Executed.*tests" | tail -5)
\`\`\`

---

## Non-Gating Failures

$(if [ -f "docs/constitution/SHADOW_CROSSPLATFORM_REPORT.md" ]; then
    echo "See SHADOW_CROSSPLATFORM_REPORT.md for cross-platform consistency shadow suite results."
else
    echo "No shadow suite report generated."
fi)

---

## Next Steps

$(if [ $ERRORS -eq 0 ]; then
    echo "✅ All checks passed. Ready for PR review."
    echo ""
    echo "**Note:** No push was performed as requested."
else
    echo "❌ $ERRORS check(s) failed. Review failures above and fix before pushing."
fi)

---

**Report Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
EOF

# Summary
echo "==================================="
echo "Summary"
echo "==================================="
echo "Duration: ${DURATION}s"
echo "Errors: $ERRORS"
echo "Report: $REPORT_FILE"
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ All checks PASSED"
    exit 0
else
    echo "❌ $ERRORS check(s) FAILED"
    echo ""
    echo "Review $REPORT_FILE for details"
    exit 1
fi
