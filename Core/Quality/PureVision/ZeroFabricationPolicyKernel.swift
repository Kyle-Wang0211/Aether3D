// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// ML actions routed through the zero-fabrication policy kernel.
public enum MLActionType: String, Codable, Sendable {
    case calibrationCorrection
    case multiViewDenoise
    case outlierRejection
    case confidenceEstimation
    case uncertaintyEstimation
    case textureInpaint
    case holeFilling
    case geometryCompletion
    case unknownRegionGrowth
}

/// Confidence class used by policy decisions.
public enum ReconstructionConfidenceClass: String, Codable, Sendable {
    case measured
    case estimated
    case unknown
}

public enum PolicySeverity: String, Codable, Sendable {
    case info
    case warn
    case block
}

public struct ZeroFabricationContext: Codable, Sendable {
    public let confidenceClass: ReconstructionConfidenceClass
    public let hasDirectObservation: Bool
    public let requestedPointDisplacementMeters: Float
    public let requestedNewGeometryCount: Int

    public init(
        confidenceClass: ReconstructionConfidenceClass,
        hasDirectObservation: Bool,
        requestedPointDisplacementMeters: Float = 0,
        requestedNewGeometryCount: Int = 0
    ) {
        self.confidenceClass = confidenceClass
        self.hasDirectObservation = hasDirectObservation
        self.requestedPointDisplacementMeters = requestedPointDisplacementMeters
        self.requestedNewGeometryCount = requestedNewGeometryCount
    }
}

public struct ZeroFabricationDecision: Codable, Sendable {
    public let allowed: Bool
    public let reasonCode: String
    public let severity: PolicySeverity

    public init(allowed: Bool, reasonCode: String, severity: PolicySeverity) {
        self.allowed = allowed
        self.reasonCode = reasonCode
        self.severity = severity
    }
}

/// Runtime policy kernel that turns "zero fabrication" principles into executable guards.
public struct ZeroFabricationPolicyKernel: Sendable {
    public enum Mode: String, Codable, Sendable {
        case forensicStrict
        case researchRelaxed
    }

    public let mode: Mode
    public let maxDenoiseDisplacementMeters: Float

    public init(mode: Mode = .forensicStrict, maxDenoiseDisplacementMeters: Float = 0.0) {
        self.mode = mode
        self.maxDenoiseDisplacementMeters = maxDenoiseDisplacementMeters
    }

    public func evaluate(action: MLActionType, context: ZeroFabricationContext) -> ZeroFabricationDecision {
        if let native = NativePureVisionRuntimeBridge.evaluateZeroFabrication(
            mode: mode,
            maxDenoiseDisplacementMeters: maxDenoiseDisplacementMeters,
            action: action,
            context: context
        ) {
            return native
        }
        return evaluateSwift(action: action, context: context)
    }

    private func evaluateSwift(action: MLActionType, context: ZeroFabricationContext) -> ZeroFabricationDecision {
        switch action {
        case .textureInpaint, .holeFilling, .geometryCompletion:
            return .init(
                allowed: false,
                reasonCode: "ZERO_FAB_BLOCK_GENERATIVE_ACTION",
                severity: .block
            )
        case .unknownRegionGrowth:
            if context.confidenceClass == .unknown || !context.hasDirectObservation {
                return .init(
                    allowed: false,
                    reasonCode: "ZERO_FAB_BLOCK_UNKNOWN_GROWTH",
                    severity: .block
                )
            }
            return .init(allowed: true, reasonCode: "ALLOW_OBSERVED_GROWTH", severity: .info)
        case .multiViewDenoise:
            if mode == .forensicStrict && context.requestedPointDisplacementMeters > 0 {
                return .init(
                    allowed: false,
                    reasonCode: "ZERO_FAB_BLOCK_COORDINATE_REWRITE",
                    severity: .block
                )
            }
            if context.requestedPointDisplacementMeters > maxDenoiseDisplacementMeters {
                return .init(
                    allowed: false,
                    reasonCode: "ZERO_FAB_DENOISE_DISPLACEMENT_EXCEEDS_POLICY",
                    severity: .block
                )
            }
            return .init(allowed: true, reasonCode: "ALLOW_DENOISE", severity: .info)
        case .outlierRejection:
            return .init(allowed: true, reasonCode: "ALLOW_OUTLIER_REJECTION", severity: .info)
        case .calibrationCorrection, .confidenceEstimation, .uncertaintyEstimation:
            return .init(allowed: true, reasonCode: "ALLOW_NON_GENERATIVE_CALIBRATION", severity: .info)
        }
    }
}

