// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  RemoteB1Client.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

public enum RemoteB1ClientError: Error {
    case notConfigured
    case networkError(String)
    case networkTimeout
    case invalidResponse
    case uploadFailed(String)
    case downloadFailed(String)
    case jobFailed(String)
}

public enum RemoteUploadPhase: String, Sendable {
    case transferring
    case finalizing
}

public struct RemoteUploadProgress: Sendable {
    public let uploadedBytes: Int64
    public let totalBytes: Int64
    public let phase: RemoteUploadPhase

    public init(
        uploadedBytes: Int64,
        totalBytes: Int64,
        phase: RemoteUploadPhase = .transferring
    ) {
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.phase = phase
    }

    public var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(Double(uploadedBytes) / Double(totalBytes), 0.0), 1.0)
    }

    public var isFinalizing: Bool {
        phase == .finalizing
    }
}

public struct RemoteJobProgress: Sendable {
    public let progressFraction: Double?
    public let stageKey: String?
    public let phaseName: String?
    public let currentTier: String?
    public let title: String?
    public let detail: String?
    public let etaMinutes: Int?
    public let elapsedSeconds: Int?
    public let progressBasis: String?
    public let runtimeMetrics: [String: String]

    public init(
        progressFraction: Double?,
        stageKey: String?,
        phaseName: String? = nil,
        currentTier: String? = nil,
        title: String? = nil,
        detail: String?,
        etaMinutes: Int?,
        elapsedSeconds: Int?,
        progressBasis: String?,
        runtimeMetrics: [String: String] = [:]
    ) {
        self.progressFraction = progressFraction
        self.stageKey = stageKey
        self.phaseName = phaseName
        self.currentTier = currentTier
        self.title = title
        self.detail = detail
        self.etaMinutes = etaMinutes
        self.elapsedSeconds = elapsedSeconds
        self.progressBasis = progressBasis
        self.runtimeMetrics = runtimeMetrics
    }
}

protocol RemoteB1Client {
    func upload(
        videoURL: URL,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String
    func startJob(assetId: String) async throws -> String
    func pollStatus(jobId: String) async throws -> JobStatus
    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat)
    func cancel(jobId: String) async throws
}

extension RemoteB1Client {
    func upload(videoURL: URL) async throws -> String {
        try await upload(videoURL: videoURL, onProgress: nil)
    }
}

public enum JobStatus: Sendable {
    case pending(RemoteJobProgress)
    case processing(RemoteJobProgress)
    case downloadReady(RemoteJobProgress)
    case completed(RemoteJobProgress?)
    case failed(reason: String, progress: RemoteJobProgress?)
}
