//
// ObservationMath.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - Deterministic Math Functions
//
// Pure functions, deterministic, no side effects.
// All floating-point operations use tolerance comparisons.
//

import Foundation

/// Deterministic math functions for observation validation
public struct ObservationMath {
    
    // MARK: - Finite Checks
    
    /// Check if Vec3D is finite
    public static func isFinite(_ v: Vec3D) -> Bool {
        return v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
    
    /// Check if Double is finite
    public static func isFinite(_ d: Double) -> Bool {
        return d.isFinite
    }
    
    // MARK: - Vector Operations
    
    /// Compute distance between two points
    public static func distance(_ a: Vec3D, _ b: Vec3D) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
    
    /// Compute dot product
    public static func dot(_ a: Vec3D, _ b: Vec3D) -> Double {
        return a.x * b.x + a.y * b.y + a.z * b.z
    }
    
    /// Compute vector norm
    public static func norm(_ v: Vec3D) -> Double {
        return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    }
    
    /// Clamp value to range
    public static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        return Swift.max(min, Swift.min(max, value))
    }
    
    // MARK: - Angular Separation
    
    /// Compute angular separation between two forward vectors
    /// Uses forward vectors with clamped acos (no quaternions)
    public static func angularSeparation(_ pose1: SensorPose, _ pose2: SensorPose) -> Double {
        // Finite checks
        guard isFinite(pose1.forward) && isFinite(pose2.forward) else {
            return Double.infinity
        }
        
        let n1 = norm(pose1.forward)
        let n2 = norm(pose2.forward)
        guard n1 > ObservationConstants.finiteEpsilon && n2 > ObservationConstants.finiteEpsilon else {
            return Double.infinity
        }
        
        let dotProduct = dot(pose1.forward, pose2.forward)
        let clamped = clamp(dotProduct, min: -1.0, max: 1.0)  // Prevent acos domain error
        return acos(clamped)
    }
    
    // MARK: - Variance Computations
    
    /// Compute variance of values
    public static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else {
            return 0.0
        }
        
        let mean = values.reduce(0.0, +) / Double(values.count)
        let sumSquaredDiff = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSquaredDiff / Double(values.count - 1)
    }
    
    /// Compute Lab color variance (deterministic: max of channel variances)
    public static func labVariance(_ colors: [LabColor]) -> Double {
        guard colors.count > 1 else {
            return 0.0
        }
        
        let lValues = colors.map { $0.l }
        let aValues = colors.map { $0.a }
        let bValues = colors.map { $0.b }
        
        let lVar = variance(lValues)
        let aVar = variance(aValues)
        let bVar = variance(bValues)
        
        // Return max of channel variances (deterministic)
        return Swift.max(Swift.max(lVar, aVar), bVar)
    }
}
