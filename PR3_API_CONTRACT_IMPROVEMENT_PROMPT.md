# PR3 API Contract Improvement - Comprehensive Implementation Prompt

## 🎯 Mission Objective

Implement enterprise-grade upload infrastructure with adaptive chunk sizing, parallel uploads, resume capability, and network-aware optimization. This PR builds on PR2-JSM-3.0-merged foundation.

---

## 📋 Pre-Implementation Checklist

Before starting, verify the codebase state:

```bash
# 1. Verify current branch and contract version
git branch --show-current  # Should be: pr3 or pr3/api-contract-v1
grep "CONTRACT_VERSION" Core/Jobs/ContractConstants.swift
# Expected: PR2-JSM-3.0-merged

# 2. Verify build passes
swift build

# 3. Verify all tests pass
swift test
```

---

## 🏗️ Architecture Overview

### New Files to Create

| # | File Path | Purpose | Lines (Est.) |
|---|-----------|---------|--------------|
| 1 | `Core/Upload/ChunkManager.swift` | Parallel chunk upload orchestration | ~250 |
| 2 | `Core/Upload/AdaptiveChunkSizer.swift` | Network-aware chunk size selection | ~150 |
| 3 | `Core/Upload/NetworkSpeedMonitor.swift` | Real-time bandwidth measurement | ~200 |
| 4 | `Core/Upload/UploadSession.swift` | Session lifecycle & state tracking | ~180 |
| 5 | `Core/Upload/UploadResumeManager.swift` | Resume/recovery with persistence | ~220 |
| 6 | `Core/Upload/UploadProgressTracker.swift` | Aggregate progress across chunks | ~120 |
| 7 | `Core/Constants/UploadConstants.swift` | All upload-related constants | ~100 |
| 8 | `Tests/Upload/ChunkManagerTests.swift` | Chunk manager unit tests | ~300 |
| 9 | `Tests/Upload/AdaptiveChunkSizerTests.swift` | Adaptive sizing tests | ~200 |
| 10 | `Tests/Upload/NetworkSpeedMonitorTests.swift` | Network monitor tests | ~150 |
| 11 | `Tests/Upload/UploadSessionTests.swift` | Session lifecycle tests | ~180 |
| 12 | `Tests/Upload/UploadResumeManagerTests.swift` | Resume/recovery tests | ~200 |

### Files to Modify

| # | File Path | Changes |
|---|-----------|---------|
| 1 | `Core/Constants/APIContractConstants.swift` | Add upload constants, deprecate fixed CHUNK_SIZE |
| 2 | `Core/Jobs/ContractConstants.swift` | Update version to PR3-API-1.0 |
| 3 | `Core/API/APIContract.swift` | Add upload session types |
| 4 | `Core/API/APIEndpoints.swift` | Add chunk upload endpoints |

---

## 📁 File 1: UploadConstants.swift

**Path:** `Core/Constants/UploadConstants.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure
// ============================================================================

import Foundation

/// Upload infrastructure constants following Constitutional Contract pattern.
/// Reference: tus.io resumable upload protocol v1.0.0
public enum UploadConstants {

    // MARK: - Contract Version

    /// Upload module contract version
    public static let UPLOAD_CONTRACT_VERSION = "PR3-UPLOAD-1.0"

    // MARK: - Adaptive Chunk Sizing

    /// Minimum chunk size (slow/unstable networks)
    /// - 2MB balances reliability vs overhead on poor connections
    /// - Below 2MB: HTTP overhead becomes significant (>5%)
    public static let CHUNK_SIZE_MIN_BYTES = 2 * 1024 * 1024  // 2MB

    /// Default chunk size (normal networks, 10-50 Mbps)
    /// - 5MB is optimal for typical mobile/WiFi connections
    /// - Matches S3 multipart minimum for compatibility
    public static let CHUNK_SIZE_DEFAULT_BYTES = 5 * 1024 * 1024  // 5MB

    /// Maximum chunk size (fast networks, >100 Mbps)
    /// - 20MB maximizes throughput on high-speed connections
    /// - Above 20MB: Memory pressure on mobile devices
    public static let CHUNK_SIZE_MAX_BYTES = 20 * 1024 * 1024  // 20MB

    /// Chunk size step increment for adaptive adjustment
    /// - 1MB steps provide granular optimization
    public static let CHUNK_SIZE_STEP_BYTES = 1 * 1024 * 1024  // 1MB

    // MARK: - Network Speed Thresholds

    /// Slow network threshold (Mbps)
    /// - Below 5 Mbps: Use minimum chunk size
    /// - Typical 3G/poor WiFi speeds
    public static let NETWORK_SPEED_SLOW_MBPS: Double = 5.0

    /// Normal network threshold (Mbps)
    /// - 5-50 Mbps: Use default chunk size
    /// - Typical 4G/good WiFi speeds
    public static let NETWORK_SPEED_NORMAL_MBPS: Double = 50.0

    /// Fast network threshold (Mbps)
    /// - Above 50 Mbps: Use maximum chunk size
    /// - Typical 5G/fiber speeds
    public static let NETWORK_SPEED_FAST_MBPS: Double = 100.0

    /// Minimum samples before speed estimation is trusted
    /// - 3 samples reduces noise from temporary spikes
    public static let NETWORK_SPEED_MIN_SAMPLES = 3

    /// Speed measurement window (seconds)
    /// - 30 seconds captures recent network conditions
    public static let NETWORK_SPEED_WINDOW_SECONDS: TimeInterval = 30.0

    // MARK: - Parallel Upload Configuration

    /// Maximum concurrent chunk uploads
    /// - 4 parallel uploads optimal for throughput vs resource usage
    /// - Research: Beyond 4, diminishing returns on most networks
    public static let MAX_PARALLEL_CHUNK_UPLOADS = 4

    /// Minimum concurrent chunk uploads
    /// - Always at least 1 for progress
    public static let MIN_PARALLEL_CHUNK_UPLOADS = 1

    /// Parallel upload ramp-up delay (seconds)
    /// - Stagger parallel requests to avoid burst congestion
    public static let PARALLEL_RAMP_UP_DELAY_SECONDS: TimeInterval = 0.1

    // MARK: - Upload Session Management

    /// Maximum upload session duration (seconds)
    /// - 24 hours allows for interrupted uploads to resume
    public static let UPLOAD_SESSION_MAX_AGE_SECONDS: TimeInterval = 24 * 60 * 60

    /// Upload session cleanup interval (seconds)
    /// - Check for stale sessions every hour
    public static let UPLOAD_SESSION_CLEANUP_INTERVAL_SECONDS: TimeInterval = 60 * 60

    /// Maximum concurrent upload sessions per user
    /// - Limit to prevent resource exhaustion
    public static let MAX_CONCURRENT_SESSIONS_PER_USER = 3

    // MARK: - Resume & Recovery

    /// Chunk upload timeout (seconds)
    /// - 60 seconds per chunk before retry
    public static let CHUNK_UPLOAD_TIMEOUT_SECONDS: TimeInterval = 60.0

    /// Maximum retries per chunk
    /// - 3 retries with exponential backoff
    public static let CHUNK_MAX_RETRIES = 3

    /// Stall detection timeout (seconds)
    /// - No progress for 15 seconds = stalled
    public static let STALL_DETECTION_TIMEOUT_SECONDS: TimeInterval = 15.0

    /// Minimum progress rate before stall (bytes/second)
    /// - Below 1KB/s for 15 seconds = stalled
    public static let STALL_MIN_PROGRESS_RATE_BPS = 1024  // 1 KB/s

    /// Resume state persistence key prefix
    public static let RESUME_STATE_KEY_PREFIX = "upload_resume_"

    // MARK: - Progress Reporting

    /// Progress update throttle interval (seconds)
    /// - Limit UI updates to every 100ms
    public static let PROGRESS_THROTTLE_INTERVAL_SECONDS: TimeInterval = 0.1

    /// Minimum bytes transferred before progress update
    /// - Avoid micro-updates for tiny transfers
    public static let PROGRESS_MIN_BYTES_DELTA = 64 * 1024  // 64KB

    // MARK: - Idempotency

    /// Idempotency key header name (tus.io compatible)
    public static let IDEMPOTENCY_KEY_HEADER = "Upload-Metadata"

    /// Idempotency key format
    public static let IDEMPOTENCY_KEY_FORMAT = "idempotency_key base64"

    /// Maximum idempotency key age (seconds)
    /// - Keys expire after 24 hours
    public static let IDEMPOTENCY_KEY_MAX_AGE_SECONDS: TimeInterval = 24 * 60 * 60

    // MARK: - tus.io Protocol Headers

    /// tus.io protocol version
    public static let TUS_VERSION = "1.0.0"

    /// tus.io resumable header
    public static let TUS_RESUMABLE_HEADER = "Tus-Resumable"

    /// tus.io upload offset header
    public static let TUS_UPLOAD_OFFSET_HEADER = "Upload-Offset"

    /// tus.io upload length header
    public static let TUS_UPLOAD_LENGTH_HEADER = "Upload-Length"

    /// tus.io upload metadata header
    public static let TUS_UPLOAD_METADATA_HEADER = "Upload-Metadata"

    // MARK: - Validation

    /// Maximum file size for upload (bytes)
    /// - 10GB limit for video files
    public static let MAX_UPLOAD_FILE_SIZE_BYTES: Int64 = 10 * 1024 * 1024 * 1024

    /// Minimum file size for chunked upload (bytes)
    /// - Below 5MB: Single request upload
    public static let MIN_CHUNKED_UPLOAD_SIZE_BYTES = 5 * 1024 * 1024
}
```

