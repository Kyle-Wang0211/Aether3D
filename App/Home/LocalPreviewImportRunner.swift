//
// LocalPreviewImportRunner.swift
// Aether3D
//
// Imported-video local_preview runner extracted out of HomeViewModel so
// the product split can evolve without repeatedly modifying shared UI state logic.
//

import Foundation
import Aether3DCore
import Dispatch
import simd

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
#endif

#if canImport(PR5Capture)
import PR5Capture
#endif

#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

#if canImport(AVFoundation)
struct LocalPreviewImportResult: Sendable {
    let exported: Bool
    let runtimeMetrics: [String: String]
    let detailMessage: String
    let terminalPhase: LocalPreviewWorkflowPhase
    let terminalProgressFraction: Double
}

enum LocalPreviewImportRunner {
    private enum ImportedVideoIntrinsicsSource: Int32, Sendable {
        case unknown = 0
        case real = 1
        case metadata35mmEquivalent = 2
        case colmapDefault = 3

        var traceLabel: String {
            switch self {
            case .unknown: return "unknown"
            case .real: return "real"
            case .metadata35mmEquivalent: return "metadata_35mm"
            case .colmapDefault: return "colmap_default"
            }
        }
    }

    private struct ImportedVideoMetadataIntrinsicsEstimate: Sendable {
        let intrinsics: simd_float3x3
        let focalLength35mmEquivalentMM: Double
    }

    private struct ImportedVideoSidecarIntrinsicsEstimate: Sendable {
        let intrinsics: simd_float3x3
        let sourceLabel: String
    }

    private struct CaptureIntrinsicsSidecar: Decodable {
        let version: String
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            storage = value
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ newValue: Value) {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    private struct ImportedVideoPhotometricStats {
        let exposure: Double
        let whiteBalanceR: Double
        let whiteBalanceG: Double
        let whiteBalanceB: Double
    }

    private struct ImportedVideoPhotometricDecision {
        let accepted: Bool
        let exposureAccepted: Bool
        let whiteBalanceAccepted: Bool
        let exposureConsistencyScore: Double
        let whiteBalanceConsistencyScore: Double
    }

    private struct ImportedVideoPhotometricCounters {
        var acceptedFrames = 0
        var exposureRejects = 0
        var whiteBalanceRejects = 0
        var lastExposureConsistencyScore = 1.0
        var lastWhiteBalanceConsistencyScore = 1.0
    }

    private static func isApplicationForegroundActive() -> Bool {
#if canImport(UIKit)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIApplication.shared.applicationState == .active
            }
        }
        let stateBox = LockedBox(false)
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            stateBox.set(
                MainActor.assumeIsolated {
                    UIApplication.shared.applicationState == .active
                }
            )
            semaphore.signal()
        }
        semaphore.wait()
        return stateBox.value
#else
        return true
#endif
    }

    private static func waitForApplicationForeground(
        pollIntervalSeconds: Double,
        stableForegroundSeconds: Double,
        onWaiting: (() -> Void)? = nil
    ) -> Bool {
        var emittedWaiting = false
        var activeSince: CFAbsoluteTime?
        while true {
            if isApplicationForegroundActive() {
                if activeSince == nil {
                    activeSince = CFAbsoluteTimeGetCurrent()
                }
                if CFAbsoluteTimeGetCurrent() - (activeSince ?? 0.0) >= max(stableForegroundSeconds, 0.0) {
                    return true
                }
            } else {
                activeSince = nil
            }
            if !emittedWaiting {
                onWaiting?()
                emittedWaiting = true
            }
            Thread.sleep(forTimeInterval: max(pollIntervalSeconds, 0.05))
        }
    }

    private static func samplePhotometricStats(
        pixelBuffer: CVPixelBuffer
    ) -> ImportedVideoPhotometricStats? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        let sampleStride = max(4, min(width, height) / 48)

        var luminanceSum = 0.0
        var rSum = 0.0
        var gSum = 0.0
        var bSum = 0.0
        var sampleCount = 0.0

        for y in Swift.stride(from: 0, to: height, by: sampleStride) {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in Swift.stride(from: 0, to: width, by: sampleStride) {
                let p = row.advanced(by: x * 4)
                let b = Double(p[0]) / 255.0
                let g = Double(p[1]) / 255.0
                let r = Double(p[2]) / 255.0
                luminanceSum += 0.299 * r + 0.587 * g + 0.114 * b
                rSum += r
                gSum += g
                bSum += b
                sampleCount += 1.0
            }
        }

        guard sampleCount > 0 else { return nil }
        let meanExposure = luminanceSum / sampleCount
        let meanR = rSum / sampleCount
        let meanG = gSum / sampleCount
        let meanB = bSum / sampleCount
        let meanRGB = max((meanR + meanG + meanB) / 3.0, 1e-6)

        return ImportedVideoPhotometricStats(
            exposure: meanExposure,
            whiteBalanceR: meanR / meanRGB,
            whiteBalanceG: meanG / meanRGB,
            whiteBalanceB: meanB / meanRGB
        )
    }

#if canImport(PR5Capture)
    private static func evaluatePhotometricDecision(
        stats: ImportedVideoPhotometricStats,
        exposureChecker: ExposureConsistencyChecker,
        whiteBalanceValidator: WhiteBalanceValidator
    ) -> ImportedVideoPhotometricDecision {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = LockedBox<ImportedVideoPhotometricDecision>(
            ImportedVideoPhotometricDecision(
                accepted: true,
                exposureAccepted: true,
                whiteBalanceAccepted: true,
                exposureConsistencyScore: 1.0,
                whiteBalanceConsistencyScore: 1.0
            )
        )

        Task {
            let exposure = await exposureChecker.checkConsistency(stats.exposure)
            let whiteBalance = await whiteBalanceValidator.validateWhiteBalance(
                r: stats.whiteBalanceR,
                g: stats.whiteBalanceG,
                b: stats.whiteBalanceB
            )
            decision.set(
                ImportedVideoPhotometricDecision(
                    accepted: exposure.isConsistent && whiteBalance.isValid,
                    exposureAccepted: exposure.isConsistent,
                    whiteBalanceAccepted: whiteBalance.isValid,
                    exposureConsistencyScore: exposure.consistencyScore,
                    whiteBalanceConsistencyScore: whiteBalance.consistencyScore
                )
            )
            semaphore.signal()
        }

        semaphore.wait()
        return decision.value
    }
