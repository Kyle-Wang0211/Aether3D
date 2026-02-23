// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  DirectionSummary.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 4
//  DirectionSummary - direction summary structure
//

import Foundation

/// DirectionSummaryCore - minimal field set for direction summary
public struct DirectionSummaryCore: Codable {
    public let directionId: DirectionId
    public let endReason: DirectionEndReason
    public let endCategory: DirectionEndCategory
    public let dominantProblem: QualityProblem
    public let firstGrayMs: Int64?
    public let firstWhiteMs: Int64?
    public let preWarningLogged: Bool
    
    public init(
        directionId: DirectionId,
        endReason: DirectionEndReason,
        endCategory: DirectionEndCategory,
        dominantProblem: QualityProblem,
        firstGrayMs: Int64? = nil,
        firstWhiteMs: Int64? = nil,
        preWarningLogged: Bool = false
    ) {
        self.directionId = directionId
        self.endReason = endReason
        self.endCategory = endCategory
        self.dominantProblem = dominantProblem
        self.firstGrayMs = firstGrayMs
        self.firstWhiteMs = firstWhiteMs
        self.preWarningLogged = preWarningLogged
    }
}

