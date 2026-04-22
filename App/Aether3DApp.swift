// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  Aether3DApp.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import SwiftUI
import Aether3DCore

#if canImport(UIKit)
import UIKit
#endif

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

#if canImport(UIKit) && canImport(BackgroundTasks)
private final class BackgroundTaskCompletionBox: @unchecked Sendable {
    nonisolated(unsafe) private let task: BGTask
    private let lock = NSLock()
    private var completed = false

    init(task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        let shouldComplete = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldComplete else { return }
        task.setTaskCompleted(success: success)
    }
}

@available(iOS 26.0, *)
final class LocalProcessingContinuedTaskCoordinator: @unchecked Sendable {
    static let shared = LocalProcessingContinuedTaskCoordinator()

    private static let totalProgressUnits: Int64 = 1000
    private static let activeProcessingTitle = "Aether3D 正在本地处理"
    private static var taskIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.aether3d.app").local-processing"
    }

    private let lock = NSLock()
    private var registered = false
    private var activeRecordID: UUID?
    private var activeTask: BGContinuedProcessingTask?
    private var taskExpired = false
    private var latestTitle = "Aether3D 正在本地处理"
    private var latestSubtitle = "本地训练继续进行中"
    private var latestCompletedUnits: Int64 = 0

    private init() {}

    static func supportsBackgroundGPUExecution() -> Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    func register() {
        guard !registered else { return }
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.attach(continuedTask)
        }
        registered = didRegister
        if didRegister {
            NSLog("[Aether3D][LocalBG] registered continued processing id=%@", Self.taskIdentifier)
        } else {
            NSLog("[Aether3D][LocalBG] failed to register continued processing id=%@", Self.taskIdentifier)
        }
    }

    func submit(recordId: UUID, scanName: String?) {
        let title = Self.activeProcessingTitle
        let subtitle = Self.normalizedSubtitle(scanName ?? "本地训练继续进行中")
        lock.withLock {
            activeRecordID = recordId
            taskExpired = false
            latestCompletedUnits = 0
            latestTitle = title
            latestSubtitle = subtitle
        }

        // Keep only the current run visible to the system UI instead of
        // accumulating queued historical tasks in the Dynamic Island sheet.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .fail
        let requestBackgroundGPU = Self.supportsBackgroundGPUExecution()
        if requestBackgroundGPU {
            request.requiredResources = .gpu
        }

        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog(
                requestBackgroundGPU
                    ? "[Aether3D][LocalBG] submitted continued processing record=%@ mode=gpu"
                    : "[Aether3D][LocalBG] submitted continued processing record=%@ mode=cpu_only",
                recordId.uuidString
            )
        } catch {
            NSLog(
                "[Aether3D][LocalBG] submit failed record=%@ error=%@",
                recordId.uuidString,
                String(describing: error)
            )
        }
    }

    func update(
        recordId: UUID,
        progressFraction: Double?,
        title: String,
        subtitle: String
    ) {
        let normalizedSubtitle = Self.composedActiveSubtitle(
            phaseTitle: title,
            detail: subtitle
        )
        let completedUnits = Self.completedUnits(for: progressFraction)
        let snapshot = lock.withLock { () -> (BGContinuedProcessingTask?, Int64, String, String)? in
            if activeRecordID == nil {
                activeRecordID = recordId
            }
            guard activeRecordID == recordId else {
                return nil
            }
            latestTitle = Self.activeProcessingTitle
            latestSubtitle = normalizedSubtitle
            latestCompletedUnits = max(latestCompletedUnits, completedUnits)
            return (activeTask, latestCompletedUnits, latestTitle, latestSubtitle)
        }

        guard let snapshot, let task = snapshot.0 else { return }
        task.progress.totalUnitCount = Self.totalProgressUnits
        task.progress.completedUnitCount = snapshot.1
        task.updateTitle(snapshot.2, subtitle: snapshot.3)
    }

    func finish(
        recordId: UUID,
        success: Bool,
        title: String,
        subtitle: String
    ) {
        let normalizedSubtitle = Self.normalizedSubtitle(subtitle)
        let task: BGContinuedProcessingTask? = lock.withLock {
            guard activeRecordID == recordId else {
                return nil
            }
            latestTitle = title
            latestSubtitle = normalizedSubtitle
            latestCompletedUnits = success ? Self.totalProgressUnits : latestCompletedUnits
            let capturedTask = activeTask
            activeTask = nil
            activeRecordID = nil
            taskExpired = false
            return capturedTask
        }

        if let task {
            task.progress.totalUnitCount = Self.totalProgressUnits
            task.progress.completedUnitCount = success
                ? Self.totalProgressUnits
                : min(task.progress.completedUnitCount, Self.totalProgressUnits)
            task.updateTitle(title, subtitle: normalizedSubtitle)
            task.setTaskCompleted(success: success)
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    func isBackgroundExecutionActive(for recordId: UUID? = nil) -> Bool {
        lock.withLock {
            guard activeTask != nil, !taskExpired else {
                return false
            }
            guard let recordId else {
                return true
            }
            return activeRecordID == recordId
        }
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        let snapshot = lock.withLock {
            activeTask = task
            taskExpired = false
            return (latestTitle, latestSubtitle, latestCompletedUnits, activeRecordID)
        }

        task.expirationHandler = { [weak self] in
            self?.markExpired()
        }
        task.progress.totalUnitCount = Self.totalProgressUnits
        task.progress.completedUnitCount = snapshot.2
        task.updateTitle(snapshot.0, subtitle: snapshot.1)
        NSLog(
            "[Aether3D][LocalBG] attached continued processing record=%@",
            snapshot.3?.uuidString ?? "none"
        )
    }

    private func markExpired() {
        let snapshot = lock.withLock { () -> (BGContinuedProcessingTask?, UUID?) in
            taskExpired = true
            let capturedTask = activeTask
            let capturedRecordID = activeRecordID
            activeTask = nil
            activeRecordID = nil
            return (capturedTask, capturedRecordID)
        }
        NSLog(
            "[Aether3D][LocalBG] continued processing expired record=%@",
            snapshot.1?.uuidString ?? "none"
        )
        // The system-managed continued-processing lease can end even while the
        // app still has foreground or ordinary background execution available.
        // Report the lease ending cleanly so Dynamic Island does not show a
        // spurious "Task failed" badge for work that is still progressing.
        snapshot.0?.setTaskCompleted(success: true)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private static func completedUnits(for progressFraction: Double?) -> Int64 {
        guard let progressFraction else { return 0 }
        let clamped = min(max(progressFraction, 0.0), 1.0)
        return Int64((clamped * Double(totalProgressUnits)).rounded(.down))
    }

    private static func normalizedSubtitle(_ value: String) -> String {
        let firstLine = value
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? value
        let collapsedWhitespace = firstLine
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsedWhitespace.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count > 72 else {
            return trimmed.isEmpty ? "本地训练继续进行中" : trimmed
        }
        return String(trimmed.prefix(72))
    }

    private static func composedActiveSubtitle(
        phaseTitle: String,
        detail: String
    ) -> String {
        let normalizedPhaseTitle = normalizedSubtitle(phaseTitle)
        let normalizedDetail = normalizedSubtitle(detail)
        if normalizedDetail.isEmpty {
            return normalizedPhaseTitle.isEmpty ? "本地训练继续进行中" : normalizedPhaseTitle
        }
        if normalizedPhaseTitle.isEmpty || normalizedPhaseTitle == normalizedDetail {
            return normalizedDetail
        }
        return normalizedSubtitle("\(normalizedPhaseTitle) · \(normalizedDetail)")
    }
}

private final class BackgroundRemoteResumeCoordinator: @unchecked Sendable {
    static let shared = BackgroundRemoteResumeCoordinator()

    static let refreshIdentifier = "com.aether3d.remote-resume.refresh"
    static let processingIdentifier = "com.aether3d.remote-resume.processing"

    private let store = ScanRecordStore()
    private let backend = PipelineBackend.productDefault()
    private let lock = NSLock()
    private var activeTaskIDs: Set<String> = []

    private init() {}

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(refreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleProcessing(processingTask)
        }
    }

    func scheduleIfNeeded(reason: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard self.hasPendingRemoteWork() else { return }

            let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60)
            do {
                try BGTaskScheduler.shared.submit(refresh)
            } catch {
                NSLog("[Aether3D][BGResume] refresh submit failed reason=%@ error=%@", reason, String(describing: error))
            }

            let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
            processing.earliestBeginDate = Date(timeIntervalSinceNow: 60)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            do {
                try BGTaskScheduler.shared.submit(processing)
            } catch {
                NSLog("[Aether3D][BGResume] processing submit failed reason=%@ error=%@", reason, String(describing: error))
            }
        }
    }

    func kickoffImmediateResume(reason: String) {
        guard hasPendingRemoteWork() else { return }
        Task.detached(priority: .background) { [weak self] in
            await self?.performCatchUpCycle(trigger: reason, maxRecords: 2)
        }
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        scheduleIfNeeded(reason: "app_refresh_started")
        let completionBox = BackgroundTaskCompletionBox(task: task)
        let worker = Task(priority: .background) { [weak self, completionBox] in
            let success = await self?.performCatchUpCycle(trigger: "bg_app_refresh", maxRecords: 2) ?? false
            completionBox.complete(success: success)
        }
        task.expirationHandler = {
            worker.cancel()
            NSLog("[Aether3D][BGResume] app refresh expired; completing task as failed")
            completionBox.complete(success: false)
        }
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        scheduleIfNeeded(reason: "processing_started")
        let completionBox = BackgroundTaskCompletionBox(task: task)
        let worker = Task(priority: .background) { [weak self, completionBox] in
            let success = await self?.performCatchUpCycle(trigger: "bg_processing", maxRecords: 4) ?? false
            completionBox.complete(success: success)
        }
        task.expirationHandler = {
            worker.cancel()
            NSLog("[Aether3D][BGResume] processing expired; completing task as failed")
            completionBox.complete(success: false)
        }
    }

    private func performCatchUpCycle(trigger: String, maxRecords: Int) async -> Bool {
        let records = store.loadRecords()
            .filter { self.shouldResumeRecord($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !records.isEmpty else { return true }

        NSLog("[Aether3D][BGResume] trigger=%@ pending=%ld", trigger, records.count)

        var attemptedAny = false
        for record in records.prefix(maxRecords) {
            if Task.isCancelled {
                return false
            }
            guard markStarted(record.id) else { continue }
            attemptedAny = true
            await resume(record: record)
            markFinished(record.id)
        }

        scheduleIfNeeded(reason: "post_cycle")
        return attemptedAny
    }

    private func markStarted(_ id: UUID) -> Bool {
        lock.withLock {
            let token = id.uuidString
            guard !activeTaskIDs.contains(token) else { return false }
            activeTaskIDs.insert(token)
            return true
        }
    }

    private func markFinished(_ id: UUID) {
        _ = lock.withLock {
            activeTaskIDs.remove(id.uuidString)
        }
    }

    private func hasPendingRemoteWork() -> Bool {
        store.loadRecords().contains(where: shouldResumeRecord(_:))
    }

    private func shouldResumeRecord(_ record: ScanRecord) -> Bool {
        guard record.artifactPath == nil,
              let remoteJobId = record.remoteJobId,
              !remoteJobId.isEmpty else {
            return false
        }

        if record.status == .completed {
            return true
        }

        if record.status == .failed {
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

        if record.status == .cancelled {
            return record.failureReason == "cancel_requested_unconfirmed"
        }

        return record.isProcessing
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

    private func failureDetail(for reason: FailReason) -> String {
        switch reason {
        case .networkTimeout, .timeout:
            return "后台刷新时连接远端超时了。"
        case .uploadFailed:
            return "后台刷新发现上传没有完成。"
        case .downloadFailed:
            return "远端已经完成，但回传手机时失败了；我会继续尝试恢复。"
        case .stalledProcessing:
            return "远端训练长时间没有推进，后台刷新停止了这次恢复。"
        case .apiError, .apiNotConfigured:
            return "后台刷新暂时连不上正式 control-plane。"
        case .inputInvalid:
            return "这次素材暂时无法继续恢复。"
        case .outOfMemory:
            return "远端显存不足，后台刷新无法自动恢复。"
        case .jobTimeout, .invalidResponse, .unknownError:
            return "后台刷新拿到了异常结果。"
        }
    }

    private func shouldAcceptRemoteResumeUpdate(recordId: UUID, remoteJobId: String) -> Bool {
        let normalizedRemoteJobId = remoteJobId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemoteJobId.isEmpty else { return false }
        let currentRemoteJobId = store.record(id: recordId)?
            .remoteJobId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !currentRemoteJobId.isEmpty else { return false }
        return currentRemoteJobId == normalizedRemoteJobId
    }

    private func updateRecordFromProgress(recordId: UUID, snapshot: GenerateProgressSnapshot, remoteJobId: String) {
        guard shouldAcceptRemoteResumeUpdate(recordId: recordId, remoteJobId: remoteJobId) else {
            return
        }
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
            remoteJobId: remoteJobId
        )
    }

    private func completeRecord(recordId: UUID, remoteJobId: String, artifact: ArtifactRef) {
        guard shouldAcceptRemoteResumeUpdate(recordId: recordId, remoteJobId: remoteJobId) else {
            return
        }
        let finalExtension: String = {
            switch artifact.format {
            case .splat:
                return "splat"
            case .spz:
                return "spz"
            case .splatPly:
                return "ply"
            }
        }()

        let finalURL = store.baseDirectoryURL()
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(recordId.uuidString).\(finalExtension)")

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
        } catch {
            guard shouldAcceptRemoteResumeUpdate(recordId: recordId, remoteJobId: remoteJobId) else {
                return
            }
            store.updateProcessingState(
                recordId: recordId,
                status: .failed,
                statusMessage: "回传到手机时失败了",
                detailMessage: "后台下载已经完成，但落地本地文件失败了。",
                progressFraction: 0.92,
                estimatedRemainingMinutes: nil,
                failureReason: "copy_failed"
            )
        }
    }

    private func failRecord(recordId: UUID, remoteJobId: String, reason: FailReason) {
        guard shouldAcceptRemoteResumeUpdate(recordId: recordId, remoteJobId: remoteJobId) else {
            return
        }
        store.updateProcessingState(
            recordId: recordId,
            status: .failed,
            statusMessage: failureTitle(for: reason),
            detailMessage: failureDetail(for: reason),
            progressFraction: nil,
            estimatedRemainingMinutes: nil,
            failureReason: reason.rawValue
        )
    }

    private func resume(record: ScanRecord) async {
        guard let remoteJobId = record.remoteJobId, !remoteJobId.isEmpty else { return }
        let runner = PipelineRunner(backend: backend)
        let result = await runner.resumeGenerate(jobId: remoteJobId) { [weak self] snapshot in
            self?.updateRecordFromProgress(recordId: record.id, snapshot: snapshot, remoteJobId: remoteJobId)
        }

        switch result {
        case .success(let artifact, _):
            completeRecord(recordId: record.id, remoteJobId: remoteJobId, artifact: artifact)
        case .fail(let reason, _):
            failRecord(recordId: record.id, remoteJobId: remoteJobId, reason: reason)
        }
    }
}

#if canImport(AVFoundation)
private final class BackgroundLocalRecoveryCoordinator: @unchecked Sendable {
    static let shared = BackgroundLocalRecoveryCoordinator()

    private let store = ScanRecordStore()
    private let lock = NSLock()
    private var activeRecoveries: Set<String> = []

    private init() {}

    func kickoffImmediateRecovery(reason: String) {
        let pendingRecords = store.loadRecords()
            .filter { record in
                let trimmedRemoteJobID = record.remoteJobId?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return record.artifactPath == nil &&
                    record.isProcessing &&
                    record.resolvedProcessingBackend == .localSubjectFirst &&
                    trimmedRemoteJobID.isEmpty
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard !pendingRecords.isEmpty else { return }

        let resumableRecords = pendingRecords.filter(canResumeRecord(_:))
        let resumableIDs = Set(resumableRecords.map(\.id))
        let failedCount = store.failOrphanedLocalProcessingRecordsOnColdLaunch(
            excludingRecordIDs: resumableIDs
        )
        if failedCount > 0 {
            NSLog(
                "[Aether3D][LaunchRecovery] marked %ld orphaned local processing record(s) as interrupted because no recoverable local video was found",
                failedCount
            )
        }

        guard !resumableRecords.isEmpty else { return }
        NSLog(
            "[Aether3D][LaunchRecovery] resuming %ld local processing record(s) from persisted source video",
            resumableRecords.count
        )
        for record in resumableRecords {
            guard markStarted(record.id) else { continue }
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                await self.resume(record: record, trigger: reason)
                self.markFinished(record.id)
            }
        }
    }

    private func canResumeRecord(_ record: ScanRecord) -> Bool {
        sourceVideoURL(for: record) != nil
    }

    private func markStarted(_ id: UUID) -> Bool {
        lock.withLock {
            let token = id.uuidString
            guard !activeRecoveries.contains(token) else { return false }
            activeRecoveries.insert(token)
            return true
        }
    }

    private func markFinished(_ id: UUID) {
        _ = lock.withLock {
            activeRecoveries.remove(id.uuidString)
        }
    }

    private func sourceVideoURL(for record: ScanRecord) -> URL? {
        guard let sourceRelativePath = record.sourceVideoPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceRelativePath.isEmpty else {
            return nil
        }
        let sourceURL = store.baseDirectoryURL().appendingPathComponent(sourceRelativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        return sourceURL
    }

    private func frameSamplingProfile(for record: ScanRecord) -> FrameSamplingProfile {
        if let rawValue = record.frameSamplingProfile,
           let profile = FrameSamplingProfile(rawValue: rawValue) {
            return profile
        }
        return FrameSamplingProfile.currentSelection()
    }

    private func artifactURL(for recordId: UUID) -> URL {
        store.baseDirectoryURL()
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("\(recordId.uuidString).ply")
    }

    private func relativeArtifactPath(for recordId: UUID) -> String {
        "exports/\(recordId.uuidString).ply"
    }

    private func startupRuntimeMetrics(
        sourceRelativePath: String,
        trigger: String,
        frameSamplingProfile: FrameSamplingProfile
    ) -> [String: String] {
        LocalPreviewProductProfile.canonicalRuntimeMetrics([
            "processing_backend": ProcessingBackendChoice.localSubjectFirst.rawValue,
            "native_input_kind": "recorded_video_relaunch_recovery",
            "native_handoff_from": "cold_launch_recovery",
            "native_resume_trigger": trigger,
            "native_active_phase": LocalPreviewWorkflowPhase.depth.phaseName,
            "native_phase_model": LocalPreviewProductProfile.phaseModelDescriptor(
                for: .localSubjectFirst
            ),
            "source_video": sourceRelativePath,
            "frame_sampling_profile": frameSamplingProfile.rawValue
        ])
    }

    private func resume(record: ScanRecord, trigger: String) async {
        guard let sourceURL = sourceVideoURL(for: record),
              let sourceRelativePath = record.sourceVideoPath?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceRelativePath.isEmpty else {
            store.updateProcessingState(
                recordId: record.id,
                status: .failed,
                statusMessage: "本地处理已中断",
                detailMessage: "重新启动 app 后尝试恢复这条本地任务，但这次已经找不到可恢复的本地视频输入，所以系统把它标成中断；请回主页重新发起。",
                progressFraction: nil,
                estimatedRemainingMinutes: nil,
                failureReason: "local_processing_interrupted_no_recoverable_source_after_relaunch"
            )
            NSLog(
                "[Aether3D][LaunchRecovery] failed local recovery because source video missing record=%@",
                record.id.uuidString
            )
            return
        }

        let frameSamplingProfile = frameSamplingProfile(for: record)
        let runtimeMetrics = startupRuntimeMetrics(
            sourceRelativePath: sourceRelativePath,
            trigger: trigger,
            frameSamplingProfile: frameSamplingProfile
        )
        let workflowStageKey =
            ProcessingBackendChoice.localSubjectFirst.localWorkflowStageKey
            ?? "local_subject_first"
        let localModeResultTitle = "本地结果已生成"
        let localModeFailureTitle = "本地处理失败了"
        let startupDetail = "检测到上次本地任务在 app 重启前被打断，这次会直接用已落盘视频恢复本地处理。"

        try? FileManager.default.createDirectory(
            at: artifactURL(for: record.id).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        store.updateProcessingState(
            recordId: record.id,
            status: .training,
            statusMessage: LocalPreviewWorkflowPhase.depth.title,
            detailMessage: startupDetail,
            progressFraction: LocalPreviewWorkflowPhase.depth.startFraction,
            progressBasis: LocalPreviewWorkflowPhase.depth.progressBasis,
            remoteStageKey: workflowStageKey,
            remotePhaseName: LocalPreviewWorkflowPhase.depth.phaseName,
            runtimeMetrics: runtimeMetrics,
            estimatedRemainingMinutes: nil,
            sourceVideoPath: sourceRelativePath,
            frameSamplingProfile: frameSamplingProfile.rawValue,
            clearRemoteJobId: true
        )

        let importResult = await LocalPreviewImportRunner.execute(
            sourceVideoURL: sourceURL,
            artifactURL: artifactURL(for: record.id),
            sourceRelativePath: sourceRelativePath,
            frameSamplingProfile: frameSamplingProfile,
            processingBackend: .localSubjectFirst,
            onPhaseUpdate: { [weak self] update in
                guard let self else { return }
                self.store.updateProcessingState(
                    recordId: record.id,
                    status: update.phase == .export ? .packaging : .training,
                    statusMessage: update.title,
                    detailMessage: update.detail,
                    progressFraction: update.progressFraction,
                    progressBasis: update.phase.progressBasis,
                    remoteStageKey: workflowStageKey,
                    remotePhaseName: update.phase.phaseName,
                    runtimeMetrics: update.runtimeMetrics,
                    estimatedRemainingMinutes: nil,
                    sourceVideoPath: sourceRelativePath,
                    frameSamplingProfile: frameSamplingProfile.rawValue,
                    clearRemoteJobId: true
                )
            }
        )

        if importResult.exported {
            store.updateProcessingState(
                recordId: record.id,
                status: .completed,
                statusMessage: localModeResultTitle,
                detailMessage: "已经从上次中断处自动恢复，并基于已落盘视频完成本地导出。",
                progressFraction: 1.0,
                progressBasis: LocalPreviewWorkflowPhase.export.progressBasis,
                remoteStageKey: workflowStageKey,
                remotePhaseName: LocalPreviewWorkflowPhase.export.phaseName,
                runtimeMetrics: importResult.runtimeMetrics,
                estimatedRemainingMinutes: 0,
                sourceVideoPath: sourceRelativePath,
                frameSamplingProfile: frameSamplingProfile.rawValue,
                clearRemoteJobId: true
            )
            store.updateArtifactPath(
                recordId: record.id,
                artifactPath: relativeArtifactPath(for: record.id)
            )
            NSLog(
                "[Aether3D][LaunchRecovery] local recorded-video recovery succeeded record=%@",
                record.id.uuidString
            )
            return
        }

        let failureReason =
            LocalPreviewProductProfile.runtimeMetricString(
                "native_failure_reason",
                from: importResult.runtimeMetrics
            ) ?? "cold_launch_local_recovery_failed"
        store.updateProcessingState(
            recordId: record.id,
            status: .failed,
            statusMessage: localModeFailureTitle,
            detailMessage: "系统已经用已落盘视频自动恢复过一次本地处理，但这次仍然失败了。\n\n\(importResult.detailMessage)",
            progressFraction: importResult.terminalProgressFraction,
            progressBasis: importResult.terminalPhase.progressBasis,
            remoteStageKey: workflowStageKey,
            remotePhaseName: importResult.terminalPhase.phaseName,
            runtimeMetrics: importResult.runtimeMetrics,
            estimatedRemainingMinutes: nil,
            sourceVideoPath: sourceRelativePath,
            frameSamplingProfile: frameSamplingProfile.rawValue,
            failureReason: failureReason
        )
        NSLog(
            "[Aether3D][LaunchRecovery] local recorded-video recovery failed record=%@ reason=%@",
            record.id.uuidString,
            failureReason
        )
    }
}
#endif

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
#endif

#if canImport(UIKit)
final class Aether3DAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        // BGTaskScheduler.register / BackgroundRemoteResumeCoordinator.register 必须在
        // didFinishLaunching 同步调,否则系统不接受 BGTask 注册。这两步本身极快(< 5ms)。
        #if canImport(BackgroundTasks)
        if #available(iOS 26.0, *) {
            LocalProcessingContinuedTaskCoordinator.shared.register()
        }
        BackgroundRemoteResumeCoordinator.shared.register()
        // scheduleIfNeeded 不是注册,可以异步(只是排个调度,延迟一两秒无影响)
        Task.detached(priority: .background) {
            BackgroundRemoteResumeCoordinator.shared.scheduleIfNeeded(reason: "launch")
        }
        #endif

        // LocalRecovery 是冷启动时扫历史录制找孤儿任务标 failed —— 重活,但**不影响首屏渲染**,
        // 完全可以扔后台。代价:用户在首屏看到的"还在处理中"状态可能 1-2s 后变 "interrupted",
        // 99% 冷启动没孤儿任务,所以视觉上感觉不到。
        #if canImport(AVFoundation)
        Task.detached(priority: .background) {
            BackgroundLocalRecoveryCoordinator.shared.kickoffImmediateRecovery(reason: "cold_launch")
        }
        #else
        Task.detached(priority: .background) {
            let interruptedLocalJobs = ScanRecordStore().failOrphanedLocalProcessingRecordsOnColdLaunch()
            if interruptedLocalJobs > 0 {
                NSLog(
                    "[Aether3D][LaunchRecovery] marked %ld orphaned local processing record(s) as interrupted",
                    interruptedLocalJobs
                )
            }
        }
        #endif
        return true   // 立刻返回,SwiftUI 可以马上开始渲染 HomePage
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        #if canImport(BackgroundTasks)
        BackgroundRemoteResumeCoordinator.shared.scheduleIfNeeded(reason: "did_enter_background")
        #endif
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadBrokerClient.shared.handleEventsForBackgroundURLSession(
            identifier: identifier,
            completionHandler: completionHandler
        )
        #if canImport(BackgroundTasks)
        BackgroundRemoteResumeCoordinator.shared.kickoffImmediateResume(reason: "background_url_session_event")
        #endif
    }
}
#endif

@main
struct Aether3DApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(Aether3DAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomePage()
            }
        }
    }
}
