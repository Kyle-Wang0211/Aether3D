// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// PR1 C-Class v2.3b — FROZEN SEMANTICS
// Any change here requires SSOT-Change: yes and full deterministic replay validation.
//
// AdmissionController.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Admission Controller
//
// Single policy engine for admission decisions
// Pipeline runners MUST NOT embed policy
//

import Foundation

/// Admission decision output contract (MUST)
/// 
/// **v2.3b Sealed:**
/// - MUST depend only on serializable/replayable inputs
/// - MUST NOT depend on non-deterministic runtime conditions
public struct AdmissionDecision: Codable {
    /// Candidate ID (MUST for idempotency)
    public let candidateId: UUID
    
    /// Patch classification
    public let classification: PatchClassification
    
    /// Reject reason (if rejected)
    public let reason: RejectReason?
    
    /// EEB delta (0 if not accepted, MUST >= EEB_MIN_QUANTUM if accepted)
    public let eebDelta: Double
    
    /// Build mode at decision time
    public let buildMode: BuildMode
    
    /// Guidance signal for no-text UX
    public let guidanceSignal: GuidanceSignal
    
    /// Hard fuse trigger (if SATURATED latched)
    public let hardFuseTrigger: HardFuseTrigger?
    
    /// Deterministic decision hash (computed from stable fields)
    /// 
    /// **v2.4+:** Changed to DecisionHash (32 bytes, byte-stable)
    /// **MUST:** Hash MUST be deterministic across runs, platforms, and locales
    /// Used for audit/replay validation
    public let decisionHash: DecisionHash
    
    /// Decision hash bytes (32 bytes, internal)
    public var decisionHashBytes: Data {
        return Data(decisionHash.bytes)
    }
    
    /// Decision hash hex string (64 lowercase hex chars, no prefix)
    /// 
    /// **P0 Contract:**
    /// - Exactly 64 characters
    /// - Lowercase hex only
    /// - No "0x" prefix
    /// - Stable formatting for logging/audit
    public var decisionHashHexLower: String {
        return decisionHash.hexString
    }
    
    /// Legacy decision hash string (for backward compatibility)
    @available(*, deprecated, message: "Use decisionHashHexLower instead")
    public var decisionHashString: String {
        return decisionHashHexLower
    }
    
    /// Generate canonical admission record bytes (AdmissionDecisionBytesLayout_v1)
    /// 
    /// **P0 Contract:**
    /// - Uses CanonicalBytesWriter for deterministic encoding
    /// - Follows AdmissionDecisionBytesLayout_v1 table order
    /// - Cross-platform deterministic (macOS + Linux produce identical bytes)
    /// - Used for audit/fixture comparison (not just JSON fields)
    /// 
    /// **Fail-closed:** Throws FailClosedError on encoding failure
    public func admissionRecordBytes(
        schemaVersion: UInt16,
        policyHash: UInt64,
        sessionStableId: UInt64,
        candidateStableId: UInt64,
        degradationLevel: UInt8,
        degradationReasonCode: DegradationReasonCode?,
        valueScore: Int64
    ) throws -> Data {
        let writer = CanonicalBytesWriter()
        
        // Layout version (fixed as 1 for v1)
        writer.writeUInt8(1) // layoutVersion = 1
        
        // Schema version
        writer.writeUInt16BE(schemaVersion)
        
        // Policy hash
        writer.writeUInt64BE(policyHash)
        
        // Stable IDs
        writer.writeUInt64BE(sessionStableId)
        writer.writeUInt64BE(candidateStableId)
        
        // Decision hash algorithm ID (BLAKE3_256 = 1)
        writer.writeUInt8(1) // decisionHashAlgoId = BLAKE3_256
        
        // Decision hash (32 bytes)
        writer.writeBytes(Array(decisionHash.bytes))
        
        // Classification (map from PatchClassification)
        let classificationUInt8: UInt8 = {
            switch classification {
            case .REJECTED, .DUPLICATE_REJECTED:
                return reason == .HARD_CAP ? 0 : 1 // REJECTED_HARD_CAP : REJECTED_SOFT
            case .ACCEPTED:
                return 2 // ACCEPTED
            case .DISPLAY_ONLY:
                return 2 // Treat as ACCEPTED for classification purposes
            }
        }()
        writer.writeUInt8(classificationUInt8)
        
        // Reject reason (optional, presenceTag encoding)
        if let reasonValue = reason {
            writer.writeUInt8(1) // present
            writer.writeUInt8(reasonValue.rawValueUInt8)
        } else {
            writer.writeUInt8(0) // absent (no payload bytes)
        }
        
        // Shed decision (optional, presenceTag encoding)
        // For now, always absent (not implemented yet)
        writer.writeUInt8(0) // absent (no payload bytes)
        
        // Shed reason (optional, presenceTag encoding)
        // For now, always absent (not implemented yet)
        writer.writeUInt8(0) // absent (no payload bytes)
        
        // Degradation level
        writer.writeUInt8(degradationLevel)
        
        // Degradation reason code (optional, presenceTag encoding)
        if let reasonCode = degradationReasonCode {
            writer.writeUInt8(1) // present
            writer.writeUInt8(reasonCode.rawValue)
        } else {
            writer.writeUInt8(0) // absent (no payload bytes)
        }
        
        // Value score
        writer.writeInt64BE(valueScore)
        
        // Reserved padding (4 bytes, must be zeros)
        writer.writeZeroBytes(count: 4)
        
        return writer.toData()
    }
    
