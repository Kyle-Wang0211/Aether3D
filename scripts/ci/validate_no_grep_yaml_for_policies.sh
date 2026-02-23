#!/bin/bash
# validate_no_grep_yaml_for_policies.sh
# Meta-validator: Ensures critical policies use Python YAML parsing, not grep-based parsing

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

ERRORS=0

echo "🔒 Validating No Grep-Based YAML Parsing for Critical Policies"
echo ""

# Critical policy scripts that MUST use Python YAML parsing
CRITICAL_POLICIES=(
    "validate_gate2_linux_crypto_policy.sh"
    "validate_gate2_linux_toolchain_policy.sh"
    "validate_no_duplicate_steps_keys.sh"
    "validate_concurrency_contexts.sh"
    "validate_workflow_graph.sh"
)

for policy_script in "${CRITICAL_POLICIES[@]}"; do
    SCRIPT_PATH="scripts/ci/$policy_script"
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "  ⚠️  $policy_script not found (may be optional)"
        continue
    fi
    
    echo "Checking $policy_script..."
    
    # Check if script uses Python YAML parsing
    if grep -q "python3.*yaml\|import yaml\|yaml.safe_load" "$SCRIPT_PATH" 2>/dev/null; then
        echo "  ✅ Uses Python YAML parsing"
    else
        # Check if script uses grep-based YAML parsing (forbidden for critical policies)
        if grep -qE "grep.*steps:|grep.*env:|grep.*jobs:|sed.*steps:" "$SCRIPT_PATH" 2>/dev/null && \
           ! grep -q "python3.*yaml\|import yaml\|yaml.safe_load" "$SCRIPT_PATH" 2>/dev/null; then
            echo "  ❌ Uses grep-based YAML parsing (forbidden for critical policies)"
            ERRORS=$((ERRORS + 1))
        else
            # Script may not parse YAML at all (e.g., bash syntax validator)
            echo "  ✅ Does not parse YAML (or uses safe method)"
        fi
    fi
done

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ No grep-based YAML parsing for critical policies"
    exit 0
else
    echo "❌ Validation failed ($ERRORS error(s))"
    echo ""
    echo "Fix: Critical policy scripts must use Python YAML parsing (yaml.safe_load)"
    echo "Grep-based parsing is fragile and can miss structural issues"
    exit 1
fi
