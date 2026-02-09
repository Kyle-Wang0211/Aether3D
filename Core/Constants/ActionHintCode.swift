// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ActionHintCode.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Action Hint Code Enumeration (B2)
//
// This enum defines all action hints for user guidance.
// APPEND_ONLY_CLOSED_SET: may only append cases at the end, never delete/rename/reorder.
//

import Foundation

/// Action hint code enumeration (APPEND_ONLY_CLOSED_SET).
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
public enum ActionHintCode: String, Codable, CaseIterable {
    /// Clear occlusion (move hand/object away)
    /// firstIntroducedInFoundationVersion: "1.1"
    case CLEAR_OCCLUSION = "HINT_CLEAR_OCCLUSION"
    
    /// Change scanning angle
    /// firstIntroducedInFoundationVersion: "1.1"
    case CHANGE_ANGLE = "HINT_CHANGE_ANGLE"
    
    /// Slow down scanning speed
    /// firstIntroducedInFoundationVersion: "1.1"
    case SLOW_DOWN = "HINT_SLOW_DOWN"
    
    /// Improve lighting conditions
    /// firstIntroducedInFoundationVersion: "1.1"
    case IMPROVE_LIGHT = "HINT_IMPROVE_LIGHT"
    
    /// Avoid reflections
    /// firstIntroducedInFoundationVersion: "1.1"
    case AVOID_REFLECTION = "HINT_AVOID_REFLECTION"
    
    /// Stabilize object
    /// firstIntroducedInFoundationVersion: "1.1"
    case STABILIZE_OBJECT = "HINT_STABILIZE_OBJECT"
    
    /// Declare as reflective-dominant
    /// firstIntroducedInFoundationVersion: "1.1"
    case DECLARE_REFLECTIVE = "HINT_DECLARE_REFLECTIVE"
    
    /// Declare as transparent-dominant
    /// firstIntroducedInFoundationVersion: "1.1"
    case DECLARE_TRANSPARENT = "HINT_DECLARE_TRANSPARENT"
    
    /// Declare as dynamic-intended
    /// firstIntroducedInFoundationVersion: "1.1"
    case DECLARE_DYNAMIC = "HINT_DECLARE_DYNAMIC"
    
    /// Resume scanning in same light
    /// firstIntroducedInFoundationVersion: "1.1"
    case RESUME_IN_SAME_LIGHT = "HINT_RESUME_IN_SAME_LIGHT"
    
    /// Contact support
    /// firstIntroducedInFoundationVersion: "1.1"
    case CONTACT_SUPPORT = "HINT_CONTACT_SUPPORT"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    /// **Rule ID:** B3
    public static let schemaId = "ActionHintCode_v1.1"
    
    /// Frozen case order hash (B3)
    /// **Rule ID:** B3
    /// **Status:** IMMUTABLE
    public static let frozenCaseOrderHash = "3a31d7d2a4011a9042917976b9521829623b624f08c8aa77a1519f9455dda07b"
}
