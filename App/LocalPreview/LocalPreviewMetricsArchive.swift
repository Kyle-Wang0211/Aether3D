//
// LocalPreviewMetricsArchive.swift
// Aether3D
//
// Stable archive schema for on-device preview telemetry. This keeps preview
// metrics ownership out of shared view models so local_preview can keep
// productizing independently from cloud orchestration.
//

import Foundation
import Darwin
import Aether3DCore

#if canImport(CAetherNativeBridge)
import CAetherNativeBridge

enum LocalPreviewMetricsArchive {
    static func runtimeMetrics(
        snapshot: aether_evidence_snapshot_t?,
        sourceVideo: String? = nil,
        exported: Bool? = nil,
        sourceKind: String = "direct_capture",
        thermalState: ProcessInfo.ThermalState? = nil,
        exportElapsedMs: UInt64? = nil
    ) -> [String: String] {
        let currentThermal = thermalState ?? ProcessInfo.processInfo.thermalState
        var metrics: [String: String] = [
            "processing_backend": ProcessingBackendChoice.localPreview.rawValue,
            "preview_mode": LocalPreviewProductProfile.previewMode,
            "depth_prior_source": LocalPreviewProductProfile.depthPriorSource,
            "depth_prior_transport": LocalPreviewProductProfile.depthPriorTransport,
            "depth_prior_profile": LocalPreviewProductProfile.depthPriorProfile,
            "preview_source_kind": sourceKind,
            "device_model": deviceModelIdentifier(),
            "thermal_state_raw": String(currentThermal.rawValue),
            "thermal_state_label": thermalStateLabel(currentThermal),
        ]
        if let sourceVideo {
            metrics["source_video"] = sourceVideo
        }
        if let exported {
            metrics["preview_export_succeeded"] = exported ? "1" : "0"
        }
        if let exportElapsedMs {
            metrics["preview_export_ms"] = String(exportElapsedMs)
        }
        guard let snapshot else { return metrics }
        metrics["preview_elapsed_ms"] = String(snapshot.preview_elapsed_ms)
        metrics["preview_phase_depth_ms"] = String(snapshot.preview_phase_depth_ms)
        metrics["preview_phase_seed_ms"] = String(snapshot.preview_phase_seed_ms)
        metrics["preview_phase_refine_ms"] = String(snapshot.preview_phase_refine_ms)
        metrics["preview_processed_frames"] = String(snapshot.preview_frames_ingested)
        metrics["preview_depth_batches_submitted"] = String(snapshot.preview_depth_batches_submitted)
        metrics["preview_depth_results_ready"] = String(snapshot.preview_depth_results_ready)
        metrics["preview_depth_reuse_frames"] = String(snapshot.preview_depth_reuse_frames)
        metrics["preview_prefilter_accepts"] = String(snapshot.preview_prefilter_accepts)
        metrics["preview_prefilter_brightness_rejects"] = String(snapshot.preview_prefilter_brightness_rejects)
        metrics["preview_prefilter_blur_rejects"] = String(snapshot.preview_prefilter_blur_rejects)
        metrics["preview_keyframe_gate_accepts"] = String(snapshot.preview_keyframe_gate_accepts)
        metrics["preview_keyframe_gate_rejects"] = String(snapshot.preview_keyframe_gate_rejects)
        metrics["preview_seed_candidates"] = String(snapshot.preview_seed_candidates)
        metrics["preview_seed_accepted"] = String(snapshot.preview_seed_accepted)
        metrics["preview_seed_rejected"] = String(snapshot.preview_seed_rejected)
        metrics["preview_seed_quality_mean"] = String(format: "%.4f", snapshot.preview_seed_quality_mean)
        metrics["preview_native_frames_enqueued"] = String(snapshot.preview_frames_enqueued)
        metrics["preview_native_frames_ingested"] = String(snapshot.preview_frames_ingested)
        metrics["preview_native_frame_backlog"] = String(snapshot.preview_frame_backlog)
        metrics["preview_selected_frames"] = String(snapshot.selected_frames)
        metrics["preview_min_frames_needed"] = String(snapshot.min_frames_needed)
        metrics["preview_gaussians"] = String(snapshot.num_gaussians)
        metrics["preview_training_progress"] = String(format: "%.4f", snapshot.training_progress)
        metrics["preview_coverage"] = String(format: "%.4f", snapshot.coverage)
        metrics["preview_overall_quality"] = String(format: "%.4f", snapshot.overall_quality)
        return metrics
    }

