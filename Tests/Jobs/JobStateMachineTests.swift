// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5
// States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
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
}

