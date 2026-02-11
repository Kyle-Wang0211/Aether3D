// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PatchClassification.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Patch Classification Enumeration
//
// Closed-world patch classification enum (MUST)
// All enum raw string wire values MUST be SSOT-defined and identical across Python/Swift
//

import Foundation

/// Closed-world patch classification enumeration (MUST)
/// 
/// **Rule ID:** PR1 C-Class v2.3
/// **Status:** IMMUTABLE
/// 
/// **Requirement:** All classifications must be closed-world
/// 
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
public enum PatchClassification: String, Codable, CaseIterable {
    /// Patch accepted into evidential set
    case ACCEPTED = "ACCEPTED"
    
    /// Patch rejected (not accepted)
    case REJECTED = "REJECTED"
    
    /// Patch for display only (excluded from evidence)
    case DISPLAY_ONLY = "DISPLAY_ONLY"
    
    /// Duplicate patch rejected
    case DUPLICATE_REJECTED = "DUPLICATE_REJECTED"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    public static let schemaId = "PatchClassification_v1.0"
}
