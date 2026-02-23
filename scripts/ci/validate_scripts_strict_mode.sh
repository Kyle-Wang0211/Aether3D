#!/bin/bash
# validate_scripts_strict_mode.sh
# Ensures all new guardrail scripts have set -euo pipefail

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔒 Validating Scripts Have Strict Mode"
echo ""

# Find all guardrail and CI scripts
CI_SCRIPTS=$(find scripts/ci -name "*.sh" -type f | sort)

if [ -z "$CI_SCRIPTS" ]; then
    echo "⚠️  No CI scripts found"
    exit 0
fi

echo "Checking CI scripts for strict mode..."
for script in $CI_SCRIPTS; do
    SCRIPT_NAME=$(basename "$script")
    
    # Skip if script is this validator itself
    if [ "$SCRIPT_NAME" = "validate_scripts_strict_mode.sh" ]; then
        continue
    fi
    
    # Check if script starts with set -euo pipefail
    FIRST_LINE=$(head -1 "$script" 2>/dev/null || echo "")
    SECOND_LINE=$(sed -n '2p' "$script" 2>/dev/null || echo "")
    
    # Check first or second line for strict mode
    if echo "$FIRST_LINE" | grep -qE "set -euo pipefail|set -euopipefail"; then
        echo "  ✅ $SCRIPT_NAME: Has strict mode"
    elif echo "$SECOND_LINE" | grep -qE "set -euo pipefail|set -euopipefail"; then
        echo "  ✅ $SCRIPT_NAME: Has strict mode (line 2)"
    else
        echo "  ❌ $SCRIPT_NAME: Missing 'set -euo pipefail'"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Scripts strict mode validation passed"
    exit 0
else
    echo "❌ Scripts strict mode validation failed ($ERRORS error(s))"
    echo ""
    echo "Policy: All CI scripts must start with 'set -euo pipefail'"
    echo "Fix: Add 'set -euo pipefail' as the first line of each script"
    exit 1
fi
