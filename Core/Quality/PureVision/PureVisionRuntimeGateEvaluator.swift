// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PureVisionRuntimeGateEvaluator.swift
// Aether3D
//
// Runtime-first gate evaluation for pure-vision first-scan admission.
//

import Foundation

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

public struct PureVisionRuntimeMetrics: Codable, Sendable {
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

public struct PureVisionGateResult: Codable, Sendable {
    public let gateId: PureVisionGateID
    public let passed: Bool
    public let observed: Double
    public let threshold: Double
    public let comparator: String

    public init(gateId: PureVisionGateID, passed: Bool, observed: Double, threshold: Double, comparator: String) {
        self.gateId = gateId
        self.passed = passed
        self.observed = observed
        self.threshold = threshold
        self.comparator = comparator
    }
}

public struct ZeroFabricationPolicyActionAttempt: Codable, Sendable {
    public let action: MLActionType
    public let context: ZeroFabricationContext

    public init(action: MLActionType, context: ZeroFabricationContext) {
        self.action = action
        self.context = context
    }
}

public struct PureVisionRuntimeTriTetInput: Sendable {
    public let triangles: [ScanTriangle]
    public let vertices: [TriTetVertex]
    public let tetrahedra: [TriTetTetrahedron]
    public let config: TriTetConfig

    public init(
        triangles: [ScanTriangle],
        vertices: [TriTetVertex],
        tetrahedra: [TriTetTetrahedron],
        config: TriTetConfig = .init()
    ) {
        self.triangles = triangles
        self.vertices = vertices
        self.tetrahedra = tetrahedra
        self.config = config
    }
}

public struct PureVisionRuntimeAuditThresholds: Codable, Sendable {
    public let maxCalibrationRejectCount: Int
    public let maxTriTetUnknownRatio: Float

    public init(
        maxCalibrationRejectCount: Int = 0,
        maxTriTetUnknownRatio: Float? = nil,
        profile: PureVisionRuntimeProfile = .balanced
    ) {
        let triTetThresholds = PureVisionRuntimeProfileConfig.config(for: profile).triTet
        self.maxCalibrationRejectCount = maxCalibrationRejectCount
        self.maxTriTetUnknownRatio = maxTriTetUnknownRatio ?? triTetThresholds.maxUnknownRatio
    }
}

public struct PureVisionRuntimeAuditInput: Sendable {
    public let runtimeProfile: PureVisionRuntimeProfile
    public let policyMode: ZeroFabricationPolicyKernel.Mode
    public let maxDenoiseDisplacementMeters: Float
    public let policyActionAttempts: [ZeroFabricationPolicyActionAttempt]
    public let outlierCrossValidation: [OutlierCrossValidationInput]
    public let calibrationCrossValidation: [CalibrationCrossValidationInput]
    public let triTetInput: PureVisionRuntimeTriTetInput?
    public let runtimeMetrics: PureVisionRuntimeMetrics?
    public let captureSignals: GeometryMLCaptureSignals
    public let evidenceSignals: GeometryMLEvidenceSignals
    public let transportSignals: GeometryMLTransportSignals
    public let securitySignals: GeometryMLSecuritySignals
    public let fusionThresholdsOverride: PureVisionGeometryMLThresholds?
    public let fusionWeightsOverride: PureVisionGeometryMLWeights?
    public let thresholds: PureVisionRuntimeAuditThresholds

    public init(
        runtimeProfile: PureVisionRuntimeProfile = .balanced,
        policyMode: ZeroFabricationPolicyKernel.Mode = .forensicStrict,
        maxDenoiseDisplacementMeters: Float = 0,
        policyActionAttempts: [ZeroFabricationPolicyActionAttempt] = [],
        outlierCrossValidation: [OutlierCrossValidationInput] = [],
        calibrationCrossValidation: [CalibrationCrossValidationInput] = [],
        triTetInput: PureVisionRuntimeTriTetInput? = nil,
        runtimeMetrics: PureVisionRuntimeMetrics? = nil,
        captureSignals: GeometryMLCaptureSignals = .init(),
        evidenceSignals: GeometryMLEvidenceSignals = .init(),
        transportSignals: GeometryMLTransportSignals = .init(),
        securitySignals: GeometryMLSecuritySignals = .init(),
        fusionThresholdsOverride: PureVisionGeometryMLThresholds? = nil,
        fusionWeightsOverride: PureVisionGeometryMLWeights? = nil,
        thresholds: PureVisionRuntimeAuditThresholds = .init()
    ) {
        self.runtimeProfile = runtimeProfile
        self.policyMode = policyMode
        self.maxDenoiseDisplacementMeters = maxDenoiseDisplacementMeters
        self.policyActionAttempts = policyActionAttempts
        self.outlierCrossValidation = outlierCrossValidation
        self.calibrationCrossValidation = calibrationCrossValidation
        self.triTetInput = triTetInput
        self.runtimeMetrics = runtimeMetrics
        self.captureSignals = captureSignals
        self.evidenceSignals = evidenceSignals
        self.transportSignals = transportSignals
        self.securitySignals = securitySignals
        self.fusionThresholdsOverride = fusionThresholdsOverride
        self.fusionWeightsOverride = fusionWeightsOverride
        self.thresholds = thresholds
    }
}

public struct ZeroFabricationPolicyAuditRecord: Codable, Sendable {
    public let action: MLActionType
    public let confidenceClass: ReconstructionConfidenceClass
    public let hasDirectObservation: Bool
    public let decision: ZeroFabricationDecision