---

## 📁 File 2: NetworkSpeedMonitor.swift

**Path:** `Core/Upload/NetworkSpeedMonitor.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Network Speed Monitor
// ============================================================================

import Foundation

/// Network speed classification for adaptive chunk sizing.
public enum NetworkSpeedClass: String, Codable {
    case slow = "slow"           // < 5 Mbps
    case normal = "normal"       // 5-50 Mbps
    case fast = "fast"           // 50-100 Mbps
    case ultrafast = "ultrafast" // > 100 Mbps
    case unknown = "unknown"     // Insufficient data

    /// Recommended chunk size for this speed class.
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

    /// Recommended parallel upload count for this speed class.
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
}

/// Measurement sample for speed calculation.
public struct SpeedSample: Codable {
    public let bytesTransferred: Int64
    public let durationSeconds: TimeInterval
    public let timestamp: Date

    /// Speed in bytes per second.
    public var speedBps: Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(bytesTransferred) / durationSeconds
    }

    /// Speed in megabits per second.
    public var speedMbps: Double {
        return (speedBps * 8) / (1024 * 1024)
    }

    public init(bytesTransferred: Int64, durationSeconds: TimeInterval, timestamp: Date = Date()) {
        self.bytesTransferred = bytesTransferred
        self.durationSeconds = durationSeconds
        self.timestamp = timestamp
    }
}

/// Real-time network speed monitor with adaptive classification.
/// Thread-safe implementation using serial queue.
public final class NetworkSpeedMonitor {

    // MARK: - Properties

    private var samples: [SpeedSample] = []
    private let queue = DispatchQueue(label: "com.app.networkspeedmonitor")
    private let maxSamples: Int
    private let windowSeconds: TimeInterval

    /// Current speed classification.
    public private(set) var currentClass: NetworkSpeedClass = .unknown

    /// Current estimated speed in Mbps.
    public private(set) var currentSpeedMbps: Double = 0

    // MARK: - Initialization

    public init(
        maxSamples: Int = 20,
        windowSeconds: TimeInterval = UploadConstants.NETWORK_SPEED_WINDOW_SECONDS
    ) {
        self.maxSamples = maxSamples
        self.windowSeconds = windowSeconds
    }

    // MARK: - Public Methods

    /// Record a speed measurement sample.
    /// - Parameters:
    ///   - bytesTransferred: Bytes transferred in this measurement
    ///   - durationSeconds: Time taken for the transfer
    public func recordSample(bytesTransferred: Int64, durationSeconds: TimeInterval) {
        guard durationSeconds > 0, bytesTransferred > 0 else { return }

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

    /// Get current speed classification.
    /// - Returns: Speed class based on recent measurements
    public func getSpeedClass() -> NetworkSpeedClass {
        return queue.sync { currentClass }
    }

    /// Get current estimated speed in Mbps.
    /// - Returns: Speed in megabits per second
    public func getSpeedMbps() -> Double {
        return queue.sync { currentSpeedMbps }
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
    /// - Returns: True if estimation is reliable
    public func hasReliableEstimate() -> Bool {
        return queue.sync {
            samples.count >= UploadConstants.NETWORK_SPEED_MIN_SAMPLES
        }
    }

    /// Reset all samples and classification.
    public func reset() {
        queue.sync {
            samples.removeAll()
            currentClass = .unknown
            currentSpeedMbps = 0
        }
    }

    // MARK: - Private Methods

    private func pruneOldSamples() {
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        samples = samples.filter { $0.timestamp > cutoff }

        // Also limit total samples
        if samples.count > maxSamples {
            samples = Array(samples.suffix(maxSamples))
        }
    }

    private func recalculateSpeed() {
        guard samples.count >= UploadConstants.NETWORK_SPEED_MIN_SAMPLES else {
            currentClass = .unknown
            currentSpeedMbps = 0
            return
        }

        // Weighted average: recent samples have more weight
        var weightedSum: Double = 0
        var weightSum: Double = 0
        let now = Date()

        for sample in samples {
            let age = now.timeIntervalSince(sample.timestamp)
            let weight = max(0.1, 1.0 - (age / windowSeconds))
            weightedSum += sample.speedMbps * weight
            weightSum += weight
        }

        currentSpeedMbps = weightSum > 0 ? weightedSum / weightSum : 0
        currentClass = classifySpeed(currentSpeedMbps)
    }

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
```

---

## 📁 File 3: AdaptiveChunkSizer.swift

