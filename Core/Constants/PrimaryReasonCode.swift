//
// PrimaryReasonCode.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Primary Reason Code Enumeration (B2)
//
// This enum defines all primary reason codes that explain asset state.
// APPEND_ONLY_CLOSED_SET: may only append cases at the end, never delete/rename/reorder.
//

import Foundation

/// Primary reason code enumeration (APPEND_ONLY_CLOSED_SET).
///
/// **Rule ID:** B2, B3
/// **Status:** IMMUTABLE
///
/// **Requirement:** All codes must reference USER_EXPLANATION_CATALOG.json
///
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
/// - Each case must record firstIntroducedInFoundationVersion
public enum PrimaryReasonCode: String, Codable, CaseIterable {
    /// Normal scan - no issues detected
    /// firstIntroducedInFoundationVersion: "1.1"
    case NORMAL = "PRC_NORMAL"
    
    /// Hand or object occlusion during capture
    /// firstIntroducedInFoundationVersion: "1.1"
    case CAPTURE_OCCLUDED = "PRC_CAPTURE_OCCLUDED"
    
    /// Structural occlusion confirmed
    /// firstIntroducedInFoundationVersion: "1.1"
    case STRUCTURAL_OCCLUSION_CONFIRMED = "PRC_STRUCTURAL_OCCLUSION_CONFIRMED"
    
    /// Boundary uncertainty
    /// firstIntroducedInFoundationVersion: "1.1"
    case BOUNDARY_UNCERTAIN = "PRC_BOUNDARY_UNCERTAIN"
    
    /// Specular reflection dominant
    /// firstIntroducedInFoundationVersion: "1.1"
    case SPECULAR = "PRC_SPECULAR"
    
    /// Transparent or see-through material
    /// firstIntroducedInFoundationVersion: "1.1"
    case TRANSPARENT_SEETHROUGH = "PRC_TRANSPARENT_SEETHROUGH"
    
    /// Porous material
    /// firstIntroducedInFoundationVersion: "1.1"
    case POROUS_SEETHROUGH = "PRC_POROUS_SEETHROUGH"
    
    /// Dynamic motion detected
    /// firstIntroducedInFoundationVersion: "1.1"
    case DYNAMIC_MOTION = "PRC_DYNAMIC_MOTION"
    
    /// Edge case triggered
    /// firstIntroducedInFoundationVersion: "1.1"
    case EDGE_CASE_TRIGGERED = "PRC_EDGE_CASE_TRIGGERED"
    
    /// Risk flags detected
    /// firstIntroducedInFoundationVersion: "1.1"
    case RISK_FLAGGED = "PRC_RISK_FLAGGED"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    /// **Rule ID:** B3
    public static let schemaId = "PrimaryReasonCode_v1.1"
    
    /// Frozen case order hash (B3)
    /// **Rule ID:** B3
    /// **Status:** IMMUTABLE
    public static let frozenCaseOrderHash = "f2ed056c978ecdbbd6c509c4ca3ff13545f91edc547056b01c97ead6bd60cd56"
}