    public init(
        action: MLActionType,
        confidenceClass: ReconstructionConfidenceClass,
        hasDirectObservation: Bool,
        decision: ZeroFabricationDecision
    ) {
        self.action = action
        self.confidenceClass = confidenceClass
        self.hasDirectObservation = hasDirectObservation
        self.decision = decision
    }
}

public struct PureVisionRuntimeAuditReport: Codable, Sendable {
    public let passes: Bool
    public let blockingReason: String?
    public let blockedPolicyCount: Int
    public let outlierRejectCount: Int
    public let outlierDowngradeCount: Int
    public let calibrationRejectCount: Int
    public let calibrationDowngradeCount: Int
    public let triTetUnknownRatio: Float
    public let triTetReport: TriTetConsistencyReport?
    public let geometryMLFusion: GeometryMLFusionResult?
    public let fusionFailureCount: Int
    public let policyRecords: [ZeroFabricationPolicyAuditRecord]
    public let outlierOutcomes: [CrossValidationOutcome]
    public let calibrationOutcomes: [CrossValidationOutcome]
}

public enum PureVisionRuntimeAuditEvaluator {
    public static func evaluate(_ input: PureVisionRuntimeAuditInput) -> PureVisionRuntimeAuditReport {
        let policyKernel = ZeroFabricationPolicyKernel(
            mode: input.policyMode,
            maxDenoiseDisplacementMeters: input.maxDenoiseDisplacementMeters
        )
        let policyRecords = input.policyActionAttempts.map { attempt -> ZeroFabricationPolicyAuditRecord in
            let decision = policyKernel.evaluate(action: attempt.action, context: attempt.context)
            return ZeroFabricationPolicyAuditRecord(
                action: attempt.action,
                confidenceClass: attempt.context.confidenceClass,
                hasDirectObservation: attempt.context.hasDirectObservation,
                decision: decision
            )
        }

        let blockedPolicyCount = policyRecords.filter { !$0.decision.allowed }.count
        let outlierOutcomes = input.outlierCrossValidation.map(CrossValidationFusion.evaluateOutlier)
        let calibrationOutcomes = input.calibrationCrossValidation.map(CrossValidationFusion.evaluateCalibration)

        let outlierRejectCount = outlierOutcomes.filter { $0.decision == .reject }.count
        let outlierDowngradeCount = outlierOutcomes.filter { $0.decision == .downgrade }.count
        let calibrationRejectCount = calibrationOutcomes.filter { $0.decision == .reject }.count
        let calibrationDowngradeCount = calibrationOutcomes.filter { $0.decision == .downgrade }.count

        let triTetReport = input.triTetInput.map {
            TriTetConsistencyEngine.evaluate(
                triangles: $0.triangles,
                vertices: $0.vertices,
                tetrahedra: $0.tetrahedra,
                config: $0.config
            )
        }

        let triTetUnknownRatio: Float = {
            guard let triTetReport else { return 0 }
            let total = triTetReport.measuredCount + triTetReport.estimatedCount + triTetReport.unknownCount
            guard total > 0 else { return 0 }
            return Float(triTetReport.unknownCount) / Float(total)
        }()

        let profileConfig = PureVisionRuntimeProfileConfig.config(for: input.runtimeProfile)
        let geometryMLFusion: GeometryMLFusionResult? = input.runtimeMetrics.map { runtimeMetrics in
            GeometryMLFusionEngine.evaluate(
                input: GeometryMLFusionInput(
                    runtimeMetrics: runtimeMetrics,
                    triTetReport: triTetReport,
                    outlierOutcomes: outlierOutcomes,
                    calibrationOutcomes: calibrationOutcomes,
                    captureSignals: input.captureSignals,
                    evidenceSignals: input.evidenceSignals,
                    transportSignals: input.transportSignals,
                    securitySignals: input.securitySignals
                ),
                thresholds: input.fusionThresholdsOverride ?? profileConfig.geometryML,
                weights: input.fusionWeightsOverride ?? profileConfig.geometryMLWeights,
                uploadThresholds: profileConfig.uploadCDC
            )
        }
        let fusionFailureCount = geometryMLFusion?.reasonCodes.count ?? 0

        let blockingReason: String?
        if blockedPolicyCount > 0 {
            blockingReason = "policy_blocked"
        } else if calibrationRejectCount > input.thresholds.maxCalibrationRejectCount {
            blockingReason = "calibration_reject_exceeded"
        } else if triTetUnknownRatio > input.thresholds.maxTriTetUnknownRatio {
            blockingReason = "tri_tet_unknown_ratio_exceeded"
        } else if let geometryMLFusion, !geometryMLFusion.passes {
            let suffix = geometryMLFusion.primaryReasonCode ?? "GENERIC_FUSION_FAILURE"
            blockingReason = "geometry_ml_fusion_failed:\(suffix)"
        } else {
            blockingReason = nil
        }

        return PureVisionRuntimeAuditReport(
            passes: blockingReason == nil,
            blockingReason: blockingReason,
            blockedPolicyCount: blockedPolicyCount,
            outlierRejectCount: outlierRejectCount,
            outlierDowngradeCount: outlierDowngradeCount,
            calibrationRejectCount: calibrationRejectCount,
            calibrationDowngradeCount: calibrationDowngradeCount,
            triTetUnknownRatio: triTetUnknownRatio,
            triTetReport: triTetReport,
            geometryMLFusion: geometryMLFusion,
            fusionFailureCount: fusionFailureCount,
            policyRecords: policyRecords,
            outlierOutcomes: outlierOutcomes,
            calibrationOutcomes: calibrationOutcomes
        )
    }
}

public enum PureVisionRuntimeGateEvaluator {
    public static func evaluate(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateResult] {
        if let native = NativePureVisionRuntimeBridge.evaluateGates(metrics) {
            return native
        }
        return evaluateSwift(metrics)
    }

