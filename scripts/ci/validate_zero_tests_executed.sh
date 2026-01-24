#!/bin/bash
# validate_zero_tests_executed.sh
# Ensures Gate 1 and Gate 2 test steps detect and fail on "0 tests executed"

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating Zero Tests Executed Detection"
echo ""

# Extract Gate 1 and Gate 2 test steps
TEST_STEPS=$(python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    # Find Gate 1 and Gate 2 jobs
    gate1_job = jobs.get('gate_1_constitutional', {})
    gate2_job = jobs.get('gate_2_determinism_trust', {})
    
    results = []
    
    # Check Gate 1
    if gate1_job:
        steps = gate1_job.get('steps', [])
        for step in steps:
            step_name = step.get('name', '')
            if 'Gate 1 Tests' in step_name or 'Run Gate 1' in step_name:
                run_block = step.get('run', '')
                # Check if run block detects "0 tests executed"
                if '0 tests' in run_block.lower() or 'executed 0' in run_block.lower():
                    results.append(f"GATE1_HAS_CHECK|{step_name}")
                else:
                    results.append(f"GATE1_MISSING_CHECK|{step_name}")
    
    # Check Gate 2
    if gate2_job:
        steps = gate2_job.get('steps', [])
        for step in steps:
            step_name = step.get('name', '')
            if 'Gate 2 Tests' in step_name or 'Run Gate 2' in step_name:
                run_block = step.get('run', '')
                # Check if run block detects "0 tests executed"
                if '0 tests' in run_block.lower() or 'executed 0' in run_block.lower():
                    results.append(f"GATE2_HAS_CHECK|{step_name}")
                else:
                    results.append(f"GATE2_MISSING_CHECK|{step_name}")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status step_name; do
    case "$status" in
        GATE1_HAS_CHECK)
            echo "  ✅ Gate 1 step '$step_name': Detects zero tests"
            ;;
        GATE1_MISSING_CHECK)
            echo "  ❌ Gate 1 step '$step_name': Missing zero tests detection"
            ERRORS=$((ERRORS + 1))
            ;;
        GATE2_HAS_CHECK)
            echo "  ✅ Gate 2 step '$step_name': Detects zero tests"
            ;;
        GATE2_MISSING_CHECK)
            echo "  ❌ Gate 2 step '$step_name': Missing zero tests detection"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$TEST_STEPS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Zero tests executed detection validation passed"
    exit 0
else
    echo "❌ Zero tests executed detection validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Gate 1 and Gate 2 test steps must detect and fail on '0 tests executed'"
    echo "Fix: Add check for 'Executed 0 tests' or '0 tests executed' in test output"
    exit 1
fi
