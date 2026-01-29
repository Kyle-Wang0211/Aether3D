//
//  CaptureProfile.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - PR5-QUALITY-2.0
//  Capture profile definitions for profile-aware thresholds
//

import Foundation

/// CaptureProfile - defines the type of 3D capture scenario
/// Used for profile-aware quality thresholds
public enum CaptureProfile: UInt8, Codable, CaseIterable, Equatable {
    /// Standard object scanning (default)
    case standard = 1

    /// Small object macro photography
    case smallObjectMacro = 2

    /// Large scene capture (rooms, buildings)
    case largeScene = 3

    /// Professional-level macro scanning
    case proMacro = 4

    /// Cinematic scene capture
    case cinematicScene = 5

    /// Human-readable description
    public var description: String {
        switch self {
        case .standard: return "Standard"
        case .smallObjectMacro: return "Small Object (Macro)"
        case .largeScene: return "Large Scene"
        case .proMacro: return "Professional Macro"
        case .cinematicScene: return "Cinematic Scene"
        }
    }
}
