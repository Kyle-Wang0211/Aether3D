// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SessionCompletionStatus.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Session completion status enumeration
//

import Foundation

/// SessionCompletionStatus - session completion status
public enum SessionCompletionStatus: String, Codable {
    case completed = "completed"
    case corruptedEvidence = "corruptedEvidence"
    case excessiveCommits = "excessiveCommits"
    case interrupted = "interrupted"
}

