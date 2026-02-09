// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PolicyProof.swift
// PR5Capture
//
// PR5 v1.8.1 - PART C: 状态机增强
// 策略决策证明，决策原因记录，可解释性支持
//

import Foundation

/// Policy proof generator
///
/// Generates proofs for policy decisions with decision reasons.
/// Supports explainability by recording decision rationale.
public actor PolicyProof {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Decision proof history
    private var decisionProofs: [DecisionProof] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Proof Generation
    
    /// Generate proof for a policy decision
    ///
    /// Records decision with full rationale for explainability
    public func generateProof(
        decision: PolicyDecision,
        reason: String,
        inputs: [String: String] = [:],
        timestamp: Date = Date()
    ) -> DecisionProof {
        let proof = DecisionProof(
            id: UUID(),
            timestamp: timestamp,
            decision: decision,
            reason: reason,
            inputs: inputs,
            configSnapshot: config.profile.rawValue
        )
        
        decisionProofs.append(proof)
        
        // Keep only recent proofs (last 1000)
        if decisionProofs.count > 1000 {
            decisionProofs.removeFirst()
        }
        
        return proof
    }
    
    /// Get proof by ID
    public func getProof(_ id: UUID) -> DecisionProof? {
        return decisionProofs.first { $0.id == id }
    }
    
    /// Get recent proofs
    public func getRecentProofs(count: Int = 10) -> [DecisionProof] {
        return Array(decisionProofs.suffix(count))
    }
    
    /// Get proofs for a decision type
    public func getProofs(for decision: PolicyDecision) -> [DecisionProof] {
        return decisionProofs.filter { $0.decision == decision }
    }
    
    // MARK: - Data Types
    
    /// Policy decision
    public enum PolicyDecision: String, Codable, Sendable, CaseIterable {
        case accept
        case reject
        case `defer`
        case emergencyOverride
    }
    
    /// Decision proof
    public struct DecisionProof: Sendable {
        public let id: UUID
        public let timestamp: Date
        public let decision: PolicyDecision
        public let reason: String
        public let inputs: [String: String]  // Use String instead of Any for Sendable
        public let configSnapshot: String
        
        public init(
            id: UUID = UUID(),
            timestamp: Date,
            decision: PolicyDecision,
            reason: String,
            inputs: [String: String],
            configSnapshot: String
        ) {
            self.id = id
            self.timestamp = timestamp
            self.decision = decision
            self.reason = reason
            self.inputs = inputs
            self.configSnapshot = configSnapshot
        }
    }
}
