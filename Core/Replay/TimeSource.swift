//
// TimeSource.swift
// Aether3D
//
// Time Source Protocol - Async time source abstraction
// 符合 Phase 4: Deterministic Replay Engine (Async TimeSource Protocol Migration)
//

import Foundation

/// Time Source Protocol
///
/// Protocol for time sources (deterministic or system).
/// 符合 Phase 4: Async TimeSource Protocol Migration
public protocol TimeSource: Sendable {
    /// Get current time in milliseconds
    /// 
    /// - Returns: Current time in milliseconds
    func nowMs() async -> Int64
}

/// Mock Time Source
///
/// Deterministic time source using DeterministicScheduler.
public struct MockTimeSource: TimeSource {
    private let scheduler: DeterministicScheduler
    
    /// Initialize Mock Time Source
    /// 
    /// - Parameter scheduler: Deterministic scheduler
    public init(scheduler: DeterministicScheduler) {
        self.scheduler = scheduler
    }
    
    /// Get current time in milliseconds
    public func nowMs() async -> Int64 {
        let timeNs = await scheduler.getCurrentTimeNs()
        return Int64(timeNs / 1_000_000)
    }
}

/// System Time Source
///
/// System time source using monotonic clock.
public struct SystemTimeSource: TimeSource {
    /// Initialize System Time Source
    public init() {}
    
    /// Get current time in milliseconds
    public func nowMs() async -> Int64 {
        // Use MonotonicClock for system time
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// Time Source Errors
public enum TimeSourceError: Error, Sendable {
    case schedulerNotAvailable
    case timeRetrievalFailed(String)
    
    public var localizedDescription: String {
        switch self {
        case .schedulerNotAvailable:
            return "Scheduler not available"
        case .timeRetrievalFailed(let reason):
            return "Time retrieval failed: \(reason)"
        }
    }
}
