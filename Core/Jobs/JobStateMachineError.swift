// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5
// States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
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
}

