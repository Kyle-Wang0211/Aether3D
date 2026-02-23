// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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

public struct GeometryMLEvidenceSignals: Codable, Sendable, Equatable {
    public let coverageScore: Double
    public let softEvidenceScore: Double
    public let persistentPizRegionCount: Int
    public let invariantViolationCount: Int
    public let replayStableRate: Double
    public let triTetBindingCoverage: Double
    public let merkleProofCoverage: Double
    public let occlusionExcludedAreaRatio: Double
    public let provenanceGapCount: Int

    public init(
        coverageScore: Double = 0,
        softEvidenceScore: Double = 0,
        persistentPizRegionCount: Int = 0,
        invariantViolationCount: Int = 0,
        replayStableRate: Double = 1.0,
        triTetBindingCoverage: Double = 1.0,
        merkleProofCoverage: Double = 1.0,
        occlusionExcludedAreaRatio: Double = 0,
        provenanceGapCount: Int = 0
    ) {
        self.coverageScore = coverageScore
        self.softEvidenceScore = softEvidenceScore
        self.persistentPizRegionCount = persistentPizRegionCount
        self.invariantViolationCount = invariantViolationCount
        self.replayStableRate = replayStableRate
        self.triTetBindingCoverage = triTetBindingCoverage
        self.merkleProofCoverage = merkleProofCoverage
        self.occlusionExcludedAreaRatio = occlusionExcludedAreaRatio
        self.provenanceGapCount = provenanceGapCount
    }
}

public struct GeometryMLTransportSignals: Codable, Sendable, Equatable {
    public let bandwidthMbps: Double
    public let rttMs: Double
    public let lossRate: Double
    public let chunkSizeBytes: Int
    public let dedupSavingsRatio: Double
    public let compressionSavingsRatio: Double
    public let byzantineCoverage: Double
    public let merkleProofSuccessRate: Double
    public let proofOfPossessionSuccessRate: Double
    public let chunkHmacMismatchRate: Double
    public let circuitBreakerOpenRatio: Double
    public let retryExhaustionRate: Double
    public let resumeCorruptionRate: Double

    public init(
        bandwidthMbps: Double = 0,
        rttMs: Double = 0,
        lossRate: Double = 0,
        chunkSizeBytes: Int = UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
        dedupSavingsRatio: Double = 0,
        compressionSavingsRatio: Double = 0,
        byzantineCoverage: Double = 1.0,
        merkleProofSuccessRate: Double = 1.0,
        proofOfPossessionSuccessRate: Double = 1.0,
        chunkHmacMismatchRate: Double = 0,
        circuitBreakerOpenRatio: Double = 0,
        retryExhaustionRate: Double = 0,
        resumeCorruptionRate: Double = 0
    ) {
        self.bandwidthMbps = bandwidthMbps
        self.rttMs = rttMs
        self.lossRate = lossRate
        self.chunkSizeBytes = chunkSizeBytes
        self.dedupSavingsRatio = dedupSavingsRatio
        self.compressionSavingsRatio = compressionSavingsRatio
        self.byzantineCoverage = byzantineCoverage
        self.merkleProofSuccessRate = merkleProofSuccessRate
        self.proofOfPossessionSuccessRate = proofOfPossessionSuccessRate
        self.chunkHmacMismatchRate = chunkHmacMismatchRate
        self.circuitBreakerOpenRatio = circuitBreakerOpenRatio
        self.retryExhaustionRate = retryExhaustionRate
        self.resumeCorruptionRate = resumeCorruptionRate
    }
}

public struct GeometryMLSecuritySignals: Codable, Sendable, Equatable {
    public let codeSignatureValid: Bool
    public let runtimeIntegrityValid: Bool
    public let telemetryHmacValid: Bool
    public let debuggerDetected: Bool
    public let environmentTampered: Bool
    public let certificatePinMismatchCount: Int
    public let bootChainValidated: Bool
    public let requestSignerValidRate: Double
    public let secureEnclaveAvailable: Bool

    public init(
        codeSignatureValid: Bool = true,
        runtimeIntegrityValid: Bool = true,
        telemetryHmacValid: Bool = true,
        debuggerDetected: Bool = false,
        environmentTampered: Bool = false,
        certificatePinMismatchCount: Int = 0,
        bootChainValidated: Bool = true,
        requestSignerValidRate: Double = 1.0,
        secureEnclaveAvailable: Bool = true
    ) {
        self.codeSignatureValid = codeSignatureValid
        self.runtimeIntegrityValid = runtimeIntegrityValid
        self.telemetryHmacValid = telemetryHmacValid
        self.debuggerDetected = debuggerDetected
        self.environmentTampered = environmentTampered
        self.certificatePinMismatchCount = certificatePinMismatchCount
        self.bootChainValidated = bootChainValidated
        self.requestSignerValidRate = requestSignerValidRate
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }
}

