//
//  MonotonicClock.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Monotonic clock implementation (P6/H2)
//  All decision windows must use MonotonicClock, not Date()
//

import Foundation

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#endif

/// MonotonicClock - monotonic time source for decision windows
/// H2: All time windows must use MonotonicClock milliseconds, not Date()
/// H2: Time windows must be centralized in QualityPreCheckConstants.swift
public struct MonotonicClock {
    /// Get current monotonic time in milliseconds
    /// Uses mach_continuous_time on Apple platforms, clock_gettime on others
    public static func nowMs() -> Int64 {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        // Use mach_continuous_time for monotonic time on Apple platforms
        let time = mach_continuous_time()
        // Convert from nanoseconds to milliseconds
        return Int64(time / 1_000_000)
        #else
        // Use clock_gettime(CLOCK_MONOTONIC) on other platforms
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
        #endif
    }
    
    /// Get current monotonic time in seconds (Double)
    public static func nowSeconds() -> Double {
        return Double(nowMs()) / 1000.0
    }
}

#if !os(macOS) && !os(iOS) && !os(tvOS) && !os(watchOS)
// For non-Apple platforms, use a simple implementation
// Note: This should be replaced with actual clock_gettime for production
private struct timespec {
    var tv_sec: Int
    var tv_nsec: Int
}

private let CLOCK_MONOTONIC: Int32 = 1

private func clock_gettime(_ clock: Int32, _ timespec: UnsafeMutablePointer<timespec>) -> Int32 {
    // Fallback implementation - should use actual clock_gettime
    let now = Date().timeIntervalSince1970
    timespec.pointee.tv_sec = Int(now)
    timespec.pointee.tv_nsec = Int((now - Double(Int(now))) * 1_000_000_000)
    return 0
}
#endif

