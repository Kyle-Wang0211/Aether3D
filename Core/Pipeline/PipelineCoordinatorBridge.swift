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

private enum OnDeviceRecordedVideoProfileCompatibility {
    static let legacyProfileRawValue = "local_preview_monocular"
}

public enum PipelineCoordinatorProfile: String, Sendable {
    case cloudDefault = "cloud_default"
    @available(*, deprecated, message: "Use localSubjectFirstMonocular for on-device recorded-video processing.")
    case localPreviewMonocular = "local_preview_monocular"
    case localSubjectFirstMonocular = "local_subject_first_monocular"

    public var normalizedForActiveUse: PipelineCoordinatorProfile {
        if rawValue == OnDeviceRecordedVideoProfileCompatibility.legacyProfileRawValue {
            return .localSubjectFirstMonocular
        }
        return self
    }
}

#if canImport(CAetherNativeBridge)
public extension aether_evidence_snapshot_t {
    var onDeviceElapsedMs: UInt64 { preview_elapsed_ms }
    var onDeviceDepthPhaseMs: UInt64 { preview_phase_depth_ms }
    var onDeviceSeedPhaseMs: UInt64 { preview_phase_seed_ms }
    var onDeviceRefinePhaseMs: UInt64 { preview_phase_refine_ms }
    var onDeviceDepthBatchesSubmitted: UInt32 { preview_depth_batches_submitted }
    var onDeviceDepthResultsReady: UInt32 { preview_depth_results_ready }
    var onDeviceDepthReuseFrames: UInt32 { preview_depth_reuse_frames }
    var onDevicePrefilterAccepts: UInt32 { preview_prefilter_accepts }
    var onDevicePrefilterBrightnessRejects: UInt32 { preview_prefilter_brightness_rejects }
    var onDevicePrefilterBlurRejects: UInt32 { preview_prefilter_blur_rejects }
    var onDeviceKeyframeGateAccepts: UInt32 { preview_keyframe_gate_accepts }
    var onDeviceKeyframeGateRejects: UInt32 { preview_keyframe_gate_rejects }
    var onDeviceImportedFramesEvaluated: UInt32 { preview_imported_frames_evaluated }
    var onDeviceImportedLowParallaxRejects: UInt32 { preview_imported_low_parallax_rejects }
    var onDeviceImportedNearDuplicateRejects: UInt32 { preview_imported_near_duplicate_rejects }
    var onDeviceImportedSelectedKeyframes: UInt32 { preview_imported_selected_keyframes }
    var onDeviceImportedSelectedTranslationMeanMm: Float { preview_imported_selected_translation_mean_mm }
    var onDeviceImportedSelectedRotationMeanDeg: Float { preview_imported_selected_rotation_mean_deg }
    var onDeviceImportedSelectedOverlapMean: Float { preview_imported_selected_overlap_mean }
    var onDeviceSeedCandidates: UInt32 { preview_seed_candidates }
    var onDeviceSeedAccepted: UInt32 { preview_seed_accepted }
    var onDeviceSeedRejected: UInt32 { preview_seed_rejected }
    var onDeviceSeedQualityMean: Float { preview_seed_quality_mean }
    var onDeviceFramesEnqueued: UInt32 { preview_frames_enqueued }
    var onDeviceFramesIngested: UInt32 { preview_frames_ingested }
    var onDeviceFrameBacklog: UInt32 { preview_frame_backlog }
}

private extension aether_coordinator_config_t {
    mutating func setSubjectFirstOnDeviceMode(_ enabled: Bool) {
        local_preview_mode = enabled ? 1 : 0
    }
}
#endif

public struct PipelinePLYExportResult: Sendable {
    public let statusCode: Int32
    public let statusReason: String
    public let fileSizeBytes: UInt64
    public let outputPath: String

    public var succeeded: Bool {
        statusCode == 0 && fileSizeBytes > 0
    }
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
        let normalizedProfile = profile.normalizedForActiveUse
        guard var config = Self.makeConfig(for: normalizedProfile) else { return nil }

