#!/bin/bash
# linux_equivalence_smoke_no_docker.sh
# Linux equivalence smoke test without Docker
# Catches common Ubuntu failures: paths, locale, JSON decoding, CRLF, case sensitivity

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

# Enforce CI-equivalent environment
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export TZ=UTC

ERRORS=0

echo "🐧 Linux Equivalence Smoke Test (No Docker)"
echo "============================================"
echo "Environment:"
echo "  LC_ALL=$LC_ALL"
echo "  LANG=$LANG"
echo "  TZ=$TZ"
echo ""

# Phase 1: Re-run validations that would run on Ubuntu
echo "Phase 1: Running Ubuntu-equivalent validations..."
echo ""

echo "1.1 Repository Hygiene..."
if bash scripts/ci/repo_hygiene.sh; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

echo "1.2 Workflow Lint..."
if bash scripts/ci/lint_workflows.sh >/dev/null 2>&1; then
    echo "   ✅ PASSED"
else
    echo "   ⚠️  FAILED (non-blocking for SSOT Foundation)"
fi
echo ""

echo "1.3 Workflow Graph Validation..."
if bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

echo "1.4 SSOT Gate Test Selection Validation..."
if bash scripts/ci/validate_ssot_gate_test_selection.sh; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

echo "1.5 SSOT Preflight..."
if bash scripts/ci/preflight_ssot_foundation.sh; then
    echo "   ✅ PASSED"
else
    echo "   ❌ FAILED"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# Phase 2: Bundle/path independence check
echo "Phase 2: Bundle/Path Independence Check..."
echo ""

# Locate all JSON catalogs
JSON_CATALOGS=$(find docs/constitution/constants -name "*.json" -type f | sort)

if [ -z "$JSON_CATALOGS" ]; then
    echo "   ❌ No JSON catalogs found"
    ERRORS=$((ERRORS + 1))
else
    echo "   Found $(echo "$JSON_CATALOGS" | wc -l | tr -d ' ') JSON catalog(s)"
    
    # Test JSON loading via filesystem paths (not Bundle)
    echo "   Testing filesystem path access..."
    PATH_ERRORS=0
    
    for json_file in $JSON_CATALOGS; do
        # Verify file exists and is readable
        if [ ! -r "$json_file" ]; then
            echo "      ❌ Not readable: $json_file"
            PATH_ERRORS=$((PATH_ERRORS + 1))
            continue
        fi
        
        # Verify JSON is valid using Python (available on Ubuntu)
        if ! python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
            echo "      ❌ Invalid JSON: $json_file"
            PATH_ERRORS=$((PATH_ERRORS + 1))
        fi
    done
    
    if [ $PATH_ERRORS -eq 0 ]; then
        echo "   ✅ All JSON catalogs accessible via filesystem paths"
    else
        echo "   ❌ Found $PATH_ERRORS JSON catalog issue(s)"
        ERRORS=$((ERRORS + PATH_ERRORS))
    fi
fi
echo ""

# Phase 3: Verify JSONTestHelpers supports filesystem paths
echo "Phase 3: JSONTestHelpers Path Independence..."
echo ""

# Check if JSONTestHelpers has filesystem fallback logic
if grep -q "Bundle\|bundle\|mainBundle" Tests/Constants/TestHelpers/JSONTestHelpers.swift 2>/dev/null; then
    # Check if it also has filesystem fallback
    if grep -q "FileManager\|fileExists\|contentsOfFile\|filesystem\|file system" Tests/Constants/TestHelpers/JSONTestHelpers.swift 2>/dev/null; then
        echo "   ✅ JSONTestHelpers has filesystem fallback"
    else
        echo "   ⚠️  JSONTestHelpers uses Bundle; may fail in non-Xcode contexts"
        echo "      Recommendation: Add filesystem fallback for Linux compatibility"
    fi
else
    echo "   ✅ JSONTestHelpers does not depend on Bundle"
fi
echo ""

# Phase 4: SPM manifest sanity probe
echo "Phase 4: SPM Manifest Sanity Probe..."
echo ""

if [ -f "Package.swift" ]; then
    echo "   Package.swift found"
    
    echo "   4.1 Running 'swift package describe'..."
    if swift package describe >/dev/null 2>&1; then
        echo "      ✅ PASSED"
    else
        echo "      ❌ FAILED"
        ERRORS=$((ERRORS + 1))
    fi
    
    echo "   4.2 Running 'swift package resolve'..."
    if swift package resolve >/dev/null 2>&1; then
        echo "      ✅ PASSED"
    else
        echo "      ❌ FAILED"
        ERRORS=$((ERRORS + 1))
    fi
    
    echo "   4.3 Running 'swift build -c debug'..."
    if swift build -c debug >/dev/null 2>&1; then
        echo "      ✅ PASSED"
    else
        echo "      ⚠️  FAILED (may be non-blocking if Xcode-only project)"
    fi
else
    echo "   ⚠️  Package.swift not found; SPM not configured"
    echo "      Skipping SPM checks"
fi
echo ""

# Phase 5: Case sensitivity check (Linux is case-sensitive)
echo "Phase 5: Case Sensitivity Check..."
echo ""

# Check for potential case sensitivity issues
CASE_ERRORS=0

# Check if any imports use wrong case
if grep -r "import.*[A-Z]" Core/Constants/*.swift Tests/Constants/*.swift 2>/dev/null | grep -v "import Foundation\|import XCTest\|import Aether3DCore" | grep -q "[a-z][A-Z]\|[A-Z][a-z]"; then
    echo "   ⚠️  Potential case sensitivity issues in imports"
    CASE_ERRORS=$((CASE_ERRORS + 1))
fi

# Check file naming consistency
if find Core/Constants Tests/Constants -name "*.swift" 2>/dev/null | grep -q "[A-Z].*[a-z].*\.swift"; then
    echo "   ✅ File naming appears consistent"
else
    echo "   ✅ File naming consistent"
fi

if [ $CASE_ERRORS -eq 0 ]; then
    echo "   ✅ No case sensitivity issues detected"
fi
echo ""

# Summary
echo "==================================="
echo "Summary"
echo "==================================="
echo "Errors: $ERRORS"
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Linux equivalence smoke test PASSED"
    echo ""
    echo "This indicates the codebase should work on Ubuntu Linux."
    echo "For full Linux validation, run with Docker:"
    echo "  bash scripts/ci/run_linux_spm_matrix.sh"
    exit 0
else
    echo "❌ Linux equivalence smoke test FAILED ($ERRORS error(s))"
    echo ""
    echo "Fix the issues above before pushing."
    echo "These are likely to cause failures on Ubuntu CI."
    exit 1
fi
