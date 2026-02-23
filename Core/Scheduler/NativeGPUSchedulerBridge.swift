// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for GPU workload scheduler (budget + priority).
enum NativeGPUSchedulerBridge {
    static func create(config: aether_gpu_scheduler_config_t) -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var sched: OpaquePointer?
        var cfg = config
        let rc = aether_gpu_scheduler_create(&cfg, &sched)
        return rc == 0 ? sched : nil
        #else
        return nil
        #endif
    }
    static func destroy(_ sched: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_gpu_scheduler_destroy(sched)
        #endif
    }
}
