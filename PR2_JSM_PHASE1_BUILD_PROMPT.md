# PR2-JSM-3.0 Phase 1 Build Prompt

## Mission

Upgrade the Job State Machine from PR2-JSM-2.5 to PR2-JSM-3.0 (Phase 1). This phase includes core functionality (Part 1-9) plus critical enhancements (Part A, C, G). After completing all changes, run self-verification and generate a detailed inspection report.

---

## Phase 1 Scope

### Core Functionality (Part 1-9)
- Contract version upgrade
- Exponential backoff retry with jitter
- Dead Letter Queue (DLQ) support
- Idempotent transition protection
- Heartbeat timeout monitoring
- Enhanced cancel reasons
- UX micro-optimizations
- New error types
- Test updates

### Critical Enhancements (Part A, C, G only)
- **Part A**: Circuit Breaker + Decorrelated Jitter
- **Part C**: Deterministic JSON Encoder (cross-platform)
- **Part G**: Local pre-push verification script

### Deferred to Phase 2
- Part B: OpenTelemetry Span Tracking
- Part D: Swift Async Concurrency
- Part E: UX Progress Estimator
- Part F: Bulkhead Pattern Constants
- Part H: Additional test files (CircuitBreakerTests, DeterministicEncoderTests)
- Part I: Documentation badges

---

## Files to Create (6 files)

### 1. `Core/Jobs/RetryCalculator.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Jitter strategy enumeration
public enum JitterStrategy: String, Codable, CaseIterable {
    case full           // random(0, min(cap, base * 2^attempt))
    case equal          // temp/2 + random(0, temp/2)
    case decorrelated   // min(cap, random(base, previousDelay * 3)) - RECOMMENDED
}

/// Retry calculator with exponential backoff and jitter
/// Reference: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
public final class RetryCalculator {

    // MARK: - Properties

    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let maxRetries: Int
    private let jitterStrategy: JitterStrategy
    private let decorrelatedMultiplier: Double

    /// Previous delay for decorrelated jitter (stateful)
    private var previousDelay: TimeInterval

    // MARK: - Initialization

    public init(
        baseDelay: TimeInterval = TimeInterval(ContractConstants.RETRY_BASE_INTERVAL_SECONDS),
        maxDelay: TimeInterval = TimeInterval(ContractConstants.RETRY_MAX_DELAY_SECONDS),
        maxRetries: Int = ContractConstants.MAX_AUTO_RETRY_COUNT,
        jitterStrategy: JitterStrategy = .decorrelated,
        decorrelatedMultiplier: Double = ContractConstants.RETRY_DECORRELATED_MULTIPLIER
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
        self.jitterStrategy = jitterStrategy
        self.decorrelatedMultiplier = decorrelatedMultiplier
        self.previousDelay = baseDelay
    }

    // MARK: - Public Methods

    /// Calculate delay for a given retry attempt
    /// - Parameter attempt: Retry attempt number (0-based)
    /// - Returns: Delay in seconds
    public func calculateDelay(attempt: Int) -> TimeInterval {
        switch jitterStrategy {
        case .full:
            return calculateFullJitterDelay(attempt: attempt)
        case .equal:
            return calculateEqualJitterDelay(attempt: attempt)
        case .decorrelated:
            return calculateDecorrelatedDelay()
        }
    }

    /// Check if retry should be attempted
    /// - Parameters:
    ///   - attempt: Current attempt number (0-based)
    ///   - failureReason: The failure reason
    /// - Returns: True if retry should be attempted
    public func shouldRetry(attempt: Int, failureReason: FailureReason) -> Bool {
        guard attempt < maxRetries else { return false }
        return failureReason.isRetryable
    }

    /// Preview all retry delays for display/debugging
    /// - Returns: Array of delays for each retry attempt
    public func previewDelays() -> [TimeInterval] {
        let calculator = RetryCalculator(
            baseDelay: baseDelay,
            maxDelay: maxDelay,
            maxRetries: maxRetries,
            jitterStrategy: jitterStrategy,
            decorrelatedMultiplier: decorrelatedMultiplier
        )
        return (0..<maxRetries).map { calculator.calculateDelay(attempt: $0) }
    }

    /// Reset state (for decorrelated jitter)
    public func reset() {
        previousDelay = baseDelay
    }

    // MARK: - Private Methods

    /// Full jitter: random(0, min(cap, base * 2^attempt))
    private func calculateFullJitterDelay(attempt: Int) -> TimeInterval {
        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(maxDelay, exponentialDelay)
        return Double.random(in: 0...cappedDelay)
    }

    /// Equal jitter: temp/2 + random(0, temp/2)
    private func calculateEqualJitterDelay(attempt: Int) -> TimeInterval {
        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(maxDelay, exponentialDelay)
        let halfDelay = cappedDelay / 2.0
        return halfDelay + Double.random(in: 0...halfDelay)
    }

    /// Decorrelated jitter: min(cap, random(base, previousDelay * 3))
    /// Netflix/AWS recommended strategy
    private func calculateDecorrelatedDelay() -> TimeInterval {
        let maxRange = min(maxDelay, previousDelay * decorrelatedMultiplier)
        let delay = Double.random(in: baseDelay...max(baseDelay, maxRange))
        previousDelay = delay
        return delay
    }
}
```

### 2. `Core/Jobs/DLQEntry.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Dead Letter Queue entry for failed jobs
public struct DLQEntry: Codable, Equatable {
    /// Unique DLQ entry ID
    public let dlqId: String

    /// Original job ID
    public let jobId: String

    /// Final failure reason
    public let failureReason: FailureReason

    /// Number of retry attempts made
    public let retryCount: Int

    /// Last state before entering DLQ
    public let lastState: JobState

    /// Timestamp when job entered DLQ
    public let enteredAt: Date

    /// Original job creation timestamp
    public let originalCreatedAt: Date

    /// Contract version at time of DLQ entry
    public let contractVersion: String

    /// Additional metadata
    public let metadata: [String: String]?

    public init(
        jobId: String,
        failureReason: FailureReason,
        retryCount: Int,
        lastState: JobState,
        enteredAt: Date = Date(),
        originalCreatedAt: Date,
        contractVersion: String = ContractConstants.CONTRACT_VERSION,
        metadata: [String: String]? = nil
    ) {
        self.dlqId = "\(ContractConstants.DLQ_ID_PREFIX)\(UUID().uuidString)"
        self.jobId = jobId
        self.failureReason = failureReason
        self.retryCount = retryCount
        self.lastState = lastState
        self.enteredAt = enteredAt
        self.originalCreatedAt = originalCreatedAt
        self.contractVersion = contractVersion
        self.metadata = metadata
    }
}

