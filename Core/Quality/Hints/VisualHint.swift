//
//  VisualHint.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 5
//  VisualHint - protocol layer unified type for hints
//

import Foundation

/// VisualHint - protocol layer unified type for visual hints
/// Hides internal implementation (may separate into Prompt/GuidanceHint internally)
public struct VisualHint: Codable {
    public let domain: HintDomain
    public let strength: HintStrength
    public let direction: CodableVector?
    
    public init(domain: HintDomain, strength: HintStrength, direction: CodableVector? = nil) {
        self.domain = domain
        self.strength = strength
        self.direction = direction
    }
}

/// HintAction - action taken for hint
public enum HintAction: String, Codable {
    case shown = "shown"
    case suppressed = "suppressed"
}

/// HintSuppressionReason - reason for hint suppression
public enum HintSuppressionReason: String, Codable {
    case quotaExceeded = "quotaExceeded"
    case cooldown = "cooldown"
    case whiteRegion = "whiteRegion"
    case speedFeedback = "speedFeedback"
    case consistency = "consistency"
}

/// HintQuotaState - current quota state
public struct HintQuotaState: Codable {
    public let strongCount: Int
    public let subtleCountByDirection: [DirectionId: Int]
    
    public init(strongCount: Int, subtleCountByDirection: [DirectionId: Int]) {
        self.strongCount = strongCount
        self.subtleCountByDirection = subtleCountByDirection
    }
}

/// HintAuditEntry - audit entry for hint decisions (H1)
public struct HintAuditEntry: Codable {
    public let sessionId: String
    public let hintDomain: HintDomain
    public let hintStrength: HintStrength
    public let action: HintAction
    public let suppressionReason: HintSuppressionReason?
    public let quotaState: HintQuotaState
    public let timestamp: Int64
    
    public init(
        sessionId: String,
        hintDomain: HintDomain,
        hintStrength: HintStrength,
        action: HintAction,
        suppressionReason: HintSuppressionReason? = nil,
        quotaState: HintQuotaState,
        timestamp: Int64
    ) {
        self.sessionId = sessionId
        self.hintDomain = hintDomain
        self.hintStrength = hintStrength
        self.action = action
        self.suppressionReason = suppressionReason
        self.quotaState = quotaState
        self.timestamp = timestamp
    }
}

