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
    
    func upload(videoURL: URL) async throws -> String {
        return Self.fixedAssetId
    }
    
    func startJob(assetId: String) async throws -> String {
        pollCount = 0  // Reset on new job
        return "fake-job-\(assetId)"
    }
    
    func pollStatus(jobId: String) async throws -> JobStatus {
        pollCount += 1
        
        // Simulate normal progress increments
        if pollCount <= 2 {
            return .processing(progress: Double(pollCount) * 30.0)
        } else if pollCount == 3 {
            if simulateProgressRegression {
                // Simulate progress regression (should be ignored by client)
                return .processing(progress: 50.0)  // Lower than previous 60.0
            }
            return .processing(progress: 90.0)
        } else if pollCount == 4 {
            if simulateStall {
                // Simulate stall: return same progress value
                return .processing(progress: 90.0)
            }
            return .completed
        } else {
            // After completion, always return completed
            return .completed
        }
    }
    
    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        return (Self.fixedPlyContent, .splatPly)
    }
}

