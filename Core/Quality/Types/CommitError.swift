// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CommitError.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Commit error enumeration (PART 0.1)
//

import Foundation

/// CommitError - closed set of commit errors
/// PR5.1: Enhanced with extended error codes and SQL operation context
public indirect enum CommitError: Error, Codable, Equatable {
    case databaseBusy(extendedCode: Int32? = nil, sqlOperation: String? = nil)
    case databaseLocked(extendedCode: Int32? = nil, sqlOperation: String? = nil)
    case databaseIOError(extendedCode: Int32? = nil, sqlOperation: String? = nil)
    case databaseCorrupt(extendedCode: Int32? = nil, sqlOperation: String? = nil)
    case databaseFull(extendedCode: Int32? = nil, sqlOperation: String? = nil)
    case databaseUnknown(code: Int, extendedCode: Int32? = nil, sqlOperation: String? = nil, errorMessage: String? = nil)
    case payloadTooLarge
    case invalidCellIndex
    case deltaTooLarge
    case concurrentWriteConflict
    case maxRetriesExceeded(lastError: CommitError? = nil)
    case migrationInProgress
    case emergencyTierBlocked
    case corruptedEvidence
    
    /// Get primary error code for databaseUnknown cases
    public var primaryCode: Int? {
        if case .databaseUnknown(let code, _, _, _) = self {
            return code
        }
        return nil
    }
    
    /// Get extended error code if available
    public var extendedCode: Int32? {
        switch self {
        case .databaseBusy(let ext, _), .databaseLocked(let ext, _), .databaseIOError(let ext, _),
             .databaseCorrupt(let ext, _), .databaseFull(let ext, _):
            return ext
        case .databaseUnknown(_, let ext, _, _):
            return ext
        default:
            return nil
        }
    }
    
    /// Get SQL operation tag for debugging
    public var sqlOperation: String? {
        switch self {
        case .databaseBusy(_, let op), .databaseLocked(_, let op), .databaseIOError(_, let op),
             .databaseCorrupt(_, let op), .databaseFull(_, let op):
            return op
        case .databaseUnknown(_, _, let op, _):
            return op
        default:
            return nil
        }
    }
}