public struct GeometryMLFusionInput: Sendable {
    public let runtimeMetrics: PureVisionRuntimeMetrics
    public let triTetReport: TriTetConsistencyReport?
    public let outlierOutcomes: [CrossValidationOutcome]
    public let calibrationOutcomes: [CrossValidationOutcome]
    public let captureSignals: GeometryMLCaptureSignals
    public let evidenceSignals: GeometryMLEvidenceSignals
    public let transportSignals: GeometryMLTransportSignals
    public let securitySignals: GeometryMLSecuritySignals

    public init(
        runtimeMetrics: PureVisionRuntimeMetrics,
        triTetReport: TriTetConsistencyReport? = nil,
        outlierOutcomes: [CrossValidationOutcome] = [],
        calibrationOutcomes: [CrossValidationOutcome] = [],
        captureSignals: GeometryMLCaptureSignals = .init(),
        evidenceSignals: GeometryMLEvidenceSignals = .init(),
        transportSignals: GeometryMLTransportSignals = .init(),
        securitySignals: GeometryMLSecuritySignals = .init()
    ) {
        self.runtimeMetrics = runtimeMetrics
        self.triTetReport = triTetReport
        self.outlierOutcomes = outlierOutcomes
        self.calibrationOutcomes = calibrationOutcomes
        self.captureSignals = captureSignals
        self.evidenceSignals = evidenceSignals
        self.transportSignals = transportSignals
        self.securitySignals = securitySignals
    }
}

public struct GeometryMLFusionComponentScores: Codable, Sendable, Equatable {
    public let geometry: Double
    public let crossValidation: Double
    public let capture: Double
    public let evidence: Double
    public let transport: Double
    public let security: Double

    public init(
        geometry: Double,
        crossValidation: Double,
        capture: Double,
        evidence: Double,
        transport: Double,
        security: Double
    ) {
        self.geometry = geometry
        self.crossValidation = crossValidation
        self.capture = capture
        self.evidence = evidence
        self.transport = transport
        self.security = security
    }
}

public struct GeometryMLCrossValidationStats: Codable, Sendable, Equatable {
    public let keepCount: Int
    public let downgradeCount: Int
    public let rejectCount: Int
    public let keepRatio: Double

    public init(
        keepCount: Int,
        downgradeCount: Int,
        rejectCount: Int,
        keepRatio: Double
    ) {
        self.keepCount = keepCount
        self.downgradeCount = downgradeCount
        self.rejectCount = rejectCount
        self.keepRatio = keepRatio
    }
}

public struct GeometryMLFusionResult: Codable, Sendable, Equatable {
    public let passes: Bool
    public let fusionScore: Double
    public let riskScore: Double
    public let securityPenalty: Double
    public let triTetMeasuredRatio: Double
    public let triTetUnknownRatio: Double
    public let crossValidationKeepRatio: Double
    public let captureExposurePenalty: Double
    public let componentScores: GeometryMLFusionComponentScores
    public let crossValidationStats: GeometryMLCrossValidationStats
    public let reasonCodes: [String]

    public var primaryReasonCode: String? {
        reasonCodes.first
    }

    public init(
        passes: Bool,
        fusionScore: Double,
        riskScore: Double,
        securityPenalty: Double,
        triTetMeasuredRatio: Double,
        triTetUnknownRatio: Double,
        crossValidationKeepRatio: Double,
        captureExposurePenalty: Double,
        componentScores: GeometryMLFusionComponentScores,
        crossValidationStats: GeometryMLCrossValidationStats,
        reasonCodes: [String]
    ) {
        self.passes = passes
        self.fusionScore = fusionScore
        self.riskScore = riskScore
        self.securityPenalty = securityPenalty
        self.triTetMeasuredRatio = triTetMeasuredRatio
        self.triTetUnknownRatio = triTetUnknownRatio
        self.crossValidationKeepRatio = crossValidationKeepRatio
        self.captureExposurePenalty = captureExposurePenalty
        self.componentScores = componentScores
        self.crossValidationStats = crossValidationStats
        self.reasonCodes = reasonCodes
    }
}

