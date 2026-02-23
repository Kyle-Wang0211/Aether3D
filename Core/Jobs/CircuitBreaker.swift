// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Circuit breaker state machine (3 states)
public enum CircuitState: String, Codable {
    case closed     // Normal operation, requests pass through
    case open       // Failures exceeded threshold, requests fail fast
    case halfOpen   // Testing if service recovered
}

/// Circuit breaker for job state machine operations
public final class CircuitBreaker {
    
    // MARK: - Configuration Constants
    
    /// Failure threshold to trip the circuit
    public static let FAILURE_THRESHOLD = 5
    
    /// Success threshold in half-open state to close circuit
    public static let SUCCESS_THRESHOLD = 3
    
    /// Timeout before transitioning from open to half-open (seconds)
    public static let OPEN_TIMEOUT_SECONDS: TimeInterval = 30
    
    /// Sliding window size for failure rate calculation
    public static let SLIDING_WINDOW_SIZE = 10
    
    // MARK: - State
    
    private(set) var state: CircuitState = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private var lastFailureTime: Date?
    private var recentResults: [Bool] = []  // Sliding window
    
    // MARK: - Configuration
    
    private let failureThreshold: Int
    private let successThreshold: Int
    private let openTimeout: TimeInterval
    private let slidingWindowSize: Int
    
    // MARK: - Initialization
    
    public init(
        failureThreshold: Int = 5,
        successThreshold: Int = 3,
        openTimeout: TimeInterval = 30.0,
        slidingWindowSize: Int = 10
    ) {
        self.failureThreshold = failureThreshold
        self.successThreshold = successThreshold
        self.openTimeout = openTimeout
        self.slidingWindowSize = slidingWindowSize
    }
    
    // MARK: - Public Methods
    
    /// Check if request should be allowed
    public func shouldAllowRequest() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            // Check if timeout has elapsed
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= openTimeout {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }
    
    /// Record a successful operation
    public func recordSuccess() {
        recentResults.append(true)
        trimSlidingWindow()
        
        switch state {
        case .closed:
            failureCount = 0
        case .halfOpen:
            successCount += 1
            if successCount >= successThreshold {
                state = .closed
                failureCount = 0
                successCount = 0
            }
        case .open:
            break
        }
    }
    
    /// Record a failed operation
    public func recordFailure() {
        recentResults.append(false)
        trimSlidingWindow()
        lastFailureTime = Date()
        
        switch state {
        case .closed:
            failureCount += 1
            if failureCount >= failureThreshold {
                state = .open
            }
        case .halfOpen:
            state = .open
            successCount = 0
        case .open:
            break
        }
    }
    
    /// Get current failure rate from sliding window
    public func failureRate() -> Double {
        guard !recentResults.isEmpty else { return 0.0 }
        let failures = recentResults.filter { !$0 }.count
        return Double(failures) / Double(recentResults.count)
    }
    
    /// Reset circuit breaker to initial state
    public func reset() {
        state = .closed
        failureCount = 0
        successCount = 0
        lastFailureTime = nil
        recentResults.removeAll()
    }
    
    private func trimSlidingWindow() {
        while recentResults.count > slidingWindowSize {
            recentResults.removeFirst()
        }
    }
}

/// Thread-safe circuit breaker using Swift actor
@available(macOS 10.15, iOS 13.0, *)
public actor CircuitBreakerActor {
    private var breaker = CircuitBreaker()
    
    public func shouldAllowRequest() -> Bool {
        breaker.shouldAllowRequest()
    }
    
    public func recordSuccess() {
        breaker.recordSuccess()
    }
    
    public func recordFailure() {
        breaker.recordFailure()
    }
    
    public func failureRate() -> Double {
        breaker.failureRate()
    }
}
