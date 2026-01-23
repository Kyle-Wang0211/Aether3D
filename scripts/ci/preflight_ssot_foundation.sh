#!/bin/bash
# preflight_ssot_foundation.sh
# Preflight checks for SSOT Foundation PR
# Runs before tests to catch structural issues early

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔒 SSOT Foundation Preflight Checks"
echo "===================================="
echo ""

# 1. Validate workflow graph
echo "1. Validating workflow graph..."
if bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml; then
    echo "   ✅ Workflow graph valid"
else
    echo "   ❌ Workflow graph invalid"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 2. Audit documentation markers
echo "2. Auditing documentation markers..."
if bash scripts/ci/audit_docs_markers.sh; then
    echo "   ✅ Documentation markers present"
else
    echo "   ❌ Documentation markers missing"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 3. Validate JSON catalogs exist and are parseable
echo "3. Validating JSON catalogs..."
CATALOGS=(
    "docs/constitution/constants/EDGE_CASE_TYPES.json"
    "docs/constitution/constants/RISK_FLAGS.json"
    "docs/constitution/constants/COLOR_MATRICES.json"
    "docs/constitution/constants/USER_EXPLANATION_CATALOG.json"
    "docs/constitution/constants/BREAKING_CHANGE_SURFACE.json"
    "docs/constitution/constants/MINIMUM_EXPLANATION_SET.json"
    "docs/constitution/constants/DOMAIN_PREFIXES.json"
    "docs/constitution/constants/REASON_COMPATIBILITY.json"
    "docs/constitution/constants/GOLDEN_VECTORS_ENCODING.json"
    "docs/constitution/constants/GOLDEN_VECTORS_QUANTIZATION.json"
    "docs/constitution/constants/GOLDEN_VECTORS_COLOR.json"
)

CATALOG_ERRORS=0
for catalog in "${CATALOGS[@]}"; do
    if [ ! -f "$catalog" ]; then
        echo "   ❌ Missing: $catalog"
        CATALOG_ERRORS=$((CATALOG_ERRORS + 1))
    elif ! python3 -c "import json; json.load(open('$catalog'))" 2>/dev/null; then
        echo "   ❌ Invalid JSON: $catalog"
        CATALOG_ERRORS=$((CATALOG_ERRORS + 1))
    fi
done

if [ $CATALOG_ERRORS -eq 0 ]; then
    echo "   ✅ All JSON catalogs valid"
else
    echo "   ❌ Found $CATALOG_ERRORS catalog issue(s)"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# 4. Check critical Swift files exist
echo "4. Checking critical Swift files..."
SWIFT_FILES=(
    "Core/Constants/EdgeCaseType.swift"
    "Core/Constants/RiskFlag.swift"
    "Core/Constants/PrimaryReasonCode.swift"
    "Core/Constants/ActionHintCode.swift"
    "Core/Constants/DeterministicEncoding.swift"
    "Core/Constants/DeterministicQuantization.swift"
    "Core/Constants/SafeRatio.swift"
)

SWIFT_ERRORS=0
for swift_file in "${SWIFT_FILES[@]}"; do
    if [ ! -f "$swift_file" ]; then
        echo "   ❌ Missing: $swift_file"
        SWIFT_ERRORS=$((SWIFT_ERRORS + 1))
    fi
done

if [ $SWIFT_ERRORS -eq 0 ]; then
    echo "   ✅ All critical Swift files present"
else
    echo "   ❌ Found $SWIFT_ERRORS missing Swift file(s)"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# Summary
if [ $ERRORS -eq 0 ]; then
    echo "✅ All preflight checks passed"
    exit 0
else
    echo "❌ Preflight checks failed ($ERRORS error(s))"
    echo ""
    echo "Next steps:"
    echo "  1. Fix workflow graph if invalid"
    echo "  2. Add missing documentation markers"
    echo "  3. Fix JSON catalog issues"
    echo "  4. Add missing Swift files"
    exit 1
fi
