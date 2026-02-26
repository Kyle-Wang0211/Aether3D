// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

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
struct RecordingResult: Sendable {
    /// Output file URL
    let fileURL: URL

    /// Recording duration (seconds)
    let duration: TimeInterval

    /// File size (bytes)
    let fileSize: Int64

    /// Recording start time
    let startTime: Date

    /// Recording end time
    let endTime: Date

    /// Capture metadata
    let metadata: CaptureMetadata?

    /// IMU data (if collected)
    let imuData: [IMUDataPoint]?

    /// LiDAR depth data (if collected)
    let lidarData: [LiDARDepthFrame]?

    /// Recording errors (if any)
    let errors: [RecordingError]?

    init(
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
struct IMUDataPoint: Sendable {
    let timestamp: Date
    let acceleration: SIMD3<Double>
    let rotationRate: SIMD3<Double>
    let magneticField: SIMD3<Double>

    init(timestamp: Date, acceleration: SIMD3<Double>, rotationRate: SIMD3<Double>, magneticField: SIMD3<Double>) {
        self.timestamp = timestamp
        self.acceleration = acceleration
        self.rotationRate = rotationRate
        self.magneticField = magneticField
    }
}

/// LiDAR Depth Frame
struct LiDARDepthFrame: Sendable {
    let timestamp: Date
    let depthMap: Data
    let confidenceMap: Data?

    init(timestamp: Date, depthMap: Data, confidenceMap: Data? = nil) {
        self.timestamp = timestamp
        self.depthMap = depthMap
        self.confidenceMap = confidenceMap
    }
}

// RecordingError is defined in CaptureMetadata.swift — do not redeclare here
