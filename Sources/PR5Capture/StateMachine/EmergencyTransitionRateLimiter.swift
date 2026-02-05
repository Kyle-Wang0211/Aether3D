//
// EmergencyTransitionRateLimiter.swift
// PR5Capture
//
// PR5 v1.8.1 - PART C: 状态机增强
// 紧急转换速率限制，防止状态抖动
//

import Foundation

/// Emergency transition rate limiter
///
/// Limits the rate of emergency transitions to prevent state oscillation.
/// Tracks emergency transitions and enforces rate limits.
public actor EmergencyTransitionRateLimiter {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Emergency transition history
    private var emergencyTransitions: [Date] = []
    
    /// Rate limit window (1 second)
    private let rateLimitWindow: TimeInterval = 1.0
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Rate Limiting
    
    /// Check if emergency transition is allowed
    ///
    /// Returns true if transition is allowed, false if rate limited
    public func canTransition() -> RateLimitResult {
        let now = Date()
        
        // Clean old transitions outside window
        let cutoff = now.addingTimeInterval(-rateLimitWindow)
        emergencyTransitions.removeAll { $0 < cutoff }
        
        // Check rate limit
        let rateLimit = config.stateMachine.emergencyTransitionRateLimit
        let currentRate = Double(emergencyTransitions.count) / rateLimitWindow
        
        if currentRate >= rateLimit {
            let remaining = rateLimitWindow - (now.timeIntervalSince(emergencyTransitions.first ?? now))
            return .rateLimited(
                currentRate: currentRate,
                limit: rateLimit,
                remaining: max(0, remaining)
            )
        } else {
            // Allow transition
            emergencyTransitions.append(now)
            return .allowed(currentRate: currentRate, limit: rateLimit)
        }
    }
    
    /// Record emergency transition
    ///
    /// Records the transition and checks rate limit
    public func recordTransition() -> RateLimitResult {
        return canTransition()
    }
    
    // MARK: - Queries
    
    /// Get current transition rate
    public func getCurrentRate() -> Double {
        let now = Date()
        let cutoff = now.addingTimeInterval(-rateLimitWindow)
        let recentTransitions = emergencyTransitions.filter { $0 >= cutoff }
        return Double(recentTransitions.count) / rateLimitWindow
    }
    
    /// Get rate limit
    public func getRateLimit() -> Double {
        return config.stateMachine.emergencyTransitionRateLimit
    }
    
    // MARK: - Result Types
    
    /// Rate limit result
    public enum RateLimitResult: Sendable {
        case allowed(currentRate: Double, limit: Double)
        case rateLimited(currentRate: Double, limit: Double, remaining: TimeInterval)
    }
}
