// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Constants shared by native bridge adapters.
public enum BridgeInteropConstants {
    // 64-bit FNV-1a constants used for fallback deterministic patch-key hashing.
    public static let fnv1a64OffsetBasis: UInt64 = 1469598103934665603
    public static let fnv1a64Prime: UInt64 = 1099511628211

    // Canonical JSON scratch buffer capacity for replay C API bridge.
    public static let canonicalJSONScratchCapacity: Int32 = 8192

    // glTF accessor component types.
    public static let gltfComponentTypeUInt16: Int = 5123
    public static let gltfComponentTypeUInt32: Int = 5125

    // Render selection scoring defaults.
    public static let renderSelectionCompletionBoost: Float = 1000.0

    // Disable hidden retention floor in bridge-level confidence decay path.
    public static let confidenceDecayPeakRetentionFloor: Float = 0.0
    public static let confidenceDecayPerceptualExponent: Float = 0.0
}
