//
// UnifiedAdmissionController.swift
// Aether3D
//
// PR2 Patch V4 - Unified Admission Controller
// Hard-block vs soft-penalty separation with guaranteed minimum throughput
//

import Foundation

/// Evidence admission decision result
/// NOTE: Different from Core/Quality/Admission/AdmissionDecision
public struct EvidenceAdmissionDecision: Sendable {
    
    /// Whether observation is allowed
    public let allowed: Bool
    
    /// Quality scale factor [0, 1] - applied even if allowed
    public let qualityScale: Double
    
    /// Reasons for decision (debug only)
    public let reasons: [EvidenceAdmissionReason]
    
    public enum EvidenceAdmissionReason: String, Sendable {
        case allowed = "allowed"
        case timeDensitySamePatch = "time_density_same_patch"
        case tokenBucketLow = "token_bucket_low"
        case noveltyLow = "novelty_low"
        case frequencyCap = "frequency_cap"
        case confirmedSpam = "confirmed_spam"
    }
    
    /// Hard block: observation is completely rejected
    /// Reasons: time density on same patch, confirmed spam
    public var isHardBlocked: Bool {
        return !allowed && reasons.contains { reason in
            reason == .timeDensitySamePatch || reason == .confirmedSpam
        }
    }
    
    public init(allowed: Bool, qualityScale: Double, reasons: [EvidenceAdmissionReason]) {
        self.allowed = allowed
        self.qualityScale = qualityScale
        self.reasons = reasons
    }
}

/// Unified admission controller with guaranteed minimum throughput
public final class UnifiedAdmissionController {
    
    // MARK: - Dependencies
    
    private let spamProtection: SpamProtection
    private let tokenBucket: TokenBucketLimiter
    private let viewDiversity: ViewDiversityTracker
    
    // MARK: - Configuration
    
    /// Minimum soft penalty scale (GUARANTEED MINIMUM THROUGHPUT)
    /// Even worst-case compound penalties cannot go below this
    /// RATIONALE: Weak-texture scenes should still make progress
    public static let minimumSoftScale: Double = EvidenceConstants.minimumSoftScale
    
    /// Soft penalty when token unavailable
    public static let noTokenPenalty: Double = EvidenceConstants.noTokenPenalty
    
    /// Low novelty threshold
    public static let lowNoveltyThreshold: Double = EvidenceConstants.lowNoveltyThreshold
    
    /// Soft penalty for low novelty
    public static let lowNoveltyPenalty: Double = EvidenceConstants.lowNoveltyPenalty
    
    // MARK: - Public API
    
    public init(
        spamProtection: SpamProtection,
        tokenBucket: TokenBucketLimiter,
        viewDiversity: ViewDiversityTracker
    ) {
        self.spamProtection = spamProtection
        self.tokenBucket = tokenBucket
        self.viewDiversity = viewDiversity
    }
    
    /// Compute admission decision
    public func checkAdmission(
        patchId: String,
        viewAngle: Float,
        timestamp: TimeInterval
    ) -> EvidenceAdmissionDecision {
        
        // LAYER 1: Time density (HARD BLOCK for same patch)
        // This is the ONLY hard block in normal operation
        if !spamProtection.shouldAllowUpdate(patchId: patchId, timestamp: timestamp) {
            return EvidenceAdmissionDecision(
                allowed: false,
                qualityScale: 0.0,
                reasons: [.timeDensitySamePatch]
            )
        }
        
        // LAYER 2: Token bucket (SOFT PENALTY)
        let timestampMs = Int64(timestamp * 1000.0)
        let hasToken = tokenBucket.tryConsume(patchId: patchId, timestampMs: timestampMs)
        let tokenScale: Double = hasToken ? 1.0 : Self.noTokenPenalty
        
        // LAYER 3: View novelty (SOFT PENALTY)
        let novelty = viewDiversity.addObservation(
            patchId: patchId,
            viewAngleDeg: Double(viewAngle),
            timestampMs: timestampMs
        )
        let noveltyScale = spamProtection.noveltyScale(rawNovelty: novelty)
        
        // LAYER 4: Frequency cap (SOFT PENALTY)
        let frequencyScale = spamProtection.frequencyScale(patchId: patchId, timestampMs: timestampMs)
        
        // COMPOUND PENALTY with GUARANTEED MINIMUM
        var combinedScale = tokenScale * noveltyScale * frequencyScale
        
        // CRITICAL: Enforce minimum throughput
        combinedScale = max(Self.minimumSoftScale, combinedScale)
        
        // Determine reasons
        var reasons: [EvidenceAdmissionDecision.EvidenceAdmissionReason] = []
        if !hasToken {
            reasons.append(.tokenBucketLow)
        }
        if novelty < Self.lowNoveltyThreshold {
            reasons.append(.noveltyLow)
        }
        if frequencyScale < 1.0 {
            reasons.append(.frequencyCap)
        }
        if reasons.isEmpty {
            reasons.append(.allowed)
        }
        
        return EvidenceAdmissionDecision(
            allowed: true,
            qualityScale: combinedScale,
            reasons: reasons
        )
    }
    
    /// Check for confirmed spam (HARD BLOCK)
    /// Called separately when spam detection confirms malicious behavior
    public func checkConfirmedSpam(
        patchId: String,
        spamScore: Double,
        threshold: Double = 0.95
    ) -> EvidenceAdmissionDecision {
        if spamScore >= threshold {
            return EvidenceAdmissionDecision(
                allowed: false,
                qualityScale: 0.0,
                reasons: [.confirmedSpam]
            )
        }
        return EvidenceAdmissionDecision(
            allowed: true,
            qualityScale: 1.0,
            reasons: [.allowed]
        )
    }
}

// SpamProtection, TokenBucketLimiter, and ViewDiversityTracker are now implemented in separate files
