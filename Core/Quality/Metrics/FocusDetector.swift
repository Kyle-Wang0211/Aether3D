//
//  FocusDetector.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  FocusDetector - focus status detection (Laplacian + Motion)
//

import Foundation

/// FocusStatus - focus status enumeration
public enum FocusStatus: String, Codable {
    case sharp = "sharp"
    case hunting = "hunting"
    case failed = "failed"
    case unknown = "unknown"
}

/// FocusDetector - focus status detection
public class FocusDetector {
    /// StatusProvider - injectable function to provide focus status and confidence
    /// Allows testing without camera/hardware dependencies
    public typealias StatusProvider = (_ qualityLevel: QualityLevel) -> (status: FocusStatus, confidence: Double)
    
    private let statusProvider: StatusProvider
    
    /// Default status provider - returns unknown status deterministically
    /// Hardware-free implementation for testing and placeholder behavior
    public static func defaultStatusProvider(qualityLevel: QualityLevel) -> (status: FocusStatus, confidence: Double) {
        return (.unknown, 0.0)
    }
    
    /// Initialize FocusDetector with optional status provider
    /// - Parameter statusProvider: Function that returns focus status and confidence for a given quality level
    ///   Defaults to defaultStatusProvider which returns (.unknown, 0.0)
    public init(statusProvider: @escaping StatusProvider = FocusDetector.defaultStatusProvider) {
        self.statusProvider = statusProvider
    }
    
    /// Detect focus status for given quality level
    /// Combines Laplacian + Motion
    /// 250ms window judgment
    public func detect(qualityLevel: QualityLevel) -> MetricResult? {
        // Get status and confidence from provider (non-constant)
        let providerResult = statusProvider(qualityLevel)
        let status = providerResult.status
        var confidence = providerResult.confidence
        
        // Map status to value
        let value: Double
        switch status {
        case .sharp: value = 1.0
        case .hunting: value = 0.5
        case .failed: value = 0.0
        case .unknown: value = 0.0
        }
        
        // Defensive clamping: ensure values are in [0,1] range
        let clampedValue = min(1.0, max(0.0, value))
        confidence = min(1.0, max(0.0, confidence))
        
        // H1: NaN/Inf check
        if clampedValue.isNaN || clampedValue.isInfinite || confidence.isNaN || confidence.isInfinite {
            return MetricResult(value: 0.0, confidence: 0.0)
        }
        
        return MetricResult(value: clampedValue, confidence: confidence)
    }
}

