// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// NativeSplatEngineBridge.swift
// Aether3D
//
// Ultra-thin platform bridge: Swift ↔ C API for SplatRenderEngine.
// No business logic — pure I/O forwarding.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Swift bridge to the C++ SplatRenderEngine via C API.
/// Manages engine lifecycle and forwards rendering commands.
public final class NativeSplatEngineBridge {
    #if canImport(CAetherNativeBridge)
    private var engine: OpaquePointer?
    #endif

    /// Create a splat render engine.
    /// - Parameter gpuDevicePtr: Opaque pointer to the platform GPUDevice.
    public init?(gpuDevicePtr: UnsafeMutableRawPointer) {
        #if canImport(CAetherNativeBridge)
        var config = aether_splat_config_t()
        _ = aether_splat_default_config(&config)

        var enginePtr: OpaquePointer?
        let rc = aether_splat_engine_create(gpuDevicePtr, &config, &enginePtr)
        guard rc == 0, let ptr = enginePtr else { return nil }
        self.engine = ptr
        #else
        return nil
        #endif
    }

    deinit {
        #if canImport(CAetherNativeBridge)
        if let engine = engine {
            aether_splat_engine_destroy(engine)
        }
        #endif
    }

    // MARK: - Data Loading

    public func loadPLY(path: String) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return false }
        return path.withCString { cStr in
            aether_splat_load_ply(engine, cStr) == 0
        }
        #else
        return false
        #endif
    }

    public func loadSPZ(data: Data) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return false }
        return data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return aether_splat_load_spz(engine, base, ptr.count) == 0
        }
        #else
        return false
        #endif
    }

    // MARK: - Incremental Update (Spark pushSplat API)

    public func pushSplats(params: UnsafePointer<aether_gaussian_params_t>, count: Int) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        _ = aether_splat_push(engine, params, count)
        #endif
    }

    /// D3: Push Gaussians with per-splat region IDs for progressive reveal.
    public func pushSplatsWithRegions(params: UnsafePointer<aether_gaussian_params_t>,
                                       regionIds: UnsafePointer<UInt8>,
                                       count: Int) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        _ = aether_splat_push_with_regions(engine, params, regionIds, count)
        #endif
    }

    /// D3: Set per-region fade alphas for progressive reveal rendering.
    /// fade_alphas[i] = alpha for region i, range [0,1].
    public func setRegionFadeAlphas(_ fadeAlphas: [Float]) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        fadeAlphas.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            aether_splat_set_region_fade_alphas(engine, base, ptr.count)
        }
        #endif
    }

    public func clearSplats() {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        aether_splat_clear(engine)
        #endif
    }

    // MARK: - Per-Frame Rendering

    public func beginFrame() {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        aether_splat_begin_frame(engine)
        #endif
    }

    public func updateCamera(_ camera: aether_splat_camera_t) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        var cam = camera
        aether_splat_update_camera(engine, &cam)
        #endif
    }

    public func encodeSort(cmdBufferPtr: UnsafeMutableRawPointer) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        aether_splat_encode_sort(engine, cmdBufferPtr)
        #endif
    }

    public func encodeRender(cmdBufferPtr: UnsafeMutableRawPointer,
                      renderTargetPtr: UnsafeMutableRawPointer) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        aether_splat_encode_render(engine, cmdBufferPtr, renderTargetPtr)
        #endif
    }

    /// Encode render pass using a native MTLRenderPassDescriptor.
    /// Renders directly into the MTKView's drawable (no offscreen textures).
    public func encodeRenderNative(cmdBufferPtr: UnsafeMutableRawPointer,
                                    renderPassDescPtr: UnsafeMutableRawPointer) {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return }
        aether_splat_encode_render_native(engine, cmdBufferPtr, renderPassDescPtr)
        #endif
    }

    public func endFrame() -> aether_splat_stats_t {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return aether_splat_stats_t() }
        var stats = aether_splat_stats_t()
        aether_splat_end_frame(engine, &stats)
        return stats
        #else
        return aether_splat_stats_t()
        #endif
    }

    // MARK: - Queries

    public var splatCount: Int {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return 0 }
        return aether_splat_count(engine)
        #else
        return 0
        #endif
    }

    /// Get bounding sphere of loaded data: (center, radius).
    /// Returns nil if no data loaded.
    public func getBounds() -> (center: SIMD3<Float>, radius: Float)? {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return nil }
        var center: (Float, Float, Float) = (0, 0, 0)
        var radius: Float = 0
        let rc = withUnsafeMutablePointer(to: &center) { cPtr in
            cPtr.withMemoryRebound(to: Float.self, capacity: 3) { floatPtr in
                aether_splat_get_bounds(engine, floatPtr, &radius)
            }
        }
        guard rc == 0 else { return nil }
        return (SIMD3<Float>(center.0, center.1, center.2), radius)
        #else
        return nil
        #endif
    }

    public var isInitialized: Bool {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return false }
        return aether_splat_is_initialized(engine) != 0
        #else
        return false
        #endif
    }

    // MARK: - Direct Data Access (for Swift-side Metal rendering)

    /// Get raw pointer to CPU-side PackedSplat array (16 bytes per element).
    /// Valid until next push/clear/load call.
    public func getPackedData() -> UnsafeRawPointer? {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return nil }
        return aether_splat_get_packed_data(engine)
        #else
        return nil
        #endif
    }

    /// Get number of packed splats in the CPU buffer.
    public func getPackedCount() -> Int {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return 0 }
        return aether_splat_get_packed_count(engine)
        #else
        return 0
        #endif
    }

    /// Get raw pointer to the CPU-side SH degree-1 buffer.
    /// Layout matches float4[packedCount * 3].
    public func getSHData() -> UnsafeRawPointer? {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return nil }
        return aether_splat_get_sh_data(engine)
        #else
        return nil
        #endif
    }

    /// Get number of floats in the SH degree-1 buffer.
    public func getSHFloatCount() -> Int {
        #if canImport(CAetherNativeBridge)
        guard let engine = engine else { return 0 }
        return aether_splat_get_sh_float_count(engine)
        #else
        return 0
        #endif
    }
}
