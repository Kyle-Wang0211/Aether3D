//
// FrameID.swift
// PR4Ownership
//
// PR4 V10 - Unique frame identifier for ownership tracking
// Task 1.5: Foundation module with no dependencies
//

import Foundation

/// Unique frame identifier
public struct FrameID: Hashable, Comparable, CustomStringConvertible, Codable {
    
    private static var counter: UInt64 = 0
    private static let lock = NSLock()
    
    public let value: UInt64
    public let timestamp: Date
    
    /// Create a new unique frame ID
    public static func next() -> FrameID {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return FrameID(value: counter, timestamp: Date())
    }
    
    private init(value: UInt64, timestamp: Date) {
        self.value = value
        self.timestamp = timestamp
    }
    
    // For Codable
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try container.decode(UInt64.self, forKey: .value)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timestamp, forKey: .timestamp)
    }
    
    private enum CodingKeys: String, CodingKey {
        case value, timestamp
    }
    
    public static func < (lhs: FrameID, rhs: FrameID) -> Bool {
        return lhs.value < rhs.value
    }
    
    public var description: String {
        return "Frame(\(value))"
    }
}
