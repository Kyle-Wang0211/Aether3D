// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CPUBudgetEnforcer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// CPU 预算强制，线程优先级管理
//

import Foundation

/// CPU budget enforcer
///
/// Enforces CPU budgets with thread priority management.
/// Controls CPU usage to stay within allocated budget.
public actor CPUBudgetEnforcer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// CPU usage history
    private var cpuUsage: [Double] = []
    
    /// Budget limit
    private let budgetLimit: Double = 0.8  // 80% CPU
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Budget Enforcement
    
    /// Check CPU budget
    public func checkBudget(_ currentUsage: Double) -> BudgetCheckResult {
        cpuUsage.append(currentUsage)
        
        // Keep only recent history (last 100)
        if cpuUsage.count > 100 {
            cpuUsage.removeFirst()
        }
        
        let exceedsBudget = currentUsage > budgetLimit
        
        return BudgetCheckResult(
            currentUsage: currentUsage,
            budgetLimit: budgetLimit,
            exceedsBudget: exceedsBudget,
            action: exceedsBudget ? .throttle : .allow
        )
    }
    
    // MARK: - Result Types
    
    /// Budget check result
    public struct BudgetCheckResult: Sendable {
        public let currentUsage: Double
        public let budgetLimit: Double
        public let exceedsBudget: Bool
        public let action: EnforcementAction
        
        public enum EnforcementAction: String, Sendable {
            case allow
            case throttle
            case suspend
        }
    }
}
