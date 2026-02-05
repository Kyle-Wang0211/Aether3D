//
// RiskScoreCalculator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART O: 风险注册和治理
// 风险评分计算，CVSS风格评分
//

import Foundation

/// Risk score calculator
///
/// Calculates risk scores using CVSS-style scoring.
/// Provides quantitative risk assessment.
public actor RiskScoreCalculator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Risk scores
    private var scores: [String: RiskScore] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Score Calculation
    
    /// Calculate risk score
    public func calculateScore(
        severity: RiskRegisterImplementation.RiskSeverity,
        exploitability: Double,
        impact: Double
    ) -> RiskScore {
        // CVSS-style calculation
        let baseScore = (exploitability * 0.4) + (impact * 0.6)
        
        // Adjust by severity
        let severityMultiplier: Double
        switch severity {
        case .p0:
            severityMultiplier = 1.0
        case .p1:
            severityMultiplier = 0.75
        case .p2:
            severityMultiplier = 0.5
        case .p3:
            severityMultiplier = 0.25
        }
        
        let finalScore = baseScore * severityMultiplier
        
        let score = RiskScore(
            baseScore: baseScore,
            finalScore: finalScore,
            exploitability: exploitability,
            impact: impact,
            severity: severity
        )
        
        return score
    }
    
    // MARK: - Data Types
    
    /// Risk score
    public struct RiskScore: Sendable {
        public let baseScore: Double
        public let finalScore: Double
        public let exploitability: Double
        public let impact: Double
        public let severity: RiskRegisterImplementation.RiskSeverity
    }
}
