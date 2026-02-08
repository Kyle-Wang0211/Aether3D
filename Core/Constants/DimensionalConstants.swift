//
// DimensionalConstants.swift
// Aether3D
//
// PR6 Evidence Grid System - Dimensional Constants
// SSOT for dimensional evidence weights and thresholds
//

import Foundation

/// **Rule ID:** PR6_GRID_DIMENSIONAL_CONSTANTS_001
/// Dimensional Constants: SSOT for dimensional evidence weights and thresholds
public enum DimensionalConstants {
    
    /// **Rule ID:** PR6_GRID_DIMENSIONAL_CONSTANTS_002
    /// Reliability discount constants (MUST-FIX G)
    
    /// Reliability when tracking is stable
    public static let reliabilityTrackingStable: Double = 0.95
    
    /// Reliability when motion blur is detected
    public static let reliabilityMotionBlur: Double = 0.60
    
    /// Reliability when feature count is low
    public static let reliabilityLowFeatures: Double = 0.70
    
    /// Reliability when confidence is high
    public static let reliabilityHighConfidence: Double = 1.0
    
    /// **Rule ID:** PR6_GRID_DIMENSIONAL_CONSTANTS_003
    /// Dimensional weights (default weights for 15 dimensions)
    
    /// Default weights for dimensions ①-⑩ (active dimensions)
    public static let defaultDimensionalWeights: [Double] = [
        0.10,  // ① View gain
        0.10,  // ② Geometry gain
        0.08,  // ③ Depth quality
        0.08,  // ④ Semantic consistency
        0.06,  // ⑤ Error type score
        0.10,  // ⑥ Basic gain
        0.05,  // ⑦ Provenance contribution
        0.10,  // ⑧ Coverage tracker score
        0.08,  // ⑨ Resolution quality
        0.10,  // ⑩ View diversity
        // ⑪-⑮ are stubs (0.0 weight)
    ]
    
    /// Get reliability coefficient for a condition
    public static func reliability(for condition: ReliabilityCondition) -> Double {
        switch condition {
        case .trackingStable:
            return reliabilityTrackingStable
        case .motionBlur:
            return reliabilityMotionBlur
        case .lowFeatures:
            return reliabilityLowFeatures
        case .highConfidence:
            return reliabilityHighConfidence
        }
    }
    
    /// Reliability condition enum
    public enum ReliabilityCondition {
        case trackingStable
        case motionBlur
        case lowFeatures
        case highConfidence
    }
}
