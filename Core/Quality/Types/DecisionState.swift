//
//  DecisionState.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  DecisionState enumeration - internal decision state (can freeze)
//

import Foundation

/// DecisionState - internal decision state machine
/// Can freeze (unlike VisualState which never retreats)
public enum DecisionState: String, Codable {
    case active = "active"
    case frozen = "frozen"
    case directionComplete = "directionComplete"
    case sessionComplete = "sessionComplete"
}

