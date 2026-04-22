//
// ScanRecord.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Record Data Model
// Cross-platform data model (Foundation-only, no platform imports)
//

import Foundation
import Aether3DCore

#if canImport(SwiftUI)
import SwiftUI  // For Identifiable in older iOS
#endif

public enum ScanRecordStatus: String, Codable, Sendable, CaseIterable {
    case preparing
    case uploading
    case queued
    case reconstructing
    case training
    case packaging
    case downloading
    case localFallback
    case completed
    case cancelled
    case failed
}

public enum WorkflowMilestoneState: Sendable, Equatable {
    case pending
    case active
    case completed
}

public struct WorkflowMilestone: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: WorkflowMilestoneState

    public init(id: String, title: String, state: WorkflowMilestoneState) {
        self.id = id
        self.title = title
        self.state = state
    }
}

public struct WorkflowActivityMetric: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String

    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public struct WorkflowStepProgress: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let state: WorkflowMilestoneState
    public let progressFraction: Double
    public let progressText: String
    public let detailText: String?

    public init(
        id: String,
        title: String,
        state: WorkflowMilestoneState,
        progressFraction: Double,
        progressText: String,
        detailText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.progressFraction = progressFraction
        self.progressText = progressText
        self.detailText = detailText
    }
}

public struct ViewerInitialPose: Codable, Sendable, Equatable {
    public var artifactCacheKey: String
    public var orientationW: Float
    public var orientationX: Float
    public var orientationY: Float
    public var orientationZ: Float
    public var sceneUpX: Float
    public var sceneUpY: Float
    public var sceneUpZ: Float
    public var source: String
    public var confidence: Float?
    public var estimatedAt: Date

    public init(
        artifactCacheKey: String,
        orientationW: Float,
        orientationX: Float,
        orientationY: Float,
        orientationZ: Float,
        sceneUpX: Float,
        sceneUpY: Float,
        sceneUpZ: Float,
        source: String,
        confidence: Float? = nil,
        estimatedAt: Date = Date()
    ) {
        self.artifactCacheKey = artifactCacheKey
        self.orientationW = orientationW
        self.orientationX = orientationX
        self.orientationY = orientationY
        self.orientationZ = orientationZ
        self.sceneUpX = sceneUpX
        self.sceneUpY = sceneUpY
        self.sceneUpZ = sceneUpZ
        self.source = source
        self.confidence = confidence
        self.estimatedAt = estimatedAt
    }
}

public enum ScanCaptureIntent: String, Codable, Sendable, CaseIterable {
    case object
    case space

    public static let userDefaultsKey = "aether.scanCaptureIntent"

    public static func currentSelection(userDefaults: UserDefaults = .standard) -> ScanCaptureIntent {
        let rawValue = userDefaults.string(forKey: userDefaultsKey)
        return ScanCaptureIntent(rawValue: rawValue ?? "") ?? .object
    }

    public var title: String {
        switch self {
        case .object:
            return "物体"
        case .space:
            return "空间"
        }
    }

    public var detail: String {
        switch self {
        case .object:
            return "轨道"
        case .space:
            return "漫游"
        }
    }
}

