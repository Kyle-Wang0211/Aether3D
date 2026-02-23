// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AdaptiveThresholdManager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 3 + E: 质量指标和鲁棒性
// 自适应阈值管理，动态调整，上下文感知
//

import Foundation

/// Adaptive threshold manager
///
/// Manages adaptive thresholds that adjust based on context.
/// Provides context-aware threshold adjustment.
public actor AdaptiveThresholdManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Current thresholds
    private var thresholds: [String: Double] = [:]
    
    /// Threshold history
    private var thresholdHistory: [(timestamp: Date, thresholds: [String: Double], context: String)] = []
    
    /// Context factors
    private var contextFactors: [String: Double] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
        // Initialize default thresholds directly in init
        thresholds = [
            "quality": 0.7,
            "sharpness": 0.6,
            "exposure": 0.65,
            "contrast": 0.6,
            "noise": 0.3  // Lower is better for noise
        ]
    }
    
    // MARK: - Threshold Management
    
    /// Get threshold for metric
    public func getThreshold(for metric: String) -> Double {
        return thresholds[metric] ?? 0.5
    }
    
    /// Set threshold for metric
    public func setThreshold(for metric: String, value: Double) {
        thresholds[metric] = max(0.0, min(1.0, value))
    }
    
    /// Adapt thresholds based on context
    ///
    /// Adjusts thresholds based on current context factors
    public func adaptThresholds(context: [String: Double]) -> AdaptationResult {
        contextFactors = context
        
        var adapted: [String: Double] = [:]
        var changes: [String: (old: Double, new: Double)] = [:]
        
        for (metric, baseThreshold) in thresholds {
            // Compute adaptation factor from context
            let adaptationFactor = computeAdaptationFactor(metric: metric, context: context)
            let newThreshold = baseThreshold * adaptationFactor
            
            adapted[metric] = newThreshold
            
            if abs(newThreshold - baseThreshold) > 0.01 {
                changes[metric] = (old: baseThreshold, new: newThreshold)
            }
        }
        
        // Record adaptation
        thresholdHistory.append((timestamp: Date(), thresholds: adapted, context: context.description))
        
        // Keep only recent history (last 100)
        if thresholdHistory.count > 100 {
            thresholdHistory.removeFirst()
        }
        
        return AdaptationResult(
            adaptedThresholds: adapted,
            changes: changes,
            context: context
        )
    }
    
    /// Compute adaptation factor
    private func computeAdaptationFactor(metric: String, context: [String: Double]) -> Double {
        var factor = 1.0
        
        // Adapt based on lighting conditions
        if let lighting = context["lighting"] {
            if metric == "exposure" || metric == "noise" {
                // Lower threshold in low light (more lenient)
                factor *= (0.8 + lighting * 0.2)
            }
        }
        
        // Adapt based on motion
        if let motion = context["motion"] {
            if metric == "sharpness" {
                // Lower threshold with high motion (more lenient)
                factor *= (0.9 + (1.0 - motion) * 0.1)
            }
        }
        
        // Adapt based on scene complexity
        if let complexity = context["complexity"] {
            // More lenient for complex scenes
            factor *= (0.85 + complexity * 0.15)
        }
        
        return max(0.5, min(1.5, factor))  // Clamp to reasonable range
    }
    
    /// Apply adapted thresholds
    public func applyAdaptedThresholds(_ adapted: [String: Double]) {
        thresholds = adapted
    }
    
    // MARK: - Queries
    
    /// Get all thresholds
    public func getAllThresholds() -> [String: Double] {
        return thresholds
    }
    
    /// Get threshold history
    public func getThresholdHistory() -> [(timestamp: Date, thresholds: [String: Double], context: String)] {
        return thresholdHistory
    }
    
    // MARK: - Result Types
    
    /// Adaptation result
    public struct AdaptationResult: Sendable {
        public let adaptedThresholds: [String: Double]
        public let changes: [String: (old: Double, new: Double)]
        public let context: [String: Double]
    }
}
