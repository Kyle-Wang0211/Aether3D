// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BuildRequest.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation
public typealias VideoAsset = AVAsset
#else
// Linux stub: minimal type to satisfy compilation
public struct VideoAsset {
    // Stub type for Linux builds where AVFoundation is unavailable
}
#endif

public enum BuildMode: String, Codable, CaseIterable, Sendable {
    case enter
    case publish
    case failSoft
    case NORMAL
    case DAMPING
    case SATURATED
}

public enum DeviceTier: Codable, Sendable {
    case low
    case medium
    case high

    static func detect() -> DeviceTier {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Double(physicalMemory) / (1024 * 1024 * 1024)

        if memoryGB < 4.0 {
            return .low
        } else if memoryGB <= 8.0 {
            return .medium
        } else {
            return .high
        }
    }

    public static func current() -> DeviceTier {
        detect()
    }
}

public enum FrameSamplingProfile: String, Codable, CaseIterable, Sendable {
    case full
    case half
    case third

    public static let userDefaultsKey = "aether.frameSamplingProfile"

    public static func currentSelection(userDefaults: UserDefaults = .standard) -> FrameSamplingProfile {
        let rawValue = userDefaults.string(forKey: userDefaultsKey)
        return FrameSamplingProfile(rawValue: rawValue ?? "") ?? .full
    }

    public var title: String {
        switch self {
        case .full:
            return "全量"
        case .half:
            return "1/2"
        case .third:
            return "1/3"
        }
    }

    public var detail: String {
        switch self {
        case .full:
            return "200 帧"
        case .half:
            return "100 帧"
        case .third:
            return "67 帧"
        }
    }

    public var displayLabel: String {
        switch self {
        case .full:
            return "全量采集"
        case .half:
            return "半量采集"
        case .third:
            return "三分之一采集"
        }
    }

    public var pipelineProfilePayload: [String: String] {
        let fractionText: String
        switch self {
        case .full:
            fractionText = "1.0"
        case .half:
            fractionText = "0.5"
        case .third:
            fractionText = "0.3333333333"
        }
        return [
            "frame_sampling_profile": rawValue,
            "requested_preset_title": displayLabel,
            "requested_frame_fraction": fractionText,
        ]
    }
}

public enum ProcessingBackendChoice: String, Codable, CaseIterable, Sendable {
    case cloud
    @available(*, deprecated, message: "Use localSubjectFirst for on-device recorded-video processing.")
    case localPreview = "local_preview"
    case localSubjectFirst = "local_subject_first"

    public static let userDefaultsKey = "aether.processingBackendChoice"
    public static let allCases: [ProcessingBackendChoice] = [
        .cloud,
        .localSubjectFirst,
    ]

    public static func resolvedStoredSelection(rawValue: String?) -> ProcessingBackendChoice {
        guard let normalized = OnDeviceProcessingCompatibility.normalizedStoredBackendRawValue(rawValue) else {
            return .cloud
        }
        guard let backend = ProcessingBackendChoice(rawValue: normalized) else { return .cloud }
        return backend.normalizedForActiveUse
    }

    public static func canonicalStoredSelectionRawValue(_ rawValue: String?) -> String {
        resolvedStoredSelection(rawValue: rawValue).rawValue
    }

    public static func currentSelection(userDefaults: UserDefaults = .standard) -> ProcessingBackendChoice {
        resolvedStoredSelection(rawValue: userDefaults.string(forKey: userDefaultsKey))
    }

    public var normalizedForActiveUse: ProcessingBackendChoice {
        if OnDeviceProcessingCompatibility.isLegacyStoredBackendRawValue(rawValue) {
            return .localSubjectFirst
        }
        return self
    }

    public var title: String {
        normalizedForActiveUse == .cloud ? "云端" : "本地"
    }

    public var detail: String {
        normalizedForActiveUse == .cloud ? "高质量" : "本地处理"
    }

    public var displayLabel: String {
        normalizedForActiveUse == .cloud ? "云端高质量" : "本地处理"
    }

    public var supportsImportedVideoPreview: Bool {
        true
    }

    public var localWorkflowStageKey: String? {
        normalizedForActiveUse == .cloud ? nil : OnDeviceProcessingCompatibility.canonicalWorkflowStageKey
    }

    public var usesSubjectFirstCaptureContract: Bool {
        switch normalizedForActiveUse {
        case .cloud, .localPreview, .localSubjectFirst:
            return true
        }
    }

    public var usesLocalPreviewPipeline: Bool {
        normalizedForActiveUse != .cloud
    }
}

