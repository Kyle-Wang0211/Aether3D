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
}

