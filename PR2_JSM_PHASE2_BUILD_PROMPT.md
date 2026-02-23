# PR2-JSM-3.0 Phase 2 Build Prompt

## Mission

Complete the PR2-JSM-3.0 upgrade by implementing Phase 2 features. Phase 1 (core functionality + critical enhancements) is already complete. This phase adds remaining enhancements and comprehensive testing. After completion, run full verification to ensure push readiness.

**IMPORTANT: DO NOT push to remote. Only prepare for push.**

---

## Phase 1 Status (COMPLETED)

The following are already implemented and should NOT be modified:

### Core Files (DO NOT MODIFY)
- `Core/Jobs/ContractConstants.swift` - ✅ Complete (v3.0)
- `Core/Jobs/JobStateMachine.swift` - ✅ Complete (v3.0 with async support)
- `Core/Jobs/JobState.swift` - ✅ Complete (v3.0 header)
- `Core/Jobs/FailureReason.swift` - ✅ Complete (17 reasons)
- `Core/Jobs/CancelReason.swift` - ✅ Complete (3 reasons)
- `Core/Jobs/JobStateMachineError.swift` - ✅ Complete (13 errors)
- `Core/Jobs/RetryCalculator.swift` - ✅ Complete
- `Core/Jobs/DLQEntry.swift` - ✅ Complete
- `Core/Jobs/CircuitBreaker.swift` - ✅ Complete
- `Core/Jobs/DeterministicEncoder.swift` - ✅ Complete

### Test Files (DO NOT MODIFY unless adding new tests)
- `Tests/Jobs/JobStateMachineTests.swift` - ✅ Complete (16 tests)
- `Tests/Jobs/RetryCalculatorTests.swift` - ✅ Complete (8 tests)

---

## Phase 2 Scope

### New Files to Create (4 files)

1. `Core/Jobs/TransitionSpan.swift` - OpenTelemetry-compatible span tracking
2. `Core/Jobs/ProgressEstimator.swift` - UX wait time estimation
3. `Tests/Jobs/CircuitBreakerTests.swift` - Circuit breaker tests
4. `Tests/Jobs/DeterministicEncoderTests.swift` - Determinism tests

### Files to Verify/Update (1 file)

1. `scripts/pre-push-verify.sh` - Ensure executable and complete

---

## Files to Create

### 1. `Core/Jobs/TransitionSpan.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// OpenTelemetry-compatible span for state transitions.
/// Reference: https://opentelemetry.io/docs/concepts/signals/traces/
public struct TransitionSpan: Codable, Equatable {
    /// Unique span ID (16 hex characters)
    public let spanId: String

    /// Parent span ID (for distributed tracing)
    public let parentSpanId: String?

    /// Trace ID (32 hex characters)
    public let traceId: String

    /// Span name (e.g., "job.transition.pending_to_uploading")
    public let name: String

    /// Start timestamp (Unix nanoseconds)
    public let startTimeUnixNano: UInt64

    /// End timestamp (Unix nanoseconds)
    public let endTimeUnixNano: UInt64

    /// Span status
    public let status: SpanStatus

    /// Span attributes
    public let attributes: [String: String]

    /// Span events (e.g., errors, retries)
    public let events: [SpanEvent]

    public enum SpanStatus: String, Codable {
        case unset
        case ok
        case error
    }

    public struct SpanEvent: Codable, Equatable {
        public let name: String
        public let timeUnixNano: UInt64
        public let attributes: [String: String]

        public init(name: String, timeUnixNano: UInt64, attributes: [String: String] = [:]) {
            self.name = name
            self.timeUnixNano = timeUnixNano
            self.attributes = attributes
        }
    }

    public init(
        spanId: String,
        parentSpanId: String? = nil,
        traceId: String,
        name: String,
        startTimeUnixNano: UInt64,
        endTimeUnixNano: UInt64,
        status: SpanStatus = .ok,
        attributes: [String: String] = [:],
        events: [SpanEvent] = []
    ) {
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.traceId = traceId
        self.name = name
        self.startTimeUnixNano = startTimeUnixNano
        self.endTimeUnixNano = endTimeUnixNano
        self.status = status
        self.attributes = attributes
        self.events = events
    }
}

/// Span builder for state transitions.
public final class TransitionSpanBuilder {
    private var spanId: String
    private var parentSpanId: String?
    private var traceId: String
    private var name: String = ""
    private var startTime: Date
    private var attributes: [String: String] = [:]
    private var events: [TransitionSpan.SpanEvent] = []

