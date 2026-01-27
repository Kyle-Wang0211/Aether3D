// PR1 C-Class v2.3b — FROZEN SEMANTICS
// Any change here requires SSOT-Change: yes and full deterministic replay validation.
//
// PatchTracker.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Patch Tracker Actor
//
// Single-writer authority for PatchCountShadow, EEB_remaining, build_mode latches, idempotency registry
// MUST be implemented as Swift actor (mandatory, not "actor or lock")
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Capacity invariant violation type
public enum CapacityInvariantViolation: Error {
    case eebNaN
    case eebInf
    case eebNegative
    case eebExceedsBaseBudget
}

/// Accepted evidence record (in-memory)
public struct AcceptedEvidence: Codable {
    public let candidateId: UUID
    public let timestamp: Date
    public let eebDelta: Double
    
    public init(candidateId: UUID, timestamp: Date, eebDelta: Double) {
        self.candidateId = candidateId
        self.timestamp = timestamp
        self.eebDelta = eebDelta
    }
}

/// Commit result with capacity metrics
public enum CommitResult: Codable {
    case committed(CapacityMetrics)
    case alreadyCommitted(UUID)
}

/// PatchTracker MUST be implemented as Swift actor (mandatory)
/// Single-writer authority for PatchCountShadow, EEB_remaining, build_mode latches, idempotency registry
/// 
/// **v2.3b Sealed:**
/// - EEB initialization occurs ONLY in init() (single entrypoint)
/// - Atomic evidence commit occurs in single actor turn
/// - Idempotency registry is session-scoped (no mid-session eviction)
public actor PatchTracker {
    // MARK: - State
    
    /// Patch count shadow (counts only ACCEPTED patches committed to evidential set)
    private var patchCountShadow: Int = 0
    
    /// EEB remaining (monotonically decreasing, initialized from EEB_BASE_BUDGET)
    private var eebRemaining: Double
    
    /// Build mode (NORMAL/DAMPING/SATURATED)
    private var buildMode: BuildMode = .NORMAL
    
    /// SATURATED latch (once entered, cannot exit)
    private var saturatedLatched: Bool = false
    
    /// Idempotency registry (session-scoped, no mid-session eviction)
    private var committedCandidateIds: Set<UUID> = []
    
    /// In-memory evidential set (append-only)
    private var evidenceSet: [AcceptedEvidence] = []
    
    /// SATURATED latch metadata
    private var saturatedLatchedAtPatchCount: Int?
    private var saturatedLatchedAtTimestamp: Date?
    private var saturatedLatchedTrigger: HardFuseTrigger?
    
    /// Reject reason distribution (snapshot for audit)
    private var rejectReasonDistribution: [RejectReason: Int] = [:]
    
    // MARK: - Initialization
    
    /// Single EEB initialization entrypoint (MUST)
    /// EEB initialized ONLY here, reading from CapacityLimitConstants.EEB_BASE_BUDGET
    public init() {
        // Single entrypoint: EEB initialized ONLY here
        self.eebRemaining = CapacityLimitConstants.EEB_BASE_BUDGET
    }
    
    // MARK: - State Queries
    
    /// Get current patch count shadow
    public func getPatchCountShadow() -> Int {
        return patchCountShadow
    }
    
    /// Get current EEB remaining
    public func getEEBRemaining() -> Double {
        return eebRemaining
    }
    
    /// Get current build mode
    public func getCurrentBuildMode() -> BuildMode {
        return buildMode
    }
    
    /// Check if SATURATED is latched
    public func isSaturatedLatched() -> Bool {
        return saturatedLatched
    }
    
    /// Get SATURATED latch metadata
    public func getSaturatedLatchMetadata() -> (patchCount: Int?, timestamp: Date?, trigger: HardFuseTrigger?) {
        return (saturatedLatchedAtPatchCount, saturatedLatchedAtTimestamp, saturatedLatchedTrigger)
    }
    
    // MARK: - Limit Checks
    
    /// Check if SOFT limit should trigger
    public func shouldTriggerSoftLimit() -> Bool {
        return patchCountShadow >= CapacityLimitConstants.SOFT_LIMIT_PATCH_COUNT ||
               eebRemaining <= CapacityLimitConstants.SOFT_BUDGET_THRESHOLD
    }
    
    /// Check if HARD limit should trigger
    public func shouldTriggerHardLimit() -> HardFuseTrigger? {
        if patchCountShadow >= CapacityLimitConstants.HARD_LIMIT_PATCH_COUNT {
            return .PATCHCOUNT_HARD
        }
        if eebRemaining <= CapacityLimitConstants.HARD_BUDGET_THRESHOLD {
            return .EEB_HARD
        }
        return nil
    }
    
    // MARK: - EEB Validation
    
    /// Validate EEB invariants
    public func validateEEBInvariants() -> (isValid: Bool, violation: CapacityInvariantViolation?) {
        if eebRemaining.isNaN {
            return (false, .eebNaN)
        }
        if eebRemaining.isInfinite {
            return (false, .eebInf)
        }
        if eebRemaining < 0 {
            return (false, .eebNegative)
        }
        if eebRemaining > CapacityLimitConstants.EEB_BASE_BUDGET {
            return (false, .eebExceedsBaseBudget)
        }
        return (true, nil)
    }
    
    // MARK: - Atomic Evidence Commit
    
    /// Atomic evidence commit (MUST occur in single actor turn)
    /// All steps executed in one serialized mutation slice
    /// 
    /// **v2.3b Sealed:** All commit steps MUST be executed in single actor turn:
    /// 1. Append evidence record (in-memory commit)
    /// 2. Increment PatchCountShadow
    /// 3. Consume EEB (apply eeb_delta)
    /// 4. Update build_mode latches
    /// 5. Emit audit snapshot (created inside actor for atomicity)
    /// 6. If SATURATED: latch + emit state transition request (one-shot)
    public func commitAcceptedEvidence(
        candidateId: UUID,
        evidence: AcceptedEvidence,
        eebDelta: Double,
        decision: AdmissionDecision
    ) async throws -> CommitResult {
        // Step 1: Idempotency check (inside actor)
        // **v2.3b Sealed:** Same candidateId MUST return same result deterministically
        guard !committedCandidateIds.contains(candidateId) else {
            // Idempotent replay: return existing metrics without mutation
            // This ensures:
            // - No double-count PatchCountShadow
            // - No double-consume EEB
            // - Same decision on replay
            let distributionStringKeys = Dictionary(uniqueKeysWithValues: 
                rejectReasonDistribution.map { ($0.key.rawValue, $0.value) }
            )
            
            let existingMetrics = CapacityMetrics(
                candidateId: candidateId,
                patchCountShadow: patchCountShadow,
                eebRemaining: eebRemaining,
                eebDelta: 0.0,  // No delta for already committed
                buildMode: buildMode,
                rejectReason: nil,
                hardFuseTrigger: saturatedLatchedTrigger,
                rejectReasonDistribution: distributionStringKeys,
                capacityInvariantViolation: false,
                capacitySaturatedLatchedAtPatchCount: saturatedLatchedAtPatchCount,
                capacitySaturatedLatchedAtTimestamp: saturatedLatchedAtTimestamp,
                flushFailure: false,
                decisionHash: decision.decisionHash
            )
            return .committed(existingMetrics)
        }
        
        // Validate eebDelta
        guard eebDelta >= CapacityLimitConstants.EEB_MIN_QUANTUM else {
            throw PatchTrackerError.invalidEEBDelta
        }
        
        // Step 2-6: All in single actor turn (atomic)
        // **v2.3b Sealed:** All mutations happen in one serialized slice
        // No split-brain possible: evidence, counters, EEB, mode latches all updated together
        
        // Pre-validate EEB invariants BEFORE mutations (to avoid rollback)
        // Check if eebDelta would violate invariants
        let projectedEEB = eebRemaining - eebDelta
        guard projectedEEB >= 0 && projectedEEB <= CapacityLimitConstants.EEB_BASE_BUDGET &&
              !projectedEEB.isNaN && !projectedEEB.isInfinite else {
            throw PatchTrackerError.eebInvariantViolation(.eebNegative)
        }
        
        // 2. Append evidence record (in-memory commit, authoritative)
        // **v2.3b Sealed:** Once appended, evidence is immutable and cannot be evicted
        evidenceSet.append(evidence)
        
        // 3. Increment PatchCountShadow (idempotent: only if not already committed)
        patchCountShadow += 1
        
        // 4. Consume EEB (monotonic, idempotent: only if not already committed)
        eebRemaining -= eebDelta
        
        // Post-validate EEB invariants (defense in depth)
        let (isValid, violation) = validateEEBInvariants()
        guard isValid else {
            // This should never happen if pre-validation passed, but defense in depth
            throw PatchTrackerError.eebInvariantViolation(violation!)
        }
        
        // 5. Update build_mode latches (NORMAL → DAMPING → SATURATED)
        updateBuildModeLatches()
        
        // Invariant fence: check after mutations
        _preconditionInvariants()
        
        // 6. Create audit snapshot (structured CapacityMetrics) - inside actor for atomicity
        let (latchedPatchCount, latchedTimestamp, _) = getSaturatedLatchMetadata()
        
        // Convert rejectReasonDistribution to string keys for CapacityMetrics
        let distributionStringKeys = Dictionary(uniqueKeysWithValues: 
            rejectReasonDistribution.map { ($0.key.rawValue, $0.value) }
        )
        
        let metrics = CapacityMetrics(
            candidateId: candidateId,
            patchCountShadow: patchCountShadow,
            eebRemaining: eebRemaining,
            eebDelta: eebDelta,
            buildMode: buildMode,
            rejectReason: decision.reason,
            hardFuseTrigger: decision.hardFuseTrigger,
            rejectReasonDistribution: distributionStringKeys,
            capacityInvariantViolation: violation != nil,
            capacitySaturatedLatchedAtPatchCount: latchedPatchCount,
            capacitySaturatedLatchedAtTimestamp: latchedTimestamp,
            flushFailure: false,
            decisionHash: decision.decisionHash
        )
        // Note: Actual audit emission handled by caller or async flush
        
        // 7. SATURATED latch is handled in updateBuildModeLatches()
        // Invariant fence: check after all mutations
        if buildMode == .SATURATED && saturatedLatched {
            _preconditionInvariants()
        }
        
        // 8. Register idempotency
        committedCandidateIds.insert(candidateId)
        
        // Final invariant fence before returning
        _preconditionInvariants()
        
        // Return commit result with metrics (created inside actor for atomicity)
        return .committed(metrics)
    }
    
    // MARK: - Invariant Fence (Panic on Violation)
    
    /// Internal invariant checker (panic fence)
    /// 
    /// **MUST:** Called after every mutation that changes:
    /// - patchCountShadow
    /// - eebRemaining
    /// - buildMode / saturated latch state
    /// - idempotency registry state (when it affects metrics)
    /// 
    /// In Debug/CI: crashes fast using precondition(...) (not assert(...))
    private func _preconditionInvariants(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(eebRemaining.isFinite, "EEB must be finite", file: file, line: line)
        precondition(eebRemaining >= 0, "EEB must be >= 0", file: file, line: line)
        precondition(eebRemaining <= CapacityLimitConstants.EEB_BASE_BUDGET, "EEB must be <= base budget", file: file, line: line)
        precondition(patchCountShadow >= 0, "patchCountShadow must be >= 0", file: file, line: line)
        
        // If latched saturated, buildMode must be SATURATED (latch consistency)
        if saturatedLatched {
            precondition(buildMode == .SATURATED, "latched saturated implies buildMode.SATURATED", file: file, line: line)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Update build mode latches based on current state
    private func updateBuildModeLatches() {
        // Check HARD limit first (highest priority)
        if let hardTrigger = shouldTriggerHardLimit() {
            buildMode = .SATURATED
            // Latch SATURATED if not already latched
            if !saturatedLatched {
                saturatedLatched = true
                saturatedLatchedAtPatchCount = patchCountShadow
                saturatedLatchedAtTimestamp = Date()
                saturatedLatchedTrigger = hardTrigger
            }
            return
        }
        
        // Check SOFT limit
        if shouldTriggerSoftLimit() {
            if buildMode == .NORMAL {
                buildMode = .DAMPING
            }
            // If already DAMPING, stay DAMPING
            // If already SATURATED, stay SATURATED (latched)
        }
    }
    
    // MARK: - Rejection Tracking
    
    /// Record rejection reason for audit distribution
    /// Called for all rejections (including DUPLICATE_REJECTED)
    /// Updates rejectReasonDistribution inside actor for atomicity
    public func recordRejection(reason: RejectReason) {
        rejectReasonDistribution[reason, default: 0] += 1
        // Invariant fence: check after mutation
        _preconditionInvariants()
    }
    
    /// Get current reject reason distribution snapshot
    public func getRejectReasonDistribution() -> [RejectReason: Int] {
        return rejectReasonDistribution
    }
    
    // MARK: - Session Management
    
    /// Release session-scoped resources (idempotency registry)
    /// Called when session terminates
    public func releaseSession() {
        // Clear idempotency registry (session-scoped release)
        committedCandidateIds.removeAll()
        // Note: evidenceSet, counters, and rejectReasonDistribution remain for audit/replay
    }
}

// MARK: - Patch Tracker Error

public enum PatchTrackerError: Error {
    case invalidEEBDelta
    case eebInvariantViolation(CapacityInvariantViolation)
    case alreadyCommitted
}
