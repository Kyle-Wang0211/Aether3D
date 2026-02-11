// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GracefulDegradationHandler.swift
// PR5Capture
//
// PR5 v1.8.1 - PART N: 崩溃恢复
// 优雅降级处理，功能逐级关闭
//

import Foundation

/// Graceful degradation handler
///
/// Handles graceful degradation with progressive feature shutdown.
/// Implements tiered degradation strategies.
public actor GracefulDegradationHandler {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Degradation Levels
    
    public enum DegradationLevel: Int, Sendable, Comparable {
        case none = 0
        case light = 1
        case moderate = 2
        case severe = 3
        case critical = 4
        
        public static func < (lhs: DegradationLevel, rhs: DegradationLevel) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
    
    // MARK: - State
    
    /// Current degradation level
    private var currentLevel: DegradationLevel = .none
    
    /// Degradation history
    private var degradationHistory: [(timestamp: Date, level: DegradationLevel)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Degradation Handling
    
    /// Apply degradation
    public func applyDegradation(_ level: DegradationLevel) -> DegradationResult {
        currentLevel = level
        
        // Record degradation
        degradationHistory.append((timestamp: Date(), level: level))
        
        // Keep only recent history (last 100)
        if degradationHistory.count > 100 {
            degradationHistory.removeFirst()
        }
        
        // Determine disabled features
        let disabledFeatures = getDisabledFeatures(for: level)
        
        return DegradationResult(
            level: level,
            disabledFeatures: disabledFeatures,
            timestamp: Date()
        )
    }
    
    /// Get disabled features for level
    private func getDisabledFeatures(for level: DegradationLevel) -> [String] {
        switch level {
        case .none:
            return []
        case .light:
            return ["nonEssentialFeatures"]
        case .moderate:
            return ["nonEssentialFeatures", "advancedProcessing"]
        case .severe:
            return ["nonEssentialFeatures", "advancedProcessing", "qualityEnhancement"]
        case .critical:
            return ["nonEssentialFeatures", "advancedProcessing", "qualityEnhancement", "backgroundTasks"]
        }
    }
    
    // MARK: - Result Types
    
    /// Degradation result
    public struct DegradationResult: Sendable {
        public let level: DegradationLevel
        public let disabledFeatures: [String]
        public let timestamp: Date
    }
}