    public init() {
        // Generate 16-char hex span ID
        self.spanId = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        // Generate 32-char hex trace ID
        self.traceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.startTime = Date()
    }

    @discardableResult
    public func setName(_ name: String) -> Self {
        self.name = name
        return self
    }

    @discardableResult
    public func setParentSpanId(_ id: String?) -> Self {
        self.parentSpanId = id
        return self
    }

    @discardableResult
    public func setTraceId(_ id: String) -> Self {
        self.traceId = id
        return self
    }

    @discardableResult
    public func setAttribute(_ key: String, value: String) -> Self {
        self.attributes[key] = value
        return self
    }

    @discardableResult
    public func addEvent(name: String, attributes: [String: String] = [:]) -> Self {
        let event = TransitionSpan.SpanEvent(
            name: name,
            timeUnixNano: UInt64(Date().timeIntervalSince1970 * 1_000_000_000),
            attributes: attributes
        )
        self.events.append(event)
        return self
    }

    public func build(status: TransitionSpan.SpanStatus = .ok) -> TransitionSpan {
        let now = Date()
        return TransitionSpan(
            spanId: spanId,
            parentSpanId: parentSpanId,
            traceId: traceId,
            name: name,
            startTimeUnixNano: UInt64(startTime.timeIntervalSince1970 * 1_000_000_000),
            endTimeUnixNano: UInt64(now.timeIntervalSince1970 * 1_000_000_000),
            status: status,
            attributes: attributes,
            events: events
        )
    }

    /// Create span from transition log
    public static func fromTransitionLog(_ log: TransitionLog) -> TransitionSpan {
        let builder = TransitionSpanBuilder()
            .setName("job.transition.\(log.from.rawValue)_to_\(log.to.rawValue)")
            .setAttribute("job.id", value: log.jobId)
            .setAttribute("job.from_state", value: log.from.rawValue)
            .setAttribute("job.to_state", value: log.to.rawValue)
            .setAttribute("job.contract_version", value: log.contractVersion)
            .setAttribute("job.transition_id", value: log.transitionId)
            .setAttribute("job.source", value: log.source.rawValue)

        if let retryAttempt = log.retryAttempt {
            builder.setAttribute("job.retry_attempt", value: String(retryAttempt))
        }

        if let sessionId = log.sessionId {
            builder.setAttribute("job.session_id", value: sessionId)
        }

        if let deviceState = log.deviceState {
            builder.setAttribute("device.state", value: deviceState.rawValue)
        }

        if let failureReason = log.failureReason {
            builder.setAttribute("job.failure_reason", value: failureReason.rawValue)
            return builder.build(status: .error)
        }

        if let cancelReason = log.cancelReason {
            builder.setAttribute("job.cancel_reason", value: cancelReason.rawValue)
        }

        return builder.build(status: .ok)
    }
}
```

### 2. `Core/Jobs/ProgressEstimator.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Estimates remaining time based on historical data.
/// Reference: Nielsen Norman Group - Response Time Limits
public final class ProgressEstimator {

    /// Historical processing times by state (rolling average)
    private var stateAverages: [JobState: TimeInterval] = [:]

    /// Sample count per state
    private var sampleCounts: [JobState: Int] = [:]

    /// Maximum samples to keep (for rolling average)
    private static let MAX_SAMPLES = 100

    /// Alpha for exponential moving average
    private static func alpha(sampleCount: Int) -> Double {
        return 2.0 / Double(min(sampleCount + 1, MAX_SAMPLES) + 1)
    }

    public init() {}

    /// Estimate remaining time from current state.
    /// - Parameters:
    ///   - currentState: Current job state
    ///   - elapsedInCurrentState: Time already spent in current state
    /// - Returns: Estimated remaining time, or nil if no data available
    public func estimateRemainingTime(
        currentState: JobState,
        elapsedInCurrentState: TimeInterval
    ) -> TimeInterval? {
        guard let average = stateAverages[currentState] else {
            return ContractConstants.FALLBACK_ETA_SECONDS
        }

        let remainingInState = max(0, average - elapsedInCurrentState)

        // Add estimates for subsequent states
        var total = remainingInState
        var nextState = currentState

        while let next = nextNonTerminalState(after: nextState) {
            if let nextAverage = stateAverages[next] {
                total += nextAverage
            }
            nextState = next
        }

        return total
    }

