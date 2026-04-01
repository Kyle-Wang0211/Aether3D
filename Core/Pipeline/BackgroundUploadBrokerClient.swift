// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

struct PreparedUploadProgress: Sendable {
    let phase: String
    let progressFraction: Double
    let title: String
    let detail: String
    let metrics: [String: String]
}

#if canImport(UIKit)
import UIKit

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

private enum ManagedPreparedUploadSourceStore {
    struct Metadata: Codable, Sendable {
        var originalFileBytes: Int64
        var estimatedUploadBytes: Int64
        var currentPreparedBytes: Int64
        var finalized: Bool
        var exportFailedReason: String?
        var updatedAt: Date
    }

    static func rootDirectory() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether3D", isDirectory: true)
            .appendingPathComponent("stream-friendly-uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        return supportDirectory
    }

    static func isManaged(_ url: URL) -> Bool {
        let rootPath = rootDirectory().standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func cleanupIfManaged(_ url: URL) {
        guard isManaged(url) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: metadataURL(for: url))
    }

    static func pruneStaleFiles(olderThan age: TimeInterval) {
        let root = rootDirectory()
        let expirationDate = Date().addingTimeInterval(-age)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            if modifiedAt < expirationDate {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func makeOutputURL(for originalURL: URL, pathExtension: String) -> URL {
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let sanitizedBaseName = baseName.isEmpty ? "upload" : baseName
        return rootDirectory()
            .appendingPathComponent("\(sanitizedBaseName)-streamable-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    static func metadataURL(for outputURL: URL) -> URL {
        outputURL.deletingPathExtension()
            .appendingPathExtension(outputURL.pathExtension + ".upload.json")
    }

    static func loadMetadata(for outputURL: URL) -> Metadata? {
        let url = metadataURL(for: outputURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Metadata.self, from: data)
    }

    static func saveMetadata(_ metadata: Metadata, for outputURL: URL) {
        let url = metadataURL(for: outputURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metadata) else { return }
        let tmpURL = url.appendingPathExtension("tmp")
        try? data.write(to: tmpURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.moveItem(at: tmpURL, to: url)
    }

    static func currentFileSize(for outputURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

#if canImport(AVFoundation)
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private actor StreamFriendlyUploadPreparer {
    static let shared = StreamFriendlyUploadPreparer()

    private struct ExportStrategy {
        let presetName: String
        let fileType: AVFileType
    }

    private let staleRetentionSeconds: TimeInterval = 60 * 60 * 24
    private var activeExportTasks: [String: Task<Void, Never>] = [:]

    func prepareSource(
        from videoURL: URL,
        onProgress: (@Sendable (PreparedUploadProgress) async -> Void)? = nil
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RemoteB1ClientError.uploadFailed("upload_source_missing")
        }
        if ManagedPreparedUploadSourceStore.isManaged(videoURL) {
            return videoURL
        }

        ManagedPreparedUploadSourceStore.pruneStaleFiles(olderThan: staleRetentionSeconds)

        let asset = AVURLAsset(url: videoURL)
        let originalFileBytes = try fileSizeBytes(at: videoURL)
        if let onProgress {
            await onProgress(
                PreparedUploadProgress(
                    phase: "prepare_inspecting_source",
                    progressFraction: 0.06,
                    title: "正在检查原视频",
                    detail: "正在确认视频可读、时长正常，并挑选最合适的流式重封装方案。",
                    metrics: [
                        "prepare_phase": "inspect_source",
                        "prepare_progress_percent": "6"
                    ]
                )
            )
        }
        var lastError: Error?
        for strategy in candidateStrategies(for: asset) {
            let outputURL = ManagedPreparedUploadSourceStore.makeOutputURL(
                for: videoURL,
                pathExtension: strategy.fileType == .mov ? "mov" : "mp4"
            )
            do {
                try startStreamingExport(
                    asset: asset,
                    to: outputURL,
                    strategy: strategy,
                    originalFileBytes: originalFileBytes,
                    onProgress: onProgress
                )
                try await waitUntilPreparedOutputBecomesReadable(
                    at: outputURL,
                    originalFileBytes: originalFileBytes
                )
                if let onProgress {
                    await onProgress(
                        PreparedUploadProgress(
                            phase: "prepare_streaming_ready",
                            progressFraction: 0.10,
                            title: "正在边整理边切块",
                            detail: "流式友好容器已开始写出，后台上传会在前几块数据可用后立即开工，不再等整理彻底结束。",
                            metrics: [
                                "prepare_phase": "streaming_ready",
                                "prepare_progress_percent": "10",
                                "prepare_estimated_bytes": "\(originalFileBytes)"
                            ]
                        )
                    )
                }
                return outputURL
            } catch {
                lastError = error
                ManagedPreparedUploadSourceStore.cleanupIfManaged(outputURL)
            }
        }

        let fallbackDescription = lastError.map { String(describing: $0) } ?? "unknown"
        throw RemoteB1ClientError.uploadFailed("stream_friendly_remux_failed:\(fallbackDescription)")
    }

    private func waitUntilPreparedOutputBecomesReadable(
        at outputURL: URL,
        originalFileBytes: Int64,
        timeout: TimeInterval = 15
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let preparedBytes = ManagedPreparedUploadSourceStore.currentFileSize(for: outputURL)
            if preparedBytes > 0,
               FileManager.default.fileExists(atPath: outputURL.path),
               FileManager.default.isReadableFile(atPath: outputURL.path) {
                ManagedPreparedUploadSourceStore.saveMetadata(
                    .init(
                        originalFileBytes: originalFileBytes,
                        estimatedUploadBytes: max(originalFileBytes, 1),
                        currentPreparedBytes: preparedBytes,
                        finalized: ManagedPreparedUploadSourceStore.loadMetadata(for: outputURL)?.finalized ?? false,
                        exportFailedReason: nil,
                        updatedAt: Date()
                    ),
                    for: outputURL
                )
                return
            }

            if let metadata = ManagedPreparedUploadSourceStore.loadMetadata(for: outputURL),
               metadata.finalized,
               let exportFailedReason = metadata.exportFailedReason {
                throw RemoteB1ClientError.uploadFailed("stream_friendly_export_failed:\(exportFailedReason)")
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw RemoteB1ClientError.uploadFailed("prepared_upload_source_not_readable")
    }

    private func candidateStrategies(for asset: AVURLAsset) -> [ExportStrategy] {
        let preferred: [(String, AVFileType)] = [
            (AVAssetExportPresetPassthrough, .mp4),
            (AVAssetExportPresetHighestQuality, .mp4),
            (AVAssetExportPresetMediumQuality, .mp4),
            (AVAssetExportPresetPassthrough, .mov),
            (AVAssetExportPresetHighestQuality, .mov),
            (AVAssetExportPresetMediumQuality, .mov)
        ]

        var strategies: [ExportStrategy] = []
        for (presetName, fileType) in preferred {
            guard let session = AVAssetExportSession(asset: asset, presetName: presetName),
                  session.supportedFileTypes.contains(fileType) else {
                continue
            }
            strategies.append(ExportStrategy(presetName: presetName, fileType: fileType))
        }
        return strategies
    }

    private func startStreamingExport(
        asset: AVURLAsset,
        to outputURL: URL,
        strategy: ExportStrategy,
        originalFileBytes: Int64,
        onProgress: (@Sendable (PreparedUploadProgress) async -> Void)? = nil
    ) throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: strategy.presetName) else {
            throw RemoteB1ClientError.uploadFailed("stream_friendly_export_session_unavailable")
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        ManagedPreparedUploadSourceStore.saveMetadata(
            .init(
                originalFileBytes: originalFileBytes,
                estimatedUploadBytes: max(originalFileBytes, 1),
                currentPreparedBytes: 0,
                finalized: false,
                exportFailedReason: nil,
                updatedAt: Date()
            ),
            for: outputURL
        )

        session.outputURL = outputURL
        session.outputFileType = strategy.fileType
        session.shouldOptimizeForNetworkUse = true
        let sessionBox = UncheckedSendableBox(session)
        let task = Task { [weak self, sessionBox] in
            guard let self else { return }

            let progressTask = Task { [weak self, sessionBox] in
                guard let self else { return }
                var lastPercent = -1
                while !Task.isCancelled {
                    let rawProgress = max(0.0, min(1.0, Double(sessionBox.value.progress)))
                    let percent = max(10, min(94, Int((rawProgress * 84.0).rounded()) + 10))
                    let currentBytes = ManagedPreparedUploadSourceStore.currentFileSize(for: outputURL)
                    ManagedPreparedUploadSourceStore.saveMetadata(
                        .init(
                            originalFileBytes: originalFileBytes,
                            estimatedUploadBytes: max(originalFileBytes, 1),
                            currentPreparedBytes: currentBytes,
                            finalized: false,
                            exportFailedReason: nil,
                            updatedAt: Date()
                        ),
                        for: outputURL
                    )
                    if percent != lastPercent, let onProgress {
                        lastPercent = percent
                        await onProgress(
                            PreparedUploadProgress(
                                phase: "prepare_remuxing_container",
                                progressFraction: Double(percent) / 100.0,
                                title: "正在边整理边切块",
                                detail: "视频正在重封装成流式友好容器；一旦前几块字节落盘，后台上传就会立刻开始。",
                                metrics: [
                                    "prepare_phase": "remuxing_container",
                                    "prepare_progress_percent": "\(percent)",
                                    "prepare_container_type": strategy.fileType == .mov ? "mov" : "mp4",
                                    "prepared_file_bytes": "\(currentBytes)"
                                ]
                            )
                        )
                    }
                    if sessionBox.value.status != .waiting && sessionBox.value.status != .exporting {
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                sessionBox.value.exportAsynchronously {
                    let exportSession = sessionBox.value
                    switch exportSession.status {
                    case .completed:
                        continuation.resume(returning: .success(()))
                    case .failed:
                        continuation.resume(
                            returning: .failure(
                                exportSession.error ?? RemoteB1ClientError.uploadFailed("stream_friendly_export_failed")
                            )
                        )
                    case .cancelled:
                        continuation.resume(
                            returning: .failure(RemoteB1ClientError.uploadFailed("stream_friendly_export_cancelled"))
                        )
                    default:
                        continuation.resume(
                            returning: .failure(RemoteB1ClientError.uploadFailed("stream_friendly_export_incomplete"))
                        )
                    }
                }
            }

            progressTask.cancel()

            let finalBytes = ManagedPreparedUploadSourceStore.currentFileSize(for: outputURL)
            switch result {
            case .success:
                ManagedPreparedUploadSourceStore.saveMetadata(
                    .init(
                        originalFileBytes: originalFileBytes,
                        estimatedUploadBytes: max(originalFileBytes, 1),
                        currentPreparedBytes: max(finalBytes, 0),
                        finalized: true,
                        exportFailedReason: nil,
                        updatedAt: Date()
                    ),
                    for: outputURL
                )
                if let onProgress {
                    await onProgress(
                        PreparedUploadProgress(
                            phase: "prepare_ready_for_upload",
                            progressFraction: 1.0,
                            title: "上传素材已整理完成",
                            detail: "流式友好容器已经完成写出，后续会继续补完剩余切块并完成上传。",
                            metrics: [
                                "prepare_phase": "ready_for_upload",
                                "prepare_progress_percent": "100",
                                "prepared_file_bytes": "\(finalBytes)"
                            ]
                        )
                    )
                }
            case let .failure(error):
                ManagedPreparedUploadSourceStore.saveMetadata(
                    .init(
                        originalFileBytes: originalFileBytes,
                        estimatedUploadBytes: max(originalFileBytes, 1),
                        currentPreparedBytes: max(finalBytes, 0),
                        finalized: true,
                        exportFailedReason: String(describing: error),
                        updatedAt: Date()
                    ),
                    for: outputURL
                )
            }

            await self.finishStreamingExport(for: outputURL)
        }

        activeExportTasks[outputURL.standardizedFileURL.path] = task
    }

    private func finishStreamingExport(for outputURL: URL) {
        activeExportTasks.removeValue(forKey: outputURL.standardizedFileURL.path)
    }

    private func fileSizeBytes(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
#endif

public struct BackgroundUploadBrokerConfiguration: Sendable {
    public let baseURL: URL
    public let fallbackBaseURL: URL?
    public let apiKey: String?
    public let backgroundSessionIdentifier: String
    public let backgroundMaximumConnectionsPerHost: Int
    public let foregroundMultipartMaximumConnectionsPerHost: Int

    public init(
        baseURL: URL,
        fallbackBaseURL: URL?,
        apiKey: String?,
        backgroundSessionIdentifier: String,
        backgroundMaximumConnectionsPerHost: Int,
        foregroundMultipartMaximumConnectionsPerHost: Int
    ) {
        self.baseURL = baseURL
        self.fallbackBaseURL = fallbackBaseURL
        self.apiKey = apiKey
        self.backgroundSessionIdentifier = backgroundSessionIdentifier
        self.backgroundMaximumConnectionsPerHost = backgroundMaximumConnectionsPerHost
        self.foregroundMultipartMaximumConnectionsPerHost = foregroundMultipartMaximumConnectionsPerHost
    }

    public static func current(bundle: Bundle = .main) -> BackgroundUploadBrokerConfiguration? {
        let info = bundle.infoDictionary ?? [:]

        let env = ProcessInfo.processInfo.environment
        let baseURLString =
            env["AETHER_BROKER_BASE_URL"] ??
            (info["AETHER_BROKER_BASE_URL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let baseURLString,
              !baseURLString.isEmpty,
              let baseURL = URL(string: baseURLString) else {
            return nil
        }

        let fallbackBaseURLString =
            env["AETHER_BROKER_FALLBACK_BASE_URL"] ??
            (info["AETHER_BROKER_FALLBACK_BASE_URL"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackBaseURL: URL?
        if let fallbackBaseURLString, !fallbackBaseURLString.isEmpty {
            fallbackBaseURL = URL(string: fallbackBaseURLString)
        } else {
            fallbackBaseURL = nil
        }

        let apiKey =
            env["AETHER_BROKER_API_KEY"] ??
            (info["AETHER_BROKER_API_KEY"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

        let sessionIdentifier =
            env["AETHER_BROKER_BACKGROUND_SESSION_ID"] ??
            (info["AETHER_BROKER_BACKGROUND_SESSION_ID"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ??
            "com.aether3d.background-upload.v20260323c"

        let backgroundMaxConnections =
            Int(
                (env["AETHER_BROKER_BACKGROUND_MAX_CONNECTIONS_PER_HOST"] ??
                    (info["AETHER_BROKER_BACKGROUND_MAX_CONNECTIONS_PER_HOST"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ??
                    "20")
            ) ?? 20

        let foregroundMultipartMaxConnections =
            Int(
                (env["AETHER_BROKER_FOREGROUND_MULTIPART_MAX_CONNECTIONS_PER_HOST"] ??
                    (info["AETHER_BROKER_FOREGROUND_MULTIPART_MAX_CONNECTIONS_PER_HOST"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ??
                    "24")
            ) ?? 24

        return BackgroundUploadBrokerConfiguration(
            baseURL: baseURL,
            fallbackBaseURL: fallbackBaseURL,
            apiKey: apiKey?.isEmpty == true ? nil : apiKey,
            backgroundSessionIdentifier: sessionIdentifier,
            backgroundMaximumConnectionsPerHost: max(1, backgroundMaxConnections),
            foregroundMultipartMaximumConnectionsPerHost: max(1, foregroundMultipartMaxConnections)
        )
    }
}

struct BrokerUploadRequest: Codable, Sendable {
    let kind: String?
    let method: String?
    let url: String?
    let headers: [String: String]
    let storageKey: String
    let uploadId: String?
    let partSizeBytes: Int?
    let maxConcurrency: Int?
    let partReadyURL: String?
    let parts: [BrokerMultipartPartRequest]?
    let completeURL: String?
    let abortURL: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case method
        case url
        case headers
        case storageKey
        case uploadId
        case partSizeBytes
        case maxConcurrency
        case partReadyURL
        case parts
        case completeURL
        case abortURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        storageKey = try container.decode(String.self, forKey: .storageKey)
        uploadId = try container.decodeIfPresent(String.self, forKey: .uploadId)
        partSizeBytes = try container.decodeIfPresent(Int.self, forKey: .partSizeBytes)
        maxConcurrency = try container.decodeIfPresent(Int.self, forKey: .maxConcurrency)
        partReadyURL = try container.decodeIfPresent(String.self, forKey: .partReadyURL)
        parts = try container.decodeIfPresent([BrokerMultipartPartRequest].self, forKey: .parts)
        completeURL = try container.decodeIfPresent(String.self, forKey: .completeURL)
        abortURL = try container.decodeIfPresent(String.self, forKey: .abortURL)
    }
}

struct BrokerMultipartPartRequest: Codable, Sendable {
    let partNumber: Int
    let method: String
    let url: String
    let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case partNumber
        case method
        case url
        case headers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partNumber = try container.decode(Int.self, forKey: .partNumber)
        method = try container.decode(String.self, forKey: .method)
        url = try container.decode(String.self, forKey: .url)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
    }
}

private struct BrokerMultipartCompletedPart: Codable, Sendable {
    let partNumber: Int
    let etag: String
}

private struct BrokerMultipartCompleteRequest: Codable, Sendable {
    let uploadId: String
    let storageKey: String
    let parts: [BrokerMultipartCompletedPart]
    let sizeBytes: Int64
}

private struct BrokerMultipartAbortRequest: Codable, Sendable {
    let uploadId: String
    let storageKey: String
}

private struct BrokerMultipartPartReadyRequest: Codable, Sendable {
    let uploadId: String
    let storageKey: String
    let partNumber: Int
    let etag: String
    let uploadedBytes: Int64
    let completedPartCount: Int
    let totalPartCount: Int
}

struct BrokerCreateJobRequest: Codable, Sendable {
    let fileName: String
    let fileSizeBytes: Int64
    let contentType: String
    let captureOrigin: String
    let clientRecordId: String?
    let pipelineProfile: [String: String]?

    enum CodingKeys: String, CodingKey {
        case fileName
        case fileSizeBytes
        case contentType
        case captureOrigin
        case clientRecordId
        case pipelineProfile = "pipeline_profile"
    }
}

struct BrokerCreateJobResponse: Codable, Sendable {
    let jobId: String
    let upload: BrokerUploadRequest
    let pollPath: String?
    let cancelPath: String?
}

struct BrokerArtifactPayload: Codable, Sendable {
    let downloadURL: String
    let format: String

    enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url"
        case format
    }
}

private enum BrokerRuntimeMetricScalar: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.typeMismatch(
                BrokerRuntimeMetricScalar.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported runtime metric value")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            let rounded = value.rounded()
            if rounded == value {
                return String(Int(rounded))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return nil
        }
    }
}

struct BrokerRuntimeMetricMap: Codable, Sendable {
    let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([String: BrokerRuntimeMetricScalar].self)) ?? [:]
        self.values = raw.reduce(into: [:]) { partialResult, item in
            if let stringValue = item.value.stringValue {
                partialResult[item.key] = stringValue
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

struct BrokerJobStatusResponse: Codable, Sendable {
    let jobId: String
    let state: String
    let stage: String?
    let phaseName: String?
    let currentTier: String?
    let title: String?
    let detail: String?
    let progressFraction: Double?
    let elapsedSeconds: Int?
    let estimatedRemainingSeconds: Int?
    let progressBasis: String?
    let metrics: BrokerRuntimeMetricMap?
    let artifact: BrokerArtifactPayload?
    let failureReason: String?
    let assignedWorkerId: String?
    let cancelAcknowledged: Bool?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case state
        case stage
        case phaseName = "phase_name"
        case currentTier = "current_tier"
        case title
        case detail
        case progressFraction = "progress_fraction"
        case elapsedSeconds = "elapsed_seconds"
        case estimatedRemainingSeconds = "estimated_remaining_seconds"
        case progressBasis = "progress_basis"
        case metrics
        case artifact
        case failureReason = "failure_reason"
        case assignedWorkerId = "assigned_worker_id"
        case cancelAcknowledged = "cancel_acknowledged"
    }
}

private struct PersistedBackgroundUploadTask: Codable, Sendable {
    let taskIdentifier: Int
    let jobId: String
    let sourcePath: String
    let totalBytes: Int64
    let createdAt: Date
}

private struct PersistedArtifactDownloadTask: Codable, Sendable {
    let taskIdentifier: Int
    let jobId: String
    let stagedFilePath: String
    let format: String
    let requestURL: String?
    let createdAt: Date
    let completedAt: Date?
}

private struct PersistedMultipartUploadContext: Codable, Sendable {
    let jobId: String
    let totalBytes: Int64
    let sourcePath: String
    let storageKey: String
    let uploadId: String
    let partSizeBytes: Int64
    let maxConcurrency: Int
    let parts: [BrokerMultipartPartRequest]
    let partReadyURL: String?
    let completeURL: String
    let abortURL: String?
    let tempDirectoryPath: String
    let nextPartIndex: Int
    let activeTaskIdentifiers: [String]
    let uploadedBytesByPart: [Int: Int64]
    let completedETagsByPart: [Int: String]
    let retryCountsByPart: [Int: Int]
    let pendingRetryPartNumbers: [Int]
    let failed: Bool
    let isFinalizing: Bool
    let lastActivityAt: Date
}

private struct PersistedMultipartTaskContext: Codable, Sendable {
    let taskToken: String
    let jobId: String
    let partNumber: Int
    let totalBytes: Int64
    let tempFilePath: String
}

private struct PersistedMultipartState: Codable, Sendable {
    let contexts: [PersistedMultipartUploadContext]
    let taskContexts: [PersistedMultipartTaskContext]

    static let empty = PersistedMultipartState(contexts: [], taskContexts: [])
}

private final class BackgroundUploadBrokerStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aether3d.background-upload.storage", qos: .utility)
    private let manifestURL: URL
    private let multipartManifestURL: URL
    private let artifactDownloadManifestURL: URL

    init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether3D", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        manifestURL = supportDirectory.appendingPathComponent("background_upload_tasks.json")
        multipartManifestURL = supportDirectory.appendingPathComponent("background_multipart_uploads.json")
        artifactDownloadManifestURL = supportDirectory.appendingPathComponent("background_artifact_downloads.json")
    }

    func load() -> [PersistedBackgroundUploadTask] {
        queue.sync {
            guard let data = try? Data(contentsOf: manifestURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([PersistedBackgroundUploadTask].self, from: data)) ?? []
        }
    }

    func save(_ tasks: [PersistedBackgroundUploadTask]) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(tasks) else { return }
            let tmpURL = manifestURL.appendingPathExtension("tmp")
            try? data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                try? FileManager.default.removeItem(at: manifestURL)
            }
            try? FileManager.default.moveItem(at: tmpURL, to: manifestURL)
        }
    }

    func loadMultipartState() -> PersistedMultipartState {
        queue.sync {
            guard let data = try? Data(contentsOf: multipartManifestURL) else { return .empty }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(PersistedMultipartState.self, from: data)) ?? .empty
        }
    }

    func saveMultipartState(_ state: PersistedMultipartState) {
        queue.sync {
            if state.contexts.isEmpty, state.taskContexts.isEmpty {
                try? FileManager.default.removeItem(at: multipartManifestURL)
                return
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(state) else { return }
            let tmpURL = multipartManifestURL.appendingPathExtension("tmp")
            try? data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: multipartManifestURL.path) {
                try? FileManager.default.removeItem(at: multipartManifestURL)
            }
            try? FileManager.default.moveItem(at: tmpURL, to: multipartManifestURL)
        }
    }

    func loadArtifactDownloads() -> [PersistedArtifactDownloadTask] {
        queue.sync {
            guard let data = try? Data(contentsOf: artifactDownloadManifestURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([PersistedArtifactDownloadTask].self, from: data)) ?? []
        }
    }

    func saveArtifactDownloads(_ tasks: [PersistedArtifactDownloadTask]) {
        queue.sync {
            if tasks.isEmpty {
                try? FileManager.default.removeItem(at: artifactDownloadManifestURL)
                return
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(tasks) else { return }
            let tmpURL = artifactDownloadManifestURL.appendingPathExtension("tmp")
            try? data.write(to: tmpURL, options: .atomic)
            if FileManager.default.fileExists(atPath: artifactDownloadManifestURL.path) {
                try? FileManager.default.removeItem(at: artifactDownloadManifestURL)
            }
            try? FileManager.default.moveItem(at: tmpURL, to: artifactDownloadManifestURL)
        }
    }
}

private final class BackgroundUploadBrokerEngine: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundUploadBrokerEngine()

    private struct UploadActivity {
        var lastProgressAt: Date
        var totalBytesSent: Int64
    }

    private struct DownloadActivity {
        var lastProgressAt: Date
        var totalBytesWritten: Int64
        var totalBytesExpected: Int64
    }

    private struct SingleUploadContext {
        let jobId: String
        let totalBytes: Int64
        let sourceURL: URL
        let onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
        let completion: CheckedContinuation<String, Error>?
    }

    private struct ArtifactDownloadWaiter {
        let id: UUID
        let onProgress: (@Sendable (Int64, Int64) async -> Void)?
        let completion: CheckedContinuation<URL, Error>?
    }

    private struct ArtifactDownloadContext {
        let jobId: String
        let format: ArtifactFormat
        let stagedFileURL: URL
        let requestURL: URL
        var waiters: [ArtifactDownloadWaiter]
    }

    private struct MultipartUploadContext {
        let jobId: String
        let totalBytes: Int64
        let sourceURL: URL
        let storageKey: String
        let uploadId: String
        let partSizeBytes: Int64
        let maxConcurrency: Int
        let parts: [BrokerMultipartPartRequest]
        let partReadyURL: URL?
        let completeURL: URL
        let abortURL: URL?
        let onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
        let completion: CheckedContinuation<String, Error>?
        let tempDirectory: URL
        var nextPartIndex: Int
        var activeTaskIdentifiers: Set<String>
        var uploadedBytesByPart: [Int: Int64]
        var completedETagsByPart: [Int: String]
        var retryCountsByPart: [Int: Int]
        var pendingRetryPartNumbers: [Int]
        var failed: Bool
        var isFinalizing: Bool
        var lastActivityAt: Date
    }

    private struct MultipartTaskContext {
        let taskToken: String
        let jobId: String
        let partNumber: Int
        let totalBytes: Int64
        let tempFileURL: URL
    }

    private struct MultipartRecoveryTask {
        let taskToken: String
        let tempFileURL: URL
    }

    private struct MultipartWorkItem {
        let jobId: String
        let sourceURL: URL
        let part: BrokerMultipartPartRequest
        let offset: Int64
        let totalBytes: Int64
        let tempFileURL: URL
    }

    private struct SourceAvailabilitySnapshot {
        let availableBytes: Int64
        let totalBytes: Int64
        let finalized: Bool
        let exportFailedReason: String?
    }

    private let lock = NSLock()
    private let storage = BackgroundUploadBrokerStorage()
    private let encoder = JSONEncoder()
    private var activeContexts: [Int: SingleUploadContext] = [:]
    private var activeDownloadContexts: [Int: ArtifactDownloadContext] = [:]
    private var uploadActivity: [Int: UploadActivity] = [:]
    private var stalledUploads: [Int: Int64] = [:]
    private var downloadActivity: [Int: DownloadActivity] = [:]
    private var stalledArtifactDownloads: [Int: Int64] = [:]
    private var pendingCompletionHandlers: [String: () -> Void] = [:]
    private var multipartContexts: [String: MultipartUploadContext] = [:]
    private var multipartTaskContexts: [String: MultipartTaskContext] = [:]
    private let uploadStallPollInterval: UInt64 = 30 * 1_000_000_000
    private let downloadStallPollInterval: UInt64 = 20 * 1_000_000_000
    private let multipartMonitorPollInterval: UInt64 = 1 * 1_000_000_000
    private let multipartFinalizeRecoveryInterval: TimeInterval = 12
    private let multipartPartRetryLimit = 4
    private let backgroundMultipartConcurrencyCap = 6
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        let brokerConfig = BackgroundUploadBrokerConfiguration.current()
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = brokerConfig?.backgroundMaximumConnectionsPerHost ?? 20
        config.timeoutIntervalForRequest = 60 * 10
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private lazy var foregroundMultipartSession: URLSession = {
        let config = URLSessionConfiguration.default
        let brokerConfig = BackgroundUploadBrokerConfiguration.current()
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.httpMaximumConnectionsPerHost = brokerConfig?.foregroundMultipartMaximumConnectionsPerHost ?? 24
        config.timeoutIntervalForRequest = 60 * 10
        config.timeoutIntervalForResource = 60 * 60 * 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private static var sessionIdentifier: String {
        BackgroundUploadBrokerConfiguration.current()?.backgroundSessionIdentifier
            ?? "com.aether3d.background-upload.v20260323c"
    }

    override init() {
        super.init()
        restorePersistedMultipartState()
        _ = backgroundSession
    }

    private func shouldRetryMultipartPart(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        if nsError.code == NSURLErrorCancelled,
           let cancellationReason = (nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? NSNumber)?.intValue,
           cancellationReason == NSURLErrorCancelledReasonUserForceQuitApplication {
            return false
        }
        switch nsError.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorCancelled,
             NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorResourceUnavailable,
             NSURLErrorBackgroundSessionInUseByAnotherProcess,
             NSURLErrorBackgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    private func shouldRetryMultipartPart(httpStatusCode: Int) -> Bool {
        switch httpStatusCode {
        case 408, 409, 423, 425, 429:
            return true
        case 500...599:
            return true
        default:
            return false
        }
    }

    private func allUploadTasks() async -> [URLSessionTask] {
        async let backgroundTasks: [URLSessionTask] = withCheckedContinuation { continuation in
            backgroundSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
        async let foregroundTasks: [URLSessionTask] = withCheckedContinuation { continuation in
            foregroundMultipartSession.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
        return await backgroundTasks + foregroundTasks
    }

    private func sourceAvailability(for sourceURL: URL, estimatedTotalBytes: Int64) -> SourceAvailabilitySnapshot {
        if let metadata = ManagedPreparedUploadSourceStore.loadMetadata(for: sourceURL) {
            let availableBytes = max(0, metadata.currentPreparedBytes)
            let totalBytes = metadata.finalized ? availableBytes : max(estimatedTotalBytes, metadata.estimatedUploadBytes)
            return SourceAvailabilitySnapshot(
                availableBytes: availableBytes,
                totalBytes: max(0, totalBytes),
                finalized: metadata.finalized,
                exportFailedReason: metadata.exportFailedReason
            )
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return SourceAvailabilitySnapshot(
            availableBytes: max(0, fileBytes),
            totalBytes: max(0, fileBytes),
            finalized: true,
            exportFailedReason: nil
        )
    }

    private func uploadStallTimeout(for totalBytes: Int64) -> TimeInterval {
        if totalBytes < 200 * 1_024 * 1_024 {
            return 120
        }
        if totalBytes < 1_024 * 1_024 * 1_024 {
            return 60 * 10
        }
        return 60 * 20
    }

    private func artifactDownloadStallTimeout(for totalBytes: Int64) -> TimeInterval {
        if totalBytes <= 0 {
            return 120
        }
        if totalBytes < 200 * 1_024 * 1_024 {
            return 90
        }
        if totalBytes < 1_024 * 1_024 * 1_024 {
            return 60 * 5
        }
        return 60 * 10
    }

    private func artifactDownloadDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether3D", isDirectory: true)
            .appendingPathComponent("background-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func artifactFileExtension(for format: ArtifactFormat) -> String {
        switch format {
        case .splat:
            return "splat"
        case .spz:
            return "spz"
        case .splatPly:
            return "ply"
        }
    }

    private func artifactStagingURL(jobId: String, format: ArtifactFormat) -> URL {
        artifactDownloadDirectory()
            .appendingPathComponent(jobId)
            .appendingPathExtension(artifactFileExtension(for: format))
    }

    private func liveBackgroundTaskIdentifiers() async -> Set<Int> {
        await withCheckedContinuation { continuation in
            backgroundSession.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.map(\.taskIdentifier)))
            }
        }
    }

    private func completedArtifactURLIfAvailable(jobId: String) -> URL? {
        let persisted = storage.loadArtifactDownloads()
        guard let record = persisted.first(where: { $0.jobId == jobId && $0.completedAt != nil }) else {
            return nil
        }
        let url = URL(fileURLWithPath: record.stagedFilePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func failArtifactDownloadWaiters(
        _ waiters: [ArtifactDownloadWaiter],
        error: Error
    ) {
        guard !waiters.isEmpty else { return }
        for waiter in waiters {
            waiter.completion?.resume(throwing: error)
        }
    }

    private func detachArtifactDownloadWaiter(
        taskIdentifier: Int,
        waiterID: UUID
    ) -> ArtifactDownloadWaiter? {
        lock.withLock {
            guard var context = activeDownloadContexts[taskIdentifier],
                  let index = context.waiters.firstIndex(where: { $0.id == waiterID }) else {
                return nil
            }
            let waiter = context.waiters.remove(at: index)
            activeDownloadContexts[taskIdentifier] = context
            return waiter
        }
    }

    func persistedArtifactDownloadRequestURL(jobId: String) -> URL? {
        let persisted = storage.loadArtifactDownloads()
        guard let record = persisted.first(where: { $0.jobId == jobId && $0.completedAt == nil }),
              let rawRequestURL = record.requestURL,
              !rawRequestURL.isEmpty else {
            return nil
        }
        return URL(string: rawRequestURL)
    }

    private func isMultipartUpload(_ upload: BrokerUploadRequest) -> Bool {
        if upload.kind == "multipart" {
            return true
        }
        return upload.uploadId != nil && !(upload.parts?.isEmpty ?? true)
    }

    private func effectiveMultipartConcurrency(for context: MultipartUploadContext) -> Int {
        min(context.maxConcurrency, backgroundMultipartConcurrencyCap)
    }

    private func persistedMultipartStateSnapshot() -> PersistedMultipartState {
        lock.withLock {
            PersistedMultipartState(
                contexts: multipartContexts.values
                    .map(Self.makePersistedMultipartContext(from:))
                    .sorted { $0.jobId < $1.jobId },
                taskContexts: multipartTaskContexts.values
                    .map(Self.makePersistedMultipartTaskContext(from:))
                    .sorted { $0.taskToken < $1.taskToken }
            )
        }
    }

    private func persistMultipartStateSnapshot() {
        storage.saveMultipartState(persistedMultipartStateSnapshot())
    }

    private static func makePersistedMultipartContext(
        from context: MultipartUploadContext
    ) -> PersistedMultipartUploadContext {
        PersistedMultipartUploadContext(
            jobId: context.jobId,
            totalBytes: context.totalBytes,
            sourcePath: context.sourceURL.path,
            storageKey: context.storageKey,
            uploadId: context.uploadId,
            partSizeBytes: context.partSizeBytes,
            maxConcurrency: context.maxConcurrency,
            parts: context.parts,
            partReadyURL: context.partReadyURL?.absoluteString,
            completeURL: context.completeURL.absoluteString,
            abortURL: context.abortURL?.absoluteString,
            tempDirectoryPath: context.tempDirectory.path,
            nextPartIndex: context.nextPartIndex,
            activeTaskIdentifiers: Array(context.activeTaskIdentifiers).sorted(),
            uploadedBytesByPart: context.uploadedBytesByPart,
            completedETagsByPart: context.completedETagsByPart,
            retryCountsByPart: context.retryCountsByPart,
            pendingRetryPartNumbers: context.pendingRetryPartNumbers,
            failed: context.failed,
            isFinalizing: context.isFinalizing,
            lastActivityAt: context.lastActivityAt
        )
    }

    private static func makePersistedMultipartTaskContext(
        from context: MultipartTaskContext
    ) -> PersistedMultipartTaskContext {
        PersistedMultipartTaskContext(
            taskToken: context.taskToken,
            jobId: context.jobId,
            partNumber: context.partNumber,
            totalBytes: context.totalBytes,
            tempFilePath: context.tempFileURL.path
        )
    }

    private static func restoreMultipartContext(
        from persisted: PersistedMultipartUploadContext
    ) -> MultipartUploadContext? {
        guard let completeURL = URL(string: persisted.completeURL) else { return nil }
        return MultipartUploadContext(
            jobId: persisted.jobId,
            totalBytes: persisted.totalBytes,
            sourceURL: URL(fileURLWithPath: persisted.sourcePath),
            storageKey: persisted.storageKey,
            uploadId: persisted.uploadId,
            partSizeBytes: persisted.partSizeBytes,
            maxConcurrency: max(1, persisted.maxConcurrency),
            parts: persisted.parts,
            partReadyURL: persisted.partReadyURL.flatMap(URL.init(string:)),
            completeURL: completeURL,
            abortURL: persisted.abortURL.flatMap(URL.init(string:)),
            onProgress: nil,
            completion: nil,
            tempDirectory: URL(fileURLWithPath: persisted.tempDirectoryPath, isDirectory: true),
            nextPartIndex: persisted.nextPartIndex,
            activeTaskIdentifiers: Set(persisted.activeTaskIdentifiers),
            uploadedBytesByPart: persisted.uploadedBytesByPart,
            completedETagsByPart: persisted.completedETagsByPart,
            retryCountsByPart: persisted.retryCountsByPart,
            pendingRetryPartNumbers: persisted.pendingRetryPartNumbers,
            failed: persisted.failed,
            isFinalizing: persisted.isFinalizing,
            lastActivityAt: persisted.lastActivityAt
        )
    }

    private func restorePersistedMultipartState() {
        let persisted = storage.loadMultipartState()
        guard !persisted.contexts.isEmpty || !persisted.taskContexts.isEmpty else { return }

        var restoredContexts: [String: MultipartUploadContext] = [:]
        var restoredTaskContexts: [String: MultipartTaskContext] = [:]

        for persistedContext in persisted.contexts {
            guard let restored = Self.restoreMultipartContext(from: persistedContext) else {
                cleanupMultipartTempDirectory(jobId: persistedContext.jobId)
                ManagedPreparedUploadSourceStore.cleanupIfManaged(URL(fileURLWithPath: persistedContext.sourcePath))
                continue
            }
            restoredContexts[restored.jobId] = restored
        }

        for persistedTaskContext in persisted.taskContexts {
            guard restoredContexts[persistedTaskContext.jobId] != nil else { continue }
            restoredTaskContexts[persistedTaskContext.taskToken] = MultipartTaskContext(
                taskToken: persistedTaskContext.taskToken,
                jobId: persistedTaskContext.jobId,
                partNumber: persistedTaskContext.partNumber,
                totalBytes: persistedTaskContext.totalBytes,
                tempFileURL: URL(fileURLWithPath: persistedTaskContext.tempFilePath)
            )
        }

        lock.withLock {
            multipartContexts = restoredContexts
            multipartTaskContexts = restoredTaskContexts
        }
        persistMultipartStateSnapshot()

        Task {
            await self.reconcileRestoredMultipartState()
        }
    }

    private func reconcileRestoredMultipartState() async {
        let tasks = await allUploadTasks()
        let liveTaskTokens = Set(tasks.compactMap(\.taskDescription))

        let jobIds = lock.withLock { () -> [String] in
            for (jobId, var context) in multipartContexts {
                context.activeTaskIdentifiers = context.activeTaskIdentifiers.filter { liveTaskTokens.contains($0) }
                context.lastActivityAt = Date()

                let orphanTokens = multipartTaskContexts.values
                    .filter { $0.jobId == jobId && !liveTaskTokens.contains($0.taskToken) }
                    .map(\.taskToken)

                for taskToken in orphanTokens {
                    guard let taskContext = multipartTaskContexts.removeValue(forKey: taskToken) else { continue }
                    context.activeTaskIdentifiers.remove(taskContext.taskToken)
                    if context.completedETagsByPart[taskContext.partNumber] == nil {
                        if !context.pendingRetryPartNumbers.contains(taskContext.partNumber) {
                            context.pendingRetryPartNumbers.append(taskContext.partNumber)
                        }
                        context.uploadedBytesByPart[taskContext.partNumber] = 0
                    }
                    try? FileManager.default.removeItem(at: taskContext.tempFileURL)
                }

                multipartContexts[jobId] = context
            }
            return Array(multipartContexts.keys)
        }

        persistMultipartStateSnapshot()

        for jobId in jobIds {
            startMultipartMonitor(for: jobId)
            await scheduleMultipartWork(for: jobId)
        }
    }

    func handleEvents(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { return }
        lock.lock()
        pendingCompletionHandlers[identifier] = completionHandler
        lock.unlock()
        _ = backgroundSession
        Task {
            await self.reconcileRestoredMultipartState()
        }
    }

    func beginUpload(
        jobId: String,
        upload: BrokerUploadRequest,
        sourceURL: URL,
        totalBytes: Int64,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        if isMultipartUpload(upload) {
            return try await beginMultipartUpload(
                jobId: jobId,
                upload: upload,
                sourceURL: sourceURL,
                totalBytes: totalBytes,
                onProgress: onProgress
            )
        }

        var request = URLRequest(url: try uploadURL(from: upload))
        request.httpMethod = upload.method ?? "PUT"
        request.networkServiceType = .responsiveData
        for (key, value) in upload.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(String(totalBytes), forHTTPHeaderField: "Content-Length")
        try await waitUntilSourceReadableForTaskCreation(sourceURL)

        return try await withCheckedThrowingContinuation { continuation in
            let task = backgroundSession.uploadTask(with: request, fromFile: sourceURL)
            task.priority = URLSessionTask.highPriority

            lock.lock()
            activeContexts[task.taskIdentifier] = SingleUploadContext(
                jobId: jobId,
                totalBytes: totalBytes,
                sourceURL: sourceURL,
                onProgress: onProgress,
                completion: continuation
            )
            uploadActivity[task.taskIdentifier] = UploadActivity(
                lastProgressAt: Date(),
                totalBytesSent: 0
            )
            stalledUploads.removeValue(forKey: task.taskIdentifier)
            let persisted = PersistedBackgroundUploadTask(
                taskIdentifier: task.taskIdentifier,
                jobId: jobId,
                sourcePath: sourceURL.path,
                totalBytes: totalBytes,
                createdAt: Date()
            )
            var existing = storage.load()
            existing.removeAll { $0.taskIdentifier == task.taskIdentifier || $0.jobId == jobId }
            existing.append(persisted)
            storage.save(existing)
            lock.unlock()

            Task {
                if let onProgress {
                    await onProgress(RemoteUploadProgress(uploadedBytes: 0, totalBytes: totalBytes))
                }
            }

            startStallMonitor(for: task.taskIdentifier)
            task.resume()
        }
    }

    func beginArtifactDownload(
        jobId: String,
        request: URLRequest,
        format: ArtifactFormat,
        onProgress: (@Sendable (Int64, Int64) async -> Void)? = nil
    ) async throws -> URL {
        if let completedURL = completedArtifactURLIfAvailable(jobId: jobId) {
            return completedURL
        }

        let stagedFileURL = artifactStagingURL(jobId: jobId, format: format)
        let persisted = storage.loadArtifactDownloads()
        if let existing = persisted.first(where: { $0.jobId == jobId && $0.completedAt == nil }) {
            let existingStagedURL = URL(fileURLWithPath: existing.stagedFilePath)
            if FileManager.default.fileExists(atPath: existingStagedURL.path) {
                markArtifactDownloadCompleted(taskIdentifier: existing.taskIdentifier)
                return existingStagedURL
            }
            let liveTaskIdentifiers = await liveBackgroundTaskIdentifiers()
            if liveTaskIdentifiers.contains(existing.taskIdentifier) {
                let shouldReuseExistingTask = existing.requestURL == request.url?.absoluteString
                if shouldReuseExistingTask {
                    let waiterID = UUID()
                    return try await withTaskCancellationHandler(
                        operation: {
                            try await withCheckedThrowingContinuation { continuation in
                                var replacedWaiters: [ArtifactDownloadWaiter] = []
                                lock.lock()
                                let waiter = ArtifactDownloadWaiter(
                                    id: waiterID,
                                    onProgress: onProgress,
                                    completion: continuation
                                )
                                if var context = activeDownloadContexts[existing.taskIdentifier],
                                   context.jobId == jobId,
                                   context.requestURL == (request.url ?? URL(fileURLWithPath: existing.stagedFilePath)) {
                                    context.waiters.append(waiter)
                                    activeDownloadContexts[existing.taskIdentifier] = context
                                } else {
                                    replacedWaiters = activeDownloadContexts[existing.taskIdentifier]?.waiters ?? []
                                    activeDownloadContexts[existing.taskIdentifier] = ArtifactDownloadContext(
                                        jobId: jobId,
                                        format: format,
                                        stagedFileURL: URL(fileURLWithPath: existing.stagedFilePath),
                                        requestURL: request.url ?? URL(fileURLWithPath: existing.stagedFilePath),
                                        waiters: [waiter]
                                    )
                                }
                                if downloadActivity[existing.taskIdentifier] == nil {
                                    downloadActivity[existing.taskIdentifier] = DownloadActivity(
                                        lastProgressAt: Date(),
                                        totalBytesWritten: 0,
                                        totalBytesExpected: 0
                                    )
                                }
                                stalledArtifactDownloads.removeValue(forKey: existing.taskIdentifier)
                                lock.unlock()
                                if !replacedWaiters.isEmpty {
                                    self.failArtifactDownloadWaiters(
                                        replacedWaiters,
                                        error: RemoteB1ClientError.downloadFailed("artifact_download_context_replaced")
                                    )
                                }
                                startArtifactDownloadStallMonitor(for: existing.taskIdentifier)
                            }
                        },
                        onCancel: {
                            if let waiter = self.detachArtifactDownloadWaiter(
                                taskIdentifier: existing.taskIdentifier,
                                waiterID: waiterID
                            ) {
                                waiter.completion?.resume(throwing: CancellationError())
                            }
                        }
                    )
                }

                let tasks = await allUploadTasks()
                if let liveTask = tasks.first(where: { $0.taskIdentifier == existing.taskIdentifier }) {
                    liveTask.cancel()
                }
            }

            var remaining = persisted
            remaining.removeAll { $0.taskIdentifier == existing.taskIdentifier }
            storage.saveArtifactDownloads(remaining)
            let removedWaiters = lock.withLock { () -> [ArtifactDownloadWaiter] in
                let waiters = activeDownloadContexts.removeValue(forKey: existing.taskIdentifier)?.waiters ?? []
                downloadActivity.removeValue(forKey: existing.taskIdentifier)
                stalledArtifactDownloads.removeValue(forKey: existing.taskIdentifier)
                return waiters
            }
            if !removedWaiters.isEmpty {
                failArtifactDownloadWaiters(
                    removedWaiters,
                    error: RemoteB1ClientError.downloadFailed("artifact_download_restarted")
                )
            }
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: existing.stagedFilePath))
        }

        try? FileManager.default.removeItem(at: stagedFileURL)

        let waiterID = UUID()
        final class DownloadTaskRegistrationBox: @unchecked Sendable {
            let lock = NSLock()
            var taskIdentifier: Int?

            func set(_ identifier: Int) {
                lock.lock()
                taskIdentifier = identifier
                lock.unlock()
            }

            func get() -> Int? {
                lock.lock()
                defer { lock.unlock() }
                return taskIdentifier
            }
        }
        let registration = DownloadTaskRegistrationBox()

        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let task = backgroundSession.downloadTask(with: request)
                    task.priority = URLSessionTask.highPriority
                    registration.set(task.taskIdentifier)

                    lock.lock()
                    activeDownloadContexts[task.taskIdentifier] = ArtifactDownloadContext(
                        jobId: jobId,
                        format: format,
                        stagedFileURL: stagedFileURL,
                        requestURL: request.url ?? stagedFileURL,
                        waiters: [
                            ArtifactDownloadWaiter(
                                id: waiterID,
                                onProgress: onProgress,
                                completion: continuation
                            )
                        ]
                    )
                    downloadActivity[task.taskIdentifier] = DownloadActivity(
                        lastProgressAt: Date(),
                        totalBytesWritten: 0,
                        totalBytesExpected: 0
                    )
                    stalledArtifactDownloads.removeValue(forKey: task.taskIdentifier)
                    lock.unlock()

                    var persisted = storage.loadArtifactDownloads()
                    persisted.removeAll { $0.jobId == jobId || $0.taskIdentifier == task.taskIdentifier }
                    persisted.append(
                        PersistedArtifactDownloadTask(
                            taskIdentifier: task.taskIdentifier,
                            jobId: jobId,
                            stagedFilePath: stagedFileURL.path,
                            format: artifactFileExtension(for: format),
                            requestURL: request.url?.absoluteString,
                            createdAt: Date(),
                            completedAt: nil
                        )
                    )
                    storage.saveArtifactDownloads(persisted)

                    startArtifactDownloadStallMonitor(for: task.taskIdentifier)
                    task.resume()
                }
            },
            onCancel: {
                guard let taskIdentifier = registration.get(),
                      let waiter = self.detachArtifactDownloadWaiter(
                        taskIdentifier: taskIdentifier,
                        waiterID: waiterID
                      ) else {
                    return
                }
                waiter.completion?.resume(throwing: CancellationError())
            }
        )
    }

    private func waitUntilSourceReadableForTaskCreation(
        _ sourceURL: URL,
        timeout: TimeInterval = 15
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let fileBytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if fileBytes > 0,
               FileManager.default.fileExists(atPath: sourceURL.path),
               FileManager.default.isReadableFile(atPath: sourceURL.path) {
                return
            }

            if let metadata = ManagedPreparedUploadSourceStore.loadMetadata(for: sourceURL),
               metadata.finalized,
               let exportFailedReason = metadata.exportFailedReason {
                throw RemoteB1ClientError.uploadFailed("stream_friendly_export_failed:\(exportFailedReason)")
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw RemoteB1ClientError.uploadFailed("upload_source_unreadable")
    }

    private func beginMultipartUpload(
        jobId: String,
        upload: BrokerUploadRequest,
        sourceURL: URL,
        totalBytes: Int64,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        guard let uploadId = upload.uploadId,
              let partSizeBytes = upload.partSizeBytes,
              let parts = upload.parts,
              !parts.isEmpty,
              let completeURLString = upload.completeURL,
              let completeURL = URL(string: completeURLString) else {
            throw RemoteB1ClientError.invalidResponse
        }

        let abortURL = upload.abortURL.flatMap(URL.init(string:))
        let partReadyURL = upload.partReadyURL.flatMap(URL.init(string:))
        let tempDirectory = try multipartTempDirectory(for: jobId)

        return try await withCheckedThrowingContinuation { continuation in
            let context = MultipartUploadContext(
                jobId: jobId,
                totalBytes: totalBytes,
                sourceURL: sourceURL,
                storageKey: upload.storageKey,
                uploadId: uploadId,
                partSizeBytes: Int64(partSizeBytes),
                maxConcurrency: max(1, upload.maxConcurrency ?? 8),
                parts: parts,
                partReadyURL: partReadyURL,
                completeURL: completeURL,
                abortURL: abortURL,
                onProgress: onProgress,
                completion: continuation,
                tempDirectory: tempDirectory,
                nextPartIndex: 0,
                activeTaskIdentifiers: [],
                uploadedBytesByPart: [:],
                completedETagsByPart: [:],
                retryCountsByPart: [:],
                pendingRetryPartNumbers: [],
                failed: false,
                isFinalizing: false,
                lastActivityAt: Date()
            )
            lock.lock()
            multipartContexts[jobId] = context
            lock.unlock()
            self.persistMultipartStateSnapshot()

            Task {
                if let onProgress {
                    await onProgress(RemoteUploadProgress(uploadedBytes: 0, totalBytes: totalBytes))
                }
                self.startMultipartMonitor(for: jobId)
                await self.scheduleMultipartWork(for: jobId)
            }
        }
    }

    func cancelUploadIfPresent(jobId: String) async {
        let multipartState: (MultipartUploadContext, [String])? = lock.withLock { () -> (MultipartUploadContext, [String])? in
            guard let context = multipartContexts.removeValue(forKey: jobId) else {
                return nil
            }
            multipartTaskContexts = multipartTaskContexts.filter { $0.value.jobId != jobId }
            return (context, Array(context.activeTaskIdentifiers))
        }

        if let multipartState {
            persistMultipartStateSnapshot()
            let tasks = await allUploadTasks()
            for task in tasks where multipartState.1.contains(task.taskDescription ?? "") {
                task.cancel()
            }
            await performMultipartAbort(
                url: multipartState.0.abortURL,
                requestBody: BrokerMultipartAbortRequest(
                    uploadId: multipartState.0.uploadId,
                    storageKey: multipartState.0.storageKey
                )
            )
            cleanupMultipartTempDirectory(jobId: jobId)
            ManagedPreparedUploadSourceStore.cleanupIfManaged(multipartState.0.sourceURL)
            return
        }

        let taskIdentifier: Int? = {
            let persisted = storage.load()
            return persisted.first(where: { $0.jobId == jobId })?.taskIdentifier
        }()

        guard let taskIdentifier else { return }
        let tasks = await allUploadTasks()
        if let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) {
            task.cancel()
        }
    }

    private func uploadURL(from request: BrokerUploadRequest) throws -> URL {
        guard let rawURL = request.url,
              let url = URL(string: rawURL) else {
            throw RemoteB1ClientError.invalidResponse
        }
        return url
    }

    private func multipartTempDirectory(for jobId: String) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether3D", isDirectory: true)
            .appendingPathComponent("multipart-uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(jobId, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanupMultipartTempDirectory(jobId: String) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether3D", isDirectory: true)
            .appendingPathComponent("multipart-uploads", isDirectory: true)
        let directory = root.appendingPathComponent(jobId, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private func materializePartFile(
        from sourceURL: URL,
        offset: Int64,
        totalBytes: Int64,
        to tempFileURL: URL
    ) throws {
        guard totalBytes > 0 else {
            throw RemoteB1ClientError.uploadFailed("invalid_multipart_part_size")
        }
        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: tempFileURL)
        defer {
            try? input.close()
            try? output.close()
        }

        try input.seek(toOffset: UInt64(offset))
        var remaining = totalBytes
        while remaining > 0 {
            let readSize = Int(min(1_024 * 1_024, remaining))
            guard let chunk = try input.read(upToCount: readSize), !chunk.isEmpty else {
                throw RemoteB1ClientError.uploadFailed("multipart_part_read_underflow")
            }
            try output.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private func scheduleMultipartWork(for jobId: String) async {
        while true {
            let selection: (MultipartWorkItem?, MultipartUploadContext?, Bool) = lock.withLock {
                guard var context = multipartContexts[jobId], !context.failed else {
                    return (nil, nil, false)
                }
                if context.activeTaskIdentifiers.count < effectiveMultipartConcurrency(for: context) {
                    let sourceSnapshot = self.sourceAvailability(for: context.sourceURL, estimatedTotalBytes: context.totalBytes)
                    let finalizedTotalBytes = sourceSnapshot.finalized ? min(sourceSnapshot.totalBytes, context.totalBytes) : context.totalBytes
                    var selectedPart: BrokerMultipartPartRequest?
                    var selectedPartBytes: Int64?
                    if !context.pendingRetryPartNumbers.isEmpty {
                        let nextPartNumber = context.pendingRetryPartNumbers.removeFirst()
                        if let retryPart = context.parts.first(where: { $0.partNumber == nextPartNumber }) {
                            let offset = Int64(retryPart.partNumber - 1) * context.partSizeBytes
                            if sourceSnapshot.finalized {
                                let remainingBytes = max(0, finalizedTotalBytes - offset)
                                if remainingBytes > 0 {
                                    selectedPart = retryPart
                                    selectedPartBytes = min(context.partSizeBytes, remainingBytes)
                                }
                            } else if sourceSnapshot.availableBytes >= offset + context.partSizeBytes {
                                selectedPart = retryPart
                                selectedPartBytes = context.partSizeBytes
                            } else if !context.pendingRetryPartNumbers.contains(nextPartNumber) {
                                context.pendingRetryPartNumbers.insert(nextPartNumber, at: 0)
                            }
                        }
                    } else {
                        while context.nextPartIndex < context.parts.count {
                            let candidatePart = context.parts[context.nextPartIndex]
                            let offset = Int64(candidatePart.partNumber - 1) * context.partSizeBytes
                            if sourceSnapshot.finalized {
                                let remainingBytes = max(0, finalizedTotalBytes - offset)
                                if remainingBytes <= 0 {
                                    context.nextPartIndex = context.parts.count
                                    break
                                }
                                selectedPart = candidatePart
                                selectedPartBytes = min(context.partSizeBytes, remainingBytes)
                                context.nextPartIndex += 1
                                break
                            }
                            if sourceSnapshot.availableBytes >= offset + context.partSizeBytes {
                                selectedPart = candidatePart
                                selectedPartBytes = context.partSizeBytes
                                context.nextPartIndex += 1
                                break
                            }
                            break
                        }
                    }

                    guard let part = selectedPart,
                          let partBytes = selectedPartBytes,
                          partBytes > 0 else {
                        multipartContexts[jobId] = context
                        return (nil, nil, false)
                    }
                    context.lastActivityAt = Date()
                    multipartContexts[jobId] = context
                    let offset = Int64(part.partNumber - 1) * context.partSizeBytes
                    let tempFileURL = context.tempDirectory.appendingPathComponent(
                        String(format: "part-%05d.upload", part.partNumber)
                    )
                    return (
                        MultipartWorkItem(
                            jobId: jobId,
                            sourceURL: context.sourceURL,
                            part: part,
                            offset: offset,
                            totalBytes: partBytes,
                            tempFileURL: tempFileURL
                        ),
                        nil,
                        false
                    )
                }

                let sourceSnapshot = self.sourceAvailability(for: context.sourceURL, estimatedTotalBytes: context.totalBytes)
                let finalizedTotalBytes = sourceSnapshot.finalized ? min(sourceSnapshot.totalBytes, context.totalBytes) : context.totalBytes
                let expectedFinalPartCount: Int
                if sourceSnapshot.finalized {
                    expectedFinalPartCount = finalizedTotalBytes > 0
                        ? Int((finalizedTotalBytes + context.partSizeBytes - 1) / context.partSizeBytes)
                        : 0
                } else {
                    expectedFinalPartCount = context.parts.count
                }

                if !context.isFinalizing,
                   sourceSnapshot.finalized,
                   context.completedETagsByPart.count == expectedFinalPartCount,
                   context.activeTaskIdentifiers.isEmpty,
                   context.pendingRetryPartNumbers.isEmpty {
                    context.isFinalizing = true
                    context.lastActivityAt = Date()
                    multipartContexts[jobId] = context
                    return (nil, context, true)
                }
                multipartContexts[jobId] = context
                return (nil, nil, false)
            }

            if selection.2 {
                persistMultipartStateSnapshot()
            }

            if let finalizeContext = selection.1 {
                await finalizeMultipartUpload(finalizeContext)
                return
            }

            guard let workItem = selection.0 else {
                return
            }

            do {
                try materializePartFile(
                    from: workItem.sourceURL,
                    offset: workItem.offset,
                    totalBytes: workItem.totalBytes,
                    to: workItem.tempFileURL
                )
            } catch {
                await failMultipartUpload(jobId: jobId, reason: "multipart_prepare_failed:\(error)")
                return
            }

            guard let partURL = URL(string: workItem.part.url) else {
                await failMultipartUpload(jobId: jobId, reason: "invalid_multipart_part_url")
                return
            }

            var request = URLRequest(url: partURL)
            request.httpMethod = workItem.part.method
            request.networkServiceType = .responsiveData
            for (key, value) in workItem.part.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            request.setValue(String(workItem.totalBytes), forHTTPHeaderField: "Content-Length")

            // Product path favors persistence over burst speed:
            // multipart/chunked uploads must survive app backgrounding and screen lock.
            let session = backgroundSession
            let task = session.uploadTask(
                with: request,
                fromFile: workItem.tempFileURL
            )
            task.priority = URLSessionTask.highPriority
            let taskToken = Self.multipartTaskToken(
                jobId: jobId,
                partNumber: workItem.part.partNumber,
                session: session
            )
            task.taskDescription = taskToken
            let taskContext = MultipartTaskContext(
                taskToken: taskToken,
                jobId: jobId,
                partNumber: workItem.part.partNumber,
                totalBytes: workItem.totalBytes,
                tempFileURL: workItem.tempFileURL
            )
            let shouldResume = lock.withLock {
                guard var context = multipartContexts[jobId], !context.failed else {
                    return false
                }
                context.activeTaskIdentifiers.insert(taskToken)
                context.uploadedBytesByPart[workItem.part.partNumber] = 0
                context.lastActivityAt = Date()
                multipartContexts[jobId] = context
                multipartTaskContexts[taskToken] = taskContext
                return true
            }
            if !shouldResume {
                try? FileManager.default.removeItem(at: workItem.tempFileURL)
                return
            }
            persistMultipartStateSnapshot()
            task.resume()
        }
    }

    private func multipartProgressState(for jobId: String) -> (RemoteUploadProgress, (@Sendable (RemoteUploadProgress) async -> Void)?)? {
        lock.withLock { () -> (RemoteUploadProgress, (@Sendable (RemoteUploadProgress) async -> Void)?)? in
            guard let context = multipartContexts[jobId] else { return nil }
            let uploadedBytes = min(context.totalBytes, context.uploadedBytesByPart.values.reduce(0, +))
            let phase: RemoteUploadPhase = (context.totalBytes > 0 && uploadedBytes >= context.totalBytes) ? .finalizing : .transferring
            return (
                RemoteUploadProgress(uploadedBytes: uploadedBytes, totalBytes: context.totalBytes, phase: phase),
                context.onProgress
            )
        }
    }

    private func emitMultipartProgress(for jobId: String) {
        guard let (progress, onProgress) = multipartProgressState(for: jobId),
              let onProgress else { return }
        Task {
            await onProgress(progress)
        }
    }

    private static func multipartTaskToken(jobId: String, partNumber: Int, session: URLSession) -> String {
        let sessionLabel = session.configuration.identifier ?? "foreground-multipart"
        return "\(jobId):part:\(partNumber):session:\(sessionLabel):\(UUID().uuidString)"
    }

    private func startMultipartMonitor(for jobId: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(nanoseconds: self.multipartMonitorPollInterval)

                enum MonitorAction {
                    case none
                    case finalize(MultipartUploadContext)
                    case recoverStalledActiveTasks([MultipartRecoveryTask])
                    case reschedule
                    case fail(String)
                    case stop
                }

                let action: (MonitorAction, Bool) = self.lock.withLock {
                    guard var context = self.multipartContexts[jobId] else {
                        return (.stop, false)
                    }
                    if context.failed {
                        return (.stop, false)
                    }

                    let now = Date()
                    let allPartNumbers = Set(context.parts.map(\.partNumber))
                    let completedPartNumbers = Set(context.completedETagsByPart.keys)
                    let missingCompletedParts = Array(allPartNumbers.subtracting(completedPartNumbers)).sorted()
                    let uploadedBytes = min(context.totalBytes, context.uploadedBytesByPart.values.reduce(0, +))
                    let isAllBytesSent = context.totalBytes > 0 && uploadedBytes >= context.totalBytes
                    let sourceSnapshot = self.sourceAvailability(for: context.sourceURL, estimatedTotalBytes: context.totalBytes)
                    let finalizedTotalBytes = sourceSnapshot.finalized ? min(sourceSnapshot.totalBytes, context.totalBytes) : context.totalBytes
                    let expectedFinalPartCount: Int = sourceSnapshot.finalized && finalizedTotalBytes > 0
                        ? Int((finalizedTotalBytes + context.partSizeBytes - 1) / context.partSizeBytes)
                        : context.parts.count
                    if let exportFailedReason = sourceSnapshot.exportFailedReason,
                       context.activeTaskIdentifiers.isEmpty {
                        context.failed = true
                        self.multipartContexts[jobId] = context
                        return (.fail("stream_friendly_export_failed:\(exportFailedReason)"), true)
                    }
                    let isReadyToFinalize = !context.isFinalizing &&
                        sourceSnapshot.finalized &&
                        context.completedETagsByPart.count == expectedFinalPartCount &&
                        context.activeTaskIdentifiers.isEmpty &&
                        context.pendingRetryPartNumbers.isEmpty

                    if isReadyToFinalize {
                        context.isFinalizing = true
                        context.lastActivityAt = now
                        self.multipartContexts[jobId] = context
                        return (.finalize(context), true)
                    }

                    let stalledAfterAllBytes = isAllBytesSent &&
                        !context.isFinalizing &&
                        now.timeIntervalSince(context.lastActivityAt) >= self.multipartFinalizeRecoveryInterval

                    if stalledAfterAllBytes && !context.activeTaskIdentifiers.isEmpty {
                        var recoveryTasks: [MultipartRecoveryTask] = []
                        for taskToken in Array(context.activeTaskIdentifiers) {
                            guard let taskContext = self.multipartTaskContexts.removeValue(forKey: taskToken) else {
                                context.activeTaskIdentifiers.remove(taskToken)
                                continue
                            }
                            recoveryTasks.append(
                                MultipartRecoveryTask(
                                    taskToken: taskToken,
                                    tempFileURL: taskContext.tempFileURL
                                )
                            )
                            context.activeTaskIdentifiers.remove(taskToken)
                            if context.completedETagsByPart[taskContext.partNumber] != nil {
                                continue
                            }
                            let nextRetryCount = (context.retryCountsByPart[taskContext.partNumber] ?? 0) + 1
                            if nextRetryCount > self.multipartPartRetryLimit {
                                return (.fail("multipart_stalled_active_part_\(taskContext.partNumber)"), false)
                            }
                            context.retryCountsByPart[taskContext.partNumber] = nextRetryCount
                            if !context.pendingRetryPartNumbers.contains(taskContext.partNumber) {
                                context.pendingRetryPartNumbers.append(taskContext.partNumber)
                            }
                            context.uploadedBytesByPart[taskContext.partNumber] = 0
                        }
                        context.lastActivityAt = now
                        self.multipartContexts[jobId] = context
                        return (.recoverStalledActiveTasks(recoveryTasks), true)
                    }

                    let stalledAfterAllBytesWithNoActiveTasks = stalledAfterAllBytes &&
                        context.activeTaskIdentifiers.isEmpty &&
                        context.pendingRetryPartNumbers.isEmpty &&
                        !missingCompletedParts.isEmpty

                    if stalledAfterAllBytesWithNoActiveTasks {
                        for partNumber in missingCompletedParts {
                            let nextRetryCount = (context.retryCountsByPart[partNumber] ?? 0) + 1
                            if nextRetryCount > self.multipartPartRetryLimit {
                                return (.fail("multipart_finalize_stalled_missing_part_\(partNumber)"), false)
                            }
                            context.retryCountsByPart[partNumber] = nextRetryCount
                            context.pendingRetryPartNumbers.append(partNumber)
                            context.uploadedBytesByPart[partNumber] = 0
                        }
                        context.lastActivityAt = now
                        self.multipartContexts[jobId] = context
                        return (.reschedule, true)
                    }

                    let shouldPollForGrowingSource = !sourceSnapshot.finalized &&
                        context.activeTaskIdentifiers.isEmpty &&
                        context.pendingRetryPartNumbers.isEmpty &&
                        context.nextPartIndex < context.parts.count
                    let shouldRescheduleFinalTail = sourceSnapshot.finalized &&
                        !context.isFinalizing &&
                        context.activeTaskIdentifiers.isEmpty &&
                        context.pendingRetryPartNumbers.isEmpty &&
                        context.completedETagsByPart.count < expectedFinalPartCount
                    if shouldRescheduleFinalTail {
                        return (.reschedule, false)
                    }
                    if shouldPollForGrowingSource {
                        return (.reschedule, false)
                    }

                    return (.none, false)
                }

                if action.1 {
                    self.persistMultipartStateSnapshot()
                }

                switch action.0 {
                case .none:
                    continue
                case let .finalize(context):
                    await self.finalizeMultipartUpload(context)
                    return
                case let .recoverStalledActiveTasks(recoveryTasks):
                    let tasks = await self.allUploadTasks()
                    let recoveryTokens = Set(recoveryTasks.map(\.taskToken))
                    for task in tasks where recoveryTokens.contains(task.taskDescription ?? "") {
                        task.cancel()
                    }
                    for recoveryTask in recoveryTasks {
                        try? FileManager.default.removeItem(at: recoveryTask.tempFileURL)
                    }
                    self.emitMultipartProgress(for: jobId)
                    await self.scheduleMultipartWork(for: jobId)
                case .reschedule:
                    self.emitMultipartProgress(for: jobId)
                    await self.scheduleMultipartWork(for: jobId)
                case let .fail(reason):
                    await self.failMultipartUpload(jobId: jobId, reason: reason)
                    return
                case .stop:
                    return
                }
            }
        }
    }

    private func finalizeMultipartUpload(_ context: MultipartUploadContext) async {
        var request = URLRequest(url: context.completeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.networkServiceType = .responsiveData

        let parts = context.completedETagsByPart.keys.sorted().compactMap { partNumber -> BrokerMultipartCompletedPart? in
            guard let etag = context.completedETagsByPart[partNumber] else { return nil }
            return BrokerMultipartCompletedPart(partNumber: partNumber, etag: etag)
        }
        let payload = BrokerMultipartCompleteRequest(
            uploadId: context.uploadId,
            storageKey: context.storageKey,
            parts: parts,
            sizeBytes: sourceAvailability(for: context.sourceURL, estimatedTotalBytes: context.totalBytes).totalBytes
        )

        do {
            request.httpBody = try encoder.encode(payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RemoteB1ClientError.networkError("multipart_complete_http_failed")
            }
        } catch {
            await failMultipartUpload(jobId: context.jobId, reason: "multipart_complete_failed:\(error)")
            return
        }

        let completion = lock.withLock { () -> CheckedContinuation<String, Error>? in
            let removed = multipartContexts.removeValue(forKey: context.jobId)
            multipartTaskContexts = multipartTaskContexts.filter { $0.value.jobId != context.jobId }
            return removed?.completion
        }
        persistMultipartStateSnapshot()
        cleanupMultipartTempDirectory(jobId: context.jobId)
        ManagedPreparedUploadSourceStore.cleanupIfManaged(context.sourceURL)
        completion?.resume(returning: context.jobId)
    }

    private func performMultipartAbort(
        url: URL?,
        requestBody: BrokerMultipartAbortRequest
    ) async {
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? encoder.encode(requestBody)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func notifyMultipartPartReady(
        url: URL?,
        requestBody: BrokerMultipartPartReadyRequest
    ) async {
        guard let url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? encoder.encode(requestBody)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func failMultipartUpload(jobId: String, reason: String) async {
        let state = lock.withLock { () -> (MultipartUploadContext, [String])? in
            guard var context = multipartContexts.removeValue(forKey: jobId) else {
                return nil
            }
            context.failed = true
            let taskIds = Array(context.activeTaskIdentifiers)
            multipartTaskContexts = multipartTaskContexts.filter { $0.value.jobId != jobId }
            return (context, taskIds)
        }

        guard let state else { return }
        persistMultipartStateSnapshot()

        let tasks = await allUploadTasks()
        for task in tasks where state.1.contains(task.taskDescription ?? "") {
            task.cancel()
        }

        cleanupMultipartTempDirectory(jobId: jobId)
        ManagedPreparedUploadSourceStore.cleanupIfManaged(state.0.sourceURL)
        await performMultipartAbort(
            url: state.0.abortURL,
            requestBody: BrokerMultipartAbortRequest(
                uploadId: state.0.uploadId,
                storageKey: state.0.storageKey
            )
        )
        state.0.completion?.resume(throwing: RemoteB1ClientError.uploadFailed(reason))
    }

    private func removeTaskState(taskIdentifier: Int) {
        var persisted = storage.load()
        let sourcePaths = persisted
            .filter { $0.taskIdentifier == taskIdentifier }
            .map(\.sourcePath)
        persisted.removeAll { $0.taskIdentifier == taskIdentifier }
        storage.save(persisted)
        for sourcePath in sourcePaths {
            ManagedPreparedUploadSourceStore.cleanupIfManaged(URL(fileURLWithPath: sourcePath))
        }
    }

    private func markArtifactDownloadCompleted(taskIdentifier: Int) {
        var persisted = storage.loadArtifactDownloads()
        guard let index = persisted.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) else {
            return
        }
        let existing = persisted[index]
        persisted[index] = PersistedArtifactDownloadTask(
            taskIdentifier: existing.taskIdentifier,
            jobId: existing.jobId,
            stagedFilePath: existing.stagedFilePath,
            format: existing.format,
            requestURL: existing.requestURL,
            createdAt: existing.createdAt,
            completedAt: Date()
        )
        storage.saveArtifactDownloads(persisted)
    }

    private func removeArtifactDownloadState(taskIdentifier: Int, removeStagedFile: Bool) {
        var persisted = storage.loadArtifactDownloads()
        let stagedPaths = persisted
            .filter { $0.taskIdentifier == taskIdentifier }
            .map(\.stagedFilePath)
        persisted.removeAll { $0.taskIdentifier == taskIdentifier }
        storage.saveArtifactDownloads(persisted)
        lock.withLock {
            downloadActivity.removeValue(forKey: taskIdentifier)
            stalledArtifactDownloads.removeValue(forKey: taskIdentifier)
        }
        if removeStagedFile {
            for stagedPath in stagedPaths {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: stagedPath))
            }
        }
    }

    private func startStallMonitor(for taskIdentifier: Int) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(nanoseconds: self.uploadStallPollInterval)

                let shouldCancel: Bool = self.lock.withLock {
                    guard let activity = self.uploadActivity[taskIdentifier],
                          let context = self.activeContexts[taskIdentifier] else {
                        return false
                    }
                    let stallTimeout = self.uploadStallTimeout(for: context.totalBytes)
                    if Date().timeIntervalSince(activity.lastProgressAt) < stallTimeout {
                        return false
                    }
                    self.stalledUploads[taskIdentifier] = activity.totalBytesSent
                    return true
                }

                guard shouldCancel else {
                    let isFinished = self.lock.withLock { self.activeContexts[taskIdentifier] == nil }
                    if isFinished {
                        return
                    }
                    continue
                }

                let tasks = await self.allUploadTasks()
                if let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) {
                    task.cancel()
                }
                return
            }
        }
    }

    private func startArtifactDownloadStallMonitor(for taskIdentifier: Int) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while true {
                try? await Task.sleep(nanoseconds: self.downloadStallPollInterval)

                let shouldCancel: Bool = self.lock.withLock {
                    guard let activity = self.downloadActivity[taskIdentifier],
                          self.activeDownloadContexts[taskIdentifier] != nil else {
                        return false
                    }
                    let stallTimeout = self.artifactDownloadStallTimeout(for: activity.totalBytesExpected)
                    if Date().timeIntervalSince(activity.lastProgressAt) < stallTimeout {
                        return false
                    }
                    self.stalledArtifactDownloads[taskIdentifier] = activity.totalBytesWritten
                    return true
                }

                guard shouldCancel else {
                    let isFinished = self.lock.withLock { self.activeDownloadContexts[taskIdentifier] == nil }
                    if isFinished {
                        return
                    }
                    continue
                }

                let tasks = await self.allUploadTasks()
                if let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) {
                    task.cancel()
                }
                return
            }
        }
    }

    private func completionHandlerIfNeeded() -> (() -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return pendingCompletionHandlers.removeValue(forKey: Self.sessionIdentifier)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionHandlerIfNeeded()?()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        if let multipartProgress: (RemoteUploadProgress, (@Sendable (RemoteUploadProgress) async -> Void)?) = lock.withLock({ () -> (RemoteUploadProgress, (@Sendable (RemoteUploadProgress) async -> Void)?)? in
            guard let taskToken = task.taskDescription,
                  let taskContext = multipartTaskContexts[taskToken],
                  var context = multipartContexts[taskContext.jobId],
                  !context.failed else {
                return nil
            }
            context.uploadedBytesByPart[taskContext.partNumber] = totalBytesSent
            context.lastActivityAt = Date()
            multipartContexts[taskContext.jobId] = context
            let uploadedBytes = min(context.totalBytes, context.uploadedBytesByPart.values.reduce(0, +))
            let phase: RemoteUploadPhase = (context.totalBytes > 0 && uploadedBytes >= context.totalBytes) ? .finalizing : .transferring
            return (
                RemoteUploadProgress(uploadedBytes: uploadedBytes, totalBytes: context.totalBytes, phase: phase),
                context.onProgress
            )
        }) {
            if let onProgress = multipartProgress.1 {
                Task {
                    await onProgress(multipartProgress.0)
                }
            }
            return
        }

        lock.lock()
        let context = activeContexts[task.taskIdentifier]
        if context != nil {
            uploadActivity[task.taskIdentifier] = UploadActivity(
                lastProgressAt: Date(),
                totalBytesSent: totalBytesSent
            )
        }
        lock.unlock()

        guard let context else { return }
        let expected = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : context.totalBytes
        guard let onProgress = context.onProgress else { return }
        Task {
            await onProgress(
                RemoteUploadProgress(
                    uploadedBytes: totalBytesSent,
                    totalBytes: max(expected, context.totalBytes)
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let payload: (Int64, Int64, [(@Sendable (Int64, Int64) async -> Void)])? = lock.withLock {
            guard let context = activeDownloadContexts[downloadTask.taskIdentifier] else {
                return nil
            }
            let expected = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : max(totalBytesWritten, 0)
            downloadActivity[downloadTask.taskIdentifier] = DownloadActivity(
                lastProgressAt: Date(),
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: expected
            )
            stalledArtifactDownloads.removeValue(forKey: downloadTask.taskIdentifier)
            let callbacks = context.waiters.compactMap(\.onProgress)
            return (totalBytesWritten, expected, callbacks)
        }

        guard let payload, !payload.2.isEmpty else { return }
        Task {
            for onProgress in payload.2 {
                await onProgress(payload.0, payload.1)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let context: ArtifactDownloadContext? = lock.withLock {
            activeDownloadContexts[downloadTask.taskIdentifier]
        }
        let persisted = storage.loadArtifactDownloads()
        guard let persistedRecord = persisted.first(where: { $0.taskIdentifier == downloadTask.taskIdentifier }) else {
            return
        }

        let stagedFileURL = context?.stagedFileURL ?? URL(fileURLWithPath: persistedRecord.stagedFilePath)
        try? FileManager.default.createDirectory(
            at: stagedFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: stagedFileURL)

        do {
            try FileManager.default.moveItem(at: location, to: stagedFileURL)
            markArtifactDownloadCompleted(taskIdentifier: downloadTask.taskIdentifier)
        } catch {
            try? FileManager.default.removeItem(at: stagedFileURL)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let multipartTask: MultipartTaskContext? = lock.withLock {
            if let taskToken = task.taskDescription {
                return multipartTaskContexts.removeValue(forKey: taskToken)
            }
            return nil
        }
        if let multipartTask {
            let response = task.response as? HTTPURLResponse
            if let error {
                let retryDecision = lock.withLock { () -> (shouldRetry: Bool, retryCount: Int, didMutate: Bool)? in
                    guard var context = multipartContexts[multipartTask.jobId] else { return nil }
                    context.activeTaskIdentifiers.remove(multipartTask.taskToken)
                    context.lastActivityAt = Date()
                    let nextRetryCount = (context.retryCountsByPart[multipartTask.partNumber] ?? 0) + 1
                    if self.shouldRetryMultipartPart(after: error),
                       nextRetryCount <= self.multipartPartRetryLimit {
                        context.retryCountsByPart[multipartTask.partNumber] = nextRetryCount
                        context.pendingRetryPartNumbers.append(multipartTask.partNumber)
                        context.uploadedBytesByPart[multipartTask.partNumber] = 0
                        multipartContexts[multipartTask.jobId] = context
                        return (true, nextRetryCount, true)
                    }
                    multipartContexts[multipartTask.jobId] = context
                    return (false, nextRetryCount, true)
                }
                if retryDecision?.didMutate == true {
                    persistMultipartStateSnapshot()
                }
                try? FileManager.default.removeItem(at: multipartTask.tempFileURL)
                if retryDecision?.shouldRetry == true {
                    emitMultipartProgress(for: multipartTask.jobId)
                    Task {
                        await self.scheduleMultipartWork(for: multipartTask.jobId)
                    }
                    return
                }
                Task {
                    await self.failMultipartUpload(
                        jobId: multipartTask.jobId,
                        reason: "multipart_part_failed_\(multipartTask.partNumber):\(error)"
                    )
                }
                return
            }

            guard let http = response else {
                let didMutate = lock.withLock { () -> Bool in
                    guard var context = multipartContexts[multipartTask.jobId] else { return false }
                    context.activeTaskIdentifiers.remove(multipartTask.taskToken)
                    context.lastActivityAt = Date()
                    multipartContexts[multipartTask.jobId] = context
                    return true
                }
                if didMutate {
                    persistMultipartStateSnapshot()
                }
                try? FileManager.default.removeItem(at: multipartTask.tempFileURL)
                Task {
                    await self.failMultipartUpload(
                        jobId: multipartTask.jobId,
                        reason: "multipart_part_invalid_response_\(multipartTask.partNumber)"
                    )
                }
                return
            }

            guard (200...299).contains(http.statusCode) else {
                let retryDecision = lock.withLock { () -> (shouldRetry: Bool, retryCount: Int, didMutate: Bool)? in
                    guard var context = multipartContexts[multipartTask.jobId] else { return nil }
                    context.activeTaskIdentifiers.remove(multipartTask.taskToken)
                    context.lastActivityAt = Date()
                    let nextRetryCount = (context.retryCountsByPart[multipartTask.partNumber] ?? 0) + 1
                    if self.shouldRetryMultipartPart(httpStatusCode: http.statusCode),
                       nextRetryCount <= self.multipartPartRetryLimit {
                        context.retryCountsByPart[multipartTask.partNumber] = nextRetryCount
                        context.pendingRetryPartNumbers.append(multipartTask.partNumber)
                        context.uploadedBytesByPart[multipartTask.partNumber] = 0
                        multipartContexts[multipartTask.jobId] = context
                        return (true, nextRetryCount, true)
                    }
                    multipartContexts[multipartTask.jobId] = context
                    return (false, nextRetryCount, true)
                }
                if retryDecision?.didMutate == true {
                    persistMultipartStateSnapshot()
                }
                try? FileManager.default.removeItem(at: multipartTask.tempFileURL)
                if retryDecision?.shouldRetry == true {
                    emitMultipartProgress(for: multipartTask.jobId)
                    Task {
                        await self.scheduleMultipartWork(for: multipartTask.jobId)
                    }
                    return
                }
                Task {
                    await self.failMultipartUpload(
                        jobId: multipartTask.jobId,
                        reason: "multipart_part_http_\(http.statusCode)_part_\(multipartTask.partNumber)"
                    )
                }
                return
            }

            guard let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                let didMutate = lock.withLock { () -> Bool in
                    guard var context = multipartContexts[multipartTask.jobId] else { return false }
                    context.activeTaskIdentifiers.remove(multipartTask.taskToken)
                    context.lastActivityAt = Date()
                    multipartContexts[multipartTask.jobId] = context
                    return true
                }
                if didMutate {
                    persistMultipartStateSnapshot()
                }
                try? FileManager.default.removeItem(at: multipartTask.tempFileURL)
                Task {
                    await self.failMultipartUpload(
                        jobId: multipartTask.jobId,
                        reason: "multipart_part_missing_etag_\(multipartTask.partNumber)"
                    )
                }
                return
            }

            let completionState = lock.withLock { () -> (shouldReschedule: Bool, callbackURL: URL?, callbackBody: BrokerMultipartPartReadyRequest?) in
                guard var context = multipartContexts[multipartTask.jobId], !context.failed else {
                    return (false, nil, nil)
                }
                context.activeTaskIdentifiers.remove(multipartTask.taskToken)
                context.uploadedBytesByPart[multipartTask.partNumber] = multipartTask.totalBytes
                context.completedETagsByPart[multipartTask.partNumber] = etag
                context.retryCountsByPart.removeValue(forKey: multipartTask.partNumber)
                context.lastActivityAt = Date()
                let uploadedBytes = min(context.totalBytes, context.uploadedBytesByPart.values.reduce(0, +))
                let callbackBody = BrokerMultipartPartReadyRequest(
                    uploadId: context.uploadId,
                    storageKey: context.storageKey,
                    partNumber: multipartTask.partNumber,
                    etag: etag,
                    uploadedBytes: uploadedBytes,
                    completedPartCount: context.completedETagsByPart.count,
                    totalPartCount: context.parts.count
                )
                multipartContexts[multipartTask.jobId] = context
                return (true, context.partReadyURL, callbackBody)
            }
            persistMultipartStateSnapshot()
            try? FileManager.default.removeItem(at: multipartTask.tempFileURL)
            emitMultipartProgress(for: multipartTask.jobId)
            if let callbackBody = completionState.callbackBody {
                Task {
                    await self.notifyMultipartPartReady(
                        url: completionState.callbackURL,
                        requestBody: callbackBody
                    )
                }
            }
            if completionState.shouldReschedule {
                Task {
                    await self.scheduleMultipartWork(for: multipartTask.jobId)
                }
                }
                return
            }

        let downloadState: (ArtifactDownloadContext?, Int64?) = lock.withLock {
            let context = activeDownloadContexts.removeValue(forKey: task.taskIdentifier)
            downloadActivity.removeValue(forKey: task.taskIdentifier)
            let stalledBytes = stalledArtifactDownloads.removeValue(forKey: task.taskIdentifier)
            return (context, stalledBytes)
        }
        let downloadContext = downloadState.0
        let stalledDownloadBytes = downloadState.1
        let downloadWaiters = downloadContext?.waiters ?? []
        let persistedDownload = storage.loadArtifactDownloads().first(where: { $0.taskIdentifier == task.taskIdentifier })
        if let persistedDownload {
            if let error {
                removeArtifactDownloadState(taskIdentifier: task.taskIdentifier, removeStagedFile: true)
                let failure = RemoteB1ClientError.downloadFailed(
                    stalledDownloadBytes.map { "background_artifact_download_stalled_after_\($0)_bytes" }
                        ?? String(describing: error)
                )
                for waiter in downloadWaiters {
                    waiter.completion?.resume(throwing: failure)
                }
                return
            }

            let stagedFileURL = downloadContext?.stagedFileURL ?? URL(fileURLWithPath: persistedDownload.stagedFilePath)
            guard FileManager.default.fileExists(atPath: stagedFileURL.path) else {
                removeArtifactDownloadState(taskIdentifier: task.taskIdentifier, removeStagedFile: false)
                let failure = RemoteB1ClientError.downloadFailed("background_artifact_download_missing_file")
                for waiter in downloadWaiters {
                    waiter.completion?.resume(throwing: failure)
                }
                return
            }

            for waiter in downloadWaiters {
                waiter.completion?.resume(returning: stagedFileURL)
            }
            return
        }

        lock.lock()
        let context = activeContexts.removeValue(forKey: task.taskIdentifier)
        uploadActivity.removeValue(forKey: task.taskIdentifier)
        let stalledBytes = stalledUploads.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        removeTaskState(taskIdentifier: task.taskIdentifier)

        guard let context else { return }

        if let error {
            if let stalledBytes {
                context.completion?.resume(
                    throwing: RemoteB1ClientError.uploadFailed("upload_stalled_after_\(stalledBytes)_bytes")
                )
                return
            }
            context.completion?.resume(throwing: RemoteB1ClientError.uploadFailed(String(describing: error)))
            return
        }

        guard let http = task.response as? HTTPURLResponse else {
            context.completion?.resume(throwing: RemoteB1ClientError.invalidResponse)
            return
        }
        guard (200...299).contains(http.statusCode) else {
            context.completion?.resume(
                throwing: RemoteB1ClientError.networkError("broker_http_status_\(http.statusCode)")
            )
            return
        }

        context.completion?.resume(returning: context.jobId)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

public final class BackgroundUploadBrokerClient: @unchecked Sendable {
    public static let shared = BackgroundUploadBrokerClient()

    private let config: BackgroundUploadBrokerConfiguration?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var engine: BackgroundUploadBrokerEngine {
        BackgroundUploadBrokerEngine.shared
    }

    public init(configuration: BackgroundUploadBrokerConfiguration? = BackgroundUploadBrokerConfiguration.current()) {
        self.config = configuration
        decoder.keyDecodingStrategy = .useDefaultKeys
    }

    public var isConfigured: Bool {
        config != nil
    }

    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        engine.handleEvents(for: identifier, completionHandler: completionHandler)
    }

    func prepareUploadSource(
        videoURL: URL,
        onProgress: (@Sendable (PreparedUploadProgress) async -> Void)? = nil
    ) async throws -> URL {
        #if canImport(AVFoundation)
        return try await StreamFriendlyUploadPreparer.shared.prepareSource(from: videoURL, onProgress: onProgress)
        #else
        return videoURL
        #endif
    }

    func waitForPreparedUploadSourceFinalization(
        _ sourceURL: URL,
        timeout: TimeInterval = 60 * 60
    ) async throws -> Date? {
        #if canImport(AVFoundation)
        guard ManagedPreparedUploadSourceStore.isManaged(sourceURL) else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let metadata = ManagedPreparedUploadSourceStore.loadMetadata(for: sourceURL) {
                if metadata.finalized {
                    if let exportFailedReason = metadata.exportFailedReason {
                        throw RemoteB1ClientError.uploadFailed("stream_friendly_export_failed:\(exportFailedReason)")
                    }
                    return metadata.updatedAt
                }
            } else if !FileManager.default.fileExists(atPath: sourceURL.path) {
                return nil
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw RemoteB1ClientError.uploadFailed("prepared_upload_source_finalization_timeout")
        #else
        return nil
        #endif
    }

    func cleanupPreparedUploadSourceIfNeeded(_ sourceURL: URL) {
        ManagedPreparedUploadSourceStore.cleanupIfManaged(sourceURL)
    }

    func createJob(
        videoURL: URL,
        clientRecordId: UUID? = nil,
        captureOrigin: String,
        pipelineProfile: [String: String]? = nil
    ) async throws -> BrokerCreateJobResponse {
        guard let config else {
            throw RemoteB1ClientError.notConfigured
        }

        let fileSize: Int64
        if let metadata = ManagedPreparedUploadSourceStore.loadMetadata(for: videoURL) {
            fileSize = metadata.finalized ? max(metadata.currentPreparedBytes, 0) : max(metadata.estimatedUploadBytes, 0)
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: videoURL.path)
            fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard fileSize > 0 else {
            throw RemoteB1ClientError.uploadFailed("empty_file")
        }

        let requestBody = BrokerCreateJobRequest(
            fileName: videoURL.lastPathComponent,
            fileSizeBytes: fileSize,
            contentType: contentType(for: videoURL),
            captureOrigin: captureOrigin,
            clientRecordId: clientRecordId?.uuidString,
            pipelineProfile: pipelineProfile
        )

        var request = URLRequest(url: config.baseURL.appendingPathComponent("/v1/mobile-jobs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(requestBody)

        return try await createJobResponse(
            for: request,
            fallbackBaseURL: config.fallbackBaseURL
        )
    }

    func startUpload(
        jobId: String,
        upload: BrokerUploadRequest,
        sourceURL: URL,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        let fileSize: Int64
        if let metadata = ManagedPreparedUploadSourceStore.loadMetadata(for: sourceURL) {
            fileSize = metadata.finalized ? max(metadata.currentPreparedBytes, 0) : max(metadata.estimatedUploadBytes, 0)
        } else {
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard fileSize > 0 else {
            throw RemoteB1ClientError.uploadFailed("empty_file")
        }

        return try await engine.beginUpload(
            jobId: jobId,
            upload: upload,
            sourceURL: sourceURL,
            totalBytes: fileSize,
            onProgress: onProgress
        )
    }

    func createJobAndUpload(
        videoURL: URL,
        clientRecordId: UUID? = nil,
        captureOrigin: String,
        pipelineProfile: [String: String]? = nil,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        let preparedSourceURL = try await prepareUploadSource(videoURL: videoURL)
        do {
            let creation = try await createJob(
                videoURL: preparedSourceURL,
                clientRecordId: clientRecordId,
                captureOrigin: captureOrigin,
                pipelineProfile: pipelineProfile
            )
            do {
                return try await startUpload(
                    jobId: creation.jobId,
                    upload: creation.upload,
                    sourceURL: preparedSourceURL,
                    onProgress: onProgress
                )
            } catch {
                cleanupPreparedUploadSourceIfNeeded(preparedSourceURL)
                throw error
            }
        } catch {
            cleanupPreparedUploadSourceIfNeeded(preparedSourceURL)
            throw error
        }
    }

    func pollStatus(jobId: String) async throws -> JobStatus {
        let status = try await fetchJobStatus(jobId: jobId)
        let progress = RemoteJobProgress(
            progressFraction: normalized(status.progressFraction),
            stageKey: status.stage ?? stageKey(for: status.state),
            phaseName: status.phaseName,
            currentTier: status.currentTier,
            title: status.title,
            detail: status.detail ?? status.title,
            etaMinutes: etaMinutes(from: status.estimatedRemainingSeconds),
            elapsedSeconds: status.elapsedSeconds,
            progressBasis: status.progressBasis,
            runtimeMetrics: status.metrics?.values ?? [:]
        )

        switch status.state {
        case "uploading", "queued":
            return .pending(progress)
        case "reconstructing", "training", "packaging", "downloading":
            return .processing(progress)
        case "exporting":
            if status.artifact?.downloadURL.isEmpty == false {
                return .downloadReady(progress)
            }
            return .processing(progress)
        case "completed":
            return .completed(progress)
        case "failed", "cancelled":
            return .failed(reason: status.failureReason ?? status.detail ?? status.state, progress: progress)
        default:
            return .processing(progress)
        }
    }

    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        try await download(jobId: jobId, onProgress: nil)
    }

    func download(
        jobId: String,
        onProgress: (@Sendable (Int64, Int64) async -> Void)?
    ) async throws -> (data: Data, format: ArtifactFormat) {
        let status = try await fetchJobStatus(jobId: jobId)
        guard let artifact = status.artifact,
              let downloadURL = URL(string: artifact.downloadURL) else {
            throw RemoteB1ClientError.downloadFailed("missing_artifact_download_url")
        }

        let fallbackURL = config?.fallbackBaseURL?.appendingPathComponent("/v1/mobile-jobs/\(jobId)/artifact-download")
        let format = artifactFormat(for: artifact.format)
        let activePersistedURL = engine.persistedArtifactDownloadRequestURL(jobId: jobId)

        var orderedBaseURLs: [URL] = [downloadURL]
        if let fallbackURL,
           fallbackURL.absoluteString != downloadURL.absoluteString {
            if activePersistedURL?.absoluteString == downloadURL.absoluteString {
                orderedBaseURLs = [fallbackURL, downloadURL]
            } else if activePersistedURL?.absoluteString == fallbackURL.absoluteString {
                orderedBaseURLs = [downloadURL, fallbackURL]
            } else {
                orderedBaseURLs.append(fallbackURL)
            }
        }

        let maxAttempts = orderedBaseURLs.count > 1 ? 4 : 3
        var candidateURLs: [URL] = []
        candidateURLs.reserveCapacity(maxAttempts)
        while candidateURLs.count < maxAttempts {
            for url in orderedBaseURLs where candidateURLs.count < maxAttempts {
                candidateURLs.append(url)
            }
        }

        var lastError: Error?
        for (attemptIndex, requestURL) in candidateURLs.enumerated() {
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.networkServiceType = .responsiveData
            request.allowsExpensiveNetworkAccess = true
            request.allowsConstrainedNetworkAccess = true
            request.timeoutInterval = 60 * 60 * 6
            if requestURL == fallbackURL, let apiKey = config?.apiKey {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            do {
                let localURL = try await engine.beginArtifactDownload(
                    jobId: jobId,
                    request: request,
                    format: format,
                    onProgress: onProgress
                )
                let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
                return (data, format)
            } catch {
                lastError = error
                if attemptIndex + 1 < candidateURLs.count {
                    let backoffNanoseconds = UInt64(min(4, attemptIndex + 1)) * 500_000_000
                    try? await Task.sleep(nanoseconds: backoffNanoseconds)
                }
            }
        }

        throw lastError ?? RemoteB1ClientError.downloadFailed("artifact_download_failed")
    }

    func cancel(jobId: String) async throws {
        await engine.cancelUploadIfPresent(jobId: jobId)
        guard let config else { return }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("/v1/mobile-jobs/\(jobId)"))
        request.httpMethod = "DELETE"
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await data(for: request, fallbackBaseURL: config.fallbackBaseURL)
        try validate(response: response)
        try await waitForRemoteCancellation(jobId: jobId)
    }

    public func sendClientEvent(
        jobId: String,
        eventType: String,
        eventAt: Date? = nil,
        payload: [String: String] = [:]
    ) async {
        guard let config else { return }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("/v1/mobile-jobs/\(jobId)/client-event"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var finalPayload = payload
        if let eventAt {
            finalPayload["event_at"] = ISO8601DateFormatter().string(from: eventAt)
        }
        let body: [String: Any] = [
            "event_type": eventType,
            "payload": finalPayload
        ]
        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = requestBody
        do {
            let (_, response) = try await self.data(for: request, fallbackBaseURL: config.fallbackBaseURL)
            try validate(response: response)
        } catch {
            return
        }
    }

    private func waitForRemoteCancellation(jobId: String) async throws {
        let deadline = Date().addingTimeInterval(12)

        while Date() < deadline {
            let status = try await fetchJobStatus(jobId: jobId)

            if status.state == "cancelled" {
                if status.cancelAcknowledged == true || status.assignedWorkerId == nil {
                    return
                }
            } else if status.state == "completed" || status.state == "failed" {
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        throw RemoteB1ClientError.networkError("cancel_ack_timeout")
    }

    private func fetchJobStatus(jobId: String) async throws -> BrokerJobStatusResponse {
        guard let config else {
            throw RemoteB1ClientError.notConfigured
        }
        let maxAttempts = 6
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                var request = URLRequest(url: config.baseURL.appendingPathComponent("/v1/mobile-jobs/\(jobId)"))
                request.httpMethod = "GET"
                if let apiKey = config.apiKey {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await data(for: request, fallbackBaseURL: config.fallbackBaseURL)
                try validate(response: response)
                return try decoder.decode(BrokerJobStatusResponse.self, from: data)
            } catch {
                lastError = error
                guard attempt < maxAttempts,
                      shouldRetryFetchJobStatus(error) else {
                    throw error
                }
                let backoffSeconds = min(3.0, 0.4 * Double(attempt))
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            }
        }

        throw lastError ?? RemoteB1ClientError.invalidResponse
    }

    private func createJobResponse(
        for request: URLRequest,
        fallbackBaseURL: URL?
    ) async throws -> BrokerCreateJobResponse {
        let maxAttempts = 3
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await data(for: request, fallbackBaseURL: fallbackBaseURL)
                try validate(response: response)
                return try decoder.decode(BrokerCreateJobResponse.self, from: data)
            } catch {
                lastError = error
                guard attempt < maxAttempts,
                      shouldRetryCreateJob(error) else {
                    throw error
                }
                let backoffSeconds = 0.6 * Double(attempt)
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            }
        }

        throw lastError ?? RemoteB1ClientError.invalidResponse
    }

    private func data(
        for request: URLRequest,
        fallbackBaseURL: URL?
    ) async throws -> (Data, URLResponse) {
        try await data(for: request, fallbackURL: fallbackURL(for: request.url, fallbackBaseURL: fallbackBaseURL))
    }

    private func data(
        for request: URLRequest,
        fallbackURL: URL?
    ) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            guard shouldRetryWithFallback(error),
                  let fallbackURL,
                  request.url != fallbackURL else {
                throw error
            }
            var fallbackRequest = request
            fallbackRequest.url = fallbackURL
            return try await URLSession.shared.data(for: fallbackRequest)
        }
    }

    private func fallbackURL(for originalURL: URL?, fallbackBaseURL: URL?) -> URL? {
        guard let originalURL, let fallbackBaseURL else { return nil }
        guard let components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let relativePath = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        var fallbackComponents = URLComponents(
            url: fallbackBaseURL.appendingPathComponent(relativePath),
            resolvingAgainstBaseURL: false
        )
        fallbackComponents?.percentEncodedQuery = components.percentEncodedQuery
        return fallbackComponents?.url
    }

    private func shouldRetryWithFallback(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorTimedOut:
            return true
        default:
            return false
        }
    }

    private func shouldRetryMultipartPart(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorResourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func shouldRetryMultipartPart(httpStatusCode: Int) -> Bool {
        switch httpStatusCode {
        case 408, 409, 423, 425, 429:
            return true
        case 500...599:
            return true
        default:
            return false
        }
    }

    private func shouldRetryCreateJob(_ error: Error) -> Bool {
        if shouldRetryWithFallback(error) {
            return true
        }

        if let brokerError = error as? RemoteB1ClientError {
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

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    private func shouldRetryFetchJobStatus(_ error: Error) -> Bool {
        if shouldRetryWithFallback(error) {
            return true
        }

        if let brokerError = error as? RemoteB1ClientError {
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

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteB1ClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 408 {
                throw RemoteB1ClientError.networkTimeout
            }
            throw RemoteB1ClientError.networkError("broker_http_status_\(http.statusCode)")
        }
    }

    private func contentType(for videoURL: URL) -> String {
        switch videoURL.pathExtension.lowercased() {
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        default:
            return "application/octet-stream"
        }
    }

    private func artifactFormat(for value: String) -> ArtifactFormat {
        switch value.lowercased() {
        case "spz":
            return .spz
        case "splat":
            return .splat
        default:
            return .splatPly
        }
    }

    private func normalized(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(0.0, min(1.0, value))
    }

    private func etaMinutes(from seconds: Int?) -> Int? {
        guard let seconds, seconds > 0 else { return nil }
        return max(1, Int(ceil(Double(seconds) / 60.0)))
    }

    private func stageKey(for state: String) -> String {
        switch state {
        case "uploading":
            return "uploading"
        case "queued":
            return "queued"
        case "reconstructing":
            return "sfm"
        case "training":
            return "train"
        case "packaging":
            return "export"
        case "downloading":
            return "downloading"
        case "completed":
            return "complete"
        case "cancelled":
            return "cancelled"
        default:
            return state
        }
    }
}

#else

struct BrokerMultipartPartRequest: Sendable {
    let partNumber: Int
    let method: String
    let url: String
    let headers: [String: String]
}

struct BrokerUploadRequest: Sendable {
    let kind: String?
    let method: String?
    let url: String?
    let headers: [String: String]
    let storageKey: String
    let uploadId: String?
    let partSizeBytes: Int?
    let maxConcurrency: Int?
    let partReadyURL: String?
    let parts: [BrokerMultipartPartRequest]?
    let completeURL: String?
    let abortURL: String?
}

struct BrokerCreateJobResponse: Sendable {
    let jobId: String
    let upload: BrokerUploadRequest
    let pollPath: String?
    let cancelPath: String?
}

public struct BackgroundUploadBrokerConfiguration: Sendable {
    public init(
        baseURL: URL,
        fallbackBaseURL: URL?,
        apiKey: String?,
        backgroundSessionIdentifier: String,
        backgroundMaximumConnectionsPerHost: Int,
        foregroundMultipartMaximumConnectionsPerHost: Int
    ) {}
    public static func current(bundle: Bundle = .main) -> BackgroundUploadBrokerConfiguration? { nil }
}

public final class BackgroundUploadBrokerClient: @unchecked Sendable {
    public static let shared = BackgroundUploadBrokerClient()
    public init(configuration: BackgroundUploadBrokerConfiguration? = nil) {}
    public var isConfigured: Bool { false }
    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    func prepareUploadSource(
        videoURL: URL,
        onProgress: (@Sendable (PreparedUploadProgress) async -> Void)? = nil
    ) async throws -> URL { videoURL }
    func waitForPreparedUploadSourceFinalization(
        _ sourceURL: URL,
        timeout: TimeInterval = 60 * 60
    ) async throws -> Date? { nil }
    func cleanupPreparedUploadSourceIfNeeded(_ sourceURL: URL) {}
    func createJob(
        videoURL: URL,
        clientRecordId: UUID? = nil,
        captureOrigin: String,
        pipelineProfile: [String: String]? = nil
    ) async throws -> BrokerCreateJobResponse {
        throw RemoteB1ClientError.notConfigured
    }
    func startUpload(
        jobId: String,
        upload: BrokerUploadRequest,
        sourceURL: URL,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        throw RemoteB1ClientError.notConfigured
    }
    func createJobAndUpload(
        videoURL: URL,
        clientRecordId: UUID? = nil,
        captureOrigin: String,
        pipelineProfile: [String: String]? = nil,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        throw RemoteB1ClientError.notConfigured
    }
    func pollStatus(jobId: String) async throws -> JobStatus { throw RemoteB1ClientError.notConfigured }
    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) { throw RemoteB1ClientError.notConfigured }
    func cancel(jobId: String) async throws { throw RemoteB1ClientError.notConfigured }
    public func sendClientEvent(
        jobId: String,
        eventType: String,
        eventAt: Date? = nil,
        payload: [String: String] = [:]
    ) async {}
}

#endif
