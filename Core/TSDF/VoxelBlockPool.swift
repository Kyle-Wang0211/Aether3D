// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// VoxelBlockPool.swift
// Aether3D
//
// Pre-allocated contiguous pool for O(1) alloc/dealloc with zero fragmentation.

/// Pre-allocated contiguous pool for O(1) alloc/dealloc with zero fragmentation.
///
/// Wraps ManagedVoxelStorage (Section 0.7) for stable-address voxel data.
/// Free-list stack: O(1) push/pop. No heap allocation after init.
/// The Metal layer uses storage.baseAddress with MTLBuffer(bytesNoCopy:)
/// for zero-copy GPU access (Apple Silicon unified memory).
///
/// Memory budget: 100,000 blocks × 4 KB = 400 MB
/// iPhone 12 Pro (4 GB): safe at ~10% of total RAM
/// iPhone 15 Pro (8 GB): safe at ~5% of total RAM
///
/// NOTE: VoxelBlockPool is a struct but holds a reference to ManagedVoxelStorage.
/// This is intentional — the struct provides value-semantic API (alloc/dealloc)
/// while the underlying storage pointer never moves (required for Metal).
public struct VoxelBlockPool: Sendable {
    private let storage: ManagedVoxelStorage  // Reference type — pointer never moves
    private var freeStack: ContiguousArray<Int>  // Indices of free blocks
    public private(set) var allocatedCount: Int = 0

    public init(capacity: Int = TSDFConstants.maxTotalVoxelBlocks) {
        storage = ManagedVoxelStorage(capacity: capacity)
        freeStack = ContiguousArray((0..<capacity).reversed())
    }

    /// O(1) allocation from free-list
    public mutating func allocate(voxelSize: Float) -> Int? {
        guard let index = freeStack.popLast() else { return nil }
        storage[index] = VoxelBlock(
            voxels: ContiguousArray(repeating: Voxel.empty, count: 512),
            integrationGeneration: 0, meshGeneration: 0,
            lastObservedTimestamp: 0, voxelSize: voxelSize
        )
        allocatedCount += 1
        return index
    }

    /// O(1) deallocation back to free-list
    public mutating func deallocate(index: Int) {
        storage[index] = VoxelBlock.empty
        freeStack.append(index)
        allocatedCount -= 1
    }

    /// VoxelBlockAccessor for TSDFIntegrationBackend protocol
    public var accessor: VoxelBlockAccessor { storage }

    /// Direct access to underlying storage (for MetalTSDFIntegrator buffer binding)
    public var baseAddress: UnsafeMutableRawPointer { storage.baseAddress }
    public var byteCount: Int { storage.byteCount }
}
