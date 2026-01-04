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
    )
]

public let GOLDEN_POLICY_HASH: String = "50837f3d89aa2d5f39ed8a5793b801f4bd209ba2263d9bf0d66c97663a710f1e"

