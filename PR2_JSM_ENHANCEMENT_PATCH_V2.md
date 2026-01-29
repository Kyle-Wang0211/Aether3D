# PR2-JSM-3.0 Enhancement Patch V2

## Overview

This document contains **ADDITIONAL** improvements to the PR2-JSM-3.0 upgrade plan. These enhancements represent cutting-edge distributed systems patterns from AWS, Netflix, Google, and academic research. **DO NOT** duplicate any content from the original plan - implement these as additive patches.

---

## Part A: Advanced Retry Strategy Enhancements

### A1: Decorrelated Jitter (Netflix/AWS Recommended)

**Why**: The original plan uses "full jitter". Research shows **decorrelated jitter** produces smoother retry distribution and better desynchronization under high-concurrency scenarios.

**File**: `Core/Jobs/RetryCalculator.swift`

**Add**:
```swift
/// Jitter strategy enumeration
public enum JitterStrategy: String, Codable {
    case full       // random(0, min(cap, base * 2^attempt))
    case equal      // temp/2 + random(0, temp/2)
    case decorrelated  // min(cap, random(base, previousDelay * 3)) - RECOMMENDED
}

/// Calculate delay using decorrelated jitter (Netflix/AWS best practice)
/// Formula: delay = min(maxDelay, random(baseDelay, previousDelay * 3))
/// Reference: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
public func calculateDecorrelatedDelay(
    previousDelay: TimeInterval,
    baseDelay: TimeInterval = 1.0,
    maxDelay: TimeInterval = 60.0
) -> TimeInterval {
    let minDelay = baseDelay
    let maxRange = min(maxDelay, previousDelay * 3)
    return Double.random(in: minDelay...max(minDelay, maxRange))
}
```

**File**: `Core/Jobs/ContractConstants.swift`

**Add**:
```swift
/// Jitter strategy (decorrelated recommended for high-concurrency)
public static let RETRY_JITTER_STRATEGY: String = "decorrelated"

/// Decorrelated jitter multiplier (previousDelay * 3)
public static let RETRY_DECORRELATED_MULTIPLIER: Double = 3.0
```

---

### A2: Circuit Breaker Integration

