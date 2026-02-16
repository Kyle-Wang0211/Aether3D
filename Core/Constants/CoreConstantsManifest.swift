// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoreConstantsManifest.swift
// Aether3D
//
// CORE-PURE CONSTANT HUB
// Single manifest for all constants that belong in libAether3DEngine (C++ migration target).
//
// RULE: Only pure-logic constants. No I/O, no platform SDK, no network.
// REF: CURSOR_MEGA_PROMPT_V2.5 § INVIOLABLE BOUNDARY CONTRACT
//

import Foundation

/// Core-pure constant manifest for C++ migration target.
///
/// Version: 1.0.0 (2026-02-11)
/// All values here MUST be byte-identical in Track P Swift→C++ migration.
public enum CoreConstantsManifest {

    // MARK: - Version

    /// Manifest version for cross-validation with Python/Server.
    public static let CORE_CONSTANTS_VERSION = "1.0.0"

    // MARK: - Quality Gate (Evidence, PIZ, SfM)

    /// SFM registration minimum ratio — fraction of frames that must successfully register.
    /// Ref: Photogrammetry best practice; 0.75 = stricter than typical 0.60.
    public static var sfmRegistrationMinRatio: Double { QualityThresholds.sfmRegistrationMinRatio }

    /// PSNR minimum for 8-bit (dB). Ref: 3DGS papers report ~21–32 dB, avg ~27; 28 = conservative.
    public static var psnrMin8BitDb: Double { QualityThresholds.psnrMin8BitDb }

    /// PSNR minimum for 12-bit (dB). Ref: Visionular/VVC research.
    public static var psnrMin12BitDb: Double { QualityThresholds.psnrMin12BitDb }

    /// Laplacian blur threshold for frame rejection (strict). Below = discard frame.
    /// Ref: PyImageSearch 100, we use 200 for 3D reconstruction (conservative).
    public static var blurThresholdFrameRejection: Double { CoreBlurThresholds.frameRejection }

    /// Laplacian blur threshold for guidance/haptic (softer). Below = warn user.
    /// Ref: 120 = earlier feedback, allows user to correct before frame rejection.
    public static var blurThresholdGuidance: Double { CoreBlurThresholds.guidanceHaptic }

    /// Minimum feature density per frame. Ref: Apple Object Capture 300.
    public static var minFeatureDensity: Int { QualityThresholds.minFeatureDensity }

    // MARK: - Capacity (Evidence Admission)

    public static var softLimitPatchCount: Int { CapacityLimitConstants.SOFT_LIMIT_PATCH_COUNT }
    public static var hardLimitPatchCount: Int { CapacityLimitConstants.HARD_LIMIT_PATCH_COUNT }
    public static var eebBaseBudget: Double { CapacityLimitConstants.EEB_BASE_BUDGET }
    public static var softBudgetThreshold: Double { CapacityLimitConstants.SOFT_BUDGET_THRESHOLD }
    public static var hardBudgetThreshold: Double { CapacityLimitConstants.HARD_BUDGET_THRESHOLD }

    // MARK: - PIZ Detection

    public static var globalCoverageMin: Double { PIZThresholds.GLOBAL_COVERAGE_MIN }
    public static var coveredCellMin: Double { PIZThresholds.COVERED_CELL_MIN }
    public static var localCoverageMin: Double { PIZThresholds.LOCAL_COVERAGE_MIN }
    public static var severityHighThreshold: Double { PIZThresholds.SEVERITY_HIGH_THRESHOLD }
    public static var severityMediumThreshold: Double { PIZThresholds.SEVERITY_MEDIUM_THRESHOLD }
    public static var hysteresisBand: Double { PIZThresholds.HYSTERESIS_BAND }
    public static var coverageRelativeTolerance: Double { PIZThresholds.COVERAGE_RELATIVE_TOLERANCE }
    public static var jsonCanonQuantizationPrecision: Double { PIZThresholds.JSON_CANON_QUANTIZATION_PRECISION }

    // MARK: - Hard Gates (Evidence Geometry)

    public static var reprojThreshold: Double { HardGatesV13.reprojThreshold }
    public static var reprojTransitionWidth: Double { HardGatesV13.reprojTransitionWidth }
    public static var edgeThreshold: Double { HardGatesV13.edgeThreshold }
    public static var thetaThreshold: Double { HardGatesV13.thetaThreshold }
    public static var phiThreshold: Double { HardGatesV13.phiThreshold }
    public static var quantizationScale: Double { HardGatesV13.quantizationScale }

    // MARK: - System Limits

    public static var maxFrames: Int { SystemConstants.maxFrames }
    public static var minFrames: Int { SystemConstants.minFrames }
    public static var maxGaussians: Int { SystemConstants.maxGaussians }

    // MARK: - Math Safety

    public static var ratioMin: Double { MathSafetyConstants.RATIO_MIN }
    public static var ratioMax: Double { MathSafetyConstants.RATIO_MAX }
}
