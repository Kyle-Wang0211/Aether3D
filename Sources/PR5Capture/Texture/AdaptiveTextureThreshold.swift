// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AdaptiveTextureThreshold.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 5 + G: 纹理响应和闭环
// 自适应纹理阈值，上下文感知调整
//

import Foundation

/// Adaptive texture threshold manager
///
/// Manages adaptive texture thresholds with context awareness.
/// Adjusts thresholds based on scene characteristics.
public actor AdaptiveTextureThreshold {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Base threshold
    private var baseThreshold: Double = 0.7
    
    /// Current threshold
    private var currentThreshold: Double = 0.7
    
    /// Threshold history
    private var thresholdHistory: [(timestamp: Date, threshold: Double, context: String)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Threshold Management
    
    /// Adapt threshold based on context
    ///
    /// Adjusts threshold based on scene context
    public func adaptThreshold(context: [String: Double]) -> AdaptationResult {
        var adjustment: Double = 1.0
        
        // Adjust based on lighting
        if let lighting = context["lighting"] {
            // Lower threshold in low light (more lenient)
            adjustment *= (0.8 + lighting * 0.2)
        }
        
        // Adjust based on motion
        if let motion = context["motion"] {
            // Lower threshold with high motion
            adjustment *= (0.9 + (1.0 - motion) * 0.1)
        }
        
        // Apply adjustment
        let newThreshold = baseThreshold * adjustment
        currentThreshold = max(0.3, min(1.0, newThreshold))
        
        // Record adaptation
        thresholdHistory.append((timestamp: Date(), threshold: currentThreshold, context: context.description))
        
        // Keep only recent history (last 100)
        if thresholdHistory.count > 100 {
            thresholdHistory.removeFirst()
        }
        
        return AdaptationResult(
            oldThreshold: baseThreshold,
            newThreshold: currentThreshold,
            adjustment: adjustment
        )
    }
    
    /// Get current threshold
    public func getCurrentThreshold() -> Double {
        return currentThreshold
    }
    
    /// Reset to base threshold
    public func reset() {
        currentThreshold = baseThreshold
    }
    
    // MARK: - Result Types
    
    /// Adaptation result
    public struct AdaptationResult: Sendable {
        public let oldThreshold: Double
        public let newThreshold: Double
        public let adjustment: Double
    }
}
