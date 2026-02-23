//
// SpamProtection.swift
// Aether3D
//
// PR2 Patch V4 - Spam Protection (Signal Provider)
// Provides quality scale factors, does NOT hard-block
//

import Foundation
import CAetherNativeBridge

/// Spam protection signal provider
///
/// DESIGN:
/// - Provides quality scale factors (0.0 to 1.0)
/// - Does NOT hard-block (UnifiedAdmissionController handles hard blocks)
/// - Tracks per-patch update frequency
public final class SpamProtection {
    private let nativeSpam: OpaquePointer
    
    public init() {
        var spam: OpaquePointer?
        let rc = aether_spam_protection_create(&spam)
        precondition(rc == 0, "aether_spam_protection_create failed: rc=\(rc)")
        precondition(spam != nil, "aether_spam_protection_create returned nil")
        nativeSpam = spam!
    }

    deinit {
        _ = aether_spam_protection_destroy(nativeSpam)
    }
    
    /// Record an update for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - timestampMs: Current timestamp in milliseconds
    public func recordUpdate(patchId: String, timestampMs: Int64) {
        var scale: Double = 1.0
        let rc = patchId.withCString { cPatchId in
            aether_spam_protection_frequency_scale(nativeSpam, cPatchId, timestampMs, &scale)
        }
        precondition(rc == 0, "aether_spam_protection_frequency_scale failed in recordUpdate: rc=\(rc)")
    }
    
    /// Get frequency cap scale factor
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - timestampMs: Current timestamp in milliseconds
    /// - Returns: Scale factor [0, 1] where 1.0 = no penalty, 0.0 = maximum penalty
    public func frequencyScale(patchId: String, timestampMs: Int64) -> Double {
        var scale: Double = 1.0
        let rc = patchId.withCString { cPatchId in
            aether_spam_protection_frequency_scale(nativeSpam, cPatchId, timestampMs, &scale)
        }
        precondition(rc == 0, "aether_spam_protection_frequency_scale failed: rc=\(rc)")
        return scale
    }
    
    /// Convert raw novelty score to scale factor
    ///
    /// - Parameter rawNovelty: Raw novelty score [0, 1]
    /// - Returns: Scale factor [0, 1] where low novelty = lower scale
    public func noveltyScale(rawNovelty: Double) -> Double {
        var scale: Double = 1.0
        let rc = aether_spam_protection_novelty_scale(nativeSpam, rawNovelty, &scale)
        precondition(rc == 0, "aether_spam_protection_novelty_scale failed: rc=\(rc)")
        return scale
    }
    
    /// Check if update should be allowed (time density check)
    /// NOTE: This is used by UnifiedAdmissionController for hard-blocking
    /// SpamProtection itself does NOT hard-block
    public func shouldAllowUpdate(patchId: String, timestamp: TimeInterval) -> Bool {
        let timestampMs = Int64(timestamp * 1000.0)
        var allowed: Int32 = 1
        let rc = patchId.withCString { cPatchId in
            aether_spam_protection_should_allow_update(nativeSpam, cPatchId, timestampMs, &allowed)
        }
        precondition(rc == 0, "aether_spam_protection_should_allow_update failed: rc=\(rc)")
        return allowed != 0
    }
    
    /// Reset all state
    public func reset() {
        _ = aether_spam_protection_reset(nativeSpam)
    }
}