/// DLQ statistics
public struct DLQStats: Codable, Equatable {
    /// Total entries in DLQ
    public let totalCount: Int

    /// Entries by failure reason
    public let countByReason: [String: Int]

    /// Entries in last 24 hours
    public let last24HoursCount: Int

    /// Oldest entry timestamp
    public let oldestEntryAt: Date?

    /// Whether alert threshold is exceeded
    public var isAlertThresholdExceeded: Bool {
        totalCount >= ContractConstants.DLQ_ALERT_THRESHOLD
    }

    public init(
        totalCount: Int,
        countByReason: [String: Int],
        last24HoursCount: Int,
        oldestEntryAt: Date?
    ) {
        self.totalCount = totalCount
        self.countByReason = countByReason
        self.last24HoursCount = last24HoursCount
        self.oldestEntryAt = oldestEntryAt
    }
}
```

### 3. `Core/Jobs/CircuitBreaker.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Circuit breaker state (3 states)
public enum CircuitState: String, Codable, CaseIterable {
    case closed     // Normal operation, requests pass through
    case open       // Failures exceeded threshold, requests fail fast
    case halfOpen   // Testing if service recovered
}

/// Circuit breaker for preventing cascading failures
/// Reference: https://martinfowler.com/bliki/CircuitBreaker.html
public final class CircuitBreaker {

    // MARK: - Properties

    private(set) public var state: CircuitState = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private var lastFailureTime: Date?
    private var recentResults: [Bool] = []

    private let failureThreshold: Int
    private let successThreshold: Int
    private let openTimeout: TimeInterval
    private let slidingWindowSize: Int

    // MARK: - Initialization

    public init(
        failureThreshold: Int = ContractConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD,
        successThreshold: Int = ContractConstants.CIRCUIT_BREAKER_SUCCESS_THRESHOLD,
        openTimeout: TimeInterval = ContractConstants.CIRCUIT_BREAKER_OPEN_TIMEOUT_SECONDS,
        slidingWindowSize: Int = ContractConstants.CIRCUIT_BREAKER_SLIDING_WINDOW_SIZE
    ) {
        self.failureThreshold = failureThreshold
        self.successThreshold = successThreshold
        self.openTimeout = openTimeout
        self.slidingWindowSize = slidingWindowSize
    }

    // MARK: - Public Methods

    /// Check if request should be allowed
    public func shouldAllowRequest() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= openTimeout {
                state = .halfOpen
                successCount = 0
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    /// Record a successful operation
    public func recordSuccess() {
        appendResult(true)

        switch state {
        case .closed:
            failureCount = 0
        case .halfOpen:
            successCount += 1
            if successCount >= successThreshold {
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
        appendResult(false)
        lastFailureTime = Date()

        switch state {
        case .closed:
            failureCount += 1
            if failureCount >= failureThreshold {
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

    /// Reset circuit breaker to initial state
    public func reset() {
        state = .closed
        failureCount = 0
        successCount = 0
        lastFailureTime = nil
        recentResults.removeAll()
    }

    // MARK: - Private Methods

    private func appendResult(_ success: Bool) {
        recentResults.append(success)
        while recentResults.count > slidingWindowSize {
            recentResults.removeFirst()
        }
    }
}
```

### 4. `Core/Jobs/DeterministicEncoder.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Deterministic JSON encoder for cross-platform consistency
/// Ensures identical output on iOS, macOS, and Linux
public final class DeterministicJSONEncoder {

    /// Shared encoder instance with deterministic settings
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return encoder
    }()

    /// Shared decoder instance
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    // MARK: - Public Methods

    /// Encode value to deterministic JSON Data
    /// - Keys are sorted alphabetically
    /// - No whitespace
    /// - Dates use ISO8601
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
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

    /// Decode JSON Data to value
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try decoder.decode(type, from: data)
    }

    /// Compute SHA256 hash of deterministic JSON
    public static func computeHash<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Verify hash matches expected value
    public static func verifyHash<T: Encodable>(_ value: T, expectedHash: String) throws -> Bool {
        let actualHash = try computeHash(value)
        return actualHash == expectedHash
    }
}
```

### 5. `scripts/pre-push-verify.sh`

```bash
#!/bin/bash
# ============================================================================
# PR2-JSM-3.0 Local Pre-Push Verification Script
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
BLUE='\033[0;34m'
NC='\033[0m' # No Color

FAILURES=0
WARNINGS=0

# Helper functions
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAILURES++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARNINGS++)); }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# 1. Swift Version Check
echo -e "\n${YELLOW}[1/7] Checking Swift version...${NC}"
SWIFT_VERSION=$(swift --version 2>&1 | head -1)
info "Local: $SWIFT_VERSION"
if [[ "$SWIFT_VERSION" =~ "5.9" ]] || [[ "$SWIFT_VERSION" =~ "5.10" ]] || [[ "$SWIFT_VERSION" =~ "6." ]]; then
    pass "Swift version compatible"
else
    warn "CI uses Swift 5.9.2. Local version may differ."
fi

# 2. Build
echo -e "\n${YELLOW}[2/7] Building project...${NC}"
if swift build 2>&1; then
    pass "Build succeeded"
else
    fail "Build FAILED"
fi

# 3. All Tests
echo -e "\n${YELLOW}[3/7] Running all tests...${NC}"
if swift test 2>&1; then
    pass "All tests passed"
else
    fail "Tests FAILED"
fi

# 4. JobStateMachine Tests
echo -e "\n${YELLOW}[4/7] Running JobStateMachine tests...${NC}"
if swift test --filter JobStateMachineTests 2>&1; then
    pass "JobStateMachine tests passed"
else
    fail "JobStateMachine tests FAILED"
fi

# 5. RetryCalculator Tests
echo -e "\n${YELLOW}[5/7] Running RetryCalculator tests...${NC}"
if swift test --filter RetryCalculatorTests 2>&1; then
    pass "RetryCalculator tests passed"
else
    warn "RetryCalculator tests not found or failed"
fi

# 6. Contract Version Consistency
echo -e "\n${YELLOW}[6/7] Checking contract version consistency...${NC}"
VERSION_PATTERN="PR2-JSM-3.0"
CORE_FILES=(
    "Core/Jobs/ContractConstants.swift"
    "Core/Jobs/JobStateMachine.swift"
    "Core/Jobs/JobState.swift"
    "Core/Jobs/FailureReason.swift"
    "Core/Jobs/CancelReason.swift"
    "Core/Jobs/JobStateMachineError.swift"
)

VERSION_MISMATCH=0
for file in "${CORE_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        if grep -q "$VERSION_PATTERN" "$file"; then
            pass "$file - version correct"
        else
            fail "$file - version MISMATCH (expected $VERSION_PATTERN)"
            ((VERSION_MISMATCH++))
        fi
    else
        warn "$file - not found"
    fi
done

# 7. Enum Count Verification
echo -e "\n${YELLOW}[7/7] Verifying enum counts...${NC}"

# Count FailureReason cases
if [[ -f "Core/Jobs/FailureReason.swift" ]]; then
    FAILURE_COUNT=$(grep -c "case [a-zA-Z]" Core/Jobs/FailureReason.swift 2>/dev/null || echo "0")
    if [[ "$FAILURE_COUNT" -eq 17 ]]; then
        pass "FailureReason count: $FAILURE_COUNT (expected 17)"
    else
        fail "FailureReason count: $FAILURE_COUNT (expected 17)"
    fi
fi

# Count CancelReason cases
if [[ -f "Core/Jobs/CancelReason.swift" ]]; then
    CANCEL_COUNT=$(grep -c "case [a-zA-Z]" Core/Jobs/CancelReason.swift 2>/dev/null || echo "0")
    if [[ "$CANCEL_COUNT" -eq 3 ]]; then
        pass "CancelReason count: $CANCEL_COUNT (expected 3)"
    else
        fail "CancelReason count: $CANCEL_COUNT (expected 3)"
    fi
fi

# Count JobState cases
if [[ -f "Core/Jobs/JobState.swift" ]]; then
    STATE_COUNT=$(grep -c "case [a-zA-Z]" Core/Jobs/JobState.swift 2>/dev/null || echo "0")
    if [[ "$STATE_COUNT" -eq 8 ]]; then
        pass "JobState count: $STATE_COUNT (expected 8)"
    else
        fail "JobState count: $STATE_COUNT (expected 8)"
    fi
fi

# Summary
echo -e "\n========================================"
echo "VERIFICATION SUMMARY"
echo "========================================"
echo -e "Failures: ${RED}$FAILURES${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"

if [[ $FAILURES -eq 0 ]]; then
    echo -e "\n${GREEN}All checks passed! Safe to push.${NC}"
    exit 0
else
    echo -e "\n${RED}$FAILURES check(s) failed. Fix before pushing.${NC}"
    exit 1
fi
```

### 6. `Tests/Jobs/RetryCalculatorTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class RetryCalculatorTests: XCTestCase {

    // MARK: - Basic Calculation Tests

    func testCalculateDelayFullJitter() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 60.0,
            maxRetries: 5,
            jitterStrategy: .full
        )

