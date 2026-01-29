//
//  CaptureQualityPreset.swift
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

/// Quality preset for capture configuration.
///
/// Presets define a combination of resolution, frame rate, codec, and bitrate
/// optimized for different use cases. Higher presets consume more storage and battery.
///
/// - economy: Minimal quality for longest battery life (720p30, H.264)
/// - standard: Balanced quality for everyday use (1080p30, HEVC)
/// - high: High quality for detailed capture (4K30, HEVC)
/// - ultra: Maximum quality with HDR (4K60, HEVC, HDR)
/// - proRes: Professional quality for post-processing (4K30, ProRes 422)
/// - proResMax: Maximum professional quality (4K60, ProRes 422 HQ)
///
/// - Important: `proRes` and `proResMax` require iPhone 15 Pro or later.
public enum CaptureQualityPreset: String, Codable, CaseIterable, Equatable {
    case economy = "economy"
    case standard = "standard"
    case high = "high"
    case ultra = "ultra"
    case proRes = "proRes"
    case proResMax = "proResMax"
    
    /// Preset ID for digest computation
    public var presetId: UInt8 {
        switch self {
        case .economy: return 1
        case .standard: return 2
        case .high: return 3
        case .ultra: return 4
        case .proRes: return 5
        case .proResMax: return 6
        }
    }
}

/// Preset configuration mapping
public struct CaptureQualityPresetConfig {
    public let tier: String
    public let fps: Int
    public let codec: String
    public let bitrateMbps: Int
    public let hdr: Bool
    
    public init(tier: String, fps: Int, codec: String, bitrateMbps: Int, hdr: Bool = false) {
        self.tier = tier
        self.fps = fps
        self.codec = codec
        self.bitrateMbps = bitrateMbps
        self.hdr = hdr
    }
}

extension CaptureQualityPreset {
    /// Preset configurations
    public static let presetConfigs: [CaptureQualityPreset: CaptureQualityPresetConfig] = [
        .economy: CaptureQualityPresetConfig(tier: "720p", fps: 30, codec: "h264", bitrateMbps: 15),
        .standard: CaptureQualityPresetConfig(tier: "1080p", fps: 30, codec: "hevc", bitrateMbps: 30),
        .high: CaptureQualityPresetConfig(tier: "4K", fps: 30, codec: "hevc", bitrateMbps: 75),
        .ultra: CaptureQualityPresetConfig(tier: "4K", fps: 60, codec: "hevc", bitrateMbps: 120, hdr: true),
        .proRes: CaptureQualityPresetConfig(tier: "4K", fps: 30, codec: "appleProRes422", bitrateMbps: 165),
        .proResMax: CaptureQualityPresetConfig(tier: "4K", fps: 60, codec: "appleProRes422HQ", bitrateMbps: 330)
    ]
}
