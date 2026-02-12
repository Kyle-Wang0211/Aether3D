// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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
    // MARK: - Chunk Size Configuration (FINAL - PR9)
    // =========================================================================

    /// Minimum chunk size in bytes (256KB)
    /// - PR9: Reduced from 2MB to 256KB for CDC min chunk size
    public static let CHUNK_SIZE_MIN_BYTES: Int = 256 * 1024

    /// Default chunk size in bytes (2MB)
    /// - PR9: Reduced from 5MB to 2MB for better adaptability
    public static let CHUNK_SIZE_DEFAULT_BYTES: Int = 2 * 1024 * 1024

    /// Maximum chunk size in bytes (32MB)
    /// - PR9 v2.4: Increased from 20MB to 32MB for ultrafast networks
    /// - At 200+ Mbps, 16MB chunks complete in <1s
    /// - 32MB allows fewer HTTP round-trips on ultrafast networks
    public static let CHUNK_SIZE_MAX_BYTES: Int = 32 * 1024 * 1024

    /// Chunk size adjustment step (512KB)
    /// - PR9: Reduced from 1MB to 512KB for finer granularity
    public static let CHUNK_SIZE_STEP_BYTES: Int = 512 * 1024

    // =========================================================================
    // MARK: - Network Speed Thresholds (Mbps) - FINAL (PR9)
    // =========================================================================

    /// Slow network threshold: < 3 Mbps (SI Mbps, not Mibps!)
    /// - PR9: Fixed bug - uses SI Mbps: (speedBps * 8.0) / 1_000_000.0
    /// - Typical 3G, poor WiFi, congested networks
    public static let NETWORK_SPEED_SLOW_MBPS: Double = 3.0

    /// Normal network threshold: 3-30 Mbps
    /// - PR9: Adjusted for SI Mbps
    /// - Typical 4G LTE, good WiFi
    public static let NETWORK_SPEED_NORMAL_MBPS: Double = 30.0

    /// Fast network threshold: 30-100 Mbps
    /// - PR9: Adjusted for SI Mbps
    /// - 5G, fiber, excellent WiFi
    public static let NETWORK_SPEED_FAST_MBPS: Double = 100.0

    /// Ultrafast network threshold: > 200 Mbps
    /// - PR9: Added for 5.5G threshold
    public static let NETWORK_SPEED_ULTRAFAST_MBPS: Double = 200.0

    /// Minimum samples before speed estimation is reliable
    /// - PR9: Kalman needs ≥5 samples for convergence
    public static let NETWORK_SPEED_MIN_SAMPLES: Int = 5

    /// Speed measurement rolling window (seconds)
    /// - PR9: Full 5G oscillation cycle (60s)
    public static let NETWORK_SPEED_WINDOW_SECONDS: TimeInterval = 60.0

    /// Maximum speed samples to retain
    /// - PR9: Increased to 30 for ML predictor history
    public static let NETWORK_SPEED_MAX_SAMPLES: Int = 30

    // =========================================================================
    // MARK: - Parallel Upload Configuration (FINAL - PR9 v2.4)
    // =========================================================================

    /// Maximum concurrent chunk uploads
    /// - PR9 v2.4: Increased from 4 to 12 streams for maximum throughput
    public static let MAX_PARALLEL_CHUNK_UPLOADS: Int = 12

    /// Minimum concurrent chunk uploads
    /// - Always at least 1 for progress
    public static let MIN_PARALLEL_CHUNK_UPLOADS: Int = 1

    /// Ramp-up delay between parallel requests (milliseconds)
    /// - PR9 v2.4: 10ms between streams (was 100ms)
    /// - Prevents thundering herd on server
    public static let PARALLEL_RAMP_UP_DELAY_MS: Int = 10

    /// Parallelism adjustment interval (seconds)
    /// - PR9: Reduced from 5s to 3s for faster adaptation
    public static let PARALLELISM_ADJUST_INTERVAL: TimeInterval = 3.0

    // =========================================================================
    // MARK: - Upload Session Configuration (FINAL - PR9)
    // =========================================================================

    /// Maximum upload session age (seconds) - 48 hours
    /// - PR9: Extended from 24h to 48h for next-day resume
    public static let SESSION_MAX_AGE_SECONDS: TimeInterval = 172800  // 48h

    /// Session cleanup interval (seconds) - 30 minutes
    /// - PR9: More frequent cleanup (was 1h)
    public static let SESSION_CLEANUP_INTERVAL: TimeInterval = 1800   // 30min

    /// Maximum concurrent sessions per user
    /// - PR9: 3 × 12 = 36 connections max
    public static let SESSION_MAX_CONCURRENT: Int = 3

    /// Session state persistence key prefix
    /// - Used for UserDefaults storage
    /// - Namespaced to avoid collisions
    public static let SESSION_PERSISTENCE_KEY_PREFIX: String = "com.app.upload.session."

    // =========================================================================
    // MARK: - Timeout Configuration (FINAL - PR9)
    // =========================================================================

    /// Individual chunk upload timeout (seconds)
    /// - PR9: Reduced from 60s to 45s for faster failure detection
    public static let CHUNK_TIMEOUT_SECONDS: TimeInterval = 45.0

    /// Connection establishment timeout (seconds)
    /// - PR9: Reduced from 10s to 8s for faster connection
    public static let CONNECTION_TIMEOUT_SECONDS: TimeInterval = 8.0

    /// Stall detection timeout (seconds)
    /// - PR9: Reduced from 15s to 10s
    public static let STALL_DETECTION_TIMEOUT: TimeInterval = 10.0

    /// Minimum progress rate before stall (bytes/second)
    /// - PR9: Increased from 1KB/s to 4KB/s
    public static let STALL_MIN_PROGRESS_RATE_BPS: Int = 4096        // 4KB/s minimum

    // =========================================================================
    // MARK: - Retry Configuration (FINAL - PR9 v2.4)
    // =========================================================================

    /// Maximum retries per chunk
    /// - PR9 v2.4: Increased from 3 to 7 retries
    public static let CHUNK_MAX_RETRIES: Int = 7

    /// Retry base delay (seconds)
    /// - PR9 v2.4: Reduced from 2.0s to 0.5s
    /// - Decorrelated jitter: min(cap, random(base, previous_sleep * 3))
    public static let RETRY_BASE_DELAY_SECONDS: TimeInterval = 0.5

    /// Maximum retry delay (seconds)
    /// - PR9 v2.4: Reduced from 60s to 15s
    public static let RETRY_MAX_DELAY_SECONDS: TimeInterval = 15.0

    /// Retry jitter factor
    /// - PR9: Full jitter (1.0)
    public static let RETRY_JITTER_FACTOR: Double = 1.0

    // =========================================================================
    // MARK: - Progress Reporting (FINAL - PR9)
    // =========================================================================

    /// Progress update throttle interval (seconds)
    /// - PR9: 20fps (50ms) for 60Hz+120Hz displays
    public static let PROGRESS_THROTTLE_INTERVAL: TimeInterval = 0.05

    /// Minimum bytes delta before progress update
    /// - PR9: Reduced from 64KB to 32KB
    public static let PROGRESS_MIN_BYTES_DELTA: Int = 32 * 1024        // 32KB

    /// Progress smoothing factor (0.0 - 1.0)
    /// - PR9: Reduced from 0.3 to 0.2
    public static let PROGRESS_SMOOTHING_FACTOR: Double = 0.2

    /// Minimum progress increment percentage
    /// - PR9: Reduced from 2% to 1%
    public static let MIN_PROGRESS_INCREMENT_PERCENT: Double = 1.0

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
    // MARK: - File Validation (FINAL - PR9)
    // =========================================================================

    /// Maximum file size for upload (bytes) - 50GB
    /// - PR9: Increased from 10GB to 50GB
    public static let MAX_FILE_SIZE_BYTES: Int64 = 50 * 1024 * 1024 * 1024  // 50GB

    /// Minimum file size for chunked upload (bytes) - 2MB
    /// - PR9: Reduced from 5MB to 2MB
    public static let MIN_CHUNKED_UPLOAD_SIZE_BYTES: Int64 = 2 * 1024 * 1024  // 2MB

    /// Minimum file size for upload (bytes) - 1 byte
    /// - Reject empty files
    public static let MIN_FILE_SIZE_BYTES: Int64 = 1

    // =========================================================================
    // MARK: - Idempotency Configuration (FINAL - PR9)
    // =========================================================================

    /// Idempotency key header name
    public static let IDEMPOTENCY_KEY_HEADER: String = "X-Idempotency-Key"

    /// Idempotency key maximum age (seconds) - 48 hours
    /// - PR9: Match session max age (48h)
    public static let IDEMPOTENCY_KEY_MAX_AGE: TimeInterval = 172800  // Match session max age

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

    // =========================================================================
    // MARK: - KALMAN FILTER (FINAL - PR9)
    // =========================================================================

    public static let KALMAN_PROCESS_NOISE_BASE: Double = 0.01
    public static let KALMAN_MEASUREMENT_NOISE_FLOOR: Double = 0.001
    public static let KALMAN_ANOMALY_THRESHOLD_SIGMA: Double = 2.5
    public static let KALMAN_CONVERGENCE_THRESHOLD: Double = 5.0
    public static let KALMAN_DYNAMIC_R_SAMPLE_COUNT: Int = 10

    // =========================================================================
    // MARK: - MERKLE TREE (FINAL - PR9)
    // =========================================================================

    public static let MERKLE_SUBTREE_CHECKPOINT_INTERVAL: Int = 16
    public static let MERKLE_MAX_TREE_DEPTH: Int = 24
    public static let MERKLE_LEAF_PREFIX: UInt8 = 0x00
    public static let MERKLE_NODE_PREFIX: UInt8 = 0x01

    // =========================================================================
    // MARK: - COMMITMENT CHAIN (FINAL - PR9)
    // =========================================================================

    public static let COMMITMENT_CHAIN_DOMAIN: String = "CCv1\0"
    public static let COMMITMENT_CHAIN_JUMP_DOMAIN: String = "CCv1_JUMP\0"
    public static let COMMITMENT_CHAIN_GENESIS_PREFIX: String = "Aether3D_CC_GENESIS_"

    // =========================================================================
    // MARK: - BYZANTINE VERIFICATION (FINAL - PR9)
    // =========================================================================

    public static let BYZANTINE_VERIFY_DELAY_MS: Int = 100
    public static let BYZANTINE_VERIFY_TIMEOUT_MS: Int = 500
    public static let BYZANTINE_MAX_FAILURES: Int = 3
    public static let BYZANTINE_COVERAGE_TARGET: Double = 0.999

    // =========================================================================
    // MARK: - CIRCUIT BREAKER (FINAL - PR9)
    // =========================================================================

    public static let CIRCUIT_BREAKER_FAILURE_THRESHOLD: Int = 5
    public static let CIRCUIT_BREAKER_HALF_OPEN_INTERVAL: TimeInterval = 30.0
    public static let CIRCUIT_BREAKER_SUCCESS_THRESHOLD: Int = 2
    public static let CIRCUIT_BREAKER_WINDOW_SECONDS: TimeInterval = 60.0

    // =========================================================================
    // MARK: - ERASURE CODING (FINAL - PR9)
    // =========================================================================

    public static let ERASURE_RS_DATA_SYMBOLS: Int = 20
    public static let ERASURE_RAPTORQ_FALLBACK_LOSS_RATE: Double = 0.08
    public static let ERASURE_MAX_OVERHEAD_PERCENT: Double = 50.0

    // =========================================================================
    // MARK: - CDC (FINAL - PR9)
    // =========================================================================

    public static let CDC_MIN_CHUNK_SIZE: Int = 256 * 1024              // 256KB
    public static let CDC_MAX_CHUNK_SIZE: Int = 8 * 1024 * 1024         // 8MB
    public static let CDC_AVG_CHUNK_SIZE: Int = 1 * 1024 * 1024         // 1MB
    public static let CDC_GEAR_TABLE_VERSION: String = "v1"
    public static let CDC_NORMALIZATION_LEVEL: Int = 1
    public static let CDC_DEDUP_MIN_SAVINGS_RATIO: Double = 0.20
    public static let CDC_DEDUP_QUERY_TIMEOUT: TimeInterval = 5.0

    // =========================================================================
    // MARK: - RAPTORQ (FINAL - PR9)
    // =========================================================================

    public static let RAPTORQ_OVERHEAD_TARGET: Double = 0.02
    public static let RAPTORQ_MAX_REPAIR_RATIO: Double = 2.0
    public static let RAPTORQ_SYMBOL_ALIGNMENT: Int = 64
    public static let RAPTORQ_LDPC_DENSITY: Double = 0.01
    public static let RAPTORQ_INACTIVATION_THRESHOLD: Double = 0.10
    public static let RAPTORQ_CHUNK_COUNT_THRESHOLD: Int = 256

    // =========================================================================
    // MARK: - ML PREDICTOR (FINAL - PR9)
    // =========================================================================

    public static let ML_PREDICTION_HISTORY_LENGTH: Int = 30
    public static let ML_MODEL_FILENAME: String = "AetherBandwidthLSTM"
    public static let ML_WARMUP_SAMPLES: Int = 10
    public static let ML_ENSEMBLE_WEIGHT_MIN: Double = 0.3
    public static let ML_ENSEMBLE_WEIGHT_MAX: Double = 0.7
    public static let ML_INFERENCE_TIMEOUT_MS: Int = 5
    public static let ML_ACCURACY_WINDOW: Int = 10
    public static let ML_MODEL_MAX_SIZE_BYTES: Int = 5 * 1024 * 1024    // 5MB

    // =========================================================================
    // MARK: - CAMARA QoD (FINAL - PR9)
    // =========================================================================

    public static let QOD_DEFAULT_DURATION: TimeInterval = 3600
    public static let QOD_SESSION_CREATION_TIMEOUT: TimeInterval = 10.0
    public static let QOD_TOKEN_REFRESH_MARGIN: TimeInterval = 60
    public static let QOD_MIN_FILE_SIZE: Int64 = 100 * 1024 * 1024      // 100MB

    // =========================================================================
    // MARK: - MULTIPATH (FINAL - PR9)
    // =========================================================================

    public static let MULTIPATH_EWMA_ALPHA: Double = 0.3
    public static let MULTIPATH_MEASUREMENT_WINDOW: TimeInterval = 30.0
    public static let MULTIPATH_MAX_PARALLEL_PER_PATH: Int = 4
    public static let MULTIPATH_EXPECTED_THROUGHPUT_GAIN: Double = 1.7

    // =========================================================================
    // MARK: - PERFORMANCE (FINAL - PR9 v2.4)
    // =========================================================================

    public static let MMAP_WINDOW_SIZE_MACOS: Int = 64 * 1024 * 1024    // 64MB
    public static let MMAP_WINDOW_SIZE_IOS: Int = 32 * 1024 * 1024      // 32MB
    public static let PREFETCH_PIPELINE_DEPTH: Int = 3                    // Read N+2 while uploading N
    public static let LZFSE_COMPRESSION_THRESHOLD: Double = 0.10          // 10% min savings
    public static let PARALLEL_STREAM_RAMP_DELAY_NS: UInt64 = 10_000_000 // 10ms
    public static let BUFFER_POOL_MAX_BUFFERS: Int = 12
    public static let BUFFER_POOL_MIN_BUFFERS: Int = 2                    // NEVER below 2

    // =========================================================================
    // MARK: - WATCHDOG (FINAL - PR9 v2.4)
    // =========================================================================

    public static let WATCHDOG_SESSION_TIMEOUT: TimeInterval = 60.0      // Per-session
    public static let WATCHDOG_GLOBAL_TIMEOUT: TimeInterval = 300.0      // Global no-ACK
    public static let WATCHDOG_CHUNK_TIMEOUT_MULTIPLIER: Double = 2.0    // Dynamic per-chunk
    public static let WATCHDOG_CHUNK_TIMEOUT_PADDING: TimeInterval = 5.0

    // =========================================================================
    // MARK: - NETWORK TRANSITION (FINAL - PR9 v2.4)
    // =========================================================================

    public static let NETWORK_TRANSITION_OVERLAP_SECONDS: TimeInterval = 2.0
    public static let NETWORK_TRANSITION_HANDOFF_TIMEOUT: TimeInterval = 5.0
}