    public init(
        candidateId: UUID,
        classification: PatchClassification,
        reason: RejectReason?,
        eebDelta: Double,
        buildMode: BuildMode,
        guidanceSignal: GuidanceSignal,
        hardFuseTrigger: HardFuseTrigger?
    ) {
        self.candidateId = candidateId
        self.classification = classification
        self.reason = reason
        self.eebDelta = eebDelta
        self.buildMode = buildMode
        self.guidanceSignal = guidanceSignal
        self.hardFuseTrigger = hardFuseTrigger
        
        // Compute decision hash from CapacityMetrics canonical bytes (v2.4+)
        // TODO: Get actual values from CapacityMetrics when available
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: 0, // TODO: Get from tracker
            eebRemaining: 0, // TODO: Get from tracker
            eebDelta: eebDelta,
            buildMode: buildMode,
            rejectReason: reason,
            hardFuseTrigger: hardFuseTrigger,
            rejectReasonDistribution: [:],
            capacityInvariantViolation: false,
            capacitySaturatedLatchedAtPatchCount: nil,
            capacitySaturatedLatchedAtTimestamp: nil,
            flushFailure: false,
            decisionHash: nil
        )
        
        // Compute decision hash (v2.4+)
        // TODO: Pass actual policyHash, stable IDs, valueScore, etc. when available
        // For now, compute candidateStableId from candidateId to ensure different candidates produce different hashes
        do {
            // Default flowBucketCount and perFlowCounters for v2.4+
            let defaultFlowBucketCount = 4
            let defaultPerFlowCounters = Array(repeating: UInt16(0), count: defaultFlowBucketCount)
            
            // Compute candidateStableId from candidateId (temporary: should use CandidateStableIdOpaqueBytesLayout_v1)
            let candidateIdBytes = try UUIDRFC4122.uuidRFC4122Bytes(candidateId)
            let candidateStableId = try Blake3Facade.blake3_64(data: Data(candidateIdBytes))
            
            // Compute sessionStableId (temporary: should use session UUID + policyHash)
            // For now, use a hash of candidateId to ensure uniqueness
            let sessionStableId = try Blake3Facade.blake3_64(data: Data(candidateIdBytes + [0x00]))
            
            self.decisionHash = try metrics.computeDecisionHashV1(
                policyHash: 0, // TODO: Get from CapacityTier
                sessionStableId: sessionStableId,
                candidateStableId: candidateStableId,
                valueScore: 0, // TODO: Compute ValueScore
                perFlowCounters: defaultPerFlowCounters, // Default for now
                flowBucketCount: defaultFlowBucketCount,
                throttleStats: nil, // TODO: Get from limiter
                degradationLevel: 0, // TODO: Map from BuildMode
                degradationReasonCode: nil, // TODO: Get from degradation controller
                schemaVersion: 0x0204
            )
        } catch {
            // Fail-closed for v2.4+: decisionHash computation must succeed
            // In v2.4+, this should never happen - fail closed
            fatalError("Failed to compute decisionHash (v2.4+): \(error)")
        }
    }
    
    // MARK: - Codable
    
    enum CodingKeys: String, CodingKey {
        case candidateId
        case classification
        case reason
        case eebDelta
        case buildMode
        case guidanceSignal
        case hardFuseTrigger
        case decisionHash
        case decisionHashString // Legacy support
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidateId = try container.decode(UUID.self, forKey: .candidateId)
        classification = try container.decode(PatchClassification.self, forKey: .classification)
        reason = try container.decodeIfPresent(RejectReason.self, forKey: .reason)
        eebDelta = try container.decode(Double.self, forKey: .eebDelta)
        buildMode = try container.decode(BuildMode.self, forKey: .buildMode)
        guidanceSignal = try container.decode(GuidanceSignal.self, forKey: .guidanceSignal)
        hardFuseTrigger = try container.decodeIfPresent(HardFuseTrigger.self, forKey: .hardFuseTrigger)
        
        // Try to decode DecisionHash (v2.4+), fallback to legacy string
        if let decisionHashValue = try? container.decode(DecisionHash.self, forKey: .decisionHash) {
            decisionHash = decisionHashValue
        } else if let legacyHashString = try? container.decode(String.self, forKey: .decisionHashString) {
            // Convert legacy hex string to DecisionHash
            decisionHash = try DecisionHash(hexString: legacyHashString)
        } else {
            // Compute from other fields (backward compatibility)
            let metrics = CapacityMetrics(
                candidateId: candidateId,
                patchCountShadow: 0,
                eebRemaining: 0,
                eebDelta: eebDelta,
                buildMode: buildMode,
                rejectReason: reason,
                hardFuseTrigger: hardFuseTrigger,
                rejectReasonDistribution: [:],
                capacityInvariantViolation: false,
                capacitySaturatedLatchedAtPatchCount: nil,
                capacitySaturatedLatchedAtTimestamp: nil,
                flushFailure: false,
                decisionHash: nil
            )
            decisionHash = try metrics.computeDecisionHashV1()
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidateId, forKey: .candidateId)
        try container.encode(classification, forKey: .classification)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(eebDelta, forKey: .eebDelta)
        try container.encode(buildMode, forKey: .buildMode)
        try container.encode(guidanceSignal, forKey: .guidanceSignal)
        try container.encodeIfPresent(hardFuseTrigger, forKey: .hardFuseTrigger)
        try container.encode(decisionHash, forKey: .decisionHash)
        // Also encode legacy string for backward compatibility
        try container.encode(decisionHash.hexString, forKey: .decisionHashString)
    }
}

