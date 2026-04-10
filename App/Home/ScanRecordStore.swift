//
// ScanRecordStore.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Record Store
// Thread-safe JSON persistence with atomic writes and crash recovery
// Apple-platform only (uses FileManager document directory)
//

import Foundation
import Aether3DCore

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit) || canImport(AppKit)

/// Thread-safe JSON persistence for scan records
///
/// Storage layout:
///   Documents/Aether3D/scans.json       — JSON array of ScanRecord
///   Documents/Aether3D/thumbnails/      — JPEG thumbnails (one per scan)
///   Documents/Aether3D/exports/         — Final PLY / JSON outputs
///   Documents/Aether3D/imports/         — Imported or staged videos for retry
public final class ScanRecordStore {
    private final class DurationResolutionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0

        func store(_ newValue: TimeInterval) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func load() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class BlockingSignal: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func signal() {
            semaphore.signal()
        }

        @discardableResult
        func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
            semaphore.wait(timeout: timeout)
        }
    }

    private static let staleLocalFrozenStatusMessage = "这条旧本地任务不会自动重新排队"
    private static let staleLocalFrozenDetailMessage = "这是之前停在本地处理阶段的旧记录。为了避免旧素材一打开 app 就自动重新排队，系统已经把它标记为已取消。原始视频仍保留在手机里；只有你手动点“重新运行本地处理”时，才会再次使用这段视频。"

    private let baseDirectory: URL
    private let jsonFileURL: URL
    private let backupFileURL: URL
    private let thumbnailsDirectory: URL
    private let exportsDirectory: URL
    private let importsDirectory: URL
    private let queue = DispatchQueue(label: "com.aether3d.scanrecordstore", qos: .utility)
    private let maxRecords = 1000
    private var cachedRecords: [ScanRecord]?

    public init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseDirectory = documents.appendingPathComponent("Aether3D")
        self.jsonFileURL = baseDirectory.appendingPathComponent("scans.json")
        self.backupFileURL = baseDirectory.appendingPathComponent("scans.json.bak")
        self.thumbnailsDirectory = baseDirectory.appendingPathComponent("thumbnails")
        self.exportsDirectory = baseDirectory.appendingPathComponent("exports")
        self.importsDirectory = baseDirectory.appendingPathComponent("imports")

        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
    }

    public func baseDirectoryURL() -> URL {
        baseDirectory
    }

    public func loadRecords() -> [ScanRecord] {
        queue.sync {
            let records = loadRecordsUnsafe()
            cachedRecords = records
            return records
        }
    }

    @discardableResult
    public func freezeStaleProcessingRecords(
        now: Date = Date(),
        localPendingGraceSeconds: TimeInterval = 5 * 60,
        remotePendingGraceSeconds: TimeInterval = 6 * 60 * 60
    ) -> Bool {
        queue.sync {
            var records = loadRecordsUnsafe()
            var didMutate = false

            for index in records.indices {
                guard records[index].artifactPath == nil, records[index].isProcessing else {
                    continue
                }

                let age = now.timeIntervalSince(records[index].updatedAt)
                let remoteJobId = records[index].remoteJobId?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let hasRemoteJob = !(remoteJobId?.isEmpty ?? true)

                if !hasRemoteJob, age >= localPendingGraceSeconds {
                    records[index].status = .cancelled
                    records[index].statusMessage = Self.staleLocalFrozenStatusMessage
                    records[index].detailMessage = Self.staleLocalFrozenDetailMessage
                    records[index].progressFraction = nil
                    records[index].uploadedBytes = nil
                    records[index].totalBytes = nil
                    records[index].uploadBytesPerSecond = nil
                    records[index].estimatedRemainingMinutes = nil
                    records[index].remoteJobId = nil
                    records[index].failureReason = "stale_local_processing_frozen"
                    didMutate = true
                    continue
                }

                if hasRemoteJob, age >= remotePendingGraceSeconds {
                    records[index].status = .cancelled
                    records[index].statusMessage = "这条旧远端任务已停止自动恢复"
                    records[index].detailMessage = "这是较早之前的历史远端任务。为了避免 app 每次打开都自动继续轮询，这条记录已经被冻结。原始视频仍保留在手机里；如果你还想继续，请手动重新发送。"
                    records[index].progressFraction = nil
                    records[index].uploadedBytes = nil
                    records[index].totalBytes = nil
                    records[index].uploadBytesPerSecond = nil
                    records[index].estimatedRemainingMinutes = nil
                    records[index].remoteJobId = nil
                    records[index].failureReason = "stale_remote_processing_frozen"
                    didMutate = true
                }
            }

            if didMutate {
                cachedRecords = records
                writeRecordsToDisk(records)
            }

            return didMutate
        }
    }

    @discardableResult
    public func purgeExpiredFrozenPlaceholderRecords(
        now: Date = Date(),
        maxAgeSeconds: TimeInterval = 24 * 60 * 60
    ) -> Int {
        queue.sync {
            var records = loadRecordsUnsafe()
            let originalCount = records.count
            let removableIDs = Set(
                records.compactMap { record -> UUID? in
                    guard record.artifactPath == nil else { return nil }
                    guard now.timeIntervalSince(record.updatedAt) >= maxAgeSeconds else { return nil }
                    switch record.failureReason {
                    case "stale_local_processing_frozen", "stale_remote_processing_frozen":
                        return record.id
                    default:
                        return nil
                    }
                }
            )

            guard !removableIDs.isEmpty else { return 0 }

            let removedRecords = records.filter { removableIDs.contains($0.id) }
            records.removeAll { removableIDs.contains($0.id) }

            for removedRecord in removedRecords {
                cleanupThumbnail(for: removedRecord.id)
                if let artifactPath = removedRecord.artifactPath {
                    cleanupArtifact(relativePath: artifactPath)
                }
                if let sourceVideoPath = removedRecord.sourceVideoPath {
                    cleanupArtifact(relativePath: sourceVideoPath)
                }
            }

            cachedRecords = records
            writeRecordsToDisk(records)
            return originalCount - records.count
        }
    }

    public func orphanedLocalProcessingRecordsOnColdLaunch() -> [ScanRecord] {
        queue.sync {
            let records = loadRecordsUnsafe()
            cachedRecords = records
            return records.filter { record in
                let trimmedRemoteJobID = record.remoteJobId?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return record.artifactPath == nil &&
                    record.isProcessing &&
                    record.resolvedProcessingBackend == .localSubjectFirst &&
                    trimmedRemoteJobID.isEmpty
            }
        }
    }

    @discardableResult
    public func failOrphanedLocalProcessingRecordsOnColdLaunch(
        now: Date = Date(),
        excludingRecordIDs: Set<UUID> = []
    ) -> Int {
        queue.sync {
            var records = loadRecordsUnsafe()
            var mutatedCount = 0

            for index in records.indices {
                let trimmedRemoteJobID = records[index].remoteJobId?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard records[index].artifactPath == nil,
                      records[index].isProcessing,
                      records[index].resolvedProcessingBackend == .localSubjectFirst,
                      !excludingRecordIDs.contains(records[index].id),
                      trimmedRemoteJobID.isEmpty else {
                    continue
                }

                let startedAt = records[index].processingStartedAt ?? records[index].createdAt
                let recoverableSourceVideoURL: URL? = {
                    guard let sourceVideoPath = records[index].sourceVideoPath?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !sourceVideoPath.isEmpty else {
                        return nil
                    }
                    let candidate = baseDirectory.appendingPathComponent(sourceVideoPath)
                    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
                }()
                let alreadyAttemptedColdLaunchRecovery: Bool = {
                    let inputKind = LocalPreviewProductProfile.runtimeMetricString(
                        "native_input_kind",
                        from: records[index].runtimeMetrics
                    )
                    let handoff = LocalPreviewProductProfile.runtimeMetricString(
                        "native_handoff_from",
                        from: records[index].runtimeMetrics
                    )
                    let normalizedFailureReason = records[index].failureReason?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return inputKind == "recorded_video_relaunch_recovery" ||
                        handoff == "cold_launch_recovery" ||
                        normalizedFailureReason == "cold_launch_local_recovery_failed" ||
                        normalizedFailureReason == "local_processing_interrupted_after_failed_relaunch_recovery"
                }()
                records[index].status = .failed
                records[index].statusMessage = "本地处理已中断"
                records[index].detailMessage = {
                    if alreadyAttemptedColdLaunchRecovery {
                        return "这条旧本地任务在 app 重启后已经自动走过一次“已落盘视频恢复”，但那次恢复也没能跑通。为了避免它每次启动都自动重试、反复卡在旧状态，系统这次直接把它标成中断；如果你还想继续，只能从主页手动重新发起。"
                    }
                    return recoverableSourceVideoURL == nil
                        ? "这次本地处理依赖上一次 app 进程里的 live bridge。重新启动 app 后，本来可以尝试切到已落盘视频恢复，但这次没有找到可恢复的视频输入，所以系统把它标成中断；请回主页重新发起。"
                        : "这次本地处理依赖上一次 app 进程里的 live bridge。重新启动 app 后，这条本地任务没有被新的恢复链接管，所以系统把它标成中断；请回主页重新发起。"
                }()
                records[index].progressFraction = nil
                records[index].uploadedBytes = nil
                records[index].totalBytes = nil
                records[index].uploadBytesPerSecond = nil
                records[index].estimatedRemainingMinutes = nil
                records[index].remoteJobId = nil
                records[index].failureReason = {
                    if alreadyAttemptedColdLaunchRecovery {
                        return "local_processing_interrupted_after_failed_relaunch_recovery"
                    }
                    return recoverableSourceVideoURL == nil
                        ? "local_processing_interrupted_no_recoverable_source_after_relaunch"
                        : "local_processing_interrupted_after_relaunch"
                }()
                records[index].processingCompletedAt = now
                records[index].processingElapsedSeconds = max(0, now.timeIntervalSince(startedAt))
                records[index].updatedAt = now
                mutatedCount += 1
            }

            if mutatedCount > 0 {
                cachedRecords = records
                writeRecordsToDisk(records)
            }

            return mutatedCount
        }
    }

    public func record(id: UUID) -> ScanRecord? {
        queue.sync {
            let records = loadRecordsUnsafe()
            cachedRecords = records
            return records.first(where: { $0.id == id })
        }
    }

    public func saveRecord(_ record: ScanRecord) {
        queue.sync {
            var records = loadRecordsUnsafe()
            records.removeAll { $0.id == record.id }
            records.append(record)
            if records.count > maxRecords {
                let overflow = records.count - maxRecords
                let removed = Array(records.prefix(overflow))
                records = Array(records.suffix(maxRecords))
                for removedRecord in removed {
                    cleanupThumbnail(for: removedRecord.id)
                    if let artifactPath = removedRecord.artifactPath {
                        cleanupArtifact(relativePath: artifactPath)
                    }
                }
            }
            cachedRecords = records
            writeRecordsToDisk(records)
        }
    }

    public func updateArtifactPath(recordId: UUID, artifactPath: String) {
        queue.sync {
            mutateRecord(id: recordId) { record in
                let now = Date()
                record.artifactPath = artifactPath
                record.viewerInitialPose = nil
                record.remoteJobId = nil
                record.status = .completed
                record.statusMessage = ScanRecord.defaultStatusMessage(for: .completed)
                record.detailMessage = "现在可以进入黑色 3D 空间自由查看"
                record.progressFraction = 1.0
                record.uploadedBytes = nil
                record.totalBytes = nil
                record.uploadBytesPerSecond = nil
                record.failureReason = nil
                record.estimatedRemainingMinutes = 0
                let startedAt = record.processingStartedAt ?? record.createdAt
                record.processingStartedAt = startedAt
                record.processingCompletedAt = now
                record.processingElapsedSeconds = max(0, now.timeIntervalSince(startedAt))
                record.updatedAt = now
            }
        }
    }

    public func updateViewerInitialPose(recordId: UUID, viewerInitialPose: ViewerInitialPose) {
        queue.sync {
            var records = loadRecordsUnsafe()
            guard let index = records.firstIndex(where: { $0.id == recordId }) else {
                return
            }
            if records[index].viewerInitialPose == viewerInitialPose {
                return
            }
            records[index].viewerInitialPose = viewerInitialPose
            cachedRecords = records
            writeRecordsToDisk(records)
        }
    }

    public func updateThumbnailPath(recordId: UUID, thumbnailPath: String?) {
        queue.sync {
            mutateRecord(id: recordId) { record in
                record.thumbnailPath = thumbnailPath
                record.updatedAt = Date()
            }
        }
    }

    public func updateProcessingState(
        recordId: UUID,
        status: ScanRecordStatus,
        statusMessage: String? = nil,
        detailMessage: String? = nil,
        progressFraction: Double? = nil,
        progressBasis: String? = nil,
        remoteStageKey: String? = nil,
        remotePhaseName: String? = nil,
        currentTier: String? = nil,
        runtimeMetrics: [String: String]? = nil,
        uploadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        uploadBytesPerSecond: Double? = nil,
        estimatedRemainingMinutes: Int? = nil,
        sourceVideoPath: String? = nil,
        frameSamplingProfile: String? = nil,
        remoteJobId: String? = nil,
        clearRemoteJobId: Bool = false,
        failureReason: String? = nil
    ) {
        queue.sync {
            mutateRecord(id: recordId) { record in
                let now = Date()
                let normalizedIncomingProgressBasis =
                    OnDeviceProcessingCompatibility.normalizedProgressBasis(progressBasis)
                let normalizedIncomingStageKey =
                    OnDeviceProcessingCompatibility.normalizedWorkflowStageKey(remoteStageKey)
                let normalizedIncomingFailureReason =
                    OnDeviceProcessingCompatibility.normalizedFailureReason(failureReason)
                let isIncomingOnDevice =
                    OnDeviceProcessingCompatibility.isOnDeviceWorkflowStageKey(remoteStageKey)
                let incomingIsAuthoritativeRemoteRuntime = Self.shouldTrustIncomingRemoteRuntime(
                    incomingStatus: status,
                    progressBasis: normalizedIncomingProgressBasis,
                    remoteStageKey: normalizedIncomingStageKey,
                    remotePhaseName: remotePhaseName,
                    runtimeMetrics: runtimeMetrics,
                    detailMessage: detailMessage
                )
                let resolvedStatus = Self.mergedStatus(
                    existing: record,
                    incomingStatus: status,
                    progressBasis: normalizedIncomingProgressBasis,
                    remoteStageKey: normalizedIncomingStageKey,
                    remotePhaseName: remotePhaseName,
                    runtimeMetrics: runtimeMetrics,
                    detailMessage: detailMessage,
                    clearRemoteJobId: clearRemoteJobId
                )
                let regressedStage = resolvedStatus != status
                let authoritativeIncomingRegression = Self.isAuthoritativeIncomingRegression(
                    existing: record,
                    incomingStatus: resolvedStatus,
                    incomingIsAuthoritativeRemoteRuntime: incomingIsAuthoritativeRemoteRuntime,
                    clearRemoteJobId: clearRemoteJobId
                )
                let isUploadFinalizing = resolvedStatus == .uploading &&
                    normalizedIncomingProgressBasis == "upload_finalizing"
                let shouldResetProcessingClock = clearRemoteJobId && Self.isInFlightStatus(resolvedStatus)
                let shouldFinalizeProcessingClock = Self.shouldFinalizeProcessingClock(
                    for: resolvedStatus,
                    failureReason: normalizedIncomingFailureReason
                )

                if shouldResetProcessingClock {
                    record.processingStartedAt = now
                    record.processingCompletedAt = nil
                    record.processingElapsedSeconds = nil
                    if isIncomingOnDevice {
                        record.progressBasis = nil
                        record.remoteStageKey = nil
                        record.remotePhaseName = nil
                        record.currentTier = nil
                        record.runtimeMetrics = nil
                    }
                } else if record.processingStartedAt == nil {
                    record.processingStartedAt = record.createdAt
                }

                record.status = resolvedStatus
                if regressedStage {
                    record.statusMessage = record.statusMessage
                        ?? statusMessage
                        ?? ScanRecord.defaultStatusMessage(for: resolvedStatus)
                    record.detailMessage = record.detailMessage ?? detailMessage
                } else {
                    record.statusMessage = statusMessage ?? ScanRecord.defaultStatusMessage(for: resolvedStatus)
                    record.detailMessage = detailMessage
                }
                record.progressFraction = Self.mergedProgressFraction(
                    existing: record,
                    incomingStatus: resolvedStatus,
                    incomingProgress: progressFraction,
                    incomingProgressBasis: normalizedIncomingProgressBasis,
                    incomingStageKey: normalizedIncomingStageKey,
                    runtimeMetrics: runtimeMetrics,
                    clearRemoteJobId: clearRemoteJobId,
                    regressedStage: regressedStage,
                    authoritativeIncomingRegression: authoritativeIncomingRegression
                )
                if !regressedStage {
                    if incomingIsAuthoritativeRemoteRuntime {
                        record.progressBasis = normalizedIncomingProgressBasis
                        record.remoteStageKey = normalizedIncomingStageKey
                        record.remotePhaseName = remotePhaseName
                        record.currentTier = currentTier
                        record.runtimeMetrics = runtimeMetrics
                    } else {
                        record.progressBasis = normalizedIncomingProgressBasis ?? record.progressBasis
                        record.remoteStageKey = normalizedIncomingStageKey ?? record.remoteStageKey
                        record.remotePhaseName = remotePhaseName ?? record.remotePhaseName
                        record.currentTier = currentTier ?? record.currentTier
                        record.runtimeMetrics = runtimeMetrics ?? record.runtimeMetrics
                    }
                }
                if resolvedStatus == .uploading && !regressedStage {
                    record.uploadedBytes = uploadedBytes
                    record.totalBytes = totalBytes
                    if isUploadFinalizing {
                        record.uploadBytesPerSecond = nil
                    } else if let uploadBytesPerSecond,
                       uploadBytesPerSecond.isFinite,
                       uploadBytesPerSecond > 0 {
                        record.uploadBytesPerSecond = uploadBytesPerSecond
                    }
                } else {
                    record.uploadedBytes = nil
                    record.totalBytes = nil
                    record.uploadBytesPerSecond = nil
                }
                if resolvedStatus == .uploading && !regressedStage {
                    if isUploadFinalizing {
                        record.estimatedRemainingMinutes = nil
                    } else if let estimatedRemainingMinutes {
                        record.estimatedRemainingMinutes = estimatedRemainingMinutes
                    }
                } else {
                    record.estimatedRemainingMinutes = estimatedRemainingMinutes
                }
                if let sourceVideoPath {
                    record.sourceVideoPath = sourceVideoPath
                }
                if let frameSamplingProfile {
                    record.frameSamplingProfile = frameSamplingProfile
                }
                if clearRemoteJobId {
                    record.remoteJobId = nil
                    if !isIncomingOnDevice {
                        record.progressBasis = nil
                        record.remoteStageKey = nil
                        record.remotePhaseName = nil
                        record.currentTier = nil
                        record.runtimeMetrics = Self.preservedObjectFastPublishIdentityMetrics(
                            existing: record.runtimeMetrics,
                            incoming: runtimeMetrics
                        )
                    }
                } else if status == .preparing && !regressedStage {
                    record.remoteJobId = nil
                    record.remoteStageKey = nil
                    record.remotePhaseName = nil
                    record.currentTier = nil
                    record.progressBasis = normalizedIncomingProgressBasis
                    record.runtimeMetrics = runtimeMetrics
                } else if let remoteJobId {
                    record.remoteJobId = remoteJobId
                }
                record.failureReason = normalizedIncomingFailureReason
                if resolvedStatus == .failed {
                    record.artifactPath = nil
                    record.viewerInitialPose = nil
                }
                if record.artifactPath == nil {
                    record.viewerInitialPose = nil
                }
                if shouldFinalizeProcessingClock {
                    let startedAt = record.processingStartedAt ?? record.createdAt
                    record.processingStartedAt = startedAt
                    record.processingCompletedAt = now
                    record.processingElapsedSeconds = max(0, now.timeIntervalSince(startedAt))
                } else if Self.isInFlightStatus(resolvedStatus) {
                    record.processingCompletedAt = nil
                }
                record.updatedAt = now
            }
        }
    }

    private static func mergedProgressFraction(
        existing: ScanRecord,
        incomingStatus: ScanRecordStatus,
        incomingProgress: Double?,
        incomingProgressBasis: String?,
        incomingStageKey: String?,
        runtimeMetrics: [String: String]?,
        clearRemoteJobId: Bool,
        regressedStage: Bool,
        authoritativeIncomingRegression: Bool
    ) -> Double? {
        let normalizedIncoming = normalizedProgressFraction(incomingProgress, for: incomingStatus)

        switch incomingStatus {
        case .completed:
            return 1.0
        case .failed, .cancelled, .preparing:
            return normalizedIncoming
        default:
            break
        }

        if clearRemoteJobId {
            return normalizedIncoming
        }

        if authoritativeIncomingRegression {
            return normalizedIncoming
        }

        if shouldTrustIncomingOnDeviceRuntimeProgress(
            incomingStatus: incomingStatus,
            progressBasis: incomingProgressBasis,
            remoteStageKey: incomingStageKey,
            runtimeMetrics: runtimeMetrics
        ) {
            switch (normalizedIncoming, existing.progressFraction) {
            case let (incoming?, _):
                return incoming
            case (nil, let existing?):
                return existing
            case (nil, nil):
                return nil
            }
        }

        if regressedStage {
            switch (existing.progressFraction, normalizedIncoming) {
            case let (existing?, incoming?):
                return max(existing, incoming)
            case let (existing?, nil):
                return existing
            case let (nil, incoming?):
                return incoming
            case (nil, nil):
                return nil
            }
        }

        guard existing.isProcessing else {
            return normalizedIncoming
        }

        switch (existing.progressFraction, normalizedIncoming) {
        case let (existing?, incoming?):
            return max(existing, incoming)
        case let (existing?, nil):
            return existing
        case let (nil, incoming?):
            return incoming
        case (nil, nil):
            return nil
        }
    }

    private static func preservedObjectFastPublishIdentityMetrics(
        existing: [String: String]?,
        incoming: [String: String]?
    ) -> [String: String]? {
        func normalizedMetric(_ metrics: [String: String]?, key: String) -> String? {
            metrics?[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        let existingStrategy = normalizedMetric(existing, key: "pipeline_strategy")
        let incomingStrategy = normalizedMetric(incoming, key: "pipeline_strategy")
        let existingContract = normalizedMetric(existing, key: "artifact_contract_version")
        let incomingContract = normalizedMetric(incoming, key: "artifact_contract_version")

        let isObjectFastPublishIdentity =
            existingStrategy == "object_fast_publish_v1" ||
            existingStrategy == "object_splatslam_v1" ||
            incomingStrategy == "object_fast_publish_v1" ||
            incomingStrategy == "object_splatslam_v1" ||
            existingContract == "object_publish_v1" ||
            incomingContract == "object_publish_v1"

        guard isObjectFastPublishIdentity else {
            return nil
        }

        let preservedKeys = [
            "pipeline_strategy",
            "artifact_contract_version",
            "first_result_kind",
            "hq_refine",
            "optional_mesh_export",
            "capture_mode",
            "target_zone_mode",
            "client_live_selection_source",
            "visual_gate_version",
        ]

        var preserved: [String: String] = [:]
        for key in preservedKeys {
            if let value = incoming?[key] ?? existing?[key],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preserved[key] = value
            }
        }
        preserved["default_artifact_ready"] = "false"
        return preserved.isEmpty ? nil : preserved
    }

    private static func mergedStatus(
        existing: ScanRecord,
        incomingStatus: ScanRecordStatus,
        progressBasis: String?,
        remoteStageKey: String?,
        remotePhaseName: String?,
        runtimeMetrics: [String: String]?,
        detailMessage: String?,
        clearRemoteJobId: Bool
    ) -> ScanRecordStatus {
        if clearRemoteJobId {
            return incomingStatus
        }

        guard existing.isProcessing,
              let existingRank = visibleStageRank(existing.status),
              let incomingRank = visibleStageRank(incomingStatus) else {
            return incomingStatus
        }

        if shouldTrustIncomingRemoteRuntime(
            incomingStatus: incomingStatus,
            progressBasis: progressBasis,
            remoteStageKey: remoteStageKey,
            remotePhaseName: remotePhaseName,
            runtimeMetrics: runtimeMetrics,
            detailMessage: detailMessage
        ) {
            return incomingStatus
        }

        return incomingRank < existingRank ? existing.status : incomingStatus
    }

    private static func isAuthoritativeIncomingRegression(
        existing: ScanRecord,
        incomingStatus: ScanRecordStatus,
        incomingIsAuthoritativeRemoteRuntime: Bool,
        clearRemoteJobId: Bool
    ) -> Bool {
        guard !clearRemoteJobId, incomingIsAuthoritativeRemoteRuntime, existing.isProcessing else {
            return false
        }
        guard let existingRank = visibleStageRank(existing.status),
              let incomingRank = visibleStageRank(incomingStatus) else {
            return false
        }
        return incomingRank < existingRank
    }

    private static func shouldTrustIncomingOnDeviceRuntimeProgress(
        incomingStatus: ScanRecordStatus,
        progressBasis: String?,
        remoteStageKey: String?,
        runtimeMetrics: [String: String]?
    ) -> Bool {
        switch incomingStatus {
        case .preparing, .uploading, .queued, .reconstructing, .training, .packaging, .downloading, .localFallback:
            break
        case .completed, .cancelled, .failed:
            return false
        }

        let normalizedBasis =
            OnDeviceProcessingCompatibility.normalizedProgressBasis(progressBasis)
        let normalizedStageKey =
            OnDeviceProcessingCompatibility.normalizedWorkflowStageKey(remoteStageKey)
        let hasRuntimeMetrics = !(runtimeMetrics?.isEmpty ?? true)
        let isOnDeviceStage =
            normalizedStageKey == OnDeviceProcessingCompatibility.canonicalWorkflowStageKey
        let isOnDevicePhaseBasis =
            normalizedBasis == OnDeviceProcessingCompatibility.canonicalWorkflowStageKey ||
            (normalizedBasis?.hasPrefix(
                OnDeviceProcessingCompatibility.canonicalWorkflowStageKey + "_"
            ) ?? false)

        return hasRuntimeMetrics && isOnDeviceStage && isOnDevicePhaseBasis
    }

    private static func shouldTrustIncomingRemoteRuntime(
        incomingStatus: ScanRecordStatus,
        progressBasis: String?,
        remoteStageKey: String?,
        remotePhaseName: String?,
        runtimeMetrics: [String: String]?,
        detailMessage: String?
    ) -> Bool {
        switch incomingStatus {
        case .preparing, .uploading, .queued, .reconstructing, .training, .packaging, .downloading, .localFallback:
            break
        case .completed, .cancelled, .failed:
            return false
        }

        let normalizedBasis =
            OnDeviceProcessingCompatibility.normalizedProgressBasis(progressBasis)
        let normalizedStageKey =
            OnDeviceProcessingCompatibility.normalizedWorkflowStageKey(remoteStageKey)
        let normalizedPhaseName = remotePhaseName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasRuntimeMetrics = !(runtimeMetrics?.isEmpty ?? true)
        let hasRuntimeStage = !(normalizedStageKey?.isEmpty ?? true) || !(normalizedPhaseName?.isEmpty ?? true)
        let hasUsefulDetail = !(detailMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        let uploadOnlyBases: Set<String> = [
            "created",
            "upload_bytes",
            "chunked_upload_bytes",
            "chunk_part_uploaded",
            "object_storage_visible",
            "upload_finalizing",
            "control_plane_upload_complete",
            "upload_complete",
            "multipart_upload_complete",
            "chunked_upload_complete",
        ]

        let isAuthoritativeRemoteWork =
            normalizedBasis == "worker_assigned"
            || normalizedBasis == "worker_assigned_streaming_input"
            || normalizedBasis == "prep_ready_waiting_gpu"
            || normalizedBasis == "active_worker_without_runtime"
            || (normalizedBasis?.hasPrefix("prep_") ?? false)
            || (normalizedBasis?.hasPrefix("runtime_") ?? false)
            || ["sfm", "sfm_extract", "sfm_match", "sfm_reconstruct", "train", "export"].contains(normalizedStageKey)
            || ["streaming_input", "stream_probe_live", "extract_frames_live", "audit_live", "sfm_wait_live", "live_sfm_retry_wait", "live_sfm_ready", "feature_extractor", "matcher", "mapper"].contains(normalizedPhaseName)

        guard hasRuntimeStage || hasRuntimeMetrics || hasUsefulDetail else {
            return false
        }

        if let normalizedBasis, uploadOnlyBases.contains(normalizedBasis) {
            return false
        }

        return isAuthoritativeRemoteWork
    }

    private static func visibleStageRank(_ status: ScanRecordStatus) -> Int? {
        switch status {
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
        case .cancelled, .failed:
            return nil
        }
    }

    private static func normalizedProgressFraction(_ value: Double?, for status: ScanRecordStatus) -> Double? {
        switch status {
        case .completed:
            return 1.0
        case .failed, .cancelled:
            if let value {
                return max(0.0, min(1.0, value))
            }
            return nil
        default:
            guard let value else { return nil }
            return max(0.0, min(0.99, value))
        }
    }

    private static func isInFlightStatus(_ status: ScanRecordStatus) -> Bool {
        switch status {
        case .completed, .cancelled, .failed:
            return false
        default:
            return true
        }
    }

    private static func shouldFinalizeProcessingClock(
        for status: ScanRecordStatus,
        failureReason: String?
    ) -> Bool {
        switch status {
        case .completed, .failed:
            return true
        case .cancelled:
            let normalizedFailureReason =
                OnDeviceProcessingCompatibility.normalizedFailureReason(failureReason)
            return normalizedFailureReason != "cancel_requested_unconfirmed"
                && normalizedFailureReason != "cancel_requested"
        default:
            return false
        }
    }

    private static func isFilesystemRecoveredRecord(_ record: ScanRecord) -> Bool {
        let normalizedStatusMessage = record.statusMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedStatusMessage == "已从本地恢复作品"
            || normalizedStatusMessage == "已从本地恢复历史素材"
    }

    public func deleteRecord(id: UUID) {
        queue.sync {
            var records = loadRecordsUnsafe()
            let artifactRelPath = records.first(where: { $0.id == id })?.artifactPath
            let sourceVideoPath = records.first(where: { $0.id == id })?.sourceVideoPath
            records.removeAll { $0.id == id }
            cachedRecords = records
            writeRecordsToDisk(records)
            cleanupThumbnail(for: id)
            if let artifactRelPath {
                cleanupArtifact(relativePath: artifactRelPath)
            }
            if let sourceVideoPath {
                cleanupArtifact(relativePath: sourceVideoPath)
            }
        }
    }

    public func saveThumbnail(_ imageData: Data, for recordId: UUID) -> String? {
        let filename = "\(recordId.uuidString).jpg"
        let fileURL = thumbnailsDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL, options: [.atomic])
            return "thumbnails/\(filename)"
        } catch {
            return nil
        }
    }

    public func thumbnailURL(for relativePath: String) -> URL {
        baseDirectory.appendingPathComponent(relativePath)
    }

    private func mutateRecord(id: UUID, mutate: (inout ScanRecord) -> Void) {
        var records = loadRecordsUnsafe()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&records[index])
        cachedRecords = records
        writeRecordsToDisk(records)
    }

    private func loadRecordsUnsafe() -> [ScanRecord] {
        if let records = loadRecordsFromPrimaryOrBackup() {
            return records
        }
        return normalizedLoadedRecords(recoverRecordsFromFilesystem())
    }

    private func loadRecordsFromPrimaryOrBackup() -> [ScanRecord]? {
        if let primary = loadRecords(from: jsonFileURL) {
            return primary
        }

        guard let backup = loadRecords(from: backupFileURL) else {
            return nil
        }

        // Restore the primary index from the last known-good backup before we
        // fall back to filesystem salvage, so an interrupted local write does
        // not silently downgrade active local work into a cancelled record.
        writeRecordsToDisk(backup)
        return backup
    }

    private func loadRecords(from fileURL: URL) -> [ScanRecord]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return normalizedLoadedRecords(try decodeRecords(from: data))
        } catch {
            return nil
        }
    }

    private func decodeRecords(from data: Data) throws -> [ScanRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let decoded = try? decoder.decode([ScanRecord].self, from: data) {
            return decoded
        }

        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var salvaged: [ScanRecord] = []
        salvaged.reserveCapacity(rawArray.count)

        for rawValue in rawArray {
            guard JSONSerialization.isValidJSONObject(rawValue) else {
                continue
            }
            let itemData = try JSONSerialization.data(withJSONObject: rawValue)
            if let record = try? decoder.decode(ScanRecord.self, from: itemData) {
                salvaged.append(record)
            }
        }

        if !salvaged.isEmpty {
            writeRecordsToDisk(salvaged)
            return salvaged
        }

        throw CocoaError(.fileReadCorruptFile)
    }

    private func writeRecordsToDisk(_ records: [ScanRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: jsonFileURL, options: [.atomic])
            try data.write(to: backupFileURL, options: [.atomic])
        } catch {
            // Ignore write failures to avoid blocking the capture loop.
        }
    }

    private func normalizedLoadedRecords(_ records: [ScanRecord]) -> [ScanRecord] {
        var didMutate = false
        var normalizedRecords = records

        for index in normalizedRecords.indices {
            if Self.isFilesystemRecoveredRecord(normalizedRecords[index]) {
                if normalizedRecords[index].processingStartedAt != nil
                    || normalizedRecords[index].processingCompletedAt != nil
                    || normalizedRecords[index].processingElapsedSeconds != nil {
                    normalizedRecords[index].processingStartedAt = nil
                    normalizedRecords[index].processingCompletedAt = nil
                    normalizedRecords[index].processingElapsedSeconds = nil
                    didMutate = true
                }
            } else if normalizedRecords[index].processingStartedAt == nil {
                normalizedRecords[index].processingStartedAt = normalizedRecords[index].createdAt
                didMutate = true
            }

            if normalizedRecords[index].durationSeconds <= 0,
               let sourceVideoPath = normalizedRecords[index].sourceVideoPath {
                let sourceURL = baseDirectory.appendingPathComponent(sourceVideoPath)
                let derivedDuration = Self.sourceVideoDuration(at: sourceURL)
                if derivedDuration > 0 {
                    normalizedRecords[index].durationSeconds = derivedDuration
                    didMutate = true
                }
            }

            if !Self.isFilesystemRecoveredRecord(normalizedRecords[index]),
               normalizedRecords[index].processingElapsedSeconds == nil,
               let startedAt = normalizedRecords[index].processingStartedAt {
                let completedAt = normalizedRecords[index].processingCompletedAt
                    ?? (Self.shouldFinalizeProcessingClock(
                        for: normalizedRecords[index].status,
                        failureReason: normalizedRecords[index].failureReason
                    ) ? normalizedRecords[index].updatedAt : nil)
                if let completedAt, completedAt >= startedAt {
                    normalizedRecords[index].processingCompletedAt = completedAt
                    normalizedRecords[index].processingElapsedSeconds = max(0, completedAt.timeIntervalSince(startedAt))
                    didMutate = true
                }
            }

            if normalizedRecords[index].failureReason == "stale_local_processing_frozen" {
                if normalizedRecords[index].statusMessage != Self.staleLocalFrozenStatusMessage {
                    normalizedRecords[index].statusMessage = Self.staleLocalFrozenStatusMessage
                    didMutate = true
                }
                if normalizedRecords[index].detailMessage != Self.staleLocalFrozenDetailMessage {
                    normalizedRecords[index].detailMessage = Self.staleLocalFrozenDetailMessage
                    didMutate = true
                }
            }
        }

        if didMutate {
            writeRecordsToDisk(normalizedRecords)
        }

        return normalizedRecords
    }

    private func recoverRecordsFromFilesystem() -> [ScanRecord] {
        struct RecoveryRecord {
            var createdAt: Date = .distantFuture
            var updatedAt: Date = .distantPast
            var thumbnailPath: String?
            var artifactPath: String?
            var sourceVideoPath: String?
            var durationSeconds: TimeInterval = 0
        }

        let fileManager = FileManager.default
        var recoveredById: [UUID: RecoveryRecord] = [:]

        func registerFile(at url: URL, relativePrefix: String, assign: (inout RecoveryRecord, String) -> Void) {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: stem) else { return }
            let relativePath = "\(relativePrefix)/\(url.lastPathComponent)"
            var recovered = recoveredById[id] ?? RecoveryRecord()

            if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
                let createdAt = (attributes[.creationDate] as? Date) ?? (attributes[.modificationDate] as? Date) ?? Date()
                let updatedAt = (attributes[.modificationDate] as? Date) ?? createdAt
                recovered.createdAt = min(recovered.createdAt, createdAt)
                recovered.updatedAt = max(recovered.updatedAt, updatedAt)
            }

            assign(&recovered, relativePath)
            recoveredById[id] = recovered
        }

        if let thumbnailFiles = try? fileManager.contentsOfDirectory(
            at: thumbnailsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in thumbnailFiles {
                registerFile(at: url, relativePrefix: "thumbnails") { recovered, relativePath in
                    recovered.thumbnailPath = relativePath
                }
            }
        }

        if let exportFiles = try? fileManager.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in exportFiles where url.pathExtension.lowercased() == "ply" {
                registerFile(at: url, relativePrefix: "exports") { recovered, relativePath in
                    recovered.artifactPath = relativePath
                }
            }
        }

        if let importFiles = try? fileManager.contentsOfDirectory(
            at: importsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in importFiles {
                registerFile(at: url, relativePrefix: "imports") { recovered, relativePath in
                    recovered.sourceVideoPath = relativePath
                    recovered.durationSeconds = max(recovered.durationSeconds, Self.sourceVideoDuration(at: url))
                }
            }
        }

        let recoveredRecords = recoveredById.map { id, recovered -> ScanRecord in
            let createdAt = recovered.createdAt == .distantFuture ? Date() : recovered.createdAt
            let updatedAt = recovered.updatedAt == .distantPast ? createdAt : recovered.updatedAt
            let status: ScanRecordStatus = recovered.artifactPath != nil ? .completed : .cancelled
            let statusMessage = recovered.artifactPath != nil ? "已从本地恢复作品" : "已从本地恢复历史素材"
            let detailMessage = recovered.artifactPath != nil
                ? "记录文件损坏后，已根据本地导出结果重新恢复这件作品。"
                : "记录文件损坏后，已根据本地保留素材恢复这条历史记录。"
            return ScanRecord(
                id: id,
                createdAt: createdAt,
                updatedAt: updatedAt,
                thumbnailPath: recovered.thumbnailPath,
                artifactPath: recovered.artifactPath,
                sourceVideoPath: recovered.sourceVideoPath,
                durationSeconds: recovered.durationSeconds,
                processingStartedAt: nil,
                processingCompletedAt: nil,
                processingElapsedSeconds: nil,
                status: status,
                statusMessage: statusMessage,
                detailMessage: detailMessage,
                progressFraction: recovered.artifactPath != nil ? 1.0 : nil
            )
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        if !recoveredRecords.isEmpty {
            writeRecordsToDisk(recoveredRecords)
        }

        return recoveredRecords
    }

    private func cleanupThumbnail(for recordId: UUID) {
        let filename = "\(recordId.uuidString).jpg"
        let fileURL = thumbnailsDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func cleanupArtifact(relativePath: String) {
        let url = baseDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    private static func sourceVideoDuration(at url: URL) -> TimeInterval {
        #if canImport(AVFoundation)
        let resultBox = DurationResolutionBox()
        let signal = BlockingSignal()

        Task.detached(priority: .utility) {
            defer { signal.signal() }
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else {
                return
            }
            let seconds = duration.seconds
            guard duration.isNumeric, seconds.isFinite, seconds > 0 else {
                return
            }
            resultBox.store(seconds)
        }

        _ = signal.wait(timeout: .now() + 1.0)
        return resultBox.load()
        #else
        return 0
        #endif
    }
}

#endif
