//
//  PipelineRunner.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import AVFoundation

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

final class PipelineRunner {
    private let remoteClient: RemoteB1Client
    
    init(remoteClient: RemoteB1Client = NotConfiguredRemoteB1Client()) {
        self.remoteClient = remoteClient
    }
    
    // MARK: - New Generate API (Day 2)
    
    func runGenerate(request: BuildRequest) async -> GenerateResult {
        let startTime = Date()
        
        do {
            guard case let .video(asset) = request.source else {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return .fail(reason: .inputInvalid, elapsedMs: elapsed)
            }
            
            let videoURL: URL
            if let urlAsset = asset as? AVURLAsset {
                videoURL = urlAsset.url
            } else {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return .fail(reason: .inputInvalid, elapsedMs: elapsed)
            }
            
            #if canImport(AVFoundation)
            // 审计：generate_start
            let videoPath = jsonEscape(videoURL.path)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_start",
                detailsJson: "{\"videoPath\":\"\(videoPath)\"}"
            ))
            #endif
            
            let artifact: ArtifactRef = try await Timeout.withTimeout(seconds: 180) {
                // Upload video
                let assetId = try await self.remoteClient.upload(videoURL: videoURL)
                
                // Start job
                let jobId = try await self.remoteClient.startJob(assetId: assetId)
                
                // Poll and download
                let (splatData, format) = try await self.pollAndDownload(jobId: jobId)
                
                // Write to Documents/Whitebox/
                let url = try self.writeSplatToDocuments(data: splatData, format: format, jobId: jobId)
                
                return ArtifactRef(localPath: url, format: format)
            }
            
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_success
            let artifactPath = jsonEscape(artifact.localPath.path)
            let formatStr = jsonEscape(artifact.format == .splat ? "splat" : "splatPly")
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_success",
                detailsJson: "{\"artifactPath\":\"\(artifactPath)\",\"format\":\"\(formatStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .success(artifact: artifact, elapsedMs: elapsed)
            
        } catch is TimeoutError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (timeout)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"timeout\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: .timeout, elapsedMs: elapsed)
            
        } catch let error as FailReason {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (FailReason)
            let reasonStr = jsonEscape(error.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: error, elapsedMs: elapsed)
            
        } catch let error as RemoteB1ClientError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let reason = mapRemoteB1ClientError(error)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (RemoteB1ClientError)
            let reasonStr = jsonEscape(reason.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: reason, elapsedMs: elapsed)
            
        } catch {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            // 审计：generate_fail (unknown)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"unknown_error\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: .unknownError, elapsedMs: elapsed)
        }
    }
    
    // MARK: - Private Helpers
    
    private func pollAndDownload(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        let pollInterval: TimeInterval = 2.0
        
        while true {
            let status = try await self.remoteClient.pollStatus(jobId: jobId)
            
            switch status {
            case .completed:
                return try await self.remoteClient.download(jobId: jobId)
                
            case .failed(let reason):
                throw RemoteB1ClientError.jobFailed(reason)
                
            case .pending, .processing:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
            }
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
        case .networkError, .invalidResponse, .jobFailed:
            return .apiError
        }
    }
}
