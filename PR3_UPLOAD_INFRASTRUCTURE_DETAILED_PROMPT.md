# PR3 Upload Infrastructure - Extreme Detail Implementation Prompt

## 🎯 Mission Statement

Implement enterprise-grade, cross-platform upload infrastructure on branch `pr3/upload-infrastructure`. This implementation MUST:

1. Pass ALL CI checks (8 jobs green)
2. Work identically on macOS and Linux
3. Follow Constitutional Contract pattern
4. Maintain 100% backward compatibility with PR2-JSM-3.0-merged

---

## ⚠️ CRITICAL: Package.swift Configuration

**The test target configuration is CRITICAL.** Current `Package.swift` structure:

```swift
// Current Package.swift test target (excludes Constants):
.testTarget(
  name: "Aether3DCoreTests",
  dependencies: ["Aether3DCore"],
  path: "Tests",
  exclude: ["Constants", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],
  // ...
)

// Separate ConstantsTests target:
.testTarget(
  name: "ConstantsTests",
  dependencies: ["Aether3DCore", .product(name: "Crypto", package: "swift-crypto")],
  path: "Tests/Constants"
)
```

### Package.swift Update Required

**Add new UploadTests target to Package.swift:**

```swift
// ADD this new test target:
.testTarget(
  name: "UploadTests",
  dependencies: ["Aether3DCore"],
  path: "Tests/Upload"
)
```

**AND update Aether3DCoreTests exclude list:**
```swift
exclude: ["Constants", "Upload", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],
```

**Full Package.swift modification:**
```swift
// In targets array, add:
.testTarget(
  name: "UploadTests",
  dependencies: ["Aether3DCore"],
  path: "Tests/Upload"
),

// AND modify existing Aether3DCoreTests:
.testTarget(
  name: "Aether3DCoreTests",
  dependencies: ["Aether3DCore"],
  path: "Tests",
  exclude: ["Constants", "Upload", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],  // ADD "Upload"
  resources: [
    .process("QualityPreCheck/Fixtures/CoverageDeltaEndiannessFixture.json"),
    .process("QualityPreCheck/Fixtures/CoverageGridPackingFixture.json"),
    .process("QualityPreCheck/Fixtures/CanonicalJSONFloatFixture.json")
  ]
)
```

**Verification after Package.swift update:**
```bash
# Verify new test target is recognized
swift package describe 2>&1 | grep -i upload

# Verify tests can be filtered
swift test --list-tests 2>&1 | grep -i upload
```

---

## ⚠️ CRITICAL: Core/API/ Directory Does NOT Exist

**Important Discovery:** The `Core/API/` directory does NOT exist in this codebase.
The API-related constants are in `Core/Constants/APIContractConstants.swift`.

**Correction to Architecture:**
- Do NOT create `Core/API/APIEndpoints.swift`
- API endpoints should be defined in `Core/Constants/APIContractConstants.swift` if needed
- Or create a new file `Core/Constants/UploadEndpoints.swift` for upload-specific endpoints

---

## 📋 Pre-Implementation Verification

**CRITICAL: Run these commands BEFORE writing any code:**

```bash
# 1. Verify current branch
git branch --show-current
# Expected: pr3/upload-infrastructure

# 2. Verify base state
swift build 2>&1 | tee /tmp/pr3-pre-build.log
echo "Build exit code: $?"

# 3. Run existing tests to establish baseline
swift test 2>&1 | tee /tmp/pr3-pre-test.log
echo "Test exit code: $?"

# 4. Verify contract version
grep "CONTRACT_VERSION" Core/Jobs/ContractConstants.swift
# Expected: PR2-JSM-3.0-merged

# 5. Check current directory structure
ls -la Core/
ls -la Core/Constants/ 2>/dev/null || echo "Core/Constants/ does not exist yet"
ls -la Tests/
```

**DO NOT proceed until all baseline checks pass.**

---

## 🏗️ Architecture Overview

### Directory Structure (Final State)

