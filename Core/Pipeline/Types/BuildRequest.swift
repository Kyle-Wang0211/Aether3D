//
//  BuildRequest.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import AVFoundation

struct BuildRequest {
    enum Source {
        case video(asset: AVAsset)
        // Phase 1-2a 只支持 video，照片留到 1-2b / 1-3
    }

    let source: Source
    let requestedMode: BuildMode
    let deviceTier: DeviceTier
}