public enum GeometryMLFusionEngine {
    public static func evaluate(
        input: GeometryMLFusionInput,
        thresholds: PureVisionGeometryMLThresholds,
        weights: PureVisionGeometryMLWeights,
        uploadThresholds: PureVisionUploadCDCThresholds
    ) -> GeometryMLFusionResult {
        if let native = NativePureVisionRuntimeBridge.evaluateGeometryML(
            input: input,
            thresholds: thresholds,
            weights: weights,
            uploadThresholds: uploadThresholds
        ) {
            return native
        }

        let (triTetMeasuredRatio, triTetUnknownRatio, triTetCombinedScore) = triTetStats(input)
        let crossValidationStats = evaluateCrossValidation(
            outlierOutcomes: input.outlierOutcomes,
            calibrationOutcomes: input.calibrationOutcomes
        )

        let geometryScore = clamp01(
            triTetCombinedScore * 0.60
                + triTetMeasuredRatio * 0.25
                + (1.0 - triTetUnknownRatio) * 0.15
        )

        let crossValidationScore = clamp01(
            crossValidationStats.keepRatio
                + Double(crossValidationStats.downgradeCount) * 0.5 / max(1.0, Double(totalCrossValidationCount(crossValidationStats)))
        )

        let exposurePenalty = captureExposurePenalty(input.captureSignals)

        let captureScore = evaluateCapture(
            runtimeMetrics: input.runtimeMetrics,
            captureSignals: input.captureSignals,
            exposurePenalty: exposurePenalty,
            thresholds: thresholds
        )

        let evidenceScore = evaluateEvidence(
            runtimeMetrics: input.runtimeMetrics,
            evidenceSignals: input.evidenceSignals,
            thresholds: thresholds
        )

        let transportScore = evaluateTransport(
            transportSignals: input.transportSignals,
            thresholds: thresholds,
            uploadThresholds: uploadThresholds
        )

        let securityPenalty = evaluateSecurityPenalty(input.securitySignals)
        let securityScore = clamp01(1.0 - securityPenalty)

        let components = GeometryMLFusionComponentScores(
            geometry: geometryScore,
            crossValidation: crossValidationScore,
            capture: captureScore,
            evidence: evidenceScore,
            transport: transportScore,
            security: securityScore
        )

        let fusionScore = clamp01(
            components.geometry * weights.geometry
                + components.crossValidation * weights.crossValidation
                + components.capture * weights.capture
                + components.evidence * weights.evidence
                + components.transport * weights.transport
                + components.security * weights.security
        )

        let crossValidationSampleCount = totalCrossValidationCount(crossValidationStats)
        let crossValidationSupportScore = clamp01(Double(crossValidationSampleCount) / 6.0)
        let evidenceMaturityScore = clamp01(
            input.evidenceSignals.coverageScore * 0.50
                + input.evidenceSignals.triTetBindingCoverage * 0.30
                + input.evidenceSignals.replayStableRate * 0.20
        )
        let fusionMaturityScore = clamp01(
            evidenceMaturityScore * 0.65 + crossValidationSupportScore * 0.35
        )

        let adaptiveMinFusionScore = clamp01(
            thresholds.minFusionScore + (1.0 - fusionMaturityScore) * 0.05
        )
        let adaptiveMaxRiskScore = clamp01(
            thresholds.maxRiskScore - (1.0 - fusionMaturityScore) * 0.05
        )

        let rejectRatio = crossValidationSampleCount == 0
            ? 0
            : Double(crossValidationStats.rejectCount) / Double(crossValidationSampleCount)

        let motionOverflow = overflowRatio(input.captureSignals.motionScore, threshold: thresholds.maxMotionScore)
        let exposureOverflow = overflowRatio(exposurePenalty, threshold: thresholds.maxExposurePenalty)
        let lossOverflow = overflowRatio(input.transportSignals.lossRate, threshold: thresholds.maxUploadLossRate)
        let evidenceInvariantOverflow = overflowRatio(
            Double(max(0, input.evidenceSignals.invariantViolationCount)),
            threshold: Double(thresholds.maxEvidenceInvariantViolations)
        )
        let byzantineUnderflow = underflowRatio(
            input.transportSignals.byzantineCoverage,
            threshold: thresholds.minUploadByzantineCoverage
        )
        let uploadMerkleUnderflow = underflowRatio(
            input.transportSignals.merkleProofSuccessRate,
            threshold: thresholds.minUploadMerkleProofSuccessRate
        )
        let popUnderflow = underflowRatio(
            input.transportSignals.proofOfPossessionSuccessRate,
            threshold: thresholds.minUploadPoPSuccessRate
        )
        let hmacMismatchOverflow = overflowRatio(
            input.transportSignals.chunkHmacMismatchRate,
            threshold: thresholds.maxUploadHmacMismatchRate
        )
        let bindingConsistencyPenalty = overflowRatio(
            triTetMeasuredRatio * (1.0 - input.evidenceSignals.triTetBindingCoverage),
            threshold: max(0.01, 1.0 - thresholds.minTriTetBindingCoverage)
        )
        let replayConsistencyPenalty = overflowRatio(
            (1.0 - input.evidenceSignals.replayStableRate) * (1.0 + rejectRatio),
            threshold: max(0.01, 1.0 - thresholds.minEvidenceReplayStableRate)
        )
        let uploadStressPenalty = overflowRatio(
            input.transportSignals.circuitBreakerOpenRatio
                + input.transportSignals.retryExhaustionRate
                + input.transportSignals.resumeCorruptionRate,
            threshold: thresholds.maxUploadCircuitBreakerOpenRatio
                + thresholds.maxUploadRetryExhaustionRate
                + thresholds.maxUploadResumeCorruptionRate
        )
        let crossValidationSupportPenalty = underflowRatio(Double(crossValidationSampleCount), threshold: 4.0)
        let interDomainDivergencePenalty = clamp01(
            abs(components.geometry - components.evidence) * 0.45
                + abs(components.crossValidation - components.capture) * 0.30
                + abs(components.security - components.transport) * 0.25
        )
        let tamperSignalsPresent =
            input.securitySignals.debuggerDetected
            || input.securitySignals.environmentTampered
            || !input.securitySignals.telemetryHmacValid
            || input.securitySignals.certificatePinMismatchCount > 0
        let uploadAuthenticityDegraded =
            input.transportSignals.chunkHmacMismatchRate > thresholds.maxUploadHmacMismatchRate
            || input.transportSignals.merkleProofSuccessRate < thresholds.minUploadMerkleProofSuccessRate
            || input.transportSignals.proofOfPossessionSuccessRate < thresholds.minUploadPoPSuccessRate
            || input.transportSignals.byzantineCoverage < thresholds.minUploadByzantineCoverage
        let tamperChainPenalty = (tamperSignalsPresent && uploadAuthenticityDegraded) ? 1.0 : 0.0

        let riskScore = clamp01(
            (1.0 - fusionScore) * 0.45
                + triTetUnknownRatio * 0.08
                + rejectRatio * 0.08
                + motionOverflow * 0.05
                + exposureOverflow * 0.04
                + lossOverflow * 0.03
                + evidenceInvariantOverflow * 0.04
                + byzantineUnderflow * 0.03
                + uploadMerkleUnderflow * 0.03
                + popUnderflow * 0.02
                + hmacMismatchOverflow * 0.02
                + bindingConsistencyPenalty * 0.03
                + replayConsistencyPenalty * 0.03
                + uploadStressPenalty * 0.02
                + crossValidationSupportPenalty * 0.03
                + interDomainDivergencePenalty * 0.04
                + tamperChainPenalty * 0.03
                + securityPenalty * 0.18
        )

        var reasons: [String] = []
        if triTetMeasuredRatio < thresholds.minTriTetMeasuredRatio {
            reasons.append("FUSION_TRI_TET_MEASURED_RATIO_LOW")
        }
        if crossValidationStats.keepRatio < thresholds.minCrossValidationKeepRatio {
            reasons.append("FUSION_CROSS_VALIDATION_KEEP_RATIO_LOW")
        }
        if crossValidationSupportPenalty > 0.5 {
            reasons.append("FUSION_CROSS_VALIDATION_SUPPORT_LOW")
        }
        if crossValidationStats.rejectCount > 0 {
            reasons.append("FUSION_CROSS_VALIDATION_REJECT_PRESENT")
        }
        if input.captureSignals.motionScore > thresholds.maxMotionScore {
            reasons.append("FUSION_CAPTURE_MOTION_EXCEEDED")
        }
        if exposurePenalty > thresholds.maxExposurePenalty {
            reasons.append("FUSION_CAPTURE_EXPOSURE_PENALTY_EXCEEDED")
        }
        if input.evidenceSignals.coverageScore < thresholds.minCoverageScore {
            reasons.append("FUSION_EVIDENCE_COVERAGE_LOW")
        }
        if input.evidenceSignals.persistentPizRegionCount > thresholds.maxPersistentPizRegions {
            reasons.append("FUSION_EVIDENCE_PIZ_PERSISTENCE_EXCEEDED")
        }
        if input.evidenceSignals.invariantViolationCount > thresholds.maxEvidenceInvariantViolations {
            reasons.append("FUSION_EVIDENCE_INVARIANT_VIOLATION_EXCEEDED")
        }
        if input.evidenceSignals.replayStableRate < thresholds.minEvidenceReplayStableRate {
            reasons.append("FUSION_EVIDENCE_REPLAY_STABILITY_LOW")
        }
        if input.evidenceSignals.triTetBindingCoverage < thresholds.minTriTetBindingCoverage {
            reasons.append("FUSION_EVIDENCE_TRI_TET_BINDING_COVERAGE_LOW")
        }
        if bindingConsistencyPenalty > 0.5 {
            reasons.append("FUSION_EVIDENCE_TRI_TET_BINDING_INCONSISTENT")
        }
        if input.evidenceSignals.merkleProofCoverage < thresholds.minEvidenceMerkleProofCoverage {
            reasons.append("FUSION_EVIDENCE_MERKLE_COVERAGE_LOW")
        }
        if replayConsistencyPenalty > 0.5 {
            reasons.append("FUSION_EVIDENCE_REPLAY_CV_INCONSISTENT")
        }
        if input.evidenceSignals.occlusionExcludedAreaRatio > thresholds.maxEvidenceOcclusionExcludedRatio {
            reasons.append("FUSION_EVIDENCE_OCCLUSION_EXCLUDED_RATIO_HIGH")
        }
        if input.evidenceSignals.provenanceGapCount > thresholds.maxEvidenceProvenanceGapCount {
            reasons.append("FUSION_EVIDENCE_PROVENANCE_GAP_EXCEEDED")
        }
        if input.transportSignals.lossRate > thresholds.maxUploadLossRate {
            reasons.append("FUSION_TRANSPORT_LOSS_EXCEEDED")
        }
        if input.transportSignals.rttMs > thresholds.maxUploadRTTMs {
            reasons.append("FUSION_TRANSPORT_RTT_EXCEEDED")
        }
        if input.transportSignals.byzantineCoverage < thresholds.minUploadByzantineCoverage {
            reasons.append("FUSION_UPLOAD_BYZANTINE_COVERAGE_LOW")
        }
        if input.transportSignals.merkleProofSuccessRate < thresholds.minUploadMerkleProofSuccessRate {
            reasons.append("FUSION_UPLOAD_MERKLE_PROOF_SUCCESS_LOW")
        }
        if input.transportSignals.proofOfPossessionSuccessRate < thresholds.minUploadPoPSuccessRate {
            reasons.append("FUSION_UPLOAD_POP_SUCCESS_LOW")
        }
        if input.transportSignals.chunkHmacMismatchRate > thresholds.maxUploadHmacMismatchRate {
            reasons.append("FUSION_UPLOAD_HMAC_MISMATCH_HIGH")
        }
        if input.transportSignals.circuitBreakerOpenRatio > thresholds.maxUploadCircuitBreakerOpenRatio {
            reasons.append("FUSION_UPLOAD_CIRCUIT_BREAKER_OPEN_HIGH")
        }
        if input.transportSignals.retryExhaustionRate > thresholds.maxUploadRetryExhaustionRate {
            reasons.append("FUSION_UPLOAD_RETRY_EXHAUSTION_HIGH")
        }
        if input.transportSignals.resumeCorruptionRate > thresholds.maxUploadResumeCorruptionRate {
            reasons.append("FUSION_UPLOAD_RESUME_CORRUPTION_HIGH")
        }
        if uploadStressPenalty > 0.5 {
            reasons.append("FUSION_UPLOAD_STRESS_COMPOUND_HIGH")
        }
        if interDomainDivergencePenalty > 0.5 {
            reasons.append("FUSION_INTERDOMAIN_DIVERGENCE_HIGH")
        }
        if tamperChainPenalty > 0 {
            reasons.append("FUSION_SECURITY_TRANSPORT_TAMPER_CHAIN")
        }
        if input.securitySignals.certificatePinMismatchCount > thresholds.maxCertificatePinMismatchCount {
            reasons.append("FUSION_SECURITY_CERT_PIN_MISMATCH_EXCEEDED")
        }
        if !input.securitySignals.bootChainValidated {
            reasons.append("FUSION_SECURITY_BOOT_CHAIN_FAILED")
        }
        if input.securitySignals.requestSignerValidRate < thresholds.minRequestSignerValidRate {
            reasons.append("FUSION_SECURITY_REQUEST_SIGNER_VALID_RATE_LOW")
        }
        if securityPenalty > thresholds.maxSecurityPenalty {
            reasons.append("FUSION_SECURITY_PENALTY_EXCEEDED")
        }
        if fusionMaturityScore < 0.5 {
            reasons.append("FUSION_MATURITY_LOW")
        }
        if fusionScore < adaptiveMinFusionScore {
            reasons.append("FUSION_SCORE_LOW")
        }
        if riskScore > adaptiveMaxRiskScore {
            reasons.append("FUSION_RISK_HIGH")
        }

        return GeometryMLFusionResult(
            passes: reasons.isEmpty,
            fusionScore: fusionScore,
            riskScore: riskScore,
            securityPenalty: securityPenalty,
            triTetMeasuredRatio: triTetMeasuredRatio,
            triTetUnknownRatio: triTetUnknownRatio,
            crossValidationKeepRatio: crossValidationStats.keepRatio,
            captureExposurePenalty: exposurePenalty,
            componentScores: components,
            crossValidationStats: crossValidationStats,
            reasonCodes: reasons
        )
    }

