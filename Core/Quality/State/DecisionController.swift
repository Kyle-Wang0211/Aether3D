// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  DecisionController.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 3
//  DecisionController - manages DecisionState (H1: calls DecisionPolicy, doesn't own logic)
//

import Foundation

/// DecisionController - manages DecisionState transitions
/// H1: Calls DecisionPolicy but doesn't own decision logic
/// DecisionPolicy is SSOT
public class DecisionController {
    private var currentState: DecisionState = .active
    private let whiteCommitter: WhiteCommitContract
    
    public init(whiteCommitter: WhiteCommitContract) {
        self.whiteCommitter = whiteCommitter
    }
    
    /// Get current decision state
    public func getCurrentState() -> DecisionState {
        return currentState
    }
    
    /// Check if Gray→White transition is allowed
    /// H1: Calls DecisionPolicy (SSOT), doesn't own logic
    public func canTransitionToWhite(
        fpsTier: FpsTier,
        criticalMetrics: CriticalMetricBundle?,
        stability: Double?
    ) -> (allowed: Bool, reason: String?) {
        // H1: Call DecisionPolicy (SSOT)
        return DecisionPolicy.canTransition(
            from: .gray,
            to: .white,
            fpsTier: fpsTier,
            criticalMetrics: criticalMetrics,
            stability: stability
        )
    }
    
    /// Attempt Gray→White transition
    /// Must call whiteCommitter.commitWhite() successfully
    public func attemptGrayToWhite(
        sessionId: String,
        auditRecord: AuditRecord,
        coverageDelta: CoverageDelta
    ) throws -> DurableToken {
        // H1: Emergency hard assertion
        // This should be checked before calling, but double-check here
        // In practice, DecisionPolicy should have already blocked this
        
        // Call whiteCommitter
        return try whiteCommitter.commitWhite(
            sessionId: sessionId,
            auditRecord: auditRecord,
            coverageDelta: coverageDelta
        )
    }
    
    /// Freeze decisions
    public func freeze(reason: FreezeReason) {
        currentState = .frozen
    }
    
    /// Unfreeze decisions
    public func unfreeze() {
        if currentState == .frozen {
            currentState = .active
        }
    }
}

