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
    
    func upload(videoURL: URL) async throws -> String {
        return Self.fixedAssetId
    }
    
    func startJob(assetId: String) async throws -> String {
        return "fake-job-\(assetId)"
    }
    
    func pollStatus(jobId: String) async throws -> JobStatus {
        return .completed
    }
    
    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        return (Self.fixedPlyContent, .splatPly)
    }
}

