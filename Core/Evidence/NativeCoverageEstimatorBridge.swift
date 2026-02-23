// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for the coverage estimator.
/// Delegates to optimized C++ implementation when available.
enum NativeCoverageEstimatorBridge {

    static func defaultConfig() -> aether_coverage_estimator_config_t {
        #if canImport(CAetherNativeBridge)
        var config = aether_coverage_estimator_config_t()
        _ = aether_coverage_estimator_default_config(&config)
        return config
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func create(config: aether_coverage_estimator_config_t) -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var estimator: OpaquePointer?
        var cfg = config
        let rc = aether_coverage_estimator_create(&cfg, &estimator)
        return rc == 0 ? estimator : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func destroy(_ estimator: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_coverage_estimator_destroy(estimator)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func reset(_ estimator: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_coverage_estimator_reset(estimator)
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func update(
        _ estimator: OpaquePointer,
        cells: UnsafePointer<aether_coverage_cell_observation_t>,
        cellCount: Int32,
        monotonicTimestampMs: Int64
    ) -> aether_coverage_result_t? {
        #if canImport(CAetherNativeBridge)
        var result = aether_coverage_result_t()
        let rc = aether_coverage_estimator_update(
            estimator, cells, cellCount, monotonicTimestampMs, &result)
        return rc == 0 ? result : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func lastCoverage(_ estimator: OpaquePointer) -> Double? {
        #if canImport(CAetherNativeBridge)
        var coverage: Double = 0
        let rc = aether_coverage_estimator_last_coverage(estimator, &coverage)
        return rc == 0 ? coverage : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }

    static func nonMonotonicCount(_ estimator: OpaquePointer) -> Int? {
        #if canImport(CAetherNativeBridge)
        var count: Int32 = 0
        let rc = aether_coverage_estimator_non_monotonic_count(estimator, &count)
        return rc == 0 ? Int(count) : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
