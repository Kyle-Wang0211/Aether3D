// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  RuleId.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Single source of truth for RuleId enumeration (PART 9.5)
//

import Foundation

/// Rule ID enumeration - closed set for audit traceability
/// Each rule ID represents a decision path taken during quality evaluation
public enum RuleId: String, Codable, CaseIterable {
    // Brightness rules
    case BRIGHTNESS_PASS = "BRIGHTNESS_PASS"
    case BRIGHTNESS_FAIL = "BRIGHTNESS_FAIL"
    case BRIGHTNESS_FLICKER = "BRIGHTNESS_FLICKER"
    
    // Laplacian/Blur rules
    case LAPLACIAN_PASS = "LAPLACIAN_PASS"
    case LAPLACIAN_FAIL = "LAPLACIAN_FAIL"
    case LAPLACIAN_NOISY = "LAPLACIAN_NOISY"
    
    // Feature score rules
    case FEATURE_SCORE_PASS = "FEATURE_SCORE_PASS"
    case FEATURE_SCORE_FAIL = "FEATURE_SCORE_FAIL"
    case FEATURE_SCORE_REPETITIVE = "FEATURE_SCORE_REPETITIVE"
    
    // Motion rules
    case MOTION_PASS = "MOTION_PASS"
    case MOTION_FAIL = "MOTION_FAIL"
    case MOTION_HANDSHAKE = "MOTION_HANDSHAKE"
    case MOTION_FAST_PAN = "MOTION_FAST_PAN"
    
    // Exposure rules
    case EXPOSURE_PASS = "EXPOSURE_PASS"
    case EXPOSURE_OVEREXPOSE = "EXPOSURE_OVEREXPOSE"
    case EXPOSURE_UNDEREXPOSE = "EXPOSURE_UNDEREXPOSE"
    
    // Focus rules
    case FOCUS_SHARP = "FOCUS_SHARP"
    case FOCUS_HUNTING = "FOCUS_HUNTING"
    case FOCUS_FAILED = "FOCUS_FAILED"
    
    // Confidence gate rules
    case CONFIDENCE_PASS = "CONFIDENCE_PASS"
    case CONFIDENCE_FAIL = "CONFIDENCE_FAIL"
    
    // Stability rules
    case STABILITY_PASS = "STABILITY_PASS"
    case STABILITY_FAIL = "STABILITY_FAIL"
    
    // FPS tier rules
    case FPS_FULL = "FPS_FULL"
    case FPS_DEGRADED = "FPS_DEGRADED"
    case FPS_EMERGENCY = "FPS_EMERGENCY"
    
    // Direction rules
    case DIR_ENTER = "DIR_ENTER"
    case DIR_EXIT_VALUE_EXHAUSTED = "DIR_EXIT_VALUE_EXHAUSTED"
    case DIR_EXIT_QUALITY_BLOCKED = "DIR_EXIT_QUALITY_BLOCKED"
    
    // White commit rules
    case WHITE_COMMIT_SUCCESS = "WHITE_COMMIT_SUCCESS"
    case WHITE_COMMIT_FAIL = "WHITE_COMMIT_FAIL"
    case WHITE_COMMIT_CORRUPTED_EVIDENCE = "WHITE_COMMIT_CORRUPTED_EVIDENCE"

    // =========================================================================
    // PR5-QUALITY-2.0 NEW RULE IDS
    // APPEND ONLY - DO NOT INSERT OR REORDER
    // =========================================================================

    // Tenengrad rules
    case TENENGRAD_PASS = "TENENGRAD_PASS"
    case TENENGRAD_FAIL = "TENENGRAD_FAIL"
    case TENENGRAD_DEGRADED = "TENENGRAD_DEGRADED"

    // SfM feature rules
    case SFM_FEATURES_PASS = "SFM_FEATURES_PASS"
    case SFM_FEATURES_WARN = "SFM_FEATURES_WARN"
    case SFM_FEATURES_FAIL = "SFM_FEATURES_FAIL"
    case SFM_FEATURES_CLUSTERED = "SFM_FEATURES_CLUSTERED"

    // Material detection rules
    case MATERIAL_SPECULAR_DETECTED = "MATERIAL_SPECULAR_DETECTED"
    case MATERIAL_TRANSPARENT_WARNING = "MATERIAL_TRANSPARENT_WARNING"
    case MATERIAL_TEXTURELESS_WARNING = "MATERIAL_TEXTURELESS_WARNING"

    // Advanced motion rules
    case MOTION_ANGULAR_VELOCITY_EXCEEDED = "MOTION_ANGULAR_VELOCITY_EXCEEDED"
    case MOTION_BLUR_RISK_HIGH = "MOTION_BLUR_RISK_HIGH"

    // Photometric consistency rules
    case PHOTOMETRIC_LUMINANCE_INCONSISTENT = "PHOTOMETRIC_LUMINANCE_INCONSISTENT"
    case PHOTOMETRIC_EXPOSURE_JUMP = "PHOTOMETRIC_EXPOSURE_JUMP"
    case PHOTOMETRIC_LAB_VARIANCE_EXCEEDED = "PHOTOMETRIC_LAB_VARIANCE_EXCEEDED"

    // Depth quality rules
    case DEPTH_CONFIDENCE_LOW = "DEPTH_CONFIDENCE_LOW"
    case DEPTH_VARIANCE_HIGH = "DEPTH_VARIANCE_HIGH"
}

