// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5 (PR1 C-Class: +1 state CAPACITY_SATURATED)
// States: 9 | Transitions: 14 | FailureReasons: 14 | CancelReasons: 2
// ============================================================================

import Foundation

/// Job state enumeration (9 states, PR1 C-Class adds CAPACITY_SATURATED).
public enum JobState: String, Codable, CaseIterable {
    case pending = "pending"
    case uploading = "uploading"
    case queued = "queued"
    case processing = "processing"
    case packaging = "packaging"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case capacitySaturated = "capacity_saturated"  // PR1 C-Class: terminal non-error state
    
    /// Whether this state is a terminal state (no further transitions allowed).
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .capacitySaturated:
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
        case .processing, .packaging, .completed, .failed, .cancelled, .capacitySaturated:
            return false
        }
    }
}

