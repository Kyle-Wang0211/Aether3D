# PR3 Upload Infrastructure - 最终精确补丁提示词

## 📌 当前状态

- **分支**: `pr3/upload-infrastructure`
- **基准**: 已包含 PR2-JSM-3.0-merged 的 main
- **模块名**: `Aether3DCore`
- **目标合同版本**: `PR3-API-1.0`

---

## 🔧 补丁 1: Package.swift 修改

**文件**: `/Users/kaidongwang/Documents/progecttwo/progect2/progect2/Package.swift`

**精确修改位置**: 第 59 行和第 73 行之间

### 修改 1.1: 更新 exclude 列表 (第 59 行)

```swift
// 当前 (第 59 行):
exclude: ["Constants", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],

// 修改为:
exclude: ["Constants", "Upload", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],
```

### 修改 1.2: 在第 73 行 `)` 之前添加新 test target

```swift
    // 在 ConstantsTests 的闭合括号 `)` 之后 (第 73 行之后), 添加:
    ,
    .testTarget(
      name: "UploadTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Upload"
    )
```

### Package.swift 完整修改后效果

```swift
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests",
      exclude: ["Constants", "Upload", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],  // 添加 "Upload"
      resources: [
        .process("QualityPreCheck/Fixtures/CoverageDeltaEndiannessFixture.json"),
        .process("QualityPreCheck/Fixtures/CoverageGridPackingFixture.json"),
        .process("QualityPreCheck/Fixtures/CanonicalJSONFloatFixture.json")
      ]
    ),
    .testTarget(
      name: "ConstantsTests",
      dependencies: [
        "Aether3DCore",
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Tests/Constants"
    ),
    .testTarget(
      name: "UploadTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Upload"
    )
```

---

## 📁 补丁 2: 创建目录结构

**执行以下 shell 命令**:

```bash
# 创建 Core/Upload 目录
mkdir -p Core/Upload

# 创建 Tests/Upload 目录
mkdir -p Tests/Upload

# 验证
ls -la Core/Upload
ls -la Tests/Upload
```

---

## 📄 补丁 3: 创建源文件 (按依赖顺序)

### 3.1 创建 `Core/Constants/UploadConstants.swift`

**完整代码见 PR3_UPLOAD_INFRASTRUCTURE_DETAILED_PROMPT.md 第 208-535 行**

关键常量:
```swift
public enum UploadConstants {
    public static let UPLOAD_CONTRACT_VERSION = "PR3-UPLOAD-1.0"
    public static let CHUNK_SIZE_MIN_BYTES: Int = 2 * 1024 * 1024      // 2MB
    public static let CHUNK_SIZE_DEFAULT_BYTES: Int = 5 * 1024 * 1024  // 5MB
    public static let CHUNK_SIZE_MAX_BYTES: Int = 20 * 1024 * 1024     // 20MB
    public static let MAX_PARALLEL_CHUNK_UPLOADS: Int = 4
    public static let NETWORK_SPEED_SLOW_MBPS: Double = 5.0
    public static let NETWORK_SPEED_NORMAL_MBPS: Double = 50.0
    public static let NETWORK_SPEED_FAST_MBPS: Double = 100.0
    // ... 其余常量
}
```

### 3.2 创建 `Core/Upload/NetworkSpeedMonitor.swift`

**完整代码见 PR3_UPLOAD_INFRASTRUCTURE_DETAILED_PROMPT.md 第 567-982 行**

关键类型:
```swift
public enum NetworkSpeedClass: String, Codable, CaseIterable { ... }
public struct SpeedSample: Codable, Equatable { ... }
public final class NetworkSpeedMonitor { ... }
```

### 3.3 创建 `Core/Upload/AdaptiveChunkSizer.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Adaptive Chunk Sizer
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Chunk sizing strategy enumeration.
public enum ChunkSizingStrategy: String, Codable {
    case fixed = "fixed"
    case adaptive = "adaptive"
    case aggressive = "aggressive"
}

/// Adaptive chunk sizer configuration.
public struct AdaptiveChunkConfig: Codable, Equatable {
    public let strategy: ChunkSizingStrategy
    public let minChunkSize: Int
    public let maxChunkSize: Int
    public let targetUploadTime: TimeInterval