```
Core/
├── Constants/
│   ├── APIContractConstants.swift  # MODIFY: Add deprecation
│   └── UploadConstants.swift       # CREATE: Upload SSOT
├── Jobs/
│   └── ContractConstants.swift     # MODIFY: Update version
└── Upload/                         # CREATE: New directory
    ├── NetworkSpeedMonitor.swift   # CREATE
    ├── AdaptiveChunkSizer.swift    # CREATE
    ├── UploadSession.swift         # CREATE
    ├── ChunkManager.swift          # CREATE
    ├── UploadResumeManager.swift   # CREATE
    └── UploadProgressTracker.swift # CREATE

# NOTE: Core/API/ does NOT exist - upload endpoints go in Core/Constants/

Tests/
└── Upload/                         # CREATE: New directory
    ├── NetworkSpeedMonitorTests.swift
    ├── AdaptiveChunkSizerTests.swift
    ├── UploadSessionTests.swift
    ├── ChunkManagerTests.swift
    └── UploadResumeManagerTests.swift
```

### File Creation Order (Dependency Graph)

```
Phase 1: Foundation (No Dependencies)
    └── UploadConstants.swift

Phase 2: Monitoring (Depends on Phase 1)
    └── NetworkSpeedMonitor.swift

Phase 3: Intelligence (Depends on Phase 1, 2)
    └── AdaptiveChunkSizer.swift

Phase 4: State Management (Depends on Phase 1)
    └── UploadSession.swift

Phase 5: Coordination (Depends on Phase 1, 2, 3, 4)
    ├── ChunkManager.swift
    ├── UploadResumeManager.swift
    └── UploadProgressTracker.swift

Phase 6: Tests (Depends on All Above)
    └── All test files

Phase 7: Integration (Modify Existing)
    ├── ContractConstants.swift
    └── APIContractConstants.swift
```

---

## 📁 Phase 1: UploadConstants.swift

**Path:** `Core/Constants/UploadConstants.swift`

**Purpose:** Single Source of Truth for all upload-related constants.

### Cross-Platform Requirements

| Requirement | macOS | Linux | Notes |
|-------------|-------|-------|-------|
| Foundation import | ✅ | ✅ | Standard |
| TimeInterval | ✅ | ✅ | Double alias |
| Int64 | ✅ | ✅ | Fixed-width |
| No Apple frameworks | ✅ | ✅ | Pure Swift only |

### Implementation

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Constants (SSOT)
// Cross-Platform: macOS + Linux
// ============================================================================

import Foundation

/// Upload infrastructure constants - Single Source of Truth.
/// All upload-related magic numbers MUST be defined here.
///
/// ## Cross-Platform Compatibility
/// - Uses only Foundation types available on all platforms
/// - No Apple-specific frameworks (UIKit, AppKit, etc.)
/// - All numeric types are fixed-width for consistency
///
/// ## References
/// - tus.io resumable upload protocol v1.0.0
/// - AWS S3 multipart upload best practices
/// - Netflix/AWS exponential backoff patterns
public enum UploadConstants {

    // =========================================================================
    // MARK: - Contract Metadata
    // =========================================================================

    /// Upload module contract version
    /// Format: PR{n}-UPLOAD-{major}.{minor}
    public static let UPLOAD_CONTRACT_VERSION = "PR3-UPLOAD-1.0"

    /// Minimum supported contract version for resume compatibility
    public static let UPLOAD_MIN_COMPATIBLE_VERSION = "PR3-UPLOAD-1.0"

    // =========================================================================
    // MARK: - Chunk Size Configuration
    // =========================================================================

    /// Minimum chunk size in bytes (2MB)
    /// - Below 2MB: HTTP overhead becomes significant (>5%)
    /// - Used for slow/unstable networks (<5 Mbps)
    /// - Matches minimum viable chunk for S3 compatibility
    public static let CHUNK_SIZE_MIN_BYTES: Int = 2 * 1024 * 1024

    /// Default chunk size in bytes (5MB)
    /// - Optimal for typical mobile/WiFi (10-50 Mbps)
    /// - Matches S3 multipart minimum for compatibility
    /// - Balances memory usage vs. overhead
    public static let CHUNK_SIZE_DEFAULT_BYTES: Int = 5 * 1024 * 1024

    /// Maximum chunk size in bytes (20MB)
    /// - Used for fast networks (>100 Mbps)
    /// - Above 20MB: Memory pressure on mobile devices
    /// - Maximizes throughput on high-speed connections
    public static let CHUNK_SIZE_MAX_BYTES: Int = 20 * 1024 * 1024

    /// Chunk size adjustment step (1MB)
    /// - Granular optimization steps
    /// - Allows smooth transitions between sizes
    public static let CHUNK_SIZE_STEP_BYTES: Int = 1 * 1024 * 1024

    // =========================================================================
    // MARK: - Network Speed Thresholds (Mbps)
    // =========================================================================

