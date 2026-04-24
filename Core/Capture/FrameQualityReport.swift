// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FrameQualityReport.swift
// Aether3D
//
// Output of FrameAnalyzer — a numeric summary of a single camera frame's
// visual quality. Produced by QualityAnalysisObserver and consumed by
// DomeUpdateObserver (to gate what counts as an "accepted" frame).
//
// INTERPRETATION OF `laplacianVariance`
// ─────────────────────────────────────
// Laplacian variance on a 128×128 grayscale downsample of the Y plane.
// iPhone back camera, normal lighting, in focus:
//    < 100    非常糊 (快速移动 / 严重失焦)
//    100–300  偏糊 (轻微移动 / 浅失焦)
//    300–500  临界
//    500+     合格
//   1000+     清晰
//   3000+     非常锐利 (高对比场景)
//
// Dark scenes suppress variance naturally — see `meanBrightness` to
// adjust thresholds dynamically.

import Foundation

public struct FrameQualityReport: Sendable, Equatable {

    /// Same timestamp as the CaptureFrame the report was computed from.
    public let timestamp: TimeInterval

    /// Variance of the discrete 3×3 Laplacian convolution on the 128×128
    /// grayscale downsample. Primary sharpness metric.
    public let laplacianVariance: Double

    /// Mean luminance (0–255) across the 128×128 downsample. Low values
    /// indicate dark scenes where absolute `laplacianVariance` is
    /// misleading.
    public let meanBrightness: Double

    /// Global variance of luminance across the downsample. Proxy for
    /// scene contrast. Low values indicate flat / featureless scenes
    /// (white wall, black fabric) that won't give a sharp frame even if
    /// Laplacian variance happens to be moderate.
    public let globalContrastVariance: Double

    public init(
        timestamp: TimeInterval,
        laplacianVariance: Double,
        meanBrightness: Double,
        globalContrastVariance: Double
    ) {
        self.timestamp = timestamp
        self.laplacianVariance = laplacianVariance
        self.meanBrightness = meanBrightness
        self.globalContrastVariance = globalContrastVariance
    }
}

/// Gate policy: given a quality report, is this frame sharp enough to
/// count toward coverage / training data?
///
/// The threshold is scaled down in dark scenes because Laplacian variance
/// depends on absolute luminance — a sharp image in dim light naturally
/// produces lower variance than the same image under strong light.
public struct FrameQualityGate: Sendable {

    /// Default sharpness threshold under normal lighting (brightness ≥ 80).
    public static let defaultMinSharpnessNormalLight: Double = 400

    /// Relaxed threshold for low-light (brightness < 40). Above 40 but
    /// below 80 we linearly interpolate between normal and low.
    public static let defaultMinSharpnessLowLight: Double = 250

    /// Absolute brightness below which the frame is treated as "too dark
    /// to judge" and accepted regardless of sharpness (so the user isn't
    /// stuck when pointing at a shadow).
    public static let defaultIgnoreBelowBrightness: Double = 15

    public let minSharpnessNormalLight: Double
    public let minSharpnessLowLight: Double
    public let ignoreBelowBrightness: Double

    public init(
        minSharpnessNormalLight: Double = Self.defaultMinSharpnessNormalLight,
        minSharpnessLowLight: Double = Self.defaultMinSharpnessLowLight,
        ignoreBelowBrightness: Double = Self.defaultIgnoreBelowBrightness
    ) {
        self.minSharpnessNormalLight = minSharpnessNormalLight
        self.minSharpnessLowLight = minSharpnessLowLight
        self.ignoreBelowBrightness = ignoreBelowBrightness
    }

    /// `true` if the report passes the gate.
    public func passes(_ report: FrameQualityReport) -> Bool {
        if report.meanBrightness < ignoreBelowBrightness {
            // Too dark to meaningfully gate; accept rather than stall.
            return true
        }
        let threshold = adaptiveThreshold(brightness: report.meanBrightness)
        return report.laplacianVariance >= threshold
    }

    /// Linear interpolate between low-light and normal-light thresholds.
    public func adaptiveThreshold(brightness: Double) -> Double {
        let lowAnchor = 40.0
        let highAnchor = 80.0
        if brightness <= lowAnchor { return minSharpnessLowLight }
        if brightness >= highAnchor { return minSharpnessNormalLight }
        let t = (brightness - lowAnchor) / (highAnchor - lowAnchor)
        return minSharpnessLowLight + (minSharpnessNormalLight - minSharpnessLowLight) * t
    }
}