        let result: OpaquePointer? = Self.withConfiguredModelPaths(
            profile: normalizedProfile,
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

        if profile.normalizedForActiveUse == .cloudDefault {
            config.setSubjectFirstOnDeviceMode(false)
        } else {
            // Subject-first local path: bias toward faster on-device convergence
            // while keeping the existing cloud path untouched.
            config.setSubjectFirstOnDeviceMode(true)
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
        let normalizedProfile = profile.normalizedForActiveUse
        NSLog(
            "[Aether3D] Depth prior profile=%@ small=%@",
            normalizedProfile.rawValue,
            smallPath != nil ? "found" : "missing"
        )

        let videoPath: String? = {
            guard normalizedProfile == .localSubjectFirstMonocular else { return nil }
            let candidates = [
                Bundle.main.url(forResource: "VideoDepthAnythingSmall", withExtension: "mlmodelc"),
                Bundle.main.url(forResource: "VideoDepthAnythingV2Small", withExtension: "mlmodelc"),
                Bundle.main.url(forResource: "VideoDepthAnything", withExtension: "mlmodelc")
            ]
            let found = candidates.compactMap { $0?.path }.first
            NSLog(
                "[Aether3D] Video depth model for %@: %@",
                normalizedProfile.rawValue,
                found != nil ? "found" : "missing"
            )
            return found
        }()

        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let largePath: String? = {
            guard normalizedProfile == .cloudDefault else { return nil }
            guard memoryGB >= 8.0 else {
                NSLog(
                    "[Aether3D] RAM %.2fGB < 8.0GB — blocking Large depth model for %@",
                    memoryGB,
                    normalizedProfile.rawValue
                )
                return nil
            }
            let url = Bundle.main.url(
                forResource: "DepthAnythingV2Large",
                withExtension: "mlmodelc"
            )
            NSLog(
                "[Aether3D] Large depth model for %@: %@",
                normalizedProfile.rawValue,
                url != nil ? "found" : "missing"
            )
            return url?.path
        }()

        func withLargePath<R>(_ body2: () -> R) -> R {
            if let lp = largePath {
                return lp.withCString { lCStr in
                    config.depth_model_path_large = lCStr
                    return body2()
                }
            } else {
                config.depth_model_path_large = nil
                return body2()
            }
        }

        func withVideoPath<R>(_ body2: () -> R) -> R {
            if let vp = videoPath {
                return vp.withCString { vCStr in
                    config.depth_model_path_video = vCStr
                    return body2()
                }
            } else {
                config.depth_model_path_video = nil
                return body2()
            }
        }

        if let sp = smallPath {
            return sp.withCString { sCStr in
                config.depth_model_path = sCStr
                return withLargePath {
                    withVideoPath {
                        withUnsafeMutablePointer(to: &config) { configPtr in
                            body(configPtr)
                        }
                    }
                }
            }
        }

        config.depth_model_path = nil
        config.depth_model_path_large = nil
        config.depth_model_path_video = nil
        NSLog(
            "[Aether3D] WARNING: no bundled monocular depth model, profile=%@ → MVS-only backup path",
            normalizedProfile.rawValue
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

    /// Submit imported-video frame for local subject-first processing using native bootstrap pose/intrinsics.
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

    /// Tell the native on-device subject-first pipeline whether the host app is
    /// currently
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

    /// Service local subject-first bootstrap work so async depth prior results
    /// can be consumed even while imported-video ingestion is temporarily idle.
    public func serviceLocalSubjectFirstBootstrap() -> Bool {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else { return false }
        return aether_pipeline_coordinator_service_local_subject_first_bootstrap(coordinator) == 1
        #else
        return false
        #endif
    }

    /// Legacy wrapper retained for older bootstrap call sites.
    @available(*, deprecated, message: "Use serviceLocalSubjectFirstBootstrap() instead.")
    public func serviceLocalPreviewBootstrap() -> Bool {
        serviceLocalSubjectFirstBootstrap()
    }

    /// Whether training is running on GPU (true) or CPU recovery mode (false).
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
        exportPLYResult(path: path).succeeded
    }

    /// Export final PLY (trained Gaussians) with diagnostics.
    public func exportPLYResult(path: String) -> PipelinePLYExportResult {
        #if canImport(CAetherNativeBridge)
        guard let coordinator = coordinator else {
            return PipelinePLYExportResult(
                statusCode: -999,
                statusReason: "coordinator_unavailable",
                fileSizeBytes: 0,
                outputPath: path
            )
        }
        let outputURL = URL(fileURLWithPath: path)
        let outputDirectoryURL = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: outputDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return PipelinePLYExportResult(
                statusCode: -998,
                statusReason: "swift_parent_dir_create_failed",
                fileSizeBytes: 0,
                outputPath: path
            )
        }
        let statusCode: Int32 = path.withCString { cStr in
            aether_pipeline_coordinator_export_ply(coordinator, cStr)
        }
        let fileSizeBytes: UInt64 = {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
                return 0
            }
            return fileSize
        }()
        return PipelinePLYExportResult(
            statusCode: statusCode,
            statusReason: Self.exportPLYStatusReason(statusCode: statusCode, fileSizeBytes: fileSizeBytes),
            fileSizeBytes: fileSizeBytes,
            outputPath: path
        )
        #else
        return PipelinePLYExportResult(
            statusCode: -999,
            statusReason: "bridge_unavailable",
            fileSizeBytes: 0,
            outputPath: path
        )
        #endif
    }

    private static func exportPLYStatusReason(statusCode: Int32, fileSizeBytes: UInt64) -> String {
        switch statusCode {
        case 0:
            return fileSizeBytes > 0 ? "ok" : "native_ok_but_empty_or_missing_file"
        case -1:
            return "native_invalid_argument"
        case -2:
            return "native_out_of_range"
        case -3:
            return "native_resource_exhausted"
        case -4:
            return "native_cancelled"
        case -5:
            return "native_failed_precondition"
        case -6:
            return "native_io_error"
        case -998:
            return "swift_parent_dir_create_failed"
        default:
            return "native_status_\(statusCode)"
        }
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
