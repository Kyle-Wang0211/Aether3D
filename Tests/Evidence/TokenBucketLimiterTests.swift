// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TokenBucketLimiterTests.swift
// Aether3D
//
// PR2 Patch V4 - Token Bucket Limiter Tests
//

import XCTest
@testable import Aether3DCore

final class TokenBucketLimiterTests: XCTestCase {
    
    var limiter: TokenBucketLimiter!
    var currentTimeMs: Int64!
    
    override func setUp() {
        super.setUp()
        limiter = TokenBucketLimiter()
        currentTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
    }
    
    func testRefillDeterministic() {
        // Start with empty bucket
        let patchId = "test_patch"
        
        // Refill over 1 second
        let laterTimeMs = currentTimeMs + 1000
        
        let tokensBefore = limiter.availableTokens(patchId: patchId, timestampMs: currentTimeMs)
        let tokensAfter = limiter.availableTokens(patchId: patchId, timestampMs: laterTimeMs)
        
        // Should have refilled
        XCTAssertGreaterThan(tokensAfter, tokensBefore, "Tokens should refill over time")
        
        // Should be approximately refillRate * dtSeconds
        let expectedRefill = EvidenceConstants.tokenRefillRatePerSec * 1.0
        XCTAssertEqual(tokensAfter, expectedRefill, accuracy: 0.1, "Refill should match rate")
    }
    
    func testConsumeLimitsRate() {
        let patchId = "rate_test"
        
        // Fill bucket to max
        let fillTimeMs = currentTimeMs + Int64(EvidenceConstants.tokenBucketMaxTokens / EvidenceConstants.tokenRefillRatePerSec * 1000)
        _ = limiter.availableTokens(patchId: patchId, timestampMs: fillTimeMs)
        
        // Try to consume multiple times rapidly
        var successCount = 0
        for _ in 0..<20 {
            if limiter.tryConsume(patchId: patchId, timestampMs: fillTimeMs) {
                successCount += 1
            }
        }
        
        // Should only succeed up to max tokens
        XCTAssertLessThanOrEqual(successCount, Int(EvidenceConstants.tokenBucketMaxTokens), "Should not exceed max tokens")
    }
    
    func testNoBackwardTimeRefill() {
        let patchId = "backward_test"
        
        // Set initial time
        _ = limiter.availableTokens(patchId: patchId, timestampMs: currentTimeMs)
        
        // Try backward time
        let backwardTimeMs = currentTimeMs - 1000
        let tokens = limiter.availableTokens(patchId: patchId, timestampMs: backwardTimeMs)
        
        // Should not crash and should handle gracefully
        XCTAssertGreaterThanOrEqual(tokens, 0.0, "Should handle backward time gracefully")
    }
}
