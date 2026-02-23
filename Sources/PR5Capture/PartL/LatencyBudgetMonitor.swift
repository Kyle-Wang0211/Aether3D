// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// LatencyBudgetMonitor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// 延迟预算监控，帧时间追踪
//

import Foundation

/// Latency budget monitor
///
/// Monitors latency budgets and tracks frame times.
/// Ensures frame processing stays within budget.
public actor LatencyBudgetMonitor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Frame time history
    private var frameTimes: [TimeInterval] = []
    
    /// Budget violations
    private var violations: [(timestamp: Date, frameTime: TimeInterval, budget: TimeInterval)] = []
    
    /// Target frame time (e.g., 16.67ms for 60fps)
    private let targetFrameTime: TimeInterval = 0.01667
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Monitoring
    
    /// Record frame time
    public func recordFrameTime(_ time: TimeInterval) -> MonitoringResult {
        frameTimes.append(time)
        
        // Keep only recent history (last 100)
        if frameTimes.count > 100 {
            frameTimes.removeFirst()
        }
        
        // Check budget violation
        if time > targetFrameTime {
            violations.append((timestamp: Date(), frameTime: time, budget: targetFrameTime))
            
            // Keep only recent violations (last 50)
            if violations.count > 50 {
                violations.removeFirst()
            }
        }
        
        return MonitoringResult(
            frameTime: time,
            withinBudget: time <= targetFrameTime,
            budget: targetFrameTime,
            violationCount: violations.count
        )
    }
    
    /// Get average frame time
    public func getAverageFrameTime() -> TimeInterval? {
        guard !frameTimes.isEmpty else { return nil }
        return frameTimes.reduce(0.0, +) / Double(frameTimes.count)
    }
    
    // MARK: - Result Types
    
    /// Monitoring result
    public struct MonitoringResult: Sendable {
        public let frameTime: TimeInterval
        public let withinBudget: Bool
        public let budget: TimeInterval
        public let violationCount: Int
    }
}
