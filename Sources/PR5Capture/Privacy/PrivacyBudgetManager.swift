// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PrivacyBudgetManager.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 7 + I: 隐私加固和双轨
// 隐私预算管理，差分隐私，预算跟踪
//

import Foundation

/// Privacy budget manager
///
/// Manages privacy budget for differential privacy.
/// Tracks and enforces privacy budget limits.
public actor PrivacyBudgetManager {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Current budget
    private var remainingBudget: Double = 1.0
    
    /// Budget usage history
    private var usageHistory: [(timestamp: Date, amount: Double, operation: String)] = []
    
    /// Budget reset time
    private var lastResetTime: Date = Date()
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Budget Management
    
    /// Check if operation is allowed
    ///
    /// Verifies if privacy budget allows operation
    public func canPerformOperation(_ cost: Double) -> BudgetCheckResult {
        // Reset budget periodically (daily)
        if Date().timeIntervalSince(lastResetTime) >= 86400 {
            remainingBudget = 1.0
            lastResetTime = Date()
        }
        
        if cost > remainingBudget {
            return .exceeded(requested: cost, available: remainingBudget)
        }
        
        // Deduct cost
        remainingBudget -= cost
        
        // Record usage
        usageHistory.append((timestamp: Date(), amount: cost, operation: "operation"))
        
        // Keep only recent history (last 100)
        if usageHistory.count > 100 {
            usageHistory.removeFirst()
        }
        
        return .allowed(cost: cost, remaining: remainingBudget)
    }
    
    /// Get current budget
    public func getCurrentBudget() -> Double {
        // Reset if needed
        if Date().timeIntervalSince(lastResetTime) >= 86400 {
            remainingBudget = 1.0
            lastResetTime = Date()
        }
        
        return remainingBudget
    }
    
    // MARK: - Result Types
    
    /// Budget check result
    public enum BudgetCheckResult: Sendable {
        case allowed(cost: Double, remaining: Double)
        case exceeded(requested: Double, available: Double)
    }
}