**Path:** `Core/Upload/AdaptiveChunkSizer.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Adaptive Chunk Sizer
// ============================================================================

import Foundation

/// Chunk sizing strategy.
public enum ChunkSizingStrategy: String, Codable {
    case fixed = "fixed"           // Use fixed chunk size
    case adaptive = "adaptive"     // Adjust based on network speed
    case aggressive = "aggressive" // Maximize chunk size for fast networks
    case conservative = "conservative" // Minimize chunk size for reliability
}

/// Configuration for adaptive chunk sizing.
public struct AdaptiveChunkConfig: Codable {
    public let strategy: ChunkSizingStrategy
    public let minChunkSize: Int
    public let maxChunkSize: Int
    public let targetUploadTimeSeconds: TimeInterval

    public static let `default` = AdaptiveChunkConfig(
        strategy: .adaptive,
        minChunkSize: UploadConstants.CHUNK_SIZE_MIN_BYTES,
        maxChunkSize: UploadConstants.CHUNK_SIZE_MAX_BYTES,
        targetUploadTimeSeconds: 10.0  // Target 10 seconds per chunk
    )

    public init(
        strategy: ChunkSizingStrategy,
        minChunkSize: Int,
        maxChunkSize: Int,
        targetUploadTimeSeconds: TimeInterval
    ) {
        self.strategy = strategy
        self.minChunkSize = minChunkSize
        self.maxChunkSize = maxChunkSize
        self.targetUploadTimeSeconds = targetUploadTimeSeconds
    }
}

/// Adaptive chunk sizer that adjusts chunk size based on network conditions.
/// Reference: AWS S3 Transfer Acceleration best practices
public final class AdaptiveChunkSizer {

    // MARK: - Properties

    private let networkMonitor: NetworkSpeedMonitor
    private let config: AdaptiveChunkConfig
    private var lastCalculatedSize: Int

    // MARK: - Initialization

    public init(
        networkMonitor: NetworkSpeedMonitor,
        config: AdaptiveChunkConfig = .default
    ) {
        self.networkMonitor = networkMonitor
        self.config = config
        self.lastCalculatedSize = UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
    }

    // MARK: - Public Methods

    /// Calculate optimal chunk size for current network conditions.
    /// - Returns: Recommended chunk size in bytes
    public func calculateOptimalChunkSize() -> Int {
        switch config.strategy {
        case .fixed:
            return UploadConstants.CHUNK_SIZE_DEFAULT_BYTES

        case .conservative:
            return config.minChunkSize

        case .aggressive:
            return networkMonitor.hasReliableEstimate()
                ? max(config.minChunkSize, networkMonitor.getRecommendedChunkSize())
                : config.maxChunkSize

        case .adaptive:
            return calculateAdaptiveSize()
        }
    }

    /// Calculate chunk size optimized for a specific file size.
    /// - Parameter fileSize: Total file size in bytes
    /// - Returns: Recommended chunk size for this file
    public func calculateChunkSizeForFile(fileSize: Int64) -> Int {
        let baseSize = calculateOptimalChunkSize()

        // For small files, don't use chunks larger than 1/4 of file
        if fileSize < Int64(baseSize * 4) {
            let quarterSize = Int(fileSize / 4)
            return max(config.minChunkSize, min(quarterSize, baseSize))
        }

        // For very large files, ensure reasonable chunk count
        let maxChunks = 1000
        let minChunkForCount = Int(fileSize / Int64(maxChunks))

        return max(baseSize, minChunkForCount)
    }

    /// Record chunk upload completion for future optimization.
    /// - Parameters:
    ///   - chunkSize: Size of the uploaded chunk
    ///   - durationSeconds: Time taken to upload
    public func recordChunkUpload(chunkSize: Int, durationSeconds: TimeInterval) {
        networkMonitor.recordSample(
            bytesTransferred: Int64(chunkSize),
            durationSeconds: durationSeconds
        )
    }

    /// Get current chunk size without recalculation.
    /// - Returns: Last calculated chunk size
    public func getCurrentChunkSize() -> Int {
        return lastCalculatedSize
    }

    // MARK: - Private Methods

    private func calculateAdaptiveSize() -> Int {
        guard networkMonitor.hasReliableEstimate() else {
            return UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        }

        let speedMbps = networkMonitor.getSpeedMbps()
        let speedBps = (speedMbps * 1024 * 1024) / 8  // Convert to bytes/second

        // Calculate chunk size to achieve target upload time
        let targetSize = Int(speedBps * config.targetUploadTimeSeconds)

        // Round to nearest step size
        let stepSize = UploadConstants.CHUNK_SIZE_STEP_BYTES
        let roundedSize = (targetSize / stepSize) * stepSize

        // Clamp to configured bounds
        lastCalculatedSize = max(config.minChunkSize, min(config.maxChunkSize, roundedSize))

        return lastCalculatedSize
    }
}
```

---

## 📁 File 4: UploadSession.swift

**Path:** `Core/Upload/UploadSession.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Upload Session
// ============================================================================

import Foundation

/// Upload session state.
public enum UploadSessionState: String, Codable {
    case initialized = "initialized"   // Session created, not started
    case uploading = "uploading"       // Actively uploading chunks
    case paused = "paused"             // User-initiated pause
    case stalled = "stalled"           // No progress detected
    case completing = "completing"     // All chunks uploaded, finalizing
    case completed = "completed"       // Successfully completed
    case failed = "failed"             // Permanently failed
    case cancelled = "cancelled"       // User cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    public var canResume: Bool {
        switch self {
        case .paused, .stalled, .failed:
            return true
        default:
            return false
        }
    }
}

/// Chunk upload status.
public struct ChunkStatus: Codable, Equatable {
    public let chunkIndex: Int
    public let offset: Int64
    public let size: Int
    public var state: ChunkState
    public var retryCount: Int
    public var lastError: String?
    public var uploadedAt: Date?

    public enum ChunkState: String, Codable {
        case pending = "pending"
        case uploading = "uploading"
        case completed = "completed"
        case failed = "failed"
    }

    public init(chunkIndex: Int, offset: Int64, size: Int) {
        self.chunkIndex = chunkIndex
        self.offset = offset
        self.size = size
        self.state = .pending
        self.retryCount = 0
        self.lastError = nil
        self.uploadedAt = nil
    }
}

/// Upload session representing a single file upload with multiple chunks.
public final class UploadSession: Codable {

    // MARK: - Properties

    public let sessionId: String
    public let jobId: String
    public let fileSize: Int64
    public let fileName: String
    public let mimeType: String
    public let chunkSize: Int
    public let createdAt: Date

    public private(set) var state: UploadSessionState
    public private(set) var chunks: [ChunkStatus]
    public private(set) var uploadedBytes: Int64
    public private(set) var lastActivityAt: Date
    public private(set) var errorMessage: String?
    public private(set) var serverUploadId: String?

    /// Idempotency key for this upload session.
    public let idempotencyKey: String

    // MARK: - Computed Properties

    /// Progress as a fraction (0.0 - 1.0).
    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(uploadedBytes) / Double(fileSize)
    }

    /// Number of completed chunks.
    public var completedChunkCount: Int {
        return chunks.filter { $0.state == .completed }.count
    }

    /// Number of pending chunks.
    public var pendingChunkCount: Int {
        return chunks.filter { $0.state == .pending }.count
    }

    /// Number of failed chunks.
    public var failedChunkCount: Int {
        return chunks.filter { $0.state == .failed }.count
    }

    /// Total number of chunks.
    public var totalChunkCount: Int {
        return chunks.count
    }

    /// Whether all chunks are completed.
    public var allChunksCompleted: Bool {
        return chunks.allSatisfy { $0.state == .completed }
    }

    // MARK: - Initialization

    public init(
        jobId: String,
        fileSize: Int64,
        fileName: String,
        mimeType: String,
        chunkSize: Int
    ) {
        self.sessionId = UUID().uuidString
        self.jobId = jobId
        self.fileSize = fileSize
        self.fileName = fileName
        self.mimeType = mimeType
        self.chunkSize = chunkSize
        self.createdAt = Date()
        self.state = .initialized
        self.uploadedBytes = 0
        self.lastActivityAt = Date()
        self.idempotencyKey = "\(jobId)_\(UUID().uuidString)"

        // Calculate chunks
        self.chunks = Self.calculateChunks(fileSize: fileSize, chunkSize: chunkSize)
    }

    // MARK: - State Management

    /// Start the upload session.
    public func start(serverUploadId: String) {
        guard state == .initialized else { return }
        self.serverUploadId = serverUploadId
        self.state = .uploading
        self.lastActivityAt = Date()
    }

    /// Mark a chunk as uploading.
    public func markChunkUploading(index: Int) {
        guard index < chunks.count else { return }
        chunks[index].state = .uploading
        lastActivityAt = Date()
    }

    /// Mark a chunk as completed.
    public func markChunkCompleted(index: Int) {
        guard index < chunks.count else { return }
        chunks[index].state = .completed
        chunks[index].uploadedAt = Date()
        uploadedBytes += Int64(chunks[index].size)
        lastActivityAt = Date()

        if allChunksCompleted {
            state = .completing
        }
    }

    /// Mark a chunk as failed.
    public func markChunkFailed(index: Int, error: String) {
        guard index < chunks.count else { return }
        chunks[index].state = .failed
        chunks[index].retryCount += 1
        chunks[index].lastError = error
        lastActivityAt = Date()

        // Check if chunk exceeded max retries
        if chunks[index].retryCount >= UploadConstants.CHUNK_MAX_RETRIES {
            state = .failed
            errorMessage = "Chunk \(index) failed after \(chunks[index].retryCount) retries: \(error)"
        }
    }

    /// Reset a failed chunk for retry.
    public func resetChunkForRetry(index: Int) {
        guard index < chunks.count else { return }
        guard chunks[index].state == .failed else { return }
        guard chunks[index].retryCount < UploadConstants.CHUNK_MAX_RETRIES else { return }

        chunks[index].state = .pending
    }

    /// Pause the upload.
    public func pause() {
        guard state == .uploading else { return }
        state = .paused
        lastActivityAt = Date()
    }

    /// Resume the upload.
    public func resume() {
        guard state.canResume else { return }
        state = .uploading
        lastActivityAt = Date()
    }

    /// Mark as stalled (no progress detected).
    public func markStalled() {
        guard state == .uploading else { return }
        state = .stalled
    }

    /// Complete the upload.
    public func complete() {
        guard state == .completing else { return }
        state = .completed
        lastActivityAt = Date()
    }

    /// Fail the upload.
    public func fail(error: String) {
        state = .failed
        errorMessage = error
        lastActivityAt = Date()
    }

    /// Cancel the upload.
    public func cancel() {
        state = .cancelled
        lastActivityAt = Date()
    }

    /// Get next chunks to upload (for parallel upload).
    public func getNextChunks(count: Int) -> [ChunkStatus] {
        return Array(chunks.filter { $0.state == .pending }.prefix(count))
    }

    // MARK: - Private Methods

    private static func calculateChunks(fileSize: Int64, chunkSize: Int) -> [ChunkStatus] {
        var chunks: [ChunkStatus] = []
        var offset: Int64 = 0
        var index = 0

        while offset < fileSize {
            let remainingBytes = fileSize - offset
            let thisChunkSize = min(Int(remainingBytes), chunkSize)

            chunks.append(ChunkStatus(
                chunkIndex: index,
                offset: offset,
                size: thisChunkSize
            ))

            offset += Int64(thisChunkSize)
            index += 1
        }

        return chunks
    }
}
```

