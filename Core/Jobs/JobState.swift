// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Job state enumeration (8 states).
public enum JobState: String, Codable, CaseIterable {
    case pending = "pending"
    case uploading = "uploading"
    case queued = "queued"
    case processing = "processing"
    case packaging = "packaging"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    
    /// Whether this state is a terminal state (no further transitions allowed).
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .pending, .uploading, .queued, .processing, .packaging:
            return false
        }
    }
    
    /// Whether this state is always cancellable.
    /// - Note: PROCESSING has conditional cancellability (30-second window).
    public var isCancellable: Bool {
        switch self {
        case .pending, .uploading, .queued:
            return true
        case .processing, .packaging, .completed, .failed, .cancelled:
            return false
        }
    }
}

