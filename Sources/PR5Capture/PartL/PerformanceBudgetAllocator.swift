// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PerformanceBudgetAllocator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// 性能预算分配器，CPU/GPU/内存配额
//

import Foundation

/// Performance budget allocator
///
/// Allocates performance budgets for CPU/GPU/memory.
/// Manages resource quotas and enforces limits.
public actor PerformanceBudgetAllocator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Budget Types
    
    public enum BudgetType: String, Sendable {
        case cpu
        case gpu
        case memory
        case network
    }
    
    // MARK: - State
    
    /// Allocated budgets
    private var budgets: [BudgetType: Double] = [:]
    
    /// Used budgets
    private var used: [BudgetType: Double] = [:]

    private static let defaultBudgets: [BudgetType: Double] = [
        .cpu: 0.8,
        .gpu: 0.7,
        .memory: 0.6,
        .network: 0.5,
    ]

    private static let defaultUsed: [BudgetType: Double] = [
        .cpu: 0.0,
        .gpu: 0.0,
        .memory: 0.0,
        .network: 0.0,
    ]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
        self.budgets = Self.defaultBudgets
        self.used = Self.defaultUsed
    }
    
    // MARK: - Budget Management
    
    /// Allocate budget
    public func allocate(_ amount: Double, for type: BudgetType) -> AllocationResult {
        let available = budgets[type] ?? 0.0
        let currentUsed = used[type] ?? 0.0
        let remaining = available - currentUsed
        
        if amount > remaining {
            return .exceeded(requested: amount, available: remaining)
        }
        
        used[type, default: 0.0] += amount
        
        return .allocated(amount: amount, remaining: remaining - amount)
    }
    
    /// Release budget
    public func release(_ amount: Double, for type: BudgetType) {
        used[type, default: 0.0] = max(0.0, (used[type] ?? 0.0) - amount)
    }
    
    /// Get remaining budget
    public func getRemaining(for type: BudgetType) -> Double {
        let available = budgets[type] ?? 0.0
        let currentUsed = used[type] ?? 0.0
        return max(0.0, available - currentUsed)
    }
    
    // MARK: - Result Types
    
    /// Allocation result
    public enum AllocationResult: Sendable {
        case allocated(amount: Double, remaining: Double)
        case exceeded(requested: Double, available: Double)
    }
}
