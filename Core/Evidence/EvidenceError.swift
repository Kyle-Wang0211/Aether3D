// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceError.swift
// Aether3D
//
// PR2 Patch V4 - Evidence System Errors
//

import Foundation

/// Evidence-related errors
public enum EvidenceError: Error, Equatable {
    case incompatibleSchemaVersion(expected: String, found: String)
    case invalidEvidenceValue(value: Double, reason: String)
    case patchNotFound(patchId: String)
    case serializationFailed(reason: String)
    case deserializationFailed(reason: String)
    
    public var localizedDescription: String {
        switch self {
        case .incompatibleSchemaVersion(let expected, let found):
            return "Incompatible schema version: expected \(expected), found \(found)"
        case .invalidEvidenceValue(let value, let reason):
            return "Invalid evidence value \(value): \(reason)"
        case .patchNotFound(let patchId):
            return "Patch not found: \(patchId)"
        case .serializationFailed(let reason):
            return "Serialization failed: \(reason)"
        case .deserializationFailed(let reason):
            return "Deserialization failed: \(reason)"
        }
    }
}
