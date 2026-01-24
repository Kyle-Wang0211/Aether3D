#!/bin/bash
# validate_merge_contract_structure.sh
# Validates structural consistency between:
# - MERGE_CONTRACT.md
# - BRANCH_PROTECTION_REQUIRED_CHECKS.md
# - Workflow job graph
# SSOT-blocking validation

set -euo pipefail

MERGE_CONTRACT_FILE="${1:-docs/constitution/MERGE_CONTRACT.md}"
BRANCH_PROTECTION_FILE="${2:-docs/constitution/BRANCH_PROTECTION_REQUIRED_CHECKS.md}"
WORKFLOW_FILE="${3:-.github/workflows/ssot-foundation-ci.yml}"

ERRORS=0

echo "🔒 Validating Merge Contract Structure Consistency"
echo ""

# Read mode from SSOT
MERGE_CONTRACT_MODE=$(bash scripts/ci/read_ssot_mode.sh)
if [ $? -ne 0 ]; then
    echo "❌ Failed to read SSOT mode"
    exit 1
fi

echo "Mode: $MERGE_CONTRACT_MODE"
echo ""

# Validate that merge contract document exists and is parseable
if [ ! -f "$MERGE_CONTRACT_FILE" ]; then
    echo "❌ Merge contract file not found: $MERGE_CONTRACT_FILE"
    ERRORS=$((ERRORS + 1))
fi

# Validate that branch protection document exists and is parseable
if [ ! -f "$BRANCH_PROTECTION_FILE" ]; then
    echo "❌ Branch protection file not found: $BRANCH_PROTECTION_FILE"
    ERRORS=$((ERRORS + 1))
fi

# Validate that workflow file exists and is parseable
if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -gt 0 ]; then
    exit 1
fi

