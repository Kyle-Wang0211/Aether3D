// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
import simd
@testable import Aether3DCore

final class GaussianSplatTwoFingerGestureTransformTests: XCTestCase {

    func test_translationOnlyProducesCentroidDelta() {
        let previous = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(0, 0),
            second: SIMD2<Float>(20, 0)
        )
        let current = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(12, -6),
            second: SIMD2<Float>(32, -6)
        )

        let delta = GaussianSplatTwoFingerGestureTransform.delta(from: previous, to: current)

        XCTAssertEqual(delta.centroidTranslation.x, 12, accuracy: 0.0001)
        XCTAssertEqual(delta.centroidTranslation.y, -6, accuracy: 0.0001)
        XCTAssertEqual(delta.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(delta.rotationRadians, 0, accuracy: 0.0001)
    }

    func test_pinchOnlyProducesScale() {
        let previous = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(-10, 0),
            second: SIMD2<Float>(10, 0)
        )
        let current = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(-25, 0),
            second: SIMD2<Float>(25, 0)
        )

        let delta = GaussianSplatTwoFingerGestureTransform.delta(from: previous, to: current)

        XCTAssertEqual(delta.centroidTranslation, .zero)
        XCTAssertEqual(delta.scale, 2.5, accuracy: 0.0001)
        XCTAssertEqual(delta.rotationRadians, 0, accuracy: 0.0001)
    }

    func test_rotationOnlyProducesRotation() {
        let previous = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(-10, 0),
            second: SIMD2<Float>(10, 0)
        )
        let current = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(0, -10),
            second: SIMD2<Float>(0, 10)
        )

        let delta = GaussianSplatTwoFingerGestureTransform.delta(from: previous, to: current)

        XCTAssertEqual(delta.centroidTranslation, .zero)
        XCTAssertEqual(delta.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(delta.rotationRadians, .pi / 2.0, accuracy: 0.0001)
    }

    func test_combinedGestureKeepsAllThreeComponents() {
        let previous = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(-10, 0),
            second: SIMD2<Float>(10, 0)
        )
        let current = GaussianSplatTwoFingerGestureSample(
            first: SIMD2<Float>(10, -20),
            second: SIMD2<Float>(30, 20)
        )

        let delta = GaussianSplatTwoFingerGestureTransform.delta(from: previous, to: current)

        XCTAssertEqual(delta.centroidTranslation.x, 20, accuracy: 0.0001)
        XCTAssertEqual(delta.centroidTranslation.y, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(delta.scale, 2.0)
        XCTAssertGreaterThan(delta.rotationRadians, 0.5)
    }
}
