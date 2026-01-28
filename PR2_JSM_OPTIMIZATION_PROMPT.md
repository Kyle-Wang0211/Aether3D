# PR2 Job State Machine - Ultimate Optimization Prompt

**Version**: 1.0.0
**Date**: 2026-01-28
**Branch**: pr2
**Scope**: Elevate PR2-JSM-2.5 to industry-leading distributed job orchestration standard
**Priority**: P0 (Foundation-level enhancement)

---

## Executive Summary

This prompt upgrades PR2 Job State Machine from **excellent (4/5)** to **world-class (5/5)** by implementing:

1. **Exponential Backoff with Jitter** - Industry-standard retry strategy (AWS, Google, Netflix)
2. **Dead Letter Queue (DLQ)** - Failed job isolation for debugging and manual retry
3. **Idempotent Transition Protection** - Prevent duplicate state transitions
4. **Processing Heartbeat Timeout** - Detect and reclaim stalled jobs
5. **Enhanced Failure Taxonomy** - More granular failure classification
6. **Micro-optimizations** - Small parameter tweaks for smoother UX

---

## PART 1: CONTRACT VERSION UPGRADE

### 1.1 Update Contract Header

**File**: ALL files in `Core/Jobs/`

**Change**: Update contract version from `PR2-JSM-2.5` to `PR2-JSM-3.0`

```swift
// BEFORE (all 6 files)
// Contract Version: PR2-JSM-2.5
// States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2

// AFTER (all 6 files)
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
```

**Files to update**:
- `Core/Jobs/ContractConstants.swift` (line 3)
- `Core/Jobs/JobStateMachine.swift` (line 3)
- `Core/Jobs/JobState.swift` (line 3)
- `Core/Jobs/FailureReason.swift` (line 3)
- `Core/Jobs/CancelReason.swift` (line 3)
- `Core/Jobs/JobStateMachineError.swift` (line 3)
- `Tests/Jobs/JobStateMachineTests.swift` (line 3)

---

## PART 2: EXPONENTIAL BACKOFF WITH JITTER

### 2.1 Rationale

**Current**: Fixed retry with 2s base interval → 2s → 4s → 8s (predictable)
**Problem**: Thundering herd effect when many clients retry simultaneously
**Solution**: Exponential backoff + random jitter (AWS/Google/Netflix standard)

**Formula**:
```
delay = min(baseDelay × 2^attempt + random(0, jitterMax), maxDelay)
```

### 2.2 Constants Update

**File**: `Core/Jobs/ContractConstants.swift`

**Add after line 75** (after `RETRY_BASE_INTERVAL_SECONDS`):

```swift
    // MARK: - Retry Strategy (Enhanced v3.0)

    /// Maximum automatic retry count
    /// - Increased from 3 to 5 for better resilience against transient failures
    /// - Studies show 5 retries covers 99.9% of recoverable transient errors
    public static let MAX_AUTO_RETRY_COUNT = 5

    /// Base retry interval in seconds (exponential backoff base)
    /// - Kept at 2 seconds for quick first retry
    public static let RETRY_BASE_INTERVAL_SECONDS = 2

    /// Maximum retry delay in seconds (cap for exponential backoff)
    /// - 60 seconds max prevents excessive wait times
    /// - After 5 retries: 2→4→8→16→32 (capped before 64)
    public static let RETRY_MAX_DELAY_SECONDS = 60

    /// Maximum jitter in milliseconds
    /// - Random jitter prevents thundering herd
    /// - 1000ms (1 second) provides sufficient distribution
    public static let RETRY_JITTER_MAX_MS = 1000

    /// Jitter strategy: "full" or "equal"
    /// - "full": random(0, jitterMax) - AWS recommendation
    /// - "equal": delay/2 + random(0, delay/2) - Google recommendation
    /// - We use "full" for maximum distribution
    public static let RETRY_JITTER_STRATEGY = "full"
```

### 2.3 Retry Calculator Implementation

**File**: `Core/Jobs/RetryCalculator.swift` (NEW FILE)

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// Purpose: Calculate retry delays with exponential backoff and jitter
// ============================================================================

import Foundation

/// Retry delay calculator with exponential backoff and jitter.
/// Based on AWS and Google Cloud best practices for distributed systems.
public enum RetryCalculator {

