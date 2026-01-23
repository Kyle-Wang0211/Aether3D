#!/bin/bash
# validate_concurrency_contexts.sh
# Validates that concurrency.group uses ONLY compile-time safe contexts
# Fails if env.*, secrets.*, or other runtime contexts are used in concurrency.group

set -euo pipefail

# If first arg is a file path, use it; otherwise use default
if [ -f "${1:-}" ]; then
    WORKFLOW_FILE="$1"
    REPO_ROOT="$(cd "$(dirname "$WORKFLOW_FILE")/../.." && pwd)"
else
    REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
    WORKFLOW_FILE="${2:-$REPO_ROOT/.github/workflows/ssot-foundation-ci.yml}"
fi

cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔍 Validating concurrency contexts in workflow files"
echo ""

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "⚠️  Workflow file not found: $WORKFLOW_FILE"
    exit 0
fi

# Find concurrency.group line
CONCURRENCY_BLOCK=$(grep -n "concurrency:" "$WORKFLOW_FILE" || true)
if [ -z "$CONCURRENCY_BLOCK" ]; then
    echo "⚠️  No concurrency block found in $WORKFLOW_FILE"
    exit 0
fi

# Get line number of concurrency: and check next few lines for group:
CONCURRENCY_LINE_NUM=$(echo "$CONCURRENCY_BLOCK" | head -1 | cut -d: -f1)
GROUP_LINE=$(sed -n "${CONCURRENCY_LINE_NUM},$((CONCURRENCY_LINE_NUM + 5))p" "$WORKFLOW_FILE" | grep -n "group:" | head -1)

if [ -z "$GROUP_LINE" ]; then
    echo "⚠️  No concurrency.group found in $WORKFLOW_FILE"
    exit 0
fi

ACTUAL_LINE_NUM=$((CONCURRENCY_LINE_NUM + $(echo "$GROUP_LINE" | cut -d: -f1) - 1))
GROUP_CONTENT=$(sed -n "${ACTUAL_LINE_NUM}p" "$WORKFLOW_FILE")

echo "Found concurrency.group at line $ACTUAL_LINE_NUM:"
echo "  $GROUP_CONTENT"
echo ""

# Check for forbidden contexts in concurrency.group
FORBIDDEN_PATTERNS=(
    "\${{ env\\."
    "\${{ secrets\\."
    "\${{ vars\\."
    "\${{ steps\\."
    "\${{ job\\."
    "\${{ runner\\."
)

VIOLATIONS=()
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if echo "$GROUP_CONTENT" | grep -q "$pattern"; then
        VIOLATIONS+=("$pattern")
    fi
done

if [ ${#VIOLATIONS[@]} -gt 0 ]; then
    echo "❌ concurrency.group contains forbidden runtime contexts:"
    for violation in "${VIOLATIONS[@]}"; do
        echo "   - $violation"
    done
    echo ""
    echo "Fix: concurrency.group must use ONLY compile-time contexts:"
    echo "   ✅ github.* (github.workflow, github.ref, github.event.pull_request.number, etc.)"
    echo "   ✅ inputs.* (if workflow_dispatch)"
    echo "   ❌ env.* (runtime only)"
    echo "   ❌ secrets.* (runtime only)"
    echo "   ❌ steps.* (runtime only)"
    echo ""
    echo "Example correct pattern:"
    echo "   concurrency:"
    echo "     group: \${{ github.workflow }}-\${{ github.event.pull_request.number || github.ref }}"
    echo ""
    ERRORS=$((ERRORS + 1))
else
    echo "✅ concurrency.group uses only compile-time safe contexts"
fi

if [ $ERRORS -eq 0 ]; then
    exit 0
else
    exit 1
fi
