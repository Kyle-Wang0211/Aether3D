// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class RetryCalculatorTests: XCTestCase {
    
    func testExponentialBackoff() {
        // Verify exponential growth pattern
        let delays = (0..<5).map { attempt in
            RetryCalculator.calculateDelay(attempt: attempt, jitterMaxMs: 0)
        }
        
        XCTAssertEqual(delays[0], 2.0, accuracy: 0.01)   // 2^0 * 2 = 2
        XCTAssertEqual(delays[1], 4.0, accuracy: 0.01)   // 2^1 * 2 = 4
        XCTAssertEqual(delays[2], 8.0, accuracy: 0.01)   // 2^2 * 2 = 8
        XCTAssertEqual(delays[3], 16.0, accuracy: 0.01)  // 2^3 * 2 = 16
        XCTAssertEqual(delays[4], 32.0, accuracy: 0.01)  // 2^4 * 2 = 32
    }
    
    func testMaxDelayCap() {
        // Verify delay is capped at maxDelay
        let delay = RetryCalculator.calculateDelay(
            attempt: 10,  // Would be 2048 without cap
            maxDelay: 60,
            jitterMaxMs: 0
        )
        
        XCTAssertEqual(delay, 60.0, accuracy: 0.01)
    }
    
    func testJitterRange() {
        // Verify jitter is within expected range
        for _ in 0..<100 {
            let delay = RetryCalculator.calculateDelay(
                attempt: 0,
                baseInterval: 2,
                jitterMaxMs: 1000
            )
            
            // Base is 2, jitter is 0-1, so delay should be 2.0-3.0
            XCTAssertGreaterThanOrEqual(delay, 2.0)
            XCTAssertLessThanOrEqual(delay, 3.0)
        }
    }
    
    func testShouldRetryWithRetryableReason() {
        XCTAssertTrue(RetryCalculator.shouldRetry(attempt: 0, failureReason: .networkError))
        XCTAssertTrue(RetryCalculator.shouldRetry(attempt: 4, failureReason: .networkError))
        XCTAssertFalse(RetryCalculator.shouldRetry(attempt: 5, failureReason: .networkError))
    }
    
    func testShouldNotRetryWithNonRetryableReason() {
        XCTAssertFalse(RetryCalculator.shouldRetry(attempt: 0, failureReason: .invalidVideoFormat))
        XCTAssertFalse(RetryCalculator.shouldRetry(attempt: 0, failureReason: .videoTooShort))
    }
    
    func testPreviewDelays() {
        let delays = RetryCalculator.previewDelays(maxAttempts: 5)
        XCTAssertEqual(delays.count, 5)

        // Each delay should be greater than the previous (exponential growth)
        // Since base = 2 and exponential: 2, 4, 8, 16, 32
        // With jitter up to 1 second, delays[i] base > delays[i-1] base * 2 - jitter margin
        // Use 1.2x multiplier to account for jitter variance across runs
        for i in 1..<delays.count {
            XCTAssertGreaterThan(delays[i], delays[i-1] * 1.2,
                "Delay \(i) (\(delays[i])) should be greater than delay \(i-1) (\(delays[i-1])) * 1.2")
        }
    }
    
    // MARK: - Decorrelated Jitter Tests
    
    func testDecorrelatedJitterBounds() {
        let baseDelay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 60.0
        
        var previousDelay = baseDelay
        
        for _ in 0..<100 {
            let delay = RetryCalculator.calculateDecorrelatedDelay(
                previousDelay: previousDelay,
                baseDelay: baseDelay,
                maxDelay: maxDelay
            )
            
            // Delay must be >= base
            XCTAssertGreaterThanOrEqual(delay, baseDelay)
            
            // Delay must be <= max
            XCTAssertLessThanOrEqual(delay, maxDelay)
            
            // Delay must be <= previousDelay * 3 (or max)
            XCTAssertLessThanOrEqual(delay, min(maxDelay, previousDelay * 3))
            
            previousDelay = delay
        }
    }
    
    func testDecorrelatedJitterDistribution() {
        var delays: [TimeInterval] = []
        var previousDelay: TimeInterval = 1.0
        
        for _ in 0..<1000 {
            let delay = RetryCalculator.calculateDecorrelatedDelay(
                previousDelay: previousDelay,
                baseDelay: 1.0,
                maxDelay: 60.0
            )
            delays.append(delay)
            previousDelay = delay
        }
        
        // Check distribution is reasonably spread (not clustered)
        let mean = delays.reduce(0, +) / Double(delays.count)
        let variance = delays.map { pow($0 - mean, 2) }.reduce(0, +) / Double(delays.count)
        let stdDev = sqrt(variance)
        
        // Standard deviation should be significant (not all same value)
        XCTAssertGreaterThan(stdDev, 1.0, "Jitter should produce varied delays")
    }
}