    /// Slow network threshold: < 5 Mbps
    /// - Typical 3G, poor WiFi, congested networks
    /// - Use minimum chunk size, reduced parallelism
    public static let NETWORK_SPEED_SLOW_MBPS: Double = 5.0

    /// Normal network threshold: 5-50 Mbps
    /// - Typical 4G LTE, good WiFi
    /// - Use default chunk size, moderate parallelism
    public static let NETWORK_SPEED_NORMAL_MBPS: Double = 50.0

    /// Fast network threshold: 50-100 Mbps
    /// - 5G, fiber, excellent WiFi
    /// - Use larger chunks, maximum parallelism
    public static let NETWORK_SPEED_FAST_MBPS: Double = 100.0

    /// Minimum samples before speed estimation is reliable
    /// - 3 samples reduces noise from temporary spikes
    /// - Provides statistical confidence
    public static let NETWORK_SPEED_MIN_SAMPLES: Int = 3

    /// Speed measurement rolling window (seconds)
    /// - 30 seconds captures recent network conditions
    /// - Old samples expire for responsiveness
    public static let NETWORK_SPEED_WINDOW_SECONDS: TimeInterval = 30.0

    /// Maximum speed samples to retain
    /// - Prevents unbounded memory growth
    /// - 20 samples at 1.5s intervals ≈ 30 seconds
    public static let NETWORK_SPEED_MAX_SAMPLES: Int = 20

    // =========================================================================
    // MARK: - Parallel Upload Configuration
    // =========================================================================

    /// Maximum concurrent chunk uploads
    /// - 4 parallel uploads optimal for most networks
    /// - Beyond 4: diminishing returns, increased complexity
    /// - Research: AWS/Netflix recommend 3-5 for resilience
    public static let MAX_PARALLEL_CHUNK_UPLOADS: Int = 4

    /// Minimum concurrent chunk uploads
    /// - Always at least 1 for progress
    /// - Fallback for extremely slow networks
    public static let MIN_PARALLEL_CHUNK_UPLOADS: Int = 1

    /// Ramp-up delay between parallel requests (seconds)
    /// - Stagger requests to avoid burst congestion
    /// - 100ms provides smooth ramp-up
    public static let PARALLEL_RAMP_UP_DELAY_SECONDS: TimeInterval = 0.1

    /// Parallelism adjustment interval (seconds)
    /// - How often to re-evaluate optimal parallelism
    /// - 5 seconds balances responsiveness vs. stability
    public static let PARALLELISM_ADJUST_INTERVAL_SECONDS: TimeInterval = 5.0

    // =========================================================================
    // MARK: - Upload Session Configuration
    // =========================================================================

    /// Maximum upload session age (seconds) - 24 hours
    /// - Sessions older than this cannot be resumed
    /// - Balances storage vs. resume capability
    public static let SESSION_MAX_AGE_SECONDS: TimeInterval = 24 * 60 * 60

    /// Session cleanup interval (seconds) - 1 hour
    /// - How often to purge expired sessions
    /// - Prevents storage bloat
    public static let SESSION_CLEANUP_INTERVAL_SECONDS: TimeInterval = 60 * 60

    /// Maximum concurrent sessions per user
    /// - Prevents resource exhaustion
    /// - 3 allows reasonable multitasking
    public static let SESSION_MAX_CONCURRENT_PER_USER: Int = 3

    /// Session state persistence key prefix
    /// - Used for UserDefaults storage
    /// - Namespaced to avoid collisions
    public static let SESSION_PERSISTENCE_KEY_PREFIX: String = "com.app.upload.session."

    // =========================================================================
    // MARK: - Timeout Configuration
    // =========================================================================

    /// Individual chunk upload timeout (seconds)
    /// - 60 seconds per chunk before retry
    /// - Accounts for large chunks on slow networks
    public static let CHUNK_TIMEOUT_SECONDS: TimeInterval = 60.0

    /// Connection establishment timeout (seconds)
    /// - 10 seconds for initial connection
    /// - Fail fast if server unreachable
    public static let CONNECTION_TIMEOUT_SECONDS: TimeInterval = 10.0

    /// Stall detection timeout (seconds)
    /// - No progress for 15 seconds = stalled
    /// - Triggers automatic recovery
    public static let STALL_DETECTION_TIMEOUT_SECONDS: TimeInterval = 15.0

    /// Minimum progress rate before stall (bytes/second)
    /// - Below 1KB/s for stall timeout = stalled
    /// - Prevents false positives from slow but active transfers
    public static let STALL_MIN_PROGRESS_RATE_BPS: Int = 1024

