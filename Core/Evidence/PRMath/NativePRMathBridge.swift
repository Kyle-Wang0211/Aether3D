// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for PRMath mathematical utilities.
/// When CAetherNativeBridge is available, delegates to C++ StableLogistic
/// for bit-exact cross-platform sigmoid computation.
enum NativePRMathBridge {

    static func sigmoid(_ x: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_sigmoid(x)
        #else
        // Fallback to Swift StableLogistic
        return StableLogistic.sigmoid(x)
        #endif
    }

    static func sigmoid01FromThreshold(value: Double, threshold: Double, transitionWidth: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_sigmoid01_from_threshold(value, threshold, transitionWidth)
        #else
        return PRMath.sigmoid01FromThreshold(value: value, threshold: threshold, transitionWidth: transitionWidth)
        #endif
    }

    static func sigmoidInverted01(value: Double, threshold: Double, transitionWidth: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_sigmoid_inverted01(value, threshold, transitionWidth)
        #else
        return PRMath.sigmoidInverted01FromThreshold(value: value, threshold: threshold, transitionWidth: transitionWidth)
        #endif
    }

    static func expSafe(_ x: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_exp_safe(x)
        #else
        return PRMath.expSafe(x)
        #endif
    }

    static func atan2Safe(_ y: Double, _ x: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_atan2_safe(y, x)
        #else
        return PRMath.atan2Safe(y, x)
        #endif
    }

    static func asinSafe(_ x: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_asin_safe(x)
        #else
        return PRMath.asinSafe(x)
        #endif
    }

    static func sqrtSafe(_ x: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_sqrt_safe(x)
        #else
        return PRMath.sqrtSafe(x)
        #endif
    }

    static func clamp01(_ x: Double) -> Double {
        #if canImport(CAetherNativeBridge)
        return aether_clamp01(x)
        #else
        return PRMath.clamp01(x)
        #endif
    }

    static func isUsable(_ x: Double) -> Bool {
        #if canImport(CAetherNativeBridge)
        return aether_is_usable(x) != 0
        #else
        return PRMath.isUsable(x)
        #endif
    }
}
