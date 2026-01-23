//
// SessionBoundaryConstants.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Session Boundary Constants
//
// This file defines constants for session boundary detection.
//

import Foundation

/// Session boundary constants.
///
/// **Rule ID:** CONTRACT_SESSION_001
/// **Status:** IMMUTABLE
public enum SessionBoundaryConstants {
    
    /// Time gap threshold for new session (30 minutes).
    /// **Rule ID:** CONTRACT_SESSION_001
    /// **Status:** IMMUTABLE
    /// **Unit:** minutes
    /// **Scope:** user_contract
    public static let SESSION_TIME_GAP_THRESHOLD_MINUTES: Int = 30
    
    /// Background threshold for new session (5 minutes).
    /// **Rule ID:** CONTRACT_SESSION_001
    /// **Status:** IMMUTABLE
    /// **Unit:** minutes
    /// **Scope:** user_contract
    public static let SESSION_BACKGROUND_THRESHOLD_MINUTES: Int = 5
    
    /// Maximum frames to search for anchor frame.
    /// **Rule ID:** CONTRACT_SESSION_001
    /// **Status:** IMMUTABLE
    /// **Unit:** frames
    /// **Scope:** user_contract
    public static let SESSION_ANCHOR_SEARCH_MAX_FRAMES: Int = 15
}
