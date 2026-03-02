// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PipelineCoordinatorBridge.swift
// Aether3D
//
// Ultra-thin platform bridge: Swift ↔ C API for PipelineCoordinator.
// 3-thread unified pipeline: scan → train → render.
// All devices get unified UX: dense point cloud → 3DGS progressive.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

import simd

/// Swift bridge to the C++ PipelineCoordinator via C API.
/// Manages the 3-thread pipeline lifecycle with MAESTRO thermal management.
public final class PipelineCoordinatorBridge: @unchecked Sendable {
    #if canImport(CAetherNativeBridge)
    private var coordinator: OpaquePointer?
    #endif

    /// Create a pipeline coordinator with default config.
    /// Automatically configures DAv2 depth model path from app bundle.
    public init?(gpuDevicePtr: UnsafeMutableRawPointer,
                 splatEnginePtr: UnsafeMutableRawPointer) {
        #if canImport(CAetherNativeBridge)
        var config = aether_coordinator_config_t()
        _ = aether_coordinator_default_config(&config)

        // ─── DAv2 depth model paths: tell C++ where to find .mlmodelc ───
        // C++ PipelineCoordinator creates its own DepthInferenceEngines
        // via CoreML Obj-C++ bridge. Swift just passes bundle paths.
        //
        // Model selection by device capability:
        //   A14 (iPhone 12, 4GB): Small only — Large fails ANE compilation,
        //     CPU fallback starves ARKit tracking + causes OOM crash.
        //   A15+ (iPhone 13+, 6GB+): Small + Large cross-validation.
        let smallURL = Bundle.main.url(
            forResource: "DepthAnythingV2Small",
            withExtension: "mlmodelc")
        let smallPath = smallURL?.path
        NSLog("[Aether3D] DAv2 Small model: %@",
              smallPath != nil ? "found in bundle" : "NOT FOUND")

        // Gate Large model on physical memory — strict check.
        // iPhone 12 (A14): 4GB → MUST skip Large (ANE compile fails, CPU fallback OOM).
        // iPhone 13+ (A15+): 6GB+ → Large enabled for cross-validation.
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        NSLog("[Aether3D] Device RAM: %.2fGB (threshold for Large model: 5.5GB)", memoryGB)

        let largePath: String? = {
            guard memoryGB >= 5.5 else {
                NSLog("[Aether3D] RAM %.2fGB < 5.5GB — BLOCKING Large depth model", memoryGB)
                return nil
            }
            let url = Bundle.main.url(
                forResource: "DepthAnythingV2Large",
                withExtension: "mlmodelc")
            NSLog("[Aether3D] Large model: %@",
                  url != nil ? "found in bundle, will load" : "NOT FOUND in bundle")
            return url?.path
        }()

        NSLog("[Aether3D] Model config: small=%@, large=%@",
              smallPath != nil ? "YES" : "NO",
              largePath != nil ? "YES" : "NO")

        // Helper to set paths and create coordinator
        // Using withCString safely: both paths need to be alive during create()
        // IMPORTANT: Never pass Large model path on low-RAM devices.
        let result: OpaquePointer? = {
            if let sp = smallPath, let lp = largePath {
                return sp.withCString { sCStr in
                    lp.withCString { lCStr in
                        config.depth_model_path = sCStr
                        config.depth_model_path_large = lCStr
                        return aether_pipeline_coordinator_create(
                            gpuDevicePtr, splatEnginePtr, &config)
                    }
                }
            } else if let sp = smallPath {
                return sp.withCString { sCStr in
                    config.depth_model_path = sCStr
                    config.depth_model_path_large = nil
                    return aether_pipeline_coordinator_create(
                        gpuDevicePtr, splatEnginePtr, &config)
                }
            } else {
                // No Small model → go MVS-only. Never load Large alone
                // (Large without Small wastes memory on single slow inference).
                config.depth_model_path = nil
                config.depth_model_path_large = nil
                NSLog("[Aether3D] WARNING: No Small model, falling back to MVS-only")
                return aether_pipeline_coordinator_create(
                    gpuDevicePtr, splatEnginePtr, &config)
            }
        }()

        guard let ptr = result else { return nil }
        self.coordinator = ptr
        #else
        return nil
        #endif
    }

