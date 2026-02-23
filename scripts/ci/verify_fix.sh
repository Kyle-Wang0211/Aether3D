#!/usr/bin/env bash
# Verification script for swift test exit code fix
# Tests three scenarios to ensure the fix works correctly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_TEST_SCRIPT="$SCRIPT_DIR/01_build_and_test.sh"

# Create temporary directory for swift wrapper
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Save original swift path (before we modify PATH)
ORIGINAL_SWIFT=$(which swift)

echo "=========================================="
echo "Verification: swift test exit code fix"
echo "=========================================="
echo ""

# Scenario 1: swift test exit=0 -> script exit=0
echo "=== SCENARIO 1: swift test exit=0 ==="
cat > "$TMP_DIR/swift" <<EOF
#!/bin/bash
REAL_SWIFT="$ORIGINAL_SWIFT"
if [ "\$1" = "test" ]; then
    echo "Test run started."
    echo "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
    exit 0
else
    # Forward all other commands to real swift
    exec "\$REAL_SWIFT" "\$@"
fi
EOF
chmod +x "$TMP_DIR/swift"

export PATH="$TMP_DIR:$PATH"
cd "$REPO_ROOT"
bash "$BUILD_TEST_SCRIPT"
EXIT_CODE=$?
echo "Exit code: $EXIT_CODE"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ SCENARIO 1 PASSED"
else
    echo "❌ SCENARIO 1 FAILED: Expected exit 0, got $EXIT_CODE"
    exit 1
fi
echo ""

# Scenario 2: swift test exit=1 but output contains "passed" -> script exit=0
echo "=== SCENARIO 2: swift test exit=1 but output shows passed ==="
cat > "$TMP_DIR/swift" <<EOF
#!/bin/bash
REAL_SWIFT="$ORIGINAL_SWIFT"
if [ "\$1" = "test" ]; then
    echo "Test run started."
    echo "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
    exit 1  # Exit 1 but tests passed
else
    # Forward all other commands to real swift
    exec "\$REAL_SWIFT" "\$@"
fi
EOF
chmod +x "$TMP_DIR/swift"

export PATH="$TMP_DIR:$PATH"
cd "$REPO_ROOT"
bash "$BUILD_TEST_SCRIPT"
EXIT_CODE=$?
echo "Exit code: $EXIT_CODE"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ SCENARIO 2 PASSED"
else
    echo "❌ SCENARIO 2 FAILED: Expected exit 0, got $EXIT_CODE"
    exit 1
fi
echo ""

# Scenario 3: swift test exit=1 and output does NOT contain "passed" -> script exit=1
echo "=== SCENARIO 3: swift test exit=1 and output shows failure ==="
cat > "$TMP_DIR/swift" <<EOF
#!/bin/bash
REAL_SWIFT="$ORIGINAL_SWIFT"
if [ "\$1" = "test" ]; then
    echo "Test run started."
    echo "✗ Test 'SomeTest' failed"
    echo "Test run failed."
    exit 1
else
    # Forward all other commands to real swift
    exec "\$REAL_SWIFT" "\$@"
fi
EOF
chmod +x "$TMP_DIR/swift"

export PATH="$TMP_DIR:$PATH"
cd "$REPO_ROOT"
set +e  # Allow script to fail
bash "$BUILD_TEST_SCRIPT"
EXIT_CODE=$?
set -e
echo "Exit code: $EXIT_CODE"
if [ $EXIT_CODE -eq 1 ]; then
    echo "✅ SCENARIO 3 PASSED"
else
    echo "❌ SCENARIO 3 FAILED: Expected exit 1, got $EXIT_CODE"
    exit 1
fi
echo ""

# Scenario 4: Real swift test (no wrapper) - should work normally
echo "=== SCENARIO 4: Real swift test (verification) ==="
export PATH=$(echo $PATH | sed "s|$TMP_DIR:||")
cd "$REPO_ROOT"
set +e  # Allow script to fail (tests might fail)
bash "$BUILD_TEST_SCRIPT"
EXIT_CODE=$?
set -e
echo "Exit code: $EXIT_CODE"
echo "✅ SCENARIO 4 COMPLETED (real swift test)"
echo ""

echo "=========================================="
echo "All verification scenarios completed"
echo "=========================================="
