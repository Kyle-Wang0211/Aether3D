// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SoftGateMachine.swift
// PR4Gate
//
// PR4 V10 - Pillar 37: Soft gate state machine
//

import Foundation
import PR4Math
import PR4Health

/// Soft gate state machine
public enum SoftGateMachine {
    
    /// Transition gate state
    public static func transition(
        currentState: SoftGateState,
        health: Double,
        quality: Double,
        threshold: Double = 0.7
    ) -> GateDecision {
        let isHealthy = HealthComputer.isHealthy(health)
        let isGoodQuality = quality >= threshold
        
        let shouldEnable = isHealthy && isGoodQuality
        
        let newState: SoftGateState
        let reason: String
        
        switch currentState {
        case .enabled:
            if !shouldEnable {
                newState = .disablingConfirming
                reason = "Health/quality degraded"
            } else {
                newState = .enabled
                reason = "Still healthy"
            }
            
        case .disabled:
            if shouldEnable {
                newState = .enablingConfirming
                reason = "Health/quality improved"
            } else {
                newState = .disabled
                reason = "Still degraded"
            }
            
        case .disablingConfirming:
            if shouldEnable {
                newState = .enabled
                reason = "Recovered during confirmation"
            } else {
                newState = .disabled
                reason = "Confirmed degraded"
            }
            
        case .enablingConfirming:
            if !shouldEnable {
                newState = .disabled
                reason = "Degraded during confirmation"
            } else {
                newState = .enabled
                reason = "Confirmed healthy"
            }
        }
        
        return GateDecision(
            previousState: currentState,
            newState: newState,
            reason: reason
        )
    }
}
