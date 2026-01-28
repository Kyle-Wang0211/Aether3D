#!/bin/bash
# validate_gate2_backend_policy_test_first.sh
# Ensures Gate 2 always includes CryptoBackendPolicyTests filter first

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
fi

ERRORS=0

echo "🔒 Validating Gate 2 Backend Policy Test Order"
echo ""

# Extract Gate 2 test step filters
GATE2_FILTERS=$(python3 <<'PYTHON_EOF'
import yaml
import sys

try:
    with open('.github/workflows/ssot-foundation-ci.yml', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    gate2_job = jobs.get('gate_2_determinism_trust', {})
    
    if not gate2_job:
        print("GATE2_NOT_FOUND|Gate 2 job not found")
        sys.exit(1)
    
    steps = gate2_job.get('steps', [])
    
    for step in steps:
        step_name = step.get('name', '')
        if 'Gate 2 Tests' in step_name or 'Run Gate 2' in step_name:
            run_block = step.get('run', '')
            
            # Find FILTERS array or --filter arguments
            if 'FILTERS=(' in run_block or '--filter' in run_block:
                # Check if CryptoBackendPolicyTests is first
                # Look for array pattern or filter list
                filters_section = run_block
                
                # Check if CryptoBackendPolicyTests appears first in filter list
                first_filter_match = None
                if 'FILTERS=(' in filters_section:
                    # Extract array content
                    array_start = filters_section.find('FILTERS=(')
                    array_end = filters_section.find(')', array_start)
                    if array_end != -1:
                        array_content = filters_section[array_start:array_end]
                        # Find first --filter
                        first_filter_idx = array_content.find('--filter')
                        if first_filter_idx != -1:
                            first_filter_line = array_content[first_filter_idx:first_filter_idx+100]
                            if 'CryptoBackendPolicyTests' in first_filter_line:
                                print("POLICY_TEST_FIRST|Gate 2")
                            else:
                                print(f"POLICY_TEST_NOT_FIRST|Gate 2|First filter: {first_filter_line[:50]}")
                elif '--filter CryptoBackendPolicyTests' in filters_section:
                    # Check if it's the first --filter
                    first_filter_idx = filters_section.find('--filter')
                    policy_test_idx = filters_section.find('--filter CryptoBackendPolicyTests')
                    if first_filter_idx == policy_test_idx:
                        print("POLICY_TEST_FIRST|Gate 2")
                    else:
                        print(f"POLICY_TEST_NOT_FIRST|Gate 2|Found at position {policy_test_idx}, first filter at {first_filter_idx}")
                else:
                    print("POLICY_TEST_MISSING|Gate 2")
    
    sys.exit(0)
except Exception as e:
    print(f"Error parsing workflow: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id detail; do
    case "$status" in
        POLICY_TEST_FIRST)
            echo "  ✅ Gate 2: CryptoBackendPolicyTests is first filter"
            ;;
        POLICY_TEST_NOT_FIRST)
            echo "  ❌ Gate 2: CryptoBackendPolicyTests is not first filter - $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        POLICY_TEST_MISSING)
            echo "  ❌ Gate 2: CryptoBackendPolicyTests filter missing"
            ERRORS=$((ERRORS + 1))
            ;;
        GATE2_NOT_FOUND)
            echo "  ⚠️  Gate 2 job not found"
            ;;
    esac
done <<< "$GATE2_FILTERS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Gate 2 backend policy test order validation passed"
    exit 0
else
    echo "❌ Gate 2 backend policy test order validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Gate 2 must include CryptoBackendPolicyTests as the FIRST filter"
    echo "This ensures backend policy is validated before other tests run"
    exit 1
fi
