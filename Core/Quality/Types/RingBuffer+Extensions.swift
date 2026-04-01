// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  RingBuffer+Extensions.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - PR5-QUALITY-2.0
//  Extensions for RingBuffer to support variance calculations
//

import Foundation

// MARK: - Double Extensions

extension RingBuffer where T == Double {
    /// Compute variance of buffer contents
    /// Cross-platform deterministic (uses Double only)
    func variance() -> Double {
        guard currentCount >= 2 else { return 0.0 }
        let values = getAll()
        let mean = values.reduce(0.0, +) / Double(values.count)
        let sumSquares = values.map { ($0 - mean) * ($0 - mean) }.reduce(0.0, +)
        return sumSquares / Double(values.count)
    }

    /// Compute min/max consistency ratio
    func consistencyRatio() -> Double {
        guard currentCount >= 2 else { return 1.0 }
        let values = getAll()
        guard let minVal = values.min(), let maxVal = values.max(), maxVal > 0 else {
            return 1.0
        }
        return minVal / maxVal
    }
}
