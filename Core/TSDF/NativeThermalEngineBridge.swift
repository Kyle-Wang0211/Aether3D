// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif
/// Native bridge for thermal throttle engine.
enum NativeThermalEngineBridge {
    static func create() -> OpaquePointer? {
        #if canImport(CAetherNativeBridge)
        var engine: OpaquePointer?
        let rc = aether_thermal_engine_create(&engine)
        return rc == 0 ? engine : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func destroy(_ engine: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_thermal_engine_destroy(engine)
        #endif
    }
    static func reset(_ engine: OpaquePointer) {
        #if canImport(CAetherNativeBridge)
        _ = aether_thermal_engine_reset(engine)
        #endif
    }
    static func update(_ engine: OpaquePointer, observation: aether_thermal_observation_t) -> aether_thermal_state_t? {
        #if canImport(CAetherNativeBridge)
        var obs = observation
        var state = aether_thermal_state_t()
        let rc = aether_thermal_engine_update(engine, &obs, &state)
        return rc == 0 ? state : nil
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
    static func cpuProbeMs() -> Float {
        #if canImport(CAetherNativeBridge)
        return aether_thermal_engine_cpu_probe_ms()
        #else
        fatalError("CAetherNativeBridge not available")
        #endif
    }
}
