//
// LocalPreviewProductProfile.swift
// Aether3D
//
// Product-facing on-device subject-first configuration extracted out of
// individual runners so the native recorded-video path can evolve
// independently from shared UI orchestration and cloud routing.
//

import Foundation
import Aether3DCore

enum LocalPreviewWorkflowPhase: String, CaseIterable, Sendable {
    case depth
    case seed
    case refine
    case cutout
    case cleanup
    case export

    var title: String {
        switch self {
        case .depth:
            return "深度先验"
        case .seed:
            return "初始化高斯"
        case .refine:
            return "本地 refine"
        case .cutout:
            return "主体裁切"
        case .cleanup:
            return "边角清理"
        case .export:
            return "导出结果"
        }
    }

    var progressBasis: String {
        "local_subject_first_\(rawValue)"
    }

    var legacyProgressBasis: String {
        "local_preview_\(rawValue)"
    }

    var phaseName: String {
        rawValue
    }

    var startFraction: Double {
        switch self {
        case .depth:
            return 0.08
        case .seed:
            return 0.30
        case .refine:
            return 0.52
        case .cutout:
            return 0.74
        case .cleanup:
            return 0.84
        case .export:
            return 0.92
        }
    }

    var defaultActiveFraction: Double {
        switch self {
        case .depth:
            return 0.18
        case .seed:
            return 0.38
        case .refine:
            return 0.64
        case .cutout:
            return 0.79
        case .cleanup:
            return 0.88
        case .export:
            return 0.96
        }
    }

    var detailMessage: String {
        switch self {
        case .depth:
            return "正在做多帧单目深度先验，先把可用于本地结果生成的几何线索补齐。"
        case .seed:
            return "正在根据深度先验初始化高斯种子，筛掉不稳定和低质量 seed。"
        case .refine:
            return "正在做有上限的本地 refine，只追求尽快得到一个能看的本地结果。"
        case .cutout:
            return "正在沿着主体主簇做显式 cutout，先把能看的主体边界站住。"
        case .cleanup:
            return "正在保守清理低覆盖碎边和浮空小块，同时尽量保住主体和接触面。"
        case .export:
            return "本地训练已经收口，正在导出可交互结果。"
        }
    }

    var completedProgressText: String {
        "已完成"
    }
}

struct LocalPreviewPhaseUpdate: Sendable {
    let phase: LocalPreviewWorkflowPhase
    let progressFraction: Double
    let title: String
    let detail: String
    let runtimeMetrics: [String: String]
}

struct ImportedLocalPreviewBudget: Sendable {
    let minFrameIntervalSeconds: Double
    let targetSubmittedFPS: Double
    let maxSubmittedFrames: Int
    let targetSelectedFrames: Int
    let minimumSelectedFramesToStartTraining: Int
    let minimumProcessedFramesBeforeFinalize: Int
    let trainingMinSteps: Int
    let trainingTimeoutSeconds: Double
    let maxFramesAheadOfNative: Int
    let maxFramesAheadBeforeFinalize: Int
    let ingestPollIntervalSeconds: Double
    let bootstrapFrameBudget: Int
    let bootstrapWaitSeconds: Double
    let preFinishDrainSeconds: Double
    let minDepthResultsBeforeFinalize: Int
    let foregroundActivationWaitSeconds: Double
    let inactivePollIntervalSeconds: Double
    let nativeCatchUpStride: Int
}

struct DirectCaptureLocalPreviewBudget: Sendable {
    let trainingMinSteps: Int
    let trainingTimeoutSeconds: Double
    let ingestPollIntervalSeconds: Double
    let exportAttemptLimit: Int
    let exportWaitFloorSeconds: Double
    let extraRefineTailSeconds: Double
}

enum LocalPreviewProductProfile {
    static let defaultCloudPipelineMode = "monocular_ref_depth"
    static let defaultSubjectFirstPipelineMode = "monocular_subject_first_result"
    static let depthPriorSource = "depthanything_v2_coreml"
    static let depthPriorTransport = "ref_depth"
    static let depthPriorProfile = "small_only_fast_native"

