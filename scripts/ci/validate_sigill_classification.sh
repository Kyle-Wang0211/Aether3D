#!/bin/bash
# validate_sigill_classification.sh
# Ensures SIGILL classifier does not mention invariants (exclusive environmental classification)

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating SIGILL Classification (Exclusive Environmental)"
echo ""

# Extract SIGILL classification sections
SIGILL_SECTIONS=$(python3 <<'PYTHON_EOF'
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
            run_block = step.get('run', '')
            step_name = step.get('name', '')
            
            # Check if step contains SIGILL classification
            if 'SIGILL' in run_block or 'signal code 4' in run_block or 'Illegal instruction' in run_block:
                # Check if SIGILL section mentions invariants (forbidden)
                if 'SSOT_GATE2_FAILURE_CLASS=SIGILL_ENVIRONMENTAL' in run_block:
                    # Check if it mentions invariants in the SIGILL path
                    sigill_section_start = run_block.find('SSOT_GATE2_FAILURE_CLASS=SIGILL_ENVIRONMENTAL')
                    if sigill_section_start != -1:
                        # Extract SIGILL section (next 50 lines or until next major section)
                        sigill_section = run_block[sigill_section_start:sigill_section_start+2000]
                        
                        # Check for invariant mentions in SIGILL section
                        if 'invariant' in sigill_section.lower() and 'not evaluated' not in sigill_section.lower():
                            results.append(f"SIGILL_MENTIONS_INVARIANTS|{job_id}|{step_name}")
                        elif 'invariant' in sigill_section.lower() and 'not evaluated' in sigill_section.lower():
                            results.append(f"SIGILL_CORRECT|{job_id}|{step_name}")
                        else:
                            results.append(f"SIGILL_CORRECT|{job_id}|{step_name}")
    
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
        SIGILL_CORRECT)
            echo "  ✅ $job_id / $step_name: SIGILL classification correct"
            ;;
        SIGILL_MENTIONS_INVARIANTS)
            echo "  ❌ $job_id / $step_name: SIGILL section mentions invariants (must be exclusive environmental)"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$SIGILL_SECTIONS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ SIGILL classification validation passed"
    exit 0
else
    echo "❌ SIGILL classification validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: SIGILL failures must be classified exclusively as environmental"
    echo "SIGILL sections must NOT mention invariant IDs or 'invariant drift'"
    echo "They must explicitly state 'Invariants not evaluated due to crash'"
    exit 1
fi