    public static func failedGateIDs(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateID] {
        if let native = NativePureVisionRuntimeBridge.failedGateIDs(metrics) {
            return native
        }
        return evaluateSwift(metrics).filter { !$0.passed }.map(\.gateId)
    }

    private static func evaluateSwift(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateResult] {
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
                passed: metrics.blurLaplacian >= CoreBlurThresholds.frameRejection,
                observed: metrics.blurLaplacian,
                threshold: CoreBlurThresholds.frameRejection,
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
}

public struct FirstScanReplaySample: Codable, Sendable {
    public let sessionId: String
    public let durationSeconds: Double
    public let metrics: PureVisionRuntimeMetrics
    public let guidanceDisplayValue: Double
    public let softEvidenceValue: Double
    public let replayHashStable: Bool

    public init(
        sessionId: String,
        durationSeconds: Double,
        metrics: PureVisionRuntimeMetrics,
        guidanceDisplayValue: Double,
        softEvidenceValue: Double,
        replayHashStable: Bool
    ) {
        self.sessionId = sessionId
        self.durationSeconds = durationSeconds
        self.metrics = metrics
        self.guidanceDisplayValue = guidanceDisplayValue
        self.softEvidenceValue = softEvidenceValue
        self.replayHashStable = replayHashStable
    }
}

public struct FirstScanKPIReport: Codable, Sendable {
    public let totalSessions: Int
    public let firstScanSuccessRate: Double
    public let replayStableRate: Double
    public let medianDurationSeconds: Double
    public let maxDurationSeconds: Double
    public let hardCapViolations: Int
    public let failureReasons: [String: Int]
    public let passesGate: Bool

    public init(
        totalSessions: Int,
        firstScanSuccessRate: Double,
        replayStableRate: Double,
        medianDurationSeconds: Double,
        maxDurationSeconds: Double,
        hardCapViolations: Int,
        failureReasons: [String: Int],
        passesGate: Bool
    ) {
        self.totalSessions = totalSessions
        self.firstScanSuccessRate = firstScanSuccessRate
        self.replayStableRate = replayStableRate
        self.medianDurationSeconds = medianDurationSeconds
        self.maxDurationSeconds = maxDurationSeconds
        self.hardCapViolations = hardCapViolations
        self.failureReasons = failureReasons
        self.passesGate = passesGate
    }
}

public enum FirstScanKPIEvaluator {
    public static let targetFirstScanSuccessRate: Double = PureVisionRuntimeProfileConfig.config(for: .balanced).firstScan.targetSuccessRate
    public static let firstScanTargetSeconds: Double = PureVisionRuntimeProfileConfig.config(for: .balanced).firstScan.targetDurationSeconds
    public static let hardCapSeconds: Double = PureVisionRuntimeProfileConfig.config(for: .balanced).firstScan.hardCapSeconds

