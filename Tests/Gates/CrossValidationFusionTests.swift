// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class CrossValidationFusionTests: XCTestCase {
    func testOutlierRejectRequiresDualAgreement() {
        let thresholds = PureVisionRuntimeProfileConfig.config(for: .balanced).crossValidation
        let bothReject = OutlierCrossValidationInput(
            ruleInlier: false,
            mlInlierScore: 0.1,
            mlInlierThreshold: thresholds.outlierMlInlierThreshold
        )
        XCTAssertEqual(CrossValidationFusion.evaluateOutlier(bothReject).decision, .reject)

        let disagreement = OutlierCrossValidationInput(
            ruleInlier: false,
            mlInlierScore: 0.9,
            mlInlierThreshold: thresholds.outlierMlInlierThreshold
        )
        XCTAssertEqual(CrossValidationFusion.evaluateOutlier(disagreement).decision, .downgrade)
    }

    func testOutlierKeepWhenBothAgreeInlier() {
        let thresholds = PureVisionRuntimeProfileConfig.config(for: .balanced).crossValidation
        let input = OutlierCrossValidationInput(
            ruleInlier: true,
            mlInlierScore: 0.9,
            mlInlierThreshold: thresholds.outlierMlInlierThreshold
        )
        let outcome = CrossValidationFusion.evaluateOutlier(input)
        XCTAssertEqual(outcome.decision, .keep)
        XCTAssertEqual(outcome.reasonCode, "OUTLIER_BOTH_INLIER")
    }

    func testCalibrationDecisionMatrix() {
        let thresholds = PureVisionRuntimeProfileConfig.config(for: .balanced).crossValidation
        let bothGood = CalibrationCrossValidationInput(
            baselineErrorCm: 0.6 * thresholds.calibrationMaxAllowedErrorCm,
            mlErrorCm: 0.8 * thresholds.calibrationMaxAllowedErrorCm,
            maxAllowedErrorCm: thresholds.calibrationMaxAllowedErrorCm,
            maxDivergenceCm: thresholds.calibrationMaxDivergenceCm
        )
        XCTAssertEqual(CrossValidationFusion.evaluateCalibration(bothGood).decision, .keep)

        let bothBad = CalibrationCrossValidationInput(
            baselineErrorCm: thresholds.calibrationMaxAllowedErrorCm * 3.0,
            mlErrorCm: thresholds.calibrationMaxAllowedErrorCm * 2.8,
            maxAllowedErrorCm: thresholds.calibrationMaxAllowedErrorCm,
            maxDivergenceCm: thresholds.calibrationMaxDivergenceCm
        )
        XCTAssertEqual(CrossValidationFusion.evaluateCalibration(bothBad).decision, .reject)

        let divergent = CalibrationCrossValidationInput(
            baselineErrorCm: thresholds.calibrationMaxAllowedErrorCm * 0.4,
            mlErrorCm: thresholds.calibrationMaxAllowedErrorCm * 1.1,
            maxAllowedErrorCm: thresholds.calibrationMaxAllowedErrorCm,
            maxDivergenceCm: thresholds.calibrationMaxDivergenceCm * 0.5
        )
        XCTAssertEqual(CrossValidationFusion.evaluateCalibration(divergent).decision, .downgrade)
    }
}

