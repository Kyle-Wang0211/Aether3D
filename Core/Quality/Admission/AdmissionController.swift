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
    /// **MUST:** Hash MUST be deterministic across runs, platforms, and locales
    /// Used for audit/replay validation
    public let decisionHash: String
    
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
        
        // Compute deterministic hash from canonical string representation
        let canonicalString = [
            candidateId.uuidString.lowercased(),
            classification.rawValue,
            reason?.rawValue ?? "none",
            DeterministicHash.formatDouble(eebDelta),
            buildMode.rawValue,
            guidanceSignal.rawValue,
            hardFuseTrigger?.rawValue ?? "none"
        ].joined(separator: "|")
        
        self.decisionHash = DeterministicHash.sha256Hex(canonicalString)
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
