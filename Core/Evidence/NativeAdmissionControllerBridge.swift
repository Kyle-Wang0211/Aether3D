// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for the admission controller subsystem.
/// Delegates to optimized C++ implementation when available.
/// Wraps spam protection, token bucket, view diversity, and admission controller APIs.
enum NativeAdmissionControllerBridge {

    // MARK: - Spam Protection

    static func spamProtectionCreate() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var spam: OpaquePointer?
        let rc = aether_spam_protection_create(&spam)
        return rc == 0 ? spam : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func spamProtectionDestroy(_ spam: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_spam_protection_destroy(spam)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func spamProtectionReset(_ spam: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_spam_protection_reset(spam)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func spamProtectionShouldAllowUpdate(
        _ spam: OpaquePointer,
        patchID: String,
        timestampMs: Int64
    ) -> Bool {
        #if canImport(CAetherNativeBridge)
        var allowed: Int32 = 0
        let rc = patchID.withCString { cStr in
            aether_spam_protection_should_allow_update(spam, cStr, timestampMs, &allowed)
        }
        return rc == 0 && allowed != 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func spamProtectionNoveltyScale(
        _ spam: OpaquePointer,
        rawNovelty: Double
    ) -> Double {
        #if canImport(CAetherNativeBridge)
        var scale: Double = 0
        let rc = aether_spam_protection_novelty_scale(spam, rawNovelty, &scale)
        return rc == 0 ? scale : 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func spamProtectionFrequencyScale(
        _ spam: OpaquePointer,
        patchID: String,
        timestampMs: Int64
    ) -> Double {
        #if canImport(CAetherNativeBridge)
        var scale: Double = 0
        let rc = patchID.withCString { cStr in
            aether_spam_protection_frequency_scale(spam, cStr, timestampMs, &scale)
        }
        return rc == 0 ? scale : 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    // MARK: - Token Bucket

    static func tokenBucketCreate() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var limiter: OpaquePointer?
        let rc = aether_token_bucket_create(&limiter)
        return rc == 0 ? limiter : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func tokenBucketDestroy(_ limiter: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_token_bucket_destroy(limiter)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func tokenBucketReset(_ limiter: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_token_bucket_reset(limiter)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func tokenBucketTryConsume(
        _ limiter: OpaquePointer,
        patchID: String,
        timestampMs: Int64
    ) -> Bool {
        #if canImport(CAetherNativeBridge)
        var consumed: Int32 = 0
        let rc = patchID.withCString { cStr in
            aether_token_bucket_try_consume(limiter, cStr, timestampMs, &consumed)
        }
        return rc == 0 && consumed != 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func tokenBucketAvailableTokens(
        _ limiter: OpaquePointer,
        patchID: String,
        timestampMs: Int64
    ) -> Double {
        #if canImport(CAetherNativeBridge)
        var tokens: Double = 0
        let rc = patchID.withCString { cStr in
            aether_token_bucket_available_tokens(limiter, cStr, timestampMs, &tokens)
        }
        return rc == 0 ? tokens : 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    // MARK: - View Diversity

    static func viewDiversityCreate() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var tracker: OpaquePointer?
        let rc = aether_view_diversity_create(&tracker)
        return rc == 0 ? tracker : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func viewDiversityDestroy(_ tracker: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_view_diversity_destroy(tracker)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func viewDiversityReset(_ tracker: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_view_diversity_reset(tracker)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func viewDiversityAddObservation(
        _ tracker: OpaquePointer,
        patchID: String,
        viewAngleDeg: Double,
        timestampMs: Int64
    ) -> Double {
        #if canImport(CAetherNativeBridge)
        var diversity: Double = 0
        let rc = patchID.withCString { cStr in
            aether_view_diversity_add_observation(tracker, cStr, viewAngleDeg, timestampMs, &diversity)
        }
        return rc == 0 ? diversity : 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func viewDiversityScore(
        _ tracker: OpaquePointer,
        patchID: String
    ) -> Double {
        #if canImport(CAetherNativeBridge)
        var diversity: Double = 0
        let rc = patchID.withCString { cStr in
            aether_view_diversity_score(tracker, cStr, &diversity)
        }
        return rc == 0 ? diversity : 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    // MARK: - Admission Controller

    static func admissionControllerCreate() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var controller: OpaquePointer?
        let rc = aether_admission_controller_create(&controller)
        return rc == 0 ? controller : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func admissionControllerDestroy(_ controller: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_admission_controller_destroy(controller)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func admissionControllerReset(_ controller: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_admission_controller_reset(controller)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func admissionControllerCheck(
        _ controller: OpaquePointer,
        patchID: String,
        viewAngleDeg: Double,
        timestampMs: Int64
    ) -> aether_admission_decision_t {
        #if canImport(CAetherNativeBridge)
        var decision = aether_admission_decision_t()
        patchID.withCString { cStr in
            _ = aether_admission_controller_check(
                controller, cStr, viewAngleDeg, timestampMs, &decision)
        }
        return decision
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func admissionControllerCheckConfirmedSpam(
        _ controller: OpaquePointer,
        patchID: String,
        spamScore: Double,
        threshold: Double
    ) -> aether_admission_decision_t {
        #if canImport(CAetherNativeBridge)
        var decision = aether_admission_decision_t()
        patchID.withCString { cStr in
            _ = aether_admission_controller_check_confirmed_spam(
                controller, cStr, spamScore, threshold, &decision)
        }
        return decision
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
