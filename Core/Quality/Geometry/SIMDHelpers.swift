//
// SIMDHelpers.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Cross-platform SIMD helpers
// On Apple platforms, simd provides normalize(), cross(), dot(), length().
// On Linux, swift-numerics lacks these free functions.
// This file provides cross-platform inline replacements.
//

import Foundation

// MARK: - Cross-platform SIMD helpers

/// Dot product of two SIMD3<Float> vectors
@inline(__always)
internal func simdDot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
}

/// Squared length of a SIMD3<Float> vector
@inline(__always)
internal func simdLengthSquared(_ v: SIMD3<Float>) -> Float {
    simdDot(v, v)
}

/// Length (magnitude) of a SIMD3<Float> vector
@inline(__always)
internal func simdLength(_ v: SIMD3<Float>) -> Float {
    sqrt(simdLengthSquared(v))
}

/// Normalize a SIMD3<Float> vector to unit length
/// Returns zero vector if input is near-zero
@inline(__always)
internal func simdNormalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = simdLength(v)
    guard len > 1e-10 else { return SIMD3<Float>(0, 0, 0) }
    return v / len
}

/// Cross product of two SIMD3<Float> vectors
@inline(__always)
internal func simdCross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
}
