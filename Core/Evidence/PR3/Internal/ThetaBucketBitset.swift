//
// ThetaBucketBitset.swift
// Aether3D
//
// PR3 - Theta Bucket Bitset (24 bits in UInt32)
// O(1) operations, zero allocation, zero edge cases
//

import Foundation

/// Theta Bucket Bitset: 24 bits in UInt32
///
/// BIT LAYOUT:
/// - Bit 0: bucket 0 (0° - 15°)
/// - Bit 1: bucket 1 (15° - 30°)
/// - ...
/// - Bit 23: bucket 23 (345° - 360°)
/// - Bits 24-31: unused (always 0)
///
/// INVARIANT: bits & 0xFF000000 == 0 (upper 8 bits always zero)
public struct ThetaBucketBitset: Equatable, Sendable, Codable {

    /// The bitset value
    @usableFromInline
    internal var bits: UInt32 = 0

    /// Mask for valid bits (lower 24 bits)
    @usableFromInline
    internal static let validMask: UInt32 = 0x00FFFFFF

    /// Number of buckets
    public static let bucketCount: Int = 24

    /// Initialize empty
    public init() {}

    /// Initialize from raw bits (for deserialization)
    ///
    /// - Parameter rawBits: Raw UInt32 value
    public init(rawBits: UInt32) {
        self.bits = rawBits & Self.validMask
    }

    /// Insert bucket index
    ///
    /// PRECONDITION: index ∈ [0, 23]
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
    public var count: Int {
        return bits.nonzeroBitCount
    }

    /// Check if empty
    public var isEmpty: Bool {
        return bits == 0
    }

    /// Clear all buckets
    @inlinable
    public mutating func clear() {
        bits = 0
    }

    /// Raw bits (for serialization)
    public var rawBits: UInt32 { bits }

    /// Iterate over filled bucket indices in ascending order
    ///
    /// DETERMINISM: Always iterates in ascending order (0, 1, 2, ...)
    ///
    /// - Parameter body: Closure called for each filled bucket index
    @inlinable
    public func forEachBucket(_ body: (Int) -> Void) {
        var remaining = bits
        var index = 0
        while remaining != 0 {
            if (remaining & 1) != 0 {
                body(index)
            }
            remaining >>= 1
            index += 1
        }
    }
}
