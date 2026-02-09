// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EmergencyTransitionRateLimiterTests.swift
// PR5CaptureTests
//
// Tests for EmergencyTransitionRateLimiter
//

import XCTest
@testable import PR5Capture

@MainActor
final class EmergencyTransitionRateLimiterTests: XCTestCase {
    
    var limiter: EmergencyTransitionRateLimiter!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        limiter = EmergencyTransitionRateLimiter(config: config)
    }
    
    override func tearDown() async throws {
        limiter = nil
        config = nil
    }
    
    func testRateLimit() async {
        let rateLimit = await limiter.getRateLimit()
        
        // Try to exceed rate limit
        for _ in 0..<Int(rateLimit) + 1 {
            _ = await limiter.recordTransition()
        }
        
        let result = await limiter.canTransition()
        
        switch result {
        case .allowed:
            XCTFail("Should be rate limited")
        case .rateLimited:
            // Expected
            break
        }
    }
    
    func testRateLimitReset() async {
        // Exceed rate limit
        let rateLimit = await limiter.getRateLimit()
        for _ in 0..<Int(rateLimit) + 1 {
            _ = await limiter.recordTransition()
        }
        
        // Wait for window to reset
        try? await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1 seconds
        
        // Should be allowed again
        let result = await limiter.canTransition()
        switch result {
        case .allowed:
            break  // Expected
        case .rateLimited:
            XCTFail("Should be allowed after window reset")
        }
    }
}
