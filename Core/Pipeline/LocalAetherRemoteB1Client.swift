// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  LocalAetherRemoteB1Client.swift
//  progect2
//
//  Embedded self-developed fallback client.
//  Keeps PipelineRunner usable without external API wiring.
//

import Foundation

actor LocalAetherRemoteB1Client: RemoteB1Client {
    private struct LocalJob {
        var pollCount: Int
        let result: Result<Data, RemoteB1ClientError>
    }

    private var assets: [String: URL] = [:]
    private var jobs: [String: LocalJob] = [:]

    func upload(videoURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RemoteB1ClientError.uploadFailed("Input file does not exist")
        }
        let assetId = "local-asset-\(UUID().uuidString)"
        assets[assetId] = videoURL
        return assetId
    }

    func startJob(assetId: String) async throws -> String {
        guard let videoURL = assets[assetId] else {
            throw RemoteB1ClientError.invalidResponse
        }
        let jobId = "local-job-\(UUID().uuidString)"
        do {
            let plyData = try self.generateDeterministicPLY(from: videoURL)
            jobs[jobId] = LocalJob(pollCount: 0, result: .success(plyData))
        } catch {
            jobs[jobId] = LocalJob(
                pollCount: 0,
                result: .failure(.jobFailed(error.localizedDescription))
            )
        }
        return jobId
    }

    func pollStatus(jobId: String) async throws -> JobStatus {
        guard var job = jobs[jobId] else {
            throw RemoteB1ClientError.invalidResponse
        }
        job.pollCount += 1
        jobs[jobId] = job

        switch job.result {
        case .failure(let error):
            return .failed(reason: self.describe(error))
        case .success:
            switch job.pollCount {
            case 0...1:
                return .pending(progress: nil)
            case 2:
                return .processing(progress: 35.0)
            case 3:
                return .processing(progress: 70.0)
            case 4:
                return .processing(progress: 95.0)
            default:
                return .completed
            }
        }
    }

    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        guard let job = jobs[jobId] else {
            throw RemoteB1ClientError.invalidResponse
        }
        switch job.result {
        case .success(let data):
            return (data, .splatPly)
        case .failure(let error):
            throw error
        }
    }

    private func generateDeterministicPLY(from inputURL: URL) throws -> Data {
        let inputData = try Data(contentsOf: inputURL)
        guard !inputData.isEmpty else {
            throw RemoteB1ClientError.uploadFailed("Input file is empty")
        }

        let digest = _SHA256.hash(data: inputData)
        let digestBytes = Array(digest)
        let vertexCount = max(300, min(6000, inputData.count / 1024 + 300))

        var lines: [String] = [
            "ply",
            "format ascii 1.0",
            "element vertex \(vertexCount)",
            "property float x",
            "property float y",
            "property float z",
            "property float nx",
            "property float ny",
            "property float nz",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "end_header"
        ]

        for i in 0..<vertexCount {
            let b0 = Double(digestBytes[i % digestBytes.count])
            let b1 = Double(digestBytes[(i * 3 + 11) % digestBytes.count])
            let b2 = Double(digestBytes[(i * 7 + 19) % digestBytes.count])

            let phase = Double(i % 360) * .pi / 180.0
            let radius = 0.2 + (b0 / 255.0) * 1.5
            let x = radius * cos(phase)
            let y = radius * sin(phase)
            let z = (Double(i) / Double(max(vertexCount - 1, 1))) * 2.0 - 1.0

            let nx = x / max(radius, 1e-6)
            let ny = y / max(radius, 1e-6)
            let nz = 0.0

            lines.append(
                String(
                    format: "%.6f %.6f %.6f %.6f %.6f %.6f %d %d %d",
                    x, y, z, nx, ny, nz, Int(b0), Int(b1), Int(b2)
                )
            )
        }

        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func describe(_ error: RemoteB1ClientError) -> String {
        switch error {
        case .notConfigured:
            return "Local client is not configured"
        case .networkError(let message):
            return message
        case .networkTimeout:
            return "Network timeout"
        case .invalidResponse:
            return "Invalid response"
        case .uploadFailed(let message):
            return message
        case .downloadFailed(let message):
            return message
        case .jobFailed(let message):
            return message
        }
    }
}