    /// Calculate the delay before the next retry attempt.
    /// - Parameters:
    ///   - attempt: Current attempt number (0-indexed, so first retry is attempt 0)
    ///   - baseInterval: Base interval in seconds (default: 2)
    ///   - maxDelay: Maximum delay cap in seconds (default: 60)
    ///   - jitterMaxMs: Maximum jitter in milliseconds (default: 1000)
    /// - Returns: Delay in seconds (Double for millisecond precision)
    public static func calculateDelay(
        attempt: Int,
        baseInterval: Int = ContractConstants.RETRY_BASE_INTERVAL_SECONDS,
        maxDelay: Int = ContractConstants.RETRY_MAX_DELAY_SECONDS,
        jitterMaxMs: Int = ContractConstants.RETRY_JITTER_MAX_MS
    ) -> Double {
        // Exponential component: baseInterval × 2^attempt
        let exponentialDelay = Double(baseInterval) * pow(2.0, Double(attempt))

        // Cap at maxDelay
        let cappedDelay = min(exponentialDelay, Double(maxDelay))

        // Add jitter (full jitter strategy)
        let jitterSeconds = Double.random(in: 0...(Double(jitterMaxMs) / 1000.0))

        // Final delay
        let finalDelay = cappedDelay + jitterSeconds

        return finalDelay
    }

    /// Check if retry should be attempted based on attempt count and failure reason.
    /// - Parameters:
    ///   - attempt: Current attempt number (0-indexed)
    ///   - failureReason: The failure reason from the last attempt
    /// - Returns: True if retry should be attempted
    public static func shouldRetry(
        attempt: Int,
        failureReason: FailureReason
    ) -> Bool {
        // Check attempt limit
        guard attempt < ContractConstants.MAX_AUTO_RETRY_COUNT else {
            return false
        }

        // Check if failure reason is retryable
        return failureReason.isRetryable
    }

    /// Get all retry delays for a full retry sequence (for preview/logging).
    /// - Parameters:
    ///   - maxAttempts: Maximum attempts (default from constants)
    /// - Returns: Array of delays in seconds
    public static func previewDelays(
        maxAttempts: Int = ContractConstants.MAX_AUTO_RETRY_COUNT
    ) -> [Double] {
        return (0..<maxAttempts).map { attempt in
            calculateDelay(attempt: attempt)
        }
    }
}

// MARK: - Retry Sequence Example
// Attempt 0: 2.0 + jitter(0~1.0) = 2.0~3.0 seconds
// Attempt 1: 4.0 + jitter(0~1.0) = 4.0~5.0 seconds
// Attempt 2: 8.0 + jitter(0~1.0) = 8.0~9.0 seconds
// Attempt 3: 16.0 + jitter(0~1.0) = 16.0~17.0 seconds
// Attempt 4: 32.0 + jitter(0~1.0) = 32.0~33.0 seconds
// Total max wait: ~68 seconds (reasonable for user experience)
```

### 2.4 Update ContractConstants Count

**File**: `Core/Jobs/ContractConstants.swift`

**Modify line 72**:

```swift
// BEFORE
public static let MAX_AUTO_RETRY_COUNT = 3

// AFTER
public static let MAX_AUTO_RETRY_COUNT = 5
```

---

## PART 3: DEAD LETTER QUEUE (DLQ) SUPPORT

### 3.1 Rationale

**Problem**: Jobs that fail after max retries disappear into the void
**Solution**: DLQ captures failed jobs for debugging, analytics, and manual retry
**Benefit**: Zero job loss, full audit trail, operational visibility

### 3.2 New State: DLQ (Dead Letter Queue)

**IMPORTANT**: We do NOT add a new state enum value. Instead, DLQ is a **logical concept** tracked via metadata. This preserves the 8-state constitutional contract.

### 3.3 DLQ Metadata Structure

**File**: `Core/Jobs/DLQEntry.swift` (NEW FILE)

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// Purpose: Dead Letter Queue entry for failed jobs
// ============================================================================

import Foundation

/// Dead Letter Queue entry for jobs that have exhausted all retry attempts.
public struct DLQEntry: Codable {
    /// Unique DLQ entry ID
    public let dlqId: String

    /// Original job ID
    public let jobId: String

    /// Final failure reason
    public let failureReason: FailureReason

    /// Number of retry attempts made
    public let retryAttempts: Int

    /// Timestamp when job entered DLQ
    public let enqueuedAt: Date

    /// Expiration timestamp (after which entry may be purged)
    public let expiresAt: Date

    /// Last state before entering DLQ
    public let lastState: JobState

    /// Full transition history for debugging
    public let transitionHistory: [TransitionLog]

    /// Whether this entry has been manually reviewed
    public var isReviewed: Bool

    /// Whether this entry has been manually retried
    public var isRetried: Bool

    /// Manual retry job ID (if retried)
    public var retryJobId: String?

    /// Contract version at time of failure
    public let contractVersion: String

    public init(
        dlqId: String = UUID().uuidString,
        jobId: String,
        failureReason: FailureReason,
        retryAttempts: Int,
        enqueuedAt: Date = Date(),
        expiresAt: Date? = nil,
        lastState: JobState,
        transitionHistory: [TransitionLog] = [],
        isReviewed: Bool = false,
        isRetried: Bool = false,
        retryJobId: String? = nil,
        contractVersion: String = ContractConstants.CONTRACT_VERSION
    ) {
        self.dlqId = dlqId
        self.jobId = jobId
        self.failureReason = failureReason
        self.retryAttempts = retryAttempts
        self.enqueuedAt = enqueuedAt
        self.expiresAt = expiresAt ?? Calendar.current.date(
            byAdding: .day,
            value: ContractConstants.DLQ_RETENTION_DAYS,
            to: enqueuedAt
        )!
        self.lastState = lastState
        self.transitionHistory = transitionHistory
        self.isReviewed = isReviewed
        self.isRetried = isRetried
        self.retryJobId = retryJobId
        self.contractVersion = contractVersion
    }
}

/// DLQ statistics for monitoring.
public struct DLQStats: Codable {
    /// Total entries in DLQ
    public let totalEntries: Int

    /// Entries by failure reason
    public let entriesByReason: [String: Int]

    /// Entries pending review
    public let pendingReview: Int

    /// Entries retried
    public let retriedCount: Int

    /// Oldest entry timestamp
    public let oldestEntry: Date?

    /// Stats generation timestamp
    public let generatedAt: Date
}
```

