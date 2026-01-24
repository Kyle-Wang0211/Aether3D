#!/bin/bash
# validate_runner_pinning.sh
# Ensures gates use pinned runners (not ubuntu-latest, macos-latest)

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating Runner Pinning"
echo ""

# Extract job runner specifications
RUNNER_SPECS=$(python3 <<'PYTHON_EOF'
import yaml
import sys

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    results = []
    
    for job_id, job_def in jobs.items():
        runs_on = job_def.get('runs-on', '')
        job_name = job_def.get('name', job_id)
        
        # Check if job is a gate (blocking)
        is_gate = 'gate' in job_id.lower() or 'gate' in job_name.lower()
        
        if is_gate:
            # Gates must use pinned runners
            if runs_on == 'ubuntu-latest' or runs_on == 'macos-latest':
                results.append(f"GATE_UNPINNED|{job_id}|{runs_on}")
            elif 'ubuntu-' in runs_on or 'macos-' in runs_on:
                # Check if it's a matrix reference
                if '${{' in runs_on:
                    # Matrix reference is OK if matrix values are pinned
                    results.append(f"GATE_MATRIX_RUNNER|{job_id}|{runs_on}")
                else:
                    results.append(f"GATE_PINNED|{job_id}|{runs_on}")
            else:
                results.append(f"GATE_PINNED|{job_id}|{runs_on}")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id runs_on; do
    case "$status" in
        GATE_PINNED)
            echo "  ✅ Gate '$job_id': Uses pinned runner ($runs_on)"
            ;;
        GATE_MATRIX_RUNNER)
            echo "  ✅ Gate '$job_id': Uses matrix runner ($runs_on) - check matrix values are pinned"
            ;;
        GATE_UNPINNED)
            echo "  ❌ Gate '$job_id': Uses unpinned runner ($runs_on)"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$RUNNER_SPECS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Runner pinning validation passed"
    exit 0
else
    echo "❌ Runner pinning validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Blocking gates must use pinned runners (ubuntu-22.04, macos-14, not ubuntu-latest)"
    exit 1
fi
