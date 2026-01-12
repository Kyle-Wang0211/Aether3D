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
    
    /// Minimum PSNR value (db)
    /// 本色区域最低要求
    public static let psnrMinDb = 30.0
    
    /// PSNR warning threshold (db)
    /// 低于这个提醒用户
    public static let psnrWarnDb = 32.0
    
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
        defaultValue: psnrMinDb,
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
    
    /// All quality threshold specs
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(sfmRegistrationMinRatioSpec),
        .threshold(psnrMinDbSpec),
        .threshold(psnrWarnDbSpec)
    ]
    
    /// Validate relationships between thresholds
    public static func validateRelationships() -> [String] {
        let errors: [String] = []
        // No cross-threshold relationships to validate yet
        return errors
    }
}