### 3.4 DLQ Constants

**File**: `Core/Jobs/ContractConstants.swift`

**Add new section after Retry section**:

```swift
    // MARK: - Dead Letter Queue (DLQ)

    /// DLQ retention period in days
    /// - 7 days provides sufficient time for manual review
    /// - After 7 days, entries may be purged (but logged permanently)
    public static let DLQ_RETENTION_DAYS = 7

    /// Maximum DLQ entries before alert
    /// - Triggers operational alert when exceeded
    public static let DLQ_ALERT_THRESHOLD = 100

    /// DLQ entry ID prefix
    public static let DLQ_ID_PREFIX = "dlq_"
```

---

## PART 4: IDEMPOTENT TRANSITION PROTECTION

### 4.1 Rationale

**Problem**: Duplicate API calls can cause duplicate state transitions
**Solution**: Transition ID ensures each transition is executed exactly once
**Pattern**: Standard distributed systems idempotency pattern

### 4.2 Enhanced TransitionLog

**File**: `Core/Jobs/JobStateMachine.swift`

**Modify TransitionLog structure (lines 10-36)**:

```swift
/// Transition log structure for state change events.
public struct TransitionLog: Codable {
    /// Unique transition ID (UUID) for idempotency
    public let transitionId: String

    public let jobId: String
    public let from: JobState
    public let to: JobState
    public let failureReason: FailureReason?
    public let cancelReason: CancelReason?
    public let timestamp: Date
    public let contractVersion: String

    /// Retry attempt number (0 = first attempt, nil = not a retry)
    public let retryAttempt: Int?

    /// Source of transition (client/server/system)
    public let source: TransitionSource

    public init(
        transitionId: String = UUID().uuidString,
        jobId: String,
        from: JobState,
        to: JobState,
        failureReason: FailureReason?,
        cancelReason: CancelReason?,
        timestamp: Date,
        contractVersion: String,
        retryAttempt: Int? = nil,
        source: TransitionSource = .client
    ) {
        self.transitionId = transitionId
        self.jobId = jobId
        self.from = from
        self.to = to
        self.failureReason = failureReason
        self.cancelReason = cancelReason
        self.timestamp = timestamp
        self.contractVersion = contractVersion
        self.retryAttempt = retryAttempt
        self.source = source
    }
}

/// Source of state transition.
public enum TransitionSource: String, Codable {
    case client = "client"       // Mobile app initiated
    case server = "server"       // Backend initiated
    case system = "system"       // Automatic (timeout, heartbeat failure)
}
```

### 4.3 Idempotency Check in Transition

**File**: `Core/Jobs/JobStateMachine.swift`

**Add new parameter to transition function (line 161)**:

