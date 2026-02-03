//
// GateDecision.swift
// PR4Gate
//
// PR4 V10 - Pillar 37: Gate decision structure
//

import Foundation
import PR4Protocols

/// Gate decision
public struct GateDecision: HasNewState {
    public let previousState: SoftGateState
    public let newState: SoftGateState
    public let reason: String

    public init(previousState: SoftGateState, newState: SoftGateState, reason: String) {
        self.previousState = previousState
        self.newState = newState
        self.reason = reason
    }

    // MARK: - HasNewState conformance

    public var newStateAny: Any { newState }
}
