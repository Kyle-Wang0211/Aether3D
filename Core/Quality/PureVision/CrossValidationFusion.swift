// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

public enum CrossValidationDecision: String, Codable, Sendable {
    case keep
    case downgrade
    case reject
}

public struct CrossValidationOutcome: Codable, Sendable {
    public let decision: CrossValidationDecision
    public let reasonCode: String

    public init(decision: CrossValidationDecision, reasonCode: String) {
        self.decision = decision
        self.reasonCode = reasonCode
    }
}

public struct OutlierCrossValidationInput: Codable, Sendable {
    public let ruleInlier: Bool
    public let mlInlierScore: Double
    public let mlInlierThreshold: Double

    public init(ruleInlier: Bool, mlInlierScore: Double, mlInlierThreshold: Double) {
        self.ruleInlier = ruleInlier
        self.mlInlierScore = mlInlierScore
        self.mlInlierThreshold = mlInlierThreshold
    }

    public init(
        ruleInlier: Bool,
        mlInlierScore: Double,
        profile: PureVisionRuntimeProfile
    ) {
        let thresholds = PureVisionRuntimeProfileConfig.config(for: profile).crossValidation
        self.init(
            ruleInlier: ruleInlier,
            mlInlierScore: mlInlierScore,
            mlInlierThreshold: thresholds.outlierMlInlierThreshold
        )
    }
}

public struct CalibrationCrossValidationInput: Codable, Sendable {
    public let baselineErrorCm: Double
    public let mlErrorCm: Double
    public let maxAllowedErrorCm: Double
    public let maxDivergenceCm: Double

    public init(
        baselineErrorCm: Double,
        mlErrorCm: Double,
        maxAllowedErrorCm: Double,
        maxDivergenceCm: Double
    ) {
        self.baselineErrorCm = baselineErrorCm
        self.mlErrorCm = mlErrorCm
        self.maxAllowedErrorCm = maxAllowedErrorCm
        self.maxDivergenceCm = maxDivergenceCm
    }

    public init(
        baselineErrorCm: Double,
        mlErrorCm: Double,
        profile: PureVisionRuntimeProfile
    ) {
        let thresholds = PureVisionRuntimeProfileConfig.config(for: profile).crossValidation
        self.init(
            baselineErrorCm: baselineErrorCm,
            mlErrorCm: mlErrorCm,
            maxAllowedErrorCm: thresholds.calibrationMaxAllowedErrorCm,
            maxDivergenceCm: thresholds.calibrationMaxDivergenceCm
        )
    }
}

/// Cross-validation fusion rules for "rule-based + ML" dual-lane verification.
public enum CrossValidationFusion {
    /// Outlier rejection is only permitted when both lanes agree.
    public static func evaluateOutlier(_ input: OutlierCrossValidationInput) -> CrossValidationOutcome {
        if let native = NativePureVisionRuntimeBridge.evaluateOutlier(input) {
            return native
        }

        let mlSaysInlier = input.mlInlierScore >= input.mlInlierThreshold
        if input.ruleInlier && mlSaysInlier {
            return .init(decision: .keep, reasonCode: "OUTLIER_BOTH_INLIER")
        }
        if !input.ruleInlier && !mlSaysInlier {
            return .init(decision: .reject, reasonCode: "OUTLIER_BOTH_REJECT")
        }
        return .init(decision: .downgrade, reasonCode: "OUTLIER_DISAGREEMENT_DOWNGRADE")
    }

    /// Calibration is promoted to measured-grade only when both lanes are good and mutually consistent.
    public static func evaluateCalibration(_ input: CalibrationCrossValidationInput) -> CrossValidationOutcome {
        if let native = NativePureVisionRuntimeBridge.evaluateCalibration(input) {
            return native
        }

        let baselineGood = input.baselineErrorCm <= input.maxAllowedErrorCm
        let mlGood = input.mlErrorCm <= input.maxAllowedErrorCm
        let divergence = abs(input.baselineErrorCm - input.mlErrorCm)
        let consistent = divergence <= input.maxDivergenceCm

        if baselineGood && mlGood && consistent {
            return .init(decision: .keep, reasonCode: "CALIBRATION_BOTH_PASS")
        }
        if !baselineGood && !mlGood {
            return .init(decision: .reject, reasonCode: "CALIBRATION_BOTH_FAIL")
        }
        return .init(decision: .downgrade, reasonCode: "CALIBRATION_DISAGREEMENT_OR_DIVERGENCE")
    }
}

