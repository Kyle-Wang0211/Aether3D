//
//  MetricResult.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Metric result structure
//

import Foundation

/// MetricResult - result of a single metric calculation
public struct MetricResult: Codable {
    public let value: Double
    public let confidence: Double
    public let roiCoverageRatio: Double?
    
    public init(value: Double, confidence: Double, roiCoverageRatio: Double? = nil) {
        self.value = value
        self.confidence = confidence
        self.roiCoverageRatio = roiCoverageRatio
    }
}