    static let subjectFirstCurrentDepthPrior = "video_depth_runtime_optional + dav2_temporal_consistency_assist"
    static let subjectFirstTargetDepthPrior = "video_depth_anything_v2"
    static let subjectFirstCurrentBootstrap = "native_icp_repo_mvs_seed"
    static let subjectFirstTargetBootstrap = "vggt_lite"

    static let importedVideoPoseBootstrap = "native_online_depth_bootstrap"
    static let importedVideoKeyframeGate = "subject_first_strong_motion_gate"
    static let importedVideoSeedInitialization = "repo_mvs_initialize_primary + repo_dav2_assist_prior"
    static let importedVideoPhotometricGate = "pr5_exposure_white_balance_consistency"

    private static func normalizedBackend(
        _ processingBackend: ProcessingBackendChoice
    ) -> ProcessingBackendChoice {
        processingBackend.normalizedForActiveUse
    }

    static func phase(
        for progressBasis: String?,
        phaseName: String?,
        processingBackend: ProcessingBackendChoice = .localSubjectFirst
    ) -> LocalPreviewWorkflowPhase? {
        if let phaseName {
            let normalized = phaseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let phase = LocalPreviewWorkflowPhase(rawValue: normalized),
               workflowPhases(for: processingBackend).contains(phase) {
                return phase
            }
        }
        if let progressBasis {
            let normalized = progressBasis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return workflowPhases(for: processingBackend).first(where: {
                $0.progressBasis == normalized || $0.legacyProgressBasis == normalized
            })
        }
        return nil
    }

    static func makePhaseUpdate(
        phase: LocalPreviewWorkflowPhase,
        runtimeMetrics: [String: String],
        processingBackend: ProcessingBackendChoice = .localSubjectFirst,
        progressFraction: Double? = nil,
        detailOverride: String? = nil
    ) -> LocalPreviewPhaseUpdate {
        LocalPreviewPhaseUpdate(
            phase: phase,
            progressFraction: progressFraction ?? defaultActiveFraction(for: phase, processingBackend: processingBackend),
            title: phase.title,
            detail: detailOverride ?? phase.detailMessage,
            runtimeMetrics: runtimeMetrics
        )
    }

    static func workflowPhases(
        for processingBackend: ProcessingBackendChoice
    ) -> [LocalPreviewWorkflowPhase] {
        if normalizedBackend(processingBackend) == .cloud {
            return [.depth, .seed, .refine, .export]
        }
        return [.depth, .seed, .refine, .cutout, .cleanup, .export]
    }

    static func nativePipelineMode(
        for processingBackend: ProcessingBackendChoice
    ) -> String {
        normalizedBackend(processingBackend) == .cloud
            ? defaultCloudPipelineMode
            : defaultSubjectFirstPipelineMode
    }

    static func phaseModelDescriptor(
        for processingBackend: ProcessingBackendChoice
    ) -> String {
        normalizedBackend(processingBackend) == .localSubjectFirst
            ? "recorded_video_depth_seed_refine_cutout_cleanup_export"
            : "recorded_video_depth_seed_refine_export"
    }

    static func defaultActiveFraction(
        for phase: LocalPreviewWorkflowPhase,
        processingBackend: ProcessingBackendChoice
    ) -> Double {
        if normalizedBackend(processingBackend) != .cloud {
            return phase.defaultActiveFraction
        }
        switch phase {
        case .depth:
            return 0.18
        case .seed:
            return 0.42
        case .refine:
            return 0.72
        case .export:
            return 0.94
        case .cutout, .cleanup:
            return 0.94
        }
    }

    static func nextPhaseStartFraction(
        after phase: LocalPreviewWorkflowPhase,
        processingBackend: ProcessingBackendChoice
    ) -> Double {
        let phases = workflowPhases(for: processingBackend)
        guard let index = phases.firstIndex(of: phase) else {
            return 0.99
        }
        let nextIndex = phases.index(after: index)
        guard nextIndex < phases.endIndex else {
            return 0.99
        }
        return phases[nextIndex].startFraction
    }

    static func directCaptureSourceKind(sourceVideoRelativePath: String?) -> String {
        return "direct_capture_video"
    }