        for attempt in 0..<5 {
            let delay = calculator.calculateDelay(attempt: attempt)
            let maxExpected = min(60.0, 1.0 * pow(2.0, Double(attempt)))

            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, maxExpected)
        }
    }

    func testCalculateDelayEqualJitter() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 60.0,
            maxRetries: 5,
            jitterStrategy: .equal
        )

        for attempt in 0..<5 {
            let delay = calculator.calculateDelay(attempt: attempt)
            let exponentialDelay = min(60.0, 1.0 * pow(2.0, Double(attempt)))
            let halfDelay = exponentialDelay / 2.0

            XCTAssertGreaterThanOrEqual(delay, halfDelay)
            XCTAssertLessThanOrEqual(delay, exponentialDelay)
        }
    }

    func testCalculateDelayDecorrelatedJitter() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 60.0,
            maxRetries: 5,
            jitterStrategy: .decorrelated,
            decorrelatedMultiplier: 3.0
        )

        var previousDelay = 1.0
        for _ in 0..<100 {
            let delay = calculator.calculateDelay(attempt: 0)

            // Delay must be >= base
            XCTAssertGreaterThanOrEqual(delay, 1.0)

            // Delay must be <= max
            XCTAssertLessThanOrEqual(delay, 60.0)

            previousDelay = delay
        }
    }

    // MARK: - Max Delay Cap Tests

    func testMaxDelayCap() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 10.0,
            maxRetries: 10,
            jitterStrategy: .full
        )

        for attempt in 0..<10 {
            let delay = calculator.calculateDelay(attempt: attempt)
            XCTAssertLessThanOrEqual(delay, 10.0, "Delay should never exceed maxDelay")
        }
    }

    // MARK: - Should Retry Tests

    func testShouldRetryWithRetryableReason() {
        let calculator = RetryCalculator(maxRetries: 5)

        // Retryable reasons should allow retry
        XCTAssertTrue(calculator.shouldRetry(attempt: 0, failureReason: .networkError))
        XCTAssertTrue(calculator.shouldRetry(attempt: 4, failureReason: .networkError))

        // Should not retry after max attempts
        XCTAssertFalse(calculator.shouldRetry(attempt: 5, failureReason: .networkError))
    }

    func testShouldRetryWithNonRetryableReason() {
        let calculator = RetryCalculator(maxRetries: 5)

        // Non-retryable reasons should not allow retry
        XCTAssertFalse(calculator.shouldRetry(attempt: 0, failureReason: .invalidVideoFormat))
        XCTAssertFalse(calculator.shouldRetry(attempt: 0, failureReason: .videoTooShort))
    }

    // MARK: - Preview Delays Tests

    func testPreviewDelays() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 60.0,
            maxRetries: 5,
            jitterStrategy: .full
        )

        let delays = calculator.previewDelays()

        XCTAssertEqual(delays.count, 5)
        for delay in delays {
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, 60.0)
        }
    }

    // MARK: - Reset Tests

    func testReset() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 60.0,
            maxRetries: 5,
            jitterStrategy: .decorrelated
        )

        // Generate some delays to change internal state
        for _ in 0..<10 {
            _ = calculator.calculateDelay(attempt: 0)
        }

        // Reset should work without error
        calculator.reset()

        // After reset, delays should still be valid
        let delay = calculator.calculateDelay(attempt: 0)
        XCTAssertGreaterThanOrEqual(delay, 1.0)
    }

    // MARK: - Decorrelated Jitter Distribution Tests

    func testDecorrelatedJitterDistribution() {
        let calculator = RetryCalculator(
            baseDelay: 1.0,
            maxDelay: 60.0,
            maxRetries: 5,
            jitterStrategy: .decorrelated
        )

        var delays: [TimeInterval] = []
        for _ in 0..<1000 {
            delays.append(calculator.calculateDelay(attempt: 0))
        }

        // Calculate standard deviation
        let mean = delays.reduce(0, +) / Double(delays.count)
        let variance = delays.map { pow($0 - mean, 2) }.reduce(0, +) / Double(delays.count)
        let stdDev = sqrt(variance)

        // Standard deviation should be significant (not all same value)
        XCTAssertGreaterThan(stdDev, 0.5, "Decorrelated jitter should produce varied delays")
    }

    // MARK: - Default Values Tests

    func testDefaultValues() {
        let calculator = RetryCalculator()

        // Should use ContractConstants defaults
        let delay = calculator.calculateDelay(attempt: 0)
        XCTAssertGreaterThanOrEqual(delay, 0)
        XCTAssertLessThanOrEqual(delay, TimeInterval(ContractConstants.RETRY_MAX_DELAY_SECONDS))
    }
}
```

---

## Files to Modify (7 files)

### 1. `Core/Jobs/ContractConstants.swift`

**Replace entire file with:**

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Contract constants for PR#2 Job State Machine (SSOT).
public enum ContractConstants {
    // MARK: - Version

    /// Contract version identifier
    public static let CONTRACT_VERSION = "PR2-JSM-3.0"

    // MARK: - Counts (MUST match actual enum counts)

    /// Total number of job states
    public static let STATE_COUNT = 8

    /// Number of legal state transitions
    public static let LEGAL_TRANSITION_COUNT = 13

    /// Number of illegal state transitions (8 × 8 - 13 = 51)
    public static let ILLEGAL_TRANSITION_COUNT = 51

    /// Total number of possible state pairs (8 × 8 = 64)
    public static let TOTAL_STATE_PAIRS = 64

    /// Total number of failure reasons
    public static let FAILURE_REASON_COUNT = 17

    /// Total number of cancel reasons
    public static let CANCEL_REASON_COUNT = 3

    // MARK: - JobId Validation

    /// Minimum job ID length (sonyflake IDs are 15-20 digits)
    public static let JOB_ID_MIN_LENGTH = 15

    /// Maximum job ID length
    public static let JOB_ID_MAX_LENGTH = 20

    // MARK: - Cancel Window

    /// Cancel window duration in seconds (PROCESSING state only)
    public static let CANCEL_WINDOW_SECONDS = 30

    // MARK: - Progress Report

    /// Progress report interval in seconds (optimized for smooth UX)
    public static let PROGRESS_REPORT_INTERVAL_SECONDS = 3

    /// Health check interval in seconds
    public static let HEALTH_CHECK_INTERVAL_SECONDS = 10

    // MARK: - Upload

    /// Upload chunk size in bytes (5MB)
    public static let CHUNK_SIZE_BYTES = 5 * 1024 * 1024

    /// Maximum video duration in seconds (15 minutes)
    public static let MAX_VIDEO_DURATION_SECONDS = 15 * 60

    /// Minimum video duration in seconds (optimized for quick scan)
    public static let MIN_VIDEO_DURATION_SECONDS = 5

    // MARK: - Retry (Exponential Backoff)

    /// Maximum automatic retry count
    public static let MAX_AUTO_RETRY_COUNT = 5

    /// Base retry interval in seconds
    public static let RETRY_BASE_INTERVAL_SECONDS = 2

    /// Maximum retry delay in seconds (cap)
    public static let RETRY_MAX_DELAY_SECONDS = 60

    /// Jitter max in milliseconds
    public static let RETRY_JITTER_MAX_MS = 1000

    /// Jitter strategy (decorrelated recommended)
    public static let RETRY_JITTER_STRATEGY = "decorrelated"

    /// Decorrelated jitter multiplier
    public static let RETRY_DECORRELATED_MULTIPLIER: Double = 3.0

    // MARK: - Queued Timeout

    /// Queued timeout duration in seconds (1 hour)
    public static let QUEUED_TIMEOUT_SECONDS = 3600

    /// Queued warning threshold in seconds (15 minutes - earlier notification)
    public static let QUEUED_WARNING_SECONDS = 900

    // MARK: - Heartbeat Monitoring

    /// Heartbeat interval in seconds
    public static let PROCESSING_HEARTBEAT_INTERVAL_SECONDS = 30

    /// Maximum missed heartbeats before timeout
    public static let PROCESSING_HEARTBEAT_MAX_MISSED = 3

    /// Heartbeat timeout in seconds (calculated: interval * max_missed)
    public static let PROCESSING_HEARTBEAT_TIMEOUT_SECONDS = 90

    // MARK: - Dead Letter Queue (DLQ)

    /// DLQ retention period in days
    public static let DLQ_RETENTION_DAYS = 7

    /// DLQ alert threshold (trigger alert when exceeded)
    public static let DLQ_ALERT_THRESHOLD = 100

    /// DLQ ID prefix
    public static let DLQ_ID_PREFIX = "dlq_"

    // MARK: - Circuit Breaker

    /// Failure threshold to trip circuit
    public static let CIRCUIT_BREAKER_FAILURE_THRESHOLD = 5

    /// Success threshold in half-open state
    public static let CIRCUIT_BREAKER_SUCCESS_THRESHOLD = 3

    /// Open state timeout in seconds
    public static let CIRCUIT_BREAKER_OPEN_TIMEOUT_SECONDS: Double = 30.0

    /// Sliding window size for failure rate
    public static let CIRCUIT_BREAKER_SLIDING_WINDOW_SIZE = 10

    // MARK: - Date Formatting (Cross-Platform)

    /// ISO8601 date format
    public static let ISO8601_FORMAT = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"

    /// Timezone for all timestamps
    public static let TIMESTAMP_TIMEZONE = "UTC"
}
```

