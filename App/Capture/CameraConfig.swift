//
// CameraConfig.swift
// Aether3D
//
// Camera Configuration - iOS 18/19 Camera API integration
// 符合 PR4-01: iOS 18/19 Camera API Integration
//

import Foundation
import AVFoundation

/// Camera Configuration
///
/// Configuration for advanced camera features (iOS 18+).
/// Supports Zero Shutter Lag, Deferred Processing, 4K ARKit, ProRes RAW.
public struct CameraConfig: Sendable {
    /// Video resolution
    public let resolution: VideoResolution
    
    /// Frame rate
    public let frameRate: Double
    
    /// Video codec
    public let codec: VideoCodec
    
    /// Enable HDR
    public let enableHDR: Bool
    
    /// Enable ProRes RAW (if available)
    public let enableProResRAW: Bool
    
    /// Enable Zero Shutter Lag
    public let enableZeroShutterLag: Bool
    
    /// Enable Deferred Processing
    public let enableDeferredProcessing: Bool
    
    /// Enable ARKit integration
    public let enableARKit: Bool
    
    /// Maximum recording duration (seconds)
    public let maxDuration: TimeInterval
    
    /// Maximum file size (bytes)
    public let maxFileSize: Int64
    
    public init(
        resolution: VideoResolution = .resolution4K,
        frameRate: Double = 60.0,
        codec: VideoCodec = .hevc,
        enableHDR: Bool = true,
        enableProResRAW: Bool = false,
        enableZeroShutterLag: Bool = true,
        enableDeferredProcessing: Bool = true,
        enableARKit: Bool = true,
        maxDuration: TimeInterval = 120.0,
        maxFileSize: Int64 = 2_000_000_000 // 2GB
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.enableHDR = enableHDR
        self.enableProResRAW = enableProResRAW
        self.enableZeroShutterLag = enableZeroShutterLag
        self.enableDeferredProcessing = enableDeferredProcessing
        self.enableARKit = enableARKit
        self.maxDuration = maxDuration
        self.maxFileSize = maxFileSize
    }
}

/// Video Resolution
public enum VideoResolution: String, Codable, Sendable {
    case resolution1080p = "1080p"
    case resolution4K = "4K"
    case resolution4K60 = "4K60"
    
    public var dimensions: CMVideoDimensions {
        switch self {
        case .resolution1080p:
            return CMVideoDimensions(width: 1920, height: 1080)
        case .resolution4K:
            return CMVideoDimensions(width: 3840, height: 2160)
        case .resolution4K60:
            return CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

/// Video Codec
public enum VideoCodec: String, Codable, Sendable {
    case h264 = "H.264"
    case hevc = "HEVC"
    case proResRAW = "ProRes RAW"
    case proRes422 = "ProRes 422"
}
