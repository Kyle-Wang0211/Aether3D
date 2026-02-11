// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ManagedVoxelStorage.swift
// Aether3D
//
// Reference-semantics voxel block storage with stable base address.

/// Reference-semantics voxel block storage with stable base address.
///
/// WHY NOT ContiguousArray<VoxelBlock>:
///   ContiguousArray is a value type. Swift's CoW may relocate its buffer on mutation.
///   Metal's makeBuffer(bytesNoCopy:) requires a pointer that NEVER moves.
///   A single CoW relocation = GPU reads stale/freed memory = crash or corruption.
///
/// WHY NOT ManagedBuffer:
///   ManagedBuffer's API is complex and designed for COW reference types.
///   We need simpler semantics: allocate once, never move, deallocate at end.
///
/// This is a standard pattern in the codebase (38 files use UnsafeMutableBufferPointer).
/// @unchecked Sendable because TSDFVolume actor provides all synchronization.
public final class ManagedVoxelStorage: @unchecked Sendable, VoxelBlockAccessor {
    private let pointer: UnsafeMutablePointer<VoxelBlock>
    public let capacity: Int

    public init(capacity: Int = TSDFConstants.maxTotalVoxelBlocks) {
        self.capacity = capacity
        pointer = .allocate(capacity: capacity)
        pointer.initialize(repeating: VoxelBlock.empty, count: capacity)
    }

    deinit {
        pointer.deinitialize(count: capacity)
        pointer.deallocate()
    }

    // ── VoxelBlockAccessor conformance ──

    public var baseAddress: UnsafeMutableRawPointer { UnsafeMutableRawPointer(pointer) }
    public var byteCount: Int { capacity * MemoryLayout<VoxelBlock>.stride }

    public func readBlock(at poolIndex: Int) -> VoxelBlock {
        precondition(poolIndex >= 0 && poolIndex < capacity)
        return pointer[poolIndex]
    }

    public func writeBlock(at poolIndex: Int, _ block: VoxelBlock) {
        precondition(poolIndex >= 0 && poolIndex < capacity)
        pointer[poolIndex] = block
    }

    public subscript(index: Int) -> VoxelBlock {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }
}
