// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  CoverageDelta.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  CoverageDelta - delta encoding for coverage changes (P4/P21/P23/H1/H2)
//
//  CHANGED (v6.0): Byte order unified to BIG-ENDIAN for consistency
//  with CanonicalBinaryCodec and all other binary encodings in the project.
//  Previous LE encoding was inconsistent with project-wide BE standard.
//

import Foundation

/// CoverageDelta - delta encoding for coverage changes
///
/// **Rule ID:** A2, P23, H1, H2
/// **Status:** SEALED (v6.0)
///
/// **CHANGED (v6.0):** All integer fields now use BIG-ENDIAN encoding
/// for consistency with CanonicalBinaryCodec and project-wide standards.
///
/// **H1:** Validity limits, sorting, deduplication
public struct CoverageDelta {
    /// Changed cells: (cellIndex, newState)
    public struct CellChange {
        public let cellIndex: UInt32
        public let newState: UInt8
        
        public init(cellIndex: UInt32, newState: UInt8) {
            self.cellIndex = cellIndex
            self.newState = newState
        }
    }
    
    public let changes: [CellChange]
    
    public init(changes: [CellChange]) {
        self.changes = changes
    }
    
    /// Encode to binary payload (BIG-ENDIAN)
    ///
    /// **Layout (v6.0):**
    /// - changedCount: UInt32 BE (4 bytes)
    /// - For each change:
    ///   - cellIndex: UInt32 BE (4 bytes)
    ///   - newState: UInt8 (1 byte)
    ///
    /// **CHANGED (v6.0):** Now uses BIG-ENDIAN for consistency with
    /// CanonicalBinaryCodec and project-wide encoding standards.
    ///
    /// **H1:** Sort by cellIndex, deduplicate (last-write-wins)
    public func encode() throws -> Data {
        // H1: Validate limits
        guard changes.count <= QualityPreCheckConstants.MAX_DELTA_CHANGED_COUNT else {
            throw CommitError.deltaTooLarge
        }

        // H1: Sort by cellIndex and deduplicate (last-write-wins)
        var sortedChanges = changes
        sortedChanges.sort { $0.cellIndex < $1.cellIndex }

        // Deduplicate: keep last occurrence for each cellIndex
        var deduplicated: [CellChange] = []
        var seen: Set<UInt32> = []
        for change in sortedChanges.reversed() {
            if !seen.contains(change.cellIndex) {
                seen.insert(change.cellIndex)
                deduplicated.append(change)
            }
        }
        deduplicated.reverse() // Restore ascending order

        // Validate cellIndex bounds
        for change in deduplicated {
            guard change.cellIndex <= UInt32(QualityPreCheckConstants.MAX_CELL_INDEX) else {
                throw CommitError.invalidCellIndex
            }
            // Validate newState (P21)
            guard change.newState <= 2 else {
                throw CommitError.corruptedEvidence
            }
        }

        // Encode: changedCount (u32 BE) + (cellIndex u32 BE, newState u8)...
        var data = Data()
        data.reserveCapacity(4 + deduplicated.count * 5) // Pre-allocate for determinism

        // changedCount (u32 BE) - CHANGED from LE to BE
        let changedCount = UInt32(deduplicated.count)
        withUnsafeBytes(of: changedCount.bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }

        // Each change: cellIndex (u32 BE) + newState (u8)
        for change in deduplicated {
            // cellIndex (u32 BE) - CHANGED from LE to BE
            withUnsafeBytes(of: change.cellIndex.bigEndian) { bytes in
                data.append(contentsOf: bytes)
            }

            // newState (u8, no endianness)
            data.append(change.newState)
        }

        return data
    }
    
    /// Compute coverage delta SHA256 hash
    public func computeSHA256() throws -> String {
        let payload = try encode()
        return SHA256Utility.sha256(payload)
    }
}

