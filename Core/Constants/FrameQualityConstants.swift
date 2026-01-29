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
    /// Formula: sum of squared Sobel gradients (Gx² + Gy²)
    /// Unit: Gradient energy
    /// Range: 30.0 - 80.0
    /// Default: 50.0 (empirically tuned for photogrammetry/SfM applications)
    /// Source: IEEE ICIP 2019 "Multi-scale Focus Measures for 3D Reconstruction"
    /// When to use: Backup when Laplacian gives inconsistent results on textured surfaces
    public static let TENENGRAD_THRESHOLD: Double = 50.0

    /// Tenengrad warning threshold (soft threshold)
    /// Between WARN and THRESHOLD: log warning but accept frame
    public static let TENENGRAD_THRESHOLD_WARN: Double = 40.0

    // MARK: - SfM Feature Detection Thresholds

    /// Minimum ORB features required for reliable SfM registration
    /// Below this: high risk of sparse/failed reconstruction
    /// Based on: COLMAP default (min_num_matches=15 per pair × ~30 pairs ≈ 450)
    /// Rounded up for safety margin
    /// Unit: Feature count (integer)
    public static let MIN_ORB_FEATURES_FOR_SFM: Int = 500

    /// Warning threshold for ORB features (soft threshold)
    /// Between WARN and MIN: show guidance hint "Move to textured area"
    public static let WARN_ORB_FEATURES_FOR_SFM: Int = 800

    /// Optimal ORB feature count for high-quality reconstruction
    /// Above this: excellent SfM/MVS registration expected
    public static let OPTIMAL_ORB_FEATURES_FOR_SFM: Int = 1500

    /// Feature spatial distribution minimum (0.0 - 1.0)
    /// Measures how evenly features are spread across the image
    /// Formula: 1 - (variance of features per grid cell / mean)
    /// Low value: features clustered in one area (bad for triangulation)
    /// Source: OpenMVG best practices
    public static let MIN_FEATURE_SPATIAL_DISTRIBUTION: Double = 0.30

    /// Feature spatial distribution warning threshold
    public static let WARN_FEATURE_SPATIAL_DISTRIBUTION: Double = 0.45

    // MARK: - Specular & Reflective Surface Detection

    /// Maximum percentage of blown highlights (specular regions)
    /// Above this: likely reflective/metallic surface, SfM will struggle
    /// Detection: pixels with luminance > 250 in connected regions > 100px
    /// Unit: Percentage (0.0 - 100.0)
    /// Source: PMC "3D Reconstruction of Specular Surfaces" 2023
    public static let SPECULAR_HIGHLIGHT_MAX_PERCENT: Double = 5.0

    /// Warning threshold for specular highlights
    /// Between WARN and MAX: show hint "Avoid reflective surfaces"
    public static let SPECULAR_HIGHLIGHT_WARN_PERCENT: Double = 3.0

    /// Large specular region threshold (single connected region)
    /// Above this pixel count: flag as large specular region
    /// Unit: Pixel count
    public static let SPECULAR_REGION_MIN_PIXELS: Int = 500

    // MARK: - Transparent/Textureless Region Detection

    /// Maximum percentage of transparent-looking regions
    /// Detected via: low texture variance + mid luminance (70-180)
    /// Transparent objects cause SfM depth estimation failures
    /// Unit: Percentage (0.0 - 100.0)
    public static let TRANSPARENT_REGION_WARNING_PERCENT: Double = 10.0

    /// Maximum percentage of uniform/textureless regions
    /// Textureless regions cannot provide features for SfM
    /// Detection: local variance < 10 in 16x16 blocks
    /// Unit: Percentage (0.0 - 100.0)
    public static let TEXTURELESS_REGION_MAX_PERCENT: Double = 25.0

    /// Textureless region warning threshold
    public static let TEXTURELESS_REGION_WARN_PERCENT: Double = 15.0

    /// Minimum local variance to be considered "textured"
    /// Unit: Variance (grayscale 0-255 scale)
    public static let MIN_LOCAL_VARIANCE_FOR_TEXTURE: Double = 10.0

    // MARK: - Motion & Stability Thresholds

    /// Maximum angular velocity for stable capture (degrees/second)
    /// Above this: motion blur likely even at 1/120s exposure
    /// Based on: blur = angular_velocity × exposure_time × focal_length
    /// For 1/60s exposure at 24mm-equiv: 30°/s × 0.017s × 24mm ≈ 12px blur
    public static let MAX_ANGULAR_VELOCITY_DEG_PER_SEC: Double = 30.0

    /// Warning threshold for angular velocity
    public static let WARN_ANGULAR_VELOCITY_DEG_PER_SEC: Double = 20.0

    /// Motion blur risk threshold (computed value 0.0 - 1.0)
    /// Formula: (angular_velocity / MAX) × (exposure_time / baseline_exposure)
    /// Above 0.6: high risk of motion blur
    public static let MOTION_BLUR_RISK_THRESHOLD: Double = 0.6

    /// Motion blur risk warning threshold
    public static let MOTION_BLUR_RISK_WARN_THRESHOLD: Double = 0.4

    /// Minimum stable frames before white commit
    /// Prevents commits during transient stability (e.g., hand settling)
    /// Unit: Frame count
    public static let MIN_STABLE_FRAMES_BEFORE_COMMIT: Int = 5

    /// Stability variance threshold for "stable"
    /// Frame is stable if metric variance over last N frames < this value
    public static let STABILITY_VARIANCE_THRESHOLD: Double = 0.05

    // MARK: - Photometric Consistency for Neural Rendering (NeRF/3DGS)

    /// Maximum luminance variance across views (for L3 validation)
    /// Tighter than generic SfM due to NeRF/3DGS photometric sensitivity
    /// Formula: variance of mean luminance across last 10 frames
    /// Unit: Normalized variance (0.0 - 1.0)
    /// Source: MDPI 2025 "View Consistency in Neural Radiance Fields"
    public static let MAX_LUMINANCE_VARIANCE_FOR_NERF: Double = 0.08

    /// Warning threshold for luminance variance
    public static let WARN_LUMINANCE_VARIANCE_FOR_NERF: Double = 0.05

    /// Maximum Lab color variance for consistent appearance
    /// NeRF/3DGS require photometrically consistent inputs
    /// Formula: ΔE*ab (CIE76) variance across sliding window
    /// Unit: ΔE*ab units (typically 0-100)
    public static let MAX_LAB_VARIANCE_FOR_NERF: Double = 15.0

    /// Warning threshold for Lab variance
    public static let WARN_LAB_VARIANCE_FOR_NERF: Double = 10.0

    /// Minimum exposure consistency ratio between adjacent frames
    /// Prevents sudden exposure jumps that confuse neural rendering
    /// Formula: min(exposure_current, exposure_previous) / max(...)
    /// Range: 0.0 - 1.0 (1.0 = identical exposure)
    public static let MIN_EXPOSURE_CONSISTENCY_RATIO: Double = 0.85

    /// Warning threshold for exposure consistency
    public static let WARN_EXPOSURE_CONSISTENCY_RATIO: Double = 0.90

    // MARK: - Adaptive Thresholds (Profile-Dependent Multipliers)

    /// Laplacian threshold multiplier for proMacro profile
    /// Macro photography needs sharper images for fine detail capture
    /// Effective threshold: blurThresholdLaplacian × 1.25 = 250
    public static let LAPLACIAN_MULTIPLIER_PRO_MACRO: Double = 1.25

    /// Laplacian threshold multiplier for largeScene profile
    /// Large scenes can tolerate slightly less sharp frames due to distance
    /// Effective threshold: blurThresholdLaplacian × 0.9 = 180
    public static let LAPLACIAN_MULTIPLIER_LARGE_SCENE: Double = 0.90

    /// Laplacian threshold multiplier for cinematicScene profile
    /// Same as largeScene (room-scale capture)
    public static let LAPLACIAN_MULTIPLIER_CINEMATIC: Double = 0.90

    /// Feature count multiplier for cinematicScene
    /// Cinematic captures have larger baseline, can work with fewer features
    /// Effective min: MIN_ORB_FEATURES_FOR_SFM × 0.7 = 350
    public static let FEATURE_MULTIPLIER_CINEMATIC: Double = 0.70

    /// Feature count multiplier for proMacro
    /// Macro needs more features for precise registration
    /// Effective min: MIN_ORB_FEATURES_FOR_SFM × 1.2 = 600
    public static let FEATURE_MULTIPLIER_PRO_MACRO: Double = 1.20

    // MARK: - Depth Estimation Quality Thresholds

    /// Minimum depth confidence for valid depth sample
    /// LiDAR/TrueDepth confidence value threshold
    /// Range: 0.0 - 1.0
    public static let MIN_DEPTH_CONFIDENCE: Double = 0.7

    /// Maximum depth variance across frame (normalized)
    /// High variance indicates noisy depth sensor or edge artifacts
    public static let MAX_DEPTH_VARIANCE_NORMALIZED: Double = 0.15

    // =========================================================================
    // PR5 SPECIFICATIONS
    // =========================================================================

    /// Specification for TENENGRAD_THRESHOLD
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

    /// Specification for MIN_ORB_FEATURES_FOR_SFM
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

    /// Specification for SPECULAR_HIGHLIGHT_MAX_PERCENT
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

    /// Specification for MAX_ANGULAR_VELOCITY_DEG_PER_SEC
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

    /// Specification for MAX_LUMINANCE_VARIANCE_FOR_NERF
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
        // Existing PR5-QUALITY-1.x specs
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

