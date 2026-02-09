// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BatteryAwareScheduler.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// 电池感知调度，低电量模式
//

import Foundation

/// Battery-aware scheduler
///
/// Schedules tasks with battery awareness.
/// Implements low-power mode strategies.
public actor BatteryAwareScheduler {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Battery States
    
    public enum BatteryState: String, Sendable {
        case charging
        case high      // > 50%
        case medium    // 20-50%
        case low       // < 20%
        case critical  // < 10%
    }
    
    // MARK: - State
    
    /// Current battery state
    private var currentState: BatteryState = .high
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Scheduling
    
    /// Schedule task based on battery state
    public func scheduleTask(_ task: ScheduledTask) -> SchedulingResult {
        let priority: TaskPriority
        
        switch currentState {
        case .charging, .high:
            priority = .normal
        case .medium:
            priority = .reduced
        case .low, .critical:
            priority = .minimal
        }
        
        return SchedulingResult(
            task: task,
            priority: priority,
            batteryState: currentState
        )
    }
    
    /// Update battery state
    public func updateBatteryState(_ state: BatteryState) {
        currentState = state
    }
    
    // MARK: - Data Types
    
    /// Scheduled task
    public struct ScheduledTask: Sendable {
        public let id: UUID
        public let name: String
        
        public init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
        }
    }
    
    /// Task priority
    public enum TaskPriority: String, Sendable {
        case normal
        case reduced
        case minimal
    }
    
    /// Scheduling result
    public struct SchedulingResult: Sendable {
        public let task: ScheduledTask
        public let priority: TaskPriority
        public let batteryState: BatteryState
    }
}
