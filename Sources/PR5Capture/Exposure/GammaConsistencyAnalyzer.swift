// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GammaConsistencyAnalyzer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 6 + H: 曝光和颜色一致性
// 伽马一致性分析，色调曲线验证
//

import Foundation

/// Gamma consistency analyzer
///
/// Analyzes gamma consistency and validates tone curves.
/// Ensures consistent gamma correction.
public actor GammaConsistencyAnalyzer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Gamma history
    private var gammaHistory: [(timestamp: Date, gamma: Double)] = []
    
    /// Consistency scores
    private var consistencyScores: [Double] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Gamma Analysis
    
    /// Analyze gamma consistency
    ///
    /// Validates gamma correction consistency
    public func analyzeGamma(_ gamma: Double) -> GammaAnalysisResult {
        gammaHistory.append((timestamp: Date(), gamma: gamma))
        
        // Keep only recent history (last 50)
        if gammaHistory.count > 50 {
            gammaHistory.removeFirst()
        }
        
        guard gammaHistory.count >= 3 else {
            let mean = gammaHistory.isEmpty ? gamma : gammaHistory.map { $0.gamma }.reduce(0.0, +) / Double(gammaHistory.count)
            let variance = gammaHistory.isEmpty ? 0.0 : gammaHistory.map { pow($0.gamma - mean, 2) }.reduce(0.0, +) / Double(gammaHistory.count)
            let stdDev = sqrt(variance)
            return GammaAnalysisResult(
                isConsistent: true,
                consistencyScore: 1.0,
                gamma: gamma,
                sampleCount: gammaHistory.count,
                mean: mean,
                stdDev: stdDev
            )
        }
        
        // Compute statistics
        let gammas = gammaHistory.map { $0.gamma }
        let mean = gammas.reduce(0.0, +) / Double(gammas.count)
        let variance = gammas.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(gammas.count)
        let stdDev = sqrt(variance)
        
        // Check consistency (threshold: std dev < 0.05)
        let isConsistent = stdDev < 0.05
        let consistencyScore = 1.0 - min(1.0, stdDev / 0.1)
        
        consistencyScores.append(consistencyScore)
        
        // Keep only recent scores (last 50)
        if consistencyScores.count > 50 {
            consistencyScores.removeFirst()
        }
        
        return GammaAnalysisResult(
            isConsistent: isConsistent,
            consistencyScore: consistencyScore,
            gamma: gamma,
            sampleCount: gammaHistory.count,
            mean: mean,
            stdDev: stdDev
        )
    }
    
    // MARK: - Result Types
    
    /// Gamma analysis result
    public struct GammaAnalysisResult: Sendable {
        public let isConsistent: Bool
        public let consistencyScore: Double
        public let gamma: Double
        public let sampleCount: Int
        public let mean: Double
        public let stdDev: Double
    }
}
