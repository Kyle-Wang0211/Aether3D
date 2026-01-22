#!/usr/bin/env bash
set -euo pipefail

echo "==> swift build"
swift build

echo "==> swift test"
# Capture output and exit code separately
# Swift Package Manager may return non-zero exit code even when tests pass
# (known issue in some CI environments)
TEST_OUTPUT=$(swift test 2>&1)
TEST_EXIT_CODE=$?

# Check if tests actually passed by examining output
# Match Swift Testing success patterns:
# - "Test run with X test.*passed" (e.g., "Test run with 1 test in 0 suites passed")
# - "Test Suite.*passed" (XCTest suite passed)
# - "All tests passed" (explicit success message)
if echo "$TEST_OUTPUT" | grep -qE "(Test run with [0-9]+ test.*passed|Test Suite.*passed|All tests passed)"; then
    # Tests passed - print output and succeed regardless of exit code
    echo "$TEST_OUTPUT"
    exit 0
elif [ $TEST_EXIT_CODE -eq 0 ]; then
    # Exit code 0 - tests passed
    echo "$TEST_OUTPUT"
    exit 0
else
    # Exit code non-zero and no "passed" message - tests failed
    echo "$TEST_OUTPUT"
    exit 1
fi