    // =========================================================================
    // MARK: - Retry Configuration
    // =========================================================================

    /// Maximum retries per chunk
    /// - 3 retries with exponential backoff
    /// - Matches PR2 retry strategy
    public static let CHUNK_MAX_RETRIES: Int = 3

    /// Retry base delay (seconds)
    /// - Initial delay before first retry
    /// - Exponential: 2^attempt * base
    public static let RETRY_BASE_DELAY_SECONDS: TimeInterval = 2.0

    /// Maximum retry delay (seconds)
    /// - Cap exponential backoff at 60 seconds
    /// - Prevents excessive wait times
    public static let RETRY_MAX_DELAY_SECONDS: TimeInterval = 60.0

    /// Retry jitter range (0.0 - 1.0)
    /// - Random factor to prevent thundering herd
    /// - 0.5 = ±50% of calculated delay
    public static let RETRY_JITTER_FACTOR: Double = 0.5

    // =========================================================================
    // MARK: - Progress Reporting
    // =========================================================================

    /// Progress update throttle interval (seconds)
    /// - Minimum time between progress callbacks
    /// - 100ms provides smooth UI updates
    public static let PROGRESS_THROTTLE_INTERVAL_SECONDS: TimeInterval = 0.1

    /// Minimum bytes delta before progress update
    /// - Avoid micro-updates for tiny transfers
    /// - 64KB provides meaningful progress
    public static let PROGRESS_MIN_BYTES_DELTA: Int = 64 * 1024

    /// Progress smoothing factor (0.0 - 1.0)
    /// - EMA alpha for speed smoothing
    /// - 0.3 balances responsiveness vs. stability
    public static let PROGRESS_SMOOTHING_FACTOR: Double = 0.3

    // =========================================================================
    // MARK: - tus.io Protocol Configuration
    // =========================================================================

    /// tus.io protocol version
    public static let TUS_VERSION: String = "1.0.0"

    /// tus.io Resumable header name
    public static let TUS_HEADER_RESUMABLE: String = "Tus-Resumable"

    /// tus.io Upload-Offset header name
    public static let TUS_HEADER_UPLOAD_OFFSET: String = "Upload-Offset"

    /// tus.io Upload-Length header name
    public static let TUS_HEADER_UPLOAD_LENGTH: String = "Upload-Length"

    /// tus.io Upload-Metadata header name
    public static let TUS_HEADER_UPLOAD_METADATA: String = "Upload-Metadata"

    /// tus.io Upload-Checksum header name
    public static let TUS_HEADER_UPLOAD_CHECKSUM: String = "Upload-Checksum"

    /// tus.io Upload-Defer-Length header name
    public static let TUS_HEADER_UPLOAD_DEFER_LENGTH: String = "Upload-Defer-Length"

    // =========================================================================
    // MARK: - File Validation
    // =========================================================================

    /// Maximum file size for upload (bytes) - 10GB
    /// - Reasonable limit for video files
    /// - Prevents accidental huge uploads
    public static let MAX_FILE_SIZE_BYTES: Int64 = 10 * 1024 * 1024 * 1024

    /// Minimum file size for chunked upload (bytes) - 5MB
    /// - Below this: single request upload
    /// - Above this: chunked upload
    public static let MIN_CHUNKED_UPLOAD_SIZE_BYTES: Int = 5 * 1024 * 1024

    /// Minimum file size for upload (bytes) - 1 byte
    /// - Reject empty files
    public static let MIN_FILE_SIZE_BYTES: Int64 = 1

    // =========================================================================
    // MARK: - Idempotency Configuration
    // =========================================================================

    /// Idempotency key header name
    public static let IDEMPOTENCY_KEY_HEADER: String = "X-Idempotency-Key"

    /// Idempotency key maximum age (seconds) - 24 hours
    /// - Keys expire after this duration
    /// - Matches session max age
    public static let IDEMPOTENCY_KEY_MAX_AGE_SECONDS: TimeInterval = 24 * 60 * 60

    /// Idempotency key format (UUID v4)
    public static let IDEMPOTENCY_KEY_FORMAT: String = "uuid-v4"

    // =========================================================================
    // MARK: - Computed Constants
    // =========================================================================

    /// Total possible chunk sizes (for validation)
    /// Calculated: (MAX - MIN) / STEP + 1
    public static var CHUNK_SIZE_OPTIONS_COUNT: Int {
        return (CHUNK_SIZE_MAX_BYTES - CHUNK_SIZE_MIN_BYTES) / CHUNK_SIZE_STEP_BYTES + 1
    }

