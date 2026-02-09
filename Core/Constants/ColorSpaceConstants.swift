// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ColorSpaceConstants.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Color Space Conversion Constants (CE)
//
// This file defines color space conversion matrices and constants.
// System/OS color APIs are strictly forbidden.
//

import Foundation

/// Color space conversion constants (CE - IMMUTABLE).
///
/// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
/// **Status:** IMMUTABLE
///
/// **Lab 颜色空间参考系统永久固定:**
/// - Illuminant / White Point: D65（永久固定，无运行时切换）
/// - 转换路径：sRGB → XYZ (D65) → Lab
/// - 转换矩阵和常量：明确硬编码的 SSOT 常量
/// - 系统/OS 颜色 API：严格禁止
public enum ColorSpaceConstants {
    
    // MARK: - White Point (D65)
    
    /// D65 white point (permanently fixed).
    /// **Rule ID:** CE
    /// **Status:** IMMUTABLE
    public static let WHITE_POINT = "D65"
    
    // MARK: - sRGB → XYZ Conversion Matrix (D65)
    
    /// sRGB to XYZ conversion matrix (D65 white point).
    /// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
    /// **Status:** IMMUTABLE
    ///
    /// Matrix:
    /// | | X | Y | Z |
    /// |---|-------|-------|-------|
    /// | R | 0.4124564 | 0.3575761 | 0.1804375 |
    /// | G | 0.2126729 | 0.7151522 | 0.0721750 |
    /// | B | 0.0193339 | 0.1191920 | 0.9503041 |
    public static let SRGB_TO_XYZ_MATRIX: [[Double]] = [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041]
    ]
    
    // MARK: - XYZ → Lab Conversion Parameters (D65)
    
    /// D65 reference white point Xn.
    /// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
    /// **Status:** IMMUTABLE
    public static let XYZ_REFERENCE_WHITE_XN: Double = 0.95047
    
    /// D65 reference white point Yn.
    /// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
    /// **Status:** IMMUTABLE
    public static let XYZ_REFERENCE_WHITE_YN: Double = 1.00000
    
    /// D65 reference white point Zn.
    /// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
    /// **Status:** IMMUTABLE
    public static let XYZ_REFERENCE_WHITE_ZN: Double = 1.08883
    
    /// Delta constant for Lab conversion.
    /// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
    /// **Status:** IMMUTABLE
    public static let LAB_DELTA: Double = 6.0 / 29.0
    
    /// Delta cubed threshold for Lab conversion.
    /// **Rule ID:** CE, CROSS_PLATFORM_COLOR_001
    /// **Status:** IMMUTABLE
    public static let LAB_DELTA_CUBED: Double = {
        let delta = 6.0 / 29.0
        return delta * delta * delta
    }()
    
    // MARK: - CE Constraints
    
    /// **CE 约束:**
    /// - D65 永久固定
    /// - 转换矩阵是 SSOT 常量
    /// - 无运行时切换
    /// - 任何未来偏差需要：新 schemaVersion、新资产类别、不继承旧 L3 证据
    
    // MARK: - Forbidden APIs
    
    /// **Rule ID:** CE
    /// **Status:** IMMUTABLE
    ///
    /// **禁止使用系统默认颜色转换 API:**
    /// - iOS: UIColor, CGColorSpace, ColorSync
    /// - Android: ColorSpace, Color
    /// - 必须使用上述常量自行实现转换
}
