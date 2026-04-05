//
// LocalPreviewMetricsArchive.swift
// Aether3D
//
// Stable archive schema for on-device native telemetry. This keeps runtime
// metrics ownership out of shared view models so the recorded-video path can
// keep evolving independently from cloud orchestration.
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
        processingBackend: ProcessingBackendChoice = .localSubjectFirst,
        thermalState: ProcessInfo.ThermalState? = nil,
        exportElapsedMs: UInt64? = nil
    ) -> [String: String] {
        let processingBackend = processingBackend.normalizedForActiveUse
        let currentThermal = thermalState ?? ProcessInfo.processInfo.thermalState
        var metrics: [String: String] = [
            "processing_backend": processingBackend.rawValue,
            "native_pipeline_mode": LocalPreviewProductProfile.nativePipelineMode(for: processingBackend),
            "depth_prior_source": LocalPreviewProductProfile.depthPriorSource,
            "depth_prior_transport": LocalPreviewProductProfile.depthPriorTransport,
            "depth_prior_profile": LocalPreviewProductProfile.depthPriorProfile,
            "native_input_kind": sourceKind,
            "device_model": deviceModelIdentifier(),
            "thermal_state_raw": String(currentThermal.rawValue),
            "thermal_state_label": thermalStateLabel(currentThermal),
        ]
        if processingBackend == .localSubjectFirst {
            metrics["native_subject_first_enabled"] = "1"
            metrics["native_subject_depth_prior_current"] =
                LocalPreviewProductProfile.subjectFirstCurrentDepthPrior
            metrics["native_subject_depth_prior_target"] =
                LocalPreviewProductProfile.subjectFirstTargetDepthPrior
            metrics["native_subject_bootstrap_current"] =
                LocalPreviewProductProfile.subjectFirstCurrentBootstrap
            metrics["native_subject_bootstrap_target"] =
                LocalPreviewProductProfile.subjectFirstTargetBootstrap
        }
        if let sourceVideo {
            metrics["source_video"] = sourceVideo
        }
        if let exported {
            metrics["native_export_succeeded"] = exported ? "1" : "0"
        }
        if let exportElapsedMs {
            metrics["native_export_ms"] = String(exportElapsedMs)
        }
        guard let snapshot else {
            return LocalPreviewProductProfile.canonicalRuntimeMetrics(metrics)
        }
        metrics["native_elapsed_ms"] = String(snapshot.onDeviceElapsedMs)
        metrics["native_phase_depth_ms"] = String(snapshot.onDeviceDepthPhaseMs)
        metrics["native_phase_seed_ms"] = String(snapshot.onDeviceSeedPhaseMs)
        metrics["native_phase_refine_ms"] = String(snapshot.onDeviceRefinePhaseMs)
        metrics["native_processed_frames"] = String(snapshot.onDeviceFramesIngested)
        metrics["native_depth_batches_submitted"] = String(snapshot.onDeviceDepthBatchesSubmitted)
        metrics["native_depth_results_ready"] = String(snapshot.onDeviceDepthResultsReady)
        metrics["native_depth_reuse_frames"] = String(snapshot.onDeviceDepthReuseFrames)
        metrics["native_prefilter_accepts"] = String(snapshot.onDevicePrefilterAccepts)
        metrics["native_prefilter_brightness_rejects"] = String(snapshot.onDevicePrefilterBrightnessRejects)
        metrics["native_prefilter_blur_rejects"] = String(snapshot.onDevicePrefilterBlurRejects)
        metrics["native_keyframe_gate_accepts"] = String(snapshot.onDeviceKeyframeGateAccepts)
        metrics["native_keyframe_gate_rejects"] = String(snapshot.onDeviceKeyframeGateRejects)
        metrics["native_imported_frames_evaluated"] = String(snapshot.onDeviceImportedFramesEvaluated)
        metrics["native_imported_low_parallax_rejects"] = String(snapshot.onDeviceImportedLowParallaxRejects)
        metrics["native_imported_near_duplicate_rejects"] = String(snapshot.onDeviceImportedNearDuplicateRejects)
        metrics["native_imported_selected_keyframes"] = String(snapshot.onDeviceImportedSelectedKeyframes)
        metrics["native_imported_selected_translation_mean_mm"] = String(
            format: "%.2f",
            snapshot.onDeviceImportedSelectedTranslationMeanMm
        )
        metrics["native_imported_selected_rotation_mean_deg"] = String(
            format: "%.2f",
            snapshot.onDeviceImportedSelectedRotationMeanDeg
        )
        metrics["native_imported_selected_overlap_mean"] = String(
            format: "%.4f",
            snapshot.onDeviceImportedSelectedOverlapMean
        )
        metrics["native_seed_candidates"] = String(snapshot.onDeviceSeedCandidates)
        metrics["native_seed_accepted"] = String(snapshot.onDeviceSeedAccepted)
        metrics["native_seed_rejected"] = String(snapshot.onDeviceSeedRejected)
        metrics["native_seed_quality_mean"] = String(format: "%.4f", snapshot.onDeviceSeedQualityMean)
        metrics["native_frames_enqueued"] = String(snapshot.onDeviceFramesEnqueued)
        metrics["native_frames_ingested"] = String(snapshot.onDeviceFramesIngested)
        metrics["native_frame_backlog"] = String(snapshot.onDeviceFrameBacklog)
        metrics["native_selected_frames"] = String(snapshot.selected_frames)
        metrics["native_min_frames_needed"] = String(snapshot.min_frames_needed)
        metrics["native_gaussians"] = String(snapshot.num_gaussians)
        metrics["native_training_progress"] = String(format: "%.4f", snapshot.training_progress)
        metrics["native_coverage"] = String(format: "%.4f", snapshot.coverage)
        metrics["native_overall_quality"] = String(format: "%.4f", snapshot.overall_quality)
        return LocalPreviewProductProfile.canonicalRuntimeMetrics(metrics)
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
        metrics["native_import_width"] = String(width)
        metrics["native_import_height"] = String(height)
        metrics["native_import_duration_s"] = String(format: "%.3f", durationSeconds)
        metrics["native_import_sampled_frames"] = String(sampledFrames)
        metrics["native_import_submitted_frames"] = String(submittedFrames)
        metrics["native_import_frames_with_camera_intrinsics"] = String(framesWithCameraIntrinsics)
        metrics["native_import_frames_with_sidecar_intrinsics"] = String(framesWithSidecarIntrinsics)
        metrics["native_import_frames_with_metadata_estimated_intrinsics"] = String(framesWithMetadataEstimatedIntrinsics)
        metrics["native_import_frames_using_colmap_default_intrinsics"] = String(framesUsingColmapDefaultIntrinsics)
        let framesUsingFallbackIntrinsics =
            framesWithMetadataEstimatedIntrinsics + framesUsingColmapDefaultIntrinsics
        metrics["native_import_frames_using_estimated_intrinsics"] = String(framesUsingFallbackIntrinsics)
        metrics["native_import_sampling_interval_ms"] = String(Int((samplingIntervalSeconds * 1000.0).rounded()))
        if let focalLength35mmEquivalentMM {
            metrics["native_import_focal_length_35mm_equivalent_mm"] = String(format: "%.2f", focalLength35mmEquivalentMM)
        }
        if framesWithSidecarIntrinsics > 0 &&
            framesWithCameraIntrinsics == 0 &&
            framesWithMetadataEstimatedIntrinsics == 0 &&
            framesUsingColmapDefaultIntrinsics == 0 {
            metrics["native_import_intrinsics_source"] = "capture_sidecar"
        } else if framesUsingFallbackIntrinsics == 0 && framesWithSidecarIntrinsics == 0 {
            metrics["native_import_intrinsics_source"] = "real"
        } else if framesWithSidecarIntrinsics > 0 &&
            framesWithMetadataEstimatedIntrinsics == 0 &&
            framesUsingColmapDefaultIntrinsics == 0 {
            metrics["native_import_intrinsics_source"] = "mixed_sidecar"
        } else if framesUsingColmapDefaultIntrinsics == 0 &&
            framesWithCameraIntrinsics == 0 &&
            framesWithSidecarIntrinsics == 0 {
            metrics["native_import_intrinsics_source"] = "metadata_35mm"
        } else if framesWithMetadataEstimatedIntrinsics == 0 &&
            framesWithCameraIntrinsics == 0 &&
            framesWithSidecarIntrinsics == 0 {
            metrics["native_import_intrinsics_source"] = "colmap_default"
        } else if framesWithCameraIntrinsics == 0 {
            metrics["native_import_intrinsics_source"] = "mixed_estimated"
        } else {
            metrics["native_import_intrinsics_source"] = "mixed"
        }
        metrics["native_import_photometric_accepted_frames"] = String(photometricAcceptedFrames)
        metrics["native_import_photometric_exposure_rejects"] = String(photometricExposureRejects)
        metrics["native_import_photometric_white_balance_rejects"] = String(photometricWhiteBalanceRejects)
        metrics["native_import_photometric_last_exposure_score"] = String(format: "%.4f", lastExposureConsistencyScore)
        metrics["native_import_photometric_last_white_balance_score"] = String(format: "%.4f", lastWhiteBalanceConsistencyScore)
        metrics["native_import_target_selected_frames"] = String(budget.targetSelectedFrames)
        metrics["native_import_target_submitted_fps"] = String(format: "%.2f", budget.targetSubmittedFPS)
        metrics["native_import_min_frame_interval_ms"] = String(Int((samplingIntervalSeconds * 1000.0).rounded()))
        metrics["native_import_training_min_steps"] = String(budget.trainingMinSteps)
        metrics["native_import_training_reached_steps"] = String(reachedSteps)
        metrics["native_import_total_elapsed_ms"] = String(totalElapsedMs)
        metrics["native_import_max_frames_ahead_of_native"] = String(budget.maxFramesAheadOfNative)
        metrics["native_import_bootstrap_frame_budget"] = String(budget.bootstrapFrameBudget)
        metrics["native_import_bootstrap_wait_ms"] = String(Int((budget.bootstrapWaitSeconds * 1000.0).rounded()))
        metrics["native_import_prefinish_drain_ms"] = String(Int((budget.preFinishDrainSeconds * 1000.0).rounded()))
        metrics["native_import_poll_interval_ms"] = String(Int((budget.ingestPollIntervalSeconds * 1000.0).rounded()))
        metrics["native_import_min_depth_results_before_finalize"] = String(budget.minDepthResultsBeforeFinalize)
        metrics["native_import_foreground_wait_ms"] = String(Int((budget.foregroundActivationWaitSeconds * 1000.0).rounded()))
        metrics["native_import_inactive_poll_ms"] = String(Int((budget.inactivePollIntervalSeconds * 1000.0).rounded()))
        metrics["native_import_pose_bootstrap"] = LocalPreviewProductProfile.importedVideoPoseBootstrap
        metrics["native_import_keyframe_gate"] = LocalPreviewProductProfile.importedVideoKeyframeGate
        metrics["native_import_seed_init"] = LocalPreviewProductProfile.importedVideoSeedInitialization
        metrics["native_import_photometric_gate"] = LocalPreviewProductProfile.importedVideoPhotometricGate
        return LocalPreviewProductProfile.canonicalRuntimeMetrics(metrics)
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
        metrics["native_capture_input_kind"] =
            LocalPreviewProductProfile.directCaptureSourceKind(sourceVideoRelativePath: sourceVideoRelativePath)
        metrics["native_capture_world_state_frames"] = String(worldStateFrameCount)
        metrics["native_capture_surface_samples"] = String(surfaceSampleCount)
        metrics["native_capture_training_min_steps"] = String(budget.trainingMinSteps)
        metrics["native_capture_training_reached_steps"] = String(reachedSteps)
        metrics["native_capture_training_timeout_seconds"] = String(
            Int(budget.trainingTimeoutSeconds.rounded())
        )
        metrics["native_capture_poll_interval_ms"] = String(
            Int((budget.ingestPollIntervalSeconds * 1000.0).rounded())
        )
        metrics["native_capture_export_attempt_limit"] = String(budget.exportAttemptLimit)
        metrics["native_capture_export_wait_floor_seconds"] = String(
            Int(budget.exportWaitFloorSeconds.rounded())
        )
        metrics["native_capture_extra_refine_tail_seconds"] = String(
            Int(budget.extraRefineTailSeconds.rounded())
        )
        metrics["native_capture_total_elapsed_ms"] = String(totalElapsedMs)
        if let exportAttempts {
            metrics["native_capture_export_attempts"] = String(exportAttempts)
        }
        if let exportFileSizeBytes {
            metrics["native_capture_export_file_size_bytes"] = String(exportFileSizeBytes)
        }
        return LocalPreviewProductProfile.canonicalRuntimeMetrics(metrics)
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
