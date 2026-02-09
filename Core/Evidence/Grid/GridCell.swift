// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GridCell.swift
// Aether3D
//
// PR6 Evidence Grid System - Grid Cell
// Per-cell data structure for evidence grid
//

import Foundation

/// **Rule ID:** PR6_GRID_CELL_001
/// Grid cell: per-cell data (evidence, mass, metadata)
public struct GridCell: Codable, Sendable, Equatable {
    /// Quantized position (grid coordinates)
    public struct QuantizedPosition: Codable, Sendable, Equatable {
        public let x: Int32
        public let y: Int32
        public let z: Int32
        
        public init(x: Int32, y: Int32, z: Int32) {
            self.x = x
            self.y = y
            self.z = z
        }
    }
    
    /// Patch ID this cell belongs to
    public let patchId: String
    
    /// Quantized position (grid coordinates)
    public let quantizedPosition: QuantizedPosition
    
    /// Dimensional scores (15 dimensions)
    public let dimScores: DimensionalScoreSet
    
    /// D-S mass function (occupied, free, unknown)
    public let dsMass: DSMassFunction
    
    /// Confidence level (L0..L6)
    public let level: EvidenceConfidenceLevel
    
    /// Directional bitmask (26 directions)
    public let directionalMask: UInt32
    
    /// Last update timestamp (monotonic milliseconds)
    public let lastUpdatedMillis: Int64
    
    public init(
        patchId: String,
        quantizedPosition: QuantizedPosition,
        dimScores: DimensionalScoreSet,
        dsMass: DSMassFunction,
        level: EvidenceConfidenceLevel,
        directionalMask: UInt32,
        lastUpdatedMillis: Int64
    ) {
        self.patchId = patchId
        self.quantizedPosition = quantizedPosition
        self.dimScores = dimScores
        self.dsMass = dsMass
        self.level = level
        self.directionalMask = directionalMask
        self.lastUpdatedMillis = lastUpdatedMillis
    }
    
    /// Convenience initializer with tuple position
    public init(
        patchId: String,
        quantizedPosition: (x: Int32, y: Int32, z: Int32),
        dimScores: DimensionalScoreSet,
        dsMass: DSMassFunction,
        level: EvidenceConfidenceLevel,
        directionalMask: UInt32,
        lastUpdatedMillis: Int64
    ) {
        self.init(
            patchId: patchId,
            quantizedPosition: QuantizedPosition(x: quantizedPosition.x, y: quantizedPosition.y, z: quantizedPosition.z),
            dimScores: dimScores,
            dsMass: dsMass,
            level: level,
            directionalMask: directionalMask,
            lastUpdatedMillis: lastUpdatedMillis
        )
    }
}

/// **Rule ID:** PR6_GRID_CELL_002
/// Spatial key: Morton code + level
public struct SpatialKey: Codable, Sendable, Equatable, Hashable {
    /// Morton code (UInt64)
    public let mortonCode: UInt64
    
    /// Confidence level (UInt8, L0..L6)
    public let level: UInt8
    
    public init(mortonCode: UInt64, level: UInt8) {
        self.mortonCode = mortonCode
        self.level = level
    }
    
    /// Create from EvidenceConfidenceLevel
    public init(mortonCode: UInt64, level: EvidenceConfidenceLevel) {
        self.mortonCode = mortonCode
        self.level = level.rawValue
    }
}
