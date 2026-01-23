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

# Toolchain version check
echo "0. Toolchain Version Check..."
SWIFT_VERSION=$(swift --version | head -1)
echo "   Swift: $SWIFT_VERSION"
# Warn if Swift version is outside expected range (6.0+)
SWIFT_MAJOR=$(echo "$SWIFT_VERSION" | grep -oE "Swift version [0-9]+\.[0-9]+" | grep -oE "[0-9]+\.[0-9]+" | cut -d. -f1)
if [ -n "$SWIFT_MAJOR" ] && [ "$SWIFT_MAJOR" -lt 6 ]; then
    echo "   ⚠️  WARNING: Swift version < 6.0 may have compatibility issues"
    echo "   Expected: Swift 6.0+ (CI uses Swift 6.0)"
else
    echo "   ✅ Swift version acceptable"
fi
echo ""

# 1. Validate workflow graph and structure
echo "1. Validating workflow graph and structure..."
if bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml; then
    echo "   ✅ Workflow graph valid"
else
    echo "   ❌ Workflow graph invalid"
    ERRORS=$((ERRORS + 1))
fi

# 1.1. Validate concurrency contexts
if bash scripts/ci/validate_concurrency_contexts.sh .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
    echo "   ✅ Concurrency contexts valid"
else
    echo "   ❌ Concurrency context validation failed"
    ERRORS=$((ERRORS + 1))
fi

# 1.2. Validate no duplicate steps keys
if bash scripts/ci/validate_no_duplicate_steps_keys.sh .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
    echo "   ✅ No duplicate steps keys"
else
    echo "   ❌ Duplicate steps keys found"
    ERRORS=$((ERRORS + 1))
fi

# 1.3. Validate bash syntax
if bash scripts/ci/validate_workflow_bash_syntax.sh .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
    echo "   ✅ Bash syntax valid"
else
    echo "   ❌ Bash syntax validation failed"
    ERRORS=$((ERRORS + 1))
fi

# 1.4. Workflow parity check (push vs PR)
echo "1.4. Validating workflow parity (push vs PR)..."
if python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    # Check concurrency group computation
    concurrency_group = workflow.get('concurrency', {}).get('group', '')
    if not concurrency_group or concurrency_group == '-':
        print("   ❌ Concurrency group evaluates to empty or invalid")
        sys.exit(1)
    
    # Check that required env vars exist
    env_vars = workflow.get('env', {})
    if 'SSOT_CONCURRENCY_GROUP' not in env_vars:
        print("   ❌ SSOT_CONCURRENCY_GROUP missing from workflow env")
        sys.exit(1)
    
    # Verify concurrency group uses only github.* contexts
    if 'env.' in concurrency_group or 'secrets.' in concurrency_group:
        print("   ❌ Concurrency group uses runtime contexts (must use only github.*)")
        sys.exit(1)
    
    print("   ✅ Workflow parity check passed")
    sys.exit(0)
except Exception as e:
    print(f"   ❌ Parity check failed: {e}")
    sys.exit(1)
PYTHON_EOF
then
    echo "   ✅ Workflow parity valid"
else
    echo "   ❌ Workflow parity check failed"
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
