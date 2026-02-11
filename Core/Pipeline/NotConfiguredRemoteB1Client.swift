// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  NotConfiguredRemoteB1Client.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

final class NotConfiguredRemoteB1Client: RemoteB1Client {
    func upload(videoURL: URL) async throws -> String {
        throw FailReason.apiNotConfigured
    }
    
    func startJob(assetId: String) async throws -> String {
        throw FailReason.apiNotConfigured
    }
    
    func pollStatus(jobId: String) async throws -> JobStatus {
        throw FailReason.apiNotConfigured
    }
    
    func download(jobId: String) async throws -> (data: Data, format: ArtifactFormat) {
        throw FailReason.apiNotConfigured
    }
}

