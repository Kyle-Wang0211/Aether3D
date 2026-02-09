// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeterministicScheduler.swift
// Aether3D
//
// Deterministic Scheduler - Deterministic Simulation Testing (DST) with Xoshiro256** PRNG
// 符合 Phase 4: Deterministic Replay Engine
//

import Foundation

/// Task Handle
///
/// Handle for scheduled task.
public struct TaskHandle: Sendable {
    public let id: UInt64
    
    public init(id: UInt64) {
        self.id = id
    }
}

/// Scheduled Task
private struct ScheduledTask: Sendable {
    let handle: TaskHandle
    let scheduledTime: UInt64
    let task: @Sendable () async throws -> Void
    
    init(handle: TaskHandle, scheduledTime: UInt64, task: @escaping @Sendable () async throws -> Void) {
        self.handle = handle
        self.scheduledTime = scheduledTime
        self.task = task
    }
}

/// Deterministic Scheduler
///
/// Implements deterministic task scheduling with Xoshiro256** PRNG.
/// 符合 Phase 4: Deterministic Replay Engine
public actor DeterministicScheduler {
    
    // MARK: - State
    
    private var currentTimeNs: UInt64 = 0
    private let seed: UInt64
    private var prng: Xoshiro256StarStar
    private var scheduledTasks: [ScheduledTask] = []
    private var nextTaskId: UInt64 = 1
    
    // MARK: - Initialization
    
    /// Initialize Deterministic Scheduler
    /// 
    /// - Parameter seed: PRNG seed (if 0, use 1)
    public init(seed: UInt64) {
        let actualSeed = seed == 0 ? 1 : seed
        self.seed = actualSeed
        
        // Initialize Xoshiro256** state using SplitMix64
        var splitMix = SplitMix64(seed: actualSeed)
        let state = Xoshiro256State(
            state0: splitMix.next(),
            state1: splitMix.next(),
            state2: splitMix.next(),
            state3: splitMix.next()
        )
        self.prng = Xoshiro256StarStar(state: state)
    }
    
    // MARK: - Time Management
    
    /// Get current virtual time (nanoseconds)
    public func getCurrentTimeNs() -> UInt64 {
        return currentTimeNs
    }
    
    /// Advance time and execute scheduled tasks
    /// 
    /// - Parameter nanoseconds: Nanoseconds to advance
    public func advance(by nanoseconds: UInt64) async throws {
        currentTimeNs += nanoseconds
        
        // Execute all tasks scheduled <= currentTimeNs
        while let task = scheduledTasks.first, task.scheduledTime <= currentTimeNs {
            scheduledTasks.removeFirst()
            try await task.task()
        }
    }
    
    /// Run until all tasks are executed
    public func runUntilIdle() async throws {
        while !scheduledTasks.isEmpty {
            let nextTask = scheduledTasks.first!
            currentTimeNs = nextTask.scheduledTime
            scheduledTasks.removeFirst()
            try await nextTask.task()
        }
    }
    
    // MARK: - Task Scheduling
    
    /// Schedule task at given time
    /// 
    /// - Parameters:
    ///   - timeNs: Scheduled time (nanoseconds)
    ///   - task: Task to execute
    /// - Returns: Task handle
    public func schedule(at timeNs: UInt64, task: @escaping @Sendable () async throws -> Void) -> TaskHandle {
        let handle = TaskHandle(id: nextTaskId)
        nextTaskId += 1
        
        let scheduledTask = ScheduledTask(handle: handle, scheduledTime: timeNs, task: task)
        scheduledTasks.append(scheduledTask)
        
        // Sort by scheduled time, then by task ID
        scheduledTasks.sort { (a, b) in
            if a.scheduledTime != b.scheduledTime {
                return a.scheduledTime < b.scheduledTime
            }
            return a.handle.id < b.handle.id
        }
        
        return handle
    }
    
    // MARK: - Random Number Generation
    
    /// Generate random UInt64
    /// 
    /// - Returns: Random number
    public func random() -> UInt64 {
        return prng.next()
    }
    
    /// Generate random number in range
    /// 
    /// - Parameter range: Range (inclusive)
    /// - Returns: Random number in range
    public func random(in range: ClosedRange<UInt64>) -> UInt64 {
        let size = range.upperBound - range.lowerBound + 1
        return range.lowerBound + (prng.next() % size)
    }
}

/// SplitMix64 PRNG
///
/// Used for seeding Xoshiro256**.
struct SplitMix64 {
    private var state: UInt64
    
    init(seed: UInt64) {
        self.state = seed
    }
    
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

/// Xoshiro256** State
struct Xoshiro256State: Sendable {
    var state0: UInt64
    var state1: UInt64
    var state2: UInt64
    var state3: UInt64
}

/// Xoshiro256** PRNG
///
/// High-quality PRNG for deterministic randomness.
struct Xoshiro256StarStar {
    private var state: Xoshiro256State
    
    init(state: Xoshiro256State) {
        self.state = state
    }
    
    mutating func next() -> UInt64 {
        let result = rotl(state.state1 &* 5, 7) &* 9
        let t = state.state1 << 17
        
        state.state2 ^= state.state0
        state.state3 ^= state.state1
        state.state1 ^= state.state2
        state.state0 ^= state.state3
        
        state.state2 ^= t
        state.state3 = rotl(state.state3, 45)
        
        return result
    }
    
    private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        return (x << k) | (x >> (64 - k))
    }
}

/// Deterministic Scheduler Errors
public enum DeterministicSchedulerError: Error, Sendable {
    case invalidSeed
    case taskExecutionFailed(String)
    
    public var localizedDescription: String {
        switch self {
        case .invalidSeed:
            return "Invalid seed (should not occur)"
        case .taskExecutionFailed(let reason):
            return "Task execution failed: \(reason)"
        }
    }
}
