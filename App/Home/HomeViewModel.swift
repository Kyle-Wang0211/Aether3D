//
// HomeViewModel.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Home Page ViewModel
// Apple-platform only (SwiftUI)
//

import Foundation
import Aether3DCore
import simd

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

private struct HomePersistedObjectModeViewerBundle {
    let defaultArtifactRelativePath: String
    let localManifestRelativePath: String
    let localComparisonAssetPath: String?
    let localComparisonMetricsPath: String?
    let localHQArtifactPath: String?
    let inspectionOnly: Bool
    let hqPassed: Bool
    let failedCards: [String]
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var scanRecords: [ScanRecord] = []
    @Published var navigateToScan: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var busyMessage: String?
    @Published var isImportingVideo: Bool = false

    private let store: ScanRecordStore
    private var activeRecoveryRecordIDs: Set<UUID> = []
    private var scheduledRecoveryRecordIDs: Set<UUID> = []
    private var lastRecoveryAttemptAt: [UUID: Date] = [:]
    private var loadRecordsTask: Task<Void, Never>?
    private let preferredRemoteBackend: PipelineBackend
    private let recoveryAttemptThrottleSeconds: TimeInterval = 4

    init(store: ScanRecordStore = ScanRecordStore(), preferredRemoteBackend: PipelineBackend = .productDefault()) {
        self.store = store
        self.preferredRemoteBackend = preferredRemoteBackend
    }