### 2. `Core/Jobs/JobState.swift`

**Update header only (lines 1-5):**

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================
```

### 3. `Core/Jobs/FailureReason.swift`

**Replace entire file with:**

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Failure reason enumeration (17 reasons).
public enum FailureReason: String, Codable, CaseIterable {
    // Original 14 reasons
    case networkError = "network_error"
    case uploadInterrupted = "upload_interrupted"
    case serverUnavailable = "server_unavailable"
    case invalidVideoFormat = "invalid_video_format"
    case videoTooShort = "video_too_short"
    case videoTooLong = "video_too_long"
    case insufficientFrames = "insufficient_frames"
    case poseEstimationFailed = "pose_estimation_failed"
    case lowRegistrationRate = "low_registration_rate"
    case trainingFailed = "training_failed"
    case gpuOutOfMemory = "gpu_out_of_memory"
    case processingTimeout = "processing_timeout"
    case packagingFailed = "packaging_failed"
    case internalError = "internal_error"

    // New 3 reasons (PR2-JSM-3.0)
    case heartbeatTimeout = "heartbeat_timeout"
    case stalledProcessing = "stalled_processing"
    case resourceExhausted = "resource_exhausted"

    /// Whether this failure reason is retryable.
    public var isRetryable: Bool {
        switch self {
        case .networkError, .uploadInterrupted, .serverUnavailable,
             .trainingFailed, .gpuOutOfMemory, .processingTimeout,
             .packagingFailed, .internalError,
             .heartbeatTimeout, .stalledProcessing:  // New retryable reasons
            return true
        case .invalidVideoFormat, .videoTooShort, .videoTooLong,
             .insufficientFrames, .poseEstimationFailed, .lowRegistrationRate,
             .resourceExhausted:  // resourceExhausted is NOT retryable
            return false
        }
    }

    /// Whether this failure reason is server-side only.
    public var isServerOnly: Bool {
        switch self {
        case .networkError, .uploadInterrupted:
            return false
        case .serverUnavailable, .invalidVideoFormat, .videoTooShort,
             .videoTooLong, .insufficientFrames, .poseEstimationFailed,
             .lowRegistrationRate, .trainingFailed, .gpuOutOfMemory,
             .processingTimeout, .packagingFailed, .internalError,
             .heartbeatTimeout, .stalledProcessing, .resourceExhausted:  // All new reasons are server-only
            return true
        }
    }
}
```

