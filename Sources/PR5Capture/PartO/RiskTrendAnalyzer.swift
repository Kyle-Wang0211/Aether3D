//
// RiskTrendAnalyzer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART O: 风险注册和治理
// 风险趋势分析，历史数据追踪
//

import Foundation

/// Risk trend analyzer
///
/// Analyzes risk trends with historical data tracking.
/// Provides risk evolution insights.
public actor RiskTrendAnalyzer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Risk history
    private var riskHistory: [(timestamp: Date, p0: Int, p1: Int, p2: Int, p3: Int)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Trend Analysis
    
    /// Analyze risk trend
    public func analyzeTrend(risks: [RiskRegisterImplementation.RiskEntry]) -> TrendResult {
        let p0Count = risks.filter { $0.severity == .p0 }.count
        let p1Count = risks.filter { $0.severity == .p1 }.count
        let p2Count = risks.filter { $0.severity == .p2 }.count
        let p3Count = risks.filter { $0.severity == .p3 }.count
        
        // Record history
        riskHistory.append((timestamp: Date(), p0: p0Count, p1: p1Count, p2: p2Count, p3: p3Count))
        
        // Keep only recent history (last 100)
        if riskHistory.count > 100 {
            riskHistory.removeFirst()
        }
        
        // Compute trend
        let trend = computeTrend()
        
        return TrendResult(
            current: (p0: p0Count, p1: p1Count, p2: p2Count, p3: p3Count),
            trend: trend,
            timestamp: Date()
        )
    }
    
    /// Compute trend
    private func computeTrend() -> Trend {
        guard riskHistory.count >= 2 else { return .stable }
        
        let recent = Array(riskHistory.suffix(5))
        let first = recent.first!
        let last = recent.last!
        
        let totalFirst = first.p0 + first.p1 + first.p2 + first.p3
        let totalLast = last.p0 + last.p1 + last.p2 + last.p3
        
        let delta = totalLast - totalFirst
        
        if delta > 5 {
            return .increasing
        } else if delta < -5 {
            return .decreasing
        } else {
            return .stable
        }
    }
    
    // MARK: - Result Types
    
    /// Trend
    public enum Trend: String, Sendable {
        case increasing
        case decreasing
        case stable
    }
    
    /// Trend result
    public struct TrendResult: Sendable {
        public let current: (p0: Int, p1: Int, p2: Int, p3: Int)
        public let trend: Trend
        public let timestamp: Date
    }
}
