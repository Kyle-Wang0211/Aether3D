// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HardFuseTrigger.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Hard Fuse Trigger Enumeration
//
// Closed-world hard fuse trigger enum (MUST)
// All enum raw string wire values MUST be SSOT-defined and identical across Python/Swift
//

import Foundation

/// Closed-world hard fuse trigger enumeration (MUST)
/// 
/// **Rule ID:** PR1 C-Class v2.3
/// **Status:** IMMUTABLE
/// 
/// **Requirement:** All triggers must be closed-world
/// 
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
public enum HardFuseTrigger: String, Codable, CaseIterable, Sendable {
    /// Hard limit triggered by patch count
    case PATCHCOUNT_HARD = "PATCHCOUNT_HARD"
    
    /// Hard limit triggered by EEB budget (optional trigger path)
    /// If unused in v1, still defined for audit clarity
    case EEB_HARD = "EEB_HARD"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    public static let schemaId = "HardFuseTrigger_v1.0"
}
