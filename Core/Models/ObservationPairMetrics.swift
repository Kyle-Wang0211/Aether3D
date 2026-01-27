//
// ObservationPairMetrics.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - Pairwise Metrics
//
// Pairwise metrics are NOT per-observation inputs.
// Reprojection error and triangulated variance are pairwise evidence.
// PR#1 MUST model them explicitly as pair inputs.
//

import Foundation

// MARK: - ObservationPairKey

/// Pair key with canonical ordering (removes direction ambiguity)
public struct ObservationPairKey: Codable, Equatable, Hashable {
    public let a: ObservationID
    public let b: ObservationID
    
    public init(_ x: ObservationID, _ y: ObservationID) {
        // Canonical ordering to remove direction ambiguity
        if x.value <= y.value {
            self.a = x
            self.b = y
        } else {
            self.a = y
            self.b = x
        }
    }
}

// MARK: - ObservationPairMetrics

/// Pairwise metrics (pairwise evidence, not per-observation inputs)
public struct ObservationPairMetrics: Codable, Equatable {
    public let key: ObservationPairKey
    public let reprojectionErrorPx: Double
    public let triangulatedVariance: Double
    
    public init(key: ObservationPairKey, reprojectionErrorPx: Double, triangulatedVariance: Double) {
        precondition(reprojectionErrorPx.isFinite && triangulatedVariance.isFinite,
                     "Pair metrics must be finite")
        self.key = key
        self.reprojectionErrorPx = reprojectionErrorPx
        self.triangulatedVariance = triangulatedVariance
    }
}
