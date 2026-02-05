//
// CapacityMetrics.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Capacity Metrics
//
// Structured capacity metrics (SSOT), not string summaries
//

import Foundation

// MARK: - DecisionHash Support (PR1 v2.4 Addendum EXT+)

/// Structured capacity metrics (SSOT)
/// 
/// **v2.3b Sealed:**
/// - MUST use structured fields, not string summaries
/// - MUST NOT imply "computed from maxPatches"
/// - MUST record capacity_invariant_violation if EEB invariants violated
public struct CapacityMetrics: Codable, Sendable, Equatable {
    /// Candidate ID (MUST for audit traceability)
    public let candidateId: UUID
    
    /// Patch count shadow
    public let patchCountShadow: Int
    
    /// EEB remaining
    public let eebRemaining: Double
    
    /// EEB delta (consumed for this decision)
    public let eebDelta: Double
    
    /// Build mode at decision time
    public let buildMode: BuildMode
    
    /// Reject reason (if rejected)
    public let rejectReason: RejectReason?
    
    /// Hard fuse trigger (if SATURATED latched)
    public let hardFuseTrigger: HardFuseTrigger?
    
    /// Reject reason distribution snapshot (at transitions or periodic)
    public let rejectReasonDistribution: [String: Int]
    
    /// Capacity invariant violation flag
    /// MUST record if EEB invariants violated
    public let capacityInvariantViolation: Bool
    
    /// SATURATED latch metadata (if SATURATED latched)
    public let capacitySaturatedLatchedAtPatchCount: Int?
    public let capacitySaturatedLatchedAtTimestamp: Date?
    
    /// Flush failure flag (if async persistence failed)
    public let flushFailure: Bool
    
    /// Decision hash (deterministic hash of AdmissionDecision)
    /// Used for audit/replay validation
    /// 
    /// **v2.4+:** Changed from String? to DecisionHash? (32 bytes, byte-stable)
    public let decisionHash: DecisionHash?
    
    /// Legacy decision hash string (for backward compatibility)
    /// Used for JSON encoding/decoding only
    @available(*, deprecated, message: "Use decisionHash instead")
    public var decisionHashString: String? {
        return decisionHash?.hexString
    }
    
    public init(
        candidateId: UUID,
        patchCountShadow: Int,
        eebRemaining: Double,
        eebDelta: Double,
        buildMode: BuildMode,
        rejectReason: RejectReason?,
        hardFuseTrigger: HardFuseTrigger?,
        rejectReasonDistribution: [String: Int],
        capacityInvariantViolation: Bool,
        capacitySaturatedLatchedAtPatchCount: Int?,
        capacitySaturatedLatchedAtTimestamp: Date?,
        flushFailure: Bool = false,
        decisionHash: DecisionHash? = nil
    ) {
        self.candidateId = candidateId
        self.patchCountShadow = patchCountShadow
        self.eebRemaining = eebRemaining
        self.eebDelta = eebDelta
        self.buildMode = buildMode
        self.rejectReason = rejectReason
        self.hardFuseTrigger = hardFuseTrigger
        self.rejectReasonDistribution = rejectReasonDistribution
        self.capacityInvariantViolation = capacityInvariantViolation
        self.capacitySaturatedLatchedAtPatchCount = capacitySaturatedLatchedAtPatchCount
        self.capacitySaturatedLatchedAtTimestamp = capacitySaturatedLatchedAtTimestamp
        self.flushFailure = flushFailure
        self.decisionHash = decisionHash
    }
    
    // MARK: - DecisionHash Computation (PR1 v2.4 Addendum EXT+)
    
