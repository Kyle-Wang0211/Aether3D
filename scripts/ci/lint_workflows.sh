#!/bin/bash
# lint_workflows.sh
# Validates all GitHub Actions workflow files
# Ensures YAML syntax and job graph integrity
# Prevents hardcoded Xcode paths

set -euo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT" || exit 1

WORKFLOWS_DIR=".github/workflows"
ERRORS=0

echo "🔍 Linting GitHub Actions workflows"
echo ""

# Find all workflow files
WORKFLOW_FILES=$(find "$WORKFLOWS_DIR" -name "*.yml" -o -name "*.yaml" 2>/dev/null | sort)

if [ -z "$WORKFLOW_FILES" ]; then
    echo "⚠️  No workflow files found in $WORKFLOWS_DIR"
    exit 0
fi

# Check YAML syntax (if python3-yaml available)
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import yaml" 2>/dev/null; then
        echo "1. Validating YAML syntax..."
        for workflow in $WORKFLOW_FILES; do
            if python3 -c "import yaml; yaml.safe_load(open('$workflow'))" 2>/dev/null; then
                echo "   ✅ $workflow"
            else
                echo "   ❌ $workflow: YAML syntax error"
                ERRORS=$((ERRORS + 1))
            fi
        done
        echo ""
    else
        echo "⚠️  python3-yaml not available, skipping YAML syntax check"
        echo ""
    fi
fi

# Validate job graphs using validate_workflow_graph.sh
echo "2. Validating job graphs..."
if [ -f "scripts/ci/validate_workflow_graph.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        # Only fail on SSOT Foundation workflow; others are non-blocking
        if echo "$workflow" | grep -q "ssot-foundation"; then
            if bash scripts/ci/validate_workflow_graph.sh "$workflow" 2>/dev/null; then
                echo "   ✅ $workflow: Job graph valid"
            else
                echo "   ❌ $workflow: Job graph validation failed"
                ERRORS=$((ERRORS + 1))
            fi
        else
            # Non-SSOT workflows: warn but don't fail
            if bash scripts/ci/validate_workflow_graph.sh "$workflow" 2>/dev/null; then
                echo "   ✅ $workflow: Job graph valid"
            else
                echo "   ⚠️  $workflow: Job graph validation failed (non-SSOT, non-blocking)"
            fi
        fi
    done
else
    echo "   ⚠️  validate_workflow_graph.sh not found, skipping graph validation"
fi
echo ""

# Check for hardcoded Xcode paths (forbidden in all workflows)
echo "3. Checking for hardcoded Xcode paths..."
HARDCODED_XCODE=0
for workflow in $WORKFLOW_FILES; do
    if grep -q "/Applications/Xcode_" "$workflow" 2>/dev/null || \
       grep -q "xcode-select -s /Applications/" "$workflow" 2>/dev/null; then
        echo "   ❌ $workflow: Contains hardcoded Xcode path"
        echo "      Hardcoded Xcode app paths are forbidden. Use setup-xcode action + pinned runner."
        echo "      Found patterns:"
        grep -n "/Applications/Xcode_\|xcode-select -s /Applications/" "$workflow" | sed 's/^/         /'
        HARDCODED_XCODE=$((HARDCODED_XCODE + 1))
    else
        echo "   ✅ $workflow: No hardcoded Xcode paths"
    fi
done

if [ $HARDCODED_XCODE -gt 0 ]; then
    ERRORS=$((ERRORS + HARDCODED_XCODE))
fi
echo ""

# Check concurrency contexts (compile-time safety)
echo "4. Validating concurrency contexts..."
if [ -f "scripts/ci/validate_concurrency_contexts.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        if echo "$workflow" | grep -q "ssot-foundation"; then
            if bash scripts/ci/validate_concurrency_contexts.sh "$workflow" 2>/dev/null; then
                echo "   ✅ $workflow: Concurrency contexts valid"
            else
                echo "   ❌ $workflow: Concurrency context validation failed"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
else
    echo "   ⚠️  validate_concurrency_contexts.sh not found, skipping"
fi
echo ""

# Check for duplicate steps keys
echo "5. Validating no duplicate 'steps:' keys..."
if [ -f "scripts/ci/validate_no_duplicate_steps_keys.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        if echo "$workflow" | grep -q "ssot-foundation"; then
            if bash scripts/ci/validate_no_duplicate_steps_keys.sh "$workflow" 2>/dev/null; then
                echo "   ✅ $workflow: No duplicate 'steps:' keys"
            else
                echo "   ❌ $workflow: Duplicate 'steps:' keys found"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
else
    echo "   ⚠️  validate_no_duplicate_steps_keys.sh not found, skipping"
fi
echo ""

# Check concurrency uniqueness (prevent cross-workflow cancellation)
echo "6. Validating concurrency uniqueness..."
if [ -f "scripts/ci/validate_concurrency_uniqueness.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        if bash scripts/ci/validate_concurrency_uniqueness.sh "$workflow" 2>/dev/null; then
            echo "   ✅ $workflow: Concurrency groups are workflow-specific"
        else
            echo "   ❌ $workflow: Concurrency uniqueness validation failed"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    echo "   ⚠️  validate_concurrency_uniqueness.sh not found, skipping"
fi
echo ""

# Check bash syntax in run blocks (prevent shell syntax errors)
echo "7. Validating bash syntax in run blocks..."
if [ -f "scripts/ci/validate_workflow_bash_syntax.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        if bash scripts/ci/validate_workflow_bash_syntax.sh "$workflow" 2>/dev/null; then
            echo "   ✅ $workflow: Bash syntax valid"
        else
            echo "   ❌ $workflow: Bash syntax validation failed"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    echo "   ⚠️  validate_workflow_bash_syntax.sh not found, skipping"
fi
echo ""

# Check Gate 2 Linux crypto policy (closed-world assertion)
echo "8. Validating Gate 2 Linux crypto policy..."
if [ -f "scripts/ci/validate_gate2_linux_crypto_policy.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        if echo "$workflow" | grep -q "ssot-foundation"; then
            if bash scripts/ci/validate_gate2_linux_crypto_policy.sh "$workflow" 2>/dev/null; then
                echo "   ✅ $workflow: Gate 2 Linux crypto policy valid"
            else
                echo "   ❌ $workflow: Gate 2 Linux crypto policy validation failed"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
else
    echo "   ⚠️  validate_gate2_linux_crypto_policy.sh not found, skipping"
fi
echo ""

# Check Gate 2 Linux toolchain policy (closed-world assertion)
echo "9. Validating Gate 2 Linux toolchain policy..."
if [ -f "scripts/ci/validate_gate2_linux_toolchain_policy.sh" ]; then
    for workflow in $WORKFLOW_FILES; do
        if echo "$workflow" | grep -q "ssot-foundation"; then
            if bash scripts/ci/validate_gate2_linux_toolchain_policy.sh "$workflow" 2>/dev/null; then
                echo "   ✅ $workflow: Gate 2 Linux toolchain policy valid"
            else
                echo "   ❌ $workflow: Gate 2 Linux toolchain policy validation failed"
                ERRORS=$((ERRORS + 1))
            fi
        fi
    done
else
    echo "   ⚠️  validate_gate2_linux_toolchain_policy.sh not found, skipping"
fi
echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ All workflow files valid"
    exit 0
else
    echo "❌ Found $ERRORS error(s) in workflow files"
    exit 1
fi