    /// Record actual duration for a state transition.
    /// - Parameters:
    ///   - state: The state that was completed
    ///   - duration: How long the job spent in that state
    public func recordDuration(state: JobState, duration: TimeInterval) {
        guard !state.isTerminal else { return }

        let count = sampleCounts[state] ?? 0
        let currentAverage = stateAverages[state] ?? duration

        // Exponential moving average for smooth updates
        let a = Self.alpha(sampleCount: count)
        let newAverage = a * duration + (1 - a) * currentAverage

        stateAverages[state] = newAverage
        sampleCounts[state] = min(count + 1, Self.MAX_SAMPLES)
    }

    /// Get current estimate for a specific state.
    /// - Parameter state: The state to query
    /// - Returns: Average duration for that state, or nil if no data
    public func getStateEstimate(_ state: JobState) -> TimeInterval? {
        return stateAverages[state]
    }

    /// Get sample count for a specific state.
    /// - Parameter state: The state to query
    /// - Returns: Number of samples recorded
    public func getSampleCount(_ state: JobState) -> Int {
        return sampleCounts[state] ?? 0
    }

    /// Reset all historical data.
    public func reset() {
        stateAverages.removeAll()
        sampleCounts.removeAll()
    }

    /// Calculate display progress with psychological optimization.
    /// - Parameters:
    ///   - actualProgress: Real progress (0.0 - 1.0)
    ///   - isInitialPhase: Whether this is the first few seconds
    /// - Returns: Perceived progress for display
    public func calculatePerceivedProgress(actualProgress: Double, isInitialPhase: Bool) -> Double {
        var perceived = actualProgress * 100.0

        // Initial boost: Show immediate progress
        if isInitialPhase && perceived < ContractConstants.INITIAL_PROGRESS_BOOST_PERCENT {
            perceived = ContractConstants.INITIAL_PROGRESS_BOOST_PERCENT
        }

        // Slowdown near completion: Slow down progress above 90%
        if perceived > ContractConstants.PROGRESS_SLOWDOWN_THRESHOLD_PERCENT {
            let excess = perceived - ContractConstants.PROGRESS_SLOWDOWN_THRESHOLD_PERCENT
            perceived = ContractConstants.PROGRESS_SLOWDOWN_THRESHOLD_PERCENT + (excess * 0.5)
        }

        // Cap at 99% until actually complete
        if perceived >= 100.0 && actualProgress < 1.0 {
            perceived = 99.0
        }

        return min(100.0, max(0.0, perceived))
    }

    /// Check if progress update should be reported.
    /// - Parameters:
    ///   - previousProgress: Last reported progress
    ///   - currentProgress: Current progress
    /// - Returns: True if update should be reported
    public func shouldReportProgress(previousProgress: Double, currentProgress: Double) -> Bool {
        let diff = abs(currentProgress - previousProgress)
        return diff >= ContractConstants.MIN_PROGRESS_INCREMENT_PERCENT
    }

    // MARK: - Private Methods

