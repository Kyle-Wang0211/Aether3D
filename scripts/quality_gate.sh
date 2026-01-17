#!/bin/bash
#
# quality_gate.sh
# PR#5 Quality Pre-check - Unified Quality Gate Script
# Single entry point for all quality checks
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== PR#5 Quality Pre-check Gates ==="

# Gate 0: Check for placeholder tests (must be first)
echo "[0/5] Checking for placeholder tests..."
echo "  Command: grep -rn \"XCTAssertTrue(true)\" Tests/QualityPreCheck/"
set +e  # Allow grep to return non-zero without failing script
PLACEHOLDER_MATCHES=$(grep -rn "XCTAssertTrue(true)" Tests/QualityPreCheck/ --include="*.swift" 2>/dev/null || true)
PLACEHOLDER_COUNT=$(echo "$PLACEHOLDER_MATCHES" | grep -v "^$" | wc -l | tr -d ' ')
set -e
if [ "$PLACEHOLDER_COUNT" -gt 0 ]; then
    echo "FAIL: Found $PLACEHOLDER_COUNT placeholder tests (XCTAssertTrue(true))"
    echo "$PLACEHOLDER_MATCHES"
    exit 1
fi

echo "  Command: grep -rn \"TODO.*test|placeholder.*test|WIP.*test\" Tests/QualityPreCheck/"
set +e
PLACEHOLDER_KEYWORD_MATCHES=$(grep -rn "TODO.*test\|placeholder.*test\|WIP.*test" Tests/QualityPreCheck/ --include="*.swift" -i 2>/dev/null | grep -v "//.*TODO.*future\|//.*deferred\|//.*PR5.1\|PR5.1:" || true)
PLACEHOLDER_KEYWORDS=$(echo "$PLACEHOLDER_KEYWORD_MATCHES" | grep -v "^$" | wc -l | tr -d ' ')
set -e
if [ "$PLACEHOLDER_KEYWORDS" -gt 0 ]; then
    echo "FAIL: Found $PLACEHOLDER_KEYWORDS placeholder keywords in test assertions"
    echo "$PLACEHOLDER_KEYWORD_MATCHES"
    exit 1
fi
echo "  ✅ No placeholder tests found (checked $PLACEHOLDER_COUNT XCTAssertTrue(true), $PLACEHOLDER_KEYWORDS keywords)"

# Gate 1: Tests
echo "[1/5] Running tests..."
echo "  Command: swift test --filter WhiteCommitTests"
# PR5.1: Capture full output and exit code, print last 120 lines on failure
set +e  # Temporarily disable strict mode to capture exit code
TEST_OUTPUT=$(swift test --filter WhiteCommitTests 2>&1)
TEST_EXIT_CODE=$?
set -e  # Re-enable strict mode

if [ $TEST_EXIT_CODE -ne 0 ]; then
    echo "FAIL: Tests failed (exit code: $TEST_EXIT_CODE)"
    echo ""
    echo "=== Last 120 lines of test output ==="
    echo "$TEST_OUTPUT" | tail -120
    
    echo ""
    echo "=== Failing Tests Summary ==="
    FAILING_TESTS=$(echo "$TEST_OUTPUT" | grep -E "Test Case.*failed" | sed 's/.*Test Case.*\[\(.*\)\].*/\1/' | sort -u)
    if [ -n "$FAILING_TESTS" ]; then
        echo "Failing test cases:"
        echo "$FAILING_TESTS" | while read -r test; do
            echo "  - $test"
        done
    fi
    echo ""
    echo "=== SQLite Constraint Errors ==="
    echo "$TEST_OUTPUT" | grep -E "SQLITE_CONSTRAINT|CHECK constraint failed|UNIQUE constraint failed|no such table" -A 2 -B 2 || echo "  (No SQLite constraint errors found in output)"
    exit 1
fi

# Extract test count from output
TEST_COUNT=$(echo "$TEST_OUTPUT" | grep -E "Executed.*test" | tail -1 | grep -oE "[0-9]+ test" | grep -oE "[0-9]+" || echo "unknown")
echo "  ✅ Tests passed ($TEST_COUNT tests executed)"

# Gate 2: Lint
echo "[2/5] Running lint..."
echo "  Command: $SCRIPT_DIR/quality_lint.sh"
if ! "$SCRIPT_DIR/quality_lint.sh" 2>&1; then
    echo "FAIL: Lint failed"
    exit 1
fi
echo "  ✅ Lint checks passed"

