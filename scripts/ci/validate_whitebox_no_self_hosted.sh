#!/bin/bash
# validate_whitebox_no_self_hosted.sh
# Validates that WHITEBOX mode does not use self-hosted runners for required jobs
# SSOT-blocking validation

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
fi

ERRORS=0

# Read mode from SSOT
MERGE_CONTRACT_MODE=$(bash scripts/ci/read_ssot_mode.sh)
if [ $? -ne 0 ]; then
    echo "❌ Failed to read SSOT mode"
    exit 1
fi

if [ "$MERGE_CONTRACT_MODE" != "WHITEBOX" ]; then
    echo "🔒 Validating Whitebox Runner Safety (skipped - not in WHITEBOX mode)"
    echo "  Mode: $MERGE_CONTRACT_MODE"
    echo "  ✅ Validation skipped (only applies to WHITEBOX mode)"
    exit 0
fi

echo "🔒 Validating Whitebox Runner Safety"
echo ""
echo "Mode: WHITEBOX"
echo ""

# Extract required jobs and their runners
VALIDATION_RESULT=$(python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    # Required jobs in WHITEBOX mode
    required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'golden_vector_governance']
    
    results = []
    
    for job_id in required_jobs:
        if job_id not in jobs:
            continue
        
        job_def = jobs[job_id]
        runs_on = job_def.get('runs-on', '')
        
        # Check if uses self-hosted
        is_self_hosted = False
        if isinstance(runs_on, list):
            is_self_hosted = 'self-hosted' in runs_on
        elif isinstance(runs_on, str):
            is_self_hosted = 'self-hosted' in runs_on
        
        if is_self_hosted:
            results.append(f"FORBIDDEN|{job_id}|Uses self-hosted runner (forbidden in WHITEBOX mode)")
        else:
            results.append(f"VALID|{job_id}|Uses GitHub-hosted runner")
    
    # Check telemetry jobs (must use GitHub-hosted, pinned OS)
    telemetry_jobs = ['gate_2_determinism_trust_linux_telemetry', 'gate_2_linux_hosted_telemetry']
    for job_id in telemetry_jobs:
        if job_id not in jobs:
            continue
        
        job_def = jobs[job_id]
        runs_on = job_def.get('runs-on', '')
        
        is_self_hosted = False
        if isinstance(runs_on, list):
            is_self_hosted = 'self-hosted' in runs_on
        elif isinstance(runs_on, str):
            is_self_hosted = 'self-hosted' in runs_on
        
        is_pinned_hosted = (runs_on == 'ubuntu-22.04' or 
                           (isinstance(runs_on, str) and 'ubuntu-' in runs_on and 'self-hosted' not in runs_on))
        
        if is_self_hosted:
            results.append(f"FORBIDDEN|{job_id}|Telemetry job uses self-hosted runner (must use GitHub-hosted)")
        elif is_pinned_hosted:
            results.append(f"VALID|{job_id}|Telemetry job uses pinned GitHub-hosted runner")
        else:
            results.append(f"INVALID|{job_id}|Telemetry job must use pinned GitHub-hosted runner (ubuntu-22.04)")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id detail; do
    case "$status" in
        VALID)
            echo "  ✅ Job '$job_id': $detail"
            ;;
        FORBIDDEN)
            echo "  ❌ Job '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        INVALID)
            echo "  ❌ Job '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$VALIDATION_RESULT"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Whitebox runner safety validation passed"
    exit 0
else
    echo "❌ Whitebox runner safety validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy (WHITEBOX mode):"
    echo "  ❌ Required jobs must NOT use self-hosted runners"
    echo "  ✅ Required jobs must use GitHub-hosted runners"
    echo "  ✅ Telemetry jobs must use pinned GitHub-hosted runners (ubuntu-22.04)"
    exit 1
fi
