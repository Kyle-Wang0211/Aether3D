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