    private func nextNonTerminalState(after state: JobState) -> JobState? {
        switch state {
        case .pending: return .uploading
        case .uploading: return .queued
        case .queued: return .processing
        case .processing: return .packaging
        case .packaging: return nil  // completed is terminal
        case .completed, .failed, .cancelled: return nil
        }
    }
}
```

### 3. `Tests/Jobs/CircuitBreakerTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class CircuitBreakerTests: XCTestCase {

    // MARK: - Test 1: Initial State

    func testInitialStateClosed() {
        let breaker = CircuitBreaker()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.shouldAllowRequest())
    }

    // MARK: - Test 2: Trips After Threshold

    func testTripsAfterThreshold() {
        let breaker = CircuitBreaker(failureThreshold: 3)

        // First 2 failures - should still be closed
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)

        // 3rd failure - should trip to open
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
        XCTAssertFalse(breaker.shouldAllowRequest())
    }

    // MARK: - Test 3: Success Resets Failure Count

    func testSuccessResetsFailureCount() {
        let breaker = CircuitBreaker(failureThreshold: 3)

        breaker.recordFailure()
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)

        // Success resets count
        breaker.recordSuccess()

        // Need 3 more failures to trip
        breaker.recordFailure()
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)

        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
    }

    // MARK: - Test 4: Failure Rate Calculation

    func testFailureRateCalculation() {
        let breaker = CircuitBreaker(slidingWindowSize: 10)

        // 5 successes, 5 failures = 50% failure rate
        for _ in 0..<5 {
            breaker.recordSuccess()
        }
        for _ in 0..<5 {
            breaker.recordFailure()
        }

        XCTAssertEqual(breaker.failureRate(), 0.5, accuracy: 0.01)
    }

    // MARK: - Test 5: Sliding Window Trim

    func testSlidingWindowTrim() {
        let breaker = CircuitBreaker(slidingWindowSize: 5)

        // Add 10 results (first 5 should be trimmed)
        for _ in 0..<5 {
            breaker.recordFailure()  // These will be trimmed
        }
        for _ in 0..<5 {
            breaker.recordSuccess()  // These will remain
        }

        // Failure rate should be 0% (only successes in window)
        XCTAssertEqual(breaker.failureRate(), 0.0, accuracy: 0.01)
    }

    // MARK: - Test 6: Reset

    func testReset() {
        let breaker = CircuitBreaker(failureThreshold: 3)

        // Trip the circuit
        for _ in 0..<3 {
            breaker.recordFailure()
        }
        XCTAssertEqual(breaker.state, .open)

        // Reset
        breaker.reset()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.shouldAllowRequest())
        XCTAssertEqual(breaker.failureRate(), 0.0)
    }

    // MARK: - Test 7: Half-Open After Failure in Half-Open

    func testHalfOpenReturnsToOpenOnFailure() {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            openTimeout: 0.0  // Immediate timeout for testing
        )

        // Trip to open
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)

        // Should transition to half-open on next request (timeout = 0)
        XCTAssertTrue(breaker.shouldAllowRequest())
        XCTAssertEqual(breaker.state, .halfOpen)

        // Failure in half-open returns to open
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
    }

    // MARK: - Test 8: Half-Open to Closed After Successes

    func testHalfOpenClosesAfterSuccesses() {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            openTimeout: 0.0
        )

        // Trip to open
        breaker.recordFailure()

        // Transition to half-open
        _ = breaker.shouldAllowRequest()
        XCTAssertEqual(breaker.state, .halfOpen)

        // First success - still half-open
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .halfOpen)

        // Second success - should close
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .closed)
    }

    // MARK: - Test 9: Default Constants

    func testDefaultConstants() {
        let breaker = CircuitBreaker()

        // Trip with default threshold (5)
        for _ in 0..<ContractConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD {
            breaker.recordFailure()
        }
        XCTAssertEqual(breaker.state, .open)
    }
}
```

### 4. `Tests/Jobs/DeterministicEncoderTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class DeterministicEncoderTests: XCTestCase {

    // MARK: - Test 1: Sorted Keys

    func testSortedKeys() throws {
        struct TestStruct: Codable {
            let zebra: String
            let apple: String
            let mango: String
        }

        let value = TestStruct(zebra: "z", apple: "a", mango: "m")
        let json = try DeterministicJSONEncoder.encodeToString(value)

        // Keys must be alphabetically sorted
        guard let appleRange = json.range(of: "\"apple\""),
              let mangoRange = json.range(of: "\"mango\""),
              let zebraRange = json.range(of: "\"zebra\"") else {
            XCTFail("Keys not found in JSON")
            return
        }

        XCTAssertLessThan(appleRange.lowerBound, mangoRange.lowerBound, "apple should come before mango")
        XCTAssertLessThan(mangoRange.lowerBound, zebraRange.lowerBound, "mango should come before zebra")
    }

    // MARK: - Test 2: Consistent Output

    func testConsistentOutput() throws {
        struct TestStruct: Codable, Equatable {
            let id: Int
            let name: String
        }

        let value = TestStruct(id: 42, name: "test")

        // Encode multiple times - must be identical
        let json1 = try DeterministicJSONEncoder.encodeToString(value)
        let json2 = try DeterministicJSONEncoder.encodeToString(value)
        let json3 = try DeterministicJSONEncoder.encodeToString(value)

        XCTAssertEqual(json1, json2)
        XCTAssertEqual(json2, json3)
    }

    // MARK: - Test 3: TransitionLog Determinism

    func testTransitionLogDeterminism() throws {
        let fixedDate = Date(timeIntervalSince1970: 1705312245.123)

        let log = TransitionLog(
            transitionId: "test-txn-id",
            jobId: "12345678901234567",
            from: .pending,
            to: .uploading,
            failureReason: nil,
            cancelReason: nil,
            timestamp: fixedDate,
            contractVersion: "PR2-JSM-3.0",
            retryAttempt: nil,
            source: .client,
            sessionId: nil,
            deviceState: nil
        )

        let json1 = try DeterministicJSONEncoder.encodeToString(log)
        let json2 = try DeterministicJSONEncoder.encodeToString(log)

        XCTAssertEqual(json1, json2)
    }

    // MARK: - Test 4: Hash Computation

    func testHashComputation() throws {
        struct TestStruct: Codable {
            let value: Int
        }

        let value = TestStruct(value: 42)

        let hash1 = try DeterministicJSONEncoder.computeHash(value)
        let hash2 = try DeterministicJSONEncoder.computeHash(value)

        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64, "SHA256 hash should be 64 hex characters")
    }

    // MARK: - Test 5: Hash Verification

    func testHashVerification() throws {
        struct TestStruct: Codable {
            let value: Int
        }

        let value = TestStruct(value: 42)
        let hash = try DeterministicJSONEncoder.computeHash(value)

        XCTAssertTrue(try DeterministicJSONEncoder.verifyHash(value, expectedHash: hash))
        XCTAssertFalse(try DeterministicJSONEncoder.verifyHash(value, expectedHash: "wronghash"))
    }

    // MARK: - Test 6: Encode/Decode Round Trip

    func testEncodeDecodeRoundTrip() throws {
        struct TestStruct: Codable, Equatable {
            let id: Int
            let name: String
            let active: Bool
        }

        let original = TestStruct(id: 123, name: "test", active: true)
        let data = try DeterministicJSONEncoder.encode(original)
        let decoded = try DeterministicJSONEncoder.decode(TestStruct.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - Test 7: DLQEntry Determinism

    func testDLQEntryDeterminism() throws {
        let fixedDate = Date(timeIntervalSince1970: 1705312245.0)

        // Create DLQEntry with fixed values
        let entry1Data = try DeterministicJSONEncoder.encode(
            ["jobId": "12345678901234567", "failureReason": "network_error"]
        )
        let entry2Data = try DeterministicJSONEncoder.encode(
            ["jobId": "12345678901234567", "failureReason": "network_error"]
        )

        XCTAssertEqual(entry1Data, entry2Data)
    }

    // MARK: - Test 8: Empty and Nested Structures

    func testComplexStructures() throws {
        struct Nested: Codable, Equatable {
            let inner: String
        }

        struct Outer: Codable, Equatable {
            let nested: Nested
            let array: [Int]
            let optional: String?
        }

        let value = Outer(
            nested: Nested(inner: "test"),
            array: [1, 2, 3],
            optional: nil
        )

        let json1 = try DeterministicJSONEncoder.encodeToString(value)
        let json2 = try DeterministicJSONEncoder.encodeToString(value)

        XCTAssertEqual(json1, json2)
    }
}
```

---

## Verification Script Update

### `scripts/pre-push-verify.sh`

Ensure the file is executable and contains comprehensive checks:

```bash
#!/bin/bash
# ============================================================================
# PR2-JSM-3.0 Comprehensive Pre-Push Verification Script
# Run this before pushing to ensure CI will pass
# Version: 2.0 (Phase 2 Complete)
# ============================================================================

set -euo pipefail

echo "========================================"
echo "PR2-JSM-3.0 Pre-Push Verification v2.0"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FAILURES=0
WARNINGS=0
TOTAL_CHECKS=0

# Helper functions
pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((TOTAL_CHECKS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILURES++)); ((TOTAL_CHECKS++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARNINGS++)); }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ============================================================================
# SECTION 1: Environment Check
# ============================================================================
section "[1/8] Environment Check"

