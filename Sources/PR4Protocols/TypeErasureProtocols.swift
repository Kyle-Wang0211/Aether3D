// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TypeErasureProtocols.swift
// PR4Protocols
//
// PR4 V10 - Foundation protocols for type-erased cross-module communication
// This module has NO dependencies and can be imported by any PR4 module.
//

import Foundation

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Type-Erased Protocols
// ═══════════════════════════════════════════════════════════════════════

/// Protocol for types that have a Double value (e.g., QualityResult)
public protocol HasDoubleValue {
    var doubleValue: Double { get }
}

/// Protocol for types that have a newState (e.g., GateDecision)
public protocol HasNewState {
    var newStateAny: Any { get }
}

/// Protocol for types that can be identified by a frame
public protocol FrameScoped {
    var frameIndex: UInt64 { get }
}

/// Protocol for types that belong to a session
public protocol SessionScoped {
    var sessionId: UUID { get }
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Common Type Aliases
// ═══════════════════════════════════════════════════════════════════════

/// Source identifier type
public typealias SourceID = String

/// Depth sample type
public typealias DepthSample = Double

/// Calibration data type
public typealias CalibrationData = [String: Double]