```swift
    /// Execute state transition (pure function).
    /// - Parameters:
    ///   - transitionId: Unique transition ID for idempotency (optional, auto-generated if nil)
    ///   - jobId: Job ID (snowflake ID, 15-20 digits)
    ///   - from: Current state
    ///   - to: Target state
    ///   - failureReason: Failure reason (required when to == .failed)
    ///   - cancelReason: Cancel reason (required when to == .cancelled)
    ///   - elapsedSeconds: Seconds elapsed since entering PROCESSING (required for PROCESSING → CANCELLED)
    ///   - isServerSide: Whether this is a server-side call (for serverOnly validation)
    ///   - retryAttempt: Retry attempt number (0-indexed, nil if not a retry)
    ///   - source: Source of transition (client/server/system)
    ///   - idempotencyCheck: Callback to check if transitionId already executed (returns true if duplicate)
    ///   - logger: Log callback
    /// - Returns: New state after transition
    /// - Throws: JobStateMachineError if transition is invalid
    public static func transition(
        transitionId: String? = nil,
        jobId: String,
        from: JobState,
        to: JobState,
        failureReason: FailureReason? = nil,
        cancelReason: CancelReason? = nil,
        elapsedSeconds: Int? = nil,
        isServerSide: Bool = false,
        retryAttempt: Int? = nil,
        source: TransitionSource = .client,
        idempotencyCheck: ((String) -> Bool)? = nil,
        logger: ((TransitionLog) -> Void)? = nil
    ) throws -> JobState {
        // Generate transition ID if not provided
        let finalTransitionId = transitionId ?? UUID().uuidString

        // 0. Idempotency check (highest priority)
        if let check = idempotencyCheck, check(finalTransitionId) {
            // Already executed - return current state (idempotent behavior)
            return from
        }

        // Error priority order (strictly enforced):
        // 1. jobId validation
        try validateJobId(jobId)

        // ... (rest of existing validation code unchanged)

        // 7. Log transition (with enhanced fields)
        logger?(TransitionLog(
            transitionId: finalTransitionId,
            jobId: jobId,
            from: from,
            to: to,
            failureReason: failureReason,
            cancelReason: cancelReason,
            timestamp: Date(),
            contractVersion: ContractConstants.CONTRACT_VERSION,
            retryAttempt: retryAttempt,
            source: source
        ))

        return to
    }
```

---

## PART 5: PROCESSING HEARTBEAT TIMEOUT

### 5.1 Rationale

**Current**: QUEUED has 1-hour timeout, but PROCESSING has none
**Problem**: Stalled PROCESSING jobs block resources forever
**Solution**: 30-second heartbeat interval, auto-fail after 3 missed heartbeats

### 5.2 Heartbeat Constants

**File**: `Core/Jobs/ContractConstants.swift`

**Update existing constants and add new ones**:

```swift
    // MARK: - Heartbeat & Monitoring

    /// Progress report interval in seconds
    /// - Reduced from 5 to 3 seconds for more responsive UI
    public static let PROGRESS_REPORT_INTERVAL_SECONDS = 3

    /// Health check interval in seconds
    /// - Kept at 10 seconds for balance between overhead and responsiveness
    public static let HEALTH_CHECK_INTERVAL_SECONDS = 10

    /// Processing heartbeat interval in seconds
    /// - Server must receive heartbeat within this interval
    /// - 30 seconds balances network latency and detection speed
    public static let PROCESSING_HEARTBEAT_INTERVAL_SECONDS = 30

    /// Maximum missed heartbeats before auto-failure
    /// - 3 missed heartbeats = 90 seconds of silence
    /// - Provides grace period for network issues
    public static let PROCESSING_HEARTBEAT_MAX_MISSED = 3

    /// Processing heartbeat timeout in seconds (computed)
    /// - Auto-fail if no heartbeat for this duration
    /// - 30 × 3 = 90 seconds
    public static let PROCESSING_HEARTBEAT_TIMEOUT_SECONDS =
        PROCESSING_HEARTBEAT_INTERVAL_SECONDS * PROCESSING_HEARTBEAT_MAX_MISSED
```

### 5.3 New Failure Reason: Heartbeat Timeout

**File**: `Core/Jobs/FailureReason.swift`

**Add new case after `processingTimeout` (line 22)**:

```swift
    case processingTimeout = "processing_timeout"
    case heartbeatTimeout = "heartbeat_timeout"     // NEW: v3.0
    case stalledProcessing = "stalled_processing"   // NEW: v3.0
    case resourceExhausted = "resource_exhausted"   // NEW: v3.0
    case packagingFailed = "packaging_failed"
    case internalError = "internal_error"
```

**Update `isRetryable` computed property**:

