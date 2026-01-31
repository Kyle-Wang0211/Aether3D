//
// SmootherConfig.swift
// Aether3D
//
// PR3 - Smoother Configuration
// Configuration for smart anti-boost behavior
//

import Foundation

/// Configuration for smart anti-boost behavior
public struct SmootherConfig: Sendable {

    /// Jitter band: differences within this range are considered noise
    public let jitterBand: Double

    /// Anti-boost factor: how much slower to improve on suspicious jumps
    /// 0.3 = improve at 30% speed (only for suspicious jumps)
    public let antiBoostFactor: Double

    /// Normal improvement factor: how fast to improve on normal changes
    /// 0.7 = improve at 70% speed (faster than anti-boost)
    public let normalImproveFactor: Double

    /// Degradation factor: how fast to degrade
    /// 1.0 = immediate degradation (realistic penalty)
    public let degradeFactor: Double

    /// Consecutive invalid threshold: after K invalid frames, force worst-case
    public let maxConsecutiveInvalid: Int

    /// Worst-case fallback value
    public let worstCaseFallback: Double

    /// Default configuration
    public static let `default` = SmootherConfig(
        jitterBand: 0.05,
        antiBoostFactor: 0.3,
        normalImproveFactor: 0.7,
        degradeFactor: 1.0,
        maxConsecutiveInvalid: 5,
        worstCaseFallback: 0.0
    )

    /// Initialize with custom values
    ///
    /// - Parameters:
    ///   - jitterBand: Jitter band threshold
    ///   - antiBoostFactor: Anti-boost factor
    ///   - normalImproveFactor: Normal improvement factor
    ///   - degradeFactor: Degradation factor
    ///   - maxConsecutiveInvalid: Max consecutive invalid frames
    ///   - worstCaseFallback: Worst-case fallback value
    public init(
        jitterBand: Double,
        antiBoostFactor: Double,
        normalImproveFactor: Double,
        degradeFactor: Double,
        maxConsecutiveInvalid: Int,
        worstCaseFallback: Double
    ) {
        self.jitterBand = jitterBand
        self.antiBoostFactor = antiBoostFactor
        self.normalImproveFactor = normalImproveFactor
        self.degradeFactor = degradeFactor
        self.maxConsecutiveInvalid = maxConsecutiveInvalid
        self.worstCaseFallback = worstCaseFallback
    }
}
