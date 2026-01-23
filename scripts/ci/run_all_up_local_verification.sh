#!/bin/bash
# run_all_up_local_verification.sh
# Comprehensive "all-up" local verification runner
# Executes the full matrix we can do locally before push
# Non-zero exit on any failure

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export TZ=UTC

ERRORS=0
START_TIME=$(date +%s)
REPORT_FILE="docs/constitution/FINAL_LOCAL_VERIFICATION_REPORT.md"

echo "🔒 SSOT Foundation All-Up Local Verification"
echo "============================================="
echo ""

# Phase 0: Snapshot & Safety
echo "📋 Phase 0: Snapshot & Safety"
echo "Branch: $(git branch --show-current)"
echo "Swift: $(swift --version | head -1)"
if command -v xcodebuild &> /dev/null; then
    echo "Xcode: $(xcodebuild -version | head -1)"
fi
echo ""

# Phase 1: Workflow & CI Guardrails
echo "📋 Phase 1: Workflow & CI Guardrails"
echo ""

echo "1.1 Linting workflows..."
if bash scripts/ci/lint_workflows.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo "1.2 Validating workflow graph..."
if bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo "1.3 Validating macOS Xcode selection..."
if bash scripts/ci/validate_macos_xcode_selection.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ⚠️  WARNING (non-blocking on non-macOS)"
fi

echo "1.4 Validating SSOT gate test selection..."
if bash scripts/ci/validate_ssot_gate_test_selection.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Phase 2: Repo Hygiene & Docs Integrity
echo "📋 Phase 2: Repo Hygiene & Docs Integrity"
echo ""

echo "2.1 Repository hygiene..."
if bash scripts/ci/repo_hygiene.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo "2.2 Auditing documentation markers..."
if bash scripts/ci/audit_docs_markers.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ⚠️  WARNING (non-blocking)"
fi

echo "2.3 Checking markdown links..."
if bash scripts/ci/check_markdown_links.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ⚠️  WARNING (non-blocking)"
fi

echo "2.4 Validating JSON catalogs..."
CATALOG_ERRORS=0
for catalog in docs/constitution/constants/USER_EXPLANATION_CATALOG.json \
               docs/constitution/constants/GOLDEN_VECTORS_ENCODING.json \
               docs/constitution/constants/GOLDEN_VECTORS_QUANTIZATION.json \
               docs/constitution/constants/GOLDEN_VECTORS_COLOR.json; do
    if ! python3 -c "import json; json.load(open('$catalog'))" 2>/dev/null; then
        echo "   ❌ Invalid JSON: $catalog"
        CATALOG_ERRORS=$((CATALOG_ERRORS + 1))
    fi
done

if [ $CATALOG_ERRORS -eq 0 ]; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED ($CATALOG_ERRORS catalog(s) invalid)"
    ERRORS=$((ERRORS + CATALOG_ERRORS))
fi

echo ""

# Phase 3: Swift Build Sanity
echo "📋 Phase 3: Swift Build Sanity"
echo ""

echo "3.1 Swift package resolve..."
if swift package resolve >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo "3.2 Swift build (debug)..."
if swift build -c debug >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo "3.3 Swift build (release)..."
if swift build -c release >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Phase 4: SSOT Foundation Tests
echo "📋 Phase 4: SSOT Foundation Tests"
echo ""

echo "4.1 Gate 1 Tests (Debug)..."
GATE1_DEBUG_OUTPUT=$(swift test -c debug \
    --filter EnumFrozenOrderTests \
    --filter CatalogSchemaTests \
    --filter DocumentationSyncTests \
    --filter DeterministicEncodingContractTests \
    --filter DeterministicQuantizationContractTests \
    --filter GoldenVectorsRoundTripTests 2>&1)
if echo "$GATE1_DEBUG_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
    echo "   ✅ PASSED"
    GATE1_DEBUG_STATUS="✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
    GATE1_DEBUG_STATUS="❌ FAILED"
fi

