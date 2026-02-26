// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFTypes.swift
// Aether3D
//
// Shared types for TSDF pipeline

import Foundation

public enum MemoryPressureLevel: Int, Sendable {
    case warning = 1
    case critical = 2
    case terminal = 3
}

public struct IntegrationRecord: Sendable {
    public let timestamp: TimeInterval
    public let cameraPose: TSDFMatrix4x4
    public let intrinsics: TSDFMatrix3x3
    public let affectedBlockIndices: [Int32]
    public let isKeyframe: Bool
    public let keyframeId: UInt32?

    public init(timestamp: TimeInterval, cameraPose: TSDFMatrix4x4, intrinsics: TSDFMatrix3x3,
                affectedBlockIndices: [Int32], isKeyframe: Bool, keyframeId: UInt32?) {
        self.timestamp = timestamp; self.cameraPose = cameraPose; self.intrinsics = intrinsics
        self.affectedBlockIndices = affectedBlockIndices; self.isKeyframe = isKeyframe; self.keyframeId = keyframeId
    }

    public static let empty = IntegrationRecord(
        timestamp: 0,
        cameraPose: .tsdIdentity4x4,
        intrinsics: .tsdIdentity3x3,
        affectedBlockIndices: [],
        isKeyframe: false,
        keyframeId: nil
    )
}

/// Swift-side TSDFParams struct matching Metal shader layout (TSDFShaderTypes.h).
/// Single definition for both MetalTSDFIntegrator and MetalBufferPool.
public struct TSDFParams: Sendable {
    public var depthMin: Float
    public var depthMax: Float
    public var skipLowConfidence: Int32
    public var _pad0: Int32

    public var depthNearThreshold: Float
    public var depthFarThreshold: Float
    public var voxelSizeNear: Float
    public var voxelSizeMid: Float
    public var voxelSizeFar: Float

    public var truncationMultiplier: Float
    public var truncationMinimum: Float

    public var confidenceWeights: (Float, Float, Float)
    public var distanceDecayAlpha: Float
    public var viewingAngleFloor: Float
    public var weightMax: UInt8
    public var carvingDecayRate: UInt8
    public var _pad1: (UInt8, UInt8)

    public var blockSize: Int32
    public var maxOutputBlocks: Int32
    /// BUG-11: Depth resolution and SDF dead zone for Metal shader
    public var depthWidth: UInt32
    public var depthHeight: UInt32
    public var sdfDeadZoneBase: Float
    public var sdfDeadZoneWeightScale: Float

    public init(
        depthMin: Float, depthMax: Float, skipLowConfidence: Int32, _pad0: Int32,
        depthNearThreshold: Float, depthFarThreshold: Float,
        voxelSizeNear: Float, voxelSizeMid: Float, voxelSizeFar: Float,
        truncationMultiplier: Float, truncationMinimum: Float,
        confidenceWeights: (Float, Float, Float), distanceDecayAlpha: Float, viewingAngleFloor: Float,
        weightMax: UInt8, carvingDecayRate: UInt8, _pad1: (UInt8, UInt8),
        blockSize: Int32, maxOutputBlocks: Int32,
        depthWidth: UInt32, depthHeight: UInt32,
        sdfDeadZoneBase: Float, sdfDeadZoneWeightScale: Float
    ) {
        self.depthMin = depthMin; self.depthMax = depthMax
        self.skipLowConfidence = skipLowConfidence; self._pad0 = _pad0
        self.depthNearThreshold = depthNearThreshold; self.depthFarThreshold = depthFarThreshold
        self.voxelSizeNear = voxelSizeNear; self.voxelSizeMid = voxelSizeMid; self.voxelSizeFar = voxelSizeFar
        self.truncationMultiplier = truncationMultiplier; self.truncationMinimum = truncationMinimum
        self.confidenceWeights = confidenceWeights; self.distanceDecayAlpha = distanceDecayAlpha
        self.viewingAngleFloor = viewingAngleFloor
        self.weightMax = weightMax; self.carvingDecayRate = carvingDecayRate; self._pad1 = _pad1
        self.blockSize = blockSize; self.maxOutputBlocks = maxOutputBlocks
        self.depthWidth = depthWidth; self.depthHeight = depthHeight
        self.sdfDeadZoneBase = sdfDeadZoneBase; self.sdfDeadZoneWeightScale = sdfDeadZoneWeightScale
    }
}