---

## 📁 File 5: ChunkManager.swift

**Path:** `Core/Upload/ChunkManager.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Chunk Manager
// ============================================================================

import Foundation

/// Delegate protocol for chunk upload events.
public protocol ChunkManagerDelegate: AnyObject {
    func chunkManager(_ manager: ChunkManager, didStartChunk index: Int, of total: Int)
    func chunkManager(_ manager: ChunkManager, didCompleteChunk index: Int, of total: Int)
    func chunkManager(_ manager: ChunkManager, didFailChunk index: Int, with error: Error)
    func chunkManager(_ manager: ChunkManager, didUpdateProgress progress: Double)
    func chunkManager(_ manager: ChunkManager, didCompleteSession session: UploadSession)
    func chunkManager(_ manager: ChunkManager, didFailSession session: UploadSession, with error: Error)
}

/// Chunk upload error types.
public enum ChunkUploadError: Error, LocalizedError {
    case sessionNotStarted
    case sessionAlreadyCompleted
    case chunkIndexOutOfBounds(Int)
    case networkError(underlying: Error)
    case serverError(statusCode: Int, message: String)
    case timeout
    case cancelled
    case maxRetriesExceeded(chunkIndex: Int)
    case stallDetected

    public var errorDescription: String? {
        switch self {
        case .sessionNotStarted:
            return "Upload session has not been started"
        case .sessionAlreadyCompleted:
            return "Upload session is already completed"
        case .chunkIndexOutOfBounds(let index):
            return "Chunk index \(index) is out of bounds"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error \(code): \(message)"
        case .timeout:
            return "Chunk upload timed out"
        case .cancelled:
            return "Upload was cancelled"
        case .maxRetriesExceeded(let index):
            return "Chunk \(index) exceeded maximum retry attempts"
        case .stallDetected:
            return "Upload stalled - no progress detected"
        }
    }
}

/// Manages parallel chunk uploads for a session.
/// Coordinates chunk scheduling, retries, and progress aggregation.
public final class ChunkManager {

    // MARK: - Properties

    public weak var delegate: ChunkManagerDelegate?

    private let session: UploadSession
    private let networkMonitor: NetworkSpeedMonitor
    private let chunkSizer: AdaptiveChunkSizer
    private let uploadQueue: OperationQueue
    private let progressQueue = DispatchQueue(label: "com.app.chunkmanager.progress")

    private var activeUploads: Set<Int> = []
    private var lastProgressUpdate: Date = Date()
    private var lastProgressBytes: Int64 = 0
    private var stallCheckTimer: Timer?
    private var isCancelled = false

    // MARK: - Initialization

    public init(
        session: UploadSession,
        networkMonitor: NetworkSpeedMonitor,
        chunkSizer: AdaptiveChunkSizer
    ) {
        self.session = session
        self.networkMonitor = networkMonitor
        self.chunkSizer = chunkSizer

        self.uploadQueue = OperationQueue()
        self.uploadQueue.name = "com.app.chunkmanager.upload"
        self.uploadQueue.maxConcurrentOperationCount = networkMonitor.getRecommendedParallelCount()
    }

    // MARK: - Public Methods

    /// Start uploading all chunks.
    public func startUpload() {
        guard session.state == .uploading else {
            delegate?.chunkManager(self, didFailSession: session, with: ChunkUploadError.sessionNotStarted)
            return
        }

        isCancelled = false
        startStallDetection()
        scheduleNextChunks()
    }

    /// Pause the upload.
    public func pauseUpload() {
        session.pause()
        uploadQueue.isSuspended = true
        stopStallDetection()
    }

    /// Resume the upload.
    public func resumeUpload() {
        session.resume()
        uploadQueue.isSuspended = false
        startStallDetection()
        scheduleNextChunks()
    }

    /// Cancel the upload.
    public func cancelUpload() {
        isCancelled = true
        session.cancel()
        uploadQueue.cancelAllOperations()
        stopStallDetection()
    }

    /// Retry failed chunks.
    public func retryFailedChunks() {
        for index in 0..<session.chunks.count {
            if session.chunks[index].state == .failed {
                session.resetChunkForRetry(index: index)
            }
        }

        if session.state == .failed || session.state == .stalled {
            session.resume()
        }

        scheduleNextChunks()
    }

    // MARK: - Private Methods

    private func scheduleNextChunks() {
        guard !isCancelled else { return }
        guard session.state == .uploading else { return }

        let parallelCount = networkMonitor.getRecommendedParallelCount()
        let availableSlots = parallelCount - activeUploads.count

        guard availableSlots > 0 else { return }

        let nextChunks = session.getNextChunks(count: availableSlots)

        for chunk in nextChunks {
            scheduleChunkUpload(chunk)
        }

        // Check if all done
        if session.allChunksCompleted {
            finalizeUpload()
        } else if nextChunks.isEmpty && activeUploads.isEmpty {
            // No more chunks to upload and no active uploads
            if session.failedChunkCount > 0 {
                delegate?.chunkManager(self, didFailSession: session, with: ChunkUploadError.maxRetriesExceeded(chunkIndex: -1))
            }
        }
    }

    private func scheduleChunkUpload(_ chunk: ChunkStatus) {
        guard !activeUploads.contains(chunk.chunkIndex) else { return }

        activeUploads.insert(chunk.chunkIndex)
        session.markChunkUploading(index: chunk.chunkIndex)

        delegate?.chunkManager(self, didStartChunk: chunk.chunkIndex, of: session.totalChunkCount)

        // Create upload operation
        let operation = BlockOperation { [weak self] in
            self?.uploadChunk(chunk)
        }

        uploadQueue.addOperation(operation)
    }

    private func uploadChunk(_ chunk: ChunkStatus) {
        // Simulate chunk upload (replace with actual network call)
        let startTime = Date()

        // TODO: Replace with actual upload implementation
        // This should:
        // 1. Read chunk data from file at chunk.offset with chunk.size bytes
        // 2. Send PATCH request to server with chunk data
        // 3. Include tus.io headers (Upload-Offset, etc.)
        // 4. Handle response and retry on failure

        // For now, simulate success after delay
        Thread.sleep(forTimeInterval: 0.5)

        let duration = Date().timeIntervalSince(startTime)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Record for adaptive sizing
            self.chunkSizer.recordChunkUpload(chunkSize: chunk.size, durationSeconds: duration)

            // Mark completed
            self.activeUploads.remove(chunk.chunkIndex)
            self.session.markChunkCompleted(index: chunk.chunkIndex)

            // Update progress
            self.updateProgress()

            self.delegate?.chunkManager(self, didCompleteChunk: chunk.chunkIndex, of: self.session.totalChunkCount)

            // Schedule more chunks
            self.scheduleNextChunks()
        }
    }

    private func handleChunkFailure(_ chunk: ChunkStatus, error: Error) {
        activeUploads.remove(chunk.chunkIndex)
        session.markChunkFailed(index: chunk.chunkIndex, error: error.localizedDescription)

        delegate?.chunkManager(self, didFailChunk: chunk.chunkIndex, with: error)

        if session.state == .failed {
            delegate?.chunkManager(self, didFailSession: session, with: error)
        } else {
            // Try to schedule replacement chunk
            scheduleNextChunks()
        }
    }

    private func updateProgress() {
        let progress = session.progress

        progressQueue.async { [weak self] in
            guard let self = self else { return }

            let now = Date()
            let timeSinceLastUpdate = now.timeIntervalSince(self.lastProgressUpdate)
            let bytesSinceLastUpdate = self.session.uploadedBytes - self.lastProgressBytes

            // Throttle progress updates
            if timeSinceLastUpdate >= UploadConstants.PROGRESS_THROTTLE_INTERVAL_SECONDS ||
               bytesSinceLastUpdate >= Int64(UploadConstants.PROGRESS_MIN_BYTES_DELTA) {

                self.lastProgressUpdate = now
                self.lastProgressBytes = self.session.uploadedBytes

                DispatchQueue.main.async {
                    self.delegate?.chunkManager(self, didUpdateProgress: progress)
                }
            }
        }
    }

    private func finalizeUpload() {
        stopStallDetection()

        // TODO: Send completion request to server
        // This should:
        // 1. Send POST request to finalize the upload
        // 2. Wait for server to assemble chunks
        // 3. Mark session as completed or failed

        session.complete()
        delegate?.chunkManager(self, didCompleteSession: session)
    }

    private func startStallDetection() {
        stopStallDetection()

        stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkForStall()
        }
    }

    private func stopStallDetection() {
        stallCheckTimer?.invalidate()
        stallCheckTimer = nil
    }

    private func checkForStall() {
        let timeSinceActivity = Date().timeIntervalSince(session.lastActivityAt)

        if timeSinceActivity > UploadConstants.STALL_DETECTION_TIMEOUT_SECONDS {
            session.markStalled()
            delegate?.chunkManager(self, didFailSession: session, with: ChunkUploadError.stallDetected)
        }
    }
}
```