    private static func triTetStats(_ input: GeometryMLFusionInput) -> (measuredRatio: Double, unknownRatio: Double, combinedScore: Double) {
        guard let report = input.triTetReport else {
            let unknownRatio = clamp01(input.runtimeMetrics.unknownVoxelRatio)
            let measuredRatio = clamp01(1.0 - unknownRatio)
            return (measuredRatio, unknownRatio, measuredRatio * 0.9)
        }

        let total = report.measuredCount + report.estimatedCount + report.unknownCount
        guard total > 0 else {
            return (0, 1, 0)
        }

        let measuredRatio = Double(report.measuredCount) / Double(total)
        let unknownRatio = Double(report.unknownCount) / Double(total)
        return (clamp01(measuredRatio), clamp01(unknownRatio), clamp01(Double(report.combinedScore)))
    }

    private static func evaluateCrossValidation(
        outlierOutcomes: [CrossValidationOutcome],
        calibrationOutcomes: [CrossValidationOutcome]
    ) -> GeometryMLCrossValidationStats {
        let outcomes = outlierOutcomes + calibrationOutcomes

        let keepCount = outcomes.filter { $0.decision == .keep }.count
        let downgradeCount = outcomes.filter { $0.decision == .downgrade }.count
        let rejectCount = outcomes.filter { $0.decision == .reject }.count
        let keepRatio: Double
        if outcomes.isEmpty {
            keepRatio = 1.0
        } else {
            keepRatio = Double(keepCount) / Double(outcomes.count)
        }

        return GeometryMLCrossValidationStats(
            keepCount: keepCount,
            downgradeCount: downgradeCount,
            rejectCount: rejectCount,
            keepRatio: clamp01(keepRatio)
        )
    }

