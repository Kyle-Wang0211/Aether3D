// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  GenerateResult.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

public enum GenerateResult: Sendable {
    case success(artifact: ArtifactRef, elapsedMs: Int)
    case fail(reason: FailReason, elapsedMs: Int)
}

public struct ArtifactRef: Sendable {
    public let localPath: URL
    public let format: ArtifactFormat
}

public enum ArtifactFormat: Sendable {
    case splat
    case splatPly
    case spz
}

public enum FailReason: String, Error, Sendable {
    case timeout = "timeout"
    case networkTimeout = "network_timeout"
    case uploadFailed = "upload_failed"
    case apiError = "api_error"
    case jobTimeout = "job_timeout"
    case downloadFailed = "download_failed"
    case invalidResponse = "invalid_response"
    case apiNotConfigured = "api_not_configured"
    case inputInvalid = "input_invalid"
    case outOfMemory = "out_of_memory"
    case stalledProcessing = "stalled_processing"
    case unknownError = "unknown_error"
}

public enum GenerateProgressStage: String, Codable, Sendable {
    case preparing
    case uploading
    case queued
    case reconstructing
    case training
    case packaging
    case downloading
    case localFallback
    case completed
    case failed
}

public struct GenerateProgressSnapshot: Codable, Sendable, Equatable {
    public let stage: GenerateProgressStage
    public let progressFraction: Double?
    public let progressBasis: String?
    public let remoteStageKey: String?
    public let remotePhaseName: String?
    public let currentTier: String?
    public let title: String
    public let detail: String?
    public let etaMinutes: Int?
    public let remoteJobId: String?
    public let runtimeMetrics: [String: String]?
    public let uploadedBytes: Int64?
    public let totalBytes: Int64?
    public let uploadBytesPerSecond: Double?

    public init(
        stage: GenerateProgressStage,
        progressFraction: Double?,
        progressBasis: String? = nil,
        remoteStageKey: String? = nil,
        remotePhaseName: String? = nil,
        currentTier: String? = nil,
        title: String,
        detail: String? = nil,
        etaMinutes: Int? = nil,
        remoteJobId: String? = nil,
        runtimeMetrics: [String: String]? = nil,
        uploadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        uploadBytesPerSecond: Double? = nil
    ) {
        self.stage = stage
        self.progressFraction = progressFraction
        self.progressBasis = progressBasis
        self.remoteStageKey = remoteStageKey
        self.remotePhaseName = remotePhaseName
        self.currentTier = currentTier
        self.title = title
        self.detail = detail
        self.etaMinutes = etaMinutes
        self.remoteJobId = remoteJobId
        self.runtimeMetrics = runtimeMetrics
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}
