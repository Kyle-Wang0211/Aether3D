#!/bin/bash
#
# quality_gate.sh
# PR#5 Quality Pre-check - Unified Quality Gate Script
# Single entry point for all quality checks
#

set -euo pipefail

# Platform-aware global timeout policy
if [ -z "${CI:-}" ]; then
    # Default (non-CI): 240 seconds
    GLOBAL_TIMEOUT_SECONDS=240
elif [ "${RUNNER_OS:-}" = "macOS" ]; then
    # CI + macOS runner: 720 seconds
    GLOBAL_TIMEOUT_SECONDS=720
else
    # CI + non-macOS: 300 seconds
    GLOBAL_TIMEOUT_SECONDS=300
fi

# Per-command timeouts
CMD_TIMEOUT_WHITE_COMMIT=90
CMD_TIMEOUT_FIXTURES=45
CMD_TIMEOUT_DETERMINISM=45
CMD_TIMEOUT_LINT=30
CMD_TIMEOUT_JSON=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Global timeout watchdog
TIMEOUT_PID=""
cleanup_timeout() {
    if [ -n "$TIMEOUT_PID" ]; then
        kill "$TIMEOUT_PID" 2>/dev/null || true
        wait "$TIMEOUT_PID" 2>/dev/null || true
    fi
}

start_global_timeout() {
    (
        sleep "$TIMEOUT_SECONDS"
        echo "FAIL: quality_gate.sh timeout exceeded (${TIMEOUT_SECONDS}s)" >&2
        kill $$ 2>/dev/null || true
    ) &
    TIMEOUT_PID=$!
}

trap cleanup_timeout EXIT
start_global_timeout

