// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FramePacingClassifier.swift
// PR5Capture
//
// PR5 v1.8.1 - PART B: 时间戳和同步
// 帧率分类（24/30/60fps），节奏类别分析
//

import Foundation

/// Frame pacing classifier
///
/// Classifies frame rate (24/30/60fps) and analyzes pacing rhythm.
/// Detects frame drops and irregular pacing patterns.
public actor FramePacingClassifier {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Frame Rate Types
    
    public enum FrameRate: String, Codable, Sendable, CaseIterable {
        case fps24 = "24fps"
        case fps30 = "30fps"
        case fps60 = "60fps"
        case variable = "variable"
        case unknown = "unknown"
    }
    
    // MARK: - Pacing Rhythm Types
    
    public enum PacingRhythm: String, Codable, Sendable, CaseIterable {
        case regular      // Consistent frame intervals
        case irregular    // Variable frame intervals
        case dropped      // Missing frames detected
        case stuttering   // Frequent frame drops
    }
    
    // MARK: - State
    
    /// Frame timestamp history
    private var frameTimestamps: [Date] = []
    
    /// Classified frame rate
    private var classifiedFrameRate: FrameRate = .unknown
    
    /// Classified pacing rhythm
    private var classifiedRhythm: PacingRhythm = .regular
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Frame Recording
    
    /// Record frame timestamp
    public func recordFrame(_ timestamp: Date) {
        frameTimestamps.append(timestamp)
        
        // Keep only recent history (last 120 frames, ~2 seconds at 60fps)
        if frameTimestamps.count > 120 {
            frameTimestamps.removeFirst()
        }
        
        // Re-classify when we have enough samples
        if frameTimestamps.count >= 10 {
            classifyFrameRate()
            classifyPacingRhythm()
        }
    }
    
    // MARK: - Classification
    
    /// Classify frame rate
    private func classifyFrameRate() {
        guard frameTimestamps.count >= 2 else {
            classifiedFrameRate = .unknown
            return
        }
        
        // Compute average frame interval
        var intervals: [TimeInterval] = []
        for i in 1..<frameTimestamps.count {
            let interval = frameTimestamps[i].timeIntervalSince(frameTimestamps[i-1])
            intervals.append(interval)
        }
        
        let avgInterval = intervals.reduce(0.0, +) / Double(intervals.count)
        let fps = 1.0 / avgInterval
        
        // Classify based on FPS
        if abs(fps - 24.0) < 2.0 {
            classifiedFrameRate = .fps24
        } else if abs(fps - 30.0) < 2.0 {
            classifiedFrameRate = .fps30
        } else if abs(fps - 60.0) < 2.0 {
            classifiedFrameRate = .fps60
        } else {
            // Check variance to determine if variable
            let variance = intervals.map { pow($0 - avgInterval, 2) }.reduce(0.0, +) / Double(intervals.count)
            let stdDev = sqrt(variance)
            
            if stdDev / avgInterval > 0.1 {  // >10% variance
                classifiedFrameRate = .variable
            } else {
                classifiedFrameRate = .unknown
            }
        }
    }
    
    /// Classify pacing rhythm
    private func classifyPacingRhythm() {
        guard frameTimestamps.count >= 3 else {
            classifiedRhythm = .regular
            return
        }
        
        // Compute frame intervals
        var intervals: [TimeInterval] = []
        for i in 1..<frameTimestamps.count {
            let interval = frameTimestamps[i].timeIntervalSince(frameTimestamps[i-1])
            intervals.append(interval)
        }
        
        let avgInterval = intervals.reduce(0.0, +) / Double(intervals.count)
        let expectedInterval = avgInterval
        
        // Count frame drops (intervals significantly longer than expected)
        var dropCount = 0
        var variance = 0.0
        
        for interval in intervals {
            // Check for drops (interval > 1.5x expected)
            if interval > expectedInterval * 1.5 {
                dropCount += 1
            }
            
            // Accumulate variance
            variance += pow(interval - avgInterval, 2)
        }
        
        variance /= Double(intervals.count)
        let stdDev = sqrt(variance)
        let coefficientOfVariation = stdDev / avgInterval
        
        // Classify rhythm
        if dropCount >= intervals.count / 4 {  // >25% drops
            classifiedRhythm = .stuttering
        } else if dropCount > 0 {
            classifiedRhythm = .dropped
        } else if coefficientOfVariation > 0.15 {  // >15% CV
            classifiedRhythm = .irregular
        } else {
            classifiedRhythm = .regular
        }
    }
    
    // MARK: - Queries
    
    /// Get classified frame rate
    public func getClassifiedFrameRate() -> FrameRate {
        return classifiedFrameRate
    }
    
    /// Get classified pacing rhythm
    public func getClassifiedPacingRhythm() -> PacingRhythm {
        return classifiedRhythm
    }
    
    /// Get frame rate analysis result
    public func getAnalysisResult() -> FrameRateAnalysisResult {
        return FrameRateAnalysisResult(
            frameRate: classifiedFrameRate,
            pacingRhythm: classifiedRhythm,
            sampleCount: frameTimestamps.count
        )
    }
    
    // MARK: - Result Types
    
    /// Frame rate analysis result
    public struct FrameRateAnalysisResult: Sendable {
        public let frameRate: FrameRate
        public let pacingRhythm: PacingRhythm
        public let sampleCount: Int
    }
}