---

## 📁 File 6: UploadResumeManager.swift

**Path:** `Core/Upload/UploadResumeManager.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Resume Manager
// ============================================================================

import Foundation

/// Resume manager for persisting and recovering upload sessions.
/// Implements tus.io resumable upload protocol for server coordination.
public final class UploadResumeManager {

    // MARK: - Properties

    private let storage: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Key prefix for stored sessions.
    private let keyPrefix = UploadConstants.RESUME_STATE_KEY_PREFIX

    // MARK: - Initialization

    public init(storage: UserDefaults = .standard) {
        self.storage = storage
    }

    // MARK: - Public Methods

    /// Save session state for later resume.
    /// - Parameter session: The session to persist
    public func saveSession(_ session: UploadSession) throws {
        let key = keyForSession(session.sessionId)
        let data = try encoder.encode(session)
        storage.set(data, forKey: key)
    }

    /// Load a saved session.
    /// - Parameter sessionId: The session ID to load
    /// - Returns: The loaded session, or nil if not found
    public func loadSession(sessionId: String) -> UploadSession? {
        let key = keyForSession(sessionId)
        guard let data = storage.data(forKey: key) else { return nil }

        return try? decoder.decode(UploadSession.self, from: data)
    }

    /// Load session by job ID.
    /// - Parameter jobId: The job ID associated with the session
    /// - Returns: The loaded session, or nil if not found
    public func loadSessionForJob(jobId: String) -> UploadSession? {
        let sessions = loadAllSessions()
        return sessions.first { $0.jobId == jobId && !$0.state.isTerminal }
    }

    /// Load all saved sessions.
    /// - Returns: Array of all persisted sessions
    public func loadAllSessions() -> [UploadSession] {
        let keys = storage.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }

        return keys.compactMap { key -> UploadSession? in
            guard let data = storage.data(forKey: key) else { return nil }
            return try? decoder.decode(UploadSession.self, from: data)
        }
    }

    /// Delete a saved session.
    /// - Parameter sessionId: The session ID to delete
    public func deleteSession(sessionId: String) {
        let key = keyForSession(sessionId)
        storage.removeObject(forKey: key)
    }

    /// Delete session for job.
    /// - Parameter jobId: The job ID associated with the session
    public func deleteSessionForJob(jobId: String) {
        if let session = loadSessionForJob(jobId: jobId) {
            deleteSession(sessionId: session.sessionId)
        }
    }

    /// Clean up expired sessions.
    /// - Returns: Number of sessions cleaned up
    @discardableResult
    public func cleanupExpiredSessions() -> Int {
        let sessions = loadAllSessions()
        let maxAge = UploadConstants.UPLOAD_SESSION_MAX_AGE_SECONDS
        let cutoff = Date().addingTimeInterval(-maxAge)

        var cleanedCount = 0

        for session in sessions {
            if session.createdAt < cutoff || session.state.isTerminal {
                deleteSession(sessionId: session.sessionId)
                cleanedCount += 1
            }
        }

        return cleanedCount
    }

    /// Check if a resumable session exists for a job.
    /// - Parameter jobId: The job ID to check
    /// - Returns: True if a resumable session exists
    public func hasResumableSession(forJob jobId: String) -> Bool {
        guard let session = loadSessionForJob(jobId: jobId) else { return false }
        return session.state.canResume
    }

    /// Get resume info for display.
    /// - Parameter jobId: The job ID
    /// - Returns: Resume info dictionary
    public func getResumeInfo(forJob jobId: String) -> [String: Any]? {
        guard let session = loadSessionForJob(jobId: jobId) else { return nil }

        return [
            "sessionId": session.sessionId,
            "fileName": session.fileName,
            "fileSize": session.fileSize,
            "progress": session.progress,
            "completedChunks": session.completedChunkCount,
            "totalChunks": session.totalChunkCount,
            "state": session.state.rawValue,
            "lastActivity": session.lastActivityAt
        ]
    }

    /// Query server for actual upload offset (tus.io HEAD request).
    /// - Parameters:
    ///   - session: The session to query
    ///   - completion: Completion handler with server offset or error
    public func queryServerOffset(
        for session: UploadSession,
        completion: @escaping (Result<Int64, Error>) -> Void
    ) {
        // TODO: Implement actual HEAD request to server
        // This should:
        // 1. Send HEAD request to upload URL
        // 2. Read Upload-Offset header from response
        // 3. Update local session state to match server

        // For now, return local offset
        completion(.success(session.uploadedBytes))
    }

    /// Reconcile local session state with server.
    /// - Parameters:
    ///   - session: The session to reconcile
    ///   - serverOffset: The offset reported by server
    /// - Returns: Updated session with reconciled state
    public func reconcileWithServer(
        session: UploadSession,
        serverOffset: Int64
    ) -> UploadSession {
        // Find which chunks need to be re-uploaded based on server offset
        // Mark chunks after server offset as pending

        for (index, chunk) in session.chunks.enumerated() {
            if chunk.offset >= serverOffset {
                // This chunk needs to be re-uploaded
                if chunk.state == .completed {
                    session.chunks[index].state = .pending
                    session.chunks[index].uploadedAt = nil
                }
            }
        }

        return session
    }

    // MARK: - Private Methods

    private func keyForSession(_ sessionId: String) -> String {
        return "\(keyPrefix)\(sessionId)"
    }
}
```

