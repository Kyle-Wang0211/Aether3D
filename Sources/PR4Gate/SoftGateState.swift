//
// SoftGateState.swift
// PR4Gate
//
// PR4 V10 - Pillar 37: Soft gate state machine
//

import Foundation

/// Soft gate state
public enum SoftGateState: String, Codable {
    case enabled
    case disabled
    case disablingConfirming
    case enablingConfirming
}
