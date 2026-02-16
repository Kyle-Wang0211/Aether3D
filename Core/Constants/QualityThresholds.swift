// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityThresholds.swift
// Aether3D
//
// Quality-related thresholds and limits.
//

import Foundation

/// Quality thresholds for processing and validation.
public enum QualityThresholds {
    /// Minimum SFM registration ratio (ratio)
    /// 配准率保底
    public static let sfmRegistrationMinRatio = 0.75
    
    /// Minimum PSNR value for 8-bit images (dB)
    /// Unit: decibels (dB)
    /// Industry standard: 28.0 dB
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let psnrMin8BitDb: Double = 28.0
    
    /// Minimum PSNR value for 12-bit images (dB)
    /// Unit: decibels (dB)
    /// Visionular research: 55.0 dB
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let psnrMin12BitDb: Double = 55.0
    
    /// Minimum PSNR value (db) - Legacy, use psnrMin8BitDb or psnrMin12BitDb
    /// 本色区域最低要求
    @available(*, deprecated, message: "Use psnrMin8BitDb or psnrMin12BitDb instead")
    public static let psnrMinDb = 30.0
    
    /// PSNR warning threshold (db)
    /// 低于这个提醒用户
    public static let psnrWarnDb = 32.0
    
    /// Minimum SSIM value
    /// Unit: ratio (0.0 to 1.0)
    /// MipNeRF-360 benchmark: 0.85
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let ssimMin: Double = 0.85
    
    /// Maximum LPIPS value
    /// Unit: perceptual distance (0.0 to 1.0)
    /// Tanks & Temples benchmark: 0.15
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let lpipsMax: Double = 0.15
    
    /// Frame overlap for forward motion (ratio)
    /// Unit: ratio (0.0 to 1.0)
    /// Photogrammetry standard: 0.80
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let frameOverlapForward: Double = 0.80
    
    /// Frame overlap for side motion (ratio)
    /// Unit: ratio (0.0 to 1.0)
    /// Photogrammetry standard: 0.65
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let frameOverlapSide: Double = 0.65
    
    /// Minimum feature density (features per frame)
    /// Unit: features per frame
    /// Apple Object Capture standard: 300 (raised from 200)
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let minFeatureDensity: Int = 300
    
    /// Laplacian blur threshold
    /// Unit: variance
    /// Guidance SSOT: 100.0
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let laplacianBlurThreshold: Double = 100.0
    
    /// Dynamic range stops
    /// Unit: stops
    /// Latest mobile sensors: 14 stops
    /// 符合 PR1-01: Quality Thresholds Based on Industry Research
    public static let dynamicRangeStops: Int = 14
    
    // MARK: - Deprecated
    // qualityRejectScore 已废弃，不再使用综合分
    // 只用 psnrMinDb 和 sfmRegistrationMinRatio 两个检查
    // public static let qualityRejectScore = 40
    
    // MARK: - Specifications
    
    /// Specification for sfmRegistrationMinRatio
    public static let sfmRegistrationMinRatioSpec = ThresholdSpec(
        ssotId: "QualityThresholds.sfmRegistrationMinRatio",
        name: "SFM Registration Minimum Ratio",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: sfmRegistrationMinRatio,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Minimum ratio of successfully registered frames in SFM pipeline (配准率保底)"
    )
    
    /// Specification for psnrMinDb
    public static let psnrMinDbSpec = ThresholdSpec(
        ssotId: "QualityThresholds.psnrMinDb",
        name: "PSNR Minimum (dB)",
        unit: .db,
        category: .quality,
        min: 0.0,
        max: 100.0,
        defaultValue: psnrMin8BitDb,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Minimum Peak Signal-to-Noise Ratio in decibels for acceptable quality (本色区域最低要求)"
    )
    
    /// Specification for psnrWarnDb
    public static let psnrWarnDbSpec = ThresholdSpec(
        ssotId: "QualityThresholds.psnrWarnDb",
        name: "PSNR Warning (dB)",
        unit: .db,
        category: .quality,
        min: 0.0,
        max: 100.0,
        defaultValue: psnrWarnDb,
        onExceed: .warn,
        onUnderflow: .warn,
        documentation: "PSNR threshold below which user should be warned (低于这个提醒用户)"
    )
    