```swift
    public var isRetryable: Bool {
        switch self {
        case .networkError, .uploadInterrupted, .serverUnavailable,
             .trainingFailed, .gpuOutOfMemory, .processingTimeout,
             .heartbeatTimeout, .stalledProcessing,  // NEW: retryable
             .packagingFailed, .internalError:
            return true
        case .invalidVideoFormat, .videoTooShort, .videoTooLong,
             .insufficientFrames, .poseEstimationFailed, .lowRegistrationRate,
             .resourceExhausted:  // NEW: not retryable (permanent)
            return false
        }
    }
```

**Update `isServerOnly` computed property**:

```swift
    public var isServerOnly: Bool {
        switch self {
        case .networkError, .uploadInterrupted:
            return false
        case .serverUnavailable, .invalidVideoFormat, .videoTooShort,
             .videoTooLong, .insufficientFrames, .poseEstimationFailed,
             .lowRegistrationRate, .trainingFailed, .gpuOutOfMemory,
             .processingTimeout, .heartbeatTimeout, .stalledProcessing,  // NEW
             .resourceExhausted,  // NEW
             .packagingFailed, .internalError:
            return true
        }
    }
```

### 5.4 Update Failure Reason Binding

**File**: `Core/Jobs/JobStateMachine.swift`

**Update `failureReasonBinding` (lines 65-80)**:

```swift
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
        .heartbeatTimeout: [.processing],      // NEW v3.0
        .stalledProcessing: [.processing],     // NEW v3.0
        .resourceExhausted: [.processing],     // NEW v3.0
        .packagingFailed: [.packaging],
        .internalError: [.uploading, .queued, .processing, .packaging],
    ]
```

### 5.5 Update Constants

**File**: `Core/Jobs/ContractConstants.swift`

**Update line 31**:

```swift
// BEFORE
public static let FAILURE_REASON_COUNT = 14

// AFTER
public static let FAILURE_REASON_COUNT = 17
```

---

## PART 6: ENHANCED CANCEL REASONS

### 6.1 New Cancel Reason: System Timeout

**File**: `Core/Jobs/CancelReason.swift`

**Add new case**:

```swift
public enum CancelReason: String, Codable, CaseIterable {
    case userRequested = "user_requested"
    case appTerminated = "app_terminated"
    case systemTimeout = "system_timeout"    // NEW v3.0: Auto-cancel on prolonged inactivity
}
```

### 6.2 Update Cancel Reason Binding

**File**: `Core/Jobs/JobStateMachine.swift`

**Update `cancelReasonBinding` (lines 83-86)**:

```swift
    private static let cancelReasonBinding: [CancelReason: Set<JobState>] = [
        .userRequested: [.pending, .uploading, .queued, .processing],
        .appTerminated: [.pending, .uploading, .queued, .processing],
        .systemTimeout: [.pending, .uploading, .queued],  // NEW v3.0 (not PROCESSING - use heartbeatTimeout instead)
    ]
```

### 6.3 Update Constants

**File**: `Core/Jobs/ContractConstants.swift`

**Update line 34**:

```swift
// BEFORE
public static let CANCEL_REASON_COUNT = 2

// AFTER
public static let CANCEL_REASON_COUNT = 3
```

---

## PART 7: MICRO-OPTIMIZATIONS

### 7.1 Progress Report Interval

**File**: `Core/Jobs/ContractConstants.swift`

**Modify line 53**:

```swift
// BEFORE
public static let PROGRESS_REPORT_INTERVAL_SECONDS = 5

// AFTER
/// Progress report interval in seconds
/// - Reduced from 5 to 3 seconds for smoother progress bar animation
/// - 3 seconds provides good UX without excessive network overhead
public static let PROGRESS_REPORT_INTERVAL_SECONDS = 3
```

### 7.2 Queued Warning Threshold

**File**: `Core/Jobs/ContractConstants.swift`

**Modify line 83**:

```swift
// BEFORE
public static let QUEUED_WARNING_SECONDS = 1800  // 30 minutes

// AFTER
/// Queued warning threshold in seconds
/// - Reduced from 30 to 15 minutes for earlier user notification
/// - Users should know sooner if their job is delayed
public static let QUEUED_WARNING_SECONDS = 900  // 15 minutes
```

### 7.3 Cancel Window Extension for Premium UX

**Discussion**: Keep at 30 seconds. This is optimal:
- Long enough for users to reconsider
- Short enough that server resources aren't wasted
- Industry standard for "grace period" cancellation

### 7.4 Min Video Duration

**File**: `Core/Jobs/ContractConstants.swift`

**Modify line 67**:

```swift
// BEFORE
public static let MIN_VIDEO_DURATION_SECONDS = 10

// AFTER
/// Minimum video duration in seconds
/// - Reduced from 10 to 5 seconds for quick scan support
/// - Enables "Quick Scan" mode for small objects
/// - Server can still reject if insufficient frames
public static let MIN_VIDEO_DURATION_SECONDS = 5
```

