#!/bin/bash
# validate_concurrency_uniqueness.sh
# Validates that concurrency.group in workflows includes workflow-specific prefix
# Prevents cross-workflow cancellation by ensuring each workflow has unique concurrency group

set -euo pipefail

WORKFLOW_FILE="${1:-}"
if [ -z "$WORKFLOW_FILE" ]; then
    echo "Usage: validate_concurrency_uniqueness.sh <workflow_file>"
    exit 1
fi

# Determine repo root
if [ -f "$WORKFLOW_FILE" ]; then
    REPO_ROOT=$(cd "$(dirname "$WORKFLOW_FILE")/../.." && pwd)
else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

cd "$REPO_ROOT" || exit 1

if [ ! -f "$WORKFLOW_FILE" ]; then
    # SSOT Foundation workflow removed - exit gracefully
    exit 0
fi

WORKFLOW_NAME=$(basename "$WORKFLOW_FILE" .yml | sed 's/\.yaml$//')
ERRORS=0

echo "🔍 Validating concurrency uniqueness for workflow: $WORKFLOW_NAME"
echo ""

# Extract concurrency.group value(s) from workflow
# Handle both "concurrency:" at workflow level and potential indentation
CONCURRENCY_GROUPS=$(grep -A 2 "^concurrency:" "$WORKFLOW_FILE" 2>/dev/null | grep "group:" | sed 's/.*group:[[:space:]]*//' | tr -d '"' || \
                     grep -A 2 "^[[:space:]]*concurrency:" "$WORKFLOW_FILE" 2>/dev/null | grep "[[:space:]]*group:" | sed 's/.*group:[[:space:]]*//' | tr -d '"' || true)

if [ -z "$CONCURRENCY_GROUPS" ]; then
    echo "   ⚠️  No concurrency.group found in workflow (may be intentional)"
    echo "   ✅ Skipping uniqueness check (no concurrency defined)"
    exit 0
fi

# Check each concurrency.group
while IFS= read -r group_expr; do
    if [ -z "$group_expr" ]; then
        continue
    fi
    
    echo "   Checking concurrency.group: $group_expr"
    
    # Check if group contains github.workflow or workflow name
    # Pattern should be: ${{ github.workflow }}-... or similar workflow-specific prefix
    if echo "$group_expr" | grep -qE '\$\{\{\s*github\.workflow\s*\}\}' || \
       echo "$group_expr" | grep -qiE "workflow|$WORKFLOW_NAME"; then
        echo "      ✅ Contains workflow-specific identifier"
    else
        # Check if it's a constant (high risk of cross-workflow collision)
        if echo "$group_expr" | grep -qvE '\$\{\{'; then
            echo "      ❌ Constant concurrency group (no workflow-specific prefix)"
            echo "         Risk: Cross-workflow cancellation if other workflows use same group"
            echo "         Fix: Add \${{ github.workflow }} or workflow name to group"
            ERRORS=$((ERRORS + 1))
        else
            # Contains expressions but may not include workflow identifier
            echo "      ⚠️  Concurrency group uses expressions but may lack workflow-specific prefix"
            echo "         Verify it includes \${{ github.workflow }} or workflow name"
            echo "         Current: $group_expr"
        fi
    fi
done <<< "$CONCURRENCY_GROUPS"

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Concurrency groups are workflow-specific (no cross-workflow collision risk)"
    exit 0
else
    echo "❌ Found $ERRORS concurrency group(s) that may cause cross-workflow cancellation"
    exit 1
fi
