//
// EvidenceCommitTransaction.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Evidence Commit Transaction
//
// Atomic evidence commit transaction coordinator
// All commit steps MUST be executed in single PatchTracker actor turn
//

import Foundation

/// Evidence commit result
public enum EvidenceCommitResult: Codable {
    case committed(CapacityMetrics)  // Metrics created inside actor for atomicity
    case alreadyCommitted(UUID)
    case rejected(PatchClassification, RejectReason?)
}

/// Evidence persistence handler (for async flush)
public protocol EvidencePersistenceHandler {
    func persistEvidence(_ evidence: AcceptedEvidence) async throws
}

/// Atomic evidence commit transaction coordinator
/// 
/// **v2.3b Sealed:**
/// - All commit steps MUST be executed in single PatchTracker actor turn
/// - Two-step model for async persistence: in-memory commit (authoritative) + async flush
/// - Flush failure MUST NOT rollback acceptance
public struct EvidenceCommitTransaction {
    private let persistenceHandler: EvidencePersistenceHandler?
    
    public init(persistenceHandler: EvidencePersistenceHandler? = nil) {
        self.persistenceHandler = persistenceHandler
    }
    
    /// Commit evidence atomically
    /// 
    /// **v2.3b Sealed Atomicity Boundary:**
    /// All commit steps executed in single PatchTracker actor turn:
    /// 1. Append evidence record (in-memory commit)
    /// 2. Increment PatchCountShadow
    /// 3. Consume EEB (apply eeb_delta)
    /// 4. Update build_mode latches
    /// 5. Emit audit snapshot
    /// 6. If SATURATED: latch + emit state transition request (one-shot)
    public func commitEvidence(
        candidate: PatchCandidate,
        decision: AdmissionDecision,
        tracker: PatchTracker
    ) async throws -> EvidenceCommitResult {
        // All commit steps MUST be executed via single actor method call
        // to ensure atomicity within one actor turn
        
        guard decision.classification == .ACCEPTED else {
            return .rejected(decision.classification, decision.reason)
        }
        
        // Create evidence record
        let evidence = AcceptedEvidence(
            candidateId: candidate.candidateId,
            timestamp: Date(),
            eebDelta: decision.eebDelta
        )
        
        // Step 1: In-memory commit (authoritative, inside actor turn)
        // All state queries and mutations happen inside single actor turn
        // CapacityMetrics is created inside actor to ensure atomicity
        // This single await call executes all commit steps atomically
        let commitResult = try await tracker.commitAcceptedEvidence(
            candidateId: candidate.candidateId,
            evidence: evidence,
            eebDelta: decision.eebDelta,
            decision: decision
        )
        
        switch commitResult {
        case .committed(let metrics):
            // Step 2: Async flush attempt (outside actor turn, non-blocking)
            if let handler = persistenceHandler {
                Task {
                    do {
                        try await handler.persistEvidence(evidence)
                    } catch {
                        // Record flush_failure = true in audit
                        // MUST NOT evict evidence, decrement counters, or refund EEB
                        // Note: Actual audit recording handled by audit system
                        // TODO: Update metrics with flushFailure = true in audit system
                        print("[EvidenceCommitTransaction] Flush failure for candidateId \(candidate.candidateId): \(error)")
                    }
                }
            }
            // Metrics created inside actor, ready for audit emission
            return .committed(metrics)
            
        case .alreadyCommitted(let id):
            return .alreadyCommitted(id)
        }
    }
}
