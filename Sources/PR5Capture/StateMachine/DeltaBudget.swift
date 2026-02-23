// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeltaBudget.swift
// PR5Capture
//
// PR5 v1.8.1 - PART C: 状态机增强
// Delta 乘数预算，防止乘数混乱，预算边界检查
//

import Foundation

/// Delta budget manager
///
/// Manages delta multiplier budget to prevent multiplier chaos.
/// Enforces budget boundaries and tracks usage.
public actor DeltaBudget {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Budget State
    
    /// Current budget remaining
    private var remainingBudget: Double = 1.0
    
    /// Budget usage history
    private var usageHistory: [(timestamp: Date, amount: Double, reason: String)] = []
    
    /// Budget reset time
    private var lastResetTime: Date = Date()
    
    /// Budget reset interval (1 second)
    private let resetInterval: TimeInterval = 1.0
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
        self.remainingBudget = 1.0
    }
    
    // MARK: - Budget Management
    
    /// Check if delta can be applied
    ///
    /// Verifies budget availability and applies delta if allowed
    public func canApplyDelta(_ delta: Double, reason: String = "") -> BudgetCheckResult {
        let now = Date()
        
        // Reset budget if interval elapsed
        if now.timeIntervalSince(lastResetTime) >= resetInterval {
            remainingBudget = 1.0
            lastResetTime = now
        }
        
        // Check if delta exceeds budget
        if abs(delta) > remainingBudget {
            return .exceeded(
                requested: delta,
                available: remainingBudget,
                reason: reason
            )
        }
        
        // Apply delta
        remainingBudget -= abs(delta)
        usageHistory.append((timestamp: now, amount: delta, reason: reason))
        
        // Keep only recent history (last 100)
        if usageHistory.count > 100 {
            usageHistory.removeFirst()
        }
        
        return .allowed(
            delta: delta,
            remainingBudget: remainingBudget
        )
    }
    
    /// Get current budget
    public func getCurrentBudget() -> Double {
        let now = Date()
        
        // Reset if needed
        if now.timeIntervalSince(lastResetTime) >= resetInterval {
            remainingBudget = 1.0
            lastResetTime = now
        }
        
        return remainingBudget
    }
    
    /// Get usage history
    public func getUsageHistory() -> [(timestamp: Date, amount: Double, reason: String)] {
        return usageHistory
    }
    
    /// Reset budget manually
    public func resetBudget() {
        remainingBudget = 1.0
        lastResetTime = Date()
    }
    
    // MARK: - Result Types
    
    /// Budget check result
    public enum BudgetCheckResult: Sendable {
        case allowed(delta: Double, remainingBudget: Double)
        case exceeded(requested: Double, available: Double, reason: String)
    }
}
