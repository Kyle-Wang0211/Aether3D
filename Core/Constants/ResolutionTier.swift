//
//  ResolutionTier.swift
//  Aether3D
//
//  Created for PR#4 Capture Recording
//
//  CI-HARDENED: Core-owned type for resolution tier classification.
//  This type must be platform-agnostic and Foundation-only.

import Foundation

/// Resolution tier classification (closed set).
/// Used for bitrate estimation and format selection.
public enum ResolutionTier: String, Codable, CaseIterable, Equatable {
    case t8K = "8K"
    case t4K = "4K"
    case t1080p = "1080p"
    case t720p = "720p"
    case lower = "lower"
}

