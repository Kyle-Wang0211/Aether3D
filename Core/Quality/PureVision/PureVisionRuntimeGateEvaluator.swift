// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PureVisionRuntimeGateEvaluator.swift
// Aether3D
//
// Minimal runtime review and upload-admission gate set for the whitebox loop.
//

import Foundation

public struct GeometryMLCaptureSignals: Codable, Sendable, Equatable {
    public let motionScore: Double
    public let overexposureRatio: Double
    public let underexposureRatio: Double
    public let hasLargeBlownRegion: Bool

    public init(
        motionScore: Double = 0,
        overexposureRatio: Double = 0,
        underexposureRatio: Double = 0,
        hasLargeBlownRegion: Bool = false
    ) {
        self.motionScore = motionScore
        self.overexposureRatio = overexposureRatio
        self.underexposureRatio = underexposureRatio
        self.hasLargeBlownRegion = hasLargeBlownRegion
    }
}

public enum PureVisionGateID: String, CaseIterable, Codable, Sendable {
    case baseline = "baseline_pixels"
    case blur = "blur_laplacian"
    case orbFeatures = "orb_feature_count"
    case parallax = "parallax_ratio"
    case depthSigma = "depth_sigma"
    case closureRatio = "closure_ratio"
    case unknownVoxelRatio = "unknown_voxel_ratio"
    case thermal = "thermal_celsius"
}

public struct PureVisionRuntimeMetrics: Codable, Sendable, Equatable {
    public let baselinePixels: Double
    public let blurLaplacian: Double
    public let orbFeatures: Int
    public let parallaxRatio: Double
    public let depthSigmaMeters: Double
    public let closureRatio: Double
    public let unknownVoxelRatio: Double
    public let thermalCelsius: Double

    public init(
        baselinePixels: Double,
        blurLaplacian: Double,
        orbFeatures: Int,
        parallaxRatio: Double,
        depthSigmaMeters: Double,
        closureRatio: Double,
        unknownVoxelRatio: Double,
        thermalCelsius: Double
    ) {
        self.baselinePixels = baselinePixels
        self.blurLaplacian = blurLaplacian
        self.orbFeatures = orbFeatures
        self.parallaxRatio = parallaxRatio
        self.depthSigmaMeters = depthSigmaMeters
        self.closureRatio = closureRatio
        self.unknownVoxelRatio = unknownVoxelRatio
        self.thermalCelsius = thermalCelsius
    }
}

public struct PureVisionGateResult: Codable, Sendable, Equatable {
    public let gateId: PureVisionGateID
    public let passed: Bool
    public let observed: Double
    public let threshold: Double
    public let comparator: String

    public init(
        gateId: PureVisionGateID,
        passed: Bool,
        observed: Double,
        threshold: Double,
        comparator: String
    ) {
        self.gateId = gateId
        self.passed = passed
        self.observed = observed
        self.threshold = threshold
        self.comparator = comparator
    }
}

public struct PureVisionUploadAdmissionDecision: Codable, Sendable, Equatable {
    public let allowed: Bool
    public let blockingReason: String?
    public let failedGateIDs: [PureVisionGateID]
    public let captureWarnings: [String]

    public init(
        allowed: Bool,
        blockingReason: String?,
        failedGateIDs: [PureVisionGateID],
        captureWarnings: [String]
    ) {
        self.allowed = allowed
        self.blockingReason = blockingReason
        self.failedGateIDs = failedGateIDs
        self.captureWarnings = captureWarnings
    }
}

public enum PureVisionRuntimeGateEvaluator {
    public static let maxRuntimeMotionScoreForUpload = 0.75
    public static let maxRuntimeExposureRatioForUpload = 0.10

