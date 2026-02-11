// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  HintDomain.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Hint domain and strength enumerations
//

import Foundation

/// HintDomain - domain of visual hint
public enum HintDomain: String, Codable {
    case focus = "focus"
    case light = "light"
    case motion = "motion"
    case texture = "texture"
    case navigation = "navigation"
}

/// HintStrength - strength of visual hint
public enum HintStrength: String, Codable {
    case strong = "strong"
    case subtle = "subtle"
}

