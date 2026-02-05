//
// DynamicRangePreserver.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 6 + H: 曝光和颜色一致性
// 动态范围保持，HDR处理，范围验证
//

import Foundation

/// Dynamic range preserver
///
/// Preserves dynamic range in HDR processing.
/// Validates dynamic range consistency.
public actor DynamicRangePreserver {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Dynamic range history
    private var rangeHistory: [(timestamp: Date, min: Double, max: Double, range: Double)] = []
    
    /// Preservation scores
    private var preservationScores: [Double] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Range Preservation
    
    /// Preserve dynamic range
    ///
    /// Validates and preserves dynamic range
    public func preserveRange(minValue: Double, maxValue: Double) -> RangePreservationResult {
        let range = maxValue - minValue
        
        rangeHistory.append((timestamp: Date(), min: minValue, max: maxValue, range: range))
        
        // Keep only recent history (last 50)
        if rangeHistory.count > 50 {
            rangeHistory.removeFirst()
        }
        
        guard rangeHistory.count >= 3 else {
            let avgRange = rangeHistory.isEmpty ? range : rangeHistory.map { $0.range }.reduce(0.0, +) / Double(rangeHistory.count)
            return RangePreservationResult(
                isPreserved: true,
                preservationScore: 1.0,
                range: range,
                sampleCount: rangeHistory.count,
                avgRange: avgRange
            )
        }
        
        // Compute average range
        let avgRange = rangeHistory.map { $0.range }.reduce(0.0, +) / Double(rangeHistory.count)
        
        // Check if range is preserved (within 10% of average)
        let rangeRatio = range / max(avgRange, 0.001)
        let isPreserved = rangeRatio >= 0.9 && rangeRatio <= 1.1
        
        // Compute preservation score
        let preservationScore = 1.0 - abs(rangeRatio - 1.0)
        
        preservationScores.append(preservationScore)
        
        // Keep only recent scores (last 50)
        if preservationScores.count > 50 {
            preservationScores.removeFirst()
        }
        
        return RangePreservationResult(
            isPreserved: isPreserved,
            preservationScore: preservationScore,
            range: range,
            sampleCount: rangeHistory.count,
            avgRange: avgRange
        )
    }
    
    // MARK: - Result Types
    
    /// Range preservation result
    public struct RangePreservationResult: Sendable {
        public let isPreserved: Bool
        public let preservationScore: Double
        public let range: Double
        public let sampleCount: Int
        public let avgRange: Double
    }
}
