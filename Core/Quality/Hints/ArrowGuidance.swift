//
//  ArrowGuidance.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 5
//  ArrowGuidance - calculates arrow direction
//

import Foundation

/// ArrowGuidance - calculates arrow direction for hints
/// Priority: coverage gradient > brightness gradient > texture gradient
public struct ArrowGuidance {
    /// Calculate arrow direction
    public static func calculateDirection(
        coverageGradient: CodableVector?,
        brightnessGradient: CodableVector?,
        textureGradient: CodableVector?
    ) -> CodableVector? {
        // Priority: coverage > brightness > texture
        if let coverage = coverageGradient {
            return coverage
        }
        if let brightness = brightnessGradient {
            return brightness
        }
        return textureGradient
    }
}

