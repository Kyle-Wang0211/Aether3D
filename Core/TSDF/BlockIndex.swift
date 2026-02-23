// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// BlockIndex.swift
// Aether3D
//
// Block coordinate in voxel grid space.

public struct BlockIndex: Sendable, Codable, Equatable, Hashable {
    public var x: Int32
    public var y: Int32
    public var z: Int32

    public init(_ x: Int32, _ y: Int32, _ z: Int32) {
        self.x = x; self.y = y; self.z = z
    }

    @inlinable
    public func niessnerHash(tableSize: Int) -> Int {
        let h = Int(x) &* 73856093 ^ Int(y) &* 19349669 ^ Int(z) &* 83492791
        return abs(h) % tableSize
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(x); hasher.combine(y); hasher.combine(z)
    }

    public static let faceNeighborOffsets: [BlockIndex] = [
        BlockIndex(1,0,0), BlockIndex(-1,0,0),
        BlockIndex(0,1,0), BlockIndex(0,-1,0),
        BlockIndex(0,0,1), BlockIndex(0,0,-1)
    ]

    @inlinable
    public static func +(lhs: BlockIndex, rhs: BlockIndex) -> BlockIndex {
        BlockIndex(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
}
