// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CanonicalLayoutLengthValidator.swift
// Aether3D
//
// PR1 v2.4 Addendum - Canonical Layout Length Validator
//
// Validates exact byte length for canonical layouts (fail-closed on mismatch)
//

import Foundation

/// Canonical layout length validator
/// 
/// **P0 Contract:**
/// - Computes expected byte length for each canonical layout
/// - Validates actual length matches expected (fail-closed on mismatch)
/// - Used by all canonicalBytesForX() methods
public enum CanonicalLayoutLengthValidator {
    /// Expected length for PolicyHashCanonicalBytesLayout_v1
    /// 
    /// **Formula:** sum(fixed fields) + flowBucketCount * 2
    public static func expectedLengthForPolicyHash(flowBucketCount: UInt8) -> Int {
        // Fixed fields:
        // tierId: UInt16 = 2
        // schemaVersion: UInt16 = 2
        // profileId: UInt8 = 1
        // policyEpoch: UInt32 = 4
        // policyFlags: UInt32 = 4
        // softLimitPatchCount: Int32 = 4
        // hardLimitPatchCount: Int32 = 4
        // eebBaseBudget: Int64 = 8
        // softBudgetThreshold: Int64 = 8
        // hardBudgetThreshold: Int64 = 8
        // budgetEpsilon: Int64 = 8
        // maxSessionExtensions: UInt8 = 1
        // extensionBudgetRatio: Int64 = 8
        // cooldownNs: UInt64 = 8
        // throttleWindowNs: UInt64 = 8
        // throttleMaxAttempts: UInt8 = 1
        // throttleBurstTokens: UInt8 = 1
        // throttleRefillRateNs: UInt64 = 8
        // retryStormFuseThreshold: UInt32 = 4
        // costWindowK: UInt8 = 1
        // minValueScore: Int64 = 8
        // shedRateAtSaturated: Int64 = 8
        // shedRateAtTerminal: Int64 = 8
        // deterministicSelectionSalt: UInt64 = 8
        // hashAlgoId: UInt8 = 1
        // eligibilityWindowK: UInt8 = 1
        // minGainThreshold: Int64 = 8
        // minDiversity: Int64 = 8
        // rejectDominanceMaxShare: Int64 = 8
        // flowBucketCount: UInt8 = 1
        // flowWeights: [UInt16] = flowBucketCount * 2
        // maxPerFlowExtensionsPerFlow: UInt16 = 2
        // limiterTickNs: UInt64 = 8
        // valueScoreWeightA: Int64 = 8
        // valueScoreWeightB: Int64 = 8
        // valueScoreWeightC: Int64 = 8
        // valueScoreWeightD: Int64 = 8
        // valueScoreMax: Int64 = 8
        
        let fixedFieldsLength = 2 + 2 + 1 + 4 + 4 + 4 + 4 + 8 + 8 + 8 + 8 + 1 + 8 + 8 + 8 + 1 + 1 + 8 + 4 + 1 + 8 + 8 + 8 + 8 + 8 + 1 + 1 + 8 + 8 + 8 + 1 + 2 + 8 + 8 + 8 + 8 + 8 + 8
        let flowWeightsLength = Int(flowBucketCount) * 2
        return fixedFieldsLength + flowWeightsLength
    }
    
    /// Expected length for CandidateStableIdOpaqueBytesLayout_v1
    /// 
    /// **Formula:** layoutVersion(1) + sessionStableIdSourceUuid(16) + candidateId(16) + policyHash(8) + candidateKind(1) + reserved(3)
    public static func expectedLengthForCandidateStableId() -> Int {
        return 1 + 16 + 16 + 8 + 1 + 3 // = 45
    }
    
