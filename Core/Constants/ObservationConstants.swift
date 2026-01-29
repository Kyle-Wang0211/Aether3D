//
// ObservationConstants.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - SSOT Constants
//
// Defines all thresholds for observational validity (L1/L2/L3).
// All constants are compile-time values with explicit defaults.
// No runtime injection, no platform differences.
//

import Foundation

/// Observation constants (SSOT)
/// 
/// **Rule ID:** PR1 E-Class
/// **Status:** IMMUTABLE
/// 
/// All thresholds are compile-time constants with explicit defaults.
/// Changing constants requires an explicit PR.
public enum ObservationConstants {
    /// L1: Minimum overlap area (ε)
    public static let minOverlapArea: Double = 1e-6
    
    /// L2: Minimum parallax ratio (r_min)
    public static let minParallaxRatio: Double = 0.02
    
    /// L2: Maximum reprojection error in pixels (ε_reproj)
    public static let maxReprojectionErrorPx: Double = 2.0
    
    /// L2: Maximum geometric variance (ε_geo)
    public static let maxGeometricVariance: Double = 1e-4
    
    /// L3: Maximum depth variance (ε_depth)
    public static let maxDepthVariance: Double = 1e-3
    
    /// L3: Maximum luminance variance (ε_L)
    public static let maxLuminanceVariance: Double = 1e-2
    
    /// L3: Maximum Lab color variance (ε_Lab)
    public static let maxLabVariance: Double = 1e-2
    
    /// Minimum angular separation in radians (θ_min = 5°)
    public static let minAngularSeparationRad: Double = 0.0872664626
    
    /// Forward vector unit-length tolerance
    public static let unitVectorTolerance: Double = 1e-6
    
    /// Finite check epsilon
    public static let finiteEpsilon: Double = 1e-12
}
