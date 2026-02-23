// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for two-pass frustum/occlusion culler.
enum NativeTwoPassCullerBridge {
    static func selectTier(runtime: aether_two_pass_runtime_t) -> Int32? {
        #if canImport(CAetherNativeBridge)
        var rt = runtime
        var tier: Int32 = 0
        let rc = aether_two_pass_select_tier(&rt, &tier)
        return rc == 0 ? tier : nil
        #else
        return nil
        #endif
    }
}
