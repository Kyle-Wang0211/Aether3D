//
// SSOT.swift
// Aether3D
//
// Single public entry point for all SSOT constants and error codes.
//

import Foundation

/// Single entry point for SSOT system.
/// Provides unified access to all constants, thresholds, and error codes.
public enum SSOT {
    // MARK: - System Constants
    
    /// Maximum number of frames
    public static var maxFrames: Int { SystemConstants.maxFrames }
    
    /// Minimum number of frames
    public static var minFrames: Int { SystemConstants.minFrames }
    
    /// Maximum number of Gaussians
    public static var maxGaussians: Int { SystemConstants.maxGaussians }
    
    // MARK: - Conversion Constants
    
    /// Bytes per kilobyte
    public static var bytesPerKB: Int { ConversionConstants.bytesPerKB }
    
    /// Bytes per megabyte
    public static var bytesPerMB: Int { ConversionConstants.bytesPerMB }
    
    // MARK: - Quality Thresholds
    
    /// Minimum SFM registration ratio
    public static var sfmRegistrationMinRatio: Double { QualityThresholds.sfmRegistrationMinRatio }
    
    /// Minimum PSNR value (dB)
    public static var psnrMinDb: Double { QualityThresholds.psnrMinDb }
    
    /// PSNR warning threshold (dB)
    public static var psnrWarnDb: Double { QualityThresholds.psnrWarnDb }
    
    // MARK: - Retry Constants
    
    /// Maximum retry count
    public static var maxRetryCount: Int { RetryConstants.maxRetryCount }
    
    /// Retry interval (seconds)
    public static var retryIntervalSeconds: TimeInterval { RetryConstants.retryIntervalSeconds }
    
    /// Upload timeout (seconds, .infinity for unlimited)
    public static var uploadTimeoutSeconds: TimeInterval { RetryConstants.uploadTimeoutSeconds }
    
    /// Download maximum retry count
    public static var downloadMaxRetryCount: Int { RetryConstants.downloadMaxRetryCount }
    
    /// Artifact TTL (seconds)
    public static var artifactTTLSeconds: TimeInterval { RetryConstants.artifactTTLSeconds }
    
    /// Heartbeat interval (seconds)
    public static var heartbeatIntervalSeconds: TimeInterval { RetryConstants.heartbeatIntervalSeconds }
    
    /// Polling interval (seconds)
    public static var pollingIntervalSeconds: TimeInterval { RetryConstants.pollingIntervalSeconds }
    
    /// Stall detection time (seconds)
    public static var stallDetectionSeconds: TimeInterval { RetryConstants.stallDetectionSeconds }
    
    /// Stall heartbeat failure count
    public static var stallHeartbeatFailureCount: Int { RetryConstants.stallHeartbeatFailureCount }
    
    // MARK: - Sampling Constants
    
    /// Minimum video duration (seconds)
    public static var minVideoDurationSeconds: TimeInterval { SamplingConstants.minVideoDurationSeconds }
    
    /// Maximum video duration (seconds)
    public static var maxVideoDurationSeconds: TimeInterval { SamplingConstants.maxVideoDurationSeconds }
    
    /// Minimum frame count
    public static var minFrameCount: Int { SamplingConstants.minFrameCount }
    
    /// Maximum frame count
    public static var maxFrameCount: Int { SamplingConstants.maxFrameCount }
    
    /// JPEG quality (0.0-1.0)
    public static var jpegQuality: Double { SamplingConstants.jpegQuality }
    
    /// Maximum image long edge (pixels)
    public static var maxImageLongEdge: Int { SamplingConstants.maxImageLongEdge }
    
    // MARK: - Frame Quality Constants
    
    /// Blur threshold (Laplacian variance)
    public static var blurThresholdLaplacian: Double { FrameQualityConstants.blurThresholdLaplacian }
    
    /// Dark threshold (brightness 0-255)
    public static var darkThresholdBrightness: Double { FrameQualityConstants.darkThresholdBrightness }
    
    /// Bright threshold (brightness 0-255)
    public static var brightThresholdBrightness: Double { FrameQualityConstants.brightThresholdBrightness }
    
    /// Maximum frame similarity (ratio)
    public static var maxFrameSimilarity: Double { FrameQualityConstants.maxFrameSimilarity }
    