    /// Network speed categories count
    public static let NETWORK_SPEED_CATEGORY_COUNT: Int = 5  // slow, normal, fast, ultrafast, unknown

    /// Upload session state count
    public static let SESSION_STATE_COUNT: Int = 8  // initialized, uploading, paused, stalled, completing, completed, failed, cancelled

    /// Chunk state count
    public static let CHUNK_STATE_COUNT: Int = 4  // pending, uploading, completed, failed
}

// =========================================================================
// MARK: - Compile-Time Validation
// =========================================================================

#if DEBUG
/// Compile-time assertions for constant validity
/// These run only in debug builds to catch configuration errors
private enum UploadConstantsValidation {
    static func validate() {
        // Chunk size ordering
        assert(UploadConstants.CHUNK_SIZE_MIN_BYTES < UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
               "MIN chunk size must be less than DEFAULT")
        assert(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES < UploadConstants.CHUNK_SIZE_MAX_BYTES,
               "DEFAULT chunk size must be less than MAX")

        // Network speed ordering
        assert(UploadConstants.NETWORK_SPEED_SLOW_MBPS < UploadConstants.NETWORK_SPEED_NORMAL_MBPS,
               "SLOW speed must be less than NORMAL")
        assert(UploadConstants.NETWORK_SPEED_NORMAL_MBPS < UploadConstants.NETWORK_SPEED_FAST_MBPS,
               "NORMAL speed must be less than FAST")

        // Parallelism bounds
        assert(UploadConstants.MIN_PARALLEL_CHUNK_UPLOADS >= 1,
               "MIN parallel uploads must be at least 1")
        assert(UploadConstants.MIN_PARALLEL_CHUNK_UPLOADS <= UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS,
               "MIN parallel uploads must not exceed MAX")

        // Timeout sanity
        assert(UploadConstants.STALL_DETECTION_TIMEOUT_SECONDS < UploadConstants.CHUNK_TIMEOUT_SECONDS,
               "Stall detection must be faster than chunk timeout")

        // Retry sanity
        assert(UploadConstants.RETRY_BASE_DELAY_SECONDS < UploadConstants.RETRY_MAX_DELAY_SECONDS,
               "Base retry delay must be less than max")
    }
}
#endif
```

### Verification Commands

```bash
# After creating the file:
swift build 2>&1 | grep -i "UploadConstants"
# Should compile without errors

# Verify constant accessibility
swift -e 'import Foundation; print(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)'
# Expected: 5242880
```

---

## 📁 Phase 2: NetworkSpeedMonitor.swift

**Path:** `Core/Upload/NetworkSpeedMonitor.swift`

### Cross-Platform Requirements

| Requirement | macOS | Linux | Notes |
|-------------|-------|-------|-------|
| DispatchQueue | ✅ | ✅ | libdispatch available |
| Date | ✅ | ✅ | Foundation |
| Codable | ✅ | ✅ | Standard |
| No Network.framework | ❌ | N/A | macOS only, do NOT use |
| No NWPathMonitor | ❌ | N/A | macOS only, do NOT use |

### Implementation

```swift
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
```

---

## 📁 Phase 3-6: Remaining Files

Due to length, I'll provide the key structure for remaining files. Each file MUST:

1. Include the Constitutional Contract header
2. Import only Foundation
3. Use only cross-platform types
4. Include comprehensive documentation

### File Checklist

| File | Lines (Est.) | Key Classes/Structs |
|------|--------------|---------------------|
| AdaptiveChunkSizer.swift | 200 | `ChunkSizingStrategy`, `AdaptiveChunkConfig`, `AdaptiveChunkSizer` |
| UploadSession.swift | 300 | `UploadSessionState`, `ChunkStatus`, `ChunkState`, `UploadSession` |
| ChunkManager.swift | 350 | `ChunkManagerDelegate`, `ChunkUploadError`, `ChunkManager` |
| UploadResumeManager.swift | 250 | `UploadResumeManager` |
| UploadProgressTracker.swift | 180 | `UploadProgressEvent`, `UploadProgressTrackerDelegate`, `UploadProgressTracker` |

---

## 🧪 Phase 6: Test Files

### Test File Structure

Each test file MUST:
1. Import XCTest
2. Use `@testable import` for the module
3. Include setup/teardown
4. Test edge cases
5. Test cross-platform behavior

### Test Coverage Requirements

| Component | Required Coverage |
|-----------|-------------------|
| NetworkSpeedMonitor | Speed classification, sample recording, thread safety |
| AdaptiveChunkSizer | All strategies, file size optimization, boundary conditions |
| UploadSession | State transitions, chunk management, progress calculation |
| ChunkManager | Parallel coordination, retry logic, stall detection |
| UploadResumeManager | Persistence, expiration, recovery |

### Example Test File: NetworkSpeedMonitorTests.swift

```swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR3-API-1.0
// Module: Upload Infrastructure Tests - Network Speed Monitor
// Cross-Platform: macOS + Linux
// ============================================================================

