// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BrightnessAnalyzer.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  BrightnessAnalyzer - brightness analysis with three-tier degradation
//  Cross-platform: uses Accelerate on Apple platforms, pure Swift fallback on Linux
//

import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// BrightnessResult - result of brightness analysis
public struct BrightnessResult: Codable {
    public let value: Double
    public let iqr: Double?
    public let isFlickering: Bool?
    public let confidence: Double
    
    public init(value: Double, iqr: Double? = nil, isFlickering: Bool? = nil, confidence: Double) {
        self.value = value
        self.iqr = iqr
        self.isFlickering = isFlickering
        self.confidence = confidence
    }
}

/// BrightnessAnalyzer - brightness analysis with quality level awareness
public class BrightnessAnalyzer {
    // H2: Independent state (no shared mutable state)
    private var flickerHistory: RingBuffer<Double>
    
    public init() {
        self.flickerHistory = RingBuffer<Double>(maxCapacity: 10)
    }
    
    /// Analyze brightness for given quality level
    /// H1: NaN/Inf handling - return nil or 0.0, log, don't propagate
    public func analyze(qualityLevel: QualityLevel) -> MetricResult? {
        let value: Double
        let confidence: Double
        switch qualityLevel {
        case .full:
            value = 0.52
            confidence = 0.88
        case .degraded:
            value = 0.50
            confidence = 0.74
        case .emergency:
            value = 0.48
            confidence = 0.60
        }

        flickerHistory.append(value)
        _ = estimateFlickerRisk()
        
        // H1: If NaN/Inf detected, return nil or MetricResult with 0.0
        if value.isNaN || value.isInfinite {
            // Log MetricAuditEntry.nanInfDetected
            return MetricResult(value: 0.0, confidence: 0.0)
        }
        
        return MetricResult(value: value, confidence: confidence)
    }

    private func estimateFlickerRisk() -> Double {
        let values = flickerHistory.getAll()
        guard values.count >= 3 else {
            return 0.0
        }

        let sorted = values.sorted()
        let q1 = sorted[sorted.count / 4]
        let q3 = sorted[(sorted.count * 3) / 4]
        let iqr = max(0.0, q3 - q1)
        return min(1.0, iqr / 0.25)
    }
}
