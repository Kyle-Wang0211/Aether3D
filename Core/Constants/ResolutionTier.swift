// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ResolutionTier.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 32 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation

// CI-HARDENED: Core-owned type for resolution tier classification.
// This type must be platform-agnostic and Foundation-only.

/// Resolution tier classification (closed set).
/// Used for bitrate estimation and format selection.
///
/// Tiers are ordered from highest to lowest resolution:
/// - t8K: 7680x4320 and above
/// - t4K: 3840x2160 (UHD)
/// - t2K: 2560x1440 (QHD) - NEW
/// - t1080p: 1920x1080 (Full HD)
/// - t720p: 1280x720 (HD)
/// - t480p: 640x480 (SD) - NEW
/// - lower: Below 480p
public enum ResolutionTier: String, Codable, CaseIterable, Equatable {
    case t8K = "8K"
    case t4K = "4K"
    case t1080p = "1080p"
    case t720p = "720p"
    case lower = "lower"
    case t2K = "2K"       // NEW: 2560x1440 (QHD)
    case t480p = "480p"   // NEW: Legacy SD
    
    /// Minimum dimension threshold for this tier
    public var minDimension: Int {
        switch self {
        case .t8K: return 7680
        case .t4K: return 3840
        case .t2K: return 2560
        case .t1080p: return 1920
        case .t720p: return 1280
        case .t480p: return 640
        case .lower: return 0
        }
    }
    
    /// Recommended bitrate (bps) for this tier at 30fps
    public var recommendedBitrate30fps: Int64 {
        switch self {
        case .t8K: return 200_000_000
        case .t4K: return 75_000_000
        case .t2K: return 50_000_000
        case .t1080p: return 30_000_000
        case .t720p: return 18_000_000
        case .t480p: return 8_000_000
        case .lower: return 4_000_000
        }
    }
    
    /// Quality score (higher = better)
    public var qualityScore: Int {
        switch self {
        case .t8K: return 100
        case .t4K: return 80
        case .t2K: return 60
        case .t1080p: return 50
        case .t720p: return 30
        case .t480p: return 15
        case .lower: return 5
        }
    }
    
    /// Suitable for 3D reconstruction?
    public var suitableFor3DReconstruction: Bool {
        switch self {
        case .t8K, .t4K, .t2K, .t1080p: return true
        case .t720p, .t480p, .lower: return false
        }
    }
}

