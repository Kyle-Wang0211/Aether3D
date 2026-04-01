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

public enum PipelineCoordinatorProfile: String, Sendable {
    case cloudDefault = "cloud_default"
    case localPreviewMonocular = "local_preview_monocular"
}

/// Swift bridge to the C++ PipelineCoordinator via C API.
/// Manages the 3-thread pipeline lifecycle with MAESTRO thermal management.
public final class PipelineCoordinatorBridge: @unchecked Sendable {
    #if canImport(CAetherNativeBridge)
    private var coordinator: OpaquePointer?
    #endif

    /// Create a pipeline coordinator with a named runtime profile.
    /// Automatically configures bundled monocular depth priors from app resources.
    public init?(gpuDevicePtr: UnsafeMutableRawPointer,
                 splatEnginePtr: UnsafeMutableRawPointer,
                 profile: PipelineCoordinatorProfile = .cloudDefault) {
        #if canImport(CAetherNativeBridge)
        guard var config = Self.makeConfig(for: profile) else { return nil }

        let result: OpaquePointer? = Self.withConfiguredModelPaths(
            profile: profile,
            config: &config
        ) { configuredConfig in
            aether_pipeline_coordinator_create(
                gpuDevicePtr,
                splatEnginePtr,
                configuredConfig
            )
        }

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

    #if canImport(CAetherNativeBridge)
    private static func makeConfig(
        for profile: PipelineCoordinatorProfile
    ) -> aether_coordinator_config_t? {
        var config = aether_coordinator_config_t()
        guard aether_coordinator_default_config(&config) == 0 else {
            return nil
        }

        switch profile {
        case .cloudDefault:
            config.local_preview_mode = 0
            break
        case .localPreviewMonocular:
            // Preview-first local path: bias toward faster on-device convergence
            // while keeping the existing cloud path untouched.
            config.local_preview_mode = 1
            config.max_iterations = 1400
            config.min_frames_to_start_training = 3
            config.render_width = 640
            config.render_height = 480
            config.low_quality_loss_weight = 0.45
            config.blend_start_splat_count = 250.0
            config.blend_end_splat_count = 12000.0
            config.large_model_interval = 9
        }

        return config
    }

    private static func withConfiguredModelPaths<T>(
        profile: PipelineCoordinatorProfile,
        config: inout aether_coordinator_config_t,
        body: (UnsafeMutablePointer<aether_coordinator_config_t>) -> T
    ) -> T {
        let smallURL = Bundle.main.url(
            forResource: "DepthAnythingV2Small",
            withExtension: "mlmodelc"
        )
        let smallPath = smallURL?.path
        NSLog(
            "[Aether3D] Depth prior profile=%@ small=%@",
            profile.rawValue,
            smallPath != nil ? "found" : "missing"
        )

        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let largePath: String? = {
            guard profile == .cloudDefault else { return nil }
            guard memoryGB >= 8.0 else {
                NSLog(
                    "[Aether3D] RAM %.2fGB < 8.0GB — blocking Large depth model for %@",
                    memoryGB,
                    profile.rawValue
                )
                return nil
            }
            let url = Bundle.main.url(
                forResource: "DepthAnythingV2Large",
                withExtension: "mlmodelc"
            )
            NSLog(
                "[Aether3D] Large depth model for %@: %@",
                profile.rawValue,
                url != nil ? "found" : "missing"
            )
            return url?.path
        }()

        if let sp = smallPath, let lp = largePath {
            return sp.withCString { sCStr in
                lp.withCString { lCStr in
                    config.depth_model_path = sCStr
                    config.depth_model_path_large = lCStr
                    return withUnsafeMutablePointer(to: &config) { configPtr in
                        body(configPtr)
                    }
                }
            }
        }

        if let sp = smallPath {
            return sp.withCString { sCStr in
                config.depth_model_path = sCStr
                config.depth_model_path_large = nil
                return withUnsafeMutablePointer(to: &config) { configPtr in
                    body(configPtr)
                }
            }
        }

        config.depth_model_path = nil
        config.depth_model_path_large = nil
        NSLog(
            "[Aether3D] WARNING: no bundled monocular depth model, profile=%@ → MVS-only fallback",
            profile.rawValue
        )
        return withUnsafeMutablePointer(to: &config) { configPtr in
            body(configPtr)
        }
    }
    #endif

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

    /// Submit imported-video frame for local_preview using native bootstrap pose/intrinsics.
    public func onImportedVideoFrame(
        rgba: UnsafePointer<UInt8>,
        width: UInt32,
        height: UInt32,
        cameraIntrinsics: simd_float3x3? = nil,
        intrinsicsSource: Int32 = 0,
        timestampSeconds: Double,
        frameIndex: UInt32,
        totalFrames: UInt32,
        thermalState: Int
    ) -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        var intrinsicsArray = cameraIntrinsics.map { simdToRowMajor3x3($0) }
        let rc: Int32
        if var intrinsicsArray {
            rc = intrinsicsArray.withUnsafeMutableBufferPointer { iPtr in
                aether_pipeline_coordinator_on_imported_video_frame(
                    coordinator,
                    rgba,
                    width,
                    height,
                    iPtr.baseAddress,
                    intrinsicsSource,
                    timestampSeconds,
                    frameIndex,
                    totalFrames,
                    Int32(thermalState)
                )
            }
        } else {
            rc = aether_pipeline_coordinator_on_imported_video_frame(
                coordinator,
                rgba,
                width,
                height,
                nil,
                intrinsicsSource,
                timestampSeconds,
                frameIndex,
                totalFrames,
                Int32(thermalState)
            )
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

    /// Tell the native local-preview pipeline whether the host app is currently
    /// foreground-active. Training uses this to pause GPU refine instead of
    /// tripping iOS background GPU execution denial and degrading to CPU.
    public func setForegroundActive(_ active: Bool) {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return }
        aether_pipeline_coordinator_set_foreground_active(coordinator, active ? 1 : 0)
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

    /// Service local-preview bootstrap work so async depth prior results can be
    /// consumed even while imported-video ingestion is temporarily idle.
    public func serviceLocalPreviewBootstrap() -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_pipeline_coordinator_service_local_preview_bootstrap(coordinator) == 1
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

    /// Copy TSDF surface sample positions for export-time world-state metrics.
    public func copySurfacePoints(maxPoints: Int) -> [SIMD3<Float>] {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator, maxPoints > 0 else { return [] }
        var xyz = [Float](repeating: 0, count: maxPoints * 3)
        let count = xyz.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return Int(aether_pipeline_coordinator_copy_surface_points_xyz(
                coordinator,
                baseAddress,
                maxPoints
            ))
        }
        guard count > 0 else { return [] }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let base = index * 3
            points.append(SIMD3<Float>(xyz[base + 0], xyz[base + 1], xyz[base + 2]))
        }
        return points
        #else
        _ = maxPoints
        return []
        #endif
    }

    /// Signal that the user has entered the 3D viewer space.
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
