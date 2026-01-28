//
//  FreezeReason.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Freeze reason and category enumerations
//

import Foundation

/// FreezeReason - reason for freezing decisions
public enum FreezeReason: String, Codable {
    case insufficientQuality = "insufficientQuality"
    case emergencyMode = "emergencyMode"
    case corruptedEvidence = "corruptedEvidence"
    case excessiveCommits = "excessiveCommits"
}

/// FreezeCategory - category of freeze
public enum FreezeCategory: String, Codable {
    case quality = "quality"
    case performance = "performance"
    case integrity = "integrity"
}

