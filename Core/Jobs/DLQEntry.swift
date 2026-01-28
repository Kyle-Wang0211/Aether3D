// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
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
