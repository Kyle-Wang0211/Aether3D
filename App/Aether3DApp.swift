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

    init(task: BGTask) {
        self.task = task
    }

    @MainActor
    func complete(success: Bool) {
        task.setTaskCompleted(success: success)
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
            await completionBox.complete(success: success)
        }
        task.expirationHandler = {
            worker.cancel()
        }
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        scheduleIfNeeded(reason: "processing_started")
        let completionBox = BackgroundTaskCompletionBox(task: task)
        let worker = Task(priority: .background) { [weak self, completionBox] in
            let success = await self?.performCatchUpCycle(trigger: "bg_processing", maxRecords: 4) ?? false
            await completionBox.complete(success: success)
        }
        task.expirationHandler = {
            worker.cancel()
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

    private func updateRecordFromProgress(recordId: UUID, snapshot: GenerateProgressSnapshot, remoteJobId: String) {
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

    private func completeRecord(recordId: UUID, artifact: ArtifactRef) {
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

    private func failRecord(recordId: UUID, reason: FailReason) {
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
            completeRecord(recordId: record.id, artifact: artifact)
        case .fail(let reason, _):
            failRecord(recordId: record.id, reason: reason)
        }
    }
}

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
        #if canImport(BackgroundTasks)
        BackgroundRemoteResumeCoordinator.shared.register()
        BackgroundRemoteResumeCoordinator.shared.scheduleIfNeeded(reason: "launch")
        #endif
        return true
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
            .preferredColorScheme(.dark)
        }
    }
}
