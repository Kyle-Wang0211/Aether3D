#!/bin/bash
# lint_workflows.sh
# Validates all GitHub Actions workflow files
# Ensures YAML syntax and job graph integrity

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
        if bash scripts/ci/validate_workflow_graph.sh "$workflow" 2>/dev/null; then
            echo "   ✅ $workflow"
        else
            echo "   ❌ $workflow: Job graph validation failed"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    echo "   ⚠️  validate_workflow_graph.sh not found, skipping graph validation"
fi

echo ""

if [ $ERRORS -eq 0 ]; then
    echo "✅ All workflow files valid"
    exit 0
else
    echo "❌ Found $ERRORS error(s) in workflow files"
    exit 1
fi
