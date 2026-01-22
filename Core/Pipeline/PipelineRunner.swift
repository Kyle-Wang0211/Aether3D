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
                timestamp: WallClock.now(),
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
            
            let (plyData, _) = try await Timeout.withTimeout(seconds: 180) {
                let assetId = try await self.remoteClient.upload(videoURL: videoURL)
                let jobId = try await self.remoteClient.startJob(assetId: assetId)
                let (splatData, format) = try await self.pollAndDownload(jobId: jobId)
                return (splatData, format)
            }
            
            let plyPath = artifactsDir.appendingPathComponent("model.ply")
            try plyData.write(to: plyPath, options: .atomic)
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
                timestamp: WallClock.now(),
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
                timestamp: WallClock.now(),
                eventType: "generate_success",
                detailsJson: "{\"artifactPath\":\"\(artifactPath)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .success(artifact: ArtifactRef(localPath: finalDir, format: .splatPly), elapsedMs: elapsed)
            
        } catch is TimeoutError {
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
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
            let reasonStr = jsonEscape(reason.rawValue)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"\(reasonStr)\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: reason, elapsedMs: elapsed)
            
        } catch {
            print("[Whitebox] generate failed with error: \(error)")
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            
            #if canImport(AVFoundation)
            PlainAuditLog.shared.append(AuditEntry(
                timestamp: WallClock.now(),
                eventType: "generate_fail",
                detailsJson: "{\"reason\":\"unknown_error\",\"elapsedMs\":\(elapsed)}"
            ))
            #endif
            
            return .fail(reason: .unknownError, elapsedMs: elapsed)
        }
    }
    
    func runGenerate(request: BuildRequest) async -> GenerateResult {
        #if canImport(AVFoundation)
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
        #else
        // Linux stub: AVFoundation unavailable
        fatalError("AVFoundation unavailable on this platform")
        #endif
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
                let hash = _hexLowercase(_SHA256.hash(data: data))
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
