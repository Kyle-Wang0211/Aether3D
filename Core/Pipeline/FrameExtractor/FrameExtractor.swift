//
//  FrameExtractor.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import AVFoundation
import CoreGraphics

struct FrameExtractor {

    func extractFrames(
        asset: AVAsset,
        frameBudget: Int
    ) async throws -> [Frame] {

        guard frameBudget > 0 else {
            throw PipelineError.invalidInput
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else {
            throw PipelineError.extractFramesFailed
        }

        let count = min(frameBudget, Int(duration.rounded(.down)))
        let step = duration / Double(count)

        var frames: [Frame] = []

        for i in 0..<count {
            if Task.isCancelled {
                throw PipelineError.cancelled
            }

            let time = CMTime(seconds: Double(i) * step, preferredTimescale: 600)

            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                frames.append(
                    Frame(
                        index: i,
                        timestamp: CMTimeGetSeconds(time),
                        image: cgImage
                    )
                )
            } catch {
                throw PipelineError.extractFramesFailed
            }
        }

        return frames
    }
}

