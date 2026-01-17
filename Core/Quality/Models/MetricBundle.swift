//
//  MetricBundle.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Metric bundle containing all quality metrics
//

import Foundation

/// MetricBundle - bundle of all quality metrics
public struct MetricBundle: Codable {
    public let brightness: MetricResult?
    public let laplacian: MetricResult?
    public let featureScore: MetricResult?
    public let motionScore: MetricResult?
    public let saturation: MetricResult?
    public let focus: MetricResult?
    
    public init(
        brightness: MetricResult? = nil,
        laplacian: MetricResult? = nil,
        featureScore: MetricResult? = nil,
        motionScore: MetricResult? = nil,
        saturation: MetricResult? = nil,
        focus: MetricResult? = nil
    ) {
        self.brightness = brightness
        self.laplacian = laplacian
        self.featureScore = featureScore
        self.motionScore = motionScore
        self.saturation = saturation
        self.focus = focus
    }
}

/// CriticalMetricBundle - only brightness + laplacian (PART 2.5)
/// Used for Gray→White decisions
public struct CriticalMetricBundle: Codable {
    public let brightness: MetricResult
    public let laplacian: MetricResult
    
    public init(brightness: MetricResult, laplacian: MetricResult) {
        self.brightness = brightness
        self.laplacian = laplacian
    }
}

/// MetricSnapshotMinimal - minimal metric snapshot for logging
public struct MetricSnapshotMinimal: Codable {
    public let brightness: Double?
    public let laplacian: Double?
    public let featureScore: Double?
    public let motionScore: Double?
    
    public init(
        brightness: Double? = nil,
        laplacian: Double? = nil,
        featureScore: Double? = nil,
        motionScore: Double? = nil
    ) {
        self.brightness = brightness
        self.laplacian = laplacian
        self.featureScore = featureScore
        self.motionScore = motionScore
    }
}

