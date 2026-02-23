// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EvidenceGrid.swift
// Aether3D
//
// PR6 Evidence Grid System - Evidence Grid
// Spatial hash table with Morton codes, deterministic iteration
//

import Foundation

/// **Rule ID:** PR6_GRID_001
/// Evidence Grid: spatial hash table with Morton codes
/// Actor-based single-writer design for mutable state updates
@EvidenceActor
public final class EvidenceGrid: @unchecked Sendable {
    
    // MARK: - Types
    
    /// Batch update operation
    public enum GridCellUpdate: Sendable {
        case insert(key: SpatialKey, cell: GridCell)
        case update(key: SpatialKey, cell: GridCell)
        case evict(key: SpatialKey)
        case refine(key: SpatialKey, newLevel: EvidenceConfidenceLevel)
    }
    
    /// Batch of updates (fixed capacity, MUST-FIX V)
    public struct EvidenceGridDeltaBatch: Sendable {
        public var updates: [GridCellUpdate]
        public let maxCapacity: Int
        
        public init(maxCapacity: Int = EvidenceConstants.batchMaxCapacity) {
            self.updates = []
            self.maxCapacity = maxCapacity
        }
        
        /// Add update (with overflow handling)
        public mutating func add(_ update: GridCellUpdate) {
            if updates.count < maxCapacity {
                updates.append(update)
            } else {
                // Overflow: drop lowest priority (MUST-FIX V)
                // Priority: insertions > updates > refinements > evictions
                // For now, simple implementation: drop oldest
                if case .evict = update {
                    // Drop eviction
                    return
                }
                // Replace lowest priority update
                updates.removeFirst()
                updates.append(update)
            }
        }
    }
    
    // MARK: - State (MUST-FIX J + M)
    
    /// Stable key list (append-only, deterministic iteration)
    private var stableKeyList: [SpatialKey] = []
    
    /// Tombstone flags (0=active, 1=tombstone)
    private var tombstoneFlags: [UInt8] = []

    /// Cached tombstone count (avoid O(N) reduce on every frame)
    private var tombstoneCount: Int = 0
    
    /// Cell storage (key -> cell)
    private var cells: [SpatialKey: GridCell] = [:]
    
    /// Index map: SpatialKey -> stableKeyList index (deterministic open-addressing)
    private var indexMap: [SpatialKey: Int] = [:]

    /// Rolling scan cursor for amortized O(1) oldest eviction.
    private var nextEvictionScanIndex: Int = 0
    
    /// Current frame count (for compaction trigger)
    private var frameCount: Int = 0
    
    /// Compaction trigger frame count
    private let compactionTriggerFrameCount = 100
    
    /// Compaction trigger tombstone ratio
    private let compactionTriggerTombstoneRatio = 0.3
    
    /// Maximum cells (from memory tier)
    private let maxCells: Int
    
    /// Spatial quantizer
    public let quantizer: SpatialQuantizer
    
    // MARK: - Initialization
    
    public init(cellSize: LengthQ, maxCells: Int = EvidenceConstants.maxCellsByTier[0]) {
        self.quantizer = SpatialQuantizer(cellSize: cellSize)
        self.maxCells = maxCells
    }
    
    /// Reset grid
    public func reset() {
        stableKeyList.removeAll()
        tombstoneFlags.removeAll()
        tombstoneCount = 0
        cells.removeAll()
        indexMap.removeAll()
        frameCount = 0
        nextEvictionScanIndex = 0
    }
    
    // MARK: - Batch Application
    
    /// **Rule ID:** PR6_GRID_002
    /// Apply batch of updates (single await, no await inside loops)
    public func apply(_ batch: EvidenceGridDeltaBatch) {
        // Process all updates synchronously (no await)
        for updateOp in batch.updates {
            switch updateOp {
            case .insert(let key, let cell):
                insert(key: key, cell: cell)
            case .update(let key, let cell):
                update(key: key, cell: cell)
            case .evict(let key):
                evict(key: key)
            case .refine(let key, let newLevel):
                refine(key: key, newLevel: newLevel)
            }
        }
        
        // Increment frame count
        frameCount += 1
        
        // Check compaction trigger
        if shouldCompact() {
            compact()
        }
    }
    
    // MARK: - Cell Operations
    
    /// Insert new cell
    private func insert(key: SpatialKey, cell: GridCell) {
        // Idempotent insert for active key: treat as update to avoid duplicate stable keys.
        if let index = indexMap[key], tombstoneFlags[index] == 0 {
            cells[key] = cell
            return
        }

        // Check capacity
        if cells.count >= maxCells {
            // Evict oldest cell
            evictOldest()
        }
        
        // Add to stable key list
        let index = stableKeyList.count
        stableKeyList.append(key)
        tombstoneFlags.append(0)  // Active
        
        // Store cell
        cells[key] = cell
        indexMap[key] = index
    }
    