public enum OnDeviceProcessingCompatibility {
    public static let legacyStoredBackendRawValue = "local_preview"
    public static let canonicalStoredBackendRawValue = ProcessingBackendChoice.localSubjectFirst.rawValue
    public static let legacyWorkflowStageKey = "local_preview"
    public static let canonicalWorkflowStageKey = "local_subject_first"
    public static let canonicalDepthProgressBasis = canonicalWorkflowStageKey + "_depth"
    public static let canonicalSeedProgressBasis = canonicalWorkflowStageKey + "_seed"
    public static let canonicalRefineProgressBasis = canonicalWorkflowStageKey + "_refine"
    public static let canonicalCutoutProgressBasis = canonicalWorkflowStageKey + "_cutout"
    public static let canonicalCleanupProgressBasis = canonicalWorkflowStageKey + "_cleanup"
    public static let canonicalExportProgressBasis = canonicalWorkflowStageKey + "_export"

    public static let legacyImportFailureReason = "local_preview_import_failed"
    public static let canonicalImportFailureReason = "local_subject_first_import_failed"
    public static let legacyBridgeMissingFailureReason = "local_preview_bridge_missing"
    public static let canonicalBridgeMissingFailureReason = "local_subject_first_bridge_missing"
    public static let canonicalInsufficientParallaxFailureReason = "local_subject_first_insufficient_parallax"
    public static let canonicalDuplicateViewsFailureReason = "local_subject_first_duplicate_views"

    public static func normalizedStoredBackendRawValue(_ rawValue: String?) -> String? {
        let normalized = normalizedToken(rawValue)
        switch normalized {
        case legacyStoredBackendRawValue:
            return canonicalStoredBackendRawValue
        default:
            return normalized
        }
    }

    public static func isLegacyStoredBackendRawValue(_ rawValue: String?) -> Bool {
        normalizedToken(rawValue) == legacyStoredBackendRawValue
    }

    public static func normalizedWorkflowStageKey(_ stageKey: String?) -> String? {
        let normalized = normalizedToken(stageKey)
        switch normalized {
        case legacyWorkflowStageKey:
            return canonicalWorkflowStageKey
        default:
            return normalized
        }
    }

    public static func normalizedProgressBasis(_ progressBasis: String?) -> String? {
        guard let normalized = normalizedToken(progressBasis) else { return nil }
        if normalized == legacyWorkflowStageKey {
            return canonicalWorkflowStageKey
        }
        if normalized.hasPrefix(legacyWorkflowStageKey + "_") {
            return canonicalWorkflowStageKey +
                normalized.dropFirst(legacyWorkflowStageKey.count)
        }
        return normalized
    }

    public static func isOnDeviceWorkflowStageKey(_ stageKey: String?) -> Bool {
        normalizedWorkflowStageKey(stageKey) == canonicalWorkflowStageKey
    }

    public static func normalizedFailureReason(_ failureReason: String?) -> String? {
        let normalized = normalizedToken(failureReason)
        switch normalized {
        case legacyImportFailureReason:
            return canonicalImportFailureReason
        case legacyBridgeMissingFailureReason:
            return canonicalBridgeMissingFailureReason
        default:
            return normalized
        }
    }

    public static func progressBasisDisplayTitle(_ progressBasis: String?) -> String? {
        switch normalizedProgressBasis(progressBasis) {
        case canonicalDepthProgressBasis:
            return "深度先验"
        case canonicalSeedProgressBasis:
            return "初始化高斯"
        case canonicalRefineProgressBasis:
            return "本地 refine"
        case canonicalCutoutProgressBasis:
            return "主体裁切"
        case canonicalCleanupProgressBasis:
            return "边角清理"
        case canonicalExportProgressBasis:
            return "导出结果"
        case canonicalWorkflowStageKey:
            return "本地处理"
        default:
            return nil
        }
    }

    public static func failureReasonDisplayTitle(_ failureReason: String?) -> String? {
        switch normalizedFailureReason(failureReason) {
        case canonicalBridgeMissingFailureReason:
            return "本地引擎未启动"
        case canonicalImportFailureReason:
            return "本地处理失败"
        case canonicalInsufficientParallaxFailureReason:
            return "本地视差不足"
        case canonicalDuplicateViewsFailureReason:
            return "近重复视角过多"
        default:
            return nil
        }
    }

    private static func normalizedToken(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

public struct BuildRequest {
    public enum Source {
        case video(asset: VideoAsset)
        case file(url: URL)
        // Phase 1-2a 只支持 video，照片留到 1-2b / 1-3
    }

    public let source: Source
    public let requestedMode: BuildMode
    public let deviceTier: DeviceTier
    public let frameSamplingProfile: FrameSamplingProfile
    public let processingBackend: ProcessingBackendChoice

    public init(
        source: Source,
        requestedMode: BuildMode,
        deviceTier: DeviceTier,
        frameSamplingProfile: FrameSamplingProfile = .full,
        processingBackend: ProcessingBackendChoice = .cloud
    ) {
        self.source = source
        self.requestedMode = requestedMode
        self.deviceTier = deviceTier
        self.frameSamplingProfile = frameSamplingProfile
        self.processingBackend = processingBackend.normalizedForActiveUse
    }
}
