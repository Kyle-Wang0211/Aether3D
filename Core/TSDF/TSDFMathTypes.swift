// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TSDFMathTypes.swift
// Aether3D
//
// Cross-platform math types for TSDF pipeline.

#if canImport(simd)
import simd
public typealias TSDFFloat3 = SIMD3<Float>
public typealias TSDFFloat4 = SIMD4<Float>
public typealias TSDFMatrix3x3 = simd_float3x3
public typealias TSDFMatrix4x4 = simd_float4x4

extension SIMD3 where Scalar == Float {
    @inlinable public func length() -> Float { simd_length(self) }
    @inlinable public func normalized() -> Self { simd_normalize(self) }
}

extension simd_float4x4 {
    public static let tsdIdentity4x4 = matrix_identity_float4x4
}
extension simd_float3x3 {
    public static let tsdIdentity3x3 = simd_float3x3(
        SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0), SIMD3<Float>(0,0,1))
}

@inlinable public func mix(_ a: TSDFFloat3, _ b: TSDFFloat3, t: Float) -> TSDFFloat3 {
    simd_mix(a, b, TSDFFloat3(repeating: t))
}

@inlinable public func round(_ v: TSDFFloat3) -> TSDFFloat3 {
    TSDFFloat3(v.x.rounded(), v.y.rounded(), v.z.rounded())
}

/// Cross-platform dot product
@inlinable public func dot(_ a: TSDFFloat3, _ b: TSDFFloat3) -> Float {
    simd_dot(a, b)
}

/// Cross-platform cross product
@inlinable public func cross(_ a: TSDFFloat3, _ b: TSDFFloat3) -> TSDFFloat3 {
    simd_cross(a, b)
}

@inlinable public func tsdTranslation(_ m: TSDFMatrix4x4) -> TSDFFloat3 {
    TSDFFloat3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
}
@inlinable public func tsdTransform(_ m: TSDFMatrix4x4, _ v: TSDFFloat3) -> TSDFFloat3 {
    let r = m * SIMD4<Float>(v, 1.0)
    return TSDFFloat3(r.x, r.y, r.z) / r.w
}
@inlinable public func tsdTransform(_ m: TSDFMatrix3x3, _ v: TSDFFloat3) -> TSDFFloat3 {
    m * v
}

@inlinable public func tsdIsFinite(_ v: TSDFFloat3) -> Bool {
    v.x.isFinite && v.y.isFinite && v.z.isFinite
}

@inlinable public func tsdIntrinsicsParameters(_ k: TSDFMatrix3x3) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
    (k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y)
}

@inlinable public func tsdMakeIntrinsicsMatrix(fx: Float, fy: Float, cx: Float, cy: Float) -> TSDFMatrix3x3 {
    TSDFMatrix3x3(
        SIMD3<Float>(fx, 0, 0),
        SIMD3<Float>(0, fy, 0),
        SIMD3<Float>(cx, cy, 1)
    )
}

@inlinable public func tsdMakeRigidTransform(
    rotationColumns: (TSDFFloat3, TSDFFloat3, TSDFFloat3),
    translation: TSDFFloat3
) -> TSDFMatrix4x4 {
    TSDFMatrix4x4(
        SIMD4<Float>(rotationColumns.0.x, rotationColumns.0.y, rotationColumns.0.z, 0),
        SIMD4<Float>(rotationColumns.1.x, rotationColumns.1.y, rotationColumns.1.z, 0),
        SIMD4<Float>(rotationColumns.2.x, rotationColumns.2.y, rotationColumns.2.z, 0),
        SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    )
}