    public static func evaluate(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateResult] {
        [
            .init(
                gateId: .baseline,
                passed: metrics.baselinePixels >= PureVisionRuntimeConstants.K_OBS_MIN_BASELINE_PIXELS,
                observed: metrics.baselinePixels,
                threshold: PureVisionRuntimeConstants.K_OBS_MIN_BASELINE_PIXELS,
                comparator: ">="
            ),
            .init(
                gateId: .blur,
                passed: metrics.blurLaplacian >= QualityThresholds.laplacianBlurThreshold,
                observed: metrics.blurLaplacian,
                threshold: QualityThresholds.laplacianBlurThreshold,
                comparator: ">="
            ),
            .init(
                gateId: .orbFeatures,
                passed: metrics.orbFeatures >= FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM,
                observed: Double(metrics.orbFeatures),
                threshold: Double(FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM),
                comparator: ">="
            ),
            .init(
                gateId: .parallax,
                passed: metrics.parallaxRatio >= PureVisionRuntimeConstants.K_OBS_REQ_PARALLAX_RATIO,
                observed: metrics.parallaxRatio,
                threshold: PureVisionRuntimeConstants.K_OBS_REQ_PARALLAX_RATIO,
                comparator: ">="
            ),
            .init(
                gateId: .depthSigma,
                passed: metrics.depthSigmaMeters <= PureVisionRuntimeConstants.K_OBS_SIGMA_Z_TARGET_M,
                observed: metrics.depthSigmaMeters,
                threshold: PureVisionRuntimeConstants.K_OBS_SIGMA_Z_TARGET_M,
                comparator: "<="
            ),
            .init(
                gateId: .closureRatio,
                passed: metrics.closureRatio >= PureVisionRuntimeConstants.K_VOLUME_CLOSURE_RATIO_MIN,
                observed: metrics.closureRatio,
                threshold: PureVisionRuntimeConstants.K_VOLUME_CLOSURE_RATIO_MIN,
                comparator: ">="
            ),
            .init(
                gateId: .unknownVoxelRatio,
                passed: metrics.unknownVoxelRatio <= PureVisionRuntimeConstants.K_VOLUME_UNKNOWN_VOXEL_MAX,
                observed: metrics.unknownVoxelRatio,
                threshold: PureVisionRuntimeConstants.K_VOLUME_UNKNOWN_VOXEL_MAX,
                comparator: "<="
            ),
            .init(
                gateId: .thermal,
                passed: metrics.thermalCelsius <= ThermalConstants.thermalCriticalC,
                observed: metrics.thermalCelsius,
                threshold: ThermalConstants.thermalCriticalC,
                comparator: "<="
            ),
        ]
    }

    public static func failedGateIDs(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateID] {
        evaluate(metrics).filter { !$0.passed }.map(\.gateId)
    }

    public static func uploadAdmissionDecision(
        metrics: PureVisionRuntimeMetrics,
        captureSignals: GeometryMLCaptureSignals = .init()
    ) -> PureVisionUploadAdmissionDecision {
        let failed = failedGateIDs(metrics)
        let captureWarnings = captureWarnings(for: captureSignals)

        let blockingReason: String?
        if let firstGate = failed.first {
            blockingReason = "gate_failed:\(firstGate.rawValue)"
        } else if let firstWarning = captureWarnings.first {
            blockingReason = firstWarning
        } else {
            blockingReason = nil
        }

        return PureVisionUploadAdmissionDecision(
            allowed: failed.isEmpty && captureWarnings.isEmpty,
            blockingReason: blockingReason,
            failedGateIDs: failed,
            captureWarnings: captureWarnings
        )
    }

    private static func captureWarnings(for captureSignals: GeometryMLCaptureSignals) -> [String] {
        var warnings: [String] = []

        if captureSignals.motionScore > maxRuntimeMotionScoreForUpload {
            warnings.append("capture_motion_unstable")
        }
        if captureSignals.overexposureRatio > maxRuntimeExposureRatioForUpload {
            warnings.append("capture_overexposed")
        }
        if captureSignals.underexposureRatio > maxRuntimeExposureRatioForUpload {
            warnings.append("capture_underexposed")
        }
        if captureSignals.hasLargeBlownRegion {
            warnings.append("capture_large_blown_region")
        }

        return warnings
    }
}
