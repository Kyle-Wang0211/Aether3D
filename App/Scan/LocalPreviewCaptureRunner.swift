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
import CAetherNativeBridge

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
        processingBackend: ProcessingBackendChoice = .localSubjectFirst,
        onPhaseUpdate: (@Sendable (LocalPreviewPhaseUpdate) -> Void)? = nil
    ) -> LocalPreviewCaptureResult {
        let processingBackend: ProcessingBackendChoice =
            processingBackend == .localPreview ? .localSubjectFirst : processingBackend
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
                processingBackend: processingBackend,
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
            metrics["preview_phase_model"] = processingBackend == .localSubjectFirst
                ? "live_depth_seed_refine_cutout_cleanup_export"
                : "live_depth_seed_refine_export"
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
                case .cutout:
                    metrics["preview_cutout_phase_metric_text"] = "mask / boundary"
                case .cleanup:
                    metrics["preview_cleanup_phase_metric_text"] = "边界 cleanup"
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
                    processingBackend: processingBackend,
                    detailOverride: detailOverride
                )
            )
        }

        func subjectCleanupArtifactPath(for finalURL: URL) -> URL {
            finalURL.deletingLastPathComponent()
                .appendingPathComponent(finalURL.deletingPathExtension().lastPathComponent + ".raw.ply")
        }

        func runSubjectCleanupIfNeeded(
            rawArtifactURL: URL,
            finalArtifactURL: URL,
            runtimeMetrics: inout [String: String]
        ) -> (exported: Bool, detailMessage: String) {
            guard processingBackend == .localSubjectFirst else {
                return (
                    FileManager.default.fileExists(atPath: finalArtifactURL.path),
                    "现在可以进入黑色 3D 空间自由查看"
                )
            }

            emitPhase(.cutout, detailOverride: "正在做 mask / boundary cutout，先把边界薄带和接触面站住。")
            emitPhase(.cleanup, detailOverride: "正在沿边界 mask 做最后收口，清理低置信碎边并尽量保住连续几何。")

#if canImport(CAetherNativeBridge)
            var cleanupStats = aether_subject_cleanup_stats_t()
            let cleanupStart = CFAbsoluteTimeGetCurrent()
            let cleanupStatus = rawArtifactURL.path.withCString { inputPtr in
                finalArtifactURL.path.withCString { outputPtr in
                    aether_splat_subject_cleanup_ply(inputPtr, outputPtr, &cleanupStats)
                }
            }
            let cleanupElapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - cleanupStart) * 1000.0))
            runtimeMetrics["preview_phase_cutout_ms"] = String(cleanupElapsedMs)
            runtimeMetrics["preview_phase_cleanup_ms"] = String(cleanupElapsedMs)
            runtimeMetrics["preview_subject_input_splats"] = String(cleanupStats.input_splats)
            runtimeMetrics["preview_subject_mask_seed_kept"] = String(cleanupStats.mask_seed_kept_splats)
            runtimeMetrics["preview_subject_boundary_refined"] = String(cleanupStats.boundary_refined_splats)
            runtimeMetrics["preview_subject_boundary_split"] = String(cleanupStats.boundary_split_splats)
            runtimeMetrics["preview_subject_cutout_kept"] = String(cleanupStats.cutout_kept_splats)
            runtimeMetrics["preview_subject_cleanup_kept"] = String(cleanupStats.cleanup_kept_splats)
            runtimeMetrics["preview_subject_cleanup_removed"] = String(cleanupStats.cleanup_removed_splats)
            runtimeMetrics["preview_cutout_phase_metric_text"] =
                "\(cleanupStats.mask_seed_kept_splats) -> \(cleanupStats.cutout_kept_splats)"
            runtimeMetrics["preview_cleanup_phase_metric_text"] =
                cleanupStats.cleanup_removed_splats > 0
                    ? "split+\(cleanupStats.boundary_split_splats) / 移除 \(cleanupStats.cleanup_removed_splats)"
                    : "split+\(cleanupStats.boundary_split_splats)"
            let finalExists: Bool = {
                guard cleanupStatus == 0,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: finalArtifactURL.path),
                      let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
                    return false
                }
                return fileSize > 0
            }()
            if finalExists {
                return (
                    true,
                    "本地结果已生成，mask / boundary cutout 和边界收口已完成。"
                )
            }
