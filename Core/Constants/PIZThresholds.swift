// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PIZThresholds.swift
// Aether3D
//
// PR1 PIZ Detection - SSOT Threshold Constants
//
// Single Source of Truth for all PIZ detection thresholds.
// No bare threshold numbers may exist outside this file.

import Foundation

/// PIZ Detection Thresholds (SSOT)
/// 
/// **Rule:** All PIZ-related thresholds MUST be defined here.
/// CI enforces that no bare threshold numbers exist elsewhere.
/// **Rule ID:** PIZ_COVERED_CELL_001, PIZ_MAX_REGIONS_DERIVED_001, PIZ_NUMERIC_FORMAT_001
public enum PIZThresholds {
    /// Covered cell predicate threshold.
    /// A cell is covered if value >= COVERED_CELL_MIN.
    /// **Rule ID:** PIZ_COVERED_CELL_001
    public static let COVERED_CELL_MIN: Double = 0.5
    
    /// Global coverage minimum threshold.
    /// If coverage_total < this value, global trigger fires (severity >= MEDIUM).
    public static let GLOBAL_COVERAGE_MIN: Double = 0.75
    
    /// Local coverage minimum threshold.
    /// A region is PIZ if coverage_local < this value AND other conditions are met.
    public static let LOCAL_COVERAGE_MIN: Double = 0.5
    
    /// Local area ratio minimum threshold.
    /// A region is PIZ if region_area_ratio >= this value AND other conditions are met.
    public static let LOCAL_AREA_RATIO_MIN: Double = 0.05
    
    /// Minimum region pixel count (noise suppression).
    /// Regions with pixel count < this value are filtered out.
    /// Grid-based, resolution independent.
    public static let MIN_REGION_PIXELS: Int = 8
    
    /// Hysteresis band for preventing flip-flop.
    /// Once recommendation is set, requires crossing threshold + hysteresis to change.
    public static let HYSTERESIS_BAND: Double = 0.05
    
    /// Severity threshold for HIGH severity (triggers RECAPTURE).
    public static let SEVERITY_HIGH_THRESHOLD: Double = 0.7
    
    /// Severity threshold for MEDIUM severity (triggers BLOCK_PUBLISH).
    public static let SEVERITY_MEDIUM_THRESHOLD: Double = 0.3
    
    /// Grid size for PIZ detection (32x32).
    public static let GRID_SIZE: Int = 32
    
    /// Total grid cells (32 * 32).
    public static let TOTAL_GRID_CELLS: Int = GRID_SIZE * GRID_SIZE
    
    /// Floating-point tolerance for coverage/ratio comparisons (relative error).
    /// **Rule ID:** PIZ_TOLERANCE_SSOT_001
    public static let COVERAGE_RELATIVE_TOLERANCE: Double = 1e-4
    
    /// Floating-point tolerance for Lab color component comparisons (absolute error).
    /// **Rule ID:** PIZ_TOLERANCE_SSOT_001
    public static let LAB_COLOR_ABSOLUTE_TOLERANCE: Double = 1e-3
    
    /// JSON canonicalization quantization precision.
    /// **Rule ID:** PIZ_FLOAT_CANON_001, PIZ_NUMERIC_FORMAT_001
    public static let JSON_CANON_QUANTIZATION_PRECISION: Double = 1e-6
    
    /// JSON canonicalization decimal places (derived from quantization precision).
    /// **Rule ID:** PIZ_NUMERIC_FORMAT_001
    /// Formula: decimalPlaces = -log10(JSON_CANON_QUANTIZATION_PRECISION)
    /// Must be an integer; verified at compile-time and runtime.
    /// 
    /// Note: Verification is done in tests (PIZThresholdsTests.testDecimalPlacesIsInteger)
    /// to avoid assert/fatalError in Core/Constants/ directory.
    public static let JSON_CANON_DECIMAL_PLACES: Int = {
        let precision = JSON_CANON_QUANTIZATION_PRECISION
        let decimalPlaces = -log10(precision)
        let rounded = Int(decimalPlaces.rounded())
        // Verification done in tests - no assert here to comply with Constants directory rules
        return rounded
    }()
    
