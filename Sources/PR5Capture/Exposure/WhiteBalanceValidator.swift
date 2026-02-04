//
// WhiteBalanceValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 6 + H: 曝光和颜色一致性
// 白平衡验证，色温一致性检查
//

import Foundation

/// White balance validator
///
/// Validates white balance consistency.
/// Checks color temperature consistency.
public actor WhiteBalanceValidator {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// White balance history
    private var wbHistory: [(timestamp: Date, r: Double, g: Double, b: Double)] = []
    
    /// Validation results
    private var validationResults: [(timestamp: Date, isValid: Bool)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Validation
    
    /// Validate white balance
    ///
    /// Checks if white balance is consistent
    public func validateWhiteBalance(r: Double, g: Double, b: Double) -> ValidationResult {
        wbHistory.append((timestamp: Date(), r: r, g: g, b: b))
        
        // Keep only recent history (last 50)
        if wbHistory.count > 50 {
            wbHistory.removeFirst()
        }
        
        guard wbHistory.count >= 3 else {
            return ValidationResult(
                isValid: true,
                consistencyScore: 1.0,
                sampleCount: wbHistory.count,
                deviation: 0.0
            )
        }
        
        // Compute average white balance
        let avgR = wbHistory.map { $0.r }.reduce(0.0, +) / Double(wbHistory.count)
        let avgG = wbHistory.map { $0.g }.reduce(0.0, +) / Double(wbHistory.count)
        let avgB = wbHistory.map { $0.b }.reduce(0.0, +) / Double(wbHistory.count)
        
        // Compute deviation
        let deviationR = abs(r - avgR)
        let deviationG = abs(g - avgG)
        let deviationB = abs(b - avgB)
        
        let maxDeviation = max(deviationR, deviationG, deviationB)
        
        // Check consistency (threshold: 0.1)
        let isValid = maxDeviation < 0.1
        let consistencyScore = 1.0 - min(1.0, maxDeviation)
        
        // Record validation
        validationResults.append((timestamp: Date(), isValid: isValid))
        
        // Keep only recent results (last 50)
        if validationResults.count > 50 {
            validationResults.removeFirst()
        }
        
        return ValidationResult(
            isValid: isValid,
            consistencyScore: consistencyScore,
            sampleCount: wbHistory.count,
            deviation: maxDeviation
        )
    }
    
    // MARK: - Result Types
    
    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let consistencyScore: Double
        public let sampleCount: Int
        public let deviation: Double
    }
}