    private static func evaluateCapture(
        runtimeMetrics: PureVisionRuntimeMetrics,
        captureSignals: GeometryMLCaptureSignals,
        exposurePenalty: Double,
        thresholds: PureVisionGeometryMLThresholds
    ) -> Double {
        let blurScore = normalizeHigherIsBetter(
            runtimeMetrics.blurLaplacian,
            min: CoreBlurThresholds.frameRejection * 0.7,
            max: CoreBlurThresholds.frameRejection * 1.6
        )

        let featureScore = normalizeHigherIsBetter(
            Double(runtimeMetrics.orbFeatures),
            min: Double(FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM),
            max: Double(FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM) * 2.0
        )

        let parallaxScore = normalizeHigherIsBetter(
            runtimeMetrics.parallaxRatio,
            min: PureVisionRuntimeConstants.K_OBS_REQ_PARALLAX_RATIO,
            max: min(1.0, PureVisionRuntimeConstants.K_OBS_REQ_PARALLAX_RATIO * 2.0)
        )

        let motionScore = normalizeLowerIsBetter(
            captureSignals.motionScore,
            min: 0,
            max: thresholds.maxMotionScore
        )

        let exposureScore = normalizeLowerIsBetter(
            exposurePenalty,
            min: 0,
            max: thresholds.maxExposurePenalty
        )

        let thermalScore = normalizeLowerIsBetter(
            runtimeMetrics.thermalCelsius,
            min: 20.0,
            max: ThermalConstants.thermalCriticalC
        )
        let baselineScore = normalizeHigherIsBetter(
            runtimeMetrics.baselinePixels,
            min: PureVisionRuntimeConstants.K_OBS_MIN_BASELINE_PIXELS,
            max: PureVisionRuntimeConstants.K_OBS_MIN_BASELINE_PIXELS * 3.0
        )
        let depthSigmaScore = normalizeLowerIsBetter(
            runtimeMetrics.depthSigmaMeters,
            min: 0.0,
            max: PureVisionRuntimeConstants.K_OBS_SIGMA_Z_TARGET_M * 1.5
        )

        return clamp01(
            blurScore * 0.18
                + featureScore * 0.18
                + parallaxScore * 0.15
                + motionScore * 0.12
                + exposureScore * 0.12
                + thermalScore * 0.07
                + baselineScore * 0.10
                + depthSigmaScore * 0.08
        )
    }

