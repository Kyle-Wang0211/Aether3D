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

protocol RemoteB1Client {
    func upload(videoURL: URL) async throws -> String  // assetId
    func startJob(assetId: String) async throws -> String  // jobId
    func pollStatus(jobId: String) async throws -> JobStatus
    func download(jobId: String) async throws -> Data  // .splat bytes
}

enum JobStatus {
    case pending(progress: Double?)
    case processing(progress: Double?)
    case completed
    case failed(reason: String)
}