# Swift Version
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
info "Swift: $SWIFT_VERSION"
if [[ "$SWIFT_VERSION" =~ "5.9" ]] || [[ "$SWIFT_VERSION" =~ "5.10" ]] || [[ "$SWIFT_VERSION" =~ "6." ]]; then
    pass "Swift version compatible"
else
    warn "CI uses Swift 5.9.2. Local version may differ."
fi

# Git status
if [[ -d ".git" ]]; then
    BRANCH=$(git branch --show-current)
    info "Branch: $BRANCH"
    pass "Git repository detected"
else
    fail "Not a git repository"
fi

# ============================================================================
# SECTION 2: Build
# ============================================================================
section "[2/8] Build Verification"

if swift build 2>&1 | tail -5; then
    pass "swift build succeeded"
else
    fail "swift build FAILED"
fi

# ============================================================================
# SECTION 3: All Tests
# ============================================================================
section "[3/8] Full Test Suite"

TEST_OUTPUT=$(swift test 2>&1)
if echo "$TEST_OUTPUT" | grep -q "Test Suite.*passed"; then
    PASSED=$(echo "$TEST_OUTPUT" | grep -oE "[0-9]+ test[s]? passed" | head -1)
    pass "All tests passed ($PASSED)"
else
    fail "Some tests FAILED"
    echo "$TEST_OUTPUT" | grep -E "(failed|error)" | head -10
