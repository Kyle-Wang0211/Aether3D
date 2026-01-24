#!/bin/bash
# production_readiness_report.sh
# One-command production readiness inspection (read-only, never fails CI)

set -euo pipefail

echo "📋 Production Readiness Report"
echo "=============================="
echo ""

# Read mode from SSOT
MERGE_CONTRACT_MODE=$(bash scripts/ci/read_ssot_mode.sh 2>/dev/null || echo "WHITEBOX")
echo "Current Mode: $MERGE_CONTRACT_MODE"
echo ""

# Check for missing self-hosted runner jobs
echo "1. Self-Hosted Runner Jobs Status:"
if [ "$MERGE_CONTRACT_MODE" = "PRODUCTION" ]; then
    python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    required_job = 'gate_2_determinism_trust_linux_self_hosted'
    
    if required_job in jobs:
        job_def = jobs[required_job]
        runs_on = job_def.get('runs-on', '')
        is_self_hosted = False
        if isinstance(runs_on, list):
            is_self_hosted = 'self-hosted' in runs_on
        elif isinstance(runs_on, str):
            is_self_hosted = 'self-hosted' in runs_on
        
        if is_self_hosted:
            print("  ✅ Self-hosted runner job exists and configured")
        else:
            print("  ⚠️  Self-hosted runner job exists but does not use self-hosted runner")
    else:
        print("  ❌ Missing: gate_2_determinism_trust_linux_self_hosted")
except Exception as e:
    print(f"  ⚠️  Error checking: {e}")
PYTHON_EOF
else
    echo "  ℹ️  Not applicable (WHITEBOX mode does not require self-hosted runners)"
fi
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
if bash scripts/ci/validate_actions_pinning_audit_comment.sh .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
    echo "  ✅ All action pins have audit comments"
else
    echo "  ⚠️  Some action pins may be missing audit comments"
fi
echo ""

echo "=============================="
echo "Report complete (read-only, non-blocking)"
