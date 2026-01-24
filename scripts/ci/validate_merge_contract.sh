#!/bin/bash
# validate_merge_contract.sh
# Validates that merge-blocking jobs exist, are reachable on pull_request, and have stable names

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating Merge Contract"
echo ""

# Required merge-blocking jobs (from MERGE_CONTRACT.md)
REQUIRED_JOBS=(
    "gate_0_workflow_lint"
    "gate_linux_preflight_only"
    "gate_1_constitutional"
    "gate_2_determinism_trust"
    "golden_vector_governance"
)

# Explicitly non-blocking jobs (must NOT run on pull_request by default)
EXPERIMENTAL_JOBS=(
    "gate_2_linux_native_crypto_experiment"
)

# Parse workflow using Python YAML
VALIDATION_RESULT=$(python3 <<'PYTHON_EOF'
import yaml
import sys

try:
    workflow_file = '.github/workflows/ssot-foundation-ci.yml'
    with open(workflow_file, 'r') as f:
        workflow = yaml.safe_load(f)
    
    if not workflow or 'jobs' not in workflow:
        print("ERROR|No jobs found in workflow", file=sys.stderr)
        print("ERROR|No jobs found in workflow")
        sys.exit(1)
    
    # Check workflow triggers
    # Note: PyYAML parses 'on:' as boolean True, so we need to check for True key
    # or use a workaround by checking the raw YAML or using a custom loader
    on_triggers = None
    if True in workflow:  # 'on' is parsed as boolean True
        on_triggers = workflow[True]
    elif 'on' in workflow:
        on_triggers = workflow['on']
    
    has_pull_request_trigger = False
    
    # Handle different trigger formats
    if isinstance(on_triggers, dict):
        # Check for pull_request key (can be dict or list)
        if 'pull_request' in on_triggers:
            has_pull_request_trigger = True
    elif isinstance(on_triggers, list):
        has_pull_request_trigger = 'pull_request' in on_triggers
    elif on_triggers == 'pull_request' or on_triggers == ['pull_request']:
        has_pull_request_trigger = True
    
    if not has_pull_request_trigger:
        error_msg = f"ERROR|Workflow does not trigger on pull_request events (on triggers: {on_triggers})"
        print(error_msg, file=sys.stderr)
        print(error_msg)
        sys.exit(1)
    
    jobs = workflow.get('jobs', {})
    found_jobs = set(jobs.keys())
    
    # Check required jobs exist
    required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'golden_vector_governance']
    missing_jobs = []
    for req_job in required_jobs:
        if req_job not in found_jobs:
            missing_jobs.append(req_job)
    
    if missing_jobs:
        error_msg = f"ERROR|Missing required jobs: {', '.join(missing_jobs)}"
        print(error_msg, file=sys.stderr)
        print(error_msg)
        sys.exit(1)
    
    # Check each required job is reachable on pull_request
    unreachable_jobs = []
    for req_job in required_jobs:
        job_config = jobs.get(req_job, {})
        job_if = job_config.get('if', '')
        
        # Check if job has an 'if:' that prevents pull_request execution
        # Common patterns: 'github.event_name == "workflow_dispatch"', 'github.event_name == "schedule"'
        if 'workflow_dispatch' in job_if or 'schedule' in job_if:
            # Check if it's negated (e.g., 'github.event_name != "workflow_dispatch"')
            if '!=' in job_if or 'ne' in job_if.lower():
                # Negated condition is OK (allows pull_request)
                pass
            else:
                # Non-negated condition blocks pull_request
                unreachable_jobs.append(f"{req_job} (if: {job_if})")
    
    if unreachable_jobs:
        error_msg = f"ERROR|Required jobs unreachable on pull_request: {', '.join(unreachable_jobs)}"
        print(error_msg, file=sys.stderr)
        print(error_msg)
        sys.exit(1)
    
    # Check experimental jobs are properly isolated
    experimental_jobs = ['gate_2_linux_native_crypto_experiment']
    warnings = []
    for exp_job in experimental_jobs:
        if exp_job in found_jobs:
            job_config = jobs.get(exp_job, {})
            job_if = job_config.get('if', '')
            continue_on_error = job_config.get('continue-on-error', False)
            
            # Experimental job must have if: restricting to workflow_dispatch or schedule
            if 'workflow_dispatch' not in job_if and 'schedule' not in job_if:
                warnings.append(f"WARNING|Experimental job {exp_job} may run on pull_request (should be restricted)")
            
            # Experimental job should have continue-on-error
            if not continue_on_error:
                warnings.append(f"WARNING|Experimental job {exp_job} missing continue-on-error: true")
    
    # Print warnings if any
    for warning in warnings:
        print(warning)
    
    # All checks passed
    print("SUCCESS|All required jobs exist and are reachable on pull_request")
    sys.exit(0)
    
except Exception as e:
    error_msg = f"ERROR|Error parsing workflow: {e}"
    print(error_msg, file=sys.stderr)
    print(error_msg)
    sys.exit(1)
PYTHON_EOF
)

# Process validation result
if echo "$VALIDATION_RESULT" | grep -q "^ERROR|"; then
    ERROR_MSG=$(echo "$VALIDATION_RESULT" | sed 's/^ERROR|//')
    echo "  ❌ $ERROR_MSG"
    ERRORS=$((ERRORS + 1))
elif echo "$VALIDATION_RESULT" | grep -q "^WARNING|"; then
    WARNING_MSG=$(echo "$VALIDATION_RESULT" | sed 's/^WARNING|//')
    echo "  ⚠️  $WARNING_MSG"
elif echo "$VALIDATION_RESULT" | grep -q "^SUCCESS|"; then
    SUCCESS_MSG=$(echo "$VALIDATION_RESULT" | sed 's/^SUCCESS|//')
    echo "  ✅ $SUCCESS_MSG"
else
    echo "  ❌ Unexpected validation output"
    ERRORS=$((ERRORS + 1))
fi

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Merge contract validation passed"
    exit 0
else
    echo "❌ Merge contract validation failed ($ERRORS error(s))"
    echo ""
    echo "Fix: Ensure all required jobs exist and are reachable on pull_request events"
    echo "See docs/constitution/MERGE_CONTRACT.md for contract definition"
    exit 1
fi
