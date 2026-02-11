// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HealthInputs.swift
// PR4Health
//
// PR4 V10 - Pillar 30: Health input closed set (NO quality/uncertainty/gate)
//

import Foundation

/// Health inputs - closed set with NO dependencies on quality/uncertainty/gate
///
/// V8 RULE: Health inputs are ONLY raw sensor metrics.
/// NO derived values from quality computation.
public struct HealthInputs {
    /// Consistency: source agreement ratio (from depth agreement, NOT quality)
    public let consistency: Double
    
    /// Coverage: depth coverage ratio (from validity mask, NOT quality)
    public let coverage: Double
    
    /// Confidence stability (from raw confidence variance, NOT quality)
    public let confidenceStability: Double
    
    /// Latency OK flag (from timing measurement)
    public let latencyOK: Bool
    
    public init(
        consistency: Double,
        coverage: Double,
        confidenceStability: Double,
        latencyOK: Bool
    ) {
        self.consistency = consistency
        self.coverage = coverage
        self.confidenceStability = confidenceStability
        self.latencyOK = latencyOK
    }
}
