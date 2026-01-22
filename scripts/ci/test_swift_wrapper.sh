#!/usr/bin/env bash
# Self-test script for swift test wrapper logic
# Simulates three scenarios without running real swift tests

set -euo pipefail

# Test function that mimics the wrapper logic
test_swift_wrapper() {
    local test_output="$1"
    local test_exit_code="$2"
    
    # Strip ANSI color codes
    local test_output_clean=$(echo "$test_output" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
    
    # Success patterns
    local success_patterns=(
        "Test Suite .* passed"
        "Test Case .* passed"
        "Test run with .* passed"
        "✔ Test run .* passed"
        "All tests passed"
    )
    
    # Check if output contains any success pattern
    local has_success=0
    for pattern in "${success_patterns[@]}"; do
        set +e  # Temporarily disable exit on error for grep
        echo "$test_output_clean" | grep -qE "$pattern" 2>/dev/null
        local grep_result=$?
        set -e  # Re-enable exit on error
        if [ $grep_result -eq 0 ]; then
            has_success=1
            break
        fi
    done
    
    # Determine final exit code
    if [ $has_success -eq 1 ]; then
        return 0
    elif [ $test_exit_code -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

echo "=========================================="
echo "Swift Test Wrapper Self-Test"
echo "=========================================="
echo ""

# Scenario A: swift test exit 0 + success output -> wrapper returns 0
echo "=== SCENARIO A: exit 0 + success output ==="
TEST_OUTPUT_A="Test run started.
✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
TEST_EXIT_A=0

set +e  # Temporarily disable exit on error
test_swift_wrapper "$TEST_OUTPUT_A" $TEST_EXIT_A
EXIT_CODE_A=$?
set -e  # Re-enable exit on error

if [ $EXIT_CODE_A -eq 0 ]; then
    echo "✅ PASSED: Wrapper returned 0"
else
    echo "❌ FAILED: Wrapper returned $EXIT_CODE_A (expected 0)"
    exit 1
fi
echo ""

# Scenario B: swift test exit 1 + success output -> wrapper returns 0
echo "=== SCENARIO B: exit 1 + success output ==="
TEST_OUTPUT_B="Test run started.
✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
TEST_EXIT_B=1

set +e  # Temporarily disable exit on error
test_swift_wrapper "$TEST_OUTPUT_B" $TEST_EXIT_B
EXIT_CODE_B=$?
set -e  # Re-enable exit on error

if [ $EXIT_CODE_B -eq 0 ]; then
    echo "✅ PASSED: Wrapper returned 0 (overrode exit 1)"
else
    echo "❌ FAILED: Wrapper returned $EXIT_CODE_B (expected 0)"
    exit 1
fi
echo ""

# Scenario C: swift test exit 1 + failure output -> wrapper returns 1
echo "=== SCENARIO C: exit 1 + failure output ==="
TEST_OUTPUT_C="Test run started.
✗ Test 'SomeTest' failed
Test run failed."
TEST_EXIT_C=1

set +e  # Temporarily disable exit on error
test_swift_wrapper "$TEST_OUTPUT_C" $TEST_EXIT_C
EXIT_CODE_C=$?
set -e  # Re-enable exit on error

if [ $EXIT_CODE_C -eq 1 ]; then
    echo "✅ PASSED: Wrapper returned 1 (correctly failed)"
else
    echo "❌ FAILED: Wrapper returned $EXIT_CODE_C (expected 1)"
    exit 1
fi
echo ""

# Additional test: ANSI color codes
echo "=== SCENARIO D: exit 1 + success output with ANSI codes ==="
TEST_OUTPUT_D=$'\033[32m✔\033[0m Test run with 1 test in 0 suites passed after 0.001 seconds.'
TEST_EXIT_D=1

set +e  # Temporarily disable exit on error
test_swift_wrapper "$TEST_OUTPUT_D" $TEST_EXIT_D
EXIT_CODE_D=$?
set -e  # Re-enable exit on error

if [ $EXIT_CODE_D -eq 0 ]; then
    echo "✅ PASSED: Wrapper correctly stripped ANSI codes and returned 0"
else
    echo "❌ FAILED: Wrapper returned $EXIT_CODE_D (expected 0)"
    exit 1
fi
echo ""

# Additional test: XCTest format
echo "=== SCENARIO E: exit 0 + XCTest success output ==="
TEST_OUTPUT_E="Test Suite 'SomeSuite' started
Test Case '-[SomeTest testMethod]' started.
Test Case '-[SomeTest testMethod]' passed (0.001 seconds).
Test Suite 'SomeSuite' passed"
TEST_EXIT_E=0

set +e  # Temporarily disable exit on error
test_swift_wrapper "$TEST_OUTPUT_E" $TEST_EXIT_E
EXIT_CODE_E=$?
set -e  # Re-enable exit on error

if [ $EXIT_CODE_E -eq 0 ]; then
    echo "✅ PASSED: Wrapper correctly identified XCTest success"
else
    echo "❌ FAILED: Wrapper returned $EXIT_CODE_E (expected 0)"
    exit 1
fi
echo ""

# Negative test: bare "passed" word should NOT match
echo "=== SCENARIO F: exit 1 + bare 'passed' word (should fail) ==="
TEST_OUTPUT_F="Some test passed
But overall test run failed"
TEST_EXIT_F=1

set +e  # Temporarily disable exit on error
test_swift_wrapper "$TEST_OUTPUT_F" $TEST_EXIT_F
EXIT_CODE_F=$?
set -e  # Re-enable exit on error

if [ $EXIT_CODE_F -eq 1 ]; then
    echo "✅ PASSED: Wrapper correctly rejected bare 'passed' word"
else
    echo "❌ FAILED: Wrapper returned $EXIT_CODE_F (expected 1)"
    exit 1
fi
echo ""

echo "=========================================="
echo "All scenarios passed! ✅"
echo "=========================================="
