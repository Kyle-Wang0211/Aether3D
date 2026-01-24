#!/bin/bash
# validate_cancellation_notices.sh
# Ensures cancellation notices only run on cancelled() and do not hide failures

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating Cancellation Notices"
echo ""

# Extract cancellation notice steps
CANCELLATION_STEPS=$(python3 <<'PYTHON_EOF'
import yaml
import sys

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    results = []
    
    for job_id, job_def in jobs.items():
        steps = job_def.get('steps', [])
        for step in steps:
            step_name = step.get('name', '')
            if_condition = step.get('if', '')
            run_block = step.get('run', '')
            
            # Check if step is a cancellation notice
            if 'cancellation' in step_name.lower() or 'canceled' in step_name.lower() or 'cancel' in step_name.lower():
                # Must have if: cancelled() condition
                if 'cancelled()' in if_condition:
                    # Check that it clearly states cancellation != failure
                    if 'not a test failure' in run_block.lower() or 'not a failure' in run_block.lower():
                        results.append(f"CANCELLATION_CORRECT|{job_id}|{step_name}")
                    else:
                        results.append(f"CANCELLATION_MISSING_CLARIFICATION|{job_id}|{step_name}")
                else:
                    results.append(f"CANCELLATION_MISSING_IF|{job_id}|{step_name}")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id step_name; do
    case "$status" in
        CANCELLATION_CORRECT)
            echo "  ✅ $job_id / $step_name: Cancellation notice correct"
            ;;
        CANCELLATION_MISSING_IF)
            echo "  ❌ $job_id / $step_name: Missing if: cancelled() condition"
            ERRORS=$((ERRORS + 1))
            ;;
        CANCELLATION_MISSING_CLARIFICATION)
            echo "  ❌ $job_id / $step_name: Missing 'not a test failure' clarification"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$CANCELLATION_STEPS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Cancellation notices validation passed"
    exit 0
else
    echo "❌ Cancellation notices validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Cancellation notice steps must:"
    echo "  1. Have if: cancelled() condition"
    echo "  2. Explicitly state 'not a test failure' or 'not a failure'"
    exit 1
fi
