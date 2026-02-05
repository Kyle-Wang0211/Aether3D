//
// ISPDetector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 0: 传感器和相机管道
// 噪声底分析，锐化检测，色调曲线分析，ISP 强度分类
//

import Foundation

/// ISP detector
///
/// Analyzes Image Signal Processor (ISP) characteristics:
/// - Noise floor analysis
/// - Sharpening detection
/// - Tone curve analysis
/// - ISP strength classification
public actor ISPDetector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// ISP strength classification history
    private var strengthHistory: [ISPStrength] = []
    
    /// Noise floor measurements
    private var noiseFloorMeasurements: [Double] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - ISP Analysis
    
    /// Analyze ISP characteristics from image data
    ///
    /// Detects noise floor, sharpening, tone curve, and classifies ISP strength
    public func analyzeISP(
        pixelValues: [Double],
        metadata: [String: Any]
    ) -> ISPAnalysisResult {
        // Analyze noise floor
        let noiseFloor = analyzeNoiseFloor(pixelValues)
        noiseFloorMeasurements.append(noiseFloor)
        
        // Keep only recent measurements (last 50)
        if noiseFloorMeasurements.count > 50 {
            noiseFloorMeasurements.removeFirst()
        }
        
        // Analyze sharpening
        let sharpeningScore = analyzeSharpening(pixelValues)
        
        // Analyze tone curve
        let toneCurveScore = analyzeToneCurve(pixelValues)
        
        // Classify ISP strength
        let strength = classifyISPStrength(
            noiseFloor: noiseFloor,
            sharpeningScore: sharpeningScore,
            toneCurveScore: toneCurveScore
        )
        
        strengthHistory.append(strength)
        
        // Keep only recent history (last 50)
        if strengthHistory.count > 50 {
            strengthHistory.removeFirst()
        }
        
        return ISPAnalysisResult(
            noiseFloor: noiseFloor,
            sharpeningScore: sharpeningScore,
            toneCurveScore: toneCurveScore,
            strength: strength,
            threshold: PR5CaptureConstants.getValue(
                PR5CaptureConstants.Sensor.ispNoiseFloorThreshold,
                profile: config.profile
            )
        )
    }
    
    /// Analyze noise floor
    private func analyzeNoiseFloor(_ pixelValues: [Double]) -> Double {
        guard !pixelValues.isEmpty else { return 0.0 }
        
        // Compute variance in low-intensity regions (noise floor indicator)
        let lowIntensityPixels = pixelValues.filter { $0 < 0.1 }
        
        guard !lowIntensityPixels.isEmpty else {
            // Fallback: use overall variance
            let mean = pixelValues.reduce(0.0, +) / Double(pixelValues.count)
            let variance = pixelValues.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(pixelValues.count)
            return sqrt(variance)
        }
        
        let mean = lowIntensityPixels.reduce(0.0, +) / Double(lowIntensityPixels.count)
        let variance = lowIntensityPixels.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(lowIntensityPixels.count)
        
        return sqrt(variance)
    }
    
    /// Analyze sharpening
    private func analyzeSharpening(_ pixelValues: [Double]) -> Double {
        guard pixelValues.count >= 3 else { return 0.0 }
        
        // Compute high-frequency content (sharpening increases high frequencies)
        var highFreqSum = 0.0
        for i in 1..<(pixelValues.count - 1) {
            // Second derivative approximation
            let secondDeriv = abs(pixelValues[i+1] - 2*pixelValues[i] + pixelValues[i-1])
            highFreqSum += secondDeriv
        }
        
        return highFreqSum / Double(pixelValues.count - 2)
    }
    
    /// Analyze tone curve
    private func analyzeToneCurve(_ pixelValues: [Double]) -> Double {
        guard !pixelValues.isEmpty else { return 0.0 }
        
        // Analyze histogram shape (tone curve affects distribution)
        let histogram = computeHistogram(pixelValues, bins: 10)
        
        // Compute histogram variance (tone curve compression reduces variance)
        let mean = histogram.reduce(0.0, +) / Double(histogram.count)
        let variance = histogram.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(histogram.count)
        
        return variance
    }
    
    /// Compute histogram
    private func computeHistogram(_ values: [Double], bins: Int) -> [Double] {
        var histogram = Array(repeating: 0.0, count: bins)
        
        for value in values {
            let binIndex = min(Int(value * Double(bins)), bins - 1)
            histogram[binIndex] += 1.0
        }
        
        // Normalize
        let total = Double(values.count)
        return histogram.map { $0 / total }
    }
    
    /// Classify ISP strength
    private func classifyISPStrength(
        noiseFloor: Double,
        sharpeningScore: Double,
        toneCurveScore: Double
    ) -> ISPStrength {
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Sensor.ispNoiseFloorThreshold,
            profile: config.profile
        )
        
        // Combine indicators
        let combinedScore = (noiseFloor / threshold) * 0.4 +
                           (sharpeningScore * 10.0) * 0.3 +
                           (toneCurveScore * 10.0) * 0.3
        
        if combinedScore < 0.2 {
            return .none
        } else if combinedScore < 0.4 {
            return .low
        } else if combinedScore < 0.7 {
            return .medium
        } else if combinedScore < 1.0 {
            return .high
        } else {
            return .extreme
        }
    }
    
    // MARK: - Queries
    
    /// Get average noise floor
    public func getAverageNoiseFloor() -> Double? {
        guard !noiseFloorMeasurements.isEmpty else { return nil }
        return noiseFloorMeasurements.reduce(0.0, +) / Double(noiseFloorMeasurements.count)
    }
    
    /// Get most common ISP strength
    public func getMostCommonStrength() -> ISPStrength {
        guard !strengthHistory.isEmpty else { return .none }
        
        var counts: [ISPStrength: Int] = [:]
        for strength in strengthHistory {
            counts[strength, default: 0] += 1
        }
        
        return counts.max(by: { $0.value < $1.value })?.key ?? .none
    }
    
    // MARK: - Result Types
    
    /// ISP analysis result
    public struct ISPAnalysisResult: Sendable {
        public let noiseFloor: Double
        public let sharpeningScore: Double
        public let toneCurveScore: Double
        public let strength: ISPStrength
        public let threshold: Double
    }
}
