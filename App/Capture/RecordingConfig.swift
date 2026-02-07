//
// RecordingConfig.swift
// Aether3D
//
// Recording Configuration - Recording configuration parameters
//

import Foundation

/// Recording Configuration
///
/// Configuration parameters for video recording.
public struct RecordingConfig: Sendable {
    /// Minimum recording duration (seconds)
    public let minDuration: TimeInterval
    
    /// Maximum recording duration (seconds)
    public let maxDuration: TimeInterval
    
    /// Maximum file size (bytes)
    public let maxFileSize: Int64
    
    /// Enable metadata collection
    public let enableMetadata: Bool
    
    /// Enable IMU data collection
    public let enableIMU: Bool
    
    /// Enable LiDAR depth collection
    public let enableLiDAR: Bool
    
    /// IMU sampling rate (Hz)
    public let imuSamplingRate: Double
    
    public init(
        minDuration: TimeInterval = 10.0,
        maxDuration: TimeInterval = 120.0,
        maxFileSize: Int64 = 2_000_000_000, // 2GB
        enableMetadata: Bool = true,
        enableIMU: Bool = true,
        enableLiDAR: Bool = true,
        imuSamplingRate: Double = 100.0
    ) {
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.maxFileSize = maxFileSize
        self.enableMetadata = enableMetadata
        self.enableIMU = enableIMU
        self.enableLiDAR = enableLiDAR
        self.imuSamplingRate = imuSamplingRate
    }
}