#endif

            runtimeMetrics["preview_subject_cleanup_fallback"] = "disabled_raw_fallback"
            runtimeMetrics["preview_subject_cleanup_failed"] = "1"
            return (
                false,
                "本地结果在 cutout / cleanup 阶段失败了。raw artifact 已保留为 sidecar，但不会再回退成旧结果。"
            )
        }

        emitPhase(.refine, detailOverride: "采集已经结束，正在用手机本地状态做 bounded refine 并收口结果。")
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
        var lastExportStatusCode: Int32 = -999
        var lastExportStatusReason = "not_started"
        let rawArtifactURL = processingBackend == .localSubjectFirst
            ? subjectCleanupArtifactPath(for: plyURL)
            : plyURL
        func exportDiagnosticsDetail() -> String {
            let fileSizeText = ByteCountFormatter.string(
                fromByteCount: Int64(exportFileSizeBytes),
                countStyle: .file
            )
            return "导出诊断：尝试 \(exportAttempts) 次；状态 \(lastExportStatusCode)（\(lastExportStatusReason)）；文件 \(fileSizeText)；等待步数 \(reachedSteps)。"
        }
        while exportAttempts < budget.exportAttemptLimit {
            exportAttempts += 1
            let exportStart = CFAbsoluteTimeGetCurrent()
            let exportResult = bridge.exportPLYResult(path: rawArtifactURL.path)
            exportElapsedMs += UInt64(max(0, (CFAbsoluteTimeGetCurrent() - exportStart) * 1000.0))
            lastExportStatusCode = exportResult.statusCode
            lastExportStatusReason = exportResult.statusReason
            exportFileSizeBytes = max(exportFileSizeBytes, exportResult.fileSizeBytes)

            if exportResult.succeeded {
                exported = true
                break
            }
            Thread.sleep(forTimeInterval: 0.20)
        }

        if exported {
            NSLog("[Aether3D] ✅ Background export: local Gaussian result PLY → %@", plyURL.path)
        } else {
            NSLog("[Aether3D] ❌ Background export: local Gaussian result export failed")
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
        runtimeMetrics["preview_export_status_code"] = String(lastExportStatusCode)
        runtimeMetrics["preview_export_failure_reason"] = lastExportStatusReason
        runtimeMetrics["preview_export_output_path"] = rawArtifactURL.path
        runtimeMetrics["preview_export_phase_metric_text"] = exported
            ? "导出完成"
            : "导出尝试 \(exportAttempts)/\(budget.exportAttemptLimit)"

        let finalExportState: (exported: Bool, detailMessage: String) = {
            guard exported else {
                return (false, "这次没有拿到可用的 3DGS 结果，请重新拍一轮。\n\n\(exportDiagnosticsDetail())")
            }
            return runSubjectCleanupIfNeeded(
                rawArtifactURL: rawArtifactURL,
                finalArtifactURL: plyURL,
                runtimeMetrics: &runtimeMetrics
            )
        }()
        exported = finalExportState.exported

        if exported {
            return LocalPreviewCaptureResult(
                exported: true,
                artifactRelativePath: ScanViewModel.relativeArtifactPath(for: recordId),
                runtimeMetrics: runtimeMetrics,
                detailMessage: finalExportState.detailMessage
            )
        }

        return LocalPreviewCaptureResult(
            exported: false,
            artifactRelativePath: nil,
            runtimeMetrics: runtimeMetrics,
            detailMessage: finalExportState.detailMessage
        )
    }
}
#endif
