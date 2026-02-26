// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for pose stabilization (EMA + jitter suppression).
public enum NativePoseStabilizerBridge {

    public static func create(config: aether_pose_stabilizer_config_t? = nil) -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var stabilizer: OpaquePointer?
        if var cfg = config {
            let rc = aether_pose_stabilizer_create(&cfg, &stabilizer)
            return rc == 0 ? stabilizer : nil
        } else {
            let rc = aether_pose_stabilizer_create(nil, &stabilizer)
            return rc == 0 ? stabilizer : nil
        }
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    public static func destroy(_ stabilizer: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_pose_stabilizer_destroy(stabilizer)
        #endif
    }

    public static func reset(_ stabilizer: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_pose_stabilizer_reset(stabilizer)
        #endif
    }

    /// Update with raw pose (4×4 column-major), gyro, accel, and timestamp.
    /// Returns (stabilizedPose, quality) or nil on error.
    public static func update(_ stabilizer: OpaquePointer,
                              rawPose: UnsafePointer<Float>,
                              gyro: UnsafePointer<Float>?,
                              accel: UnsafePointer<Float>?,
                              timestampNs: UInt64) -> ([Float], Float)? {
        #if canImport(CAetherNativeBridge)
        var outPose = [Float](repeating: 0, count: 16)
        var quality: Float = 0
        let rc = aether_pose_stabilizer_update(stabilizer, rawPose, gyro, accel, timestampNs, &outPose, &quality)
        return rc == 0 ? (outPose, quality) : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    public static func predict(_ stabilizer: OpaquePointer, targetTimestampNs: UInt64) -> [Float]? {
        #if canImport(CAetherNativeBridge)
        var outPose = [Float](repeating: 0, count: 16)
        let rc = aether_pose_stabilizer_predict(stabilizer, targetTimestampNs, &outPose)
        return rc == 0 ? outPose : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
