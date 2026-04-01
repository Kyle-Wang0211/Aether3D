// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Thermal thresholds kept by the shipping whitebox capture loop.
public enum ThermalConstants {
    public static let thermalSafeAmbientMaxC: Double = 35.0
    public static let thermalWarningC: Double = 40.0
    public static let thermalCriticalC: Double = 45.0
    public static let thermalShutdownC: Double = 50.0

    public static let max4K60ContinuousSeconds: Int = 1800
    public static let maxProResContinuousSeconds: Int = 900
    public static let thermalCooldownSeconds: Int = 120

    public static func validateRelationships() -> [String] {
        var errors: [String] = []

        if thermalSafeAmbientMaxC >= thermalWarningC {
            errors.append("thermalSafeAmbientMaxC (\(thermalSafeAmbientMaxC)) >= thermalWarningC (\(thermalWarningC))")
        }
        if thermalWarningC >= thermalCriticalC {
            errors.append("thermalWarningC (\(thermalWarningC)) >= thermalCriticalC (\(thermalCriticalC))")
        }
        if thermalCriticalC >= thermalShutdownC {
            errors.append("thermalCriticalC (\(thermalCriticalC)) >= thermalShutdownC (\(thermalShutdownC))")
        }

        return errors
    }
}