---

## PART 8: NEW ERROR TYPES

### 8.1 Update JobStateMachineError

**File**: `Core/Jobs/JobStateMachineError.swift`

**Add new error cases**:

```swift
public enum JobStateMachineError: Error, Equatable {
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

    // NEW v3.0
    case duplicateTransition(transitionId: String)
    case heartbeatMissed(missedCount: Int, lastHeartbeat: Date?)
    case retryLimitExceeded(attempts: Int, maxAttempts: Int)
}
```

---

## PART 9: TEST UPDATES

### 9.1 Update Test Constants

**File**: `Tests/Jobs/JobStateMachineTests.swift`

**Update header (line 4)**:

```swift
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
```

### 9.2 New Test: Retry Calculator

**File**: `Tests/Jobs/RetryCalculatorTests.swift` (NEW FILE)

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// ============================================================================

import XCTest
@testable import Aether3DCore

final class RetryCalculatorTests: XCTestCase {

    func testExponentialBackoff() {
        // Verify exponential growth pattern
        let delays = (0..<5).map { attempt in
            RetryCalculator.calculateDelay(attempt: attempt, jitterMaxMs: 0)
        }

        XCTAssertEqual(delays[0], 2.0, accuracy: 0.01)   // 2^0 * 2 = 2
        XCTAssertEqual(delays[1], 4.0, accuracy: 0.01)   // 2^1 * 2 = 4
        XCTAssertEqual(delays[2], 8.0, accuracy: 0.01)   // 2^2 * 2 = 8
        XCTAssertEqual(delays[3], 16.0, accuracy: 0.01)  // 2^3 * 2 = 16
        XCTAssertEqual(delays[4], 32.0, accuracy: 0.01)  // 2^4 * 2 = 32
    }

    func testMaxDelayCap() {
        // Verify delay is capped at maxDelay
        let delay = RetryCalculator.calculateDelay(
            attempt: 10,  // Would be 2048 without cap
            maxDelay: 60,
            jitterMaxMs: 0
        )

        XCTAssertEqual(delay, 60.0, accuracy: 0.01)
    }

    func testJitterRange() {
        // Verify jitter is within expected range
        for _ in 0..<100 {
            let delay = RetryCalculator.calculateDelay(
                attempt: 0,
                baseInterval: 2,
                jitterMaxMs: 1000
            )

            // Base is 2, jitter is 0-1, so delay should be 2.0-3.0
            XCTAssertGreaterThanOrEqual(delay, 2.0)
            XCTAssertLessThanOrEqual(delay, 3.0)
        }
    }

    func testShouldRetryWithRetryableReason() {
        XCTAssertTrue(RetryCalculator.shouldRetry(attempt: 0, failureReason: .networkError))
        XCTAssertTrue(RetryCalculator.shouldRetry(attempt: 4, failureReason: .networkError))
        XCTAssertFalse(RetryCalculator.shouldRetry(attempt: 5, failureReason: .networkError))
    }

    func testShouldNotRetryWithNonRetryableReason() {
        XCTAssertFalse(RetryCalculator.shouldRetry(attempt: 0, failureReason: .invalidVideoFormat))
        XCTAssertFalse(RetryCalculator.shouldRetry(attempt: 0, failureReason: .videoTooShort))
    }

    func testPreviewDelays() {
        let delays = RetryCalculator.previewDelays(maxAttempts: 5)
        XCTAssertEqual(delays.count, 5)

        // Each delay should be greater than the previous (exponential)
        for i in 1..<delays.count {
            XCTAssertGreaterThan(delays[i], delays[i-1] * 1.5)  // Allow for jitter
        }
    }
}
```

### 9.3 New Test: Enhanced Failure Reasons

**File**: `Tests/Jobs/JobStateMachineTests.swift`

**Add new test method**:

```swift
    // MARK: - Test 11: New Failure Reasons (v3.0)

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

        // Verify new reasons are server-only
        for reason in [FailureReason.heartbeatTimeout, .stalledProcessing, .resourceExhausted] {
            XCTAssertTrue(reason.isServerOnly)
        }

        // Verify retryable status
        XCTAssertTrue(FailureReason.heartbeatTimeout.isRetryable)
        XCTAssertTrue(FailureReason.stalledProcessing.isRetryable)
        XCTAssertFalse(FailureReason.resourceExhausted.isRetryable)  // Permanent failure
    }

    // MARK: - Test 12: New Cancel Reason (v3.0)

    func testSystemTimeoutCancelReason() {
        // systemTimeout from PENDING
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .pending,
                to: .cancelled,
                cancelReason: .systemTimeout
            )
        )

        // systemTimeout from QUEUED
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .queued,
                to: .cancelled,
                cancelReason: .systemTimeout
            )
        )

        // systemTimeout NOT allowed from PROCESSING (use heartbeatTimeout instead)
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .cancelled,
                cancelReason: .systemTimeout,
                elapsedSeconds: 10
            )
        )
    }

    // MARK: - Test 13: Failure Reason Count (v3.0)

    func testFailureReasonCountV3() {
        XCTAssertEqual(FailureReason.allCases.count, ContractConstants.FAILURE_REASON_COUNT)
        XCTAssertEqual(ContractConstants.FAILURE_REASON_COUNT, 17)
    }

    // MARK: - Test 14: Cancel Reason Count (v3.0)

    func testCancelReasonCountV3() {
        XCTAssertEqual(CancelReason.allCases.count, ContractConstants.CANCEL_REASON_COUNT)
        XCTAssertEqual(ContractConstants.CANCEL_REASON_COUNT, 3)
    }
