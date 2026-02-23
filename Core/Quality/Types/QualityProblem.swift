// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  QualityProblem.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Quality problem enumeration (for dominantProblem)
//

import Foundation

/// QualityProblem - dominant quality problem
public enum QualityProblem: String, Codable {
    case none = "none"
    case brightness = "brightness"
    case blur = "blur"
    case motion = "motion"
    case exposure = "exposure"
    case focus = "focus"
    case texture = "texture"
}