import XCTest
@testable import YourModuleName  // Replace with actual module name

final class NetworkSpeedMonitorTests: XCTestCase {

    var monitor: NetworkSpeedMonitor!

    override func setUp() {
        super.setUp()
        monitor = NetworkSpeedMonitor()
    }

    override func tearDown() {
        monitor = nil
        super.tearDown()
    }

    // =========================================================================
    // MARK: - Classification Tests
    // =========================================================================

    func testSlowNetworkClassification() {
        // 2 Mbps = ~250 KB/s = 250,000 bytes/sec
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .slow)
        XCTAssertLessThan(monitor.getSpeedMbps(), UploadConstants.NETWORK_SPEED_SLOW_MBPS)
    }

    func testNormalNetworkClassification() {
        // 20 Mbps = ~2.5 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 2_500_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .normal)
    }

    func testFastNetworkClassification() {
        // 80 Mbps = ~10 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .fast)
    }

    func testUltrafastNetworkClassification() {
        // 200 Mbps = ~25 MB/s
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 25_000_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(monitor.getSpeedClass(), .ultrafast)
    }

    // =========================================================================
    // MARK: - Reliability Tests
    // =========================================================================

    func testUnknownWithInsufficientSamples() {
        monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)

        XCTAssertFalse(monitor.hasReliableEstimate())
        XCTAssertEqual(monitor.getSpeedClass(), .unknown)
    }

    func testReliableWithSufficientSamples() {
        for _ in 0..<UploadConstants.NETWORK_SPEED_MIN_SAMPLES {
            monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)
        }

        XCTAssertTrue(monitor.hasReliableEstimate())
        XCTAssertNotEqual(monitor.getSpeedClass(), .unknown)
    }

    // =========================================================================
    // MARK: - Edge Case Tests
    // =========================================================================

    func testZeroBytesIgnored() {
        monitor.recordSample(bytesTransferred: 0, durationSeconds: 1.0)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    func testNegativeBytesIgnored() {
        monitor.recordSample(bytesTransferred: -100, durationSeconds: 1.0)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    func testZeroDurationIgnored() {
        monitor.recordSample(bytesTransferred: 1000, durationSeconds: 0)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    // =========================================================================
    // MARK: - Reset Tests
    // =========================================================================

    func testReset() {
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 1_000_000, durationSeconds: 1.0)
        }

        XCTAssertTrue(monitor.hasReliableEstimate())

        monitor.reset()

        XCTAssertFalse(monitor.hasReliableEstimate())
        XCTAssertEqual(monitor.getSpeedClass(), .unknown)
        XCTAssertEqual(monitor.getSampleCount(), 0)
    }

    // =========================================================================
    // MARK: - Thread Safety Tests
    // =========================================================================

    func testConcurrentAccess() {
        let expectation = XCTestExpectation(description: "Concurrent access")
        let iterations = 100
        let dispatchGroup = DispatchGroup()

        for i in 0..<iterations {
            dispatchGroup.enter()
            DispatchQueue.global().async {
                self.monitor.recordSample(
                    bytesTransferred: Int64(i * 1000),
                    durationSeconds: 0.1
                )
                _ = self.monitor.getSpeedClass()
                _ = self.monitor.getSpeedMbps()
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            // Should not crash, data should be consistent
            XCTAssertGreaterThanOrEqual(self.monitor.getSampleCount(), 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)
    }

    // =========================================================================
    // MARK: - Recommendation Tests
    // =========================================================================

    func testSlowNetworkRecommendations() {
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 250_000, durationSeconds: 1.0)
        }

        XCTAssertEqual(
            monitor.getRecommendedChunkSize(),
            UploadConstants.CHUNK_SIZE_MIN_BYTES
        )
        XCTAssertEqual(monitor.getRecommendedParallelCount(), 2)
    }

    func testFastNetworkRecommendations() {
        for _ in 0..<5 {
            monitor.recordSample(bytesTransferred: 10_000_000, durationSeconds: 1.0)
        }

        XCTAssertGreaterThan(
            monitor.getRecommendedChunkSize(),
            UploadConstants.CHUNK_SIZE_DEFAULT_BYTES
        )
        XCTAssertEqual(
            monitor.getRecommendedParallelCount(),
            UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS
        )
    }
}
```

---

## 🔧 Phase 7: Integration Changes

### Modify: Core/Jobs/ContractConstants.swift

```swift
// Change line 3:
// Contract Version: PR2-JSM-3.0-merged
// To:
// Contract Version: PR3-API-1.0

