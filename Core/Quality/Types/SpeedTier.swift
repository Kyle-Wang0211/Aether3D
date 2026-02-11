// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SpeedTier.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Speed tier enumeration (excellent/good/moderate/poor/stopped)
//

import Foundation

/// SpeedTier - progress speed tier
/// Maps to user-facing animation speed feedback
public enum SpeedTier: String, Codable {
    case excellent = "excellent"
    case good = "good"
    case moderate = "moderate"
    case poor = "poor"
    case stopped = "stopped"
}

