// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZRuleIDs.swift
// Aether3D
//
// PR1 PIZ Detection - Rule IDs Source of Truth
//
// Closed-set list of all Rule IDs declared in spec v1.3.
// This file serves as the single source of truth for Rule ID coverage verification.

import Foundation

/// All Rule IDs declared in PR1 spec v1.3 (closed set).
/// **Rule ID:** PIZ_COVERAGE_REGRESSION
public enum PIZRuleIDs {
    /// All Rule IDs in lexicographic order.
    public static let all: [String] = [
        "PIZ_CI_FAILURE_TAXONOMY_001",
        "PIZ_COMBINE_001",
        "PIZ_COMPONENT_MEMBERSHIP_001",
        "PIZ_CONNECTIVITY_001",
        "PIZ_CONNECTIVITY_DETERMINISM_001",
        "PIZ_COVERED_CELL_001",
        "PIZ_DECISION_EXPLAINABILITY_SEPARATION_001",
        "PIZ_DECISION_INDEPENDENCE_001",
        "PIZ_DIRECTION_TIEBREAK_001",
        "PIZ_FLOAT_CANON_001",
        "PIZ_FLOAT_CLASSIFICATION_001",
        "PIZ_FLOAT_COMPARISON_001",
        "PIZ_GEOMETRY_DETERMINISM_001",
        "PIZ_GLOBAL_001",
        "PIZ_GLOBAL_REGION_001",
        "PIZ_HYSTERESIS_001",
        "PIZ_INPUT_BUDGET_001",
        "PIZ_INPUT_VALIDATION_001",
        "PIZ_INPUT_VALIDATION_002",
        "PIZ_JSON_CANON_001",
        "PIZ_LOCAL_001",
        "PIZ_MAX_REGIONS_DERIVED_001",
        "PIZ_NOISE_001",
        "PIZ_NUMERIC_ACCELERATION_BAN_001",
        "PIZ_NUMERIC_FORMAT_001",
        "PIZ_OUTPUT_PROFILE_001",
        "PIZ_REGION_ID_001",
        "PIZ_REGION_ID_SPEC_001",
        "PIZ_REGION_ORDER_002",
        "PIZ_SCHEMA_COMPAT_001",
        "PIZ_SCHEMA_PROFILE_001",
        "PIZ_SEMANTIC_PARITY_001",
        "PIZ_STATEFUL_GATE_001",
        "PIZ_TOLERANCE_SSOT_001",
        "PIZ_TRAVERSAL_ORDER_001"
    ]
    
    /// Verify all Rule IDs are unique.
    public static func verifyUniqueness() -> Bool {
        let unique = Set(all)
        return unique.count == all.count
    }
}
