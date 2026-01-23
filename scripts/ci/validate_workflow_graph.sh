#!/bin/bash
# validate_workflow_graph.sh
# Validates GitHub Actions workflow job graph
# Ensures all 'needs:' references point to existing job IDs

set -euo pipefail

WORKFLOW_FILE="${1:-.github/workflows/ssot-foundation-ci.yml}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "❌ Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

echo "🔍 Validating workflow job graph: $WORKFLOW_FILE"

# Extract all job IDs (only within 'jobs:' section)
# Find jobs: section and extract job IDs (lines like "  job_id:" at top level of jobs)
JOB_IDS=$(awk '/^jobs:/{flag=1; next} /^[a-z]/ && flag {flag=0} flag && /^  [a-z0-9_]+:$/ {print $1}' "$WORKFLOW_FILE" | sed 's/://' | sort -u)

if [ -z "$JOB_IDS" ]; then
    echo "❌ No jobs found in workflow file"
    exit 1
fi

echo "Found job IDs:"
echo "$JOB_IDS" | sed 's/^/  - /'

# Extract all 'needs:' references
NEEDS_REFERENCES=$(grep -E '^\s+needs:' "$WORKFLOW_FILE" | sed 's/.*needs://' | sed 's/\[//' | sed 's/\]//' | sed 's/,//' | tr ' ' '\n' | grep -v '^$' | sort -u)

if [ -z "$NEEDS_REFERENCES" ]; then
    echo "✅ No 'needs:' references found (all jobs are independent)"
    exit 0
fi

echo ""
echo "Found 'needs:' references:"
echo "$NEEDS_REFERENCES" | sed 's/^/  - /'

# Check each needs reference
ERRORS=0
for ref in $NEEDS_REFERENCES; do
    if ! echo "$JOB_IDS" | grep -q "^${ref}$"; then
        echo ""
        echo "❌ ERROR: 'needs: $ref' references non-existent job"
        echo "   Available jobs: $(echo "$JOB_IDS" | tr '\n' ' ')"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $ERRORS -eq 0 ]; then
    echo ""
    echo "✅ All 'needs:' references are valid"
    exit 0
else
    echo ""
    echo "❌ Found $ERRORS invalid 'needs:' reference(s)"
    exit 1
fi
