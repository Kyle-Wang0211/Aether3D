// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Source of state transition.
public enum TransitionSource: String, Codable {
    case client = "client"       // Mobile app initiated
    case server = "server"       // Backend initiated
    case system = "system"       // Automatic (timeout, heartbeat failure)
}

/// Device state enumeration.
public enum DeviceState: String, Codable {
    case foreground
    case background
    case lowPower
    case networkConstrained
}

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
    
    /// Session ID for correlating transitions within a user session
    public let sessionId: String?
    
    /// Device state at transition time
    public let deviceState: DeviceState?
    
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
        source: TransitionSource = .client,
        sessionId: String? = nil,
        deviceState: DeviceState? = nil
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
        self.sessionId = sessionId
        self.deviceState = deviceState
    }
}

/// Job state machine (pure function implementation).
public final class JobStateMachine {
    
    /// Internal transition structure.
    private struct Transition: Hashable {
        let from: JobState
        let to: JobState
    }
    
    /// Legal transitions (15 total: PR1 adds PROCESSING->CAPACITY_SATURATED, PR2 adds PACKAGING->CAPACITY_SATURATED).
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
        Transition(from: .processing, to: .capacitySaturated),  // PR1 C-Class: capacity saturated transition
        Transition(from: .packaging, to: .completed),
        Transition(from: .packaging, to: .failed),
        Transition(from: .packaging, to: .capacitySaturated),   // PR2: packaging can also saturate capacity
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
        .heartbeatTimeout: [.processing],      // NEW v3.0
        .stalledProcessing: [.processing],     // NEW v3.0
        .resourceExhausted: [.processing],     // NEW v3.0
        .packagingFailed: [.packaging],
        .internalError: [.uploading, .queued, .processing, .packaging],
    ]
    
    /// Cancel reason binding map (which reasons are allowed from which states).
    private static let cancelReasonBinding: [CancelReason: Set<JobState>] = [
        .userRequested: [.pending, .uploading, .queued, .processing],
        .appTerminated: [.pending, .uploading, .queued, .processing],
        .systemTimeout: [.pending, .uploading, .queued],  // NEW v3.0 (not PROCESSING - use heartbeatTimeout instead)
    ]
    
    // MARK: - Public Methods
    
    /// Check if a transition is legal (does not include 30-second window check).
    /// - Parameters:
    ///   - from: Source state
    ///   - to: Target state
    /// - Returns: True if transition is legal
    public static func canTransition(from: JobState, to: JobState) -> Bool {
        guard from != to else { return false }
        return legalTransitions.contains(Transition(from: from, to: to))
    }
    
    /// Validate job ID format (15-20 digit string).
    /// - Parameter jobId: Job ID to validate
    /// - Throws: JobStateMachineError if validation fails
    private static func validateJobId(_ jobId: String) throws {
        // 1. Check empty
        guard !jobId.isEmpty else {
            throw JobStateMachineError.emptyJobId
        }
        
        // 2. Check length
        guard jobId.count >= ContractConstants.JOB_ID_MIN_LENGTH else {
            throw JobStateMachineError.jobIdTooShort(length: jobId.count)
        }
        guard jobId.count <= ContractConstants.JOB_ID_MAX_LENGTH else {
            throw JobStateMachineError.jobIdTooLong(length: jobId.count)
        }
        
        // 3. Check characters (only digits allowed)
        for (index, char) in jobId.enumerated() {
            if !char.isNumber {
                throw JobStateMachineError.jobIdInvalidCharacters(firstInvalidIndex: index)
            }
        }
    }
    
    /// Validate failure reason is allowed from source state.
    /// - Parameters:
    ///   - reason: Failure reason
    ///   - from: Source state
    /// - Returns: True if valid
    private static func isValidFailureReason(_ reason: FailureReason, from: JobState) -> Bool {
        guard let allowedStates = failureReasonBinding[reason] else {
            return false
        }
        return allowedStates.contains(from)
    }
    
    /// Validate cancel reason is allowed from source state.
    /// - Parameters:
    ///   - reason: Cancel reason
    ///   - from: Source state
    /// - Returns: True if valid
    private static func isValidCancelReason(_ reason: CancelReason, from: JobState) -> Bool {
        guard let allowedStates = cancelReasonBinding[reason] else {
            return false
        }
        return allowedStates.contains(from)
    }
    
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
    ///   - sessionId: Session ID for correlating transitions
    ///   - deviceState: Device state at transition time
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
        sessionId: String? = nil,
        deviceState: DeviceState? = nil,
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
            source: source,
            sessionId: sessionId,
            deviceState: deviceState
        ))
        
        return to
    }
    
    /// Async transition with cancellation support (Swift 6 compatible)
    /// Reference: https://developer.apple.com/documentation/swift/task/iscancelled
    @available(macOS 10.15, iOS 13.0, *)
    public static func transitionAsync(
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
        sessionId: String? = nil,
        deviceState: DeviceState? = nil,
        idempotencyCheck: ((String) -> Bool)? = nil,
        logger: ((TransitionLog) -> Void)? = nil
    ) async throws -> JobState {
        // Check for task cancellation before expensive operations
        try Task.checkCancellation()
        
        // Perform synchronous validation
        let result = try transition(
            transitionId: transitionId,
            jobId: jobId,
            from: from,
            to: to,
            failureReason: failureReason,
            cancelReason: cancelReason,
            elapsedSeconds: elapsedSeconds,
            isServerSide: isServerSide,
            retryAttempt: retryAttempt,
            source: source,
            sessionId: sessionId,
            deviceState: deviceState,
            idempotencyCheck: idempotencyCheck,
            logger: logger
        )
        
        // Check again after operation
        try Task.checkCancellation()
        
        return result
    }
}

