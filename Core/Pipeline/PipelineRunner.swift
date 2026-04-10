// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  PipelineRunner.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit)
import UIKit
#endif

/// JSON 转义函数，防止文件名等破坏 JSON 格式
private func jsonEscape(_ string: String) -> String {
    var result = ""
    for char in string {
        switch char {
        case "\\": result += "\\\\"
        case "\"": result += "\\\""
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if char.unicodeScalars.first!.value < 32 {
                result += String(format: "\\u%04x", char.unicodeScalars.first!.value)
            } else {
                result.append(char)
            }
        }
    }
    return result
}

public final class PipelineRunner: @unchecked Sendable {
    private struct UploadRateSample {
        let timestamp: Date
        let uploadedBytes: Int64
    }

    private final class FirstPreparedBytesRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var firstPreparedBytesAt: Date?

        func recordIfNeeded(preparedBytes: Int64) {
            guard preparedBytes > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            if firstPreparedBytesAt == nil {
                firstPreparedBytesAt = Date()
            }
        }

        func value() -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return firstPreparedBytesAt
        }
    }

    private actor BrokerUploadMonitor {
        private var failureMessage: String?

        func markFailed(_ error: Error) {
            failureMessage = String(describing: error)
        }

        func throwIfFailed() throws {
            if let failureMessage {
                throw RemoteB1ClientError.uploadFailed(failureMessage)
            }
        }

        func reconcile(with status: JobStatus) throws {
            guard let failureMessage else { return }

            switch status {
            case .processing, .downloadReady, .completed, .failed:
                self.failureMessage = nil
            case .pending(let progress):
                let normalizedBasis = progress.progressBasis?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let remoteHasMovedPastUploadFailure = progress.stageKey == "queued"
                    || normalizedBasis == "upload_complete"
                    || normalizedBasis == "control_plane_upload_complete"
                    || normalizedBasis == "chunked_upload_complete"
                    || normalizedBasis == "worker_assigned_streaming_input"
                    || normalizedBasis == "prep_stream_probe_live"
                    || normalizedBasis == "prep_extract_frames_live"
                    || normalizedBasis == "prep_audit_live"

                if remoteHasMovedPastUploadFailure {
                    self.failureMessage = nil
                    return
                }
                throw RemoteB1ClientError.uploadFailed(failureMessage)
            }
        }
    }

    private struct UploadRateEstimate {
        var startedAt: Date?
        var recentSamples: [UploadRateSample] = []
        var smoothedBytesPerSecond: Double?
        var lastMeasuredAt: Date?
    }

    private let backend: PipelineBackend
    private let remoteClient: RemoteB1Client?
    private let brokerClient: BackgroundUploadBrokerClient?
    private let progressStateQueue = DispatchQueue(label: "com.aether3d.pipeline.progress")
    private var lastEmittedProgressFraction: Double?
    private var lastEmittedRemoteJobId: String?
    private var lastEmittedSnapshot: GenerateProgressSnapshot?
    private var uploadRateEstimate = UploadRateEstimate()

    public convenience init() {
        self.init(backend: .productDefault())
    }

    public convenience init(backend: PipelineBackend) {
        switch backend {
        case .localEmbedded:
            self.init(backend: backend, remoteClient: LocalAetherRemoteB1Client(), brokerClient: nil)
        case .danishGoldenSSH:
            self.init(backend: backend, remoteClient: DanishGoldenRemoteB1Client(), brokerClient: nil)
        case .brokeredBackgroundUpload:
            self.init(backend: backend, remoteClient: nil, brokerClient: .shared)
        }
    }

    init(remoteClient: RemoteB1Client = LocalAetherRemoteB1Client()) {
        self.backend = .danishGoldenSSH
        self.remoteClient = remoteClient
        self.brokerClient = nil
    }

    private init(
        backend: PipelineBackend,
        remoteClient: RemoteB1Client?,
        brokerClient: BackgroundUploadBrokerClient?
    ) {
        self.backend = backend
        self.remoteClient = remoteClient
        self.brokerClient = brokerClient
    }

    private func emitProgress(
        _ snapshot: GenerateProgressSnapshot?,
        to handler: (@Sendable (GenerateProgressSnapshot) async -> Void)?
    ) async {
        guard let snapshot, let handler else { return }
        await handler(monotonicProgressSnapshot(snapshot))
    }

    private func monotonicProgressSnapshot(_ snapshot: GenerateProgressSnapshot) -> GenerateProgressSnapshot {
        progressStateQueue.sync {
            if snapshot.stage == .preparing {
                if lastEmittedSnapshot?.stage != .preparing {
                    lastEmittedProgressFraction = nil
                    lastEmittedRemoteJobId = snapshot.remoteJobId
                    lastEmittedSnapshot = nil
                    uploadRateEstimate = UploadRateEstimate()
                }
            } else if let jobId = snapshot.remoteJobId,
                      let lastJobId = lastEmittedRemoteJobId,
                      jobId != lastJobId {
                lastEmittedProgressFraction = nil
                lastEmittedSnapshot = nil
                uploadRateEstimate = UploadRateEstimate()
            }

            var stage = snapshot.stage
            var title = snapshot.title
            var detail = snapshot.detail
            var progressBasis = snapshot.progressBasis
            var remoteStageKey = snapshot.remoteStageKey
            var remotePhaseName = snapshot.remotePhaseName
            var currentTier = snapshot.currentTier
            var runtimeMetrics = snapshot.runtimeMetrics
            let authoritativeIncomingStage = isAuthoritativeIncomingStage(snapshot)
            let authoritativeStageRegression = {
                guard let previous = lastEmittedSnapshot else { return false }
                guard authoritativeIncomingStage else { return false }
                guard let previousRank = visibleStageRank(previous.stage),
                      let incomingRank = visibleStageRank(snapshot.stage) else {
                    return false
                }
                return incomingRank < previousRank
            }()

            var preservedStage: GenerateProgressStage?
            if let previous = lastEmittedSnapshot,
               shouldPreserveVisibleStage(previous.stage, over: snapshot.stage),
               !authoritativeIncomingStage {
                preservedStage = previous.stage
            }

            if let previous = lastEmittedSnapshot,
               let preservedStage {
                stage = preservedStage
                if visibleStageRank(snapshot.stage) == visibleStageRank(previous.stage) {
                    title = preferredLiveStatusTitle(
                        incomingTitle: snapshot.title,
                        fallbackTitle: previous.title
                    )
                    detail = preferredLiveStatusDetail(
                        incomingDetail: snapshot.detail,
                        incomingTitle: snapshot.title,
                        fallbackStage: previous.stage
                    )
                    progressBasis = snapshot.progressBasis ?? previous.progressBasis
                    remoteStageKey = snapshot.remoteStageKey ?? previous.remoteStageKey
                    remotePhaseName = snapshot.remotePhaseName ?? previous.remotePhaseName
                    currentTier = snapshot.currentTier ?? previous.currentTier
                    runtimeMetrics = snapshot.runtimeMetrics ?? previous.runtimeMetrics
                } else {
                    title = previous.title
                    detail = previous.detail ?? stableDetailForRegressedStage(previous.stage)
                    progressBasis = previous.progressBasis
                    remoteStageKey = previous.remoteStageKey
                    remotePhaseName = previous.remotePhaseName
                    currentTier = previous.currentTier
                    runtimeMetrics = previous.runtimeMetrics
                }
            }

            var progress = snapshot.progressFraction
            switch stage {
            case .completed:
                progress = 1.0
            case .failed:
                break
            default:
                if authoritativeStageRegression {
                    progress = snapshot.progressFraction
                } else if let last = lastEmittedProgressFraction {
                    if let current = progress {
                        progress = preservedStage == nil ? max(last, current) : current
                    } else {
                        progress = last
                    }
                }
            }

            if snapshot.stage != .failed, let progress {
                lastEmittedProgressFraction = progress
            } else if authoritativeStageRegression {
                lastEmittedProgressFraction = nil
            }
            if let jobId = snapshot.remoteJobId {
                lastEmittedRemoteJobId = jobId
            }

            let resolvedSnapshot = GenerateProgressSnapshot(
                stage: stage,
                progressFraction: progress,
                progressBasis: progressBasis,
                remoteStageKey: remoteStageKey,
                remotePhaseName: remotePhaseName,
                currentTier: currentTier,
                title: title,
                detail: detail,
                etaMinutes: snapshot.etaMinutes,
                remoteJobId: snapshot.remoteJobId,
                runtimeMetrics: runtimeMetrics,
                uploadedBytes: snapshot.uploadedBytes,
                totalBytes: snapshot.totalBytes,
                uploadBytesPerSecond: snapshot.uploadBytesPerSecond
            )

            if stage != .failed {
                lastEmittedSnapshot = resolvedSnapshot
            }

            return resolvedSnapshot
        }
    }

    private func shouldPreserveVisibleStage(
        _ previous: GenerateProgressStage,
        over incoming: GenerateProgressStage
    ) -> Bool {
        guard incoming != .failed, incoming != .completed else { return false }
        guard let previousRank = visibleStageRank(previous),
              let incomingRank = visibleStageRank(incoming) else {
            return false
        }
        return previousRank > incomingRank
    }

    private func isAuthoritativeIncomingStage(_ snapshot: GenerateProgressSnapshot) -> Bool {
        let normalizedBasis = snapshot.progressBasis?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedStage = snapshot.remoteStageKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPhase = snapshot.remotePhaseName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let basis = normalizedBasis,
           basis.hasPrefix("prep_")
            || basis == "active_worker_without_runtime"
            || basis == "worker_assigned_streaming_input"
            || basis == "worker_assigned"
            || basis == "runtime_tqdm_steps"
            || basis == "runtime_render_count" {
            return true
        }

        if let stage = normalizedStage,
           ["gpu_wait", "sfm", "sfm_extract", "sfm_match", "sfm_reconstruct", "train", "export", "render", "package", "packaging", "download"].contains(stage) {
            return true
        }

        if let phase = normalizedPhase,
           ["gpu_wait", "streaming_input", "stream_probe_live", "extract_frames_live", "audit_live", "sfm_wait_live", "live_sfm_retry_wait", "live_sfm_ready", "feature_extractor", "matcher", "mapper", "audit", "prep", "prep_complete", "probe", "full", "export"].contains(phase) {
            return true
        }

        return !(snapshot.runtimeMetrics?.isEmpty ?? true)
    }

    private func visibleStageRank(_ stage: GenerateProgressStage) -> Int? {
        switch stage {
        case .preparing:
            return 0
        case .uploading, .queued:
            return 1
        case .reconstructing:
            return 2
        case .training, .localFallback:
            return 3
        case .packaging, .downloading, .completed:
            return 4
        case .failed:
            return nil
        }
    }

    private func stableDetailForRegressedStage(_ stage: GenerateProgressStage) -> String? {
        switch stage {
        case .training, .localFallback:
            return "远端正在继续处理这条任务。内部可能会穿插回退尝试，但整体阶段仍属于训练流程。"
        case .reconstructing:
            return "远端正在继续做相机重建和视角对齐。"
        case .packaging, .downloading, .completed:
            return "远端正在整理结果并准备回传到手机。"
        case .queued:
            return backend == .brokeredBackgroundUpload
                ? "视频已经到达对象存储，正在等待可用 GPU。"
                : "远端已经接收任务，正在等待可用算力。"
        case .uploading:
            return backend == .brokeredBackgroundUpload
                ? "视频正在上传到后台对象存储。"
                : "视频正在上传到远端。"
        case .preparing:
            return "正在准备本次任务。"
        case .failed:
            return nil
        }
    }

    private func preferredLiveStatusTitle(
        incomingTitle: String,
        fallbackTitle: String
    ) -> String {
        let trimmedIncoming = incomingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIncoming.isEmpty {
            return trimmedIncoming
        }
        return fallbackTitle
    }

    private func preferredLiveStatusDetail(
        incomingDetail: String?,
        incomingTitle: String,
        fallbackStage: GenerateProgressStage
    ) -> String? {
        if let incomingDetail {
            let trimmed = incomingDetail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let trimmedIncomingTitle = incomingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIncomingTitle.isEmpty {
            return "当前子步骤：\(trimmedIncomingTitle)"
        }

        return stableDetailForRegressedStage(fallbackStage)
    }

    private func failureSnapshot(
        for reason: FailReason,
        remoteJobId: String? = nil,
        detailOverride: String? = nil
    ) -> GenerateProgressSnapshot {
        let title: String
        let detail: String
        if let detailOverride, !detailOverride.isEmpty {
            detail = detailOverride
        } else {
            switch reason {
            case .networkTimeout, .timeout:
                detail = "远端等待超时了，请稍后重试。"
            case .uploadFailed:
                detail = "视频上传没有完成，请确认网络后再试。"
            case .downloadFailed:
                detail = "模型已经生成，但回传手机时失败了。"
            case .stalledProcessing:
                detail = "远端长时间没有推进，本次任务已经停止。"
            case .inputInvalid:
                detail = "输入视频暂时不适合进入当前白盒闭环。"
            case .apiError, .apiNotConfigured:
                detail = backend == .brokeredBackgroundUpload
                    ? "后台上传服务或远端调度服务当前不可用，请稍后再试。"
                    : "丹麦 5090 当前不可用，请稍后再试。"
            case .jobTimeout, .invalidResponse, .unknownError, .outOfMemory:
                detail = "远端返回了异常结果，请稍后重试。"
            }
        }
        switch reason {
        case .uploadFailed:
            title = "上传已中断"
        case .downloadFailed:
            title = "回传到手机时失败了"
        case .networkTimeout, .timeout:
            title = "远端等待超时"
        default:
            title = "远端生成失败"
        }
        return GenerateProgressSnapshot(
            stage: .failed,
            progressFraction: nil,
            title: title,
            detail: detail,
            etaMinutes: nil,
            remoteJobId: remoteJobId
        )
    }

    private func detailedRemoteFailureMessage(
        for error: RemoteB1ClientError,
        mappedReason: FailReason
    ) -> String {
        let transportLabel = backend == .brokeredBackgroundUpload ? "底层上传/调度" : "底层 SSH"
        let usesBroker = backend == .brokeredBackgroundUpload

        func rawSSHDetail(_ rawMessage: String) -> String {
            let normalized = rawMessage
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return "" }
            let shortened = normalized.count > 180 ? String(normalized.prefix(180)) + "..." : normalized
            return "\n\n\(transportLabel): \(shortened)"
        }

        func stalledUploadBytes(from rawMessage: String) -> Int64? {
            let prefix = "upload_stalled_after_"
            let suffix = "_bytes"
            guard rawMessage.hasPrefix(prefix), rawMessage.hasSuffix(suffix) else { return nil }
            let value = rawMessage.dropFirst(prefix.count).dropLast(suffix.count)
            return Int64(value)
        }

        func megabytesString(for bytes: Int64) -> String {
            let mb = Double(bytes) / 1_048_576.0
            if mb >= 1024 {
                return String(format: "%.2f GB", mb / 1024.0)
            }
            return String(format: "%.0f MB", mb)
        }

        switch error {
        case .networkError(let rawMessage):
            if usesBroker {
                if rawMessage.contains("broker_http_status_502")
                    || rawMessage.contains("broker_http_status_503")
                    || rawMessage.contains("broker_http_status_504") {
                    return "后台状态查询服务刚才返回了临时错误，手机一度拿不到最新进度。这不代表远端任务一定没开始；如果远端仍在处理，系统会优先继续重连，而不是立刻放弃。"
                }
                switch mappedReason {
                case .apiError, .apiNotConfigured:
                    return "后台上传服务或训练调度服务当前不可用，所以这次任务没有真正开始。请稍后重试。" + rawSSHDetail(rawMessage)
                default:
                    return "上传服务返回了异常结果，所以这次任务没有继续。请重试。" + rawSSHDetail(rawMessage)
                }
            }
            let message = rawMessage.lowercased()
            if message.contains("authorized_keys") || message.contains("permission denied") {
                return "这台手机还没有拿到丹麦 5090 的 SSH 权限，所以这次任务没有真正发出去。请先把手机公钥加入远端 authorized_keys，然后再试。" + rawSSHDetail(rawMessage)
            }
            if message.contains("host_key_mismatch") {
                return "丹麦 5090 的 SSH 指纹和 app 里保存的不一致，所以这次任务没有真正连上远端。需要先更新指纹后才能继续。" + rawSSHDetail(rawMessage)
            }
            if message.contains("remote_start_not_acknowledged") {
                return "已经连上丹麦 5090，但远端并没有真正接收这次新任务，所以系统已立即停止等待。请直接重试一次。" + rawSSHDetail(rawMessage)
            }
            switch mappedReason {
            case .apiError, .apiNotConfigured:
                return "这次还没有真正连上丹麦 5090，所以任务没有开始。请检查手机网络后重试。" + rawSSHDetail(rawMessage)
            default:
                return "远端连接返回了异常结果，所以这次任务没有继续。请重试。" + rawSSHDetail(rawMessage)
            }
        case .networkTimeout:
            if usesBroker {
                return "后台上传服务连接超时了，这次任务还没有真正开始。请确认网络后再试。"
            }
            return "连接丹麦 5090 超时了，这次任务还没有真正开始。请确认手机网络后再试。"
        case .uploadFailed(let rawMessage):
            if usesBroker {
                if rawMessage.lowercased().contains("empty") {
                    return "本地视频内容为空，所以这次没有进入后台上传流程。请换一个正常的视频再试。" + rawSSHDetail(rawMessage)
                }
                if let stalledBytes = stalledUploadBytes(from: rawMessage) {
                    return "后台上传在已发送约 \(megabytesString(for: stalledBytes)) 后长时间没有继续推进，所以系统主动停止了这次上传。更像是大文件上传过程中的网络停顿，不是远端 GPU 已经开始训练。" + rawSSHDetail(rawMessage)
                }
                return "后台上传中断了。控制平面会停止这次任务，并自动清理对象存储分片与远端临时残留。请确认网络后重试。" + rawSSHDetail(rawMessage)
            }
            if rawMessage.lowercased().contains("empty") {
                return "本地视频内容为空，所以这次没有上传到丹麦 5090。请换一个正常的视频再试。" + rawSSHDetail(rawMessage)
            }
            return "视频还没有真正上传到丹麦 5090，所以这次任务没有开始。请确认本地视频可用并检查网络后重试。" + rawSSHDetail(rawMessage)
        case .downloadFailed:
            return "远端已经完成，但把 3DGS 回传到手机时失败了。你可以稍后重试。"
        case .invalidResponse:
            if usesBroker {
                return "后台服务返回了无法识别的响应，这次任务没有继续。请直接重试一次。"
            }
            return "丹麦 5090 返回了无法识别的响应，这次任务没有继续。请直接重试一次。"
        case .jobFailed(let reason):
            if reason.contains("cancelled_by_user") || reason.contains("cancel_requested") {
                return "这次远端任务已经被取消，所以 5090 不会继续训练。"
            }
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains("worker_orphaned_assignment")
                || normalized.contains("worker_stalled_or_runtime_stale")
                || reason.contains("worker 记录已经不存在")
                || reason.contains("worker 当前已经不再承接这条 job")
                || reason.contains("worker 已经不再承接这条 job")
                || reason.contains("worker 已经空闲")
                || reason.contains("worker 心跳已经过期") {
                return "控制平面发现这条任务原来挂在一台已经失联、空闲或不再承接这条 job 的 worker 上，所以已经主动停止。请直接重新发送。"
            }
            if reason.contains("remote_runner_orphaned") || reason.contains("只剩 runner 壳进程") {
                return "远端外层 runner 还挂着，但真正的预处理/训练 worker 已经不存在，所以这次任务已经卡住，不会继续自己推进。请直接重新发送。"
            }
            if reason.contains("这次失败发生在远端预处理阶段")
                || reason.contains("COLMAP")
                || reason.contains("SIGKILL")
                || reason.contains("sparse")
                || reason.contains("cameras.txt")
            {
                return reason
            }
            return "丹麦 5090 已经开始处理，但远端返回了失败结果：\(reason)。"
        case .notConfigured:
            if usesBroker {
                return "后台上传服务还没有配置好，所以这次任务没有真正开始。"
            }
            return "丹麦 5090 还没有配置好，所以这次任务没有真正开始。"
        }
    }

    private func processingLivenessSignature(_ progress: RemoteJobProgress) -> String {
        let metricString = progress.runtimeMetrics
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return [
            progress.stageKey ?? "",
            progress.phaseName ?? "",
            progress.currentTier ?? "",
            progress.progressBasis ?? "",
            progress.title ?? "",
            progress.detail ?? "",
            metricString
        ].joined(separator: "|")
    }

    private func shouldGracefullyRetryStatusPoll(_ error: Error) -> Bool {
        guard let brokerError = error as? RemoteB1ClientError else { return false }
        switch brokerError {
        case .networkTimeout:
            return true
        case .networkError(let message):
            return [
                "broker_http_status_502",
                "broker_http_status_503",
                "broker_http_status_504",
            ].contains(message)
        default:
            return false
        }
    }

    private func genericFailureDetail(_ error: Error) -> String {
        let nsError = error as NSError
        let typeName = String(reflecting: type(of: error))
        let brief = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        let reflected = String(reflecting: error).trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = ["type=\(typeName)"]
        if !nsError.domain.isEmpty || nsError.code != 0 {
            parts.append("ns=\(nsError.domain)(\(nsError.code))")
        }
        if !brief.isEmpty, brief.lowercased() != "unknown" {
            parts.append("desc=\(brief)")
        }
        if !reflected.isEmpty, reflected != brief {
            parts.append("reflect=\(reflected)")
        }

        let label = backend == .brokeredBackgroundUpload ? "底层上传/调度" : "底层 SSH"
        return "远端返回了未分类异常，所以这次任务没有继续。请重试。\n\n\(label): \(parts.joined(separator: " | "))"
    }

    private func progressSnapshot(
        from remoteProgress: RemoteJobProgress,
        fallbackStage: GenerateProgressStage,
        remoteJobId: String? = nil
    ) -> GenerateProgressSnapshot {
        let normalizedBasis = remoteProgress.progressBasis?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedStageKey = remoteProgress.stageKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedPhaseName = remoteProgress.phaseName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let uploadCompleted = remoteProgress.runtimeMetrics["upload_completed"]?.lowercased() == "true"
        let isAuthoritativeGpuWait =
            normalizedBasis == "prep_ready_waiting_gpu"
            || normalizedStageKey == "gpu_wait"
            || normalizedPhaseName == "gpu_wait"
        let isStreamingOverlapBasis =
            normalizedBasis == "worker_assigned_streaming_input"
            || normalizedBasis == "prep_stream_probe_live"
            || normalizedBasis == "prep_extract_frames_live"
            || normalizedBasis == "prep_audit_live"
            || normalizedBasis == "prep_live_sfm_wait_frames"
            || normalizedBasis == "prep_live_sfm_retry_wait"
            || normalizedBasis == "prep_live_sfm_ready"
        let isStreamingOverlapWhileUploadActive = !uploadCompleted && isStreamingOverlapBasis
        let isStreamingSfmWhileUploadActive =
            uploadCompleted == false
            && {
                guard let stageKey = remoteProgress.stageKey else { return false }
                return ["sfm", "sfm_extract", "sfm_match", "sfm_reconstruct"].contains(stageKey)
            }()
        let stage: GenerateProgressStage
        switch normalizedStageKey {
        case "uploading":
            stage = .uploading
        case "gpu_wait":
            stage = .queued
        case let key where ["sfm", "sfm_extract", "sfm_match", "sfm_reconstruct"].contains(key) && (isStreamingOverlapWhileUploadActive || isStreamingSfmWhileUploadActive):
            // 只有在上传仍未完成时，才保留“上传中 + 并行预处理”的主线。
            stage = .uploading
        case "queued":
            stage = .queued
        case "sfm", "sfm_extract", "sfm_match", "sfm_reconstruct":
            stage = .reconstructing
        case "train":
            stage = .training
        case "export", "packaging":
            stage = .packaging
        case "downloading":
            stage = .downloading
        case "complete":
            stage = .completed
        case "cancelled":
            stage = .failed
        default:
            stage = fallbackStage
        }

        let prefersRuntimeProgress = {
            guard let basis = remoteProgress.progressBasis?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !basis.isEmpty else {
                return false
            }
            return basis != "stage_only"
        }()

        func clampedProgress(_ value: Double?) -> Double? {
            guard let value else { return nil }
            return max(0.0, min(1.0, value))
        }

        let progress: Double?
        if prefersRuntimeProgress, let runtimeProgress = clampedProgress(remoteProgress.progressFraction) {
            if isAuthoritativeGpuWait {
                progress = max(runtimeProgress, 0.52)
            } else {
            switch stage {
            case .completed:
                progress = 1.0
            case .failed:
                progress = runtimeProgress
            default:
                progress = stageWeightedOverallProgress(
                    stage: stage,
                    runtimeProgress: runtimeProgress
                )
            }
            }
        } else {
            switch stage {
            case .queued:
                if isAuthoritativeGpuWait {
                    progress = max(remoteProgress.progressFraction ?? 0.0, 0.52)
                } else {
                    progress = max(remoteProgress.progressFraction ?? 0.0, 0.24)
                }
            case .reconstructing:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.32)
            case .training:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.48)
            case .packaging:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.82)
            case .downloading:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.94)
            case .completed:
                progress = 1.0
            case .uploading:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.05)
            case .preparing:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.01)
            case .localFallback:
                progress = max(remoteProgress.progressFraction ?? 0.0, 0.82)
            case .failed:
                progress = remoteProgress.progressFraction
            }
        }
        let title: String
        let preferredRemoteTitle = remoteProgress.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = remoteProgress.detail
        let eta: Int?
        switch stage {
        case .queued:
            title = preferredRemoteTitle?.isEmpty == false
                ? preferredRemoteTitle!
                : (backend == .brokeredBackgroundUpload ? "后台已接收任务" : "已提交到丹麦 5090")
            eta = remoteProgress.etaMinutes
        case .reconstructing:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "正在做相机重建"
            eta = remoteProgress.etaMinutes
        case .training:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "远端正在训练 3D 模型"
            eta = remoteProgress.etaMinutes
        case .packaging:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "正在导出并整理结果"
            eta = remoteProgress.etaMinutes
        case .downloading:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "正在回传到手机"
            eta = remoteProgress.etaMinutes
        case .completed:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "远端训练完成"
            eta = remoteProgress.etaMinutes
        case .preparing:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "正在准备任务"
            eta = remoteProgress.etaMinutes
        case .uploading:
            title = preferredRemoteTitle?.isEmpty == false
                ? preferredRemoteTitle!
                : (backend == .brokeredBackgroundUpload ? "正在上传到后台对象存储" : "正在上传到丹麦 5090")
            eta = remoteProgress.etaMinutes
        case .localFallback:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "远端不可用，正在切到本地处理"
            eta = remoteProgress.etaMinutes
        case .failed:
            title = preferredRemoteTitle?.isEmpty == false ? preferredRemoteTitle! : "远端生成失败"
            eta = nil
        }

        var runtimeMetrics = remoteProgress.runtimeMetrics
        if let elapsedSeconds = remoteProgress.elapsedSeconds, elapsedSeconds >= 0 {
            runtimeMetrics["elapsed_seconds"] = String(elapsedSeconds)
            if runtimeMetrics["phase_elapsed_seconds"] == nil {
                runtimeMetrics["phase_elapsed_seconds"] = String(elapsedSeconds)
            }
        }

        return GenerateProgressSnapshot(
            stage: stage,
            progressFraction: progress,
            progressBasis: remoteProgress.progressBasis,
            remoteStageKey: remoteProgress.stageKey,
            remotePhaseName: remoteProgress.phaseName,
            currentTier: remoteProgress.currentTier,
            title: title,
            detail: detail,
            etaMinutes: eta,
            remoteJobId: remoteJobId,
            runtimeMetrics: runtimeMetrics.isEmpty ? nil : runtimeMetrics
        )
    }

    private func uploadProgressSnapshot(
        _ progress: RemoteUploadProgress,
        startedAt startTime: Date,
        remoteJobId: String? = nil
    ) -> GenerateProgressSnapshot {
        if progress.isFinalizing {
            return GenerateProgressSnapshot(
                stage: .uploading,
                progressFraction: 0.219,
                progressBasis: "upload_finalizing",
                title: "正在确认上传",
                detail: "所有分片已发送，正在等待服务器确认并完成合并。",
                etaMinutes: nil,
                remoteJobId: remoteJobId,
                uploadedBytes: progress.uploadedBytes,
                totalBytes: progress.totalBytes,
                uploadBytesPerSecond: nil
            )
        }

        let uploadFraction = progress.fraction ?? 0.0
        let overallFraction = max(0.0, min(0.22, uploadFraction * 0.22))
        let uploadSpeed = smoothedUploadBytesPerSecond(for: progress, startedAt: startTime)
        return GenerateProgressSnapshot(
            stage: .uploading,
            progressFraction: overallFraction,
            progressBasis: "upload_bytes",
            title: backend == .brokeredBackgroundUpload ? "正在上传到后台对象存储" : "正在上传到丹麦 5090",
            detail: "已上传 \(Self.byteString(progress.uploadedBytes)) / \(Self.byteString(progress.totalBytes))",
            etaMinutes: estimatedUploadRemainingMinutes(progress, uploadBytesPerSecond: uploadSpeed),
            remoteJobId: remoteJobId,
            uploadedBytes: progress.uploadedBytes,
            totalBytes: progress.totalBytes,
            uploadBytesPerSecond: uploadSpeed
        )
    }

    private func stageWeightedOverallProgress(
        stage: GenerateProgressStage,
        runtimeProgress: Double
    ) -> Double {
        let clampedRuntime = max(0.0, min(1.0, runtimeProgress))
        let band: ClosedRange<Double>
        switch stage {
        case .preparing:
            band = 0.01...0.04
        case .uploading:
            band = 0.04...0.22
        case .queued:
            band = 0.22...0.24
        case .reconstructing:
            band = 0.24...0.55
        case .training, .localFallback:
            band = 0.55...0.88
        case .packaging:
            band = 0.88...0.96
        case .downloading:
            band = 0.96...0.99
        case .completed:
            band = 1.0...1.0
        case .failed:
            return clampedRuntime
        }
        let weighted = band.lowerBound + clampedRuntime * (band.upperBound - band.lowerBound)
        return max(0.0, min(stage == .completed ? 1.0 : 0.99, weighted))
    }

    private func uploadAwaitingRemoteStartSnapshot(
        totalBytes: Int64
    ) -> GenerateProgressSnapshot {
        GenerateProgressSnapshot(
            stage: .uploading,
            progressFraction: 0.22,
            title: backend == .brokeredBackgroundUpload ? "上传完成，正在等待后端调度" : "上传完成，正在请求丹麦 5090 接单",
            detail: backend == .brokeredBackgroundUpload
                ? "视频已上传 \(Self.byteString(totalBytes))，正在等待后端从对象存储接收并调度可用 GPU。"
                : "视频已上传 \(Self.byteString(totalBytes))，正在等待远端真正接收并启动任务。",
            etaMinutes: nil,
            uploadedBytes: totalBytes,
            totalBytes: totalBytes
        )
    }

    private static func byteString(_ bytes: Int64) -> String {
        if bytes <= 0 {
            return "0 KB"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func smoothedUploadBytesPerSecond(
        for progress: RemoteUploadProgress,
        startedAt startTime: Date
    ) -> Double? {
        progressStateQueue.sync {
            let now = Date()
            let uploadedBytes = max(Int64(0), progress.uploadedBytes)

            if uploadRateEstimate.startedAt == nil ||
                uploadedBytes < (uploadRateEstimate.recentSamples.last?.uploadedBytes ?? 0) {
                uploadRateEstimate = UploadRateEstimate(
                    startedAt: startTime,
                    recentSamples: [UploadRateSample(timestamp: now, uploadedBytes: uploadedBytes)],
                    smoothedBytesPerSecond: nil,
                    lastMeasuredAt: nil
                )
                return nil
            }

            if uploadRateEstimate.startedAt == nil {
                uploadRateEstimate.startedAt = startTime
            }

            uploadRateEstimate.recentSamples.append(
                UploadRateSample(timestamp: now, uploadedBytes: uploadedBytes)
            )

            let minimumSampleDate = now.addingTimeInterval(-4.0)
            uploadRateEstimate.recentSamples.removeAll { $0.timestamp < minimumSampleDate }
            if uploadRateEstimate.recentSamples.count > 48 {
                uploadRateEstimate.recentSamples.removeFirst(uploadRateEstimate.recentSamples.count - 48)
            }

            guard let firstSample = uploadRateEstimate.recentSamples.first,
                  let lastSample = uploadRateEstimate.recentSamples.last else {
                return uploadRateEstimate.smoothedBytesPerSecond
            }

            let deltaTime = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)
            let deltaBytes = lastSample.uploadedBytes - firstSample.uploadedBytes

            guard deltaTime >= 0.75, deltaBytes >= 512 * 1024 else {
                return recentUploadBytesPerSecond(now: now)
            }

            let instantaneousBytesPerSecond = Double(deltaBytes) / deltaTime
            guard instantaneousBytesPerSecond.isFinite, instantaneousBytesPerSecond > 0 else {
                return recentUploadBytesPerSecond(now: now)
            }

            if let smoothed = uploadRateEstimate.smoothedBytesPerSecond {
                uploadRateEstimate.smoothedBytesPerSecond = (smoothed * 0.35) + (instantaneousBytesPerSecond * 0.65)
            } else {
                uploadRateEstimate.smoothedBytesPerSecond = instantaneousBytesPerSecond
            }
            uploadRateEstimate.lastMeasuredAt = now

            return uploadRateEstimate.smoothedBytesPerSecond
        }
    }

    private func recentUploadBytesPerSecond(now: Date) -> Double? {
        guard let smoothed = uploadRateEstimate.smoothedBytesPerSecond,
              smoothed.isFinite,
              smoothed > 0 else {
            return nil
        }

        guard let lastMeasuredAt = uploadRateEstimate.lastMeasuredAt else {
            return smoothed
        }

        return now.timeIntervalSince(lastMeasuredAt) <= 6.0 ? smoothed : nil
    }

    private func estimatedUploadRemainingMinutes(
        _ progress: RemoteUploadProgress,
        uploadBytesPerSecond: Double?
    ) -> Int? {
        guard progress.totalBytes > 0, progress.uploadedBytes > 0 else { return nil }

        let uploaded = Double(progress.uploadedBytes)
        let total = Double(progress.totalBytes)
        guard uploaded >= min(total * 0.03, 8 * 1024 * 1024) else { return nil }

        guard let bytesPerSecond = uploadBytesPerSecond,
              bytesPerSecond.isFinite else { return nil }
        guard bytesPerSecond.isFinite, bytesPerSecond > 64 * 1024 else { return nil }

        let remainingBytes = max(0, total - uploaded)
        guard remainingBytes > 0 else { return 0 }

        let remainingSeconds = remainingBytes / bytesPerSecond
        guard remainingSeconds.isFinite, remainingSeconds > 0 else { return nil }

        return max(1, Int(ceil(remainingSeconds / 60.0)))
    }
    
    // MARK: - New Generate API (Day 2)
    
    func runGenerate(request: BuildRequest, outputRoot: URL) async -> GenerateResult {
        let startTime = Date()
        
        do {
            let videoURL: URL
            switch request.source {
            case .video(let asset):
                #if canImport(AVFoundation)
                guard let urlAsset = asset as? AVURLAsset else {
                    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                    return .fail(reason: .inputInvalid, elapsedMs: elapsed)
                }
                videoURL = urlAsset.url
                #else
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return .fail(reason: .inputInvalid, elapsedMs: elapsed)
                #endif
            case .file(let url):
                videoURL = url
            }
            
            #if canImport(AVFoundation)
            let videoPath = jsonEscape(videoURL.path)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_start",
                detailsJson: "{\"videoPath\":\"\(videoPath)\"}"
            ))
            #endif
            
            let stagingId = UUID().uuidString
            let stagingDir = outputRoot.appendingPathComponent(".staging-\(stagingId)")
            
            defer {
                try? FileManager.default.removeItem(at: stagingDir)
            }
            
            print("[Whitebox] outputRoot=\(outputRoot.path)")
            print("[Whitebox] stagingDir=\(stagingDir.path)")
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            
            let artifactsDir = stagingDir.appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
            
            let jobId: String
            switch backend {
            case .brokeredBackgroundUpload:
                guard let brokerClient else {
                    throw RemoteB1ClientError.notConfigured
                }
                let preparedUploadURL = try await brokerClient.prepareUploadSource(videoURL: videoURL)
                do {
                    let creation = try await brokerClient.createJob(
                        videoURL: preparedUploadURL,
                        captureOrigin: "mobile_app",
                        pipelineProfile: request.frameSamplingProfile.pipelineProfilePayload
                    )
                    do {
                        jobId = try await brokerClient.startUpload(
                            jobId: creation.jobId,
                            upload: creation.upload,
                            sourceURL: preparedUploadURL,
                            onProgress: nil
                        )
                    } catch {
                        brokerClient.cleanupPreparedUploadSourceIfNeeded(preparedUploadURL)
                        throw error
                    }
                } catch {
                    brokerClient.cleanupPreparedUploadSourceIfNeeded(preparedUploadURL)
                    throw error
                }
            case .localEmbedded, .danishGoldenSSH:
                guard let remoteClient else {
                    throw RemoteB1ClientError.notConfigured
                }
                let assetId = try await remoteClient.upload(videoURL: videoURL)
                jobId = try await remoteClient.startJob(assetId: assetId)
            }

            let (plyData, _) = try await self.pollAndDownload(jobId: jobId, onProgress: nil)
            
            let plyPath = artifactsDir.appendingPathComponent("model.ply")
            try plyData.write(to: plyPath, options: Data.WritingOptions.atomic)
            print("[Whitebox] wrote ply at \(plyPath.path) bytes=\(plyData.count)")
            
            let files = try computeFileDescriptors(in: stagingDir)
            print("[Whitebox] files discovered: \(files.map { $0.path })")
            
            let policyHash = getCurrentPolicyHash()
            
            let artifactHash = computeArtifactHash(
                policyHash: policyHash,
                schemaVersion: 1,
                files: files
            )
            
            let manifest = WhiteboxArtifactManifest(
                schemaVersion: 1,
                artifactId: String(artifactHash.prefix(8)),
                policyHash: policyHash,
                artifactHash: artifactHash,
                files: files
            )
            
            try validateManifest(manifest)
            
            let manifestData = CanonicalEncoder.encode(manifest)
            let manifestURL = stagingDir.appendingPathComponent("manifest.json")
            try manifestData.write(to: manifestURL)
            print("[Whitebox] wrote manifest at \(manifestURL.path) bytes=\(manifestData.count)")
            
            try validatePackage(at: stagingDir, manifest: manifest)
            print("[Whitebox] validatePackage OK")
            
            let artifactIdJson = jsonEscape(manifest.artifactId)
            let artifactHashJson = jsonEscape(manifest.artifactHash)
            let policyHashJson = jsonEscape(manifest.policyHash)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "artifact.produced",
                detailsJson: "{\"artifactId\":\"\(artifactIdJson)\",\"artifactHash\":\"\(artifactHashJson)\",\"policyHash\":\"\(policyHashJson)\"}"
            ))
            
            let finalDir = outputRoot.appendingPathComponent(manifest.artifactId)
            
            if FileManager.default.fileExists(atPath: finalDir.path) {
                try FileManager.default.removeItem(at: finalDir)
            }
            
            try FileManager.default.moveItem(at: stagingDir, to: finalDir)
            print("[Whitebox] moved to finalDir=\(finalDir.path)")
            
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            let artifactPath = jsonEscape(finalDir.path)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_success",
                detailsJson: "{\"artifactPath\":\"\(artifactPath)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .success(artifact: ArtifactRef(localPath: finalDir, format: .splatPly), elapsedMs: elapsed)
            
        } catch let error as FailReason where error == .stalledProcessing {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            #if canImport(AVFoundation)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"stalled_processing\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            return .fail(reason: .stalledProcessing, elapsedMs: elapsed)
            
        } catch let error as FailReason {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            let reasonStr = jsonEscape(error.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: error, elapsedMs: elapsed)
            
        } catch let error as RemoteB1ClientError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let reason = mapRemoteB1ClientError(error)
            let detail = detailedRemoteFailureMessage(for: error, mappedReason: reason)
            
            #if canImport(AVFoundation)
            let reasonStr = jsonEscape(reason.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                    detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            await emitProgress(
                failureSnapshot(for: reason, detailOverride: detail),
                to: nil
            )
            
            return .fail(reason: reason, elapsedMs: elapsed)
            
        } catch {
            print("[Whitebox] generate failed with error: \(error)")
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"unknown_error\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: .unknownError, elapsedMs: elapsed)
        }
    }
    
    public func runGenerate(
        request: BuildRequest,
        clientRecordId: UUID? = nil,
        progressHandler: (@Sendable (GenerateProgressSnapshot) async -> Void)? = nil
    ) async -> GenerateResult {
        #if canImport(AVFoundation)
        let startTime = Date()
        
        do {
            let videoURL: URL
            switch request.source {
            case .video(let asset):
                guard let urlAsset = asset as? AVURLAsset else {
                    let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                    return .fail(reason: .inputInvalid, elapsedMs: elapsed)
                }
                videoURL = urlAsset.url
            case .file(let url):
                videoURL = url
            }
            
            #if canImport(AVFoundation)
            // 审计：generate_start
            let videoPath = jsonEscape(videoURL.path)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_start",
                detailsJson: "{\"videoPath\":\"\(videoPath)\"}"
            ))
            #endif

            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .preparing,
                    progressFraction: 0.01,
                    title: "正在准备远端任务",
                    detail: backend == .brokeredBackgroundUpload
                        ? "会先检查视频，然后交给后台上传与任务调度服务。"
                        : "会先检查视频，然后上传到丹麦 5090。",
                    etaMinutes: nil
                ),
                to: progressHandler
            )

            if backend == .brokeredBackgroundUpload {
                return try await runBrokeredGenerate(
                    videoURL: videoURL,
                    clientRecordId: clientRecordId,
                    frameSamplingProfile: request.frameSamplingProfile,
                    startTime: startTime,
                    progressHandler: progressHandler
                )
            }

            guard let remoteClient else {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return .fail(reason: .apiNotConfigured, elapsedMs: elapsed)
            }
            
            // Upload video
            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .uploading,
                    progressFraction: 0.0,
                    title: "正在上传到丹麦 5090",
                    detail: "会显示真实上传进度，只有远端真正接单后才会切到排队与训练阶段。",
                    etaMinutes: nil
                ),
                to: progressHandler
            )
            let uploadStartedAt = Date()
            let assetId = try await remoteClient.upload(videoURL: videoURL) { [weak self] progress in
                guard let self else { return }
                await self.emitProgress(
                    self.uploadProgressSnapshot(progress, startedAt: uploadStartedAt),
                    to: progressHandler
                )
            }

            let totalBytes = Int64((try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? NSNumber)?.int64Value ?? 0)
            await emitProgress(
                uploadAwaitingRemoteStartSnapshot(totalBytes: max(totalBytes, 1)),
                to: progressHandler
            )
            
            // Start job
            let jobId = try await remoteClient.startJob(assetId: assetId)
            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .queued,
                    progressFraction: 0.24,
                    title: "丹麦 5090 已接收任务",
                    detail: "上传已经结束，远端启动脚本也已确认接单，现在才正式进入排队与训练阶段。",
                    etaMinutes: nil,
                    remoteJobId: jobId
                ),
                to: progressHandler
            )
            
            // Poll and download
            let (splatData, format) = try await self.pollAndDownload(jobId: jobId, onProgress: progressHandler)
            
            // Write to Documents/Whitebox/
            let url = try self.writeSplatToDocuments(data: splatData, format: format, jobId: jobId)
            
            let artifact = ArtifactRef(localPath: url, format: format)
            
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_success
            let artifactPath = jsonEscape(artifact.localPath.path)
            let formatStr = jsonEscape(artifact.format == .splat ? "splat" : "splatPly")
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_success",
                detailsJson: "{\"artifactPath\":\"\(artifactPath)\",\"format\":\"\(formatStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif

            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .completed,
                    progressFraction: 1.0,
                    title: "3DGS 已回传到手机",
                    detail: "现在可以进入黑色 3D 空间查看结果。",
                    etaMinutes: nil
                ),
                to: progressHandler
            )
            
            return .success(artifact: artifact, elapsedMs: elapsed)
            
        } catch let error as FailReason where error == .stalledProcessing {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            #if canImport(AVFoundation)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"stalled_processing\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            await emitProgress(failureSnapshot(for: .stalledProcessing), to: progressHandler)
            return .fail(reason: .stalledProcessing, elapsedMs: elapsed)
            
        } catch let error as FailReason {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (FailReason)
            let reasonStr = jsonEscape(error.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            await emitProgress(failureSnapshot(for: error), to: progressHandler)
            
            return .fail(reason: error, elapsedMs: elapsed)
            
        } catch let error as RemoteB1ClientError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let reason = mapRemoteB1ClientError(error)
            let detail = detailedRemoteFailureMessage(for: error, mappedReason: reason)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (RemoteB1ClientError)
            let reasonStr = jsonEscape(reason.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                    detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            await emitProgress(
                failureSnapshot(for: reason, detailOverride: detail),
                to: progressHandler
            )
            
            return .fail(reason: reason, elapsedMs: elapsed)
            
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (unknown)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: Date(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"unknown_error\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            await emitProgress(
                failureSnapshot(for: .unknownError, detailOverride: genericFailureDetail(error)),
                to: progressHandler
            )
            
            return .fail(reason: .unknownError, elapsedMs: elapsed)
        }
        #else
        // Linux stub: AVFoundation unavailable
        fatalError("AVFoundation unavailable on this platform")
        #endif
    }

    private func runBrokeredGenerate(
        videoURL: URL,
        clientRecordId: UUID?,
        frameSamplingProfile: FrameSamplingProfile,
        startTime: Date,
        progressHandler: (@Sendable (GenerateProgressSnapshot) async -> Void)?
    ) async throws -> GenerateResult {
        guard let brokerClient else {
            throw RemoteB1ClientError.notConfigured
        }

        let prepareStartedAt = Date()
        let prepareFirstBytesRecorder = FirstPreparedBytesRecorder()
        var prepareCompletedAt: Date? = nil

        await emitProgress(
            GenerateProgressSnapshot(
                stage: .preparing,
                progressFraction: stageWeightedOverallProgress(stage: .preparing, runtimeProgress: 0.06),
                progressBasis: "prepare_inspecting_source",
                title: "正在检查原视频",
                detail: "正在确认视频可读、时长正常，并挑选最合适的流式重封装方案。",
                etaMinutes: nil
            ),
            to: progressHandler
        )

        let preparedUploadURL = try await brokerClient.prepareUploadSource(videoURL: videoURL) { [weak self] progress in
            guard let self else { return }
            if let preparedBytesRaw = progress.metrics["prepared_file_bytes"],
               let preparedBytes = Int64(preparedBytesRaw) {
                prepareFirstBytesRecorder.recordIfNeeded(preparedBytes: preparedBytes)
            }
            await self.emitProgress(
                GenerateProgressSnapshot(
                    stage: .preparing,
                    progressFraction: self.stageWeightedOverallProgress(stage: .preparing, runtimeProgress: progress.progressFraction),
                    progressBasis: progress.phase,
                    title: progress.title,
                    detail: progress.detail,
                    etaMinutes: nil,
                    runtimeMetrics: progress.metrics
                ),
                to: progressHandler
            )
        }
        prepareCompletedAt = Date()

        await emitProgress(
            GenerateProgressSnapshot(
                stage: .uploading,
                progressFraction: 0.0,
                title: "正在发起后台上传任务",
                detail: "会先向上传服务申请任务，然后交给 iOS 后台上传，不再直接持有 GPU 的 SSH 连接。",
                etaMinutes: nil
            ),
            to: progressHandler
        )

        let uploadStartedAt = Date()
        let creation: BrokerCreateJobResponse
        do {
            creation = try await brokerClient.createJob(
                videoURL: preparedUploadURL,
                clientRecordId: clientRecordId,
                captureOrigin: "mobile_app",
                pipelineProfile: frameSamplingProfile.pipelineProfilePayload
            )
        } catch {
            brokerClient.cleanupPreparedUploadSourceIfNeeded(preparedUploadURL)
            throw error
        }
        let jobId = creation.jobId
        await brokerClient.sendClientEvent(jobId: jobId, eventType: "mobile_prepare_started", eventAt: prepareStartedAt)
        if let prepareFirstBytesAt = prepareFirstBytesRecorder.value() {
            await brokerClient.sendClientEvent(
                jobId: jobId,
                eventType: "mobile_prepare_first_bytes_written",
                eventAt: prepareFirstBytesAt
            )
        }
        if let prepareCompletedAt {
            await brokerClient.sendClientEvent(
                jobId: jobId,
                eventType: "mobile_prepare_streaming_ready",
                eventAt: prepareCompletedAt
            )
        }
        let prepareFinalizationTask = Task { [brokerClient, preparedUploadURL, jobId] in
            do {
                if let finalizedAt = try await brokerClient.waitForPreparedUploadSourceFinalization(preparedUploadURL) {
                    await brokerClient.sendClientEvent(
                        jobId: jobId,
                        eventType: "mobile_prepare_completed",
                        eventAt: finalizedAt
                    )
                }
            } catch {
                return
            }
        }
        defer {
            prepareFinalizationTask.cancel()
        }

        let uploadMonitor = BrokerUploadMonitor()
        _ = Task { [weak self] in
            guard let self else { return }
            do {
                await brokerClient.sendClientEvent(
                    jobId: jobId,
                    eventType: "upload_started",
                    eventAt: Date()
                )
                _ = try await brokerClient.startUpload(
                    jobId: jobId,
                    upload: creation.upload,
                    sourceURL: preparedUploadURL,
                    onProgress: { [weak self] progress in
                        guard let self else { return }
                        await self.emitProgress(
                            self.uploadProgressSnapshot(progress, startedAt: uploadStartedAt, remoteJobId: jobId),
                            to: progressHandler
                        )
                    }
                )
            } catch {
                brokerClient.cleanupPreparedUploadSourceIfNeeded(preparedUploadURL)
                await uploadMonitor.markFailed(error)
            }
        }

        await emitProgress(
            GenerateProgressSnapshot(
                stage: .uploading,
                progressFraction: 0.01,
                title: "后台上传已接管",
                detail: "视频已建单。上传继续进行的同时，后端状态也会立即开始刷新；一旦远端开始预处理，这里会立刻切过去。",
                etaMinutes: nil,
                remoteJobId: jobId
            ),
            to: progressHandler
        )

        let (splatData, format) = try await self.pollAndDownload(
            jobId: jobId,
            onProgress: progressHandler,
            statusReconciler: { status in
                try await uploadMonitor.reconcile(with: status)
            }
        )
        // Once the artifact is back on-device, finish immediately instead of
        // waiting on background-upload bookkeeping that can linger after the
        // remote job is already done.
        prepareFinalizationTask.cancel()
        let url = try self.writeSplatToDocuments(data: splatData, format: format, jobId: jobId)
        let artifact = ArtifactRef(localPath: url, format: format)
        let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

        #if canImport(AVFoundation)
        let artifactPath = jsonEscape(artifact.localPath.path)
        let formatStr = jsonEscape(artifact.format == .splat ? "splat" : artifact.format == .spz ? "spz" : "splatPly")
        PlainAuditLog.shared.append(AuditEntry(
            timestamp: Date(),
            eventType: "generate_success",
            detailsJson: "{\"artifactPath\":\"\(artifactPath)\",\"format\":\"\(formatStr)\",\"elapsedMs\":\(elapsed),\"backend\":\"brokered_background_upload\"}"
        ))
        #endif

        await emitProgress(
            GenerateProgressSnapshot(
                stage: .completed,
                progressFraction: 1.0,
                title: "3DGS 已回传到手机",
                detail: "对象存储与后端调度这条链已经完成，现在可以进入黑色 3D 空间查看结果。",
                etaMinutes: nil,
                remoteJobId: jobId
            ),
            to: progressHandler
        )

        return .success(artifact: artifact, elapsedMs: elapsed)
    }
    
    // MARK: - Private Helpers

    private func pollRemoteStatus(jobId: String) async throws -> JobStatus {
        switch backend {
        case .brokeredBackgroundUpload:
            guard let brokerClient else { throw RemoteB1ClientError.notConfigured }
            return try await brokerClient.pollStatus(jobId: jobId)
        case .localEmbedded, .danishGoldenSSH:
            guard let remoteClient else { throw RemoteB1ClientError.notConfigured }
            return try await remoteClient.pollStatus(jobId: jobId)
        }
    }

    private func downloadRemoteArtifact(
        jobId: String,
        onProgress: (@Sendable (GenerateProgressSnapshot) async -> Void)? = nil
    ) async throws -> (data: Data, format: ArtifactFormat) {
        switch backend {
        case .brokeredBackgroundUpload:
            guard let brokerClient else { throw RemoteB1ClientError.notConfigured }
            await brokerClient.sendClientEvent(jobId: jobId, eventType: "mobile_download_started", eventAt: Date())
            let result = try await brokerClient.download(jobId: jobId) { [weak self] downloadedBytes, totalBytes in
                guard let self else { return }
                let safeTotalBytes = max(downloadedBytes, totalBytes)
                let ratio: Double? = safeTotalBytes > 0
                    ? min(max(Double(downloadedBytes) / Double(safeTotalBytes), 0.0), 1.0)
                    : nil
                await self.emitProgress(
                    GenerateProgressSnapshot(
                        stage: .downloading,
                        progressFraction: self.stageWeightedOverallProgress(
                            stage: .downloading,
                            runtimeProgress: ratio ?? 0.0
                        ),
                        progressBasis: "download_bytes",
                        remoteStageKey: "download",
                        remotePhaseName: "download",
                        title: "正在回传到手机",
                        detail: "手机正在接收 3DGS 结果文件。",
                        etaMinutes: nil,
                        remoteJobId: jobId,
                        runtimeMetrics: [
                            "downloaded_bytes": String(downloadedBytes),
                            "download_total_bytes": String(safeTotalBytes),
                            "current_units": String(downloadedBytes),
                            "target_units": String(safeTotalBytes),
                            "unit_label": "bytes"
                        ]
                    ),
                    to: onProgress
                )
            }
            await brokerClient.sendClientEvent(jobId: jobId, eventType: "mobile_download_completed", eventAt: Date())
            return result
        case .localEmbedded, .danishGoldenSSH:
            guard let remoteClient else { throw RemoteB1ClientError.notConfigured }
            return try await remoteClient.download(jobId: jobId)
        }
    }

    private func cancelRemoteJob(jobId: String) async throws {
        switch backend {
        case .brokeredBackgroundUpload:
            guard let brokerClient else { throw RemoteB1ClientError.notConfigured }
            try await brokerClient.cancel(jobId: jobId)
        case .localEmbedded, .danishGoldenSSH:
            guard let remoteClient else { throw RemoteB1ClientError.notConfigured }
            try await remoteClient.cancel(jobId: jobId)
        }
    }
    
    /// Polls for job completion with stall detection.
    /// - If progress does not change for `stallTimeoutSeconds`, throws `FailReason.stalledProcessing`
    /// - If total elapsed exceeds `absoluteMaxTimeoutSeconds`, throws `FailReason.stalledProcessing`
    #if canImport(UIKit)
    private final class PollingBackgroundTaskBox: @unchecked Sendable {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        var ended = false
    }

    private func endPollingBackgroundTask(_ box: PollingBackgroundTaskBox) async {
        await MainActor.run {
            guard !box.ended, box.identifier != .invalid else { return }
            let identifier = box.identifier
            box.identifier = .invalid
            box.ended = true
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func withPollingBackgroundTask<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let appState = await MainActor.run { UIApplication.shared.applicationState }
        guard appState != .active else {
            return try await operation()
        }

        let box = PollingBackgroundTaskBox()
        box.identifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "PipelinePoll") {
                guard !box.ended, box.identifier != .invalid else { return }
                let identifier = box.identifier
                box.identifier = .invalid
                box.ended = true
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }

        return try await withTaskCancellationHandler(
            operation: {
                do {
                    let value = try await operation()
                    await endPollingBackgroundTask(box)
                    return value
                } catch {
                    await endPollingBackgroundTask(box)
                    throw error
                }
            },
            onCancel: {
                Task {
                    await self.endPollingBackgroundTask(box)
                }
            }
        )
    }
    #endif

    internal func pollAndDownload(
        jobId: String,
        onProgress: (@Sendable (GenerateProgressSnapshot) async -> Void)?,
        statusReconciler: (@Sendable (JobStatus) async throws -> Void)? = nil
    ) async throws -> (data: Data, format: ArtifactFormat) {
        let pollInterval = PipelineTimeoutConstants.pollIntervalSeconds
        let queuedPollInterval = PipelineTimeoutConstants.pollIntervalQueuedSeconds
        let stallTimeout = PipelineTimeoutConstants.stallTimeoutSeconds
        let absoluteMax = PipelineTimeoutConstants.absoluteMaxTimeoutSeconds
        let pollErrorGrace = PipelineTimeoutConstants.backgroundGracePeriodSeconds
        let minDelta = PipelineTimeoutConstants.stallMinProgressDelta

        let startTime = Date()
        var lastProgressValue: Double? = nil
        var lastProgressChangeTime = Date()
        var lastProcessingSignature: String? = nil
        var lastSuccessfulStatusPollTime = Date()

        while true {
            // 1. Absolute timeout check
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > absoluteMax {
                throw FailReason.stalledProcessing
            }

            // 2. Poll server
            let status: JobStatus
            do {
                #if canImport(UIKit)
                status = try await withPollingBackgroundTask {
                    try await self.pollRemoteStatus(jobId: jobId)
                }
                #else
                status = try await self.pollRemoteStatus(jobId: jobId)
                #endif
                lastSuccessfulStatusPollTime = Date()
            } catch {
                if shouldGracefullyRetryStatusPoll(error) {
                    let outageDuration = Date().timeIntervalSince(lastSuccessfulStatusPollTime)
                    if outageDuration <= pollErrorGrace {
                        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                        continue
                    }
                }
                throw error
            }

            if let statusReconciler {
                try await statusReconciler(status)
            }

            switch status {
            case .downloadReady(let progress):
            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .downloading,
                    progressFraction: 0.96,
                    title: "远端已预上传结果，正在提前回传",
                    detail: progress.detail ?? "主 3DGS 结果已经提前进入对象存储，手机现在开始边收尾边下载。",
                    etaMinutes: nil,
                    remoteJobId: jobId,
                    runtimeMetrics: progress.runtimeMetrics
                ),
                to: onProgress
            )
                return try await self.downloadRemoteArtifact(jobId: jobId, onProgress: onProgress)

            case .completed(let progress):
            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .downloading,
                    progressFraction: 0.97,
                    title: "远端训练完成，正在回传结果",
                    detail: progress?.detail ?? "手机会自动接收 3DGS 结果文件。",
                    etaMinutes: nil,
                    remoteJobId: jobId
                ),
                to: onProgress
            )
                return try await self.downloadRemoteArtifact(jobId: jobId, onProgress: onProgress)

            case .failed(let reason, let progress):
                if let progress {
                    await emitProgress(progressSnapshot(from: progress, fallbackStage: .failed, remoteJobId: jobId), to: onProgress)
                }
                let remoteDetail = progress?.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !remoteDetail.isEmpty, remoteDetail != reason {
                    throw RemoteB1ClientError.jobFailed(remoteDetail)
                }
                throw RemoteB1ClientError.jobFailed(reason)

            case .pending(let progress):
                await emitProgress(progressSnapshot(from: progress, fallbackStage: .queued, remoteJobId: jobId), to: onProgress)
                // Queued — use longer poll interval, no stall detection yet
                try await Task.sleep(nanoseconds: UInt64(queuedPollInterval * 1_000_000_000))
                continue

            case .processing(let progress):
                await emitProgress(progressSnapshot(from: progress, fallbackStage: .training, remoteJobId: jobId), to: onProgress)
                let currentProgress = progress.progressFraction ?? 0.0
                let currentSignature = processingLivenessSignature(progress)

                // 3. Stall detection: has progress changed?
                if let lastProgress = lastProgressValue {
                    let delta = abs(currentProgress - lastProgress)
                    if delta >= minDelta || currentSignature != lastProcessingSignature {
                        // Progress is moving — reset stall timer
                        lastProgressValue = currentProgress
                        lastProcessingSignature = currentSignature
                        lastProgressChangeTime = Date()
                    } else {
                        // Progress stalled — check stall timeout
                        let stallDuration = Date().timeIntervalSince(lastProgressChangeTime)
                        if stallDuration > stallTimeout {
                            throw FailReason.stalledProcessing
                        }
                    }
                } else {
                    // First progress value — initialize tracking
                    lastProgressValue = currentProgress
                    lastProcessingSignature = currentSignature
                    lastProgressChangeTime = Date()
                }

                // Enforce monotonicity: never decrease progress
                if let lastProgress = lastProgressValue, currentProgress < lastProgress {
                    // Progress regression: ignore, don't reset timer
                    // Continue with last known progress
                } else {
                    lastProgressValue = currentProgress
                }
                lastProcessingSignature = currentSignature

                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
    }

    public func resumeGenerate(
        jobId: String,
        progressHandler: (@Sendable (GenerateProgressSnapshot) async -> Void)? = nil
    ) async -> GenerateResult {
        let startTime = Date()

        await emitProgress(
            GenerateProgressSnapshot(
                stage: .queued,
                progressFraction: nil,
                title: "正在重新连接远端任务",
                detail: backend == .brokeredBackgroundUpload
                    ? "会继续轮询后台任务状态，并在完成后自动回传结果。"
                    : "会继续轮询丹麦 5090，并在完成后自动回传结果。",
                etaMinutes: nil,
                remoteJobId: jobId
            ),
            to: progressHandler
        )

        do {
            let (splatData, format) = try await self.pollAndDownload(jobId: jobId, onProgress: progressHandler)
            let url = try self.writeSplatToDocuments(data: splatData, format: format, jobId: jobId)
            let artifact = ArtifactRef(localPath: url, format: format)
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            await emitProgress(
                GenerateProgressSnapshot(
                    stage: .completed,
                    progressFraction: 1.0,
                    title: "3DGS 已回传到手机",
                    detail: "现在可以进入黑色 3D 空间查看结果。",
                    etaMinutes: nil,
                    remoteJobId: jobId
                ),
                to: progressHandler
            )

            return .success(artifact: artifact, elapsedMs: elapsed)
        } catch let error as FailReason {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            await emitProgress(failureSnapshot(for: error, remoteJobId: jobId), to: progressHandler)
            return .fail(reason: error, elapsedMs: elapsed)
        } catch let error as RemoteB1ClientError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let reason = mapRemoteB1ClientError(error)
            let detail = detailedRemoteFailureMessage(for: error, mappedReason: reason)
            await emitProgress(
                failureSnapshot(for: reason, remoteJobId: jobId, detailOverride: detail),
                to: progressHandler
            )
            return .fail(reason: reason, elapsedMs: elapsed)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            await emitProgress(
                failureSnapshot(
                    for: .unknownError,
                    remoteJobId: jobId,
                    detailOverride: genericFailureDetail(error)
                ),
                to: progressHandler
            )
            return .fail(reason: .unknownError, elapsedMs: elapsed)
        }
    }

    public func cancelGenerate(jobId: String) async -> Bool {
        do {
            try await cancelRemoteJob(jobId: jobId)
            return true
        } catch {
            return false
        }
    }
    
    private func writeSplatToDocuments(data: Data, format: ArtifactFormat, jobId: String) throws -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let whiteboxDir = documentsPath.appendingPathComponent("Whitebox", isDirectory: true)
        
        try FileManager.default.createDirectory(at: whiteboxDir, withIntermediateDirectories: true)
        
        let fileName: String
        switch format {
        case .splat:
            fileName = "\(jobId).splat"
        case .splatPly:
            fileName = "\(jobId).ply"
        case .spz:
            fileName = "\(jobId).spz"
        }
        let fileURL = whiteboxDir.appendingPathComponent(fileName)
        
        try data.write(to: fileURL)
        
        return fileURL
    }
    
    private func mapRemoteB1ClientError(_ error: RemoteB1ClientError) -> FailReason {
        switch error {
        case .notConfigured:
            return .apiNotConfigured
        case .networkTimeout:
            return .networkTimeout
        case .uploadFailed:
            return .uploadFailed
        case .downloadFailed:
            return .downloadFailed
        case .jobFailed(let reason):
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "upload_failed"
                || normalized.contains("upload_aborted")
                || normalized.contains("后台上传在流式分片阶段中断")
                || normalized.contains("后台上传中断") {
                return .uploadFailed
            }
            if normalized.contains("worker_orphaned_assignment")
                || normalized.contains("worker_stalled_or_runtime_stale")
                || reason.contains("worker 记录已经不存在")
                || reason.contains("worker 当前已经不再承接这条 job")
                || reason.contains("worker 已经不再承接这条 job")
                || reason.contains("worker 已经空闲")
                || reason.contains("worker 心跳已经过期") {
                return .stalledProcessing
            }
            return .apiError
        case .networkError, .invalidResponse:
            return .apiError
        }
    }
    
    private func computeFileDescriptors(in root: URL) throws -> [WhiteboxFileDescriptor] {
        let fm = FileManager.default
        let artifactsDir = root.appendingPathComponent("artifacts")
        var files: [WhiteboxFileDescriptor] = []
        
        guard let enumerator = fm.enumerator(
            at: artifactsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return []
        }
        
        let rootStd = root.resolvingSymlinksInPath()
        while let url = enumerator.nextObject() as? URL {
            let rv = try url.resourceValues(forKeys: [.isRegularFileKey])
            if rv.isRegularFile == true {
                let data = try Data(contentsOf: url)
                let hash = _hexLowercase(ArtifactSHA256.hash(data: data))
                let urlStd = url.resolvingSymlinksInPath()
                var relPath = urlStd.path.replacingOccurrences(of: rootStd.path + "/", with: "")
                if relPath.hasPrefix("/") {
                    relPath.removeFirst()
                }
                files.append(WhiteboxFileDescriptor(
                    bytes: data.count,
                    path: relPath,
                    sha256: hash
                ))
            }
        }
        
        return files.sorted { $0.path < $1.path }
    }
}