### 4. `Core/Jobs/CancelReason.swift`

**Replace entire file with:**

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Cancel reason enumeration (3 reasons).
public enum CancelReason: String, Codable, CaseIterable {
    case userRequested = "user_requested"
    case appTerminated = "app_terminated"
    case systemTimeout = "system_timeout"  // New in PR2-JSM-3.0
}
```

### 5. `Core/Jobs/JobStateMachineError.swift`

**Replace entire file with:**

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Job state machine error types.
public enum JobStateMachineError: Error, Equatable {
    // Original errors
    case emptyJobId
    case jobIdTooShort(length: Int)
    case jobIdTooLong(length: Int)
    case jobIdInvalidCharacters(firstInvalidIndex: Int)
    case alreadyTerminal(currentState: JobState)
    case illegalTransition(from: JobState, to: JobState)
    case cancelWindowExpired(elapsedSeconds: Int)
    case invalidFailureReason(reason: FailureReason, fromState: JobState)
    case invalidCancelReason(reason: CancelReason, fromState: JobState)
    case serverOnlyFailureReason(reason: FailureReason)

    // New errors (PR2-JSM-3.0)
    case duplicateTransition(transitionId: String)
    case heartbeatMissed(missedCount: Int, lastHeartbeat: Date?)
    case retryLimitExceeded(attempts: Int, maxAttempts: Int)
}
```

### 6. `Core/Jobs/JobStateMachine.swift`

**Replace entire file with:**

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Transition source enumeration
public enum TransitionSource: String, Codable {
    case client
    case server
    case system
}

/// Transition log structure for state change events.
public struct TransitionLog: Codable {
    public let jobId: String
    public let from: JobState
    public let to: JobState
    public let failureReason: FailureReason?
    public let cancelReason: CancelReason?
    public let timestamp: Date
    public let contractVersion: String

    // New fields (PR2-JSM-3.0)
    public let transitionId: String
    public let retryAttempt: Int?
    public let source: TransitionSource

    public init(
        jobId: String,
        from: JobState,
        to: JobState,
        failureReason: FailureReason?,
        cancelReason: CancelReason?,
        timestamp: Date,
        contractVersion: String,
        transitionId: String = UUID().uuidString,
        retryAttempt: Int? = nil,
        source: TransitionSource = .client
    ) {
        self.jobId = jobId
        self.from = from
        self.to = to
        self.failureReason = failureReason
        self.cancelReason = cancelReason
        self.timestamp = timestamp
        self.contractVersion = contractVersion
        self.transitionId = transitionId
        self.retryAttempt = retryAttempt
        self.source = source
    }
}

/// Job state machine (pure function implementation).
public final class JobStateMachine {

    /// Internal transition structure.
    private struct Transition: Hashable {
        let from: JobState
        let to: JobState
    }

    /// Legal transitions (13 total).
    private static let legalTransitions: Set<Transition> = [
        Transition(from: .pending, to: .uploading),
        Transition(from: .pending, to: .cancelled),
        Transition(from: .uploading, to: .queued),
        Transition(from: .uploading, to: .failed),
        Transition(from: .uploading, to: .cancelled),
        Transition(from: .queued, to: .processing),
        Transition(from: .queued, to: .failed),
        Transition(from: .queued, to: .cancelled),
        Transition(from: .processing, to: .packaging),
        Transition(from: .processing, to: .failed),
        Transition(from: .processing, to: .cancelled),
        Transition(from: .packaging, to: .completed),
        Transition(from: .packaging, to: .failed),
    ]

    /// Failure reason binding map (which reasons are allowed from which states).
    private static let failureReasonBinding: [FailureReason: Set<JobState>] = [
        .networkError: [.uploading],
        .uploadInterrupted: [.uploading],
        .serverUnavailable: [.uploading, .queued],
        .invalidVideoFormat: [.uploading, .queued],
        .videoTooShort: [.queued],
        .videoTooLong: [.queued],
        .insufficientFrames: [.queued, .processing],
        .poseEstimationFailed: [.processing],
        .lowRegistrationRate: [.processing],
        .trainingFailed: [.processing],
        .gpuOutOfMemory: [.processing],
        .processingTimeout: [.processing],
        .packagingFailed: [.packaging],
        .internalError: [.uploading, .queued, .processing, .packaging],
        // New failure reasons (PR2-JSM-3.0)
        .heartbeatTimeout: [.processing],
        .stalledProcessing: [.processing],
        .resourceExhausted: [.processing, .packaging],
    ]

