// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for noise-aware image quality metrics.
enum NativeImageMetricsBridge {
    static func computeWeight(sample: aether_noise_aware_sample_t) -> Float? {
        #if canImport(CAetherNativeBridge)
        var s = sample
        var weight: Float = 0
        let rc = aether_noise_aware_compute_weight(&s, &weight)
        return rc == 0 ? weight : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func batchLoss(samples: UnsafePointer<aether_noise_aware_sample_t>, count: Int32) -> aether_noise_aware_result_t? {
        #if canImport(CAetherNativeBridge)
        var result = aether_noise_aware_result_t()
        let rc = aether_noise_aware_batch_loss(samples, count, &result)
        return rc == 0 ? result : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