    public init(
        strategy: ChunkSizingStrategy = .adaptive,
        minChunkSize: Int = UploadConstants.CHUNK_SIZE_MIN_BYTES,
        maxChunkSize: Int = UploadConstants.CHUNK_SIZE_MAX_BYTES,
        targetUploadTime: TimeInterval = 10.0
    ) {
        self.strategy = strategy
        self.minChunkSize = minChunkSize
        self.maxChunkSize = maxChunkSize
        self.targetUploadTime = targetUploadTime
    }
}

/// Adaptive chunk sizer for network-aware chunk sizing.
public final class AdaptiveChunkSizer {

    private let config: AdaptiveChunkConfig
    private let speedMonitor: NetworkSpeedMonitor

    public init(config: AdaptiveChunkConfig = AdaptiveChunkConfig(), speedMonitor: NetworkSpeedMonitor) {
        self.config = config
        self.speedMonitor = speedMonitor
    }

    /// Calculate optimal chunk size based on current network conditions.
    public func calculateChunkSize() -> Int {
        switch config.strategy {
        case .fixed:
            return UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        case .adaptive:
            return speedMonitor.getRecommendedChunkSize()
        case .aggressive:
            let speedClass = speedMonitor.getSpeedClass()
            return speedClass.allowsAggressiveOptimization
                ? config.maxChunkSize
                : speedMonitor.getRecommendedChunkSize()
        }
    }

    /// Calculate optimal chunk size for a specific file size.
    public func calculateChunkSize(forFileSize fileSize: Int64) -> Int {
        let baseSize = calculateChunkSize()

        // For small files, use smaller chunks
        if fileSize < Int64(baseSize * 2) {
            return max(config.minChunkSize, Int(fileSize / 2))
        }

        return baseSize
    }

    /// Get recommended parallel upload count.
    public func getRecommendedParallelCount() -> Int {
        return speedMonitor.getRecommendedParallelCount()
    }
}
```

### 3.4 创建 `Core/Upload/UploadSession.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Upload Session
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Upload session state enumeration.
public enum UploadSessionState: String, Codable, CaseIterable {
    case initialized = "initialized"
    case uploading = "uploading"
    case paused = "paused"
    case stalled = "stalled"
    case completing = "completing"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Chunk state enumeration.
public enum ChunkState: String, Codable {
    case pending = "pending"
    case uploading = "uploading"
    case completed = "completed"
    case failed = "failed"
}

/// Chunk status tracking.
public struct ChunkStatus: Codable, Equatable {
    public let index: Int
    public let offset: Int64
    public let size: Int
    public var state: ChunkState
    public var retryCount: Int
    public var lastError: String?

    public init(index: Int, offset: Int64, size: Int) {
        self.index = index
        self.offset = offset
        self.size = size
        self.state = .pending
        self.retryCount = 0
        self.lastError = nil
    }
}

/// Upload session for managing a single file upload.
public final class UploadSession {

    public let sessionId: String
    public let fileSize: Int64
    public let fileName: String
    public private(set) var state: UploadSessionState
    public private(set) var chunks: [ChunkStatus]
    public private(set) var uploadedBytes: Int64
    public let createdAt: Date
    public private(set) var updatedAt: Date

    private let queue = DispatchQueue(label: "com.app.upload.session", qos: .userInitiated)

    public init(sessionId: String = UUID().uuidString, fileName: String, fileSize: Int64, chunkSize: Int) {
        self.sessionId = sessionId
        self.fileName = fileName
        self.fileSize = fileSize
        self.state = .initialized
        self.uploadedBytes = 0
        self.createdAt = Date()
        self.updatedAt = Date()

        // Calculate chunks
        var chunks: [ChunkStatus] = []
        var offset: Int64 = 0
        var index = 0
        while offset < fileSize {
            let remainingBytes = fileSize - offset
            let currentChunkSize = min(Int(remainingBytes), chunkSize)
            chunks.append(ChunkStatus(index: index, offset: offset, size: currentChunkSize))
            offset += Int64(currentChunkSize)
            index += 1
        }
        self.chunks = chunks
    }

    /// Get progress as a percentage (0.0 - 1.0).
    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(uploadedBytes) / Double(fileSize)
    }

    /// Get number of completed chunks.
    public var completedChunkCount: Int {
        return queue.sync { chunks.filter { $0.state == .completed }.count }
    }

    /// Get total chunk count.
    public var totalChunkCount: Int {
        return chunks.count
    }

