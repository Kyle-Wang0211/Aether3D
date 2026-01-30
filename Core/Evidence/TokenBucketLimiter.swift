//
// TokenBucketLimiter.swift
// Aether3D
//
// PR2 Patch V4 - Token Bucket Rate Limiter
// Deterministic time-based token refill
//

import Foundation

/// Token bucket per-patch state
private struct TokenBucketState {
    var tokens: Double
    var lastRefillMs: Int64
    
    init(tokens: Double = 0.0, lastRefillMs: Int64 = 0) {
        self.tokens = tokens
        self.lastRefillMs = lastRefillMs
    }
}

/// Token bucket rate limiter
///
/// DESIGN:
/// - Deterministic refill based on elapsed time
/// - Per-patch buckets to prevent one patch from starving others
/// - No hard-blocking (returns false if no tokens, but caller decides action)
public final class TokenBucketLimiter {
    
    /// Per-patch bucket state
    private var buckets: [String: TokenBucketState] = [:]
    
    public init() {}
    
    /// Try to consume tokens for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - cost: Token cost (defaults to SSOT constant)
    ///   - timestampMs: Current timestamp in milliseconds
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: true if tokens were consumed, false if insufficient tokens
    @discardableResult
    public func tryConsume(
        patchId: String,
        cost: Double? = nil,
        timestampMs: Int64,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Bool {
        let actualCost = cost ?? constants.tokenCostPerObservation
        
        // Refill tokens first
        refill(patchId: patchId, timestampMs: timestampMs, constants: constants)
        
        // Check if enough tokens
        guard let state = buckets[patchId], state.tokens >= actualCost else {
            return false
        }
        
        // Consume tokens
        buckets[patchId]?.tokens -= actualCost
        
        return true
    }
    
    /// Get available tokens for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - timestampMs: Current timestamp in milliseconds
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Available token count
    public func availableTokens(
        patchId: String,
        timestampMs: Int64,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Double {
        refill(patchId: patchId, timestampMs: timestampMs, constants: constants)
        return buckets[patchId]?.tokens ?? 0.0
    }
    
    /// Refill tokens based on elapsed time
    private func refill(
        patchId: String,
        timestampMs: Int64,
        constants: EvidenceConstants.Type
    ) {
        var state = buckets[patchId] ?? TokenBucketState(lastRefillMs: timestampMs)
        
        // Compute elapsed time in seconds
        let dtMs = timestampMs - state.lastRefillMs
        
        // Handle backward time (shouldn't happen, but be safe)
        if dtMs < 0 {
            EvidenceLogger.warn("TokenBucketLimiter: backward time detected for patch \(patchId), treating dt=0")
            state.lastRefillMs = timestampMs
            buckets[patchId] = state
            return
        }
        
        let dtSeconds = Double(dtMs) / 1000.0
        
        // Refill: tokens += refillRate * dtSeconds
        let refillAmount = constants.tokenRefillRatePerSec * dtSeconds
        state.tokens = min(constants.tokenBucketMaxTokens, state.tokens + refillAmount)
        state.lastRefillMs = timestampMs
        
        buckets[patchId] = state
    }
    
    /// Reset all buckets
    public func reset() {
        buckets.removeAll()
    }
}
