// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class PureVisionRuntimeAuditEvaluatorTests: XCTestCase {
    func testPolicyBlockFailsAudit() {
        let input = PureVisionRuntimeAuditInput(
            policyMode: .forensicStrict,
            policyActionAttempts: [
                ZeroFabricationPolicyActionAttempt(
                    action: .holeFilling,
                    context: ZeroFabricationContext(
                        confidenceClass: .unknown,
                        hasDirectObservation: false
                    )
                )
            ]
        )

        let report = PureVisionRuntimeAuditEvaluator.evaluate(input)
        XCTAssertFalse(report.passes)
        XCTAssertEqual(report.blockingReason, "policy_blocked")
        XCTAssertEqual(report.blockedPolicyCount, 1)
    }

    func testTriTetUnknownRatioCanFailAudit() {
        let vertices: [TriTetVertex] = [
            .init(index: 0, position: SIMD3<Float>(0, 0, 0), viewCount: 1),
            .init(index: 1, position: SIMD3<Float>(1, 0, 0), viewCount: 1),
            .init(index: 2, position: SIMD3<Float>(0, 1, 0), viewCount: 1),
            .init(index: 3, position: SIMD3<Float>(1, 1, 0), viewCount: 1),
            .init(index: 4, position: SIMD3<Float>(0, 0, 1), viewCount: 1),
            .init(index: 5, position: SIMD3<Float>(1, 0, 1), viewCount: 1),
            .init(index: 6, position: SIMD3<Float>(0, 1, 1), viewCount: 1),
            .init(index: 7, position: SIMD3<Float>(1, 1, 1), viewCount: 1)
        ]

        let tetrahedra = TriTetConsistencyEngine.kuhn5(parity: 0).enumerated().map {
            TriTetTetrahedron(id: $0.offset, vertices: $0.element)
        }

        let triangle = ScanTriangle(
            patchId: "tri0",
            vertices: (
                SIMD3<Float>(0.05, 0.05, 0.05),
                SIMD3<Float>(0.15, 0.05, 0.05),
                SIMD3<Float>(0.05, 0.15, 0.05)
            ),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.005
        )

        let triTetInput = PureVisionRuntimeTriTetInput(
            triangles: [triangle],
            vertices: vertices,
            tetrahedra: tetrahedra,
            config: TriTetConfig(measuredMinViewCount: 3, estimatedMinViewCount: 2, maxTriangleToTetDistance: 0.5)
        )

        let input = PureVisionRuntimeAuditInput(
            triTetInput: triTetInput,
            thresholds: PureVisionRuntimeAuditThresholds(maxCalibrationRejectCount: 0, maxTriTetUnknownRatio: 0.2)
        )

        let report = PureVisionRuntimeAuditEvaluator.evaluate(input)
        XCTAssertFalse(report.passes)
        XCTAssertEqual(report.blockingReason, "tri_tet_unknown_ratio_exceeded")
        XCTAssertEqual(report.triTetReport?.unknownCount, 1)
    }

    func testFirstScanKPIEvaluatorConsumesRuntimeAudit() {
        let sample = FirstScanReplaySample(
            sessionId: "session-audit-blocked",
            durationSeconds: 90,
            metrics: PureVisionRuntimeMetrics(
                baselinePixels: 10,
                blurLaplacian: max(200, QualityThresholds.laplacianBlurThreshold + 1),
                orbFeatures: max(500, FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM + 10),
                parallaxRatio: max(0.5, PureVisionRuntimeConstants.K_OBS_REQ_PARALLAX_RATIO + 0.01),
                depthSigmaMeters: max(0.001, PureVisionRuntimeConstants.K_OBS_SIGMA_Z_TARGET_M * 0.5),
                closureRatio: max(0.99, PureVisionRuntimeConstants.K_VOLUME_CLOSURE_RATIO_MIN + 0.01),
                unknownVoxelRatio: 0.0,
                thermalCelsius: min(30, ThermalConstants.thermalCriticalC - 1)
            ),
            // Inlined: s4ToS5Threshold = 0.88, s5MinSoftEvidence = 0.75
            guidanceDisplayValue: max(1.0, 0.88 + 0.01),
            softEvidenceValue: max(1.0, 0.75 + 0.01),
            replayHashStable: true
        )

        let audit = PureVisionRuntimeAuditEvaluator.evaluate(
            PureVisionRuntimeAuditInput(
                policyMode: .forensicStrict,
                policyActionAttempts: [
                    ZeroFabricationPolicyActionAttempt(
                        action: .geometryCompletion,
                        context: ZeroFabricationContext(
                            confidenceClass: .unknown,
                            hasDirectObservation: false
                        )
                    )
                ]
            )
        )

        let report = FirstScanKPIEvaluator.evaluate(
            samples: [sample],
            runtimeAuditsBySessionId: [sample.sessionId: audit]
        )

        XCTAssertEqual(report.totalSessions, 1)
        XCTAssertEqual(report.firstScanSuccessRate, 0.0)
        XCTAssertFalse(report.passesGate)
        XCTAssertEqual(report.failureReasons["ml_audit_failed:policy_blocked"], 1)
    }
}
