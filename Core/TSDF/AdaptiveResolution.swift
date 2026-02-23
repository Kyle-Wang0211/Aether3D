// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AdaptiveResolution.swift
// Aether3D
//
// Depth-to-voxel-size selection and distance-dependent integration weight.

/// Depth-to-voxel-size selection and distance-dependent integration weight.
///
/// Three resolution tiers based on LiDAR noise model:
///   Near (<1m): 5mm voxels, σ_integrated ≈ 0.8mm → 6× margin
///   Mid (1-3m): 10mm voxels, σ_integrated ≈ 3-18mm → adequate
///   Far (>3m): 20mm voxels, σ_integrated ≈ 18mm → structural detail only
public enum AdaptiveResolution {

    /// Select voxel size based on measured depth (meters).
    @inlinable
    public static func voxelSize(forDepth depth: Float) -> Float {
        if depth < TSDFConstants.depthNearThreshold { return TSDFConstants.voxelSizeNear }
        if depth < TSDFConstants.depthFarThreshold { return TSDFConstants.voxelSizeMid }
        return TSDFConstants.voxelSizeFar
    }

    /// Compute truncation distance for a given voxel size.
    /// Guardrail #25: Truncation sanity check — ensure τ >= 2 × voxelSize
    @inlinable
    public static func truncationDistance(voxelSize: Float) -> Float {
        let truncation = max(TSDFConstants.truncationMultiplier * voxelSize, TSDFConstants.truncationMinimum)
        // Guardrail #25: Force minimum: max(2×voxelSize, configured)
        let safetyFloor = 2.0 * voxelSize
        return max(truncation, safetyFloor)
    }

    /// Distance-dependent observation weight: w = 1 / (1 + α × d²).
    @inlinable
    public static func distanceWeight(depth: Float) -> Float {
        1.0 / (1.0 + TSDFConstants.distanceDecayAlpha * depth * depth)
    }

    /// Confidence-to-weight mapping.
    @inlinable
    public static func confidenceWeight(level: UInt8) -> Float {
        switch level {
        case 0: return TSDFConstants.confidenceWeightLow
        case 1: return TSDFConstants.confidenceWeightMid
        default: return TSDFConstants.confidenceWeightHigh
        }
    }

    /// Viewing angle weight: max(floor, |dot(viewRay, normal)|).
    @inlinable
    public static func viewingAngleWeight(viewRay: TSDFFloat3, normal: TSDFFloat3) -> Float {
        max(TSDFConstants.viewingAngleWeightFloor, abs(dot(viewRay, normal)))
    }

    /// Compute world-space block index from a world position and voxel size.
    @inlinable
    public static func blockIndex(worldPosition: TSDFFloat3, voxelSize: Float) -> BlockIndex {
        // BUG-6: Use .down for negative coordinates (floor division)
        let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
        return BlockIndex(
            Int32((worldPosition.x / blockWorldSize).rounded(.down)),
            Int32((worldPosition.y / blockWorldSize).rounded(.down)),
            Int32((worldPosition.z / blockWorldSize).rounded(.down))
        )
    }
}
