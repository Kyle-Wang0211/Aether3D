// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for Morton code / Z-order spatial quantization.
/// Delegates to optimized C++ bit-interleaving when available.
enum NativeSpatialQuantizerBridge {

    static func mortonCode(x: Int32, y: Int32, z: Int32) -> UInt64 {
        #if canImport(CAetherNativeBridge)
        return aether_morton_encode(x, y, z)
        #else
        return SpatialQuantizer.mortonCode(x: x, y: y, z: z)
        #endif
    }

    static func decodeMortonCode(_ code: UInt64) -> (x: Int32, y: Int32, z: Int32) {
        #if canImport(CAetherNativeBridge)
        var ox: Int32 = 0, oy: Int32 = 0, oz: Int32 = 0
        aether_morton_decode(code, &ox, &oy, &oz)
        return (ox, oy, oz)
        #else
        return SpatialQuantizer.decodeMortonCode(code)
        #endif
    }

    static func mortonCode(from worldPos: EvidenceVector3, origin: EvidenceVector3, cellSize: Float) -> UInt64 {
        #if canImport(CAetherNativeBridge)
        var config = aether_spatial_quantizer_config_t(
            origin_x: Float(origin.x), origin_y: Float(origin.y), origin_z: Float(origin.z),
            cell_size: cellSize
        )
        return aether_spatial_morton_code(&config, Float(worldPos.x), Float(worldPos.y), Float(worldPos.z))
        #else
        let q = SpatialQuantizer(origin: origin, cellSize: cellSize)
        return q.mortonCode(from: worldPos)
        #endif
    }
}
