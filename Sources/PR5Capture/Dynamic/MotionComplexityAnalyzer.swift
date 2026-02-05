//
// MotionComplexityAnalyzer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 4 + F: 动态场景和细化
// 运动复杂度分析，多目标跟踪，轨迹分析
//

import Foundation

/// Motion complexity analyzer
///
/// Analyzes motion complexity for multi-object tracking.
/// Performs trajectory analysis.
public actor MotionComplexityAnalyzer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Motion vectors history
    private var motionVectors: [[MotionVector]] = []
    
    /// Complexity scores
    private var complexityScores: [(timestamp: Date, score: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Complexity Analysis
    
    /// Analyze motion complexity
    ///
    /// Computes complexity score from motion vectors
    public func analyzeComplexity(_ vectors: [MotionVector]) -> ComplexityAnalysisResult {
        motionVectors.append(vectors)
        
        // Keep only recent history (last 50)
        if motionVectors.count > 50 {
            motionVectors.removeFirst()
        }
        
        // Compute complexity metrics
        let magnitudeVariance = computeMagnitudeVariance(vectors)
        let directionVariance = computeDirectionVariance(vectors)
        let objectCount = vectors.count
        
        // Combine into complexity score
        let complexity = (magnitudeVariance * 0.4) + (directionVariance * 0.4) + (min(Double(objectCount) / 10.0, 1.0) * 0.2)
        
        // Record score
        complexityScores.append((timestamp: Date(), score: complexity))
        
        // Keep only recent scores (last 100)
        if complexityScores.count > 100 {
            complexityScores.removeFirst()
        }
        
        return ComplexityAnalysisResult(
            complexity: complexity,
            magnitudeVariance: magnitudeVariance,
            directionVariance: directionVariance,
            objectCount: objectCount
        )
    }
    
    /// Compute magnitude variance
    private func computeMagnitudeVariance(_ vectors: [MotionVector]) -> Double {
        guard !vectors.isEmpty else { return 0.0 }
        
        let magnitudes = vectors.map { sqrt($0.dx * $0.dx + $0.dy * $0.dy) }
        let mean = magnitudes.reduce(0.0, +) / Double(magnitudes.count)
        let variance = magnitudes.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(magnitudes.count)
        
        return min(1.0, variance)
    }
    
    /// Compute direction variance
    private func computeDirectionVariance(_ vectors: [MotionVector]) -> Double {
        guard !vectors.isEmpty else { return 0.0 }
        
        let directions = vectors.map { atan2($0.dy, $0.dx) }
        let mean = directions.reduce(0.0, +) / Double(directions.count)
        let variance = directions.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(directions.count)
        
        return min(1.0, variance)
    }
    
    // MARK: - Data Types
    
    /// Motion vector
    public struct MotionVector: Sendable {
        public let dx: Double
        public let dy: Double
        
        public init(dx: Double, dy: Double) {
            self.dx = dx
            self.dy = dy
        }
    }
    
    /// Complexity analysis result
    public struct ComplexityAnalysisResult: Sendable {
        public let complexity: Double
        public let magnitudeVariance: Double
        public let directionVariance: Double
        public let objectCount: Int
    }
}
