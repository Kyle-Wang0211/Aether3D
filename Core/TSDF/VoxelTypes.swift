// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// VoxelTypes.swift
// Aether3D
//
// Cross-platform SDF storage type — 2 bytes, IEEE 754 half-precision.

#if canImport(simd) || arch(arm64)
public typealias SDFStorage = Float16
#else
public struct SDFStorage: Sendable, Codable, Equatable, Hashable {
    public var bitPattern: UInt16

    public init(_ value: Float) {
        let bits = value.bitPattern
        let sign = (bits >> 16) & 0x8000
        let exp = Int((bits >> 23) & 0xFF) - 127
        let frac = bits & 0x7FFFFF
        if exp > 15 { bitPattern = UInt16(sign | 0x7C00) }
        else if exp < -14 { bitPattern = UInt16(sign) }
        else { bitPattern = UInt16(sign | UInt32((exp + 15) << 10) | (frac >> 13)) }
    }

    public var floatValue: Float {
        let sign = UInt32(bitPattern & 0x8000) << 16
        let exp = UInt32(bitPattern >> 10) & 0x1F
        let frac = UInt32(bitPattern & 0x3FF)
        if exp == 0 { return Float(bitPattern: sign) }
        if exp == 31 { return Float(bitPattern: sign | 0x7F800000) }
        return Float(bitPattern: sign | ((exp + 112) << 23) | (frac << 13))
    }

    public init(floatLiteral value: Float) { self.init(value) }
}
#endif