---

## 📁 File 7: UploadProgressTracker.swift

**Path:** `Core/Upload/UploadProgressTracker.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Progress Tracker
// ============================================================================

import Foundation

/// Progress event for upload tracking.
public struct UploadProgressEvent {
    public let sessionId: String
    public let bytesUploaded: Int64
    public let totalBytes: Int64
    public let progress: Double
    public let speedBps: Double
    public let estimatedRemainingSeconds: TimeInterval?
    public let chunksCompleted: Int
    public let totalChunks: Int
    public let timestamp: Date

    public var progressPercent: Double {
        return progress * 100
    }

    public var speedMbps: Double {
        return (speedBps * 8) / (1024 * 1024)
    }

    public var formattedSpeed: String {
        if speedMbps >= 1 {
            return String(format: "%.1f Mbps", speedMbps)
        } else {
            let kbps = (speedBps * 8) / 1024
            return String(format: "%.0f Kbps", kbps)
        }
    }

    public var formattedETA: String? {
        guard let remaining = estimatedRemainingSeconds else { return nil }

        if remaining < 60 {
            return String(format: "%.0f sec", remaining)
        } else if remaining < 3600 {
            let minutes = Int(remaining / 60)
            let seconds = Int(remaining.truncatingRemainder(dividingBy: 60))
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            return String(format: "%d:%02d:00", hours, minutes)
        }
    }
}

/// Delegate protocol for progress updates.
public protocol UploadProgressTrackerDelegate: AnyObject {
    func progressTracker(_ tracker: UploadProgressTracker, didUpdate event: UploadProgressEvent)
}

/// Aggregates and smooths upload progress across multiple chunks.
public final class UploadProgressTracker {

    // MARK: - Properties

    public weak var delegate: UploadProgressTrackerDelegate?

    private let session: UploadSession
    private var speedSamples: [(bytes: Int64, timestamp: Date)] = []
    private let maxSpeedSamples = 10
    private var lastReportedProgress: Double = 0
    private var lastReportTime: Date = Date()

    // MARK: - Initialization

    public init(session: UploadSession) {
        self.session = session
    }

    // MARK: - Public Methods

    /// Record bytes uploaded and potentially emit progress event.
    /// - Parameter bytes: Bytes uploaded since last call
    public func recordProgress(bytes: Int64) {
        let now = Date()

        speedSamples.append((bytes: bytes, timestamp: now))
        if speedSamples.count > maxSpeedSamples {
            speedSamples.removeFirst()
        }

        // Check if we should emit progress event
        let progress = session.progress
        let progressDelta = progress - lastReportedProgress
        let timeDelta = now.timeIntervalSince(lastReportTime)

        if progressDelta >= 0.01 || timeDelta >= 1.0 {
            emitProgressEvent()
            lastReportedProgress = progress
            lastReportTime = now
        }
    }

    /// Force emit a progress event.
    public func forceEmit() {
        emitProgressEvent()
    }

    /// Get current progress event.
    /// - Returns: Current progress state
    public func getCurrentProgress() -> UploadProgressEvent {
        return createProgressEvent()
    }

    // MARK: - Private Methods

    private func emitProgressEvent() {
        let event = createProgressEvent()
        delegate?.progressTracker(self, didUpdate: event)
    }

    private func createProgressEvent() -> UploadProgressEvent {
        let speed = calculateCurrentSpeed()
        let eta = calculateETA(speedBps: speed)

        return UploadProgressEvent(
            sessionId: session.sessionId,
            bytesUploaded: session.uploadedBytes,
            totalBytes: session.fileSize,
            progress: session.progress,
            speedBps: speed,
            estimatedRemainingSeconds: eta,
            chunksCompleted: session.completedChunkCount,
            totalChunks: session.totalChunkCount,
            timestamp: Date()
        )
    }

    private func calculateCurrentSpeed() -> Double {
        guard speedSamples.count >= 2 else { return 0 }

        let totalBytes = speedSamples.reduce(0) { $0 + $1.bytes }
        let firstTime = speedSamples.first!.timestamp
        let lastTime = speedSamples.last!.timestamp
        let duration = lastTime.timeIntervalSince(firstTime)

        guard duration > 0 else { return 0 }

        return Double(totalBytes) / duration
    }

    private func calculateETA(speedBps: Double) -> TimeInterval? {
        guard speedBps > 0 else { return nil }

        let remainingBytes = session.fileSize - session.uploadedBytes
        return Double(remainingBytes) / speedBps
    }
}
```

---

## 🔧 Modifications to Existing Files

### Modify: Core/Constants/APIContractConstants.swift

Add the following at the end of the file (before closing brace):

```swift
    // MARK: - Upload Configuration (Deprecated - Use UploadConstants)

    /// @deprecated Use UploadConstants.CHUNK_SIZE_DEFAULT_BYTES instead
    @available(*, deprecated, message: "Use UploadConstants.CHUNK_SIZE_DEFAULT_BYTES")
    public static let CHUNK_SIZE_BYTES = 5 * 1024 * 1024

    // MARK: - PR3 Upload Infrastructure Reference

    /// Upload module constants are now in UploadConstants.swift
    /// See: Core/Constants/UploadConstants.swift for:
    /// - Adaptive chunk sizing
    /// - Network speed thresholds
    /// - Parallel upload configuration
    /// - tus.io protocol headers
```

