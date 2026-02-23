// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Deterministic TSDF-block to Tri/Tet mapping for Kuhn 5-tet decomposition.
///
/// This module is intentionally pure and table-driven so it can be replayed
/// bit-exactly in fixture checks and governance gates.
public struct TriTetMappedCell: Sendable, Codable, Equatable {
    public let blockIndex: BlockIndex
    public let parity: Int
    public let localTetIndex: Int

    public let v0: Int
    public let v1: Int
    public let v2: Int
    public let v3: Int

    public let c0: BlockIndex
    public let c1: BlockIndex
    public let c2: BlockIndex
    public let c3: BlockIndex

    public var localVertices: (Int, Int, Int, Int) {
        (v0, v1, v2, v3)
    }

    public init(
        blockIndex: BlockIndex,
        parity: Int,
        localTetIndex: Int,
        vertices: (Int, Int, Int, Int),
        coordinates: (BlockIndex, BlockIndex, BlockIndex, BlockIndex)
    ) {
        self.blockIndex = blockIndex
        self.parity = parity
        self.localTetIndex = localTetIndex
        self.v0 = vertices.0
        self.v1 = vertices.1
        self.v2 = vertices.2
        self.v3 = vertices.3
        self.c0 = coordinates.0
        self.c1 = coordinates.1
        self.c2 = coordinates.2
        self.c3 = coordinates.3
    }
}

public enum TriTetTSDFMapping {
    /// Cube vertex order shared with `TriTetConsistencyEngine.kuhn5`:
    /// 0(0,0,0),1(1,0,0),2(0,1,0),3(1,1,0),4(0,0,1),5(1,0,1),6(0,1,1),7(1,1,1)
    private static let cubeCornerOffsets: [BlockIndex] = [
        BlockIndex(0, 0, 0),
        BlockIndex(1, 0, 0),
        BlockIndex(0, 1, 0),
        BlockIndex(1, 1, 0),
        BlockIndex(0, 0, 1),
        BlockIndex(1, 0, 1),
        BlockIndex(0, 1, 1),
        BlockIndex(1, 1, 1),
    ]

    /// Block parity drives diagonal family selection (Kuhn parity 0/1).
    @inlinable
    public static func parity(for blockIndex: BlockIndex) -> Int {
        let sum = Int(blockIndex.x) + Int(blockIndex.y) + Int(blockIndex.z)
        return ((sum % 2) + 2) % 2
    }

    /// Return the deterministic 5-tet decomposition for the target block.
    public static func decomposition(for blockIndex: BlockIndex) -> [TriTetMappedCell] {
        (0..<5).compactMap { map(blockIndex: blockIndex, localTetIndex: $0) }
    }

    /// Map a TSDF block + local tet index to the canonical local vertices and
    /// block-corner coordinates.
    public static func map(blockIndex: BlockIndex, localTetIndex: Int) -> TriTetMappedCell? {
        guard (0..<5).contains(localTetIndex) else { return nil }
        let p = parity(for: blockIndex)
        let tet = TriTetConsistencyEngine.kuhn5(parity: p)[localTetIndex]
        let corners = cubeCornerOffsets.map { blockIndex + $0 }

        return TriTetMappedCell(
            blockIndex: blockIndex,
            parity: p,
            localTetIndex: localTetIndex,
            vertices: tet,
            coordinates: (corners[tet.0], corners[tet.1], corners[tet.2], corners[tet.3])
        )
    }

    /// Strong deterministic check used by phase gates.
    public static func isDeterministicDecomposition(for blockIndex: BlockIndex) -> Bool {
        let first = decomposition(for: blockIndex)
        let second = decomposition(for: blockIndex)
        guard first == second, first.count == 5 else { return false }

        let expected = TriTetConsistencyEngine.kuhn5(parity: parity(for: blockIndex))
        for index in 0..<5 {
            let cell = first[index]
            let ref = expected[index]
            guard cell.localTetIndex == index else { return false }
            guard cell.localVertices == ref else { return false }
        }
        return true
    }

    /// Canonical digest of decomposition layout for deterministic replay checks.
    public static func decompositionDigest(for blockIndex: BlockIndex) -> String {
        let canonical = decomposition(for: blockIndex)
            .map(canonicalRow(_:))
            .joined(separator: ";")
        return SHA256Utility.sha256(canonical)
    }

    private static func canonicalRow(_ cell: TriTetMappedCell) -> String {
        [
            "p=\(cell.parity)",
            "i=\(cell.localTetIndex)",
            "v=\(cell.v0),\(cell.v1),\(cell.v2),\(cell.v3)",
            "c0=\(cell.c0.x),\(cell.c0.y),\(cell.c0.z)",
            "c1=\(cell.c1.x),\(cell.c1.y),\(cell.c1.z)",
            "c2=\(cell.c2.x),\(cell.c2.y),\(cell.c2.z)",
            "c3=\(cell.c3.x),\(cell.c3.y),\(cell.c3.z)",
        ].joined(separator: "|")
    }
}