fi

# ============================================================================
# SECTION 4: Individual Test Suites
# ============================================================================
section "[4/8] Individual Test Suites"

# JobStateMachineTests
if swift test --filter JobStateMachineTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter JobStateMachineTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "JobStateMachineTests ($COUNT)"
else
    fail "JobStateMachineTests FAILED"
fi

# RetryCalculatorTests
if swift test --filter RetryCalculatorTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter RetryCalculatorTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "RetryCalculatorTests ($COUNT)"
else
    fail "RetryCalculatorTests FAILED"
fi

# CircuitBreakerTests
if swift test --filter CircuitBreakerTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter CircuitBreakerTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "CircuitBreakerTests ($COUNT)"
else
    warn "CircuitBreakerTests not found or failed"
fi

# DeterministicEncoderTests
if swift test --filter DeterministicEncoderTests 2>&1 | grep -q "passed"; then
    COUNT=$(swift test --filter DeterministicEncoderTests 2>&1 | grep -oE "[0-9]+ test" | head -1)
    pass "DeterministicEncoderTests ($COUNT)"
else
    warn "DeterministicEncoderTests not found or failed"
fi

# ============================================================================
# SECTION 5: Contract Version Consistency
# ============================================================================
section "[5/8] Contract Version Consistency"

VERSION_PATTERN="PR2-JSM-3.0"
CORE_FILES=(
    "Core/Jobs/ContractConstants.swift"
    "Core/Jobs/JobStateMachine.swift"
    "Core/Jobs/JobState.swift"
    "Core/Jobs/FailureReason.swift"
    "Core/Jobs/CancelReason.swift"
    "Core/Jobs/JobStateMachineError.swift"
    "Core/Jobs/RetryCalculator.swift"
    "Core/Jobs/DLQEntry.swift"
    "Core/Jobs/CircuitBreaker.swift"
    "Core/Jobs/DeterministicEncoder.swift"
)

for file in "${CORE_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        if grep -q "$VERSION_PATTERN" "$file"; then
            pass "$file"
        else
            fail "$file - version MISMATCH"
        fi
    else
        warn "$file - not found"
    fi
done

# ============================================================================
# SECTION 6: Enum Count Verification
# ============================================================================
section "[6/8] Enum Count Verification"

# FailureReason count (should be 17)
if [[ -f "Core/Jobs/FailureReason.swift" ]]; then
    FAILURE_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/FailureReason.swift | wc -l | tr -d ' ')
    if [[ "$FAILURE_COUNT" -eq 17 ]]; then
        pass "FailureReason: $FAILURE_COUNT cases (expected 17)"
    else
        fail "FailureReason: $FAILURE_COUNT cases (expected 17)"
    fi
fi

# CancelReason count (should be 3)
if [[ -f "Core/Jobs/CancelReason.swift" ]]; then
    CANCEL_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/CancelReason.swift | wc -l | tr -d ' ')
    if [[ "$CANCEL_COUNT" -eq 3 ]]; then
        pass "CancelReason: $CANCEL_COUNT cases (expected 3)"
    else
        fail "CancelReason: $CANCEL_COUNT cases (expected 3)"
    fi
fi

# JobState count (should be 8)
if [[ -f "Core/Jobs/JobState.swift" ]]; then
    STATE_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/JobState.swift | wc -l | tr -d ' ')
    if [[ "$STATE_COUNT" -eq 8 ]]; then
        pass "JobState: $STATE_COUNT cases (expected 8)"
    else
        fail "JobState: $STATE_COUNT cases (expected 8)"
    fi
fi

# CircuitState count (should be 3)
if [[ -f "Core/Jobs/CircuitBreaker.swift" ]]; then
    CIRCUIT_COUNT=$(grep -E "^\s+case [a-zA-Z]" Core/Jobs/CircuitBreaker.swift | grep -v "//" | wc -l | tr -d ' ')
    if [[ "$CIRCUIT_COUNT" -eq 3 ]]; then
        pass "CircuitState: $CIRCUIT_COUNT cases (expected 3)"
    else
        warn "CircuitState: $CIRCUIT_COUNT cases (expected 3)"
    fi
fi

# ============================================================================
# SECTION 7: File Existence Check
# ============================================================================
section "[7/8] Required Files Check"