    static func importedVideoBudget(
        for frameSamplingProfile: FrameSamplingProfile
    ) -> ImportedLocalPreviewBudget {
        switch frameSamplingProfile {
        case .full:
            return ImportedLocalPreviewBudget(
                minFrameIntervalSeconds: 0.0,
                targetSubmittedFPS: 4.0,
                maxSubmittedFrames: 120,
                targetSelectedFrames: 24,
                minimumSelectedFramesToStartTraining: 3,
                minimumProcessedFramesBeforeFinalize: 10,
                trainingMinSteps: 1500,
                trainingTimeoutSeconds: 300.0,
                maxFramesAheadOfNative: 54,
                maxFramesAheadBeforeFinalize: 16,
                ingestPollIntervalSeconds: 0.005,
                bootstrapFrameBudget: 12,
                bootstrapWaitSeconds: 0.6,
                preFinishDrainSeconds: 4.0,
                minDepthResultsBeforeFinalize: 1,
                foregroundActivationWaitSeconds: 0.35,
                inactivePollIntervalSeconds: 0.10,
                nativeCatchUpStride: 32
            )
        case .half:
            return ImportedLocalPreviewBudget(
                minFrameIntervalSeconds: 0.0,
                targetSubmittedFPS: 3.0,
                maxSubmittedFrames: 72,
                targetSelectedFrames: 16,
                minimumSelectedFramesToStartTraining: 3,
                minimumProcessedFramesBeforeFinalize: 8,
                trainingMinSteps: 1200,
                trainingTimeoutSeconds: 240.0,
                maxFramesAheadOfNative: 36,
                maxFramesAheadBeforeFinalize: 12,
                ingestPollIntervalSeconds: 0.005,
                bootstrapFrameBudget: 8,
                bootstrapWaitSeconds: 0.5,
                preFinishDrainSeconds: 3.5,
                minDepthResultsBeforeFinalize: 1,
                foregroundActivationWaitSeconds: 0.35,
                inactivePollIntervalSeconds: 0.10,
                nativeCatchUpStride: 24
            )
        case .third:
            return ImportedLocalPreviewBudget(
                minFrameIntervalSeconds: 0.0,
                targetSubmittedFPS: 2.0,
                maxSubmittedFrames: 48,
                targetSelectedFrames: 10,
                minimumSelectedFramesToStartTraining: 3,
                minimumProcessedFramesBeforeFinalize: 6,
                trainingMinSteps: 900,
                trainingTimeoutSeconds: 180.0,
                maxFramesAheadOfNative: 24,
                maxFramesAheadBeforeFinalize: 8,
                ingestPollIntervalSeconds: 0.005,
                bootstrapFrameBudget: 6,
                bootstrapWaitSeconds: 0.4,
                preFinishDrainSeconds: 3.0,
                minDepthResultsBeforeFinalize: 1,
                foregroundActivationWaitSeconds: 0.35,
                inactivePollIntervalSeconds: 0.10,
                nativeCatchUpStride: 16
            )
        }
    }

    static func directCaptureBudget() -> DirectCaptureLocalPreviewBudget {
        DirectCaptureLocalPreviewBudget(
            trainingMinSteps: 2400,
            trainingTimeoutSeconds: 360.0,
            ingestPollIntervalSeconds: 0.10,
            exportAttemptLimit: 3,
            exportWaitFloorSeconds: 45.0,
            extraRefineTailSeconds: 45.0
        )
    }

    static func canonicalRuntimeMetrics(_ runtimeMetrics: [String: String]) -> [String: String] {
        var canonical: [String: String] = [:]
        for (key, value) in runtimeMetrics {
            let canonicalKey = canonicalMetricKey(for: key)
            canonical[canonicalKey] = canonicalMetricValue(
                for: canonicalKey,
                originalKey: key,
                value: value
            )
        }
        return canonical
    }

