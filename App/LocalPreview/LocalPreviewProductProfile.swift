//
// LocalPreviewProductProfile.swift
// Aether3D
//
// Product-facing local preview configuration extracted out of individual
// runners so preview budget policy can evolve independently from shared UI
// orchestration and cloud routing.
//

import Foundation
import Aether3DCore

enum LocalPreviewWorkflowPhase: String, CaseIterable, Sendable {
    case depth
    case seed
    case refine
    case export

    var title: String {
        switch self {
        case .depth:
            return "深度先验"
        case .seed:
            return "初始化高斯"
        case .refine:
            return "本地 refine"
        case .export:
            return "导出预览"
        }
    }

    var progressBasis: String {
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
            return 0.34
        case .refine:
            return 0.58
        case .export:
            return 0.88
        }
    }

    var defaultActiveFraction: Double {
        switch self {
        case .depth:
            return 0.18
        case .seed:
            return 0.42
        case .refine:
            return 0.72
        case .export:
            return 0.94
        }
    }

    var detailMessage: String {
        switch self {
        case .depth:
            return "正在做多帧单目深度先验，先把可用于 preview 的几何线索补齐。"
        case .seed:
            return "正在根据深度先验初始化高斯种子，筛掉不稳定和低质量 seed。"
        case .refine:
            return "正在做有上限的本地 refine，只追求尽快得到一个能看的 preview。"
        case .export:
            return "本地训练已经收口，正在导出可交互预览结果。"
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
    static let previewMode = "monocular_ref_depth"
    static let depthPriorSource = "depthanything_v2_coreml"
    static let depthPriorTransport = "ref_depth"
    static let depthPriorProfile = "small_only_fast_preview"

    static let importedVideoPoseBootstrap = "native_online_depth_bootstrap"
    static let importedVideoKeyframeGate = "native_depth_backed_overlap_gate"
    static let importedVideoSeedInitialization = "repo_mvs_initialize_primary + repo_dav2_fallback_prior"
    static let importedVideoPhotometricGate = "pr5_exposure_white_balance_consistency"

    static let workflowPhases: [LocalPreviewWorkflowPhase] = LocalPreviewWorkflowPhase.allCases

    static func phase(
        for progressBasis: String?,
        phaseName: String?
    ) -> LocalPreviewWorkflowPhase? {
        if let phaseName {
            let normalized = phaseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let phase = LocalPreviewWorkflowPhase(rawValue: normalized) {
                return phase
            }
        }
        if let progressBasis {
            let normalized = progressBasis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return workflowPhases.first(where: { $0.progressBasis == normalized })
        }
        return nil
    }

    static func makePhaseUpdate(
        phase: LocalPreviewWorkflowPhase,
        runtimeMetrics: [String: String],
        progressFraction: Double? = nil,
        detailOverride: String? = nil
    ) -> LocalPreviewPhaseUpdate {
        LocalPreviewPhaseUpdate(
            phase: phase,
            progressFraction: progressFraction ?? phase.defaultActiveFraction,
            title: phase.title,
            detail: detailOverride ?? phase.detailMessage,
            runtimeMetrics: runtimeMetrics
        )
    }

    static func directCaptureSourceKind(sourceVideoRelativePath: String?) -> String {
        if sourceVideoRelativePath == "memory_only" {
            return "direct_capture_memory_only"
        }
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
}
