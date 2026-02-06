// PR1 C-Class v2.3b — FROZEN SEMANTICS
// Any change here requires SSOT-Change: yes and full deterministic replay validation.
//
// CapacityLimitConstants.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Capacity Limit Constants
//
// SSOT constants for capacity control thresholds and EEB physical budget
//

import Foundation

/// Capacity limit constants (SSOT)
/// 
/// These constants define fixed thresholds for SOFT_LIMIT and HARD_LIMIT capacity control.
/// EEB (Effective Evidence Budget) is a physical budget and MUST NOT depend on maxPatches or CaptureProfile.
public enum CapacityLimitConstants {
    /// SOFT_LIMIT patch count threshold
    /// Unit: patch count (shadow metric only)
    /// Semantic: counts alive accepted patches
    public static let SOFT_LIMIT_PATCH_COUNT: Int = 5000
    
    /// HARD_LIMIT patch count threshold
    /// Unit: patch count (shadow metric only)
    /// Semantic: counts alive accepted patches
    public static let HARD_LIMIT_PATCH_COUNT: Int = 8000
    
    /// EEB base budget (physical budget constant, SSOT)
    /// 
    /// EEB is a physical budget and MUST NOT depend on:
    /// - maxPatches
    /// - CaptureProfile (in PR1)
    /// - runtime strategy inputs
    /// 
    /// EEB_INIT = EEB_BASE_BUDGET is the only initialization source.
    public static let EEB_BASE_BUDGET: Double = 10000.0
    
    /// Minimum EEB quantum per accepted patch
    /// Prevents infinite micro-patching attacks
    public static let EEB_MIN_QUANTUM: Double = 1.0
    
    /// SOFT budget threshold (EEB soft threshold)
    /// Normative constant, MUST NOT be derived from patch count
    public static let SOFT_BUDGET_THRESHOLD: Double = 2000.0
    
    /// HARD budget threshold (EEB hard threshold)
    /// Optional fuse path; if present must be constant
    /// MUST NOT be derived from patch count
    public static let HARD_BUDGET_THRESHOLD: Double = 500.0
    
    /// Information gain minimum threshold for SOFT damping mode
    public static let IG_MIN_SOFT: Double = 0.1
    
    /// Novelty minimum threshold for SOFT damping mode
    public static let NOVELTY_MIN_SOFT: Double = 0.1
    
    // MARK: - Duplicate Detection Constants
    
    /// Pose epsilon for duplicate detection (SSOT constant)
    public static let POSE_EPS: Double = 0.01
    
    /// Coverage cell size for duplicate detection (SSOT constant)
    public static let COVERAGE_CELL_SIZE: Double = 0.1
    
    /// Radiance binning for duplicate detection (SSOT constant)
    public static let RADIANCE_BINNING: Int = 16
}

/// Degradation reason code (closed-world enum)
/// 
/// **P0 Contract:**
/// - UInt8 closed-world enum
/// - All degradation transitions must record reasonCode
/// - Audit must include reasonCode
public enum DegradationReasonCode: UInt8 {
    /// Saturated escalation (SATURATED → SHEDDING, fixed path)
    case SATURATED_ESCALATION = 1
    
    /// EEB threshold reached
    case EEB_THRESHOLD_REACHED = 2
    
    /// Value score below minimum
    case VALUE_SCORE_BELOW_MIN = 3
    
    /// Retry storm detected
    case RETRY_STORM_DETECTED = 4
    
    /// Arithmetic overflow (limiter overflow)
    case ARITHMETIC_OVERFLOW = 5
    
    /// Extensions exhausted
    case EXTENSIONS_EXHAUSTED = 6
    
    // Closed-world: no unknown default
}
