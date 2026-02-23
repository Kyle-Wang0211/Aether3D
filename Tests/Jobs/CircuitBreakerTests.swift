// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class CircuitBreakerTests: XCTestCase {
    
    // MARK: - Test 1: Initial State
    
    func testInitialStateClosed() {
        let breaker = CircuitBreaker()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.shouldAllowRequest())
    }
    
    // MARK: - Test 2: Trips After Threshold
    
    func testTripsAfterThreshold() {
        let breaker = CircuitBreaker(failureThreshold: 3)
        
        // First 2 failures - should still be closed
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        
        // 3rd failure - should trip to open
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
        XCTAssertFalse(breaker.shouldAllowRequest())
    }
    
    // MARK: - Test 3: Success Resets Failure Count
    
    func testSuccessResetsFailureCount() {
        let breaker = CircuitBreaker(failureThreshold: 3)
        
        breaker.recordFailure()
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        
        // Success resets count
        breaker.recordSuccess()
        
        // Need 3 more failures to trip
        breaker.recordFailure()
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .closed)
        
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
    }
    
    // MARK: - Test 4: Failure Rate Calculation
    
    func testFailureRateCalculation() {
        let breaker = CircuitBreaker(slidingWindowSize: 10)
        
        // 5 successes, 5 failures = 50% failure rate
        for _ in 0..<5 {
            breaker.recordSuccess()
        }
        for _ in 0..<5 {
            breaker.recordFailure()
        }
        
        XCTAssertEqual(breaker.failureRate(), 0.5, accuracy: 0.01)
    }
    
    // MARK: - Test 5: Sliding Window Trim
    
    func testSlidingWindowTrim() {
        let breaker = CircuitBreaker(slidingWindowSize: 5)
        
        // Add 10 results (first 5 should be trimmed)
        for _ in 0..<5 {
            breaker.recordFailure()  // These will be trimmed
        }
        for _ in 0..<5 {
            breaker.recordSuccess()  // These will remain
        }
        
        // Failure rate should be 0% (only successes in window)
        XCTAssertEqual(breaker.failureRate(), 0.0, accuracy: 0.01)
    }
    
    // MARK: - Test 6: Reset
    
    func testReset() {
        let breaker = CircuitBreaker(failureThreshold: 3)
        
        // Trip the circuit
        for _ in 0..<3 {
            breaker.recordFailure()
        }
        XCTAssertEqual(breaker.state, .open)
        
        // Reset
        breaker.reset()
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertTrue(breaker.shouldAllowRequest())
        XCTAssertEqual(breaker.failureRate(), 0.0)
    }
    
    // MARK: - Test 7: Half-Open After Failure in Half-Open
    
    func testHalfOpenReturnsToOpenOnFailure() {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            openTimeout: 0.0  // Immediate timeout for testing
        )
        
        // Trip to open
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
        
        // Should transition to half-open on next request (timeout = 0)
        XCTAssertTrue(breaker.shouldAllowRequest())
        XCTAssertEqual(breaker.state, .halfOpen)
        
        // Failure in half-open returns to open
        breaker.recordFailure()
        XCTAssertEqual(breaker.state, .open)
    }
    
    // MARK: - Test 8: Half-Open to Closed After Successes
    
    func testHalfOpenClosesAfterSuccesses() {
        let breaker = CircuitBreaker(
            failureThreshold: 1,
            successThreshold: 2,
            openTimeout: 0.0
        )
        
        // Trip to open
        breaker.recordFailure()
        
        // Transition to half-open
        _ = breaker.shouldAllowRequest()
        XCTAssertEqual(breaker.state, .halfOpen)
        
        // First success - still half-open
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .halfOpen)
        
        // Second success - should close
        breaker.recordSuccess()
        XCTAssertEqual(breaker.state, .closed)
    }
    
    // MARK: - Test 9: Default Constants
    
    func testDefaultConstants() {
        let breaker = CircuitBreaker()
        
        // Trip with default threshold (5)
        for _ in 0..<ContractConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD {
            breaker.recordFailure()
        }
        XCTAssertEqual(breaker.state, .open)
    }
}