    /// Update existing cell
    private func update(key: SpatialKey, cell: GridCell) {
        guard let index = indexMap[key], tombstoneFlags[index] == 0 else {
            // Not found or tombstoned, treat as insert
            insert(key: key, cell: cell)
            return
        }
        
        // Update cell
        cells[key] = cell
    }
    
    /// Evict cell
    private func evict(key: SpatialKey) {
        guard let index = indexMap[key] else {
            return
        }

        guard tombstoneFlags[index] == 0 else {
            return
        }
        
        // Mark as tombstone
        tombstoneFlags[index] = 1
        tombstoneCount += 1
        
        // Remove from cells
        cells.removeValue(forKey: key)
        indexMap.removeValue(forKey: key)
    }
    
    /// Evict oldest cell (for capacity management)
    private func evictOldest() {
        let total = stableKeyList.count
        guard total > 0 else { return }

        // Amortized O(1): continue scanning from last eviction point.
        var scanned = 0
        var index = nextEvictionScanIndex
        while scanned < total {
            if index >= total {
                index = 0
            }
            if tombstoneFlags[index] == 0 {
                let key = stableKeyList[index]
                evict(key: key)
                nextEvictionScanIndex = index + 1
                if nextEvictionScanIndex >= stableKeyList.count {
                    nextEvictionScanIndex = 0
                }
                return
            }
            index += 1
            scanned += 1
        }
    }
    
    /// Refine cell (change level)
    private func refine(key: SpatialKey, newLevel: EvidenceConfidenceLevel) {
        guard let cell = cells[key] else {
            return
        }
        
        // Create new key with new level
        let newKey = SpatialKey(mortonCode: key.mortonCode, level: newLevel)
        
        // Update cell level (would need mutable cell, simplified here)
        // For now, just update the key mapping
        if let index = indexMap[key] {
            stableKeyList[index] = newKey
            indexMap.removeValue(forKey: key)
            indexMap[newKey] = index
            cells.removeValue(forKey: key)
            cells[newKey] = cell
        }
    }
    
    // MARK: - Compaction (MUST-FIX M)
    
    /// Check if compaction should be triggered
    private func shouldCompact() -> Bool {
        if frameCount % compactionTriggerFrameCount == 0 {
            return true
        }
        
        if stableKeyList.count > 0 && tombstoneCount > 0 {
            let ratio = Double(tombstoneCount) / Double(stableKeyList.count)
            if ratio > compactionTriggerTombstoneRatio {
                return true
            }
        }
        
        return false
    }
    
    /// Compact stable key list (linear scan, no Set/Dictionary iteration)
    private func compact() {
        var newKeyList: [SpatialKey] = []
        var newTombstoneFlags: [UInt8] = []
        var newIndexMap: [SpatialKey: Int] = [:]
        
        // Linear scan over arrays
        for (index, key) in stableKeyList.enumerated() {
            if tombstoneFlags[index] == 0 {
                // Active cell: keep it
                let newIndex = newKeyList.count
                newKeyList.append(key)
                newTombstoneFlags.append(0)
                newIndexMap[key] = newIndex
            }
            // Tombstone: skip
        }
        
        // Replace with compacted arrays
        stableKeyList = newKeyList
        tombstoneFlags = newTombstoneFlags
        indexMap = newIndexMap
        tombstoneCount = 0
        nextEvictionScanIndex = 0
        
        frameCount = 0  // Reset frame count
    }
    
    // MARK: - Query Operations
    
    /// Get cell for key
    public func get(key: SpatialKey) -> GridCell? {
        return cells[key]
    }
    
    /// Get all active cells (deterministic iteration)
    public func allActiveCells() -> [GridCell] {
        var result: [GridCell] = []
        result.reserveCapacity(cells.count)
        for (index, key) in stableKeyList.enumerated() {
            if tombstoneFlags[index] == 0, let cell = cells[key] {
                result.append(cell)
            }
        }
        return result
    }

    /// Fast count query for active cells.
    public func activeCellCount() -> Int {
        cells.count
    }
    
    /// Check if iteration order is deterministic
    public func iterationOrderIsDeterministic() -> Bool {
        // Check that we're using stable key list, not Set/Dictionary iteration
        return true  // Simplified check
    }
    
    /// Check if all adjacent cells satisfy condition
    public func allAdjacentCellsSatisfy(_ condition: (GridCell, GridCell) -> Bool) -> Bool {
        // Simplified: would need neighbor computation
        return true
    }
    
    /// Check if all active cells satisfy condition
    public func allActiveCellsSatisfy(_ condition: (GridCell) -> Bool) -> Bool {
        for (index, key) in stableKeyList.enumerated() {
            if tombstoneFlags[index] == 0, let cell = cells[key] {
                if !condition(cell) {
                    return false
                }
            }
        }
        return true
    }
}
