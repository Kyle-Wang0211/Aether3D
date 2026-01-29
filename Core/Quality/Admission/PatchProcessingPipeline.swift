//
// PatchProcessingPipeline.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Patch Processing Pipeline Integration
//
// Integration example showing how to use AdmissionController in pipeline
//

import Foundation

/// Patch processing pipeline integration
/// 
/// **v2.3b Sealed:**
/// - All PatchTracker access MUST be via await actor methods
/// - MUST NOT directly access or modify PatchTracker internal state
/// - SATURATED latch triggers state machine transition
public struct PatchProcessingPipeline {
    private let tracker: PatchTracker
    private let admissionController: AdmissionController
    private let duplicateDetector: DuplicateDetector
    private let commitTransaction: EvidenceCommitTransaction
    private var duplicateSignatures: Set<String> = []
    private var coverageGrid: CoverageGrid = CoverageGrid()
    private var existingPatches: [PatchCandidate] = []
    
    /// Initialize pipeline with tracker and controllers
    public init(
        tracker: PatchTracker = PatchTracker(),
        admissionController: AdmissionController = AdmissionController(),
        duplicateDetector: DuplicateDetector = DuplicateDetector(),
        commitTransaction: EvidenceCommitTransaction = EvidenceCommitTransaction()
    ) {
        self.tracker = tracker
        self.admissionController = admissionController
        self.duplicateDetector = duplicateDetector
        self.commitTransaction = commitTransaction
    }
    
    /// Process a patch candidate through the admission pipeline
    /// 
    /// **Integration flow (v2.3b Sealed):**
    /// 1. Create PatchTracker actor instance (per session)
    /// 2. Generate candidateId: UUID for each candidate patch
    /// 3. Call DuplicateDetector.computeDuplicateSignature() (deterministic)
    /// 4. Call AdmissionController.evaluateAdmission() (deterministic input, via await)
    /// 5. Call EvidenceCommitTransaction.commitEvidence() (atomic transaction, via await)
    /// 6. If SATURATED latched, trigger state machine transition to CAPACITY_SATURATED
    public mutating func processPatch(_ candidate: PatchCandidate) async throws -> AdmissionDecision {
        // Step 1: Generate candidate ID (if not already set)
        _ = candidate.candidateId
        
        // Step 2: Compute duplicate signature (deterministic)
        let signature = DuplicateDetector.computeDuplicateSignature(candidate)
        let isDuplicate = duplicateSignatures.contains(signature)
        
        // Step 3: Evaluate admission (deterministic input, via await access to tracker)
        let decision = await admissionController.evaluateAdmission(
            candidate: candidate,
            isDuplicate: isDuplicate,
            existingCoverage: coverageGrid,
            existingPatches: existingPatches,
            tracker: tracker
        )
        
        // Record rejection for audit distribution (if rejected)
        if decision.classification != .ACCEPTED, let reason = decision.reason {
            await tracker.recordRejection(reason: reason)
        }
        
        // Step 4: Commit evidence if accepted (atomic transaction, via await)
        if decision.classification == .ACCEPTED {
            let commitResult = try await commitTransaction.commitEvidence(
                candidate: candidate,
                decision: decision,
                tracker: tracker
            )
            
            switch commitResult {
            case .committed(let metrics):
                // Update local state (for duplicate detection and coverage tracking)
                duplicateSignatures.insert(signature)
                existingPatches.append(candidate)
                // Note: coverageGrid update handled by coverage system (out of scope for PR1)
                
                // Emit audit snapshot (metrics created inside actor, atomic)
                // Note: Actual audit emission handled by audit system
                
                // Check if SATURATED latched (one-shot)
                if metrics.buildMode == .SATURATED && metrics.capacitySaturatedLatchedAtPatchCount != nil {
                    // Step 5: Trigger state machine transition to CAPACITY_SATURATED (one-shot)
                    await handleSaturatedTransition()
                }
                
            case .alreadyCommitted(let id):
                // Idempotency: return existing decision
                // Same candidateId returns same result deterministically
                print("[PatchProcessingPipeline] Already committed: \(id)")
                
            case .rejected(_, _):
                // Rejected patches don't update state
                break
            }
        }
        
        return decision
    }
    
    /// Handle SATURATED transition (one-shot)
    private func handleSaturatedTransition() async {
        // Get latch metadata
        let (patchCount, _, trigger) = await tracker.getSaturatedLatchMetadata()
        
        // Emit state transition request (one-shot)
        // Note: Actual state machine transition handled by JobStateMachine
        // This is a callback point; actual transition implementation depends on job context
        print("[PatchProcessingPipeline] SATURATED latched at patch count: \(patchCount ?? -1), trigger: \(trigger?.rawValue ?? "unknown")")
        
        // State machine transition example:
        // JobStateMachine.transition(
        //     jobId: jobId,
        //     from: .processing,
        //     to: .capacitySaturated,
        //     logger: { log in /* emit to audit */ }
        // )
    }
    
    /// Release session-scoped resources
    public mutating func releaseSession() async {
        await tracker.releaseSession()
        duplicateSignatures.removeAll()
        existingPatches.removeAll()
    }
}
