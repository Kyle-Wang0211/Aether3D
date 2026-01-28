#!/bin/bash
# validate_guardrail_wiring.sh
# Meta-validator: Ensures ALL required CI semantic guardrails are invoked by lint_workflows.sh

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔒 Validating Guardrail Wiring (Meta-Validator)"
echo ""

# Required guardrails that MUST be invoked by lint_workflows.sh
REQUIRED_GUARDRAILS=(
    "validate_concurrency_contexts.sh"
    "validate_concurrency_uniqueness.sh"
    "validate_no_duplicate_steps_keys.sh"
    "validate_workflow_bash_syntax.sh"
    "validate_gate2_linux_crypto_policy.sh"
)

# Optional guardrails (if present in repo, must be invoked)
OPTIONAL_GUARDRAILS=(
    "validate_gate2_linux_toolchain_policy.sh"
    "validate_runner_pinning.sh"
    "validate_no_grep_yaml_for_policies.sh"
    "validate_gate2_backend_policy_test_first.sh"
    "validate_guardrail_integration.sh"
)

echo "Checking lint_workflows.sh integration..."
LINT_MISSING=0
for guardrail in "${REQUIRED_GUARDRAILS[@]}" "${OPTIONAL_GUARDRAILS[@]}"; do
    if [ ! -f "scripts/ci/$guardrail" ]; then
        # Skip if file doesn't exist (optional guardrails)
        if [[ " ${REQUIRED_GUARDRAILS[@]} " =~ " ${guardrail} " ]]; then
            echo "  ❌ REQUIRED: $guardrail not found in repo"
            LINT_MISSING=$((LINT_MISSING + 1))
            ERRORS=$((ERRORS + 1))
        fi
        continue
    fi
    
    # Check if invoked in lint_workflows.sh
    if grep -q "$guardrail" scripts/ci/lint_workflows.sh 2>/dev/null; then
        echo "  ✅ $guardrail: Invoked in lint_workflows.sh"
    else
        if [[ " ${REQUIRED_GUARDRAILS[@]} " =~ " ${guardrail} " ]]; then
            echo "  ❌ REQUIRED: $guardrail not invoked in lint_workflows.sh"
            LINT_MISSING=$((LINT_MISSING + 1))
            ERRORS=$((ERRORS + 1))
        else
            echo "  ⚠️  OPTIONAL: $guardrail not invoked in lint_workflows.sh"
        fi
    fi
done

if [ $LINT_MISSING -eq 0 ]; then
    echo "  ✅ All required guardrails integrated in lint_workflows.sh"
fi
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ Guardrail wiring validation passed"
    exit 0
else
    echo "❌ Guardrail wiring validation failed ($ERRORS error(s))"
    echo ""
    echo "Fix: Ensure all required guardrail scripts are invoked by:"
    echo "  - scripts/ci/lint_workflows.sh (for all workflows)"
    exit 1
fi