public func tsdInverseIntrinsics(_ k: TSDFMatrix3x3, epsilon: Float = 1e-8) -> TSDFMatrix3x3? {
    let a00 = k.columns.0.x, a01 = k.columns.1.x, a02 = k.columns.2.x
    let a10 = k.columns.0.y, a11 = k.columns.1.y, a12 = k.columns.2.y
    let a20 = k.columns.0.z, a21 = k.columns.1.z, a22 = k.columns.2.z

    let det = a00 * (a11 * a22 - a12 * a21)
        - a01 * (a10 * a22 - a12 * a20)
        + a02 * (a10 * a21 - a11 * a20)

    guard det.isFinite, abs(det) > epsilon else { return nil }
    let invDet = 1.0 / det

    let i00 =  (a11 * a22 - a12 * a21) * invDet
    let i01 = -(a01 * a22 - a02 * a21) * invDet
    let i02 =  (a01 * a12 - a02 * a11) * invDet
    let i10 = -(a10 * a22 - a12 * a20) * invDet
    let i11 =  (a00 * a22 - a02 * a20) * invDet
    let i12 = -(a00 * a12 - a02 * a10) * invDet
    let i20 =  (a10 * a21 - a11 * a20) * invDet
    let i21 = -(a00 * a21 - a01 * a20) * invDet
    let i22 =  (a00 * a11 - a01 * a10) * invDet

    let inverse = TSDFMatrix3x3(
        SIMD3<Float>(i00, i10, i20),
        SIMD3<Float>(i01, i11, i21),
        SIMD3<Float>(i02, i12, i22)
    )
    guard [i00, i01, i02, i10, i11, i12, i20, i21, i22].allSatisfy(\.isFinite) else { return nil }
    return inverse
}

public func tsdInverseRigidTransform(_ m: TSDFMatrix4x4, orthonormalTolerance: Float = 1e-3) -> TSDFMatrix4x4? {
    let c0 = TSDFFloat3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    let c1 = TSDFFloat3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    let c2 = TSDFFloat3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    let t = TSDFFloat3(m.columns.3.x, m.columns.3.y, m.columns.3.z)

    guard tsdIsFinite(c0), tsdIsFinite(c1), tsdIsFinite(c2), tsdIsFinite(t) else { return nil }
    guard abs(m.columns.0.w) <= orthonormalTolerance,
          abs(m.columns.1.w) <= orthonormalTolerance,
          abs(m.columns.2.w) <= orthonormalTolerance,
          abs(m.columns.3.w - 1.0) <= orthonormalTolerance else {
        return nil
    }

    guard abs(c0.length() - 1.0) <= orthonormalTolerance,
          abs(c1.length() - 1.0) <= orthonormalTolerance,
          abs(c2.length() - 1.0) <= orthonormalTolerance,
          abs(dot(c0, c1)) <= orthonormalTolerance,
          abs(dot(c0, c2)) <= orthonormalTolerance,
          abs(dot(c1, c2)) <= orthonormalTolerance else {
        return nil
    }

    let rt = TSDFMatrix3x3(
        SIMD3<Float>(c0.x, c1.x, c2.x),
        SIMD3<Float>(c0.y, c1.y, c2.y),
        SIMD3<Float>(c0.z, c1.z, c2.z)
    )
    let invT = -(rt * t)

    return TSDFMatrix4x4(
        SIMD4<Float>(rt.columns.0.x, rt.columns.0.y, rt.columns.0.z, 0),
        SIMD4<Float>(rt.columns.1.x, rt.columns.1.y, rt.columns.1.z, 0),
        SIMD4<Float>(rt.columns.2.x, rt.columns.2.y, rt.columns.2.z, 0),
        SIMD4<Float>(invT.x, invT.y, invT.z, 1)
    )
}

#else
public struct TSDFFloat3: Sendable, Codable, Equatable, Hashable {
    public var x, y, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    public init(repeating v: Float) { x = v; y = v; z = v }

    @inlinable public static func +(l: Self, r: Self) -> Self { Self(l.x+r.x, l.y+r.y, l.z+r.z) }
    @inlinable public static func -(l: Self, r: Self) -> Self { Self(l.x-r.x, l.y-r.y, l.z-r.z) }
    @inlinable public static func *(l: Self, s: Float) -> Self { Self(l.x*s, l.y*s, l.z*s) }
    @inlinable public static func *(s: Float, r: Self) -> Self { Self(s*r.x, s*r.y, s*r.z) }
    @inlinable public static func /(l: Self, s: Float) -> Self { Self(l.x/s, l.y/s, l.z/s) }

    @inlinable public func length() -> Float { (x*x + y*y + z*z).squareRoot() }
    @inlinable public func normalized() -> Self { let l = length(); return l > 0 ? self / l : .zero }
    public static let zero = Self(0, 0, 0)
}
@inlinable public func dot(_ a: TSDFFloat3, _ b: TSDFFloat3) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }
@inlinable public func cross(_ a: TSDFFloat3, _ b: TSDFFloat3) -> TSDFFloat3 {
    TSDFFloat3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
}
@inlinable public func normalize(_ v: TSDFFloat3) -> TSDFFloat3 { v.normalized() }
@inlinable public func mix(_ a: TSDFFloat3, _ b: TSDFFloat3, t: Float) -> TSDFFloat3 {
    a * (1 - t) + b * t
}
@inlinable public func round(_ v: TSDFFloat3) -> TSDFFloat3 {
    TSDFFloat3(v.x.rounded(), v.y.rounded(), v.z.rounded())
}