    /// Update session state.
    public func updateState(_ newState: UploadSessionState) {
        queue.sync {
            self.state = newState
            self.updatedAt = Date()
        }
    }

    /// Mark chunk as completed.
    public func markChunkCompleted(index: Int) {
        queue.sync {
            guard index < chunks.count else { return }
            chunks[index].state = .completed
            uploadedBytes = chunks.filter { $0.state == .completed }
                .reduce(0) { $0 + Int64($1.size) }
            updatedAt = Date()
        }
    }

    /// Mark chunk as failed.
    public func markChunkFailed(index: Int, error: String) {
        queue.sync {
            guard index < chunks.count else { return }
            chunks[index].state = .failed
            chunks[index].retryCount += 1
            chunks[index].lastError = error
            updatedAt = Date()
        }
    }

    /// Get next pending chunk.
    public func getNextPendingChunk() -> ChunkStatus? {
        return queue.sync {
            chunks.first { $0.state == .pending }
        }
    }

    /// Check if session has expired.
    public func isExpired(maxAge: TimeInterval = UploadConstants.SESSION_MAX_AGE_SECONDS) -> Bool {
        return Date().timeIntervalSince(createdAt) > maxAge
    }
}
```

### 3.5 创建 `Core/Upload/ChunkManager.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Chunk Manager
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Chunk upload error enumeration.
public enum ChunkUploadError: Error, Equatable {
    case networkError(String)
    case serverError(Int)
    case timeout
    case cancelled
    case maxRetriesExceeded
}

/// Chunk manager delegate protocol.
public protocol ChunkManagerDelegate: AnyObject {
    func chunkManager(_ manager: ChunkManager, didStartChunk index: Int)
    func chunkManager(_ manager: ChunkManager, didCompleteChunk index: Int)
    func chunkManager(_ manager: ChunkManager, didFailChunk index: Int, error: ChunkUploadError)
    func chunkManager(_ manager: ChunkManager, didUpdateProgress progress: Double)
}

/// Chunk manager for coordinating parallel chunk uploads.
public final class ChunkManager {

    public weak var delegate: ChunkManagerDelegate?

    private let session: UploadSession
    private let speedMonitor: NetworkSpeedMonitor
    private let chunkSizer: AdaptiveChunkSizer
    private let queue = DispatchQueue(label: "com.app.upload.chunkmanager", qos: .userInitiated)
    private var activeUploads: Set<Int> = []
    private var isCancelled: Bool = false

    public init(session: UploadSession, speedMonitor: NetworkSpeedMonitor, chunkSizer: AdaptiveChunkSizer) {
        self.session = session
        self.speedMonitor = speedMonitor
        self.chunkSizer = chunkSizer
    }

    /// Get current number of active uploads.
    public var activeUploadCount: Int {
        return queue.sync { activeUploads.count }
    }

    /// Get recommended parallel count based on network conditions.
    public var recommendedParallelCount: Int {
        return chunkSizer.getRecommendedParallelCount()
    }

    /// Check if upload should continue.
    public var shouldContinue: Bool {
        return queue.sync { !isCancelled && !session.state.isTerminal }
    }

    /// Cancel all uploads.
    public func cancel() {
        queue.sync {
            isCancelled = true
            activeUploads.removeAll()
        }
        session.updateState(.cancelled)
    }

    /// Mark chunk upload as started.
    public func markChunkStarted(index: Int) {
        queue.sync {
            activeUploads.insert(index)
        }
        delegate?.chunkManager(self, didStartChunk: index)
    }

    /// Mark chunk upload as completed.
    public func markChunkCompleted(index: Int, bytesTransferred: Int64, duration: TimeInterval) {
        queue.sync {
            activeUploads.remove(index)
        }
        session.markChunkCompleted(index: index)
        speedMonitor.recordSample(bytesTransferred: bytesTransferred, durationSeconds: duration)
        delegate?.chunkManager(self, didCompleteChunk: index)
        delegate?.chunkManager(self, didUpdateProgress: session.progress)
    }

    /// Mark chunk upload as failed.
    public func markChunkFailed(index: Int, error: ChunkUploadError) {
        queue.sync {
            activeUploads.remove(index)
        }
        session.markChunkFailed(index: index, error: "\(error)")
        delegate?.chunkManager(self, didFailChunk: index, error: error)
    }

