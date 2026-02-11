// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SpatialHashTable.swift
// Aether3D
//
// Sparse voxel storage using spatial hashing with separated metadata

import Foundation

struct HashEntry: Sendable {
    var key: BlockIndex    // Int32 x, Int32 y, Int32 z — 12 bytes
    var blockPoolIndex: Int32  // Index into VoxelBlockPool, -1 if empty — 4 bytes
}

/// Sparse voxel storage using spatial hashing with separated metadata
public struct SpatialHashTable: Sendable {
    private var entries: ContiguousArray<HashEntry>
    private var stableKeyList: ContiguousArray<BlockIndex>  // Deterministic iteration
    private var pool: VoxelBlockPool
    public private(set) var count: Int = 0

    /// Initial table size: 2^16 = 65,536
    public init(
        initialSize: Int = TSDFConstants.hashTableInitialSize,
        poolCapacity: Int = TSDFConstants.maxTotalVoxelBlocks
    ) {
        entries = ContiguousArray(repeating: HashEntry(key: BlockIndex(0,0,0), blockPoolIndex: -1), count: initialSize)
        stableKeyList = ContiguousArray()
        pool = VoxelBlockPool(capacity: poolCapacity)
        count = 0
    }

    public mutating func insertOrGet(key: BlockIndex, voxelSize: Float) -> Int? {
        let hash = key.niessnerHash(tableSize: entries.count)
        var probe = hash
        
        // Linear probing
        for _ in 0..<TSDFConstants.hashMaxProbeLength {
            let entry = entries[probe]
            
            if entry.blockPoolIndex == -1 {
                // Empty slot - allocate new block
                guard let poolIndex = pool.allocate(voxelSize: voxelSize) else { return nil }
                entries[probe] = HashEntry(key: key, blockPoolIndex: Int32(poolIndex))
                stableKeyList.append(key)
                count += 1
                return poolIndex
            }
            
            if entry.key == key {
                // Found existing block
                return Int(entry.blockPoolIndex)
            }
            
            probe = (probe + 1) % entries.count
        }
        
        return nil  // Max probe length exceeded
    }

    public func lookup(key: BlockIndex) -> Int? {
        let hash = key.niessnerHash(tableSize: entries.count)
        var probe = hash
        
        for _ in 0..<TSDFConstants.hashMaxProbeLength {
            let entry = entries[probe]
            
            if entry.blockPoolIndex == -1 {
                return nil  // Empty slot, not found
            }
            
            if entry.key == key {
                return Int(entry.blockPoolIndex)
            }
            
            probe = (probe + 1) % entries.count
        }
        
        return nil
    }

    public mutating func remove(key: BlockIndex) {
        // BUG-5: Backward-shift deletion to preserve linear probing chain
        let h = key.niessnerHash(tableSize: entries.count)
        var probe = h
        
        for _ in 0..<TSDFConstants.hashMaxProbeLength {
            let entry = entries[probe]
            if entry.blockPoolIndex == -1 { return }
            if entry.key == key {
                pool.deallocate(index: Int(entry.blockPoolIndex))
                stableKeyList.removeAll { $0 == key }
                var empty = probe
                var j = (probe + 1) % entries.count
                while entries[j].blockPoolIndex >= 0 {
                    let ideal = entries[j].key.niessnerHash(tableSize: entries.count)
                    if (empty <= j) ? (ideal <= empty || ideal > j) : (ideal <= empty && ideal > j) {
                        entries[empty] = entries[j]
                        empty = j
                    }
                    j = (j + 1) % entries.count
                }
                entries[empty] = HashEntry(key: BlockIndex(0,0,0), blockPoolIndex: -1)
                count -= 1
                return
            }
            probe = (probe + 1) % entries.count
        }
    }

    /// Load factor check — rehash at 0.7
    /// Guardrail #24: Hash load factor monitoring
    public var loadFactor: Float { Float(count) / Float(entries.count) }
    
    /// Guardrail #24: Check if load factor exceeds warning threshold
    public var loadFactorWarning: Bool {
        loadFactor >= 0.6  // Warn at 0.6, rehash at 0.7
    }

    public mutating func rehashIfNeeded() {
        // Guardrail #24: Proactive rehash at 0.7 — only remap key→poolIndex, do not re-allocate pool blocks (BUG-4 fix)
        guard loadFactor >= TSDFConstants.hashTableMaxLoadFactor else { return }
        
        let oldMappings: [(BlockIndex, Int32)] = entries.compactMap { entry in
            entry.blockPoolIndex >= 0 ? (entry.key, entry.blockPoolIndex) : nil
        }
        let newSize = entries.count * 2
        entries = ContiguousArray(repeating: HashEntry(key: BlockIndex(0,0,0), blockPoolIndex: -1), count: newSize)
        stableKeyList = ContiguousArray()
        count = 0
        
        for (key, poolIndex) in oldMappings {
            let h = key.niessnerHash(tableSize: entries.count)
            var probe = h
            for _ in 0..<TSDFConstants.hashMaxProbeLength {
                if entries[probe].blockPoolIndex == -1 {
                    entries[probe] = HashEntry(key: key, blockPoolIndex: poolIndex)
                    stableKeyList.append(key)
                    count += 1
                    break
                }
                probe = (probe + 1) % entries.count
            }
        }
    }

    // ── Exposed for TSDFVolume and MetalTSDFIntegrator ──

    /// VoxelBlockAccessor for TSDFIntegrationBackend protocol dispatch.
    public var voxelAccessor: VoxelBlockAccessor { pool.accessor }

    /// Stable base address for Metal MTLBuffer(bytesNoCopy:) binding.
    public var voxelBaseAddress: UnsafeMutableRawPointer { pool.baseAddress }
    public var voxelByteCount: Int { pool.byteCount }

    /// Read a voxel block by pool index (for MarchingCubes).
    public func readBlock(at poolIndex: Int) -> VoxelBlock { pool.accessor.readBlock(at: poolIndex) }
    
    /// Iterate through all active blocks in the hash table.
    /// Used by MarchingCubes and memory pressure handling.
    public func forEachBlock(_ block: (BlockIndex, Int, VoxelBlock) -> Void) {
        for key in stableKeyList {
            if let poolIndex = lookup(key: key) {
                let voxelBlock = readBlock(at: poolIndex)
                block(key, poolIndex, voxelBlock)
            }
        }
    }
    
    /// Get all block indices and their pool indices.
    /// Returns array of (BlockIndex, poolIndex) tuples.
    public func getAllBlocks() -> [(BlockIndex, Int)] {
        var result: [(BlockIndex, Int)] = []
        for key in stableKeyList {
            if let poolIndex = lookup(key: key) {
                result.append((key, poolIndex))
            }
        }
        return result
    }
    
    /// Mutate a block at the given pool index.
    /// Used to update meshGeneration after meshing.
    public mutating func updateBlock(at poolIndex: Int, _ updater: (inout VoxelBlock) -> Void) {
        var block = pool.accessor.readBlock(at: poolIndex)
        updater(&block)
        pool.accessor.writeBlock(at: poolIndex, block)
    }
}
