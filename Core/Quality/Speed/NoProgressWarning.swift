// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  NoProgressWarning.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 6
//  NoProgressWarning - no progress warning state machine
//

import Foundation

/// NoProgressWarningStateMachine - small state machine for no progress warning
/// States: armed → fired → cooldown
public enum NoProgressWarningState {
    case armed
    case fired
    case cooldown
}

/// NoProgressWarning - manages no progress warning
public class NoProgressWarning {
    private var state: NoProgressWarningState = .armed
    private var armedTime: Int64?
    
    public init() {}
    
    /// Update state based on no progress duration
    /// 2s no white progress → speed must drop
    public func update(noProgressDurationMs: Int64) {
        switch state {
        case .armed:
            if noProgressDurationMs >= QualityPreCheckConstants.NO_PROGRESS_WARNING_MS {
                state = .fired
                // Trigger speed drop
            }
            
        case .fired:
            // Enter cooldown after firing
            state = .cooldown
            armedTime = MonotonicClock.nowMs()
            
        case .cooldown:
            // Check if cooldown expired
            if let armed = armedTime {
                let cooldownMs = Int64(1000)  // 1 second cooldown
                if MonotonicClock.nowMs() - armed >= cooldownMs {
                    state = .armed
                    armedTime = nil
                }
            }
        }
    }
    
    /// Check if warning is active
    public func isWarningActive() -> Bool {
        return state == .fired
    }
}

