// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GridResolutionPolicy.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Grid Resolution Policy (Closed Set)
//
// C: Grid Resolution Policy with two-layer limits
// - systemMinimumQuantum: minimum representable quantum
// - recommendedCaptureFloor: per-profile default floor
//

import Foundation

// MARK: - Grid Resolution Policy

/// Grid resolution policy (closed set, immutable mappings)
public enum GridResolutionPolicy {
    
    // MARK: - System Minimum Quantum
    
    /// System minimum quantum (LengthQ) - the minimum representable quantum for determinism/future hardware
    /// This is the absolute floor for the system
    public static let systemMinimumQuantum = LengthQ(scaleId: .systemMinimum, quanta: 1)  // 0.05mm
    
    // MARK: - Recommended Capture Floor (per profile)
    
    /// Recommended capture floor for standard profile
    public static let recommendedCaptureFloorStandard = LengthQ(scaleId: .geomId, quanta: 1)  // 1mm
    
    /// Recommended capture floor for smallObjectMacro profile
    public static let recommendedCaptureFloorSmallObjectMacro = LengthQ(scaleId: .systemMinimum, quanta: 5)  // 0.25mm
    
    /// Recommended capture floor for largeScene profile
    public static let recommendedCaptureFloorLargeScene = LengthQ(scaleId: .geomId, quanta: 5)  // 5mm
    
    /// Get recommended capture floor for a profile
    public static func recommendedCaptureFloor(for profile: CaptureProfile) -> LengthQ {
        switch profile {
        case .standard:
            return recommendedCaptureFloorStandard
        case .smallObjectMacro:
            return recommendedCaptureFloorSmallObjectMacro
        case .largeScene:
            return recommendedCaptureFloorLargeScene
        case .proMacro:
            return recommendedCaptureFloorSmallObjectMacro  // proMacro uses same floor as smallObjectMacro (high detail)
        case .cinematicScene:
            return recommendedCaptureFloorLargeScene  // cinematicScene uses same floor as largeScene (room-scale)
        }
    }
    
    // MARK: - Closed Set of Allowed Grid Cell Sizes
    
    /// Closed set of allowed grid cell sizes (LengthQ)
    /// **Rule:** Only these values are allowed. No dynamic or arbitrary resolutions.
    public static let allowedGridCellSizes: [LengthQ] = [
        LengthQ(scaleId: .systemMinimum, quanta: 5),   // 0.25mm
        LengthQ(scaleId: .systemMinimum, quanta: 10), // 0.5mm
        LengthQ(scaleId: .geomId, quanta: 1),          // 1mm
        LengthQ(scaleId: .geomId, quanta: 2),          // 2mm
        LengthQ(scaleId: .geomId, quanta: 5),          // 5mm
        LengthQ(scaleId: .geomId, quanta: 10),         // 1cm
        LengthQ(scaleId: .geomId, quanta: 20),         // 2cm
        LengthQ(scaleId: .geomId, quanta: 50),         // 5cm
    ]
    
    // MARK: - Profile to Grid Resolution Mapping
    
    /// Get allowed grid resolutions for a profile (immutable mapping)
    public static func allowedResolutions(for profile: CaptureProfile) -> [LengthQ] {
        switch profile {
        case .standard:
            return [
                LengthQ(scaleId: .geomId, quanta: 2),   // 2mm
                LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),  // 1cm
                LengthQ(scaleId: .geomId, quanta: 20),  // 2cm
                LengthQ(scaleId: .geomId, quanta: 50),  // 5cm
            ]
        case .smallObjectMacro:
            return [
                LengthQ(scaleId: .systemMinimum, quanta: 5),  // 0.25mm
                LengthQ(scaleId: .systemMinimum, quanta: 10), // 0.5mm
                LengthQ(scaleId: .geomId, quanta: 1),         // 1mm
                LengthQ(scaleId: .geomId, quanta: 2),         // 2mm
                LengthQ(scaleId: .geomId, quanta: 5),         // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),        // 1cm
            ]
        case .largeScene:
            return [
                LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),  // 1cm
                LengthQ(scaleId: .geomId, quanta: 20),   // 2cm
                LengthQ(scaleId: .geomId, quanta: 50),  // 5cm
            ]
        case .proMacro:
            // proMacro uses same resolutions as smallObjectMacro (high detail)
            return [
                LengthQ(scaleId: .systemMinimum, quanta: 5),  // 0.25mm
                LengthQ(scaleId: .systemMinimum, quanta: 10), // 0.5mm
                LengthQ(scaleId: .geomId, quanta: 1),         // 1mm
                LengthQ(scaleId: .geomId, quanta: 2),         // 2mm
                LengthQ(scaleId: .geomId, quanta: 5),         // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),        // 1cm
            ]
        case .cinematicScene:
            // cinematicScene uses same resolutions as largeScene (room-scale)
            return [
                LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),  // 1cm
                LengthQ(scaleId: .geomId, quanta: 20),   // 2cm
                LengthQ(scaleId: .geomId, quanta: 50),  // 5cm
            ]
        }
    }
    
    // MARK: - Validation
    
    /// Validate that a resolution is in the closed set
    public static func validateResolution(_ resolution: LengthQ) -> Bool {
        return allowedGridCellSizes.contains(resolution)
    }
    
    /// Validate that a resolution is allowed for a profile
    public static func validateResolution(_ resolution: LengthQ, for profile: CaptureProfile) -> Bool {
        let allowed = allowedResolutions(for: profile)
        return allowed.contains(resolution)
    }
    
}
