//
//  BuildRequest.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation
typealias VideoAsset = AVAsset
#else
// Linux stub: minimal type to satisfy compilation
struct VideoAsset {
    // Stub type for Linux builds where AVFoundation is unavailable
}
#endif

struct BuildRequest {
    enum Source {
        case video(asset: VideoAsset)
        case file(url: URL)
        // Phase 1-2a 只支持 video，照片留到 1-2b / 1-3
    }

    let source: Source
    let requestedMode: BuildMode
    let deviceTier: DeviceTier
}

