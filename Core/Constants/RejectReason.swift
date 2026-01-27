//
// RejectReason.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Reject Reason Enumeration
//
// Closed-world reject reason enum (MUST)
// All enum raw string wire values MUST be SSOT-defined and identical across Python/Swift
//

import Foundation

/// Closed-world reject reason enumeration (MUST)
/// 
/// **Rule ID:** PR1 C-Class v2.3
/// **Status:** IMMUTABLE
/// 
/// **Requirement:** All reasons must be closed-world
/// 
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
/// - No other reasons permitted unless added via explicit SSOT change
public enum RejectReason: String, Codable, CaseIterable, Sendable {
    /// Low information gain in SOFT damping mode
    case LOW_GAIN_SOFT = "LOW_GAIN_SOFT"
    
    /// Redundant coverage detected
    case REDUNDANT_COVERAGE = "REDUNDANT_COVERAGE"
    
    /// Duplicate patch detected
    case DUPLICATE = "DUPLICATE"
    
    /// Hard capacity limit reached
    case HARD_CAP = "HARD_CAP"
    
    /// Policy rejection (reserved for other closed policies, if already SSOT-defined)
    case POLICY_REJECT = "POLICY_REJECT"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    public static let schemaId = "RejectReason_v1.0"
}
