// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for patch display and color evidence kernels.
/// Delegates to optimized C++ implementation when available.
enum NativePatchDisplayBridge {

    /// Single patch display EMA step.
    static func patchDisplayStep(
        previousDisplay: Double,
        previousEMA: Double,
        observationCount: Int,
        target: Double,
        isLocked: Bool,
        config: aether_patch_display_kernel_config_t? = nil
    ) -> aether_patch_display_step_result_t? {
        #if canImport(CAetherNativeBridge)
        var result = aether_patch_display_step_result_t()
        let rc: Int32
        if var cfgVal = config {
            rc = aether_patch_display_step(
                previousDisplay, previousEMA, Int32(observationCount),
                target, isLocked ? 1 : 0, &cfgVal, &result)
        } else {
            rc = aether_patch_display_step(
                previousDisplay, previousEMA, Int32(observationCount),
                target, isLocked ? 1 : 0, nil, &result)
        }
        return rc == 0 ? result : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    /// Compute color evidence from local and global display values.
    static func patchColorEvidence(
        localDisplay: Double,
        globalDisplay: Double,
        config: aether_patch_display_kernel_config_t? = nil
    ) -> Double? {
        #if canImport(CAetherNativeBridge)
        var evidence: Double = 0
        let rc: Int32
        if var cfgVal = config {
            rc = aether_patch_color_evidence(localDisplay, globalDisplay, &cfgVal, &evidence)
        } else {
            rc = aether_patch_color_evidence(localDisplay, globalDisplay, nil, &evidence)
        }
        return rc == 0 ? evidence : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    // MARK: - Smart Smoother

    static func smartSmootherCreate(
        config: aether_smart_smoother_config_t? = nil
    ) -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var smoother: OpaquePointer?
        let rc: Int32
        if var cfgVal = config {
            rc = aether_smart_smoother_create(&cfgVal, &smoother)
        } else {
            rc = aether_smart_smoother_create(nil, &smoother)
        }
        return rc == 0 ? smoother : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func smartSmootherDestroy(_ smoother: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_smart_smoother_destroy(smoother)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func smartSmootherReset(_ smoother: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_smart_smoother_reset(smoother)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func smartSmootherAdd(
        _ smoother: OpaquePointer,
        value: Double
    ) -> Double? {
        #if canImport(CAetherNativeBridge)
        var smoothed: Double = 0
        let rc = aether_smart_smoother_add(smoother, value, &smoothed)
        return rc == 0 ? smoothed : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
