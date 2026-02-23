// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for motion analyzer (optical flow + quality).
enum NativeMotionAnalyzerBridge {
    static func create() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var analyzer: OpaquePointer?
        let rc = aether_motion_analyzer_create(&analyzer)
        return rc == 0 ? analyzer : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func destroy(_ analyzer: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_motion_analyzer_destroy(analyzer)
        #endif
    }
    static func reset(_ analyzer: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_motion_analyzer_reset(analyzer)
        #endif
    }
}
