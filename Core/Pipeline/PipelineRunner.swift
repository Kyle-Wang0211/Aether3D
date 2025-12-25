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

            // 获取 sourceVideoURL（用于保存 output）
            let sourceVideoURL: URL
            if let urlAsset = asset as? AVURLAsset {
                sourceVideoURL = urlAsset.url
            } else {
                // Fallback: 使用临时路径
                sourceVideoURL = URL(fileURLWithPath: "/tmp/unknown_video.mov")
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

            // 创建 PipelineOutput 并保存（Phase 1-3）
            let output = PipelineOutput(
                id: UUID(),
                sourceVideoURL: sourceVideoURL,
                frames: artifact.frames,
                buildPlan: plan,
                pluginResult: nil, // Phase 1-3 允许为 nil
                state: .success,
                metadata: PipelineMetadata(
                    processingTimeMs: Double(totalMs),
                    totalFrames: artifact.frames.count
                ),
                createdAt: Date()
            )
            OutputManager.shared.save(output)

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

