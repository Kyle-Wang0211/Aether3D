//
// TripleTimeAnchorError.swift
// Aether3D
//
// Phase 1: Time Anchoring - Triple Time Anchor Fusion Error Types
//

import Foundation

/// Errors for triple time anchor fusion
///
/// **Fail-closed:** All errors are explicit
public enum TripleTimeAnchorError: Error, Sendable {
    /// Insufficient sources (need at least 2)
    case insufficientSources(available: Int, required: Int)
    
    /// Time disagreement (evidences don't agree within uncertainty bounds)
    case timeDisagreement(
        source1: TimeEvidence.Source,
        source2: TimeEvidence.Source,
        differenceNs: UInt64
    )
    
    /// All sources failed
    case allSourcesFailed
}
