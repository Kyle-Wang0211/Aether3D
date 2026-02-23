//
// ViewDiversityTracker.swift
// Aether3D
//
// PR2 Patch V4 - View Diversity Tracker
// Deterministic angle bucketing for novelty scoring
//

import Foundation
import CAetherNativeBridge

/// View diversity tracker
///
/// DESIGN:
/// - Buckets view angles into fixed-size buckets
/// - Novelty score higher for new buckets
/// - Deterministic storage (sorted arrays, no Set iteration)
public final class ViewDiversityTracker {
    private let nativeTracker: OpaquePointer
    
    public init() {
        var tracker: OpaquePointer?
        let rc = aether_view_diversity_create(&tracker)
        precondition(rc == 0, "aether_view_diversity_create failed: rc=\(rc)")
        precondition(tracker != nil, "aether_view_diversity_create returned nil tracker")
        nativeTracker = tracker!
    }

    deinit {
        _ = aether_view_diversity_destroy(nativeTracker)
    }
    
    /// Add observation and return novelty score
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - viewAngleDeg: View angle in degrees [0, 360)
    ///   - timestampMs: Current timestamp in milliseconds
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Novelty score [0, 1] where 1.0 = highly novel (new bucket)
    public func addObservation(
        patchId: String,
        viewAngleDeg: Double,
        timestampMs: Int64,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Double {
        precondition(constants.diversityMaxBucketsTracked == 16,
                     "ViewDiversityTracker uses C++ SSOT constants only")
        precondition(abs(constants.diversityAngleBucketSizeDeg - 15.0) < 1e-12,
                     "ViewDiversityTracker uses C++ SSOT constants only")

        var diversity: Double = 1.0
        let rc = patchId.withCString { cPatchId in
            aether_view_diversity_add_observation(
                nativeTracker,
                cPatchId,
                viewAngleDeg,
                timestampMs,
                &diversity
            )
        }
        precondition(rc == 0, "aether_view_diversity_add_observation failed: rc=\(rc)")
        return diversity
    }
    
    /// Get diversity score for a patch
    ///
    /// - Parameters:
    ///   - patchId: Patch identifier
    ///   - constants: Evidence constants (defaults to EvidenceConstants)
    /// - Returns: Diversity score [0, 1] where 1.0 = high diversity
    public func diversityScore(
        patchId: String,
        constants: EvidenceConstants.Type = EvidenceConstants.self
    ) -> Double {
        precondition(constants.diversityMaxBucketsTracked == 16,
                     "ViewDiversityTracker uses C++ SSOT constants only")

        var diversity: Double = 1.0
        let rc = patchId.withCString { cPatchId in
            aether_view_diversity_score(nativeTracker, cPatchId, &diversity)
        }
        precondition(rc == 0, "aether_view_diversity_score failed: rc=\(rc)")
        return diversity
    }
    
    /// Reset all tracking
    public func reset() {
        _ = aether_view_diversity_reset(nativeTracker)
    }
}