    /// Cancel reason binding map (which reasons are allowed from which states).
    private static let cancelReasonBinding: [CancelReason: Set<JobState>] = [
        .userRequested: [.pending, .uploading, .queued, .processing],
        .appTerminated: [.pending, .uploading, .queued, .processing],
        // New cancel reason (PR2-JSM-3.0) - NOT allowed from PROCESSING
        .systemTimeout: [.pending, .uploading, .queued],
    ]

    // MARK: - Public Methods

    /// Check if a transition is legal (does not include 30-second window check).
    public static func canTransition(from: JobState, to: JobState) -> Bool {
        guard from != to else { return false }
        return legalTransitions.contains(Transition(from: from, to: to))
    }

    /// Validate job ID format (15-20 digit string).
    private static func validateJobId(_ jobId: String) throws {
        guard !jobId.isEmpty else {
            throw JobStateMachineError.emptyJobId
        }

        guard jobId.count >= ContractConstants.JOB_ID_MIN_LENGTH else {
            throw JobStateMachineError.jobIdTooShort(length: jobId.count)
        }
        guard jobId.count <= ContractConstants.JOB_ID_MAX_LENGTH else {
            throw JobStateMachineError.jobIdTooLong(length: jobId.count)
        }

        for (index, char) in jobId.enumerated() {
            if !char.isNumber {
                throw JobStateMachineError.jobIdInvalidCharacters(firstInvalidIndex: index)
            }
        }
    }

    /// Validate failure reason is allowed from source state.
    private static func isValidFailureReason(_ reason: FailureReason, from: JobState) -> Bool {
        guard let allowedStates = failureReasonBinding[reason] else {
            return false
        }
        return allowedStates.contains(from)
    }

    /// Validate cancel reason is allowed from source state.
    private static func isValidCancelReason(_ reason: CancelReason, from: JobState) -> Bool {
        guard let allowedStates = cancelReasonBinding[reason] else {
            return false
        }
        return allowedStates.contains(from)
    }

    /// Execute state transition (pure function).
    /// - Parameters:
    ///   - jobId: Job ID (snowflake ID, 15-20 digits)
    ///   - from: Current state
    ///   - to: Target state
    ///   - failureReason: Failure reason (required when to == .failed)
    ///   - cancelReason: Cancel reason (required when to == .cancelled)
    ///   - elapsedSeconds: Seconds elapsed since entering PROCESSING
    ///   - isServerSide: Whether this is a server-side call
    ///   - transitionId: Unique transition ID for idempotency (auto-generated if nil)
    ///   - retryAttempt: Current retry attempt number
    ///   - source: Transition source (client/server/system)
    ///   - idempotencyCheck: Callback to check for duplicate transitions
    ///   - logger: Log callback
    /// - Returns: New state after transition
    /// - Throws: JobStateMachineError if transition is invalid
    public static func transition(
        jobId: String,
        from: JobState,
        to: JobState,
        failureReason: FailureReason? = nil,
        cancelReason: CancelReason? = nil,
        elapsedSeconds: Int? = nil,
        isServerSide: Bool = false,
        transitionId: String? = nil,
        retryAttempt: Int? = nil,
        source: TransitionSource = .client,
        idempotencyCheck: ((String) -> Bool)? = nil,
        logger: ((TransitionLog) -> Void)? = nil
    ) throws -> JobState {

        // Generate transition ID if not provided
        let txnId = transitionId ?? UUID().uuidString

        // 0. Idempotency check (highest priority after ID generation)
        if let check = idempotencyCheck, check(txnId) {
            throw JobStateMachineError.duplicateTransition(transitionId: txnId)
        }

        // 1. jobId validation
        try validateJobId(jobId)

        // 2. Check terminal state
        guard !from.isTerminal else {
            throw JobStateMachineError.alreadyTerminal(currentState: from)
        }

        // 3. Check transition legality
        guard canTransition(from: from, to: to) else {
            throw JobStateMachineError.illegalTransition(from: from, to: to)
        }

        // 4. Check 30-second cancel window (only for PROCESSING → CANCELLED)
        if from == .processing && to == .cancelled {
            guard let elapsed = elapsedSeconds else {
                throw JobStateMachineError.cancelWindowExpired(elapsedSeconds: -1)
            }
            guard elapsed <= ContractConstants.CANCEL_WINDOW_SECONDS else {
                throw JobStateMachineError.cancelWindowExpired(elapsedSeconds: elapsed)
            }
        }

        // 5. Validate failure reason
        if to == .failed {
            guard let reason = failureReason else {
                throw JobStateMachineError.invalidFailureReason(reason: .internalError, fromState: from)
            }
            guard isValidFailureReason(reason, from: from) else {
                throw JobStateMachineError.invalidFailureReason(reason: reason, fromState: from)
            }
            if reason.isServerOnly && !isServerSide {
                throw JobStateMachineError.serverOnlyFailureReason(reason: reason)
            }
        }

        // 6. Validate cancel reason
        if to == .cancelled {
            guard let reason = cancelReason else {
                throw JobStateMachineError.invalidCancelReason(reason: .userRequested, fromState: from)
            }
            guard isValidCancelReason(reason, from: from) else {
                throw JobStateMachineError.invalidCancelReason(reason: reason, fromState: from)
            }
        }

        // 7. Log transition
        logger?(TransitionLog(
            jobId: jobId,
            from: from,
            to: to,
            failureReason: failureReason,
            cancelReason: cancelReason,
            timestamp: Date(),
            contractVersion: ContractConstants.CONTRACT_VERSION,
            transitionId: txnId,
            retryAttempt: retryAttempt,
            source: source
        ))

        return to
    }
}
```

### 7. `Tests/Jobs/JobStateMachineTests.swift`

**Update the following sections:**

1. **Update header (lines 1-5):**
```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================
```

2. **Update `testFailureReasonCodable()` - add 3 new cases:**
```swift
func testFailureReasonCodable() {
    let validCases: [(String, FailureReason)] = [
        ("network_error", .networkError),
        ("upload_interrupted", .uploadInterrupted),
        ("server_unavailable", .serverUnavailable),
        ("invalid_video_format", .invalidVideoFormat),
        ("video_too_short", .videoTooShort),
        ("video_too_long", .videoTooLong),
        ("insufficient_frames", .insufficientFrames),
        ("pose_estimation_failed", .poseEstimationFailed),
        ("low_registration_rate", .lowRegistrationRate),
        ("training_failed", .trainingFailed),
        ("gpu_out_of_memory", .gpuOutOfMemory),
        ("processing_timeout", .processingTimeout),
        ("packaging_failed", .packagingFailed),
        ("internal_error", .internalError),
        // New in PR2-JSM-3.0
        ("heartbeat_timeout", .heartbeatTimeout),
        ("stalled_processing", .stalledProcessing),
        ("resource_exhausted", .resourceExhausted),
    ]

    for (rawValue, expected) in validCases {
        let json = "\"\(rawValue)\"".data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(FailureReason.self, from: json)
        XCTAssertEqual(decoded, expected, "Failed to decode \(rawValue)")
    }

    XCTAssertEqual(validCases.count, ContractConstants.FAILURE_REASON_COUNT)
}
```

3. **Update `testCancelReasonCodable()` - add 1 new case:**
```swift
func testCancelReasonCodable() {
    let validCases: [(String, CancelReason)] = [
        ("user_requested", .userRequested),
        ("app_terminated", .appTerminated),
        // New in PR2-JSM-3.0
        ("system_timeout", .systemTimeout),
    ]

    for (rawValue, expected) in validCases {
        let json = "\"\(rawValue)\"".data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(CancelReason.self, from: json)
        XCTAssertEqual(decoded, expected, "Failed to decode \(rawValue)")
    }

    XCTAssertEqual(validCases.count, ContractConstants.CANCEL_REASON_COUNT)
}
```

4. **Add new test methods at the end of the class:**
```swift
// MARK: - PR2-JSM-3.0 New Tests

