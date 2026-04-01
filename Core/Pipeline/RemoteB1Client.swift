// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  RemoteB1Client.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

enum RemoteB1ClientError: Error {
    case notConfigured
    case networkError(String)
    case networkTimeout
    case invalidResponse
    case uploadFailed(String)
    case downloadFailed(String)
    case jobFailed(String)
}

enum RemoteUploadPhase: String, Sendable {
    case transferring
    case finalizing
}

struct RemoteUploadProgress: Sendable {
    let uploadedBytes: Int64
    let totalBytes: Int64
    let phase: RemoteUploadPhase

    init(
        uploadedBytes: Int64,
        totalBytes: Int64,
        phase: RemoteUploadPhase = .transferring
    ) {
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.phase = phase
    }

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(Double(uploadedBytes) / Double(totalBytes), 0.0), 1.0)
    }

    var isFinalizing: Bool {
        phase == .finalizing
    }
}

struct RemoteJobProgress: Sendable {
    let progressFraction: Double?
    let stageKey: String?
    let phaseName: String?
    let currentTier: String?
    let title: String?
    let detail: String?
    let etaMinutes: Int?
    let elapsedSeconds: Int?
    let progressBasis: String?
    let runtimeMetrics: [String: String]

    init(
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

enum JobStatus: Sendable {
    case pending(RemoteJobProgress)
    case processing(RemoteJobProgress)
    case downloadReady(RemoteJobProgress)
    case completed(RemoteJobProgress?)
    case failed(reason: String, progress: RemoteJobProgress?)
}
