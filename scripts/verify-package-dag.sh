#!/bin/bash
# verify-package-dag.sh
# Verify Package.swift dependency graph is correct

set -e

echo "=== PR4 Package DAG Verification ==="

# Step 1: Check Health module isolation
echo "Checking Health module isolation..."

HEALTH_IMPORTS=$(grep -r "^import " Sources/PR4Health/*.swift 2>/dev/null | grep -v "Foundation\|PR4Math" || true)

if [ -n "$HEALTH_IMPORTS" ]; then
    echo "❌ Health module has unexpected imports:"
    echo "$HEALTH_IMPORTS"
    exit 1
fi

echo "✅ Health module only imports Foundation and PR4Math"

# Step 2: Check for Accelerate in critical path
echo "Checking for Accelerate framework..."

# Only check for actual imports, not string literals in comments
ACCELERATE_USAGE=$(grep -rE "^import Accelerate" \
    Sources/PR4Math/ \
    Sources/PR4Softmax/ \
    Sources/PR4LUT/ \
    Sources/PR4Overflow/ \
    Sources/PR4Determinism/ 2>/dev/null || true)

if [ -n "$ACCELERATE_USAGE" ]; then
    echo "❌ Accelerate found in critical path:"
    echo "$ACCELERATE_USAGE"
    exit 1
fi

echo "✅ No Accelerate in critical path"

# Step 3: Verify no circular dependencies
echo "Checking for circular dependencies..."

swift build 2>&1 | grep -i "circular" && {
    echo "❌ Circular dependency detected"
    exit 1
} || true

echo "✅ No circular dependencies"

# Step 4: Verify forbidden imports
echo "Checking forbidden imports..."

if grep -r "import PR4Health" Sources/PR4Quality/*.swift 2>/dev/null; then
    echo "❌ Quality imports Health (forbidden)"
    exit 1
fi

if grep -r "import PR4Gate" Sources/PR4Health/*.swift 2>/dev/null; then
    echo "❌ Health imports Gate (forbidden)"
    exit 1
fi

echo "✅ No forbidden imports found"

echo ""
echo "=== All DAG checks passed ==="
