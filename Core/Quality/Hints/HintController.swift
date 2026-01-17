//
//  HintController.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 5
//  HintController - manages hint display logic and limits (H1: session-level logging)
//

import Foundation

/// HintController - manages visual hint display
/// H1: Session-level logging for all hint decisions
public class HintController {
    private var strongCount: Int = 0
    private var subtleCountByDirection: [DirectionId: Int] = [:]
    private var lastHintTime: Int64 = 0
    private var sessionId: String
    
    public init(sessionId: String) {
        self.sessionId = sessionId
    }
    
    /// Check if hint should be shown
    /// H1: Log all decisions (shown or suppressed)
    public func shouldShowHint(
        domain: HintDomain,
        strength: HintStrength,
        currentDirectionId: DirectionId?
    ) -> (show: Bool, reason: String?) {
        let now = MonotonicClock.nowMs()
        
        // Check cooldown
        if now - lastHintTime < QualityPreCheckConstants.HINT_COOLDOWN_MS {
            logHintDecision(domain: domain, strength: strength, action: .suppressed, reason: .cooldown)
            return (false, "Cooldown")
        }
        
        // Check quota
        if strength == .strong {
            if strongCount >= QualityPreCheckConstants.HINT_MAX_STRONG_PER_SESSION {
                logHintDecision(domain: domain, strength: strength, action: .suppressed, reason: .quotaExceeded)
                return (false, "Strong quota exceeded")
            }
        } else {
            if let directionId = currentDirectionId {
                let count: Int
                if let existing = subtleCountByDirection[directionId] {
                    count = existing
                } else {
                    count = 0
                }
                if count >= QualityPreCheckConstants.HINT_MAX_SUBTLE_PER_DIRECTION {
                    logHintDecision(domain: domain, strength: strength, action: .suppressed, reason: .quotaExceeded)
                    return (false, "Subtle quota exceeded")
                }
            }
        }
        
        // Show hint
        logHintDecision(domain: domain, strength: strength, action: .shown, reason: nil)
        lastHintTime = now
        
        if strength == .strong {
            strongCount += 1
        } else if let directionId = currentDirectionId {
            let current: Int
            if let existing = subtleCountByDirection[directionId] {
                current = existing
            } else {
                current = 0
            }
            subtleCountByDirection[directionId] = current + 1
        }
        
        return (true, nil)
    }
    
    /// Log hint decision (H1)
    private func logHintDecision(
        domain: HintDomain,
        strength: HintStrength,
        action: HintAction,
        reason: HintSuppressionReason?
    ) {
        let quotaState = HintQuotaState(
            strongCount: strongCount,
            subtleCountByDirection: subtleCountByDirection
        )
        
        let _ = HintAuditEntry(
            sessionId: sessionId,
            hintDomain: domain,
            hintStrength: strength,
            action: action,
            suppressionReason: reason,
            quotaState: quotaState,
            timestamp: MonotonicClock.nowMs()
        )
        // In real implementation, this would be logged to audit system
    }
}