    static func runtimeMetricString(
        _ key: String,
        from runtimeMetrics: [String: String]?
    ) -> String? {
        guard let runtimeMetrics else { return nil }
        for candidate in runtimeMetricLookupKeys(for: key) {
            if let value = runtimeMetrics[candidate]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func setRuntimeMetric(
        _ key: String,
        value: String?,
        in metrics: inout [String: String]
    ) {
        guard let value else { return }
        let canonicalKey = canonicalMetricKey(for: key)
        metrics[canonicalKey] = canonicalMetricValue(
            for: canonicalKey,
            originalKey: key,
            value: value
        )
    }

    private static let canonicalMetricKeyOverrides: [String: String] = [
        "preview_mode": "native_pipeline_mode",
        "preview_source_kind": "native_input_kind",
        "preview_capture_source_kind": "native_capture_input_kind",
        "preview_active_phase": "native_active_phase",
        "preview_phase_model": "native_phase_model",
        "preview_trace_last_event": "native_trace_last_event",
        "preview_trace_log": "native_trace_log",
        "preview_gaussians_current": "native_current_gaussians",
        "preview_peak_gaussians": "native_peak_gaussians",
        "preview_fallback_from": "native_handoff_from",
        "preview_failure_reason": "native_failure_reason",
        "preview_export_failure_reason": "native_export_failure_reason",
        "preview_native_frames_enqueued": "native_frames_enqueued",
        "preview_native_frames_ingested": "native_frames_ingested",
        "preview_native_frame_backlog": "native_frame_backlog",
        "preview_import_frames_using_fallback_intrinsics": "native_import_frames_using_estimated_intrinsics",
        "preview_subject_cleanup_fallback": "native_subject_cleanup_strategy",
    ]

    private static func runtimeMetricLookupKeys(for key: String) -> [String] {
        var candidates: [String] = []
        let canonical = canonicalMetricKey(for: key)
        let legacy = legacyMetricKey(for: key)

        func appendUnique(_ candidate: String) {
            guard !candidate.isEmpty, !candidates.contains(candidate) else { return }
            candidates.append(candidate)
        }

        appendUnique(canonical)
        appendUnique(key)
        appendUnique(legacy)
        return candidates
    }

    private static func canonicalMetricKey(for key: String) -> String {
        if let override = canonicalMetricKeyOverrides[key] {
            return override
        }
        if key.hasPrefix("preview_") {
            return "native_" + key.dropFirst("preview_".count)
        }
        return key
    }

    private static func legacyMetricKey(for key: String) -> String {
        if let legacy = canonicalMetricKeyOverrides.first(where: { $0.value == key })?.key {
            return legacy
        }
        if key.hasPrefix("native_") {
            return "preview_" + key.dropFirst("native_".count)
        }
        return key
    }

    private static func canonicalMetricValue(
        for canonicalKey: String,
        originalKey: String,
        value: String
    ) -> String {
        switch canonicalKey {
        case "native_input_kind", "native_capture_input_kind":
            switch value {
            case "imported_video":
                return "recorded_video"
            case "captured_video", "direct_capture_video":
                return "recorded_video_from_capture"
            case "captured_video_missing":
                return "recorded_video_missing"
            case "direct_capture":
                return "live_capture"
            default:
                return value
            }
        case "native_phase_model":
            switch value {
            case "captured_video_depth_seed_refine_cutout_cleanup_export":
                return "recorded_video_from_capture_depth_seed_refine_cutout_cleanup_export"
            case "captured_video_depth_seed_refine_export":
                return "recorded_video_from_capture_depth_seed_refine_export"
            case "depth_seed_refine_cutout_cleanup_export":
                return "recorded_video_depth_seed_refine_cutout_cleanup_export"
            case "depth_seed_refine_export":
                return "recorded_video_depth_seed_refine_export"
            default:
                return value
            }
        case "native_import_intrinsics_source":
            return value == "mixed_fallback" ? "mixed_estimated" : value
        case "native_import_suitability_verdict":
            return value == "fallback_remote" ? "remote_recommended" : value
        case "native_subject_cleanup_strategy":
            return value == "disabled_raw_fallback" ? "disabled_raw_retention" : value
        default:
            if originalKey == "preview_subject_cleanup_fallback",
               value == "disabled_raw_fallback" {
                return "disabled_raw_retention"
            }
            return value
        }
    }
}
