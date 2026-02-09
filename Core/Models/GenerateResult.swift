// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  GenerateResult.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

public enum GenerateResult {
    case success(artifact: ArtifactRef, elapsedMs: Int)
    case fail(reason: FailReason, elapsedMs: Int)
}

public struct ArtifactRef {
    public let localPath: URL
    public let format: ArtifactFormat
}

public enum ArtifactFormat {
    case splat        // .splat binary 3DGS
    case splatPly     // .ply container with Gaussian Splatting data
}

public enum FailReason: String, Error {
    case timeout = "timeout"
    case networkTimeout = "network_timeout"
    case uploadFailed = "upload_failed"
    case apiError = "api_error"
    case jobTimeout = "job_timeout"
    case downloadFailed = "download_failed"
    case invalidResponse = "invalid_response"
    case apiNotConfigured = "api_not_configured"
    case inputInvalid = "input_invalid"
    case outOfMemory = "out_of_memory"
    case stalledProcessing = "stalled_processing"  // PR-PROGRESS-1.0: No progress for stallTimeoutSeconds
    case unknownError = "unknown_error"
}