    /// Specification for psnrMin8BitDb
    public static let psnrMin8BitDbSpec = ThresholdSpec(
        ssotId: "QualityThresholds.psnrMin8BitDb",
        name: "PSNR Minimum 8-bit (dB)",
        unit: .db,
        category: .quality,
        min: 0.0,
        max: 100.0,
        defaultValue: psnrMin8BitDb,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Minimum PSNR for 8-bit images - Industry standard: 28.0 dB"
    )
    
    /// Specification for psnrMin12BitDb
    public static let psnrMin12BitDbSpec = ThresholdSpec(
        ssotId: "QualityThresholds.psnrMin12BitDb",
        name: "PSNR Minimum 12-bit (dB)",
        unit: .db,
        category: .quality,
        min: 0.0,
        max: 100.0,
        defaultValue: psnrMin12BitDb,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Minimum PSNR for 12-bit images - Visionular research: 55.0 dB"
    )
    
    /// Specification for ssimMin
    public static let ssimMinSpec = ThresholdSpec(
        ssotId: "QualityThresholds.ssimMin",
        name: "SSIM Minimum",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: ssimMin,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Minimum SSIM - MipNeRF-360 benchmark: 0.85"
    )
    
    /// Specification for lpipsMax
    public static let lpipsMaxSpec = ThresholdSpec(
        ssotId: "QualityThresholds.lpipsMax",
        name: "LPIPS Maximum",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: lpipsMax,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "Maximum LPIPS - Tanks & Temples benchmark: 0.15"
    )
    
    /// Specification for frameOverlapForward
    public static let frameOverlapForwardSpec = ThresholdSpec(
        ssotId: "QualityThresholds.frameOverlapForward",
        name: "Frame Overlap Forward",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: frameOverlapForward,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Frame overlap for forward motion - Photogrammetry standard: 0.80"
    )
    
    /// Specification for frameOverlapSide
    public static let frameOverlapSideSpec = ThresholdSpec(
        ssotId: "QualityThresholds.frameOverlapSide",
        name: "Frame Overlap Side",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: frameOverlapSide,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Frame overlap for side motion - Photogrammetry standard: 0.65"
    )
    
    /// Specification for minFeatureDensity
    public static let minFeatureDensitySpec = ThresholdSpec(
        ssotId: "QualityThresholds.minFeatureDensity",
        name: "Minimum Feature Density",
        unit: .count,
        category: .quality,
        min: 0.0,
        max: 10000.0,
        defaultValue: Double(minFeatureDensity),
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Minimum feature density - Apple Object Capture: 300 features per frame"
    )
    
    /// Specification for laplacianBlurThreshold
    public static let laplacianBlurThresholdSpec = ThresholdSpec(
        ssotId: "QualityThresholds.laplacianBlurThreshold",
        name: "Laplacian Blur Threshold",
        unit: .variance,
        category: .quality,
        min: 0.0,
        max: 1000.0,
        defaultValue: laplacianBlurThreshold,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Laplacian blur threshold - PyImageSearch + empirical: 120.0"
    )
    
    /// Specification for dynamicRangeStops
    public static let dynamicRangeStopsSpec = ThresholdSpec(
        ssotId: "QualityThresholds.dynamicRangeStops",
        name: "Dynamic Range Stops",
        unit: .stops,
        category: .quality,
        min: 0.0,
        max: 20.0,
        defaultValue: Double(dynamicRangeStops),
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Dynamic range stops - Latest mobile sensors: 14 stops"
    )
    
    /// All quality threshold specs
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(sfmRegistrationMinRatioSpec),
        .threshold(psnrMinDbSpec),
        .threshold(psnrWarnDbSpec),
        .threshold(psnrMin8BitDbSpec),
        .threshold(psnrMin12BitDbSpec),
        .threshold(ssimMinSpec),
        .threshold(lpipsMaxSpec),
        .threshold(frameOverlapForwardSpec),
        .threshold(frameOverlapSideSpec),
        .threshold(minFeatureDensitySpec),
        .threshold(laplacianBlurThresholdSpec),
        .threshold(dynamicRangeStopsSpec)
    ]
    
    /// Validate relationships between thresholds
    public static func validateRelationships() -> [String] {
        let errors: [String] = []
        // No cross-threshold relationships to validate yet
        return errors
    }
}
