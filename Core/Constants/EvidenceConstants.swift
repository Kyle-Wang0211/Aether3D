//
// EvidenceConstants.swift
// Aether3D
//
// PR2 Patch V4 - Evidence System Constants (SSOT)
// Single Source of Truth for all evidence-related constants
//

import Foundation

/// All evidence-related constants
/// SSOT: Single Source of Truth for evidence system
public enum EvidenceConstants {
    
    // MARK: - EMA
    
    /// EMA smoothing coefficient (ledger → display)
    /// Legacy alias for patchDisplayAlpha
    @available(*, deprecated, renamed: "patchDisplayAlpha")
    public static var emaAlpha: Double { patchDisplayAlpha }
    
    /// Patch display EMA alpha (smoothing coefficient)
    ///
    /// Controls how quickly display evidence responds to ledger updates.
    /// Lower values = smoother, slower response.
    /// Higher values = faster response, more jitter.
    ///
    /// ACCEPTABLE RANGE: [0.1, 0.3]
    /// DEFAULT: 0.2
    public static let patchDisplayAlpha: Double = 0.2
    
    /// Locked patch display acceleration multiplier
    ///
    /// When a patch is locked (high confidence), its display growth rate
    /// is multiplied by this factor. Still maintains monotonicity.
    ///
    /// ACCEPTABLE RANGE: [1.2, 2.0]
    /// DEFAULT: 1.5
    public static let patchDisplayLockedAcceleration: Double = 1.5
    
    /// Color evidence local weight (Rule F)
    ///
    /// Local patch display contribution to color evidence.
    /// ACCEPTABLE RANGE: [0.6, 0.8]
    /// DEFAULT: 0.70
    public static let colorEvidenceLocalWeight: Double = 0.70
    
    /// Color evidence global weight (Rule F)
    ///
    /// Global display contribution to color evidence.
    /// ACCEPTABLE RANGE: [0.2, 0.4]
    /// DEFAULT: 0.30
    public static let colorEvidenceGlobalWeight: Double = 0.30
    
    // MARK: - Penalty
    
    /// Base penalty for error observations
    public static let basePenalty: Double = 0.05
    
    /// Maximum penalty per update
    public static let maxPenaltyPerUpdate: Double = 0.15
    
    /// Error cooldown period in seconds
    public static let errorCooldownSec: Double = 1.0
    
    /// Maximum error streak to consider
    public static let maxErrorStreak: Int = 5
    
    // MARK: - Soft Ledger Write Policy (B1)
    
    /// Minimum gate quality required to write to soft ledger
    ///
    /// SEMANTIC MEANING:
    /// Soft evidence (depth/topology/occlusion) is only meaningful when there's
    /// a stable geometric foundation (gate). This threshold defines "stable enough".
    ///
    /// VALUE ANALYSIS:
    /// - 0.20 = Too low: Writes soft evidence on unstable geometry, leads to false positives
    /// - 0.25 = Conservative: Safe for most scenes, may miss some valid soft data
    /// - 0.30 = DEFAULT: Good balance for typical indoor/outdoor scenes
    /// - 0.35 = Strict: For high-precision applications, may slow soft evidence growth
    /// - 0.40 = Too strict: Most soft evidence never written
    ///
    /// ACCEPTABLE RANGE: [0.25, 0.35]
    ///
    /// TUNING SCENARIOS:
    /// - Weak texture (blank walls): Consider 0.25 (allow more soft writes)
    /// - High precision (industrial): Consider 0.35 (stricter gate requirement)
    /// - Moving objects: Keep at 0.30 (balance between coverage and accuracy)
    ///
    /// MATHEMATICAL INTERPRETATION:
    /// 0.30 ≈ 3-4 L2+ quality observations from diverse angles
    /// This means the patch has been seen well enough to establish basic geometry.
    public static let softWriteRequiresGateMin: Double = 0.30
    
