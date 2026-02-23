// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MitigationStrategySelector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART O: 风险注册和治理
// 缓解策略选择，自动响应匹配
//

import Foundation

/// Mitigation strategy selector
///
/// Selects mitigation strategies with automatic response matching.
/// Provides risk-specific mitigation recommendations.
public actor MitigationStrategySelector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Strategy Types
    
    public enum MitigationStrategy: String, Sendable {
        case patch
        case workaround
        case accept
        case transfer
        case avoid
    }
    
    // MARK: - State
    
    /// Strategy history
    private var strategyHistory: [(timestamp: Date, riskId: String, strategy: MitigationStrategy)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Strategy Selection
    
    /// Select mitigation strategy
    public func selectStrategy(
        riskId: String,
        severity: RiskRegisterImplementation.RiskSeverity,
        score: Double
    ) -> SelectionResult {
        let strategy: MitigationStrategy
        
        switch severity {
        case .p0:
            strategy = .patch  // Critical: must patch
        case .p1:
            strategy = score > 7.0 ? .patch : .workaround
        case .p2:
            strategy = .workaround
        case .p3:
            strategy = .accept  // Low: can accept
        }
        
        // Record selection
        strategyHistory.append((timestamp: Date(), riskId: riskId, strategy: strategy))
        
        // Keep only recent history (last 1000)
        if strategyHistory.count > 1000 {
            strategyHistory.removeFirst()
        }
        
        return SelectionResult(
            riskId: riskId,
            strategy: strategy,
            timestamp: Date()
        )
    }
    
    // MARK: - Result Types
    
    /// Selection result
    public struct SelectionResult: Sendable {
        public let riskId: String
        public let strategy: MitigationStrategy
        public let timestamp: Date
    }
}