#endif

    private static func decodeCameraIntrinsics(
        from rawValue: Any?
    ) -> simd_float3x3? {
        guard let rawValue else {
            return nil
        }
        let data: Data
        if let direct = rawValue as? Data {
            data = direct
        } else if CFGetTypeID(rawValue as CFTypeRef) == CFDataGetTypeID() {
            data = rawValue as! Data
        } else {
            return nil
        }
        guard data.count >= MemoryLayout<matrix_float3x3>.size else {
            return nil
        }
        var matrix = matrix_identity_float3x3
        _ = withUnsafeMutableBytes(of: &matrix) { bytes in
            data.copyBytes(to: bytes)
        }
        let fx = matrix.columns.0.x
        let fy = matrix.columns.1.y
        guard fx.isFinite, fy.isFinite, fx > 1.0, fy > 1.0 else {
            return nil
        }
        return matrix
    }

    private static func parsePositiveMetadataDouble(
        from item: AVMetadataItem?
    ) -> Double? {
        guard let item else { return nil }
        if let number = item.numberValue?.doubleValue,
           number.isFinite,
           number > 0.0 {
            return number
        }
        if let string = item.stringValue {
            let characters = string.filter { $0.isNumber || $0 == "." }
            if let value = Double(characters),
               value.isFinite,
               value > 0.0 {
                return value
            }
        }
        return nil
    }

    private static func importedVideoMetadataItems(
        asset: AVAsset,
        videoTrack: AVAssetTrack
    ) -> [AVMetadataItem] {
        var metadata = asset.commonMetadata + asset.metadata
        for format in asset.availableMetadataFormats {
            metadata.append(contentsOf: asset.metadata(forFormat: format))
        }
        for format in videoTrack.availableMetadataFormats {
            metadata.append(contentsOf: videoTrack.metadata(forFormat: format))
        }
        return metadata
    }

    private static func importedVideoMetadataIntrinsicsEstimate(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        width: Int,
        height: Int
    ) -> ImportedVideoMetadataIntrinsicsEstimate? {
        let metadata = importedVideoMetadataItems(asset: asset, videoTrack: videoTrack)
        let focalItemByKey = metadata.first(where: { item in
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let key = item.key.map { String(describing: $0).lowercased() } ?? ""
            return identifier.contains("focallength35mmequivalent") ||
                identifier.contains("camerafocallength35mmequivalent") ||
                (key.contains("35mm") && key.contains("focal"))
        })
        let focalItem: AVMetadataItem?
        if #available(iOS 26.0, *) {
            focalItem = AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .quickTimeMetadataCameraFocalLength35mmEquivalent
            ).first ?? focalItemByKey
        } else {
            focalItem = focalItemByKey
        }
        guard let focal35mmEquivalentMM = parsePositiveMetadataDouble(from: focalItem) else {
            return nil
        }

        let diagonalPixels = hypot(Double(width), Double(height))
        guard diagonalPixels.isFinite, diagonalPixels > 1.0 else {
            return nil
        }

        // Apple exposes a 35mm-equivalent focal length for some QuickTime
        // videos. Convert that standard full-frame-diagonal equivalence into a
        // pixel focal prior for the local adapter so we can stay closer to a
        // real camera model before any downstream refinement.
        let fullFrameDiagonalMM = 43.266615305567875
        let focalPixels = (focal35mmEquivalentMM / fullFrameDiagonalMM) * diagonalPixels
        guard focalPixels.isFinite, focalPixels > 1.0 else {
            return nil
        }

        let fx = Float(focalPixels)
        let fy = Float(focalPixels)
        let cx = Float(width) * 0.5
        let cy = Float(height) * 0.5
        let intrinsics = simd_float3x3(
            SIMD3<Float>(fx, 0.0, 0.0),
            SIMD3<Float>(0.0, fy, 0.0),
            SIMD3<Float>(cx, cy, 1.0)
        )
        return ImportedVideoMetadataIntrinsicsEstimate(
            intrinsics: intrinsics,
            focalLength35mmEquivalentMM: focal35mmEquivalentMM
        )
    }

    private static func importedVideoSidecarIntrinsicsEstimate(
        videoURL: URL
    ) -> ImportedVideoSidecarIntrinsicsEstimate? {
        let sidecarURL = videoURL.deletingPathExtension().appendingPathExtension("intrinsics.json")
        guard let data = try? Data(contentsOf: sidecarURL),
              let payload = try? JSONDecoder().decode(CaptureIntrinsicsSidecar.self, from: data) else {
            return nil
        }

        let fx = payload.fx
        let fy = payload.fy
        let cx = payload.cx
        let cy = payload.cy
        guard fx.isFinite, fy.isFinite, cx.isFinite, cy.isFinite,
              fx > 1.0, fy > 1.0 else {
            return nil
        }

        let intrinsics = simd_float3x3(
            SIMD3<Float>(fx, 0.0, 0.0),
            SIMD3<Float>(0.0, fy, 0.0),
            SIMD3<Float>(cx, cy, 1.0)
        )
        return ImportedVideoSidecarIntrinsicsEstimate(
            intrinsics: intrinsics,
            sourceLabel: payload.version
        )
    }

    private static func importedVideoCameraIntrinsics(
        from sampleBuffer: CMSampleBuffer,
        videoTrack: AVAssetTrack
    ) -> simd_float3x3? {
        let cameraIntrinsicExtensionKey = "CameraIntrinsicMatrix" as NSString

        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ),
           let matrix = decodeCameraIntrinsics(from: attachment) {
            return matrix
        }

        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?,
           let matrix = decodeCameraIntrinsics(
                from: extensions[cameraIntrinsicExtensionKey]
           ) {
            return matrix
        }

        for description in videoTrack.formatDescriptions {
            let formatDescription = description as! CMFormatDescription
            guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary? else {
                continue
            }
            if let matrix = decodeCameraIntrinsics(
                from: extensions[cameraIntrinsicExtensionKey]
            ) {
                return matrix
            }
        }

        return nil
    }

    static func execute(
        sourceVideoURL: URL,
        artifactURL: URL,
        sourceRelativePath: String,
        frameSamplingProfile: FrameSamplingProfile,
        onPhaseUpdate: (@Sendable (LocalPreviewPhaseUpdate) -> Void)? = nil
    ) -> LocalPreviewImportResult {
        let budget = LocalPreviewProductProfile.importedVideoBudget(for: frameSamplingProfile)
        let thermalAtFinish = ProcessInfo.processInfo.thermalState
        let runnerStartWallClock = CFAbsoluteTimeGetCurrent()
        var photometricCounters = ImportedVideoPhotometricCounters()
        var targetSubmittedFrames = budget.maxSubmittedFrames
        let minimumSelectedFramesToStartTraining = max(
            budget.minimumSelectedFramesToStartTraining,
            1
        )
        let foregroundRequiredDetail = "iOS 不允许本地深度先验在后台继续提交 GPU 工作，请保持 app 停留前台，回到前台后会继续。"
        let foregroundRecheckIntervalSeconds = max(
            0.4,
            budget.foregroundActivationWaitSeconds * 2.0
        )
        let livePhaseEmitIntervalSeconds = 0.05
        let periodicSnapshotPollSeconds = 0.20
        var lastForegroundValidationAt: CFAbsoluteTime = 0.0
        var lastLivePhaseEmissionAt: CFAbsoluteTime = 0.0
        var lastEmittedPhase: LocalPreviewWorkflowPhase?
        var lastEmittedSubmittedFrames = -1
        var lastEmittedProcessedFrames = -1
        var lastEmittedDepthReady = -1
        var lastEmittedSelectedFrames = -1
        var lastSnapshotPollAt: CFAbsoluteTime = 0.0
        var lastObservedGaussianCount = 0
        var traceLines: [String] = []

#if canImport(PR5Capture)
        let photometricProfile = ExtremeProfile(profile: .standard)
        let exposureChecker = ExposureConsistencyChecker(config: photometricProfile)
        let whiteBalanceValidator = WhiteBalanceValidator(config: photometricProfile)
#endif

        func metricsForPhase(
            _ phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t? = nil,
            exported: Bool? = nil,
            exportElapsedMs: UInt64? = nil
        ) -> [String: String] {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: snapshot,
                sourceVideo: sourceRelativePath,
                exported: exported,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish,
                exportElapsedMs: exportElapsedMs
            )
            metrics["preview_active_phase"] = phase.phaseName
            metrics["preview_phase_model"] = "depth_seed_refine_export"
            if !traceLines.isEmpty {
                metrics["preview_trace_last_event"] = traceLines.last
                metrics["preview_trace_log"] = traceLines.joined(separator: "\n")
            }
            if let snapshot {
                lastObservedGaussianCount = max(
                    lastObservedGaussianCount,
                    Int(snapshot.num_gaussians)
                )
            }
            if lastObservedGaussianCount > 0 {
                metrics["preview_gaussians"] = String(lastObservedGaussianCount)
            }
            return metrics
        }

        func appendTrace(
            _ label: String,
            phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            detail: String? = nil
        ) {
            let elapsedMs = Int(max(0, (CFAbsoluteTimeGetCurrent() - runnerStartWallClock) * 1000.0))
            let ingested = Int(snapshot?.preview_frames_ingested ?? 0)
            let selected = Int(snapshot?.selected_frames ?? 0)
            let depthReady = Int(snapshot?.preview_depth_results_ready ?? 0)
            var line = "[\(elapsedMs)ms] \(label) phase=\(phase.phaseName) submitted=\(submittedFrames) ingested=\(ingested) selected=\(selected) depth_ready=\(depthReady)"
            if let detail, !detail.isEmpty {
                line += " detail=\(detail)"
            }
            traceLines.append(line)
            if traceLines.count > 80 {
                traceLines.removeFirst(traceLines.count - 80)
            }
        }

        func depthMetricText(
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int
        ) -> String {
            let enqueuedFrames = max(
                submittedFrames,
                Int(snapshot?.preview_frames_enqueued ?? 0)
            )
            let ingestedFrames = Int(snapshot?.preview_frames_ingested ?? 0)
            let backlogFrames = Int(snapshot?.preview_frame_backlog ?? 0)
            if enqueuedFrames > 0 {
                let batches = Int(snapshot?.preview_depth_batches_submitted ?? 0)
                let ready = Int(snapshot?.preview_depth_results_ready ?? 0)
                if batches > 0 {
                    if backlogFrames > 0 {
                        return "\(ingestedFrames) / \(enqueuedFrames) 帧 · depth \(ready)/\(batches) · 排队 \(backlogFrames)"
                    }
                    return "\(ingestedFrames) / \(enqueuedFrames) 帧 · depth \(ready)/\(batches)"
                }
                if backlogFrames > 0 {
                    return "\(ingestedFrames) / \(enqueuedFrames) 帧 · 排队 \(backlogFrames) 帧"
                }
                return "\(ingestedFrames) / \(enqueuedFrames) 帧"
            }
            return "等待开始"
        }

        func seedMetricText(
            snapshot: aether_evidence_snapshot_t?,
            minimumSelectedFrames: Int
        ) -> String {
            let selectedFrames = Int(snapshot?.selected_frames ?? 0)
            if minimumSelectedFrames > 0 {
                return "\(selectedFrames) / \(minimumSelectedFrames)"
            }
            let acceptedSeeds = Int(snapshot?.preview_seed_accepted ?? 0)
            let candidateSeeds = Int(snapshot?.preview_seed_candidates ?? 0)
            if candidateSeeds > 0 {
                return "\(acceptedSeeds) / \(candidateSeeds)"
            }
            return "等待开始"
        }

        func refineMetricText(snapshot: aether_evidence_snapshot_t?) -> String {
            let trainingProgress = Double(snapshot?.training_progress ?? 0)
            if trainingProgress > 0 {
                return String(format: "%.1f%%", trainingProgress * 100.0)
            }
            let gaussianCount = max(
                Int(snapshot?.num_gaussians ?? 0),
                lastObservedGaussianCount
            )
            if gaussianCount > 0 {
                return "\(gaussianCount) 个高斯"
            }
            return "等待开始"
        }

        func emitPhase(
            _ phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t? = nil,
            exported: Bool? = nil,
            exportElapsedMs: UInt64? = nil,
            detailOverride: String? = nil,
            progressFraction: Double? = nil,
            liveSubmittedFrames: Int? = nil,
            liveMinimumSelectedFrames: Int? = nil,
            liveTargetFrames: Int? = nil
        ) {
            var metrics = metricsForPhase(
                phase,
                snapshot: snapshot,
                exported: exported,
                exportElapsedMs: exportElapsedMs
            )
            if let liveSubmittedFrames {
                metrics["preview_live_submitted_frames"] = String(liveSubmittedFrames)
                metrics["preview_import_submitted_frames"] = String(liveSubmittedFrames)
            }
            if let liveMinimumSelectedFrames {
                metrics["preview_live_min_selected_frames"] = String(liveMinimumSelectedFrames)
            }
            if let liveTargetFrames {
                metrics["preview_live_target_frames"] = String(liveTargetFrames)
            }
            let minimumSelected = liveMinimumSelectedFrames
                ?? max(Int(snapshot?.min_frames_needed ?? 0), minimumSelectedFramesToStartTraining)
            switch phase {
            case .depth:
                metrics["preview_depth_phase_metric_text"] = depthMetricText(
                    snapshot: snapshot,
                    submittedFrames: liveSubmittedFrames ?? 0
                )
            case .seed:
                metrics["preview_seed_phase_metric_text"] = seedMetricText(
                    snapshot: snapshot,
                    minimumSelectedFrames: minimumSelected
                )
            case .refine:
                metrics["preview_refine_phase_metric_text"] = refineMetricText(snapshot: snapshot)
            case .export:
                metrics["preview_export_phase_metric_text"] = exported == true ? "已完成" : "导出中"
            }
            appendTrace(
                "phase_update",
                phase: phase,
                snapshot: snapshot,
                submittedFrames: liveSubmittedFrames ?? 0,
                detail: detailOverride ?? phase.detailMessage
            )
            onPhaseUpdate?(
                LocalPreviewProductProfile.makePhaseUpdate(
                    phase: phase,
                    runtimeMetrics: metrics,
                    progressFraction: progressFraction,
                    detailOverride: detailOverride
                )
            )
        }

        func boundedPhaseProgress(
            _ phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minSelectedFrames: Int
        ) -> Double {
            let lower = phase.startFraction
            let upper: Double = {
                switch phase {
                case .depth:
                    return LocalPreviewWorkflowPhase.seed.startFraction
                case .seed:
                    return LocalPreviewWorkflowPhase.refine.startFraction
                case .refine:
                    return LocalPreviewWorkflowPhase.export.startFraction
                case .export:
                    return 0.99
                }
            }()

            guard let snapshot else {
                return phase.defaultActiveFraction
            }

            let normalized: Double = {
                switch phase {
                case .depth:
                    let submittedRatio = targetSubmittedFrames > 0
                        ? min(1.0, Double(submittedFrames) / Double(max(targetSubmittedFrames, 1)))
                        : 0.0
                    let ingestedFrames = Int(snapshot.preview_frames_ingested)
                    let processedRatio = submittedFrames > 0
                        ? min(1.0, Double(ingestedFrames) / Double(max(submittedFrames, 1)))
                        : 0.0
                    let depthRatio = min(
                        1.0,
                        Double(snapshot.preview_depth_results_ready) /
                            Double(max(budget.minDepthResultsBeforeFinalize, 1))
                    )
                    return max(
                        submittedRatio * 0.25 +
                        processedRatio * 0.45 +
                        depthRatio * 0.30,
                        0.02
                    )
                case .seed:
                    let selectedRatio = min(
                        1.0,
                        Double(snapshot.selected_frames) / Double(max(minSelectedFrames, 1))
                    )
                    let seedRatio = min(
                        1.0,
                        Double(snapshot.preview_seed_accepted) / 512.0
                    )
                    return max(selectedRatio * 0.6 + seedRatio * 0.4, 0.02)
                case .refine:
                    return max(min(1.0, Double(snapshot.training_progress)), 0.02)
                case .export:
                    return 0.6
                }
            }()

            return min(max(lower + (upper - lower) * normalized, lower), upper)
        }

        func phaseDetail(
            _ phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minSelectedFrames: Int
        ) -> String {
            guard let snapshot else {
                return phase.detailMessage
            }
            switch phase {
            case .depth:
                let enqueuedFrames = max(
                    submittedFrames,
                    Int(snapshot.preview_frames_enqueued)
                )
                let processedFrames = Int(snapshot.preview_frames_ingested)
                let nativeBacklog = Int(snapshot.preview_frame_backlog)
                let depthReady = Int(snapshot.preview_depth_results_ready)
                let depthSubmitted = Int(snapshot.preview_depth_batches_submitted)
                if depthSubmitted > 0 {
                    return "已送入队列 \(enqueuedFrames)/\(max(targetSubmittedFrames, 1)) 帧，native 已接收 \(processedFrames) 帧，排队中 \(nativeBacklog) 帧，depth 已回流 \(depthReady)/\(max(depthSubmitted, 1)) 批，正在建立可用于 preview 的几何先验。"
                }
                return "已送入队列 \(enqueuedFrames)/\(max(targetSubmittedFrames, 1)) 帧，native 已接收 \(processedFrames) 帧，排队中 \(nativeBacklog) 帧，正在建立可用于 preview 的几何先验。"
            case .seed:
                return "已选中 \(snapshot.selected_frames)/\(max(minSelectedFrames, 1)) 个关键帧，候选 seed \(snapshot.preview_seed_candidates) 个，已接受 \(snapshot.preview_seed_accepted) 个。"
            case .refine:
                let gaussianCount = max(
                    Int(snapshot.num_gaussians),
                    lastObservedGaussianCount
                )
                return "本地 refine 已跑到 \(snapshot.training_step) 步，当前高斯 \(gaussianCount) 个，继续收口 preview 几何。"
            case .export:
                return "训练结果正在写出为本地 Gaussian preview artifact。"
            }
        }

        func emitLivePhase(
            _ phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minSelectedFrames: Int,
            force: Bool = false
        ) {
            let now = CFAbsoluteTimeGetCurrent()
            let processedFrames = Int(snapshot?.preview_frames_ingested ?? 0)
            let depthReady = Int(snapshot?.preview_depth_results_ready ?? 0)
            let selectedFrames = Int(snapshot?.selected_frames ?? 0)
            let phaseChanged = lastEmittedPhase != phase
            let shouldEmit =
                force ||
                phaseChanged ||
                submittedFrames != lastEmittedSubmittedFrames ||
                processedFrames != lastEmittedProcessedFrames ||
                depthReady != lastEmittedDepthReady ||
                selectedFrames != lastEmittedSelectedFrames ||
                now - lastLivePhaseEmissionAt >= livePhaseEmitIntervalSeconds
            guard shouldEmit else { return }

            lastLivePhaseEmissionAt = now
            lastEmittedPhase = phase
            lastEmittedSubmittedFrames = submittedFrames
            lastEmittedProcessedFrames = processedFrames
            lastEmittedDepthReady = depthReady
            lastEmittedSelectedFrames = selectedFrames

            emitPhase(
                phase,
                snapshot: snapshot,
                detailOverride: phaseDetail(
                    phase,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minSelectedFrames
                ),
                progressFraction: boundedPhaseProgress(
                    phase,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minSelectedFrames
                ),
                liveSubmittedFrames: submittedFrames,
                liveMinimumSelectedFrames: minSelectedFrames,
                liveTargetFrames: targetSubmittedFrames
            )
        }

        var foregroundBridge: PipelineCoordinatorBridge?

        func waitForForegroundIfNeeded(
            phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minimumSelectedFrames: Int
        ) -> Bool {
            let now = CFAbsoluteTimeGetCurrent()
            let isForegroundActive = Self.isApplicationForegroundActive()
            foregroundBridge?.setForegroundActive(isForegroundActive)
            if isForegroundActive &&
                now - lastForegroundValidationAt < foregroundRecheckIntervalSeconds {
                return true
            }
            guard isForegroundActive else {
                emitPhase(
                    phase,
                    snapshot: snapshot,
                    detailOverride: foregroundRequiredDetail,
                    progressFraction: boundedPhaseProgress(
                        phase,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: minimumSelectedFrames
                    ),
                    liveSubmittedFrames: submittedFrames,
                    liveMinimumSelectedFrames: minimumSelectedFrames,
                    liveTargetFrames: targetSubmittedFrames
                )
                let resumed = Self.waitForApplicationForeground(
                    pollIntervalSeconds: budget.inactivePollIntervalSeconds,
                    stableForegroundSeconds: budget.foregroundActivationWaitSeconds
                ) {
                    emitPhase(
                        phase,
                        snapshot: snapshot,
                        detailOverride: foregroundRequiredDetail,
                        progressFraction: boundedPhaseProgress(
                            phase,
                            snapshot: snapshot,
                            submittedFrames: submittedFrames,
                            minSelectedFrames: minimumSelectedFrames
                        ),
                        liveSubmittedFrames: submittedFrames,
                        liveMinimumSelectedFrames: minimumSelectedFrames,
                        liveTargetFrames: targetSubmittedFrames
                    )
                }
                if resumed {
                    foregroundBridge?.setForegroundActive(true)
                    lastForegroundValidationAt = CFAbsoluteTimeGetCurrent()
                }
                return resumed
            }
            lastForegroundValidationAt = now
            return true
        }

        func buildResult(
            snapshot: aether_evidence_snapshot_t? = nil,
            exported: Bool,
            runtimeMetrics: [String: String],
            detailMessage: String,
            terminalPhase: LocalPreviewWorkflowPhase,
            terminalProgressFraction: Double,
            liveSubmittedFrames: Int? = nil,
            liveMinimumSelectedFrames: Int? = nil,
            liveTargetFrames: Int? = nil
        ) -> LocalPreviewImportResult {
            var metrics = runtimeMetrics
            metrics["preview_active_phase"] = terminalPhase.phaseName
            if let liveSubmittedFrames {
                metrics["preview_live_submitted_frames"] = String(liveSubmittedFrames)
                metrics["preview_import_submitted_frames"] = String(liveSubmittedFrames)
            }
            if let liveMinimumSelectedFrames {
                metrics["preview_live_min_selected_frames"] = String(liveMinimumSelectedFrames)
            }
            if let liveTargetFrames {
                metrics["preview_live_target_frames"] = String(max(liveTargetFrames, 1))
            }
            let minimumSelected = liveMinimumSelectedFrames ?? minimumSelectedFramesToStartTraining
            switch terminalPhase {
            case .depth:
                metrics["preview_depth_phase_metric_text"] = depthMetricText(
                    snapshot: snapshot,
                    submittedFrames: liveSubmittedFrames ?? 0
                )
            case .seed:
                metrics["preview_seed_phase_metric_text"] = seedMetricText(
                    snapshot: snapshot,
                    minimumSelectedFrames: minimumSelected
                )
            case .refine:
                metrics["preview_refine_phase_metric_text"] = refineMetricText(snapshot: snapshot)
            case .export:
                metrics["preview_export_phase_metric_text"] = exported ? "已完成" : "导出失败"
            }
            appendTrace(
                exported ? "terminal_success" : "terminal_failure",
                phase: terminalPhase,
                snapshot: snapshot,
                submittedFrames: liveSubmittedFrames ?? 0,
                detail: detailMessage
            )
            if !traceLines.isEmpty {
                metrics["preview_trace_last_event"] = traceLines.last
                metrics["preview_trace_log"] = traceLines.joined(separator: "\n")
            }
            return LocalPreviewImportResult(
                exported: exported,
                runtimeMetrics: metrics,
                detailMessage: detailMessage,
                terminalPhase: terminalPhase,
                terminalProgressFraction: terminalProgressFraction
            )
        }

        func hasAnyPreviewBootstrapSignal(_ snapshot: aether_evidence_snapshot_t?) -> Bool {
            guard let snapshot else { return false }
            return Int(snapshot.preview_depth_results_ready) > 0 ||
                Int(snapshot.selected_frames) > 0 ||
                Int(snapshot.pending_gaussian_count) > 0 ||
                Int(snapshot.preview_seed_candidates) > 0 ||
                Int(snapshot.preview_seed_accepted) > 0 ||
                snapshot.training_active != 0 ||
                Int(snapshot.training_step) > 0
        }

        func hasDepthPhaseEvidence(
            _ snapshot: aether_evidence_snapshot_t?,
            minimumSelectedFrames: Int
        ) -> Bool {
            guard let snapshot else { return false }
            let processedFrames = Int(snapshot.preview_frames_ingested)
            let depthReady = Int(snapshot.preview_depth_results_ready)
            let selectedFrames = Int(snapshot.selected_frames)
            let pendingGaussians = Int(snapshot.pending_gaussian_count)
            let seedCandidates = Int(snapshot.preview_seed_candidates)
            return depthReady >= max(budget.minDepthResultsBeforeFinalize, 1) &&
                processedFrames >= max(budget.minimumProcessedFramesBeforeFinalize, 1) &&
                (selectedFrames >= minimumSelectedFrames ||
                 pendingGaussians > 0 ||
                 seedCandidates > 0)
        }

        func hasSeedPhaseEvidence(
            _ snapshot: aether_evidence_snapshot_t?,
            minimumSelectedFrames: Int
        ) -> Bool {
            guard let snapshot else { return false }
            let selectedFrames = Int(snapshot.selected_frames)
            let acceptedSeeds = Int(snapshot.preview_seed_accepted)
            let pendingGaussians = Int(snapshot.pending_gaussian_count)
            return selectedFrames >= minimumSelectedFrames ||
                acceptedSeeds > 0 ||
                pendingGaussians > 0 ||
                snapshot.training_active != 0 ||
                Int(snapshot.training_step) > 0
        }

        guard let handles = ScanViewModel.createCoordinatorHandles(processingBackend: .localPreview),
              let bridge = handles.bridge else {
            let metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "手机本地预览引擎没有初始化成功，这次还没法开始单目 preview。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }
        defer { ScanViewModel.destroyCoordinatorHandles(handles) }
        foregroundBridge = bridge

        func waitForNativeCatchUp(
            submittedFrames: Int,
            requireBootstrap: Bool,
            timeoutSeconds: Double,
            requireAllProcessed: Bool = false,
            minimumSelectedFrames: Int = 0,
            phaseDuringWait: LocalPreviewWorkflowPhase = .depth
        ) -> aether_evidence_snapshot_t? {
            let deadline = CFAbsoluteTimeGetCurrent() + max(timeoutSeconds, 0.0)
            var latestSnapshot = bridge.getSnapshot()
            var bootstrapDepthReady = false

            while CFAbsoluteTimeGetCurrent() < deadline {
                guard waitForForegroundIfNeeded(
                    phase: phaseDuringWait,
                    snapshot: latestSnapshot,
                    submittedFrames: submittedFrames,
                    minimumSelectedFrames: max(minimumSelectedFrames, minimumSelectedFramesToStartTraining)
                ) else {
                    break
                }
                bootstrapDepthReady = bridge.serviceLocalPreviewBootstrap() || bootstrapDepthReady
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    let processedFrames = Int(snapshot.preview_frames_ingested)
                    let inFlightFrames = max(0, submittedFrames - processedFrames)
                    let selectedFrames = Int(snapshot.selected_frames)
                    let requiredSelectedFrames = max(
                        minimumSelectedFrames,
                        minimumSelectedFramesToStartTraining
                    )
                    let bootstrapReady: Bool = {
                        switch phaseDuringWait {
                        case .depth:
                            return bootstrapDepthReady ||
                                hasDepthPhaseEvidence(
                                    snapshot,
                                    minimumSelectedFrames: requiredSelectedFrames
                                )
                        case .seed:
                            return hasSeedPhaseEvidence(
                                snapshot,
                                minimumSelectedFrames: requiredSelectedFrames
                            )
                        case .refine, .export:
                            return true
                        }
                    }()
                    let processedFloor = min(
                        submittedFrames,
                        max(budget.minimumProcessedFramesBeforeFinalize, 1)
                    )
                    let processedReady: Bool = {
                        if requireAllProcessed {
                            return inFlightFrames == 0
                        }
                        switch phaseDuringWait {
                        case .depth, .seed:
                            return processedFrames >= processedFloor
                        case .refine, .export:
                            return inFlightFrames <= budget.maxFramesAheadBeforeFinalize &&
                                processedFrames >= processedFloor
                        }
                    }()
                    let selectionReady = phaseDuringWait == .seed
                        ? requiredSelectedFrames <= 0 || selectedFrames >= requiredSelectedFrames
                        : true
                    emitLivePhase(
                        phaseDuringWait,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(minimumSelectedFrames, minimumSelectedFramesToStartTraining),
                        force: selectedFrames > 0 || processedFrames > 0 || bootstrapReady
                    )
                    if processedReady &&
                        (!requireBootstrap || bootstrapReady) &&
                        selectionReady {
                        break
                    }
                }
                Thread.sleep(forTimeInterval: budget.ingestPollIntervalSeconds)
            }

            return latestSnapshot
        }

        func waitForNativeSubmissionWindow(
            submittedFrames: Int,
            minimumSelectedFrames: Int,
            timeoutSeconds: Double
        ) -> aether_evidence_snapshot_t? {
            guard submittedFrames > 0 else { return bridge.getSnapshot() }
            var latestSnapshot = bridge.getSnapshot()
            let deadline = CFAbsoluteTimeGetCurrent() + max(timeoutSeconds, 0.0)

            while true {
                guard waitForForegroundIfNeeded(
                    phase: .depth,
                    snapshot: latestSnapshot,
                    submittedFrames: submittedFrames,
                    minimumSelectedFrames: max(minimumSelectedFrames, minimumSelectedFramesToStartTraining)
                ) else {
                    break
                }

                _ = bridge.serviceLocalPreviewBootstrap()
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    let processedFrames = Int(snapshot.preview_frames_ingested)
                    let inFlightFrames = max(0, submittedFrames - processedFrames)
                    emitLivePhase(
                        .depth,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(minimumSelectedFrames, minimumSelectedFramesToStartTraining),
                        force: processedFrames > 0
                    )
                    if inFlightFrames <= budget.maxFramesAheadOfNative {
                        break
                    }
                }

                if CFAbsoluteTimeGetCurrent() >= deadline {
                    break
                }

                Thread.sleep(forTimeInterval: max(budget.ingestPollIntervalSeconds, 0.05))
            }

            return latestSnapshot
        }

        emitPhase(LocalPreviewWorkflowPhase.depth)

        if !waitForForegroundIfNeeded(
            phase: .depth,
            snapshot: nil,
            submittedFrames: 0,
            minimumSelectedFrames: minimumSelectedFramesToStartTraining
        ) {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["preview_import_error"] = "foreground_required_for_gpu_depth"
            metrics["preview_import_foreground_wait_expired"] = "1"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: foregroundRequiredDetail,
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.defaultActiveFraction
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: artifactURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: artifactURL.path) {
                try FileManager.default.removeItem(at: artifactURL)
            }
        } catch {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["preview_import_error"] = "artifact_directory_prepare_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "本地导出目录准备失败了，这次没有拿到可写的 preview 输出位置。",
                terminalPhase: .export,
                terminalProgressFraction: LocalPreviewWorkflowPhase.export.startFraction
            )
        }

        let asset = AVURLAsset(url: sourceVideoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["preview_import_error"] = "video_track_missing"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "这个相册视频没有可用的视频轨道，本地 preview 这次无法启动。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["preview_import_error"] = "asset_reader_create_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "本地没法读取这个视频的帧数据，这次无法继续做单目 preview。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["preview_import_error"] = "asset_reader_output_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "视频读取输出没有准备成功，这次本地 preview 无法继续。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["preview_import_error"] = "asset_reader_start_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "视频帧读取启动失败了，这次本地 preview 还没法开始。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }

        let trackSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let width = max(1, Int(abs(trackSize.width.rounded())))
        let height = max(1, Int(abs(trackSize.height.rounded())))
        let durationSeconds = max(0.1, CMTimeGetSeconds(asset.duration))
        let estimatedSubmittedFrames = max(
            1,
            min(
                budget.maxSubmittedFrames,
                Int(ceil(durationSeconds * max(budget.targetSubmittedFPS, 0.5)))
            )
        )
        let samplingIntervalSeconds = max(
            budget.minFrameIntervalSeconds,
            durationSeconds / Double(max(estimatedSubmittedFrames, 1))
        )
        targetSubmittedFrames = estimatedSubmittedFrames
        let sidecarIntrinsicsEstimate = importedVideoSidecarIntrinsicsEstimate(videoURL: sourceVideoURL)
        let metadataIntrinsicsEstimate = importedVideoMetadataIntrinsicsEstimate(
            asset: asset,
            videoTrack: videoTrack,
            width: width,
            height: height
        )

        var sampledFrames = 0
        var submittedFrames = 0
        var framesWithCameraIntrinsics = 0
        var framesWithSidecarIntrinsics = 0
        var framesWithMetadataEstimatedIntrinsics = 0
        var framesUsingColmapDefaultIntrinsics = 0
        var lastSubmittedPTS = -Double.infinity
        let startWallClock = CFAbsoluteTimeGetCurrent()
        var latestSnapshot = bridge.getSnapshot()
        lastSnapshotPollAt = startWallClock

        while let sample = output.copyNextSampleBuffer() {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSnapshotPollAt >= periodicSnapshotPollSeconds {
                latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
                lastSnapshotPollAt = now
            }
            if !waitForForegroundIfNeeded(
                phase: .depth,
                snapshot: latestSnapshot,
                submittedFrames: submittedFrames,
                minimumSelectedFrames: minimumSelectedFramesToStartTraining
            ) {
                var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                    snapshot: latestSnapshot,
                    sourceVideo: sourceRelativePath,
                    exported: false,
                    sourceKind: "imported_video",
                    thermalState: thermalAtFinish
                )
                metrics["preview_import_error"] = "foreground_required_for_gpu_depth"
                metrics["preview_import_foreground_wait_expired"] = "1"
                return buildResult(
                    snapshot: latestSnapshot,
                    exported: false,
                    runtimeMetrics: metrics,
                    detailMessage: foregroundRequiredDetail,
                    terminalPhase: .depth,
                    terminalProgressFraction: boundedPhaseProgress(
                        .depth,
                        snapshot: latestSnapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: minimumSelectedFramesToStartTraining
                    ),
                    liveSubmittedFrames: submittedFrames,
                    liveMinimumSelectedFrames: minimumSelectedFramesToStartTraining,
                    liveTargetFrames: targetSubmittedFrames
                )
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if pts.isFinite,
               submittedFrames > 0,
               pts - lastSubmittedPTS < samplingIntervalSeconds {
                continue
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { continue }
            let rgba = baseAddress.assumingMemoryBound(to: UInt8.self)
            let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
            let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
            let directCameraIntrinsics = importedVideoCameraIntrinsics(
                from: sample,
                videoTrack: videoTrack
            )
            let submittedCameraIntrinsics: simd_float3x3?
            let intrinsicsSource: ImportedVideoIntrinsicsSource
            if let directCameraIntrinsics {
                submittedCameraIntrinsics = directCameraIntrinsics
                intrinsicsSource = .real
                framesWithCameraIntrinsics += 1
            } else if let sidecarIntrinsicsEstimate {
                submittedCameraIntrinsics = sidecarIntrinsicsEstimate.intrinsics
                intrinsicsSource = .real
                framesWithSidecarIntrinsics += 1
                if framesWithSidecarIntrinsics <= 3 ||
                    framesWithSidecarIntrinsics % 20 == 0 {
                    appendTrace(
                        "camera_intrinsics",
                        phase: .depth,
                        snapshot: latestSnapshot,
                        submittedFrames: submittedFrames,
                        detail: "source=capture_sidecar frame=\(sampledFrames + 1) label=\(sidecarIntrinsicsEstimate.sourceLabel)"
                    )
                }
            } else if let metadataIntrinsicsEstimate {
                submittedCameraIntrinsics = metadataIntrinsicsEstimate.intrinsics
                intrinsicsSource = .metadata35mmEquivalent
                framesWithMetadataEstimatedIntrinsics += 1
                if framesWithMetadataEstimatedIntrinsics <= 3 ||
                    framesWithMetadataEstimatedIntrinsics % 20 == 0 {
                    appendTrace(
                        "camera_intrinsics",
                        phase: .depth,
                        snapshot: latestSnapshot,
                        submittedFrames: submittedFrames,
                        detail: String(
                            format: "source=metadata_35mm frame=%d focal35mm=%.2f",
                            sampledFrames + 1,
                            metadataIntrinsicsEstimate.focalLength35mmEquivalentMM
                        )
                    )
                }
            } else {
                submittedCameraIntrinsics = nil
                intrinsicsSource = .colmapDefault
                framesUsingColmapDefaultIntrinsics += 1
                if framesUsingColmapDefaultIntrinsics <= 5 ||
                    framesUsingColmapDefaultIntrinsics % 20 == 0 {
                    appendTrace(
                        "camera_intrinsics",
                        phase: .depth,
                        snapshot: latestSnapshot,
                        submittedFrames: submittedFrames,
                        detail: "source=colmap_default frame=\(sampledFrames + 1)"
                    )
                }
            }

            sampledFrames += 1

#if canImport(PR5Capture)
            if let photometricStats = samplePhotometricStats(pixelBuffer: pixelBuffer) {
                // Imported-video local_preview must stay fire-and-forget on the
                // hot path. PR5 photometric consistency checks are useful for
                // diagnostics, but running them synchronously per bootstrap
                // frame makes album ingestion look "stuck" before native depth
                // has even had a chance to catch up.
                if sampledFrames == 1 {
                    let photometricDecision = evaluatePhotometricDecision(
                        stats: photometricStats,
                        exposureChecker: exposureChecker,
                        whiteBalanceValidator: whiteBalanceValidator
                    )
                    photometricCounters.lastExposureConsistencyScore =
                        photometricDecision.exposureConsistencyScore
                    photometricCounters.lastWhiteBalanceConsistencyScore =
                        photometricDecision.whiteBalanceConsistencyScore
                    if !photometricDecision.exposureAccepted {
                        photometricCounters.exposureRejects += 1
                    }
                    if !photometricDecision.whiteBalanceAccepted {
                        photometricCounters.whiteBalanceRejects += 1
                    }
                }
                photometricCounters.acceptedFrames += 1
            }
#endif

            let frameTimestamp = pts.isFinite
                ? pts
                : (Double(sampledFrames) * samplingIntervalSeconds)
            var accepted = false
            let submitDeadline = CFAbsoluteTimeGetCurrent() + 0.08
            repeat {
                accepted = bridge.onImportedVideoFrame(
                    rgba: rgba,
                    width: UInt32(pixelWidth),
                    height: UInt32(pixelHeight),
                    cameraIntrinsics: submittedCameraIntrinsics,
                    intrinsicsSource: intrinsicsSource.rawValue,
                    timestampSeconds: frameTimestamp,
                    frameIndex: UInt32(max(sampledFrames - 1, 0)),
                    totalFrames: UInt32(estimatedSubmittedFrames),
                    thermalState: ProcessInfo.processInfo.thermalState.rawValue
                )
                if accepted {
                    break
                }
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    lastSnapshotPollAt = CFAbsoluteTimeGetCurrent()
                }
                Thread.sleep(forTimeInterval: max(budget.ingestPollIntervalSeconds, 0.002))
            } while CFAbsoluteTimeGetCurrent() < submitDeadline
            if accepted {
                submittedFrames += 1
                lastSubmittedPTS = frameTimestamp
                let bootstrapFrameBudget = max(budget.bootstrapFrameBudget, 1)
                let latestDepthReady =
                    Int(latestSnapshot?.preview_depth_results_ready ?? 0)
                let latestSelectedFrames =
                    Int(latestSnapshot?.selected_frames ?? 0)
                let latestSeedCandidates =
                    Int(latestSnapshot?.preview_seed_candidates ?? 0)
                let eagerBootstrap =
                    latestDepthReady < max(budget.minDepthResultsBeforeFinalize, 1) ||
                    latestSelectedFrames < minimumSelectedFramesToStartTraining ||
                    latestSeedCandidates == 0
                let shouldPulseBootstrap =
                    submittedFrames == 1 ||
                    eagerBootstrap ||
                    submittedFrames == bootstrapFrameBudget ||
                    submittedFrames % max(budget.nativeCatchUpStride, 1) == 0
                if shouldPulseBootstrap {
                    _ = bridge.serviceLocalPreviewBootstrap()
                }
                let shouldRefreshSnapshot =
                    submittedFrames == 1 ||
                    eagerBootstrap ||
                    submittedFrames % 16 == 0 ||
                    CFAbsoluteTimeGetCurrent() - lastSnapshotPollAt >= periodicSnapshotPollSeconds
                if shouldRefreshSnapshot {
                    latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
                    lastSnapshotPollAt = CFAbsoluteTimeGetCurrent()
                }
                emitLivePhase(
                    .depth,
                    snapshot: latestSnapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minimumSelectedFramesToStartTraining,
                    force: submittedFrames <= bootstrapFrameBudget || shouldPulseBootstrap
                )
            }

            if submittedFrames >= budget.maxSubmittedFrames {
                break
            }
            if let snapshot = latestSnapshot ?? bridge.getSnapshot(),
               Int(snapshot.selected_frames) >= budget.targetSelectedFrames {
                let seedAccepted = Int(snapshot.preview_seed_accepted)
                let pendingGaussians = Int(snapshot.pending_gaussian_count)
                let depthReady = Int(snapshot.preview_depth_results_ready)
                let trainingStarted =
                    snapshot.training_active != 0 || Int(snapshot.training_step) > 0
                let readyToStopIngesting =
                    depthReady >= max(budget.minDepthResultsBeforeFinalize, 1) &&
                    (trainingStarted || seedAccepted > 0 || pendingGaussians >= 8000)
                if readyToStopIngesting {
                    break
                }
            }
        }

        let outstandingFrames = max(
            0,
            submittedFrames - Int(latestSnapshot?.preview_frames_ingested ?? 0)
        )
        let dynamicDrainSeconds = max(
            budget.preFinishDrainSeconds,
            min(8.0, 1.0 + Double(outstandingFrames) * 0.12)
        )
        let finalizeCatchUpSeconds = max(
            dynamicDrainSeconds,
            min(12.0, 1.5 + Double(outstandingFrames) * 0.10)
        )

        latestSnapshot = waitForNativeCatchUp(
            submittedFrames: submittedFrames,
            requireBootstrap: true,
            timeoutSeconds: dynamicDrainSeconds,
            requireAllProcessed: false,
            minimumSelectedFrames: minimumSelectedFramesToStartTraining,
            phaseDuringWait: .depth
        )

        _ = bridge.serviceLocalPreviewBootstrap()
        if let refreshedSnapshot = bridge.getSnapshot() {
            latestSnapshot = refreshedSnapshot
        }

        let minimumFramesForTraining = max(
            Int(latestSnapshot?.min_frames_needed ?? 0),
            minimumSelectedFramesToStartTraining
        )
        var depthBootstrapReady = hasDepthPhaseEvidence(
            latestSnapshot,
            minimumSelectedFrames: minimumFramesForTraining
        )

        if !depthBootstrapReady {
            latestSnapshot = waitForNativeCatchUp(
                submittedFrames: submittedFrames,
                requireBootstrap: true,
                timeoutSeconds: finalizeCatchUpSeconds,
                requireAllProcessed: true,
                minimumSelectedFrames: minimumSelectedFramesToStartTraining,
                phaseDuringWait: .depth
            )
            _ = bridge.finishScanning()
            latestSnapshot = waitForNativeCatchUp(
                submittedFrames: submittedFrames,
                requireBootstrap: false,
                timeoutSeconds: dynamicDrainSeconds,
                requireAllProcessed: false,
                minimumSelectedFrames: minimumSelectedFramesToStartTraining,
                phaseDuringWait: .depth
            )
            _ = bridge.serviceLocalPreviewBootstrap()
            if let refreshedSnapshot = bridge.getSnapshot() {
                latestSnapshot = refreshedSnapshot
            }
            depthBootstrapReady = hasDepthPhaseEvidence(
                latestSnapshot,
                minimumSelectedFrames: minimumFramesForTraining
            )
        }

        if !depthBootstrapReady {
            let snapshot = bridge.getSnapshot() ?? latestSnapshot
            let baseMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: snapshot,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: ProcessInfo.processInfo.thermalState
            )
            let metrics = LocalPreviewMetricsArchive.appendingImportedVideoContext(
                to: baseMetrics,
                width: width,
                height: height,
                durationSeconds: durationSeconds,
                sampledFrames: sampledFrames,
                submittedFrames: submittedFrames,
                framesWithCameraIntrinsics: framesWithCameraIntrinsics,
                framesWithSidecarIntrinsics: framesWithSidecarIntrinsics,
                framesWithMetadataEstimatedIntrinsics: framesWithMetadataEstimatedIntrinsics,
                framesUsingColmapDefaultIntrinsics: framesUsingColmapDefaultIntrinsics,
                focalLength35mmEquivalentMM: metadataIntrinsicsEstimate?.focalLength35mmEquivalentMM,
                samplingIntervalSeconds: samplingIntervalSeconds,
                photometricAcceptedFrames: photometricCounters.acceptedFrames,
                photometricExposureRejects: photometricCounters.exposureRejects,
                photometricWhiteBalanceRejects: photometricCounters.whiteBalanceRejects,
                lastExposureConsistencyScore: photometricCounters.lastExposureConsistencyScore,
                lastWhiteBalanceConsistencyScore: photometricCounters.lastWhiteBalanceConsistencyScore,
                budget: budget,
                reachedSteps: 0,
                totalElapsedMs: UInt64(max(0, (CFAbsoluteTimeGetCurrent() - startWallClock) * 1000.0))
            )
            emitLivePhase(
                .depth,
                snapshot: snapshot,
                submittedFrames: submittedFrames,
                minSelectedFrames: minimumFramesForTraining
            )
            return buildResult(
                snapshot: snapshot,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "这次本地预览没能导出成功。相册视频已经读完，但在保底预算内仍然没有拿到可启动 preview 的深度/seed 信号，所以本地链没法继续往下走。",
                terminalPhase: .depth,
                terminalProgressFraction: boundedPhaseProgress(
                    .depth,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minimumFramesForTraining
                ),
                liveSubmittedFrames: submittedFrames,
                liveMinimumSelectedFrames: minimumFramesForTraining,
                liveTargetFrames: targetSubmittedFrames
            )
        }

        let seedDetail: String = {
            let depthReady = Int(latestSnapshot?.preview_depth_results_ready ?? 0)
            if depthReady > 0 {
                return "深度先验已经回流，正在根据有效深度和局部一致性初始化 preview 高斯。"
            }
            return "正在等待最后一批单目 depth prior 回流，再启动 preview 高斯初始化。"
        }()

        emitPhase(
            LocalPreviewWorkflowPhase.seed,
            snapshot: latestSnapshot,
            detailOverride: seedDetail
        )

        latestSnapshot = waitForNativeCatchUp(
            submittedFrames: submittedFrames,
            requireBootstrap: true,
            timeoutSeconds: finalizeCatchUpSeconds,
            requireAllProcessed: true,
            minimumSelectedFrames: minimumFramesForTraining,
            phaseDuringWait: .seed
        )
        _ = bridge.finishScanning()
        latestSnapshot = waitForNativeCatchUp(
            submittedFrames: submittedFrames,
            requireBootstrap: true,
            timeoutSeconds: dynamicDrainSeconds,
            requireAllProcessed: false,
            minimumSelectedFrames: minimumFramesForTraining,
            phaseDuringWait: .seed
        )
        let seedBootstrapReady = hasSeedPhaseEvidence(
            latestSnapshot,
            minimumSelectedFrames: minimumFramesForTraining
        )

        if !seedBootstrapReady {
            let snapshot = bridge.getSnapshot() ?? latestSnapshot
            let baseMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: snapshot,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: ProcessInfo.processInfo.thermalState
            )
            let metrics = LocalPreviewMetricsArchive.appendingImportedVideoContext(
                to: baseMetrics,
                width: width,
                height: height,
                durationSeconds: durationSeconds,
                sampledFrames: sampledFrames,
                submittedFrames: submittedFrames,
                framesWithCameraIntrinsics: framesWithCameraIntrinsics,
                framesWithSidecarIntrinsics: framesWithSidecarIntrinsics,
                framesWithMetadataEstimatedIntrinsics: framesWithMetadataEstimatedIntrinsics,
                framesUsingColmapDefaultIntrinsics: framesUsingColmapDefaultIntrinsics,
                focalLength35mmEquivalentMM: metadataIntrinsicsEstimate?.focalLength35mmEquivalentMM,
                samplingIntervalSeconds: samplingIntervalSeconds,
                photometricAcceptedFrames: photometricCounters.acceptedFrames,
                photometricExposureRejects: photometricCounters.exposureRejects,
                photometricWhiteBalanceRejects: photometricCounters.whiteBalanceRejects,
                lastExposureConsistencyScore: photometricCounters.lastExposureConsistencyScore,
                lastWhiteBalanceConsistencyScore: photometricCounters.lastWhiteBalanceConsistencyScore,
                budget: budget,
                reachedSteps: 0,
                totalElapsedMs: UInt64(max(0, (CFAbsoluteTimeGetCurrent() - startWallClock) * 1000.0))
            )
            emitLivePhase(
                .seed,
                snapshot: snapshot,
                submittedFrames: submittedFrames,
                minSelectedFrames: minimumFramesForTraining
            )
            return buildResult(
                snapshot: snapshot,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "这次本地预览没能导出成功。深度先验已经回流，但保底 seed 初始化仍然没拿到可开训的稳定几何，所以 preview 初始化被卡住了。",
                terminalPhase: .seed,
                terminalProgressFraction: boundedPhaseProgress(
                    .seed,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minimumFramesForTraining
                ),
                liveSubmittedFrames: submittedFrames,
                liveMinimumSelectedFrames: minimumFramesForTraining,
                liveTargetFrames: targetSubmittedFrames
            )
        }
        func resolveExportMinSteps(currentFloor: Int) -> Int {
            var resolved = max(currentFloor, budget.trainingMinSteps)
            if let progress = bridge.trainingProgress() {
                let totalSteps = Int(progress.total_steps)
                if totalSteps > 0 {
                    resolved = max(
                        resolved,
                        Int((Double(totalSteps) * 0.60).rounded(.awayFromZero))
                    )
                }
            }
            return resolved
        }

        func waitForTrainingForegroundAware(
            targetSteps: Int,
            deadline: inout CFAbsoluteTime
        ) -> Int {
            var reached = Int(latestSnapshot?.training_step ?? 0)
            while CFAbsoluteTimeGetCurrent() < deadline {
                let foregroundWaitStarted = CFAbsoluteTimeGetCurrent()
                let wasForeground = Self.isApplicationForegroundActive()
                guard waitForForegroundIfNeeded(
                    phase: .refine,
                    snapshot: latestSnapshot,
                    submittedFrames: submittedFrames,
                    minimumSelectedFrames: minimumFramesForTraining
                ) else {
                    break
                }
                if !wasForeground {
                    deadline += max(0, CFAbsoluteTimeGetCurrent() - foregroundWaitStarted)
                }
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    lastObservedGaussianCount = max(
                        lastObservedGaussianCount,
                        Int(snapshot.num_gaussians)
                    )
                    reached = max(reached, Int(snapshot.training_step))
                    emitLivePhase(
                        .refine,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(
                            Int(snapshot.min_frames_needed),
                            minimumSelectedFramesToStartTraining
                        )
                    )
                    if Int(snapshot.training_step) >= targetSteps {
                        break
                    }
                    if snapshot.training_active == 0 && snapshot.training_step > 0 {
                        break
                    }
                }
                Thread.sleep(forTimeInterval: max(0.10, budget.ingestPollIntervalSeconds))
            }
            return reached
        }

        bridge.setForegroundActive(Self.isApplicationForegroundActive())
        emitLivePhase(
            LocalPreviewWorkflowPhase.refine,
            snapshot: latestSnapshot,
            submittedFrames: submittedFrames,
            minSelectedFrames: minimumFramesForTraining
        )
        var trainingDeadline = CFAbsoluteTimeGetCurrent() + max(budget.trainingTimeoutSeconds, 0.0)
        var reachedSteps = Int(latestSnapshot?.training_step ?? 0)
        var exportMinSteps = resolveExportMinSteps(currentFloor: reachedSteps)
        while CFAbsoluteTimeGetCurrent() < trainingDeadline {
            let foregroundWaitStarted = CFAbsoluteTimeGetCurrent()
            let wasForeground = Self.isApplicationForegroundActive()
            guard waitForForegroundIfNeeded(
                phase: .refine,
                snapshot: latestSnapshot,
                submittedFrames: submittedFrames,
                minimumSelectedFrames: minimumFramesForTraining
            ) else {
                break
            }
            if !wasForeground {
                trainingDeadline += max(0, CFAbsoluteTimeGetCurrent() - foregroundWaitStarted)
            }
            exportMinSteps = resolveExportMinSteps(currentFloor: max(exportMinSteps, reachedSteps))
            if let snapshot = bridge.getSnapshot() {
                latestSnapshot = snapshot
                lastObservedGaussianCount = max(
                    lastObservedGaussianCount,
                    Int(snapshot.num_gaussians)
                )
                reachedSteps = max(reachedSteps, Int(snapshot.training_step))
                emitLivePhase(
                    LocalPreviewWorkflowPhase.refine,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: max(
                        Int(snapshot.min_frames_needed),
                        minimumSelectedFramesToStartTraining
                    )
                )
                if Int(snapshot.training_step) >= exportMinSteps {
                    break
                }
                if snapshot.training_active == 0 && snapshot.training_step > 0 {
                    break
                }
            }
            Thread.sleep(forTimeInterval: budget.ingestPollIntervalSeconds)
        }

        exportMinSteps = resolveExportMinSteps(currentFloor: max(exportMinSteps, reachedSteps))
        let exportWaitTargetSteps = max(exportMinSteps, reachedSteps)
        reachedSteps = max(
            reachedSteps,
            waitForTrainingForegroundAware(
                targetSteps: exportWaitTargetSteps,
                deadline: &trainingDeadline
            )
        )
        latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
        if let latestSnapshot {
            lastObservedGaussianCount = max(
                lastObservedGaussianCount,
                Int(latestSnapshot.num_gaussians)
            )
        }
        emitLivePhase(
            LocalPreviewWorkflowPhase.refine,
            snapshot: latestSnapshot,
            submittedFrames: submittedFrames,
            minSelectedFrames: max(
                Int(latestSnapshot?.min_frames_needed ?? 0),
                minimumSelectedFramesToStartTraining
            ),
            force: true
        )

        if reachedSteps < exportMinSteps,
           (latestSnapshot?.training_active ?? 0) != 0 {
            var extraRefineDeadline = trainingDeadline
            while CFAbsoluteTimeGetCurrent() < extraRefineDeadline {
                let foregroundWaitStarted = CFAbsoluteTimeGetCurrent()
                let wasForeground = Self.isApplicationForegroundActive()
                guard waitForForegroundIfNeeded(
                    phase: .refine,
                    snapshot: latestSnapshot,
                    submittedFrames: submittedFrames,
                    minimumSelectedFrames: minimumFramesForTraining
                ) else {
                    break
                }
                if !wasForeground {
                    extraRefineDeadline += max(0, CFAbsoluteTimeGetCurrent() - foregroundWaitStarted)
                }
                exportMinSteps = resolveExportMinSteps(currentFloor: max(exportMinSteps, reachedSteps))
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    lastObservedGaussianCount = max(
                        lastObservedGaussianCount,
                        Int(snapshot.num_gaussians)
                    )
                    reachedSteps = max(reachedSteps, Int(snapshot.training_step))
                    emitLivePhase(
                        LocalPreviewWorkflowPhase.refine,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(
                            Int(snapshot.min_frames_needed),
                            minimumSelectedFramesToStartTraining
                        )
                    )
                    if Int(snapshot.training_step) >= exportMinSteps ||
                        snapshot.training_active == 0 {
                        break
                    }
                }
                Thread.sleep(forTimeInterval: 0.20)
            }
        }

        latestSnapshot = bridge.getSnapshot()
        emitPhase(LocalPreviewWorkflowPhase.export, snapshot: latestSnapshot)
        let exportAttemptLimit = 3
        var exportAttempts = 0
        var exported = false
        var exportElapsedMs: UInt64 = 0
        var exportFileSizeBytes: UInt64 = 0
        while exportAttempts < exportAttemptLimit {
            exportAttempts += 1
            let exportAttemptStart = CFAbsoluteTimeGetCurrent()
            let attemptExported = bridge.exportPLY(path: artifactURL.path)
            exportElapsedMs += UInt64(
                max(0, (CFAbsoluteTimeGetCurrent() - exportAttemptStart) * 1000.0)
            )

            if let attributes = try? FileManager.default.attributesOfItem(atPath: artifactURL.path),
               let fileSize = (attributes[.size] as? NSNumber)?.uint64Value {
                exportFileSizeBytes = max(exportFileSizeBytes, fileSize)
            }

            if attemptExported && exportFileSizeBytes > 0 {
                exported = true
                break
            }

            latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
            reachedSteps = max(reachedSteps, Int(latestSnapshot?.training_step ?? 0))
            if exportAttempts < exportAttemptLimit &&
                ((latestSnapshot?.training_active ?? 0) != 0 || reachedSteps > 0) {
                Thread.sleep(forTimeInterval: 0.20)
            }
        }

        let snapshot = bridge.getSnapshot() ?? latestSnapshot
        let totalElapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - startWallClock) * 1000.0))

        let baseMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
            snapshot: snapshot,
            sourceVideo: sourceRelativePath,
            exported: exported,
            sourceKind: "imported_video",
            thermalState: ProcessInfo.processInfo.thermalState,
            exportElapsedMs: exportElapsedMs
        )
        var metrics = LocalPreviewMetricsArchive.appendingImportedVideoContext(
            to: baseMetrics,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            sampledFrames: sampledFrames,
            submittedFrames: submittedFrames,
            framesWithCameraIntrinsics: framesWithCameraIntrinsics,
            framesWithSidecarIntrinsics: framesWithSidecarIntrinsics,
            framesWithMetadataEstimatedIntrinsics: framesWithMetadataEstimatedIntrinsics,
            framesUsingColmapDefaultIntrinsics: framesUsingColmapDefaultIntrinsics,
            focalLength35mmEquivalentMM: metadataIntrinsicsEstimate?.focalLength35mmEquivalentMM,
            samplingIntervalSeconds: samplingIntervalSeconds,
            photometricAcceptedFrames: photometricCounters.acceptedFrames,
            photometricExposureRejects: photometricCounters.exposureRejects,
            photometricWhiteBalanceRejects: photometricCounters.whiteBalanceRejects,
            lastExposureConsistencyScore: photometricCounters.lastExposureConsistencyScore,
            lastWhiteBalanceConsistencyScore: photometricCounters.lastWhiteBalanceConsistencyScore,
            budget: budget,
            reachedSteps: reachedSteps,
            totalElapsedMs: totalElapsedMs
        )
        metrics["preview_export_attempts"] = "\(exportAttempts)"
        metrics["preview_export_file_size_bytes"] = "\(exportFileSizeBytes)"
        metrics["preview_export_wait_steps"] = "\(reachedSteps)"

        let detailMessage: String = {
            if exported {
                return "本地快速预览已生成。这个结果导出的是本地 Gaussian preview，不再回退成 TSDF/点云伪彩替代物。"
            }
            if reachedSteps > 0 || snapshot?.training_active != 0 {
                if let snapshot {
                    let step = Int(snapshot.training_step)
                    let gaussians = Int(snapshot.num_gaussians)
                    if step > 0 {
                        return "这次本地预览没能导出成功。本地 refine 已经真正启动并跑到 \(step) 步（当前 \(gaussians) 个高斯），但最终 preview artifact 还没有成功写出来。"
                    }
                    return "这次本地预览没能导出成功。初始化和本地 refine 已经启动（当前 \(gaussians) 个高斯），但最终 preview artifact 还没有成功写出来。"
                }
                return "这次本地预览没能导出成功。本地 refine 已经启动，但最终 preview artifact 还没有成功写出来。"
            }
            if let snapshot {
                if snapshot.selected_frames > 0 || snapshot.preview_seed_candidates > 0 || snapshot.preview_seed_accepted > 0 {
                    return "这次本地预览没能导出成功。单目 depth prior 已经回流，但关键帧 gate / seed 初始化没有拿到足够的稳定几何，preview 没能真正启动。"
                }
                if snapshot.preview_depth_results_ready == 0 {
                    return "这次本地预览没能导出成功。相册视频已经读完，但单目 depth prior 还没在预算内真正回流，所以 preview 没能启动。"
                }
                if snapshot.selected_frames == 0 {
                    return "这次本地预览没能导出成功。深度先验已经回流，但关键帧 gate 没有拿到足够的有效帧，preview 初始化被卡住了。"
                }
            }
            if photometricCounters.acceptedFrames == 0 &&
                (photometricCounters.exposureRejects > 0 || photometricCounters.whiteBalanceRejects > 0) {
                return "这次本地预览没能导出成功。相册视频在曝光或白平衡一致性上不稳定，导入帧在 photometric gate 里被全部拦下了。"
            }
            if reachedSteps == 0 {
                return "这次本地预览没能导出成功。视频读取已经完成，但本地 refine 没有真正启动，所以最终 preview artifact 没有写出来。"
            }
            return "这次本地预览没能导出成功。视频读取和训练链已经跑通，但最终 preview artifact 没有写出来。"
        }()

        let terminalFailurePhase: LocalPreviewWorkflowPhase = {
            guard !exported else { return .export }
            if reachedSteps > 0 || snapshot?.training_active != 0 {
                return .refine
            }
            if let snapshot {
                if snapshot.preview_seed_accepted > 0 ||
                    snapshot.preview_seed_candidates > 0 ||
                    snapshot.pending_gaussian_count > 0 ||
                    snapshot.selected_frames > 0 {
                    return .seed
                }
                if snapshot.preview_depth_results_ready > 0 {
                    return .depth
                }
            }
            return .depth
        }()

        return buildResult(
            snapshot: snapshot,
            exported: exported,
            runtimeMetrics: metrics,
            detailMessage: detailMessage,
            terminalPhase: terminalFailurePhase,
            terminalProgressFraction: exported
                ? 1.0
                : boundedPhaseProgress(
                    terminalFailurePhase,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minimumFramesForTraining
                ),
            liveSubmittedFrames: submittedFrames,
            liveMinimumSelectedFrames: minimumFramesForTraining,
            liveTargetFrames: targetSubmittedFrames
        )
    }
}
#endif
