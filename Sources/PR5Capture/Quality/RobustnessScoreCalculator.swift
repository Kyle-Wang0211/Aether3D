// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RobustnessScoreCalculator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 3 + E: 质量指标和鲁棒性
// 鲁棒性评分计算，异常值处理，稳定性评估
//

import Foundation

/// Robustness score calculator
///
/// Calculates robustness scores with outlier handling.
/// Evaluates stability across varying conditions.
public actor RobustnessScoreCalculator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Quality score history
    private var qualityHistory: [Double] = []
    
    /// Robustness scores
    private var robustnessScores: [(timestamp: Date, score: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Robustness Calculation
    
    /// Calculate robustness score
    ///
    /// Computes robustness based on quality score stability
    public func calculateRobustness(_ qualityScore: Double) -> RobustnessResult {
        qualityHistory.append(qualityScore)
        
        // Keep only recent history (last 100)
        if qualityHistory.count > 100 {
            qualityHistory.removeFirst()
        }
        
        guard qualityHistory.count >= 5 else {
            // Not enough data
            let mean = qualityHistory.isEmpty ? qualityScore : qualityHistory.reduce(0.0, +) / Double(qualityHistory.count)
            let variance = qualityHistory.isEmpty ? 0.0 : qualityHistory.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(qualityHistory.count)
            let stdDev = sqrt(variance)
            return RobustnessResult(
                score: 0.5,
                stability: 0.5,
                outlierCount: 0,
                sampleCount: qualityHistory.count,
                mean: mean,
                stdDev: stdDev
            )
        }
        
        // Calculate statistics
        let mean = qualityHistory.reduce(0.0, +) / Double(qualityHistory.count)
        let variance = qualityHistory.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(qualityHistory.count)
        let stdDev = sqrt(variance)
        
        // Detect outliers (beyond 2 standard deviations)
        let outlierThreshold = 2.0 * stdDev
        let outlierCount = qualityHistory.filter { abs($0 - mean) > outlierThreshold }.count
        
        // Calculate stability (inverse of coefficient of variation)
        let coefficientOfVariation = stdDev / max(mean, 0.001)
        let stability = 1.0 / (1.0 + coefficientOfVariation)
        
        // Calculate robustness score (combination of mean quality and stability)
        let qualityComponent = mean
        let stabilityComponent = stability
        let robustness = (qualityComponent * 0.6) + (stabilityComponent * 0.4)
        
        // Record score
        robustnessScores.append((timestamp: Date(), score: robustness))
        
        // Keep only recent scores (last 100)
        if robustnessScores.count > 100 {
            robustnessScores.removeFirst()
        }
        
        return RobustnessResult(
            score: robustness,
            stability: stability,
            outlierCount: outlierCount,
            sampleCount: qualityHistory.count,
            mean: mean,
            stdDev: stdDev
        )
    }
    
    // MARK: - Queries
    
    /// Get average robustness score
    public func getAverageRobustness() -> Double? {
        guard !robustnessScores.isEmpty else { return nil }
        let sum = robustnessScores.reduce(0.0) { $0 + $1.score }
        return sum / Double(robustnessScores.count)
    }
    
    /// Get robustness trend
    public func getRobustnessTrend() -> Trend {
        guard robustnessScores.count >= 3 else { return .insufficient }
        
        let recent = Array(robustnessScores.suffix(5))
        let scores = recent.map { $0.score }
        
        // Simple linear trend
        let firstHalf = Array(scores.prefix(scores.count / 2))
        let secondHalf = Array(scores.suffix(scores.count / 2))
        
        let firstAvg = firstHalf.reduce(0.0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0.0, +) / Double(secondHalf.count)
        
        let delta = secondAvg - firstAvg
        let threshold = 0.05
        
        if delta > threshold {
            return .improving
        } else if delta < -threshold {
            return .degrading
        } else {
            return .stable
        }
    }
    
    // MARK: - Result Types
    
    /// Robustness result
    public struct RobustnessResult: Sendable {
        public let score: Double
        public let stability: Double
        public let outlierCount: Int
        public let sampleCount: Int
        public let mean: Double
        public let stdDev: Double
    }
    
    /// Trend
    public enum Trend: String, Sendable {
        case improving
        case stable
        case degrading
        case insufficient
    }
}