### Modify: Core/Jobs/ContractConstants.swift

Update the contract version header and add PR3 reference:

```swift
// Change line 3:
// Contract Version: PR2-JSM-3.0-merged
// To:
// Contract Version: PR3-API-1.0

// Change line 14:
// public static let CONTRACT_VERSION = "PR2-JSM-3.0-merged"
// To:
public static let CONTRACT_VERSION = "PR3-API-1.0"

// Add after line 14:
    /// Upload infrastructure version (see UploadConstants.swift)
    public static let UPLOAD_MODULE_VERSION = "PR3-UPLOAD-1.0"
```

### Modify: Core/API/APIEndpoints.swift

Add new upload endpoints:

```swift
    // MARK: - Chunked Upload (PR3)

    /// Create upload session (tus.io POST)
    /// POST /api/v1/upload/sessions
    case createUploadSession

    /// Upload chunk (tus.io PATCH)
    /// PATCH /api/v1/upload/sessions/{sessionId}
    case uploadChunk(sessionId: String)

    /// Query upload offset (tus.io HEAD)
    /// HEAD /api/v1/upload/sessions/{sessionId}
    case queryUploadOffset(sessionId: String)

    /// Finalize upload
    /// POST /api/v1/upload/sessions/{sessionId}/finalize
    case finalizeUpload(sessionId: String)

    /// Cancel upload session
    /// DELETE /api/v1/upload/sessions/{sessionId}
    case cancelUploadSession(sessionId: String)
```

---

## 🧪 Test Files

### Tests/Upload/ChunkManagerTests.swift

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests
// ============================================================================

import XCTest
@testable import YourModuleName

final class ChunkManagerTests: XCTestCase {

    var networkMonitor: NetworkSpeedMonitor!
    var chunkSizer: AdaptiveChunkSizer!

    override func setUp() {
        super.setUp()
        networkMonitor = NetworkSpeedMonitor()
        chunkSizer = AdaptiveChunkSizer(networkMonitor: networkMonitor)
    }

    // MARK: - Session Creation Tests

    func testSessionCreation() {
        let session = UploadSession(
            jobId: "test-job-123",
            fileSize: 50 * 1024 * 1024,  // 50MB
            fileName: "test.mp4",
            mimeType: "video/mp4",
            chunkSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        )

        XCTAssertEqual(session.state, .initialized)
        XCTAssertEqual(session.totalChunkCount, 10)  // 50MB / 5MB = 10 chunks
        XCTAssertEqual(session.progress, 0)
    }

    func testChunkCalculation() {
        let session = UploadSession(
            jobId: "test-job",
            fileSize: 12 * 1024 * 1024,  // 12MB
            fileName: "test.mp4",
            mimeType: "video/mp4",
            chunkSize: 5 * 1024 * 1024  // 5MB chunks
        )

        XCTAssertEqual(session.totalChunkCount, 3)
        XCTAssertEqual(session.chunks[0].size, 5 * 1024 * 1024)
        XCTAssertEqual(session.chunks[1].size, 5 * 1024 * 1024)
        XCTAssertEqual(session.chunks[2].size, 2 * 1024 * 1024)  // Remaining
    }

    // MARK: - State Transition Tests

    func testSessionStateTransitions() {
        let session = UploadSession(
            jobId: "test",
            fileSize: 10 * 1024 * 1024,
            fileName: "test.mp4",
            mimeType: "video/mp4",
            chunkSize: 5 * 1024 * 1024
        )

        XCTAssertEqual(session.state, .initialized)

        session.start(serverUploadId: "server-123")
        XCTAssertEqual(session.state, .uploading)

        session.pause()
        XCTAssertEqual(session.state, .paused)

        session.resume()
        XCTAssertEqual(session.state, .uploading)

        session.cancel()
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertTrue(session.state.isTerminal)
    }

    // MARK: - Chunk State Tests

    func testChunkCompletion() {
        let session = UploadSession(
            jobId: "test",
            fileSize: 10 * 1024 * 1024,
            fileName: "test.mp4",
            mimeType: "video/mp4",
            chunkSize: 5 * 1024 * 1024
        )

        session.start(serverUploadId: "server-123")

        session.markChunkUploading(index: 0)
        XCTAssertEqual(session.chunks[0].state, .uploading)

        session.markChunkCompleted(index: 0)
        XCTAssertEqual(session.chunks[0].state, .completed)
        XCTAssertEqual(session.completedChunkCount, 1)
        XCTAssertEqual(session.uploadedBytes, 5 * 1024 * 1024)
    }

    func testChunkRetry() {
        let session = UploadSession(
            jobId: "test",
            fileSize: 10 * 1024 * 1024,
            fileName: "test.mp4",
            mimeType: "video/mp4",
            chunkSize: 5 * 1024 * 1024
        )

        session.start(serverUploadId: "server-123")

        session.markChunkFailed(index: 0, error: "Network error")
        XCTAssertEqual(session.chunks[0].state, .failed)
        XCTAssertEqual(session.chunks[0].retryCount, 1)

        session.resetChunkForRetry(index: 0)
        XCTAssertEqual(session.chunks[0].state, .pending)
    }

    // MARK: - Progress Tests

    func testProgressCalculation() {
        let session = UploadSession(
            jobId: "test",
            fileSize: 20 * 1024 * 1024,  // 20MB
            fileName: "test.mp4",
            mimeType: "video/mp4",
            chunkSize: 5 * 1024 * 1024  // 4 chunks
        )

        session.start(serverUploadId: "server-123")

        XCTAssertEqual(session.progress, 0, accuracy: 0.01)

        session.markChunkCompleted(index: 0)
        XCTAssertEqual(session.progress, 0.25, accuracy: 0.01)

        session.markChunkCompleted(index: 1)
        XCTAssertEqual(session.progress, 0.50, accuracy: 0.01)

        session.markChunkCompleted(index: 2)
        XCTAssertEqual(session.progress, 0.75, accuracy: 0.01)

        session.markChunkCompleted(index: 3)
        XCTAssertEqual(session.progress, 1.0, accuracy: 0.01)
    }
}
```

### Tests/Upload/AdaptiveChunkSizerTests.swift

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Adaptive Chunk Sizer
// ============================================================================

import XCTest
@testable import YourModuleName

final class AdaptiveChunkSizerTests: XCTestCase {

    var networkMonitor: NetworkSpeedMonitor!

    override func setUp() {
        super.setUp()
        networkMonitor = NetworkSpeedMonitor()
    }

    // MARK: - Strategy Tests

    func testFixedStrategy() {
        let config = AdaptiveChunkConfig(
            strategy: .fixed,
            minChunkSize: UploadConstants.CHUNK_SIZE_MIN_BYTES,
            maxChunkSize: UploadConstants.CHUNK_SIZE_MAX_BYTES,
            targetUploadTimeSeconds: 10.0
        )

        let sizer = AdaptiveChunkSizer(networkMonitor: networkMonitor, config: config)

        XCTAssertEqual(sizer.calculateOptimalChunkSize(), UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    func testConservativeStrategy() {
        let config = AdaptiveChunkConfig(
            strategy: .conservative,
            minChunkSize: UploadConstants.CHUNK_SIZE_MIN_BYTES,
            maxChunkSize: UploadConstants.CHUNK_SIZE_MAX_BYTES,
            targetUploadTimeSeconds: 10.0
        )

        let sizer = AdaptiveChunkSizer(networkMonitor: networkMonitor, config: config)

        XCTAssertEqual(sizer.calculateOptimalChunkSize(), UploadConstants.CHUNK_SIZE_MIN_BYTES)
    }

    // MARK: - Adaptive Tests

    func testAdaptiveWithSlowNetwork() {
        let sizer = AdaptiveChunkSizer(networkMonitor: networkMonitor)

        // Simulate slow network (2 Mbps = ~250 KB/s)
        for _ in 0..<5 {
            networkMonitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        let chunkSize = sizer.calculateOptimalChunkSize()
        XCTAssertLessThanOrEqual(chunkSize, UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    func testAdaptiveWithFastNetwork() {
        let sizer = AdaptiveChunkSizer(networkMonitor: networkMonitor)

        // Simulate fast network (100 Mbps = ~12.5 MB/s)
        for _ in 0..<5 {
            networkMonitor.recordSample(bytesTransferred: 12_500_000, durationSeconds: 1.0)
        }

        let chunkSize = sizer.calculateOptimalChunkSize()
        XCTAssertGreaterThanOrEqual(chunkSize, UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    // MARK: - File Size Tests

    func testChunkSizeForSmallFile() {
        let sizer = AdaptiveChunkSizer(networkMonitor: networkMonitor)

        // 8MB file should not use 5MB chunks
        let chunkSize = sizer.calculateChunkSizeForFile(fileSize: 8 * 1024 * 1024)

        XCTAssertLessThanOrEqual(chunkSize, 2 * 1024 * 1024)
    }

    func testChunkSizeForLargeFile() {
        let sizer = AdaptiveChunkSizer(networkMonitor: networkMonitor)

        // 5GB file should have reasonable chunk count
        let chunkSize = sizer.calculateChunkSizeForFile(fileSize: 5 * 1024 * 1024 * 1024)

        let chunkCount = (5 * 1024 * 1024 * 1024) / Int64(chunkSize)
        XCTAssertLessThanOrEqual(chunkCount, 1000)
    }
}
```