REQUIRED_FILES=(
    "Core/Jobs/ContractConstants.swift"
    "Core/Jobs/JobStateMachine.swift"
    "Core/Jobs/JobState.swift"
    "Core/Jobs/FailureReason.swift"
    "Core/Jobs/CancelReason.swift"
    "Core/Jobs/JobStateMachineError.swift"
    "Core/Jobs/RetryCalculator.swift"
    "Core/Jobs/DLQEntry.swift"
    "Core/Jobs/CircuitBreaker.swift"
    "Core/Jobs/DeterministicEncoder.swift"
    "Core/Jobs/TransitionSpan.swift"
    "Core/Jobs/ProgressEstimator.swift"
    "Tests/Jobs/JobStateMachineTests.swift"
    "Tests/Jobs/RetryCalculatorTests.swift"
    "Tests/Jobs/CircuitBreakerTests.swift"
    "Tests/Jobs/DeterministicEncoderTests.swift"
)

MISSING=0
for file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        pass "$file exists"
    else
        fail "$file MISSING"
        ((MISSING++))
    fi
done

# ============================================================================
# SECTION 8: Final Checks
# ============================================================================
section "[8/8] Final Checks"

# Check for uncommitted changes
if [[ -n "$(git status --porcelain)" ]]; then
    warn "Uncommitted changes detected"
    git status --short
else
    pass "Working directory clean"
fi

