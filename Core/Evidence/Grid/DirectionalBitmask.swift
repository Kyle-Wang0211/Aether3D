//
// DirectionalBitmask.swift
// Aether3D
//
// PR6 Evidence Grid System - Directional Bitmask
// 26-direction encoding for view direction tracking
//

import Foundation

/// **Rule ID:** PR6_GRID_DIRECTION_001
/// Directional bitmask: 26-direction encoding (UInt32)
/// Stable mapping from view direction to direction indices
public struct DirectionalBitmask {
    
    /// **Rule ID:** PR6_GRID_DIRECTION_002
    /// Convert view direction (theta, phi) to direction index
    ///
    /// - Parameters:
    ///   - theta: Horizontal angle in degrees [0, 360)
    ///   - phi: Vertical angle in degrees [0, 180)
    /// - Returns: Direction index [0, 25]
    public static func directionIndex(theta: Double, phi: Double) -> Int {
        // Normalize angles
        let normalizedTheta = theta.truncatingRemainder(dividingBy: 360.0)
        let clampedTheta = normalizedTheta < 0 ? normalizedTheta + 360.0 : normalizedTheta
        let clampedPhi = max(0.0, min(180.0, phi))
        
        // Bin angles into 26 directions
        // Simplified: 6 horizontal bins × 4 vertical bins + 2 poles = 26 directions
        let thetaBin = Int(clampedTheta / 60.0) % 6  // 6 horizontal bins
        let phiBin: Int
        if clampedPhi < 15.0 {
            phiBin = 0  // North pole
        } else if clampedPhi > 165.0 {
            phiBin = 3  // South pole
        } else {
            phiBin = Int((clampedPhi - 15.0) / 50.0) + 1  // 2 middle bins
        }
        
        // Map to direction index [0, 25]
        if phiBin == 0 {
            return 0  // North pole
        } else if phiBin == 3 {
            return 25  // South pole
        } else {
            return phiBin * 6 + thetaBin + 1  // Middle directions
        }
    }
    
    /// Convert unit vector to direction index
    public static func directionIndex(from unitVector: EvidenceVector3) -> Int {
        // Convert to spherical coordinates
        let r = unitVector.length()
        guard r > 1e-10 else {
            return 0  // Default to north pole for zero vector
        }
        
        let x = unitVector.x / r
        let y = unitVector.y / r
        let z = unitVector.z / r
        
        // Compute theta (azimuth) and phi (elevation)
        let theta = atan2(y, x) * 180.0 / .pi
        let phi = acos(z) * 180.0 / .pi
        
        return directionIndex(theta: theta, phi: phi)
    }
    
    /// Set direction bit in bitmask
    public static func setBit(_ bitmask: UInt32, directionIndex: Int) -> UInt32 {
        guard directionIndex >= 0 && directionIndex < 26 else {
            return bitmask
        }
        return bitmask | (1 << directionIndex)
    }
    
    /// Check if direction bit is set
    public static func isBitSet(_ bitmask: UInt32, directionIndex: Int) -> Bool {
        guard directionIndex >= 0 && directionIndex < 26 else {
            return false
        }
        return (bitmask & (1 << directionIndex)) != 0
    }
    
    /// **Rule ID:** PR6_GRID_DIRECTION_003
    /// Popcount: count number of set bits
    public static func popcount(_ bitmask: UInt32) -> Int {
        return bitmask.nonzeroBitCount
    }
    
    /// Count distinct directions
    public static func distinctDirectionCount(_ bitmask: UInt32) -> Int {
        return popcount(bitmask)
    }
    
    /// Check if has at least two distinct directions
    public static func hasAtLeastTwoDistinctDirections(_ bitmask: UInt32) -> Bool {
        return popcount(bitmask) >= 2
    }
}
