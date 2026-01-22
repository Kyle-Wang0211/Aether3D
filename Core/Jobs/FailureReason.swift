// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5
// States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
// ============================================================================

import Foundation

/// Failure reason enumeration (14 reasons).
public enum FailureReason: String, Codable, CaseIterable {
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
    case packagingFailed = "packaging_failed"
    case internalError = "internal_error"
    
    /// Whether this failure reason is retryable.
    public var isRetryable: Bool {
        switch self {
        case .networkError, .uploadInterrupted, .serverUnavailable,
             .trainingFailed, .gpuOutOfMemory, .processingTimeout,
             .packagingFailed, .internalError:
            return true
        case .invalidVideoFormat, .videoTooShort, .videoTooLong,
             .insufficientFrames, .poseEstimationFailed, .lowRegistrationRate:
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
             .processingTimeout, .packagingFailed, .internalError:
            return true
        }
    }
}

