//
//  VisualState.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  VisualState enumeration - user-facing visual state (never retreats)
//

import Foundation

/// VisualState - user-facing visual state machine
/// Never retreats: uses max() to enforce forward progression
public enum VisualState: String, Codable, Comparable {
    case black = "black"
    case gray = "gray"
    case white = "white"
    case clear = "clear"
    
    /// Comparable implementation for max() enforcement
    /// Order: black < gray < white < clear
    public static func < (lhs: VisualState, rhs: VisualState) -> Bool {
        let order: [VisualState] = [.black, .gray, .white, .clear]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