    /// Calculate retry delay with decorrelated jitter.
    public func calculateRetryDelay(attempt: Int) -> TimeInterval {
        let baseDelay = UploadConstants.RETRY_BASE_DELAY_SECONDS
        let maxDelay = UploadConstants.RETRY_MAX_DELAY_SECONDS
        let jitter = UploadConstants.RETRY_JITTER_FACTOR

        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(exponentialDelay, maxDelay)
        let jitterRange = cappedDelay * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)

        return max(baseDelay, cappedDelay + randomJitter)
    }
}
```

### 3.6 创建 `Core/Upload/UploadResumeManager.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Resume Manager
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Upload resume manager for persisting and recovering upload sessions.
public final class UploadResumeManager {

    private let userDefaults: UserDefaults
    private let keyPrefix: String
    private let queue = DispatchQueue(label: "com.app.upload.resumemanager", qos: .utility)

    public init(userDefaults: UserDefaults = .standard, keyPrefix: String = UploadConstants.SESSION_PERSISTENCE_KEY_PREFIX) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    /// Save session state for later resume.
    public func saveSession(_ session: UploadSession) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let key = self.keyPrefix + session.sessionId
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            if let data = try? encoder.encode(SessionSnapshot(session: session)) {
                self.userDefaults.set(data, forKey: key)
            }
        }
    }

    /// Load session state for resume.
    public func loadSession(sessionId: String) -> SessionSnapshot? {
        return queue.sync { [weak self] in
            guard let self = self else { return nil }
            let key = self.keyPrefix + sessionId
            guard let data = self.userDefaults.data(forKey: key) else { return nil }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(SessionSnapshot.self, from: data)
        }
    }

    /// Delete session state.
    public func deleteSession(sessionId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let key = self.keyPrefix + sessionId
            self.userDefaults.removeObject(forKey: key)
        }
    }

    /// Get all saved session IDs.
    public func getAllSessionIds() -> [String] {
        return queue.sync { [weak self] in
            guard let self = self else { return [] }
            return self.userDefaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(self.keyPrefix) }
                .map { String($0.dropFirst(self.keyPrefix.count)) }
        }
    }

    /// Clean up expired sessions.
    public func cleanupExpiredSessions(maxAge: TimeInterval = UploadConstants.SESSION_MAX_AGE_SECONDS) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let sessionIds = self.getAllSessionIds()
            let cutoff = Date().addingTimeInterval(-maxAge)

            for sessionId in sessionIds {
                if let snapshot = self.loadSession(sessionId: sessionId),
                   snapshot.createdAt < cutoff {
                    self.deleteSession(sessionId: sessionId)
                }
            }
        }
    }
}

/// Session snapshot for persistence.
public struct SessionSnapshot: Codable {
    public let sessionId: String
    public let fileName: String
    public let fileSize: Int64
    public let chunks: [ChunkStatus]
    public let uploadedBytes: Int64
    public let createdAt: Date
    public let state: UploadSessionState

    public init(session: UploadSession) {
        self.sessionId = session.sessionId
        self.fileName = session.fileName
        self.fileSize = session.fileSize
        self.chunks = session.chunks
        self.uploadedBytes = session.uploadedBytes
        self.createdAt = session.createdAt
        self.state = session.state
    }
}
```

### 3.7 创建 `Core/Upload/UploadProgressTracker.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure - Progress Tracker
// Cross-Platform: macOS + Linux (pure Foundation)
// ============================================================================

import Foundation

/// Upload progress event.
public struct UploadProgressEvent: Equatable {
    public let sessionId: String
    public let progress: Double
    public let uploadedBytes: Int64
    public let totalBytes: Int64
    public let speedBps: Double
    public let estimatedRemainingSeconds: TimeInterval?
    public let timestamp: Date

    public init(
        sessionId: String,
        progress: Double,
        uploadedBytes: Int64,
        totalBytes: Int64,
        speedBps: Double,
        estimatedRemainingSeconds: TimeInterval?,
        timestamp: Date = Date()
    ) {
        self.sessionId = sessionId
        self.progress = progress
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.speedBps = speedBps
        self.estimatedRemainingSeconds = estimatedRemainingSeconds
        self.timestamp = timestamp
    }
}

