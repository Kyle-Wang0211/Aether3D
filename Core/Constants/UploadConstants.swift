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

    /// Minimum progress increment percentage
    /// - Users notice changes >=2%, smaller increments feel stagnant
    public static let MIN_PROGRESS_INCREMENT_PERCENT: Double = 2.0

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
