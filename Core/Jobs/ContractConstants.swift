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
    /// - PROCESSING → CANCELLED is only allowed within 30 seconds
    public static let CANCEL_WINDOW_SECONDS = 30
    
    // MARK: - Heartbeat & Monitoring
    
    /// Progress report interval in seconds (v3.0: reduced from 5 to 3)
    /// Research: 3s provides smooth animation without battery impact
    /// Reference: Nielsen Norman Group response time limits
    public static let PROGRESS_REPORT_INTERVAL_SECONDS = 3
    
    /// Health check interval in seconds
    public static let HEALTH_CHECK_INTERVAL_SECONDS = 10
    
    /// Processing heartbeat interval in seconds (v3.0: NEW)
    /// - Server must receive heartbeat within this interval
    /// - 30 seconds balances network latency and detection speed
    public static let PROCESSING_HEARTBEAT_INTERVAL_SECONDS = 30
    
    /// Maximum missed heartbeats before auto-failure (v3.0: NEW)
    /// - 3 missed heartbeats = 90 seconds of silence
    /// - Provides grace period for network issues
    public static let PROCESSING_HEARTBEAT_MAX_MISSED = 3
    
    /// Processing heartbeat timeout in seconds (computed) (v3.0: NEW)
    /// - Auto-fail if no heartbeat for this duration
    /// - 30 × 3 = 90 seconds
    public static let PROCESSING_HEARTBEAT_TIMEOUT_SECONDS =
        PROCESSING_HEARTBEAT_INTERVAL_SECONDS * PROCESSING_HEARTBEAT_MAX_MISSED
    
    // MARK: - Upload
    
    /// Upload chunk size in bytes (5MB)
    public static let CHUNK_SIZE_BYTES = 5 * 1024 * 1024
    
    /// Maximum video duration in seconds (15 minutes)
    public static let MAX_VIDEO_DURATION_SECONDS = 15 * 60
    
    /// Minimum video duration in seconds (v3.0: reduced from 10 to 5)
    /// - Reduced from 10 to 5 seconds for quick scan support
    /// - Enables "Quick Scan" mode for small objects
    /// - Server can still reject if insufficient frames
    public static let MIN_VIDEO_DURATION_SECONDS = 5
    
    // MARK: - Retry Strategy (Enhanced v3.0)
    
    /// Maximum automatic retry count (v3.0: increased from 3 to 5)
    /// - Increased from 3 to 5 for better resilience against transient failures
    /// - Studies show 5 retries covers 99.9% of recoverable transient errors
    public static let MAX_AUTO_RETRY_COUNT = 5
    
    /// Base retry interval in seconds (exponential backoff base)
    /// - Kept at 2 seconds for quick first retry
    public static let RETRY_BASE_INTERVAL_SECONDS = 2
    
    /// Maximum retry delay in seconds (cap for exponential backoff) (v3.0: NEW)
    /// - 60 seconds max prevents excessive wait times
    /// - After 5 retries: 2→4→8→16→32 (capped before 64)
    public static let RETRY_MAX_DELAY_SECONDS = 60
    
    /// Maximum jitter in milliseconds (v3.0: NEW)
    /// - Random jitter prevents thundering herd
    /// - 1000ms (1 second) provides sufficient distribution
    public static let RETRY_JITTER_MAX_MS = 1000
    
    /// Jitter strategy: "full", "equal", or "decorrelated" (v3.0: NEW)
    /// - "full": random(0, jitterMax) - AWS recommendation
    /// - "equal": delay/2 + random(0, delay/2) - Google recommendation
    /// - "decorrelated": min(cap, random(base, previousDelay * 3)) - Netflix/AWS recommended for high-concurrency
    public static let RETRY_JITTER_STRATEGY = "decorrelated"
    
    /// Decorrelated jitter multiplier (previousDelay * 3) (v3.0: NEW)
    public static let RETRY_DECORRELATED_MULTIPLIER: Double = 3.0
    
    // MARK: - Dead Letter Queue (DLQ) (v3.0: NEW)
    
    /// DLQ retention period in days
    /// - 7 days provides sufficient time for manual review
    /// - After 7 days, entries may be purged (but logged permanently)
    public static let DLQ_RETENTION_DAYS = 7
    
    /// Maximum DLQ entries before alert
    /// - Triggers operational alert when exceeded
    public static let DLQ_ALERT_THRESHOLD = 100
    
    /// DLQ entry ID prefix
    public static let DLQ_ID_PREFIX = "dlq_"
    
    // MARK: - Queued Timeout
    
    /// Queued timeout duration in seconds (1 hour)
    public static let QUEUED_TIMEOUT_SECONDS = 3600
    
    /// Queued warning threshold in seconds (v3.0: reduced from 30 to 15 minutes)
    /// - Reduced from 30 to 15 minutes for earlier user notification
    /// - Users should know sooner if their job is delayed
    public static let QUEUED_WARNING_SECONDS = 900
    
    // MARK: - Circuit Breaker (v3.0: NEW)
    
    /// Circuit breaker failure threshold
    public static let CIRCUIT_BREAKER_FAILURE_THRESHOLD = 5
    
    /// Circuit breaker success threshold (half-open → closed)
    public static let CIRCUIT_BREAKER_SUCCESS_THRESHOLD = 3
    
    /// Circuit breaker open timeout in seconds
    public static let CIRCUIT_BREAKER_OPEN_TIMEOUT_SECONDS: Double = 30.0
    
    /// Circuit breaker sliding window size
    public static let CIRCUIT_BREAKER_SLIDING_WINDOW_SIZE = 10
    
    // MARK: - Progress Feedback (Psychologically Optimized) (v3.0: NEW)
    
    /// Minimum progress increment to report (avoid micro-updates)
    /// Users notice changes >=2%, smaller increments feel stagnant
    public static let MIN_PROGRESS_INCREMENT_PERCENT: Double = 2.0
    
    /// Initial progress boost (show immediate response)
    /// Research: Users feel faster when initial progress is visible
    public static let INITIAL_PROGRESS_BOOST_PERCENT: Double = 5.0
    
    /// Progress slowdown threshold (slow down near completion)
    /// Research: Perceived speed increases if progress slows at 90%+
    public static let PROGRESS_SLOWDOWN_THRESHOLD_PERCENT: Double = 90.0
    
    // MARK: - Bulkhead Pattern (Resource Isolation) (v3.0: NEW)
    
    /// Maximum concurrent transitions per job type
    public static let MAX_CONCURRENT_UPLOADS = 3
    
    /// Maximum concurrent processing jobs
    public static let MAX_CONCURRENT_PROCESSING = 5
    
    /// Queue overflow threshold (reject new jobs)
    public static let QUEUE_OVERFLOW_THRESHOLD = 100
    
    // MARK: - Graceful Degradation Fallbacks (v3.0: NEW)
    
    /// Default ETA when estimation unavailable (seconds)
    public static let FALLBACK_ETA_SECONDS: TimeInterval = 120.0
    
    /// Cached progress value when network unavailable
    public static let FALLBACK_PROGRESS_STALE_THRESHOLD_SECONDS: TimeInterval = 30.0
    
    /// Message to show when degraded
    public static let FALLBACK_MESSAGE_KEY = "job.progress.degraded"
    
    // MARK: - Date Formatting (Cross-Platform) (v3.0: NEW)
    
    /// ISO8601 date format with milliseconds and UTC timezone
    /// Example: "2024-01-15T10:30:45.123Z"
    public static let ISO8601_FORMAT = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    
    /// Timezone identifier for all timestamps
    public static let TIMESTAMP_TIMEZONE = "UTC"
}

