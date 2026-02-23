// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FramePacingNormalizer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 0: 传感器和相机管道
// FPS 估计，丢帧检测，时间窗口转换
//

import Foundation

/// Frame pacing normalizer
///
/// Estimates FPS, detects frame drops, and normalizes timing windows.
/// Ensures consistent frame pacing analysis.
public actor FramePacingNormalizer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Frame timestamp history
    private var frameTimestamps: [Date] = []
    
    /// Estimated FPS
    private var estimatedFPS: Double?
    
    /// Frame drop history
    private var frameDrops: [(timestamp: Date, expectedInterval: TimeInterval, actualInterval: TimeInterval)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Frame Recording
    
    /// Record frame timestamp
    public func recordFrame(_ timestamp: Date) {
        frameTimestamps.append(timestamp)
        
        // Keep only recent history (last 120 frames)
        if frameTimestamps.count > 120 {
            frameTimestamps.removeFirst()
        }
        
        // Update FPS estimate
        if frameTimestamps.count >= 10 {
            estimateFPS()
        }
        
        // Detect frame drops
        if frameTimestamps.count >= 2 {
            detectFrameDrops()
        }
    }
    
    // MARK: - FPS Estimation
    
    /// Estimate FPS from timestamp history
    private func estimateFPS() {
        guard frameTimestamps.count >= 2 else {
            estimatedFPS = nil
            return
        }
        
        // Compute average interval
        var intervals: [TimeInterval] = []
        for i in 1..<frameTimestamps.count {
            let interval = frameTimestamps[i].timeIntervalSince(frameTimestamps[i-1])
            intervals.append(interval)
        }
        
        // Use median to avoid outliers
        intervals.sort()
        let medianInterval = intervals[intervals.count / 2]
        
        estimatedFPS = 1.0 / medianInterval
    }
    
    // MARK: - Frame Drop Detection
    
    /// Detect frame drops
    private func detectFrameDrops() {
        guard let fps = estimatedFPS, frameTimestamps.count >= 2 else { return }
        
        let expectedInterval = 1.0 / fps
        
        // Check last interval
        let lastIndex = frameTimestamps.count - 1
        let actualInterval = frameTimestamps[lastIndex].timeIntervalSince(frameTimestamps[lastIndex - 1])
        
        // If actual interval is significantly longer than expected, it's a drop
        if actualInterval > expectedInterval * 1.5 {
            frameDrops.append((
                timestamp: frameTimestamps[lastIndex],
                expectedInterval: expectedInterval,
                actualInterval: actualInterval
            ))
            
            // Keep only recent drops (last 50)
            if frameDrops.count > 50 {
                frameDrops.removeFirst()
            }
        }
    }
    
    // MARK: - Time Window Normalization
    
    /// Normalize time window
    ///
    /// Converts time-based windows to frame-based windows using estimated FPS
    public func normalizeTimeWindow(_ timeWindow: TimeInterval) -> Int? {
        guard let fps = estimatedFPS else { return nil }
        
        let frameCount = Int(timeWindow * fps)
        return max(1, frameCount)  // At least 1 frame
    }
    
    /// Denormalize frame window to time
    ///
    /// Converts frame-based windows to time-based windows
    public func denormalizeFrameWindow(_ frameWindow: Int) -> TimeInterval? {
        guard let fps = estimatedFPS else { return nil }
        
        return Double(frameWindow) / fps
    }
    
    // MARK: - Analysis
    
    /// Get frame pacing analysis
    public func getAnalysis() -> FramePacingAnalysis {
        let dropRate = frameDrops.count > 0 ? Double(frameDrops.count) / Double(frameTimestamps.count) : 0.0
        
        return FramePacingAnalysis(
            estimatedFPS: estimatedFPS,
            frameCount: frameTimestamps.count,
            dropCount: frameDrops.count,
            dropRate: dropRate,
            averageInterval: computeAverageInterval(),
            normalizedWindow: config.sensor.framePacingNormalizationWindow
        )
    }
    
    /// Compute average interval
    private func computeAverageInterval() -> TimeInterval? {
        guard frameTimestamps.count >= 2 else { return nil }
        
        var intervals: [TimeInterval] = []
        for i in 1..<frameTimestamps.count {
            let interval = frameTimestamps[i].timeIntervalSince(frameTimestamps[i-1])
            intervals.append(interval)
        }
        
        return intervals.reduce(0.0, +) / Double(intervals.count)
    }
    
    // MARK: - Queries
    
    /// Get estimated FPS
    public func getEstimatedFPS() -> Double? {
        return estimatedFPS
    }
    
    /// Get frame drop count
    public func getFrameDropCount() -> Int {
        return frameDrops.count
    }
    
    /// Get frame drop history
    public func getFrameDropHistory() -> [(timestamp: Date, expectedInterval: TimeInterval, actualInterval: TimeInterval)] {
        return frameDrops
    }
    
    // MARK: - Result Types
    
    /// Frame pacing analysis result
    public struct FramePacingAnalysis: Sendable {
        public let estimatedFPS: Double?
        public let frameCount: Int
        public let dropCount: Int
        public let dropRate: Double
        public let averageInterval: TimeInterval?
        public let normalizedWindow: TimeInterval
    }
}