    private static func evaluateEvidence(
        runtimeMetrics: PureVisionRuntimeMetrics,
        evidenceSignals: GeometryMLEvidenceSignals,
        thresholds: PureVisionGeometryMLThresholds
    ) -> Double {
        let coverageScore = clamp01(evidenceSignals.coverageScore)
        let softEvidenceScore = clamp01(evidenceSignals.softEvidenceScore)
        let replayStabilityScore = clamp01(evidenceSignals.replayStableRate)
        let triTetBindingScore = clamp01(evidenceSignals.triTetBindingCoverage)
        let evidenceMerkleScore = clamp01(evidenceSignals.merkleProofCoverage)

        let pizScore = normalizeLowerIsBetter(
            Double(max(0, evidenceSignals.persistentPizRegionCount)),
            min: 0,
            max: Double(max(1, thresholds.maxPersistentPizRegions))
        )
        let invariantScore = normalizeLowerIsBetter(
            Double(max(0, evidenceSignals.invariantViolationCount)),
            min: 0,
            max: Double(thresholds.maxEvidenceInvariantViolations)
        )
        let occlusionScore = normalizeLowerIsBetter(
            evidenceSignals.occlusionExcludedAreaRatio,
            min: 0,
            max: thresholds.maxEvidenceOcclusionExcludedRatio
        )
        let provenanceScore = normalizeLowerIsBetter(
            Double(max(0, evidenceSignals.provenanceGapCount)),
            min: 0,
            max: Double(thresholds.maxEvidenceProvenanceGapCount)
        )

        let closureScore = normalizeHigherIsBetter(
            runtimeMetrics.closureRatio,
            min: PureVisionRuntimeConstants.K_VOLUME_CLOSURE_RATIO_MIN,
            max: 1.0
        )

        let unknownVoxelScore = normalizeLowerIsBetter(
            runtimeMetrics.unknownVoxelRatio,
            min: 0,
            max: PureVisionRuntimeConstants.K_VOLUME_UNKNOWN_VOXEL_MAX * 2.0
        )

        return clamp01(
            coverageScore * 0.20
                + softEvidenceScore * 0.12
                + pizScore * 0.10
                + closureScore * 0.10
                + unknownVoxelScore * 0.10
                + replayStabilityScore * 0.12
                + triTetBindingScore * 0.10
                + evidenceMerkleScore * 0.08
                + invariantScore * 0.05
                + occlusionScore * 0.02
                + provenanceScore * 0.01
        )
    }

