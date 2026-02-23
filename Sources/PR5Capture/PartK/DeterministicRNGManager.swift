// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicRNGManager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART K: 跨平台确定性
// 确定性随机数生成器，可重现种子管理
//

import Foundation

/// Deterministic RNG manager
///
/// Manages deterministic random number generation with reproducible seeds.
/// Ensures consistent random sequences across platforms.
public actor DeterministicRNGManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Current seed
    private var currentSeed: UInt64 = 0
    
    /// RNG state
    private var state: UInt64 = 0
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile, seed: UInt64 = 0) {
        self.config = config
        self.currentSeed = seed
        self.state = seed
    }
    
    // MARK: - RNG Operations
    
    /// Set seed
    public func setSeed(_ seed: UInt64) {
        currentSeed = seed
        state = seed
    }
    
    /// Get next random value
    ///
    /// Linear congruential generator (LCG) for deterministic randomness
    public func next() -> UInt64 {
        // LCG: (a * state + c) mod m
        // Using constants from Numerical Recipes
        state = (state &* 1664525 &+ 1013904223) & 0xFFFFFFFFFFFFFFFF
        return state
    }
    
    /// Get next random double in [0, 1)
    public func nextDouble() -> Double {
        return Double(next()) / Double(UInt64.max)
    }
    
    /// Get next random integer in range
    public func nextInt(in range: Range<Int>) -> Int {
        let rangeSize = UInt64(range.upperBound - range.lowerBound)
        let random = next() % rangeSize
        return range.lowerBound + Int(random)
    }
    
    /// Reset to initial seed
    public func reset() {
        state = currentSeed
    }
}
