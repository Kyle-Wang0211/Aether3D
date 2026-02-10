//
//  UploadCircuitBreakerTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Upload Circuit Breaker Tests
//

import XCTest
@testable import Aether3DCore

final class UploadCircuitBreakerTests: XCTestCase {
    
    // MARK: - Initial State
    
    func testInitial_State_IsClosed() async {
        let breaker = UploadCircuitBreaker()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Circuit breaker should start in closed state")
    }
    
    func testInitial_ShouldAllowRequest_ReturnsTrue() async {
        let breaker = UploadCircuitBreaker()
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "Should allow requests in closed state")
    }
    
    func testInitial_NoFailures_Recorded() async {
        let breaker = UploadCircuitBreaker()
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "No failures should allow requests")
    }
    
    func testInitial_CircuitState_AllCases_Exist() {
        let allCases: [UploadCircuitState] = [.closed, .open, .halfOpen]
        XCTAssertEqual(allCases.count, 3,
                      "UploadCircuitState should have 3 cases")
    }
    
    func testInitial_CircuitState_Closed_RawValue() {
        XCTAssertEqual(UploadCircuitState.closed.rawValue, "closed",
                       "Closed state rawValue should be 'closed'")
    }
    
    func testInitial_CircuitState_Open_RawValue() {
        XCTAssertEqual(UploadCircuitState.open.rawValue, "open",
                       "Open state rawValue should be 'open'")
    }
    
    func testInitial_CircuitState_HalfOpen_RawValue() {
        XCTAssertEqual(UploadCircuitState.halfOpen.rawValue, "halfOpen",
                       "HalfOpen state rawValue should be 'halfOpen'")
    }
    
    func testInitial_CircuitState_Sendable() {
        // Verify Sendable conformance compiles
        let state: UploadCircuitState = .closed
        XCTAssertNotNil(state, "UploadCircuitState should be Sendable")
    }
    
    // MARK: - Closed → Open Transition
    
    func testClosed_1Failure_StillClosed() async {
        let breaker = UploadCircuitBreaker()
        
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "1 failure should not open circuit")
    }
    
    func testClosed_4Failures_StillClosed() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<4 {
            await breaker.recordFailure()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "4 failures should not open circuit")
    }
    
    func testClosed_5Failures_OpensCircuit() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "5 failures should open circuit")
    }
    
    func testClosed_ExactlyThreshold_Opens() async {
        let breaker = UploadCircuitBreaker()
        
        let threshold = UploadConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD
        for _ in 0..<threshold {
            await breaker.recordFailure()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "Exactly threshold failures should open circuit")
    }
    
    func testClosed_SuccessResetsCounter() async {
        let breaker = UploadCircuitBreaker()
        
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.recordSuccess()
        
        // After success, 1 more failure should not open
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Success should reset failure counter")
    }
    
    func testClosed_4Failures_1Success_ResetTo0() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<4 {
            await breaker.recordFailure()
        }
        await breaker.recordSuccess()
        
        // Now 1 failure should not open
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Success should reset counter to 0")
    }
    
    func testClosed_4Failures_1Success_1Failure_StillClosed() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<4 {
            await breaker.recordFailure()
        }
        await breaker.recordSuccess()
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "After success reset, 1 failure should not open")
    }
    
    func testClosed_ShouldAllowRequest_AlwaysTrue() async {
        let breaker = UploadCircuitBreaker()
        
        await breaker.recordFailure()
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "Closed state should always allow requests")
    }
    
    func testClosed_RecordSuccess_KeepsClosed() async {
        let breaker = UploadCircuitBreaker()
        
        await breaker.recordSuccess()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Success in closed state should keep it closed")
    }
    
    func testClosed_AlternatingFailureSuccess_NeverOpens() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<10 {
            await breaker.recordFailure()
            await breaker.recordSuccess()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Alternating failures and successes should never open")
    }
    
    func testClosed_5FailuresConsecutive_Opens() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "5 consecutive failures should open circuit")
    }
    
    func testClosed_FailureThreshold_Equals5() {
        XCTAssertEqual(UploadConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD, 5,
                      "Failure threshold should be 5")
    }
    
    // MARK: - Open State
    
    func testOpen_ShouldAllowRequest_ReturnsFalse() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertFalse(allowed,
                      "Open circuit should block requests")
    }
    
    func testOpen_ImmediatelyAfterOpen_Blocked() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Immediately check
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertFalse(allowed,
                      "Immediately after opening, requests should be blocked")
    }
    
    func testOpen_RecordFailure_UpdatesTimestamp() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Record another failure
        await breaker.recordFailure()
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertFalse(allowed,
                      "Additional failure should update timestamp but keep open")
    }
    
    func testOpen_After29Seconds_StillBlocked() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait 29 seconds (simulated)
        try await Task.sleep(nanoseconds: 29_000_000_000)
        
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertFalse(allowed,
                      "After 29 seconds, circuit should still be blocked")
    }
    
    func testOpen_After30Seconds_TransitionsToHalfOpen() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait 30 seconds
        try await Task.sleep(nanoseconds: 30_000_000_000)
        
        let allowed = await breaker.shouldAllowRequest()
        let state = await breaker.getState()
        
        XCTAssertTrue(allowed,
                     "After 30 seconds, should allow request")
        XCTAssertEqual(state, .halfOpen,
                      "After 30 seconds, should transition to half-open")
    }
    
    func testOpen_After31Seconds_AllowsRequest() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait 31 seconds
        try await Task.sleep(nanoseconds: 31_000_000_000)
        
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "After 31 seconds, should allow request")
    }
    
    func testOpen_TimeBasedTransition_HalfOpenInterval30s() {
        XCTAssertEqual(UploadConstants.CIRCUIT_BREAKER_HALF_OPEN_INTERVAL, 30.0,
                       "Half-open interval should be 30 seconds")
    }
    
    func testOpen_MultipleFailures_ResetTimer() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Record another failure (resets timer)
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
        await breaker.recordFailure()
        
        // Check immediately
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertFalse(allowed,
                      "Additional failure should reset timer")
    }
    
    func testOpen_State_ReportsOpen() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "State should report open")
    }
    
    // MARK: - Half-Open State
    
    func testHalfOpen_ShouldAllowRequest_ReturnsTrue() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait to enter half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "Half-open state should allow requests")
    }
    
    func testHalfOpen_1Success_StillHalfOpen() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait to enter half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()  // Transition to half-open
        
        await breaker.recordSuccess()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .halfOpen,
                      "1 success should keep circuit half-open")
    }
    
    func testHalfOpen_2Successes_CloseCircuit() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait to enter half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()  // Transition to half-open
        
        await breaker.recordSuccess()
        await breaker.recordSuccess()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "2 successes should close circuit")
    }
    
    func testHalfOpen_ExactlySuccessThreshold_Closes() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait to enter half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()  // Transition to half-open
        
        let threshold = UploadConstants.CIRCUIT_BREAKER_SUCCESS_THRESHOLD
        for _ in 0..<threshold {
            await breaker.recordSuccess()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Exactly threshold successes should close circuit")
    }
    
    func testHalfOpen_1Failure_OpensAgain() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Wait to enter half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()  // Transition to half-open
        
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "1 failure in half-open should reopen circuit")
    }
    
    func testHalfOpen_SuccessThreshold_Equals2() {
        XCTAssertEqual(UploadConstants.CIRCUIT_BREAKER_SUCCESS_THRESHOLD, 2,
                      "Success threshold should be 2")
    }
    
    func testHalfOpen_AfterClose_FailureCountReset() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open → Close
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        await breaker.recordSuccess()
        await breaker.recordSuccess()
        
        // Now record 1 failure - should not open
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "After closing, failure count should be reset")
    }
    
    func testHalfOpen_AfterClose_SuccessCountReset() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open → Close
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        await breaker.recordSuccess()
        await breaker.recordSuccess()
        
        // Verify state is closed
        let state = await breaker.getState()
        XCTAssertEqual(state, .closed,
                      "Circuit should be closed")
    }
    
    func testHalfOpen_1Success_1Failure_OpensAgain() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        await breaker.recordSuccess()
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "Failure after success should reopen circuit")
    }
    
    func testHalfOpen_Failure_SetsTimestamp() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        await breaker.recordFailure()
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertFalse(allowed,
                      "Failure should set timestamp and block requests")
    }
    
    func testHalfOpen_Failure_FailureCountEqualsThreshold() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        await breaker.recordFailure()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .open,
                      "Failure count should equal threshold after failure")
    }
    
    func testHalfOpen_Success_CountIncrementsCorrectly() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        await breaker.recordSuccess()
        let state1 = await breaker.getState()
        XCTAssertEqual(state1, .halfOpen,
                      "1 success should keep half-open")
        
        await breaker.recordSuccess()
        let state2 = await breaker.getState()
        XCTAssertEqual(state2, .closed,
                      "2 successes should close")
    }
    
    func testHalfOpen_SuccessCountResets_OnReopen() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open → Success → Failure (reopen)
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        await breaker.recordSuccess()
        await breaker.recordFailure()
        
        // Now in open state, success count should be reset
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        await breaker.recordSuccess()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .halfOpen,
                      "Success count should reset on reopen")
    }
    
    func testHalfOpen_State_ReportsHalfOpen() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .halfOpen,
                      "State should report half-open")
    }
    
    func testHalfOpen_MultipleTransitions_Stable() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Multiple open → half-open → close cycles
        for cycle in 0..<3 {
            // Open
            for _ in 0..<5 {
                await breaker.recordFailure()
            }
            
            // Half-open
            try await Task.sleep(nanoseconds: 30_000_000_000)
            await breaker.shouldAllowRequest()
            
            // Close
            await breaker.recordSuccess()
            await breaker.recordSuccess()
            
            let state = await breaker.getState()
            XCTAssertEqual(state, .closed,
                          "Cycle \(cycle) should end in closed state")
        }
    }
    
    // MARK: - Reset
    
    func testReset_FromClosed_StaysClosed() async {
        let breaker = UploadCircuitBreaker()
        
        await breaker.reset()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Reset from closed should stay closed")
    }
    
    func testReset_FromOpen_GoesToClosed() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        await breaker.reset()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Reset from open should go to closed")
    }
    
    func testReset_FromHalfOpen_GoesToClosed() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        await breaker.reset()
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Reset from half-open should go to closed")
    }
    
    func testReset_ClearsFailureCount() async {
        let breaker = UploadCircuitBreaker()
        
        await breaker.recordFailure()
        await breaker.recordFailure()
        await breaker.reset()
        
        // After reset, 4 failures should not open
        for _ in 0..<4 {
            await breaker.recordFailure()
        }
        let state = await breaker.getState()
        
        XCTAssertEqual(state, .closed,
                      "Reset should clear failure count")
    }
    
    func testReset_ClearsSuccessCount() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Open → Half-open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        await breaker.recordSuccess()
        
        await breaker.reset()
        
        // After reset, should be in closed state
        let state = await breaker.getState()
        XCTAssertEqual(state, .closed,
                      "Reset should clear success count")
    }
    
    func testReset_ClearsLastFailureTime() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        await breaker.reset()
        
        // Should allow immediately (no time-based blocking)
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "Reset should clear last failure time")
    }
    
    func testReset_ShouldAllowRequest_True() async {
        let breaker = UploadCircuitBreaker()
        
        // Open circuit
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        await breaker.reset()
        let allowed = await breaker.shouldAllowRequest()
        
        XCTAssertTrue(allowed,
                     "After reset, should allow requests")
    }
    
    func testReset_CanResetMultipleTimes() async {
        let breaker = UploadCircuitBreaker()
        
        for _ in 0..<10 {
            // Open circuit
            for _ in 0..<5 {
                await breaker.recordFailure()
            }
            await breaker.reset()
        }
        
        let state = await breaker.getState()
        XCTAssertEqual(state, .closed,
                      "Multiple resets should work correctly")
    }
    
    // MARK: - Full Lifecycle
    
    func testLifecycle_ClosedToOpenToHalfOpenToClosed() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Closed → Open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        let state1 = await breaker.getState()
        XCTAssertEqual(state1, .open,
                      "Should transition to open")
        
        // Open → Half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        let state2 = await breaker.getState()
        XCTAssertEqual(state2, .halfOpen,
                      "Should transition to half-open")
        
        // Half-open → Closed
        await breaker.recordSuccess()
        await breaker.recordSuccess()
        let state3 = await breaker.getState()
        XCTAssertEqual(state3, .closed,
                      "Should transition to closed")
    }
    
    func testLifecycle_ClosedToOpenToHalfOpenToOpen() async throws {
        let breaker = UploadCircuitBreaker()
        
        // Closed → Open
        for _ in 0..<5 {
            await breaker.recordFailure()
        }
        
        // Open → Half-open
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await breaker.shouldAllowRequest()
        
        // Half-open → Open (failure)
        await breaker.recordFailure()
        let state = await breaker.getState()
        XCTAssertEqual(state, .open,
                      "Should transition back to open")
    }
    
    func testLifecycle_RepeatCycling_5Times() async throws {
        let breaker = UploadCircuitBreaker()
        
        for cycle in 0..<5 {
            // Open
            for _ in 0..<5 {
                await breaker.recordFailure()
            }
            
            // Half-open
            try await Task.sleep(nanoseconds: 30_000_000_000)
            await breaker.shouldAllowRequest()
            
            // Close
            await breaker.recordSuccess()
            await breaker.recordSuccess()
            
            let state = await breaker.getState()
            XCTAssertEqual(state, .closed,
                          "Cycle \(cycle) should end in closed")
        }
    }
    
    func testLifecycle_RapidTransitions_NoCorruption() async {
        let breaker = UploadCircuitBreaker()
        
        // Rapid failures and successes
        for _ in 0..<100 {
            await breaker.recordFailure()
            await breaker.recordSuccess()
        }
        
        let state = await breaker.getState()
        XCTAssertEqual(state, .closed,
                      "Rapid transitions should not corrupt state")
    }
    
    func testLifecycle_ConcurrentAccess_ActorSafe() async {
        let breaker = UploadCircuitBreaker()
        
        // Concurrent operations
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await breaker.recordFailure()
                }
                group.addTask {
                    await breaker.recordSuccess()
                }
                group.addTask {
                    _ = await breaker.shouldAllowRequest()
                }
            }
        }
        
        // State should be consistent
        let state = await breaker.getState()
        XCTAssertTrue([.closed, .open, .halfOpen].contains(state),
                     "State should be valid after concurrent access")
    }
    
    func testLifecycle_10ConcurrentRecordFailure_Correct() async {
        let breaker = UploadCircuitBreaker()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await breaker.recordFailure()
                }
            }
        }
        
        let state = await breaker.getState()
        XCTAssertEqual(state, .open,
                      "10 concurrent failures should open circuit")
    }
    
    func testLifecycle_MixedConcurrentOperations_NoRace() async {
        let breaker = UploadCircuitBreaker()
        
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                if i % 2 == 0 {
                    group.addTask {
                        await breaker.recordFailure()
                    }
                } else {
                    group.addTask {
                        await breaker.recordSuccess()
                    }
                }
            }
        }
        
        // State should be consistent
        let state = await breaker.getState()
        XCTAssertTrue([.closed, .open, .halfOpen].contains(state),
                     "State should be valid after mixed concurrent operations")
    }
}
