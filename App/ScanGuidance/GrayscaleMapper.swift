//
// GrayscaleMapper.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Grayscale Mapper
// v7.0.1 NEW: Continuous display→grayscale conversion
// Bypasses discrete ColorState (S1/S2 both map to .darkGray in EvidenceStateMachine)
//
// NOTE: This file is in App/ directory and will not compile with SwiftPM.
// It will be compiled only via Xcode project on iOS/macOS.
//

import Foundation

/// Maps display [0, 1] → continuous grayscale RGB
///
/// This is necessary because EvidenceStateMachine maps both S1 and S2
/// to the same `.darkGray` ColorState. PR7 needs finer-grained grayscale.
///
/// Mapping:
///   display 0.00 → RGB(0, 0, 0)       black
///   display 0.10 → RGB(64, 64, 64)    dark gray
///   display 0.25 → RGB(128, 128, 128) medium gray
///   display 0.50 → RGB(200, 200, 200) light gray
///   display 0.75 → original color (alpha blend)
///   display 0.88 → transparent (S5)
public struct GrayscaleMapper {

    public init() {}

    /// Convert display value to grayscale RGB [0, 1]
    public func grayscale(for display: Double) -> (r: Float, g: Float, b: Float) {
        let clamped = min(max(display, 0.0), 1.0)

        // S0→S3: interpolate grayscale
        if clamped < ScanGuidanceConstants.s3ToS4Threshold {
            // Map [0, 0.75) → [0, 200/255]
            let t = Float(clamped / ScanGuidanceConstants.s3ToS4Threshold)
            let gray = t * (200.0 / 255.0)
            return (gray, gray, gray)
        }

        // S4+: return white (original color blending handled by shader)
        return (1.0, 1.0, 1.0)
    }
}
