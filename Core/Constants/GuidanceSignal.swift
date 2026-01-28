//
// GuidanceSignal.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Guidance Signal Enumeration
//
// Closed-world guidance signal enum for no-text UX (MUST)
// All enum raw string wire values MUST be SSOT-defined and identical across Python/Swift
//

import Foundation

/// Closed-world guidance signal enumeration for no-text UX (MUST)
/// 
/// **Rule ID:** PR1 C-Class v2.3
/// **Status:** IMMUTABLE
/// 
/// **Requirement:** All signals must be closed-world
/// 
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
public enum GuidanceSignal: String, Codable, CaseIterable {
    /// Heat/cool coverage visualization (missing vs redundant regions)
    case HEAT_COOL_COVERAGE = "HEAT_COOL_COVERAGE"
    
    /// Directional affordance (arrows, edge flow, boundary highlight)
    case DIRECTIONAL_AFFORDANCE = "DIRECTIONAL_AFFORDANCE"
    
    /// Static overlay (SATURATED freeze - overlay becomes static)
    case STATIC_OVERLAY = "STATIC_OVERLAY"
    
    /// No guidance signal
    case NONE = "NONE"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    public static let schemaId = "GuidanceSignal_v1.0"
}
