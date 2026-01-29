//
//  PhotometricConsistencyChecker.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - PR5-QUALITY-2.0
//  Cross-frame photometric consistency validation
//  Critical for NeRF/3DGS quality
//

import Foundation

/// Lab color representation
public struct LabColor: Codable, Equatable {
    public let l: Double  // Luminance (0-100)
    public let a: Double  // Green-Red (-128 to 127)
    public let b: Double  // Blue-Yellow (-128 to 127)
    
    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }
}

/// Photometric consistency result
public struct PhotometricResult: Codable, Equatable {
    /// Luminance variance across sliding window
    public let luminanceVariance: Double
    
    /// Lab color variance (ΔE*ab)
    public let labVariance: Double
    
    /// Exposure consistency ratio (0-1)
    public let exposureConsistency: Double
    
    /// True if all metrics pass thresholds
    public let isConsistent: Bool
    
    /// Confidence level
    public let confidence: Double
    
    /// Applicable rule IDs
    public var applicableRuleIds: [RuleId] {
        var rules: [RuleId] = []
        
        if luminanceVariance > FrameQualityConstants.MAX_LUMINANCE_VARIANCE_FOR_NERF {
            rules.append(.PHOTOMETRIC_LUMINANCE_INCONSISTENT)
        }
        if labVariance > FrameQualityConstants.MAX_LAB_VARIANCE_FOR_NERF {
            rules.append(.PHOTOMETRIC_LAB_VARIANCE_EXCEEDED)
        }
        if exposureConsistency < FrameQualityConstants.MIN_EXPOSURE_CONSISTENCY_RATIO {
            rules.append(.PHOTOMETRIC_EXPOSURE_JUMP)
        }
        
        return rules
    }
    
    public init(
        luminanceVariance: Double,
        labVariance: Double,
        exposureConsistency: Double,
        isConsistent: Bool,
        confidence: Double
    ) {
        self.luminanceVariance = luminanceVariance
        self.labVariance = labVariance
        self.exposureConsistency = exposureConsistency
        self.isConsistent = isConsistent
        self.confidence = confidence
    }
}

/// Cross-frame photometric consistency checker
/// Validates that sequential frames have consistent lighting/exposure
/// Critical for NeRF/3DGS which assume photometric consistency
public class PhotometricConsistencyChecker {
    
    /// Sliding window of luminance values (mean luminance per frame)
    private var luminanceHistory: RingBuffer<Double>
    
    /// Sliding window of exposure values (from EXIF or estimated)
    private var exposureHistory: RingBuffer<Double>
    
    /// Sliding window of Lab mean values
    private var labHistory: RingBuffer<LabColor>
    
    /// Window size in frames
    private let windowSize: Int
    
    public init(windowSize: Int = 10) {
        self.windowSize = windowSize
        self.luminanceHistory = RingBuffer(maxCapacity: windowSize)
        self.exposureHistory = RingBuffer(maxCapacity: windowSize)
        self.labHistory = RingBuffer(maxCapacity: windowSize)
    }
    
    /// Update with new frame data
    public func update(luminance: Double, exposure: Double, lab: LabColor) {
        luminanceHistory.append(luminance)
        exposureHistory.append(exposure)
        labHistory.append(lab)
    }
    
    /// Check current consistency
    public func checkConsistency() -> PhotometricResult {
        let luminanceVar = luminanceHistory.variance()
        let labVar = labHistory.labVariance()
        let expConsistency = exposureHistory.consistencyRatio()
        
        // H1: NaN/Inf check
        let safeLuminanceVar = luminanceVar.isNaN || luminanceVar.isInfinite ? 0.0 : luminanceVar
        let safeLabVar = labVar.isNaN || labVar.isInfinite ? 0.0 : labVar
        let safeExpConsistency = expConsistency.isNaN || expConsistency.isInfinite ? 1.0 : expConsistency
        
        let isConsistent = safeLuminanceVar <= FrameQualityConstants.MAX_LUMINANCE_VARIANCE_FOR_NERF
            && safeLabVar <= FrameQualityConstants.MAX_LAB_VARIANCE_FOR_NERF
            && safeExpConsistency >= FrameQualityConstants.MIN_EXPOSURE_CONSISTENCY_RATIO
        
        let confidence = Double(luminanceHistory.currentCount) / Double(windowSize)
        
        return PhotometricResult(
            luminanceVariance: safeLuminanceVar,
            labVariance: safeLabVar,
            exposureConsistency: safeExpConsistency,
            isConsistent: isConsistent,
            confidence: min(1.0, confidence)
        )
    }
    
    /// Reset history (e.g., after lighting change detected)
    public func reset() {
        luminanceHistory.clear()
        exposureHistory.clear()
        labHistory.clear()
    }
}