### Tests/Upload/NetworkSpeedMonitorTests.swift

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Network Speed Monitor
// ============================================================================

import XCTest
@testable import YourModuleName

final class NetworkSpeedMonitorTests: XCTestCase {

    // MARK: - Classification Tests

    func testSlowNetworkClassification() {
        let monitor = NetworkSpeedMonitor()

        // 2 Mbps = ~250 KB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .slow)
    }

    func testNormalNetworkClassification() {
        let monitor = NetworkSpeedMonitor()

        // 20 Mbps = ~2.5 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 2_500_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .normal)
    }

    func testFastNetworkClassification() {
        let monitor = NetworkSpeedMonitor()

        // 80 Mbps = ~10 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .fast)
    }

    func testUltrafastNetworkClassification() {
        let monitor = NetworkSpeedMonitor()

        // 200 Mbps = ~25 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 25_000_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .ultrafast)
    }

    // MARK: - Reliability Tests

    func testUnknownWithInsufficientSamples() {
        let monitor = NetworkSpeedMonitor()

        monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)

        XCTAssertFalse(monitor.hasReliableEstimate())
        XCTAssertEqual(monitor.getSpeedClass(), .unknown)
    }

    func testReliableWithSufficientSamples() {
        let monitor = NetworkSpeedMonitor()

        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)
        }

        XCTAssertTrue(monitor.hasReliableEstimate())
    }

    // MARK: - Reset Tests

    func testReset() {
        let monitor = NetworkSpeedMonitor()

        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)
        }

        XCTAssertTrue(monitor.hasReliableEstimate())

        monitor.reset()

        XCTAssertFalse(monitor.hasReliableEstimate())
        XCTAssertEqual(monitor.getSpeedClass(), .unknown)
    }
}
```

---

## ✅ Post-Implementation Verification

Run the following commands after implementation:

```bash
# 1. Build verification
swift build 2>&1 | tee /tmp/pr3-build.log
if grep -i "error:" /tmp/pr3-build.log; then
  echo "❌ BUILD FAILED"
  exit 1
fi
echo "✅ Build passed"

# 2. Test verification
swift test 2>&1 | tee /tmp/pr3-test.log
if grep "failed" /tmp/pr3-test.log | grep -v "0 failed"; then
  echo "❌ TESTS FAILED"
  exit 1
fi
echo "✅ All tests passed"

# 3. Contract version verification
grep "PR3-API-1.0" Core/Jobs/ContractConstants.swift && echo "✅ Contract version updated"
grep "PR3-UPLOAD-1.0" Core/Constants/UploadConstants.swift && echo "✅ Upload module version set"

# 4. File existence verification
ls -la Core/Upload/ChunkManager.swift && echo "✅ ChunkManager.swift exists"
ls -la Core/Upload/AdaptiveChunkSizer.swift && echo "✅ AdaptiveChunkSizer.swift exists"
ls -la Core/Upload/NetworkSpeedMonitor.swift && echo "✅ NetworkSpeedMonitor.swift exists"
ls -la Core/Upload/UploadSession.swift && echo "✅ UploadSession.swift exists"
ls -la Core/Upload/UploadResumeManager.swift && echo "✅ UploadResumeManager.swift exists"
ls -la Core/Upload/UploadProgressTracker.swift && echo "✅ UploadProgressTracker.swift exists"
ls -la Core/Constants/UploadConstants.swift && echo "✅ UploadConstants.swift exists"

# 5. New test files verification
ls -la Tests/Upload/*.swift && echo "✅ Upload test files exist"
```

---

## 📝 Git Commit Message

```bash
git commit -m "$(cat <<'EOF'
feat(pr3): implement enterprise-grade upload infrastructure

BREAKING CHANGE: Contract version updated to PR3-API-1.0

New Features:
- Adaptive chunk sizing (2MB-20MB based on network speed)
- Parallel chunk uploads (up to 4 concurrent)
- Network speed monitoring with weighted averaging
- Upload session lifecycle management
- Resume/recovery with persistence
- Stall detection and auto-retry
- Progress tracking with ETA calculation
- tus.io protocol compatibility

New Files:
- Core/Upload/ChunkManager.swift - Parallel upload orchestration
- Core/Upload/AdaptiveChunkSizer.swift - Network-aware sizing
- Core/Upload/NetworkSpeedMonitor.swift - Bandwidth measurement
- Core/Upload/UploadSession.swift - Session state management
- Core/Upload/UploadResumeManager.swift - Resume persistence
- Core/Upload/UploadProgressTracker.swift - Progress aggregation
- Core/Constants/UploadConstants.swift - Upload configuration

Network Speed Thresholds:
- Slow: < 5 Mbps → 2MB chunks
- Normal: 5-50 Mbps → 5MB chunks
- Fast: 50-100 Mbps → 10MB chunks
- Ultrafast: > 100 Mbps → 20MB chunks

References:
- tus.io resumable upload protocol v1.0.0
- AWS S3 Transfer Acceleration best practices
- Netflix/AWS decorrelated jitter pattern

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## ⚠️ Implementation Notes

1. **Thread Safety**: All managers use serial dispatch queues for thread safety
2. **Memory Management**: Use weak references for delegates to avoid retain cycles
3. **Error Handling**: All errors are typed with LocalizedError for debugging
4. **Testing**: Mock NetworkSpeedMonitor for deterministic tests
5. **tus.io Compliance**: Headers follow tus.io v1.0.0 specification

## 🔗 References

- [tus.io Protocol Specification](https://tus.io/protocols/resumable-upload.html)
- [AWS S3 Multipart Upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
- [Netflix/AWS Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- [Nielsen Norman Group Response Time Limits](https://www.nngroup.com/articles/response-times-3-important-limits/)
