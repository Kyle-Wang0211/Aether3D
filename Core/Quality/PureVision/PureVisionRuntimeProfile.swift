// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

public enum PureVisionRuntimeProfile: String, CaseIterable, Codable, Sendable {
    case forensic
    case balanced
    case speed

    public static let environmentVariable = "AETHER_RUNTIME_PROFILE"
    public static let defaultProfile: PureVisionRuntimeProfile = .balanced

    public static func resolveCurrent(processInfo: ProcessInfo = .processInfo) -> PureVisionRuntimeProfile {
        guard let raw = processInfo.environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return defaultProfile
        }
        return PureVisionRuntimeProfile(rawValue: raw.lowercased()) ?? defaultProfile
    }
}

public struct PureVisionTriTetThresholds: Codable, Sendable, Equatable {
    public let measuredMinViewCount: Int
    public let estimatedMinViewCount: Int
    public let maxTriangleToTetDistance: Float
    public let maxUnknownRatio: Float

    public init(
        measuredMinViewCount: Int,
        estimatedMinViewCount: Int,
        maxTriangleToTetDistance: Float,
        maxUnknownRatio: Float
    ) {
        self.measuredMinViewCount = measuredMinViewCount
        self.estimatedMinViewCount = estimatedMinViewCount
        self.maxTriangleToTetDistance = maxTriangleToTetDistance
        self.maxUnknownRatio = maxUnknownRatio
    }
}

public struct PureVisionFirstScanTargets: Codable, Sendable, Equatable {
    public let targetSuccessRate: Double
    public let targetReplayStableRate: Double
    public let targetDurationSeconds: Double
    public let hardCapSeconds: Double

    public init(
        targetSuccessRate: Double,
        targetReplayStableRate: Double,
        targetDurationSeconds: Double,
        hardCapSeconds: Double
    ) {
        self.targetSuccessRate = targetSuccessRate
        self.targetReplayStableRate = targetReplayStableRate
        self.targetDurationSeconds = targetDurationSeconds
        self.hardCapSeconds = hardCapSeconds
    }
}

public struct PureVisionCrossValidationThresholds: Codable, Sendable, Equatable {
    public let outlierMlInlierThreshold: Double
    public let calibrationMaxAllowedErrorCm: Double
    public let calibrationMaxDivergenceCm: Double

    public init(
        outlierMlInlierThreshold: Double,
        calibrationMaxAllowedErrorCm: Double,
        calibrationMaxDivergenceCm: Double
    ) {
        self.outlierMlInlierThreshold = outlierMlInlierThreshold
        self.calibrationMaxAllowedErrorCm = calibrationMaxAllowedErrorCm
        self.calibrationMaxDivergenceCm = calibrationMaxDivergenceCm
    }
}

public struct PureVisionUploadCDCThresholds: Codable, Sendable, Equatable {
    public let minChunkSize: Int
    public let avgChunkSize: Int
    public let maxChunkSize: Int
    public let dedupMinSavingsRatio: Double
    public let compressionMinSavingsRatio: Double

    public init(
        minChunkSize: Int,
        avgChunkSize: Int,
        maxChunkSize: Int,
        dedupMinSavingsRatio: Double,
        compressionMinSavingsRatio: Double
    ) {
        self.minChunkSize = minChunkSize
        self.avgChunkSize = avgChunkSize
        self.maxChunkSize = maxChunkSize
        self.dedupMinSavingsRatio = dedupMinSavingsRatio
        self.compressionMinSavingsRatio = compressionMinSavingsRatio
    }
}

public struct PureVisionGeometryMLThresholds: Codable, Sendable, Equatable {
    public let minFusionScore: Double
    public let maxRiskScore: Double
    public let minTriTetMeasuredRatio: Double
    public let minCrossValidationKeepRatio: Double
    public let maxMotionScore: Double
    public let maxExposurePenalty: Double
    public let minCoverageScore: Double
    public let maxPersistentPizRegions: Int
    public let maxEvidenceInvariantViolations: Int
    public let minEvidenceReplayStableRate: Double
    public let minTriTetBindingCoverage: Double
    public let minEvidenceMerkleProofCoverage: Double
    public let maxEvidenceOcclusionExcludedRatio: Double
    public let maxEvidenceProvenanceGapCount: Int
    public let maxUploadLossRate: Double
    public let maxUploadRTTMs: Double
    public let minUploadByzantineCoverage: Double
    public let minUploadMerkleProofSuccessRate: Double
    public let minUploadPoPSuccessRate: Double
    public let maxUploadHmacMismatchRate: Double
    public let maxUploadCircuitBreakerOpenRatio: Double
    public let maxUploadRetryExhaustionRate: Double
    public let maxUploadResumeCorruptionRate: Double
    public let maxCertificatePinMismatchCount: Int
    public let minRequestSignerValidRate: Double
    public let maxSecurityPenalty: Double

