// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObservationValidity.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - Validity Enums
//
// Closed-world enums for observation validity and invalid reasons.
// No String errors, no dynamic extension.
//

import Foundation

// MARK: - InvalidReason

/// Invalid reason (closed-world enum)
public enum InvalidReason: String, Codable, CaseIterable {
    case noGeometricIntersection
    case insufficientOverlapArea
    case fullyOccluded
    case insufficientMultiViewSupport
    case parallaxThresholdNotMet
    case missingDepthMeasurement
    case missingPairMetrics
    case reprojectionErrorExceeded
    case geometricVarianceExceeded
    case insufficientDistinctViewpoints
    case depthVarianceExceeded
    case luminanceVarianceExceeded
    case labVarianceExceeded
    case nonFiniteInput
}

// MARK: - ObservationValidity

/// Observation validity (closed-world)
public enum ObservationValidity: Equatable {
    case invalid(reason: InvalidReason)
    case l1
    case l2
    case l3_core
    case l3_strict
}
