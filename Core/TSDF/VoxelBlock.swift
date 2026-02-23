// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// VoxelBlock.swift
// Aether3D
//
// Voxel and VoxelBlock types

import Foundation

/// Single voxel — 4 bytes (sdf:2 + weight:1 + confidence:1).
///
/// NOTE: Reserved/padding fields removed to avoid Swift Release-mode optimizer
/// miscompilation when structs with default-valued fields cross module boundaries
/// via @testable import (observed: property reads returned garbage with -O).
/// Future RGB8+flags can be added back when the TSDF GPU pipeline needs them.
public struct Voxel: Sendable {
    public var sdf: SDFStorage     // Normalized signed distance [-1.0, +1.0], scaled by truncation distance
    public var weight: UInt8       // Accumulated observation weight, clamped to W_MAX=64
    public var confidence: UInt8   // Max observed confidence (0=low, 1=mid, 2=high)

    public static let empty = Voxel(sdf: SDFStorage(1.0), weight: 0, confidence: 0)

    public init(sdf: SDFStorage, weight: UInt8, confidence: UInt8) {
        self.sdf = sdf
        self.weight = weight
        self.confidence = confidence
    }
}

/// 8×8×8 voxel block — the fundamental storage unit
public struct VoxelBlock: Sendable {
    public static let size: Int = 8  // 8×8×8 = 512 voxels
    public var voxels: ContiguousArray<Voxel>  // 512 voxels, initialized to sdf=1.0 weight=0
    public var integrationGeneration: UInt32 = 0  // Incremented on every integration touch
    public var meshGeneration: UInt32 = 0         // Set to integrationGeneration after meshing
    public var lastObservedTimestamp: TimeInterval = 0
    public var voxelSize: Float  // Adaptive: 0.005 or 0.01 or 0.02

    /// Empty block sentinel — used to pre-fill ManagedVoxelStorage on init.
    public static let empty = VoxelBlock(
        voxels: ContiguousArray(repeating: Voxel.empty, count: 512),
        integrationGeneration: 0, meshGeneration: 0,
        lastObservedTimestamp: 0, voxelSize: 0.01
    )
}
