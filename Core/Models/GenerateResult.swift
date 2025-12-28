//
//  GenerateResult.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

enum GenerateResult {
    case success(artifact: ArtifactRef, elapsedMs: Int)
    case fail(reason: FailReason, elapsedMs: Int)
}

struct ArtifactRef {
    let localPath: URL
    let format: ArtifactFormat
}

enum ArtifactFormat {
    case splat        // .splat binary 3DGS
    case splatPly     // .ply container with Gaussian Splatting data
}

enum FailReason: String, Error {
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
    case unknownError = "unknown_error"
}

