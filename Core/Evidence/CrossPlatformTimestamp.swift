//
// CrossPlatformTimestamp.swift
// Aether3D
//
// PR2 Patch V4 - Cross-Platform Timestamp Representation
// Uses Int64 milliseconds for deterministic serialization
//

import Foundation

/// Cross-platform timestamp representation
///
/// DESIGN DECISION:
/// - Internal: Use TimeInterval (Double) for computation convenience
/// - Serialization: Use Int64 milliseconds for cross-platform consistency
///
/// RATIONALE:
/// - Double has ~15 significant digits, but serialization may round differently
/// - Int64 milliseconds has exact representation across all platforms
/// - 1ms precision is sufficient for evidence timing (120ms minimum interval)
public struct CrossPlatformTimestamp: Codable, Equatable, Hashable, Comparable, Sendable {
    
    /// Milliseconds since reference epoch
    public let milliseconds: Int64
    
    /// Initialize from TimeInterval
    public init(timeInterval: TimeInterval) {
        // Round to nearest millisecond
        self.milliseconds = Int64((timeInterval * 1000.0).rounded())
    }
    
    /// Initialize from milliseconds
    public init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }
    
    /// Convert to TimeInterval
    public var timeInterval: TimeInterval {
        return TimeInterval(milliseconds) / 1000.0
    }
    
    /// Current time
    public static var now: CrossPlatformTimestamp {
        return CrossPlatformTimestamp(timeInterval: Date().timeIntervalSince1970)
    }
    
    /// Zero timestamp
    public static var zero: CrossPlatformTimestamp {
        return CrossPlatformTimestamp(milliseconds: 0)
    }
    
    // MARK: - Comparable
    
    public static func < (lhs: CrossPlatformTimestamp, rhs: CrossPlatformTimestamp) -> Bool {
        return lhs.milliseconds < rhs.milliseconds
    }
    
    // MARK: - Codable
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.milliseconds = try container.decode(Int64.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(milliseconds)
    }
}

extension CrossPlatformTimestamp: CustomStringConvertible {
    public var description: String {
        return "\(milliseconds)ms"
    }
}
