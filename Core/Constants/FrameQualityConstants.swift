// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FrameQualityConstants.swift
// Aether3D
//
// Frame quality assessment and rejection thresholds.
//

import Foundation

/// Frame quality assessment and rejection thresholds.
public enum FrameQualityConstants {
    
    /// 模糊阈值（Laplacian 方差）
    /// - 低于此值判定为模糊，丢弃
    public static let blurThresholdLaplacian: Double = 200.0
    
    /// 暗部阈值（平均亮度 0-255）
    /// - 低于此值判定为太暗，丢弃
    public static let darkThresholdBrightness: Double = 60.0
    
    /// 亮部阈值（平均亮度 0-255）
    /// - 高于此值判定为太亮/过曝，丢弃
    public static let brightThresholdBrightness: Double = 200.0
    
    /// 帧间相似度上限
    /// - 高于此值判定为冗余帧，丢弃
    public static let maxFrameSimilarity: Double = 0.92
    
    /// 帧间相似度下限
    /// - 低于此值判定为跳帧，丢弃
    public static let minFrameSimilarity: Double = 0.50
    
    // MARK: - Specifications
    
    /// Specification for blurThresholdLaplacian
    public static let blurThresholdLaplacianSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.blurThresholdLaplacian",
        name: "Blur Threshold (Laplacian)",
        unit: .variance,
        category: .quality,
        min: 50.0,
        max: 500.0,
        defaultValue: blurThresholdLaplacian,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "比行业标准(100)严格2倍，宁可丢帧也要清晰"
    )
    
    /// Specification for darkThresholdBrightness
    public static let darkThresholdBrightnessSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.darkThresholdBrightness",
        name: "Dark Threshold (Brightness)",
        unit: .brightness,
        category: .quality,
        min: 0.0,
        max: 255.0,
        defaultValue: darkThresholdBrightness,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "暗部细节和深度估计都会失效"
    )
    
    /// Specification for brightThresholdBrightness
    public static let brightThresholdBrightnessSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.brightThresholdBrightness",
        name: "Bright Threshold (Brightness)",
        unit: .brightness,
        category: .quality,
        min: 0.0,
        max: 255.0,
        defaultValue: brightThresholdBrightness,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "过曝区域完全没有纹理信息"
    )
    
    /// Specification for maxFrameSimilarity
    public static let maxFrameSimilaritySpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.maxFrameSimilarity",
        name: "Maximum Frame Similarity",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: maxFrameSimilarity,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "高于92%为冗余帧，减少无效数据"
    )
    
    /// Specification for minFrameSimilarity
    public static let minFrameSimilaritySpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.minFrameSimilarity",
        name: "Minimum Frame Similarity",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: minFrameSimilarity,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "低于50%为跳帧，连续性断裂"
    )
    
    // =========================================================================
    // PR5-QUALITY-2.0 ENHANCEMENTS
    // =========================================================================

    // MARK: - Tenengrad (Sobel-based) Backup Sharpness Detection

    /// Tenengrad threshold for backup blur detection (Sobel gradient magnitude)
    public static let TENENGRAD_THRESHOLD: Double = 50.0
    public static let TENENGRAD_THRESHOLD_WARN: Double = 40.0

    // MARK: - SfM Feature Detection Thresholds

    public static let MIN_ORB_FEATURES_FOR_SFM: Int = 500
    public static let WARN_ORB_FEATURES_FOR_SFM: Int = 800
    public static let OPTIMAL_ORB_FEATURES_FOR_SFM: Int = 1500
    public static let MIN_FEATURE_SPATIAL_DISTRIBUTION: Double = 0.30
    public static let WARN_FEATURE_SPATIAL_DISTRIBUTION: Double = 0.45

    // MARK: - Specular & Reflective Surface Detection

    public static let SPECULAR_HIGHLIGHT_MAX_PERCENT: Double = 5.0
    public static let SPECULAR_HIGHLIGHT_WARN_PERCENT: Double = 3.0
    public static let SPECULAR_REGION_MIN_PIXELS: Int = 500

    // MARK: - Transparent/Textureless Region Detection

    public static let TRANSPARENT_REGION_WARNING_PERCENT: Double = 10.0
    public static let TEXTURELESS_REGION_MAX_PERCENT: Double = 25.0
    public static let TEXTURELESS_REGION_WARN_PERCENT: Double = 15.0
    public static let MIN_LOCAL_VARIANCE_FOR_TEXTURE: Double = 10.0

    // MARK: - Motion & Stability Thresholds

    public static let MAX_ANGULAR_VELOCITY_DEG_PER_SEC: Double = 30.0
    public static let WARN_ANGULAR_VELOCITY_DEG_PER_SEC: Double = 20.0
    public static let MOTION_BLUR_RISK_THRESHOLD: Double = 0.6
    public static let MOTION_BLUR_RISK_WARN_THRESHOLD: Double = 0.4
    public static let MIN_STABLE_FRAMES_BEFORE_COMMIT: Int = 5
    public static let STABILITY_VARIANCE_THRESHOLD: Double = 0.05

    // MARK: - Photometric Consistency for Neural Rendering (NeRF/3DGS)

    public static let MAX_LUMINANCE_VARIANCE_FOR_NERF: Double = 0.08
    public static let WARN_LUMINANCE_VARIANCE_FOR_NERF: Double = 0.05
    public static let MAX_LAB_VARIANCE_FOR_NERF: Double = 15.0
    public static let WARN_LAB_VARIANCE_FOR_NERF: Double = 10.0
    public static let MIN_EXPOSURE_CONSISTENCY_RATIO: Double = 0.85
    public static let WARN_EXPOSURE_CONSISTENCY_RATIO: Double = 0.90

    // MARK: - Adaptive Thresholds (Profile-Dependent Multipliers)

    public static let LAPLACIAN_MULTIPLIER_PRO_MACRO: Double = 1.25
    public static let LAPLACIAN_MULTIPLIER_LARGE_SCENE: Double = 0.90
    public static let LAPLACIAN_MULTIPLIER_CINEMATIC: Double = 0.90
    public static let FEATURE_MULTIPLIER_CINEMATIC: Double = 0.70
    public static let FEATURE_MULTIPLIER_PRO_MACRO: Double = 1.20

    // MARK: - Depth Estimation Quality Thresholds

    public static let MIN_DEPTH_CONFIDENCE: Double = 0.7
    public static let MAX_DEPTH_VARIANCE_NORMALIZED: Double = 0.15

    // MARK: - PR5 Specifications

    public static let tenengradThresholdSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.TENENGRAD_THRESHOLD",
        name: "Tenengrad Threshold (Sobel)",
        unit: .variance,
        category: .quality,
        min: 30.0,
        max: 80.0,
        defaultValue: TENENGRAD_THRESHOLD,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Sobel-based backup sharpness metric for edge cases"
    )

    public static let minOrbFeaturesSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM",
        name: "Minimum ORB Features for SfM",
        unit: .count,
        category: .quality,
        min: 100.0,
        max: 2000.0,
        defaultValue: Double(MIN_ORB_FEATURES_FOR_SFM),
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "Below this: sparse/failed SfM registration"
    )

    public static let specularHighlightMaxSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.SPECULAR_HIGHLIGHT_MAX_PERCENT",
        name: "Specular Highlight Maximum",
        unit: .percent,
        category: .quality,
        min: 1.0,
        max: 20.0,
        defaultValue: SPECULAR_HIGHLIGHT_MAX_PERCENT,
        onExceed: .warn,
        onUnderflow: .warn,
        documentation: "Reflective surfaces cause SfM failures"
    )

    public static let maxAngularVelocitySpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.MAX_ANGULAR_VELOCITY_DEG_PER_SEC",
        name: "Maximum Angular Velocity",
        unit: .degreesPerSecond,
        category: .motion,
        min: 10.0,
        max: 60.0,
        defaultValue: MAX_ANGULAR_VELOCITY_DEG_PER_SEC,
        onExceed: .warn,
        onUnderflow: .warn,
        documentation: "Above this: motion blur likely"
    )

    public static let maxLuminanceVarianceSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.MAX_LUMINANCE_VARIANCE_FOR_NERF",
        name: "Max Luminance Variance (NeRF)",
        unit: .variance,
        category: .photometric,
        min: 0.01,
        max: 0.20,
        defaultValue: MAX_LUMINANCE_VARIANCE_FOR_NERF,
        onExceed: .warn,
        onUnderflow: .warn,
        documentation: "NeRF/3DGS require consistent lighting"
    )

    /// All frame quality constant specs (UPDATED for PR5)
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(blurThresholdLaplacianSpec),
        .threshold(darkThresholdBrightnessSpec),
        .threshold(brightThresholdBrightnessSpec),
        .threshold(maxFrameSimilaritySpec),
        .threshold(minFrameSimilaritySpec),
        // NEW PR5-QUALITY-2.0 specs
        .threshold(tenengradThresholdSpec),
        .threshold(minOrbFeaturesSpec),
        .threshold(specularHighlightMaxSpec),
        .threshold(maxAngularVelocitySpec),
        .threshold(maxLuminanceVarianceSpec)
    ]
}

