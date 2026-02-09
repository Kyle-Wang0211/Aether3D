// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// OnlineMADEstimator.swift
// PR4Gate
//
// PR4 V10 - Pillar 37: Online MAD estimator
//

import Foundation
import PR4Math

/// Online MAD estimator
public final class OnlineMADEstimator {
    private var samples: [Double] = []
    private let maxSamples = 1000
    
    public init() {}
    
    public func addSample(_ value: Double) {
        samples.append(value)
        if samples.count > maxSamples {
            samples.removeFirst()
        }
    }
    
    public func getMAD() -> Double {
        guard samples.count >= 3 else { return 0 }
        return DeterministicMedianMAD.mad(samples)
    }
    
    public func reset() {
        samples.removeAll()
    }
}
