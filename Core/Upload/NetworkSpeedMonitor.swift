// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Network Speed Monitor
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

// ============================================================================
// MARK: - Network Speed Classification
// ============================================================================

/// Network speed classification for adaptive chunk sizing.
/// Used to categorize current network conditions.
public enum NetworkSpeedClass: String, Codable, CaseIterable {
    /// < 5 Mbps - Typical 3G, poor WiFi
    case slow = "slow"

    /// 5-50 Mbps - Typical 4G, good WiFi
    case normal = "normal"

    /// 50-100 Mbps - 5G, fiber
    case fast = "fast"

    /// > 100 Mbps - Excellent connectivity
    case ultrafast = "ultrafast"

    /// Insufficient data for classification
    case unknown = "unknown"

    /// Human-readable description
    public var displayName: String {
        switch self {
        case .slow: return "Slow (<5 Mbps)"
        case .normal: return "Normal (5-50 Mbps)"
        case .fast: return "Fast (50-100 Mbps)"
        case .ultrafast: return "Ultra Fast (>100 Mbps)"
        case .unknown: return "Unknown"
        }
    }

    /// Recommended chunk size for this speed class
    public var recommendedChunkSize: Int {
        switch self {
        case .slow:
            return UploadConstants.CHUNK_SIZE_MIN_BYTES
        case .normal:
            return UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        case .fast:
            return 10 * 1024 * 1024  // 10MB
        case .ultrafast:
            return UploadConstants.CHUNK_SIZE_MAX_BYTES
        case .unknown:
            return UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        }
    }

    /// Recommended parallel upload count
    public var recommendedParallelCount: Int {
        switch self {
        case .slow:
            return 2
        case .normal:
            return 3
        case .fast, .ultrafast:
            return UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS
        case .unknown:
            return 2
        }
    }

    /// Whether this class allows aggressive optimization
    public var allowsAggressiveOptimization: Bool {
        switch self {
        case .fast, .ultrafast:
            return true
        default:
            return false
        }
    }
}

// ============================================================================
// MARK: - Speed Sample
// ============================================================================

/// Individual speed measurement sample.
/// Immutable value type for thread safety.
public struct SpeedSample: Codable, Equatable {
    /// Bytes transferred in this sample
    public let bytesTransferred: Int64

    /// Duration of the transfer in seconds
    public let durationSeconds: TimeInterval

    /// Timestamp when sample was recorded
    public let timestamp: Date

    /// Calculated speed in bytes per second
    public var speedBps: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(bytesTransferred) / durationSeconds
    }

    /// Calculated speed in megabits per second
    public var speedMbps: Double {
        return (speedBps * 8.0) / (1024.0 * 1024.0)
    }

    /// Calculated speed in kilobytes per second
    public var speedKBps: Double {
        return speedBps / 1024.0
    }

    /// Initialize a new speed sample
    /// - Parameters:
    ///   - bytesTransferred: Number of bytes transferred
    ///   - durationSeconds: Time taken for transfer
    ///   - timestamp: When sample was recorded (defaults to now)
    public init(
        bytesTransferred: Int64,
        durationSeconds: TimeInterval,
        timestamp: Date = Date()
    ) {
        self.bytesTransferred = max(0, bytesTransferred)
        self.durationSeconds = max(0, durationSeconds)
        self.timestamp = timestamp
    }

    /// Check if sample is recent (within window)
    /// - Parameter window: Time window in seconds
    /// - Returns: True if sample is within window
    public func isRecent(window: TimeInterval = UploadConstants.NETWORK_SPEED_WINDOW_SECONDS) -> Bool {
        return Date().timeIntervalSince(timestamp) <= window
    }
}

// ============================================================================
// MARK: - Network Speed Monitor
// ============================================================================

/// Real-time network speed monitor with adaptive classification.
///
/// ## Thread Safety
/// All public methods are thread-safe, using a serial dispatch queue
/// for synchronization.
///
/// ## Usage
/// ```swift
/// let monitor = NetworkSpeedMonitor()
///
/// // Record samples from chunk uploads
/// monitor.recordSample(bytesTransferred: chunkSize, durationSeconds: elapsed)
///
/// // Get current classification
/// let speedClass = monitor.getSpeedClass()
/// let chunkSize = speedClass.recommendedChunkSize
/// ```
///
/// ## Cross-Platform
/// Uses only Foundation types. No Apple-specific frameworks.
public final class NetworkSpeedMonitor {