func testNewFailureReasons() {
    // heartbeatTimeout from PROCESSING
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .processing,
            to: .failed,
            failureReason: .heartbeatTimeout,
            isServerSide: true
        )
    )

    // stalledProcessing from PROCESSING
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .processing,
            to: .failed,
            failureReason: .stalledProcessing,
            isServerSide: true
        )
    )

    // resourceExhausted from PROCESSING
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .processing,
            to: .failed,
            failureReason: .resourceExhausted,
            isServerSide: true
        )
    )

    // resourceExhausted from PACKAGING
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .packaging,
            to: .failed,
            failureReason: .resourceExhausted,
            isServerSide: true
        )
    )
}

func testSystemTimeoutCancelReason() {
    // systemTimeout from PENDING - should succeed
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .pending,
            to: .cancelled,
            cancelReason: .systemTimeout
        )
    )

    // systemTimeout from UPLOADING - should succeed
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .uploading,
            to: .cancelled,
            cancelReason: .systemTimeout
        )
    )

    // systemTimeout from QUEUED - should succeed
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .queued,
            to: .cancelled,
            cancelReason: .systemTimeout
        )
    )

    // systemTimeout from PROCESSING - should FAIL (not allowed)
    XCTAssertThrowsError(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .processing,
            to: .cancelled,
            cancelReason: .systemTimeout,
            elapsedSeconds: 10
        )
    ) { error in
        guard case JobStateMachineError.invalidCancelReason(let reason, let fromState) = error else {
            XCTFail("Expected invalidCancelReason, got \(error)")
            return
        }
        XCTAssertEqual(reason, .systemTimeout)
        XCTAssertEqual(fromState, .processing)
    }
}

func testIdempotentTransition() {
    let transitionId = "test-txn-123"
    var seenIds: Set<String> = []

    // First transition should succeed
    XCTAssertNoThrow(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .pending,
            to: .uploading,
            transitionId: transitionId,
            idempotencyCheck: { id in
                if seenIds.contains(id) {
                    return true  // Duplicate
                }
                seenIds.insert(id)
                return false
            }
        )
    )

    // Second transition with same ID should fail
    XCTAssertThrowsError(
        try JobStateMachine.transition(
            jobId: validJobId,
            from: .pending,
            to: .uploading,
            transitionId: transitionId,
            idempotencyCheck: { id in seenIds.contains(id) }
        )
    ) { error in
        guard case JobStateMachineError.duplicateTransition(let id) = error else {
            XCTFail("Expected duplicateTransition, got \(error)")
            return
        }
        XCTAssertEqual(id, transitionId)
    }
}

func testTransitionLogEnhancedFields() {
    var capturedLog: TransitionLog?

    _ = try? JobStateMachine.transition(
        jobId: validJobId,
        from: .pending,
        to: .uploading,
        transitionId: "custom-id-456",
        retryAttempt: 2,
        source: .server,
        logger: { log in capturedLog = log }
    )

    XCTAssertNotNil(capturedLog)
    XCTAssertEqual(capturedLog?.transitionId, "custom-id-456")
    XCTAssertEqual(capturedLog?.retryAttempt, 2)
    XCTAssertEqual(capturedLog?.source, .server)
    XCTAssertEqual(capturedLog?.contractVersion, "PR2-JSM-3.0")
}

func testNewFailureReasonRetryability() {
    // heartbeatTimeout should be retryable
    XCTAssertTrue(FailureReason.heartbeatTimeout.isRetryable)

    // stalledProcessing should be retryable
    XCTAssertTrue(FailureReason.stalledProcessing.isRetryable)

    // resourceExhausted should NOT be retryable
    XCTAssertFalse(FailureReason.resourceExhausted.isRetryable)
}

