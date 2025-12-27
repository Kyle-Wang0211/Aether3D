//
//  NotConfiguredRemoteB1Client.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

final class NotConfiguredRemoteB1Client: RemoteB1Client {
    func upload(videoURL: URL) async throws -> String {
        throw RemoteB1ClientError.notConfigured
    }
    
    func startJob(assetId: String) async throws -> String {
        throw RemoteB1ClientError.notConfigured
    }
    
    func pollStatus(jobId: String) async throws -> JobStatus {
        throw RemoteB1ClientError.notConfigured
    }
    
    func download(jobId: String) async throws -> Data {
        throw RemoteB1ClientError.notConfigured
    }
}