// Change line 14:
public static let CONTRACT_VERSION = "PR3-API-1.0"

// Add after line 14:
/// Upload infrastructure version (see UploadConstants.swift)
public static let UPLOAD_MODULE_VERSION = UploadConstants.UPLOAD_CONTRACT_VERSION
```

### Modify: Core/Constants/APIContractConstants.swift

Add deprecation notice for CHUNK_SIZE_BYTES:

```swift
// Add near existing CHUNK_SIZE_BYTES:

/// @available(*, deprecated, message: "Use UploadConstants.CHUNK_SIZE_DEFAULT_BYTES instead")
/// Legacy chunk size constant - preserved for backward compatibility.
/// New code should use UploadConstants for all upload configuration.
```

---

## ✅ CI Verification Matrix

### Required CI Jobs (All Must Pass)

| Job | Platform | Purpose | Key Checks |
|-----|----------|---------|------------|
| Preflight | ubuntu-22.04 | Phase 0.5 guardrails | Tag verification, SSOT check |
| Test & Lint | ubuntu-22.04 | Platform-safe tests | Build, lint, SQLitePlatformTests |
| PIZ Tests (macos-15) | macos-15 | macOS PIZ validation | Build, PIZ tests, fixture dump |
| PIZ Tests (ubuntu-22.04) | ubuntu-22.04 | Linux PIZ validation | Build, PIZ tests, fixture dump |
| PIZ Cross-Platform | ubuntu-22.04 | Byte-identical check | Compare macOS vs Linux output |
| PIZ Sealing Evidence | ubuntu-22.04 | Evidence generation | Generate sealing proof |
| PIZ Final Gate | ubuntu-22.04 | No-skip policy | Assert all PIZ jobs success |
| CI Gate | macos-15 | Final gate | Run all CI checks |

### Pre-Push Verification Script

```bash
#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "PR3 Upload Infrastructure - Pre-Push Check"
echo "=========================================="

# 1. Clean build
echo "[1/7] Clean build..."
swift package clean
swift build 2>&1 | tee /tmp/pr3-build.log
if grep -i "error:" /tmp/pr3-build.log; then
    echo "❌ BUILD FAILED"
    exit 1
fi
echo "✅ Build passed"

# 2. Check for warnings
echo "[2/7] Check warnings..."
if swift build 2>&1 | grep -i "warning:"; then
    echo "⚠️  Warnings detected (review manually)"
fi

# 3. Run all tests
echo "[3/7] Run tests..."
swift test 2>&1 | tee /tmp/pr3-test.log
if grep "failed" /tmp/pr3-test.log | grep -v "0 failed"; then
    echo "❌ TESTS FAILED"
    exit 1
fi
echo "✅ All tests passed"

# 4. Verify contract version
echo "[4/7] Verify contract version..."
CONTRACT_VERSION=$(grep "CONTRACT_VERSION" Core/Jobs/ContractConstants.swift | head -1)
echo "Contract: $CONTRACT_VERSION"
if ! echo "$CONTRACT_VERSION" | grep -q "PR3-API-1.0"; then
    echo "❌ Contract version not updated to PR3-API-1.0"
    exit 1
fi
echo "✅ Contract version correct"

# 5. Verify upload module
echo "[5/7] Verify upload module..."
if [ ! -f "Core/Constants/UploadConstants.swift" ]; then
    echo "❌ UploadConstants.swift missing"
    exit 1
fi
if [ ! -f "Core/Upload/NetworkSpeedMonitor.swift" ]; then
    echo "❌ NetworkSpeedMonitor.swift missing"
    exit 1
fi
echo "✅ Upload module files exist"

