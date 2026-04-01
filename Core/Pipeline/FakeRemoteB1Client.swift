// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  FakeRemoteB1Client.swift
//  progect2
//
//  Created for PR#13 Whitebox Integration v6
//

import Foundation

final class FakeRemoteB1Client: RemoteB1Client {
    private static let fixedAssetId = "fake-asset-00000000"
    
    private static let fixedPlyContent: Data = """
        ply
        format ascii 1.0
        element vertex 10
        property float x
        property float y
        property float z
        end_header
        0.0 0.0 0.0
        0.1 0.0 0.0
        0.2 0.0 0.0
        0.3 0.0 0.0
        0.4 0.0 0.0
        0.5 0.0 0.0
        0.6 0.0 0.0
        0.7 0.0 0.0
        0.8 0.0 0.0
        0.9 0.0 0.0
        
        """.data(using: .utf8)!
    
    private var pollCount = 0
    private var simulateStall = false
    private var simulateProgressRegression = false
    
    /// Configure simulation behavior (for tests)
    func configure(simulateStall: Bool = false, simulateProgressRegression: Bool = false) {
        self.simulateStall = simulateStall
        self.simulateProgressRegression = simulateProgressRegression
    }
    
    func upload(
        videoURL: URL,
        onProgress: (@Sendable (RemoteUploadProgress) async -> Void)?
    ) async throws -> String {
        if let onProgress {
            await onProgress(RemoteUploadProgress(uploadedBytes: 1, totalBytes: 1))
        }
        return Self.fixedAssetId
    }
    
    func startJob(assetId: String) async throws -> String {
        pollCount = 0  // Reset on new job
        return "fake-job-\(assetId)"
    }
    
    func pollStatus(jobId: String) async throws -> JobStatus {
        pollCount += 1
        let progress = RemoteJobProgress(
            progressFraction: Double(min(pollCount, 4)) * 0.25,
            stageKey: "train",
            detail: "测试桩正在模拟远端训练。",
            etaMinutes: max(1, 5 - pollCount),
            elapsedSeconds: pollCount * 15,
            progressBasis: "fake_fixture"
        )
        
        // Simulate normal progress increments
        if pollCount <= 2 {
            return .processing(progress)
        } else if pollCount == 3 {
            if simulateProgressRegression {
                // Simulate progress regression (should be ignored by client)
                return .processing(
                    RemoteJobProgress(
                        progressFraction: 0.5,
                        stageKey: "train",
                        detail: "测试桩模拟进度回退。",
                        etaMinutes: 2,
                        elapsedSeconds: pollCount * 15,
                        progressBasis: "fake_fixture"
                    )
                )
            }
            return .processing(
                RemoteJobProgress(
                    progressFraction: 0.9,
                    stageKey: "packaging",
                    detail: "测试桩正在导出结果。",
                    etaMinutes: 1,
                    elapsedSeconds: pollCount * 15,
                    progressBasis: "fake_fixture"
                )
            )
        } else if pollCount == 4 {
            if simulateStall {
                // Simulate stall: return same progress value
                return .processing(
                    RemoteJobProgress(
                        progressFraction: 0.9,
                        stageKey: "packaging",
                        detail: "测试桩模拟长时间停滞。",
                        etaMinutes: nil,
                        elapsedSeconds: pollCount * 15,
                        progressBasis: "fake_fixture"
                    )
                )
            }
            return .completed(
                RemoteJobProgress(
                    progressFraction: 1.0,
                    stageKey: "complete",
                    detail: "测试桩已经完成。",
                    etaMinutes: 0,
                    elapsedSeconds: pollCount * 15,
                    progressBasis: "fake_fixture"
                )
            )
        } else {
            // After completion, always return completed
            return .completed(
                RemoteJobProgress(
                    progressFraction: 1.0,
                    stageKey: "complete",
                    detail: "测试桩已经完成。",
                    etaMinutes: 0,
                    elapsedSeconds: pollCount * 15,
                    progressBasis: "fake_fixture"
                )
            )
        }
    }
    
    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        return (Self.fixedPlyContent, .splatPly)
    }

    func cancel(jobId: String) async throws {
        pollCount = 0
    }
}
