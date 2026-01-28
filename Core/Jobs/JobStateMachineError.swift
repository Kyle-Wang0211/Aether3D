// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Job state machine error types.
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

