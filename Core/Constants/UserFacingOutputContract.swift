// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// UserFacingOutputContract.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - User-Facing Output Contract (B2)
//
// This file defines the user-facing output contract with guaranteed interpretability fields.
//

import Foundation

/// User-facing output contract with guaranteed interpretability fields.
///
/// **Rule ID:** CONTRACT_OUTPUT_002, B2
/// **Status:** IMMUTABLE
///
/// **Note:** This defines the contract only, not the logic implementation.
/// Logic implementation belongs to PR#6.
public struct UserFacingOutputContract {
    // MARK: - Guaranteed Interpretability Fields (B2)
    
    /// Primary reason code (exactly one, never null, deterministic).
    /// **Rule ID:** B2
    /// **Status:** IMMUTABLE
    ///
    /// Must reference USER_EXPLANATION_CATALOG.json.
    /// Represents the single dominant reason affecting asset state.
    public let primaryReasonCode: PrimaryReasonCode
    
    /// Primary reason confidence level.
    /// **Rule ID:** B2
    /// **Status:** IMMUTABLE
    public let primaryReasonConfidence: ReasonConfidence
    
    /// Next best action hints (0+ entries, stable order).
    /// **Rule ID:** B2
    /// **Status:** IMMUTABLE
    ///
    /// Each entry must:
    /// - Exist in explanation catalog
    /// - Be actionable
    /// - Be user-safe
    public let nextBestActionHints: [ActionHintCode]
    
    /// Compute phase indicator.
    /// **Rule ID:** B2
    /// **Status:** IMMUTABLE
    public let computePhase: ComputePhase
    
    /// Progress confidence (0.0 to 1.0).
    /// **Rule ID:** B2
    /// **Status:** IMMUTABLE
    ///
    /// Tells UI: how trustworthy is current progress?
    public let progressConfidence: Double
    
    // MARK: - Supporting Enums
    
    /// Reason confidence level.
    public enum ReasonConfidence: String, Codable {
        case unknown
        case likely
        case confirmed
    }
    
    /// Compute phase.
    public enum ComputePhase: String, Codable {
        case realtimeEstimate = "realtime_estimate"
        case delayedRefinement = "delayed_refinement"
        case finalized = "finalized"
    }
    
    // MARK: - Explicit Non-Goals
    
    /// **This contract does NOT define:**
    /// - Scoring logic (PR#6)
    /// - Priority heuristics (PR#6)
    /// - Localization (UI layer)
    /// - UI copy decisions (UI layer)
}
