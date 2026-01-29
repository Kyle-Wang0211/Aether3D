//
//  CoverageDelta.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 1
//  CoverageDelta - delta encoding for coverage changes (P4/P21/P23/H1/H2)
//

import Foundation

/// CoverageDelta - delta encoding for coverage changes
/// P23/H2: All integer fields are LITTLE-ENDIAN
/// H1: Validity limits, sorting, deduplication
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
    
    /// Encode to binary payload (LITTLE-ENDIAN)
    /// P23: changedCount (u32 LE) + repeated (cellIndex u32 LE, newState u8)
    /// H1: Sort by cellIndex, deduplicate (last-write-wins)
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
        
        // Encode: changedCount (u32 LE) + (cellIndex u32 LE, newState u8)...
        var data = Data()
        
        // changedCount (u32 LE)
        let changedCount = UInt32(deduplicated.count)
        withUnsafeBytes(of: changedCount.littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
        
        // Each change: cellIndex (u32 LE) + newState (u8)
        for change in deduplicated {
            // cellIndex (u32 LE)
            withUnsafeBytes(of: change.cellIndex.littleEndian) { bytes in
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