    private static func evaluateTransport(
        transportSignals: GeometryMLTransportSignals,
        thresholds: PureVisionGeometryMLThresholds,
        uploadThresholds: PureVisionUploadCDCThresholds
    ) -> Double {
        let bandwidthScore = normalizeHigherIsBetter(
            transportSignals.bandwidthMbps,
            min: UploadConstants.NETWORK_SPEED_SLOW_MBPS,
            max: UploadConstants.NETWORK_SPEED_FAST_MBPS
        )

        let rttScore = normalizeLowerIsBetter(
            transportSignals.rttMs,
            min: 25,
            max: thresholds.maxUploadRTTMs
        )

        let lossScore = normalizeLowerIsBetter(
            transportSignals.lossRate,
            min: 0,
            max: thresholds.maxUploadLossRate
        )

        let chunkScore: Double
        if uploadThresholds.minChunkSize <= transportSignals.chunkSizeBytes
            && transportSignals.chunkSizeBytes <= uploadThresholds.maxChunkSize {
            chunkScore = 1.0
        } else {
            chunkScore = 0.2
        }

        let dedupScore = normalizeHigherIsBetter(
            transportSignals.dedupSavingsRatio,
            min: uploadThresholds.dedupMinSavingsRatio * 0.7,
            max: max(uploadThresholds.dedupMinSavingsRatio, uploadThresholds.dedupMinSavingsRatio + 0.15)
        )

        let compressionScore = normalizeHigherIsBetter(
            transportSignals.compressionSavingsRatio,
            min: uploadThresholds.compressionMinSavingsRatio * 0.7,
            max: max(uploadThresholds.compressionMinSavingsRatio, uploadThresholds.compressionMinSavingsRatio + 0.10)
        )
        let byzantineCoverageScore = clamp01(transportSignals.byzantineCoverage)
        let merkleProofScore = clamp01(transportSignals.merkleProofSuccessRate)
        let popScore = clamp01(transportSignals.proofOfPossessionSuccessRate)
        let hmacMismatchScore = normalizeLowerIsBetter(
            transportSignals.chunkHmacMismatchRate,
            min: 0,
            max: thresholds.maxUploadHmacMismatchRate
        )
        let circuitBreakerScore = normalizeLowerIsBetter(
            transportSignals.circuitBreakerOpenRatio,
            min: 0,
            max: thresholds.maxUploadCircuitBreakerOpenRatio
        )
        let retryExhaustionScore = normalizeLowerIsBetter(
            transportSignals.retryExhaustionRate,
            min: 0,
            max: thresholds.maxUploadRetryExhaustionRate
        )
        let resumeCorruptionScore = normalizeLowerIsBetter(
            transportSignals.resumeCorruptionRate,
            min: 0,
            max: thresholds.maxUploadResumeCorruptionRate
        )

        return clamp01(
            bandwidthScore * 0.14
                + rttScore * 0.12
                + lossScore * 0.12
                + chunkScore * 0.08
                + dedupScore * 0.08
                + compressionScore * 0.06
                + byzantineCoverageScore * 0.12
                + merkleProofScore * 0.10
                + popScore * 0.08
                + hmacMismatchScore * 0.04
                + circuitBreakerScore * 0.03
                + retryExhaustionScore * 0.02
                + resumeCorruptionScore * 0.01
        )
    }

