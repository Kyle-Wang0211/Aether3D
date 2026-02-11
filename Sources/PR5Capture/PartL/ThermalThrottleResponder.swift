// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ThermalThrottleResponder.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// 热节流响应，温度触发降级
//

import Foundation

/// Thermal throttle responder
///
/// Responds to thermal throttling with temperature-triggered degradation.
/// Implements thermal management strategies.
public actor ThermalThrottleResponder {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Thermal States
    
    public enum ThermalState: String, Sendable {
        case normal
        case warm
        case hot
        case critical
    }
    
    // MARK: - State
    
    /// Current thermal state
    private var currentState: ThermalState = .normal
    
    /// Thermal history
    private var thermalHistory: [(timestamp: Date, state: ThermalState)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Thermal Response
    
    /// Respond to thermal state
    public func respondToThermalState(_ state: ThermalState) -> ResponseResult {
        currentState = state
        
        // Record thermal event
        thermalHistory.append((timestamp: Date(), state: state))
        
        // Keep only recent history (last 100)
        if thermalHistory.count > 100 {
            thermalHistory.removeFirst()
        }
        
        // Determine degradation level
        let degradation: DegradationLevel
        switch state {
        case .normal:
            degradation = .none
        case .warm:
            degradation = .light
        case .hot:
            degradation = .moderate
        case .critical:
            degradation = .aggressive
        }
        
        return ResponseResult(
            state: state,
            degradation: degradation,
            timestamp: Date()
        )
    }
    
    // MARK: - Result Types
    
    /// Degradation level
    public enum DegradationLevel: String, Sendable {
        case none
        case light
        case moderate
        case aggressive
    }
    
    /// Response result
    public struct ResponseResult: Sendable {
        public let state: ThermalState
        public let degradation: DegradationLevel
        public let timestamp: Date
    }
}