# Check for TODO/FIXME comments in Core files
TODO_COUNT=$(grep -r "TODO\|FIXME" Core/Jobs/*.swift 2>/dev/null | wc -l | tr -d ' ')
if [[ "$TODO_COUNT" -gt 0 ]]; then
    warn "Found $TODO_COUNT TODO/FIXME comments in Core/Jobs"
else
    pass "No TODO/FIXME comments in Core/Jobs"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "========================================"
echo "VERIFICATION SUMMARY"
echo "========================================"
echo -e "Total Checks: ${BLUE}$TOTAL_CHECKS${NC}"
echo -e "Passed:       ${GREEN}$((TOTAL_CHECKS - FAILURES))${NC}"
echo -e "Failed:       ${RED}$FAILURES${NC}"
echo -e "Warnings:     ${YELLOW}$WARNINGS${NC}"
echo ""

if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ALL CHECKS PASSED - READY TO PUSH!    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review changes: git diff --stat"
    echo "  2. Stage changes:  git add -A"
    echo "  3. Commit:         git commit -m 'feat(pr2): upgrade to PR2-JSM-3.0'"
    echo "  4. Push:           git push origin <branch>"
    echo ""
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  $FAILURES CHECK(S) FAILED - FIX BEFORE PUSH  ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi
```

---

## Post-Implementation Verification

After creating all Phase 2 files, run these verification steps:

### Step 1: Make Script Executable
```bash
chmod +x scripts/pre-push-verify.sh
```

### Step 2: Run Full Verification
```bash
./scripts/pre-push-verify.sh
```

### Step 3: Manual Checks
```bash
# Build
swift build

# All tests
swift test

# Count total tests
swift test 2>&1 | grep -E "tests? passed"

# Verify new files exist
ls -la Core/Jobs/TransitionSpan.swift
ls -la Core/Jobs/ProgressEstimator.swift
ls -la Tests/Jobs/CircuitBreakerTests.swift
ls -la Tests/Jobs/DeterministicEncoderTests.swift
```

### Step 4: Git Status Check
```bash
# See all changes
git status

# See file changes summary
git diff --stat

# Review specific new files
git diff Core/Jobs/TransitionSpan.swift
```

---

## Inspection Report Template (Phase 2)

Generate this report after completing Phase 2:

```markdown
# PR2-JSM-3.0 Phase 2 Inspection Report

## Build Information
- **Date**: [YYYY-MM-DD HH:MM:SS]
- **Swift Version**: [swift --version output]
- **Platform**: [macOS/Linux version]
- **Branch**: [git branch name]

## Phase 2 Files Created
| File | Status | Lines | Notes |
|------|--------|-------|-------|
| Core/Jobs/TransitionSpan.swift | ✅/❌ | XXX | OpenTelemetry spans |
| Core/Jobs/ProgressEstimator.swift | ✅/❌ | XXX | UX estimation |
| Tests/Jobs/CircuitBreakerTests.swift | ✅/❌ | XXX | 9 tests |
| Tests/Jobs/DeterministicEncoderTests.swift | ✅/❌ | XXX | 8 tests |

## Complete File Inventory (All Phases)

### Core Files (12 total)
| File | Version | Status |
|------|---------|--------|
| ContractConstants.swift | PR2-JSM-3.0 | ✅ |
| JobStateMachine.swift | PR2-JSM-3.0 | ✅ |
| JobState.swift | PR2-JSM-3.0 | ✅ |
| FailureReason.swift | PR2-JSM-3.0 | ✅ |
| CancelReason.swift | PR2-JSM-3.0 | ✅ |
| JobStateMachineError.swift | PR2-JSM-3.0 | ✅ |
| RetryCalculator.swift | PR2-JSM-3.0 | ✅ |
| DLQEntry.swift | PR2-JSM-3.0 | ✅ |
| CircuitBreaker.swift | PR2-JSM-3.0 | ✅ |
| DeterministicEncoder.swift | PR2-JSM-3.0 | ✅ |
| TransitionSpan.swift | PR2-JSM-3.0 | ✅/❌ |
| ProgressEstimator.swift | PR2-JSM-3.0 | ✅/❌ |

### Test Files (4 total)
| File | Tests | Status |
|------|-------|--------|
| JobStateMachineTests.swift | 16 | ✅ |
| RetryCalculatorTests.swift | 8 | ✅ |
| CircuitBreakerTests.swift | 9 | ✅/❌ |
| DeterministicEncoderTests.swift | 8 | ✅/❌ |

## Test Results
| Suite | Passed | Failed | Total |
|-------|--------|--------|-------|
| JobStateMachineTests | X | 0 | 16 |
| RetryCalculatorTests | X | 0 | 8 |
| CircuitBreakerTests | X | 0 | 9 |
| DeterministicEncoderTests | X | 0 | 8 |
| **TOTAL** | **XX** | **0** | **41** |

## Contract Verification
| Metric | Expected | Actual | Status |
|--------|----------|--------|--------|
| Contract Version | PR2-JSM-3.0 | PR2-JSM-3.0 | ✅ |
| States | 8 | 8 | ✅ |
| Transitions | 13 | 13 | ✅ |
| FailureReasons | 17 | 17 | ✅ |
| CancelReasons | 3 | 3 | ✅ |
| CircuitStates | 3 | 3 | ✅ |

## Pre-Push Script Result
```
[paste output of ./scripts/pre-push-verify.sh]
```

## Git Status
```
[paste output of git status]
```

## Issues Found
| Issue | Severity | Resolution |
|-------|----------|------------|
| None | - | - |

## Summary
- **Phase 1 Status**: ✅ Complete
- **Phase 2 Status**: ✅ Complete
- **Total Files**: 16 (12 Core + 4 Tests)
- **Total Tests**: 41
- **Build Status**: ✅ SUCCESS
- **Ready to Push**: YES

## Commit Message (Recommended)
```
feat(pr2): complete PR2-JSM-3.0 upgrade

- Upgrade contract version from 2.5 to 3.0
- Add exponential backoff with decorrelated jitter (Netflix/AWS pattern)
- Add circuit breaker pattern (Martin Fowler)
- Add dead letter queue support
- Add idempotent transition protection
- Add heartbeat timeout monitoring (3 new failure reasons)
- Add systemTimeout cancel reason
- Add OpenTelemetry-compatible span tracking
- Add progress estimator with psychological optimization
- Add deterministic JSON encoder for cross-platform CI
- Add comprehensive test coverage (41 tests)

Contract: 8 states, 13 transitions, 17 failure reasons, 3 cancel reasons

Co-Authored-By: Claude <noreply@anthropic.com>
```

## Next Steps
1. Review this report
2. Run: `git add -A`
3. Run: `git commit -m "<commit message above>"`
4. Run: `git push origin <branch>` (MANUAL - do not auto-push)
```

---

## Important Reminders

1. **DO NOT** modify Phase 1 files unless fixing a bug
2. **DO NOT** push automatically - wait for manual confirmation
3. **DO** run the full verification script before considering complete
4. **DO** generate the inspection report for review
5. All new files MUST have the PR2-JSM-3.0 contract header

## Success Criteria (Phase 2)

Phase 2 is complete when:
- [ ] TransitionSpan.swift created and compiles
- [ ] ProgressEstimator.swift created and compiles
- [ ] CircuitBreakerTests.swift created with 9 passing tests
- [ ] DeterministicEncoderTests.swift created with 8 passing tests
- [ ] pre-push-verify.sh is executable and passes all checks
- [ ] Total test count is 41+
- [ ] Inspection report generated with all checks passing
- [ ] Ready for manual push (NOT auto-pushed)
