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
                    || self.shouldResumeFailedRemoteRecord(record)
                    || self.shouldResumeCompletedRemoteRecord(record) {
                    self.scheduleRemoteResumeIfNeeded(
                        record,
                        force: self.shouldForceImmediateRemoteResume(record)
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
        store.updateProcessingState(
            recordId: record.id,
            status: .preparing,
            statusMessage: backend.usesLocalPreviewPipeline
                ? "正在重新启动本地处理"
                : "正在重新发起远端训练",
            detailMessage: backend.usesLocalPreviewPipeline
                ? "这次会重新走手机本地处理链路。"
                : "这次会重新走后台上传与远端调度流程。",
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
                await self.runRemoteBuild(for: record.id, sourceVideoURL: sourceURL, allowLocalFallback: false)
            }
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

        let result = await Task.detached(priority: .userInitiated) {
            LocalPreviewImportRunner.execute(
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
        guard record.artifactPath == nil,
              (record.isProcessing || awaitingCancelConfirmation || resumableFailedRemoteRecord || resumableCompletedRemoteRecord),
              let remoteJobId = record.remoteJobId,
              !remoteJobId.isEmpty else {
            return
        }

        let shouldForceResume = force || shouldForceImmediateRemoteResume(record) || resumableCompletedRemoteRecord
        let isStale = Date().timeIntervalSince(record.updatedAt) > 15
        guard shouldForceResume || isStale else { return }
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
            remoteJobId: remoteJobId
        )
        refreshRecord(id: record.id)

        Task {
            await self.resumeRemoteBuild(for: record.id, jobId: remoteJobId)
            await MainActor.run {
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
        guard record.artifactPath == nil,
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
