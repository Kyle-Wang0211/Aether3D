// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Failure reason enumeration (17 reasons).
public enum FailureReason: String, Codable, CaseIterable, Sendable {
    case networkError = "network_error"
    case uploadInterrupted = "upload_interrupted"
    case serverUnavailable = "server_unavailable"
    case invalidVideoFormat = "invalid_video_format"
    case videoTooShort = "video_too_short"
    case videoTooLong = "video_too_long"
    case insufficientFrames = "insufficient_frames"
    case poseEstimationFailed = "pose_estimation_failed"
    case lowRegistrationRate = "low_registration_rate"
    case trainingFailed = "training_failed"
    case gpuOutOfMemory = "gpu_out_of_memory"
    case processingTimeout = "processing_timeout"
    case heartbeatTimeout = "heartbeat_timeout"     // NEW: v3.0
    case stalledProcessing = "stalled_processing"   // NEW: v3.0
    case resourceExhausted = "resource_exhausted"   // NEW: v3.0
    case packagingFailed = "packaging_failed"
    case internalError = "internal_error"
    
    /// Whether this failure reason is retryable.
    public var isRetryable: Bool {
        switch self {
        case .networkError, .uploadInterrupted, .serverUnavailable,
             .trainingFailed, .gpuOutOfMemory, .processingTimeout,
             .heartbeatTimeout, .stalledProcessing,  // NEW: retryable
             .packagingFailed, .internalError:
            return true
        case .invalidVideoFormat, .videoTooShort, .videoTooLong,
             .insufficientFrames, .poseEstimationFailed, .lowRegistrationRate,
             .resourceExhausted:  // NEW: not retryable (permanent)
            return false
        }
    }
    
    /// Whether this failure reason is server-side only.
    public var isServerOnly: Bool {
        switch self {
        case .networkError, .uploadInterrupted:
            return false
        case .serverUnavailable, .invalidVideoFormat, .videoTooShort,
             .videoTooLong, .insufficientFrames, .poseEstimationFailed,
             .lowRegistrationRate, .trainingFailed, .gpuOutOfMemory,
             .processingTimeout, .heartbeatTimeout, .stalledProcessing,  // NEW
             .resourceExhausted,  // NEW
             .packagingFailed, .internalError:
            return true
        }
    }
}

