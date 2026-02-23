// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for photometric consistency checker.
enum NativePhotometricCheckerBridge {
    static func create(windowSize: Int32) -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var checker: OpaquePointer?
        let rc = aether_photometric_checker_create(windowSize, &checker)
        return rc == 0 ? checker : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func destroy(_ checker: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_photometric_checker_destroy(checker)
        #endif
    }
    static func reset(_ checker: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_photometric_checker_reset(checker)
        #endif
    }
    static func update(_ checker: OpaquePointer, luminance: Double, exposure: Double, labL: Double, labA: Double, labB: Double) -> Bool {
        #if canImport(CAetherNativeBridge)
        let rc = aether_photometric_checker_update(checker, luminance, exposure, labL, labA, labB)
        return rc == 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func check(_ checker: OpaquePointer, maxLuminanceVariance: Double, maxLabVariance: Double, minExposureConsistency: Double) -> aether_photometric_result_t? {
        #if canImport(CAetherNativeBridge)
        var result = aether_photometric_result_t()
        let rc = aether_photometric_checker_check(checker, maxLuminanceVariance, maxLabVariance, minExposureConsistency, &result)
        return rc == 0 ? result : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
