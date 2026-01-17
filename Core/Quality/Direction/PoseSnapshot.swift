//
//  PoseSnapshot.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 4
//  PoseSnapshot - pose extraction from CMDeviceMotion
//

import Foundation
import CoreMotion

/// PoseSnapshot - pose snapshot from device motion
public struct PoseSnapshot {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double
    
    public init(yaw: Double, pitch: Double, roll: Double) {
        // Normalize angles (handle -1° and 359° case)
        self.yaw = PoseSnapshot.normalizeAngle(yaw)
        self.pitch = PoseSnapshot.normalizeAngle(pitch)
        self.roll = PoseSnapshot.normalizeAngle(roll)
    }
    
    /// Create from CMDeviceMotion
    public static func from(_ motion: CMDeviceMotion) -> PoseSnapshot {
        // Extract yaw/pitch/roll from motion.attitude
        let attitude = motion.attitude
        let yaw = attitude.yaw * 180.0 / .pi
        let pitch = attitude.pitch * 180.0 / .pi
        let roll = attitude.roll * 180.0 / .pi
        
        return PoseSnapshot(yaw: yaw, pitch: pitch, roll: roll)
    }
    
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