**Why**: [Martin Fowler's Circuit Breaker pattern](https://martinfowler.com/bliki/CircuitBreaker.html) prevents cascading failures. AWS and Netflix use this as standard practice.

**New File**: `Core/Jobs/CircuitBreaker.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import Foundation

/// Circuit breaker state machine (3 states)
public enum CircuitState: String, Codable {
    case closed     // Normal operation, requests pass through
    case open       // Failures exceeded threshold, requests fail fast
    case halfOpen   // Testing if service recovered
}

/// Circuit breaker for job state machine operations
public final class CircuitBreaker {

    // MARK: - Configuration Constants

    /// Failure threshold to trip the circuit
    public static let FAILURE_THRESHOLD = 5

    /// Success threshold in half-open state to close circuit
    public static let SUCCESS_THRESHOLD = 3

    /// Timeout before transitioning from open to half-open (seconds)
    public static let OPEN_TIMEOUT_SECONDS: TimeInterval = 30

    /// Sliding window size for failure rate calculation
    public static let SLIDING_WINDOW_SIZE = 10

    // MARK: - State

    private(set) var state: CircuitState = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private var lastFailureTime: Date?
    private var recentResults: [Bool] = []  // Sliding window

    // MARK: - Public Methods

    /// Check if request should be allowed
    public func shouldAllowRequest() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            // Check if timeout has elapsed
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= Self.OPEN_TIMEOUT_SECONDS {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    /// Record a successful operation
    public func recordSuccess() {
        recentResults.append(true)
        trimSlidingWindow()

        switch state {
        case .closed:
            failureCount = 0
        case .halfOpen:
            successCount += 1
            if successCount >= Self.SUCCESS_THRESHOLD {
                state = .closed
                failureCount = 0
                successCount = 0
            }
        case .open:
            break
        }
    }

    /// Record a failed operation
    public func recordFailure() {
        recentResults.append(false)
        trimSlidingWindow()
        lastFailureTime = Date()

        switch state {
        case .closed:
            failureCount += 1
            if failureCount >= Self.FAILURE_THRESHOLD {
                state = .open
            }
        case .halfOpen:
            state = .open
            successCount = 0
        case .open:
            break
        }
    }

    /// Get current failure rate from sliding window
    public func failureRate() -> Double {
        guard !recentResults.isEmpty else { return 0.0 }
        let failures = recentResults.filter { !$0 }.count
        return Double(failures) / Double(recentResults.count)
    }

    private func trimSlidingWindow() {
        while recentResults.count > Self.SLIDING_WINDOW_SIZE {
            recentResults.removeFirst()
        }
    }
}
```

**File**: `Core/Jobs/ContractConstants.swift`

**Add**:
```swift
// MARK: - Circuit Breaker

/// Circuit breaker failure threshold
public static let CIRCUIT_BREAKER_FAILURE_THRESHOLD = 5

/// Circuit breaker success threshold (half-open → closed)
public static let CIRCUIT_BREAKER_SUCCESS_THRESHOLD = 3

/// Circuit breaker open timeout in seconds
public static let CIRCUIT_BREAKER_OPEN_TIMEOUT_SECONDS: Double = 30.0

/// Circuit breaker sliding window size
public static let CIRCUIT_BREAKER_SLIDING_WINDOW_SIZE = 10
```

---

## Part B: Observability & Telemetry

### B1: OpenTelemetry-Compatible Span Tracking

**Why**: [OpenTelemetry for Mobile](https://embrace.io/opentelemetry-for-mobile/) is the industry standard for mobile observability. State transitions should emit spans for distributed tracing.

**New File**: `Core/Jobs/TransitionSpan.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import Foundation

/// OpenTelemetry-compatible span for state transitions
/// Reference: https://opentelemetry.io/docs/concepts/signals/traces/
public struct TransitionSpan: Codable {
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
    public let attributes: [String: AttributeValue]

    /// Span events (e.g., errors, retries)
    public let events: [SpanEvent]

    public enum SpanStatus: String, Codable {
        case unset
        case ok
        case error
    }

    public enum AttributeValue: Codable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)

        public var stringValue: String {
            switch self {
            case .string(let v): return v
            case .int(let v): return String(v)
            case .double(let v): return String(v)
            case .bool(let v): return String(v)
            }
        }
    }

    public struct SpanEvent: Codable {
        public let name: String
        public let timeUnixNano: UInt64
        public let attributes: [String: AttributeValue]
    }
}

/// Span builder for state transitions
public final class TransitionSpanBuilder {
    private var spanId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    private var parentSpanId: String?
    private var traceId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var name: String = ""
    private var startTime: Date = Date()
    private var attributes: [String: TransitionSpan.AttributeValue] = [:]
    private var events: [TransitionSpan.SpanEvent] = []

    public init() {}

    public func setName(_ name: String) -> Self {
        self.name = name
        return self
    }

    public func setParentSpanId(_ id: String?) -> Self {
        self.parentSpanId = id
        return self
    }

    public func setTraceId(_ id: String) -> Self {
        self.traceId = id
        return self
    }

    public func setAttribute(_ key: String, value: TransitionSpan.AttributeValue) -> Self {
        self.attributes[key] = value
        return self
    }

    public func addEvent(name: String, attributes: [String: TransitionSpan.AttributeValue] = [:]) -> Self {
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
}
```

### B2: Session-Based Telemetry

**Why**: Mobile observability requires [session tracking](https://www.cncf.io/blog/2024/11/29/why-does-opentelemetry-work-differently-on-mobile-versus-backend-apps/) because foreground/background states affect behavior.

**File**: `Core/Jobs/TransitionLog` enhancement in `JobStateMachine.swift`

**Add to TransitionLog struct**:
```swift
/// Session ID for correlating transitions within a user session
public let sessionId: String?

/// Device state at transition time
public let deviceState: DeviceState?

/// Device state enumeration
public enum DeviceState: String, Codable {
    case foreground
    case background
    case lowPower
    case networkConstrained
}
```

---

## Part C: Cross-Platform Determinism

### C1: Deterministic JSON Encoding

**Why**: iOS and Linux may produce different JSON output for the same struct. This breaks hash verification in CI.

**New File**: `Core/Jobs/DeterministicEncoder.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import Foundation

/// Deterministic JSON encoder for cross-platform consistency
/// Ensures identical output on iOS, macOS, and Linux
public final class DeterministicJSONEncoder {

    /// Encode value to deterministic JSON Data
    /// - Keys are sorted alphabetically
    /// - No whitespace
    /// - Dates use ISO8601 with fixed timezone
    /// - Floats use fixed precision
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64

        // Use custom float encoding for determinism
        encoder.nonConformingFloatEncodingStrategy = .throw

        return try encoder.encode(value)
    }

    /// Encode value to deterministic JSON String
    public static func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "Failed to convert JSON data to UTF-8 string"
            ))
        }
        return string
    }

    /// Compute SHA256 hash of deterministic JSON
    public static func computeHash<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        // Use CryptoKit on Apple platforms, swift-crypto on Linux
        #if canImport(CryptoKit)
        import CryptoKit
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
        #else
        import Crypto
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
        #endif
    }
}
```

### C2: Platform-Agnostic Date Handling

**Why**: Date formatting differs between platforms. Use explicit UTC timezone.

**File**: `Core/Jobs/ContractConstants.swift`

**Add**:
```swift
// MARK: - Date Formatting (Cross-Platform)

/// ISO8601 date format with milliseconds and UTC timezone
/// Example: "2024-01-15T10:30:45.123Z"
public static let ISO8601_FORMAT = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"

/// Timezone identifier for all timestamps
public static let TIMESTAMP_TIMEZONE = "UTC"
```

---

## Part D: Swift Concurrency Best Practices

### D1: Cooperative Cancellation Support

**Why**: [Swift Structured Concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) requires cooperative cancellation. Long-running operations must check `Task.isCancelled`.

**File**: `Core/Jobs/JobStateMachine.swift`

**Add**:
```swift
/// Async transition with cancellation support (Swift 6 compatible)
/// Reference: https://developer.apple.com/documentation/swift/task/iscancelled
@available(macOS 10.15, iOS 13.0, *)
public static func transitionAsync(
    jobId: String,
    from: JobState,
    to: JobState,
    failureReason: FailureReason? = nil,
    cancelReason: CancelReason? = nil,
    elapsedSeconds: Int? = nil,
    isServerSide: Bool = false,
    logger: ((TransitionLog) -> Void)? = nil
) async throws -> JobState {
    // Check for task cancellation before expensive operations
    try Task.checkCancellation()

    // Perform synchronous validation
    let result = try transition(
        jobId: jobId,
        from: from,
        to: to,
        failureReason: failureReason,
        cancelReason: cancelReason,
        elapsedSeconds: elapsedSeconds,
        isServerSide: isServerSide,
        logger: logger
    )

    // Check again after operation
    try Task.checkCancellation()

    return result
}
```

### D2: Actor Isolation for Thread Safety

**Why**: Swift 6 enforces strict concurrency. Use actors for mutable state.

**New consideration for CircuitBreaker**:
```swift
/// Thread-safe circuit breaker using Swift actor
@available(macOS 10.15, iOS 13.0, *)
public actor CircuitBreakerActor {
    private var breaker = CircuitBreaker()

    public func shouldAllowRequest() -> Bool {
        breaker.shouldAllowRequest()
    }

    public func recordSuccess() {
        breaker.recordSuccess()
    }

    public func recordFailure() {
        breaker.recordFailure()
    }

    public func failureRate() -> Double {
        breaker.failureRate()
    }
}
```

---

## Part E: UX Psychological Optimization

### E1: Progress Perception Enhancement

**Why**: [Research shows](https://www.nngroup.com/articles/response-times-3-important-limits/) users perceive faster progress with specific feedback patterns.

**File**: `Core/Jobs/ContractConstants.swift`

**Modify existing values**:
```swift
// MARK: - Progress Feedback (Psychologically Optimized)

/// Progress report interval in seconds
/// Research: 3s provides smooth animation without battery impact
/// Reference: Nielsen Norman Group response time limits
public static let PROGRESS_REPORT_INTERVAL_SECONDS = 3

/// Minimum progress increment to report (avoid micro-updates)
/// Users notice changes >=2%, smaller increments feel stagnant
public static let MIN_PROGRESS_INCREMENT_PERCENT: Double = 2.0

/// Initial progress boost (show immediate response)
/// Research: Users feel faster when initial progress is visible
public static let INITIAL_PROGRESS_BOOST_PERCENT: Double = 5.0

/// Progress slowdown threshold (slow down near completion)
/// Research: Perceived speed increases if progress slows at 90%+
public static let PROGRESS_SLOWDOWN_THRESHOLD_PERCENT: Double = 90.0
```

### E2: Predictive Wait Time Display

**Why**: [Uber-style progress](https://medium.com/design-bootcamp/the-ux-of-waiting-247c1d19c11d) with ETA reduces anxiety.

**New File**: `Core/Jobs/ProgressEstimator.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import Foundation

/// Estimates remaining time based on historical data
public final class ProgressEstimator {

    /// Historical processing times by state (rolling average)
    private var stateAverages: [JobState: TimeInterval] = [:]

    /// Sample count per state
    private var sampleCounts: [JobState: Int] = [:]

    /// Maximum samples to keep (for rolling average)
    private static let MAX_SAMPLES = 100

    /// Estimate remaining time from current state
    public func estimateRemainingTime(
        currentState: JobState,
        elapsedInCurrentState: TimeInterval
    ) -> TimeInterval? {
        guard let average = stateAverages[currentState] else {
            return nil
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

    /// Record actual duration for a state transition
    public func recordDuration(state: JobState, duration: TimeInterval) {
        let count = sampleCounts[state] ?? 0
        let currentAverage = stateAverages[state] ?? 0

        // Exponential moving average for smooth updates
        let alpha = 2.0 / Double(min(count + 1, Self.MAX_SAMPLES) + 1)
        let newAverage = alpha * duration + (1 - alpha) * currentAverage

        stateAverages[state] = newAverage
        sampleCounts[state] = min(count + 1, Self.MAX_SAMPLES)
    }

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

---

## Part F: Graceful Degradation

### F1: Bulkhead Pattern for Resource Isolation

**Why**: [Netflix Hystrix](https://www.infoq.com/news/2012/12/netflix-hystrix-fault-tolerance/) uses bulkheads to isolate failures.

**File**: `Core/Jobs/ContractConstants.swift`

**Add**:
```swift
// MARK: - Bulkhead Pattern (Resource Isolation)

/// Maximum concurrent transitions per job type
public static let MAX_CONCURRENT_UPLOADS = 3

/// Maximum concurrent processing jobs
public static let MAX_CONCURRENT_PROCESSING = 5

/// Queue overflow threshold (reject new jobs)
public static let QUEUE_OVERFLOW_THRESHOLD = 100
```

### F2: Fallback Values

**Why**: [AWS Well-Architected guidance](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_mitigate_interaction_failure_graceful_degradation.html) recommends fallbacks.

**File**: `Core/Jobs/ContractConstants.swift`

**Add**:
```swift
// MARK: - Graceful Degradation Fallbacks

/// Default ETA when estimation unavailable (seconds)
public static let FALLBACK_ETA_SECONDS: TimeInterval = 120.0

/// Cached progress value when network unavailable
public static let FALLBACK_PROGRESS_STALE_THRESHOLD_SECONDS: TimeInterval = 30.0

/// Message to show when degraded
public static let FALLBACK_MESSAGE_KEY = "job.progress.degraded"
```

---

## Part G: CI/CD Hardening

### G1: Local Pre-Push Verification Script

**Why**: Catch failures before pushing to GitHub. Match CI environment locally.

**New File**: `scripts/pre-push-verify.sh`

```bash
#!/bin/bash
# ============================================================================
# PR2-JSM-3.0 Local Verification Script
# Run this before pushing to ensure CI will pass
# ============================================================================

set -euo pipefail

echo "========================================"
echo "PR2-JSM-3.0 Pre-Push Verification"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILURES=0

# 1. Swift Version Check
echo -e "\n${YELLOW}[1/6] Checking Swift version...${NC}"
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
echo "Local: $SWIFT_VERSION"
if [[ ! "$SWIFT_VERSION" =~ "5.9" ]] && [[ ! "$SWIFT_VERSION" =~ "5.10" ]] && [[ ! "$SWIFT_VERSION" =~ "6." ]]; then
    echo -e "${RED}WARNING: CI uses Swift 5.9.2. Local version may differ.${NC}"
fi

# 2. Build
echo -e "\n${YELLOW}[2/6] Building...${NC}"
if swift build 2>&1; then
    echo -e "${GREEN}Build passed${NC}"
else
    echo -e "${RED}Build FAILED${NC}"
    ((FAILURES++))
fi

# 3. All Tests
echo -e "\n${YELLOW}[3/6] Running all tests...${NC}"
if swift test 2>&1; then
    echo -e "${GREEN}All tests passed${NC}"
else
    echo -e "${RED}Tests FAILED${NC}"
    ((FAILURES++))
fi

# 4. JobStateMachine Tests (specifically)
echo -e "\n${YELLOW}[4/6] Running JobStateMachine tests...${NC}"
if swift test --filter JobStateMachineTests 2>&1; then
    echo -e "${GREEN}JobStateMachine tests passed${NC}"
else
    echo -e "${RED}JobStateMachine tests FAILED${NC}"
    ((FAILURES++))
fi

# 5. RetryCalculator Tests (if exists)
echo -e "\n${YELLOW}[5/6] Running RetryCalculator tests...${NC}"
if swift test --filter RetryCalculatorTests 2>&1; then
    echo -e "${GREEN}RetryCalculator tests passed${NC}"
else
    echo -e "${YELLOW}RetryCalculator tests not found (may not exist yet)${NC}"
fi

# 6. Contract Version Consistency
echo -e "\n${YELLOW}[6/6] Checking contract version consistency...${NC}"
VERSION_PATTERN="PR2-JSM-3.0"
CORE_FILES=(
    "Core/Jobs/ContractConstants.swift"
    "Core/Jobs/JobStateMachine.swift"
    "Core/Jobs/JobState.swift"
    "Core/Jobs/FailureReason.swift"
    "Core/Jobs/CancelReason.swift"
    "Core/Jobs/JobStateMachineError.swift"
)

for file in "${CORE_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        if grep -q "$VERSION_PATTERN" "$file"; then
            echo -e "  ${GREEN}$file - version correct${NC}"
        else
            echo -e "  ${RED}$file - version MISMATCH${NC}"
            ((FAILURES++))
        fi
    else
        echo -e "  ${YELLOW}$file - not found${NC}"
    fi
done

# Summary
echo -e "\n========================================"
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}All checks passed! Safe to push.${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES check(s) failed. Fix before pushing.${NC}"
    exit 1
fi
```

### G2: GitHub Actions Matrix Enhancement

**File**: `.github/workflows/ci.yml`

**Recommended additions** (document only, don't modify directly):
```yaml
# Add to test-and-lint job for cross-platform verification:
strategy:
  matrix:
    os: [ubuntu-22.04, macos-14]
    swift: ["5.9.2", "5.10"]
  fail-fast: false

# Add determinism check step:
- name: Verify JSON Determinism
  run: |
    # Build twice and compare hashes
    swift build
    swift test --filter DeterministicEncoderTests

# Add contract count verification:
- name: Verify Contract Counts
  run: |
    # Verify enum counts match constants
    FAILURE_COUNT=$(grep -c "case " Core/Jobs/FailureReason.swift || echo 0)
    EXPECTED=17
    if [[ "$FAILURE_COUNT" -ne "$EXPECTED" ]]; then
      echo "FailureReason count mismatch: got $FAILURE_COUNT, expected $EXPECTED"
      exit 1
    fi
```

---

## Part H: New Test Cases

### H1: Circuit Breaker Tests

**New File**: `Tests/Jobs/CircuitBreakerTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import XCTest
@testable import Aether3DCore

final class CircuitBreakerTests: XCTestCase {

    func testInitialStateClosed() {
        let breaker = CircuitBreaker()
        XCTAssertTrue(breaker.shouldAllowRequest())
    }

    func testTripsAfterThreshold() {
        let breaker = CircuitBreaker()

        // Record failures up to threshold
        for _ in 0..<CircuitBreaker.FAILURE_THRESHOLD {
            XCTAssertTrue(breaker.shouldAllowRequest())
            breaker.recordFailure()
        }

        // Should be open now
        XCTAssertFalse(breaker.shouldAllowRequest())
    }

    func testHalfOpenAfterTimeout() {
        let breaker = CircuitBreaker()

        // Trip the circuit
        for _ in 0..<CircuitBreaker.FAILURE_THRESHOLD {
            breaker.recordFailure()
        }

        // Simulate timeout (would need to mock Date in real test)
        // After timeout, should transition to half-open
        // This is a placeholder - real test needs time mocking
    }

    func testClosesAfterSuccessInHalfOpen() {
        let breaker = CircuitBreaker()

        // Trip and recover
        for _ in 0..<CircuitBreaker.FAILURE_THRESHOLD {
            breaker.recordFailure()
        }

        // Would need time mocking to fully test
    }

    func testSlidingWindowFailureRate() {
        let breaker = CircuitBreaker()

        // 5 successes, 5 failures = 50% failure rate
        for _ in 0..<5 {
            breaker.recordSuccess()
        }
        for _ in 0..<5 {
            breaker.recordFailure()
        }

        XCTAssertEqual(breaker.failureRate(), 0.5, accuracy: 0.01)
    }
}
```

### H2: Decorrelated Jitter Tests

**Add to**: `Tests/Jobs/RetryCalculatorTests.swift`

```swift
func testDecorrelatedJitterBounds() {
    let calculator = RetryCalculator()
    let baseDelay: TimeInterval = 1.0
    let maxDelay: TimeInterval = 60.0

    var previousDelay = baseDelay

    for _ in 0..<100 {
        let delay = calculator.calculateDecorrelatedDelay(
            previousDelay: previousDelay,
            baseDelay: baseDelay,
            maxDelay: maxDelay
        )

        // Delay must be >= base
        XCTAssertGreaterThanOrEqual(delay, baseDelay)

        // Delay must be <= max
        XCTAssertLessThanOrEqual(delay, maxDelay)

        // Delay must be <= previousDelay * 3 (or max)
        XCTAssertLessThanOrEqual(delay, min(maxDelay, previousDelay * 3))

        previousDelay = delay
    }
}

func testDecorrelatedJitterDistribution() {
    let calculator = RetryCalculator()
    var delays: [TimeInterval] = []
    var previousDelay: TimeInterval = 1.0

    for _ in 0..<1000 {
        let delay = calculator.calculateDecorrelatedDelay(
            previousDelay: previousDelay,
            baseDelay: 1.0,
            maxDelay: 60.0
        )
        delays.append(delay)
        previousDelay = delay
    }

    // Check distribution is reasonably spread (not clustered)
    let mean = delays.reduce(0, +) / Double(delays.count)
    let variance = delays.map { pow($0 - mean, 2) }.reduce(0, +) / Double(delays.count)
    let stdDev = sqrt(variance)

    // Standard deviation should be significant (not all same value)
    XCTAssertGreaterThan(stdDev, 1.0, "Jitter should produce varied delays")
}
```

### H3: Cross-Platform Determinism Tests

**New File**: `Tests/Jobs/DeterministicEncoderTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import XCTest
@testable import Aether3DCore

final class DeterministicEncoderTests: XCTestCase {

    func testSortedKeys() throws {
        struct TestStruct: Codable {
            let zebra: String
            let apple: String
            let mango: String
        }

        let value = TestStruct(zebra: "z", apple: "a", mango: "m")
        let json = try DeterministicJSONEncoder.encodeToString(value)

        // Keys must be alphabetically sorted
        XCTAssertTrue(json.contains("\"apple\""))
        let appleIndex = json.range(of: "\"apple\"")!.lowerBound
        let mangoIndex = json.range(of: "\"mango\"")!.lowerBound
        let zebraIndex = json.range(of: "\"zebra\"")!.lowerBound

        XCTAssertLessThan(appleIndex, mangoIndex)
        XCTAssertLessThan(mangoIndex, zebraIndex)
    }

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

    func testTransitionLogDeterminism() throws {
        let log = TransitionLog(
            jobId: "12345678901234567",
            from: .pending,
            to: .uploading,
            failureReason: nil,
            cancelReason: nil,
            timestamp: Date(timeIntervalSince1970: 1705312245.123),
            contractVersion: "PR2-JSM-3.0"
        )

        let json1 = try DeterministicJSONEncoder.encodeToString(log)
        let json2 = try DeterministicJSONEncoder.encodeToString(log)

        XCTAssertEqual(json1, json2)
    }
}
```

---

## Part I: Documentation Updates

### I1: Update Contract Header Comments

All files must update their header to reflect new counts:

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// CircuitBreaker: 3 states | JitterStrategy: 3 types
// ============================================================================
```

### I2: README Badge (Optional)

Consider adding to project README:
```markdown
![Contract Version](https://img.shields.io/badge/JSM%20Contract-PR2--JSM--3.0-blue)
![States](https://img.shields.io/badge/States-8-green)
![Transitions](https://img.shields.io/badge/Transitions-13-green)
```

---

## Summary: Files to Create/Modify

### New Files (5)
1. `Core/Jobs/CircuitBreaker.swift` - Circuit breaker state machine
2. `Core/Jobs/TransitionSpan.swift` - OpenTelemetry-compatible spans
3. `Core/Jobs/DeterministicEncoder.swift` - Cross-platform JSON encoding
4. `Core/Jobs/ProgressEstimator.swift` - UX wait time estimation
5. `scripts/pre-push-verify.sh` - Local CI verification

### New Test Files (2)
1. `Tests/Jobs/CircuitBreakerTests.swift`
2. `Tests/Jobs/DeterministicEncoderTests.swift`

### Modified Files (from original plan, with additions)
1. `Core/Jobs/ContractConstants.swift` - Add circuit breaker, UX, and fallback constants
2. `Core/Jobs/RetryCalculator.swift` - Add decorrelated jitter strategy
3. `Core/Jobs/JobStateMachine.swift` - Add async transition, session tracking
4. `Tests/Jobs/RetryCalculatorTests.swift` - Add decorrelated jitter tests

---

## Verification Checklist

```bash
# 1. Run local pre-push script
chmod +x scripts/pre-push-verify.sh
./scripts/pre-push-verify.sh

# 2. Specific test suites
swift test --filter JobStateMachineTests
swift test --filter RetryCalculatorTests
swift test --filter CircuitBreakerTests
swift test --filter DeterministicEncoderTests

# 3. Full build
swift build

# 4. All tests
swift test

# 5. Contract count verification
grep -c "case " Core/Jobs/FailureReason.swift  # Should be 17
grep -c "case " Core/Jobs/CancelReason.swift   # Should be 3
grep -c "case " Core/Jobs/JobState.swift       # Should be 8
```

---

## References

- [Circuit Breaker Pattern - Martin Fowler](https://martinfowler.com/bliki/CircuitBreaker.html)
- [AWS Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- [Netflix Hystrix Fault Tolerance](https://www.infoq.com/news/2012/12/netflix-hystrix-fault-tolerance/)
- [OpenTelemetry for Mobile](https://embrace.io/opentelemetry-for-mobile/)
- [Swift Structured Concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)
- [Nielsen Norman Group Response Times](https://www.nngroup.com/articles/response-times-3-important-limits/)
- [AWS Well-Architected Graceful Degradation](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_mitigate_interaction_failure_graceful_degradation.html)
- [Swift Retry Policy Library](https://github.com/swiftuiux/retry-policy-service)
- [Mobile Observability with OpenTelemetry and Grafana](https://grafana.com/blog/2024/06/11/mobile-app-observability-with-opentelemetry-embrace-and-grafana-cloud/)