/// Scan record for gallery display and JSON persistence
///
/// Each completed scan produces one ScanRecord containing metadata:
/// coverage quality, duration, processing state and paths to artifacts.
/// Records are persisted as JSON in Documents/Aether3D/scans.json.
public struct ScanRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var thumbnailPath: String?       // Relative path: "thumbnails/{id}.jpg"
    public var artifactPath: String?        // Relative path: "exports/{id}.ply"
    public var sourceVideoPath: String?     // Relative path for retry / revisit
    public var remoteJobId: String?         // Remote Danish 5090 job id for resume
    public var frameSamplingProfile: String?
    public var captureIntent: String?
    public var processingBackend: String?
    public var coveragePercentage: Double   // Final coverage [0, 1]
    public var triangleCount: Int           // Reserved for future mesh metadata
    public var durationSeconds: TimeInterval   // Source video duration
    public var processingStartedAt: Date?
    public var processingCompletedAt: Date?
    public var processingElapsedSeconds: TimeInterval?
    public var status: ScanRecordStatus
    public var statusMessage: String?
    public var detailMessage: String?
    public var progressFraction: Double?
    public var progressBasis: String?
    public var remoteStageKey: String?
    public var remotePhaseName: String?
    public var currentTier: String?
    public var runtimeMetrics: [String: String]?
    public var uploadedBytes: Int64?
    public var totalBytes: Int64?
    public var uploadBytesPerSecond: Double?
    public var estimatedRemainingMinutes: Int?
    public var failureReason: String?
    public var viewerInitialPose: ViewerInitialPose?
    public var captureGravityUpX: Float?
    public var captureGravityUpY: Float?
    public var captureGravityUpZ: Float?
    public var captureGravitySource: String?
    public var captureGravityConfidence: Float?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case updatedAt
        case thumbnailPath
        case artifactPath
        case sourceVideoPath
        case remoteJobId
        case frameSamplingProfile
        case captureIntent
        case processingBackend
        case coveragePercentage
        case triangleCount
        case durationSeconds
        case processingStartedAt
        case processingCompletedAt
        case processingElapsedSeconds
        case status
        case statusMessage
        case detailMessage
        case progressFraction
        case progressBasis
        case remoteStageKey
        case remotePhaseName
        case currentTier
        case runtimeMetrics
        case uploadedBytes
        case totalBytes
        case uploadBytesPerSecond
        case estimatedRemainingMinutes
        case failureReason
        case viewerInitialPose
        case captureGravityUpX
        case captureGravityUpY
        case captureGravityUpZ
        case captureGravitySource
        case captureGravityConfidence
    }

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        thumbnailPath: String? = nil,
        artifactPath: String? = nil,
        sourceVideoPath: String? = nil,
        remoteJobId: String? = nil,
        frameSamplingProfile: String? = nil,
        captureIntent: String? = nil,
        processingBackend: String? = nil,
        coveragePercentage: Double = 0.0,
        triangleCount: Int = 0,
        durationSeconds: TimeInterval = 0.0,
        processingStartedAt: Date? = nil,
        processingCompletedAt: Date? = nil,
        processingElapsedSeconds: TimeInterval? = nil,
        status: ScanRecordStatus? = nil,
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
        failureReason: String? = nil,
        viewerInitialPose: ViewerInitialPose? = nil,
        captureGravityUpX: Float? = nil,
        captureGravityUpY: Float? = nil,
        captureGravityUpZ: Float? = nil,
        captureGravitySource: String? = nil,
        captureGravityConfidence: Float? = nil
    ) {
        let resolvedStatus = status ?? (artifactPath != nil ? .completed : .preparing)
        self.id = id
        self.name = name ?? Self.defaultName(for: createdAt)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.thumbnailPath = thumbnailPath
        self.artifactPath = artifactPath
        self.sourceVideoPath = sourceVideoPath
        self.remoteJobId = remoteJobId
        self.frameSamplingProfile = Self.normalizedFrameSamplingProfile(frameSamplingProfile)
        self.captureIntent = Self.normalizedCaptureIntent(captureIntent)
        self.processingBackend = Self.normalizedProcessingBackend(processingBackend)
        self.coveragePercentage = max(0.0, min(1.0, coveragePercentage))
        self.triangleCount = max(0, triangleCount)
        self.durationSeconds = max(0, durationSeconds)
        let resolvedProcessingStartedAt = processingStartedAt ?? createdAt
        self.processingStartedAt = resolvedProcessingStartedAt
        self.processingCompletedAt = processingCompletedAt
        if let processingElapsedSeconds {
            self.processingElapsedSeconds = max(0, processingElapsedSeconds)
        } else if let processingCompletedAt {
            self.processingElapsedSeconds = max(0, processingCompletedAt.timeIntervalSince(resolvedProcessingStartedAt))
        } else {
            self.processingElapsedSeconds = nil
        }
        self.status = resolvedStatus
        self.statusMessage = statusMessage ?? Self.defaultStatusMessage(for: resolvedStatus)
        self.detailMessage = detailMessage
        self.progressFraction = Self.normalized(progressFraction, for: resolvedStatus)
        self.progressBasis = progressBasis
        self.remoteStageKey = remoteStageKey
        self.remotePhaseName = remotePhaseName
        self.currentTier = currentTier
        self.runtimeMetrics = runtimeMetrics
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.estimatedRemainingMinutes = estimatedRemainingMinutes
        self.failureReason = failureReason
        self.viewerInitialPose = viewerInitialPose
        self.captureGravityUpX = captureGravityUpX
        self.captureGravityUpY = captureGravityUpY
        self.captureGravityUpZ = captureGravityUpZ
        self.captureGravitySource = captureGravitySource
        self.captureGravityConfidence = captureGravityConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let artifactPath = Self.decodeLossyString(from: container, forKey: .artifactPath)
        let decodedStatus = Self.decodeLossyStatus(from: container, forKey: .status)
            ?? (artifactPath != nil ? .completed : .preparing)

        self.id = id
        self.name = Self.decodeLossyString(from: container, forKey: .name)
            ?? Self.defaultName(for: createdAt)
        self.createdAt = createdAt
        self.updatedAt = Self.decodeLossyDate(from: container, forKey: .updatedAt) ?? createdAt
        self.thumbnailPath = Self.decodeLossyString(from: container, forKey: .thumbnailPath)
        self.artifactPath = artifactPath
        self.sourceVideoPath = Self.decodeLossyString(from: container, forKey: .sourceVideoPath)
        self.remoteJobId = Self.decodeLossyString(from: container, forKey: .remoteJobId)
        self.frameSamplingProfile = Self.normalizedFrameSamplingProfile(
            Self.decodeLossyString(from: container, forKey: .frameSamplingProfile)
        )
        self.captureIntent = Self.normalizedCaptureIntent(
            Self.decodeLossyString(from: container, forKey: .captureIntent)
        )
        self.processingBackend = Self.normalizedProcessingBackend(
            Self.decodeLossyString(from: container, forKey: .processingBackend)
        )
        self.coveragePercentage = max(0.0, min(1.0, Self.decodeLossyDouble(from: container, forKey: .coveragePercentage) ?? 0.0))
        self.triangleCount = max(0, Self.decodeLossyInt(from: container, forKey: .triangleCount) ?? 0)
        self.durationSeconds = max(0.0, Self.decodeLossyDouble(from: container, forKey: .durationSeconds) ?? 0.0)
        let decodedProcessingStartedAt = Self.decodeLossyDate(from: container, forKey: .processingStartedAt)
        self.processingStartedAt = decodedProcessingStartedAt ?? createdAt
        self.processingCompletedAt = Self.decodeLossyDate(from: container, forKey: .processingCompletedAt)
        if let decodedProcessingElapsedSeconds = Self.decodeLossyDouble(from: container, forKey: .processingElapsedSeconds) {
            self.processingElapsedSeconds = max(0.0, decodedProcessingElapsedSeconds)
        } else if let processingCompletedAt {
            self.processingElapsedSeconds = max(0.0, processingCompletedAt.timeIntervalSince(self.processingStartedAt ?? createdAt))
        } else {
            self.processingElapsedSeconds = nil
        }
        self.status = decodedStatus
        self.statusMessage = Self.decodeLossyString(from: container, forKey: .statusMessage)
            ?? Self.defaultStatusMessage(for: decodedStatus)
        self.detailMessage = Self.decodeLossyString(from: container, forKey: .detailMessage)
        self.progressFraction = Self.normalized(Self.decodeLossyDouble(from: container, forKey: .progressFraction), for: decodedStatus)
        self.progressBasis = Self.decodeLossyString(from: container, forKey: .progressBasis)
        self.remoteStageKey = Self.decodeLossyString(from: container, forKey: .remoteStageKey)
        self.remotePhaseName = Self.decodeLossyString(from: container, forKey: .remotePhaseName)
        self.currentTier = Self.decodeLossyString(from: container, forKey: .currentTier)
        self.runtimeMetrics = Self.decodeLossyStringDictionary(from: container, forKey: .runtimeMetrics)
        self.uploadedBytes = Self.decodeLossyInt64(from: container, forKey: .uploadedBytes)
        self.totalBytes = Self.decodeLossyInt64(from: container, forKey: .totalBytes)
        self.uploadBytesPerSecond = Self.decodeLossyDouble(from: container, forKey: .uploadBytesPerSecond)
        self.estimatedRemainingMinutes = Self.decodeLossyInt(from: container, forKey: .estimatedRemainingMinutes)
        self.failureReason = Self.decodeLossyString(from: container, forKey: .failureReason)
        self.viewerInitialPose = try? container.decodeIfPresent(ViewerInitialPose.self, forKey: .viewerInitialPose)
        self.captureGravityUpX = Self.decodeLossyFloat(from: container, forKey: .captureGravityUpX)
        self.captureGravityUpY = Self.decodeLossyFloat(from: container, forKey: .captureGravityUpY)
        self.captureGravityUpZ = Self.decodeLossyFloat(from: container, forKey: .captureGravityUpZ)
        self.captureGravitySource = Self.decodeLossyString(from: container, forKey: .captureGravitySource)
        self.captureGravityConfidence = Self.decodeLossyFloat(from: container, forKey: .captureGravityConfidence)
    }

    private static func decodeLossyString(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key) {
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(intValue)
        }
        if let int64Value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return String(int64Value)
        }
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(doubleValue)
        }
        if let boolValue = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return boolValue ? "true" : "false"
        }
        return nil
    }

    private static func decodeLossyDouble(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
        if let doubleValue = try? container.decodeIfPresent(Double.self, forKey: key) {
            return doubleValue
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        if let int64Value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return Double(int64Value)
        }
        if let stringValue = decodeLossyString(from: container, forKey: key) {
            return Double(stringValue)
        }
        return nil
    }

    private static func decodeLossyFloat(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Float? {
        if let floatValue = try? container.decodeIfPresent(Float.self, forKey: key) {
            return floatValue
        }
        if let doubleValue = decodeLossyDouble(from: container, forKey: key) {
            return Float(doubleValue)
        }
        return nil
    }

    private static func decodeLossyInt(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return intValue
        }
        if let int64Value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return Int(exactly: int64Value)
        }
        if let doubleValue = decodeLossyDouble(from: container, forKey: key) {
            return Int(doubleValue.rounded())
        }
        return nil
    }

    private static func decodeLossyInt64(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int64? {
        if let int64Value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return int64Value
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Int64(intValue)
        }
        if let doubleValue = decodeLossyDouble(from: container, forKey: key) {
            return Int64(doubleValue.rounded())
        }
        return nil
    }

    private static func decodeLossyDate(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Date? {
        if let dateValue = try? container.decodeIfPresent(Date.self, forKey: key) {
            return dateValue
        }
        guard let stringValue = decodeLossyString(from: container, forKey: key), !stringValue.isEmpty else {
            return nil
        }
        return ISO8601DateFormatter().date(from: stringValue)
    }

    private static func decodeLossyStatus(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> ScanRecordStatus? {
        if let statusValue = try? container.decodeIfPresent(ScanRecordStatus.self, forKey: key) {
            return statusValue
        }
        guard let rawValue = decodeLossyString(from: container, forKey: key) else {
            return nil
        }
        return ScanRecordStatus(rawValue: rawValue)
    }

    private static func decodeLossyStringDictionary(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> [String: String]? {
        if let dictionaryValue = try? container.decodeIfPresent([String: String].self, forKey: key) {
            return dictionaryValue
        }
        if let anyDictionary = try? container.decodeIfPresent([String: [String: String]].self, forKey: key) {
            return anyDictionary.reduce(into: [:]) { partialResult, element in
                partialResult[element.key] = element.value.description
            }
        }
        return nil
    }

    private static func normalizedFrameSamplingProfile(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "full", "half", "third":
            return normalized
        default:
            return nil
        }
    }

    private static func normalizedCaptureIntent(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case ScanCaptureIntent.object.rawValue, ScanCaptureIntent.space.rawValue:
            return normalized
        default:
            return nil
        }
    }

    private static func normalizedProcessingBackend(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let backend = ProcessingBackendChoice(rawValue: normalized) else { return nil }
        return backend.normalizedForActiveUse.rawValue
    }

    public var resolvedCaptureIntent: ScanCaptureIntent? {
        guard let captureIntent else { return nil }
        return ScanCaptureIntent(rawValue: captureIntent)
    }

    public var resolvedProcessingBackend: ProcessingBackendChoice {
        ProcessingBackendChoice.resolvedStoredSelection(rawValue: processingBackend)
    }

    public var isProcessing: Bool {
        switch status {
        case .completed, .cancelled, .failed:
            return false
        default:
            return true
        }
    }

    public var canOpenStatusView: Bool {
        artifactPath != nil || isProcessing || status == .failed || status == .cancelled
    }

    public var isObjectFastPublishV1: Bool {
        let strategy = runtimeMetricString("pipeline_strategy")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let contract = runtimeMetricString("artifact_contract_version")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if strategy == "object_fast_publish_v1" || strategy == "object_splatslam_v1" || strategy == "object_slam3r_surface_v1" || contract == "object_publish_v1" {
            return true
        }

        if let artifactPath {
            let lowercased = artifactPath.lowercased()
            return lowercased.hasSuffix(".glb") || lowercased.hasSuffix(".ply") || lowercased.hasSuffix(".splat") || lowercased.hasSuffix(".spz")
        }

        return false
    }

    public var isInspectionOnlyCandidate: Bool {
        if runtimeMetricString("inspection_only_candidate") == "true" {
            return true
        }
        if runtimeMetricString("hq_passed") == "false", artifactPath != nil {
            return true
        }
        guard let normalizedFailureReason else { return false }
        return normalizedFailureReason.hasPrefix(Self.hqGateFailureReasonPrefix)
    }

    public var inspectionFailedCards: [String] {
        if let cards = runtimeMetricString("hq_failed_cards"), !cards.isEmpty {
            return cards
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard let normalizedFailureReason,
              normalizedFailureReason.hasPrefix(Self.hqGateFailureReasonPrefix),
              let separator = normalizedFailureReason.firstIndex(of: ":") else {
            return []
        }
        return normalizedFailureReason[normalizedFailureReason.index(after: separator)...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var inspectionFailedCardsSummaryText: String? {
        let labels = inspectionFailedCards.map(Self.hqFailedCardLabel)
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: "、")
    }

    public var displayProgressFraction: Double {
        switch status {
        case .completed:
            return 1.0
        case .failed:
            return max(0.0, min(0.99, progressFraction ?? 0.0))
        default:
            return max(0.0, min(0.99, progressFraction ?? 0.0))
        }
    }

    public var displayWorkflowStatus: ScanRecordStatus {
        effectiveWorkflowStatus
    }

    public var displayStatusMessage: String {
        if isInspectionOnlyCandidate {
            return "未达 HQ，仅供质检"
        }
        if let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return Self.defaultStatusMessage(for: effectiveWorkflowStatus)
    }

    public var isUploadFinalizing: Bool {
        effectiveWorkflowStatus == .uploading && normalizedProgressBasis == "upload_finalizing"
    }

    public var uploadProgressText: String? {
        guard isUploadTrackActive else {
            return nil
        }
        if isUploadFinalizing {
            return "所有分片已发送，正在确认上传"
        }
        guard
              let uploadedBytes,
              let totalBytes,
              totalBytes > 0 else {
            return nil
        }
        return "已上传 \(Self.byteString(uploadedBytes)) / \(Self.byteString(totalBytes))"
    }

    private var localPreparationProgressPercent: Int? {
        if let percent = runtimeMetricInt("prepare_progress_percent") {
            return max(0, min(100, percent))
        }
        guard effectiveWorkflowStatus == .preparing,
              let localFraction = segmentProgress(from: progressFraction, start: 0.0, end: 0.04) else {
            return nil
        }
        return max(0, min(100, Int((localFraction * 100.0).rounded())))
    }

    private var localPreparationStepTitle: String {
        guard effectiveWorkflowStatus == .preparing else {
            return "正在整理上传素材"
        }
        switch normalizedProgressBasis {
        case "prepare_inspecting_source":
            return "正在检查原视频"
        case "prepare_remuxing_container":
            return "正在重封装上传视频"
        case "prepare_verifying_output":
            return "正在校验整理结果"
        case "prepare_ready_for_upload":
            return "上传素材已整理完成"
        default:
            return "正在整理上传素材"
        }
    }

    private var preprocessingActivityTitle: String {
        let displayStatus = effectiveWorkflowStatus
        if let phase = normalizedRemotePhaseName {
            switch phase {
            case "streaming_input":
                return displayStatus == .uploading ? "正在边上传边同步给 GPU" : "GPU 正在接收输入视频"
            case "stream_probe_live":
                return displayStatus == .uploading ? "正在边上传边识别视频头" : "正在识别视频头"
            case "extract_frames_live":
                return displayStatus == .uploading ? "正在边上传边抽帧" : "正在抽帧"
            case "audit_live":
                return displayStatus == .uploading ? "正在边上传边整理关键帧" : "正在整理关键帧"
            case "sfm_wait_live":
                return "正在等待足够帧后启动增量相机重建"
            case "live_sfm_retry_wait":
                return "正在等待更多帧后刷新增量相机重建"
            case "live_sfm_ready":
                return displayStatus == .uploading ? "正在边上传边增量相机重建" : "正在刷新增量相机重建结果"
            case "feature_extractor":
                return displayStatus == .uploading ? "正在边上传边提取 SfM 特征" : "正在提取特征"
            case "matcher":
                return displayStatus == .uploading ? "正在边上传边匹配相邻视角" : "正在匹配相邻视角"
            case "mapper":
                return displayStatus == .uploading ? "正在边上传边做相机重建" : "正在做相机重建"
            case "probe":
                return "正在做训练前检查"
            default:
                break
            }
        }

        if let basis = normalizedProgressBasis {
            switch basis {
            case "worker_assigned", "worker_assigned_streaming_input":
                return displayStatus == .uploading ? "正在边上传边同步给 GPU" : "GPU 已接单，正在接收输入"
            case "prep_stream_probe_live":
                return displayStatus == .uploading ? "正在边上传边识别视频头" : "正在识别视频头"
            case "prep_extract_frames_live":
                return displayStatus == .uploading ? "正在边上传边抽帧" : "正在抽帧"
            case "prep_audit_live":
                return displayStatus == .uploading ? "正在边上传边整理关键帧" : "正在整理关键帧"
            case "prep_live_sfm_wait_frames":
                return "正在等待足够帧后启动增量相机重建"
            case "prep_live_sfm_retry_wait":
                return "正在等待更多帧后刷新增量相机重建"
            case "prep_live_sfm_ready":
                return displayStatus == .uploading ? "正在边上传边增量相机重建" : "正在刷新增量相机重建结果"
            case "prep_extract_frames":
                return "正在抽帧"
            case "prep_feature_images":
                return displayStatus == .uploading ? "正在边上传边提取 SfM 特征" : "正在提取特征"
            case "prep_match_pairs":
                return displayStatus == .uploading ? "正在边上传边匹配相邻视角" : "正在匹配相邻视角"
            case "prep_mapper_registered_images":
                return displayStatus == .uploading ? "正在边上传边做相机重建" : "正在做相机重建"
            case "runtime_tqdm_steps", "runtime_budget":
                if isTrainingProbeRuntime {
                    return "正在做训练前检查"
                }
                if isAuthoritativePreprocessRuntime {
                    return "正在做训练前检查"
                }
            case "prep_ready_waiting_gpu":
                return "预处理完成，正在等待 GPU"
            case "active_worker_without_runtime":
                return "GPU 已接单，正在启动阶段任务"
            default:
                break
            }
        }

        let source = normalizedLiveDetailSource
        if source.contains("COLMAP") || source.contains("稀疏模型") {
            return displayStatus == .uploading ? "正在边上传边增量相机重建" : "正在做相机重建"
        }
        if source.contains("匹配相邻视角") || source.contains("组视角已匹配") || source.contains("视角已匹配") {
            return displayStatus == .uploading ? "正在边上传边匹配相邻视角" : "正在匹配相邻视角"
        }
        if source.contains("抽取帧图像") || source.contains("抽帧") {
            return displayStatus == .uploading ? "正在边上传边抽帧" : "正在抽帧"
        }
        if source.contains("审核和筛选") || source.contains("视角审核") {
            return displayStatus == .uploading ? "正在边上传边整理关键帧" : "正在整理关键帧"
        }
        if source.contains("特征提取") {
            return displayStatus == .uploading ? "正在边上传边提取 SfM 特征" : "正在提取特征"
        }
        return displayStatus == .uploading ? "正在边上传边预处理" : "正在预处理并准备重建"
    }

    private var trainActivityTitle: String {
        if isTrainingProbeRuntime {
            return "正在做训练前检查"
        }
        if let phase = normalizedRemotePhaseName {
            switch phase {
            case "seed_booting":
                return uploadCompletedOnBackend ? "正在启动种子训练" : "正在边上传边启动种子训练"
            case "seed_wait_more_input":
                return uploadCompletedOnBackend ? "正在等待更多输入继续种子训练" : "正在边上传边等待更多输入继续种子训练"
            case "seed_retry_smaller":
                return "正在缩小种子训练规模后重试"
            case "seed_full":
                return uploadCompletedOnBackend ? "正在训练种子模型" : "正在边上传边训练种子模型"
            case "full":
                return "正在训练 3D 模型"
            case "export":
                return "正在整理 3DGS 结果"
            default:
                break
            }
        }
        return "正在训练 3D 模型"
    }

    private var returnActivityTitle: String {
        if status == .completed, artifactPath == nil {
            return "正在回传到手机"
        }
        switch effectiveWorkflowStatus {
        case .downloading:
            return "正在回传到手机"
        case .packaging:
            return "正在整理并回传结果"
        default:
            if isAuthoritativeReturnRuntime {
                return "正在整理并回传结果"
            }
            return "正在回传到手机"
        }
    }

    private var localPreparationDetailText: String? {
        guard effectiveWorkflowStatus == .preparing else { return nil }
        let detail = normalizedLiveDetailSource
        if !detail.isEmpty {
            return detail
        }
        switch normalizedProgressBasis {
        case "prepare_inspecting_source":
            return "正在检查视频是否可读、时长是否正常，并挑选最合适的流式重封装方案。"
        case "prepare_remuxing_container":
            return "正在把视频整理成更适合后台持续上传和流式预处理的容器格式。"
        case "prepare_verifying_output":
            return "流式友好容器已经写出，正在校验文件大小与可用性。"
        case "prepare_ready_for_upload":
            return "流式友好容器已就绪，下一步会立即开始后台上传。"
        default:
            return "会先把视频整理成更适合流式处理的容器，再进入后台上传。"
        }
    }

    public var uploadSpeedText: String? {
        guard isUploadTrackActive,
              !isUploadFinalizing,
              let uploadBytesPerSecond,
              uploadBytesPerSecond.isFinite,
              uploadBytesPerSecond > 0 else {
            return nil
        }
        return Self.rateString(uploadBytesPerSecond)
    }

    public var progressPercentText: String? {
        guard progressFraction != nil else { return nil }
        return String(format: "%.1f%%", displayProgressFraction * 100.0)
    }

    private var normalizedRemoteStageKey: String? {
        OnDeviceProcessingCompatibility.normalizedWorkflowStageKey(remoteStageKey)
    }

    private var normalizedRemotePhaseName: String? {
        remotePhaseName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var normalizedRuntimeMetrics: [String: String] {
        runtimeMetrics ?? [:]
    }

    private func runtimeMetricString(_ key: String) -> String? {
        LocalPreviewProductProfile.runtimeMetricString(key, from: normalizedRuntimeMetrics)
    }

    private func runtimeMetricInt(_ key: String) -> Int? {
        guard let raw = runtimeMetricString(key) else { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: "")
        if let intValue = Int(normalized) {
            return intValue
        }
        if let doubleValue = Double(normalized) {
            return Int(doubleValue)
        }
        return nil
    }

    private var isLocalPreviewWorkflow: Bool {
        resolvedProcessingBackend.usesLocalPreviewPipeline
    }

    private var localWorkflowPhases: [LocalPreviewWorkflowPhase] {
        LocalPreviewProductProfile.workflowPhases(for: resolvedProcessingBackend)
    }

    private var localPreviewPhase: LocalPreviewWorkflowPhase? {
        guard isLocalPreviewWorkflow else { return nil }
        return LocalPreviewProductProfile.phase(
            for: normalizedProgressBasis,
            phaseName: normalizedRemotePhaseName,
            processingBackend: resolvedProcessingBackend
        )
    }

    private func localPreviewPhaseIndex(_ phase: LocalPreviewWorkflowPhase) -> Int {
        localWorkflowPhases.firstIndex(of: phase) ?? 0
    }

    private func localPreviewPhaseElapsedMs(_ phase: LocalPreviewWorkflowPhase) -> Int? {
        switch phase {
        case .depth:
            return runtimeMetricInt("native_phase_depth_ms")
        case .seed:
            return runtimeMetricInt("native_phase_seed_ms")
        case .refine:
            return runtimeMetricInt("native_phase_refine_ms")
        case .cutout:
            return runtimeMetricInt("native_phase_cutout_ms")
        case .cleanup:
            return runtimeMetricInt("native_phase_cleanup_ms")
        case .export:
            return runtimeMetricInt("native_export_ms")
        }
    }

    private func localPreviewPhaseMetricText(for phase: LocalPreviewWorkflowPhase) -> String? {
        switch phase {
        case .depth:
            let liveSubmitted = runtimeMetricInt("native_live_submitted_frames") ?? 0
            let importSubmitted = runtimeMetricInt("native_import_submitted_frames") ?? 0
            let nativeEnqueued = runtimeMetricInt("native_frames_enqueued") ?? 0
            let nativeIngested = runtimeMetricInt("native_frames_ingested") ?? 0
            let submitted = Swift.max(liveSubmitted, importSubmitted, nativeEnqueued)
            if submitted > 0 {
                return "\(nativeIngested) / \(submitted) 帧"
            }
            if let liveText = runtimeMetricString("native_depth_phase_metric_text"),
               !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return liveText
            }
            if let ready = runtimeMetricInt("native_depth_results_ready"),
               let submitted = runtimeMetricInt("native_depth_batches_submitted"),
               submitted > 0 {
                return "\(ready) / \(submitted) 批 depth"
            }
            if let processed = runtimeMetricInt("native_processed_frames"),
               let target = runtimeMetricInt("native_live_target_frames"),
               target > 0 {
                return "\(processed) / \(target) 帧"
            }
            if let processed = runtimeMetricInt("native_processed_frames"),
               processed > 0 {
                return "\(processed) 帧"
            }
        case .seed:
            if let liveText = runtimeMetricString("native_seed_phase_metric_text"),
               !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return liveText
            }
            if let accepted = runtimeMetricInt("native_seed_accepted"),
               accepted > 0 {
                let selected = runtimeMetricInt("native_selected_frames") ?? 0
                if selected > 0 {
                    return "seed \(accepted) · 帧 \(selected)"
                }
                let candidates = runtimeMetricInt("native_seed_candidates") ?? 0
                if candidates > 0 {
                    return "seed \(accepted) · 候选 \(candidates)"
                }
                return "seed \(accepted)"
            }
            if let selected = runtimeMetricInt("native_selected_frames"),
               let minimum = runtimeMetricInt("native_live_min_selected_frames"),
               minimum > 0 {
                if selected < minimum {
                    return "关键帧 \(selected) / \(minimum)"
                }
                return "关键帧 \(selected) · 已达标"
            }
            if let accepted = runtimeMetricInt("native_seed_accepted"),
               let candidates = runtimeMetricInt("native_seed_candidates"),
               candidates > 0 {
                return "seed \(accepted) · 候选 \(candidates)"
            }
        case .refine:
            if let liveText = runtimeMetricString("native_refine_phase_metric_text"),
               !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return liveText
            }
            if let percent = trainingProgressPercentTextValue {
                return percent
            }
            if let gaussians = runtimeMetricInt("native_gaussians"), gaussians > 0 {
                return "\(gaussians) 个高斯"
            }
        case .cutout:
            if let liveText = runtimeMetricString("native_cutout_phase_metric_text"),
               !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return liveText
            }
            if let kept = runtimeMetricInt("native_subject_cutout_kept"),
               let input = runtimeMetricInt("native_subject_input_splats"),
               input > 0 {
                return "\(kept) / \(input)"
            }
        case .cleanup:
            if let liveText = runtimeMetricString("native_cleanup_phase_metric_text"),
               !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return liveText
            }
            if let kept = runtimeMetricInt("native_subject_cleanup_kept"),
               let removed = runtimeMetricInt("native_subject_cleanup_removed") {
                return "保留 \(kept) · 删除 \(removed)"
            }
        case .export:
            if let liveText = runtimeMetricString("native_export_phase_metric_text"),
               !liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return liveText
            }
            if let exportMs = localPreviewPhaseElapsedMs(.export), exportMs > 0 {
                return Self.durationMetricText(seconds: max(1, Int((Double(exportMs) / 1000.0).rounded())))
            }
        }
        if let elapsed = localPreviewPhaseElapsedMs(phase), elapsed > 0 {
            return Self.durationMetricText(seconds: max(1, Int((Double(elapsed) / 1000.0).rounded())))
        }
        return nil
    }

    private func localPreviewMilestoneState(for phase: LocalPreviewWorkflowPhase) -> WorkflowMilestoneState {
        if artifactPath != nil {
            return .completed
        }
        if let currentPhase = localPreviewPhase {
            let currentIndex = localPreviewPhaseIndex(currentPhase)
            let phaseIndex = localPreviewPhaseIndex(phase)
            if phaseIndex < currentIndex {
                return .completed
            }
            if phaseIndex == currentIndex {
                return status == .completed ? .completed : .active
            }
            if phaseIndex > currentIndex {
                return .pending
            }
        }
        if let elapsed = localPreviewPhaseElapsedMs(phase), elapsed > 0 {
            return .completed
        }
        switch phase {
        case .depth:
            if let batches = runtimeMetricInt("native_depth_batches_submitted"), batches > 0 {
                return .completed
            }
        case .seed:
            if let accepted = runtimeMetricInt("native_seed_accepted"), accepted > 0 {
                return .completed
            }
        case .refine:
            if let trainingProgress = runtimeMetricString("native_training_progress"),
               !trainingProgress.isEmpty {
                return .completed
            }
        case .cutout:
            if let kept = runtimeMetricInt("native_subject_cutout_kept"), kept > 0 {
                return .completed
            }
        case .cleanup:
            if let kept = runtimeMetricInt("native_subject_cleanup_kept"), kept > 0 {
                return .completed
            }
        case .export:
            if let exported = runtimeMetricString("native_export_succeeded"), exported == "1" {
                return .completed
            }
        }
        return .pending
    }

    private var isUploadStillOpenOnBackend: Bool {
        if uploadCompletedOnBackend {
            return false
        }
        if isAuthoritativePostUploadStage {
            return false
        }
        if let raw = runtimeMetricString("upload_completed")?.lowercased() {
            return raw != "true"
        }

        guard let basis = normalizedProgressBasis else {
            return status == .uploading
        }

        switch basis {
        case "created",
             "upload_bytes",
             "chunked_upload_bytes",
             "chunk_part_uploaded",
             "object_storage_visible",
             "upload_finalizing",
             "control_plane_upload_complete",
             "upload_complete",
             "multipart_upload_complete",
             "chunked_upload_complete",
             "worker_assigned",
             "worker_assigned_streaming_input",
             "prep_stream_probe_live",
             "prep_extract_frames_live",
             "prep_audit_live",
             "prep_live_sfm_wait_frames",
             "prep_live_sfm_retry_wait",
             "prep_live_sfm_ready":
            return true
        default:
            return status == .uploading
        }
    }

    private var isStreamingLiveSfm: Bool {
        guard isUploadStillOpenOnBackend else { return false }
        if let basis = normalizedProgressBasis,
           basis.hasPrefix("prep_live_sfm") {
            return true
        }
        if let phase = normalizedRemotePhaseName,
           ["sfm_wait_live", "live_sfm_retry_wait", "live_sfm_ready", "feature_extractor", "matcher", "mapper"].contains(phase) {
            return true
        }
        if let stage = normalizedRemoteStageKey,
           ["sfm", "sfm_extract", "sfm_match", "sfm_reconstruct"].contains(stage) {
            return true
        }
        return false
    }

    public var hasStreamingPreprocessing: Bool {
        if isStreamingLiveSfm {
            return true
        }
        guard let basis = normalizedProgressBasis else { return false }
        return [
            "worker_assigned_streaming_input",
            "prep_stream_probe_live",
            "prep_extract_frames_live",
            "prep_audit_live",
            "prep_live_sfm_wait_frames",
            "prep_live_sfm_retry_wait",
            "prep_live_sfm_ready"
        ].contains(basis)
    }

    private var hasSeedTrainingRuntime: Bool {
        if let phase = normalizedRemotePhaseName,
           phase.hasPrefix("seed_") {
            return true
        }
        guard let stage = normalizedRemoteStageKey,
              stage == "train" || stage.hasPrefix("train") else {
            return false
        }
        return runtimeMetricInt("selected_frames") != nil
            || runtimeMetricInt("registered_images") != nil
            || runtimeMetricInt("seed_image_count") != nil
    }

    private var isPrepareTrackActive: Bool {
        if status == .preparing {
            return true
        }
        guard let basis = normalizedProgressBasis else { return false }
        switch basis {
        case "prepare_inspecting_source",
             "prepare_remuxing_container",
             "prepare_verifying_output",
             "prepare_ready_for_upload":
            return true
        default:
            return false
        }
    }

    private var isPrepareTrackCompleted: Bool {
        if isPrepareTrackActive {
            return false
        }
        return remoteJobId != nil
            || uploadedBytes != nil
            || totalBytes != nil
            || status != .preparing
    }

    private var isUploadTrackActive: Bool {
        if status == .failed || status == .cancelled || artifactPath != nil {
            return false
        }
        // Once the backend reports a real post-upload stage, trust that stage over stale byte counters.
        if isAuthoritativePreprocessRuntime
            || isAuthoritativeTrainingRuntime
            || isAuthoritativeReturnRuntime
            || isAuthoritativePostUploadStage {
            return false
        }
        if !uploadCompletedOnBackend {
            return uploadedBytes != nil
                || totalBytes != nil
                || status == .uploading
                || normalizedProgressBasis == "created"
                || normalizedProgressBasis == "upload_bytes"
                || normalizedProgressBasis == "chunked_upload_bytes"
                || normalizedProgressBasis == "chunk_part_uploaded"
                || normalizedProgressBasis == "upload_finalizing"
                || normalizedProgressBasis == "object_storage_visible"
                || hasStreamingPreprocessing
                || hasSeedTrainingRuntime
        }
        return false
    }

    private var isUploadTrackCompleted: Bool {
        uploadCompletedOnBackend
    }

    private var isPreprocessTrackActive: Bool {
        if isAuthoritativePreprocessRuntime || hasStreamingPreprocessing {
            return true
        }
        if !uploadCompletedOnBackend && hasSeedTrainingRuntime {
            return true
        }
        return false
    }

    private var isPreprocessTrackCompleted: Bool {
        if isPreprocessTrackActive {
            return false
        }
        if normalizedProgressBasis == "prep_ready_waiting_gpu" {
            return true
        }
        switch status {
        case .training, .localFallback, .packaging, .downloading, .completed:
            return true
        default:
            return false
        }
    }

    private var isAuthoritativeGpuWaitRuntime: Bool {
        normalizedProgressBasis == "prep_ready_waiting_gpu"
            || normalizedRemoteStageKey == "gpu_wait"
            || normalizedRemotePhaseName == "gpu_wait"
    }

    private var isTrainTrackActive: Bool {
        if isAuthoritativeGpuWaitRuntime {
            return false
        }
        return isAuthoritativeTrainingRuntime
            || isTrainingProbeRuntime
            || hasSeedTrainingRuntime
            || status == .training
            || status == .localFallback
    }

    private var isTrainTrackCompleted: Bool {
        if isTrainTrackActive {
            return false
        }
        switch status {
        case .packaging, .downloading:
            return true
        case .completed:
            return artifactPath != nil
        default:
            return false
        }
    }

    private var isReturnTrackActive: Bool {
        if isAuthoritativeReturnRuntime || status == .packaging || status == .downloading {
            return true
        }
        if status == .completed, artifactPath == nil, remoteJobId != nil {
            return true
        }
        return false
    }

    private var isReturnTrackCompleted: Bool {
        artifactPath != nil
    }

    private var activeWorkflowTrackTitles: [String] {
        if isLocalPreviewWorkflow {
            return localWorkflowPhases.compactMap { phase in
                localPreviewMilestoneState(for: phase) == .active ? phase.title : nil
            }
        }
        var titles: [String] = []
        if isPrepareTrackActive { titles.append("整理") }
        if isUploadTrackActive { titles.append("上传") }
        if isPreprocessTrackActive { titles.append("预处理") }
        if isTrainTrackActive { titles.append("训练") }
        if isReturnTrackActive { titles.append("回传") }
        return titles
    }

    private static func parallelTrackTitle(_ titles: [String]) -> String {
        switch titles.count {
        case 0:
            return "处理中"
        case 1:
            return "正在\(titles[0])"
        case 2:
            return "\(titles[0])与\(titles[1])并行中"
        default:
            return "\(titles.joined(separator: "、"))并行中"
        }
    }

    public var workflowModeTitle: String {
        if isInspectionOnlyCandidate {
            return "候选结果待质检"
        }
        if isLocalPreviewWorkflow {
            switch status {
            case .completed:
                return "本地结果已生成"
            case .failed:
                return "本地处理失败了"
            case .cancelled:
                return failureReason == "stale_local_processing_frozen"
                    ? "旧本地任务已取消"
                    : "本地处理已取消"
            default:
                return localPreviewPhase?.title ?? "正在生成本地结果"
            }
        }
        if isAuthoritativeGpuWaitRuntime {
            return "预处理完成，等待 GPU 开始训练"
        }
        if activeWorkflowTrackTitles.count > 1 {
            return Self.parallelTrackTitle(activeWorkflowTrackTitles)
        }
        switch effectiveWorkflowStatus {
        case .preparing:
            return localPreparationStepTitle
        case .uploading:
            if isUploadFinalizing {
                return "上传完成，正在确认入库"
            }
            if isStreamingLiveSfm {
                return "上传与增量相机重建并行中"
            }
            if hasStreamingPreprocessing {
                return "上传与预处理并行中"
            }
            return "正在上传视频"
        case .queued:
            if normalizedProgressBasis == "prep_ready_waiting_gpu" {
                return "预处理完成，等待 GPU 开始训练"
            }
            return "上传完成，等待 GPU 接手"
        case .reconstructing:
            if isTrainingProbeRuntime {
                return "正在做训练前检查"
            }
            return "正在预处理并准备重建"
        case .training, .localFallback:
            return "正在训练 3D 模型"
        case .packaging, .downloading:
            return "正在整理并回传结果"
        case .completed:
            return "结果已回到手机"
        case .cancelled:
            return "这次任务已取消"
        case .failed:
            return "这次任务失败了"
        }
    }

    public var workflowModeSummaryText: String? {
        if isInspectionOnlyCandidate {
            if let failedSummary = inspectionFailedCardsSummaryText {
                return "候选结果已生成，但未达 HQ，仅供质检。当前未通过：\(failedSummary)。"
            }
            return "候选结果已生成，但未达 HQ，仅供质检。"
        }
        if isLocalPreviewWorkflow {
            switch status {
            case .completed:
                return "手机已经生成可交互的本地 preview，可以直接进入 3D 查看器查看结果。"
            case .failed, .cancelled:
                return detailMessage
            default:
                if let phase = localPreviewPhase {
                    return phase.detailMessage
                }
                return "手机会依次完成深度先验、seed 初始化、bounded refine 和导出。"
            }
        }
        if isAuthoritativeGpuWaitRuntime {
            return "当前这条任务的抽帧、关键帧整理和重建已完成，正在等待 GPU 训练槽。"
        }
        if activeWorkflowTrackTitles.count > 1 {
            let titles = activeWorkflowTrackTitles.joined(separator: "、")
            if isUploadTrackActive && isPreprocessTrackActive && isTrainTrackActive {
                return "当前同时开工：\(titles)。上传未结束前，后端会继续消费可见输入、复用 live SfM 结果，并尽早启动训练。"
            }
            if isUploadTrackActive && isPreprocessTrackActive {
                return "当前同时开工：\(titles)。上传未结束时，后端会持续消费已可见的视频分片。"
            }
            return "当前同时开工：\(titles)。"
        }
        switch effectiveWorkflowStatus {
        case .preparing:
            return localPreparationDetailText
                ?? "会先把视频整理成更适合流式处理的容器，再进入后台上传。"
        case .uploading:
            if isUploadFinalizing {
                return "所有分片已发送，正在等待对象存储确认并完成合并。"
            }
            if isStreamingLiveSfm {
                return "当前同时开工：上传、抽帧、关键帧整理、增量相机重建。上传未结束时，后端会持续消费已可见的视频分片。"
            }
            if hasStreamingPreprocessing {
                return "当前同时开工：上传、抽帧、关键帧整理。上传未结束时，后端会持续消费已可见的视频分片。"
            }
            return "手机正在把视频直接上传到对象存储。"
        case .queued:
            return "视频已经完整到达对象存储，正在等待可用 GPU 真正接单。"
        case .reconstructing:
            if isTrainingProbeRuntime {
                return "相机重建和关键帧整理已完成，正在做训练前检查。通过后才会进入完整训练。"
            }
            return "上传已结束，后端正在做正式预处理、视角对齐和相机重建。"
        case .training, .localFallback:
            return "预处理已完成，GPU 正在优化 3D 模型。"
        case .packaging, .downloading:
            return "训练已结束，正在整理最终结果并回到手机。"
        case .completed:
            return "现在可以进入 3D 查看器交互查看结果。"
        case .cancelled, .failed:
            return nil
        }
    }

    public var workflowOverallFraction: Double {
        if let weighted = weightedWorkflowOverallFraction {
            switch status {
            case .completed:
                return 1.0
            case .failed, .cancelled:
                return min(max(weighted, 0.0), 0.99)
            default:
                return min(max(weighted, 0.0), 0.99)
            }
        }

        let floor: Double
        switch effectiveWorkflowStatus {
        case .preparing:
            floor = 0.02
        case .uploading:
            floor = hasStreamingPreprocessing ? 0.10 : 0.04
        case .queued:
            floor = 0.24
        case .reconstructing:
            floor = 0.30
        case .training, .localFallback:
            floor = 0.58
        case .packaging, .downloading:
            floor = 0.90
        case .completed:
            return 1.0
        case .cancelled, .failed:
            return displayProgressFraction
        }
        return min(max(displayProgressFraction, floor), 0.99)
    }

    public var workflowOverallPercentText: String? {
        guard status == .completed || weightedWorkflowOverallFraction != nil || progressFraction != nil else { return nil }
        return String(format: "%.1f%%", workflowOverallFraction * 100.0)
    }

    public var workflowMilestones: [WorkflowMilestone] {
        if isLocalPreviewWorkflow {
            return localWorkflowPhases.map { phase in
                WorkflowMilestone(
                    id: phase.rawValue,
                    title: phase.title,
                    state: localPreviewMilestoneState(for: phase)
                )
            }
        }
        return [
            WorkflowMilestone(id: "prepare", title: "整理", state: milestoneState(for: "prepare")),
            WorkflowMilestone(id: "upload", title: "上传", state: milestoneState(for: "upload")),
            WorkflowMilestone(id: "preprocess", title: "预处理", state: milestoneState(for: "preprocess")),
            WorkflowMilestone(id: "train", title: "训练", state: milestoneState(for: "train")),
            WorkflowMilestone(id: "return", title: "回传", state: milestoneState(for: "return"))
        ]
    }

    public var workflowStepProgresses: [WorkflowStepProgress] {
        if isLocalPreviewWorkflow {
            return localWorkflowPhases.map { phase in
                let state = localPreviewMilestoneState(for: phase)
                return WorkflowStepProgress(
                    id: phase.rawValue,
                    title: phase.title,
                    state: state,
                    progressFraction: workflowStepFraction(for: phase.rawValue, state: state),
                    progressText: workflowStepProgressText(for: phase.rawValue, state: state),
                    detailText: workflowStepDetailText(for: phase.rawValue, state: state)
                )
            }
        }
        return [
            workflowStepProgress(id: "prepare", title: "整理"),
            workflowStepProgress(id: "upload", title: "上传"),
            workflowStepProgress(id: "preprocess", title: "预处理"),
            workflowStepProgress(id: "train", title: "训练"),
            workflowStepProgress(id: "return", title: "回传")
        ]
    }

    public var activeWorkflowStepProgresses: [WorkflowStepProgress] {
        workflowStepProgresses.filter { $0.state == .active }
    }

    public var activeWorkflowStepCount: Int {
        activeWorkflowStepProgresses.count
    }

    private var weightedWorkflowOverallFraction: Double? {
        if isLocalPreviewWorkflow {
            let weights: [(String, Double)] = resolvedProcessingBackend == .localSubjectFirst
                ? [
                    (LocalPreviewWorkflowPhase.depth.rawValue, 0.20),
                    (LocalPreviewWorkflowPhase.seed.rawValue, 0.14),
                    (LocalPreviewWorkflowPhase.refine.rawValue, 0.32),
                    (LocalPreviewWorkflowPhase.cutout.rawValue, 0.14),
                    (LocalPreviewWorkflowPhase.cleanup.rawValue, 0.10),
                    (LocalPreviewWorkflowPhase.export.rawValue, 0.10),
                ]
                : [
                    (LocalPreviewWorkflowPhase.depth.rawValue, 0.24),
                    (LocalPreviewWorkflowPhase.seed.rawValue, 0.18),
                    (LocalPreviewWorkflowPhase.refine.rawValue, 0.40),
                    (LocalPreviewWorkflowPhase.export.rawValue, 0.18),
                ]
            let progressByID = Dictionary(uniqueKeysWithValues: workflowStepProgresses.map { ($0.id, $0.progressFraction) })
            guard progressByID.isEmpty == false else { return nil }
            let weighted = weights.reduce(0.0) { partial, entry in
                partial + (progressByID[entry.0] ?? 0.0) * entry.1
            }
            return min(max(weighted, 0.0), 1.0)
        }
        let weights: [(String, Double)] = [
            ("prepare", 0.08),
            ("upload", 0.18),
            ("preprocess", 0.34),
            ("train", 0.30),
            ("return", 0.10),
        ]
        let progressByID = Dictionary(uniqueKeysWithValues: workflowStepProgresses.map { ($0.id, $0.progressFraction) })
        guard progressByID.isEmpty == false else { return nil }
        let weighted = weights.reduce(0.0) { partial, entry in
            partial + (progressByID[entry.0] ?? 0.0) * entry.1
        }
        return min(max(weighted, 0.0), 1.0)
    }

    public var overlapUploadTitle: String {
        isUploadFinalizing ? "确认上传" : "上传视频"
    }

    public var overlapPreprocessingTitle: String? {
        guard hasStreamingPreprocessing else { return nil }
        if let phase = normalizedRemotePhaseName {
            switch phase {
            case "streaming_input":
                return "接收可见分片"
            case "stream_probe_live":
                return "识别视频头"
            case "extract_frames_live":
                return "抽帧"
            case "audit_live":
                return "关键帧整理"
            case "sfm_wait_live":
                return "等待足够帧后启动 SfM"
            case "live_sfm_retry_wait":
                return "等待更多帧后刷新 SfM"
            case "live_sfm_ready":
                return isUploadStillOpenOnBackend ? "增量相机重建已拿到结果" : "增量相机重建结果已就绪"
            case "feature_extractor":
                return "增量提取特征"
            case "matcher":
                return "增量匹配视角"
            case "mapper":
                return "增量相机重建"
            default:
                break
            }
        }
        guard let basis = normalizedProgressBasis else { return "预处理" }
        switch basis {
        case "worker_assigned_streaming_input":
            return "接收可见分片"
        case "prep_stream_probe_live":
            return "识别视频头"
        case "prep_extract_frames_live":
            return "抽帧"
        case "prep_audit_live":
            return "关键帧整理"
        case "prep_live_sfm_wait_frames":
            return "等待足够帧后启动 SfM"
        case "prep_live_sfm_retry_wait":
            return "等待更多帧后刷新 SfM"
        case "prep_live_sfm_ready":
            return isUploadStillOpenOnBackend ? "增量相机重建已拿到结果" : "增量相机重建结果已就绪"
        default:
            return "预处理"
        }
    }

    public var diagnosticStageText: String {
        if isLocalPreviewWorkflow {
            return localPreviewPhase?.title ?? "本地处理"
        }
        if isStreamingLiveSfm {
            return "上传 + 增量 SfM 并行"
        }
        if let basis = normalizedProgressBasis {
            switch basis {
            case "upload_aborted", "upload_bytes", "chunked_upload_bytes", "upload_finalizing":
                return "上传阶段"
            case "worker_assigned_streaming_input",
                 "prep_stream_probe_live",
                 "prep_extract_frames_live",
                 "prep_audit_live",
                 "prep_live_sfm_wait_frames",
                 "prep_live_sfm_retry_wait",
                 "prep_live_sfm_ready":
                return "上传 + 预处理并行"
            case "prep_extract_frames",
                 "prep_feature_images",
                 "prep_match_pairs",
                 "prep_mapper_registered_images":
                return "正式预处理阶段"
            case "runtime_tqdm_steps", "runtime_budget":
                return "训练阶段"
            case "runtime_render_count":
                return "导出阶段"
            default:
                break
            }
        }
        let headline = waitingHeadlineText
        return headline.isEmpty ? workflowModeTitle : headline
    }

    public var diagnosticProgressBasisText: String? {
        guard let basis = normalizedProgressBasis else { return nil }
        let label = Self.progressBasisDisplayTitle(for: basis)
        if label == basis {
            return basis
        }
        return "\(label) · \(basis)"
    }

    public var diagnosticFailureTitle: String? {
        guard let reason = normalizedFailureReason else { return nil }
        return Self.failureReasonDisplayTitle(for: reason)
    }

    public var diagnosticFailureCodeText: String? {
        normalizedFailureReason
    }

    public var diagnosticJobIdText: String? {
        guard let remoteJobId else { return nil }
        let trimmed = remoteJobId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var galleryVideoDurationLabelText: String? {
        guard durationSeconds > 0 else { return nil }
        return "视频 \(Self.clockDurationText(seconds: Int(durationSeconds.rounded())))"
    }

    public var gallerySamplingProfileLabelText: String? {
        switch frameSamplingProfile {
        case "full":
            return "方案 全量采集"
        case "half":
            return "方案 半量采集"
        case "third":
            return "方案 三分之一采集"
        default:
            return nil
        }
    }

    public var galleryProcessingBackendLabelText: String? {
        resolvedProcessingBackend == .cloud ? "远端方案" : "本地方案"
    }

    public var galleryProcessingDurationLabelText: String? {
        guard let seconds = effectiveProcessingElapsedSeconds else {
            return isFilesystemRecoveredRecord ? "总耗时 未知" : nil
        }
        let prefix = isProcessingDurationFinalized ? "总耗时" : "已运行"
        return "\(prefix) \(Self.clockDurationText(seconds: Int(seconds.rounded())))"
    }

    public var galleryStatusMetaText: String? {
        if isInspectionOnlyCandidate {
            if let failedSummary = inspectionFailedCardsSummaryText {
                return "未达 HQ · \(failedSummary) 待人工质检"
            }
            return "未达 HQ · 候选结果待人工质检"
        }
        if isLocalPreviewWorkflow {
            switch status {
            case .completed:
                return nil
            case .failed, .cancelled:
                return detailMessage
            default:
                if let metrics = displayStepMetricsText {
                    return "\(liveStepTitle) · \(metrics)"
                }
                return liveStepTitle
            }
        }
        switch effectiveWorkflowStatus {
        case .uploading:
            if hasStreamingPreprocessing {
                if let metrics = displayStepMetricsText {
                    return "上传 + 预处理并行 · \(liveStepTitle) · \(metrics)"
                }
                return "上传 + 预处理并行 · \(liveStepTitle)"
            }
            if let uploadProgressText {
                return uploadProgressText
            }
            return liveStepTitle
        case .preparing, .queued, .reconstructing, .training, .packaging, .downloading, .localFallback:
            if let metrics = displayStepMetricsText {
                return "\(liveStepTitle) · \(metrics)"
            }
            if let basis = diagnosticProgressBasisText {
                return "\(liveStepTitle) · \(basis)"
            }
            return liveStepTitle
        case .cancelled:
            if let reason = diagnosticFailureTitle {
                return "\(reason) · 原始视频仍保留"
            }
            return sourceVideoPath != nil ? "原始视频已保留，可随时重发" : "这次记录已停下，可按需删除"
        case .failed:
            if let reason = diagnosticFailureTitle {
                return "\(reason) · \(sourceVideoPath != nil ? "可重新发送" : "建议重新拍摄")"
            }
            return sourceVideoPath != nil ? "保留了原视频，可重新发送" : "建议重新拍摄一轮"
        case .completed:
            return nil
        }
    }

    public var liveProgressMetrics: [WorkflowActivityMetric] {
        if isLocalPreviewWorkflow {
            var metrics: [WorkflowActivityMetric] = []
            if let currentPhase = localPreviewPhase,
               let metricText = localPreviewPhaseMetricText(for: currentPhase) {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "local_native_phase_metric",
                        title: metricText,
                        subtitle: currentPhase.title
                    )
                )
            }
            let currentGaussians = runtimeMetricInt("native_current_gaussians")
                ?? runtimeMetricInt("native_gaussians")
            let retainedGaussians = runtimeMetricInt("native_current_retained_export_gaussians") ?? 0
            let peakGaussians = runtimeMetricInt("native_peak_gaussians") ?? 0
            if status == .failed, peakGaussians > 0 {
                let subtitle = retainedGaussians > 0
                    ? "训练高斯峰值（保留快照 \(retainedGaussians)）"
                    : "训练高斯峰值"
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_peak_gaussians",
                        title: "\(peakGaussians)",
                        subtitle: subtitle
                    )
                )
            } else if retainedGaussians > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_retained_export_gaussians",
                        title: "\(retainedGaussians)",
                        subtitle: "保留导出快照"
                    )
                )
            } else if let gaussians = currentGaussians, gaussians > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_gaussians",
                        title: "\(gaussians)",
                        subtitle: status == .failed ? "导出失败时当前高斯数" : "当前高斯数"
                    )
                )
            }
            if status == .failed, let attempts = runtimeMetricInt("native_export_attempts"), attempts > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_export_attempts",
                        title: "\(attempts)",
                        subtitle: "导出尝试次数"
                    )
                )
            }
            if status == .failed, let fileSize = runtimeMetricInt("native_export_file_size_bytes"), fileSize >= 0 {
                let fileSizeText = ByteCountFormatter.string(
                    fromByteCount: Int64(fileSize),
                    countStyle: .file
                )
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_export_file_size_bytes",
                        title: fileSizeText,
                        subtitle: "导出文件大小"
                    )
                )
            }
            if status == .failed, let waitSteps = runtimeMetricInt("native_export_wait_steps"), waitSteps > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_export_wait_steps",
                        title: "\(waitSteps)",
                        subtitle: "导出等待步数"
                    )
                )
            }
            if status == .failed, let statusCode = runtimeMetricInt("native_export_status_code") {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_export_status_code",
                        title: "\(statusCode)",
                        subtitle: runtimeMetricString("native_export_failure_reason") ?? "导出状态码"
                    )
                )
            }
            if let quality = runtimeMetricString("native_overall_quality") {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_quality",
                        title: quality,
                        subtitle: "当前质量估计"
                    )
                )
            }
            if let elapsed = runtimeMetricInt("native_elapsed_ms"), elapsed > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "native_elapsed_ms",
                        title: Self.durationMetricText(seconds: max(1, Int((Double(elapsed) / 1000.0).rounded()))),
                        subtitle: "本地已运行"
                    )
                )
            }
            return metrics
        }
        var metrics: [WorkflowActivityMetric] = []
        let source = normalizedLiveDetailSource
        let displayStatus = effectiveWorkflowStatus
        let allowsPreprocessMetrics = displayStatus == .uploading || displayStatus == .reconstructing
        let allowsTrainingMetrics = displayStatus == .training || displayStatus == .localFallback
        let allowsReturnMetrics = displayStatus == .packaging || displayStatus == .downloading

        if allowsReturnMetrics,
           let downloadedBytes = runtimeMetricInt("downloaded_bytes"),
           let totalDownloadBytes = runtimeMetricInt("download_total_bytes"),
           totalDownloadBytes > 0 {
            metrics.append(
                WorkflowActivityMetric(
                    id: "download_bytes",
                    title: "\(Self.byteString(Int64(downloadedBytes))) / \(Self.byteString(Int64(totalDownloadBytes)))",
                    subtitle: "已回传字节"
                )
            )
        }

        if displayStatus == .uploading {
            if let uploadedBytes,
               let totalBytes,
               totalBytes > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "upload_bytes",
                        title: "\(Self.byteString(uploadedBytes)) / \(Self.byteString(totalBytes))",
                        subtitle: "已上传字节"
                    )
                )
            }

            if let partMetric = Self.metricRatio(
                id: "upload_parts",
                subtitle: "上传分片",
                pattern: "((?:\\d[\\d,]*)\\s*/\\s*(?:\\d[\\d,]*))\\s*个分片",
                in: source
            ) {
                metrics.append(partMetric)
            }

            if let uploadSpeedText {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "upload_speed",
                        title: uploadSpeedText,
                        subtitle: "当前上传速度"
                    )
                )
            }
        }

        if allowsPreprocessMetrics,
           isPreprocessAwaitingFirstDecodableFrame {
            if let visibleChunkCount = runtimeMetricInt("visible_chunk_count"),
               let totalChunks = runtimeMetricInt("total_chunks"),
               totalChunks > 0 {
                metrics.append(
                    Self.metricRatioValue(
                        id: "visible_chunks",
                        subtitle: "已可见分片",
                        current: visibleChunkCount,
                        total: totalChunks
                    )
                )
            } else if let visibleBytes = runtimeMetricInt("visible_bytes"),
                      visibleBytes > 0,
                      let totalBytes,
                      totalBytes > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "visible_bytes",
                        title: "\(Self.byteString(Int64(visibleBytes))) / \(Self.byteString(totalBytes))",
                        subtitle: "已可见字节"
                    )
                )
            } else if let uploadedBytes,
                      uploadedBytes > 0,
                      let totalBytes,
                      totalBytes > 0 {
                metrics.append(
                    WorkflowActivityMetric(
                        id: "uploaded_bytes_visible",
                        title: "\(Self.byteString(uploadedBytes)) / \(Self.byteString(totalBytes))",
                        subtitle: "已上传字节"
                    )
                )
            }
        }

        if let structuredPhaseMetric,
           !metrics.contains(where: { $0.id == structuredPhaseMetric.id }) {
            metrics.append(structuredPhaseMetric)
        }

        let phaseElapsedSeconds = runtimeMetricInt("phase_elapsed_seconds") ?? runtimeMetricInt("elapsed_seconds")
        if let phaseElapsedSeconds,
           phaseElapsedSeconds >= 0,
           displayStatus != .completed,
           displayStatus != .failed,
           displayStatus != .cancelled {
            metrics.append(
                WorkflowActivityMetric(
                    id: "phase_elapsed_seconds",
                    title: Self.durationMetricText(seconds: phaseElapsedSeconds),
                    subtitle: runtimeMetricInt("phase_elapsed_seconds") != nil
                        ? "本阶段已运行"
                        : (resolvedProcessingBackend.usesLocalPreviewPipeline ? "本地已运行" : "远端已运行")
                )
            )
        }

        if allowsPreprocessMetrics,
           let extractedFrames = runtimeMetricInt("extracted_frames"),
           extractedFrames > 0 {
            metrics.append(
                Self.metricCountValue(
                    id: "frames_extracted",
                    subtitle: "已抽取帧",
                    value: extractedFrames,
                    suffix: " 帧"
                )
            )
        } else if allowsPreprocessMetrics, let metric = Self.metricCount(
            id: "frames_extracted",
            subtitle: "已抽取帧",
            pattern: "已抽取\\s*(\\d[\\d,]*)\\s*帧",
            in: source,
            suffix: " 帧"
        ) {
            metrics.append(metric)
        }

        if allowsPreprocessMetrics,
           let acceptedFrames = runtimeMetricInt("accepted_live_frames"),
           acceptedFrames > 0 {
            metrics.append(
                Self.metricCountValue(
                    id: "frames_audited",
                    subtitle: "已整理关键帧",
                    value: acceptedFrames,
                    suffix: " 帧"
                )
            )
        } else if allowsPreprocessMetrics, let metric = Self.metricCount(
            id: "frames_audited",
            subtitle: "已整理关键帧",
            pattern: "已整理关键帧\\s*(\\d[\\d,]*)\\s*帧",
            in: source,
            suffix: " 帧"
        ) {
            metrics.append(metric)
        }

        if allowsPreprocessMetrics, let selectedFrames = runtimeMetricInt("selected_frames") {
            metrics.append(
                Self.metricCountValue(
                    id: "colmap_selected_frames",
                    subtitle: "做 COLMAP 的帧",
                    value: selectedFrames,
                    suffix: " 帧"
                )
            )
        }

        if allowsPreprocessMetrics,
           normalizedProgressBasis == "prep_match_pairs",
           let matcherBlockIndex = runtimeMetricInt("matcher_block_index"),
           let matcherBlockTotal = runtimeMetricInt("matcher_block_total"),
           matcherBlockTotal > 0 {
            metrics.append(
                Self.metricRatioValue(
                    id: "matcher_block",
                    subtitle: "当前匹配块",
                    current: matcherBlockIndex,
                    total: matcherBlockTotal
                )
            )
        }

        if allowsPreprocessMetrics,
           normalizedProgressBasis == "prep_match_pairs",
           let matcherBlockElapsed = runtimeMetricInt("matcher_block_elapsed_sec"),
           matcherBlockElapsed >= 0 {
            metrics.append(
                WorkflowActivityMetric(
                    id: "matcher_block_elapsed",
                    title: Self.durationMetricText(seconds: matcherBlockElapsed),
                    subtitle: "本块已运行"
                )
            )
        }

        let parsedMetrics: [WorkflowActivityMetric?]
        if allowsTrainingMetrics {
            parsedMetrics = [
                Self.metricRatio(
                    id: "training_steps",
                    subtitle: "训练步数",
                    pattern: "(?:高斯优化步数|训练步数)\\s*((?:\\d[\\d,]*)\\s*/\\s*(?:\\d[\\d,]*))",
                    in: source
                )
            ]
        } else if allowsReturnMetrics {
            parsedMetrics = [
                Self.metricRatio(
                    id: "render_count",
                    subtitle: "导出渲染",
                    pattern: "((?:\\d[\\d,]*)\\s*/\\s*(?:\\d[\\d,]*))\\s*(?:次|帧)?渲染",
                    in: source
                )
            ]
        } else {
            parsedMetrics = [
                Self.metricRatio(
                    id: "matched_pairs",
                    subtitle: "已匹配视角组",
                    pattern: "((?:\\d[\\d,]*)\\s*/\\s*(?:\\d[\\d,]*))\\s*组(?:相邻)?视角已匹配",
                    in: source
                ),
                Self.metricRatio(
                    id: "registered_images",
                    subtitle: "已注册相机",
                    pattern: "((?:\\d[\\d,]*)\\s*/\\s*(?:\\d[\\d,]*))\\s*张图已注册到稀疏模型",
                    in: source
                )
            ]
        }

        parsedMetrics.compactMap { $0 }.forEach { metric in
            if !metrics.contains(where: { $0.id == metric.id }) {
                metrics.append(metric)
            }
        }

        if allowsTrainingMetrics,
           !metrics.contains(where: { $0.id == "training_progress_percent" }),
           let fraction = trainingRuntimeRatioValue ?? currentStepProgressFraction {
            let percent = Int((min(max(fraction, 0.0), 1.0) * 100.0).rounded())
            metrics.append(
                WorkflowActivityMetric(
                    id: "training_progress_percent",
                    title: "\(percent)%",
                    subtitle: "训练阶段进度"
                )
            )
        }

        if metrics.isEmpty,
           let genericRatio = liveStepMetricsText {
            metrics.append(
                WorkflowActivityMetric(
                    id: "generic_progress_metric",
                    title: genericRatio,
                    subtitle: "当前工作计数"
                )
            )
        }

        return metrics
    }

    private var structuredPhaseMetric: WorkflowActivityMetric? {
        let currentUnits = runtimeMetricInt("current_units")
        let targetUnits = runtimeMetricInt("target_units")
        let selectedFrames = runtimeMetricInt("selected_frames")
        let registeredImages = runtimeMetricInt("registered_images")
        let basis = normalizedProgressBasis

        switch effectiveWorkflowStatus {
        case .training, .localFallback:
            guard basis == "runtime_tqdm_steps" || (basis == "runtime_budget" && isAuthoritativeTrainingRuntime) else { return nil }
        case .packaging, .downloading:
            guard basis == "runtime_render_count" else { return nil }
        case .reconstructing:
            guard basis == nil
                || (basis?.hasPrefix("prep_") ?? false)
                || (basis == "runtime_budget" && isAuthoritativePreprocessRuntime)
            else { return nil }
        case .uploading:
            if !hasStreamingPreprocessing {
                return nil
            }
        case .preparing, .queued, .completed, .cancelled, .failed:
            return nil
        }

        if let registeredImages, let selectedFrames, selectedFrames > 0 {
            return Self.metricRatioValue(
                id: "registered_images",
                subtitle: "已注册相机",
                current: registeredImages,
                total: selectedFrames,
                unit: "张图"
            )
        }

        guard let currentUnits, let targetUnits, targetUnits > 0 else { return nil }
        let unitLabel = runtimeMetricString("unit_label")
        guard let basis else { return nil }

        switch basis {
        case "prep_feature_images":
            return Self.metricRatioValue(
                id: "feature_images",
                subtitle: "已提特征",
                current: currentUnits,
                total: targetUnits,
                unit: unitLabel
            )
        case "prep_match_pairs":
            return Self.metricRatioValue(
                id: "matched_pairs",
                subtitle: "已匹配视角组",
                current: currentUnits,
                total: targetUnits,
                unit: unitLabel
            )
        case "prep_mapper_registered_images", "prep_live_sfm_ready":
            return Self.metricRatioValue(
                id: "registered_images",
                subtitle: "已注册相机",
                current: currentUnits,
                total: targetUnits,
                unit: unitLabel
            )
        case "prep_runtime_budget":
            return Self.metricRatioValue(
                id: "preprocess_progress",
                subtitle: "预处理阶段",
                current: currentUnits,
                total: targetUnits,
                unit: unitLabel
            )
        case "runtime_tqdm_steps":
            return Self.metricRatioValue(
                id: "training_steps",
                subtitle: "训练步数",
                current: currentUnits,
                total: targetUnits,
                unit: unitLabel
            )
        case "runtime_budget":
            if isAuthoritativeTrainingRuntime {
                return Self.metricRatioValue(
                    id: "training_steps",
                    subtitle: "训练步数",
                    current: currentUnits,
                    total: targetUnits,
                    unit: unitLabel
                )
            }
            if isAuthoritativePreprocessRuntime {
                return Self.metricRatioValue(
                    id: "preprocess_progress",
                    subtitle: "预处理阶段",
                    current: currentUnits,
                    total: targetUnits,
                    unit: unitLabel
                )
            }
            return nil
        case "runtime_render_count":
            return Self.metricRatioValue(
                id: "render_count",
                subtitle: "导出渲染",
                current: currentUnits,
                total: targetUnits,
                unit: unitLabel
            )
        default:
            return nil
        }
    }

    public var lastUpdatedRelativeText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        switch seconds {
        case ..<2:
            return "刚刚更新"
        case 2..<60:
            return "\(seconds) 秒前更新"
        case 60..<3600:
            return "\(max(1, seconds / 60)) 分钟前更新"
        default:
            return "\(max(1, seconds / 3600)) 小时前更新"
        }
    }

    private var effectiveProcessingElapsedSeconds: TimeInterval? {
        // Filesystem-recovered records do not have an authoritative
        // end-to-end processing clock, so never surface stale persisted
        // elapsed values from older app builds.
        if isFilesystemRecoveredRecord {
            return nil
        }

        if let processingElapsedSeconds, processingElapsedSeconds > 0 {
            return processingElapsedSeconds
        }

        let start = processingStartedAt ?? createdAt

        if isProcessingDurationFinalized {
            if let processingCompletedAt {
                return max(0, processingCompletedAt.timeIntervalSince(start))
            }
            if updatedAt >= start {
                return max(0, updatedAt.timeIntervalSince(start))
            }
        }

        if isProcessing || normalizedFailureReason == "cancel_requested_unconfirmed" {
            return max(0, Date().timeIntervalSince(start))
        }

        if let elapsedSeconds = runtimeMetricInt("elapsed_seconds"), elapsedSeconds > 0 {
            return TimeInterval(elapsedSeconds)
        }

        return nil
    }

    private var isFilesystemRecoveredRecord: Bool {
        let normalizedStatusMessage = statusMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedStatusMessage == "已从本地恢复作品"
            || normalizedStatusMessage == "已从本地恢复历史素材"
    }

    private var isProcessingDurationFinalized: Bool {
        switch status {
        case .completed, .failed:
            return true
        case .cancelled:
            return normalizedFailureReason != "cancel_requested_unconfirmed"
                && normalizedFailureReason != "cancel_requested"
        default:
            return false
        }
    }

    public var liveStepTitle: String {
        if isInspectionOnlyCandidate {
            return "候选结果待质检"
        }
        if isLocalPreviewWorkflow {
            switch status {
            case .completed:
                return "本地处理已完成"
            case .failed:
                return "本地处理失败了"
            case .cancelled:
                return failureReason == "stale_local_processing_frozen"
                    ? "旧本地任务已取消"
                    : "本地处理已取消"
            default:
                return localPreviewPhase?.title ?? "正在生成本地结果"
            }
        }
        switch effectiveWorkflowStatus {
        case .preparing:
            return localPreparationStepTitle
        case .uploading:
            if isUploadFinalizing {
                return "正在确认上传"
            }
            if hasStreamingPreprocessing {
                return preprocessingActivityTitle
            }
            if let basis = normalizedProgressBasis {
                switch basis {
                case "upload_bytes", "chunked_upload_bytes":
                    return "正在上传视频"
                case "upload_aborted":
                    return "上传已中断"
                case "created":
                    return "正在创建任务"
                case "object_storage_visible":
                    return "对象存储已收到视频"
                case "control_plane_upload_complete", "upload_complete", "multipart_upload_complete":
                    return "上传完成，正在等待调度"
                default:
                    break
                }
            }
            return "正在上传视频"
        case .queued:
            if normalizedProgressBasis == "prep_ready_waiting_gpu" {
                return "预处理完成，正在等待 GPU"
            }
            return "上传完成，正在等待 GPU 接手"
        case .reconstructing:
            return preprocessingActivityTitle
        case .training, .localFallback:
            return trainActivityTitle
        case .packaging:
            return returnActivityTitle
        case .downloading:
            return returnActivityTitle
        case .completed:
            return "结果已回到手机"
        case .cancelled:
            return "这次任务已取消"
        case .failed:
            return "这次任务失败了"
        }
    }

    public var liveStepMetricsText: String? {
        if let structuredPhaseMetric {
            return structuredPhaseMetric.title
        }
        let source = normalizedLiveDetailSource
        guard !source.isEmpty else { return nil }

        if let extracted = Self.firstCapture(
            pattern: "（([^）]*\\d+\\s*/\\s*\\d+[^）]*)）",
            in: source
        ) {
            return extracted
        }

        if let extracted = Self.firstCapture(
            pattern: "\\(([^)]*\\d+\\s*/\\s*\\d+[^)]*)\\)",
            in: source
        ) {
            return extracted
        }

        if let wholeMatch = Self.firstMatch(
            pattern: "\\d[\\d,]*\\s*/\\s*\\d[\\d,]*(?:\\s*[\\p{Han}A-Za-z]+)?",
            in: source
        ) {
            return wholeMatch
        }

        return nil
    }

    public var displayStepMetricsText: String? {
        if effectiveWorkflowStatus == .preparing, let localPreparationProgressPercent {
            return "\(localPreparationProgressPercent)%"
        }
        if isUploadFinalizing {
            return nil
        }
        if isPreprocessAwaitingFirstDecodableFrame,
           let metricText = preprocessAwaitingFirstFrameMetricText {
            return metricText
        }
        if let structuredPhaseMetric {
            return "\(structuredPhaseMetric.subtitle) \(structuredPhaseMetric.title)"
        }
        if let primaryMetric = liveProgressMetrics.first(where: { $0.id != "upload_speed" && $0.id != "upload_bytes" }),
           primaryMetric.subtitle != "当前工作计数" {
            return "\(primaryMetric.subtitle) \(primaryMetric.title)"
        }
        if hasReliableCurrentStepUpperBound {
            return liveStepMetricsText
        }

        guard let ratio = currentStepActualRatio else {
            return liveStepMetricsText
        }

        let value = Self.countString(ratio.current)
        if let unit = inferredMetricUnit, !unit.isEmpty {
            return "已处理 \(value) \(unit)"
        }
        return "已处理 \(value)"
    }

    public var currentStepProgressFraction: Double? {
        if isLocalPreviewWorkflow,
           let phase = localPreviewPhase {
            let start = phase.startFraction
            let end: Double = {
                if phase == .export {
                    return 1.0
                }
                let nextIndex = localPreviewPhaseIndex(phase) + 1
                if nextIndex < localWorkflowPhases.count {
                    return localWorkflowPhases[nextIndex].startFraction
                }
                return 1.0
            }()
            return segmentProgress(from: progressFraction, start: start, end: end)
        }
        let displayStatus = effectiveWorkflowStatus

        if displayStatus == .preparing {
            if let localPreparationProgressPercent {
                return min(max(Double(localPreparationProgressPercent) / 100.0, 0.0), 1.0)
            }
            return segmentProgress(from: progressFraction, start: 0.0, end: 0.04)
        }
        if displayStatus == .uploading {
            if isUploadFinalizing {
                return nil
            }
            guard
                let uploadedBytes,
                let totalBytes,
                totalBytes > 0
            else {
                return nil
            }
            return min(max(Double(uploadedBytes) / Double(totalBytes), 0.0), 1.0)
        }

        switch displayStatus {
        case .reconstructing:
            if let preprocessOverallProgressFraction {
                return preprocessOverallProgressFraction
            }
        case .training, .localFallback:
            if isAuthoritativeGpuWaitRuntime {
                return preprocessOverallProgressFraction
            }
            if let trainingRuntimeRatioValue {
                return trainingRuntimeRatioValue
            }
            return segmentProgress(from: progressFraction, start: 0.58, end: 0.90)
        case .packaging, .downloading:
            if let returnRuntimeRatioValue {
                return returnRuntimeRatioValue
            }
            return segmentProgress(from: progressFraction, start: 0.90, end: 1.0)
        default:
            break
        }

        guard hasReliableCurrentStepUpperBound else {
            return nil
        }

        guard let metrics = liveStepMetricsText,
              let parsed = Self.parseRatio(from: metrics) else {
            return nil
        }
        return min(max(parsed.current / parsed.total, 0.0), 1.0)
    }

    public var currentStepProgressPercentText: String? {
        guard let currentStepProgressFraction else { return nil }
        return String(format: "%.1f%%", currentStepProgressFraction * 100.0)
    }

    public var workflowStatusSummaryLine: String {
        let overall = workflowOverallPercentText.map { "总链路 \($0)" } ?? "总链路处理中"
        if activeWorkflowTrackTitles.count > 1 {
            let tracks = activeWorkflowTrackTitles.joined(separator: " + ")
            if let uploadProgressText {
                return "\(overall) · \(tracks)｜\(uploadProgressText)"
            }
            return "\(overall) · \(tracks)"
        }
        if let uploadProgressText {
            return "\(overall) · \(uploadProgressText)"
        }
        return "\(overall) · \(liveStepTitle)"
    }

    public var currentStepEtaText: String? {
        guard shouldShowEstimatedRemaining,
              let estimatedRemainingMinutes else {
            return nil
        }
        return estimatedRemainingMinutes == 0 ? "不到 1 分钟" : "约 \(estimatedRemainingMinutes) 分钟"
    }

    public var estimatedRemainingSummaryText: String? {
        guard shouldShowEstimatedRemaining,
              let estimatedRemainingMinutes else {
            return nil
        }
        return estimatedRemainingMinutes == 0 ? "不到 1 分钟" : "\(estimatedRemainingMinutes) 分钟"
    }

    public var presentableDetailMessage: String? {
        if isLocalPreviewWorkflow {
            return detailMessage ?? localPreviewPhase?.detailMessage
        }
        if effectiveWorkflowStatus == .preparing {
            return localPreparationDetailText
        }
        let detail = normalizedLiveDetailSource
        if isUploadFinalizing {
            if !detail.isEmpty {
                return detail
            }
            return "所有分片已发送，正在等待服务器确认并完成合并。"
        }
        guard !detail.isEmpty else { return nil }

        if hasReliableCurrentStepUpperBound || effectiveWorkflowStatus == .uploading {
            return detail
        }

        if let displayStepMetricsText {
            return "\(liveStepTitle)。\(displayStepMetricsText)。"
        }

        return detail
    }

    public var hasReliableCurrentStepUpperBound: Bool {
        if isLocalPreviewWorkflow {
            return localPreviewPhase != nil
        }
        let displayStatus = effectiveWorkflowStatus

        if displayStatus == .preparing {
            return localPreparationProgressPercent != nil || progressFraction != nil
        }
        if displayStatus == .uploading {
            if isUploadFinalizing {
                return false
            }
            guard let totalBytes else { return false }
            return totalBytes > 0
        }

        if let targetUnits = runtimeMetricInt("target_units") {
            return targetUnits > 0
        }

        guard let basis = normalizedProgressBasis else {
            return false
        }

        switch basis {
        case "upload_bytes",
             "prep_extract_frames",
             "prep_feature_images",
             "prep_mapper_registered_images",
             "runtime_tqdm_steps":
            return true
        case "prep_match_pairs",
             "prep_runtime_budget",
             "runtime_budget",
             "runtime_render_count",
             "worker_assigned",
             "prep_ready_waiting_gpu",
             "created",
             "stage_only",
             "object_storage_visible",
             "control_plane_upload_complete",
             "upload_complete",
             "multipart_upload_complete",
             "active_worker_without_runtime":
            return false
        default:
            if basis.contains("budget") || basis.contains("match_pairs") || basis.contains("mapper_registered_images") {
                return false
            }
            if basis.contains("render_count") || basis.contains("assigned") || basis.contains("waiting") {
                return false
            }
            if basis.contains("bytes") || basis.contains("frames") || basis.contains("feature_images") {
                return true
            }
            if basis.contains("tqdm_steps") {
                return true
            }
            return false
        }
    }

    public var shouldShowEstimatedRemaining: Bool {
        guard estimatedRemainingMinutes != nil else { return false }
        if isUploadFinalizing {
            return false
        }
        if effectiveWorkflowStatus == .uploading {
            return true
        }
        return hasReliableCurrentStepUpperBound
    }

    public var waitingHeadlineText: String {
        if isLocalPreviewWorkflow {
            return workflowModeTitle
        }
        if activeWorkflowTrackTitles.count > 1 {
            return workflowModeTitle
        }
        if effectiveWorkflowStatus == .preparing {
            return localPreparationStepTitle
        }
        if normalizedProgressBasis == "stage_only" {
            return workflowModeTitle
        }
        return liveStepTitle
    }

    private static func normalized(_ value: Double?, for status: ScanRecordStatus) -> Double? {
        switch status {
        case .completed:
            return 1.0
        case .failed:
            if let value {
                return max(0.0, min(1.0, value))
            }
            return nil
        case .cancelled:
            if let value {
                return max(0.0, min(1.0, value))
            }
            return nil
        default:
            guard let value else { return nil }
            return max(0.0, min(0.99, value))
        }
    }

    public static func defaultStatusMessage(for status: ScanRecordStatus) -> String {
        switch status {
        case .preparing:
            return "正在整理拍摄素材"
        case .uploading:
            return "正在上传到对象存储"
        case .queued:
            return "后台已接收任务，正在等待 GPU"
        case .reconstructing:
            return "远端正在预处理并准备重建"
        case .training:
            return "远端正在生成 HQ 3D 成品"
        case .packaging:
            return "正在处理 HQ 3D 成品"
        case .downloading:
            return "正在回传 HQ 3D 成品到手机"
        case .localFallback:
            return "远端不可用，正在切到本地处理"
        case .completed:
            return "HQ 成品已生成，可交互查看"
        case .cancelled:
            return "你已取消这次远端任务"
        case .failed:
            return "这次生成失败了"
        }
    }

    private static func rateString(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000_000 {
            return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000.0)
        }
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000.0)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000.0)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    /// Default name: "扫描 YYYY-MM-DD HH:mm"
    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "扫描 \(formatter.string(from: date))"
    }

    private static func byteString(_ bytes: Int64) -> String {
        if bytes <= 0 {
            return "0 KB"
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var normalizedLiveDetailSource: String {
        let candidates = [detailMessage, statusMessage]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private var normalizedProgressBasis: String? {
        OnDeviceProcessingCompatibility.normalizedProgressBasis(progressBasis)
    }

    private var effectiveWorkflowStatus: ScanRecordStatus {
        if isLocalPreviewWorkflow {
            switch status {
            case .completed, .cancelled, .failed:
                return status
            default:
                if localPreviewPhase == .export {
                    return .packaging
                }
                return .training
            }
        }
        switch status {
        case .completed, .cancelled, .failed:
            return status
        default:
            break
        }

        if status == .preparing {
            return .preparing
        }

        if let basis = normalizedProgressBasis {
            switch basis {
            case "prepare_inspecting_source",
                 "prepare_remuxing_container",
                 "prepare_verifying_output",
                 "prepare_ready_for_upload":
                return .preparing
            case "created",
                 "upload_bytes",
                 "chunked_upload_bytes",
                 "chunk_part_uploaded",
                 "object_storage_visible",
                 "upload_finalizing",
                 "control_plane_upload_complete",
                 "upload_complete",
                 "multipart_upload_complete",
                 "chunked_upload_complete",
                 "worker_assigned",
                 "worker_assigned_streaming_input",
                 "prep_stream_probe_live",
                 "prep_extract_frames_live",
                 "prep_audit_live",
                 "prep_live_sfm_wait_frames",
                 "prep_live_sfm_retry_wait":
                return .uploading
            case "prep_live_sfm_ready":
                return isUploadStillOpenOnBackend ? .uploading : .reconstructing
            case "prep_extract_frames",
                 "prep_feature_images",
                 "prep_match_pairs",
                 "prep_mapper_registered_images",
                 "prep_runtime_budget",
                 "active_worker_without_runtime":
                return .reconstructing
            case "prep_ready_waiting_gpu":
                return .queued
            case "runtime_tqdm_steps":
                if isTrainingProbeRuntime {
                    return .reconstructing
                }
                return .training
            case "runtime_budget":
                if isTrainingProbeRuntime {
                    return .reconstructing
                }
                if isAuthoritativeTrainingRuntime {
                    return .training
                }
                if isAuthoritativeReturnRuntime {
                    return .packaging
                }
                if isAuthoritativePreprocessRuntime {
                    return .reconstructing
                }
                break
            case "download_bytes":
                return .downloading
            case "runtime_render_count":
                return .packaging
            default:
                break
            }
        }

        if let phase = normalizedRemotePhaseName {
            switch phase {
            case "streaming_input",
                 "stream_probe_live",
                 "extract_frames_live",
                 "audit_live",
                 "sfm_wait_live",
                 "live_sfm_retry_wait":
                return .uploading
            case "live_sfm_ready",
                 "feature_extractor",
                 "matcher",
                 "mapper":
                return .reconstructing
            default:
                break
            }
        }

        if let stage = normalizedRemoteStageKey {
            switch stage {
            case "curate",
                 "slam3r_reconstruct",
                 "slam3r_scene_contract",
                 "sfm",
                 "sfm_extract",
                 "sfm_match",
                 "sfm_reconstruct":
                return .reconstructing
            case "sparse2dgs_surface",
                 "train":
                return .training
            case "matcha_mesh_extract",
                 "optimize_default_mesh",
                 "bake_default_texture",
                 "publish_default_mesh",
                 "artifact_upload",
                 "render",
                 "export",
                 "package",
                 "packaging":
                return .packaging
            case "download", "downloading":
                return .downloading
            default:
                break
            }
        }

        return status
    }

    private var isAuthoritativeTrainingRuntime: Bool {
        if let stage = normalizedRemoteStageKey {
            if stage == "sparse2dgs_surface" {
                return true
            }
            if (stage == "train" || stage.hasPrefix("train")) && normalizedRemotePhaseName == "full" {
                return true
            }
        }
        return normalizedRemotePhaseName == "full"
    }

    private var isTrainingProbeRuntime: Bool {
        if let stage = normalizedRemoteStageKey,
           (stage == "train" || stage.hasPrefix("train")) && normalizedRemotePhaseName == "probe" {
            return true
        }
        return normalizedRemotePhaseName == "probe"
    }

    private var isAuthoritativeReturnRuntime: Bool {
        if let stage = normalizedRemoteStageKey {
            switch stage {
            case "matcha_mesh_extract",
                 "optimize_default_mesh",
                 "bake_default_texture",
                 "publish_default_mesh",
                 "artifact_upload",
                 "render",
                 "export",
                 "package",
                 "packaging",
                 "download",
                 "downloading":
                return true
            default:
                break
            }
        }
        return normalizedProgressBasis == "runtime_render_count"
            || normalizedProgressBasis == "download_bytes"
    }

    private var isAuthoritativePreprocessRuntime: Bool {
        if let basis = normalizedProgressBasis,
           basis.hasPrefix("prep_") || basis == "active_worker_without_runtime" {
            return true
        }
        if let stage = normalizedRemoteStageKey,
           stage == "curate"
            || stage == "slam3r_reconstruct"
            || stage == "slam3r_scene_contract"
            || stage == "sfm"
            || stage == "sfm_extract"
            || stage == "sfm_match"
            || stage == "sfm_reconstruct" {
            return true
        }
        if let phase = normalizedRemotePhaseName,
           phase == "feature_extractor"
            || phase == "matcher"
            || phase == "mapper"
            || phase == "audit"
            || phase == "prep"
            || phase == "prep_complete"
            || phase == "probe" {
            return true
        }
        return false
    }

    private var isAuthoritativePostUploadStage: Bool {
        if let stage = normalizedRemoteStageKey {
            switch stage {
            case "curate",
                 "slam3r_reconstruct",
                 "slam3r_scene_contract",
                 "sparse2dgs_surface",
                 "matcha_mesh_extract",
                 "optimize_default_mesh",
                 "bake_default_texture",
                 "publish_default_mesh",
                 "artifact_upload",
                 "render",
                 "export",
                 "package",
                 "packaging",
                 "download",
                 "downloading":
                return true
            default:
                if stage == "train" || stage.hasPrefix("train") {
                    return true
                }
            }
        }
        return false
    }

    private var normalizedFailureReason: String? {
        OnDeviceProcessingCompatibility.normalizedFailureReason(failureReason)
    }

    private var currentStepActualRatio: (current: Double, total: Double)? {
        guard let metrics = liveStepMetricsText else { return nil }
        return Self.parseRatio(from: metrics)
    }

    private var inferredMetricUnit: String? {
        let source = normalizedLiveDetailSource
        if source.contains("组视角") {
            return "组视角"
        }
        if source.contains("张图") {
            return "张图"
        }
        if source.contains("帧") {
            return "帧"
        }
        if source.contains("步") {
            return "步"
        }
        return nil
    }

    private func milestoneState(for milestoneID: String) -> WorkflowMilestoneState {
        if isLocalPreviewWorkflow,
           let phase = LocalPreviewWorkflowPhase(rawValue: milestoneID) {
            return localPreviewMilestoneState(for: phase)
        }
        switch milestoneID {
        case "prepare":
            if isPrepareTrackActive { return .active }
            if isPrepareTrackCompleted { return .completed }
            return .pending
        case "upload":
            if isUploadTrackActive { return .active }
            if isUploadTrackCompleted { return .completed }
            return .pending
        case "preprocess":
            if isPreprocessTrackActive { return .active }
            if isPreprocessTrackCompleted { return .completed }
            return .pending
        case "train":
            if isTrainTrackActive { return .active }
            if isTrainTrackCompleted { return .completed }
            return .pending
        case "return":
            if isReturnTrackActive { return .active }
            if isReturnTrackCompleted { return .completed }
            return .pending
        default:
            return .pending
        }
    }

    private func workflowStepProgress(id: String, title: String) -> WorkflowStepProgress {
        let state = milestoneState(for: id)
        return WorkflowStepProgress(
            id: id,
            title: title,
            state: state,
            progressFraction: workflowStepFraction(for: id, state: state),
            progressText: workflowStepProgressText(for: id, state: state),
            detailText: workflowStepDetailText(for: id, state: state)
        )
    }

    private func workflowStepFraction(for id: String, state: WorkflowMilestoneState) -> Double {
        if isLocalPreviewWorkflow,
           let phase = LocalPreviewWorkflowPhase(rawValue: id) {
            switch state {
            case .pending:
                return 0.0
            case .completed:
                return 1.0
            case .active:
                if let nextPhase = localWorkflowPhases.drop(while: { $0 != phase }).dropFirst().first,
                   let fraction = segmentProgress(from: progressFraction, start: phase.startFraction, end: nextPhase.startFraction) {
                    return max(fraction, 0.10)
                }
                if phase == .export,
                   let fraction = segmentProgress(from: progressFraction, start: LocalPreviewWorkflowPhase.export.startFraction, end: 1.0) {
                    return max(fraction, 0.10)
                }
                return 0.10
            }
        }
        switch state {
        case .pending:
            return 0.0
        case .completed:
            return 1.0
        case .active:
            break
        }

        switch id {
        case "prepare":
            if let localPreparationProgressPercent {
                return min(max(Double(localPreparationProgressPercent) / 100.0, 0.0), 1.0)
            }
            return max(segmentProgress(from: progressFraction, start: 0.0, end: 0.04) ?? 0.18, 0.08)
        case "upload":
            if uploadCompletedOnBackend {
                return 1.0
            }
            if let uploadedBytes,
               let totalBytes,
               totalBytes > 0 {
                return min(max(Double(uploadedBytes) / Double(totalBytes), 0.0), 1.0)
            }
            if let completedPartCount = runtimeMetricInt("completed_part_count"),
               let totalChunks = runtimeMetricInt("total_chunks"),
               totalChunks > 0 {
                return min(max(Double(completedPartCount) / Double(totalChunks), 0.0), 1.0)
            }
            return max(segmentProgress(from: progressFraction, start: 0.04, end: 0.24) ?? 0.12, 0.08)
        case "preprocess":
            if let ratio = preprocessOverallProgressFraction {
                return ratio
            }
            if let extractedFrames = runtimeMetricInt("extracted_frames") {
                return min(max(Double(extractedFrames) / 200.0, 0.0), 0.9)
            }
            if let acceptedLiveFrames = runtimeMetricInt("accepted_live_frames") {
                return min(max(Double(acceptedLiveFrames) / 200.0, 0.0), 0.92)
            }
            switch normalizedProgressBasis {
            case "worker_assigned_streaming_input":
                return 0.10
            case "prep_stream_probe_live":
                return 0.16
            case "prep_extract_frames_live":
                return 0.24
            case "prep_audit_live":
                return 0.32
            case "prep_live_sfm_wait_frames":
                return 0.40
            case "prep_live_sfm_retry_wait":
                return 0.56
            case "prep_live_sfm_ready":
                return 0.72
            case "prep_extract_frames":
                return 0.18
            case "prep_feature_images":
                return 0.38
            case "prep_match_pairs":
                return 0.58
            case "prep_mapper_registered_images":
                return 0.78
            default:
                return max(segmentProgress(from: progressFraction, start: 0.24, end: 0.58) ?? 0.14, 0.10)
            }
        case "train":
            if isAuthoritativeGpuWaitRuntime {
                return 0.0
            }
            if let ratio = trainingRuntimeRatioValue {
                return ratio
            }
            return max(segmentProgress(from: progressFraction, start: 0.58, end: 0.90) ?? 0.12, 0.10)
        case "return":
            if let ratio = returnRuntimeRatioValue {
                return ratio
            }
            return max(segmentProgress(from: progressFraction, start: 0.90, end: 1.0) ?? 0.12, 0.10)
        default:
            return 0.0
        }
    }

    private func workflowStepProgressText(for id: String, state: WorkflowMilestoneState) -> String {
        if isLocalPreviewWorkflow,
           let phase = LocalPreviewWorkflowPhase(rawValue: id) {
            switch state {
            case .pending:
                return "等待开始"
            case .completed:
                return phase.completedProgressText
            case .active:
                if let metric = localPreviewPhaseMetricText(for: phase) {
                    return metric
                }
                if let percent = currentStepProgressPercentText {
                    return percent
                }
                return "进行中"
            }
        }
        switch state {
        case .pending:
            return "等待开始"
        case .completed:
            return "已完成"
        case .active:
            break
        }

        switch id {
        case "prepare":
            if let localPreparationProgressPercent {
                return "\(localPreparationProgressPercent)%"
            }
            return currentStepProgressPercentText ?? "整理中"
        case "upload":
            if isUploadFinalizing {
                return "确认中"
            }
            if let uploadProgressText {
                return uploadProgressText
            }
            if let currentStepProgressPercentText {
                return currentStepProgressPercentText
            }
            return "上传中"
        case "preprocess":
            if isPreprocessAwaitingFirstDecodableFrame {
                if let metricText = preprocessAwaitingFirstFrameMetricText,
                   let percentText = preprocessProgressPercentTextValue {
                    return "\(metricText) · \(percentText)"
                }
                if let metricText = preprocessAwaitingFirstFrameMetricText {
                    return metricText
                }
                if let percentText = preprocessProgressPercentTextValue {
                    return "识别中 · \(percentText)"
                }
                return "识别中"
            }
            if let ratioText = preprocessRuntimeRatioTextValue,
               let percentText = preprocessProgressPercentTextValue {
                return "\(ratioText) · \(percentText)"
            }
            if let ratioText = preprocessRuntimeRatioTextValue {
                return ratioText
            }
            if let extractedFrames = runtimeMetricInt("extracted_frames") {
                return "\(Self.countString(Double(extractedFrames))) 帧"
            }
            if let acceptedLiveFrames = runtimeMetricInt("accepted_live_frames") {
                return "\(Self.countString(Double(acceptedLiveFrames))) 帧"
            }
            if let percentText = preprocessProgressPercentTextValue {
                return percentText
            }
            return overlapPreprocessingTitle ?? "处理中"
        case "train":
            if let ratioText = trainingRuntimeRatioTextValue,
               let percentText = trainingProgressPercentTextValue {
                return "\(ratioText) · \(percentText)"
            }
            if let ratioText = trainingRuntimeRatioTextValue {
                return ratioText
            }
            if let percentText = trainingProgressPercentTextValue {
                return percentText
            }
            return currentStepProgressPercentText ?? trainActivityTitle
        case "return":
            if let ratioText = returnRuntimeRatioTextValue,
               let percentText = returnProgressPercentTextValue {
                return "\(ratioText) · \(percentText)"
            }
            if let ratioText = returnRuntimeRatioTextValue {
                return ratioText
            }
            if let percentText = returnProgressPercentTextValue {
                return percentText
            }
            return returnActivityTitle
        default:
            return "进行中"
        }
    }

    private func workflowStepDetailText(for id: String, state: WorkflowMilestoneState) -> String? {
        if isLocalPreviewWorkflow,
           let phase = LocalPreviewWorkflowPhase(rawValue: id) {
            switch state {
            case .pending, .completed:
                return nil
            case .active:
                var fragments: [String] = [phase.detailMessage]
                if let metric = localPreviewPhaseMetricText(for: phase) {
                    fragments.append(metric)
                }
                return fragments.joined(separator: " · ")
            }
        }
        switch state {
        case .pending, .completed:
            return nil
        case .active:
            break
        }

        switch id {
        case "prepare":
            if let localPreparationProgressPercent,
               let detail = localPreparationDetailText {
                return "\(detail) · 已完成 \(localPreparationProgressPercent)%"
            }
            return localPreparationDetailText
        case "upload":
            if let uploadSpeedText {
                return "当前上传速度 \(uploadSpeedText)"
            }
            return isUploadFinalizing ? "所有分片已发出，正在等待服务器确认。" : "手机正在把视频直接发到对象存储。"
        case "preprocess":
            if isPreprocessAwaitingFirstDecodableFrame {
                if let metricText = preprocessAwaitingFirstFrameMetricText {
                    if let overlapPreprocessingTitle {
                        return "\(metricText) · \(overlapPreprocessingTitle) · 等待首批可解码帧"
                    }
                    return "\(metricText) · 等待首批可解码帧"
                }
                if let overlapPreprocessingTitle {
                    return "\(overlapPreprocessingTitle) · 等待首批可解码帧"
                }
                return "正在识别视频头，等待首批可解码帧。"
            }
            if hasStreamingPreprocessing {
                if let displayStepMetricsText {
                    return "\(displayStepMetricsText) · \(overlapPreprocessingTitle ?? preprocessingActivityTitle)"
                }
                return overlapPreprocessingTitle ?? preprocessingActivityTitle
            }
            if let displayStepMetricsText {
                return "\(displayStepMetricsText) · \(preprocessingActivityTitle)"
            }
            return preprocessingActivityTitle
        case "train":
            if let displayStepMetricsText,
               let percentText = trainingProgressPercentTextValue {
                return "\(displayStepMetricsText) · 已完成 \(percentText)"
            }
            if let displayStepMetricsText {
                return "\(displayStepMetricsText) · \(trainActivityTitle)"
            }
            if let percentText = trainingProgressPercentTextValue {
                return "已完成 \(percentText) · \(trainActivityTitle)"
            }
            return trainActivityTitle
        case "return":
            if let returnDisplayMetricsText,
               let percentText = returnProgressPercentTextValue {
                return "\(returnDisplayMetricsText) · 已完成 \(percentText)"
            }
            if let returnDisplayMetricsText {
                return "\(returnDisplayMetricsText) · \(returnActivityTitle)"
            }
            if let percentText = returnProgressPercentTextValue {
                return "已完成 \(percentText) · \(returnActivityTitle)"
            }
            return returnActivityTitle
        default:
            return nil
        }
    }

    private var uploadCompletedOnBackend: Bool {
        if let raw = runtimeMetricString("upload_completed")?.lowercased() {
            return raw == "true"
        }
        if isAuthoritativePostUploadStage {
            return true
        }
        if let stage = normalizedRemoteStageKey,
           stage == "train"
            || stage.hasPrefix("train")
            || stage == "render"
            || stage == "export"
            || stage == "package"
            || stage == "packaging"
            || stage == "download"
            || stage == "downloading" {
            return true
        }
        switch status {
        case .queued, .training, .packaging, .downloading, .completed:
            return true
        case .reconstructing, .localFallback:
            if let uploadedBytes, let totalBytes, totalBytes > 0 {
                return uploadedBytes >= totalBytes
            }
            return false
        default:
            return false
        }
    }

    private var preprocessRuntimeRatioValue: Double? {
        guard isPreprocessTrackActive || isPreprocessTrackCompleted else { return nil }
        if let registeredImages = runtimeMetricInt("registered_images"),
           let selectedFrames = runtimeMetricInt("selected_frames"),
           selectedFrames > 0 {
            return min(max(Double(registeredImages) / Double(selectedFrames), 0.0), 1.0)
        }
        guard let basis = normalizedProgressBasis,
              basis.hasPrefix("prep_"),
              let currentUnits = runtimeMetricInt("current_units"),
              let targetUnits = runtimeMetricInt("target_units"),
              targetUnits > 0 else {
            return nil
        }
        return min(max(Double(currentUnits) / Double(targetUnits), 0.0), 1.0)
    }

    private var preprocessOverallProgressFraction: Double? {
        guard isPreprocessTrackActive || isPreprocessTrackCompleted || normalizedProgressBasis == "prep_ready_waiting_gpu" else {
            return nil
        }

        let rawRatio = preprocessRuntimeRatioValue
        let key = normalizedPreprocessProgressKey

        switch key {
        case "worker_assigned_streaming_input":
            return 0.06
        case "prep_stream_probe_live":
            return weightedPreprocessProgress(rawRatio, range: 0.08...0.14, fallback: 0.10)
        case "prep_extract_frames_live":
            return weightedPreprocessProgress(rawRatio, range: 0.14...0.22, fallback: 0.18)
        case "prep_audit_live":
            return weightedPreprocessProgress(rawRatio, range: 0.22...0.32, fallback: 0.28)
        case "prep_live_sfm_wait_frames":
            return 0.36
        case "prep_live_sfm_retry_wait":
            return weightedPreprocessProgress(rawRatio, range: 0.36...0.46, fallback: 0.40)
        case "prep_live_sfm_ready":
            return weightedPreprocessProgress(rawRatio, range: 0.46...0.58, fallback: 0.52)
        case "prep_extract_frames":
            return weightedPreprocessProgress(rawRatio, range: 0.08...0.24, fallback: 0.16)
        case "prep_feature_images":
            return weightedPreprocessProgress(rawRatio, range: 0.24...0.42, fallback: 0.32)
        case "prep_match_pairs":
            return weightedPreprocessProgress(rawRatio, range: 0.42...0.78, fallback: 0.56)
        case "prep_mapper_registered_images":
            return weightedPreprocessProgress(rawRatio, range: 0.78...0.98, fallback: 0.84)
        case "prep_ready_waiting_gpu":
            return 1.0
        case "active_worker_without_runtime":
            return 0.05
        default:
            if let rawRatio {
                return rawRatio
            }
            return nil
        }
    }

    private var preprocessRuntimeRatioTextValue: String? {
        guard isPreprocessTrackActive || isPreprocessTrackCompleted else { return nil }
        if let registeredImages = runtimeMetricInt("registered_images"),
           let selectedFrames = runtimeMetricInt("selected_frames"),
           selectedFrames > 0 {
            return "\(registeredImages)/\(selectedFrames)"
        }
        guard let basis = normalizedProgressBasis,
              basis.hasPrefix("prep_"),
              let currentUnits = runtimeMetricInt("current_units"),
              let targetUnits = runtimeMetricInt("target_units"),
              targetUnits > 0 else {
            return nil
        }
        return "\(currentUnits)/\(targetUnits)"
    }

    private var isPreprocessAwaitingFirstDecodableFrame: Bool {
        guard isPreprocessTrackActive else { return false }
        guard let key = normalizedPreprocessProgressKey else { return false }
        guard key == "worker_assigned_streaming_input" || key == "prep_stream_probe_live" else {
            return false
        }
        let extractedFrames = runtimeMetricInt("extracted_frames") ?? 0
        return extractedFrames <= 0
    }

    private var preprocessAwaitingFirstFrameMetricText: String? {
        if let visibleChunkCount = runtimeMetricInt("visible_chunk_count"),
           let totalChunks = runtimeMetricInt("total_chunks"),
           totalChunks > 0 {
            return "已可见 \(visibleChunkCount)/\(totalChunks) 分片"
        }
        if let visibleBytes = runtimeMetricInt("visible_bytes"),
           visibleBytes > 0,
           let totalBytes,
           totalBytes > 0 {
            return "已可见 \(Self.byteString(Int64(visibleBytes))) / \(Self.byteString(totalBytes))"
        }
        if let uploadedBytes,
           uploadedBytes > 0,
           let totalBytes,
           totalBytes > 0 {
            return "已上传 \(Self.byteString(uploadedBytes)) / \(Self.byteString(totalBytes))"
        }
        return nil
    }

    private var normalizedPreprocessProgressKey: String? {
        if let basis = normalizedProgressBasis {
            switch basis {
            case "worker_assigned_streaming_input",
                 "prep_stream_probe_live",
                 "prep_extract_frames_live",
                 "prep_audit_live",
                 "prep_live_sfm_wait_frames",
                 "prep_live_sfm_retry_wait",
                 "prep_live_sfm_ready",
                 "prep_extract_frames",
                 "prep_feature_images",
                 "prep_match_pairs",
                 "prep_mapper_registered_images",
                 "prep_ready_waiting_gpu",
                 "active_worker_without_runtime":
                return basis
            default:
                break
            }
        }

        if let phase = normalizedRemotePhaseName {
            switch phase {
            case "streaming_input":
                return "worker_assigned_streaming_input"
            case "stream_probe_live":
                return "prep_stream_probe_live"
            case "extract_frames_live":
                return "prep_extract_frames_live"
            case "audit_live":
                return "prep_audit_live"
            case "sfm_wait_live":
                return "prep_live_sfm_wait_frames"
            case "live_sfm_retry_wait":
                return "prep_live_sfm_retry_wait"
            case "live_sfm_ready":
                return "prep_live_sfm_ready"
            case "feature_extractor":
                return "prep_feature_images"
            case "matcher":
                return "prep_match_pairs"
            case "mapper":
                return "prep_mapper_registered_images"
            default:
                break
            }
        }

        if let stage = normalizedRemoteStageKey {
            switch stage {
            case "sfm_extract":
                return "prep_feature_images"
            case "sfm_match":
                return "prep_match_pairs"
            case "sfm_reconstruct":
                return "prep_mapper_registered_images"
            default:
                break
            }
        }

        return nil
    }

    private func weightedPreprocessProgress(
        _ rawRatio: Double?,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        let clampedRatio = max(0.0, min(1.0, rawRatio ?? fallback))
        let resolvedFallback = max(range.lowerBound, min(range.upperBound, fallback))
        let effectiveRatio = rawRatio == nil ? (resolvedFallback - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001) : clampedRatio
        return range.lowerBound + effectiveRatio * (range.upperBound - range.lowerBound)
    }

    private static func percentText(for fraction: Double?) -> String? {
        guard let fraction else { return nil }
        let clamped = min(max(fraction, 0.0), 1.0)
        return String(format: "%.1f%%", clamped * 100.0)
    }

    private var preprocessProgressPercentTextValue: String? {
        Self.percentText(for: preprocessOverallProgressFraction)
    }

    private var trainingRuntimeRatioValue: Double? {
        guard isTrainTrackActive || isTrainTrackCompleted else { return nil }
        guard let basis = normalizedProgressBasis,
              basis == "runtime_tqdm_steps" || (basis == "runtime_budget" && isAuthoritativeTrainingRuntime),
              let currentUnits = runtimeMetricInt("current_units"),
              let targetUnits = runtimeMetricInt("target_units"),
              targetUnits > 0 else {
            return nil
        }
        return min(max(Double(currentUnits) / Double(targetUnits), 0.0), 1.0)
    }

    private var trainingProgressPercentTextValue: String? {
        if isAuthoritativeGpuWaitRuntime {
            return nil
        }
        return Self.percentText(
            for: trainingRuntimeRatioValue
                ?? segmentProgress(from: progressFraction, start: 0.58, end: 0.90)
        )
    }

    private var trainingRuntimeRatioTextValue: String? {
        if isAuthoritativeGpuWaitRuntime {
            return nil
        }
        guard isTrainTrackActive || isTrainTrackCompleted else { return nil }
        guard let basis = normalizedProgressBasis,
              basis == "runtime_tqdm_steps" || (basis == "runtime_budget" && isAuthoritativeTrainingRuntime),
              let currentUnits = runtimeMetricInt("current_units"),
              let targetUnits = runtimeMetricInt("target_units"),
              targetUnits > 0 else {
            return nil
        }
        return "\(currentUnits)/\(targetUnits)"
    }

    private var returnRuntimeRatioValue: Double? {
        guard isReturnTrackActive || isReturnTrackCompleted else { return nil }
        if normalizedRemoteStageKey == "optimize_default_mesh",
           let optimizeLocalProgressRatioValue {
            return optimizeLocalProgressRatioValue
        }
        if normalizedProgressBasis == "download_bytes" {
            if let downloadedBytes = runtimeMetricInt("downloaded_bytes"),
               let totalDownloadBytes = runtimeMetricInt("download_total_bytes"),
               totalDownloadBytes > 0 {
                return min(max(Double(downloadedBytes) / Double(totalDownloadBytes), 0.0), 1.0)
            }
            if let currentUnits = runtimeMetricInt("current_units"),
               let targetUnits = runtimeMetricInt("target_units"),
               targetUnits > 0 {
                return min(max(Double(currentUnits) / Double(targetUnits), 0.0), 1.0)
            }
            return nil
        }
        guard normalizedProgressBasis == "runtime_render_count",
              let currentUnits = runtimeMetricInt("current_units"),
              let targetUnits = runtimeMetricInt("target_units"),
              targetUnits > 0 else {
            return nil
        }
        return min(max(Double(currentUnits) / Double(targetUnits), 0.0), 1.0)
    }

    private var returnProgressPercentTextValue: String? {
        if normalizedProgressBasis == "download_bytes",
           returnRuntimeRatioValue == nil {
            return nil
        }
        return Self.percentText(
            for: returnRuntimeRatioValue
                ?? segmentProgress(from: progressFraction, start: 0.90, end: 1.0)
        )
    }

    private var returnRuntimeRatioTextValue: String? {
        guard isReturnTrackActive || isReturnTrackCompleted else { return nil }
        if normalizedRemoteStageKey == "optimize_default_mesh",
           let optimizeLocalProgressPercent {
            return "\(optimizeLocalProgressPercent)%"
        }
        if normalizedProgressBasis == "download_bytes" {
            if let downloadedBytes = runtimeMetricInt("downloaded_bytes"),
               let totalDownloadBytes = runtimeMetricInt("download_total_bytes"),
               totalDownloadBytes > 0 {
                return "\(Self.byteString(Int64(downloadedBytes))) / \(Self.byteString(Int64(totalDownloadBytes)))"
            }
            if let currentUnits = runtimeMetricInt("current_units"),
               let targetUnits = runtimeMetricInt("target_units"),
               targetUnits > 0 {
                return "\(currentUnits)/\(targetUnits)"
            }
            return nil
        }
        guard normalizedProgressBasis == "runtime_render_count",
              let currentUnits = runtimeMetricInt("current_units"),
              let targetUnits = runtimeMetricInt("target_units"),
              targetUnits > 0 else {
            return nil
        }
        return "\(currentUnits)/\(targetUnits)"
    }

    private var returnDisplayMetricsText: String? {
        guard isReturnTrackActive || isReturnTrackCompleted else { return nil }

        if normalizedRemoteStageKey == "optimize_default_mesh",
           let optimizeLocalProgressPercent {
            return "网格优化 \(optimizeLocalProgressPercent)%"
        }

        if let structuredPhaseMetric, structuredPhaseMetric.id == "render_count" {
            return "\(structuredPhaseMetric.subtitle) \(structuredPhaseMetric.title)"
        }

        if let metric = liveProgressMetrics.first(where: { metric in
            switch metric.id {
            case "render_count", "download_bytes", "download_chunks", "artifact_download_bytes", "artifact_download_chunks":
                return true
            default:
                return false
            }
        }) {
            return "\(metric.subtitle) \(metric.title)"
        }

        return nil
    }

    private var boundedRuntimeRatio: Double? {
        preprocessRuntimeRatioValue
            ?? trainingRuntimeRatioValue
            ?? returnRuntimeRatioValue
    }

    private var boundedRuntimeRatioText: String? {
        preprocessRuntimeRatioTextValue
            ?? trainingRuntimeRatioTextValue
            ?? returnRuntimeRatioTextValue
    }

    private var optimizeLocalProgressPercent: Int? {
        guard normalizedRemoteStageKey == "optimize_default_mesh" else { return nil }
        if let raw = runtimeMetricString("optimize_local_progress_percent")?.trimmingCharacters(in: .whitespacesAndNewlines),
           let doubleValue = Double(raw) {
            return Int(min(max(doubleValue.rounded(), 0), 100))
        }
        return nil
    }

    private var optimizeLocalProgressRatioValue: Double? {
        guard let optimizeLocalProgressPercent else { return nil }
        return min(max(Double(optimizeLocalProgressPercent) / 100.0, 0.0), 1.0)
    }

    private func segmentProgress(from value: Double?, start: Double, end: Double) -> Double? {
        guard let value else { return nil }
        guard end > start else { return nil }
        return min(max((value - start) / (end - start), 0.0), 1.0)
    }

    private static func firstCapture(pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: source) else {
            return nil
        }
        let value = String(source[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func firstMatch(pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, range: range),
              let wholeRange = Range(match.range(at: 0), in: source) else {
            return nil
        }
        let value = String(source[wholeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func metricRatio(
        id: String,
        subtitle: String,
        pattern: String,
        in source: String
    ) -> WorkflowActivityMetric? {
        guard let title = firstCapture(pattern: pattern, in: source) else { return nil }
        return WorkflowActivityMetric(
            id: id,
            title: title,
            subtitle: subtitle
        )
    }

    private static func metricCount(
        id: String,
        subtitle: String,
        pattern: String,
        in source: String,
        suffix: String = ""
    ) -> WorkflowActivityMetric? {
        guard let raw = firstCapture(pattern: pattern, in: source) else { return nil }
        let title = raw + suffix
        return WorkflowActivityMetric(
            id: id,
            title: title,
            subtitle: subtitle
        )
    }

    private static func metricCountValue(
        id: String,
        subtitle: String,
        value: Int,
        suffix: String = ""
    ) -> WorkflowActivityMetric {
        WorkflowActivityMetric(
            id: id,
            title: "\(countString(Double(value)))\(suffix)",
            subtitle: subtitle
        )
    }

    private static func metricRatioValue(
        id: String,
        subtitle: String,
        current: Int,
        total: Int,
        unit: String? = nil
    ) -> WorkflowActivityMetric {
        let unitSuffix = (unit?.isEmpty == false) ? " \(unit!)" : ""
        return WorkflowActivityMetric(
            id: id,
            title: "\(countString(Double(current))) / \(countString(Double(total)))\(unitSuffix)",
            subtitle: subtitle
        )
    }

    private static func durationMetricText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 {
            return "\(clamped) 秒"
        }
        let minutes = clamped / 60
        let remainingSeconds = clamped % 60
        if remainingSeconds == 0 {
            return "\(minutes) 分钟"
        }
        return "\(minutes) 分 \(remainingSeconds) 秒"
    }

    private static func clockDurationText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let remainingSeconds = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private static func parseRatio(from source: String) -> (current: Double, total: Double)? {
        guard let wholeMatch = firstMatch(
            pattern: "(\\d[\\d,]*)\\s*/\\s*(\\d[\\d,]*)",
            in: source
        ) else {
            return nil
        }

        let parts = wholeMatch
            .replacingOccurrences(of: ",", with: "")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard parts.count == 2,
              let current = Double(parts[0]),
              let total = Double(parts[1]),
              total > 0 else {
            return nil
        }
        return (current, total)
    }

    private static func countString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(format: "%.1f", value)
    }

    private static func progressBasisDisplayTitle(for basis: String) -> String {
        if let onDeviceTitle = OnDeviceProcessingCompatibility.progressBasisDisplayTitle(basis) {
            return onDeviceTitle
        }
        switch basis {
        case "prepare_inspecting_source":
            return "检查原视频"
        case "prepare_remuxing_container":
            return "重封装流式容器"
        case "prepare_verifying_output":
            return "校验整理结果"
        case "prepare_ready_for_upload":
            return "整理已完成"
        case "upload_bytes":
            return "上传字节进度"
        case "chunked_upload_bytes":
            return "上传字节进度"
        case "upload_aborted":
            return "上传已中断"
        case "upload_finalizing":
            return "上传收口确认"
        case "created":
            return "任务已创建"
        case "object_storage_visible":
            return "对象存储已可见"
        case "control_plane_upload_complete":
            return "控制平面已确认上传"
        case "upload_complete", "multipart_upload_complete", "chunked_upload_complete":
            return "上传已完成"
        case "worker_assigned":
            return "worker 已接单"
        case "worker_assigned_streaming_input":
            return "worker 已接单并流式接收"
        case "prep_stream_probe_live":
            return "流式头信息探测"
        case "prep_extract_frames_live":
            return "边上传边抽帧"
        case "prep_audit_live":
            return "边上传边整理关键帧"
        case "prep_live_sfm_wait_frames":
            return "等待足够帧后启动增量 SfM"
        case "prep_live_sfm_retry_wait":
            return "等待更多帧后刷新增量 SfM"
        case "prep_live_sfm_ready":
            return "增量 SfM 已拿到结果"
        case "prep_extract_frames":
            return "正式抽帧"
        case "prep_feature_images":
            return "特征提取"
        case "prep_match_pairs":
            return "相邻视角匹配"
        case "prep_mapper_registered_images":
            return "相机重建注册"
        case "prep_ready_waiting_gpu":
            return "预处理完成，等待 GPU"
        case "runtime_tqdm_steps":
            return "训练步数"
        case "runtime_budget":
            return "训练预算"
        case "runtime_render_count":
            return "导出渲染计数"
        case "stage_only":
            return "仅阶段心跳"
        case "active_worker_without_runtime":
            return "worker 活跃但尚无 runtime"
        default:
            return basis
        }
    }

    private static func failureReasonDisplayTitle(for reason: String) -> String {
        if reason.lowercased().hasPrefix(hqGateFailureReasonPrefix) {
            return "未达 HQ"
        }
        if let onDeviceTitle = OnDeviceProcessingCompatibility.failureReasonDisplayTitle(reason) {
            return onDeviceTitle
        }
        switch reason.lowercased() {
        case "timeout":
            return "远端超时"
        case "network_timeout":
            return "网络超时"
        case "upload_failed":
            return "上传已中断"
        case "api_error":
            return "后端异常"
        case "job_timeout":
            return "任务超时"
        case "download_failed":
            return "下载失败"
        case "invalid_response":
            return "响应异常"
        case "api_not_configured":
            return "后台未配置"
        case "input_invalid":
            return "输入无效"
        case "out_of_memory":
            return "内存不足"
        case "stalled_processing":
            return "处理卡住"
        case "unknown_error":
            return "未分类异常"
        case "copy_failed":
            return "本地落盘失败"
        case "cancel_requested":
            return "正在取消"
        case "cancel_requested_unconfirmed":
            return "取消待确认"
        case "cancelled_by_user":
            return "用户已取消"
        case "stale_local_processing_frozen":
            return "旧本地任务已冻结"
        case "stale_remote_processing_frozen":
            return "旧远端任务已冻结"
        default:
            return reason
        }
    }

    private static let hqGateFailureReasonPrefix = "hq_gate_failed"

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
}
