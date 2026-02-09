// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ConfidenceIntervalTracker.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 3 + E: 质量指标和鲁棒性
// 置信区间追踪，不确定性量化
//

import Foundation

/// Confidence interval tracker
///
/// Tracks confidence intervals for quality metrics.
/// Quantifies uncertainty in measurements.
public actor ConfidenceIntervalTracker {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Measurement history
    private var measurements: [Double] = []
    
    /// Confidence intervals
    private var intervals: [(timestamp: Date, lower: Double, upper: Double, confidence: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Confidence Interval Calculation
    
    /// Track measurement and compute confidence interval
    ///
    /// Computes confidence interval for measurements
    public func trackMeasurement(_ value: Double, confidenceLevel: Double = 0.95) -> ConfidenceIntervalResult {
        measurements.append(value)
        
        // Keep only recent measurements (last 100)
        if measurements.count > 100 {
            measurements.removeFirst()
        }
        
        guard measurements.count >= 3 else {
            // Not enough data
            return ConfidenceIntervalResult(
                mean: value,
                lower: value,
                upper: value,
                confidence: confidenceLevel,
                sampleCount: measurements.count,
                stdDev: 0.0
            )
        }
        
        // Calculate statistics
        let mean = measurements.reduce(0.0, +) / Double(measurements.count)
        let variance = measurements.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(measurements.count)
        let stdDev = sqrt(variance)
        
        // Compute confidence interval (simplified: using normal approximation)
        // For 95% CI: z = 1.96, for 90% CI: z = 1.645
        let zScore: Double
        if confidenceLevel >= 0.95 {
            zScore = 1.96
        } else if confidenceLevel >= 0.90 {
            zScore = 1.645
        } else {
            zScore = 1.0  // Default
        }
        
        let margin = zScore * stdDev / sqrt(Double(measurements.count))
        let lower = mean - margin
        let upper = mean + margin
        
        // Record interval
        intervals.append((timestamp: Date(), lower: lower, upper: upper, confidence: confidenceLevel))
        
        // Keep only recent intervals (last 100)
        if intervals.count > 100 {
            intervals.removeFirst()
        }
        
        return ConfidenceIntervalResult(
            mean: mean,
            lower: lower,
            upper: upper,
            confidence: confidenceLevel,
            sampleCount: measurements.count,
            stdDev: stdDev
        )
    }
    
    /// Check if value is within confidence interval
    public func isWithinInterval(_ value: Double, confidenceLevel: Double = 0.95) -> Bool {
        guard let lastInterval = intervals.last,
              lastInterval.confidence == confidenceLevel else {
            return false
        }
        
        return value >= lastInterval.lower && value <= lastInterval.upper
    }
    
    // MARK: - Queries
    
    /// Get current confidence interval
    public func getCurrentInterval(confidenceLevel: Double = 0.95) -> (lower: Double, upper: Double)? {
        return intervals.last(where: { $0.confidence == confidenceLevel }).map { ($0.lower, $0.upper) }
    }
    
    /// Get measurement statistics
    public func getStatistics() -> MeasurementStatistics? {
        guard !measurements.isEmpty else { return nil }
        
        let mean = measurements.reduce(0.0, +) / Double(measurements.count)
        let sorted = measurements.sorted()
        let median = sorted[sorted.count / 2]
        let min = sorted.first!
        let max = sorted.last!
        let variance = measurements.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(measurements.count)
        let stdDev = sqrt(variance)
        
        return MeasurementStatistics(
            mean: mean,
            median: median,
            min: min,
            max: max,
            stdDev: stdDev,
            sampleCount: measurements.count
        )
    }
    
    // MARK: - Result Types
    
    /// Confidence interval result
    public struct ConfidenceIntervalResult: Sendable {
        public let mean: Double
        public let lower: Double
        public let upper: Double
        public let confidence: Double
        public let sampleCount: Int
        public let stdDev: Double
    }
    
    /// Measurement statistics
    public struct MeasurementStatistics: Sendable {
        public let mean: Double
        public let median: Double
        public let min: Double
        public let max: Double
        public let stdDev: Double
        public let sampleCount: Int
    }
}