    public init(
        minFusionScore: Double,
        maxRiskScore: Double,
        minTriTetMeasuredRatio: Double,
        minCrossValidationKeepRatio: Double,
        maxMotionScore: Double,
        maxExposurePenalty: Double,
        minCoverageScore: Double,
        maxPersistentPizRegions: Int,
        maxEvidenceInvariantViolations: Int,
        minEvidenceReplayStableRate: Double,
        minTriTetBindingCoverage: Double,
        minEvidenceMerkleProofCoverage: Double,
        maxEvidenceOcclusionExcludedRatio: Double,
        maxEvidenceProvenanceGapCount: Int,
        maxUploadLossRate: Double,
        maxUploadRTTMs: Double,
        minUploadByzantineCoverage: Double,
        minUploadMerkleProofSuccessRate: Double,
        minUploadPoPSuccessRate: Double,
        maxUploadHmacMismatchRate: Double,
        maxUploadCircuitBreakerOpenRatio: Double,
        maxUploadRetryExhaustionRate: Double,
        maxUploadResumeCorruptionRate: Double,
        maxCertificatePinMismatchCount: Int,
        minRequestSignerValidRate: Double,
        maxSecurityPenalty: Double
    ) {
        self.minFusionScore = minFusionScore
        self.maxRiskScore = maxRiskScore
        self.minTriTetMeasuredRatio = minTriTetMeasuredRatio
        self.minCrossValidationKeepRatio = minCrossValidationKeepRatio
        self.maxMotionScore = maxMotionScore
        self.maxExposurePenalty = maxExposurePenalty
        self.minCoverageScore = minCoverageScore
        self.maxPersistentPizRegions = maxPersistentPizRegions
        self.maxEvidenceInvariantViolations = maxEvidenceInvariantViolations
        self.minEvidenceReplayStableRate = minEvidenceReplayStableRate
        self.minTriTetBindingCoverage = minTriTetBindingCoverage
        self.minEvidenceMerkleProofCoverage = minEvidenceMerkleProofCoverage
        self.maxEvidenceOcclusionExcludedRatio = maxEvidenceOcclusionExcludedRatio
        self.maxEvidenceProvenanceGapCount = maxEvidenceProvenanceGapCount
        self.maxUploadLossRate = maxUploadLossRate
        self.maxUploadRTTMs = maxUploadRTTMs
        self.minUploadByzantineCoverage = minUploadByzantineCoverage
        self.minUploadMerkleProofSuccessRate = minUploadMerkleProofSuccessRate
        self.minUploadPoPSuccessRate = minUploadPoPSuccessRate
        self.maxUploadHmacMismatchRate = maxUploadHmacMismatchRate
        self.maxUploadCircuitBreakerOpenRatio = maxUploadCircuitBreakerOpenRatio
        self.maxUploadRetryExhaustionRate = maxUploadRetryExhaustionRate
        self.maxUploadResumeCorruptionRate = maxUploadResumeCorruptionRate
        self.maxCertificatePinMismatchCount = maxCertificatePinMismatchCount
        self.minRequestSignerValidRate = minRequestSignerValidRate
        self.maxSecurityPenalty = maxSecurityPenalty
    }
}

public struct PureVisionGeometryMLWeights: Codable, Sendable, Equatable {
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

public struct PureVisionRuntimeProfileConfig: Codable, Sendable, Equatable {
    public let profile: PureVisionRuntimeProfile
    public let triTet: PureVisionTriTetThresholds
    public let firstScan: PureVisionFirstScanTargets
    public let crossValidation: PureVisionCrossValidationThresholds
    public let uploadCDC: PureVisionUploadCDCThresholds
    public let geometryML: PureVisionGeometryMLThresholds
    public let geometryMLWeights: PureVisionGeometryMLWeights