    var processingRecords: [ScanRecord] {
        scanRecords.filter { $0.isProcessing }.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var completedRecords: [ScanRecord] {
        scanRecords.filter { !$0.isProcessing && $0.status != .failed && $0.status != .cancelled }.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var cancelledRecords: [ScanRecord] {
        scanRecords.filter { $0.status == .cancelled }.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var failedRecords: [ScanRecord] {
        scanRecords.filter { $0.status == .failed }.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    var hasVisibleRecords: Bool {
        !processingRecords.isEmpty ||
        !cancelledRecords.isEmpty ||
        !failedRecords.isEmpty ||
        !completedRecords.isEmpty
    }

    func loadRecords(scheduleRemoteResume: Bool = true, showLoadingOverlay: Bool? = nil) {
        let shouldShowLoadingOverlay = showLoadingOverlay ?? scanRecords.isEmpty
        isLoading = shouldShowLoadingOverlay
        loadRecordsTask?.cancel()
        let store = self.store
        loadRecordsTask = Task(priority: .userInitiated) { [weak self] in
            _ = store.purgeExpiredFrozenPlaceholderRecords()
            _ = store.freezeStaleProcessingRecords()
            let records = store.loadRecords().sorted { $0.updatedAt > $1.updatedAt }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.scanRecords = records
                self.isLoading = false
                guard scheduleRemoteResume else { return }
                for record in self.scanRecords where
                    record.isProcessing
                    || self.shouldForceImmediateRemoteResume(record)
                    || self.shouldCheckLatestObjectFastPublishJob(record)
                    || self.shouldResumeFailedRemoteRecord(record)
                    || self.shouldResumeCompletedRemoteRecord(record) {
                    self.scheduleRemoteResumeIfNeeded(
                        record,
                        force: self.shouldForceImmediateRemoteResume(record)
                            || self.shouldCheckLatestObjectFastPublishJob(record)
                            || self.shouldResumeFailedRemoteRecord(record)
                            || self.shouldResumeCompletedRemoteRecord(record)
                    )
                }
            }
        }
    }

    func deleteRecord(_ record: ScanRecord) {
        store.deleteRecord(id: record.id)
        scanRecords.removeAll { $0.id == record.id }
    }

    func saveScanResult(_ record: ScanRecord) {
        store.saveRecord(record)
        loadRecords(scheduleRemoteResume: false)
    }

    @discardableResult
    func refreshRecord(id: UUID) -> ScanRecord? {
        let refreshed = store.record(id: id)
        if let refreshed {
            if let index = scanRecords.firstIndex(where: { $0.id == id }) {
                scanRecords[index] = refreshed
            } else {
                scanRecords.append(refreshed)
                scanRecords.sort { $0.updatedAt > $1.updatedAt }
            }
        } else {
            scanRecords.removeAll { $0.id == id }
        }
        return refreshed
    }

    #if canImport(AVFoundation)
    func importVideo(at sourceURL: URL, processingBackend: ProcessingBackendChoice) async -> ScanRecord? {
        isImportingVideo = true
        busyMessage = "正在准备所选视频..."
        errorMessage = nil

        do {
            let recordId = UUID()
            let selectedFrameSamplingProfile = FrameSamplingProfile.currentSelection()
            let effectiveProcessingBackend = processingBackend.normalizedForActiveUse
            let baseDirectory = store.baseDirectoryURL()
            let importsDirectory = baseDirectory.appendingPathComponent("imports", isDirectory: true)
            let exportsDirectory = baseDirectory.appendingPathComponent("exports", isDirectory: true)
            try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

            let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
            let targetURL = importsDirectory.appendingPathComponent("\(recordId.uuidString).\(ext)")
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)

            let asset = AVURLAsset(url: targetURL)
            let thumbnailPath = try await makeThumbnail(for: asset, recordId: recordId)
            let duration = (try? await asset.load(.duration)) ?? .zero
            let durationSeconds = duration.seconds.isFinite ? duration.seconds : 0

            let relativeSource = "imports/\(targetURL.lastPathComponent)"
            let record = ScanRecord(
                id: recordId,
                thumbnailPath: thumbnailPath,
                artifactPath: nil,
                sourceVideoPath: relativeSource,
                frameSamplingProfile: selectedFrameSamplingProfile.rawValue,
                captureIntent: nil,
                processingBackend: effectiveProcessingBackend.rawValue,
                coveragePercentage: 0.0,
                triangleCount: 0,
                durationSeconds: durationSeconds,
                status: .preparing,
                statusMessage: effectiveProcessingBackend == .cloud
                    ? "正在准备后台上传任务"
                    : "正在准备本地处理",
                detailMessage: effectiveProcessingBackend == .cloud
                    ? "只有这次你手动选择的视频会进入后台上传与训练队列；过去的旧素材不会自动重发。"
                    : "这次会先在手机上走本地处理链路：单目点图、cutout，再做保守 cleanup。",
                progressFraction: 0.01,
                estimatedRemainingMinutes: nil
            )

            store.saveRecord(record)
            loadRecords(scheduleRemoteResume: false)

            Task {
                if effectiveProcessingBackend.usesLocalPreviewPipeline {
                    await self.runLocalPreviewImport(
                        for: recordId,
                        sourceVideoURL: targetURL,
                        processingBackend: effectiveProcessingBackend
                    )
                } else {
                    await self.runRemoteBuild(for: recordId, sourceVideoURL: targetURL, allowLocalFallback: false)
                }
            }

            busyMessage = effectiveProcessingBackend == .cloud
                ? nil
                : "正在启动本地处理..."
            isImportingVideo = false
            return record
        } catch {
            errorMessage = "这个视频暂时无法导入，请换一个视频再试。"
            busyMessage = nil
            isImportingVideo = false
            return nil
        }
    }
    #endif

    func retryRecord(_ record: ScanRecord) {
        guard let sourceVideoPath = record.sourceVideoPath else {
            errorMessage = "找不到原始视频，暂时无法重试。"
            return
        }
        let sourceURL = store.baseDirectoryURL().appendingPathComponent(sourceVideoPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            errorMessage = "原始视频已经不在本地，暂时无法重试。"
            return
        }

        let backend = record.resolvedProcessingBackend
        let isObjectFastPublish = isObjectFastPublishRecord(record)
        store.updateProcessingState(
            recordId: record.id,
            status: .preparing,
            statusMessage: backend.usesLocalPreviewPipeline
                ? "正在重新启动本地处理"
                : (isObjectFastPublish ? "正在重新发起新远端生成" : "正在重新发起远端训练"),
            detailMessage: backend.usesLocalPreviewPipeline
                ? "这次会重新走手机本地处理链路。"
                : (isObjectFastPublish
                    ? "这次会重新走新远端 SLAM3R + Sparse2DGS 对象链路。"
                    : "这次会重新走后台上传与远端调度流程。"),
            progressFraction: 0.01,
            estimatedRemainingMinutes: nil,
            clearRemoteJobId: true,
            failureReason: nil
        )
        loadRecords(scheduleRemoteResume: false)

        Task {
            if backend.usesLocalPreviewPipeline {
                await self.runLocalPreviewImport(
                    for: record.id,
                    sourceVideoURL: sourceURL,
                    processingBackend: backend
                )
            } else {
                if isObjectFastPublish {
                    await self.runObjectFastPublishBuild(for: record.id, sourceVideoURL: sourceURL)
                } else {
                    await self.runRemoteBuild(for: record.id, sourceVideoURL: sourceURL, allowLocalFallback: false)
                }
            }
        }
    }

    func canReimportObjectFastPublishResult(_ record: ScanRecord) -> Bool {
        record.status == .completed
            && isObjectFastPublishRecord(record)
            && resolvedObjectFastPublishRemoteJobId(for: record) != nil
    }

    func reimportObjectFastPublishResultAsNewRecord(_ sourceRecord: ScanRecord) {
        Task { @MainActor [weak self] in
            await self?.performObjectFastPublishReimport(sourceRecord)
        }
    }

    #if canImport(AVFoundation)
    private func runLocalPreviewImport(
        for recordId: UUID,
        sourceVideoURL: URL,
        processingBackend: ProcessingBackendChoice
    ) async {
        let processingBackend = processingBackend.normalizedForActiveUse
        let frameSamplingProfile = selectedFrameSamplingProfile(for: recordId)
        let artifactRelativePath = "exports/\(recordId.uuidString).ply"
        let artifactURL = store.baseDirectoryURL().appendingPathComponent(artifactRelativePath)
        let sourceRelativePath = store.record(id: recordId)?.sourceVideoPath ?? "imports/\(sourceVideoURL.lastPathComponent)"
        let stageKey = processingBackend.localWorkflowStageKey ?? ProcessingBackendChoice.localSubjectFirst.localWorkflowStageKey!
        let initialPhaseModel = "recorded_video_depth_seed_refine_cutout_cleanup_export"
        final class LocalPreviewUiRefreshThrottle {
            var lastRefreshAt: CFAbsoluteTime = 0.0
            var lastPhaseName = ""
            var lastSubmittedFrames = -1
            var lastProcessedFrames = -1
            var lastSelectedFrames = -1
        }
        let uiRefreshThrottle = LocalPreviewUiRefreshThrottle()

        let applyLocalPreviewPhase: @MainActor @Sendable (LocalPreviewPhaseUpdate) -> Void = { [self] update in
            self.store.updateProcessingState(
                recordId: recordId,
                status: {
                    switch update.phase {
                    case .depth, .seed, .refine:
                        return .training
                    case .cutout, .cleanup, .export:
                        return .packaging
                    }
                }(),
                statusMessage: update.title,
                detailMessage: update.detail,
                progressFraction: update.progressFraction,
                progressBasis: update.phase.progressBasis,
                remoteStageKey: stageKey,
                remotePhaseName: update.phase.phaseName,
                runtimeMetrics: update.runtimeMetrics,
                estimatedRemainingMinutes: nil,
                sourceVideoPath: sourceRelativePath,
                frameSamplingProfile: frameSamplingProfile.rawValue,
                clearRemoteJobId: true
            )
            _ = self.refreshRecord(id: recordId)
            let submittedFrames = Int(
                LocalPreviewProductProfile.runtimeMetricString(
                    "native_live_submitted_frames",
                    from: update.runtimeMetrics
                )
                ?? LocalPreviewProductProfile.runtimeMetricString(
                    "native_import_submitted_frames",
                    from: update.runtimeMetrics
                )
                ?? "-1"
            ) ?? -1
            let processedFrames = Int(
                LocalPreviewProductProfile.runtimeMetricString(
                    "native_processed_frames",
                    from: update.runtimeMetrics
                ) ?? "-1"
            ) ?? -1
            let queueIngestedFrames = Int(
                LocalPreviewProductProfile.runtimeMetricString(
                    "native_frames_ingested",
                    from: update.runtimeMetrics
                ) ?? "-1"
            ) ?? -1
            let selectedFrames = Int(
                LocalPreviewProductProfile.runtimeMetricString(
                    "native_selected_frames",
                    from: update.runtimeMetrics
                ) ?? "-1"
            ) ?? -1
            let now = CFAbsoluteTimeGetCurrent()
            let isDepthPhase = update.phase == .depth
            let shouldReload =
                update.phase.phaseName != uiRefreshThrottle.lastPhaseName ||
                (isDepthPhase
                    ? submittedFrames != uiRefreshThrottle.lastSubmittedFrames
                    : submittedFrames - uiRefreshThrottle.lastSubmittedFrames >= 4) ||
                processedFrames - uiRefreshThrottle.lastProcessedFrames >= 1 ||
                selectedFrames != uiRefreshThrottle.lastSelectedFrames ||
                (isDepthPhase && queueIngestedFrames >= 0 && queueIngestedFrames != processedFrames) ||
                now - uiRefreshThrottle.lastRefreshAt >= (isDepthPhase ? 0.25 : 0.75)
            if shouldReload {
                uiRefreshThrottle.lastRefreshAt = now
                uiRefreshThrottle.lastPhaseName = update.phase.phaseName
                uiRefreshThrottle.lastSubmittedFrames = submittedFrames
                uiRefreshThrottle.lastProcessedFrames = processedFrames
                uiRefreshThrottle.lastSelectedFrames = selectedFrames
                self.loadRecords(scheduleRemoteResume: false)
            }
        }

        store.updateProcessingState(
            recordId: recordId,
            status: .training,
            statusMessage: LocalPreviewWorkflowPhase.depth.title,
            detailMessage: "正在建立本地单目深度先验，后面会继续做 cutout 和保守 cleanup。",
            progressFraction: LocalPreviewWorkflowPhase.depth.startFraction,
            progressBasis: LocalPreviewWorkflowPhase.depth.progressBasis,
            remoteStageKey: stageKey,
            remotePhaseName: LocalPreviewWorkflowPhase.depth.phaseName,
            runtimeMetrics: LocalPreviewProductProfile.canonicalRuntimeMetrics([
                "processing_backend": processingBackend.rawValue,
                "native_input_kind": "recorded_video",
                "native_active_phase": LocalPreviewWorkflowPhase.depth.phaseName,
                "native_phase_model": initialPhaseModel,
            ]),
            estimatedRemainingMinutes: nil,
            clearRemoteJobId: true
        )
        loadRecords(scheduleRemoteResume: false)

        NSLog(
            "[Aether3D][HomeLocalRun] manual local processing start record=%@ backend=%@ source=%@",
            recordId.uuidString,
            processingBackend.rawValue,
            sourceRelativePath
        )
        let result = await Task.detached(priority: .userInitiated) {
            await LocalPreviewImportRunner.execute(
                sourceVideoURL: sourceVideoURL,
                artifactURL: artifactURL,
                sourceRelativePath: sourceRelativePath,
                frameSamplingProfile: frameSamplingProfile,
                processingBackend: processingBackend,
                onPhaseUpdate: { update in
                    Task { @MainActor in
                        applyLocalPreviewPhase(update)
                    }
                }
            )
        }.value
        NSLog(
            "[Aether3D][HomeLocalRun] manual local processing end record=%@ exported=%@ terminal_phase=%@",
            recordId.uuidString,
            result.exported ? "YES" : "NO",
            result.terminalPhase.phaseName
        )

        if result.exported {
            store.updateProcessingState(
                recordId: recordId,
                status: .completed,
                statusMessage: "本地结果已生成",
                detailMessage: result.detailMessage,
                progressFraction: 1.0,
                progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                remoteStageKey: stageKey,
                remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                runtimeMetrics: result.runtimeMetrics,
                estimatedRemainingMinutes: 0,
                sourceVideoPath: sourceRelativePath,
                frameSamplingProfile: frameSamplingProfile.rawValue,
                clearRemoteJobId: true
            )
            store.updateArtifactPath(recordId: recordId, artifactPath: artifactRelativePath)
        } else {
            store.updateProcessingState(
                recordId: recordId,
                status: .failed,
                statusMessage: "本地处理失败了",
                detailMessage: result.detailMessage,
                progressFraction: result.terminalProgressFraction,
                progressBasis: result.terminalPhase.progressBasis,
                remoteStageKey: stageKey,
                remotePhaseName: result.terminalPhase.phaseName,
                runtimeMetrics: result.runtimeMetrics,
                estimatedRemainingMinutes: nil,
                sourceVideoPath: sourceRelativePath,
                frameSamplingProfile: frameSamplingProfile.rawValue,
                failureReason: LocalPreviewProductProfile.runtimeMetricString(
                    "native_failure_reason",
                    from: result.runtimeMetrics
                ) ?? OnDeviceProcessingCompatibility.canonicalImportFailureReason
            )
        }
        loadRecords(scheduleRemoteResume: false)
    }

    #endif

    func cancelRemoteRecord(_ record: ScanRecord) {
        guard let remoteJobId = record.remoteJobId, !remoteJobId.isEmpty else {
            errorMessage = "这次任务还没有远端任务号，暂时无法取消。"
            return
        }

        store.updateProcessingState(
            recordId: record.id,
            status: .cancelled,
            statusMessage: "正在取消远端任务",
            detailMessage: "会停止当前远端处理，并保留当前素材方便稍后重试。",
            progressFraction: record.displayProgressFraction,
            estimatedRemainingMinutes: nil,
            sourceVideoPath: record.sourceVideoPath,
            remoteJobId: remoteJobId,
            failureReason: "cancel_requested"
        )
        loadRecords(scheduleRemoteResume: false)

        Task {
            let runner = PipelineRunner(backend: preferredRemoteBackend)
            let cancelled = await runner.cancelGenerate(jobId: remoteJobId)
            await MainActor.run {
                self.store.updateProcessingState(
                    recordId: record.id,
                    status: .cancelled,
                    statusMessage: cancelled ? "你已取消这次远端任务" : "远端任务取消请求已发出",
                    detailMessage: cancelled
                        ? "远端任务已停止，原始视频仍保留在本地，随时可以重试。"
                        : "控制平面已经收到了取消请求，但还没等到远端 worker 真正确认停下；我会继续保留这条远端任务号，避免后台其实还在跑。",
                    progressFraction: record.displayProgressFraction,
                    estimatedRemainingMinutes: nil,
                    sourceVideoPath: record.sourceVideoPath,
                    remoteJobId: cancelled ? nil : remoteJobId,
                    clearRemoteJobId: cancelled,
                    failureReason: cancelled ? "cancelled_by_user" : "cancel_requested_unconfirmed"
                )
                self.loadRecords(scheduleRemoteResume: false)
            }
        }
    }

    func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func updateRecordFromProgress(recordId: UUID, snapshot: GenerateProgressSnapshot) {
        store.updateProcessingState(
            recordId: recordId,
            status: status(for: snapshot.stage),
            statusMessage: snapshot.title,
            detailMessage: snapshot.detail,
            progressFraction: snapshot.progressFraction,
            progressBasis: snapshot.progressBasis,
            remoteStageKey: snapshot.remoteStageKey,
            remotePhaseName: snapshot.remotePhaseName,
            currentTier: snapshot.currentTier,
            runtimeMetrics: snapshot.runtimeMetrics,
            uploadedBytes: snapshot.uploadedBytes,
            totalBytes: snapshot.totalBytes,
            uploadBytesPerSecond: snapshot.uploadBytesPerSecond,
            estimatedRemainingMinutes: snapshot.etaMinutes,
            remoteJobId: snapshot.remoteJobId
        )
        loadRecords(scheduleRemoteResume: false)
    }

    private func completeRecord(recordId: UUID, artifact: ArtifactRef) {
        let existingRecord = store.record(id: recordId)
        let finalURL = store.baseDirectoryURL()
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(recordId.uuidString).ply")

        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.createDirectory(
                at: finalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try Data(contentsOf: artifact.localPath)
            try payload.write(to: finalURL, options: .atomic)
            let artifactPath = "exports/\(finalURL.lastPathComponent)"
            store.updateArtifactPath(recordId: recordId, artifactPath: artifactPath)
            if let remoteJobId = existingRecord?.remoteJobId, !remoteJobId.isEmpty {
                Task {
                    await BackgroundUploadBrokerClient.shared.sendClientEvent(
                        jobId: remoteJobId,
                        eventType: "mobile_artifact_path_written",
                        eventAt: Date(),
                        payload: ["artifact_path": artifactPath]
                    )
                }
            }
        } catch {
            store.updateProcessingState(
                recordId: recordId,
                status: .failed,
                statusMessage: "回传到手机时失败了",
                detailMessage: "请保持网络稳定后重试。",
                progressFraction: 0.92,
                estimatedRemainingMinutes: nil,
                failureReason: "copy_failed"
            )
        }
        loadRecords(scheduleRemoteResume: false)
    }

    private func failRecord(recordId: UUID, reason: FailReason, detailOverride: String? = nil) {
        let existingRecord = store.record(id: recordId)
        let existingFailureTitle: String? = {
            guard existingRecord?.status == .failed else { return nil }
            guard let title = existingRecord?.statusMessage, !title.isEmpty else { return nil }
            return title
        }()
        let existingFailureDetail: String? = {
            guard existingRecord?.status == .failed else { return nil }
            guard let detail = existingRecord?.detailMessage, !detail.isEmpty else { return nil }
            return detail
        }()

        store.updateProcessingState(
            recordId: recordId,
            status: .failed,
            statusMessage: existingFailureTitle ?? failureTitle(for: reason),
            detailMessage: detailOverride ?? existingFailureDetail ?? failureDetail(for: reason),
            progressFraction: nil,
            estimatedRemainingMinutes: nil,
            failureReason: reason.rawValue
        )
        loadRecords(scheduleRemoteResume: false)
    }

    func resumeRemoteJobIfNeeded(_ record: ScanRecord, force: Bool = false) {
        let awaitingCancelConfirmation = record.status == .cancelled && record.failureReason == "cancel_requested_unconfirmed"
        let resumableFailedRemoteRecord = shouldResumeFailedRemoteRecord(record)
        let resumableCompletedRemoteRecord = shouldResumeCompletedRemoteRecord(record)
        let shouldCheckLatestObjectFastPublishJob = shouldCheckLatestObjectFastPublishJob(record)
        let allowProcessingArtifactResume = isObjectFastPublishRecord(record) && record.isProcessing
        let currentRemoteJobId = record.remoteJobId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (record.artifactPath == nil || allowProcessingArtifactResume),
              (record.isProcessing
                || awaitingCancelConfirmation
                || resumableFailedRemoteRecord
                || resumableCompletedRemoteRecord
                || shouldCheckLatestObjectFastPublishJob) else {
            return
        }

        let shouldForceResume = force || shouldForceImmediateRemoteResume(record) || resumableCompletedRemoteRecord
        let isStale = Date().timeIntervalSince(record.updatedAt) > 15
        guard shouldForceResume || isStale || shouldCheckLatestObjectFastPublishJob else { return }
        guard !activeRecoveryRecordIDs.contains(record.id) else { return }

        let now = Date()
        if let lastAttemptAt = lastRecoveryAttemptAt[record.id],
           now.timeIntervalSince(lastAttemptAt) < recoveryAttemptThrottleSeconds {
            return
        }
        lastRecoveryAttemptAt[record.id] = now

        activeRecoveryRecordIDs.insert(record.id)
        let recoveryDetail: String? = {
            if resumableCompletedRemoteRecord {
                return "远端已经完成，正在把 3DGS 结果继续回传到手机并写入本地记录。"
            }
            if shouldCheckLatestObjectFastPublishJob {
                return "正在检查这条扫描是否已经切换到新的远端任务，并尝试接续最新进度。"
            }
            if shouldForceResume {
                return "已经重新连上后台任务状态服务，正在立刻确认这条任务是不是已经被后端接单并开始处理。"
            }
            return "已经重新连上后台任务状态服务，正在继续拉取这次任务的最新进度。"
        }()
        store.updateProcessingState(
            recordId: record.id,
            status: record.status,
            statusMessage: record.displayStatusMessage,
            detailMessage: record.detailMessage ?? recoveryDetail,
            progressFraction: max(record.displayProgressFraction, 0.12),
            estimatedRemainingMinutes: record.estimatedRemainingMinutes,
            sourceVideoPath: record.sourceVideoPath,
            remoteJobId: currentRemoteJobId
        )
        _ = refreshRecord(id: record.id)

        Task {
            let effectiveRemoteJobId: String?
            if self.isObjectFastPublishRecord(record) {
                effectiveRemoteJobId = await self.rebindObjectFastPublishRemoteJobIfNeeded(
                    recordId: record.id,
                    currentRemoteJobId: currentRemoteJobId
                ) ?? currentRemoteJobId
            } else {
                effectiveRemoteJobId = currentRemoteJobId
            }

            guard let effectiveRemoteJobId, !effectiveRemoteJobId.isEmpty else {
                _ = await MainActor.run {
                    self.activeRecoveryRecordIDs.remove(record.id)
                }
                return
            }

            if self.isObjectFastPublishRecord(record) {
                await self.resumeObjectFastPublishBuild(for: record.id, jobId: effectiveRemoteJobId)
            } else {
                await self.resumeRemoteBuild(for: record.id, jobId: effectiveRemoteJobId)
            }
            _ = await MainActor.run {
                self.activeRecoveryRecordIDs.remove(record.id)
            }
        }
    }

    private func scheduleRemoteResumeIfNeeded(_ record: ScanRecord, force: Bool) {
        guard !scheduledRecoveryRecordIDs.contains(record.id) else { return }
        scheduledRecoveryRecordIDs.insert(record.id)
        Task { @MainActor [weak self] in
            defer { self?.scheduledRecoveryRecordIDs.remove(record.id) }
            await Task.yield()
            self?.resumeRemoteJobIfNeeded(record, force: force)
        }
    }

    private func shouldForceImmediateRemoteResume(_ record: ScanRecord) -> Bool {
        let allowProcessingArtifactResume = isObjectFastPublishRecord(record) && record.isProcessing
        guard (record.artifactPath == nil || allowProcessingArtifactResume),
              let remoteJobId = record.remoteJobId,
              !remoteJobId.isEmpty else {
            return false
        }

        switch record.status {
        case .uploading, .queued:
            return true
        case .completed:
            return record.artifactPath == nil
        case .cancelled:
            return record.failureReason == "cancel_requested_unconfirmed"
        default:
            return false
        }
    }

    private func shouldCheckLatestObjectFastPublishJob(_ record: ScanRecord) -> Bool {
        guard isObjectFastPublishRecord(record), record.artifactPath == nil else {
            return false
        }
        switch record.status {
        case .failed, .cancelled, .completed:
            return true
        default:
            return false
        }
    }

    private func shouldResumeFailedRemoteRecord(_ record: ScanRecord) -> Bool {
        guard record.status == .failed,
              record.artifactPath == nil,
              let remoteJobId = record.remoteJobId,
              !remoteJobId.isEmpty else {
            return false
        }

        let normalized = record.failureReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let resumableFailures: Set<String> = [
            "api_error",
            "worker_orphaned_assignment",
            "worker_stalled_or_runtime_stale",
            "stalled_processing",
            "download_failed",
        ]
        return resumableFailures.contains(normalized)
    }

    private func shouldResumeCompletedRemoteRecord(_ record: ScanRecord) -> Bool {
        guard record.status == .completed,
              record.artifactPath == nil,
              let remoteJobId = record.remoteJobId,
              !remoteJobId.isEmpty else {
            return false
        }
        return true
    }

    private func rebindObjectFastPublishRemoteJobIfNeeded(
        recordId: UUID,
        currentRemoteJobId: String?
    ) async -> String? {
        let normalizedCurrentRemoteJobId = currentRemoteJobId?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let latestRemoteJobId = try await BackgroundUploadBrokerClient.shared.findLatestJobId(
                clientRecordId: recordId,
                captureOrigin: "object_mode_v2"
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let latestRemoteJobId, !latestRemoteJobId.isEmpty else {
                return normalizedCurrentRemoteJobId
            }
            guard latestRemoteJobId != normalizedCurrentRemoteJobId else {
                return latestRemoteJobId
            }

            let existingRecord = store.record(id: recordId)
            store.updateProcessingState(
                recordId: recordId,
                status: .queued,
                statusMessage: "已同步到最新远端任务",
                detailMessage: "检测到这条扫描已经切换到新的远端任务，正在接续最新任务进度。",
                progressFraction: max(existingRecord?.displayProgressFraction ?? 0.12, 0.12),
                progressBasis: "remote_job_rebound",
                remoteStageKey: "remote_job_rebound",
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "remote_job_rebound",
                    detail: "rebound_to_latest_remote_job",
                    remoteJobId: latestRemoteJobId,
                    defaultArtifactReady: existingRecord?.artifactPath != nil
                ),
                remoteJobId: latestRemoteJobId,
                failureReason: nil
            )
            loadRecords(scheduleRemoteResume: false)
            return latestRemoteJobId
        } catch {
            return normalizedCurrentRemoteJobId
        }
    }

    private func runRemoteBuild(for recordId: UUID, sourceVideoURL: URL, allowLocalFallback: Bool) async {
        let frameSamplingProfile = selectedFrameSamplingProfile(for: recordId)
        let runner = PipelineRunner(backend: preferredRemoteBackend)
        let request = BuildRequest(
            source: .file(url: sourceVideoURL),
            requestedMode: .enter,
            deviceTier: DeviceTier.current(),
            frameSamplingProfile: frameSamplingProfile,
            processingBackend: .cloud
        )

        let result = await runner.runGenerate(request: request, clientRecordId: recordId) { [weak self] snapshot in
            await MainActor.run {
                self?.updateRecordFromProgress(recordId: recordId, snapshot: snapshot)
            }
        }

        switch result {
        case .success(let artifact, _):
            completeRecord(recordId: recordId, artifact: artifact)
        case .fail(let reason, _):
            if allowLocalFallback {
                store.updateProcessingState(
                    recordId: recordId,
                    status: .localFallback,
                    statusMessage: "远端不可用，正在切到本地处理",
                    detailMessage: "这次会退回到手机本地导出。",
                    progressFraction: 0.82,
                    estimatedRemainingMinutes: nil,
                    failureReason: reason.rawValue
                )
                loadRecords(scheduleRemoteResume: false)
            } else {
                failRecord(
                    recordId: recordId,
                    reason: reason,
                    detailOverride: store.record(id: recordId)?.detailMessage
                )
            }
        }
    }

    private func runObjectFastPublishBuild(for recordId: UUID, sourceVideoURL: URL) async {
        let broker = BackgroundUploadBrokerClient.shared

        do {
            let jobId = try await broker.createJobAndUpload(
                videoURL: sourceVideoURL,
                clientRecordId: recordId,
                captureOrigin: "object_mode_v2",
                pipelineProfile: objectFastPublishPipelineProfile()
            ) { [weak self] progress in
                await MainActor.run {
                    self?.store.updateProcessingState(
                        recordId: recordId,
                        status: .uploading,
                        statusMessage: progress.isFinalizing ? "正在确认上传" : "正在上传对象素材",
                        detailMessage: progress.isFinalizing
                            ? "所有分片已发送，正在等远端确认并排队。"
                            : "新远端对象模式正在上传素材，并准备 HQ 成品。",
                        progressFraction: min(max(progress.fraction ?? 0.02, 0.02), 0.16),
                        progressBasis: progress.isFinalizing ? "upload_finalizing" : "uploading",
                        remoteStageKey: "uploading",
                        runtimeMetrics: self?.objectFastPublishRuntimeMetrics(
                            stageKey: "uploading",
                            detail: progress.isFinalizing ? "upload_finalizing" : "uploading_source",
                            remoteJobId: nil,
                            defaultArtifactReady: false
                        ),
                        uploadedBytes: progress.uploadedBytes,
                        totalBytes: progress.totalBytes,
                        estimatedRemainingMinutes: nil,
                        remoteJobId: nil
                    )
                    self?.loadRecords(scheduleRemoteResume: false)
                }
            }

            store.updateProcessingState(
                recordId: recordId,
                status: .queued,
                statusMessage: "远端已接收任务",
                detailMessage: "HQ 成品正在排队并准备处理。",
                progressFraction: 0.18,
                progressBasis: "queued",
                remoteStageKey: "queued",
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "queued",
                    detail: "queued_for_worker",
                    remoteJobId: jobId,
                    defaultArtifactReady: false
                ),
                remoteJobId: jobId
            )
            loadRecords(scheduleRemoteResume: false)

            await resumeObjectFastPublishBuild(for: recordId, jobId: jobId)
        } catch {
            store.updateProcessingState(
                recordId: recordId,
                status: .failed,
                statusMessage: "新远端生成失败",
                detailMessage: error.localizedDescription,
                progressFraction: store.record(id: recordId)?.displayProgressFraction,
                progressBasis: "failed",
                remoteStageKey: "failed",
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "failed",
                    detail: error.localizedDescription,
                    remoteJobId: store.record(id: recordId)?.remoteJobId,
                    defaultArtifactReady: false
                ),
                failureReason: "object_fast_publish_failed"
            )
            loadRecords(scheduleRemoteResume: false)
        }
    }

    private func resumeRemoteBuild(for recordId: UUID, jobId: String) async {
        let runner = PipelineRunner(backend: preferredRemoteBackend)
        let result = await runner.resumeGenerate(jobId: jobId) { [weak self] snapshot in
            await MainActor.run {
                self?.updateRecordFromProgress(recordId: recordId, snapshot: snapshot)
            }
        }

        switch result {
        case .success(let artifact, _):
            completeRecord(recordId: recordId, artifact: artifact)
        case .fail(let reason, _):
            failRecord(recordId: recordId, reason: reason, detailOverride: store.record(id: recordId)?.detailMessage)
        }
    }

    private func resumeObjectFastPublishBuild(for recordId: UUID, jobId: String) async {
        let broker = BackgroundUploadBrokerClient.shared
        var transientPollFailures = 0
        var defaultArtifactReady = store.record(id: recordId)?.artifactPath != nil
        let requiredConfirmedRemoteFailurePolls = 3
        var consecutiveRemoteFailedPolls = 0
        var lastObservedRemoteFailureReason: String?

        while true {
            guard shouldAcceptObjectFastPublishUpdate(recordId: recordId, jobId: jobId) else {
                return
            }
            let status: JobStatus
            do {
                status = try await broker.pollStatus(jobId: jobId)
                transientPollFailures = 0
            } catch {
                guard shouldAcceptObjectFastPublishUpdate(recordId: recordId, jobId: jobId) else {
                    return
                }
                transientPollFailures += 1
                if transientPollFailures <= 12 {
                    store.updateProcessingState(
                        recordId: recordId,
                        status: .reconstructing,
                        statusMessage: "正在重新连接远端状态",
                        detailMessage: "网络短暂波动，系统正在继续拉取新远端任务状态。",
                        progressFraction: max(store.record(id: recordId)?.displayProgressFraction ?? 0.12, 0.12),
                        progressBasis: "network_retry",
                        remoteStageKey: "network_retry",
                        runtimeMetrics: objectFastPublishRuntimeMetrics(
                            stageKey: "network_retry",
                            detail: "retrying_status_poll",
                            remoteJobId: jobId,
                            defaultArtifactReady: defaultArtifactReady
                        ),
                        remoteJobId: jobId
                    )
                    loadRecords(scheduleRemoteResume: false)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                store.updateProcessingState(
                    recordId: recordId,
                    status: .failed,
                    statusMessage: "新远端状态拉取失败",
                    detailMessage: error.localizedDescription,
                    progressFraction: store.record(id: recordId)?.displayProgressFraction,
                    progressBasis: "failed",
                    remoteStageKey: "failed",
                    runtimeMetrics: objectFastPublishRuntimeMetrics(
                        stageKey: "failed",
                        detail: error.localizedDescription,
                        remoteJobId: jobId,
                        defaultArtifactReady: defaultArtifactReady
                    ),
                    remoteJobId: jobId,
                    failureReason: "object_fast_publish_poll_failed"
                )
                loadRecords(scheduleRemoteResume: false)
                return
            }

            guard shouldAcceptObjectFastPublishUpdate(recordId: recordId, jobId: jobId) else {
                return
            }
            switch status {
            case .pending(let progress), .processing(let progress):
                consecutiveRemoteFailedPolls = 0
                lastObservedRemoteFailureReason = nil
                persistObjectFastPublishProgress(
                    recordId: recordId,
                    remoteJobId: jobId,
                    progress: progress,
                    defaultArtifactReady: defaultArtifactReady
                )
            case .downloadReady(let progress):
                consecutiveRemoteFailedPolls = 0
                lastObservedRemoteFailureReason = nil
                if !defaultArtifactReady {
                    do {
                        let bundle = try await broker.downloadObjectModeViewerBundle(jobId: jobId)
                        guard shouldAcceptObjectFastPublishUpdate(recordId: recordId, jobId: jobId) else {
                            return
                        }
                        let persistedBundle = try persistObjectFastPublishViewerBundle(
                            bundle,
                            recordId: recordId
                        )
                        persistObjectFastPublishDefaultReady(
                            recordId: recordId,
                            remoteJobId: jobId,
                            progress: progress,
                            artifactPath: persistedBundle.defaultArtifactRelativePath,
                            viewerManifestPath: persistedBundle.localManifestRelativePath,
                            comparisonAssetPath: persistedBundle.localComparisonAssetPath,
                            comparisonMetricsPath: persistedBundle.localComparisonMetricsPath
                        )
                        defaultArtifactReady = true
                    } catch {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .failed,
                            statusMessage: "HQ 成品下载失败",
                            detailMessage: error.localizedDescription,
                            progressFraction: progress.progressFraction ?? store.record(id: recordId)?.displayProgressFraction,
                            progressBasis: progress.progressBasis,
                            remoteStageKey: progress.stageKey,
                            remotePhaseName: progress.phaseName,
                            currentTier: progress.currentTier,
                            runtimeMetrics: objectFastPublishRuntimeMetrics(
                                stageKey: progress.stageKey,
                                detail: error.localizedDescription,
                                remoteJobId: jobId,
                                defaultArtifactReady: false,
                                remoteMetrics: progress.runtimeMetrics
                            ),
                            remoteJobId: jobId,
                            failureReason: "object_fast_publish_default_download_failed"
                        )
                        loadRecords(scheduleRemoteResume: false)
                        return
                    }
                } else {
                    persistObjectFastPublishProgress(
                        recordId: recordId,
                        remoteJobId: jobId,
                        progress: progress,
                        defaultArtifactReady: true
                    )
                }
            case .completed(let progress):
                consecutiveRemoteFailedPolls = 0
                lastObservedRemoteFailureReason = nil
                do {
                    let relativePath: String
                    let viewerManifestPath: String?
                    let comparisonAssetPath: String?
                    let comparisonMetricsPath: String?
                    let hqAssetPath: String?
                    let bundle = try await broker.downloadObjectModeViewerBundle(jobId: jobId)
                    guard shouldAcceptObjectFastPublishUpdate(recordId: recordId, jobId: jobId) else {
                        return
                    }
                    let persistedBundle = try persistObjectFastPublishViewerBundle(
                        bundle,
                        recordId: recordId
                    )
                    relativePath = persistedBundle.defaultArtifactRelativePath
                    viewerManifestPath = persistedBundle.localManifestRelativePath
                    comparisonAssetPath = persistedBundle.localComparisonAssetPath
                    comparisonMetricsPath = persistedBundle.localComparisonMetricsPath
                    hqAssetPath = persistedBundle.localHQArtifactPath
                    persistObjectFastPublishCompleted(
                        recordId: recordId,
                        remoteJobId: jobId,
                        progress: progress,
                        artifactPath: relativePath,
                        viewerManifestPath: viewerManifestPath,
                        comparisonAssetPath: comparisonAssetPath,
                        comparisonMetricsPath: comparisonMetricsPath,
                        hqAssetPath: hqAssetPath,
                        inspectionOnly: persistedBundle.inspectionOnly,
                        hqPassed: persistedBundle.hqPassed,
                        failedCards: persistedBundle.failedCards
                    )
                } catch {
                    store.updateProcessingState(
                        recordId: recordId,
                        status: .failed,
                        statusMessage: "HQ 成品回传失败",
                        detailMessage: error.localizedDescription,
                        progressFraction: progress?.progressFraction ?? store.record(id: recordId)?.displayProgressFraction,
                        progressBasis: progress?.progressBasis,
                        remoteStageKey: progress?.stageKey,
                        remotePhaseName: progress?.phaseName,
                        currentTier: progress?.currentTier,
                        runtimeMetrics: objectFastPublishRuntimeMetrics(
                            stageKey: progress?.stageKey,
                            detail: error.localizedDescription,
                            remoteJobId: jobId,
                            defaultArtifactReady: defaultArtifactReady,
                            remoteMetrics: progress?.runtimeMetrics ?? [:]
                        ),
                        remoteJobId: jobId,
                        failureReason: "object_fast_publish_complete_download_failed"
                    )
                    loadRecords(scheduleRemoteResume: false)
                }
                return
            case .failed(let reason, let progress):
                let normalizedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if lastObservedRemoteFailureReason == normalizedReason {
                    consecutiveRemoteFailedPolls += 1
                } else {
                    lastObservedRemoteFailureReason = normalizedReason
                    consecutiveRemoteFailedPolls = 1
                }

                if consecutiveRemoteFailedPolls < requiredConfirmedRemoteFailurePolls {
                    if let progress {
                        persistObjectFastPublishProgress(
                            recordId: recordId,
                            remoteJobId: jobId,
                            progress: progress,
                            defaultArtifactReady: defaultArtifactReady
                        )
                    } else {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .reconstructing,
                            statusMessage: "正在确认远端状态",
                            detailMessage: "远端短暂返回失败状态，系统正在再次确认任务是否仍在继续。",
                            progressFraction: max(store.record(id: recordId)?.displayProgressFraction ?? 0.12, 0.12),
                            progressBasis: "remote_failure_pending",
                            remoteStageKey: "remote_failure_pending",
                            runtimeMetrics: objectFastPublishRuntimeMetrics(
                                stageKey: "remote_failure_pending",
                                detail: normalizedReason,
                                remoteJobId: jobId,
                                defaultArtifactReady: defaultArtifactReady
                            ),
                            remoteJobId: jobId
                        )
                        loadRecords(scheduleRemoteResume: false)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                if isHQGateFailure(normalizedReason) {
                    do {
                        let persistedBundle = try persistObjectFastPublishViewerBundle(
                            try await broker.downloadObjectModeViewerBundle(jobId: jobId),
                            recordId: recordId
                        )
                        guard shouldAcceptObjectFastPublishUpdate(recordId: recordId, jobId: jobId) else {
                            return
                        }
                        store.updateArtifactPath(
                            recordId: recordId,
                            artifactPath: persistedBundle.defaultArtifactRelativePath
                        )
                        let failedCards = resolvedHQFailedCards(
                            manifestCards: persistedBundle.failedCards,
                            failureReason: normalizedReason
                        )
                        let detailMessage = inspectionOnlyDetailMessage(for: failedCards)
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .failed,
                            statusMessage: "未达 HQ，仅供质检",
                            detailMessage: detailMessage,
                            progressFraction: progress?.progressFraction ?? store.record(id: recordId)?.displayProgressFraction,
                            progressBasis: progress?.progressBasis,
                            remoteStageKey: progress?.stageKey,
                            remotePhaseName: progress?.phaseName,
                            currentTier: progress?.currentTier,
                            runtimeMetrics: objectFastPublishRuntimeMetrics(
                                stageKey: progress?.stageKey,
                                detail: detailMessage,
                                remoteJobId: jobId,
                                defaultArtifactReady: true,
                                remoteMetrics: progress?.runtimeMetrics ?? [:],
                                localViewerManifestPath: persistedBundle.localManifestRelativePath,
                                localComparisonAssetPath: persistedBundle.localComparisonAssetPath,
                                localComparisonMetricsPath: persistedBundle.localComparisonMetricsPath,
                                localHQArtifactPath: persistedBundle.localHQArtifactPath,
                                inspectionOnly: true,
                                hqPassed: false,
                                failedCards: failedCards
                            ),
                            remoteJobId: jobId,
                            failureReason: normalizedReason
                        )
                        loadRecords(scheduleRemoteResume: false)
                    } catch {
                        store.updateProcessingState(
                            recordId: recordId,
                            status: .failed,
                            statusMessage: "候选结果回传失败",
                            detailMessage: error.localizedDescription,
                            progressFraction: progress?.progressFraction ?? store.record(id: recordId)?.displayProgressFraction,
                            progressBasis: progress?.progressBasis,
                            remoteStageKey: progress?.stageKey,
                            remotePhaseName: progress?.phaseName,
                            currentTier: progress?.currentTier,
                            runtimeMetrics: objectFastPublishRuntimeMetrics(
                                stageKey: progress?.stageKey,
                                detail: error.localizedDescription,
                                remoteJobId: jobId,
                                defaultArtifactReady: false,
                                remoteMetrics: progress?.runtimeMetrics ?? [:]
                            ),
                            remoteJobId: jobId,
                            failureReason: "object_fast_publish_candidate_download_failed"
                        )
                        loadRecords(scheduleRemoteResume: false)
                    }
                    return
                }

                store.updateProcessingState(
                    recordId: recordId,
                    status: .failed,
                    statusMessage: "新远端生成失败",
                    detailMessage: normalizedReason,
                    progressFraction: progress?.progressFraction ?? store.record(id: recordId)?.displayProgressFraction,
                    progressBasis: progress?.progressBasis,
                    remoteStageKey: progress?.stageKey,
                    remotePhaseName: progress?.phaseName,
                    currentTier: progress?.currentTier,
                    runtimeMetrics: objectFastPublishRuntimeMetrics(
                        stageKey: progress?.stageKey,
                        detail: normalizedReason,
                        remoteJobId: jobId,
                        defaultArtifactReady: defaultArtifactReady,
                        remoteMetrics: progress?.runtimeMetrics ?? [:]
                    ),
                    remoteJobId: jobId,
                    failureReason: "object_fast_publish_failed"
                )
                loadRecords(scheduleRemoteResume: false)
                return
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func shouldAcceptObjectFastPublishUpdate(recordId: UUID, jobId: String) -> Bool {
        let normalizedJobId = jobId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedJobId.isEmpty else { return false }
        let currentRemoteJobId = store.record(id: recordId)?
            .remoteJobId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return currentRemoteJobId == normalizedJobId
    }

    private func isObjectFastPublishRecord(_ record: ScanRecord) -> Bool {
        record.isObjectFastPublishV1
    }

    private func objectFastPublishPipelineProfile() -> [String: String] {
        [
            "strategy": "object_slam3r_surface_v1",
            "capture_mode": "guided_object",
            "artifact_contract_version": "object_publish_v1",
            "first_result_kind": "hq_mesh_glb",
            "hq_refine": "disabled",
            "optional_mesh_export": "disabled",
            "target_zone_mode": "subject",
        ]
    }

    private func objectFastPublishRuntimeMetrics(
        stageKey: String?,
        detail: String?,
        remoteJobId: String?,
        defaultArtifactReady: Bool,
        remoteMetrics: [String: String] = [:],
        localViewerManifestPath: String? = nil,
        localComparisonAssetPath: String? = nil,
        localComparisonMetricsPath: String? = nil,
        localHQArtifactPath: String? = nil,
        inspectionOnly: Bool? = nil,
        hqPassed: Bool? = nil,
        failedCards: [String] = []
    ) -> [String: String] {
        var metrics = remoteMetrics
        metrics["pipeline_strategy"] = "object_slam3r_surface_v1"
        metrics["artifact_contract_version"] = "object_publish_v1"
        metrics["first_result_kind"] = "hq_mesh_glb"
        metrics["hq_refine"] = "disabled"
        metrics["optional_mesh_export"] = "disabled"
        metrics["default_artifact_ready"] = defaultArtifactReady ? "true" : "false"
        if let inspectionOnly {
            metrics["inspection_only_candidate"] = inspectionOnly ? "true" : "false"
        }
        if let hqPassed {
            metrics["hq_passed"] = hqPassed ? "true" : "false"
        }
        if !failedCards.isEmpty {
            metrics["hq_failed_cards"] = failedCards.joined(separator: ",")
        }
        if let stageKey, !stageKey.isEmpty {
            metrics["remote_stage_key"] = stageKey
        }
        if let detail, !detail.isEmpty {
            metrics["remote_detail"] = detail
        }
        if let remoteJobId, !remoteJobId.isEmpty {
            metrics["remote_job_id"] = remoteJobId
        }
        if let localViewerManifestPath, !localViewerManifestPath.isEmpty {
            metrics["local_viewer_manifest_path"] = localViewerManifestPath
        }
        if let localComparisonAssetPath, !localComparisonAssetPath.isEmpty {
            metrics["local_comparison_asset_path"] = localComparisonAssetPath
        }
        if let localComparisonMetricsPath, !localComparisonMetricsPath.isEmpty {
            metrics["local_comparison_metrics_path"] = localComparisonMetricsPath
        }
        if let localHQArtifactPath, !localHQArtifactPath.isEmpty {
            metrics["local_hq_asset_path"] = localHQArtifactPath
        }
        return metrics
    }

    private func isHQGateFailure(_ reason: String) -> Bool {
        reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("hq_gate_failed")
    }

    private func resolvedHQFailedCards(manifestCards: [String], failureReason: String) -> [String] {
        if !manifestCards.isEmpty {
            return manifestCards
        }
        let normalized = failureReason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let separator = normalized.firstIndex(of: ":") else {
            return []
        }
        return normalized[normalized.index(after: separator)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func inspectionOnlyDetailMessage(for failedCards: [String]) -> String {
        if failedCards.isEmpty {
            return "候选结果已生成，但未达 HQ，仅供质检。"
        }
        let labels = failedCards.map(Self.hqFailedCardLabel).joined(separator: "、")
        return "候选结果已生成，但未达 HQ，仅供质检。未通过：\(labels)。"
    }

    private static func hqFailedCardLabel(_ rawCard: String) -> String {
        switch rawCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "geometry_hq":
            return "几何"
        case "texture_hq":
            return "贴图"
        case "open_surface_hq":
            return "开放表面"
        case "hole_fill_hq":
            return "补洞克制"
        case "mesh_fidelity_hq":
            return "网格保真"
        default:
            return rawCard
        }
    }

    private func objectFastPublishStatus(for progress: RemoteJobProgress, defaultArtifactReady: Bool) -> ScanRecordStatus {
        let stageKey = progress.stageKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch stageKey {
        case "uploading":
            return .uploading
        case "queued":
            return .queued
        case "curate", "slam3r_reconstruct", "slam3r_scene_contract":
            return .reconstructing
        case "sparse2dgs_surface":
            return .training
        case "matcha_mesh_extract", "optimize_default_mesh", "bake_default_texture", "publish_default_mesh", "artifact_upload":
            return .packaging
        case "downloading":
            return .downloading
        default:
            return defaultArtifactReady ? .packaging : .reconstructing
        }
    }

    private func persistObjectFastPublishProgress(
        recordId: UUID,
        remoteJobId: String,
        progress: RemoteJobProgress,
        defaultArtifactReady: Bool
    ) {
        let existingMetrics = store.record(id: recordId)?.runtimeMetrics
        let status = objectFastPublishStatus(for: progress, defaultArtifactReady: defaultArtifactReady)
        let detailSuffix = defaultArtifactReady ? "HQ 成品已可打开。" : nil
        let detail: String? = {
            let base = progress.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let base, !base.isEmpty, let detailSuffix {
                return "\(base) \(detailSuffix)"
            }
            if let base, !base.isEmpty {
                return base
            }
            return detailSuffix
        }()

        store.updateProcessingState(
            recordId: recordId,
            status: status,
            statusMessage: progress.title ?? "正在生成 HQ 成品",
            detailMessage: detail,
            progressFraction: progress.progressFraction,
            progressBasis: progress.progressBasis,
            remoteStageKey: progress.stageKey,
            remotePhaseName: progress.phaseName,
            currentTier: progress.currentTier,
            runtimeMetrics: objectFastPublishRuntimeMetrics(
                stageKey: progress.stageKey,
                detail: progress.detail,
                remoteJobId: remoteJobId,
                defaultArtifactReady: defaultArtifactReady,
                remoteMetrics: progress.runtimeMetrics,
                localViewerManifestPath: existingMetrics?["local_viewer_manifest_path"],
                localComparisonAssetPath: existingMetrics?["local_comparison_asset_path"],
                localComparisonMetricsPath: existingMetrics?["local_comparison_metrics_path"]
            ),
            estimatedRemainingMinutes: progress.etaMinutes,
            remoteJobId: remoteJobId
        )
        loadRecords(scheduleRemoteResume: false)
    }

    private func persistObjectFastPublishDefaultReady(
        recordId: UUID,
        remoteJobId: String,
        progress: RemoteJobProgress,
        artifactPath: String,
        viewerManifestPath: String?,
        comparisonAssetPath: String?,
        comparisonMetricsPath: String?
    ) {
        guard var record = store.record(id: recordId) else { return }
        let now = Date()
        record.artifactPath = artifactPath
        record.remoteJobId = remoteJobId
        record.status = .packaging
        record.statusMessage = progress.title ?? "HQ 成品已就绪"
        record.detailMessage = "HQ 成品已下载，可从首页打开。"
        record.progressFraction = max(progress.progressFraction ?? 0.92, 0.92)
        record.progressBasis = progress.progressBasis
        record.remoteStageKey = progress.stageKey
        record.remotePhaseName = progress.phaseName
        record.currentTier = progress.currentTier
        record.runtimeMetrics = objectFastPublishRuntimeMetrics(
            stageKey: progress.stageKey,
            detail: progress.detail,
            remoteJobId: remoteJobId,
            defaultArtifactReady: true,
            remoteMetrics: progress.runtimeMetrics,
            localViewerManifestPath: viewerManifestPath,
            localComparisonAssetPath: comparisonAssetPath,
            localComparisonMetricsPath: comparisonMetricsPath,
            localHQArtifactPath: nil
        )
        record.processingStartedAt = record.processingStartedAt ?? record.createdAt
        record.processingCompletedAt = nil
        record.processingElapsedSeconds = now.timeIntervalSince(record.processingStartedAt ?? record.createdAt)
        record.updatedAt = now
        store.saveRecord(record)
        loadRecords(scheduleRemoteResume: false)
    }

    private func persistObjectFastPublishCompleted(
        recordId: UUID,
        remoteJobId: String,
        progress: RemoteJobProgress?,
        artifactPath: String,
        viewerManifestPath: String?,
        comparisonAssetPath: String?,
        comparisonMetricsPath: String?,
        hqAssetPath: String?,
        inspectionOnly: Bool,
        hqPassed: Bool,
        failedCards: [String]
    ) {
        guard var record = store.record(id: recordId) else { return }
        let now = Date()
        let startedAt = record.processingStartedAt ?? record.createdAt
        record.artifactPath = artifactPath
        record.remoteJobId = nil
        record.status = .completed
        if inspectionOnly {
            record.statusMessage = "未达 HQ，仅供质检"
            record.detailMessage = inspectionOnlyDetailMessage(for: failedCards)
        } else {
            record.statusMessage = "HQ 成品已完成"
            record.detailMessage = progress?.detail ?? "HQ 成品已完成，可从首页直接打开。"
        }
        record.progressFraction = 1.0
        record.progressBasis = progress?.progressBasis
        record.remoteStageKey = progress?.stageKey
        record.remotePhaseName = progress?.phaseName
        record.currentTier = progress?.currentTier
        record.runtimeMetrics = objectFastPublishRuntimeMetrics(
            stageKey: progress?.stageKey,
            detail: progress?.detail,
            remoteJobId: remoteJobId,
            defaultArtifactReady: true,
            remoteMetrics: progress?.runtimeMetrics ?? [:],
            localViewerManifestPath: viewerManifestPath,
            localComparisonAssetPath: comparisonAssetPath,
            localComparisonMetricsPath: comparisonMetricsPath,
            localHQArtifactPath: hqAssetPath,
            inspectionOnly: inspectionOnly,
            hqPassed: hqPassed,
            failedCards: failedCards
        )
        record.processingStartedAt = startedAt
        record.processingCompletedAt = now
        record.processingElapsedSeconds = max(0, now.timeIntervalSince(startedAt))
        record.updatedAt = now
        record.failureReason = nil
        store.saveRecord(record)
        loadRecords(scheduleRemoteResume: false)
    }

    private func performObjectFastPublishReimport(_ sourceRecord: ScanRecord) async {
        let latestSource = store.record(id: sourceRecord.id) ?? sourceRecord
        guard canReimportObjectFastPublishResult(latestSource) else {
            errorMessage = "这条作品暂时没有可重新导入的远端结果。"
            return
        }
        guard let remoteJobId = resolvedObjectFastPublishRemoteJobId(for: latestSource) else {
            errorMessage = "找不到这条作品的远端任务号，暂时无法重新导入。"
            return
        }

        isImportingVideo = true
        busyMessage = "正在从远端重新导入对比结果..."
        errorMessage = nil

        do {
            let bundle = try await BackgroundUploadBrokerClient.shared.downloadObjectModeViewerBundle(jobId: remoteJobId)
            let newRecordId = UUID()
            let persistedBundle = try persistObjectFastPublishViewerBundle(bundle, recordId: newRecordId)
            let duplicatedThumbnailPath = duplicateThumbnail(
                relativePath: latestSource.thumbnailPath,
                for: newRecordId
            )
            persistImportedObjectFastPublishComparison(
                sourceRecord: latestSource,
                newRecordId: newRecordId,
                remoteJobId: remoteJobId,
                artifactPath: persistedBundle.defaultArtifactRelativePath,
                viewerManifestPath: persistedBundle.localManifestRelativePath,
                comparisonAssetPath: persistedBundle.localComparisonAssetPath,
                comparisonMetricsPath: persistedBundle.localComparisonMetricsPath,
                hqAssetPath: persistedBundle.localHQArtifactPath,
                thumbnailPath: duplicatedThumbnailPath
            )
            busyMessage = nil
            isImportingVideo = false
        } catch {
            busyMessage = nil
            isImportingVideo = false
            errorMessage = "远端结果重新导入失败：\(error.localizedDescription)"
        }
    }

    private func persistImportedObjectFastPublishComparison(
        sourceRecord: ScanRecord,
        newRecordId: UUID,
        remoteJobId: String,
        artifactPath: String,
        viewerManifestPath: String?,
        comparisonAssetPath: String?,
        comparisonMetricsPath: String?,
        hqAssetPath: String?,
        thumbnailPath: String?
    ) {
        let now = Date()
        let startedAt = sourceRecord.processingStartedAt ?? sourceRecord.createdAt
        let completedAt = sourceRecord.processingCompletedAt ?? now
        let elapsed = sourceRecord.processingElapsedSeconds
            ?? max(0, completedAt.timeIntervalSince(startedAt))

        var remoteMetrics = sanitizedRuntimeMetricsForImportedObjectFastPublishComparison(
            sourceRecord.runtimeMetrics
        )
        remoteMetrics["reimport_source_record_id"] = sourceRecord.id.uuidString
        remoteMetrics["reimport_kind"] = "remote_comparison_copy"

        let runtimeMetrics = objectFastPublishRuntimeMetrics(
            stageKey: sourceRecord.remoteStageKey,
            detail: "remote_comparison_copy",
            remoteJobId: remoteJobId,
            defaultArtifactReady: true,
            remoteMetrics: remoteMetrics,
            localViewerManifestPath: viewerManifestPath,
            localComparisonAssetPath: comparisonAssetPath,
            localComparisonMetricsPath: comparisonMetricsPath,
            localHQArtifactPath: hqAssetPath
        )

        let importedRecord = ScanRecord(
            id: newRecordId,
            name: importedComparisonRecordName(from: sourceRecord.name),
            createdAt: now,
            updatedAt: now,
            thumbnailPath: thumbnailPath,
            artifactPath: artifactPath,
            sourceVideoPath: nil,
            remoteJobId: nil,
            frameSamplingProfile: sourceRecord.frameSamplingProfile,
            captureIntent: sourceRecord.captureIntent,
            processingBackend: sourceRecord.processingBackend,
            coveragePercentage: sourceRecord.coveragePercentage,
            triangleCount: sourceRecord.triangleCount,
            durationSeconds: sourceRecord.durationSeconds,
            processingStartedAt: startedAt,
            processingCompletedAt: completedAt,
            processingElapsedSeconds: elapsed,
            status: .completed,
            statusMessage: "远端对比卡片已导入",
            detailMessage: "这是从远端重新导入的对比副本，可和原作品对照查看。",
            progressFraction: 1.0,
            progressBasis: sourceRecord.progressBasis,
            remoteStageKey: sourceRecord.remoteStageKey,
            remotePhaseName: sourceRecord.remotePhaseName,
            currentTier: sourceRecord.currentTier,
            runtimeMetrics: runtimeMetrics,
            estimatedRemainingMinutes: 0,
            failureReason: nil,
            viewerInitialPose: sourceRecord.viewerInitialPose,
            captureGravityUpX: sourceRecord.captureGravityUpX,
            captureGravityUpY: sourceRecord.captureGravityUpY,
            captureGravityUpZ: sourceRecord.captureGravityUpZ,
            captureGravitySource: sourceRecord.captureGravitySource,
            captureGravityConfidence: sourceRecord.captureGravityConfidence
        )

        store.saveRecord(importedRecord)
        loadRecords(scheduleRemoteResume: false)
    }

    private func persistObjectFastPublishArtifactFile(_ artifactURL: URL, recordId: UUID) throws -> String {
        let exportsDirectory = store.baseDirectoryURL().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let pathExtension = artifactURL.pathExtension.isEmpty ? "glb" : artifactURL.pathExtension.lowercased()
        let targetURL = exportsDirectory.appendingPathComponent("\(recordId.uuidString).\(pathExtension)")
        if artifactURL.standardizedFileURL.path == targetURL.standardizedFileURL.path {
            return "exports/\(targetURL.lastPathComponent)"
        }
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.copyItem(at: artifactURL, to: targetURL)
        return "exports/\(targetURL.lastPathComponent)"
    }

    private func persistObjectFastPublishViewerBundle(
        _ bundle: BrokerDownloadedObjectModeViewerBundle,
        recordId: UUID
    ) throws -> HomePersistedObjectModeViewerBundle {
        let exportsDirectory = store.baseDirectoryURL().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

        func copyArtifact(_ sourceURL: URL, fileName: String) throws -> URL {
            let destinationURL = exportsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }

        let defaultExtension = bundle.defaultArtifact.localURL.pathExtension.isEmpty ? "ply" : bundle.defaultArtifact.localURL.pathExtension.lowercased()
        let defaultDestinationURL = try copyArtifact(
            bundle.defaultArtifact.localURL,
            fileName: "\(recordId.uuidString).\(defaultExtension)"
        )

        var cleanedRelativePath: String?
        if let comparisonArtifact = bundle.comparisonArtifact {
            let cleanedExtension = comparisonArtifact.localURL.pathExtension.isEmpty ? "ply" : comparisonArtifact.localURL.pathExtension.lowercased()
            let cleanedURL = try copyArtifact(
                comparisonArtifact.localURL,
                fileName: "\(recordId.uuidString).cleanup.\(cleanedExtension)"
            )
            cleanedRelativePath = "exports/\(cleanedURL.lastPathComponent)"
        }

        var compareMetricsRelativePath: String?
        if let comparisonMetrics = bundle.comparisonMetrics {
            let compareExtension = comparisonMetrics.localURL.pathExtension.isEmpty ? "json" : comparisonMetrics.localURL.pathExtension.lowercased()
            let compareURL = try copyArtifact(
                comparisonMetrics.localURL,
                fileName: "\(recordId.uuidString).cleanup_compare.\(compareExtension)"
            )
            compareMetricsRelativePath = "exports/\(compareURL.lastPathComponent)"
        }

        var hqRelativePath: String?
        if let hqArtifact = bundle.hqArtifact {
            let hqExtension = hqArtifact.localURL.pathExtension.isEmpty ? "splat" : hqArtifact.localURL.pathExtension.lowercased()
            let hqURL = try copyArtifact(
                hqArtifact.localURL,
                fileName: "\(recordId.uuidString).hq.\(hqExtension)"
            )
            hqRelativePath = "exports/\(hqURL.lastPathComponent)"
        }

        var remoteManifestPayload: [String: Any] = [:]
        if let remoteManifest = bundle.viewerManifest,
           let data = try? Data(contentsOf: remoteManifest.localURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            remoteManifestPayload = payload
        }

        let inspectionOnly = (remoteManifestPayload["inspection_only"] as? Bool) ?? false
        let hqPassed = (remoteManifestPayload["hq_passed"] as? Bool) ?? !inspectionOnly
        let failedCards = (remoteManifestPayload["failed_cards"] as? [String]) ?? []

        var localManifestPayload: [String: Any] = [
            "version": remoteManifestPayload["version"] ?? "object_publish_v1",
            "product_mode": remoteManifestPayload["product_mode"] ?? "hq_only",
            "primary_product": remoteManifestPayload["primary_product"] ?? "hq_mesh_glb",
            "inspection_only": inspectionOnly,
            "hq_passed": hqPassed,
            "failed_cards": failedCards,
            "default_asset": [
                "kind": bundle.defaultArtifact.format,
                "path": defaultDestinationURL.lastPathComponent,
                "ready": true,
            ],
        ]
        if let cleanedRelativePath {
            localManifestPayload["cleaned_asset"] = [
                "kind": bundle.comparisonArtifact?.format ?? "ply",
                "path": URL(fileURLWithPath: cleanedRelativePath).lastPathComponent,
                "ready": true,
            ]
        }
        if let compareMetricsRelativePath {
            localManifestPayload["cleanup_compare"] = [
                "kind": "json",
                "path": URL(fileURLWithPath: compareMetricsRelativePath).lastPathComponent,
                "ready": true,
            ]
        }
        if let hqRelativePath {
            localManifestPayload["hq_asset"] = [
                "kind": bundle.hqArtifact?.format ?? "splat",
                "path": URL(fileURLWithPath: hqRelativePath).lastPathComponent,
                "ready": true,
            ]
        }
        if let cameraPreset = remoteManifestPayload["camera_preset"] {
            localManifestPayload["camera_preset"] = cameraPreset
        }
        if let supportPatchBounds = remoteManifestPayload["support_patch_bounds"] {
            localManifestPayload["support_patch_bounds"] = supportPatchBounds
        }

        let localManifestURL = exportsDirectory.appendingPathComponent("\(recordId.uuidString).viewer_manifest.json")
        if FileManager.default.fileExists(atPath: localManifestURL.path) {
            try FileManager.default.removeItem(at: localManifestURL)
        }
        let manifestData = try JSONSerialization.data(withJSONObject: localManifestPayload, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: localManifestURL, options: .atomic)

        return HomePersistedObjectModeViewerBundle(
            defaultArtifactRelativePath: "exports/\(defaultDestinationURL.lastPathComponent)",
            localManifestRelativePath: "exports/\(localManifestURL.lastPathComponent)",
            localComparisonAssetPath: cleanedRelativePath,
            localComparisonMetricsPath: compareMetricsRelativePath,
            localHQArtifactPath: hqRelativePath,
            inspectionOnly: inspectionOnly,
            hqPassed: hqPassed,
            failedCards: failedCards
        )
    }

    private func failureDetail(for reason: FailReason) -> String {
        switch reason {
        case .networkTimeout, .timeout:
            return "远端等待超时了。请稍后重试，或者换一个网络环境。"
        case .uploadFailed:
            return "视频上传没有完成，请确认手机网络后重试。"
        case .downloadFailed:
            return "3DGS 已经生成，但回传手机时失败了，请稍后重试。"
        case .stalledProcessing:
            return "远端训练长时间没有推进，已经停止本次任务。"
        case .apiError, .apiNotConfigured:
            return "丹麦 5090 当前不可用，请稍后再试。"
        case .inputInvalid:
            return "这个视频暂时不适合进入白盒流程，请换一个视频再试。"
        case .outOfMemory:
            return "远端显存不足，建议缩短视频或降低复杂度后重试。"
        case .jobTimeout, .invalidResponse, .unknownError:
            return "远端返回了异常结果，请稍后重试。"
        }
    }

    private func resolvedObjectFastPublishRemoteJobId(for record: ScanRecord) -> String? {
        let candidates = [
            record.remoteJobId,
            record.runtimeMetrics?["remote_job_id"]
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func importedComparisonRecordName(from sourceName: String) -> String {
        let trimmed = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "远端对比副本" }
        if trimmed.contains("对比") {
            return "\(trimmed) 副本"
        }
        return "\(trimmed) 对比"
    }

    private func duplicateThumbnail(relativePath: String?, for recordId: UUID) -> String? {
        guard let relativePath,
              !relativePath.isEmpty else {
            return nil
        }
        let sourceURL = store.baseDirectoryURL().appendingPathComponent(relativePath)
        guard let imageData = try? Data(contentsOf: sourceURL) else {
            return nil
        }
        return store.saveThumbnail(imageData, for: recordId)
    }

    private func sanitizedRuntimeMetricsForImportedObjectFastPublishComparison(
        _ runtimeMetrics: [String: String]?
    ) -> [String: String] {
        var cleaned = runtimeMetrics ?? [:]
        let localOnlyKeys = [
            "local_viewer_manifest_path",
            "local_comparison_asset_path",
            "local_comparison_metrics_path",
            "local_hq_asset_path",
            "default_artifact_ready",
        ]
        for key in localOnlyKeys {
            cleaned.removeValue(forKey: key)
        }
        return cleaned
    }

    private func selectedFrameSamplingProfile(for recordId: UUID) -> FrameSamplingProfile {
        if let rawValue = store.record(id: recordId)?.frameSamplingProfile,
           let profile = FrameSamplingProfile(rawValue: rawValue) {
            return profile
        }
        return FrameSamplingProfile.currentSelection()
    }

    private func failureTitle(for reason: FailReason) -> String {
        switch reason {
        case .uploadFailed:
            return "上传已中断"
        case .downloadFailed:
            return "回传到手机时失败了"
        case .networkTimeout, .timeout:
            return "远端等待超时"
        default:
            return "远端生成失败"
        }
    }

    private func status(for stage: GenerateProgressStage) -> ScanRecordStatus {
        switch stage {
        case .preparing:
            return .preparing
        case .uploading:
            return .uploading
        case .queued:
            return .queued
        case .reconstructing:
            return .reconstructing
        case .training:
            return .training
        case .packaging:
            return .packaging
        case .downloading:
            return .downloading
        case .localFallback:
            return .localFallback
        case .completed:
            return .completed
        case .failed:
            return .failed
        }
    }

    #if canImport(AVFoundation)
    private func makeThumbnail(for asset: AVAsset, recordId: UUID) async throws -> String? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let image = try await generateThumbnailImage(generator: generator, time: .zero)
        #if canImport(UIKit)
        let uiImage = UIImage(cgImage: image)
        guard let data = uiImage.jpegData(compressionQuality: 0.82) else {
            return nil
        }
        return store.saveThumbnail(data, for: recordId)
        #else
        return nil
        #endif
    }
    
    private func generateThumbnailImage(
        generator: AVAssetImageGenerator,
        time: CMTime
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "Aether3D.Thumbnail", code: -1))
                }
            }
        }
    }
    #endif
}