    public static func evaluate(
        samples: [FirstScanReplaySample],
        runtimeAuditsBySessionId: [String: PureVisionRuntimeAuditReport] = [:],
        profile: PureVisionRuntimeProfile = .balanced
    ) -> FirstScanKPIReport {
        let targets = PureVisionRuntimeProfileConfig.config(for: profile).firstScan

        guard !samples.isEmpty else {
            return FirstScanKPIReport(
                totalSessions: 0,
                firstScanSuccessRate: 0.0,
                replayStableRate: 0.0,
                medianDurationSeconds: 0.0,
                maxDurationSeconds: 0.0,
                hardCapViolations: 0,
                failureReasons: ["empty_sample": 1],
                passesGate: false
            )
        }

        var successCount = 0
        var replayStableCount = 0
        var hardCapViolations = 0
        var durations: [Double] = []
        var failureReasons: [String: Int] = [:]

        for sample in samples {
            durations.append(sample.durationSeconds)
            if sample.replayHashStable {
                replayStableCount += 1
            }

            if sample.durationSeconds > targets.hardCapSeconds {
                hardCapViolations += 1
            }

            let gateResults = PureVisionRuntimeGateEvaluator.evaluate(sample.metrics)
            let hardGatesPass = gateResults.allSatisfy(\.passed)
            let s5Pass = sample.guidanceDisplayValue >= ScanGuidanceConstants.s4ToS5Threshold
                && sample.softEvidenceValue >= ScanGuidanceConstants.s5MinSoftEvidence
            let withinFirstScanTarget = sample.durationSeconds <= targets.targetDurationSeconds
            let runtimeAudit = runtimeAuditsBySessionId[sample.sessionId]
            let runtimeAuditPass = runtimeAudit?.passes ?? true
            let passed = hardGatesPass && s5Pass && withinFirstScanTarget && runtimeAuditPass

            if passed {
                successCount += 1
            } else {
                let reason = classifyFailure(
                    sample: sample,
                    gateResults: gateResults,
                    s5Pass: s5Pass,
                    withinFirstScanTarget: withinFirstScanTarget,
                    runtimeAudit: runtimeAudit,
                    hardCapSeconds: targets.hardCapSeconds
                )
                failureReasons[reason, default: 0] += 1
            }
        }

        durations.sort()
        let median: Double = {
            let middle = durations.count / 2
            if durations.count % 2 == 0 {
                return (durations[middle - 1] + durations[middle]) / 2.0
            }
            return durations[middle]
        }()
        let maxDuration = durations.max() ?? 0.0
        let successRate = Double(successCount) / Double(samples.count)
        let replayRate = Double(replayStableCount) / Double(samples.count)

        let passes = successRate >= targets.targetSuccessRate
            && replayRate >= targets.targetReplayStableRate
            && hardCapViolations == 0

        return FirstScanKPIReport(
            totalSessions: samples.count,
            firstScanSuccessRate: successRate,
            replayStableRate: replayRate,
            medianDurationSeconds: median,
            maxDurationSeconds: maxDuration,
            hardCapViolations: hardCapViolations,
            failureReasons: failureReasons,
            passesGate: passes
        )
    }

    private static func classifyFailure(
        sample: FirstScanReplaySample,
        gateResults: [PureVisionGateResult],
        s5Pass: Bool,
        withinFirstScanTarget: Bool,
        runtimeAudit: PureVisionRuntimeAuditReport?,
        hardCapSeconds: Double
    ) -> String {
        if sample.durationSeconds > hardCapSeconds {
            return "hard_cap_exceeded"
        }
        if !withinFirstScanTarget {
            return "first_scan_duration_exceeded"
        }
        if !sample.replayHashStable {
            return "replay_hash_unstable"
        }
        if !s5Pass {
            return "s5_material_not_reached"
        }
        if let runtimeAudit, !runtimeAudit.passes {
            if let blocking = runtimeAudit.blockingReason, !blocking.isEmpty {
                return "ml_audit_failed:\(blocking)"
            }
            return "ml_audit_failed"
        }

        let failedGates = gateResults.filter { !$0.passed }
        if let first = failedGates.first {
            return "gate_failed:\(first.gateId.rawValue)"
        }
        return "unknown_failure"
    }
}

