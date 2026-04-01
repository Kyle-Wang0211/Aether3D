// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
import simd
@testable import Aether3DCore

final class GaussianSplatNavigationStateTests: XCTestCase {

  func test_orbitHorizontalDragIsReversibleForCanonicalUp() {
    var state = makeOrbitState(up: SIMD3<Float>(0, 1, 0))

    state.applySingleFingerDrag(screenTranslation: SIMD2<Float>(-120, 0))
    XCTAssertLessThan(state.orbit.azimuth, 0)

    state.applySingleFingerDrag(screenTranslation: SIMD2<Float>(120, 0))
    XCTAssertEqual(state.orbit.azimuth, 0, accuracy: 0.0001)
    XCTAssertEqual(state.currentPitchDegrees, 0, accuracy: 0.0001)
  }

  func test_orbitHorizontalDragPreservesScreenDirectionForInvertedUp() {
    var uprightState = makeOrbitState(up: SIMD3<Float>(0, 1, 0))
    var invertedState = makeOrbitState(up: SIMD3<Float>(0, -1, 0))

    let initialUprightEye = uprightState.cameraPose.eye
    let initialInvertedEye = invertedState.cameraPose.eye

    uprightState.applySingleFingerDrag(screenTranslation: SIMD2<Float>(-120, 0))
    invertedState.applySingleFingerDrag(screenTranslation: SIMD2<Float>(-120, 0))

    let uprightDeltaX = uprightState.cameraPose.eye.x - initialUprightEye.x
    let invertedDeltaX = invertedState.cameraPose.eye.x - initialInvertedEye.x

    XCTAssertNotEqual(uprightDeltaX, 0, accuracy: 0.0001)
    XCTAssertNotEqual(invertedDeltaX, 0, accuracy: 0.0001)
    XCTAssertEqual(uprightDeltaX.sign, invertedDeltaX.sign)
    XCTAssertLessThan(uprightDeltaX, 0)
  }

  func test_orbitVerticalDragIsReversibleForModerateMotion() {
    var state = makeOrbitState(up: SIMD3<Float>(0, 1, 0))

    state.applySingleFingerDrag(screenTranslation: SIMD2<Float>(0, -120))
    XCTAssertGreaterThan(state.currentPitchDegrees, 0)

    state.applySingleFingerDrag(screenTranslation: SIMD2<Float>(0, 120))
    XCTAssertEqual(state.currentPitchDegrees, 0, accuracy: 0.0001)
  }

  func test_orbitPitchIsSoftClampedBeforeDegenerateExtremes() {
    var state = makeOrbitState(up: SIMD3<Float>(0, 1, 0))

    state.applySingleFingerDrag(screenTranslation: SIMD2<Float>(0, -100_000))

    XCTAssertLessThanOrEqual(abs(state.currentPitchDegrees), 85.0)
    XCTAssertGreaterThan(abs(state.currentPitchDegrees), 70.0)
  }

  func test_orbitGesturesKeepProductPathInOrbitMode() {
    var state = makeOrbitState(up: SIMD3<Float>(0, 1, 0))

    state.applySingleFingerDrag(screenTranslation: SIMD2<Float>(-80, 40))
    state.applyTwoFingerPan(
      screenTranslation: SIMD2<Float>(30, -20),
      viewportSize: SIMD2<Float>(1179, 2556)
    )
    state.applyPinch(scale: 1.2, velocity: 0.0)

    XCTAssertEqual(state.activeNavigationMode, .orbit)
    XCTAssertEqual(state.requestedNavigationMode, .orbit)
  }

  func test_orbitPanOnlyMovesTarget() {
    var state = makeOrbitState(up: SIMD3<Float>(0, 1, 0))
    let orbitBefore = state.orbit

    state.applyTwoFingerPan(
      screenTranslation: SIMD2<Float>(60, -30),
      viewportSize: SIMD2<Float>(1179, 2556)
    )

    XCTAssertNotEqual(state.orbit.target, orbitBefore.target)
    XCTAssertEqual(state.orbit.distance, orbitBefore.distance, accuracy: 0.0001)
    XCTAssertEqual(state.orbit.azimuth, orbitBefore.azimuth, accuracy: 0.0001)
    XCTAssertEqual(state.orbit.pitch, orbitBefore.pitch, accuracy: 0.0001)
  }

  func test_orbitPinchOnlyChangesDistance() {
    var state = makeOrbitState(up: SIMD3<Float>(0, 1, 0))
    let orbitBefore = state.orbit

    state.applyPinch(scale: 1.2, velocity: 0.0)

    XCTAssertNotEqual(state.orbit.distance, orbitBefore.distance, accuracy: 0.0001)
    XCTAssertEqual(state.orbit.target, orbitBefore.target)
    XCTAssertEqual(state.orbit.azimuth, orbitBefore.azimuth, accuracy: 0.0001)
    XCTAssertEqual(state.orbit.pitch, orbitBefore.pitch, accuracy: 0.0001)
  }

  private func makeOrbitState(up: SIMD3<Float>) -> GaussianSplatNavigationState {
    var state = GaussianSplatNavigationState()
    state.configureScene(center: .zero, radius: 5.0, up: up)
    state.configureDefaults(
      target: .zero,
      distance: 10.0,
      azimuth: 0.0,
      pitch: 0.0,
      suggestedMode: .orbit
    )
    state.setRequestedNavigationMode(.orbit)
    return state
  }

}