    /// Acceptable range for softWriteRequiresGateMin
    public static let softWriteRequiresGateMinRange: ClosedRange<Double> = 0.25...0.35
    
    // MARK: - Weights
    
    /// Observation count weight cap denominator
    public static let weightCapDenominator: Double = 8.0
    
    /// Patch color blend: local weight
    public static let patchLocalWeight: Double = 0.7
    
    /// Patch color blend: global weight
    public static let patchGlobalWeight: Double = 0.3
    
    // MARK: - Dynamic Weights
    
    /// Early stage Gate weight (geometry foundation dominates)
    ///
    /// SEMANTIC MEANING:
    /// In early stages, gate evidence (geometric reachability) is more reliable
    /// than soft evidence (quality metrics). This weight reflects that priority.
    ///
    /// ACCEPTABLE RANGE: [0.60, 0.70]
    /// DEFAULT: 0.65
    public static let dynamicWeightsGateEarly: Double = 0.65
    
    /// Late stage Gate weight (quality refinement dominates)
    ///
    /// SEMANTIC MEANING:
    /// In late stages, soft evidence (quality metrics) becomes more important
    /// as geometry is already established. Gate weight decreases accordingly.
    ///
    /// ACCEPTABLE RANGE: [0.30, 0.40]
    /// DEFAULT: 0.35
    public static let dynamicWeightsGateLate: Double = 0.35
    
    /// Weight transition start point (normalized progress)
    ///
    /// When progress < transitionStart, use early weights.
    /// ACCEPTABLE RANGE: [0.40, 0.50]
    /// DEFAULT: 0.45
    public static let dynamicWeightsTransitionStart: Double = 0.45
    
    /// Weight transition end point (normalized progress)
    ///
    /// When progress > transitionEnd, use late weights.
    /// ACCEPTABLE RANGE: [0.70, 0.80]
    /// DEFAULT: 0.75
    public static let dynamicWeightsTransitionEnd: Double = 0.75
    
    /// Epsilon for weight sum validation
    ///
    /// Used to verify gate + soft ≈ 1.0 within floating-point precision.
    /// DEFAULT: 1e-9
    public static let dynamicWeightsEpsilon: Double = 1e-9
    
    // Legacy aliases for backward compatibility
    @available(*, deprecated, renamed: "dynamicWeightsGateEarly")
    public static var earlyGateWeight: Double { dynamicWeightsGateEarly }
    
    @available(*, deprecated, renamed: "dynamicWeightsGateLate")
    public static var lateGateWeight: Double { dynamicWeightsGateLate }
    
    @available(*, deprecated, renamed: "dynamicWeightsTransitionStart")
    public static var weightTransitionStart: Double { dynamicWeightsTransitionStart }
    
    @available(*, deprecated, renamed: "dynamicWeightsTransitionEnd")
    public static var weightTransitionEnd: Double { dynamicWeightsTransitionEnd }
    
    // MARK: - Color Mapping
    
    /// Black threshold
    public static let blackThreshold: Double = 0.20
    
    /// Dark gray threshold
    public static let darkGrayThreshold: Double = 0.45
    
    /// Light gray threshold
    public static let lightGrayThreshold: Double = 0.70
    
    /// White threshold (S5 total requirement)
    public static let whiteThreshold: Double = 0.88
    
    /// S5 minimum soft evidence requirement
    public static let s5MinSoftEvidence: Double = 0.75
    
    // MARK: - Stale Patch
    
    /// Stale patch threshold in seconds
    public static let patchStaleThreshold: TimeInterval = 300.0
    
    // MARK: - Token Bucket
    
    /// Token refill rate per second
    ///
    /// Controls how quickly tokens regenerate for rate limiting.
    /// ACCEPTABLE RANGE: [0.5, 5.0] tokens/second
    /// DEFAULT: 2.0 tokens/second
    public static let tokenRefillRatePerSec: Double = 2.0
    
