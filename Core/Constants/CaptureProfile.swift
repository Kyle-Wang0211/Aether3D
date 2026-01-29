//
//  CaptureProfile.swift
//  Aether3D
//
//  PR#4 Capture Recording Enhancement
//
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR4-CAPTURE-1.1
// States: N/A | Warnings: 32 | QualityPresets: 6 | ResolutionTiers: 7
// ============================================================================

import Foundation

/// Capture profile for different scanning scenarios
public enum CaptureProfile: UInt8, Codable, CaseIterable, Equatable {
    case standard = 1
    case smallObjectMacro = 2
    case largeScene = 3
    case proMacro = 4           // NEW: Pro-level macro scanning
    case cinematicScene = 5     // NEW: Cinematic capture mode
    
    /// Recommended settings for each profile
    public var recommendedSettings: ProfileSettings {
        switch self {
        case .standard:
            return ProfileSettings(
                minTier: .t1080p,
                preferredFps: 30,
                preferHDR: true,
                focusMode: .continuousAuto,
                scanPattern: .orbital
            )
        case .smallObjectMacro:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 60,
                preferHDR: true,
                focusMode: .macro,
                scanPattern: .closeUp
            )
        case .largeScene:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 30,
                preferHDR: true,
                focusMode: .continuousAuto,
                scanPattern: .walkthrough
            )
        case .proMacro:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 60,
                preferHDR: true,
                focusMode: .macroLocked,
                scanPattern: .turntable
            )
        case .cinematicScene:
            return ProfileSettings(
                minTier: .t4K,
                preferredFps: 24,
                preferHDR: true,
                focusMode: .rackFocus,
                scanPattern: .dolly
            )
        }
    }
}

/// Profile settings configuration
public struct ProfileSettings: Codable, Equatable {
    public let minTier: ResolutionTier
    public let preferredFps: Int
    public let preferHDR: Bool
    public let focusMode: FocusMode
    public let scanPattern: ScanPattern
    
    public init(minTier: ResolutionTier, preferredFps: Int, preferHDR: Bool, focusMode: FocusMode, scanPattern: ScanPattern) {
        self.minTier = minTier
        self.preferredFps = preferredFps
        self.preferHDR = preferHDR
        self.focusMode = focusMode
        self.scanPattern = scanPattern
    }
}

/// Focus mode for capture
public enum FocusMode: String, Codable, CaseIterable, Equatable {
    case continuousAuto
    case macro
    case macroLocked
    case rackFocus
    case infinity
}

/// Scan pattern for 3D reconstruction
public enum ScanPattern: String, Codable, CaseIterable, Equatable {
    case orbital      // Circle around object
    case closeUp      // Detailed surface scan
    case walkthrough  // Move through space
    case turntable    // Object on turntable
    case dolly        // Cinematic camera movement
}
