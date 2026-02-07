//
// RecordingResult.swift
// Aether3D
//
// Recording Result - Recording output structure
//

import Foundation

/// Recording Result
///
/// Result of a video recording session.
public struct RecordingResult: Sendable {
    /// Output file URL
    public let fileURL: URL
    
    /// Recording duration (seconds)
    public let duration: TimeInterval
    
    /// File size (bytes)
    public let fileSize: Int64
    
    /// Recording start time
    public let startTime: Date
    
    /// Recording end time
    public let endTime: Date
    
    /// Capture metadata
    public let metadata: CaptureMetadata?
    
    /// IMU data (if collected)
    public let imuData: [IMUDataPoint]?
    
    /// LiDAR depth data (if collected)
    public let lidarData: [LiDARDepthFrame]?
    
    /// Recording errors (if any)
    public let errors: [RecordingError]?
    
    public init(
        fileURL: URL,
        duration: TimeInterval,
        fileSize: Int64,
        startTime: Date,
        endTime: Date,
        metadata: CaptureMetadata? = nil,
        imuData: [IMUDataPoint]? = nil,
        lidarData: [LiDARDepthFrame]? = nil,
        errors: [RecordingError]? = nil
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.fileSize = fileSize
        self.startTime = startTime
        self.endTime = endTime
        self.metadata = metadata
        self.imuData = imuData
        self.lidarData = lidarData
        self.errors = errors
    }
}

/// IMU Data Point
public struct IMUDataPoint: Sendable {
    public let timestamp: Date
    public let acceleration: SIMD3<Double>
    public let rotationRate: SIMD3<Double>
    public let magneticField: SIMD3<Double>
    
    public init(timestamp: Date, acceleration: SIMD3<Double>, rotationRate: SIMD3<Double>, magneticField: SIMD3<Double>) {
        self.timestamp = timestamp
        self.acceleration = acceleration
        self.rotationRate = rotationRate
        self.magneticField = magneticField
    }
}

/// LiDAR Depth Frame
public struct LiDARDepthFrame: Sendable {
    public let timestamp: Date
    public let depthMap: Data
    public let confidenceMap: Data?
    
    public init(timestamp: Date, depthMap: Data, confidenceMap: Data? = nil) {
        self.timestamp = timestamp
        self.depthMap = depthMap
        self.confidenceMap = confidenceMap
    }
}

/// Recording Error
public enum RecordingError: Error, Sendable {
    case permissionDenied
    case cameraUnavailable
    case recordingFailed(String)
    case fileSizeExceeded
    case durationExceeded
    case thermalShutdown
    case interruption(String)
    case configurationFailed(ConfigurationError)
    
    public enum ConfigurationError: Sendable {
        case permissionNotDetermined
        case cameraUnavailable
        case formatNotSupported
        case codecNotSupported
    }
}
