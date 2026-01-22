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
#elseif os(Linux)
import Glibc
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
        #elseif os(Linux)
        // Use clock_gettime(CLOCK_MONOTONIC) on Linux
        // Linux requires explicit initialization of timespec
        var ts = timespec(tv_sec: 0, tv_nsec: 0)
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
        #else
        // Fallback for other platforms (should not be used in production)
        let now = Date().timeIntervalSince1970
        return Int64(now * 1000)
        #endif
    }
    
    /// Get current monotonic time in seconds (Double)
    public static func nowSeconds() -> Double {
        return Double(nowMs()) / 1000.0
    }
}


