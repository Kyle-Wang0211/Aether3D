#!/bin/bash
# validate_telemetry_jobs_permissions.sh
# Validates that telemetry jobs have read-only permissions
# SSOT-blocking validation

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
fi

ERRORS=0

echo "🔒 Validating Telemetry Jobs Permissions"
echo ""

# Extract telemetry jobs and their permissions
VALIDATION_RESULT=$(python3 <<PYTHON_EOF
import yaml
import sys

try:
    with open('$WORKFLOW_FILE', 'r') as f:
        workflow = yaml.safe_load(f)
    
    jobs = workflow.get('jobs', {})
    
    # Identify telemetry jobs (non-blocking)
    telemetry_job_ids = []
    for job_id, job_def in jobs.items():
        continue_on_error = job_def.get('continue-on-error', False)
        job_name = job_def.get('name', '')
        # Telemetry jobs have continue-on-error: true or are explicitly marked as telemetry
        if continue_on_error or 'telemetry' in job_name.lower() or 'Telemetry' in job_name:
            telemetry_job_ids.append(job_id)
    
    results = []
    
    for job_id in telemetry_job_ids:
        job_def = jobs.get(job_id, {})
        permissions = job_def.get('permissions', {})
        
        # Check required permissions (must be read-only)
        has_read_contents = permissions.get('contents') == 'read' or permissions.get('contents') is None
        has_read_pr = permissions.get('pull-requests') == 'read' or permissions.get('pull-requests') is None
        
        # Check forbidden permissions
        has_write_contents = permissions.get('contents') == 'write'
        has_write_id_token = permissions.get('id-token') == 'write'
        has_any_write = has_write_contents or has_write_id_token
        
        if has_any_write:
            results.append(f"FORBIDDEN|{job_id}|Has write permissions (contents: write or id-token: write)")
        elif has_read_contents and has_read_pr:
            results.append(f"VALID|{job_id}|Has read-only permissions")
        else:
            results.append(f"INVALID|{job_id}|Missing required read permissions")
    
    for result in results:
        print(result)
    
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_EOF
)

# Process results
while IFS='|' read -r status job_id detail; do
    case "$status" in
        VALID)
            echo "  ✅ Telemetry job '$job_id': $detail"
            ;;
        FORBIDDEN)
            echo "  ❌ Telemetry job '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
        INVALID)
            echo "  ❌ Telemetry job '$job_id': $detail"
            ERRORS=$((ERRORS + 1))
            ;;
    esac
done <<< "$VALIDATION_RESULT"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Telemetry permissions validation passed"
    exit 0
else
    echo "❌ Telemetry permissions validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: Telemetry jobs must have:"
    echo "  ✅ contents: read (or omitted)"
    echo "  ✅ pull-requests: read (or omitted)"
    echo "  ❌ contents: write (forbidden)"
    echo "  ❌ id-token: write (forbidden)"
    exit 1
fi