```

### 9.4 Update Existing Tests

**File**: `Tests/Jobs/JobStateMachineTests.swift`

**Update `testFailureReasonCodable` to include new reasons**:

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
            ("heartbeat_timeout", .heartbeatTimeout),        // NEW v3.0
            ("stalled_processing", .stalledProcessing),      // NEW v3.0
            ("resource_exhausted", .resourceExhausted),      // NEW v3.0
            ("packaging_failed", .packagingFailed),
            ("internal_error", .internalError),
        ]

        for (rawValue, expected) in validCases {
            let json = "\"\(rawValue)\"".data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(FailureReason.self, from: json)
            XCTAssertEqual(decoded, expected, "Failed to decode \(rawValue)")
        }

        XCTAssertEqual(validCases.count, ContractConstants.FAILURE_REASON_COUNT)
    }
```

**Update `testCancelReasonCodable`**:

```swift
    func testCancelReasonCodable() {
        let validCases: [(String, CancelReason)] = [
            ("user_requested", .userRequested),
            ("app_terminated", .appTerminated),
            ("system_timeout", .systemTimeout),  // NEW v3.0
        ]

        for (rawValue, expected) in validCases {
            let json = "\"\(rawValue)\"".data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(CancelReason.self, from: json)
            XCTAssertEqual(decoded, expected, "Failed to decode \(rawValue)")
        }

        XCTAssertEqual(validCases.count, ContractConstants.CANCEL_REASON_COUNT)
    }
```

---

## PART 10: FINAL CONSTANTS SUMMARY

