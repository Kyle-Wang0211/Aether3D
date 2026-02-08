//
// SpatialQuantizer.swift
// Aether3D
//
// PR6 Evidence Grid System - Spatial Quantizer
// 3D world coordinates → Morton code mapping
//

import Foundation

/// **Rule ID:** PR6_GRID_QUANTIZER_001
/// Spatial quantizer: maps 3D world coordinates to Morton codes
/// Uses integer-based quantization for determinism
public struct SpatialQuantizer {
    
    /// Grid cell size (from GridResolutionPolicy)
    public let cellSize: LengthQ
    
    /// World space origin (for coordinate system)
    public let origin: EvidenceVector3
    
    public init(cellSize: LengthQ, origin: EvidenceVector3 = EvidenceVector3(x: 0, y: 0, z: 0)) {
        self.cellSize = cellSize
        self.origin = origin
    }
    
    /// **Rule ID:** PR6_GRID_QUANTIZER_002
    /// Quantize 3D world coordinates to integer grid coordinates
    ///
    /// - Parameter worldPos: World position in meters
    /// - Returns: Integer grid coordinates (x, y, z)
    public func quantize(_ worldPos: EvidenceVector3) -> GridCell.QuantizedPosition {
        // Convert world position to grid coordinates
        let dx = worldPos.x - origin.x
        let dy = worldPos.y - origin.y
        let dz = worldPos.z - origin.z
        
        // Convert LengthQ to meters for quantization
        let cellSizeMeters = cellSize.toMeters()
        
        // Quantize to integer grid coordinates
        let gridX = Int32((dx / cellSizeMeters).rounded(.towardZero))
        let gridY = Int32((dy / cellSizeMeters).rounded(.towardZero))
        let gridZ = Int32((dz / cellSizeMeters).rounded(.towardZero))
        
        return GridCell.QuantizedPosition(x: gridX, y: gridY, z: gridZ)
    }
    
    /// **Rule ID:** PR6_GRID_QUANTIZER_003
    /// Compute Morton code from integer grid coordinates
    ///
    /// Morton code (Z-order curve) interleaves bits: zyxzyxzyx...
    ///
    /// - Parameters:
    ///   - x: Grid X coordinate
    ///   - y: Grid Y coordinate
    ///   - z: Grid Z coordinate
    /// - Returns: Morton code (UInt64)
    public func mortonCode(x: Int32, y: Int32, z: Int32) -> UInt64 {
        // Convert to unsigned with sign extension
        let ux = UInt32(bitPattern: x)
        let uy = UInt32(bitPattern: y)
        let uz = UInt32(bitPattern: z)
        
        // Interleave bits: zyxzyxzyx...
        var code: UInt64 = 0
        for i in 0..<21 {  // 21 bits per coordinate (63 bits total, fits in UInt64)
            let bitX = (ux >> i) & 1
            let bitY = (uy >> i) & 1
            let bitZ = (uz >> i) & 1
            
            code |= UInt64(bitX) << (i * 3)
            code |= UInt64(bitY) << (i * 3 + 1)
            code |= UInt64(bitZ) << (i * 3 + 2)
        }
        
        return code
    }
    
    /// Compute Morton code from world position
    public func mortonCode(from worldPos: EvidenceVector3) -> UInt64 {
        let pos = quantize(worldPos)
        return mortonCode(x: pos.x, y: pos.y, z: pos.z)
    }
    
    /// Decode Morton code back to grid coordinates
    public func decodeMortonCode(_ code: UInt64) -> GridCell.QuantizedPosition {
        var x: UInt32 = 0
        var y: UInt32 = 0
        var z: UInt32 = 0
        
        // De-interleave bits
        for i in 0..<21 {
            let bitX = UInt32((code >> UInt64(i * 3)) & 1)
            let bitY = UInt32((code >> UInt64(i * 3 + 1)) & 1)
            let bitZ = UInt32((code >> UInt64(i * 3 + 2)) & 1)
            x |= bitX << i
            y |= bitY << i
            z |= bitZ << i
        }
        
        return GridCell.QuantizedPosition(x: Int32(bitPattern: x), y: Int32(bitPattern: y), z: Int32(bitPattern: z))
    }
    
    /// Convert grid coordinates back to world position
    public func worldPosition(_ pos: GridCell.QuantizedPosition) -> EvidenceVector3 {
        return worldPosition(x: pos.x, y: pos.y, z: pos.z)
    }
    
    /// Convert grid coordinates back to world position
    public func worldPosition(x: Int32, y: Int32, z: Int32) -> EvidenceVector3 {
        let cellSizeMeters = cellSize.toMeters()
        return EvidenceVector3(
            x: origin.x + Double(x) * cellSizeMeters,
            y: origin.y + Double(y) * cellSizeMeters,
            z: origin.z + Double(z) * cellSizeMeters
        )
    }
}

// Note: LengthQ already has toMeters() method, no need to add extension
