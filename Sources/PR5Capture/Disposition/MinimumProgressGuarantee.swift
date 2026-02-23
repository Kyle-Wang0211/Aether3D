// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MinimumProgressGuarantee.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 2 + D: 帧处理决策和账本完整性
// 停滞检测，进度保证激活，增量乘数调整
//

import Foundation

/// Minimum progress guarantee
///
/// Detects stagnation and activates progress guarantees.
/// Adjusts increment multipliers to ensure forward progress.
public actor MinimumProgressGuarantee {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Progress history (frame ID -> progress value)
    private var progressHistory: [UInt64: Double] = [:]
    
    /// Stagnation detection state
    private var stagnationDetected: Bool = false
    private var stagnationStartTime: Date?
    
    /// Current increment multiplier
    private var incrementMultiplier: Double = 1.0
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Progress Tracking
    
    /// Record frame progress
    ///
    /// Tracks progress and detects stagnation
    public func recordProgress(
        frameId: UInt64,
        progress: Double
    ) -> ProgressAnalysisResult {
        // Record progress
        progressHistory[frameId] = progress
        
        // Keep only recent history (last 100 frames)
        if progressHistory.count > 100 {
            let sortedKeys = progressHistory.keys.sorted()
            for key in sortedKeys.prefix(progressHistory.count - 100) {
                progressHistory.removeValue(forKey: key)
            }
        }
        
        // Detect stagnation
        let stagnationResult = detectStagnation()
        
        // Adjust multiplier if stagnation detected
        if stagnationResult.isStagnant {
            if !stagnationDetected {
                stagnationDetected = true
                stagnationStartTime = Date()
            }
            
            // Increase multiplier to force progress
            incrementMultiplier = min(2.0, incrementMultiplier * 1.1)
        } else {
            if stagnationDetected {
                stagnationDetected = false
                stagnationStartTime = nil
            }
            
            // Gradually reduce multiplier back to normal
            incrementMultiplier = max(1.0, incrementMultiplier * 0.95)
        }
        
        return ProgressAnalysisResult(
            frameId: frameId,
            progress: progress,
            isStagnant: stagnationResult.isStagnant,
            stagnationDuration: stagnationResult.duration,
            incrementMultiplier: incrementMultiplier,
            threshold: PR5CaptureConstants.getValue(
                PR5CaptureConstants.Disposition.minimumProgressThreshold,
                profile: config.profile
            )
        )
    }
    
    /// Detect stagnation
    private func detectStagnation() -> StagnationResult {
        guard progressHistory.count >= 5 else {
            return StagnationResult(isStagnant: false, duration: 0.0)
        }
        
        // Get recent progress values
        let recentProgress = Array(progressHistory.values.suffix(5))
        
        // Check if progress is below threshold
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Disposition.minimumProgressThreshold,
            profile: config.profile
        )
        
        let avgProgress = recentProgress.reduce(0.0, +) / Double(recentProgress.count)
        let isStagnant = avgProgress < threshold
        
        // Check if progress is not increasing
        let progressDelta = recentProgress.last! - recentProgress.first!
        let isNotIncreasing = progressDelta < threshold * 0.1
        
        let stagnant = isStagnant || isNotIncreasing
        
        let duration: TimeInterval
        if stagnant, let startTime = stagnationStartTime {
            duration = Date().timeIntervalSince(startTime)
        } else {
            duration = 0.0
        }
        
        return StagnationResult(
            isStagnant: stagnant,
            duration: duration
        )
    }
    
    /// Get current increment multiplier
    public func getIncrementMultiplier() -> Double {
        return incrementMultiplier
    }
    
    /// Reset multiplier
    public func resetMultiplier() {
        incrementMultiplier = 1.0
        stagnationDetected = false
        stagnationStartTime = nil
    }
    
    // MARK: - Data Types
    
    /// Stagnation result
    private struct StagnationResult {
        let isStagnant: Bool
        let duration: TimeInterval
    }
    
    /// Progress analysis result
    public struct ProgressAnalysisResult: Sendable {
        public let frameId: UInt64
        public let progress: Double
        public let isStagnant: Bool
        public let stagnationDuration: TimeInterval
        public let incrementMultiplier: Double
        public let threshold: Double
    }
}
