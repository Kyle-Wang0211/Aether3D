//
// LocalPreviewCaptureRunner.swift
// Aether3D
//
// Direct-capture local_preview export/archival runner extracted out of
// ScanViewModel so the shared scan controller mainly keeps product routing.
//

import Foundation
import Aether3DCore

#if canImport(CAetherNativeBridge)
struct LocalPreviewCaptureResult: Sendable {
    let exported: Bool
    let artifactRelativePath: String?
    let runtimeMetrics: [String: String]
    let detailMessage: String
}

enum LocalPreviewCaptureRunner {
    static func execute(
        recordId: UUID,
        bridge: PipelineCoordinatorBridge,
        exportDir: URL,
        plyURL: URL,
        worldStateFrames: [ScanViewModel.RawWorldStateFrame],
        surfaceSamples: [SIMD3<Float>],
        sourceVideoRelativePath: String,
        onPhaseUpdate: (@Sendable (LocalPreviewPhaseUpdate) -> Void)? = nil
    ) -> LocalPreviewCaptureResult {
        let budget = LocalPreviewProductProfile.directCaptureBudget()
        let sourceKind = LocalPreviewProductProfile.directCaptureSourceKind(
            sourceVideoRelativePath: sourceVideoRelativePath
        )
        let startWallClock = CFAbsoluteTimeGetCurrent()

        func metricsForPhase(
            _ phase: LocalPreviewWorkflowPhase,
            exported: Bool? = nil,
            exportElapsedMs: UInt64? = nil
        ) -> [String: String] {
            let snapshot = bridge.getSnapshot()
            let reachedSteps = Int(snapshot?.training_step ?? 0)
            let totalElapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - startWallClock) * 1000.0))
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: snapshot,
                sourceVideo: sourceVideoRelativePath,
                exported: exported,
                sourceKind: sourceKind,
                exportElapsedMs: exportElapsedMs
            )
            metrics = LocalPreviewMetricsArchive.appendingDirectCaptureContext(
                to: metrics,
                sourceVideoRelativePath: sourceVideoRelativePath,
                worldStateFrameCount: worldStateFrames.count,
                surfaceSampleCount: surfaceSamples.count,
                budget: budget,
                reachedSteps: reachedSteps,
                totalElapsedMs: totalElapsedMs
            )
            metrics["preview_active_phase"] = phase.phaseName
            metrics["preview_phase_model"] = "live_depth_seed_refine_export"
            if let snapshot {
                let selectedFrames = Int(snapshot.selected_frames)
                let minimumFrames = max(Int(snapshot.min_frames_needed), 1)
                metrics["preview_live_min_selected_frames"] = String(minimumFrames)
                switch phase {
                case .refine:
                    let step = Int(snapshot.training_step)
                    let gaussians = Int(snapshot.num_gaussians)
                    if step > 0 {
                        metrics["preview_refine_phase_metric_text"] = "\(step) 步 · \(gaussians) 个高斯"
                    } else if gaussians > 0 {
                        metrics["preview_refine_phase_metric_text"] = "\(gaussians) 个高斯"
                    }
                case .seed:
                    if selectedFrames > 0 {
                        metrics["preview_seed_phase_metric_text"] = "\(selectedFrames) / \(minimumFrames)"
                    }
                case .depth:
                    let processed = Int(snapshot.preview_frames_ingested)
                    if processed > 0 {
                        metrics["preview_depth_phase_metric_text"] = "\(processed) 帧"
                    }
                case .export:
                    break
                }
            }
            return metrics
        }

        func emitPhase(_ phase: LocalPreviewWorkflowPhase, exported: Bool? = nil, exportElapsedMs: UInt64? = nil, detailOverride: String? = nil) {
            onPhaseUpdate?(
                LocalPreviewProductProfile.makePhaseUpdate(
                    phase: phase,
                    runtimeMetrics: metricsForPhase(phase, exported: exported, exportElapsedMs: exportElapsedMs),
                    detailOverride: detailOverride
                )
            )
        }

        emitPhase(.refine, detailOverride: "采集已经结束，正在用手机本地状态做 bounded refine 并收口 preview。")
        NSLog("[Aether3D] Background export: waiting for local training convergence...")
        var latestSnapshot = bridge.getSnapshot()
        var reachedSteps = Int(latestSnapshot?.training_step ?? 0)
        let trainingDeadline = CFAbsoluteTimeGetCurrent() + max(budget.trainingTimeoutSeconds, 0.0)
        while CFAbsoluteTimeGetCurrent() < trainingDeadline {
            if let snapshot = bridge.getSnapshot() {
                latestSnapshot = snapshot
                reachedSteps = max(reachedSteps, Int(snapshot.training_step))
                emitPhase(.refine)
                if Int(snapshot.training_step) >= budget.trainingMinSteps {
                    break
                }
                if snapshot.training_active == 0 && snapshot.training_step > 0 {
                    break
                }
            }
            Thread.sleep(forTimeInterval: max(0.20, budget.ingestPollIntervalSeconds))
        }

        let exportWaitTargetSteps = max(budget.trainingMinSteps, reachedSteps)
        let exportWaitTimeoutSeconds = min(
            budget.trainingTimeoutSeconds,
            max(budget.exportWaitFloorSeconds, Double(exportWaitTargetSteps - reachedSteps) * 0.08)
        )
        let exportWaitSteps = bridge.waitForTraining(
            minSteps: exportWaitTargetSteps,
            timeoutSeconds: exportWaitTimeoutSeconds
        )
        reachedSteps = max(reachedSteps, exportWaitSteps)
        latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
        emitPhase(.refine)

        if reachedSteps < budget.trainingMinSteps,
           (latestSnapshot?.training_active ?? 0) != 0 {
            let extraRefineDeadline =
                CFAbsoluteTimeGetCurrent() + min(budget.extraRefineTailSeconds, budget.trainingTimeoutSeconds)
            while CFAbsoluteTimeGetCurrent() < extraRefineDeadline {
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    reachedSteps = max(reachedSteps, Int(snapshot.training_step))
                    emitPhase(.refine)
                    if Int(snapshot.training_step) >= budget.trainingMinSteps ||
                        snapshot.training_active == 0 {
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.20)
            }
        }

        latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
        NSLog("[Aether3D] Background export: local training reached %d steps", reachedSteps)

        emitPhase(.export)
        var exportAttempts = 0
        var exported = false
        var exportElapsedMs: UInt64 = 0
        var exportFileSizeBytes: UInt64 = 0
        while exportAttempts < budget.exportAttemptLimit {
            exportAttempts += 1
            let exportStart = CFAbsoluteTimeGetCurrent()
            let attemptExported = bridge.exportPLY(path: plyURL.path)
            exportElapsedMs += UInt64(max(0, (CFAbsoluteTimeGetCurrent() - exportStart) * 1000.0))

            if let attributes = try? FileManager.default.attributesOfItem(atPath: plyURL.path),
               let fileSize = (attributes[.size] as? NSNumber)?.uint64Value {
                exportFileSizeBytes = max(exportFileSizeBytes, fileSize)
            }

            if attemptExported && exportFileSizeBytes > 0 {
                exported = true
                break
            }
            Thread.sleep(forTimeInterval: 0.20)
        }

        if exported {
            NSLog("[Aether3D] ✅ Background export: local Gaussian preview PLY → %@", plyURL.path)
        } else {
            NSLog("[Aether3D] ❌ Background export: local Gaussian preview export failed")
        }

        ScanViewModel.writeWorldStateIfAvailable(
            recordId: recordId,
            exportDir: exportDir,
            worldStateFrames: worldStateFrames,
            surfaceSamples: surfaceSamples
        )

        var runtimeMetrics = metricsForPhase(.export, exported: exported, exportElapsedMs: exportElapsedMs)
        runtimeMetrics = LocalPreviewMetricsArchive.appendingDirectCaptureContext(
            to: runtimeMetrics,
            sourceVideoRelativePath: sourceVideoRelativePath,
            worldStateFrameCount: worldStateFrames.count,
            surfaceSampleCount: surfaceSamples.count,
            budget: budget,
            reachedSteps: reachedSteps,
            totalElapsedMs: UInt64(max(0, (CFAbsoluteTimeGetCurrent() - startWallClock) * 1000.0)),
            exportAttempts: exportAttempts,
            exportFileSizeBytes: exportFileSizeBytes
        )
        runtimeMetrics["preview_export_attempts"] = String(exportAttempts)
        runtimeMetrics["preview_export_file_size_bytes"] = String(exportFileSizeBytes)
        runtimeMetrics["preview_export_wait_steps"] = String(reachedSteps)
        runtimeMetrics["preview_export_phase_metric_text"] = exported
            ? "导出完成"
            : "导出尝试 \(exportAttempts)/\(budget.exportAttemptLimit)"

        if exported {
            return LocalPreviewCaptureResult(
                exported: true,
                artifactRelativePath: ScanViewModel.relativeArtifactPath(for: recordId),
                runtimeMetrics: runtimeMetrics,
                detailMessage: "现在可以进入黑色 3D 空间自由查看"
            )
        }

        return LocalPreviewCaptureResult(
            exported: false,
            artifactRelativePath: nil,
            runtimeMetrics: runtimeMetrics,
            detailMessage: "这次没有拿到可用的 3DGS 结果，请重新拍一轮。"
        )
    }
}
#endif
