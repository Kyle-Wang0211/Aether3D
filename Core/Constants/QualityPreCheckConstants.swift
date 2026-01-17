//
//  QualityPreCheckConstants.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Centralized constants for quality pre-check system
//  H2: All time windows must be centralized here
//

import Foundation

/// QualityPreCheckConstants - centralized constants
/// H2: All time window constants must be defined here (no hardcoded time values in code)
public struct QualityPreCheckConstants {
    
    // MARK: - Threshold Constants (PART 11.1)
    
    /// C/B/E tier thresholds
    public static let CONFIDENCE_THRESHOLD_FULL: Double = 0.80
    public static let CONFIDENCE_THRESHOLD_DEGRADED: Double = 0.90
    
    /// Stability thresholds (P18)
    public static let FULL_WHITE_STABILITY_MAX: Double = 0.15  // 15% variance allowed
    public static let DEGRADED_WHITE_STABILITY_MAX: Double = 0.12  // 12% variance allowed (stricter)
    
    // MARK: - Time Constants (PART 11.2, H2: Centralized)
    
    /// Direction window time constants
    public static let DIR_ENTER_STABLE_MS: Int64 = 500
    public static let DIR_NO_PROGRESS_MS: Int64 = 2000
    public static let DIR_MIN_LIFETIME_MS: Int64 = 1000
    public static let DIR_COOLDOWN_MS: Int64 = 500
    
    /// Trend confirmation window
    public static let TREND_WINDOW_MS: Int64 = 300
    
    /// First feedback KPI (P11)
    public static let MAX_TIME_TO_FIRST_FEEDBACK_MS: Int64 = 500
    
    /// Freeze hysteresis
    public static let FREEZE_HYSTERESIS_MS: Int64 = 200
    
    /// No progress warning
    public static let NO_PROGRESS_WARNING_MS: Int64 = 2000
    
    /// Speed smoothing
    public static let SPEED_SMOOTHING_WINDOW_MS: Int64 = 200
    public static let SPEED_MAX_CHANGE_RATE: Double = 0.30  // 30% per 200ms
    
    /// Hint cooldown
    public static let HINT_COOLDOWN_MS: Int64 = 2000
    
    /// Edge pulse cooldown/debounce (H1)
    public static let EDGE_PULSE_COOLDOWN_MS: Int64 = 200
    public static let EDGE_PULSE_DEBOUNCE_MS: Int64 = 50
    
    /// Degradation hysteresis (H1)
    public static let DEGRADATION_HYSTERESIS_MS: Int64 = 500
    public static let EMERGENCY_EXIT_HYSTERESIS_MS: Int64 = 1500
    
    // MARK: - FPS Constants (PART 11.3)
    
    public static let FPS_FULL_THRESHOLD: Double = 30.0
    public static let FPS_DEGRADED_THRESHOLD: Double = 20.0
    public static let FPS_EMERGENCY_EXIT_THRESHOLD: Double = 25.0
    
    // MARK: - Performance Budget (PART 8.3)
    
    public static let PERFORMANCE_BUDGET_P50_MS: Double = 14.0
    public static let PERFORMANCE_BUDGET_P95_MS: Double = 22.0
    public static let PERFORMANCE_BUDGET_EMERGENCY_P50_MS: Double = 2.0
    
    // MARK: - RingBuffer Capacity Limits (H2)
    
    public static let MAX_TREND_BUFFER_SIZE: Int = 100
    public static let MAX_MOTION_BUFFER_SIZE: Int = 50
    
    // MARK: - Commit Retry Constants (H1)
    
    public static let MAX_COMMIT_RETRIES: Int = 3
    public static let MAX_COMMIT_RETRY_TOTAL_MS: Int64 = 300
    public static let COMMIT_RETRY_INITIAL_DELAY_MS: Int64 = 10
    public static let COMMIT_RETRY_MAX_DELAY_MS: Int64 = 100
    
    // MARK: - Payload Size Limits (H1)
    
    public static let MAX_AUDIT_PAYLOAD_BYTES: Int = 64 * 1024  // 64 KB
    public static let MAX_COVERAGE_DELTA_PAYLOAD_BYTES: Int = 256 * 1024  // 256 KB
    
    // MARK: - Commit Limits (H1)
    
    public static let MAX_COMMITS_PER_SESSION: Int = 100_000
    
    // MARK: - CoverageDelta Limits (H1)
    
    public static let MAX_DELTA_CHANGED_COUNT: Int = 16_384
    public static let MAX_CELL_INDEX: Int = 16_383  // 128*128-1
    
    // MARK: - Hint Limits
    
    public static let HINT_MAX_STRONG_PER_SESSION: Int = 4
    public static let HINT_MAX_SUBTLE_PER_DIRECTION: Int = 1
    
    // MARK: - Progress Thresholds
    
    public static let MIN_PROGRESS_INCREMENT: Int = 10  // cells
    public static let MIN_VISIBLE_PROGRESS_INCREMENT: Int = 30  // cells
    
    // MARK: - Float Comparison Epsilon (H2)
    
    public static let FLOAT_COMPARISON_EPSILON: Double = 1e-6
    
    // MARK: - Stopped Animation
    
    public static let STOPPED_ANIMATION_FREQUENCY_HZ: Double = 0.5  // 0.5Hz = 2 seconds period
}