/// Upload progress tracker delegate.
public protocol UploadProgressTrackerDelegate: AnyObject {
    func progressTracker(_ tracker: UploadProgressTracker, didUpdateProgress event: UploadProgressEvent)
}

/// Upload progress tracker for aggregating and reporting progress.
public final class UploadProgressTracker {

    public weak var delegate: UploadProgressTrackerDelegate?

    private let session: UploadSession
    private let speedMonitor: NetworkSpeedMonitor
    private let queue = DispatchQueue(label: "com.app.upload.progresstracker", qos: .userInitiated)
    private var lastReportedProgress: Double = 0.0
    private var lastReportTime: Date = .distantPast

    public init(session: UploadSession, speedMonitor: NetworkSpeedMonitor) {
        self.session = session
        self.speedMonitor = speedMonitor
    }

    /// Update and report progress if threshold is met.
    public func updateProgress() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let currentProgress = self.session.progress
            let now = Date()

            // Check throttle
            let timeSinceLastReport = now.timeIntervalSince(self.lastReportTime)
            if timeSinceLastReport < UploadConstants.PROGRESS_THROTTLE_INTERVAL_SECONDS {
                return
            }

            // Check minimum increment
            let progressDelta = abs(currentProgress - self.lastReportedProgress)
            if progressDelta < UploadConstants.MIN_PROGRESS_INCREMENT_PERCENT / 100.0 {
                return
            }

            self.lastReportedProgress = currentProgress
            self.lastReportTime = now

            let speedBps = self.speedMonitor.getSpeedBps()
            let remainingBytes = self.session.fileSize - self.session.uploadedBytes
            let estimatedRemaining: TimeInterval? = speedBps > 0
                ? Double(remainingBytes) / speedBps
                : nil

            let event = UploadProgressEvent(
                sessionId: self.session.sessionId,
                progress: currentProgress,
                uploadedBytes: self.session.uploadedBytes,
                totalBytes: self.session.fileSize,
                speedBps: speedBps,
                estimatedRemainingSeconds: estimatedRemaining
            )

