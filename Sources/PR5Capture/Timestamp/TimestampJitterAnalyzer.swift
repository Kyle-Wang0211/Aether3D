// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TimestampJitterAnalyzer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART B: 时间戳和同步
// 时间戳抖动分析，相机/IMU 时间戳方差检测
//

import Foundation

/// Timestamp jitter analyzer
///
/// Analyzes timestamp jitter and variance between camera and IMU timestamps.
/// Detects timing inconsistencies that could affect quality metrics.
public actor TimestampJitterAnalyzer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Camera timestamp history
    private var cameraTimestamps: [TimeInterval] = []
    
    /// IMU timestamp history
    private var imuTimestamps: [TimeInterval] = []
    
    /// Timestamp pairs (camera, IMU)
    private var timestampPairs: [(camera: TimeInterval, imu: TimeInterval, delta: TimeInterval)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Timestamp Recording
    
    /// Record camera timestamp
    public func recordCameraTimestamp(_ timestamp: TimeInterval) {
        cameraTimestamps.append(timestamp)
        
        // Keep only recent history (last 100 timestamps)
        if cameraTimestamps.count > 100 {
            cameraTimestamps.removeFirst()
        }
    }
    
    /// Record IMU timestamp
    public func recordIMUTimestamp(_ timestamp: TimeInterval) {
        imuTimestamps.append(timestamp)
        
        // Keep only recent history (last 100 timestamps)
        if imuTimestamps.count > 100 {
            imuTimestamps.removeFirst()
        }
    }
    
    /// Record timestamp pair (camera and IMU)
    public func recordTimestampPair(camera: TimeInterval, imu: TimeInterval) {
        let delta = abs(camera - imu)
        timestampPairs.append((camera: camera, imu: imu, delta: delta))
        
        // Keep only recent pairs (last 100)
        if timestampPairs.count > 100 {
            timestampPairs.removeFirst()
        }
    }
    
    // MARK: - Jitter Analysis
    
    /// Analyze timestamp jitter
    ///
    /// Computes variance and detects jitter exceeding thresholds
    public func analyzeJitter() -> JitterAnalysisResult {
        // Analyze camera timestamp jitter
        let cameraJitter = computeJitter(cameraTimestamps)
        
        // Analyze IMU timestamp jitter
        let imuJitter = computeJitter(imuTimestamps)
        
        // Analyze timestamp pair deltas
        let deltaJitter = computeDeltaJitter()
        
        // Get threshold from config
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Timestamp.maxJitterMs,
            profile: config.profile
        )
        
        // Check if jitter exceeds threshold
        let cameraExceeds = cameraJitter.varianceMs >= threshold
        let imuExceeds = imuJitter.varianceMs >= threshold
        let deltaExceeds = deltaJitter?.varianceMs ?? 0 >= threshold
        
        let hasExcessiveJitter = cameraExceeds || imuExceeds || deltaExceeds
        
        return JitterAnalysisResult(
            cameraJitter: cameraJitter,
            imuJitter: imuJitter,
            deltaJitter: deltaJitter,
            threshold: threshold,
            hasExcessiveJitter: hasExcessiveJitter
        )
    }
    
    /// Compute jitter statistics for a timestamp array
    private func computeJitter(_ timestamps: [TimeInterval]) -> JitterStats {
        guard timestamps.count >= 2 else {
            return JitterStats(
                meanMs: 0.0,
                varianceMs: 0.0,
                stdDevMs: 0.0,
                minMs: 0.0,
                maxMs: 0.0
            )
        }
        
        // Compute intervals between consecutive timestamps
        var intervals: [Double] = []
        for i in 1..<timestamps.count {
            let interval = (timestamps[i] - timestamps[i-1]) * 1000.0  // Convert to ms
            intervals.append(interval)
        }
        
        // Compute statistics
        let mean = intervals.reduce(0.0, +) / Double(intervals.count)
        let variance = intervals.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(intervals.count)
        let stdDev = sqrt(variance)
        let min = intervals.min() ?? 0.0
        let max = intervals.max() ?? 0.0
        
        return JitterStats(
            meanMs: mean,
            varianceMs: variance,
            stdDevMs: stdDev,
            minMs: min,
            maxMs: max
        )
    }
    
    /// Compute delta jitter between camera and IMU timestamps
    private func computeDeltaJitter() -> JitterStats? {
        guard timestampPairs.count >= 2 else { return nil }
        
        let deltas = timestampPairs.map { $0.delta * 1000.0 }  // Convert to ms
        
        let mean = deltas.reduce(0.0, +) / Double(deltas.count)
        let variance = deltas.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(deltas.count)
        let stdDev = sqrt(variance)
        let min = deltas.min() ?? 0.0
        let max = deltas.max() ?? 0.0
        
        return JitterStats(
            meanMs: mean,
            varianceMs: variance,
            stdDevMs: stdDev,
            minMs: min,
            maxMs: max
        )
    }
    
    // MARK: - Result Types
    
    /// Jitter statistics
    public struct JitterStats: Sendable {
        public let meanMs: Double
        public let varianceMs: Double
        public let stdDevMs: Double
        public let minMs: Double
        public let maxMs: Double
    }
    
    /// Jitter analysis result
    public struct JitterAnalysisResult: Sendable {
        public let cameraJitter: JitterStats
        public let imuJitter: JitterStats
        public let deltaJitter: JitterStats?
        public let threshold: Double
        public let hasExcessiveJitter: Bool
    }
}
