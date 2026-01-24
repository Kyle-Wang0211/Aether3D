#!/bin/bash
# validate_required_checks_doc_matches_merge_contract.sh
# Validates that BRANCH_PROTECTION_REQUIRED_CHECKS.md matches MERGE_CONTRACT.md
# SSOT-blocking validation

set -euo pipefail

MERGE_CONTRACT_FILE="${1:-docs/constitution/MERGE_CONTRACT.md}"
BRANCH_PROTECTION_FILE="${2:-docs/constitution/BRANCH_PROTECTION_REQUIRED_CHECKS.md}"

if [ ! -f "$MERGE_CONTRACT_FILE" ]; then
    echo "❌ Merge contract file not found: $MERGE_CONTRACT_FILE"
    exit 1
fi

if [ ! -f "$BRANCH_PROTECTION_FILE" ]; then
    echo "❌ Branch protection file not found: $BRANCH_PROTECTION_FILE"
    exit 1
fi

ERRORS=0

echo "🔒 Validating Branch Protection Required Checks Document"
echo ""

# Read mode from SSOT
MERGE_CONTRACT_MODE=$(bash scripts/ci/read_ssot_mode.sh)
if [ $? -ne 0 ]; then
    echo "❌ Failed to read SSOT mode"
    exit 1
fi

# Extract required jobs from merge contract (using Python)
MERGE_CONTRACT_JOBS=$(python3 <<'PYTHON_EOF'
import re
import sys
import os

try:
    merge_contract_file = os.environ.get('MERGE_CONTRACT_FILE', 'docs/constitution/MERGE_CONTRACT.md')
    with open(merge_contract_file, 'r') as f:
        content = f.read()
    
    mode = os.environ.get('MERGE_CONTRACT_MODE', 'WHITEBOX')
    
    # Extract required jobs based on mode
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
        # PRODUCTION mode: extract from Production Required Jobs section
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
BRANCH_PROTECTION_MODE_ENV="$MERGE_CONTRACT_MODE"
BRANCH_PROTECTION_FILE_ENV="$BRANCH_PROTECTION_FILE"
BRANCH_PROTECTION_JOBS=$(MERGE_CONTRACT_MODE="$BRANCH_PROTECTION_MODE_ENV" BRANCH_PROTECTION_FILE="$BRANCH_PROTECTION_FILE_ENV" python3 <<'PYTHON_EOF'
import re
import sys
import os

try:
    mode = os.environ.get('MERGE_CONTRACT_MODE', 'WHITEBOX')
    branch_protection_file = os.environ.get('BRANCH_PROTECTION_FILE', 'docs/constitution/BRANCH_PROTECTION_REQUIRED_CHECKS.md')
    
    with open(branch_protection_file, 'r') as f:
        content = f.read()
    
    required_jobs = []
    
    if mode == 'WHITEBOX':
        # Find WHITEBOX Mode Required Checks section
        section_start = content.find('## WHITEBOX Mode Required Checks')
        if section_start != -1:
            section_end = content.find('##', section_start + 1)
            if section_end == -1:
                section_end = len(content)
            section_content = content[section_start:section_end]
            # Extract job names from numbered list (format: 1. `job_name`)
            job_pattern = r'\d+\.\s+`([^`]+)`'
            matches = re.findall(job_pattern, section_content)
            required_jobs = matches
        # Fallback if section not found
        if not required_jobs:
            required_jobs = ['gate_0_workflow_lint', 'gate_linux_preflight_only', 'gate_1_constitutional', 'gate_2_determinism_trust', 'golden_vector_governance']
    else:
        # PRODUCTION mode
        section_start = content.find('## PRODUCTION Mode Required Checks')
        if section_start != -1:
            section_end = content.find('##', section_start + 1)
            if section_end == -1:
                section_end = len(content)
            section_content = content[section_start:section_end]
            job_pattern = r'\d+\.\s+`([^`]+)`'
            matches = re.findall(job_pattern, section_content)
            required_jobs = matches
        # Fallback if section not found
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

# Compare job lists
MERGE_CONTRACT_SET=$(echo "$MERGE_CONTRACT_JOBS" | sort | tr '\n' ' ')
BRANCH_PROTECTION_SET=$(echo "$BRANCH_PROTECTION_JOBS" | sort | tr '\n' ' ')

if [ "$MERGE_CONTRACT_SET" != "$BRANCH_PROTECTION_SET" ]; then
    echo "❌ Branch protection required checks document does not match merge contract"
    echo ""
    echo "Mode: $MERGE_CONTRACT_MODE"
    echo ""
    echo "Merge Contract Required Jobs:"
    echo "$MERGE_CONTRACT_JOBS" | sed 's/^/  - /'
    echo ""
    echo "Branch Protection Document Required Jobs:"
    echo "$BRANCH_PROTECTION_JOBS" | sed 's/^/  - /'
    echo ""
    echo "Fix: Update BRANCH_PROTECTION_REQUIRED_CHECKS.md to match MERGE_CONTRACT.md"
    ERRORS=$((ERRORS + 1))
else
    echo "  ✅ Branch protection document matches merge contract"
    echo "  Mode: $MERGE_CONTRACT_MODE"
    echo "  Required jobs: $(echo "$MERGE_CONTRACT_JOBS" | tr '\n' ' ')"
fi

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Branch protection validation passed"
    exit 0
else
    echo "❌ Branch protection validation failed ($ERRORS error(s))"
    exit 1
fi
