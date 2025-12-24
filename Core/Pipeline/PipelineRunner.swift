//
//  PipelineRunner.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import AVFoundation

final class PipelineRunner {

    func run(
        request: BuildRequest,
        onState: ((PipelineState) -> Void)?
    ) async -> Result<BuildResult, PipelineError> {

        let startTime = Date()

        do {
            onState?(.planning)

            let planStart = Date()
            let plan = RouterV0.makePlan(
                input: .init(
                    deviceTier: request.deviceTier,
                    captureStats: .placeholder,
                    runtimeState: .current(),
                    requestedMode: request.requestedMode
                )
            )
            let planMs = Int(Date().timeIntervalSince(planStart) * 1000)
            print("PLAN:", plan.debugSummary)

            onState?(.extractingFrames(progress: 0))

            guard case let .video(asset) = request.source else {
                return .failure(.invalidInput)
            }

            let extractor = FrameExtractor()
            let extractStart = Date()
            let frames = try await extractor.extractFrames(
                asset: asset,
                frameBudget: plan.frameBudget
            )
            let extractMs = Int(Date().timeIntervalSince(extractStart) * 1000)
            print("EXTRACT: frames=\(frames.count) ms=\(extractMs)")

            onState?(.buildingArtifact(progress: 0))

            let builder = PhotoSpaceBuilderB()
            let buildStart = Date()
            let artifact = try await builder.build(plan: plan, frames: frames)
            let buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
            print("BUILD: framesUsed=\(artifact.frames.count) ms=\(buildMs)")

            let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
            print("DONE: totalMs=\(totalMs)")

            onState?(.finished)

            return .success(
                BuildResult(
                    planSummary: plan.debugSummary,
                    artifact: artifact,
                    timings: .init(
                        planMs: planMs,
                        extractMs: extractMs,
                        buildMs: buildMs,
                        totalMs: totalMs
                    )
                )
            )

        } catch let error as PipelineError {
            onState?(.failed(message: "\(error)"))
            return .failure(error)
        } catch {
            onState?(.failed(message: "unknown"))
            return .failure(.internalInconsistency)
        }
    }
}