/// Admission controller (single policy engine)
/// 
/// **v2.3b Sealed:**
/// - Single authority: MUST be the only policy engine
/// - Pipeline executors MUST NOT embed policy
/// - Replayability input boundary: MUST depend only on serializable/replayable inputs
public struct AdmissionController {
    private let infoGainCalculator: InformationGainCalculator
    
    public init(infoGainCalculator: InformationGainCalculator = PlaceholderInformationGainCalculator()) {
        self.infoGainCalculator = infoGainCalculator
    }
    
    /// Evaluate admission decision
    /// 
    /// **Replayability input boundary (MUST):**
    /// AdmissionDecision MUST depend only on:
    /// - serializable PatchCandidate fields
    /// - replayable evidence summaries (CoverageGrid hash, accepted_count, eeb_remaining)
    /// - normative constants
    /// MUST NOT depend on non-deterministic runtime conditions (fps, scheduling, thermal)
    public func evaluateAdmission(
        candidate: PatchCandidate,
        isDuplicate: Bool,
        existingCoverage: CoverageGrid,
        existingPatches: [PatchCandidate],
        tracker: PatchTracker
    ) async -> AdmissionDecision {
        // Get current state from tracker (via await actor methods)
        let currentMode = await tracker.getCurrentBuildMode()
        let shouldTriggerSoft = await tracker.shouldTriggerSoftLimit()
        let hardTrigger = await tracker.shouldTriggerHardLimit()
        
        // Decision logic (priority order, MUST):
        
        // 1. Duplicate priority check (MUST before SOFT/HARD checks)
        if isDuplicate {
            return AdmissionDecision(
                candidateId: candidate.candidateId,
                classification: .DUPLICATE_REJECTED,
                reason: .DUPLICATE,
                eebDelta: 0.0,
                buildMode: currentMode,
                guidanceSignal: .NONE,
                hardFuseTrigger: nil
            )
        }
        
        // 2. HARD_LIMIT fuse check (via await access to tracker state)
        if let trigger = hardTrigger {
            return AdmissionDecision(
                candidateId: candidate.candidateId,
                classification: .REJECTED,
                reason: .HARD_CAP,
                eebDelta: 0.0,
                buildMode: .SATURATED,
                guidanceSignal: .STATIC_OVERLAY,
                hardFuseTrigger: trigger
            )
        }
        
        // 3. SOFT_LIMIT damping check (via await access to tracker state)
        if shouldTriggerSoft {
            // Compute information gain and novelty
            let infoGain = infoGainCalculator.computeInfoGain(
                patch: candidate,
                existingCoverage: existingCoverage
            )
            let novelty = infoGainCalculator.computeNovelty(
                patch: candidate,
                existingPatches: existingPatches
            )
            
            // Damping admission rule
            if infoGain < CapacityLimitConstants.IG_MIN_SOFT || novelty < CapacityLimitConstants.NOVELTY_MIN_SOFT {
                let reason: RejectReason = infoGain < CapacityLimitConstants.IG_MIN_SOFT ? .LOW_GAIN_SOFT : .REDUNDANT_COVERAGE
                return AdmissionDecision(
                    candidateId: candidate.candidateId,
                    classification: .REJECTED,
                    reason: reason,
                    eebDelta: 0.0,
                    buildMode: .DAMPING,
                    guidanceSignal: .HEAT_COOL_COVERAGE,
                    hardFuseTrigger: nil
                )
            }
            // Otherwise: MAY accept (continue to normal mode logic)
        }
        
        // 4. Normal mode: standard admission logic
        // Placeholder: accepts with minimum EEB quantum
        // Future: Replace with actual admission logic based on information gain
        // Note: This is a placeholder implementation; interface constraints (bounds [0,1], monotonic) remain
        return AdmissionDecision(
            candidateId: candidate.candidateId,
            classification: .ACCEPTED,
            reason: nil,
            eebDelta: CapacityLimitConstants.EEB_MIN_QUANTUM,
            buildMode: currentMode,
            guidanceSignal: currentMode == .DAMPING ? .DIRECTIONAL_AFFORDANCE : .NONE,
            hardFuseTrigger: nil
        )
    }
}