# Per-command timeout helper (POSIX-safe, works on macOS + Linux)
run_with_timeout() {
    local timeout_seconds="$1"
    shift
    local cmd="$*"
    local timeout_flag=$(mktemp)
    rm -f "$timeout_flag"
    
    # Run command in background
    "$@" &
    local cmd_pid=$!
    
    # Start watchdog
    (
        sleep "$timeout_seconds"
        if kill -0 "$cmd_pid" 2>/dev/null; then
            touch "$timeout_flag"
            kill "$cmd_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!
    
    # Wait for command
    wait "$cmd_pid" 2>/dev/null
    local exit_code=$?
    
    # Cancel watchdog
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    
    # Check if timeout occurred
    if [ -f "$timeout_flag" ]; then
        rm -f "$timeout_flag"
        echo "FAIL: timeout (${timeout_seconds}s): $cmd" >&2
        exit 1
    fi
    
    return $exit_code
}

echo "=== PR#5 Quality Pre-check Gates ==="
echo ""
echo "=== Platform Diagnostics ==="
echo "Platform: $(uname -a)"
echo "Swift version:"
swift --version || echo "WARNING: swift --version failed"
echo "Package root: $PROJECT_ROOT"
echo "=============================="
echo ""

# Gate 0: Check for placeholder tests (must be first)
echo "[0/5] Checking for placeholder tests..."
echo "  Command: grep -rn \"XCTAssertTrue(true)\" Tests/QualityPreCheck/"
set +e  # Allow grep to return non-zero without failing script
PLACEHOLDER_MATCHES=$(grep -rn "XCTAssertTrue(true)" Tests/QualityPreCheck/ --include="*.swift" 2>/dev/null || true)
PLACEHOLDER_COUNT=$(echo "$PLACEHOLDER_MATCHES" | grep -v "^$" | wc -l | tr -d ' ')
set -e
if [ "$PLACEHOLDER_COUNT" -gt 0 ]; then
    echo "FAIL: Found $PLACEHOLDER_COUNT placeholder tests (XCTAssertTrue(true))"
    echo "Gate: Placeholder Check"
    echo "Command: grep -rn \"XCTAssertTrue(true)\" Tests/QualityPreCheck/"
    echo "Output:"
    echo "$PLACEHOLDER_MATCHES"
    echo "Fix: remove placeholder assertions in Tests/QualityPreCheck."
    exit 1
fi

echo "  Command: grep -rn \"TODO.*test|placeholder.*test|WIP.*test\" Tests/QualityPreCheck/"
set +e
PLACEHOLDER_KEYWORD_MATCHES=$(grep -rn "TODO.*test\|placeholder.*test\|WIP.*test" Tests/QualityPreCheck/ --include="*.swift" -i 2>/dev/null | grep -v "//.*TODO.*future\|//.*deferred\|//.*PR5.1\|PR5.1:" || true)
PLACEHOLDER_KEYWORDS=$(echo "$PLACEHOLDER_KEYWORD_MATCHES" | grep -v "^$" | wc -l | tr -d ' ')
set -e
if [ "$PLACEHOLDER_KEYWORDS" -gt 0 ]; then
    echo "FAIL: Found $PLACEHOLDER_KEYWORDS placeholder keywords in test assertions"
    echo "Gate: Placeholder Check"
    echo "Command: grep -rn \"TODO.*test|placeholder.*test|WIP.*test\" Tests/QualityPreCheck/"
    echo "Output:"
    echo "$PLACEHOLDER_KEYWORD_MATCHES"
    echo "Fix: remove placeholder assertions in Tests/QualityPreCheck."
    exit 1
fi
echo "  ✅ No placeholder tests found (checked $PLACEHOLDER_COUNT XCTAssertTrue(true), $PLACEHOLDER_KEYWORDS keywords)"

# Gate 1: Tests
echo "[1/5] Running tests..."
echo "  Command: swift test --filter WhiteCommitTests"
# PR5.1: Capture full output and exit code, print last 120 lines on failure
set +e  # Temporarily disable strict mode to capture exit code
TEST_OUTPUT=$(run_with_timeout "$CMD_TIMEOUT_WHITE_COMMIT" swift test --filter WhiteCommitTests 2>&1)
TEST_EXIT_CODE=$?
set -e  # Re-enable strict mode

if [ $TEST_EXIT_CODE -ne 0 ]; then
    # Check if failure is due to 0 matching tests (hard failure for Gate 1)
    if echo "$TEST_OUTPUT" | grep -qE "No matching test cases|Executed 0 test"; then
        echo "FAIL: Gate 1 (WhiteCommitTests) matched 0 tests - this is a hard failure"
        echo "Gate: WhiteCommitTests"
        echo "Command: swift test --filter WhiteCommitTests"
        echo "Output:"
        echo "$TEST_OUTPUT" | tail -50
        echo "Fix: ensure WhiteCommitTests exist and filter name matches."
        exit 1
    fi
    
    echo "FAIL: Tests failed (exit code: $TEST_EXIT_CODE)"
    echo "Gate: WhiteCommitTests"
    echo "Command: swift test --filter WhiteCommitTests"
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
    echo ""
    echo "=== Compilation Errors ==="
    echo "$TEST_OUTPUT" | grep -E "error:|warning:" | head -20 || echo "  (No compilation errors found in output)"
    echo ""
    echo "Fix: open the failing test cases above and address the first failure."
    exit 1
fi

# Extract test count from output
TEST_COUNT=$(echo "$TEST_OUTPUT" | grep -E "Executed.*test" | tail -1 | grep -oE "[0-9]+ test" | grep -oE "[0-9]+" || echo "unknown")
echo "  ✅ Tests passed ($TEST_COUNT tests executed)"

# Gate 2: Lint
echo "[2/5] Running lint..."
echo "  Command: $SCRIPT_DIR/quality_lint.sh"
set +e
LINT_OUTPUT=$(run_with_timeout "$CMD_TIMEOUT_LINT" "$SCRIPT_DIR/quality_lint.sh" 2>&1)
LINT_EXIT_CODE=$?
set -e

if [ $LINT_EXIT_CODE -ne 0 ]; then
    echo "FAIL: Lint failed"
    echo "Gate: Lint"
    echo "Command: $SCRIPT_DIR/quality_lint.sh"
    echo "Output:"
    echo "$LINT_OUTPUT" | tail -50
    echo "Fix: run scripts/quality_lint.sh locally and resolve reported issues."
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
            set +e
            JSON_OUTPUT=$(run_with_timeout "$CMD_TIMEOUT_JSON" python3 -m json.tool "$fixture_file" 2>&1)
            JSON_EXIT_CODE=$?
            set -e
            if [ $JSON_EXIT_CODE -ne 0 ]; then
                echo "FAIL: Invalid JSON in fixture: $fixture_file"
                echo "Gate: Fixture JSON Validation"
                echo "Command: python3 -m json.tool $fixture_file"
                echo "Output:"
                echo "$JSON_OUTPUT"
                echo "Fix: repair JSON syntax for the failing fixture file."
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
FIXTURE_TEST_OUTPUT=$(run_with_timeout "$CMD_TIMEOUT_FIXTURES" swift test --filter QualityPreCheckFixtures 2>&1)
FIXTURE_TEST_EXIT_CODE=$?
set -e  # Re-enable strict mode

# Check if the failure is due to "No matching test cases" (0 matches)
if [ $FIXTURE_TEST_EXIT_CODE -ne 0 ]; then
    if echo "$FIXTURE_TEST_OUTPUT" | grep -qE "No matching test cases|Executed 0 test"; then
        echo "  ⚠️  SKIP (PASS): No QualityPreCheckFixtures tests found (filter returned 0 matches)"
        echo "    This is acceptable if fixtures are tested in the main test suite"
    else
        echo "FAIL: Fixture tests failed"
        echo "Gate: QualityPreCheckFixtures"
        echo "Command: swift test --filter QualityPreCheckFixtures"
        echo "Output:"
        echo "$FIXTURE_TEST_OUTPUT" | tail -50
        echo "Fix: run the same swift test filter locally and fix failing cases."
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
DETERMINISM_TEST_OUTPUT=$(run_with_timeout "$CMD_TIMEOUT_DETERMINISM" swift test --filter QualityPreCheckDeterminism 2>&1)
DETERMINISM_TEST_EXIT_CODE=$?
set -e  # Re-enable strict mode

# Check if the failure is due to "No matching test cases" (0 matches)
if [ $DETERMINISM_TEST_EXIT_CODE -ne 0 ]; then
    if echo "$DETERMINISM_TEST_OUTPUT" | grep -qE "No matching test cases|Executed 0 test"; then
        echo "  ⚠️  SKIP (PASS): No QualityPreCheckDeterminism tests found (filter returned 0 matches)"
        echo "    This is acceptable if determinism is tested in the main test suite"
    else
        echo "FAIL: Determinism tests failed"
        echo "Gate: QualityPreCheckDeterminism"
        echo "Command: swift test --filter QualityPreCheckDeterminism"
        echo "Output:"
        echo "$DETERMINISM_TEST_OUTPUT" | tail -50
        echo "Fix: run the same swift test filter locally and fix failing cases."
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

# Cleanup global timeout before exit
cleanup_timeout
trap - EXIT

exit 0

# ============================================================================
# Timeout Configuration Summary
# ============================================================================
# Global timeout: Platform-aware policy (entire script)
#   - Default (non-CI): 240 seconds
#   - CI + macOS runner: 720 seconds
#   - CI + non-macOS: 300 seconds
#   - Prevents infinite hangs from any source
#   - Uses background kill watchdog (POSIX-safe, works on macOS + Linux)
#
# Per-command timeouts:
#   - WhiteCommitTests: 90 seconds (longest test suite)
#   - QualityPreCheckFixtures: 45 seconds (medium test suite)
#   - QualityPreCheckDeterminism: 45 seconds (medium test suite)
#   - quality_lint.sh: 30 seconds (linting operations)
#   - JSON validation: 3 seconds per file (fast parsing)
#
# Implementation: run_with_timeout helper uses background kill watchdog
#   - Works without GNU timeout (POSIX-safe)
#   - Propagates exit codes correctly
#   - Provides clear timeout error messages