func testNewFailureReasonServerOnly() {
    // All new reasons should be server-only
    XCTAssertTrue(FailureReason.heartbeatTimeout.isServerOnly)
    XCTAssertTrue(FailureReason.stalledProcessing.isServerOnly)
    XCTAssertTrue(FailureReason.resourceExhausted.isServerOnly)
}
```

---

## Self-Verification Steps

After completing all changes, run the following verification steps and document results:

### Step 1: Build Verification
```bash
swift build 2>&1
```
**Expected**: Build succeeds with no errors

### Step 2: All Tests
```bash
swift test 2>&1
```
**Expected**: All tests pass

### Step 3: Specific Test Suites
```bash
swift test --filter JobStateMachineTests 2>&1
swift test --filter RetryCalculatorTests 2>&1
```
**Expected**: Both test suites pass

### Step 4: Contract Version Consistency
```bash
grep -r "PR2-JSM-3.0" Core/Jobs/ Tests/Jobs/
```
**Expected**: All 7+ files contain "PR2-JSM-3.0"

### Step 5: Enum Count Verification
```bash
# FailureReason count (should be 17)
grep -c "case [a-zA-Z]" Core/Jobs/FailureReason.swift

# CancelReason count (should be 3)
grep -c "case [a-zA-Z]" Core/Jobs/CancelReason.swift

# JobState count (should be 8)
grep -c "case [a-zA-Z]" Core/Jobs/JobState.swift
```
**Expected**: 17, 3, 8 respectively

### Step 6: New Files Exist
```bash
ls -la Core/Jobs/RetryCalculator.swift
ls -la Core/Jobs/DLQEntry.swift
ls -la Core/Jobs/CircuitBreaker.swift
ls -la Core/Jobs/DeterministicEncoder.swift
ls -la scripts/pre-push-verify.sh
ls -la Tests/Jobs/RetryCalculatorTests.swift
```
**Expected**: All 6 files exist

### Step 7: Pre-Push Script Test
```bash
chmod +x scripts/pre-push-verify.sh
./scripts/pre-push-verify.sh
```
**Expected**: Script runs and reports pass/fail status

---

## Inspection Report Template

After completing all implementation and verification, generate a report in the following format:

```markdown
# PR2-JSM-3.0 Phase 1 Build Inspection Report

## Build Information
- **Date**: [YYYY-MM-DD HH:MM:SS]
- **Swift Version**: [output of swift --version]
- **Platform**: [macOS/Linux version]
- **Branch**: [current git branch]

## Files Created
| File | Status | Lines | Notes |
|------|--------|-------|-------|
| Core/Jobs/RetryCalculator.swift | ✅/❌ | XXX | |
| Core/Jobs/DLQEntry.swift | ✅/❌ | XXX | |
| Core/Jobs/CircuitBreaker.swift | ✅/❌ | XXX | |
| Core/Jobs/DeterministicEncoder.swift | ✅/❌ | XXX | |
| scripts/pre-push-verify.sh | ✅/❌ | XXX | |
| Tests/Jobs/RetryCalculatorTests.swift | ✅/❌ | XXX | |

## Files Modified
| File | Status | Changes | Notes |
|------|--------|---------|-------|
| Core/Jobs/ContractConstants.swift | ✅/❌ | Version + constants | |
| Core/Jobs/JobState.swift | ✅/❌ | Header only | |
| Core/Jobs/FailureReason.swift | ✅/❌ | +3 cases | |
| Core/Jobs/CancelReason.swift | ✅/❌ | +1 case | |
| Core/Jobs/JobStateMachineError.swift | ✅/❌ | +3 errors | |
| Core/Jobs/JobStateMachine.swift | ✅/❌ | +idempotency | |
| Tests/Jobs/JobStateMachineTests.swift | ✅/❌ | +6 tests | |

## Verification Results
| Check | Status | Output |
|-------|--------|--------|
| swift build | ✅/❌ | [summary] |
| swift test | ✅/❌ | X passed, Y failed |
| JobStateMachineTests | ✅/❌ | X tests |
| RetryCalculatorTests | ✅/❌ | X tests |
| Version consistency | ✅/❌ | X files verified |
| FailureReason count | ✅/❌ | 17 |
| CancelReason count | ✅/❌ | 3 |
| JobState count | ✅/❌ | 8 |
| pre-push-verify.sh | ✅/❌ | [summary] |

## Contract Verification
- **Contract Version**: PR2-JSM-3.0
- **States**: 8 (unchanged)
- **Transitions**: 13 (unchanged)
- **FailureReasons**: 17 (was 14, +3)
- **CancelReasons**: 3 (was 2, +1)

## New Features Verified
| Feature | Test Method | Status |
|---------|-------------|--------|
| Exponential backoff | testCalculateDelayFullJitter | ✅/❌ |
| Decorrelated jitter | testCalculateDelayDecorrelatedJitter | ✅/❌ |
| Circuit breaker states | [manual/test] | ✅/❌ |
| Idempotent transitions | testIdempotentTransition | ✅/❌ |
| heartbeatTimeout reason | testNewFailureReasons | ✅/❌ |
| stalledProcessing reason | testNewFailureReasons | ✅/❌ |
| resourceExhausted reason | testNewFailureReasons | ✅/❌ |
| systemTimeout cancel | testSystemTimeoutCancelReason | ✅/❌ |
| TransitionLog enhanced | testTransitionLogEnhancedFields | ✅/❌ |
| DeterministicEncoder | [compile check] | ✅/❌ |
| DLQEntry struct | [compile check] | ✅/❌ |

## Issues Found
| Issue | Severity | Resolution |
|-------|----------|------------|
| [description] | High/Medium/Low | [how fixed] |

## Summary
- **Total Files Created**: X/6
- **Total Files Modified**: X/7
- **Total Tests**: X passed, Y failed
- **Build Status**: ✅ SUCCESS / ❌ FAILED
- **Ready for Phase 2**: Yes/No

## Recommendations
1. [Any follow-up actions needed]
2. [Issues to address in Phase 2]
```

---

## Important Notes

1. **DO NOT** modify any files outside the scope listed above
2. **DO NOT** implement Phase 2 features (Part B, D, E, F, H additional tests, I)
3. **ALWAYS** run verification steps after each major change
4. **PRESERVE** backward compatibility - all new parameters have defaults
5. **MAINTAIN** error priority order in JobStateMachine.transition()
6. The 8-state contract MUST remain unchanged (DLQ is metadata, not a state)

## Success Criteria

Phase 1 is complete when:
- [ ] All 6 new files created
- [ ] All 7 existing files modified correctly
- [ ] `swift build` succeeds
- [ ] `swift test` passes all tests
- [ ] Contract version is PR2-JSM-3.0 in all files
- [ ] Enum counts match: 17 FailureReasons, 3 CancelReasons, 8 JobStates
- [ ] pre-push-verify.sh runs successfully
- [ ] Inspection report generated with all checks passing