    /// Generate canonical bytes for decision hash input
    /// 
    /// **Layout:** DecisionHashInputBytesLayout_v1
    /// **Rules:**
    /// - Fixed-order, fixed-width, big-endian integers
    /// - Optional fields use presenceTag encoding (UInt8 0/1)
    /// - Arrays are fixed-size, no length prefix
    /// - Fail-closed for v2.4+ if mandatory fields missing or array size mismatch
    /// 
    /// **TODO (P0):** Add missing fields when CapacityTier and stable IDs are implemented:
    /// - policyHash: UInt64BE (from CapacityTier)
    /// - sessionStableId: UInt64BE (blake3_64 of session UUID + policyHash)
    /// - candidateStableId: UInt64BE (blake3_64 of candidate opaque bytes)
    /// - valueScore: Int64BE (BudgetUnit)
    /// - perFlowCounters: [UInt16] (flowBucketCount × 2)
    /// - throttleStats: optional (windowStartTick, windowDurationTicks, attemptsInWindow)
    /// - degradationReasonCode: optional UInt8
    public func canonicalBytesForDecisionHashInput(
        policyHash: UInt64 = 0, // TODO: Get from CapacityTier
        sessionStableId: UInt64 = 0, // TODO: Compute from session UUID + policyHash
        candidateStableId: UInt64 = 0, // TODO: Compute from candidate opaque bytes
        valueScore: Int64 = 0, // TODO: Compute ValueScore
        perFlowCounters inputPerFlowCounters: [UInt16]? = nil, // nil = auto-generate zeros
        flowBucketCount: Int = 4, // TODO: Get from CapacityTier
        throttleStats: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32)? = nil,
        degradationLevel: UInt8 = 0, // TODO: Map from BuildMode
        degradationReasonCode: UInt8? = nil,
        schemaVersion: UInt16 = 0x0204
    ) throws -> Data {
        // Auto-generate perFlowCounters if nil or empty (default zeros)
        let perFlowCounters: [UInt16]
        if let input = inputPerFlowCounters, !input.isEmpty {
            perFlowCounters = input
        } else {
            perFlowCounters = Array(repeating: 0, count: flowBucketCount)
        }
        let writer = CanonicalBytesWriter()
        
        // Layout version (must be 1 for v1)
        writer.writeUInt8(1) // layoutVersion = 1
        
        // Decision schema version (hash-input schema discriminator)
        // Fixed value 0x0001 for v1
        // This is NOT the global schemaVersion; it is the hash input schema discriminator
        writer.writeUInt16BE(0x0001) // decisionSchemaVersion = 0x0001
        
        // Enforce: layoutVersion==1 AND decisionSchemaVersion==0x0001 (v2.4+)
        if schemaVersion >= 0x0204 {
            // Validation is implicit: we hardcode the values above
            // If we need to support multiple versions in future, add validation here
        }
        
        // Policy hash (mandatory)
        writer.writeUInt64BE(policyHash)
        
        // Stable IDs (mandatory)
        writer.writeUInt64BE(sessionStableId)
        writer.writeUInt64BE(candidateStableId)
        
        // Classification (map from buildMode and rejectReason)
        let classification: UInt8 = {
            if rejectReason == .HARD_CAP {
                return 0 // REJECTED_HARD_CAP
            } else if rejectReason != nil {
                return 1 // REJECTED_SOFT
            } else {
                return 2 // ACCEPTED
            }
        }()
        writer.writeUInt8(classification)
        
        // Reject reason (optional, presenceTag encoding)
        // Rule: if tag==0, do NOT write payload bytes
        if let reason = rejectReason {
            writer.writeUInt8(1) // present
            writer.writeUInt8(reason.rawValueUInt8) // payload only if present
        } else {
            writer.writeUInt8(0) // absent (no payload bytes)
        }
        
        // Shed decision (optional, presenceTag encoding)
        // For now, always absent (not implemented yet)
        // Rule: if tag==0, do NOT write payload bytes
        writer.writeUInt8(0) // absent (no payload bytes)
        
        // Shed reason (optional, presenceTag encoding)
        // For now, always absent (not implemented yet)
        // Rule: if tag==0, do NOT write payload bytes
        writer.writeUInt8(0) // absent (no payload bytes)
        
        // Degradation level
        writer.writeUInt8(degradationLevel)
        
        // Degradation reason code (optional, presenceTag encoding)
        // Rule: if tag==0, do NOT write payload bytes
        if let reasonCode = degradationReasonCode {
            writer.writeUInt8(1) // present
            writer.writeUInt8(reasonCode) // payload only if present
        } else {
            writer.writeUInt8(0) // absent (no payload bytes)
        }
        
        // Value score (mandatory)
        writer.writeInt64BE(valueScore)
        
        // Flow bucket count (mandatory, self-describing, encoded before perFlowCounters)
        writer.writeUInt8(UInt8(flowBucketCount))
        
        // Per-flow counters (mandatory, fixed-size array)
        try writer.writeFixedArrayUInt16BE(array: perFlowCounters, expectedCount: flowBucketCount)
        
        // Throttle stats (optional, presenceTag encoding)
        if let stats = throttleStats {
            writer.writeUInt8(1) // present
            writer.writeUInt64BE(stats.windowStartTick)
            writer.writeUInt32BE(stats.windowDurationTicks)
            writer.writeUInt32BE(stats.attemptsInWindow)
        } else {
            writer.writeUInt8(0) // absent
        }
        
        let data = writer.toData()
        
        // Validate length (v2.4+)
        if schemaVersion >= 0x0204 {
            let expectedLength = try CanonicalLayoutLengthValidator.expectedLengthForDecisionHashInput(
                flowBucketCount: UInt8(flowBucketCount),
                hasThrottleStats: throttleStats != nil,
                hasRejectReason: rejectReason != nil,
                hasDegradationReasonCode: degradationReasonCode != nil
            )
            guard data.count == expectedLength else {
                // Debug: log actual vs expected for troubleshooting
                #if DEBUG
                print("DEBUG: DecisionHashInputBytesLayout_v1 length mismatch: actual=\(data.count), expected=\(expectedLength)")
                #endif
                throw FailClosedError.internalContractViolation(
                    code: FailClosedErrorCode.canonicalLengthMismatch.rawValue,
                    context: "DecisionHashInputBytesLayout_v1 length mismatch"
                )
            }
        }
        
        return data
    }
    
    /// Compute decision hash v1 from canonical input bytes
    /// 
    /// **Algorithm:**
    /// 1. Generate canonical bytes using canonicalBytesForDecisionHashInput()
    /// 2. Compute hash: DecisionHashV1.compute(from: canonicalBytes)
    /// 
    /// **Fail-closed (v2.4+):** Throws if mandatory fields missing or array size mismatch
    public func computeDecisionHashV1(
        policyHash: UInt64 = 0,
        sessionStableId: UInt64 = 0,
        candidateStableId: UInt64 = 0,
        valueScore: Int64 = 0,
        perFlowCounters: [UInt16]? = nil,
        flowBucketCount: Int = 4,
        throttleStats: (windowStartTick: UInt64, windowDurationTicks: UInt32, attemptsInWindow: UInt32)? = nil,
        degradationLevel: UInt8 = 0,
        degradationReasonCode: UInt8? = nil,
        schemaVersion: UInt16 = 0x0204
    ) throws -> DecisionHash {
        let canonicalBytes = try canonicalBytesForDecisionHashInput(
            policyHash: policyHash,
            sessionStableId: sessionStableId,
            candidateStableId: candidateStableId,
            valueScore: valueScore,
            perFlowCounters: perFlowCounters,
            flowBucketCount: flowBucketCount,
            throttleStats: throttleStats,
            degradationLevel: degradationLevel,
            degradationReasonCode: degradationReasonCode,
            schemaVersion: schemaVersion
        )
        return try DecisionHashV1.compute(from: canonicalBytes)
    }
    
    /// Validate for encoding (v2.4+ enforcement)
    /// 
    /// **Fail-closed (v2.4+):**
    /// - decisionHash != nil AND decisionHash.bytes.count == 32
    /// - policyHash != 0
    /// - Mandatory fields present
    /// - Array sizes match expected
    public func validateForEncoding(schemaVersion: UInt16) throws {
        let v24: UInt16 = 0x0204
        if schemaVersion >= v24 {
            guard let dh = decisionHash, dh.bytes.count == 32 else {
                throw CapacityMetricsError.missingDecisionHash
            }
            // Additional validations can be added here
        }
    }
}

/// CapacityMetrics errors
public enum CapacityMetricsError: Error {
    case missingDecisionHash
    case missingMandatoryField(fieldName: String)
    case arraySizeMismatch(fieldName: String, expected: Int, actual: Int)
}

/// Extension to RejectReason for UInt8 raw value
extension RejectReason {
    /// Raw UInt8 value for canonical encoding
    /// 
    /// **Closed-world enum:** Values must match SSOT specification
    var rawValueUInt8: UInt8 {
        switch self {
        case .LOW_GAIN_SOFT: return 1
        case .REDUNDANT_COVERAGE: return 2
        case .DUPLICATE: return 3
        case .HARD_CAP: return 4
        case .POLICY_REJECT: return 5
        }
    }
}
