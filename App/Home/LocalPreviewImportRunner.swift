//
// LocalPreviewImportRunner.swift
// Aether3D
//
// Imported-video local subject-first runner extracted out of HomeViewModel so
// the product split can evolve without repeatedly modifying shared UI state logic.
//

import Foundation
import Aether3DCore
import Dispatch
import simd

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Metal)
import Metal
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
    private struct CoordinatorHandles: @unchecked Sendable {
        let gpuDevice: OpaquePointer
        let splatEngine: OpaquePointer
        let bridge: PipelineCoordinatorBridge?
    }

    private struct SendableHandle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    private final class CoordinatorTeardownBox: @unchecked Sendable {
        var bridge: PipelineCoordinatorBridge?

        init(_ bridge: PipelineCoordinatorBridge?) {
            self.bridge = bridge
        }
    }

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

    static func subjectRawArtifactPath(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent()
            .appendingPathComponent(finalURL.deletingPathExtension().lastPathComponent + ".raw.ply")
    }

    static func subjectCutoutArtifactPath(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent()
            .appendingPathComponent(finalURL.deletingPathExtension().lastPathComponent + ".cutout.ply")
    }

    static func subjectCleanupArtifactPath(for finalURL: URL) -> URL {
        finalURL.deletingLastPathComponent()
            .appendingPathComponent(finalURL.deletingPathExtension().lastPathComponent + ".cleanup.ply")
    }

    private static func adoptFinalSubjectArtifact(
        from sourceURL: URL,
        to finalArtifactURL: URL,
        baseMetrics: inout [String: String]
    ) -> Bool {
        let adoptStart = CFAbsoluteTimeGetCurrent()

        func recordSuccess(strategy: String) -> Bool {
            let elapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - adoptStart) * 1000.0))
            baseMetrics["native_subject_final_adopt_strategy"] = strategy
            baseMetrics["native_subject_final_adopt_ms"] = String(elapsedMs)
            NSLog(
                "[Aether3D] ✅ Local subject final artifact adopt strategy=%@ source=%@ final=%@ elapsed_ms=%llu",
                strategy,
                sourceURL.path,
                finalArtifactURL.path,
                elapsedMs
            )
            return true
        }

        func recordFailure(_ error: Error) -> Bool {
            let elapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - adoptStart) * 1000.0))
            baseMetrics["native_subject_final_copy_failed"] = "1"
            baseMetrics["native_subject_final_copy_error"] = error.localizedDescription
            baseMetrics["native_subject_final_adopt_ms"] = String(elapsedMs)
            NSLog(
                "[Aether3D] ❌ Local subject final artifact adopt failed source=%@ final=%@ elapsed_ms=%llu error=%@",
                sourceURL.path,
                finalArtifactURL.path,
                elapsedMs,
                error.localizedDescription
            )
            return false
        }

        do {
            if FileManager.default.fileExists(atPath: finalArtifactURL.path) {
                try FileManager.default.removeItem(at: finalArtifactURL)
            }

            do {
                try FileManager.default.linkItem(at: sourceURL, to: finalArtifactURL)
                return recordSuccess(strategy: "hardlink")
            } catch {
                baseMetrics["native_subject_final_link_failed"] = "1"
                baseMetrics["native_subject_final_link_error"] = error.localizedDescription
                NSLog(
                    "[Aether3D] Local subject final artifact hardlink fallback source=%@ final=%@ error=%@",
                    sourceURL.path,
                    finalArtifactURL.path,
                    error.localizedDescription
                )
            }

            try FileManager.default.copyItem(at: sourceURL, to: finalArtifactURL)
            return recordSuccess(strategy: "copy")
        } catch {
            return recordFailure(error)
        }
    }

    static func finalizeLocalSubjectArtifactsIfNeeded(
        processingBackend: ProcessingBackendChoice,
        rawArtifactURL: URL,
        finalArtifactURL: URL,
        baseMetrics: inout [String: String],
        phaseEmitter: ((_ phase: LocalPreviewWorkflowPhase, _ detail: String?) async -> Void)? = nil
    ) async -> (exported: Bool, detailMessage: String) {
        guard processingBackend == .localSubjectFirst else {
            return (
                FileManager.default.fileExists(atPath: finalArtifactURL.path),
                "本地结果已生成。这个结果导出的是本地 Gaussian 结果文件，不再回退成 TSDF/点云伪彩替代物。"
            )
        }

        let cutoutArtifactURL = subjectCutoutArtifactPath(for: finalArtifactURL)
        let cleanupArtifactURL = subjectCleanupArtifactPath(for: finalArtifactURL)
        baseMetrics["native_subject_raw_path"] = rawArtifactURL.path
        baseMetrics["native_subject_cutout_path"] = cutoutArtifactURL.path
        baseMetrics["native_subject_cleanup_path"] = cleanupArtifactURL.path

        func fileExistsNonEmpty(_ url: URL) -> Bool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else {
                return false
            }
            return fileSize > 0
        }

        func adoptFinalArtifact(from sourceURL: URL) -> Bool {
            Self.adoptFinalSubjectArtifact(
                from: sourceURL,
                to: finalArtifactURL,
                baseMetrics: &baseMetrics
            )
        }

        func cleanupClearlyWorse(
            cutoutStats: aether_subject_cleanup_stats_t,
            cleanupStats: aether_subject_cleanup_stats_t
        ) -> Bool {
            let cutoutKept = max(Double(cutoutStats.cutout_kept_splats), 0)
            let cleanupKept = max(Double(cleanupStats.cleanup_kept_splats), 0)
            let cutoutSpan = max(Double(cutoutStats.cutout_scene_span), 0)
            let cleanupSpan = max(Double(cleanupStats.cleanup_scene_span), 0)
            let aggressiveCountDrop =
                cutoutKept > 0 &&
                cleanupKept > 0 &&
                cleanupKept < cutoutKept * 0.72
            let aggressiveSpanCollapse =
                cutoutSpan > 0 &&
                cleanupSpan > 0 &&
                cleanupSpan < cutoutSpan * 0.62
            let removedMany = Int(cleanupStats.cleanup_removed_splats) >= max(
                1500,
                Int((cutoutKept / 5.0).rounded(.down))
            )
            return aggressiveSpanCollapse || (aggressiveCountDrop && removedMany)
        }

        await phaseEmitter?(
            .cutout,
            "正在做 mask / boundary cutout，先把边界薄带和接触面站住。"
        )

#if !canImport(CAetherNativeBridge)
        baseMetrics["native_subject_cleanup_strategy"] = "disabled_raw_retention"
        baseMetrics["native_subject_cleanup_failed"] = "1"
        return (
            false,
            "本地结果在 cutout / cleanup 阶段失败了。raw artifact 已保留为 sidecar，但不会再回退成旧结果。"
        )
#else
        var cutoutStats = aether_subject_cleanup_stats_t()
        let cutoutStart = CFAbsoluteTimeGetCurrent()
        let cutoutStatus = rawArtifactURL.path.withCString { inputPtr in
            cutoutArtifactURL.path.withCString { outputPtr in
                aether_splat_subject_cutout_ply(inputPtr, outputPtr, &cutoutStats)
            }
        }
        let cutoutElapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - cutoutStart) * 1000.0))
        baseMetrics["native_phase_cutout_ms"] = String(cutoutElapsedMs)
        baseMetrics["native_subject_input_splats"] = String(cutoutStats.input_splats)
        baseMetrics["native_subject_mask_seed_kept"] = String(cutoutStats.mask_seed_kept_splats)
        baseMetrics["native_subject_boundary_refined"] = String(cutoutStats.boundary_refined_splats)
        baseMetrics["native_subject_boundary_split"] = String(cutoutStats.boundary_split_splats)
        baseMetrics["native_subject_cutout_kept"] = String(cutoutStats.cutout_kept_splats)
        baseMetrics["native_subject_input_scene_span"] = String(cutoutStats.input_scene_span)
        baseMetrics["native_subject_cutout_scene_span"] = String(cutoutStats.cutout_scene_span)
        baseMetrics["native_cutout_phase_metric_text"] =
            "\(cutoutStats.mask_seed_kept_splats) -> \(cutoutStats.cutout_kept_splats)"

        guard cutoutStatus == 0, fileExistsNonEmpty(cutoutArtifactURL) else {
            baseMetrics["native_subject_cleanup_strategy"] = "cutout_failed_raw_retained"
            baseMetrics["native_subject_cutout_failed"] = "1"
            return (
                false,
                "本地结果已经导出出 raw Gaussian，但 cutout 阶段没有成功产出。raw artifact 已保留，方便后续直接对比 cutout 之前的训练结果。"
            )
        }

        await phaseEmitter?(
            .cleanup,
            "正在沿边界 mask 做最后收口，清理低置信碎边并尽量保住连续几何。"
        )

        var cleanupStats = aether_subject_cleanup_stats_t()
        let cleanupStart = CFAbsoluteTimeGetCurrent()
        let cleanupStatus = cutoutArtifactURL.path.withCString { inputPtr in
            cleanupArtifactURL.path.withCString { outputPtr in
                aether_splat_subject_cleanup_cutout_ply(inputPtr, outputPtr, &cleanupStats)
            }
        }
        let cleanupElapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - cleanupStart) * 1000.0))
        baseMetrics["native_phase_cleanup_ms"] = String(cleanupElapsedMs)
        baseMetrics["native_subject_cleanup_kept"] = String(cleanupStats.cleanup_kept_splats)
        baseMetrics["native_subject_cleanup_removed"] = String(cleanupStats.cleanup_removed_splats)
        baseMetrics["native_subject_cleanup_scene_span"] = String(cleanupStats.cleanup_scene_span)
        baseMetrics["native_cleanup_phase_metric_text"] =
            "\(cleanupStats.cutout_kept_splats) -> \(cleanupStats.cleanup_kept_splats)"

        let cleanupSucceeded = cleanupStatus == 0 && fileExistsNonEmpty(cleanupArtifactURL)
        let useCleanup = cleanupSucceeded && !cleanupClearlyWorse(
            cutoutStats: cutoutStats,
            cleanupStats: cleanupStats
        )
        let selectedArtifactURL = useCleanup ? cleanupArtifactURL : cutoutArtifactURL
        let selectedStage = useCleanup ? "cleanup" : "cutout"
        let selectedReason: String = {
            if useCleanup {
                return "cleanup_kept"
            }
            if !cleanupSucceeded {
                return "cleanup_failed_fallback_cutout"
            }
            return "cleanup_collapse_fallback_cutout"
        }()

        baseMetrics["native_subject_selected_stage"] = selectedStage
        baseMetrics["native_subject_cleanup_strategy"] = selectedReason
        if !cleanupSucceeded {
            baseMetrics["native_subject_cleanup_failed"] = "1"
        } else if selectedStage == "cutout" {
            baseMetrics["native_subject_cleanup_regressed"] = "1"
        }

        guard adoptFinalArtifact(from: selectedArtifactURL), fileExistsNonEmpty(finalArtifactURL) else {
            return (
                false,
                "raw / cutout / cleanup 三段都已经单独落盘，但最终结果回填到主产物路径时失败了。sidecar 已保留，方便继续逐段排查。"
            )
        }

        if selectedStage == "cleanup" {
            return (
                true,
                "本地结果已生成。最终结果来自独立 cleanup 产物；raw 和 cutout sidecar 也已经保留，后面可以逐段对比。"
            )
        }

        return (
            true,
            cleanupSucceeded
                ? "本地结果已生成。cleanup 相比 cutout 明显更糟，最终已自动回退到 cutout 结果；raw / cleanup sidecar 也都保留了，方便逐段对比。"
                : "本地结果已生成。cleanup 阶段失败，最终已自动回退到 cutout 结果；raw / cleanup sidecar 也都保留了，方便逐段对比。"
        )