# Extract required jobs from merge contract
MERGE_CONTRACT_JOBS=$(python3 <<'PYTHON_EOF'
import re
import sys
import os
import json

try:
    mode_file = os.environ.get('SSOT_MODE_FILE', 'docs/constitution/SSOT_MODE.json')
    with open(mode_file, 'r') as f:
        mode_data = json.load(f)
    mode = mode_data.get('mode', 'WHITEBOX')
    
    merge_contract_file = os.environ.get('MERGE_CONTRACT_FILE', 'docs/constitution/MERGE_CONTRACT.md')
    with open(merge_contract_file, 'r') as f:
        content = f.read()
    
    required_jobs = []
    
    if mode == 'WHITEBOX':
        # Extract from Whitebox Merge Contract section
        job_pattern = r'\d+\.\s+\*\*`([^`]+)`\*\*'
        whitebox_start = content.find('## Whitebox Merge Contract')
        if whitebox_start != -1:
            whitebox_end = content.find('##', whitebox_start + 1)
            if whitebox_end == -1:
                whitebox_end = len(content)
            whitebox_content = content[whitebox_start:whitebox_end]
            matches = re.findall(job_pattern, whitebox_content)
            required_jobs = matches[:5]  # First 5 required jobs
    else:
        # PRODUCTION mode
        job_pattern = r'\d+\.\s+\*\*`([^`]+)`\*\*'
        prod_start = content.find('## Required Jobs (Must Exist and Pass) - Production Mode')
        if prod_start != -1:
            prod_end = content.find('##', prod_start + 1)
            if prod_end == -1:
                prod_end = len(content)
            prod_content = content[prod_start:prod_end]
            matches = re.findall(job_pattern, prod_content)
            required_jobs = matches[:6]  # First 6 required jobs
    
    # Fallback: use known job lists
    if not required_jobs:
        if mode == 'WHITEBOX':
            required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'golden_vector_governance']
        else:
            required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'gate_2_determinism_trust_linux_self_hosted', 'golden_vector_governance']
    
    for job in required_jobs:
        print(job)
    
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Extract required jobs from branch protection document
BRANCH_PROTECTION_JOBS=$(MERGE_CONTRACT_MODE="$MERGE_CONTRACT_MODE" python3 <<'PYTHON_EOF'
import re
import sys
import os
import json

try:
    mode_file = os.environ.get('SSOT_MODE_FILE', 'docs/constitution/SSOT_MODE.json')
    with open(mode_file, 'r') as f:
        mode_data = json.load(f)
    mode = mode_data.get('mode', 'WHITEBOX')
    
    # Allow environment override for testing
    mode = os.environ.get('MERGE_CONTRACT_MODE', mode)
    
    branch_protection_file = os.environ.get('BRANCH_PROTECTION_FILE', 'docs/constitution/BRANCH_PROTECTION_REQUIRED_CHECKS.md')
    with open(branch_protection_file, 'r') as f:
        content = f.read()
    
    required_jobs = []
    
    if mode == 'WHITEBOX':
        section_start = content.find('## WHITEBOX Mode Required Checks')
        if section_start != -1:
            section_end = content.find('##', section_start + 1)
            if section_end == -1:
                section_end = len(content)
            section_content = content[section_start:section_end]
            job_pattern = r'\d+\.\s+`([^`]+)`'
            matches = re.findall(job_pattern, section_content)
            required_jobs = matches
        if not required_jobs:
            required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'golden_vector_governance']
    else:
        section_start = content.find('## PRODUCTION Mode Required Checks')
        if section_start != -1:
            section_end = content.find('##', section_start + 1)
            if section_end == -1:
                section_end = len(content)
            section_content = content[section_start:section_end]
            job_pattern = r'\d+\.\s+`([^`]+)`'
            matches = re.findall(job_pattern, section_content)
            required_jobs = matches
        if not required_jobs:
            required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'gate_2_determinism_trust_linux_self_hosted', 'golden_vector_governance']
    
    for job in required_jobs:
        print(job)
    
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Extract jobs from workflow
WORKFLOW_JOBS=$(python3 <<'PYTHON_EOF'
import yaml
import sys
import os

try:
    workflow_file = os.environ.get('WORKFLOW_FILE', '.github/workflows/ssot-foundation-ci.yml')
    with open(workflow_file, 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    job_ids = list(jobs.keys())
    
    for job_id in job_ids:
        print(job_id)
    
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Compare merge contract vs branch protection
MERGE_CONTRACT_SET=$(echo "$MERGE_CONTRACT_JOBS" | sort | tr '\n' ' ')
BRANCH_PROTECTION_SET=$(echo "$BRANCH_PROTECTION_JOBS" | sort | tr '\n' ' ')

if [ "$MERGE_CONTRACT_SET" != "$BRANCH_PROTECTION_SET" ]; then
    echo "❌ Merge contract and branch protection document mismatch"
    echo "  Merge Contract: $(echo "$MERGE_CONTRACT_JOBS" | tr '\n' ' ')"
    echo "  Branch Protection: $(echo "$BRANCH_PROTECTION_JOBS" | tr '\n' ' ')"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✅ Merge contract matches branch protection document"
fi

# Verify all required jobs exist in workflow
MISSING_JOBS=""
for job in $MERGE_CONTRACT_JOBS; do
    if ! echo "$WORKFLOW_JOBS" | grep -q "^${job}$"; then
        MISSING_JOBS="${MISSING_JOBS} ${job}"
    fi
done

if [ -n "$MISSING_JOBS" ]; then
    echo "❌ Required jobs missing from workflow:${MISSING_JOBS}"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✅ All required jobs exist in workflow"
fi

# Verify telemetry jobs are non-blocking
TELEMETRY_JOBS=$(echo "$WORKFLOW_JOBS" | grep -E "telemetry|experiment" || true)
for telemetry_job in $TELEMETRY_JOBS; do
    if echo "$MERGE_CONTRACT_JOBS" | grep -q "^${telemetry_job}$"; then
        echo "❌ Telemetry job '$telemetry_job' is listed as required (must be non-blocking)"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $ERRORS -eq 0 ]; then
    echo ""
    echo "✅ Merge contract structure validation passed"
    exit 0
else
    echo ""
    echo "❌ Merge contract structure validation failed ($ERRORS error(s))"
    exit 1
fi
