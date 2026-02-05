//
// DualTimestampRecorder.swift
// PR5Capture
//
// PR5 v1.8.1 - PART B: 时间戳和同步
// 回调时间 vs 捕获时间，延迟警告
//

import Foundation

/// Dual timestamp recorder
///
/// Records both callback time and capture time to detect processing delays.
/// Issues warnings when delay exceeds thresholds.
public actor DualTimestampRecorder {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Timestamp pairs (callback time, capture time)
    private var timestampPairs: [(callbackTime: Date, captureTime: Date, delay: TimeInterval)] = []
    
    /// Delay warnings
    private var delayWarnings: [(timestamp: Date, delay: TimeInterval, threshold: TimeInterval)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Timestamp Recording
    
    /// Record dual timestamps
    ///
    /// Records both callback time (when frame callback was received) and
    /// capture time (when frame was actually captured)
    public func recordTimestamps(callbackTime: Date, captureTime: Date) {
        let delay = callbackTime.timeIntervalSince(captureTime)
        timestampPairs.append((callbackTime: callbackTime, captureTime: captureTime, delay: delay))
        
        // Keep only recent pairs (last 100)
        if timestampPairs.count > 100 {
            timestampPairs.removeFirst()
        }
        
        // Check for delay warning
        checkDelayWarning(delay: delay)
    }
    
    /// Record callback time (capture time will be recorded later)
    public func recordCallbackTime(_ callbackTime: Date) -> TimestampToken {
        return TimestampToken(callbackTime: callbackTime)
    }
    
    /// Complete timestamp recording with capture time
    public func recordCaptureTime(_ token: TimestampToken, captureTime: Date) {
        recordTimestamps(callbackTime: token.callbackTime, captureTime: captureTime)
    }
    
    // MARK: - Delay Analysis
    
    /// Check for delay warning
    private func checkDelayWarning(delay: TimeInterval) {
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Timestamp.dualTimestampMaxDelayMs,
            profile: config.profile
        ) / 1000.0  // Convert ms to seconds
        
        if delay > threshold {
            delayWarnings.append((
                timestamp: Date(),
                delay: delay,
                threshold: threshold
            ))
            
            // Keep only recent warnings (last 50)
            if delayWarnings.count > 50 {
                delayWarnings.removeFirst()
            }
        }
    }
    
    /// Get average delay
    public func getAverageDelay() -> TimeInterval? {
        guard !timestampPairs.isEmpty else { return nil }
        
        let totalDelay = timestampPairs.reduce(0.0) { $0 + $1.delay }
        return totalDelay / Double(timestampPairs.count)
    }
    
    /// Get maximum delay
    public func getMaximumDelay() -> TimeInterval? {
        return timestampPairs.map { $0.delay }.max()
    }
    
    /// Get delay warnings
    public func getDelayWarnings() -> [(timestamp: Date, delay: TimeInterval, threshold: TimeInterval)] {
        return delayWarnings
    }
    
    /// Get recent timestamp pairs
    public func getRecentPairs(count: Int = 10) -> [(callbackTime: Date, captureTime: Date, delay: TimeInterval)] {
        return Array(timestampPairs.suffix(count))
    }
    
    // MARK: - Result Types
    
    /// Timestamp token for deferred capture time recording
    public struct TimestampToken: Sendable {
        let callbackTime: Date
        
        init(callbackTime: Date) {
            self.callbackTime = callbackTime
        }
    }
}