#endif
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
        // Some recorded-video attachments store the 3x3 intrinsics payload in
        // row-major float order. `matrix_float3x3` is column-major, so copying
        // those bytes verbatim lands `cx/cy` in the third row and collapses the
        // principal point to zero when we later flatten to C++ row-major form.
        // Detect that layout and transpose it back into the expected camera
        // matrix before validation.
        let decodedCX = matrix.columns.2.x
        let decodedCY = matrix.columns.2.y
        let rowMajorCX = matrix.columns.0.z
        let rowMajorCY = matrix.columns.1.z
        let thirdColumnLooksEmpty =
            abs(decodedCX) < 0.001 && abs(decodedCY) < 0.001
        let rowMajorPrincipalPointPresent =
            rowMajorCX.isFinite && rowMajorCY.isFinite &&
            (abs(rowMajorCX) > 1.0 || abs(rowMajorCY) > 1.0)
        if thirdColumnLooksEmpty && rowMajorPrincipalPointPresent {
            matrix = matrix.transpose
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
    ) async -> Double? {
        guard let item else { return nil }
        guard #available(iOS 15.0, *) else { return nil }
        if let number = try? await item.load(.numberValue) {
            let value = number.doubleValue
            if value.isFinite, value > 0.0 {
                return value
            }
        }
        if let string = try? await item.load(.stringValue) {
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
    ) async -> [AVMetadataItem] {
        guard #available(iOS 15.0, *) else { return [] }
        var metadata: [AVMetadataItem] = []
        if let common = try? await asset.load(.commonMetadata) {
            metadata.append(contentsOf: common)
        }
        if let assetMetadata = try? await asset.load(.metadata) {
            metadata.append(contentsOf: assetMetadata)
        }
        if let assetFormats = try? await asset.load(.availableMetadataFormats) {
            for format in assetFormats {
                if let items = try? await asset.loadMetadata(for: format) {
                    metadata.append(contentsOf: items)
                }
            }
        }
        if let trackFormats = try? await videoTrack.load(.availableMetadataFormats) {
            for format in trackFormats {
                if let items = try? await videoTrack.loadMetadata(for: format) {
                    metadata.append(contentsOf: items)
                }
            }
        }
        return metadata
    }

    private static func importedVideoMetadataIntrinsicsEstimate(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        width: Int,
        height: Int
    ) async -> ImportedVideoMetadataIntrinsicsEstimate? {
        let metadata = await importedVideoMetadataItems(asset: asset, videoTrack: videoTrack)
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
        guard let focal35mmEquivalentMM = await parsePositiveMetadataDouble(from: focalItem) else {
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
        formatDescriptions: [CMFormatDescription]
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

        for formatDescription in formatDescriptions {
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

    private static func loadedDurationSeconds(for asset: AVAsset) async -> TimeInterval {
        guard #available(iOS 15.0, *) else { return 0 }
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
        }
        return 0
    }

    static func execute(
        sourceVideoURL: URL,
        artifactURL: URL,
        sourceRelativePath: String,
        frameSamplingProfile: FrameSamplingProfile,
        processingBackend: ProcessingBackendChoice = .localSubjectFirst,
        onPhaseUpdate: (@Sendable (LocalPreviewPhaseUpdate) -> Void)? = nil
    ) async -> LocalPreviewImportResult {
        let processingBackend = processingBackend.normalizedForActiveUse
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
        var lastEmittedTrainingStarted = false
        var lastEmittedRealTrainingStep = -1
        var lastSnapshotPollAt: CFAbsoluteTime = 0.0
        var lastObservedGaussianCount = 0
        var lastObservedPendingGaussianCount = 0
        var lastObservedWorkingSetCount = 0
        var lastObservedRetainedExportGaussianCount = 0
        var traceLines: [String] = []

        func observeSnapshotPeaks(_ snapshot: aether_evidence_snapshot_t?) {
            guard let snapshot else { return }
            let currentGaussians = max(Int(snapshot.num_gaussians), 0)
            let pendingGaussians = max(Int(snapshot.pending_gaussian_count), 0)
            let retainedGaussians = max(Int(snapshot.retained_export_gaussians), 0)
            let peakGaussians = max(Int(snapshot.peak_training_gaussians), currentGaussians)
            let peakWorkingSet = max(Int(snapshot.peak_working_set_gaussians), currentGaussians + pendingGaussians)
            let peakRetainedGaussians = max(Int(snapshot.peak_retained_export_gaussians), retainedGaussians)
            lastObservedGaussianCount = max(lastObservedGaussianCount, peakGaussians)
            lastObservedPendingGaussianCount = max(
                lastObservedPendingGaussianCount,
                pendingGaussians
            )
            lastObservedWorkingSetCount = max(
                lastObservedWorkingSetCount,
                peakWorkingSet
            )
            lastObservedRetainedExportGaussianCount = max(
                lastObservedRetainedExportGaussianCount,
                peakRetainedGaussians
            )
        }

        func gaussianLifecycleSummary(
            currentGaussians: Int,
            retainedExportGaussians: Int
        ) -> String {
            let peakGaussians = max(lastObservedGaussianCount, currentGaussians)
            let peakWorkingSet = max(lastObservedWorkingSetCount, currentGaussians)
            let peakRetainedGaussians = max(
                lastObservedRetainedExportGaussianCount,
                retainedExportGaussians
            )
            var components = ["训练器当前 \(currentGaussians) 个"]
            if peakGaussians > currentGaussians {
                components.append("训练峰值 \(peakGaussians) 个")
            }
            if retainedExportGaussians > 0 {
                components.append("保留导出快照 \(retainedExportGaussians) 个")
            } else if peakRetainedGaussians > 0 {
                components.append("历史保留快照峰值 \(peakRetainedGaussians) 个")
            }
            if peakWorkingSet > peakGaussians {
                components.append("含 pending 的工作集峰值 \(peakWorkingSet) 个")
            }
            return components.joined(separator: "，")
        }

        func likelyCollapsedAfterInitialization(currentGaussians: Int) -> Bool {
            let peakEvidenceCount = max(lastObservedWorkingSetCount, 0)
            guard peakEvidenceCount > 0 else { return false }
            let peakGaussians = max(lastObservedGaussianCount, currentGaussians)
            return peakEvidenceCount >= max(2048, currentGaussians * 8) &&
                peakGaussians <= peakEvidenceCount / 2
        }

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
                processingBackend: processingBackend,
                thermalState: thermalAtFinish,
                exportElapsedMs: exportElapsedMs
            )
            metrics["native_active_phase"] = phase.phaseName
            metrics["native_phase_model"] = LocalPreviewProductProfile.phaseModelDescriptor(
                for: processingBackend
            )
            if !traceLines.isEmpty {
                metrics["native_trace_last_event"] = traceLines.last
                metrics["native_trace_log"] = traceLines.joined(separator: "\n")
            }
            if let snapshot {
                observeSnapshotPeaks(snapshot)
                metrics["native_current_gaussians"] = String(snapshot.num_gaussians)
                metrics["native_current_pending_gaussians"] = String(snapshot.pending_gaussian_count)
                metrics["native_current_working_set"] = String(
                    max(Int(snapshot.num_gaussians) + Int(snapshot.pending_gaussian_count), 0)
                )
            }
            if lastObservedGaussianCount > 0 {
                metrics["native_gaussians"] = String(lastObservedGaussianCount)
                metrics["native_peak_gaussians"] = String(lastObservedGaussianCount)
            }
            if lastObservedPendingGaussianCount > 0 {
                metrics["native_peak_pending_gaussians"] = String(lastObservedPendingGaussianCount)
            }
            if lastObservedWorkingSetCount > 0 {
                metrics["native_peak_working_set"] = String(lastObservedWorkingSetCount)
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
            let ingested = Int(snapshot?.onDeviceFramesIngested ?? 0)
            let selected = Int(snapshot?.selected_frames ?? 0)
            let depthReady = Int(snapshot?.onDeviceDepthResultsReady ?? 0)
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
                Int(snapshot?.onDeviceFramesEnqueued ?? 0)
            )
            let ingestedFrames = Int(snapshot?.onDeviceFramesIngested ?? 0)
            let backlogFrames = Int(snapshot?.onDeviceFrameBacklog ?? 0)
            if enqueuedFrames > 0 {
                let batches = Int(snapshot?.onDeviceDepthBatchesSubmitted ?? 0)
                let ready = Int(snapshot?.onDeviceDepthResultsReady ?? 0)
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
            minimumSelectedFrames: Int,
            submittedFrames: Int
        ) -> String {
            let selectedFrames = Int(snapshot?.selected_frames ?? 0)
            let acceptedSeeds = Int(snapshot?.onDeviceSeedAccepted ?? 0)
            let candidateSeeds = Int(snapshot?.onDeviceSeedCandidates ?? 0)
            let processedFrames = Int(snapshot?.onDeviceFramesIngested ?? 0)
            let replayOngoing =
                submittedFrames > 0 &&
                processedFrames > 0 &&
                processedFrames < submittedFrames
            if minimumSelectedFrames > 0 {
                if selectedFrames < minimumSelectedFrames {
                    if replayOngoing {
                        return "补几何证据 \(processedFrames) / \(submittedFrames) · 关键帧 \(selectedFrames) / \(minimumSelectedFrames)"
                    }
                    return "关键帧 \(selectedFrames) / \(minimumSelectedFrames)"
                }
                if acceptedSeeds > 0 {
                    if replayOngoing {
                        return "补几何证据 \(processedFrames) / \(submittedFrames) · seed \(acceptedSeeds)"
                    }
                    return "seed \(acceptedSeeds) · 帧 \(selectedFrames)"
                }
                if replayOngoing {
                    return "补几何证据 \(processedFrames) / \(submittedFrames) · 关键帧 \(selectedFrames)"
                }
                return "关键帧 \(selectedFrames) · 已达标"
            }
            if acceptedSeeds > 0 || candidateSeeds > 0 {
                if replayOngoing {
                    return "补几何证据 \(processedFrames) / \(submittedFrames) · seed \(acceptedSeeds)"
                }
                return "seed \(acceptedSeeds) · 候选 \(candidateSeeds)"
            }
            return "等待开始"
        }

        func refineMetricText(snapshot: aether_evidence_snapshot_t?) -> String {
            let trainingStarted = foregroundBridge?.isTraining == true
            let hasTrainingEngineEvidence =
                trainingStarted ||
                Int(snapshot?.num_gaussians ?? 0) > 0 ||
                Int(snapshot?.retained_export_gaussians ?? 0) > 0 ||
                lastObservedGaussianCount > 0
            let trainingStep = trainingStarted ? Int(snapshot?.training_step ?? 0) : 0
            let gaussianCount = max(
                Int(snapshot?.num_gaussians ?? 0),
                lastObservedGaussianCount
            )
            if trainingStep > 0 {
                if gaussianCount > 0 {
                    return "\(trainingStep) 步 · \(gaussianCount) 个高斯"
                }
                return "\(trainingStep) 步"
            }
            if hasTrainingEngineEvidence {
                return "等待第 1 步"
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
                metrics["native_live_submitted_frames"] = String(liveSubmittedFrames)
                metrics["native_import_submitted_frames"] = String(liveSubmittedFrames)
            }
            if let liveMinimumSelectedFrames {
                metrics["native_live_min_selected_frames"] = String(liveMinimumSelectedFrames)
            }
            if let liveTargetFrames {
                metrics["native_live_target_frames"] = String(liveTargetFrames)
            }
            let minimumSelected = liveMinimumSelectedFrames
                ?? max(Int(snapshot?.min_frames_needed ?? 0), minimumSelectedFramesToStartTraining)
            switch phase {
            case .depth:
                metrics["native_depth_phase_metric_text"] = depthMetricText(
                    snapshot: snapshot,
                    submittedFrames: liveSubmittedFrames ?? 0
                )
            case .seed:
                metrics["native_seed_phase_metric_text"] = seedMetricText(
                    snapshot: snapshot,
                    minimumSelectedFrames: minimumSelected,
                    submittedFrames: liveSubmittedFrames ?? 0
                )
            case .refine:
                metrics["native_refine_phase_metric_text"] = refineMetricText(snapshot: snapshot)
            case .cutout:
                metrics["native_cutout_phase_metric_text"] = metrics["native_cutout_phase_metric_text"] ?? "处理中"
            case .cleanup:
                metrics["native_cleanup_phase_metric_text"] = metrics["native_cleanup_phase_metric_text"] ?? "处理中"
            case .export:
                metrics["native_export_phase_metric_text"] = exported == true ? "已完成" : "导出中"
            }
            metrics = LocalPreviewProductProfile.canonicalRuntimeMetrics(metrics)
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
                    processingBackend: processingBackend,
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
                    return processingBackend == .localSubjectFirst
                        ? LocalPreviewWorkflowPhase.cutout.startFraction
                        : LocalPreviewWorkflowPhase.export.startFraction
                case .cutout:
                    return LocalPreviewWorkflowPhase.cleanup.startFraction
                case .cleanup:
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
                    let ingestedFrames = Int(snapshot.onDeviceFramesIngested)
                    let processedRatio = submittedFrames > 0
                        ? min(1.0, Double(ingestedFrames) / Double(max(submittedFrames, 1)))
                        : 0.0
                    let depthRatio = min(
                        1.0,
                        Double(snapshot.onDeviceDepthResultsReady) /
                            Double(max(budget.minDepthResultsBeforeFinalize, 1))
                    )
                    return max(
                        submittedRatio * 0.25 +
                        processedRatio * 0.45 +
                        depthRatio * 0.30,
                        0.02
                    )
                case .seed:
                    let requiredSelectedFrames = max(
                        minSelectedFrames,
                        minimumSelectedFramesToStartTraining
                    )
                    let selectedTarget = max(
                        max(minSelectedFrames, 1),
                        max(budget.targetSelectedFrames, 1) * 2
                    )
                    let selectedRatio = min(
                        1.0,
                        Double(snapshot.selected_frames) / Double(selectedTarget)
                    )
                    let candidateRatio = min(
                        1.0,
                        Double(snapshot.onDeviceSeedCandidates) / 256.0
                    )
                    let pendingGaussianRatio = min(
                        1.0,
                        Double(snapshot.pending_gaussian_count) / 12000.0
                    )
                    let acceptedSeedRatio = min(
                        1.0,
                        Double(snapshot.onDeviceSeedAccepted) / 512.0
                    )
                    let replayRatio = submittedFrames > 0
                        ? min(
                            1.0,
                            Double(snapshot.onDeviceFramesIngested) /
                                Double(max(submittedFrames, 1))
                        )
                        : 0.0
                    let replayBridgeRatio: Double = {
                        guard Int(snapshot.selected_frames) >= requiredSelectedFrames else {
                            return 0.0
                        }
                        guard snapshot.onDeviceSeedCandidates == 0,
                              snapshot.onDeviceSeedAccepted == 0,
                              snapshot.pending_gaussian_count == 0 else {
                            return 0.0
                        }
                        return replayRatio
                    }()
                    let seedBootstrapRatio = max(
                        acceptedSeedRatio,
                        max(candidateRatio * 0.65, max(pendingGaussianRatio, replayBridgeRatio))
                    )
                    return max(selectedRatio * 0.30 + seedBootstrapRatio * 0.70, 0.02)
                case .refine:
                    let trainingStarted = foregroundBridge?.isTraining == true
                    guard trainingStarted else {
                        return 0.02
                    }
                    let progress = foregroundBridge?.trainingProgress()
                    let totalSteps = Double(progress?.total_steps ?? 0)
                    let step = Double(progress?.step ?? 0)
                    guard totalSteps > 0, step > 0 else {
                        return 0.02
                    }
                    return max(min(1.0, step / totalSteps), 0.02)
                case .cutout:
                    return 0.42
                case .cleanup:
                    return 0.58
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
                    Int(snapshot.onDeviceFramesEnqueued)
                )
                let processedFrames = Int(snapshot.onDeviceFramesIngested)
                let nativeBacklog = Int(snapshot.onDeviceFrameBacklog)
                let depthReady = Int(snapshot.onDeviceDepthResultsReady)
                let depthSubmitted = Int(snapshot.onDeviceDepthBatchesSubmitted)
                if depthSubmitted > 0 {
                    return "已送入队列 \(enqueuedFrames)/\(max(targetSubmittedFrames, 1)) 帧，native 已接收 \(processedFrames) 帧，排队中 \(nativeBacklog) 帧，depth 已回流 \(depthReady)/\(max(depthSubmitted, 1)) 批，正在建立可用于本地结果的几何先验。"
                }
                return "已送入队列 \(enqueuedFrames)/\(max(targetSubmittedFrames, 1)) 帧，native 已接收 \(processedFrames) 帧，排队中 \(nativeBacklog) 帧，正在建立可用于本地结果的几何先验。"
            case .seed:
                let selectedFrames = Int(snapshot.selected_frames)
                let seedCandidates = Int(snapshot.onDeviceSeedCandidates)
                let acceptedSeeds = Int(snapshot.onDeviceSeedAccepted)
                let pendingGaussians = Int(snapshot.pending_gaussian_count)
                let processedFrames = Int(snapshot.onDeviceFramesIngested)
                let requiredSelectedFrames = max(
                    minSelectedFrames,
                    minimumSelectedFramesToStartTraining
                )
                let replaySuffix: String = {
                    guard submittedFrames > 0 else { return "" }
                    let processedClamped = min(processedFrames, submittedFrames)
                    guard processedClamped > 0 && processedClamped < submittedFrames else { return "" }
                    return "当前已回放 \(processedClamped)/\(submittedFrames) 帧。"
                }()
                let replayDetail = replaySuffix.isEmpty ? "" : "\n\(replaySuffix)"
                if selectedFrames == 0 &&
                    seedCandidates == 0 &&
                    acceptedSeeds == 0 &&
                    pendingGaussians == 0 {
                    return "深度先验已经回流，正在重放录制视频并补关键帧。当前有效关键帧 \(selectedFrames)/\(max(requiredSelectedFrames, 1))，达到后才开始初始化高斯种子。\(replayDetail)"
                }
                if selectedFrames < requiredSelectedFrames {
                    if acceptedSeeds == 0 && pendingGaussians == 0 {
                        return "正在重放录制视频并补关键帧；当前有效关键帧 \(selectedFrames)/\(max(requiredSelectedFrames, 1))，候选 seed \(seedCandidates) 个，尚未满足本地初始化门槛。\(replayDetail)"
                    }
                    return "正在重放录制视频并补关键帧；当前有效关键帧 \(selectedFrames)/\(max(requiredSelectedFrames, 1))，候选 seed \(seedCandidates) 个，已接受 \(acceptedSeeds) 个。\(replayDetail)"
                }
                if acceptedSeeds == 0 && pendingGaussians == 0 {
                    if !replaySuffix.isEmpty {
                        return "关键帧门槛已满足，正在继续重放录制视频并汇总 MVS 几何；候选 seed \(seedCandidates) 个，正在确认第一批稳定 seed。\(replayDetail)"
                    }
                    return "关键帧门槛已满足，候选 seed \(seedCandidates) 个，正在确认第一批稳定 seed。"
                }
                if !replaySuffix.isEmpty {
                    return "关键帧门槛已满足，候选 seed \(snapshot.onDeviceSeedCandidates) 个，已接受 \(snapshot.onDeviceSeedAccepted) 个；native 仍在继续回放录制视频补几何证据。\(replayDetail)"
                }
                return "关键帧门槛已满足，候选 seed \(snapshot.onDeviceSeedCandidates) 个，已接受 \(snapshot.onDeviceSeedAccepted) 个。"
            case .refine:
                let trainingStarted = foregroundBridge?.isTraining == true
                let gaussianCount = max(
                    Int(snapshot.num_gaussians),
                    lastObservedGaussianCount
                )
                if trainingStarted {
                    let realStep = Int(snapshot.training_step)
                    if realStep > 0 {
                        return "本地 refine 已跑到 \(realStep) 步，当前高斯 \(gaussianCount) 个，继续收口本地结果几何。"
                    }
                    return "本地 refine 已启动，当前高斯 \(gaussianCount) 个，正在等待第一批真实训练步数。"
                }
                return "正在准备本地 refine，当前高斯 \(gaussianCount) 个。"
            case .cutout:
                return "正在做 mask / boundary cutout，先把边界薄带和接触面保住。"
            case .cleanup:
                return "正在保守清理低覆盖碎边和浮空小块，同时尽量保住主体核心。"
            case .export:
                return "训练结果正在写出为本地 Gaussian 结果文件。"
            }
        }

        func resolvePreRefinePhase(
            snapshot: aether_evidence_snapshot_t,
            submittedFrames: Int,
            minSelectedFrames: Int
        ) -> LocalPreviewWorkflowPhase {
            let processedFrames = Int(snapshot.onDeviceFramesIngested)
            let processedFloor = min(
                max(submittedFrames, 1),
                max(budget.minimumProcessedFramesBeforeFinalize, 1)
            )
            let depthReady = Int(snapshot.onDeviceDepthResultsReady)
            let selectedFrames = Int(snapshot.selected_frames)
            let acceptedSeeds = Int(snapshot.onDeviceSeedAccepted)
            let pendingGaussians = Int(snapshot.pending_gaussian_count)
            let seedCandidates = Int(snapshot.onDeviceSeedCandidates)
            let requiredSelectedFrames = max(
                minSelectedFrames,
                minimumSelectedFramesToStartTraining
            )
            if selectedFrames >= requiredSelectedFrames ||
                acceptedSeeds > 0 ||
                pendingGaussians > 0 ||
                seedCandidates > 0 {
                return .seed
            }
            if depthReady >= max(budget.minDepthResultsBeforeFinalize, 1) &&
                processedFrames >= processedFloor {
                return .seed
            }
            return .depth
        }

        func hasRefinePhaseEvidence(_ snapshot: aether_evidence_snapshot_t?) -> Bool {
            guard let snapshot else { return false }
            return Int(snapshot.onDeviceRefinePhaseMs) > 0 ||
                foregroundBridge?.isTraining == true ||
                Int(snapshot.num_gaussians) > 0
        }

        func resolvedLivePhase(
            requestedPhase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minSelectedFrames: Int
        ) -> LocalPreviewWorkflowPhase {
            guard let snapshot else { return requestedPhase }
            switch requestedPhase {
            case .depth, .seed:
                if hasRefinePhaseEvidence(snapshot) {
                    return .refine
                }
                return resolvePreRefinePhase(
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minSelectedFrames
                )
            case .refine:
                if hasRefinePhaseEvidence(snapshot) {
                    return .refine
                }
                return resolvePreRefinePhase(
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minSelectedFrames
                )
            case .cutout, .cleanup, .export:
                return requestedPhase
            }
        }

        func importedVideoSuitabilityDiagnosis(
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minimumSelectedFrames: Int
        ) -> (reason: String, detail: String, terminalPhase: LocalPreviewWorkflowPhase)? {
            guard processingBackend == .localSubjectFirst,
                  let snapshot else {
                return nil
            }

            let evaluatedFrames = Int(snapshot.onDeviceImportedFramesEvaluated)
            let ingestedFrames = Int(snapshot.onDeviceFramesIngested)
            let selectedFrames = Int(snapshot.selected_frames)
            let lowParallaxRejects = Int(snapshot.onDeviceImportedLowParallaxRejects)
            let nearDuplicateRejects = Int(snapshot.onDeviceImportedNearDuplicateRejects)
            let meanTranslationMm = Double(snapshot.onDeviceImportedSelectedTranslationMeanMm)
            let meanRotationDeg = Double(snapshot.onDeviceImportedSelectedRotationMeanDeg)
            let meanOverlap = Double(snapshot.onDeviceImportedSelectedOverlapMean)

            let enoughEvidenceFrames = max(16, min(targetSubmittedFrames, 24))
            guard max(evaluatedFrames, ingestedFrames, submittedFrames) >= enoughEvidenceFrames else {
                return nil
            }

            let evaluatedDenominator = Double(max(evaluatedFrames, 1))
            let lowParallaxRatio = Double(lowParallaxRejects) / evaluatedDenominator
            let nearDuplicateRatio = Double(nearDuplicateRejects) / evaluatedDenominator
            let weakSelectedMotion =
                selectedFrames > 0 &&
                meanTranslationMm > 0 &&
                meanTranslationMm < 12.0 &&
                meanRotationDeg > 0 &&
                meanRotationDeg < 2.5
            let highOverlapSelection =
                selectedFrames > 0 &&
                meanOverlap >= 0.91
            let selectedTooFew = selectedFrames < max(minimumSelectedFrames, 6)

            let shouldFailForLowParallax =
                lowParallaxRatio >= 0.60 &&
                (selectedTooFew || highOverlapSelection)
            let shouldFailForNearDuplicate =
                nearDuplicateRatio >= 0.35 &&
                (selectedTooFew || highOverlapSelection)
            let shouldFailForWeakSelectedMotion =
                weakSelectedMotion && highOverlapSelection

            guard shouldFailForLowParallax ||
                    shouldFailForNearDuplicate ||
                    shouldFailForWeakSelectedMotion else {
                return nil
            }

            let reason: String
            if shouldFailForNearDuplicate {
                reason = "local_subject_first_duplicate_views"
            } else {
                reason = "local_subject_first_insufficient_parallax"
            }

            let detail = String(
                format: """
这段视频不适合当前本地方案。当前已重放评估 %d 个采样帧、真正选中 %d 个关键帧；平均位移 %.1fmm、平均转角 %.2f°、平均视角重叠 %.3f，视差不足占比 %.0f%%、近重复视角占比 %.0f%%。

建议改成围绕主体重拍，至少补到正面、左前、右前、侧面、顶部和底部接触区；如果暂时不方便重拍，建议直接切到远端方案。
""",
                max(evaluatedFrames, ingestedFrames, submittedFrames),
                selectedFrames,
                meanTranslationMm,
                meanRotationDeg,
                meanOverlap,
                lowParallaxRatio * 100.0,
                nearDuplicateRatio * 100.0
            )
            let terminalPhase: LocalPreviewWorkflowPhase =
                selectedFrames > 0 ? .seed : .depth
            return (reason, detail, terminalPhase)
        }

        func appendImportedVideoSuitabilityFailure(
            to baseMetrics: [String: String],
            diagnosis: (reason: String, detail: String, terminalPhase: LocalPreviewWorkflowPhase),
            snapshot: aether_evidence_snapshot_t?
        ) -> [String: String] {
            var metrics = baseMetrics
            metrics["native_failure_reason"] = diagnosis.reason
            metrics["native_import_suitability_verdict"] = "remote_recommended"
            metrics["native_import_suitability_terminal_phase"] = diagnosis.terminalPhase.phaseName
            if let snapshot {
                let evaluatedFrames = max(Int(snapshot.onDeviceImportedFramesEvaluated), 1)
                let lowParallaxRejects = Int(snapshot.onDeviceImportedLowParallaxRejects)
                let nearDuplicateRejects = Int(snapshot.onDeviceImportedNearDuplicateRejects)
                let lowParallaxRatio = Double(lowParallaxRejects) / Double(evaluatedFrames)
                let nearDuplicateRatio = Double(nearDuplicateRejects) / Double(evaluatedFrames)
                metrics["native_import_low_parallax_ratio"] = String(format: "%.3f", lowParallaxRatio)
                metrics["native_import_near_duplicate_ratio"] = String(format: "%.3f", nearDuplicateRatio)
                metrics["native_import_selected_translation_mean_mm"] =
                    String(format: "%.1f", Double(snapshot.onDeviceImportedSelectedTranslationMeanMm))
                metrics["native_import_selected_rotation_mean_deg"] =
                    String(format: "%.2f", Double(snapshot.onDeviceImportedSelectedRotationMeanDeg))
                metrics["native_import_selected_overlap_mean"] =
                    String(format: "%.3f", Double(snapshot.onDeviceImportedSelectedOverlapMean))
            }
            return metrics
        }

        func emitLivePhase(
            _ phase: LocalPreviewWorkflowPhase,
            snapshot: aether_evidence_snapshot_t?,
            submittedFrames: Int,
            minSelectedFrames: Int,
            force: Bool = false
        ) {
            let effectivePhase = resolvedLivePhase(
                requestedPhase: phase,
                snapshot: snapshot,
                submittedFrames: submittedFrames,
                minSelectedFrames: minSelectedFrames
            )
            let now = CFAbsoluteTimeGetCurrent()
            let processedFrames = Int(snapshot?.onDeviceFramesIngested ?? 0)
            let depthReady = Int(snapshot?.onDeviceDepthResultsReady ?? 0)
            let selectedFrames = Int(snapshot?.selected_frames ?? 0)
            let trainingStarted = foregroundBridge?.isTraining == true
            let realTrainingStep: Int = {
                guard trainingStarted, let progress = foregroundBridge?.trainingProgress() else {
                    return 0
                }
                return Int(progress.step)
            }()
            let phaseChanged = lastEmittedPhase != effectivePhase
            let shouldEmit =
                force ||
                phaseChanged ||
                submittedFrames != lastEmittedSubmittedFrames ||
                processedFrames != lastEmittedProcessedFrames ||
                depthReady != lastEmittedDepthReady ||
                selectedFrames != lastEmittedSelectedFrames ||
                trainingStarted != lastEmittedTrainingStarted ||
                realTrainingStep != lastEmittedRealTrainingStep ||
                now - lastLivePhaseEmissionAt >= livePhaseEmitIntervalSeconds
            guard shouldEmit else { return }

            if phaseChanged {
                let previousPhaseName = lastEmittedPhase?.phaseName ?? "none"
                NSLog(
                    "[Aether3D][PhaseTransition] imported_video %@ -> %@ submitted=%d ingested=%d selected=%d training_started=%@ real_step=%d",
                    previousPhaseName,
                    effectivePhase.phaseName,
                    submittedFrames,
                    processedFrames,
                    selectedFrames,
                    trainingStarted ? "YES" : "NO",
                    realTrainingStep
                )
            }

            lastLivePhaseEmissionAt = now
            lastEmittedPhase = effectivePhase
            lastEmittedSubmittedFrames = submittedFrames
            lastEmittedProcessedFrames = processedFrames
            lastEmittedDepthReady = depthReady
            lastEmittedSelectedFrames = selectedFrames
            lastEmittedTrainingStarted = trainingStarted
            lastEmittedRealTrainingStep = realTrainingStep

            emitPhase(
                effectivePhase,
                snapshot: snapshot,
                detailOverride: phaseDetail(
                    effectivePhase,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minSelectedFrames
                ),
                progressFraction: boundedPhaseProgress(
                    effectivePhase,
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
            let effectivePhase = resolvedLivePhase(
                requestedPhase: phase,
                snapshot: snapshot,
                submittedFrames: submittedFrames,
                minSelectedFrames: minimumSelectedFrames
            )
            let now = CFAbsoluteTimeGetCurrent()
            let isForegroundActive = Self.isApplicationForegroundActive()
            foregroundBridge?.setForegroundActive(isForegroundActive)
            if isForegroundActive &&
                now - lastForegroundValidationAt < foregroundRecheckIntervalSeconds {
                return true
            }
            guard isForegroundActive else {
                emitPhase(
                    effectivePhase,
                    snapshot: snapshot,
                    detailOverride: foregroundRequiredDetail,
                    progressFraction: boundedPhaseProgress(
                        effectivePhase,
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
                        effectivePhase,
                        snapshot: snapshot,
                        detailOverride: foregroundRequiredDetail,
                        progressFraction: boundedPhaseProgress(
                            effectivePhase,
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
            metrics["native_active_phase"] = terminalPhase.phaseName
            if let liveSubmittedFrames {
                metrics["native_live_submitted_frames"] = String(liveSubmittedFrames)
                metrics["native_import_submitted_frames"] = String(liveSubmittedFrames)
            }
            if let liveMinimumSelectedFrames {
                metrics["native_live_min_selected_frames"] = String(liveMinimumSelectedFrames)
            }
            if let liveTargetFrames {
                metrics["native_live_target_frames"] = String(max(liveTargetFrames, 1))
            }
            let minimumSelected = liveMinimumSelectedFrames ?? minimumSelectedFramesToStartTraining
            switch terminalPhase {
            case .depth:
                metrics["native_depth_phase_metric_text"] = depthMetricText(
                    snapshot: snapshot,
                    submittedFrames: liveSubmittedFrames ?? 0
                )
            case .seed:
                metrics["native_seed_phase_metric_text"] = seedMetricText(
                    snapshot: snapshot,
                    minimumSelectedFrames: minimumSelected,
                    submittedFrames: liveSubmittedFrames ?? 0
                )
            case .refine:
                metrics["native_refine_phase_metric_text"] = refineMetricText(snapshot: snapshot)
            case .cutout:
                metrics["native_cutout_phase_metric_text"] = "mask / boundary"
            case .cleanup:
                metrics["native_cleanup_phase_metric_text"] = "边界 cleanup"
            case .export:
                metrics["native_export_phase_metric_text"] = exported ? "已完成" : "导出失败"
            }
            appendTrace(
                exported ? "terminal_success" : "terminal_failure",
                phase: terminalPhase,
                snapshot: snapshot,
                submittedFrames: liveSubmittedFrames ?? 0,
                detail: detailMessage
            )
            if !traceLines.isEmpty {
                metrics["native_trace_last_event"] = traceLines.last
                metrics["native_trace_log"] = traceLines.joined(separator: "\n")
            }
            metrics = LocalPreviewProductProfile.canonicalRuntimeMetrics(metrics)
            return LocalPreviewImportResult(
                exported: exported,
                runtimeMetrics: metrics,
                detailMessage: detailMessage,
                terminalPhase: terminalPhase,
                terminalProgressFraction: terminalProgressFraction
            )
        }

        func hasAnyNativeBootstrapSignal(_ snapshot: aether_evidence_snapshot_t?) -> Bool {
            guard let snapshot else { return false }
            return Int(snapshot.onDeviceDepthResultsReady) > 0 ||
                Int(snapshot.selected_frames) > 0 ||
                Int(snapshot.pending_gaussian_count) > 0 ||
                Int(snapshot.onDeviceSeedCandidates) > 0 ||
                Int(snapshot.onDeviceSeedAccepted) > 0 ||
                foregroundBridge?.isTraining == true
        }

        func hasDepthPhaseEvidence(
            _ snapshot: aether_evidence_snapshot_t?,
            minimumSelectedFrames: Int
        ) -> Bool {
            guard let snapshot else { return false }
            let processedFrames = Int(snapshot.onDeviceFramesIngested)
            let depthReady = Int(snapshot.onDeviceDepthResultsReady)
            let processedFloor = max(
                1,
                min(targetSubmittedFrames, max(budget.minimumProcessedFramesBeforeFinalize, 1))
            )
            return depthReady >= max(budget.minDepthResultsBeforeFinalize, 1) &&
                processedFrames >= processedFloor
        }

        func hasSeedPhaseEvidence(
            _ snapshot: aether_evidence_snapshot_t?,
            minimumSelectedFrames: Int
        ) -> Bool {
            guard let snapshot else { return false }
            let selectedFrames = Int(snapshot.selected_frames)
            let acceptedSeeds = Int(snapshot.onDeviceSeedAccepted)
            let pendingGaussians = Int(snapshot.pending_gaussian_count)
            return selectedFrames >= minimumSelectedFrames ||
                acceptedSeeds > 0 ||
                pendingGaussians > 0 ||
                foregroundBridge?.isTraining == true
        }

        func createCoordinatorHandles(
            processingBackend: ProcessingBackendChoice
        ) -> CoordinatorHandles? {
            #if canImport(CAetherNativeBridge) && canImport(Metal)
            guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
                return nil
            }
            let mtlDevicePtr = Unmanaged.passUnretained(mtlDevice).toOpaque()
            guard let gpuDevice = aether_gpu_device_create_metal(mtlDevicePtr) else {
                return nil
            }

            var splatConfig = aether_splat_config_t()
            _ = aether_splat_default_config(&splatConfig)

            var splatEnginePtr: OpaquePointer?
            let rc = aether_splat_engine_create(
                UnsafeMutableRawPointer(gpuDevice),
                &splatConfig,
                &splatEnginePtr
            )
            guard rc == 0, let engine = splatEnginePtr else {
                aether_gpu_device_destroy(gpuDevice)
                return nil
            }

            let profile: PipelineCoordinatorProfile = processingBackend.usesLocalPreviewPipeline
                ? .localSubjectFirstMonocular
                : .cloudDefault
            let bridge = PipelineCoordinatorBridge(
                gpuDevicePtr: UnsafeMutableRawPointer(gpuDevice),
                splatEnginePtr: UnsafeMutableRawPointer(engine),
                profile: profile
            )
            return CoordinatorHandles(gpuDevice: gpuDevice, splatEngine: engine, bridge: bridge)
            #else
            _ = processingBackend
            return nil
            #endif
        }

        func destroyCoordinatorHandles(_ handles: CoordinatorHandles) {
            #if canImport(CAetherNativeBridge) && canImport(Metal)
            let teardown = CoordinatorTeardownBox(handles.bridge)
            let engine = SendableHandle(pointer: handles.splatEngine)
            let device = SendableHandle(pointer: handles.gpuDevice)
            DispatchQueue.global(qos: .userInitiated).async {
                teardown.bridge = nil
                aether_splat_engine_destroy(engine.pointer)
                aether_gpu_device_destroy(device.pointer)
            }
            #else
            _ = handles
            #endif
        }

        guard let handles = createCoordinatorHandles(processingBackend: processingBackend),
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
                detailMessage: "手机本地处理引擎没有初始化成功，这次还没法开始本地结果生成。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }
        defer { destroyCoordinatorHandles(handles) }
        foregroundBridge = bridge

        func realTrainingStarted() -> Bool {
            bridge.isTraining
        }

        func realTrainingStep(_ snapshot: aether_evidence_snapshot_t?) -> Int {
            guard realTrainingStarted() else { return 0 }
            return Int(snapshot?.training_step ?? 0)
        }

        struct NativeActivityFingerprint: Equatable {
            let trainingStarted: Bool
            let selectedFrames: Int
            let acceptedSeeds: Int
            let pendingGaussians: Int
            let assignedBlocks: Int
            let snapshotGaussians: Int
            let snapshotTrainingStep: Int
            let progressStep: Int
            let progressTotalSteps: Int
            let progressGaussians: Int
        }

        let nativeActivityStallSeconds = 20.0
        let firstTrainingStepStallSeconds = 10.0
        var latestNativeActivityFingerprint: NativeActivityFingerprint?
        var lastNativeActivityAt = CFAbsoluteTimeGetCurrent()
        var latestNativeActivityAgeSeconds = 0.0
        var firstTrainingStepWaitStartedAt: CFAbsoluteTime?

        func hasTrainingEngineEvidence(
            snapshot: aether_evidence_snapshot_t?,
            progress: aether_coordinator_training_progress_t? = nil
        ) -> Bool {
            if bridge.isTraining {
                return true
            }
            if Int(snapshot?.training_step ?? 0) > 0 ||
                Int(snapshot?.num_gaussians ?? 0) > 0 ||
                Int(snapshot?.retained_export_gaussians ?? 0) > 0 {
                return true
            }
            if let progress {
                return Int(progress.step) > 0 || Int(progress.num_gaussians) > 0
            }
            return false
        }

        func refreshNativeActivityAge(snapshot: aether_evidence_snapshot_t?) -> Double {
            let trainingStarted = realTrainingStarted()
            let progress = trainingStarted ? bridge.trainingProgress() : nil
            let fingerprint = NativeActivityFingerprint(
                trainingStarted: trainingStarted,
                selectedFrames: Int(snapshot?.selected_frames ?? 0),
                acceptedSeeds: Int(snapshot?.onDeviceSeedAccepted ?? 0),
                pendingGaussians: Int(snapshot?.pending_gaussian_count ?? 0),
                assignedBlocks: Int(snapshot?.assigned_blocks ?? 0),
                snapshotGaussians: Int(snapshot?.num_gaussians ?? 0),
                snapshotTrainingStep: Int(snapshot?.training_step ?? 0),
                progressStep: Int(progress?.step ?? 0),
                progressTotalSteps: Int(progress?.total_steps ?? 0),
                progressGaussians: Int(progress?.num_gaussians ?? 0)
            )
            let now = CFAbsoluteTimeGetCurrent()
            if fingerprint != latestNativeActivityFingerprint {
                latestNativeActivityFingerprint = fingerprint
                lastNativeActivityAt = now
                latestNativeActivityAgeSeconds = 0.0
                return 0.0
            }
            latestNativeActivityAgeSeconds = max(0.0, now - lastNativeActivityAt)
            return latestNativeActivityAgeSeconds
        }

        func shouldAbortForFirstTrainingStepStall(
            snapshot: aether_evidence_snapshot_t?,
            phase: LocalPreviewWorkflowPhase
        ) -> Bool {
            let progress = bridge.trainingProgress()
            guard hasTrainingEngineEvidence(snapshot: snapshot, progress: progress) else {
                firstTrainingStepWaitStartedAt = nil
                return false
            }
            let currentRealStep = Int(progress?.step ?? 0)
            if currentRealStep > 0 {
                firstTrainingStepWaitStartedAt = nil
                return false
            }
            let now = CFAbsoluteTimeGetCurrent()
            if firstTrainingStepWaitStartedAt == nil {
                firstTrainingStepWaitStartedAt = now
                NSLog(
                    "[Aether3D][TrainStartupWatchdog] imported_video detected training-engine-ready evidence phase=%@ total_steps=%d gaussians=%d -> waiting for first real train step",
                    phase.phaseName,
                    Int(progress?.total_steps ?? 0),
                    max(
                        Int(snapshot?.num_gaussians ?? 0),
                        max(
                            Int(snapshot?.retained_export_gaussians ?? 0),
                            Int(progress?.num_gaussians ?? 0)
                        )
                    )
                )
                return false
            }
            let waitedSeconds = max(0.0, now - (firstTrainingStepWaitStartedAt ?? now))
            guard Self.isApplicationForegroundActive(),
                  waitedSeconds >= firstTrainingStepStallSeconds else {
                return false
            }
            NSLog(
                "[Aether3D][TrainStartupWatchdog] imported_video first real train step did not start within %.1fs after engine creation phase=%@ total_steps=%d gaussians=%d -> exporting current snapshot",
                waitedSeconds,
                phase.phaseName,
                Int(progress?.total_steps ?? 0),
                max(
                    Int(snapshot?.num_gaussians ?? 0),
                    max(
                        Int(snapshot?.retained_export_gaussians ?? 0),
                        Int(progress?.num_gaussians ?? 0)
                    )
                )
            )
            return true
        }

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
                bootstrapDepthReady = bridge.serviceLocalSubjectFirstBootstrap() || bootstrapDepthReady
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    _ = refreshNativeActivityAge(snapshot: snapshot)
                    let processedFrames = Int(snapshot.onDeviceFramesIngested)
                    let inFlightFrames = max(0, submittedFrames - processedFrames)
                    let selectedFrames = Int(snapshot.selected_frames)
                    let requiredSelectedFrames = max(
                        minimumSelectedFrames,
                        minimumSelectedFramesToStartTraining
                    )
                    let trainingStarted = realTrainingStarted()
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
                        case .refine, .cutout, .cleanup, .export:
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
                        case .refine, .cutout, .cleanup, .export:
                            return inFlightFrames <= budget.maxFramesAheadBeforeFinalize &&
                                processedFrames >= processedFloor
                        }
                    }()
                    let selectionReady = phaseDuringWait == .seed
                        ? trainingStarted ||
                            requiredSelectedFrames <= 0 ||
                            selectedFrames >= requiredSelectedFrames
                        : true
                    emitLivePhase(
                        phaseDuringWait,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(minimumSelectedFrames, minimumSelectedFramesToStartTraining),
                        force: selectedFrames > 0 || processedFrames > 0 || bootstrapReady
                    )
                    if phaseDuringWait == .seed && trainingStarted {
                        if let refreshedSnapshot = bridge.getSnapshot() {
                            latestSnapshot = refreshedSnapshot
                        }
                        emitLivePhase(
                            .refine,
                            snapshot: latestSnapshot,
                            submittedFrames: submittedFrames,
                            minSelectedFrames: max(minimumSelectedFrames, minimumSelectedFramesToStartTraining),
                            force: true
                        )
                        break
                    }
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

        func promoteToRefineIfNeeded(
            submittedFrames: Int,
            minimumSelectedFrames: Int
        ) {
            let requiredSelectedFrames = max(
                minimumSelectedFrames,
                minimumSelectedFramesToStartTraining
            )
            let settleDeadline = CFAbsoluteTimeGetCurrent() + 0.8
            var observedSnapshot = bridge.getSnapshot() ?? latestSnapshot

            while CFAbsoluteTimeGetCurrent() < settleDeadline {
                if let refreshedSnapshot = bridge.getSnapshot() {
                    observedSnapshot = refreshedSnapshot
                }
                if realTrainingStarted() || hasRefinePhaseEvidence(observedSnapshot) {
                    latestSnapshot = observedSnapshot
                    emitLivePhase(
                        .refine,
                        snapshot: observedSnapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: requiredSelectedFrames,
                        force: true
                    )
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
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

                _ = bridge.serviceLocalSubjectFirstBootstrap()
                if let snapshot = bridge.getSnapshot() {
                    latestSnapshot = snapshot
                    let processedFrames = Int(snapshot.onDeviceFramesIngested)
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
            metrics["native_import_error"] = "foreground_required_for_gpu_depth"
            metrics["native_import_foreground_wait_expired"] = "1"
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
            var staleArtifacts: [URL] = [artifactURL]
            if processingBackend == .localSubjectFirst {
                staleArtifacts.append(Self.subjectRawArtifactPath(for: artifactURL))
                staleArtifacts.append(Self.subjectCutoutArtifactPath(for: artifactURL))
                staleArtifacts.append(Self.subjectCleanupArtifactPath(for: artifactURL))
            }
            for staleURL in staleArtifacts where FileManager.default.fileExists(atPath: staleURL.path) {
                try FileManager.default.removeItem(at: staleURL)
            }
        } catch {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["native_import_error"] = "artifact_directory_prepare_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "本地导出目录准备失败了，这次没有拿到可写的本地结果输出位置。",
                terminalPhase: .export,
                terminalProgressFraction: LocalPreviewWorkflowPhase.export.startFraction
            )
        }

        let asset = AVURLAsset(url: sourceVideoURL)
        let videoTracks: [AVAssetTrack]
        if #available(iOS 15.0, *) {
            videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        } else {
            videoTracks = []
        }
        guard let videoTrack = videoTracks.first else {
            var metrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: nil,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: thermalAtFinish
            )
            metrics["native_import_error"] = "video_track_missing"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "这个相册视频没有可用的视频轨道，本地 native 视频链这次无法启动。",
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
            metrics["native_import_error"] = "asset_reader_create_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "本地没法读取这个视频的帧数据，这次无法继续做本地结果生成。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
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
            metrics["native_import_error"] = "asset_reader_output_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "视频读取输出没有准备成功，这次本地 native 视频链无法继续。",
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
            metrics["native_import_error"] = "asset_reader_start_failed"
            return buildResult(
                snapshot: nil,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: "视频帧读取启动失败了，这次本地 native 视频链还没法开始。",
                terminalPhase: .depth,
                terminalProgressFraction: LocalPreviewWorkflowPhase.depth.startFraction
            )
        }

        let trackSize: CGSize
        if #available(iOS 15.0, *) {
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            trackSize = naturalSize.applying(preferredTransform)
        } else {
            trackSize = .zero
        }
        let width = max(1, Int(abs(trackSize.width.rounded())))
        let height = max(1, Int(abs(trackSize.height.rounded())))
        let durationSeconds = max(0.1, await Self.loadedDurationSeconds(for: asset))
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
        let metadataIntrinsicsEstimate = await importedVideoMetadataIntrinsicsEstimate(
            asset: asset,
            videoTrack: videoTrack,
            width: width,
            height: height
        )
        let formatDescriptions: [CMFormatDescription]
        if #available(iOS 15.0, *) {
            formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        } else {
            formatDescriptions = []
        }

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
                metrics["native_import_error"] = "foreground_required_for_gpu_depth"
                metrics["native_import_foreground_wait_expired"] = "1"
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
                formatDescriptions: formatDescriptions
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
                // Imported-video local subject-first must stay fire-and-forget on the
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
                let sleepSeconds = max(budget.ingestPollIntervalSeconds, 0.002)
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000.0))
            } while CFAbsoluteTimeGetCurrent() < submitDeadline
            if accepted {
                submittedFrames += 1
                lastSubmittedPTS = frameTimestamp
                let bootstrapFrameBudget = max(budget.bootstrapFrameBudget, 1)
                let latestDepthReady =
                    Int(latestSnapshot?.onDeviceDepthResultsReady ?? 0)
                let latestSelectedFrames =
                    Int(latestSnapshot?.selected_frames ?? 0)
                let latestSeedCandidates =
                    Int(latestSnapshot?.onDeviceSeedCandidates ?? 0)
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
                    _ = bridge.serviceLocalSubjectFirstBootstrap()
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
                let seedAccepted = Int(snapshot.onDeviceSeedAccepted)
                let pendingGaussians = Int(snapshot.pending_gaussian_count)
                let depthReady = Int(snapshot.onDeviceDepthResultsReady)
                let trainingStarted = realTrainingStarted()
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
            submittedFrames - Int(latestSnapshot?.onDeviceFramesIngested ?? 0)
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

        _ = bridge.serviceLocalSubjectFirstBootstrap()
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
            _ = bridge.serviceLocalSubjectFirstBootstrap()
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
            if let diagnosis = importedVideoSuitabilityDiagnosis(
                snapshot: snapshot,
                submittedFrames: submittedFrames,
                minimumSelectedFrames: minimumFramesForTraining
            ) {
                let metrics = appendImportedVideoSuitabilityFailure(
                    to: baseMetrics,
                    diagnosis: diagnosis,
                    snapshot: snapshot
                )
                emitLivePhase(
                    diagnosis.terminalPhase,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minimumFramesForTraining
                )
                return buildResult(
                    snapshot: snapshot,
                    exported: false,
                    runtimeMetrics: metrics,
                    detailMessage: diagnosis.detail,
                    terminalPhase: diagnosis.terminalPhase,
                    terminalProgressFraction: boundedPhaseProgress(
                        diagnosis.terminalPhase,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: minimumFramesForTraining
                    ),
                    liveSubmittedFrames: submittedFrames,
                    liveMinimumSelectedFrames: minimumFramesForTraining,
                    liveTargetFrames: targetSubmittedFrames
                )
            }
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
                detailMessage: "这次本地结果没能导出成功。相册视频已经读完，但在保底预算内仍然没有拿到可启动本地链的深度/seed 信号，所以本地处理没法继续往下走。",
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
            let depthReady = Int(latestSnapshot?.onDeviceDepthResultsReady ?? 0)
            if depthReady > 0 {
                return "深度先验已经回流，正在根据有效深度和局部一致性初始化本地高斯。"
            }
            return "正在等待最后一批单目 depth prior 回流，再启动本地高斯初始化。"
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
        latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
        if realTrainingStarted() || hasRefinePhaseEvidence(latestSnapshot) {
            promoteToRefineIfNeeded(
                submittedFrames: submittedFrames,
                minimumSelectedFrames: minimumFramesForTraining
            )
        }
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
            if let diagnosis = importedVideoSuitabilityDiagnosis(
                snapshot: snapshot,
                submittedFrames: submittedFrames,
                minimumSelectedFrames: minimumFramesForTraining
            ) {
                let metrics = appendImportedVideoSuitabilityFailure(
                    to: baseMetrics,
                    diagnosis: diagnosis,
                    snapshot: snapshot
                )
                emitLivePhase(
                    diagnosis.terminalPhase,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: minimumFramesForTraining
                )
                return buildResult(
                    snapshot: snapshot,
                    exported: false,
                    runtimeMetrics: metrics,
                    detailMessage: diagnosis.detail,
                    terminalPhase: diagnosis.terminalPhase,
                    terminalProgressFraction: boundedPhaseProgress(
                        diagnosis.terminalPhase,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: minimumFramesForTraining
                    ),
                    liveSubmittedFrames: submittedFrames,
                    liveMinimumSelectedFrames: minimumFramesForTraining,
                    liveTargetFrames: targetSubmittedFrames
                )
            }
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
                detailMessage: "这次本地结果没能导出成功。深度先验已经回流，但保底 seed 初始化仍然没拿到可开训的稳定几何，所以本地初始化被卡住了。",
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

        if let diagnosis = importedVideoSuitabilityDiagnosis(
            snapshot: latestSnapshot,
            submittedFrames: submittedFrames,
            minimumSelectedFrames: minimumFramesForTraining
        ) {
            let baseMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
                snapshot: latestSnapshot,
                sourceVideo: sourceRelativePath,
                exported: false,
                sourceKind: "imported_video",
                thermalState: ProcessInfo.processInfo.thermalState
            )
            let importedMetrics = LocalPreviewMetricsArchive.appendingImportedVideoContext(
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
            let metrics = appendImportedVideoSuitabilityFailure(
                to: importedMetrics,
                diagnosis: diagnosis,
                snapshot: latestSnapshot
            )
            emitLivePhase(
                diagnosis.terminalPhase,
                snapshot: latestSnapshot,
                submittedFrames: submittedFrames,
                minSelectedFrames: minimumFramesForTraining,
                force: true
            )
            return buildResult(
                snapshot: latestSnapshot,
                exported: false,
                runtimeMetrics: metrics,
                detailMessage: diagnosis.detail,
                terminalPhase: diagnosis.terminalPhase,
                terminalProgressFraction: boundedPhaseProgress(
                    diagnosis.terminalPhase,
                    snapshot: latestSnapshot,
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
            var reached = realTrainingStep(latestSnapshot)
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
                    observeSnapshotPeaks(snapshot)
                    let nativeActivityAgeSeconds = refreshNativeActivityAge(snapshot: snapshot)
                    let currentRealStep = realTrainingStep(snapshot)
                    reached = max(reached, currentRealStep)
                    emitLivePhase(
                        .refine,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(
                            Int(snapshot.min_frames_needed),
                            minimumSelectedFramesToStartTraining
                        )
                    )
                    if shouldAbortForFirstTrainingStepStall(
                        snapshot: snapshot,
                        phase: .refine
                    ) {
                        break
                    }
                    if Self.isApplicationForegroundActive() &&
                        nativeActivityAgeSeconds >= nativeActivityStallSeconds {
                        let progress = bridge.trainingProgress()
                        NSLog(
                            "[Aether3D][TrainStartupWatchdog] imported_video no native activity during refine age=%.1fs step=%d total_steps=%d gaussians=%d -> exporting current snapshot",
                            nativeActivityAgeSeconds,
                            currentRealStep,
                            Int(progress?.total_steps ?? 0),
                            max(
                                Int(snapshot.num_gaussians),
                                Int(progress?.num_gaussians ?? 0)
                            )
                        )
                        break
                    }
                    if currentRealStep >= targetSteps {
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
        _ = refreshNativeActivityAge(snapshot: latestSnapshot)
        var trainingDeadline = CFAbsoluteTimeGetCurrent() + max(budget.trainingTimeoutSeconds, 0.0)
        var reachedSteps = realTrainingStep(latestSnapshot)
        var exportMinSteps = resolveExportMinSteps(currentFloor: reachedSteps)
        var lastLoggedRealTrainingHeartbeatStep = 0

        func logRealTrainingHeartbeat(phase: LocalPreviewWorkflowPhase) {
            guard bridge.isTraining, let progress = bridge.trainingProgress() else { return }
            let step = Int(progress.step)
            let totalSteps = Int(progress.total_steps)
            guard step > 0, totalSteps > 0 else { return }
            guard lastLoggedRealTrainingHeartbeatStep == 0 ||
                    step <= 10 ||
                    step >= lastLoggedRealTrainingHeartbeatStep + 100 else {
                return
            }
            lastLoggedRealTrainingHeartbeatStep = step
            NSLog(
                "[Aether3D][TrainHeartbeat] imported_video phase=%@ real_step=%d/%d loss=%.4f",
                phase.phaseName,
                step,
                totalSteps,
                progress.loss
            )
        }
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
                observeSnapshotPeaks(snapshot)
                let nativeActivityAgeSeconds = refreshNativeActivityAge(snapshot: snapshot)
                let currentRealStep = realTrainingStep(snapshot)
                reachedSteps = max(reachedSteps, currentRealStep)
                logRealTrainingHeartbeat(phase: .refine)
                emitLivePhase(
                    LocalPreviewWorkflowPhase.refine,
                    snapshot: snapshot,
                    submittedFrames: submittedFrames,
                    minSelectedFrames: max(
                        Int(snapshot.min_frames_needed),
                        minimumSelectedFramesToStartTraining
                    )
                )
                if shouldAbortForFirstTrainingStepStall(
                    snapshot: snapshot,
                    phase: .refine
                ) {
                    break
                }
                if Self.isApplicationForegroundActive() &&
                    nativeActivityAgeSeconds >= nativeActivityStallSeconds {
                    let progress = bridge.trainingProgress()
                    NSLog(
                        "[Aether3D][TrainStartupWatchdog] imported_video no native activity during refine age=%.1fs step=%d total_steps=%d gaussians=%d -> exporting current snapshot",
                        nativeActivityAgeSeconds,
                        currentRealStep,
                        Int(progress?.total_steps ?? 0),
                        max(
                            Int(snapshot.num_gaussians),
                            Int(progress?.num_gaussians ?? 0)
                        )
                    )
                    break
                }
                if currentRealStep >= exportMinSteps {
                    break
                }
            }
            try? await Task.sleep(
                nanoseconds: UInt64(budget.ingestPollIntervalSeconds * 1_000_000_000.0)
            )
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
            observeSnapshotPeaks(latestSnapshot)
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
           realTrainingStarted() {
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
                    observeSnapshotPeaks(snapshot)
                    let nativeActivityAgeSeconds = refreshNativeActivityAge(snapshot: snapshot)
                    let currentRealStep = realTrainingStep(snapshot)
                    reachedSteps = max(reachedSteps, currentRealStep)
                    logRealTrainingHeartbeat(phase: .refine)
                    emitLivePhase(
                        LocalPreviewWorkflowPhase.refine,
                        snapshot: snapshot,
                        submittedFrames: submittedFrames,
                        minSelectedFrames: max(
                            Int(snapshot.min_frames_needed),
                            minimumSelectedFramesToStartTraining
                        )
                    )
                    if shouldAbortForFirstTrainingStepStall(
                        snapshot: snapshot,
                        phase: .refine
                    ) {
                        break
                    }
                    if Self.isApplicationForegroundActive() &&
                        nativeActivityAgeSeconds >= nativeActivityStallSeconds {
                        let progress = bridge.trainingProgress()
                        NSLog(
                            "[Aether3D][TrainStartupWatchdog] imported_video no native activity during refine age=%.1fs step=%d total_steps=%d gaussians=%d -> exporting current snapshot",
                            nativeActivityAgeSeconds,
                            currentRealStep,
                            Int(progress?.total_steps ?? 0),
                            max(
                                Int(snapshot.num_gaussians),
                                Int(progress?.num_gaussians ?? 0)
                            )
                        )
                        break
                    }
                    if currentRealStep >= exportMinSteps ||
                        !realTrainingStarted() {
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        latestSnapshot = bridge.getSnapshot()
        let exportAttemptLimit = 3
        var exportAttempts = 0
        var exported = false
        var exportElapsedMs: UInt64 = 0
        var exportFileSizeBytes: UInt64 = 0
        var lastExportStatusCode: Int32 = -5
        var lastExportStatusReason = "native_training_never_started"
        let rawArtifactURL = processingBackend == .localSubjectFirst
            ? Self.subjectRawArtifactPath(for: artifactURL)
            : artifactURL
        func exportDiagnosticsDetail() -> String {
            let fileSizeText = ByteCountFormatter.string(
                fromByteCount: Int64(exportFileSizeBytes),
                countStyle: .file
            )
            let reasonHint: String = {
                switch lastExportStatusReason {
                case "native_training_never_started":
                    return "native 关键帧 / seed 证据还没通过到真正创建训练引擎，这次导出其实是在训练未启动前被触发的。"
                case "native_failed_precondition":
                    if lastObservedRetainedExportGaussianCount == 0 {
                        return "导出时 native 没拿到健康的可写快照；这次连 retained snapshot 都没留住，所以更像是导出口径问题，不等于训练根本没跑。"
                    }
                    return "导出时 native 没拿到健康的可写快照，常见于训练引擎已结束且 retained snapshot 不可用，或当前高斯已经明显收缩到不可导出。"
                case "native_io_error":
                    return "导出文件创建或写入失败。"
                case "swift_parent_dir_create_failed":
                    return "Swift 侧在导出前创建输出目录失败。"
                case "native_ok_but_empty_or_missing_file":
                    return "native 返回成功，但输出文件仍然为空或不存在。"
                default:
                    return ""
                }
            }()
            let hintSuffix = reasonHint.isEmpty ? "" : " 提示：\(reasonHint)"
            return "导出诊断：尝试 \(exportAttempts) 次；状态 \(lastExportStatusCode)（\(lastExportStatusReason)）；文件 \(fileSizeText)；等待步数 \(reachedSteps)。\(hintSuffix)"
        }
        if realTrainingStarted() || reachedSteps > 0 {
            emitPhase(LocalPreviewWorkflowPhase.export, snapshot: latestSnapshot)
            lastExportStatusCode = -999
            lastExportStatusReason = "not_started"
            while exportAttempts < exportAttemptLimit {
                exportAttempts += 1
                let exportAttemptStart = CFAbsoluteTimeGetCurrent()
                let exportResult = bridge.exportPLYResult(path: rawArtifactURL.path)
                exportElapsedMs += UInt64(
                    max(0, (CFAbsoluteTimeGetCurrent() - exportAttemptStart) * 1000.0)
                )
                lastExportStatusCode = exportResult.statusCode
                lastExportStatusReason = exportResult.statusReason
                exportFileSizeBytes = max(exportFileSizeBytes, exportResult.fileSizeBytes)

                if exportResult.succeeded {
                    exported = true
                    break
                }

                latestSnapshot = bridge.getSnapshot() ?? latestSnapshot
                reachedSteps = max(reachedSteps, realTrainingStep(latestSnapshot))
                logRealTrainingHeartbeat(phase: .export)
                observeSnapshotPeaks(latestSnapshot)
                if exportAttempts < exportAttemptLimit &&
                    (realTrainingStarted() || reachedSteps > 0) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        NSLog(
            exported
                ? "[Aether3D][ExportTerminal] imported_video result=success attempts=%d status=%d reason=%@ steps=%d file_bytes=%llu path=%@"
                : "[Aether3D][ExportTerminal] imported_video result=failure attempts=%d status=%d reason=%@ steps=%d file_bytes=%llu path=%@",
            exportAttempts,
            lastExportStatusCode,
            lastExportStatusReason,
            reachedSteps,
            exportFileSizeBytes,
            rawArtifactURL.path
        )

        let snapshot = bridge.getSnapshot() ?? latestSnapshot
        observeSnapshotPeaks(snapshot)
        let totalElapsedMs = UInt64(max(0, (CFAbsoluteTimeGetCurrent() - startWallClock) * 1000.0))

        let baseMetrics = LocalPreviewMetricsArchive.runtimeMetrics(
            snapshot: snapshot,
            sourceVideo: sourceRelativePath,
            exported: exported,
            sourceKind: "imported_video",
            processingBackend: processingBackend,
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
        metrics["native_export_attempts"] = "\(exportAttempts)"
        metrics["native_export_file_size_bytes"] = "\(exportFileSizeBytes)"
        metrics["native_export_wait_steps"] = "\(reachedSteps)"
        metrics["native_export_status_code"] = "\(lastExportStatusCode)"
        metrics["native_export_failure_reason"] = lastExportStatusReason
        metrics["native_export_output_path"] = rawArtifactURL.path
        metrics["native_peak_gaussians"] = "\(lastObservedGaussianCount)"
        metrics["native_peak_pending_gaussians"] = "\(lastObservedPendingGaussianCount)"
        metrics["native_peak_working_set"] = "\(lastObservedWorkingSetCount)"
        metrics["native_peak_retained_export_gaussians"] = "\(lastObservedRetainedExportGaussianCount)"
        let currentGaussians = Int(snapshot?.num_gaussians ?? 0)
        let currentPendingGaussians = Int(snapshot?.pending_gaussian_count ?? 0)
        let currentRetainedGaussians = Int(snapshot?.retained_export_gaussians ?? 0)
        let currentWorkingSet = max(currentGaussians + currentPendingGaussians, 0)
        metrics["native_current_gaussians"] = "\(currentGaussians)"
        metrics["native_current_pending_gaussians"] = "\(currentPendingGaussians)"
        metrics["native_current_working_set"] = "\(currentWorkingSet)"
        metrics["native_current_retained_export_gaussians"] = "\(currentRetainedGaussians)"

        let exportDetailMessage: String = {
            if exported {
                return "本地结果已生成。这个结果导出的是本地 Gaussian 结果文件，不再回退成 TSDF/点云伪彩替代物。"
            }
            if reachedSteps > 0 || realTrainingStarted() {
                if let snapshot {
                    let step = realTrainingStep(snapshot)
                    let gaussians = Int(snapshot.num_gaussians)
                    let retainedGaussians = Int(snapshot.retained_export_gaussians)
                    let gaussianSummary = gaussianLifecycleSummary(
                        currentGaussians: gaussians,
                        retainedExportGaussians: retainedGaussians
                    )
                    let collapseNote = likelyCollapsedAfterInitialization(currentGaussians: gaussians)
                        ? "\n\n初始化阶段看到的工作集并不等于最终可导出的训练高斯。导出失败时训练器里只剩 \(gaussians) 个，说明后面的 refine / cleanup 已经把大量不稳定候选明显收缩掉了。"
                        : ""
                    if step > 0 {
                        return "这次本地结果没能导出成功。本地 refine 已经真正启动并跑到 \(step) 步（\(gaussianSummary)），但最终 Gaussian 结果文件还没有成功写出来。\(collapseNote)\n\n\(exportDiagnosticsDetail())"
                    }
                    return "这次本地结果没能导出成功。初始化和本地 refine 已经启动（\(gaussianSummary)），但最终 Gaussian 结果文件还没有成功写出来。\(collapseNote)\n\n\(exportDiagnosticsDetail())"
                }
                return "这次本地结果没能导出成功。本地 refine 已经启动，但最终 Gaussian 结果文件还没有成功写出来。\n\n\(exportDiagnosticsDetail())"
            }
            if let snapshot {
                if snapshot.selected_frames > 0 || snapshot.onDeviceSeedCandidates > 0 || snapshot.onDeviceSeedAccepted > 0 {
                    return "这次本地结果没能导出成功。单目 depth prior 已经回流，但关键帧 gate / seed 初始化没有拿到足够的稳定几何，本地结果链没有真正启动。\n\n\(exportDiagnosticsDetail())"
                }
                if snapshot.onDeviceDepthResultsReady == 0 {
                    return "这次本地结果没能导出成功。相册视频已经读完，但单目 depth prior 还没在预算内真正回流，所以本地结果链没能启动。\n\n\(exportDiagnosticsDetail())"
                }
                if snapshot.selected_frames == 0 {
                    return "这次本地结果没能导出成功。深度先验已经回流，但关键帧 gate 没有拿到足够的有效帧，本地初始化被卡住了。\n\n\(exportDiagnosticsDetail())"
                }
            }
            if photometricCounters.acceptedFrames == 0 &&
                (photometricCounters.exposureRejects > 0 || photometricCounters.whiteBalanceRejects > 0) {
                return "这次本地结果没能导出成功。相册视频在曝光或白平衡一致性上不稳定，导入帧在 photometric gate 里被全部拦下了。\n\n\(exportDiagnosticsDetail())"
            }
            if reachedSteps == 0 {
                return "这次本地结果没能导出成功。视频读取已经完成，但本地 refine 没有真正启动，所以最终 Gaussian 结果文件没有写出来。\n\n\(exportDiagnosticsDetail())"
            }
            return "这次本地结果没能导出成功。视频读取和训练链已经跑通，但最终 Gaussian 结果文件没有写出来。\n\n\(exportDiagnosticsDetail())"
        }()

        let finalExportState: (exported: Bool, detailMessage: String) = await {
            guard exported else {
                return (false, exportDetailMessage)
            }
            return await Self.finalizeLocalSubjectArtifactsIfNeeded(
                processingBackend: processingBackend,
                rawArtifactURL: rawArtifactURL,
                finalArtifactURL: artifactURL,
                baseMetrics: &metrics,
                phaseEmitter: { phase, detail in
                    emitPhase(phase, snapshot: latestSnapshot, detailOverride: detail)
                }
            )
        }()
        exported = finalExportState.exported
        let detailMessage = finalExportState.detailMessage

        let terminalFailurePhase: LocalPreviewWorkflowPhase = {
            guard !exported else { return .export }
            if reachedSteps > 0 || realTrainingStarted() {
                return .refine
            }
            if let snapshot {
                if snapshot.onDeviceSeedAccepted > 0 ||
                    snapshot.onDeviceSeedCandidates > 0 ||
                    snapshot.pending_gaussian_count > 0 ||
                    snapshot.selected_frames > 0 {
                    return .seed
                }
                if snapshot.onDeviceDepthResultsReady > 0 {
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
