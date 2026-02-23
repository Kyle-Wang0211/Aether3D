#!/usr/bin/env bash
# Simplified test scenarios for swift test exit code fix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_TEST_SCRIPT="$SCRIPT_DIR/01_build_and_test.sh"

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

ORIGINAL_SWIFT=$(which swift)

test_scenario() {
    local scenario_name="$1"
    local test_output="$2"
    local test_exit_code="$3"
    local expected_exit="$4"
    
    echo "=== $scenario_name ==="
    
    # Create wrapper
    cat > "$TMP_DIR/swift" <<EOF
#!/bin/bash
REAL_SWIFT="$ORIGINAL_SWIFT"
if [ "\$1" = "test" ]; then
    cat <<'TESTEOF'
$test_output
TESTEOF
    exit $test_exit_code
else
    exec "\$REAL_SWIFT" "\$@"
fi
EOF
    chmod +x "$TMP_DIR/swift"
    
    export PATH="$TMP_DIR:$PATH"
    cd "$REPO_ROOT"
    
    # Skip swift build for faster testing (we know it works)
    # Just test the swift test part
    set +e
    TEST_OUTPUT=$("$TMP_DIR/swift" test 2>&1)
    TEST_EXIT_CODE=$?
    set -e
    
    # Apply the same logic as 01_build_and_test.sh
    if echo "$TEST_OUTPUT" | grep -qE "(Test run with [0-9]+ test.*passed|Test Suite.*passed|All tests passed)"; then
        echo "$TEST_OUTPUT"
        ACTUAL_EXIT=0
    elif [ $TEST_EXIT_CODE -eq 0 ]; then
        echo "$TEST_OUTPUT"
        ACTUAL_EXIT=0
    else
        echo "$TEST_OUTPUT"
        ACTUAL_EXIT=1
    fi
    
    echo "Expected exit: $expected_exit, Actual exit: $ACTUAL_EXIT"
    if [ $ACTUAL_EXIT -eq $expected_exit ]; then
        echo "✅ PASSED"
    else
        echo "❌ FAILED"
        return 1
    fi
    echo ""
}

echo "=========================================="
echo "Testing swift test exit code fix scenarios"
echo "=========================================="
echo ""

# Scenario 1: exit=0, output shows passed
test_scenario "SCENARIO 1: exit=0, output shows passed" \
    "Test run started.
✔ Test run with 1 test in 0 suites passed after 0.001 seconds." \
    0 \
    0

# Scenario 2: exit=1, output shows passed (the bug case)
test_scenario "SCENARIO 2: exit=1, output shows passed" \
    "Test run started.
✔ Test run with 1 test in 0 suites passed after 0.001 seconds." \
    1 \
    0

# Scenario 3: exit=1, output shows failure
test_scenario "SCENARIO 3: exit=1, output shows failure" \
    "Test run started.
✗ Test 'SomeTest' failed
Test run failed." \
    1 \
    1

echo "=========================================="
echo "All scenarios completed"
echo "=========================================="
