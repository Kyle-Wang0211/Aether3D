// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  MetricId.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Metric ID enumeration for quality metrics
//

import Foundation

/// Metric ID enumeration - identifies each quality metric
public enum MetricId: String, Codable, CaseIterable {
    case brightness = "brightness"
    case laplacian = "laplacian"
    case featureScore = "featureScore"
    case motionScore = "motionScore"
    case saturation = "saturation"
    case focus = "focus"
}