public struct TSDFFloat4: Sendable, Codable, Equatable {
    public var x, y, z, w: Float
    public init(_ xyz: TSDFFloat3, _ w: Float) { x = xyz.x; y = xyz.y; z = xyz.z; self.w = w }
}

public struct TSDFMatrix3x3: Sendable, Codable, Equatable {
    public var c0, c1, c2: TSDFFloat3
    public init(c0: TSDFFloat3, c1: TSDFFloat3, c2: TSDFFloat3) { self.c0 = c0; self.c1 = c1; self.c2 = c2 }

    /// BUG-10: Linux compatibility — Apple simd_float3x3 uses .columns tuple
    public var columns: (TSDFFloat3, TSDFFloat3, TSDFFloat3) { (c0, c1, c2) }

    @inlinable public func multiply(_ v: TSDFFloat3) -> TSDFFloat3 {
        TSDFFloat3(dot(TSDFFloat3(c0.x, c1.x, c2.x), v),
                   dot(TSDFFloat3(c0.y, c1.y, c2.y), v),
                   dot(TSDFFloat3(c0.z, c1.z, c2.z), v))
    }

    public static let tsdIdentity3x3 = TSDFMatrix3x3(
        c0: TSDFFloat3(1,0,0), c1: TSDFFloat3(0,1,0), c2: TSDFFloat3(0,0,1))
}

@inlinable public func *(m: TSDFMatrix3x3, v: TSDFFloat3) -> TSDFFloat3 { m.multiply(v) }

public struct TSDFMatrix4x4: Sendable, Codable, Equatable {
    public var c0, c1, c2, c3: TSDFFloat4
    /// BUG-10: Linux compatibility — Apple simd_float4x4 uses .columns tuple
    public var columns: (TSDFFloat4, TSDFFloat4, TSDFFloat4, TSDFFloat4) { (c0, c1, c2, c3) }
    public static let tsdIdentity4x4 = TSDFMatrix4x4(
        c0: TSDFFloat4(TSDFFloat3(1,0,0),0), c1: TSDFFloat4(TSDFFloat3(0,1,0),0),
        c2: TSDFFloat4(TSDFFloat3(0,0,1),0), c3: TSDFFloat4(TSDFFloat3(0,0,0),1))
}

@inlinable public func tsdTranslation(_ m: TSDFMatrix4x4) -> TSDFFloat3 {
    TSDFFloat3(m.c3.x, m.c3.y, m.c3.z)
}
@inlinable public func tsdTransform(_ m: TSDFMatrix4x4, _ v: TSDFFloat3) -> TSDFFloat3 {
    let r = TSDFFloat4(
        TSDFFloat3(m.c0.x*v.x + m.c1.x*v.y + m.c2.x*v.z + m.c3.x,
                   m.c0.y*v.x + m.c1.y*v.y + m.c2.y*v.z + m.c3.y,
                   m.c0.z*v.x + m.c1.z*v.y + m.c2.z*v.z + m.c3.z),
        m.c0.w*v.x + m.c1.w*v.y + m.c2.w*v.z + m.c3.w)
    return TSDFFloat3(r.x/r.w, r.y/r.w, r.z/r.w)
}
@inlinable public func tsdTransform(_ m: TSDFMatrix3x3, _ v: TSDFFloat3) -> TSDFFloat3 {
    m.multiply(v)
}

@inlinable public func tsdIsFinite(_ v: TSDFFloat3) -> Bool {
    v.x.isFinite && v.y.isFinite && v.z.isFinite
}

@inlinable public func tsdIntrinsicsParameters(_ k: TSDFMatrix3x3) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
    (k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y)
}

@inlinable public func tsdMakeIntrinsicsMatrix(fx: Float, fy: Float, cx: Float, cy: Float) -> TSDFMatrix3x3 {
    TSDFMatrix3x3(
        c0: TSDFFloat3(fx, 0, 0),
        c1: TSDFFloat3(0, fy, 0),
        c2: TSDFFloat3(cx, cy, 1)
    )
}

