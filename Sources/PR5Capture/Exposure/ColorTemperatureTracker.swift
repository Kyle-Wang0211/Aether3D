//
// ColorTemperatureTracker.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 6 + H: 曝光和颜色一致性
// 色温追踪，白平衡监控，色温稳定性
//

import Foundation

/// Color temperature tracker
///
/// Tracks color temperature and monitors white balance.
/// Validates color temperature stability.
public actor ColorTemperatureTracker {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Color temperature history
    private var temperatureHistory: [(timestamp: Date, temperature: Double)] = []
    
    /// Stability scores
    private var stabilityScores: [Double] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Temperature Tracking
    
    /// Track color temperature
    ///
    /// Monitors color temperature and computes stability
    public func trackTemperature(_ temperature: Double) -> TemperatureTrackingResult {
        temperatureHistory.append((timestamp: Date(), temperature: temperature))
        
        // Keep only recent history (last 50)
        if temperatureHistory.count > 50 {
            temperatureHistory.removeFirst()
        }
        
        guard temperatureHistory.count >= 3 else {
            let mean = temperatureHistory.isEmpty ? temperature : temperatureHistory.map { $0.temperature }.reduce(0.0, +) / Double(temperatureHistory.count)
            let variance = temperatureHistory.isEmpty ? 0.0 : temperatureHistory.map { pow($0.temperature - mean, 2) }.reduce(0.0, +) / Double(temperatureHistory.count)
            let stdDev = sqrt(variance)
            return TemperatureTrackingResult(
                temperature: temperature,
                stability: 1.0,
                drift: 0.0,
                sampleCount: temperatureHistory.count,
                mean: mean,
                stdDev: stdDev
            )
        }
        
        // Compute statistics
        let temperatures = temperatureHistory.map { $0.temperature }
        let mean = temperatures.reduce(0.0, +) / Double(temperatures.count)
        let variance = temperatures.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(temperatures.count)
        let stdDev = sqrt(variance)
        
        // Compute drift
        let drift = abs(temperature - mean)
        
        // Compute stability (inverse of normalized std dev)
        let normalizedStdDev = stdDev / max(mean, 1.0)
        let stability = 1.0 / (1.0 + normalizedStdDev * 10.0)
        
        stabilityScores.append(stability)
        
        // Keep only recent scores (last 50)
        if stabilityScores.count > 50 {
            stabilityScores.removeFirst()
        }
        
        return TemperatureTrackingResult(
            temperature: temperature,
            stability: stability,
            drift: drift,
            sampleCount: temperatureHistory.count,
            mean: mean,
            stdDev: stdDev
        )
    }
    
    // MARK: - Result Types
    
    /// Temperature tracking result
    public struct TemperatureTrackingResult: Sendable {
        public let temperature: Double
        public let stability: Double
        public let drift: Double
        public let sampleCount: Int
        public let mean: Double
        public let stdDev: Double
    }
}
