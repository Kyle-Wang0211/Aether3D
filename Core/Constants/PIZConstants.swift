//
// PIZConstants.swift
// Aether3D
//
// PR1 PIZ Detection - Additional Constants
//
// Constants for PIZ detection that don't belong in PIZThresholds.
// **Rule ID:** PIZ_SCHEMA_COMPAT_001

import Foundation

extension CodingUserInfoKey {
    /// User info key for schema version compatibility checking.
    /// **Rule ID:** PIZ_SCHEMA_COMPAT_001
    public static let pizSchemaVersion = CodingUserInfoKey(rawValue: "pizSchemaVersion")!
}

/// **Rule ID:** PR6_GRID_PIZ_CONSTANTS_001
/// PR6 PIZ Constants: per-profile thresholds for grid-based PIZ analysis
public enum PIZGridConstants {
    
    /// Persistence window (seconds)
    public static let persistenceWindowSec: Double = 30.0
    
    /// Improvement threshold (per second)
    public static let improvementThreshold: Double = 0.01
    
    /// Minimum area in square meters
    public static let minAreaSqM: Double = 0.001
    
    /// Get PIZ thresholds for a profile
    public static func thresholds(for profile: CaptureProfile) -> (persistenceWindowSec: Double, improvementThreshold: Double, minAreaSqM: Double) {
        switch profile {
        case .standard:
            return (30.0, 0.01, 0.001)
        case .smallObjectMacro:
            return (20.0, 0.015, 0.0005)  // Stricter for macro
        case .largeScene:
            return (45.0, 0.008, 0.005)   // More lenient for large scenes
        case .proMacro:
            return (15.0, 0.02, 0.00025)  // Very strict for pro macro
        case .cinematicScene:
            return (60.0, 0.005, 0.01)    // Very lenient for cinematic
        }
    }
}
