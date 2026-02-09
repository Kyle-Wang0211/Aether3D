// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CrossPlatformTimestamp.swift
// Aether3D
//
// PR2 Patch V4 - Cross-Platform Timestamp Representation
// Uses Int64 milliseconds for deterministic serialization
//
// CHANGED (v6.0): Separated wall-clock and monotonic time sources
// to prevent misuse of Date() for timing windows.
//

import Foundation

/// Cross-platform timestamp representation
///
/// **Rule ID:** INV-D1, H2
/// **Status:** SEALED (v6.0)
///
/// **DESIGN DECISION:**
/// - Internal: Use TimeInterval (Double) for computation convenience
/// - Serialization: Use Int64 milliseconds for cross-platform consistency
///
/// **RATIONALE:**
/// - Double has ~15 significant digits, but serialization may round differently
/// - Int64 milliseconds has exact representation across all platforms
/// - 1ms precision is sufficient for evidence timing (120ms minimum interval)
///
/// **CHANGED (v6.0):**
/// - Separated `wallClockNow()` and `monotonicNow()` to make time source explicit
/// - Deprecated `now` to prevent accidental misuse
/// - Wall-clock is for display/logging only; monotonic is for timing windows
public struct CrossPlatformTimestamp: Codable, Equatable, Hashable, Comparable, Sendable {

    /// Milliseconds since reference epoch
    public let milliseconds: Int64

    // MARK: - Initializers

    /// Initialize from TimeInterval (seconds since epoch)
    public init(timeInterval: TimeInterval) {
        // Round to nearest millisecond
        self.milliseconds = Int64((timeInterval * 1000.0).rounded())
    }

    /// Initialize from milliseconds
    public init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    // MARK: - Conversions

    /// Convert to TimeInterval (seconds since epoch)
    public var timeInterval: TimeInterval {
        return TimeInterval(milliseconds) / 1000.0
    }

    /// Convert to Date (for display only)
    public var date: Date {
        return Date(timeIntervalSince1970: timeInterval)
    }

    // MARK: - Time Sources

    /// Wall-clock current time (for display/logging ONLY)
    ///
    /// **WARNING:** Do NOT use for timing windows or duration calculations.
    /// Wall-clock time can jump backwards (NTP sync, DST, manual adjustment).
    ///
    /// **Use cases:**
    /// - Display timestamps to users
    /// - Logging and audit records
    /// - Comparing with external timestamps
    ///
    /// **Do NOT use for:**
    /// - Decision windows
    /// - Duration calculations
    /// - Rate limiting
    /// - Timeout detection
    public static func wallClockNow() -> CrossPlatformTimestamp {
        return CrossPlatformTimestamp(timeInterval: Date().timeIntervalSince1970)
    }

    /// Monotonic current time (for timing windows and durations)
    ///
    /// **MUST use for:**
    /// - Decision windows
    /// - Duration calculations
    /// - Rate limiting
    /// - Timeout detection
    ///
    /// **Properties:**
    /// - Never jumps backwards
    /// - Immune to NTP sync, DST, manual adjustment
    /// - Uses mach_continuous_time on Apple, clock_gettime on Linux
    ///
    /// **Note:** Monotonic time is NOT related to wall-clock time.
    /// The epoch is arbitrary (system boot time).
    public static func monotonicNow() -> CrossPlatformTimestamp {
        return CrossPlatformTimestamp(milliseconds: MonotonicClock.nowMs())
    }

    /// Current time (DEPRECATED)
    ///
    /// **DEPRECATED:** Use `wallClockNow()` for display/logging,
    /// or `monotonicNow()` for timing windows.
    ///
    /// This property uses wall-clock time, which can cause bugs
    /// when used for timing windows (NTP jumps, DST changes).
    @available(*, deprecated, message: "Use wallClockNow() for display/logging, monotonicNow() for timing windows")
    public static var now: CrossPlatformTimestamp {
        return wallClockNow()
    }

    /// Zero timestamp
    public static var zero: CrossPlatformTimestamp {
        return CrossPlatformTimestamp(milliseconds: 0)
    }

    // MARK: - Comparable

    public static func < (lhs: CrossPlatformTimestamp, rhs: CrossPlatformTimestamp) -> Bool {
        return lhs.milliseconds < rhs.milliseconds
    }

    // MARK: - Arithmetic

    /// Add milliseconds
    public func adding(milliseconds delta: Int64) -> CrossPlatformTimestamp {
        return CrossPlatformTimestamp(milliseconds: self.milliseconds + delta)
    }

    /// Subtract another timestamp to get duration in milliseconds
    public func millisecondsSince(_ other: CrossPlatformTimestamp) -> Int64 {
        return self.milliseconds - other.milliseconds
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

// MARK: - CustomStringConvertible

extension CrossPlatformTimestamp: CustomStringConvertible {
    public var description: String {
        return "\(milliseconds)ms"
    }
}

// MARK: - ISO8601 Formatting

extension CrossPlatformTimestamp {
    /// Format as ISO8601 string (for audit records)
    ///
    /// **Format:** "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
    /// **Example:** "2026-02-06T12:34:56.789Z"
    public var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
