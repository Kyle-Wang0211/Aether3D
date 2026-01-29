//
// CapacityMetrics.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Capacity Metrics
//
// Structured capacity metrics (SSOT), not string summaries
//

import Foundation

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
    public let decisionHash: String?
    
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
        decisionHash: String? = nil
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
}