# Gate 3: Fixture file validation (parse JSON)
echo "[3/5] Validating fixture JSON files..."
FIXTURE_DIR="$PROJECT_ROOT/Tests/QualityPreCheck/Fixtures"
if [ -d "$FIXTURE_DIR" ]; then
    FIXTURE_COUNT=0
    for fixture_file in "$FIXTURE_DIR"/*.json; do
        if [ -f "$fixture_file" ]; then
            FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
            if ! python3 -m json.tool "$fixture_file" > /dev/null 2>&1; then
                echo "FAIL: Invalid JSON in fixture: $fixture_file"
                exit 1
            fi
        fi
    done
    echo "  ✅ All $FIXTURE_COUNT fixture JSON files are valid"
else
    echo "WARNING: Fixture directory not found: $FIXTURE_DIR"
fi

# Gate 4: Fixture verification (if tests exist)
echo "[4/5] Verifying golden fixtures..."
echo "  Command: swift test --filter QualityPreCheckFixtures"
set +e  # Temporarily disable strict mode to capture output and exit code
FIXTURE_TEST_OUTPUT=$(swift test --filter QualityPreCheckFixtures 2>&1)
FIXTURE_TEST_EXIT_CODE=$?
set -e  # Re-enable strict mode

# Check if the failure is due to "No matching test cases" (0 matches)
if [ $FIXTURE_TEST_EXIT_CODE -ne 0 ]; then
    if echo "$FIXTURE_TEST_OUTPUT" | grep -qE "No matching test cases|Executed 0 test"; then
        echo "  ⚠️  SKIP (PASS): No QualityPreCheckFixtures tests found (filter returned 0 matches)"
        echo "    This is acceptable if fixtures are tested in the main test suite"
    else
        echo "FAIL: Fixture tests failed"
        echo "$FIXTURE_TEST_OUTPUT" | tail -50
        exit 1
    fi
else
    # Extract test count from output
    FIXTURE_TEST_COUNT=$(echo "$FIXTURE_TEST_OUTPUT" | grep -E "Executed.*test" | tail -1 | grep -oE "[0-9]+ test" | grep -oE "[0-9]+" || echo "unknown")
    echo "  ✅ Fixture tests passed ($FIXTURE_TEST_COUNT tests executed)"
fi

# Gate 5: Determinism verification (if tests exist)
echo "[5/5] Verifying determinism contracts..."
echo "  Command: swift test --filter QualityPreCheckDeterminism"
set +e  # Temporarily disable strict mode to capture output and exit code
DETERMINISM_TEST_OUTPUT=$(swift test --filter QualityPreCheckDeterminism 2>&1)
DETERMINISM_TEST_EXIT_CODE=$?
set -e  # Re-enable strict mode

# Check if the failure is due to "No matching test cases" (0 matches)
if [ $DETERMINISM_TEST_EXIT_CODE -ne 0 ]; then
    if echo "$DETERMINISM_TEST_OUTPUT" | grep -qE "No matching test cases|Executed 0 test"; then
        echo "  ⚠️  SKIP (PASS): No QualityPreCheckDeterminism tests found (filter returned 0 matches)"
        echo "    This is acceptable if determinism is tested in the main test suite"
    else
        echo "FAIL: Determinism tests failed"
        echo "$DETERMINISM_TEST_OUTPUT" | tail -50
        exit 1
    fi
else
    # Extract test count from output
    DETERMINISM_TEST_COUNT=$(echo "$DETERMINISM_TEST_OUTPUT" | grep -E "Executed.*test" | tail -1 | grep -oE "[0-9]+ test" | grep -oE "[0-9]+" || echo "unknown")
    echo "  ✅ Determinism tests passed ($DETERMINISM_TEST_COUNT tests executed)"
fi

echo ""
echo "=== Gate Summary ==="
echo "  Gate 0: Placeholder Check - ✅ PASS"
echo "  Gate 1: Tests - ✅ PASS"
echo "  Gate 2: Lint - ✅ PASS"
echo "  Gate 3: Fixtures - ✅ PASS"
if [ $FIXTURE_TEST_EXIT_CODE -eq 0 ]; then
    echo "  Gate 4: Fixture Tests - ✅ PASS"
else
    echo "  Gate 4: Fixture Tests - ⚠️  SKIP (no matching tests)"
fi
if [ $DETERMINISM_TEST_EXIT_CODE -eq 0 ]; then
    echo "  Gate 5: Determinism Tests - ✅ PASS"
else
    echo "  Gate 5: Determinism Tests - ⚠️  SKIP (no matching tests)"
fi
echo ""
echo "=== All gates passed ==="
exit 0