    // =========================================================================
    // MARK: - Properties
    // =========================================================================

    /// Thread synchronization queue
    private let queue = DispatchQueue(
        label: "com.app.upload.networkspeedmonitor",
        qos: .userInitiated
    )

    /// Recorded speed samples
    private var samples: [SpeedSample] = []

    /// Maximum samples to retain
    private let maxSamples: Int

    /// Time window for sample validity (seconds)
    private let windowSeconds: TimeInterval

    /// Current speed classification (cached)
    private var _currentClass: NetworkSpeedClass = .unknown

    /// Current estimated speed in Mbps (cached)
    private var _currentSpeedMbps: Double = 0.0

    /// Last calculation timestamp
    private var lastCalculationTime: Date = .distantPast

    // =========================================================================
    // MARK: - Initialization
    // =========================================================================

    /// Initialize network speed monitor
    /// - Parameters:
    ///   - maxSamples: Maximum samples to retain (default: 20)
    ///   - windowSeconds: Sample validity window (default: 30s)
    public init(
        maxSamples: Int = UploadConstants.NETWORK_SPEED_MAX_SAMPLES,
        windowSeconds: TimeInterval = UploadConstants.NETWORK_SPEED_WINDOW_SECONDS
    ) {
        self.maxSamples = max(1, maxSamples)
        self.windowSeconds = max(1, windowSeconds)
    }

    // =========================================================================
    // MARK: - Public Methods
    // =========================================================================

    /// Record a speed measurement sample.
    /// - Parameters:
    ///   - bytesTransferred: Bytes transferred in this measurement
    ///   - durationSeconds: Time taken for the transfer
    /// - Note: Invalid samples (zero or negative values) are ignored.
    public func recordSample(bytesTransferred: Int64, durationSeconds: TimeInterval) {
        guard bytesTransferred > 0, durationSeconds > 0 else { return }

        let sample = SpeedSample(
            bytesTransferred: bytesTransferred,
            durationSeconds: durationSeconds
        )

        queue.sync {
            samples.append(sample)
            pruneOldSamples()
            recalculateSpeed()
        }
    }

    /// Record a speed sample from a SpeedSample struct.
    /// - Parameter sample: The sample to record
    public func recordSample(_ sample: SpeedSample) {
        guard sample.bytesTransferred > 0, sample.durationSeconds > 0 else { return }

        queue.sync {
            samples.append(sample)
            pruneOldSamples()
            recalculateSpeed()
        }
    }

    /// Get current speed classification.
    /// - Returns: Network speed class based on recent measurements
    public func getSpeedClass() -> NetworkSpeedClass {
        return queue.sync { _currentClass }
    }

    /// Get current estimated speed in Mbps.
    /// - Returns: Speed in megabits per second
    public func getSpeedMbps() -> Double {
        return queue.sync { _currentSpeedMbps }
    }

    /// Get current estimated speed in bytes per second.
    /// - Returns: Speed in bytes per second
    public func getSpeedBps() -> Double {
        return queue.sync { (_currentSpeedMbps * 1024.0 * 1024.0) / 8.0 }
    }

    /// Get recommended chunk size based on current network conditions.
    /// - Returns: Recommended chunk size in bytes
    public func getRecommendedChunkSize() -> Int {
        return getSpeedClass().recommendedChunkSize
    }

    /// Get recommended parallel upload count.
    /// - Returns: Recommended number of parallel uploads
    public func getRecommendedParallelCount() -> Int {
        return getSpeedClass().recommendedParallelCount
    }

    /// Check if we have enough samples for reliable estimation.
    /// - Returns: True if estimation is statistically reliable
    public func hasReliableEstimate() -> Bool {
        return queue.sync {
            let validSamples = samples.filter { $0.isRecent(window: windowSeconds) }
            return validSamples.count >= UploadConstants.NETWORK_SPEED_MIN_SAMPLES
        }
    }

