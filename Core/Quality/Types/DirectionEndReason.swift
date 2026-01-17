//
//  DirectionEndReason.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 0
//  Direction end reason and category enumerations
//

import Foundation

/// DirectionEndReason - reason for direction exit
public enum DirectionEndReason: String, Codable {
    case valueExhausted = "valueExhausted"
    case qualityBlocked = "qualityBlocked"
    case sessionComplete = "sessionComplete"
}

/// DirectionEndCategory - category of direction end
public enum DirectionEndCategory: String, Codable {
    case exhausted = "exhausted"
    case blocked = "blocked"
    case complete = "complete"
}

