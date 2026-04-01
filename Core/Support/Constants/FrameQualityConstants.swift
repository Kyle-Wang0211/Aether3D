// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Frame-level thresholds still needed by runtime gate evaluation.
public enum FrameQualityConstants {
    public static let blurThresholdLaplacian: Double = 200.0
    public static let darkThresholdBrightness: Double = 60.0
    public static let brightThresholdBrightness: Double = 200.0
    public static let maxFrameSimilarity: Double = 0.92
    public static let minFrameSimilarity: Double = 0.50

    public static let TENENGRAD_THRESHOLD: Double = 50.0
    public static let TENENGRAD_THRESHOLD_WARN: Double = 40.0

    public static let MIN_ORB_FEATURES_FOR_SFM: Int = 500
    public static let WARN_ORB_FEATURES_FOR_SFM: Int = 800
    public static let OPTIMAL_ORB_FEATURES_FOR_SFM: Int = 1500
    public static let MIN_FEATURE_SPATIAL_DISTRIBUTION: Double = 0.30
    public static let WARN_FEATURE_SPATIAL_DISTRIBUTION: Double = 0.45

    public static let SPECULAR_HIGHLIGHT_MAX_PERCENT: Double = 5.0
    public static let SPECULAR_HIGHLIGHT_WARN_PERCENT: Double = 3.0
    public static let SPECULAR_REGION_MIN_PIXELS: Int = 500

    public static let TRANSPARENT_REGION_WARNING_PERCENT: Double = 10.0
    public static let TEXTURELESS_REGION_MAX_PERCENT: Double = 25.0
    public static let TEXTURELESS_REGION_WARN_PERCENT: Double = 15.0
    public static let MIN_LOCAL_VARIANCE_FOR_TEXTURE: Double = 10.0

    public static let MAX_ANGULAR_VELOCITY_DEG_PER_SEC: Double = 30.0
    public static let WARN_ANGULAR_VELOCITY_DEG_PER_SEC: Double = 20.0
    public static let MOTION_BLUR_RISK_THRESHOLD: Double = 0.6
    public static let MOTION_BLUR_RISK_WARN_THRESHOLD: Double = 0.4
    public static let MIN_STABLE_FRAMES_BEFORE_COMMIT: Int = 5
    public static let STABILITY_VARIANCE_THRESHOLD: Double = 0.05

    public static let MAX_LUMINANCE_VARIANCE_FOR_NERF: Double = 0.08
    public static let WARN_LUMINANCE_VARIANCE_FOR_NERF: Double = 0.05
    public static let MAX_LAB_VARIANCE_FOR_NERF: Double = 15.0
    public static let WARN_LAB_VARIANCE_FOR_NERF: Double = 10.0
    public static let MIN_EXPOSURE_CONSISTENCY_RATIO: Double = 0.85
    public static let WARN_EXPOSURE_CONSISTENCY_RATIO: Double = 0.90

    public static let LAPLACIAN_MULTIPLIER_PRO_MACRO: Double = 1.25
    public static let LAPLACIAN_MULTIPLIER_LARGE_SCENE: Double = 0.90
    public static let LAPLACIAN_MULTIPLIER_CINEMATIC: Double = 0.90
    public static let FEATURE_MULTIPLIER_CINEMATIC: Double = 0.70
    public static let FEATURE_MULTIPLIER_PRO_MACRO: Double = 1.20

    public static let MIN_DEPTH_CONFIDENCE: Double = 0.7
    public static let MAX_DEPTH_VARIANCE_NORMALIZED: Double = 0.15
}
