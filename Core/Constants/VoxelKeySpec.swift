// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// VoxelKeySpec.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Voxel Key Specification
//
// E: VoxelKeySpec with explicit integer fields (no floats)
// Grid indexing MUST use floor with half-open intervals [min, max)
//

import Foundation

// MARK: - Voxel Key Specification

/// Voxel key specification (integer domain, no floats)
/// **Rule:** Map keys MUST be strictly integer-domain and serializable
public struct VoxelKeySpec: Codable, Equatable, Hashable {
    /// Quantized X index (Int64, integer domain)
    public let qX: Int64
    
    /// Quantized Y index (Int64, integer domain)
    public let qY: Int64
    
    /// Quantized Z index (Int64, integer domain)
    public let qZ: Int64
    
    /// Resolution level identifier (closed integer)
    public let resLevelId: Int
    
    /// Schema version ID
    public let schemaVersionId: UInt16
    
    /// Profile ID
    public let profileId: UInt8
    
    public init(
        qX: Int64,
        qY: Int64,
        qZ: Int64,
        resLevelId: Int,
        schemaVersionId: UInt16,
        profileId: UInt8
    ) {
        self.qX = qX
        self.qY = qY
        self.qZ = qZ
        self.resLevelId = resLevelId
        self.schemaVersionId = schemaVersionId
        self.profileId = profileId
    }
    
    // MARK: - Canonical Serialization
    
    /// Canonical serialization (for hashing/digest)
    /// **Rule:** Must be deterministic, stable byte-for-byte
    public func canonicalSerialize() -> Data {
        var data = Data()
        // Serialize in fixed order: qX, qY, qZ, resLevelId, schemaVersionId, profileId
        data.append(contentsOf: withUnsafeBytes(of: qX.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: qY.bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: qZ.bigEndian) { Data($0) })
        let resLevelId64 = Int64(resLevelId)
        data.append(contentsOf: withUnsafeBytes(of: resLevelId64.bigEndian) { Data($0) })
        let schemaVersionId16 = schemaVersionId.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: schemaVersionId16) { Data($0) })
        data.append(contentsOf: [profileId])
        return data
    }
    
    // MARK: - Validation
    
    /// Validate conformance (PR1-level rules)
    public static func validate(_ key: VoxelKeySpec) -> [String] {
        var errors: [String] = []
        
        // All fields must be present (non-nil check not needed for struct, but validate ranges)
        // resLevelId must be non-negative
        if key.resLevelId < 0 {
            errors.append("VoxelKeySpec.resLevelId must be non-negative, got \(key.resLevelId)")
        }
        
        // schemaVersionId must match current
        if key.schemaVersionId != SSOTVersion.schemaVersionId {
            errors.append("VoxelKeySpec.schemaVersionId mismatch: expected \(SSOTVersion.schemaVersionId), got \(key.schemaVersionId)")
        }
        
        // profileId must be valid
        if CaptureProfile(rawValue: key.profileId) == nil {
            errors.append("VoxelKeySpec.profileId invalid: \(key.profileId) is not a valid CaptureProfile")
        }
        
        return errors
    }
}

// MARK: - Grid Index Computation Rules

/// Grid index computation rules (PR1-level invariants)
public enum GridIndexComputation {
    /// **Rule:** Grid indexing MUST use floor() function
    /// **Rule:** Use half-open intervals [min, max)
    /// **Rule:** No floating-point values may be used as map keys
    
    /// Compute grid index from world coordinate (using floor)
    /// - Parameter coordinate: World coordinate (LengthQ)
    /// - Parameter cellSize: Grid cell size (LengthQ)
    /// - Returns: Grid index (Int64)
    public static func computeIndex(coordinate: LengthQ, cellSize: LengthQ) -> Int64 {
        // Convert both to same scale (use finer scale)
        let finerScale = coordinate.scaleId.quantumInNanometers < cellSize.scaleId.quantumInNanometers ? coordinate.scaleId : cellSize.scaleId
        let coordQuanta = convertQuanta(coordinate.quanta, from: coordinate.scaleId, to: finerScale)
        let cellQuanta = convertQuanta(cellSize.quanta, from: cellSize.scaleId, to: finerScale)
        
        // Use floor division (half-open interval [min, max))
        return coordQuanta / cellQuanta
    }
    
    private static func convertQuanta(_ quanta: Int64, from: LengthScale, to: LengthScale) -> Int64 {
        if from == to {
            return quanta
        }
        let fromNanometers = quanta * from.quantumInNanometers
        return fromNanometers / to.quantumInNanometers
    }
}
