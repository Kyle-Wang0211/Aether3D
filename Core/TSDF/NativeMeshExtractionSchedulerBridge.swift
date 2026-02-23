// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for mesh extraction scheduler (budget-based).
enum NativeMeshExtractionSchedulerBridge {
    static func create() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        let sched = aether_mesh_extraction_scheduler_create()
        return sched
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func destroy(_ sched: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        aether_mesh_extraction_scheduler_destroy(sched)
        #endif
    }
    static func nextBudget(_ sched: OpaquePointer) -> Int32? {
        #if canImport(CAetherNativeBridge)
        var budget: Int32 = 0
        let rc = aether_mesh_extraction_next_budget(sched, &budget)
        return rc == 0 ? budget : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func reportCycle(_ sched: OpaquePointer, elapsedMs: Double) -> Bool {
        #if canImport(CAetherNativeBridge)
        let rc = aether_mesh_extraction_report_cycle(sched, elapsedMs)
        return rc == 0
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