    /// Create with custom config.
    public init?(gpuDevicePtr: UnsafeMutableRawPointer,
                 splatEnginePtr: UnsafeMutableRawPointer,
                 config: inout aether_coordinator_config_t) {
        #if canImport(CAetherNativeBridge)
        guard let ptr = aether_pipeline_coordinator_create(
            gpuDevicePtr, splatEnginePtr, &config
        ) else { return nil }
        self.coordinator = ptr
        #else
        return nil
        #endif
    }

    deinit {
        #if canImport(CAetherNativeBridge)
        if let coordinator = coordinator {
            aether_pipeline_coordinator_destroy(coordinator)
        }
        #endif
    }

    // MARK: - Frame Submission (<0.3ms, main thread only)

    /// Submit an AR frame with depth from Neural Engine.
    /// Returns true if accepted, false if dropped (queue full).
    public func onFrame(
        rgba: UnsafePointer<UInt8>,
        width: UInt32, height: UInt32,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        featurePoints: UnsafePointer<Float>?, featureCount: UInt32,
        neDepth: UnsafePointer<Float>?, neDepthW: UInt32, neDepthH: UInt32,
        lidarDepth: UnsafePointer<Float>?, lidarW: UInt32, lidarH: UInt32,
        thermalState: Int
    ) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }

        var transformArray = simdToColumnMajor4x4(transform)
        var intrinsicsArray = simdToRowMajor3x3(intrinsics)

        let rc = transformArray.withUnsafeMutableBufferPointer { tPtr in
            intrinsicsArray.withUnsafeMutableBufferPointer { iPtr in
                aether_pipeline_coordinator_on_frame(
                    coordinator,
                    rgba, width, height,
                    tPtr.baseAddress!, iPtr.baseAddress!,
                    featurePoints, featureCount,
                    neDepth, neDepthW, neDepthH,
                    lidarDepth, lidarW, lidarH,
                    Int32(thermalState)
                )
            }
        }
        return rc == 0
        #else
        return false
        #endif
    }

    // MARK: - Evidence Snapshot (lock-free read)

    /// Get latest evidence snapshot from Thread B.
    public func getSnapshot() -> aether_evidence_snapshot_t? {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return nil }
        var snapshot = aether_evidence_snapshot_t()
        let rc = aether_pipeline_coordinator_get_snapshot(coordinator, &snapshot)
        return rc == 0 ? snapshot : nil
        #else
        return nil
        #endif
    }

    // MARK: - Pipeline Control

    /// Signal scan completion. Training continues to convergence.
    public func finishScanning() -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_pipeline_coordinator_finish_scanning(coordinator) == 0
        #else
        return false
        #endif
    }

    /// Set thermal state (thread-safe).
    public func setThermalState(_ level: Int) {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return }
        aether_pipeline_coordinator_set_thermal(coordinator, Int32(level))
        #endif
    }

    /// Request additional training iterations.
    public func requestEnhance(iterations: Int = 200) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_pipeline_coordinator_enhance(coordinator, iterations) == 0
        #else
        return false
        #endif
    }

    /// Check if training is active (lock-free).
    public var isTraining: Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_pipeline_coordinator_is_training(coordinator) != 0
        #else
        return false
        #endif
    }

    /// Whether training is running on GPU (true) or CPU fallback (false).
    /// Returns false before training starts or if GPU shaders failed to load.
    /// UI should surface a warning when isTraining && !isGPUTraining.
    public var isGPUTraining: Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_pipeline_coordinator_is_gpu_training(coordinator) == 1
        #else
        return false
        #endif
    }

    /// Get training progress.
    public func trainingProgress() -> aether_coordinator_training_progress_t? {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return nil }
        var progress = aether_coordinator_training_progress_t()
        let rc = aether_pipeline_coordinator_get_training_progress(coordinator, &progress)
        return rc == 0 ? progress : nil
        #else
        return nil
        #endif
    }

    /// Wait for training to reach minimum quality before export.
    /// Blocks until training reaches minSteps or timeoutSeconds elapses.
    /// Returns the actual training step count reached.
    public func waitForTraining(minSteps: Int, timeoutSeconds: Double) -> Int {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return 0 }
        return Int(aether_pipeline_coordinator_wait_for_training(
            coordinator, minSteps, timeoutSeconds))
        #else
        return 0
        #endif
    }

    /// Export final PLY (trained Gaussians).
    public func exportPLY(path: String) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return path.withCString { cStr in
            aether_pipeline_coordinator_export_ply(coordinator, cStr) == 0
        }
        #else
        return false
        #endif
    }

    /// Export accumulated point cloud as Gaussian-format PLY for 3D viewing.
    public func exportPointCloudPLY(path: String) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return path.withCString { cStr in
            aether_pipeline_coordinator_export_point_cloud_ply(coordinator, cStr) == 0
        }
        #else
        return false
        #endif
    }

    // MARK: - D4: Temporal Region State ("破镜重圆" Progressive Reveal)

    /// Get the number of trained temporal regions.
    public var trainedRegionCount: Int {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return 0 }
        return Int(aether_get_trained_region_count(coordinator))
        #else
        return 0
        #endif
    }

    /// Get the state of a specific temporal region.
    public func getRegionState(index: Int) -> aether_temporal_region_t? {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return nil }
        var region = aether_temporal_region_t()
        let rc = aether_get_region_state(coordinator, Int32(index), &region)
        return rc == 0 ? region : nil
        #else
        return nil
        #endif
    }

    /// Check if a region's geometry is ready for rendering.
    public func isRegionGeometryReady(index: Int) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_get_region_geometry_ready(coordinator, Int32(index)) == 1
        #else
        return false
        #endif
    }

    /// Get the fade-in alpha for a region [0, 1].
    public func regionFadeAlpha(index: Int) -> Float {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return 0.0 }
        let alpha = aether_get_region_fade_alpha(coordinator, Int32(index))
        return alpha >= 0.0 ? alpha : 0.0
        #else
        return 0.0
        #endif
    }

    /// Signal that the user has entered the 3D viewer space.
    /// Triggers sequential fly-in animation for completed regions.
    public func signalViewerEntered() {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return }
        aether_pipeline_coordinator_signal_viewer_entered(coordinator)
        #endif
    }

    // MARK: - Render Data (lock-free read for Metal pipeline)

    /// Point cloud + splat + quality overlay render data from the coordinator's triple buffer.
    public struct RenderData {
        public let pointCloudVertices: UnsafeRawPointer?  // PointCloudVertex[N], 32 bytes each
        public let pointCloudCount: Int
        public let pointCloudAlpha: Float  // [0,1] fades as 3DGS grows

        // Packed splats from training (PackedSplat[N], 16 bytes each)
        public let packedSplats: UnsafeRawPointer?
        public let splatCount: Int

        // Quality overlay billboards (OverlayVertex[N], 20 bytes each, C++ generated)
        public let overlayVertices: UnsafeRawPointer?
        public let overlayCount: Int

        // TSDF active blocks (scan coverage metric — replaces surface point count)
        public let tsdfBlockCount: Int
    }

    /// Get latest point cloud + splat data for Metal rendering.
    /// Main thread only. Pointers valid until next call.
    public func getRenderData() -> RenderData? {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return nil }
        var data = aether_render_data_t()
        let rc = aether_pipeline_coordinator_get_render_data(coordinator, &data)
        guard rc == 0 else { return nil }
        return RenderData(
            pointCloudVertices: data.point_cloud_vertices != nil
                ? UnsafeRawPointer(data.point_cloud_vertices!)
                : nil,
            pointCloudCount: Int(data.point_cloud_count),
            pointCloudAlpha: data.point_cloud_alpha,
            packedSplats: data.packed_splats != nil
                ? UnsafeRawPointer(data.packed_splats!)
                : nil,
            splatCount: Int(data.splat_count),
            overlayVertices: data.overlay_vertices != nil
                ? UnsafeRawPointer(data.overlay_vertices!)
                : nil,
            overlayCount: Int(data.overlay_count),
            tsdfBlockCount: Int(data.tsdf_block_count)
        )
        #else
        return nil
        #endif
    }

    // MARK: - Private

    private func simdToColumnMajor4x4(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }

    private func simdToRowMajor3x3(_ m: simd_float3x3) -> [Float] {
        [m.columns.0.x, m.columns.1.x, m.columns.2.x,
         m.columns.0.y, m.columns.1.y, m.columns.2.y,
         m.columns.0.z, m.columns.1.z, m.columns.2.z]
    }
}