// =========================================================================
// MARK: - Compile-Time Validation
// =========================================================================

#if DEBUG
/// Compile-time assertions for constant validity
/// These run only in debug builds to catch configuration errors
/// FATAL_OK: Debug-only assertions for sanity checking constant relationships
private enum UploadConstantsValidation {
    static func validate() {
        // Chunk size ordering
        assert(UploadConstants.CHUNK_SIZE_MIN_BYTES < UploadConstants.CHUNK_SIZE_DEFAULT_BYTES, // FATAL_OK
               "MIN chunk size must be less than DEFAULT")
        assert(UploadConstants.CHUNK_SIZE_DEFAULT_BYTES < UploadConstants.CHUNK_SIZE_MAX_BYTES, // FATAL_OK
               "DEFAULT chunk size must be less than MAX")

        // Network speed ordering
        assert(UploadConstants.NETWORK_SPEED_SLOW_MBPS < UploadConstants.NETWORK_SPEED_NORMAL_MBPS, // FATAL_OK
               "SLOW speed must be less than NORMAL")
        assert(UploadConstants.NETWORK_SPEED_NORMAL_MBPS < UploadConstants.NETWORK_SPEED_FAST_MBPS, // FATAL_OK
               "NORMAL speed must be less than FAST")

        // Parallelism bounds
        assert(UploadConstants.MIN_PARALLEL_CHUNK_UPLOADS >= 1, // FATAL_OK
               "MIN parallel uploads must be at least 1")
        assert(UploadConstants.MIN_PARALLEL_CHUNK_UPLOADS <= UploadConstants.MAX_PARALLEL_CHUNK_UPLOADS, // FATAL_OK
               "MIN parallel uploads must not exceed MAX")

        // Timeout sanity
        assert(UploadConstants.STALL_DETECTION_TIMEOUT < UploadConstants.CHUNK_TIMEOUT_SECONDS, // FATAL_OK
               "Stall detection must be faster than chunk timeout")

        // Retry sanity
        assert(UploadConstants.RETRY_BASE_DELAY_SECONDS < UploadConstants.RETRY_MAX_DELAY_SECONDS, // FATAL_OK
               "Base retry delay must be less than max")
    }
}
#endif
