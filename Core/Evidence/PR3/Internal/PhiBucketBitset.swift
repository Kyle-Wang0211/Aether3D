//
// PhiBucketBitset.swift
// Aether3D
//
// PR3 - Phi Bucket Bitset (12 bits in UInt16)
// O(1) operations, zero allocation, zero edge cases
//

import Foundation

/// Phi Bucket Bitset: 12 bits in UInt16
///
/// BIT LAYOUT:
/// - Bit 0: bucket 0 (-90° to -75°)
/// - Bit 1: bucket 1 (-75° to -60°)
/// - ...
/// - Bit 11: bucket 11 (75° to 90°)
/// - Bits 12-15: unused (always 0)
public struct PhiBucketBitset: Equatable, Sendable, Codable {

    @usableFromInline
    internal var bits: UInt16 = 0

    @usableFromInline
    internal static let validMask: UInt16 = 0x0FFF

    public static let bucketCount: Int = 12

    /// Initialize empty
    public init() {}

    /// Initialize from raw bits (for deserialization)
    ///
    /// - Parameter rawBits: Raw UInt16 value
    public init(rawBits: UInt16) {
        self.bits = rawBits & Self.validMask
    }

    /// Insert bucket index
    ///
    /// PRECONDITION: index ∈ [0, 11]
    /// TIME: O(1)
    ///
    /// - Parameter index: Bucket index to insert
    @inlinable
    public mutating func insert(_ index: Int) {
        guard index >= 0 && index < Self.bucketCount else { return }
        bits |= (1 << index)
    }

    /// Check if bucket is present
    ///
    /// TIME: O(1)
    ///
    /// - Parameter index: Bucket index to check
    /// - Returns: true if bucket is present
    @inlinable
    public func contains(_ index: Int) -> Bool {
        guard index >= 0 && index < Self.bucketCount else { return false }
        return (bits & (1 << index)) != 0
    }

    /// Count of filled buckets
    ///
    /// TIME: O(1) using popcount intrinsic
    @inlinable
    public var count: Int {
        return bits.nonzeroBitCount
    }

    /// Check if empty
    @inlinable
    public var isEmpty: Bool {
        return bits == 0
    }

    /// Clear all buckets
    @inlinable
    public mutating func clear() {
        bits = 0
    }

    /// Raw bits (for serialization)
    public var rawBits: UInt16 { bits }
}
