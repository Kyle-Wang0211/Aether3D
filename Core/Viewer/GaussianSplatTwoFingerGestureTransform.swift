// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import simd

public struct GaussianSplatTwoFingerGestureSample: Sendable, Equatable {
    public var first: SIMD2<Float>
    public var second: SIMD2<Float>

    public init(first: SIMD2<Float>, second: SIMD2<Float>) {
        self.first = first
        self.second = second
    }

    public var centroid: SIMD2<Float> {
        (first + second) * 0.5
    }

    public var span: SIMD2<Float> {
        second - first
    }

    public var distance: Float {
        simd_length(span)
    }

    public var angleRadians: Float {
        atan2(span.y, span.x)
    }
}

public struct GaussianSplatTwoFingerGestureTransform: Sendable, Equatable {
    public var centroidTranslation: SIMD2<Float>
    public var scale: Float
    public var rotationRadians: Float

    public init(
        centroidTranslation: SIMD2<Float>,
        scale: Float,
        rotationRadians: Float
    ) {
        self.centroidTranslation = centroidTranslation
        self.scale = scale
        self.rotationRadians = rotationRadians
    }

    public static func delta(
        from previous: GaussianSplatTwoFingerGestureSample,
        to current: GaussianSplatTwoFingerGestureSample
    ) -> GaussianSplatTwoFingerGestureTransform {
        let previousDistance = max(previous.distance, 1e-4)
        let currentDistance = max(current.distance, 1e-4)
        return GaussianSplatTwoFingerGestureTransform(
            centroidTranslation: current.centroid - previous.centroid,
            scale: currentDistance / previousDistance,
            rotationRadians: shortestAngleDelta(
                from: previous.angleRadians,
                to: current.angleRadians
            )
        )
    }

    private static func shortestAngleDelta(from previous: Float, to current: Float) -> Float {
        var delta = current - previous
        while delta > .pi {
            delta -= 2.0 * .pi
        }
        while delta < -.pi {
            delta += 2.0 * .pi
        }
        return delta
    }
}