    /// Get current sample count.
    /// - Returns: Number of valid samples in window
    public func getSampleCount() -> Int {
        return queue.sync {
            samples.filter { $0.isRecent(window: windowSeconds) }.count
        }
    }

    /// Get all recent samples (for debugging/display).
    /// - Returns: Copy of recent samples
    public func getRecentSamples() -> [SpeedSample] {
        return queue.sync {
            samples.filter { $0.isRecent(window: windowSeconds) }
        }
    }

    /// Reset all samples and classification.
    /// - Note: Useful when network conditions change dramatically (e.g., WiFi to cellular)
    public func reset() {
        queue.sync {
            samples.removeAll()
            _currentClass = .unknown
            _currentSpeedMbps = 0.0
            lastCalculationTime = .distantPast
        }
    }

    /// Force recalculation of speed (for testing).
    public func forceRecalculate() {
        queue.sync {
            recalculateSpeed()
        }
    }

    // =========================================================================
    // MARK: - Statistics
    // =========================================================================

    /// Get speed statistics for recent samples.
    /// - Returns: Statistics tuple (min, max, avg, stddev) or nil if insufficient data
    public func getSpeedStatistics() -> (min: Double, max: Double, avg: Double, stddev: Double)? {
        return queue.sync {
            let validSamples = samples.filter { $0.isRecent(window: windowSeconds) }
            guard validSamples.count >= 2 else { return nil }

            let speeds = validSamples.map { $0.speedMbps }
            let minSpeed = speeds.min() ?? 0
            let maxSpeed = speeds.max() ?? 0
            let avgSpeed = speeds.reduce(0, +) / Double(speeds.count)

            let variance = speeds.map { pow($0 - avgSpeed, 2) }.reduce(0, +) / Double(speeds.count)
            let stddev = sqrt(variance)

            return (min: minSpeed, max: maxSpeed, avg: avgSpeed, stddev: stddev)
        }
    }

    // =========================================================================
    // MARK: - Private Methods
    // =========================================================================

    /// Remove old samples outside the time window.
    /// Must be called within queue.sync block.
    private func pruneOldSamples() {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        samples = samples.filter { $0.timestamp > cutoff }

        // Also limit total samples
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
    }

    /// Recalculate speed and classification.
    /// Must be called within queue.sync block.
    private func recalculateSpeed() {
        let validSamples = samples.filter { $0.isRecent(window: windowSeconds) }

        guard validSamples.count >= UploadConstants.NETWORK_SPEED_MIN_SAMPLES else {
            _currentClass = .unknown
            _currentSpeedMbps = 0.0
            return
        }

        // Weighted average: recent samples have more weight
        var weightedSum: Double = 0.0
        var weightSum: Double = 0.0
        let now = Date()

        for sample in validSamples {
            let age = now.timeIntervalSince(sample.timestamp)
            // Linear decay: newer samples weighted more heavily
            let weight = max(0.1, 1.0 - (age / windowSeconds))
            weightedSum += sample.speedMbps * weight
            weightSum += weight
        }

        _currentSpeedMbps = weightSum > 0 ? weightedSum / weightSum : 0.0
        _currentClass = classifySpeed(_currentSpeedMbps)
        lastCalculationTime = now
    }

    /// Classify speed into a NetworkSpeedClass.
    /// - Parameter mbps: Speed in megabits per second
    /// - Returns: Corresponding speed class
    private func classifySpeed(_ mbps: Double) -> NetworkSpeedClass {
        switch mbps {
        case ..<UploadConstants.NETWORK_SPEED_SLOW_MBPS:
            return .slow
        case ..<UploadConstants.NETWORK_SPEED_NORMAL_MBPS:
            return .normal
        case ..<UploadConstants.NETWORK_SPEED_FAST_MBPS:
            return .fast
        default:
            return .ultrafast
        }
    }
}

// ============================================================================
// MARK: - CustomStringConvertible
// ============================================================================

extension NetworkSpeedMonitor: CustomStringConvertible {
    public var description: String {
        let speedClass = getSpeedClass()
        let speedMbps = getSpeedMbps()
        let sampleCount = getSampleCount()
        return "NetworkSpeedMonitor(class: \(speedClass.rawValue), speed: \(String(format: "%.2f", speedMbps)) Mbps, samples: \(sampleCount))"
    }
}
