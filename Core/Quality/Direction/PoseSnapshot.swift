//
//  PoseSnapshot.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 4
//  PoseSnapshot - pose extraction from CMDeviceMotion (Apple platforms) or manual values (cross-platform)
//

import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// PoseSnapshot - pose snapshot from device motion
/// Cross-platform: compiles on Linux (without CoreMotion) and Apple platforms (with CoreMotion)
public struct PoseSnapshot {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double
    
    /// Initialize with explicit yaw/pitch/roll values (available on all platforms)
    /// - Parameters:
    ///   - yaw: Yaw angle in degrees
    ///   - pitch: Pitch angle in degrees
    ///   - roll: Roll angle in degrees
    public init(yaw: Double, pitch: Double, roll: Double) {
        // Normalize angles (handle -1° and 359° case)
        self.yaw = PoseSnapshot.normalizeAngle(yaw)
        self.pitch = PoseSnapshot.normalizeAngle(pitch)
        self.roll = PoseSnapshot.normalizeAngle(roll)
    }
    
    #if canImport(CoreMotion)
    /// Create from CMDeviceMotion (Apple platforms only)
    /// - Parameter motion: CMDeviceMotion instance from CoreMotion framework
    /// - Returns: PoseSnapshot with normalized angles
    public static func from(_ motion: CMDeviceMotion) -> PoseSnapshot {
        // Extract yaw/pitch/roll from motion.attitude
        let attitude = motion.attitude
        let yaw = attitude.yaw * 180.0 / .pi
        let pitch = attitude.pitch * 180.0 / .pi
        let roll = attitude.roll * 180.0 / .pi
        
        return PoseSnapshot(yaw: yaw, pitch: pitch, roll: roll)
    }
    #endif
    
    /// Normalize angle to [-180, 180] range
    private static func normalizeAngle(_ angle: Double) -> Double {
        var normalized = angle
        while normalized > 180.0 {
            normalized -= 360.0
        }
        while normalized < -180.0 {
            normalized += 360.0
        }
        return normalized
    }
}

