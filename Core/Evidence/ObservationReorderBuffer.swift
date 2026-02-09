// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObservationReorderBuffer.swift
// Aether3D
//
// PR2 Patch V4 - Observation Reorder Buffer
// Handles out-of-order observations with quality penalty for late arrivals
//

import Foundation

/// Observation with sequence number for ordering
public struct SequencedObservation: Sendable {
    public let observation: EvidenceObservation
    public let sequenceNumber: UInt64
    public let timestampMs: Int64
    
    /// Global sequence counter (atomic)
    private static var _counter: UInt64 = 0
    private static let _lock = NSLock()
    
    /// Generate next sequence number
    public static func nextSequenceNumber() -> UInt64 {
        _lock.lock()
        defer { _lock.unlock() }
        _counter += 1
        return _counter
    }
    
    public init(observation: EvidenceObservation) {
        self.observation = observation
        self.sequenceNumber = Self.nextSequenceNumber()
        self.timestampMs = Int64(observation.timestamp * 1000.0)
    }
    
    /// Test-only initializer with explicit sequence number
    internal init(observation: EvidenceObservation, sequenceNumber: UInt64, timestampMs: Int64) {
        self.observation = observation
        self.sequenceNumber = sequenceNumber
        self.timestampMs = timestampMs
    }
}

/// Observation reordering buffer
public final class ObservationReorderBuffer {
    
    /// Buffer window size (milliseconds)
    /// Observations older than this are considered late
    public static let bufferWindowMs: Int64 = 120
    
    /// Expected next sequence number
    private var expectedNext: UInt64 = 1
    
    /// Buffered observations
    private var buffer: [UInt64: SequencedObservation] = [:]
    
    /// Maximum buffer size before forcing skip
    public static let maxBufferSize: Int = 16
    
    /// Add observation, return in-order observations
    /// - Parameter observation: Observation to add
    /// - Returns: Array of in-order observations (may be empty if out of order)
    public func add(_ observation: SequencedObservation) -> [SequencedObservation] {
        buffer[observation.sequenceNumber] = observation
        
        var result: [SequencedObservation] = []
        
        // Emit in-order observations
        while let next = buffer.removeValue(forKey: expectedNext) {
            result.append(next)
            expectedNext += 1
        }
        
        // If buffer too full, skip missing observations
        if buffer.count > Self.maxBufferSize {
            if let minKey = buffer.keys.min() {
                expectedNext = minKey
                while let next = buffer.removeValue(forKey: expectedNext) {
                    result.append(next)
                    expectedNext += 1
                }
            }
        }
        
        return result
    }
    
    /// Check if observation is late (outside buffer window)
    public func isLate(_ observation: SequencedObservation, currentTimeMs: Int64) -> Bool {
        let age = currentTimeMs - observation.timestampMs
        return age > Self.bufferWindowMs
    }
    
    /// Get quality scale penalty for late observation
    /// Late observations get reduced quality but are not dropped
    public static func qualityScaleForLate(ageMs: Int64) -> Double {
        // Linear decay: 120ms = 1.0, 240ms = 0.5, 360ms = 0.25, etc.
        let normalizedAge = Double(ageMs) / Double(bufferWindowMs)
        return max(0.1, 1.0 / normalizedAge)
    }
    
    /// Flush all remaining observations in order
    /// - Returns: All remaining observations sorted by sequence number
    public func flush() -> [SequencedObservation] {
        var result: [SequencedObservation] = []
        
        // Emit all remaining in order
        while let next = buffer.removeValue(forKey: expectedNext) {
            result.append(next)
            expectedNext += 1
        }
        
        // If any remain, emit them sorted
        let remaining = buffer.values.sorted { $0.sequenceNumber < $1.sequenceNumber }
        for obs in remaining {
            buffer.removeValue(forKey: obs.sequenceNumber)
            result.append(obs)
        }
        
        return result
    }
    
    /// Reset buffer
    public func reset() {
        buffer.removeAll()
        expectedNext = 1
    }
}
