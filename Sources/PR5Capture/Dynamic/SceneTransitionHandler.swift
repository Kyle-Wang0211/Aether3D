// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SceneTransitionHandler.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 4 + F: 动态场景和细化
// 场景过渡处理，平滑过渡，状态保持
//

import Foundation

/// Scene transition handler
///
/// Handles scene transitions with smooth state preservation.
/// Manages transition between different scene types.
public actor SceneTransitionHandler {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Current scene type
    private var currentSceneType: DynamicSceneClassifier.SceneType?
    
    /// Transition history
    private var transitionHistory: [SceneTransition] = []
    
    /// Transition smoothing buffer
    private var transitionBuffer: [DynamicSceneClassifier.SceneType] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Transition Handling
    
    /// Handle scene transition
    ///
    /// Processes scene type changes with smoothing
    public func handleTransition(to newType: DynamicSceneClassifier.SceneType) -> TransitionResult {
        let previousType = currentSceneType
        
        // Add to buffer for smoothing
        transitionBuffer.append(newType)
        
        // Keep only recent buffer (last 5)
        if transitionBuffer.count > 5 {
            transitionBuffer.removeFirst()
        }
        
        // Determine smoothed transition (use most common in buffer)
        var typeCounts: [DynamicSceneClassifier.SceneType: Int] = [:]
        for type in transitionBuffer {
            typeCounts[type, default: 0] += 1
        }
        
        let smoothedType = typeCounts.max(by: { $0.value < $1.value })?.key ?? newType
        
        // Check if transition occurred
        let transitionOccurred = previousType != smoothedType
        
        if transitionOccurred {
            currentSceneType = smoothedType
            
            let transition = SceneTransition(
                from: previousType,
                to: smoothedType,
                timestamp: Date()
            )
            
            transitionHistory.append(transition)
            
            // Keep only recent history (last 50)
            if transitionHistory.count > 50 {
                transitionHistory.removeFirst()
            }
        }
        
        return TransitionResult(
            transitionOccurred: transitionOccurred,
            previousType: previousType,
            currentType: smoothedType,
            smoothed: smoothedType != newType
        )
    }
    
    // MARK: - Queries
    
    /// Get current scene type
    public func getCurrentSceneType() -> DynamicSceneClassifier.SceneType? {
        return currentSceneType
    }
    
    /// Get transition history
    public func getTransitionHistory() -> [SceneTransition] {
        return transitionHistory
    }
    
    // MARK: - Data Types
    
    /// Scene transition
    public struct SceneTransition: Sendable {
        public let from: DynamicSceneClassifier.SceneType?
        public let to: DynamicSceneClassifier.SceneType
        public let timestamp: Date
    }
    
    /// Transition result
    public struct TransitionResult: Sendable {
        public let transitionOccurred: Bool
        public let previousType: DynamicSceneClassifier.SceneType?
        public let currentType: DynamicSceneClassifier.SceneType
        public let smoothed: Bool
    }
}
