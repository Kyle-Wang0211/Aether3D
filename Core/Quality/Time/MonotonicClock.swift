// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  MonotonicClock.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Monotonic clock implementation (P6/H2)
//  All decision windows must use MonotonicClock, not Date()
//
//  CHANGED (v6.0): Removed Date() fallback - fail-closed on unsupported platforms
//

import Foundation

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// MonotonicClock - monotonic time source for decision windows
///
/// **Rule ID:** P6, H2, INV-D1
/// **Status:** SEALED (v6.0)
///
/// **H2:** All time windows must use MonotonicClock milliseconds, not Date()
/// **H2:** Time windows must be centralized in QualityPreCheckConstants.swift
///
/// **CHANGED (v6.0):** Removed Date() fallback for unsupported platforms.
/// Using wall-clock time for timing windows is a critical bug that can cause
/// non-deterministic behavior when NTP adjusts the clock.
public struct MonotonicClock {

    // MARK: - Supported Platform Check

    /// Check if monotonic clock is available on this platform
    ///
    /// Returns true on macOS, iOS, tvOS, watchOS, and Linux.
    /// Returns false on unsupported platforms.
    public static var isSupported: Bool {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Time Functions

    /// Get current monotonic time in milliseconds
    ///
    /// **Implementation:**
    /// - Apple platforms: mach_continuous_time() (survives sleep)
    /// - Linux: clock_gettime(CLOCK_MONOTONIC)
    ///
    /// **CHANGED (v6.0):** No longer falls back to Date() on unsupported platforms.
    /// Instead, triggers a precondition failure to catch platform issues at runtime.
    ///
    /// **Note:** mach_continuous_time returns ticks, not nanoseconds directly.
    /// We need to convert using mach_timebase_info.
    public static func nowMs() -> Int64 {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        // Use mach_continuous_time for monotonic time on Apple platforms
        // This survives system sleep, unlike mach_absolute_time
        let time = mach_continuous_time()

        // Get timebase info for conversion
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)

        // Convert to nanoseconds, then to milliseconds
        let nanoseconds = time * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        return Int64(nanoseconds / 1_000_000)

        #elseif os(Linux)
        // Use clock_gettime(CLOCK_MONOTONIC) on Linux
        // Linux requires explicit initialization of timespec
        var ts = timespec(tv_sec: 0, tv_nsec: 0)
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000

        #else
        // FAIL-CLOSED (v6.0): Do not fall back to Date()
        // Using wall-clock time for timing windows causes critical bugs
        preconditionFailure("""
            MonotonicClock is not supported on this platform.
            Supported platforms: macOS, iOS, tvOS, watchOS, Linux.
            Using Date() as fallback is forbidden because wall-clock time
            can jump backwards (NTP sync, DST, manual adjustment).
            """)
        #endif
    }

    /// Get current monotonic time in nanoseconds
    ///
    /// Higher precision variant for microsecond-level timing.
    public static func nowNs() -> Int64 {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        let time = mach_continuous_time()
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        let nanoseconds = time * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        return Int64(nanoseconds)

        #elseif os(Linux)
        var ts = timespec(tv_sec: 0, tv_nsec: 0)
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)

        #else
        preconditionFailure("MonotonicClock is not supported on this platform")
        #endif
    }

    /// Get current monotonic time in seconds (Double)
    ///
    /// Convenience method for APIs that expect TimeInterval.
    public static func nowSeconds() -> Double {
        return Double(nowMs()) / 1000.0
    }

    // MARK: - Duration Calculation

    /// Calculate elapsed milliseconds since a previous timestamp
    ///
    /// - Parameter startMs: Previous monotonic timestamp in milliseconds
    /// - Returns: Elapsed milliseconds (always non-negative)
    public static func elapsedMs(since startMs: Int64) -> Int64 {
        let now = nowMs()
        // Handle potential overflow/wraparound (very rare, but defensive)
        return max(0, now - startMs)
    }

    /// Calculate elapsed nanoseconds since a previous timestamp
    ///
    /// - Parameter startNs: Previous monotonic timestamp in nanoseconds
    /// - Returns: Elapsed nanoseconds (always non-negative)
    public static func elapsedNs(since startNs: Int64) -> Int64 {
        let now = nowNs()
        return max(0, now - startNs)
    }
}
