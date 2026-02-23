// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class NativeRenderStabilityBridgeTests: XCTestCase {
    private func approx(_ lhs: Float, _ rhs: Float, eps: Float = 1e-5) -> Bool {
        abs(lhs - rhs) <= eps
    }

    func testMeshStabilityRejectsNegativeStalenessThreshold() {
        let bridge = NativeRenderStabilityBridge()
        let queries = [MeshStabilityQuery(blockX: 0, blockY: 0, blockZ: 0, lastMeshGeneration: 0)]
        let result = bridge.queryMeshStability(
            queries,
            currentFrame: 1,
            graceFrames: 5,
            stalenessThresholdS: -0.1
        )
        XCTAssertNil(result)
    }

    func testMeshStabilityReturnsBoundedFields() {
        let bridge = NativeRenderStabilityBridge()
        let queries = [
            MeshStabilityQuery(blockX: 0, blockY: 0, blockZ: 0, lastMeshGeneration: 0),
            MeshStabilityQuery(blockX: 1, blockY: -1, blockZ: 2, lastMeshGeneration: 3)
        ]
        let result = bridge.queryMeshStability(
            queries,
            currentFrame: 10,
            graceFrames: 8,
            stalenessThresholdS: 5.0
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, queries.count)
        for item in result ?? [] {
            XCTAssertGreaterThanOrEqual(item.fadeInAlpha, 0)
            XCTAssertLessThanOrEqual(item.fadeInAlpha, 1)
            XCTAssertGreaterThanOrEqual(item.evictionWeight, 0)
            XCTAssertLessThanOrEqual(item.evictionWeight, 1)
        }
    }

    func testConfidenceDecayRejectsMismatchedFrustumCount() {
        let bridge = NativeRenderStabilityBridge()
        let samples = [
            ConfidenceDecaySample(id: 1, opacity: 0.8, uncertainty: 0.4),
            ConfidenceDecaySample(id: 2, opacity: 0.3, uncertainty: 0.7)
        ]
        let result = bridge.decayConfidence(
            samples,
            inCurrentFrustum: [true],
            currentFrame: 10,
            config: ConfidenceDecayConfig()
        )
        XCTAssertNil(result)
    }

    func testConfidenceDecayMatchesExpectedUpdatePattern() {
        let bridge = NativeRenderStabilityBridge()
        let config = ConfidenceDecayConfig(
            decayPerFrame: 0.2,
            minConfidence: 0.0,
            observationBoost: 0.1,
            maxConfidence: 1.0,
            graceFrames: 1
        )
        var samples = [
            ConfidenceDecaySample(id: 900001, opacity: 0.8, uncertainty: 0.41),
            ConfidenceDecaySample(id: 900002, opacity: 0.25, uncertainty: 0.73)
        ]

        samples = bridge.decayConfidence(
            samples,
            inCurrentFrustum: [false, true],
            currentFrame: 100,
            config: config
        ) ?? []
        XCTAssertEqual(samples.count, 2)
        XCTAssertTrue(approx(samples[0].opacity, 0.8))
        XCTAssertTrue(approx(samples[1].opacity, 0.35))

        samples = bridge.decayConfidence(
            samples,
            inCurrentFrustum: [false, false],
            currentFrame: 102,
            config: config
        ) ?? []
        XCTAssertTrue(approx(samples[0].opacity, 0.6))
        XCTAssertTrue(approx(samples[1].opacity, 0.15))

        samples = bridge.decayConfidence(
            samples,
            inCurrentFrustum: [true, false],
            currentFrame: 103,
            config: config
        ) ?? []
        XCTAssertTrue(approx(samples[0].opacity, 0.7))
        XCTAssertTrue(approx(samples[1].opacity, 0.0))
        XCTAssertTrue(approx(samples[0].uncertainty, 0.41))
        XCTAssertTrue(approx(samples[1].uncertainty, 0.73))
    }

    func testPatchIdentityMatchingSnapsLowDisplayObservations() {
        let bridge = NativeRenderStabilityBridge()
        let anchors = [
            PatchIdentitySample(
                patchKey: 111,
                centroid: SIMD3<Float>(0.0, 0.0, 0.0),
                display: 0.9
            ),
            PatchIdentitySample(
                patchKey: 222,
                centroid: SIMD3<Float>(0.6, 0.0, 0.0),
                display: 0.95
            )
        ]
        let observations = [
            PatchIdentitySample(
                patchKey: 1001,
                centroid: SIMD3<Float>(0.01, 0.0, 0.0),
                display: 0.01
            ),
            PatchIdentitySample(
                patchKey: 1002,
                centroid: SIMD3<Float>(0.58, 0.0, 0.0),
                display: 0.02
            ),
            PatchIdentitySample(
                patchKey: 1003,
                centroid: SIMD3<Float>(0.20, 0.0, 0.0),
                display: 0.4
            )
        ]

        let resolved = bridge.matchPatchIdentities(
            observations: observations,
            anchors: anchors,
            lockDisplayThreshold: 0.05,
            snapDistanceM: 0.05,
            cellSizeM: 0.02
        )
        XCTAssertEqual(resolved, [111, 222, 1003])
    }

    func testStableRenderSelectionDeterministicOrderWhenUnderBudget() {
        let bridge = NativeRenderStabilityBridge()
        let candidates = [
            RenderTriangleCandidate(
                patchKey: 30,
                centroid: SIMD3<Float>(0.0, 0.0, 0.0),
                display: 0.1,
                stabilityFadeAlpha: 0,
                residencyUntilFrame: 0
            ),
            RenderTriangleCandidate(
                patchKey: 10,
                centroid: SIMD3<Float>(0.0, 0.0, 0.0),
                display: 0.1,
                stabilityFadeAlpha: 0,
                residencyUntilFrame: 0
            ),
            RenderTriangleCandidate(
                patchKey: 20,
                centroid: SIMD3<Float>(0.0, 0.0, 0.0),
                display: 0.1,
                stabilityFadeAlpha: 0,
                residencyUntilFrame: 0
            )
        ]
        let selected = bridge.selectStableRenderTriangles(
            candidates: candidates,
            config: RenderSelectionConfig(
                currentFrame: 0,
                maxTriangles: 8,
                cameraPosition: SIMD3<Float>(0, 0, 0)
            )
        )
        XCTAssertEqual(selected, [1, 2, 0])
    }

    func testRenderSnapshotNeverRegressesBelowBaseDisplay() {
        let bridge = NativeRenderStabilityBridge()
        let samples = [
            RenderSnapshotSample(
                baseDisplay: 0.9,
                confidenceDisplay: 0.95,
                hasStability: true,
                fadeInAlpha: 0.1,
                evictionWeight: 0.1
            ),
            RenderSnapshotSample(
                baseDisplay: 0.6,
                confidenceDisplay: 0.9,
                hasStability: true,
                fadeInAlpha: 0.5,
                evictionWeight: 0.5
            ),
            RenderSnapshotSample(
                baseDisplay: 0.2,
                confidenceDisplay: 0.6,
                hasStability: false,
                fadeInAlpha: 0,
                evictionWeight: 0
            )
        ]
        let output = bridge.computeRenderSnapshot(
            samples,
            s3ToS4Threshold: 0.75,
            s4ToS5Threshold: 0.88
        )
        XCTAssertEqual(output?.count, 3)
        XCTAssertEqual(output?[0] ?? -1, 0.95, accuracy: 1e-6)
        XCTAssertEqual(output?[1] ?? -1, 0.6, accuracy: 1e-6)
        XCTAssertEqual(output?[2] ?? -1, 0.6, accuracy: 1e-6)
    }
}
