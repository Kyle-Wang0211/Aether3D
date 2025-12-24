//
//  PhotoSpaceBuilderB.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

struct PhotoSpaceBuilderB {

    func build(
        plan: BuildPlan,
        frames: [Frame]
    ) async throws -> PhotoSpaceArtifact {

        if Task.isCancelled {
            throw PipelineError.cancelled
        }

        let limitedFrames = Array(frames.prefix(plan.frameBudget))

        let simulatedDelayMs = min(300, max(100, plan.timeBudgetMs / 20))
        try await Task.sleep(nanoseconds: UInt64(simulatedDelayMs) * 1_000_000)

        return PhotoSpaceArtifact(
            frames: limitedFrames,
            generatedAt: Date()
        )
    }
}

