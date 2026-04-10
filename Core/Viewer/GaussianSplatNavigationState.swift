// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import simd

public enum ViewerNavigationMode: String, CaseIterable, Sendable {
    case automatic
    case orbit
}

public struct GaussianSplatNavigationState: Sendable {

    public struct OrbitState: Sendable, Equatable {
        public var target: SIMD3<Float>
        public var distance: Float
        public var azimuth: Float
        public var pitch: Float
        public var roll: Float

        public init(
            target: SIMD3<Float>,
            distance: Float,
            azimuth: Float,
            pitch: Float,
            roll: Float = 0.0
        ) {
            self.target = target
            self.distance = distance
            self.azimuth = azimuth
            self.pitch = pitch
            self.roll = roll
        }
    }


    public struct CameraPose: Sendable, Equatable {
        public let eye: SIMD3<Float>
        public let center: SIMD3<Float>
        public let forward: SIMD3<Float>
        public let up: SIMD3<Float>
        public let right: SIMD3<Float>
    }

    public static let defaultFovY: Float = .pi / 3.0
    public static let defaultPitchDownRadians: Float = 0.25
    public static let maxLookPitchRadians: Float = (.pi / 2.0) - 0.18
    public static let softLookPitchZoneRadians: Float = 0.16
    public static let canonicalWorldUp = SIMD3<Float>(0, 1, 0)
    public static let orbitSensitivity: Float = 0.006

    public private(set) var sceneCenter = SIMD3<Float>(repeating: 0)
    public private(set) var sceneRadius: Float = 1.0
    public private(set) var sceneUpAxis = GaussianSplatNavigationState.canonicalWorldUp

    public private(set) var orbit: OrbitState
    public private(set) var defaultOrbit: OrbitState

    public private(set) var requestedNavigationMode: ViewerNavigationMode = .orbit
    public private(set) var defaultNavigationMode: ViewerNavigationMode = .orbit
    public private(set) var activeNavigationMode: ViewerNavigationMode = .orbit

    public init() {
        let orbit = OrbitState(target: .zero, distance: 3.0, azimuth: 0.0, pitch: 0.0, roll: 0.0)
        self.orbit = orbit
        self.defaultOrbit = orbit
    }

    public mutating func configureScene(
        center: SIMD3<Float>,
        radius: Float,
        up: SIMD3<Float>
    ) {
        sceneCenter = center
        sceneRadius = max(radius, 0.001)
        sceneUpAxis = Self.leveledVerticalAxis(matching: up)
    }

    public mutating func configureDefaults(
        target: SIMD3<Float>,
        distance: Float,
        azimuth: Float,
        pitch: Float,
        roll: Float = 0.0,
        suggestedMode: ViewerNavigationMode
    ) {
        let clampedDistance = max(distance, 0.05)
        defaultOrbit = OrbitState(
            target: target,
            distance: clampedDistance,
            azimuth: azimuth,
            pitch: Self.softClampedPitchRadians(pitch),
            roll: roll
        )
        _ = suggestedMode
        defaultNavigationMode = .orbit
        resetToDefaults()
    }

    public mutating func configureSuggestedMode(_ mode: ViewerNavigationMode) {
        defaultNavigationMode = .orbit
        activeNavigationMode = .orbit
    }

    public mutating func resetToDefaults() {
        orbit = defaultOrbit
        requestedNavigationMode = .orbit
        activeNavigationMode = .orbit
    }

    public mutating func setRequestedNavigationMode(_ mode: ViewerNavigationMode) {
        _ = mode
        requestedNavigationMode = .orbit
        activeNavigationMode = .orbit
    }

    public mutating func applySingleFingerDrag(screenTranslation: SIMD2<Float>) {
        let delta = orbitGestureDelta(from: screenTranslation)
        activeNavigationMode = .orbit
        // USER-LOCKED ORBIT SEMANTICS:
        // - single-finger swipe left  => object rotates left
        // - single-finger swipe right => object rotates right
        // This sign has been explicitly user-validated. Do not flip it again
        // unless the user explicitly re-confirms that change.
        orbit.azimuth += delta.x
        orbit.pitch = Self.softClampedPitchRadians(orbit.pitch - delta.y)
    }

    public mutating func applyTwoFingerPan(
        screenTranslation: SIMD2<Float>,
        viewportSize: SIMD2<Float>
    ) {
        activeNavigationMode = .orbit
        let pose = cameraPose
        let scale = worldUnitsPerScreenPoint(viewportSize: viewportSize)
        orbit.target += (-screenTranslation.x * scale) * pose.right
        orbit.target += (screenTranslation.y * scale) * pose.up
    }

    public mutating func applyPinch(scale: Float, velocity: Float) {
        activeNavigationMode = .orbit
        let velocityBoost = min(max(abs(velocity) * 0.08, 0.0), 0.35)
        let normalizedDistance = orbit.distance / max(sceneRadius, 0.001)
        let closeRangeBoost = max(0.0, min(1.0, (0.9 - normalizedDistance) / 0.9))
        let zoomExponent = 1.0 + closeRangeBoost * 1.95 + velocityBoost
        let orbitScale = pow(max(scale, 0.01), zoomExponent)
        orbit.distance /= orbitScale
        let maxDistance = max(sceneRadius * 8.0, 100.0)
        orbit.distance = max(0.05, min(maxDistance, orbit.distance))
    }

    public mutating func applyTwoFingerRotation(rotationRadians: Float) {
        activeNavigationMode = .orbit
        // Match direct-manipulation semantics so the scene appears to twist
        // with the user's two-finger rotation.
        orbit.roll -= rotationRadians
    }

