// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class JobStateMachineTests: XCTestCase {
    
    // MARK: - Test Constants
    
    private let validJobId = "12345678901234567"  // 17 digits
    
    // MARK: - Test 1: All State Pairs (64 combinations)
    
    func testAllStatePairs() {
        var legalCount = 0
        var illegalCount = 0
        
        for from in JobState.allCases {
            for to in JobState.allCases {
                if from.isTerminal {
                    // From terminal state: must throw alreadyTerminal (priority over illegalTransition)
                    XCTAssertThrowsError(
                        try JobStateMachine.transition(jobId: validJobId, from: from, to: to)
                    ) { error in
                        guard case JobStateMachineError.alreadyTerminal = error else {
                            XCTFail("Expected alreadyTerminal for \(from)->\(to), got \(error)")
                            return
                        }
                    }
                    illegalCount += 1
                } else if from == to {
                    // Self-transition (non-terminal): must throw illegalTransition
                    XCTAssertThrowsError(
                        try JobStateMachine.transition(jobId: validJobId, from: from, to: to)
                    ) { error in
                        guard case JobStateMachineError.illegalTransition = error else {
                            XCTFail("Expected illegalTransition for self-transition \(from)->\(to), got \(error)")
                            return
                        }
                    }
                    illegalCount += 1
                } else if JobStateMachine.canTransition(from: from, to: to) {
                    // Legal transition: will be tested in specific test methods
                    legalCount += 1
                } else {
                    // Illegal transition: must throw illegalTransition
                    XCTAssertThrowsError(
                        try JobStateMachine.transition(jobId: validJobId, from: from, to: to)
                    ) { error in
                        guard case JobStateMachineError.illegalTransition = error else {
                            XCTFail("Expected illegalTransition for \(from)->\(to), got \(error)")
                            return
                        }
                    }
                    illegalCount += 1
                }
            }
        }
        
        // Verify counts
        XCTAssertEqual(legalCount, ContractConstants.LEGAL_TRANSITION_COUNT, "Legal transition count must match")
        XCTAssertEqual(illegalCount, ContractConstants.ILLEGAL_TRANSITION_COUNT, "Illegal transition count must match")
        XCTAssertEqual(legalCount + illegalCount, ContractConstants.TOTAL_STATE_PAIRS, "Total state pairs must match")
    }
    
    // MARK: - Test 2: Cancel Window Boundary (30 seconds)
    
    func testCancelWindowBoundary() {
        // Exactly 30 seconds: should succeed
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .cancelled,
                cancelReason: .userRequested,
                elapsedSeconds: 30
            )
        )
        
        // 31 seconds: should fail
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .cancelled,
                cancelReason: .userRequested,
                elapsedSeconds: 31
            )
        ) { error in
            guard case JobStateMachineError.cancelWindowExpired(let elapsed) = error else {
                XCTFail("Expected cancelWindowExpired, got \(error)")
                return
            }
            XCTAssertEqual(elapsed, 31)
        }
        
        // 29 seconds: should succeed
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .cancelled,
                cancelReason: .userRequested,
                elapsedSeconds: 29
            )
        )
        
        // Missing elapsedSeconds for PROCESSING → CANCELLED: should fail
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .cancelled,
                cancelReason: .userRequested,
                elapsedSeconds: nil
            )
        ) { error in
            guard case JobStateMachineError.cancelWindowExpired(let elapsed) = error else {
                XCTFail("Expected cancelWindowExpired for nil elapsedSeconds, got \(error)")
                return
            }
            XCTAssertEqual(elapsed, -1)
        }
    }
    
    // MARK: - Test 3: Error Priority Order
    
    func testErrorPriorityOrder() {
        // Empty jobId should have highest priority (even over terminal state check)
        XCTAssertThrowsError(
            try JobStateMachine.transition(jobId: "", from: .completed, to: .failed)
        ) { error in
            guard case JobStateMachineError.emptyJobId = error else {
                XCTFail("emptyJobId should have highest priority, got \(error)")
                return
            }
        }
        
        // alreadyTerminal should come before illegalTransition
        XCTAssertThrowsError(
            try JobStateMachine.transition(jobId: validJobId, from: .completed, to: .pending)
        ) { error in
            guard case JobStateMachineError.alreadyTerminal = error else {
                XCTFail("alreadyTerminal should come before illegalTransition, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Test 4: JobId Boundary Conditions
    
    func testJobIdBoundary() {
        // 14 digits: too short
        XCTAssertThrowsError(
            try JobStateMachine.transition(jobId: "12345678901234", from: .pending, to: .uploading)
        ) { error in
            guard case JobStateMachineError.jobIdTooShort(let length) = error else {
                XCTFail("Expected jobIdTooShort, got \(error)")
                return
            }
            XCTAssertEqual(length, 14)
        }
        
        // 15 digits: valid (minimum)
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: "123456789012345",
                from: .pending,
                to: .uploading,
                cancelReason: .userRequested
            )
        )
        
        // 20 digits: valid (maximum)
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: "12345678901234567890",
                from: .pending,
                to: .uploading,
                cancelReason: .userRequested
            )
        )
        
        // 21 digits: too long
        XCTAssertThrowsError(
            try JobStateMachine.transition(jobId: "123456789012345678901", from: .pending, to: .uploading)
        ) { error in
            guard case JobStateMachineError.jobIdTooLong(let length) = error else {
                XCTFail("Expected jobIdTooLong, got \(error)")
                return
            }
            XCTAssertEqual(length, 21)
        }
        
        // Invalid characters
        XCTAssertThrowsError(
            try JobStateMachine.transition(jobId: "12345678901234a", from: .pending, to: .uploading)
        ) { error in
            guard case JobStateMachineError.jobIdInvalidCharacters(let index) = error else {
                XCTFail("Expected jobIdInvalidCharacters, got \(error)")
                return
            }
            XCTAssertEqual(index, 14)
        }
    }
    
    // MARK: - Test 5: Failure Reason Binding
    
    func testFailureReasonBinding() {
        // Valid: networkError from UPLOADING
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .uploading,
                to: .failed,
                failureReason: .networkError
            )
        )
        
        // Invalid: networkError from QUEUED (not allowed)
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .queued,
                to: .failed,
                failureReason: .networkError
            )
        ) { error in
            guard case JobStateMachineError.invalidFailureReason(let reason, let fromState) = error else {
                XCTFail("Expected invalidFailureReason, got \(error)")
                return
            }
            XCTAssertEqual(reason, .networkError)
            XCTAssertEqual(fromState, .queued)
        }
        
        // Missing failure reason for FAILED state
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .uploading,
                to: .failed,
                failureReason: nil
            )
        ) { error in
            guard case JobStateMachineError.invalidFailureReason = error else {
                XCTFail("Expected invalidFailureReason for missing reason, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Test 6: Cancel Reason Binding
    
    func testCancelReasonBinding() {
        // Valid: userRequested from PENDING
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .pending,
                to: .cancelled,
                cancelReason: .userRequested
            )
        )
        
        // Valid: appTerminated from UPLOADING
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .uploading,
                to: .cancelled,
                cancelReason: .appTerminated
            )
        )
        
        // Missing cancel reason for CANCELLED state
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .pending,
                to: .cancelled,
                cancelReason: nil
            )
        ) { error in
            guard case JobStateMachineError.invalidCancelReason = error else {
                XCTFail("Expected invalidCancelReason for missing reason, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Test 7: Server-Only Failure Reason
    
    func testServerOnlyFailureReason() {
        // Client-side attempt with serverOnly reason: should fail
        XCTAssertThrowsError(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .failed,
                failureReason: .gpuOutOfMemory,
                isServerSide: false
            )
        ) { error in
            guard case JobStateMachineError.serverOnlyFailureReason(let reason) = error else {
                XCTFail("Expected serverOnlyFailureReason, got \(error)")
                return
            }
            XCTAssertEqual(reason, .gpuOutOfMemory)
        }
        
        // Server-side with serverOnly reason: should succeed
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .processing,
                to: .failed,
                failureReason: .gpuOutOfMemory,
                isServerSide: true
            )
        )
        
        // Client-side with non-serverOnly reason: should succeed
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                jobId: validJobId,
                from: .uploading,
                to: .failed,
                failureReason: .networkError,
                isServerSide: false
            )
        )
    }
    
    // MARK: - Test 8: Codable Encoding/Decoding
    
    func testJobStateCodable() {
        let validCases: [(String, JobState)] = [
            ("pending", .pending),
            ("uploading", .uploading),
            ("queued", .queued),
            ("processing", .processing),
            ("packaging", .packaging),
            ("completed", .completed),
            ("failed", .failed),
            ("cancelled", .cancelled),
            ("capacity_saturated", .capacitySaturated),  // PR1 C-Class
        ]
        
        for (rawValue, expected) in validCases {
            let json = "\"\(rawValue)\"".data(using: .utf8)!
            let decoded = try! JSONDecoder().decode(JobState.self, from: json)
            XCTAssertEqual(decoded, expected, "Failed to decode \(rawValue)")
        }
        
        XCTAssertEqual(validCases.count, ContractConstants.STATE_COUNT)
    }
    
    func testInvalidJobStateDecodingFails() {
        let invalidValues = ["PENDING", "Pending", "unknown", "", "null", "0"]
        
        for invalid in invalidValues {
            let json = "\"\(invalid)\"".data(using: .utf8)!
            XCTAssertThrowsError(
                try JSONDecoder().decode(JobState.self, from: json),
                "Should fail for invalid value: \(invalid)"
            )
        }
    }
    
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
    
    // MARK: - Test 9: Terminal State Protection
    
    func testTerminalStateProtection() {
        let terminalStates: [JobState] = [.completed, .failed, .cancelled]
        
        for terminalState in terminalStates {
            // Try to transition from terminal state to any other state
            for targetState in JobState.allCases where targetState != terminalState {
                XCTAssertThrowsError(
                    try JobStateMachine.transition(jobId: validJobId, from: terminalState, to: targetState)
                ) { error in
                    guard case JobStateMachineError.alreadyTerminal(let currentState) = error else {
                        XCTFail("Expected alreadyTerminal for \(terminalState)->\(targetState), got \(error)")
                        return
                    }
                    XCTAssertEqual(currentState, terminalState)
                }
            }
        }
    }
    
    // MARK: - Test 10: Legal Transitions
    
    func testLegalTransitions() {
        // Test each legal transition with appropriate reasons
        let legalTests: [(JobState, JobState, FailureReason?, CancelReason?, Int?)] = [
            (.pending, .uploading, nil, nil, nil),
            (.pending, .cancelled, nil, .userRequested, nil),
            (.uploading, .queued, nil, nil, nil),
            (.uploading, .failed, .networkError, nil, nil),
            (.uploading, .cancelled, nil, .userRequested, nil),
            (.queued, .processing, nil, nil, nil),
            (.queued, .failed, .serverUnavailable, nil, nil),
            (.queued, .cancelled, nil, .userRequested, nil),
            (.processing, .packaging, nil, nil, nil),
            (.processing, .failed, .trainingFailed, nil, nil),
            (.processing, .cancelled, nil, .userRequested, 30),
            (.packaging, .completed, nil, nil, nil),
            (.packaging, .failed, .packagingFailed, nil, nil),
        ]
        
        for (from, to, failureReason, cancelReason, elapsedSeconds) in legalTests {
            XCTAssertNoThrow(
                try JobStateMachine.transition(
                    jobId: validJobId,
                    from: from,
                    to: to,
                    failureReason: failureReason,
                    cancelReason: cancelReason,
                    elapsedSeconds: elapsedSeconds,
                    isServerSide: true
                )
            )
        }
    }
    
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
    
    // MARK: - Test 15: Idempotency Check (v3.0)
    
    func testIdempotencyCheck() {
        var executedTransitionIds: Set<String> = []
        
        let idempotencyCheck: (String) -> Bool = { transitionId in
            if executedTransitionIds.contains(transitionId) {
                return true  // Already executed
            }
            executedTransitionIds.insert(transitionId)
            return false  // Not executed yet
        }
        
        let transitionId = UUID().uuidString
        
        // First call should succeed
        XCTAssertNoThrow(
            try JobStateMachine.transition(
                transitionId: transitionId,
                jobId: validJobId,
                from: .pending,
                to: .uploading,
                idempotencyCheck: idempotencyCheck
            )
        )
        
        // Second call with same transitionId should return current state (idempotent)
        let result = try! JobStateMachine.transition(
            transitionId: transitionId,
            jobId: validJobId,
            from: .uploading,  // Current state after first transition
            to: .queued,
            idempotencyCheck: idempotencyCheck
        )
        
        // Should return current state, not perform transition
        XCTAssertEqual(result, .uploading)
    }
    
    // MARK: - Test 16: Enhanced TransitionLog Fields (v3.0)
    
    func testEnhancedTransitionLog() {
        var loggedTransition: TransitionLog?
        
        try! JobStateMachine.transition(
            jobId: validJobId,
            from: .pending,
            to: .uploading,
            retryAttempt: 2,
            source: .server,
            sessionId: "test-session-123",
            deviceState: .foreground,
            logger: { log in
                loggedTransition = log
            }
        )
        
        XCTAssertNotNil(loggedTransition)
        XCTAssertNotNil(loggedTransition?.transitionId)
        XCTAssertEqual(loggedTransition?.retryAttempt, 2)
        XCTAssertEqual(loggedTransition?.source, .server)
        XCTAssertEqual(loggedTransition?.sessionId, "test-session-123")
        XCTAssertEqual(loggedTransition?.deviceState, .foreground)
    }
}

