// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityMetricAggregator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 3 + E: 质量指标和鲁棒性
// 质量指标聚合，多指标融合，加权平均
//

import Foundation

/// Quality metric aggregator
///
/// Aggregates multiple quality metrics with weighted averaging.
/// Fuses different quality indicators into unified scores.
public actor QualityMetricAggregator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Metric history
    private var metricHistory: [(timestamp: Date, metrics: [String: Double], aggregated: Double)] = []
    
    /// Metric weights
    private var metricWeights: [String: Double] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
        // Initialize default weights directly in init
        metricWeights = [
            "sharpness": 0.25,
            "exposure": 0.20,
            "contrast": 0.15,
            "color": 0.15,
            "noise": 0.10,
            "motion": 0.10,
            "focus": 0.05
        ]
    }
    
    // MARK: - Metric Aggregation
    
    /// Aggregate quality metrics
    ///
    /// Combines multiple quality metrics into a single aggregated score
    public func aggregateMetrics(_ metrics: [String: Double]) -> AggregatedQualityResult {
        // Normalize metrics to [0, 1] range
        let normalizedMetrics = normalizeMetrics(metrics)
        
        // Compute weighted average
        var weightedSum = 0.0
        var totalWeight = 0.0
        
        for (metric, value) in normalizedMetrics {
            let weight = metricWeights[metric] ?? 0.0
            weightedSum += value * weight
            totalWeight += weight
        }
        
        let aggregatedScore = totalWeight > 0 ? weightedSum / totalWeight : 0.0
        
        // Record in history
        let record = (timestamp: Date(), metrics: normalizedMetrics, aggregated: aggregatedScore)
        metricHistory.append(record)
        
        // Keep only recent history (last 1000)
        if metricHistory.count > 1000 {
            metricHistory.removeFirst()
        }
        
        return AggregatedQualityResult(
            score: aggregatedScore,
            normalizedMetrics: normalizedMetrics,
            weights: metricWeights,
            timestamp: Date()
        )
    }
    
    /// Normalize metrics to [0, 1] range
    private func normalizeMetrics(_ metrics: [String: Double]) -> [String: Double] {
        var normalized: [String: Double] = [:]
        
        for (key, value) in metrics {
            // Assume metrics are already in reasonable ranges
            // Clamp to [0, 1] and normalize if needed
            let normalizedValue = max(0.0, min(1.0, value))
            normalized[key] = normalizedValue
        }
        
        return normalized
    }
    
    // MARK: - Weight Management
    
    /// Set metric weight
    public func setWeight(for metric: String, weight: Double) {
        metricWeights[metric] = max(0.0, min(1.0, weight))
    }
    
    /// Get metric weights
    public func getWeights() -> [String: Double] {
        return metricWeights
    }
    
    // MARK: - Queries
    
    /// Get average aggregated score
    public func getAverageScore() -> Double? {
        guard !metricHistory.isEmpty else { return nil }
        let sum = metricHistory.reduce(0.0) { $0 + $1.aggregated }
        return sum / Double(metricHistory.count)
    }
    
    /// Get recent metrics
    public func getRecentMetrics(count: Int = 10) -> [(timestamp: Date, metrics: [String: Double], aggregated: Double)] {
        return Array(metricHistory.suffix(count))
    }
    
    // MARK: - Result Types
    
    /// Aggregated quality result
    public struct AggregatedQualityResult: Sendable {
        public let score: Double
        public let normalizedMetrics: [String: Double]
        public let weights: [String: Double]
        public let timestamp: Date
    }
}