    public var cameraPose: CameraPose {
        let sceneUp = Self.leveledVerticalAxis(matching: sceneUpAxis)
        let forward = Self.forwardVector(
            azimuth: orbit.azimuth,
            pitch: orbit.pitch,
            sceneUp: sceneUp
        )
        let right = Self.normalizedOrFallback(
            simd_cross(forward, sceneUp),
            fallback: SIMD3<Float>(1, 0, 0)
        )
        let up = Self.normalizedOrFallback(
            simd_cross(right, forward),
            fallback: sceneUp
        )
        let rolledBasis: (right: SIMD3<Float>, up: SIMD3<Float>)
        if abs(orbit.roll) > 1e-5 {
            let rollRotation = simd_quatf(angle: orbit.roll, axis: forward)
            rolledBasis = (
                right: Self.normalizedOrFallback(rollRotation.act(right), fallback: right),
                up: Self.normalizedOrFallback(rollRotation.act(up), fallback: up)
            )
        } else {
            rolledBasis = (right, up)
        }
        let eye = orbit.target - forward * orbit.distance
        return CameraPose(
            eye: eye,
            center: orbit.target,
            forward: forward,
            up: rolledBasis.up,
            right: rolledBasis.right
        )
    }

    public var currentNearPlaneDistance: Float {
        let referenceDistance = orbit.distance
        let scaledNear = referenceDistance * 0.02
        return max(0.001, min(0.01, scaledNear))
    }

    public var currentPitchDegrees: Float {
        orbit.pitch * 180.0 / .pi
    }

    public var activeDistanceToSceneCenter: Float {
        orbit.distance
    }

    public func worldUnitsPerScreenPoint(viewportSize: SIMD2<Float>) -> Float {
        let width = max(viewportSize.x, 1.0)
        let height = max(viewportSize.y, 1.0)
        let referenceDimension = max(min(width, height), 1.0)
        let referenceDistance = orbit.distance
        let frustumHeight = 2.0 * referenceDistance * tan(Self.defaultFovY * 0.5)
        return frustumHeight / referenceDimension
    }


    private func orbitGestureDelta(from screenTranslation: SIMD2<Float>) -> SIMD2<Float> {
        return SIMD2<Float>(
            screenTranslation.x * Self.orbitSensitivity,
            screenTranslation.y * Self.orbitSensitivity * (
                simd_dot(
                    Self.leveledVerticalAxis(matching: sceneUpAxis),
                    Self.canonicalWorldUp
                ) >= 0 ? 1.0 : -1.0
            )
        )
    }


    private static func forwardVector(
        azimuth: Float,
        pitch: Float,
        sceneUp: SIMD3<Float>
    ) -> SIMD3<Float> {
        let referenceForward = fallbackHorizontalForward(for: sceneUp)
        let horizontalForward = orbitHorizontalForward(
            azimuth: azimuth,
            sceneUp: sceneUp,
            referenceForward: referenceForward
        )
        return normalizedOrFallback(
            horizontalForward * cos(pitch) - sceneUp * sin(pitch),
            fallback: SIMD3<Float>(0, 0, -1)
        )
    }

    public static func leveledVerticalAxis(matching vector: SIMD3<Float>) -> SIMD3<Float> {
        let normalized = normalizedOrFallback(vector, fallback: canonicalWorldUp)
        let sign: Float = simd_dot(normalized, canonicalWorldUp) >= 0 ? 1.0 : -1.0
        return canonicalWorldUp * sign
    }

    public static func softClampedPitchRadians(_ requestedPitch: Float) -> Float {
        let hardLimit = maxLookPitchRadians
        let softStart = max(0.0, hardLimit - softLookPitchZoneRadians)
        let sign: Float = requestedPitch >= 0 ? 1.0 : -1.0
        let magnitude = abs(requestedPitch)
        if magnitude <= softStart {
            return requestedPitch
        }

        let overflow = magnitude - softStart
        let softRange = max(hardLimit - softStart, 1e-4)
        let compressedOverflow = softRange * tanh(overflow / softRange)
        return sign * min(hardLimit, softStart + compressedOverflow)
    }

    private static func fallbackHorizontalForward(for up: SIMD3<Float>) -> SIMD3<Float> {
        let legacyForward = normalizedOrFallback(
            simd_quatf(angle: -defaultPitchDownRadians, axis: SIMD3<Float>(1, 0, 0)).act(SIMD3<Float>(0, 0, -1)),
            fallback: SIMD3<Float>(0, 0, -1)
        )
        var candidate = legacyForward - simd_dot(legacyForward, up) * up
        if simd_length_squared(candidate) < 1e-6 {
            candidate = SIMD3<Float>(0, 0, -1) - simd_dot(SIMD3<Float>(0, 0, -1), up) * up
        }
        if simd_length_squared(candidate) < 1e-6 {
            candidate = SIMD3<Float>(1, 0, 0) - simd_dot(SIMD3<Float>(1, 0, 0), up) * up
        }
        return normalizedOrFallback(candidate, fallback: SIMD3<Float>(0, 0, -1))
    }

    private static func orbitHorizontalForward(
        azimuth: Float,
        sceneUp: SIMD3<Float>,
        referenceForward: SIMD3<Float>
    ) -> SIMD3<Float> {
        let yawRotation = simd_quatf(
            angle: azimuth,
            axis: normalizedOrFallback(sceneUp, fallback: canonicalWorldUp)
        )
        return normalizedOrFallback(yawRotation.act(referenceForward), fallback: referenceForward)
    }

    private static func normalizedOrFallback(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        if lengthSquared < 1e-8 {
            return simd_normalize(fallback)
        }
        return simd_normalize(vector)
    }
}
