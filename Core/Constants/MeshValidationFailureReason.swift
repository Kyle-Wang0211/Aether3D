//
// MeshValidationFailureReason.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Mesh Validation Failure Reason Enumeration
//
// This enum defines reasons for mesh validation failure.
// CLOSED_SET: strictly fixed; any change requires RFC + major contract bump.
//

import Foundation

/// Mesh validation failure reason enumeration (CLOSED_SET).
///
/// **Rule ID:** CONTRACT_MESH_INPUT_001A
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Strictly fixed; any change requires RFC + major contract bump
public enum MeshValidationFailureReason: String, Codable, CaseIterable {
    /// Triangle count too low (< 100)
    case triangleCountTooLow = "TRIANGLE_COUNT_TOO_LOW"
    
    /// Triangle count too high (> 500,000)
    case triangleCountTooHigh = "TRIANGLE_COUNT_TOO_HIGH"
    
    /// NaN or Inf detected in vertices
    case nanOrInfDetected = "NAN_OR_INF_DETECTED"
    
    /// Coordinate out of range (not in [-1000m, 1000m])
    case coordinateOutOfRange = "COORDINATE_OUT_OF_RANGE"
    
    /// Input data corrupted
    case inputCorrupted = "INPUT_CORRUPTED"
}