    /// Maximum regions reported (derived from grid capacity).
    /// **Rule ID:** PIZ_MAX_REGIONS_DERIVED_001
    /// Formula: floor(TOTAL_GRID_CELLS / MIN_REGION_PIXELS)
    /// Derived: floor(1024 / 8) = 128
    public static let MAX_REPORTED_REGIONS: Int = TOTAL_GRID_CELLS / MIN_REGION_PIXELS
    
    /// Maximum component queue size (grid cells).
    /// **Rule ID:** PIZ_INPUT_BUDGET_001
    public static let MAX_COMPONENT_QUEUE_SIZE: Int = TOTAL_GRID_CELLS
    
    /// Maximum labeling iterations (bounded by grid size).
    /// **Rule ID:** PIZ_INPUT_BUDGET_001
    public static let MAX_LABELING_ITERATIONS: Int = TOTAL_GRID_CELLS
}

/// Combination logic for determining gate recommendation from detection results.
/// 
/// This is the ONLY place where threshold comparison logic lives.
/// Deterministic, testable, non-dynamic.
public struct PIZCombinationLogic {
    /// Compute gate recommendation from detection results.
    /// 
    /// - Parameters:
    ///   - globalTrigger: Whether global trigger fired
    ///   - regions: List of detected PIZ regions
    ///   - previousRecommendation: Previous recommendation (for hysteresis)
    /// - Returns: Gate recommendation
    public static func computeGateRecommendation(
        globalTrigger: Bool,
        regions: [PIZRegion],
        previousRecommendation: GateRecommendation? = nil
    ) -> GateRecommendation {
        // Global trigger always results in RECAPTURE
        if globalTrigger {
            return .recapture
        }
        
        // No local triggers
        if regions.isEmpty {
            return .allowPublish
        }
        
        // Find maximum severity among regions
        let maxSeverity = regions.map { $0.severityScore }.max() ?? 0.0
        
        // Apply hysteresis if previous recommendation exists
        if let previous = previousRecommendation {
            return applyHysteresis(
                severity: maxSeverity,
                previousRecommendation: previous
            )
        }
        
        // Determine recommendation based on severity thresholds
        if maxSeverity >= PIZThresholds.SEVERITY_HIGH_THRESHOLD {
            return .recapture
        } else if maxSeverity >= PIZThresholds.SEVERITY_MEDIUM_THRESHOLD {
            return .blockPublish
        } else {
            return .allowPublish
        }
    }
    
    /// Apply hysteresis to prevent flip-flopping.
    private static func applyHysteresis(
        severity: Double,
        previousRecommendation: GateRecommendation
    ) -> GateRecommendation {
        let band = PIZThresholds.HYSTERESIS_BAND
        
        switch previousRecommendation {
        case .recapture:
            // Need to drop below HIGH_THRESHOLD - band to change
            if severity < (PIZThresholds.SEVERITY_HIGH_THRESHOLD - band) {
                if severity >= PIZThresholds.SEVERITY_MEDIUM_THRESHOLD {
                    return .blockPublish
                } else {
                    return .allowPublish
                }
            }
            return .recapture
            
        case .blockPublish:
            // Need to cross HIGH_THRESHOLD + band to go up, or drop below MEDIUM_THRESHOLD - band to go down
            if severity >= (PIZThresholds.SEVERITY_HIGH_THRESHOLD + band) {
                return .recapture
            } else if severity < (PIZThresholds.SEVERITY_MEDIUM_THRESHOLD - band) {
                return .allowPublish
            }
            return .blockPublish
            
        case .allowPublish:
            // Need to cross MEDIUM_THRESHOLD + band to change
            if severity >= (PIZThresholds.SEVERITY_MEDIUM_THRESHOLD + band) {
                if severity >= (PIZThresholds.SEVERITY_HIGH_THRESHOLD + band) {
                    return .recapture
                } else {
                    return .blockPublish
                }
            }
            return .allowPublish
            
        case .insufficientData:
            // No hysteresis for insufficient data
            return computeGateRecommendation(globalTrigger: false, regions: [], previousRecommendation: nil)
        }
    }
}

/// Gate recommendation enum (closed set).
public enum GateRecommendation: String, Codable {
    case allowPublish = "ALLOW_PUBLISH"
    case blockPublish = "BLOCK_PUBLISH"
    case recapture = "RECAPTURE"
    case insufficientData = "INSUFFICIENT_DATA"
}
