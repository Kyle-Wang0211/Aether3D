// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for DA3 depth fusion algorithm.
enum NativeDepthFuserBridge {
    /// Fuses a single depth sample from vision and TSDF sources.
    /// Returns (fusedDepth, confidence), or nil on error.
    static func fuseDepth(sample: aether_da3_depth_sample_t) -> (Float, Float)? {
        #if canImport(CAetherNativeBridge)
        var s = sample
        var fusedDepth: Float = 0
        var confidence: Float = 0
        let rc = aether_da3_fuse_depth(&s, &fusedDepth, &confidence)
        return rc == 0 ? (fusedDepth, confidence) : nil
        #else
        return nil
        #endif
    }
}
