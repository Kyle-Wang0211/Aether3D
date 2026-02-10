// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-AVAILABILITY-1.0
// Module: Upload Infrastructure - Upload Circuit Breaker
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

/// Upload circuit breaker state.
public enum UploadCircuitState: String, Sendable {
    case closed    // Normal operation
    case open      // Failing — reject requests
    case halfOpen  // Testing — allow limited requests
}

/// Circuit breaker pattern for upload resilience.
///
/// **Purpose**: Circuit breaker pattern: Closed→Open→Half-Open→Closed.
/// 5 failures→open, 30s half-open, 2 successes→close.
///
/// **State Transitions**:
/// - Closed → Open: After 5 consecutive failures
/// - Open → Half-Open: After 30 seconds
/// - Half-Open → Closed: After 2 consecutive successes
/// - Half-Open → Open: After 1 failure
public actor UploadCircuitBreaker {
    
    // MARK: - State
    
    private var state: UploadCircuitState = .closed
    private var failureCount: Int = 0
    private var successCount: Int = 0
    private var lastFailureTime: Date?
    
    private let failureThreshold = UploadConstants.CIRCUIT_BREAKER_FAILURE_THRESHOLD
    private let halfOpenInterval = UploadConstants.CIRCUIT_BREAKER_HALF_OPEN_INTERVAL
    private let successThreshold = UploadConstants.CIRCUIT_BREAKER_SUCCESS_THRESHOLD
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Circuit Breaker Logic
    
    /// Check if request should be allowed.
    ///
    /// - Returns: True if request should proceed
    public func shouldAllowRequest() -> Bool {
        switch state {
        case .closed:
            return true
            
        case .open:
            // Check if enough time has passed to enter half-open
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= halfOpenInterval {
                state = .halfOpen
                successCount = 0
                return true
            }
            return false
            
        case .halfOpen:
            return true
        }
    }
    
    /// Record success.
    public func recordSuccess() {
        switch state {
        case .closed:
            // Reset failure count on success
            failureCount = 0
            
        case .halfOpen:
            successCount += 1
            if successCount >= successThreshold {
                // Transition to closed
                state = .closed
                failureCount = 0
                successCount = 0
            }
            
        case .open:
            // Should not happen, but handle gracefully
            break
        }
    }
    
    /// Record failure.
    public func recordFailure() {
        switch state {
        case .closed:
            failureCount += 1
            lastFailureTime = Date()
            
            if failureCount >= failureThreshold {
                // Transition to open
                state = .open
            }
            
        case .halfOpen:
            // One failure in half-open → back to open
            state = .open
            failureCount = failureThreshold
            lastFailureTime = Date()
            successCount = 0
            
        case .open:
            // Already open, update timestamp
            lastFailureTime = Date()
        }
    }
    
    /// Get current state.
    public func getState() -> UploadCircuitState {
        return state
    }
    
    /// Reset circuit breaker to closed state.
    public func reset() {
        state = .closed
        failureCount = 0
        successCount = 0
        lastFailureTime = nil
    }
}
