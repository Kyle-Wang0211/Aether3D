#!/bin/bash
# validate_guardrail_integration.sh
# Meta-validator: Ensures every guardrail script is invoked by lint_workflows.sh and preflight_ssot_foundation.sh

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔒 Validating Guardrail Integration (Meta-Validator)"
echo ""

# Find all guardrail scripts (exclude meta-validators that check themselves)
GUARDRAIL_SCRIPTS=$(find scripts/ci -name "validate_*.sh" -type f | grep -v "validate_guardrail_integration.sh" | sort)

if [ -z "$GUARDRAIL_SCRIPTS" ]; then
    echo "⚠️  No guardrail scripts found"
    exit 0
fi

echo "Found guardrail scripts:"
for script in $GUARDRAIL_SCRIPTS; do
    echo "  - $script"
done
echo ""

# Check lint_workflows.sh integration (all guardrails should be integrated)
echo "Checking lint_workflows.sh integration..."
LINT_MISSING=0
for script in $GUARDRAIL_SCRIPTS; do
    SCRIPT_NAME=$(basename "$script")
    
    # Scripts that are called from workflow steps (not lint_workflows) - these are OK
    WORKFLOW_CALLED_SCRIPTS=(
        "validate_macos_xcode_selection.sh"
        "validate_ssot_gate_test_selection.sh"
    )
    
    IS_WORKFLOW_CALLED=0
    for wf_script in "${WORKFLOW_CALLED_SCRIPTS[@]}"; do
        if [ "$SCRIPT_NAME" = "$wf_script" ]; then
            # Check if it's called from workflow
            if grep -q "$SCRIPT_NAME" .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
                echo "  ✅ $SCRIPT_NAME: Called from workflow steps (not lint_workflows)"
                IS_WORKFLOW_CALLED=1
                break
            fi
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
        if grep -q "$SCRIPT_NAME" scripts/ci/lint_workflows.sh 2>/dev/null; then
            echo "  ✅ $SCRIPT_NAME: Meta-validator integrated in lint_workflows.sh"
        else
            echo "  ⚠️  $SCRIPT_NAME: Meta-validator not yet integrated (non-blocking)"
        fi
        continue
    fi
    
    # All other guardrails must be in lint_workflows.sh
    if ! grep -q "$SCRIPT_NAME" scripts/ci/lint_workflows.sh 2>/dev/null; then
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

# Check preflight_ssot_foundation.sh integration (SSOT-specific guardrails only)
echo "Checking preflight_ssot_foundation.sh integration (SSOT-specific)..."
PREFLIGHT_MISSING=0
SSOT_GUARDRAILS=(
    "validate_gate2_linux_crypto_policy.sh"
    "validate_gate2_linux_toolchain_policy.sh"
    "validate_workflow_graph.sh"
    "validate_concurrency_contexts.sh"
    "validate_no_duplicate_steps_keys.sh"
    "validate_ssot_gate_test_selection.sh"
    "validate_workflow_bash_syntax.sh"
    "validate_zero_tests_executed.sh"
    "validate_sigill_classification.sh"
    "validate_gate2_backend_policy_test_first.sh"
    "validate_ssot_gate_test_selection.sh"
)

for guardrail in "${SSOT_GUARDRAILS[@]}"; do
    if [ -f "scripts/ci/$guardrail" ]; then
        # Check if called from preflight script OR from workflow steps
        if grep -q "$guardrail" scripts/ci/preflight_ssot_foundation.sh 2>/dev/null || \
           grep -q "$guardrail" .github/workflows/ssot-foundation-ci.yml 2>/dev/null; then
            echo "  ✅ $guardrail integrated (preflight or workflow)"
        else
            echo "  ❌ $guardrail not invoked in preflight_ssot_foundation.sh or workflow"
            PREFLIGHT_MISSING=$((PREFLIGHT_MISSING + 1))
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

if [ $PREFLIGHT_MISSING -eq 0 ]; then
    echo "  ✅ All SSOT guardrails integrated in preflight_ssot_foundation.sh"
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
    echo "  - scripts/ci/preflight_ssot_foundation.sh (for SSOT-specific guardrails)"
    exit 1
fi