    /// Expected length for ExtensionRequestIdempotencySnapshotBytesLayout_v1
    /// 
    /// **Formula:** layoutVersion(1) + extensionRequestId(16) + trigger(1) + tierId(2) + schemaVersion(2) + policyHash(8) + extensionCount(1) + resultTag(1) + denialReasonTag(1) + denialReason(0 or 1) + eebCeiling(8) + eebAdded(8) + newEebRemaining(8) + reserved(4)
    public static func expectedLengthForExtensionSnapshot(hasDenialReason: Bool) -> Int {
        let baseLength = 1 + 16 + 1 + 2 + 2 + 8 + 1 + 1 + 1 + 8 + 8 + 8 + 4 // = 61
        let denialReasonLength = hasDenialReason ? 1 : 0
        return baseLength + denialReasonLength
    }
    
    /// Expected length for DecisionHashInputBytesLayout_v1
    /// 
    /// **Formula:** base + flowBucketCount*2 + (throttleStatsTag ? 16 : 0) + presenceTags payloads
    public static func expectedLengthForDecisionHashInput(
        flowBucketCount: UInt8,
        hasThrottleStats: Bool,
        hasRejectReason: Bool,
        hasDegradationReasonCode: Bool
    ) throws -> Int {
        // Base fields:
        // layoutVersion: UInt8 = 1
        // decisionSchemaVersion: UInt16 = 2
        // policyHash: UInt64 = 8
        // sessionStableId: UInt64 = 8
        // candidateStableId: UInt64 = 8
        // classification: UInt8 = 1
        // rejectReasonTag: UInt8 = 1
        // rejectReason: UInt8 = 0 or 1
        // shedDecisionTag: UInt8 = 1
        // shedDecision: UInt8 = 0 or 1
        // shedReasonTag: UInt8 = 1
        // shedReason: UInt8 = 0 or 1
        // degradationLevel: UInt8 = 1
        // degradationReasonCodeTag: UInt8 = 1
        // degradationReasonCode: UInt8 = 0 or 1
        // valueScore: Int64 = 8
        // flowBucketCount: UInt8 = 1
        // perFlowCounters: [UInt16] = flowBucketCount * 2
        // throttleStatsTag: UInt8 = 1
        
        // Base fields (fixed-size, always present):
        // layoutVersion(1) + decisionSchemaVersion(2) + policyHash(8) + sessionStableId(8) + candidateStableId(8) +
        // classification(1) + rejectReasonTag(1) + shedDecisionTag(1) + shedReasonTag(1) +
        // degradationLevel(1) + degradationReasonCodeTag(1) + valueScore(8) + flowBucketCount(1) + throttleStatsTag(1) = 48
        // Note: shedDecision and shedReason do NOT write payload bytes when absent (presenceTag rule)
        // Plus variable-length parts:
        // rejectReason payload(0 or 1) + degradationReasonCode payload(0 or 1) + perFlowCounters(flowBucketCount*2) + throttleStats payload(0 or 16)
        let baseLength = 1 + 2 + 8 + 8 + 8 + 1 + 1 + 1 + 1 + 1 + 1 + 8 + 1 + 1 // = 48 (fixed fields including flowBucketCount, no payload bytes for absent optionals)
        let rejectReasonLength = hasRejectReason ? 1 : 0 // rejectReason payload (after tag)
        let degradationReasonCodeLength = hasDegradationReasonCode ? 1 : 0 // degradationReasonCode payload (after tag)
        let perFlowCountersLength = Int(flowBucketCount) * 2
        let throttleStatsLength = hasThrottleStats ? (8 + 4 + 4) : 0 // windowStartTick(8) + windowDurationTicks(4) + attemptsInWindow(4)
        
        return baseLength + rejectReasonLength + degradationReasonCodeLength + perFlowCountersLength + throttleStatsLength
    }
    
    /// Assert exact length match (fail-closed on mismatch)
    /// 
    /// **Fail-closed (v2.4+):** Throws if actual != expected
    public static func assertExactLength(
        actual: Int,
        expected: Int,
        layoutName: StaticString
    ) throws {
        guard actual == expected else {
            // Use layoutName as context (StaticString cannot be interpolated)
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.canonicalLengthMismatch.rawValue,
                context: layoutName
            )
        }
    }
}
