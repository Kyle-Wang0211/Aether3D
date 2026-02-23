// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TokenBucketLimiter.swift
// Aether3D
//
// PR2 Patch V4 - Token Bucket Rate Limiter
// Deterministic time-based token refill
//

import Foundation
import CAetherNativeBridge

/// Token bucket rate limiter
///
/// DESIGN:
/// - Deterministic refill based on elapsed time
/// - Per-patch buckets to prevent one patch from starving others
/// - No hard-blocking (returns false if no tokens, but caller decides action)
public final class TokenBucketLimiter {
    private let nativeLimiter: OpaquePointer
    
    public init() {
        var limiter: OpaquePointer?
        let rc = aether_token_bucket_create(&limiter)
        precondition(rc == 0, "aether_token_bucket_create failed: rc=\(rc)")
        precondition(limiter != nil, "aether_token_bucket_create returned nil limiter")
        nativeLimiter = limiter!
    }

    deinit {
        _ = aether_token_bucket_destroy(nativeLimiter)
    }
    
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
        precondition(constants.tokenCostPerObservation == EvidenceConstants.tokenCostPerObservation,
                     "TokenBucketLimiter uses C++ SSOT constants only")
        precondition(constants.tokenRefillRatePerSec == EvidenceConstants.tokenRefillRatePerSec,
                     "TokenBucketLimiter uses C++ SSOT constants only")
        precondition(constants.tokenBucketMaxTokens == EvidenceConstants.tokenBucketMaxTokens,
                     "TokenBucketLimiter uses C++ SSOT constants only")

        let actualCost = cost ?? constants.tokenCostPerObservation
        if abs(actualCost - constants.tokenCostPerObservation) > 1e-12 {
            return false
        }

        var consumed: Int32 = 0
        let rc = patchId.withCString { cPatchId in
            aether_token_bucket_try_consume(nativeLimiter, cPatchId, timestampMs, &consumed)
        }
        precondition(rc == 0, "aether_token_bucket_try_consume failed: rc=\(rc)")
        return consumed != 0
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
        precondition(constants.tokenRefillRatePerSec == EvidenceConstants.tokenRefillRatePerSec,
                     "TokenBucketLimiter uses C++ SSOT constants only")
        precondition(constants.tokenBucketMaxTokens == EvidenceConstants.tokenBucketMaxTokens,
                     "TokenBucketLimiter uses C++ SSOT constants only")

        var tokens: Double = 0.0
        let rc = patchId.withCString { cPatchId in
            aether_token_bucket_available_tokens(nativeLimiter, cPatchId, timestampMs, &tokens)
        }
        precondition(rc == 0, "aether_token_bucket_available_tokens failed: rc=\(rc)")
        return tokens
    }
    
    /// Reset all buckets
    public func reset() {
        _ = aether_token_bucket_reset(nativeLimiter)
    }
}
