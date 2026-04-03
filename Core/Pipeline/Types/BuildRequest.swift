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
    case localPreview = "local_preview"
    case localSubjectFirst = "local_subject_first"

    public static let userDefaultsKey = "aether.processingBackendChoice"

    public static func currentSelection(userDefaults: UserDefaults = .standard) -> ProcessingBackendChoice {
        let rawValue = userDefaults.string(forKey: userDefaultsKey)
        guard let rawValue else { return .cloud }
        switch ProcessingBackendChoice(rawValue: rawValue) {
        case .localPreview:
            return .localSubjectFirst
        case let backend?:
            return backend
        case nil:
            return .cloud
        }
    }

    public var normalizedForActiveUse: ProcessingBackendChoice {
        switch self {
        case .localPreview:
            return .localSubjectFirst
        case .cloud, .localSubjectFirst:
            return self
        }
    }

    public var title: String {
        switch self {
        case .cloud:
            return "云端"
        case .localPreview, .localSubjectFirst:
            return "本地"
        }
    }

    public var detail: String {
        switch self {
        case .cloud:
            return "高质量"
        case .localPreview, .localSubjectFirst:
            return "本地处理"
        }
    }

    public var displayLabel: String {
        switch self {
        case .cloud:
            return "云端高质量"
        case .localPreview, .localSubjectFirst:
            return "本地处理"
        }
    }

    public var supportsImportedVideoPreview: Bool {
        switch self {
        case .cloud:
            return true
        case .localPreview:
            return true
        case .localSubjectFirst:
            return true
        }
    }

    public var localWorkflowStageKey: String? {
        switch self {
        case .cloud:
            return nil
        case .localPreview, .localSubjectFirst:
            return "local_subject_first"
        }
    }

    public var usesLocalPreviewPipeline: Bool {
        switch self {
        case .cloud:
            return false
        case .localPreview, .localSubjectFirst:
            return true
        }
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
