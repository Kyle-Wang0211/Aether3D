// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

struct NativeMarchingCubesMesh: Sendable {
    var vertices: [SIMD3<Float>]
    var indices: [UInt32]
}

enum NativeMarchingCubesBridge {
    static func run(
        sdfGrid: [Float],
        dim: Int,
        origin: SIMD3<Float>,
        voxelSize: Float
    ) -> NativeMarchingCubesMesh? {
        guard dim > 1, sdfGrid.count == dim * dim * dim else {
            return nil
        }

        var vertexCapacity = max(256, dim * dim * dim)
        var indexCapacity = max(256, dim * dim * dim * 3)

        while vertexCapacity <= 4_000_000 && indexCapacity <= 8_000_000 {
            var cVertices = Array(repeating: aether_mc_vertex_t(x: 0, y: 0, z: 0), count: vertexCapacity)
            var cIndices = Array(repeating: UInt32(0), count: indexCapacity)
            var vCount = Int32(vertexCapacity)
            var iCount = Int32(indexCapacity)

            let rc = sdfGrid.withUnsafeBufferPointer { ptr in
                cVertices.withUnsafeMutableBufferPointer { vPtr in
                    cIndices.withUnsafeMutableBufferPointer { iPtr in
                        aether_marching_cubes_run(
                            ptr.baseAddress,
                            Int32(dim),
                            origin.x,
                            origin.y,
                            origin.z,
                            voxelSize,
                            vPtr.baseAddress,
                            &vCount,
                            iPtr.baseAddress,
                            &iCount
                        )
                    }
                }
            }

            if rc == 0 {
                let vertexCount = Int(vCount)
                let indexCount = Int(iCount)
                let vertices = cVertices.prefix(vertexCount).map { SIMD3<Float>($0.x, $0.y, $0.z) }
                let indices = Array(cIndices.prefix(indexCount))
                return NativeMarchingCubesMesh(vertices: vertices, indices: indices)
            }

            if rc == -3 {
                vertexCapacity = max(vertexCapacity * 2, Int(vCount))
                indexCapacity = max(indexCapacity * 2, Int(iCount))
                continue
            }

            break
        }

        return nil
    }
}
