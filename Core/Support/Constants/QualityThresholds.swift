// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Research-backed thresholds still consumed by the minimal whitebox loop.
public enum QualityThresholds {
    /// Strict frame rejection threshold for Laplacian variance blur checks.
    public static let sfmRegistrationMinRatio = 0.75
    public static let psnrMin8BitDb: Double = 28.0
    public static let psnrMin12BitDb: Double = 55.0

    @available(*, deprecated, message: "Use psnrMin8BitDb or psnrMin12BitDb instead")
    public static let psnrMinDb = 30.0

    public static let psnrWarnDb = 32.0
    public static let ssimMin: Double = 0.85
    public static let lpipsMax: Double = 0.15
    public static let frameOverlapForward: Double = 0.80
    public static let frameOverlapSide: Double = 0.65
    public static let minFeatureDensity: Int = 300
    public static let laplacianBlurThreshold: Double = 200.0
    public static let guidanceHapticBlurThreshold: Double = 100.0
    public static let dynamicRangeStops: Int = 14

    public static func validateRelationships() -> [String] {
        []
    }
}
