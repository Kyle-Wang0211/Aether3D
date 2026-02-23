// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  TrendConfirmation.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 3
//  TrendConfirmation - 300ms window stability check (PART 2.4, P6/H2)
//

import Foundation

/// TrendConfirmation - O(1) stability check using RingBuffer
/// P6/H2: Uses MonotonicClock for time windows
public class TrendConfirmation {
    private var metricHistory: RingBuffer<Double>
    private let windowMs: Int64 = QualityPreCheckConstants.TREND_WINDOW_MS
    private var timestamps: RingBuffer<Int64>
    
    public init() {
        self.metricHistory = RingBuffer<Double>(maxCapacity: QualityPreCheckConstants.MAX_TREND_BUFFER_SIZE)
        self.timestamps = RingBuffer<Int64>(maxCapacity: QualityPreCheckConstants.MAX_TREND_BUFFER_SIZE)
    }
    
    /// Add metric value with timestamp
    /// H2: Uses MonotonicClock, not Date()
    public func addValue(_ value: Double, timestamp: Int64) {
        metricHistory.append(value)
        timestamps.append(timestamp)
    }
    
    /// Check stability within window
    /// Returns stability value (variance) or nil if insufficient data
    public func checkStability() -> Double? {
        let now = MonotonicClock.nowMs()
        let windowStart = now - windowMs
        
        // Get values within window
        let allValues = metricHistory.getAll()
        let allTimestamps = timestamps.getAll()
        
        guard allValues.count == allTimestamps.count else {
            return nil
        }
        
        let windowValues = zip(allValues, allTimestamps)
            .filter { $0.1 >= windowStart }
            .map { $0.0 }
        
        guard windowValues.count >= 2 else {
            return nil
        }
        
        // Calculate variance
        let mean = windowValues.reduce(0, +) / Double(windowValues.count)
        let variance = windowValues.map { pow($0 - mean, 2) }.reduce(0, +) / Double(windowValues.count)
        
        return variance
    }
}

