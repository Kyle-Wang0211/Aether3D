// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  VisualStateMachine.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 3
//  VisualStateMachine - user-facing visual state (never retreats)
//

import Foundation

/// VisualStateMachine - manages VisualState transitions
/// Never retreats: uses max() to enforce forward progression
public class VisualStateMachine {
    private var currentState: VisualState = .black
    
    public init() {}
    
    /// Get current visual state
    public func getCurrentState() -> VisualState {
        return currentState
    }
    
    /// Update visual state (never retreats)
    /// Uses max() to enforce forward progression
    public func updateState(_ newState: VisualState) -> VisualState {
        let updatedState = max(currentState, newState)
        currentState = updatedState
        return updatedState
    }
    
    /// Reset to initial state
    public func reset() {
        currentState = .black
    }
}

