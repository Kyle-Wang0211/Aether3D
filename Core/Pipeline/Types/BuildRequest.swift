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

public struct BuildRequest {
    public enum Source {
        case video(asset: VideoAsset)
        case file(url: URL)
        // Phase 1-2a 只支持 video，照片留到 1-2b / 1-3
    }

    public let source: Source
    public let requestedMode: BuildMode
    public let deviceTier: DeviceTier

    public init(source: Source, requestedMode: BuildMode, deviceTier: DeviceTier) {
        self.source = source
        self.requestedMode = requestedMode
        self.deviceTier = deviceTier
    }
}