    /// Maximum tokens per patch bucket
    ///
    /// Prevents unbounded token accumulation.
    /// ACCEPTABLE RANGE: [5.0, 20.0] tokens
    /// DEFAULT: 10.0 tokens
    public static let tokenBucketMaxTokens: Double = 10.0
    
    /// Token cost per observation
    ///
    /// How many tokens each observation consumes.
    /// ACCEPTABLE RANGE: [0.5, 2.0] tokens
    /// DEFAULT: 1.0 token
    public static let tokenCostPerObservation: Double = 1.0
    
    // MARK: - View Diversity
    
    /// View angle bucket size in degrees
    ///
    /// Patches are bucketed by view angle for diversity tracking.
    /// ACCEPTABLE RANGE: [10, 30] degrees
    /// DEFAULT: 15 degrees
    public static let diversityAngleBucketSizeDeg: Double = 15.0
    
    /// Maximum buckets tracked per patch
    ///
    /// Limits memory usage for diversity tracking.
    /// ACCEPTABLE RANGE: [8, 24] buckets
    /// DEFAULT: 16 buckets
    public static let diversityMaxBucketsTracked: Int = 16
    
    // MARK: - Smoother
    
    /// Default smoother window size
    public static let defaultSmootherWindowSize: AllowedWindowSize = .medium
    
    // MARK: - Spam Protection (V2)
    
    /// Time density minimum interval (ms)
    public static let minUpdateIntervalMs: Double = 120.0
    
    /// Minimum novelty to write to ledger
    public static let minNoveltyForLedger: Double = 0.1
    
    // MARK: - Anomaly Quarantine (V2)
    
    /// Consecutive suspect frames for bad upgrade
    public static let quarantineThreshold: Int = 3
    
    /// Quarantine entry timeout (seconds)
    public static let quarantineTimeoutSec: Double = 1.0
    
    // MARK: - Confidence Decay (V2)
    
    /// Confidence decay half-life (seconds)
    public static let confidenceHalfLifeSec: Double = 60.0
    
    // MARK: - Evidence Locking (V2)
    
    /// Evidence threshold for locking
    public static let lockThreshold: Double = 0.85
    
    /// Minimum observations for locking
    public static let minObservationsForLock: Int = 20
    
    // MARK: - Robust Statistics (V2)
    
    /// Huber loss delta
    public static let huberDelta: Double = 0.1
    
    // MARK: - View Diversity (V2)
    
    /// Angle bucket size (degrees)
    public static let angleBucketSize: Float = 15.0
    
    // MARK: - Token Bucket (V2)
    
    /// Tokens per second refill rate
    // Legacy alias (deprecated)
    @available(*, deprecated, renamed: "tokenRefillRatePerSec")
    public static var tokenRefillRate: Double { tokenRefillRatePerSec }
    
    /// Maximum tokens per patch
    public static let maxTokensPerPatch: Double = 10.0
    
    // MARK: - Patch Strategy (V2)
    
    /// PR2 tile size (pixels)
    public static let defaultTileSize: Int = 32
    
    /// PR3 voxel size (meters)
    public static let defaultVoxelSize: Float = 0.03
    
    // MARK: - JSON Encoding (V2)
    
    /// Float quantization precision
    public static let floatPrecision: Int = 4
    
    // MARK: - Admission Controller (V4)
    
    /// Minimum soft penalty scale (guaranteed minimum throughput)
    public static let minimumSoftScale: Double = 0.25
    
    /// Soft penalty when token unavailable
    public static let noTokenPenalty: Double = 0.6
    
    /// Low novelty threshold
    public static let lowNoveltyThreshold: Double = 0.2
    
    /// Soft penalty for low novelty
    public static let lowNoveltyPenalty: Double = 0.7
}

/// Allowed window sizes for median smoothing
public enum AllowedWindowSize: Int, CaseIterable, Sendable {
    case small = 3
    case medium = 5
    case large = 7
    case extraLarge = 9
}
