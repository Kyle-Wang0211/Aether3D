// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ErrorCodes.swift
// Aether3D
//
// All error code definitions.
//

import Foundation

/// All SSOT error codes.
public enum ErrorCodes {
    // MARK: - SSOT Domain (1000-1999)
    
    /// Invalid constant specification
    public static let S_INVALID_SPEC = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1000,
        stableName: "SSOT_INVALID_SPEC",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Invalid constant specification",
        developerHint: "Check spec validation errors"
    )
    
    /// Value exceeds maximum threshold
    public static let S_EXCEEDED_MAX = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1001,
        stableName: "SSOT_EXCEEDED_MAX",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "Value exceeds maximum allowed",
        developerHint: "Check threshold limits"
    )
    
    /// Value underflows minimum threshold
    public static let S_UNDERFLOWED_MIN = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1002,
        stableName: "SSOT_UNDERFLOWED_MIN",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "Value below minimum required",
        developerHint: "Check minimum limits"
    )
    
    /// Assertion failed (replaces fatalError)
    public static let S_ASSERTION_FAILED = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1003,
        stableName: "SSOT_ASSERTION_FAILED",
        severity: .critical,
        retry: .none,
        defaultUserMessage: "Internal assertion failed",
        developerHint: "This indicates a programming error"
    )
    
    /// Registry validation failed
    public static let S_REGISTRY_INVALID = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1004,
        stableName: "SSOT_REGISTRY_INVALID",
        severity: .high,
        retry: .none,
        defaultUserMessage: "SSOT registry validation failed",
        developerHint: "Check registry selfCheck() output"
    )
    
    /// Duplicate error code
    public static let S_DUPLICATE_ERROR_CODE = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1005,
        stableName: "SSOT_DUPLICATE_ERROR_CODE",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Duplicate error code detected",
        developerHint: "Check error code uniqueness"
    )
    
    /// Duplicate constant spec ID
    public static let S_DUPLICATE_SPEC_ID = SSOTErrorCode(
        domain: ErrorDomains.ssot,
        code: 1006,
        stableName: "SSOT_DUPLICATE_SPEC_ID",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Duplicate constant spec ID detected",
        developerHint: "Check spec ID uniqueness"
    )
    
    // MARK: - Capture Domain (1000-1999, prefix E_)
    
    /// Frame count clamped
    public static let E_FRAMES_CLAMPED = SSOTErrorCode(
        domain: ErrorDomains.capture,
        code: 1001,
        stableName: "E_FRAMES_CLAMPED",
        severity: .low,
        retry: .none,
        defaultUserMessage: "Frame count adjusted to valid range",
        developerHint: "Frame count was clamped to system limits"
    )
    
    /// Not enough frames
    public static let E_FRAMES_TOO_FEW = SSOTErrorCode(
        domain: ErrorDomains.capture,
        code: 1002,
        stableName: "E_FRAMES_TOO_FEW",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "Not enough frames captured",
        developerHint: "Check minimum frame requirement"
    )
    
    /// Capture data invalid
    public static let E_CAPTURE_INVALID = SSOTErrorCode(
        domain: ErrorDomains.capture,
        code: 1003,
        stableName: "E_CAPTURE_INVALID",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Capture data is invalid",
        developerHint: "Validate capture data format and content"
    )
    
    /// Capture data corrupted
    public static let E_CAPTURE_CORRUPTED = SSOTErrorCode(
        domain: ErrorDomains.capture,
        code: 1004,
        stableName: "E_CAPTURE_CORRUPTED",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Capture data is corrupted",
        developerHint: "Check data integrity and file system"
    )
    
    // MARK: - Storage Domain (2000-2999, prefix E_)
    
    /// Storage space low
    public static let E_STORAGE_LOW = SSOTErrorCode(
        domain: ErrorDomains.storage,
        code: 2001,
        stableName: "E_STORAGE_LOW",
        severity: .low,
        retry: .none,
        defaultUserMessage: "Storage space is running low",
        developerHint: "Check available disk space"
    )
    
    /// Storage write failed
    public static let E_STORAGE_WRITE_FAILED = SSOTErrorCode(
        domain: ErrorDomains.storage,
        code: 2002,
        stableName: "E_STORAGE_WRITE_FAILED",
        severity: .high,
        retry: .immediate,
        defaultUserMessage: "Failed to save data",
        developerHint: "Check file permissions and disk space"
    )
    
    /// Storage read failed
    public static let E_STORAGE_READ_FAILED = SSOTErrorCode(
        domain: ErrorDomains.storage,
        code: 2003,
        stableName: "E_STORAGE_READ_FAILED",
        severity: .high,
        retry: .immediate,
        defaultUserMessage: "Failed to load data",
        developerHint: "Check file existence and permissions"
    )
    
    // MARK: - Network Domain (3000-3999, prefix E_)
    
    /// Upload failed
    public static let E_UPLOAD_FAILED = SSOTErrorCode(
        domain: ErrorDomains.network,
        code: 3001,
        stableName: "E_UPLOAD_FAILED",
        severity: .high,
        retry: .exponentialBackoff,
        defaultUserMessage: "Upload failed",
        developerHint: "Check network connection and server status"
    )
    
    /// Download failed
    public static let E_DOWNLOAD_FAILED = SSOTErrorCode(
        domain: ErrorDomains.network,
        code: 3002,
        stableName: "E_DOWNLOAD_FAILED",
        severity: .high,
        retry: .exponentialBackoff,
        defaultUserMessage: "Download failed",
        developerHint: "Check network connection and server status"
    )
    
    /// Upload file too large
    public static let E_UPLOAD_TOO_LARGE = SSOTErrorCode(
        domain: ErrorDomains.network,
        code: 3003,
        stableName: "E_UPLOAD_TOO_LARGE",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "File is too large to upload",
        developerHint: "Check file size limits"
    )
    
    /// Network timeout
    public static let E_NETWORK_TIMEOUT = SSOTErrorCode(
        domain: ErrorDomains.network,
        code: 3004,
        stableName: "E_NETWORK_TIMEOUT",
        severity: .high,
        retry: .exponentialBackoff,
        defaultUserMessage: "Connection timeout",
        developerHint: "Check network connection and timeout settings"
    )
    
    // MARK: - Pipeline Domain (4000-4999, prefix C_)
    
    /// SfM reconstruction failed
    public static let C_SFM_FAILED = SSOTErrorCode(
        domain: ErrorDomains.pipeline,
        code: 4001,
        stableName: "C_SFM_FAILED",
        severity: .high,
        retry: .manual,
        defaultUserMessage: "3D reconstruction failed",
        developerHint: "Check input images and SfM parameters"
    )
    
    /// No valid images for SfM
    public static let C_SFM_NO_IMAGES = SSOTErrorCode(
        domain: ErrorDomains.pipeline,
        code: 4002,
        stableName: "C_SFM_NO_IMAGES",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "No valid images found",
        developerHint: "Check image format and validity"
    )
    
    /// Gaussian count clamped
    public static let C_GAUSSIANS_CLAMPED = SSOTErrorCode(
        domain: ErrorDomains.pipeline,
        code: 4003,
        stableName: "C_GAUSSIANS_CLAMPED",
        severity: .low,
        retry: .none,
        defaultUserMessage: "Detail level adjusted to system limits",
        developerHint: "Gaussian count was clamped to maximum"
    )
    
    /// Training timeout
    public static let C_TRAINING_TIMEOUT = SSOTErrorCode(
        domain: ErrorDomains.pipeline,
        code: 4004,
        stableName: "C_TRAINING_TIMEOUT",
        severity: .high,
        retry: .manual,
        defaultUserMessage: "Processing timeout",
        developerHint: "Check processing time limits and system resources"
    )
    
    /// Training failed
    public static let C_TRAINING_FAILED = SSOTErrorCode(
        domain: ErrorDomains.pipeline,
        code: 4005,
        stableName: "C_TRAINING_FAILED",
        severity: .high,
        retry: .manual,
        defaultUserMessage: "Training failed",
        developerHint: "Check training parameters and input data"
    )
    
    // MARK: - Quality Domain (5000-5999, prefix C_)
    
    /// SFM registration ratio too low
    public static let C_SFM_REGISTRATION_TOO_LOW = SSOTErrorCode(
        domain: ErrorDomains.quality,
        code: 5001,
        stableName: "C_SFM_REGISTRATION_TOO_LOW",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "Image alignment failed",
        developerHint: "Check image quality and overlap"
    )
    
    /// PSNR below minimum
    public static let C_PSNR_BELOW_MIN = SSOTErrorCode(
        domain: ErrorDomains.quality,
        code: 5002,
        stableName: "C_PSNR_BELOW_MIN",
        severity: .medium,
        retry: .none,
        defaultUserMessage: "Quality too low",
        developerHint: "Check reconstruction quality thresholds"
    )
    
    /// Quality score below rejection threshold
    public static let C_QUALITY_SCORE_BELOW_REJECT = SSOTErrorCode(
        domain: ErrorDomains.quality,
        code: 5003,
        stableName: "C_QUALITY_SCORE_BELOW_REJECT",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Quality check failed",
        developerHint: "Quality score below rejection threshold"
    )
    
    /// Quality input data missing
    public static let C_QUALITY_INPUT_MISSING = SSOTErrorCode(
        domain: ErrorDomains.quality,
        code: 5004,
        stableName: "C_QUALITY_INPUT_MISSING",
        severity: .high,
        retry: .none,
        defaultUserMessage: "Missing quality data",
        developerHint: "Check quality input data availability"
    )
    
    /// PSNR below recommended value
    public static let C_PSNR_BELOW_RECOMMENDED = SSOTErrorCode(
        domain: ErrorDomains.quality,
        code: 5005,
        stableName: "C_PSNR_BELOW_RECOMMENDED",
        severity: .low,
        retry: .none,
        defaultUserMessage: "Quality below recommended",
        developerHint: "PSNR is below recommended threshold"
    )
    
    // MARK: - System Domain (6000-6999, prefix S_)
    
    /// Internal error
    public static let S_INTERNAL_ERROR = SSOTErrorCode(
        domain: ErrorDomains.system,
        code: 6001,
        stableName: "S_INTERNAL_ERROR",
        severity: .critical,
        retry: .none,
        defaultUserMessage: "Internal error occurred",
        developerHint: "Unexpected internal error"
    )
    
    /// System assertion failed (note: SSOT_ASSERTION_FAILED is 1003)
    public static let S_SYSTEM_ASSERTION_FAILED = SSOTErrorCode(
        domain: ErrorDomains.system,
        code: 6002,
        stableName: "S_ASSERTION_FAILED",
        severity: .critical,
        retry: .none,
        defaultUserMessage: "System assertion failed",
        developerHint: "This indicates a programming error"
    )
    
    /// Configuration error
    public static let S_CONFIGURATION_ERROR = SSOTErrorCode(
        domain: ErrorDomains.system,
        code: 6003,
        stableName: "S_CONFIGURATION_ERROR",
        severity: .critical,
        retry: .none,
        defaultUserMessage: "Configuration error",
        developerHint: "Check system configuration"
    )
    
    // MARK: - Registry
    
    /// All error codes
    public static let all: [SSOTErrorCode] = [
        // SSOT domain (1000-1999)
        S_INVALID_SPEC,
        S_EXCEEDED_MAX,
        S_UNDERFLOWED_MIN,
        S_ASSERTION_FAILED,
        S_REGISTRY_INVALID,
        S_DUPLICATE_ERROR_CODE,
        S_DUPLICATE_SPEC_ID,
        // Capture domain (1000-1999)
        E_FRAMES_CLAMPED,
        E_FRAMES_TOO_FEW,
        E_CAPTURE_INVALID,
        E_CAPTURE_CORRUPTED,
        // Storage domain (2000-2999)
        E_STORAGE_LOW,
        E_STORAGE_WRITE_FAILED,
        E_STORAGE_READ_FAILED,
        // Network domain (3000-3999)
        E_UPLOAD_FAILED,
        E_DOWNLOAD_FAILED,
        E_UPLOAD_TOO_LARGE,
        E_NETWORK_TIMEOUT,
        // Pipeline domain (4000-4999)
        C_SFM_FAILED,
        C_SFM_NO_IMAGES,
        C_GAUSSIANS_CLAMPED,
        C_TRAINING_TIMEOUT,
        C_TRAINING_FAILED,
        // Quality domain (5000-5999)
        C_SFM_REGISTRATION_TOO_LOW,
        C_PSNR_BELOW_MIN,
        C_QUALITY_SCORE_BELOW_REJECT,
        C_QUALITY_INPUT_MISSING,
        C_PSNR_BELOW_RECOMMENDED,
        // System domain (6000-6999)
        S_INTERNAL_ERROR,
        S_SYSTEM_ASSERTION_FAILED,
        S_CONFIGURATION_ERROR
    ]
}

