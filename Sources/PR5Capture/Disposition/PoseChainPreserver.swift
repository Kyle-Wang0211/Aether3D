// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PoseChainPreserver.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 2 + D: 帧处理决策和账本完整性
// 跟踪摘要创建，最小特征保留，IMU 数据保留
//

import Foundation

/// Pose chain preserver
///
/// Creates tracking summaries and preserves minimum features.
/// Retains IMU data for quality verification.
public actor PoseChainPreserver {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Pose chain history
    private var poseChain: [PoseEntry] = []
    
    /// Tracking summaries
    private var trackingSummaries: [TrackingSummary] = []
    
    /// IMU data cache
    private var imuDataCache: [UInt64: IMUData] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Pose Chain Management
    
    /// Add pose to chain
    public func addPose(
        frameId: UInt64,
        pose: Pose,
        features: [Feature],
        imuData: IMUData?
    ) {
        let entry = PoseEntry(
            frameId: frameId,
            pose: pose,
            features: features,
            timestamp: Date()
        )
        
        poseChain.append(entry)
        
        // Keep only recent poses (last 100)
        if poseChain.count > 100 {
            poseChain.removeFirst()
        }
        
        // Cache IMU data
        if let imu = imuData {
            imuDataCache[frameId] = imu
            
            // Keep only recent IMU data (last 100)
            if imuDataCache.count > 100 {
                let sortedKeys = imuDataCache.keys.sorted()
                for key in sortedKeys.prefix(imuDataCache.count - 100) {
                    imuDataCache.removeValue(forKey: key)
                }
            }
        }
    }
    
    /// Create tracking summary
    ///
    /// Creates a summary with minimum features preserved
    public func createTrackingSummary(
        frameId: UInt64,
        minFeatures: Int = 10
    ) -> TrackingSummary? {
        guard let entry = poseChain.first(where: { $0.frameId == frameId }) else {
            return nil
        }
        
        // Preserve minimum features
        let preservedFeatures = Array(entry.features.prefix(minFeatures))
        
        // Get IMU data if available
        let imuData = imuDataCache[frameId]
        
        let summary = TrackingSummary(
            frameId: frameId,
            pose: entry.pose,
            features: preservedFeatures,
            imuData: imuData,
            timestamp: entry.timestamp
        )
        
        trackingSummaries.append(summary)
        
        // Keep only recent summaries (last 50)
        if trackingSummaries.count > 50 {
            trackingSummaries.removeFirst()
        }
        
        return summary
    }
    
    // MARK: - Queries
    
    /// Get pose chain
    public func getPoseChain() -> [PoseEntry] {
        return poseChain
    }
    
    /// Get tracking summaries
    public func getTrackingSummaries() -> [TrackingSummary] {
        return trackingSummaries
    }
    
    /// Get IMU data for frame
    public func getIMUData(for frameId: UInt64) -> IMUData? {
        return imuDataCache[frameId]
    }
    
    // MARK: - Data Types
    
    /// Pose
    public struct Pose: Codable, Sendable {
        public let position: SIMD3<Double>
        public let orientation: SIMD4<Double>  // Quaternion
        
        public init(position: SIMD3<Double>, orientation: SIMD4<Double>) {
            self.position = position
            self.orientation = orientation
        }
    }
    
    /// Feature
    public struct Feature: Codable, Sendable {
        public let id: UInt64
        public let position: SIMD2<Double>
        public let descriptor: Data
        
        public init(id: UInt64, position: SIMD2<Double>, descriptor: Data) {
            self.id = id
            self.position = position
            self.descriptor = descriptor
        }
    }
    
    /// IMU data
    public struct IMUData: Codable, Sendable {
        public let acceleration: SIMD3<Double>
        public let angularVelocity: SIMD3<Double>
        public let timestamp: Date
        
        public init(acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, timestamp: Date = Date()) {
            self.acceleration = acceleration
            self.angularVelocity = angularVelocity
            self.timestamp = timestamp
        }
    }
    
    /// Pose entry
    public struct PoseEntry: Sendable {
        public let frameId: UInt64
        public let pose: Pose
        public let features: [Feature]
        public let timestamp: Date
    }
    
    /// Tracking summary
    public struct TrackingSummary: Sendable {
        public let frameId: UInt64
        public let pose: Pose
        public let features: [Feature]
        public let imuData: IMUData?
        public let timestamp: Date
    }
}
