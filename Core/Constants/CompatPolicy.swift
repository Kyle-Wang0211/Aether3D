// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CompatPolicy.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Compatibility Policy Enumeration
//
// This enum defines compatibility policies for contract versions.
// CLOSED_SET: strictly fixed; any change requires RFC + major contract bump.
//

import Foundation

/// Compatibility policy enumeration (CLOSED_SET).
///
/// **Rule ID:** FoundationVersioning
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Strictly fixed; any change requires RFC + major contract bump
public enum CompatPolicy: String, Codable, CaseIterable {
    /// Append-only: new fields may be added, existing fields unchanged
    case appendOnly = "append_only"
    
    /// Breaking changes require RFC
    case breakingRequiresRFC = "breaking_requires_rfc"
}

/// Compatibility policy semantics.
///
/// **Rule ID:** D45
/// **Status:** IMMUTABLE
///
/// If compatPolicy=append_only then breaking changes forbidden without RFC.
public enum CompatPolicySemantics {
    // Semantics documented in CLOSED_SET_GOVERNANCE.md
    // Implementation belongs to governance layer
}