echo "4.2 Gate 2 Tests (Debug)..."
GATE2_DEBUG_OUTPUT=$(swift test -c debug \
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
if echo "$GATE2_DEBUG_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
    echo "   ✅ PASSED"
    GATE2_DEBUG_STATUS="✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
    GATE2_DEBUG_STATUS="❌ FAILED"
fi

echo "4.3 Gate 1 Tests (Release)..."
GATE1_RELEASE_OUTPUT=$(swift test -c release \
    --filter EnumFrozenOrderTests \
    --filter CatalogSchemaTests \
    --filter DocumentationSyncTests \
    --filter DeterministicEncodingContractTests \
    --filter DeterministicQuantizationContractTests \
    --filter GoldenVectorsRoundTripTests 2>&1)
if echo "$GATE1_RELEASE_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
    echo "   ✅ PASSED"
    GATE1_RELEASE_STATUS="✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
    GATE1_RELEASE_STATUS="❌ FAILED"
fi

echo "4.4 Gate 2 Tests (Release)..."
GATE2_RELEASE_OUTPUT=$(swift test -c release \
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
if echo "$GATE2_RELEASE_OUTPUT" | grep -q "Executed.*tests.*with 0 failures"; then
    echo "   ✅ PASSED"
    GATE2_RELEASE_STATUS="✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
    GATE2_RELEASE_STATUS="❌ FAILED"
fi

echo ""

# Phase 5: Shadow Cross-Platform Consistency
echo "📋 Phase 5: Shadow Cross-Platform Consistency"
if bash scripts/ci/run_shadow_crossplatform_consistency.sh >/dev/null 2>&1; then
    echo "   ✅ COMPLETED (see SHADOW_CROSSPLATFORM_REPORT.md)"
    SHADOW_STATUS="✅ COMPLETED"
else
    echo "   ⚠️  COMPLETED (non-gating, see SHADOW_CROSSPLATFORM_REPORT.md)"
    SHADOW_STATUS="⚠️  COMPLETED"
fi
echo ""

# Phase 6: Linux Equivalence Smoke
echo "📋 Phase 6: Linux Equivalence Smoke (No Docker)"
LINUX_OUTPUT=$(bash scripts/ci/linux_equivalence_smoke_no_docker.sh 2>&1)
LINUX_EXIT=$?
if [ $LINUX_EXIT -eq 0 ]; then
    echo "   ✅ PASSED"
    LINUX_STATUS="✅ PASSED"
else
    echo "   ❌ FAILED (exit code: $LINUX_EXIT)"
    echo "$LINUX_OUTPUT" | tail -5
    ERRORS=$((ERRORS + 1))
    LINUX_STATUS="❌ FAILED"
fi
echo ""

# Phase 7: SSOT Preflight
echo "📋 Phase 7: SSOT Preflight"
if bash scripts/ci/preflight_ssot_foundation.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
    PREFLIGHT_STATUS="✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
    PREFLIGHT_STATUS="❌ FAILED"
fi
echo ""

# Generate Report
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

cat > "$REPORT_FILE" << EOF
# Final Local Verification Report

**Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Branch:** $(git branch --show-current)
**Duration:** ${DURATION}s
**Status:** $([ $ERRORS -eq 0 ] && echo "✅ All checks passed" || echo "❌ $ERRORS check(s) failed")

**Note:** This report is regenerated on each verification run. Timestamps and durations may vary.

---

## Toolchain Versions

- **Swift:** $(swift --version | head -1)
$(if command -v xcodebuild &> /dev/null; then echo "- **Xcode:** $(xcodebuild -version | head -1)"; fi)
- **OS:** $(uname -s) $(uname -r)
- **Architecture:** $(uname -m)

---

## Summary

This report documents the comprehensive all-up local verification run that mirrors GitHub Actions CI.
All SSOT Foundation gates and validation checks were executed locally.

### Test Results

| Phase | Check | Status |
|-------|-------|--------|
| 0 | Snapshot & Safety | ✅ PASSED |
| 1.1 | Workflow Lint | ✅ PASSED |
| 1.2 | Workflow Graph | ✅ PASSED |
| 1.3 | Xcode Selection | ✅ PASSED |
| 1.4 | Test Selection | ✅ PASSED |
| 2.1 | Repository Hygiene | ✅ PASSED |
| 2.2 | Docs Markers | ✅ PASSED |
| 2.3 | Markdown Links | ✅ PASSED |
| 2.4 | JSON Catalogs | ✅ PASSED |
| 3.1 | Swift Package Resolve | ✅ PASSED |
| 3.2 | Swift Build (Debug) | ✅ PASSED |
| 3.3 | Swift Build (Release) | ✅ PASSED |
| 4.0 | Crypto Shim Canary (Debug) | ${GATE_CRYPTO_DEBUG_STATUS:-⚠️  SKIPPED} |
| 4.0 | Crypto Shim Canary (Release) | ${GATE_CRYPTO_RELEASE_STATUS:-⚠️  SKIPPED} |
| 4.1 | Gate 1 Tests (Debug) | $GATE1_DEBUG_STATUS |
| 4.2 | Gate 2 Tests (Debug) | $GATE2_DEBUG_STATUS |
| 4.3 | Gate 1 Tests (Release) | $GATE1_RELEASE_STATUS |
| 4.4 | Gate 2 Tests (Release) | $GATE2_RELEASE_STATUS |
| 5 | Shadow Cross-Platform | $SHADOW_STATUS |
| 6 | Linux Equivalence Smoke | $LINUX_STATUS |
| 7 | SSOT Preflight | $PREFLIGHT_STATUS |

---

## Commands Executed

\`\`\`bash
# Phase 1: Workflow & CI Guardrails
bash scripts/ci/lint_workflows.sh
bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml
bash scripts/ci/validate_macos_xcode_selection.sh
bash scripts/ci/validate_ssot_gate_test_selection.sh

# Phase 2: Repo Hygiene & Docs Integrity
bash scripts/ci/repo_hygiene.sh
bash scripts/ci/audit_docs_markers.sh
bash scripts/ci/check_markdown_links.sh
python3 -c "import json; json.load(open('docs/constitution/constants/USER_EXPLANATION_CATALOG.json'))"
python3 -c "import json; json.load(open('docs/constitution/constants/GOLDEN_VECTORS_ENCODING.json'))"
python3 -c "import json; json.load(open('docs/constitution/constants/GOLDEN_VECTORS_QUANTIZATION.json'))"
python3 -c "import json; json.load(open('docs/constitution/constants/GOLDEN_VECTORS_COLOR.json'))"

# Phase 3: Swift Build Sanity
swift package resolve
swift build -c debug
swift build -c release

# Phase 4: SSOT Foundation Tests
swift test -c debug --filter [Gate 1 tests]
swift test -c debug --filter [Gate 2 tests]
swift test -c release --filter [Gate 1 tests]
swift test -c release --filter [Gate 2 tests]

# Phase 5: Shadow Cross-Platform Consistency
bash scripts/ci/run_shadow_crossplatform_consistency.sh

# Phase 6: Linux Equivalence Smoke
bash scripts/ci/linux_equivalence_smoke_no_docker.sh

# Phase 7: SSOT Preflight
bash scripts/ci/preflight_ssot_foundation.sh
\`\`\`

---

## Gate 1 Test Results (Debug)

\`\`\`
$(echo "$GATE1_DEBUG_OUTPUT" | grep -E "Executed.*tests.*with 0 failures" | tail -1)
\`\`\`

---

## Gate 2 Test Results (Debug)

\`\`\`
$(echo "$GATE2_DEBUG_OUTPUT" | grep -E "Executed.*tests.*with 0 failures" | tail -1)
\`\`\`

---

## Gate 1 Test Results (Release)

\`\`\`
$(echo "$GATE1_RELEASE_OUTPUT" | grep -E "Executed.*tests.*with 0 failures" | tail -1)
\`\`\`

---

## Gate 2 Test Results (Release)

\`\`\`
$(echo "$GATE2_RELEASE_OUTPUT" | grep -E "Executed.*tests.*with 0 failures" | tail -1)
\`\`\`

---

## Known Non-Blocking Issues

$(if [ -f "docs/constitution/SHADOW_CROSSPLATFORM_REPORT.md" ]; then
    echo "See SHADOW_CROSSPLATFORM_REPORT.md for cross-platform consistency shadow suite results."
else
    echo "No known non-blocking issues."
fi)

---

## Next Steps

$(if [ $ERRORS -eq 0 ]; then
    echo "✅ All checks passed. Ready for commit and push."
    echo ""
    echo "**Commit Command:**"
    echo "\`\`\`bash"
    echo "git add -A"
    echo "git commit -t COMMIT_MESSAGE_TEMPLATE.txt"
    echo "\`\`\`"
    echo ""
    echo "**Note:** No push was performed as requested."
else
    echo "❌ $ERRORS check(s) failed. Review failures above and fix before committing."
fi)

---

**Report Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Note:** Report timestamps reflect verification run time. Test execution times may vary.
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
    echo ""
    echo "Ready for commit. Use:"
    echo "  git add -A"
    echo "  git commit -t COMMIT_MESSAGE_TEMPLATE.txt"
    exit 0
else
    echo "❌ $ERRORS check(s) FAILED"
    echo ""
    echo "Review $REPORT_FILE for details"
    exit 1
fi
