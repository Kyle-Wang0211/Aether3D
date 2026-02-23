// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for Kuhn 5-tet decomposition.
/// Delegates to C++ for deterministic parity-based decomposition.
enum NativeTriTetMappingBridge {

    /// Cube vertex order: 0(0,0,0),1(1,0,0),2(0,1,0),3(1,1,0),4(0,0,1),5(1,0,1),6(0,1,1),7(1,1,1)
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

    static func parity(for blockIndex: BlockIndex) -> Int {
        #if canImport(CAetherNativeBridge)
        return Int(aether_tri_tet_parity(blockIndex.x, blockIndex.y, blockIndex.z))
        #else
        return TriTetTSDFMapping.parity(for: blockIndex)
        #endif
    }

    static func decomposition(for blockIndex: BlockIndex) -> [TriTetMappedCell] {
        #if canImport(CAetherNativeBridge)
        var cells = [aether_tri_tet_cell_t](repeating: aether_tri_tet_cell_t(), count: 5)
        let n = aether_tri_tet_decompose(blockIndex.x, blockIndex.y, blockIndex.z, &cells)
        guard n == 5 else { return TriTetTSDFMapping.decomposition(for: blockIndex) }
        let p = Int(aether_tri_tet_parity(blockIndex.x, blockIndex.y, blockIndex.z))
        let corners = cubeCornerOffsets.map { blockIndex + $0 }
        return cells.enumerated().map { (idx, c) in
            let v0 = Int(c.vertex_indices.0)
            let v1 = Int(c.vertex_indices.1)
            let v2 = Int(c.vertex_indices.2)
            let v3 = Int(c.vertex_indices.3)
            return TriTetMappedCell(
                blockIndex: blockIndex,
                parity: p,
                localTetIndex: idx,
                vertices: (v0, v1, v2, v3),
                coordinates: (corners[v0], corners[v1], corners[v2], corners[v3])
            )
        }
        #else
        return TriTetTSDFMapping.decomposition(for: blockIndex)
        #endif
    }
}
