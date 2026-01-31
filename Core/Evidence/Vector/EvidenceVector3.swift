//
// EvidenceVector3.swift
// Aether3D
//
// PR3 - Cross-Platform 3D Vector Abstraction
// No simd import - pure Swift implementation
//

import Foundation

/// Cross-platform 3D vector struct
///
/// DESIGN:
/// - Pure Swift implementation (no simd)
/// - Deterministic normalization
/// - Cross-platform compatible
///
/// RULE: Core/Evidence/ must NOT import simd
public struct EvidenceVector3: Codable, Sendable, Equatable {

    /// X component
    public var x: Double

    /// Y component
    public var y: Double

    /// Z component
    public var z: Double

    /// Initialize with components
    ///
    /// - Parameters:
    ///   - x: X component
    ///   - y: Y component
    ///   - z: Z component
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// Zero vector
    public static let zero = EvidenceVector3(x: 0, y: 0, z: 0)

    /// Initialize from array
    ///
    /// - Parameter array: Array of 3 Double values [x, y, z]
    public init(array: [Double]) {
        guard array.count >= 3 else {
            self = .zero
            return
        }
        self.x = array[0]
        self.y = array[1]
        self.z = array[2]
    }

    /// Convert to array
    public var array: [Double] {
        return [x, y, z]
    }

    /// Vector subtraction
    ///
    /// - Parameters:
    ///   - lhs: Left-hand side vector
    ///   - rhs: Right-hand side vector
    /// - Returns: Difference vector
    public static func - (lhs: EvidenceVector3, rhs: EvidenceVector3) -> EvidenceVector3 {
        return EvidenceVector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    /// Vector length
    ///
    /// - Returns: Length of vector
    @inlinable
    public func length() -> Double {
        return sqrt(x * x + y * y + z * z)
    }

    /// Normalized vector
    ///
    /// DETERMINISM: If length is 0 or non-finite, returns .zero
    ///
    /// - Returns: Normalized vector (unit length)
    @inlinable
    public func normalized() -> EvidenceVector3 {
        let len = length()
        guard len.isFinite && len > 1e-10 else {
            return .zero
        }
        return EvidenceVector3(x: x / len, y: y / len, z: z / len)
    }

    /// Check if vector is finite
    ///
    /// - Returns: true if all components are finite
    @inlinable
    public func isFinite() -> Bool {
        return x.isFinite && y.isFinite && z.isFinite
    }
}
