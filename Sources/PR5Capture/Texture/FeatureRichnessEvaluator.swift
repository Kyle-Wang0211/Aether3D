//
// FeatureRichnessEvaluator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 5 + G: 纹理响应和闭环
// 特征丰富度评估，特征密度分析，关键点检测
//

import Foundation

/// Feature richness evaluator
///
/// Evaluates feature richness and density.
/// Detects keypoints for quality assessment.
public actor FeatureRichnessEvaluator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Feature history
    private var featureHistory: [(timestamp: Date, count: Int, density: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Feature Evaluation
    
    /// Evaluate feature richness
    ///
    /// Computes richness score from feature count and density
    public func evaluateRichness(featureCount: Int, imageArea: Double) -> RichnessResult {
        let density = Double(featureCount) / max(imageArea, 1.0)
        
        // Normalize density (assume max 100 features per unit area)
        let normalizedDensity = min(1.0, density / 100.0)
        
        // Compute richness score (combination of count and density)
        let countScore = min(1.0, Double(featureCount) / 1000.0)
        let richnessScore = (countScore * 0.5) + (normalizedDensity * 0.5)
        
        // Record evaluation
        featureHistory.append((timestamp: Date(), count: featureCount, density: density))
        
        // Keep only recent history (last 100)
        if featureHistory.count > 100 {
            featureHistory.removeFirst()
        }
        
        return RichnessResult(
            richnessScore: richnessScore,
            featureCount: featureCount,
            density: density,
            normalizedDensity: normalizedDensity
        )
    }
    
    // MARK: - Result Types
    
    /// Richness result
    public struct RichnessResult: Sendable {
        public let richnessScore: Double
        public let featureCount: Int
        public let density: Double
        public let normalizedDensity: Double
    }
}