            DispatchQueue.main.async {
                self.delegate?.progressTracker(self, didUpdateProgress: event)
            }
        }
    }

    /// Force report current progress (ignoring throttle).
    public func forceReportProgress() {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.lastReportedProgress = self.session.progress
            self.lastReportTime = Date()

            let speedBps = self.speedMonitor.getSpeedBps()
            let remainingBytes = self.session.fileSize - self.session.uploadedBytes
            let estimatedRemaining: TimeInterval? = speedBps > 0
                ? Double(remainingBytes) / speedBps
                : nil

            let event = UploadProgressEvent(
                sessionId: self.session.sessionId,
                progress: self.session.progress,
                uploadedBytes: self.session.uploadedBytes,
                totalBytes: self.session.fileSize,
                speedBps: speedBps,
                estimatedRemainingSeconds: estimatedRemaining
            )

            DispatchQueue.main.async {
                self.delegate?.progressTracker(self, didUpdateProgress: event)
            }
        }
    }
}
```

---

## 🧪 补丁 4: 创建测试文件

### 4.1 创建 `Tests/Upload/NetworkSpeedMonitorTests.swift`

**完整代码见 PR3_UPLOAD_INFRASTRUCTURE_DETAILED_PROMPT.md 第 1030-1214 行**

**关键修改**: 将 `@testable import YourModuleName` 改为:
```swift
@testable import Aether3DCore
```

### 4.2 创建 `Tests/Upload/AdaptiveChunkSizerTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Adaptive Chunk Sizer
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class AdaptiveChunkSizerTests: XCTestCase {

    var speedMonitor: NetworkSpeedMonitor!
    var sizer: AdaptiveChunkSizer!

    override func setUp() {
        super.setUp()
        speedMonitor = NetworkSpeedMonitor()
        sizer = AdaptiveChunkSizer(speedMonitor: speedMonitor)
    }

    override func tearDown() {
        sizer = nil
        speedMonitor = nil
        super.tearDown()
    }

    func testFixedStrategy() {
        let config = AdaptiveChunkConfig(strategy: .fixed)
        let fixedSizer = AdaptiveChunkSizer(config: config, speedMonitor: speedMonitor)

        XCTAssertEqual(fixedSizer.calculateChunkSize(), UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    func testAdaptiveStrategySlowNetwork() {
        // Simulate slow network
        for _ in 0..<5 {
            speedMonitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(sizer.calculateChunkSize(), UploadConstants.CHUNK_SIZE_MIN_BYTES)
    }

    func testAdaptiveStrategyFastNetwork() {
        // Simulate fast network
        for _ in 0..<5 {
            speedMonitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertGreaterThan(sizer.calculateChunkSize(), UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
    }

    func testSmallFileSizing() {
        let smallFileSize: Int64 = 3 * 1024 * 1024  // 3MB
        let chunkSize = sizer.calculateChunkSize(forFileSize: smallFileSize)

        XCTAssertLessThanOrEqual(chunkSize, Int(smallFileSize))
    }
}
```

### 4.3 创建 `Tests/Upload/UploadSessionTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Upload Session
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class UploadSessionTests: XCTestCase {

    var session: UploadSession!

    override func setUp() {
        super.setUp()
        session = UploadSession(
            fileName: "test.mp4",
            fileSize: 50 * 1024 * 1024,  // 50MB
            chunkSize: 5 * 1024 * 1024   // 5MB chunks
        )
    }

    override func tearDown() {
        session = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(session.state, .initialized)
        XCTAssertEqual(session.totalChunkCount, 10)  // 50MB / 5MB
        XCTAssertEqual(session.completedChunkCount, 0)
        XCTAssertEqual(session.progress, 0.0)
    }

    func testChunkCompletion() {
        session.markChunkCompleted(index: 0)

        XCTAssertEqual(session.completedChunkCount, 1)
        XCTAssertEqual(session.progress, 0.1, accuracy: 0.01)
    }

    func testStateTransition() {
        session.updateState(.uploading)
        XCTAssertEqual(session.state, .uploading)

        session.updateState(.completed)
        XCTAssertEqual(session.state, .completed)
        XCTAssertTrue(session.state.isTerminal)
    }

    func testChunkFailure() {
        session.markChunkFailed(index: 0, error: "Network error")

        let chunk = session.chunks[0]
        XCTAssertEqual(chunk.state, .failed)
        XCTAssertEqual(chunk.retryCount, 1)
        XCTAssertEqual(chunk.lastError, "Network error")
    }

    func testGetNextPendingChunk() {
        let pending = session.getNextPendingChunk()
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.index, 0)

        session.markChunkCompleted(index: 0)
        let nextPending = session.getNextPendingChunk()
        XCTAssertEqual(nextPending?.index, 1)
    }
}
```

### 4.4 创建 `Tests/Upload/ChunkManagerTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Chunk Manager
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class ChunkManagerTests: XCTestCase {

    var session: UploadSession!
    var speedMonitor: NetworkSpeedMonitor!
    var chunkSizer: AdaptiveChunkSizer!
    var manager: ChunkManager!

    override func setUp() {
        super.setUp()
        session = UploadSession(fileName: "test.mp4", fileSize: 50 * 1024 * 1024, chunkSize: 5 * 1024 * 1024)
        speedMonitor = NetworkSpeedMonitor()
        chunkSizer = AdaptiveChunkSizer(speedMonitor: speedMonitor)
        manager = ChunkManager(session: session, speedMonitor: speedMonitor, chunkSizer: chunkSizer)
    }

    override func tearDown() {
        manager = nil
        chunkSizer = nil
        speedMonitor = nil
        session = nil
        super.tearDown()
    }

    func testInitialState() {
        XCTAssertEqual(manager.activeUploadCount, 0)
        XCTAssertTrue(manager.shouldContinue)
    }

    func testChunkLifecycle() {
        manager.markChunkStarted(index: 0)
        XCTAssertEqual(manager.activeUploadCount, 1)

        manager.markChunkCompleted(index: 0, bytesTransferred: 5 * 1024 * 1024, duration: 1.0)
        XCTAssertEqual(manager.activeUploadCount, 0)
        XCTAssertEqual(session.completedChunkCount, 1)
    }

    func testCancel() {
        manager.markChunkStarted(index: 0)
        manager.cancel()

        XCTAssertFalse(manager.shouldContinue)
        XCTAssertEqual(session.state, .cancelled)
    }

    func testRetryDelay() {
        let delay0 = manager.calculateRetryDelay(attempt: 0)
        let delay1 = manager.calculateRetryDelay(attempt: 1)
        let delay2 = manager.calculateRetryDelay(attempt: 2)

        XCTAssertGreaterThanOrEqual(delay0, UploadConstants.RETRY_BASE_DELAY_SECONDS * 0.5)
        XCTAssertLessThanOrEqual(delay2, UploadConstants.RETRY_MAX_DELAY_SECONDS * 1.5)
        // Delays should generally increase (though jitter may cause variation)
        XCTAssertLessThan(delay0, delay2 * 2)
    }
}
```

### 4.5 创建 `Tests/Upload/UploadResumeManagerTests.swift`

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Resume Manager
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import Aether3DCore

final class UploadResumeManagerTests: XCTestCase {

    var resumeManager: UploadResumeManager!
    var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "UploadResumeManagerTests")!
        resumeManager = UploadResumeManager(userDefaults: testDefaults, keyPrefix: "test.upload.session.")
    }

    override func tearDown() {
        // Clean up test defaults
        testDefaults.removePersistentDomain(forName: "UploadResumeManagerTests")
        resumeManager = nil
        testDefaults = nil
        super.tearDown()
    }

    func testSaveAndLoadSession() {
        let session = UploadSession(fileName: "test.mp4", fileSize: 1024 * 1024, chunkSize: 512 * 1024)
        session.markChunkCompleted(index: 0)

        resumeManager.saveSession(session)

        // Wait for async save
        let expectation = XCTestExpectation(description: "Save complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let loaded = self.resumeManager.loadSession(sessionId: session.sessionId)
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded?.sessionId, session.sessionId)
            XCTAssertEqual(loaded?.fileName, "test.mp4")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testDeleteSession() {
        let session = UploadSession(fileName: "test.mp4", fileSize: 1024, chunkSize: 512)
        resumeManager.saveSession(session)

        let expectation = XCTestExpectation(description: "Delete complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.resumeManager.deleteSession(sessionId: session.sessionId)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let loaded = self.resumeManager.loadSession(sessionId: session.sessionId)
                XCTAssertNil(loaded)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 3.0)
    }
}
```

---

## 🔄 补丁 5: 更新合同版本 (可选 - PR3 完成后)

**注意**: 只有在所有 Upload 功能完成并测试通过后才执行此步骤。

### 5.1 修改 `Core/Jobs/ContractConstants.swift`

```swift
// 将第 3 行:
// Contract Version: PR2-JSM-3.0-merged
// 改为:
// Contract Version: PR3-API-1.0

// 将 CONTRACT_VERSION 常量值更新为:
public static let CONTRACT_VERSION = "PR3-API-1.0"
```

---

## ✅ 验证命令

```bash
# 1. 验证 Package.swift 语法
swift package describe

# 2. 验证新 target 被识别
swift package describe 2>&1 | grep -i upload

# 3. 构建
swift build

# 4. 运行所有测试
swift test

# 5. 单独运行 Upload 测试
swift test --filter UploadTests

# 6. 验证无 Apple-only imports
grep -rE "import UIKit|import AppKit|import Network" Core/Upload/ && echo "FAIL" || echo "PASS"
```

---

## 📋 文件清单

| 操作 | 路径 | 状态 |
|------|------|------|
| MODIFY | `Package.swift` | 添加 UploadTests target + exclude |
| CREATE | `Core/Constants/UploadConstants.swift` | 新文件 |
| CREATE | `Core/Upload/NetworkSpeedMonitor.swift` | 新文件 |
| CREATE | `Core/Upload/AdaptiveChunkSizer.swift` | 新文件 |
| CREATE | `Core/Upload/UploadSession.swift` | 新文件 |
| CREATE | `Core/Upload/ChunkManager.swift` | 新文件 |
| CREATE | `Core/Upload/UploadResumeManager.swift` | 新文件 |
| CREATE | `Core/Upload/UploadProgressTracker.swift` | 新文件 |
| CREATE | `Tests/Upload/NetworkSpeedMonitorTests.swift` | 新文件 |
| CREATE | `Tests/Upload/AdaptiveChunkSizerTests.swift` | 新文件 |
| CREATE | `Tests/Upload/UploadSessionTests.swift` | 新文件 |
| CREATE | `Tests/Upload/ChunkManagerTests.swift` | 新文件 |
| CREATE | `Tests/Upload/UploadResumeManagerTests.swift` | 新文件 |

**总计**: 1 个修改 + 12 个新建 = 13 个文件操作