    static func appendingImportedVideoContext(
        to base: [String: String],
        width: Int,
        height: Int,
        durationSeconds: Double,
        sampledFrames: Int,
        submittedFrames: Int,
        framesWithCameraIntrinsics: Int,
        framesWithSidecarIntrinsics: Int,
        framesWithMetadataEstimatedIntrinsics: Int,
        framesUsingColmapDefaultIntrinsics: Int,
        focalLength35mmEquivalentMM: Double?,
        samplingIntervalSeconds: Double,
        photometricAcceptedFrames: Int,
        photometricExposureRejects: Int,
        photometricWhiteBalanceRejects: Int,
        lastExposureConsistencyScore: Double,
        lastWhiteBalanceConsistencyScore: Double,
        budget: ImportedLocalPreviewBudget,
        reachedSteps: Int,
        totalElapsedMs: UInt64
    ) -> [String: String] {
        var metrics = base
        metrics["preview_import_width"] = String(width)
        metrics["preview_import_height"] = String(height)
        metrics["preview_import_duration_s"] = String(format: "%.3f", durationSeconds)
        metrics["preview_import_sampled_frames"] = String(sampledFrames)
        metrics["preview_import_submitted_frames"] = String(submittedFrames)
        metrics["preview_import_frames_with_camera_intrinsics"] = String(framesWithCameraIntrinsics)
        metrics["preview_import_frames_with_sidecar_intrinsics"] = String(framesWithSidecarIntrinsics)
        metrics["preview_import_frames_with_metadata_estimated_intrinsics"] = String(framesWithMetadataEstimatedIntrinsics)
        metrics["preview_import_frames_using_colmap_default_intrinsics"] = String(framesUsingColmapDefaultIntrinsics)
        let framesUsingFallbackIntrinsics =
            framesWithMetadataEstimatedIntrinsics + framesUsingColmapDefaultIntrinsics
        metrics["preview_import_frames_using_fallback_intrinsics"] = String(framesUsingFallbackIntrinsics)
        metrics["preview_import_sampling_interval_ms"] = String(Int((samplingIntervalSeconds * 1000.0).rounded()))
        if let focalLength35mmEquivalentMM {
            metrics["preview_import_focal_length_35mm_equivalent_mm"] = String(format: "%.2f", focalLength35mmEquivalentMM)
        }
        if framesWithSidecarIntrinsics > 0 &&
            framesWithCameraIntrinsics == 0 &&
            framesWithMetadataEstimatedIntrinsics == 0 &&
            framesUsingColmapDefaultIntrinsics == 0 {
            metrics["preview_import_intrinsics_source"] = "capture_sidecar"
        } else if framesUsingFallbackIntrinsics == 0 && framesWithSidecarIntrinsics == 0 {
            metrics["preview_import_intrinsics_source"] = "real"
        } else if framesWithSidecarIntrinsics > 0 &&
            framesWithMetadataEstimatedIntrinsics == 0 &&
            framesUsingColmapDefaultIntrinsics == 0 {
            metrics["preview_import_intrinsics_source"] = "mixed_sidecar"
        } else if framesUsingColmapDefaultIntrinsics == 0 &&
            framesWithCameraIntrinsics == 0 &&
            framesWithSidecarIntrinsics == 0 {
            metrics["preview_import_intrinsics_source"] = "metadata_35mm"
        } else if framesWithMetadataEstimatedIntrinsics == 0 &&
            framesWithCameraIntrinsics == 0 &&
            framesWithSidecarIntrinsics == 0 {
            metrics["preview_import_intrinsics_source"] = "colmap_default"
        } else if framesWithCameraIntrinsics == 0 {
            metrics["preview_import_intrinsics_source"] = "mixed_fallback"
        } else {
            metrics["preview_import_intrinsics_source"] = "mixed"
        }
        metrics["preview_import_photometric_accepted_frames"] = String(photometricAcceptedFrames)
        metrics["preview_import_photometric_exposure_rejects"] = String(photometricExposureRejects)
        metrics["preview_import_photometric_white_balance_rejects"] = String(photometricWhiteBalanceRejects)
        metrics["preview_import_photometric_last_exposure_score"] = String(format: "%.4f", lastExposureConsistencyScore)
        metrics["preview_import_photometric_last_white_balance_score"] = String(format: "%.4f", lastWhiteBalanceConsistencyScore)
        metrics["preview_import_target_selected_frames"] = String(budget.targetSelectedFrames)
        metrics["preview_import_target_submitted_fps"] = String(format: "%.2f", budget.targetSubmittedFPS)
        metrics["preview_import_min_frame_interval_ms"] = String(Int((samplingIntervalSeconds * 1000.0).rounded()))
        metrics["preview_import_training_min_steps"] = String(budget.trainingMinSteps)
        metrics["preview_import_training_reached_steps"] = String(reachedSteps)
        metrics["preview_import_total_elapsed_ms"] = String(totalElapsedMs)
        metrics["preview_import_max_frames_ahead_of_native"] = String(budget.maxFramesAheadOfNative)
        metrics["preview_import_bootstrap_frame_budget"] = String(budget.bootstrapFrameBudget)
        metrics["preview_import_bootstrap_wait_ms"] = String(Int((budget.bootstrapWaitSeconds * 1000.0).rounded()))
        metrics["preview_import_prefinish_drain_ms"] = String(Int((budget.preFinishDrainSeconds * 1000.0).rounded()))
        metrics["preview_import_poll_interval_ms"] = String(Int((budget.ingestPollIntervalSeconds * 1000.0).rounded()))
        metrics["preview_import_min_depth_results_before_finalize"] = String(budget.minDepthResultsBeforeFinalize)
        metrics["preview_import_foreground_wait_ms"] = String(Int((budget.foregroundActivationWaitSeconds * 1000.0).rounded()))
        metrics["preview_import_inactive_poll_ms"] = String(Int((budget.inactivePollIntervalSeconds * 1000.0).rounded()))
        metrics["preview_import_pose_bootstrap"] = LocalPreviewProductProfile.importedVideoPoseBootstrap
        metrics["preview_import_keyframe_gate"] = LocalPreviewProductProfile.importedVideoKeyframeGate
        metrics["preview_import_seed_init"] = LocalPreviewProductProfile.importedVideoSeedInitialization
        metrics["preview_import_photometric_gate"] = LocalPreviewProductProfile.importedVideoPhotometricGate
        return metrics
    }

