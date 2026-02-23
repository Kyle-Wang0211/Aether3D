// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  FpsTier.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  FPS tier enumeration (full/degraded/emergency)
//

import Foundation

/// FpsTier - FPS performance tier
/// Full: ≥30fps, Degraded: 20-29fps, Emergency: <20fps
public enum FpsTier: String, Codable {
    case full = "full"
    case degraded = "degraded"
    case emergency = "emergency"
}

/// QualityLevel - alias for FpsTier (synonym for clarity)
public typealias QualityLevel = FpsTier