    public init(
        profile: PureVisionRuntimeProfile,
        triTet: PureVisionTriTetThresholds,
        firstScan: PureVisionFirstScanTargets,
        crossValidation: PureVisionCrossValidationThresholds,
        uploadCDC: PureVisionUploadCDCThresholds,
        geometryML: PureVisionGeometryMLThresholds,
        geometryMLWeights: PureVisionGeometryMLWeights
    ) {
        self.profile = profile
        self.triTet = triTet
        self.firstScan = firstScan
        self.crossValidation = crossValidation
        self.uploadCDC = uploadCDC
        self.geometryML = geometryML
        self.geometryMLWeights = geometryMLWeights
    }

    public static func current(processInfo: ProcessInfo = .processInfo) -> PureVisionRuntimeProfileConfig {
        config(for: PureVisionRuntimeProfile.resolveCurrent(processInfo: processInfo))
    }

    public static func config(for profile: PureVisionRuntimeProfile) -> PureVisionRuntimeProfileConfig {
        switch profile {
        case .forensic:
            return .init(
                profile: .forensic,
                triTet: .init(
                    measuredMinViewCount: 5,
                    estimatedMinViewCount: 3,
                    maxTriangleToTetDistance: 0.06,
                    maxUnknownRatio: 0.17
                ),
                firstScan: .init(
                    targetSuccessRate: 0.98,
                    targetReplayStableRate: 1.0,
                    targetDurationSeconds: 170.0,
                    hardCapSeconds: 900.0
                ),
                crossValidation: .init(
                    outlierMlInlierThreshold: 0.75,
                    calibrationMaxAllowedErrorCm: 0.8,
                    calibrationMaxDivergenceCm: 0.25
                ),
                uploadCDC: .init(
                    minChunkSize: 512 * 1024,
                    avgChunkSize: 2 * 1024 * 1024,
                    maxChunkSize: 5_242_880,
                    dedupMinSavingsRatio: 0.25,
                    compressionMinSavingsRatio: 0.15
                ),
                geometryML: .init(
                    minFusionScore: 0.80,
                    maxRiskScore: 0.18,
                    minTriTetMeasuredRatio: 0.60,
                    minCrossValidationKeepRatio: 0.85,
                    maxMotionScore: 0.50,
                    maxExposurePenalty: 0.28,
                    minCoverageScore: 0.85,
                    maxPersistentPizRegions: 2,
                    maxEvidenceInvariantViolations: 0,
                    minEvidenceReplayStableRate: 0.995,
                    minTriTetBindingCoverage: 0.95,
                    minEvidenceMerkleProofCoverage: 0.98,
                    maxEvidenceOcclusionExcludedRatio: 0.22,
                    maxEvidenceProvenanceGapCount: 0,
                    maxUploadLossRate: 0.03,
                    maxUploadRTTMs: 250,
                    minUploadByzantineCoverage: 0.99,
                    minUploadMerkleProofSuccessRate: 0.99,
                    minUploadPoPSuccessRate: 0.995,
                    maxUploadHmacMismatchRate: 0.002,
                    maxUploadCircuitBreakerOpenRatio: 0.02,
                    maxUploadRetryExhaustionRate: 0.01,
                    maxUploadResumeCorruptionRate: 0.005,
                    maxCertificatePinMismatchCount: 0,
                    minRequestSignerValidRate: 0.995,
                    maxSecurityPenalty: 0.10
                ),
                geometryMLWeights: .init(
                    geometry: 0.30,
                    crossValidation: 0.22,
                    capture: 0.20,
                    evidence: 0.14,
                    transport: 0.09,
                    security: 0.05
                )
            )
        case .balanced:
            return .init(
                profile: .balanced,
                triTet: .init(
                    measuredMinViewCount: 4,
                    estimatedMinViewCount: 2,
                    maxTriangleToTetDistance: 0.10,
                    maxUnknownRatio: 0.18
                ),
                firstScan: .init(
                    targetSuccessRate: 0.95,
                    targetReplayStableRate: 1.0,
                    targetDurationSeconds: 170.0,
                    hardCapSeconds: 900.0
                ),
                crossValidation: .init(
                    outlierMlInlierThreshold: 0.65,
                    calibrationMaxAllowedErrorCm: 1.0,
                    calibrationMaxDivergenceCm: 0.35
                ),
                uploadCDC: .init(
                    minChunkSize: 256 * 1024,
                    avgChunkSize: 2 * 1024 * 1024,
                    maxChunkSize: 5_242_880,
                    dedupMinSavingsRatio: 0.20,
                    compressionMinSavingsRatio: 0.10
                ),
                geometryML: .init(
                    minFusionScore: 0.72,
                    maxRiskScore: 0.26,
                    minTriTetMeasuredRatio: 0.45,
                    minCrossValidationKeepRatio: 0.70,
                    maxMotionScore: 0.60,
                    maxExposurePenalty: 0.35,
                    minCoverageScore: 0.75,
                    maxPersistentPizRegions: 3,
                    maxEvidenceInvariantViolations: 1,
                    minEvidenceReplayStableRate: 0.99,
                    minTriTetBindingCoverage: 0.90,
                    minEvidenceMerkleProofCoverage: 0.95,
                    maxEvidenceOcclusionExcludedRatio: 0.30,
                    maxEvidenceProvenanceGapCount: 1,
                    maxUploadLossRate: 0.05,
                    maxUploadRTTMs: 400,
                    minUploadByzantineCoverage: 0.95,
                    minUploadMerkleProofSuccessRate: 0.97,
                    minUploadPoPSuccessRate: 0.98,
                    maxUploadHmacMismatchRate: 0.01,
                    maxUploadCircuitBreakerOpenRatio: 0.08,
                    maxUploadRetryExhaustionRate: 0.03,
                    maxUploadResumeCorruptionRate: 0.015,
                    maxCertificatePinMismatchCount: 1,
                    minRequestSignerValidRate: 0.98,
                    maxSecurityPenalty: 0.20
                ),
                geometryMLWeights: .init(
                    geometry: 0.28,
                    crossValidation: 0.22,
                    capture: 0.20,
                    evidence: 0.15,
                    transport: 0.10,
                    security: 0.05
                )
            )
        case .speed:
            return .init(
                profile: .speed,
                triTet: .init(
                    measuredMinViewCount: 3,
                    estimatedMinViewCount: 2,
                    maxTriangleToTetDistance: 0.12,
                    maxUnknownRatio: 0.22
                ),
                firstScan: .init(
                    targetSuccessRate: 0.92,
                    targetReplayStableRate: 0.99,
                    targetDurationSeconds: 180.0,
                    hardCapSeconds: 900.0
                ),
                crossValidation: .init(
                    outlierMlInlierThreshold: 0.60,
                    calibrationMaxAllowedErrorCm: 1.2,
                    calibrationMaxDivergenceCm: 0.45
                ),
                uploadCDC: .init(
                    minChunkSize: 256 * 1024,
                    avgChunkSize: 4 * 1024 * 1024,
                    maxChunkSize: 5_242_880,
                    dedupMinSavingsRatio: 0.15,
                    compressionMinSavingsRatio: 0.08
                ),
                geometryML: .init(
                    minFusionScore: 0.66,
                    maxRiskScore: 0.34,
                    minTriTetMeasuredRatio: 0.35,
                    minCrossValidationKeepRatio: 0.58,
                    maxMotionScore: 0.72,
                    maxExposurePenalty: 0.45,
                    minCoverageScore: 0.65,
                    maxPersistentPizRegions: 5,
                    maxEvidenceInvariantViolations: 2,
                    minEvidenceReplayStableRate: 0.97,
                    minTriTetBindingCoverage: 0.82,
                    minEvidenceMerkleProofCoverage: 0.90,
                    maxEvidenceOcclusionExcludedRatio: 0.38,
                    maxEvidenceProvenanceGapCount: 2,
                    maxUploadLossRate: 0.08,
                    maxUploadRTTMs: 650,
                    minUploadByzantineCoverage: 0.90,
                    minUploadMerkleProofSuccessRate: 0.92,
                    minUploadPoPSuccessRate: 0.94,
                    maxUploadHmacMismatchRate: 0.02,
                    maxUploadCircuitBreakerOpenRatio: 0.15,
                    maxUploadRetryExhaustionRate: 0.06,
                    maxUploadResumeCorruptionRate: 0.03,
                    maxCertificatePinMismatchCount: 2,
                    minRequestSignerValidRate: 0.95,
                    maxSecurityPenalty: 0.28
                ),
                geometryMLWeights: .init(
                    geometry: 0.25,
                    crossValidation: 0.20,
                    capture: 0.20,
                    evidence: 0.15,
                    transport: 0.15,
                    security: 0.05
                )
            )
        }
    }
}
