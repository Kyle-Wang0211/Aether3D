#!/bin/bash
# production_readiness_report.sh
# One-command production readiness inspection (read-only, never fails CI)

set -euo pipefail

echo "📋 Production Readiness Report"
echo "=============================="
echo ""

# Default to WHITEBOX mode
MERGE_CONTRACT_MODE="WHITEBOX"
echo "Current Mode: $MERGE_CONTRACT_MODE"
echo ""

# Check for missing self-hosted runner jobs
echo "1. Self-Hosted Runner Jobs Status:"
echo "  ℹ️  Not applicable (WHITEBOX mode does not require self-hosted runners)"
echo ""

# Merge contract mode
echo "2. Merge Contract Mode:"
echo "  Mode: $MERGE_CONTRACT_MODE"
if [ "$MERGE_CONTRACT_MODE" = "WHITEBOX" ]; then
    echo "  Status: ✅ WHITEBOX (Linux Gate 2 is non-blocking telemetry)"
else
    echo "  Status: ✅ PRODUCTION (Linux Gate 2 is blocking)"
fi
echo ""

# Branch protection doc mismatch
echo "3. Branch Protection Documentation:"
if bash scripts/ci/validate_required_checks_doc_matches_merge_contract.sh 2>/dev/null; then
    echo "  ✅ Branch protection document matches merge contract"
else
    echo "  ⚠️  Branch protection document may not match merge contract"
fi
echo ""

# Telemetry isolation status
echo "4. Telemetry Isolation Status:"
if bash scripts/ci/validate_telemetry_jobs_permissions.sh 2>/dev/null; then
    echo "  ✅ Telemetry jobs have read-only permissions"
else
    echo "  ⚠️  Some telemetry jobs may have write permissions"
fi
echo ""

# Whitebox runner safety
echo "5. Whitebox Runner Safety:"
if [ "$MERGE_CONTRACT_MODE" = "WHITEBOX" ]; then
    if bash scripts/ci/validate_whitebox_no_self_hosted.sh 2>/dev/null; then
        echo "  ✅ No self-hosted runners in required jobs"
    else
        echo "  ⚠️  Some required jobs may use self-hosted runners"
    fi
else
    echo "  ℹ️  Not applicable (not in WHITEBOX mode)"
fi
echo ""

# Actions pinning audit
echo "6. Actions Pinning Audit:"
echo "  ℹ️  Skipped"
echo ""

echo "=============================="
echo "Report complete (read-only, non-blocking)"