    static func appendingDirectCaptureContext(
        to base: [String: String],
        sourceVideoRelativePath: String,
        worldStateFrameCount: Int,
        surfaceSampleCount: Int,
        budget: DirectCaptureLocalPreviewBudget,
        reachedSteps: Int,
        totalElapsedMs: UInt64,
        exportAttempts: Int? = nil,
        exportFileSizeBytes: UInt64? = nil
    ) -> [String: String] {
        var metrics = base
        metrics["preview_capture_source_kind"] =
            LocalPreviewProductProfile.directCaptureSourceKind(sourceVideoRelativePath: sourceVideoRelativePath)
        metrics["preview_capture_world_state_frames"] = String(worldStateFrameCount)
        metrics["preview_capture_surface_samples"] = String(surfaceSampleCount)
        metrics["preview_capture_training_min_steps"] = String(budget.trainingMinSteps)
        metrics["preview_capture_training_reached_steps"] = String(reachedSteps)
        metrics["preview_capture_training_timeout_seconds"] = String(
            Int(budget.trainingTimeoutSeconds.rounded())
        )
        metrics["preview_capture_poll_interval_ms"] = String(
            Int((budget.ingestPollIntervalSeconds * 1000.0).rounded())
        )
        metrics["preview_capture_export_attempt_limit"] = String(budget.exportAttemptLimit)
        metrics["preview_capture_export_wait_floor_seconds"] = String(
            Int(budget.exportWaitFloorSeconds.rounded())
        )
        metrics["preview_capture_extra_refine_tail_seconds"] = String(
            Int(budget.extraRefineTailSeconds.rounded())
        )
        metrics["preview_capture_total_elapsed_ms"] = String(totalElapsedMs)
        if let exportAttempts {
            metrics["preview_capture_export_attempts"] = String(exportAttempts)
        }
        if let exportFileSizeBytes {
            metrics["preview_capture_export_file_size_bytes"] = String(exportFileSizeBytes)
        }
        return metrics
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { partialResult, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partialResult.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    private static func thermalStateLabel(_ thermalState: ProcessInfo.ThermalState) -> String {
        switch thermalState {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }
}
#endif