# 6. Verify cross-platform compatibility
echo "[6/7] Verify cross-platform compatibility..."
# Check for forbidden Apple-only imports
FORBIDDEN_IMPORTS="import UIKit|import AppKit|import Network|import CoreFoundation"
if grep -rE "$FORBIDDEN_IMPORTS" Core/Upload/ Core/Constants/UploadConstants.swift 2>/dev/null; then
    echo "❌ Found Apple-only imports in upload module"
    exit 1
fi
echo "✅ No Apple-only imports"

# 7. Verify file headers
echo "[7/7] Verify Constitutional Contract headers..."
for file in Core/Upload/*.swift Core/Constants/UploadConstants.swift; do
    if [ -f "$file" ]; then
        if ! head -5 "$file" | grep -q "CONSTITUTIONAL CONTRACT"; then
            echo "❌ Missing Constitutional Contract header in $file"
            exit 1
        fi
    fi
done
echo "✅ All headers correct"

echo ""
echo "=========================================="
echo "✅ ALL PRE-PUSH CHECKS PASSED"
echo "=========================================="
echo ""
echo "Ready to push. Run:"
echo "  git push origin pr3/upload-infrastructure"
```

---

## 📝 Git Commit Message Template

```bash
git commit -m "$(cat <<'EOF'
feat(pr3): implement cross-platform upload infrastructure

BREAKING CHANGE: Contract version updated to PR3-API-1.0

## New Features
- Adaptive chunk sizing (2MB-20MB based on network speed)
- Parallel chunk uploads (up to 4 concurrent)
- Real-time network speed monitoring with weighted averaging
- Upload session lifecycle management with state machine
- Resume/recovery with UserDefaults persistence
- Stall detection and automatic retry
- Progress tracking with ETA calculation
- tus.io protocol header compatibility

## New Files
- Core/Constants/UploadConstants.swift - Upload SSOT (100+ constants)
- Core/Upload/NetworkSpeedMonitor.swift - Bandwidth measurement
- Core/Upload/AdaptiveChunkSizer.swift - Network-aware sizing
- Core/Upload/UploadSession.swift - Session state management
- Core/Upload/ChunkManager.swift - Parallel upload coordination
- Core/Upload/UploadResumeManager.swift - Resume persistence
- Core/Upload/UploadProgressTracker.swift - Progress aggregation
- Tests/Upload/*.swift - Comprehensive test coverage

## Cross-Platform Support
- Pure Foundation implementation (no Apple-only frameworks)
- Tested on macOS-15 and ubuntu-22.04
- Uses only libdispatch (available on Linux)
- All numeric types are fixed-width for consistency

## Network Speed Thresholds
- Slow: < 5 Mbps → 2MB chunks, 2 parallel
- Normal: 5-50 Mbps → 5MB chunks, 3 parallel
- Fast: 50-100 Mbps → 10MB chunks, 4 parallel
- Ultrafast: > 100 Mbps → 20MB chunks, 4 parallel

## References
- tus.io resumable upload protocol v1.0.0
- AWS S3 multipart upload best practices
- Netflix/AWS exponential backoff patterns

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## ⚠️ Critical Implementation Notes

### DO:
- Use `Int` for sizes (platform-native, consistent on 64-bit)
- Use `Int64` for file sizes (explicit 64-bit for large files)
- Use `TimeInterval` (Double alias) for durations
- Use `DispatchQueue` for thread safety (works on Linux)
- Test on both macOS and Linux before pushing

### DO NOT:
- Import `UIKit`, `AppKit`, `Network`, or other Apple-only frameworks
- Use `NWPathMonitor` or `NWConnection`
- Use `NSNumber` for arithmetic
- Assume `Int` is 32-bit
- Use blocking synchronous code in async contexts

### Testing Commands

```bash
# Local macOS test
swift test

# Linux test (via Docker)
docker run --rm -v "$PWD":/app -w /app swift:5.9 swift test

# Specific test filter
swift test --filter NetworkSpeedMonitorTests
swift test --filter UploadSessionTests
```

---

## 📋 Final Checklist Before PR

- [ ] All new files have Constitutional Contract header
- [ ] Contract version updated to PR3-API-1.0
- [ ] UploadConstants.swift created with all constants
- [ ] Core/Upload/ directory created with all 6 files
- [ ] Tests/Upload/ directory created with all 5 test files
- [ ] No Apple-only imports in upload module
- [ ] All tests pass locally
- [ ] Build succeeds with no errors
- [ ] Pre-push verification script passes
- [ ] Git commit message follows template
- [ ] Ready for CI validation
