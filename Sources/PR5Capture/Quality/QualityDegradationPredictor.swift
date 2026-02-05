//
// QualityDegradationPredictor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 3 + E: 质量指标和鲁棒性
// 质量退化预测，趋势分析，预警系统
//

import Foundation

/// Quality degradation predictor
///
/// Predicts quality degradation using trend analysis.
/// Provides early warning system for quality issues.
public actor QualityDegradationPredictor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Quality history
    private var qualityHistory: [(timestamp: Date, quality: Double)] = []
    
    /// Degradation warnings
    private var warnings: [DegradationWarning] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Degradation Prediction
    
    /// Predict quality degradation
    ///
    /// Analyzes trends and predicts future quality
    public func predictDegradation(_ currentQuality: Double) -> DegradationPrediction {
        let now = Date()
        qualityHistory.append((timestamp: now, quality: currentQuality))
        
        // Keep only recent history (last 100)
        if qualityHistory.count > 100 {
            qualityHistory.removeFirst()
        }
        
        guard qualityHistory.count >= 5 else {
            return DegradationPrediction(
                currentQuality: currentQuality,
                predictedQuality: currentQuality,
                trend: .insufficient,
                degradationRisk: 0.0,
                warning: nil
            )
        }
        
        // Analyze trend
        let trend = analyzeTrend()
        
        // Predict future quality (simple linear extrapolation)
        let predictedQuality = predictFutureQuality(trend: trend)
        
        // Calculate degradation risk
        let degradationRisk = calculateDegradationRisk(currentQuality: currentQuality, trend: trend)
        
        // Generate warning if needed
        let warning = generateWarningIfNeeded(risk: degradationRisk, trend: trend)
        
        return DegradationPrediction(
            currentQuality: currentQuality,
            predictedQuality: predictedQuality,
            trend: trend,
            degradationRisk: degradationRisk,
            warning: warning
        )
    }
    
    /// Analyze trend
    private func analyzeTrend() -> Trend {
        guard qualityHistory.count >= 3 else { return .insufficient }
        
        let recent = Array(qualityHistory.suffix(5))
        let qualities = recent.map { $0.quality }
        
        // Simple linear trend
        let firstHalf = Array(qualities.prefix(qualities.count / 2))
        let secondHalf = Array(qualities.suffix(qualities.count / 2))
        
        let firstAvg = firstHalf.reduce(0.0, +) / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0.0, +) / Double(secondHalf.count)
        
        let delta = secondAvg - firstAvg
        let threshold = 0.05
        
        if delta > threshold {
            return .improving
        } else if delta < -threshold {
            return .degrading
        } else {
            return .stable
        }
    }
    
    /// Predict future quality
    private func predictFutureQuality(trend: Trend) -> Double {
        guard !qualityHistory.isEmpty else { return 0.5 }
        
        let recent = Array(qualityHistory.suffix(5))
        let qualities = recent.map { $0.quality }
        let currentAvg = qualities.reduce(0.0, +) / Double(qualities.count)
        
        switch trend {
        case .improving:
            return min(1.0, currentAvg + 0.1)
        case .degrading:
            return max(0.0, currentAvg - 0.1)
        case .stable, .insufficient:
            return currentAvg
        }
    }
    
    /// Calculate degradation risk
    private func calculateDegradationRisk(currentQuality: Double, trend: Trend) -> Double {
        var risk = 0.0
        
        // Base risk from current quality
        risk += (1.0 - currentQuality) * 0.5
        
        // Risk from trend
        switch trend {
        case .degrading:
            risk += 0.4
        case .stable:
            risk += 0.1
        case .improving, .insufficient:
            break
        }
        
        return min(1.0, risk)
    }
    
    /// Generate warning if needed
    private func generateWarningIfNeeded(risk: Double, trend: Trend) -> DegradationWarning? {
        // Use config-based threshold (default 0.6)
        let threshold = 0.6
        
        if risk >= threshold {
            let warning = DegradationWarning(
                timestamp: Date(),
                risk: risk,
                trend: trend,
                severity: risk >= 0.7 ? .high : .medium
            )
            
            warnings.append(warning)
            
            // Keep only recent warnings (last 50)
            if warnings.count > 50 {
                warnings.removeFirst()
            }
            
            return warning
        }
        
        return nil
    }
    
    // MARK: - Queries
    
    /// Get degradation warnings
    public func getWarnings() -> [DegradationWarning] {
        return warnings
    }
    
    // MARK: - Data Types
    
    /// Trend
    public enum Trend: String, Sendable {
        case improving
        case stable
        case degrading
        case insufficient
    }
    
    /// Degradation prediction
    public struct DegradationPrediction: Sendable {
        public let currentQuality: Double
        public let predictedQuality: Double
        public let trend: Trend
        public let degradationRisk: Double
        public let warning: DegradationWarning?
    }
    
    /// Degradation warning
    public struct DegradationWarning: Sendable {
        public let timestamp: Date
        public let risk: Double
        public let trend: Trend
        public let severity: Severity
        
        public enum Severity: String, Sendable {
            case low
            case medium
            case high
        }
    }
}
