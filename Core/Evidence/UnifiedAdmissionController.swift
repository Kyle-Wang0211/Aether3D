//
// UnifiedAdmissionController.swift
// Aether3D
//
// PR2 Patch V4 - Unified Admission Controller
// Hard-block vs soft-penalty separation with guaranteed minimum throughput
//

import Foundation
import CAetherNativeBridge

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
    
    private let nativeController: OpaquePointer
    
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
        _ = spamProtection
        _ = tokenBucket
        _ = viewDiversity
        var controller: OpaquePointer?
        let rc = aether_admission_controller_create(&controller)
        precondition(rc == 0, "aether_admission_controller_create failed: rc=\(rc)")
        precondition(controller != nil, "aether_admission_controller_create returned nil controller")
        nativeController = controller!
    }

    deinit {
        _ = aether_admission_controller_destroy(nativeController)
    }
    
    /// Compute admission decision
    public func checkAdmission(
        patchId: String,
        viewAngle: Float,
        timestamp: TimeInterval
    ) -> EvidenceAdmissionDecision {
        let timestampMs = Int64(timestamp * 1000.0)
        var nativeDecision = aether_admission_decision_t()
        let rc = patchId.withCString { cPatchId in
            aether_admission_controller_check(
                nativeController,
                cPatchId,
                Double(viewAngle),
                timestampMs,
                &nativeDecision
            )
        }
        precondition(rc == 0, "aether_admission_controller_check failed: rc=\(rc)")

        return EvidenceAdmissionDecision(
            allowed: nativeDecision.allowed != 0,
            qualityScale: nativeDecision.quality_scale,
            reasons: Self.reasons(fromMask: nativeDecision.reason_mask)
        )
    }
    
    /// Check for confirmed spam (HARD BLOCK)
    /// Called separately when spam detection confirms malicious behavior
    public func checkConfirmedSpam(
        patchId: String,
        spamScore: Double,
        threshold: Double = 0.95
    ) -> EvidenceAdmissionDecision {
        var nativeDecision = aether_admission_decision_t()
        let rc = patchId.withCString { cPatchId in
            aether_admission_controller_check_confirmed_spam(
                nativeController,
                cPatchId,
                spamScore,
                threshold,
                &nativeDecision
            )
        }
        precondition(rc == 0, "aether_admission_controller_check_confirmed_spam failed: rc=\(rc)")
        return EvidenceAdmissionDecision(
            allowed: nativeDecision.allowed != 0,
            qualityScale: nativeDecision.quality_scale,
            reasons: Self.reasons(fromMask: nativeDecision.reason_mask)
        )
    }

    #if canImport(CAetherNativeBridge)
    private static func reasons(fromMask mask: UInt32) -> [EvidenceAdmissionDecision.EvidenceAdmissionReason] {
        var reasons: [EvidenceAdmissionDecision.EvidenceAdmissionReason] = []
        if (mask & (UInt32(1) << UInt32(AETHER_ADMISSION_REASON_TIME_DENSITY_SAME_PATCH))) != 0 {
            reasons.append(.timeDensitySamePatch)
        }
        if (mask & (UInt32(1) << UInt32(AETHER_ADMISSION_REASON_TOKEN_BUCKET_LOW))) != 0 {
            reasons.append(.tokenBucketLow)
        }
        if (mask & (UInt32(1) << UInt32(AETHER_ADMISSION_REASON_NOVELTY_LOW))) != 0 {
            reasons.append(.noveltyLow)
        }
        if (mask & (UInt32(1) << UInt32(AETHER_ADMISSION_REASON_FREQUENCY_CAP))) != 0 {
            reasons.append(.frequencyCap)
        }
        if (mask & (UInt32(1) << UInt32(AETHER_ADMISSION_REASON_CONFIRMED_SPAM))) != 0 {
            reasons.append(.confirmedSpam)
        }
        if reasons.isEmpty {
            reasons.append(.allowed)
        }
        return reasons
    }
    #else
    private static func reasons(fromMask _: UInt32) -> [EvidenceAdmissionDecision.EvidenceAdmissionReason] {
        [.allowed]
    }
    #endif
}

// SpamProtection, TokenBucketLimiter, and ViewDiversityTracker are now implemented in separate files
