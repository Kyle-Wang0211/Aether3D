//
// CrossPlatformNormalizer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART K: 跨平台确定性
// 跨平台数值归一化，消除浮点差异
//

import Foundation

/// Cross-platform normalizer
///
/// Normalizes values across platforms to eliminate floating-point differences.
/// Ensures consistent results across iOS/macOS/visionOS.
public actor CrossPlatformNormalizer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Normalization Precision
    
    /// Normalization precision (decimal places)
    private let precision: Int = 6
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Normalization
    
    /// Normalize floating-point value
    ///
    /// Rounds to specified precision to eliminate platform differences
    public func normalize(_ value: Double) -> Double {
        let multiplier = pow(10.0, Double(precision))
        return round(value * multiplier) / multiplier
    }
    
    /// Normalize array of values
    public func normalize(_ values: [Double]) -> [Double] {
        return values.map { normalize($0) }
    }
    
    /// Normalize SIMD vector
    public func normalize(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        return SIMD3<Double>(
            normalize(vector.x),
            normalize(vector.y),
            normalize(vector.z)
        )
    }
    
    /// Compare normalized values
    ///
    /// Compares values after normalization
    public func areEqual(_ a: Double, _ b: Double) -> Bool {
        return normalize(a) == normalize(b)
    }
    
    /// Compare with tolerance
    public func areEqual(_ a: Double, _ b: Double, tolerance: Double) -> Bool {
        return abs(normalize(a) - normalize(b)) <= tolerance
    }
}
