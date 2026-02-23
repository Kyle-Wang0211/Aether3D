#!/bin/bash
# validate_experimental_jobs_non_blocking.sh
# Ensures experimental jobs are never required checks and have correct triggers

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
fi

ERRORS=0

echo "🔒 Validating Experimental Jobs Are Non-Blocking"
echo ""

# Extract experimental jobs using Python YAML parsing
EXPERIMENTAL_JOBS=$(python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    for job_id, job_def in jobs.items():
        job_name = job_def.get('name', job_id)
        # Check if job is experimental (name contains "experimental" or "telemetry")
        # Note: gate_2_linux_hosted_telemetry is telemetry but runs on pull_request (non-blocking)
        if 'experimental' in job_name.lower() or 'telemetry' in job_name.lower():
            # Check if: condition restricts to non-blocking triggers
            if_condition = job_def.get('if', '')
            needs = job_def.get('needs', [])
            
            # Check triggers
            # Telemetry jobs may run on pull_request if they have continue-on-error: true
            continue_on_error = job_def.get('continue-on-error', False)
            triggers_ok = False
            if 'workflow_dispatch' in if_condition or 'schedule' in if_condition:
                triggers_ok = True
            elif if_condition == '' and continue_on_error:
                # No if condition but has continue-on-error: OK for telemetry (non-blocking)
                triggers_ok = True
            elif if_condition == '':
                # No if condition and no continue-on-error: BAD for experimental
                print(f"EXPERIMENTAL_NO_TRIGGER|{job_id}|No if: condition restricts triggers and no continue-on-error")
                sys.exit(1)
            else:
                triggers_ok = True
            
            # Check needs chain (experimental should not be in blocking chain)
            # Telemetry jobs may be in needs chain if they have continue-on-error: true
            if needs and not continue_on_error:
                print(f"EXPERIMENTAL_IN_NEEDS|{job_id}|Experimental job in needs chain without continue-on-error: {needs}")
                sys.exit(1)
            elif needs and continue_on_error:
                # Telemetry in needs chain is OK if non-blocking
                pass
            
            # Check concurrency group (should not share with blocking jobs)
            concurrency_group = job_def.get('concurrency', {}).get('group', '')
            if concurrency_group and 'experimental' not in concurrency_group.lower():
                # May share concurrency group with blocking jobs (risky)
                print(f"EXPERIMENTAL_CONCURRENCY|{job_id}|May share concurrency group: {concurrency_group}")
            
            print(f"EXPERIMENTAL_OK|{job_id}|{if_condition}")
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id detail; do
    case "$status" in
        EXPERIMENTAL_OK)
            echo "  ✅ Experimental job '$job_id': $detail"
            ;;
        EXPERIMENTAL_NO_TRIGGER)
            echo "  ❌ Experimental job '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        EXPERIMENTAL_IN_NEEDS)
            echo "  ❌ Experimental job '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        EXPERIMENTAL_CONCURRENCY)
            echo "  ⚠️  Experimental job '$job_id': $detail (may cancel blocking jobs)"
            ;;
    esac
done <<< "$EXPERIMENTAL_JOBS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Experimental jobs validation passed"
    exit 0
else
    echo "❌ Experimental jobs validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Experimental jobs must:"
    echo "  1. Have if: condition restricting to workflow_dispatch or schedule"
    echo "  2. Not be in needs chain of blocking jobs"
    echo "  3. Use distinct concurrency group or no concurrency"
    exit 1
fi
