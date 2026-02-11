// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  InvariantPolicies.swift
//  Aether3D
//
//  PR#7: Phase 2a - Core/Invariants
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
typealias SHA256Impl = CryptoKit.SHA256
#else
import Crypto
typealias SHA256Impl = Crypto.SHA256
#endif



public enum ViolationSeverity: String, Codable {
    case fatal
    case hardFail
    case softFail
}

public enum ResponseAction: String, Codable {
    case halt
    case safeMode
    case logContinue
}

public struct InvariantViolationPolicy: Codable {
    public let invariantName: String
    public let severity: ViolationSeverity
    public let responseAction: ResponseAction
    
    public init(invariantName: String, severity: ViolationSeverity, responseAction: ResponseAction) {
        self.invariantName = invariantName
        self.severity = severity
        self.responseAction = responseAction
    }
}

public let INVARIANT_POLICIES: [InvariantViolationPolicy] = [
    InvariantViolationPolicy(
        invariantName: "policy_hash_mismatch",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "profile_not_closed_set",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "profile_runtime_switch",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "grid_resolution_not_in_closed_set",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "patch_size_out_of_profile_range",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "dynamic_precision",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "float_in_identity",
        severity: .fatal,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "evidence_budget_exceeded",
        severity: .hardFail,
        responseAction: .halt
    ),
    InvariantViolationPolicy(
        invariantName: "micro_scale_direct_display",
        severity: .hardFail,
        responseAction: .halt
    )
]

public let GOLDEN_POLICY_HASH: String = "71398104e0d1f6fcecd381d893fd5c3a0f49d4740a86740030f7874b2ddf86bf"