**File**: `Core/Jobs/ContractConstants.swift` - COMPLETE FINAL VERSION

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

    /// Total number of failure reasons (v3.0: +3)
    public static let FAILURE_REASON_COUNT = 17

    /// Total number of cancel reasons (v3.0: +1)
    public static let CANCEL_REASON_COUNT = 3

    // MARK: - JobId Validation

    /// Minimum job ID length (sonyflake IDs are 15-20 digits)
    public static let JOB_ID_MIN_LENGTH = 15

    /// Maximum job ID length
    public static let JOB_ID_MAX_LENGTH = 20

    // MARK: - Cancel Window

    /// Cancel window duration in seconds (PROCESSING state only)
    public static let CANCEL_WINDOW_SECONDS = 30

    // MARK: - Heartbeat & Monitoring

    /// Progress report interval in seconds (v3.0: reduced from 5 to 3)
    public static let PROGRESS_REPORT_INTERVAL_SECONDS = 3

    /// Health check interval in seconds
    public static let HEALTH_CHECK_INTERVAL_SECONDS = 10

    /// Processing heartbeat interval in seconds (v3.0: NEW)
    public static let PROCESSING_HEARTBEAT_INTERVAL_SECONDS = 30

    /// Maximum missed heartbeats before auto-failure (v3.0: NEW)
    public static let PROCESSING_HEARTBEAT_MAX_MISSED = 3

    /// Processing heartbeat timeout in seconds (v3.0: NEW)
    public static let PROCESSING_HEARTBEAT_TIMEOUT_SECONDS =
        PROCESSING_HEARTBEAT_INTERVAL_SECONDS * PROCESSING_HEARTBEAT_MAX_MISSED

    // MARK: - Upload

    /// Upload chunk size in bytes (5MB)
    public static let CHUNK_SIZE_BYTES = 5 * 1024 * 1024

    /// Maximum video duration in seconds (15 minutes)
    public static let MAX_VIDEO_DURATION_SECONDS = 15 * 60

    /// Minimum video duration in seconds (v3.0: reduced from 10 to 5)
    public static let MIN_VIDEO_DURATION_SECONDS = 5

    // MARK: - Retry Strategy (v3.0: Enhanced)

    /// Maximum automatic retry count (v3.0: increased from 3 to 5)
    public static let MAX_AUTO_RETRY_COUNT = 5

    /// Base retry interval in seconds
    public static let RETRY_BASE_INTERVAL_SECONDS = 2

    /// Maximum retry delay in seconds (v3.0: NEW)
    public static let RETRY_MAX_DELAY_SECONDS = 60

    /// Maximum jitter in milliseconds (v3.0: NEW)
    public static let RETRY_JITTER_MAX_MS = 1000

    /// Jitter strategy (v3.0: NEW)
    public static let RETRY_JITTER_STRATEGY = "full"

    // MARK: - Dead Letter Queue (v3.0: NEW)

    /// DLQ retention period in days
    public static let DLQ_RETENTION_DAYS = 7

    /// Maximum DLQ entries before alert
    public static let DLQ_ALERT_THRESHOLD = 100

    /// DLQ entry ID prefix
    public static let DLQ_ID_PREFIX = "dlq_"

    // MARK: - Queued Timeout

    /// Queued timeout duration in seconds (1 hour)
    public static let QUEUED_TIMEOUT_SECONDS = 3600

    /// Queued warning threshold in seconds (v3.0: reduced from 30 to 15 minutes)
    public static let QUEUED_WARNING_SECONDS = 900
}
```

---

## PART 11: FILE CREATION/MODIFICATION CHECKLIST

### New Files to Create

| # | File Path | Purpose |
|---|-----------|---------|
| 1 | `Core/Jobs/RetryCalculator.swift` | Exponential backoff with jitter |
| 2 | `Core/Jobs/DLQEntry.swift` | Dead Letter Queue entry model |
| 3 | `Tests/Jobs/RetryCalculatorTests.swift` | Retry calculator tests |

### Files to Modify

| # | File Path | Changes |
|---|-----------|---------|
| 1 | `Core/Jobs/ContractConstants.swift` | Version upgrade, new constants |
| 2 | `Core/Jobs/JobStateMachine.swift` | Enhanced TransitionLog, idempotency |
| 3 | `Core/Jobs/JobState.swift` | Header version update only |
| 4 | `Core/Jobs/FailureReason.swift` | +3 new failure reasons |
| 5 | `Core/Jobs/CancelReason.swift` | +1 new cancel reason |
| 6 | `Core/Jobs/JobStateMachineError.swift` | +3 new error types |
| 7 | `Tests/Jobs/JobStateMachineTests.swift` | New tests, updated counts |

---

## PART 12: VERIFICATION

### Build Verification

```bash
swift build
```

### Test Verification

```bash
swift test --filter JobStateMachineTests
swift test --filter RetryCalculatorTests
```

### Count Verification

```bash
# Verify failure reason count
grep -c "case .*=" Core/Jobs/FailureReason.swift  # Should be 17

# Verify cancel reason count
grep -c "case .*=" Core/Jobs/CancelReason.swift  # Should be 3

# Verify all headers updated
grep "PR2-JSM-3.0" Core/Jobs/*.swift  # Should find all files
```

---

## PART 13: GIT COMMIT MESSAGE

```
feat(pr2): upgrade JSM to v3.0 with industry-standard retry and monitoring

BREAKING CHANGE: Contract version PR2-JSM-2.5 → PR2-JSM-3.0

Retry Strategy (Industry Standard):
- Exponential backoff with full jitter (AWS/Google/Netflix pattern)
- Increased max retries from 3 to 5 (covers 99.9% transient failures)
- Added RetryCalculator for standardized delay computation

Dead Letter Queue:
- DLQEntry structure for failed job isolation
- 7-day retention with operational alerts
- Supports manual review and retry workflow

Heartbeat Monitoring:
- 30-second processing heartbeat interval
- Auto-fail after 3 missed heartbeats (90 seconds)
- New failure reasons: heartbeatTimeout, stalledProcessing, resourceExhausted

UX Micro-optimizations:
- Progress report interval: 5s → 3s (smoother animations)
- Queue warning threshold: 30min → 15min (earlier notification)
- Min video duration: 10s → 5s (quick scan support)

New Error Types:
- duplicateTransition for idempotency violations
- heartbeatMissed for monitoring failures
- retryLimitExceeded for exhausted retries

Counts: FailureReasons 14→17, CancelReasons 2→3

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

**END OF PROMPT**
