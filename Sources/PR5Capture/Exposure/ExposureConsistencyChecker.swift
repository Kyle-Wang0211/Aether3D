//
// ExposureConsistencyChecker.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 6 + H: 曝光和颜色一致性
// 曝光一致性检查，曝光漂移检测，稳定性验证
//

import Foundation

/// Exposure consistency checker
///
/// Checks exposure consistency across frames.
/// Detects exposure drift and validates stability.
public actor ExposureConsistencyChecker {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Exposure history
    private var exposureHistory: [(timestamp: Date, exposure: Double)] = []
    
    /// Consistency scores
    private var consistencyScores: [Double] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Consistency Checking
    
    /// Check exposure consistency
    ///
    /// Validates exposure stability across frames
    public func checkConsistency(_ exposure: Double) -> ConsistencyResult {
        exposureHistory.append((timestamp: Date(), exposure: exposure))
        
        // Keep only recent history (last 50)
        if exposureHistory.count > 50 {
            exposureHistory.removeFirst()
        }
        
        guard exposureHistory.count >= 3 else {
            let mean = exposureHistory.isEmpty ? exposure : exposureHistory.map { $0.exposure }.reduce(0.0, +) / Double(exposureHistory.count)
            let variance = exposureHistory.isEmpty ? 0.0 : exposureHistory.map { pow($0.exposure - mean, 2) }.reduce(0.0, +) / Double(exposureHistory.count)
            let stdDev = sqrt(variance)
            return ConsistencyResult(
                isConsistent: true,
                consistencyScore: 1.0,
                drift: 0.0,
                sampleCount: exposureHistory.count,
                mean: mean,
                stdDev: stdDev
            )
        }
        
        // Compute statistics
        let exposures = exposureHistory.map { $0.exposure }
        let mean = exposures.reduce(0.0, +) / Double(exposures.count)
        let variance = exposures.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(exposures.count)
        let stdDev = sqrt(variance)
        
        // Compute drift
        let drift = abs(exposure - mean)
        
        // Compute consistency score (inverse of coefficient of variation)
        let coefficientOfVariation = stdDev / max(mean, 0.001)
        let consistencyScore = 1.0 / (1.0 + coefficientOfVariation)
        
        // Check consistency (threshold: CV < 0.1)
        let isConsistent = coefficientOfVariation < 0.1
        
        consistencyScores.append(consistencyScore)
        
        // Keep only recent scores (last 50)
        if consistencyScores.count > 50 {
            consistencyScores.removeFirst()
        }
        
        return ConsistencyResult(
            isConsistent: isConsistent,
            consistencyScore: consistencyScore,
            drift: drift,
            sampleCount: exposureHistory.count,
            mean: mean,
            stdDev: stdDev
        )
    }
    
    // MARK: - Result Types
    
    /// Consistency result
    public struct ConsistencyResult: Sendable {
        public let isConsistent: Bool
        public let consistencyScore: Double
        public let drift: Double
        public let sampleCount: Int
        public let mean: Double
        public let stdDev: Double
    }
}
