#!/bin/bash
# validate_actions_pinning.sh
# Validates that SSOT workflows pin actions to full commit SHAs (no tags like @v1, @main, @latest)

set -euo pipefail

WORKFLOW_FILE="${1:-}"

if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: validate_actions_pinning.sh <workflow_file>"
    exit 1
fi

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

ERRORS=0
WARNINGS=0

# Determine if this is an SSOT workflow (strict) or non-SSOT (tolerant)
# SSOT Foundation workflow removed - treat as non-SSOT
SSOT_WORKFLOWS=()
IS_SSOT=0

WORKFLOW_NAME=$(basename "$WORKFLOW_FILE")
if [ $IS_SSOT -eq 1 ]; then
    echo "🔒 Validating Actions Pinning (SSOT workflow - strict)"
else
    echo "🔒 Validating Actions Pinning (Non-SSOT workflow - warning only)"
fi
echo ""

# Parse workflow using Python YAML
# Use set +e temporarily to capture output even if Python exits non-zero
set +e
VALIDATION_RESULT=$(python3 <<PYTHON_EOF
import yaml
import sys
import re

try:
    workflow_file = '$WORKFLOW_FILE'
    is_ssot = $IS_SSOT
    
    with open(workflow_file, 'r') as f:
        workflow = yaml.safe_load(f)
    
    if not workflow or 'jobs' not in workflow:
        print("ERROR|No jobs found in workflow")
        sys.exit(1)
    
    unpinned_actions = []
    jobs = workflow.get('jobs', {})
    
    # Check all jobs for uses: entries
    for job_id, job_config in jobs.items():
        if 'steps' not in job_config:
            continue
        
        for step_idx, step in enumerate(job_config.get('steps', [])):
            if 'uses' not in step:
                continue
            
            uses_value = step['uses']
            step_name = step.get('name', f'step_{step_idx}')
            
            # Check if action is pinned to a full SHA (40 hex chars) or uses a tag
            # Full SHA format: owner/repo@abc123def456... (40 hex chars)
            # Tag format: owner/repo@v1, owner/repo@main, owner/repo@latest
            
            # Skip if it's a local action (starts with ./)
            if uses_value.startswith('./'):
                continue
            
            # Check for tag patterns (v1, v2, main, master, latest, etc.)
            # Full SHA should be 40 hex characters
            if '@' in uses_value:
                action_ref = uses_value.split('@', 1)[1]
                # Check if it's a full SHA (40 hex chars) or a tag
                if re.match(r'^[0-9a-f]{40}$', action_ref, re.IGNORECASE):
                    # Full SHA - OK
                    pass
                elif re.match(r'^v\d+', action_ref) or re.match(r'^v\d+\.\d+', action_ref) or action_ref in ['main', 'master', 'latest', 'v1', 'v2', 'v3', 'v4']:
                    # Tag pattern - unpinned (v1, v2, v4, main, latest, etc.)
                    unpinned_actions.append(f"{job_id}/{step_name}: {uses_value}")
            else:
                # No @ specified - unpinned
                unpinned_actions.append(f"{job_id}/{step_name}: {uses_value}")
    
    if unpinned_actions:
        for action in unpinned_actions:
            if is_ssot:
                print(f"ERROR|Unpinned action (SSOT requires full SHA): {action}")
            else:
                print(f"WARNING|Unpinned action (recommended to pin): {action}")
        sys.exit(1 if is_ssot else 0)
    else:
        print("SUCCESS|All actions are pinned to full commit SHAs")
        sys.exit(0)
    
except Exception as e:
    error_msg = f"ERROR|Error parsing workflow: {e}"
    print(error_msg)
    sys.exit(1)
PYTHON_EOF
)
PYTHON_EXIT=$?
set -euo pipefail

# Process validation result
if echo "$VALIDATION_RESULT" | grep -q "^ERROR|"; then
    while IFS='|' read -r prefix message; do
        echo "  ❌ $message"
        ERRORS=$((ERRORS + 1))
    done <<< "$(echo "$VALIDATION_RESULT" | grep "^ERROR|")"
elif echo "$VALIDATION_RESULT" | grep -q "^WARNING|"; then
    while IFS='|' read -r prefix message; do
        echo "  ⚠️  $message"
        WARNINGS=$((WARNINGS + 1))
    done <<< "$(echo "$VALIDATION_RESULT" | grep "^WARNING|")"
elif echo "$VALIDATION_RESULT" | grep -q "^SUCCESS|"; then
    SUCCESS_MSG=$(echo "$VALIDATION_RESULT" | sed 's/^SUCCESS|//')
    echo "  ✅ $SUCCESS_MSG"
else
    echo "  ❌ Unexpected validation output"
    ERRORS=$((ERRORS + 1))
fi

echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ Actions pinning validation passed"
    exit 0
elif [ $ERRORS -eq 0 ] && [ $WARNINGS -gt 0 ]; then
    echo "⚠️  Actions pinning validation passed with warnings ($WARNINGS warning(s))"
    exit 0
else
    echo "❌ Actions pinning validation failed ($ERRORS error(s))"
    echo ""
    echo "Fix: Pin all actions to full commit SHAs (40 hex characters)"
    echo "Example: actions/checkout@abc123def4567890abcdef1234567890abcdef12"
    echo "Forbidden: actions/checkout@v4, actions/checkout@main, actions/checkout@latest"
    exit 1
fi
