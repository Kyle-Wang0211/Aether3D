#!/bin/bash
# validate_guardrail_integration.sh
# Meta-validator: Ensures every guardrail script is invoked by lint_workflows.sh

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔒 Validating Guardrail Integration (Meta-Validator)"
echo ""

# Find all guardrail scripts (exclude this meta-validator).
# Build as an array to avoid whitespace-splitting bugs.
GUARDRAIL_SCRIPTS=()
while IFS= read -r script; do
    GUARDRAIL_SCRIPTS+=("$script")
done < <(find scripts/ci -name "validate_*.sh" -type f ! -name "validate_guardrail_integration.sh" | LC_ALL=C sort)

if [ ${#GUARDRAIL_SCRIPTS[@]} -eq 0 ]; then
    echo "⚠️  No guardrail scripts found"
    exit 0
fi

echo "Found guardrail scripts:"
for script in "${GUARDRAIL_SCRIPTS[@]}"; do
    echo "  - $script"
done
echo ""

# Check lint_workflows.sh integration (all guardrails should be integrated)
echo "Checking lint_workflows.sh integration..."
LINT_MISSING=0
for script in "${GUARDRAIL_SCRIPTS[@]}"; do
    SCRIPT_NAME=$(basename "$script")
    
    # Scripts that are called from workflow steps (not lint_workflows) - these are OK
    WORKFLOW_CALLED_SCRIPTS=(
        "validate_macos_xcode_selection.sh"
    )
    
    IS_WORKFLOW_CALLED=0
    for wf_script in "${WORKFLOW_CALLED_SCRIPTS[@]}"; do
        if [ "$SCRIPT_NAME" = "$wf_script" ]; then
            echo "  ✅ $SCRIPT_NAME: Called from workflow steps (not lint_workflows)"
            IS_WORKFLOW_CALLED=1
            break
        fi
    done
    
    if [ $IS_WORKFLOW_CALLED -eq 1 ]; then
        continue
    fi
    
    # Meta-validators - should be integrated but don't fail if missing (they're self-checking)
    if [ "$SCRIPT_NAME" = "validate_runner_pinning.sh" ] || \
       [ "$SCRIPT_NAME" = "validate_scripts_strict_mode.sh" ] || \
       [ "$SCRIPT_NAME" = "validate_no_grep_yaml_for_policies.sh" ] || \
       [ "$SCRIPT_NAME" = "validate_guardrail_integration.sh" ]; then
        # Check if integrated
        if grep -Fq "$SCRIPT_NAME" scripts/ci/lint_workflows.sh 2>/dev/null; then
            echo "  ✅ $SCRIPT_NAME: Meta-validator integrated in lint_workflows.sh"
        else
            echo "  ⚠️  $SCRIPT_NAME: Meta-validator not yet integrated (non-blocking)"
        fi
        continue
    fi
    
    # All other guardrails must be in lint_workflows.sh
    if ! grep -Fq "$SCRIPT_NAME" scripts/ci/lint_workflows.sh 2>/dev/null; then
        echo "  ❌ $SCRIPT_NAME not invoked in lint_workflows.sh"
        LINT_MISSING=$((LINT_MISSING + 1))
        ERRORS=$((ERRORS + 1))
    else
        echo "  ✅ $SCRIPT_NAME integrated in lint_workflows.sh"
    fi
done

if [ $LINT_MISSING -eq 0 ]; then
    echo "  ✅ All guardrails integrated in lint_workflows.sh"
fi
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Guardrail integration validation passed"
    exit 0
else
    echo "❌ Guardrail integration validation failed ($ERRORS error(s))"
    echo ""
    echo "Fix: Ensure all guardrail scripts are invoked by:"
    echo "  - scripts/ci/lint_workflows.sh (for all workflows)"
    exit 1
fi