@inlinable public func tsdMakeRigidTransform(
    rotationColumns: (TSDFFloat3, TSDFFloat3, TSDFFloat3),
    translation: TSDFFloat3
) -> TSDFMatrix4x4 {
    TSDFMatrix4x4(
        c0: TSDFFloat4(rotationColumns.0, 0),
        c1: TSDFFloat4(rotationColumns.1, 0),
        c2: TSDFFloat4(rotationColumns.2, 0),
        c3: TSDFFloat4(translation, 1)
    )
}

public func tsdInverseIntrinsics(_ k: TSDFMatrix3x3, epsilon: Float = 1e-8) -> TSDFMatrix3x3? {
    let a00 = k.columns.0.x, a01 = k.columns.1.x, a02 = k.columns.2.x
    let a10 = k.columns.0.y, a11 = k.columns.1.y, a12 = k.columns.2.y
    let a20 = k.columns.0.z, a21 = k.columns.1.z, a22 = k.columns.2.z

    let det = a00 * (a11 * a22 - a12 * a21)
        - a01 * (a10 * a22 - a12 * a20)
        + a02 * (a10 * a21 - a11 * a20)

    guard det.isFinite, abs(det) > epsilon else { return nil }
    let invDet = 1.0 / det

    let i00 =  (a11 * a22 - a12 * a21) * invDet
    let i01 = -(a01 * a22 - a02 * a21) * invDet
    let i02 =  (a01 * a12 - a02 * a11) * invDet
    let i10 = -(a10 * a22 - a12 * a20) * invDet
    let i11 =  (a00 * a22 - a02 * a20) * invDet
    let i12 = -(a00 * a12 - a02 * a10) * invDet
    let i20 =  (a10 * a21 - a11 * a20) * invDet
    let i21 = -(a00 * a21 - a01 * a20) * invDet
    let i22 =  (a00 * a11 - a01 * a10) * invDet

    guard [i00, i01, i02, i10, i11, i12, i20, i21, i22].allSatisfy(\.isFinite) else { return nil }
    return TSDFMatrix3x3(
        c0: TSDFFloat3(i00, i10, i20),
        c1: TSDFFloat3(i01, i11, i21),
        c2: TSDFFloat3(i02, i12, i22)
    )
}

public func tsdInverseRigidTransform(_ m: TSDFMatrix4x4, orthonormalTolerance: Float = 1e-3) -> TSDFMatrix4x4? {
    let c0 = TSDFFloat3(m.c0.x, m.c0.y, m.c0.z)
    let c1 = TSDFFloat3(m.c1.x, m.c1.y, m.c1.z)
    let c2 = TSDFFloat3(m.c2.x, m.c2.y, m.c2.z)
    let t = TSDFFloat3(m.c3.x, m.c3.y, m.c3.z)

    guard tsdIsFinite(c0), tsdIsFinite(c1), tsdIsFinite(c2), tsdIsFinite(t) else { return nil }
    guard abs(m.c0.w) <= orthonormalTolerance,
          abs(m.c1.w) <= orthonormalTolerance,
          abs(m.c2.w) <= orthonormalTolerance,
          abs(m.c3.w - 1.0) <= orthonormalTolerance else {
        return nil
    }

    guard abs(c0.length() - 1.0) <= orthonormalTolerance,
          abs(c1.length() - 1.0) <= orthonormalTolerance,
          abs(c2.length() - 1.0) <= orthonormalTolerance,
          abs(dot(c0, c1)) <= orthonormalTolerance,
          abs(dot(c0, c2)) <= orthonormalTolerance,
          abs(dot(c1, c2)) <= orthonormalTolerance else {
        return nil
    }

    let rt = TSDFMatrix3x3(
        c0: TSDFFloat3(c0.x, c1.x, c2.x),
        c1: TSDFFloat3(c0.y, c1.y, c2.y),
        c2: TSDFFloat3(c0.z, c1.z, c2.z)
    )
    let invT = rt * (t * -1.0)
    return TSDFMatrix4x4(
        c0: TSDFFloat4(TSDFFloat3(rt.c0.x, rt.c0.y, rt.c0.z), 0),
        c1: TSDFFloat4(TSDFFloat3(rt.c1.x, rt.c1.y, rt.c1.z), 0),
        c2: TSDFFloat4(TSDFFloat3(rt.c2.x, rt.c2.y, rt.c2.z), 0),
        c3: TSDFFloat4(invT, 1)
    )
}
#endif
