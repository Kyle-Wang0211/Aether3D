#!/bin/bash
# Check for build warnings in Core/Quality/ that would cause CI failures
# This script fails if swift build emits warnings in QualityDatabase.swift or other Core/Quality files

set -euo pipefail

echo "=== Checking for build warnings in Core/Quality/ ==="

# Build and capture output
BUILD_OUTPUT=$(swift build 2>&1) || {
    echo "FAIL: swift build failed"
    echo "$BUILD_OUTPUT" | tail -50
    exit 1
}

# Check for warnings in Core/Quality/ files
WARNINGS=$(echo "$BUILD_OUTPUT" | grep -E "warning.*Core/Quality/" || true)

if [ -n "$WARNINGS" ]; then
    echo "FAIL: Found build warnings in Core/Quality/:"
    echo "$WARNINGS"
    exit 1
fi

echo "✅ No warnings found in Core/Quality/"
exit 0
