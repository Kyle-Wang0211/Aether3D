// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5 (PR1 C-Class: +1 state CAPACITY_SATURATED)
// States: 9 | Transitions: 14 | FailureReasons: 14 | CancelReasons: 2
// ============================================================================

import Foundation

/// Contract constants for PR#2 Job State Machine (SSOT).
public enum ContractConstants {
    // MARK: - Version
    
    /// Contract version identifier
    public static let CONTRACT_VERSION = "PR2-JSM-2.5"
    
    // MARK: - Counts (MUST match actual enum counts)
    
    /// Total number of job states (PR1 C-Class: +1 for CAPACITY_SATURATED)
    public static let STATE_COUNT = 9
    
    /// Number of legal state transitions (PR1 C-Class: +1 for PROCESSING -> CAPACITY_SATURATED)
    public static let LEGAL_TRANSITION_COUNT = 14
    
    /// Number of illegal state transitions (9 × 9 - 14 = 67)
    public static let ILLEGAL_TRANSITION_COUNT = 67
    
    /// Total number of possible state pairs (9 × 9 = 81)
    public static let TOTAL_STATE_PAIRS = 81
    
    /// Total number of failure reasons
    public static let FAILURE_REASON_COUNT = 14
    
    /// Total number of cancel reasons
    public static let CANCEL_REASON_COUNT = 2
    
    // MARK: - JobId Validation
    
    /// Minimum job ID length (sonyflake IDs are 15-20 digits)
    public static let JOB_ID_MIN_LENGTH = 15
    
    /// Maximum job ID length
    public static let JOB_ID_MAX_LENGTH = 20
    
    // MARK: - Cancel Window
    
    /// Cancel window duration in seconds (PROCESSING state only)
    /// - PROCESSING → CANCELLED is only allowed within 30 seconds
    public static let CANCEL_WINDOW_SECONDS = 30
    
    // MARK: - Progress Report
    
    /// Progress report interval in seconds
    public static let PROGRESS_REPORT_INTERVAL_SECONDS = 5
    
    /// Health check interval in seconds
    public static let HEALTH_CHECK_INTERVAL_SECONDS = 10
    
    // MARK: - Upload
    
    /// Upload chunk size in bytes (5MB)
    public static let CHUNK_SIZE_BYTES = 5 * 1024 * 1024
    
    /// Maximum video duration in seconds (15 minutes)
    public static let MAX_VIDEO_DURATION_SECONDS = 15 * 60
    
    /// Minimum video duration in seconds
    public static let MIN_VIDEO_DURATION_SECONDS = 10
    
    // MARK: - Retry
    
    /// Maximum automatic retry count
    public static let MAX_AUTO_RETRY_COUNT = 3
    
    /// Base retry interval in seconds (exponential backoff: 2s → 4s → 8s)
    public static let RETRY_BASE_INTERVAL_SECONDS = 2
    
    // MARK: - Queued Timeout
    
    /// Queued timeout duration in seconds (1 hour)
    public static let QUEUED_TIMEOUT_SECONDS = 3600
    
    /// Queued warning threshold in seconds (30 minutes)
    public static let QUEUED_WARNING_SECONDS = 1800
}