    private static func evaluateSecurityPenalty(_ signals: GeometryMLSecuritySignals) -> Double {
        var penalty = 0.0

        if !signals.codeSignatureValid {
            penalty += 0.35
        }
        if !signals.runtimeIntegrityValid {
            penalty += 0.30
        }
        if !signals.telemetryHmacValid {
            penalty += 0.20
        }
        if signals.debuggerDetected {
            penalty += 0.20
        }
        if signals.environmentTampered {
            penalty += 0.25
        }
        if signals.certificatePinMismatchCount > 0 {
            penalty += min(0.30, Double(signals.certificatePinMismatchCount) * 0.10)
        }
        if !signals.bootChainValidated {
            penalty += 0.25
        }
        penalty += (1.0 - clamp01(signals.requestSignerValidRate)) * 0.25
        if !signals.secureEnclaveAvailable {
            penalty += 0.05
        }

        return clamp01(penalty)
    }

    private static func captureExposurePenalty(_ captureSignals: GeometryMLCaptureSignals) -> Double {
        let blownRegionPenalty = captureSignals.hasLargeBlownRegion ? 0.15 : 0.0
        return clamp01(captureSignals.overexposureRatio + captureSignals.underexposureRatio + blownRegionPenalty)
    }

    private static func totalCrossValidationCount(_ stats: GeometryMLCrossValidationStats) -> Int {
        stats.keepCount + stats.downgradeCount + stats.rejectCount
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private static func normalizeHigherIsBetter(_ value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return value >= max ? 1.0 : 0.0 }
        return clamp01((value - min) / (max - min))
    }

    private static func normalizeLowerIsBetter(_ value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return value <= min ? 1.0 : 0.0 }
        return clamp01((max - value) / (max - min))
    }

    private static func overflowRatio(_ value: Double, threshold: Double) -> Double {
        guard threshold > 0 else {
            return value > 0 ? 1.0 : 0.0
        }
        return max(0, value - threshold) / threshold
    }

    private static func underflowRatio(_ value: Double, threshold: Double) -> Double {
        guard threshold > 0 else {
            return 0
        }
        return max(0, threshold - value) / threshold
    }
}