    /// Minimum frame similarity (ratio)
    public static var minFrameSimilarity: Double { FrameQualityConstants.minFrameSimilarity }
    
    // MARK: - Continuity Constants
    
    /// Maximum delta theta (degrees per frame)
    public static var maxDeltaThetaDegPerFrame: Double { ContinuityConstants.maxDeltaThetaDegPerFrame }
    
    /// Maximum delta translation (meters per frame)
    public static var maxDeltaTranslationMPerFrame: Double { ContinuityConstants.maxDeltaTranslationMPerFrame }
    
    /// Freeze window (frames)
    public static var freezeWindowFrames: Int { ContinuityConstants.freezeWindowFrames }
    
    /// Recovery stable frames
    public static var recoveryStableFrames: Int { ContinuityConstants.recoveryStableFrames }
    
    /// Recovery maximum delta theta (degrees per frame)
    public static var recoveryMaxDeltaThetaDegPerFrame: Double { ContinuityConstants.recoveryMaxDeltaThetaDegPerFrame }
    
    // MARK: - Coverage Visualization Constants
    
    /// S0 border width (pixels)
    public static var s0BorderWidthPx: Double { CoverageVisualizationConstants.s0BorderWidthPx }
    
    /// S4 minimum theta span (degrees)
    public static var s4MinThetaSpanDeg: Double { CoverageVisualizationConstants.s4MinThetaSpanDeg }
    
    /// S4 minimum L2+ count
    public static var s4MinL2PlusCount: Int { CoverageVisualizationConstants.s4MinL2PlusCount }
    
    /// S4 minimum L3 count
    public static var s4MinL3Count: Int { CoverageVisualizationConstants.s4MinL3Count }
    
    /// S4 maximum reprojection RMS (pixels)
    public static var s4MaxReprojRmsPx: Double { CoverageVisualizationConstants.s4MaxReprojRmsPx }
    
    /// S4 maximum edge RMS (pixels)
    public static var s4MaxEdgeRmsPx: Double { CoverageVisualizationConstants.s4MaxEdgeRmsPx }
    
    /// Patch size minimum (meters)
    public static var patchSizeMinM: Double { CoverageVisualizationConstants.patchSizeMinM }
    
    /// Patch size maximum (meters)
    public static var patchSizeMaxM: Double { CoverageVisualizationConstants.patchSizeMaxM }
    
    /// Patch size fallback (meters)
    public static var patchSizeFallbackM: Double { CoverageVisualizationConstants.patchSizeFallbackM }
    
    // MARK: - Storage Constants
    
    /// Low storage warning threshold (bytes)
    public static var lowStorageWarningBytes: Int64 { StorageConstants.lowStorageWarningBytes }
    
    /// Maximum asset count
    public static var maxAssetCount: Int { StorageConstants.maxAssetCount }
    
    /// Auto cleanup enabled
    public static var autoCleanupEnabled: Bool { StorageConstants.autoCleanupEnabled }
    
    // MARK: - Registry
    
    /// Central registry
    public static var registry: SSOTRegistry.Type { SSOTRegistry.self }
    
    // MARK: - Error Codes
    
    /// Invalid constant specification
    public static var errorInvalidSpec: SSOTErrorCode { ErrorCodes.S_INVALID_SPEC }
    
    /// Value exceeds maximum threshold
    public static var errorExceededMax: SSOTErrorCode { ErrorCodes.S_EXCEEDED_MAX }
    
    /// Value underflows minimum threshold
    public static var errorUnderflowedMin: SSOTErrorCode { ErrorCodes.S_UNDERFLOWED_MIN }
    
    /// Assertion failed
    public static var errorAssertionFailed: SSOTErrorCode { ErrorCodes.S_ASSERTION_FAILED }
    
    /// Registry validation failed
    public static var errorRegistryInvalid: SSOTErrorCode { ErrorCodes.S_REGISTRY_INVALID }
    
    /// Duplicate error code
    public static var errorDuplicateErrorCode: SSOTErrorCode { ErrorCodes.S_DUPLICATE_ERROR_CODE }
    
    /// Duplicate constant spec ID
    public static var errorDuplicateSpecId: SSOTErrorCode { ErrorCodes.S_DUPLICATE_SPEC_ID }
}

