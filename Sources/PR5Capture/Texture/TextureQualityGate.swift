//
// TextureQualityGate.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 5 + G: 纹理响应和闭环
// 纹理质量门，质量阈值检查，纹理评估
//

import Foundation

/// Texture quality gate
///
/// Gates frames based on texture quality thresholds.
/// Evaluates texture quality for acceptance.
public actor TextureQualityGate {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Quality threshold
    private var qualityThreshold: Double = 0.7
    
    /// Gate history
    private var gateHistory: [(timestamp: Date, passed: Bool, quality: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Quality Gating
    
    /// Evaluate texture quality gate
    ///
    /// Checks if texture quality meets threshold
    public func evaluateGate(textureQuality: Double) -> GateResult {
        let passed = textureQuality >= qualityThreshold
        
        // Record gate decision
        gateHistory.append((timestamp: Date(), passed: passed, quality: textureQuality))
        
        // Keep only recent history (last 100)
        if gateHistory.count > 100 {
            gateHistory.removeFirst()
        }
        
        return GateResult(
            passed: passed,
            quality: textureQuality,
            threshold: qualityThreshold
        )
    }
    
    /// Set quality threshold
    public func setThreshold(_ threshold: Double) {
        qualityThreshold = max(0.0, min(1.0, threshold))
    }
    
    /// Get threshold
    public func getThreshold() -> Double {
        return qualityThreshold
    }
    
    // MARK: - Result Types
    
    /// Gate result
    public struct GateResult: Sendable {
        public let passed: Bool
        public let quality: Double
        public let threshold: Double
    }
}
