// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// IntrinsicsDriftMonitor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART A: Raw 溯源和 ISP 真实性
// 焦距漂移监控，内参稳定性检查
//

import Foundation

/// Intrinsics drift monitor
///
/// Monitors focal length drift and intrinsic parameter stability.
/// Detects changes in camera intrinsics that could affect quality.
public actor IntrinsicsDriftMonitor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Baseline intrinsics (established at session start)
    private var baselineIntrinsics: CameraIntrinsics?
    
    /// Intrinsics history
    private var intrinsicsHistory: [(timestamp: Date, intrinsics: CameraIntrinsics)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Intrinsics Management
    
    /// Establish baseline intrinsics
    ///
    /// Called at session start to establish reference intrinsics
    public func establishBaseline(_ intrinsics: CameraIntrinsics) {
        baselineIntrinsics = intrinsics
        intrinsicsHistory.append((timestamp: Date(), intrinsics: intrinsics))
    }
    
    /// Monitor intrinsics for drift
    ///
    /// Compares current intrinsics against baseline and detects drift
    public func monitorDrift(_ currentIntrinsics: CameraIntrinsics) -> IntrinsicsDriftResult {
        guard let baseline = baselineIntrinsics else {
            // No baseline yet - establish it
            establishBaseline(currentIntrinsics)
            return IntrinsicsDriftResult(
                hasDrift: false,
                focalLengthDrift: 0.0,
                principalPointDrift: 0.0,
                threshold: 0.0,
                baseline: nil,
                current: currentIntrinsics
            )
        }
        
        // Calculate focal length drift
        let focalLengthDrift = abs(currentIntrinsics.focalLength - baseline.focalLength) / baseline.focalLength
        
        // Calculate principal point drift
        let principalPointDrift = sqrt(
            pow(currentIntrinsics.principalPointX - baseline.principalPointX, 2) +
            pow(currentIntrinsics.principalPointY - baseline.principalPointY, 2)
        )
        
        // Get threshold from config (using lens change detection threshold as proxy)
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Sensor.lensChangeDetectionThreshold,
            profile: config.profile
        )
        
        let hasDrift = focalLengthDrift >= threshold || principalPointDrift >= threshold
        
        // Record in history
        intrinsicsHistory.append((timestamp: Date(), intrinsics: currentIntrinsics))
        
        return IntrinsicsDriftResult(
            hasDrift: hasDrift,
            focalLengthDrift: focalLengthDrift,
            principalPointDrift: principalPointDrift,
            threshold: threshold,
            baseline: baseline,
            current: currentIntrinsics
        )
    }
    
    // MARK: - History
    
    /// Get intrinsics history
    public func getIntrinsicsHistory() -> [(timestamp: Date, intrinsics: CameraIntrinsics)] {
        return intrinsicsHistory
    }
    
    // MARK: - Data Types
    
    /// Camera intrinsics
    public struct CameraIntrinsics: Codable, Sendable {
        public let focalLength: Double
        public let principalPointX: Double
        public let principalPointY: Double
        public let skew: Double
        
        public init(
            focalLength: Double,
            principalPointX: Double,
            principalPointY: Double,
            skew: Double = 0.0
        ) {
            self.focalLength = focalLength
            self.principalPointX = principalPointX
            self.principalPointY = principalPointY
            self.skew = skew
        }
    }
    
    /// Intrinsics drift result
    public struct IntrinsicsDriftResult: Sendable {
        public let hasDrift: Bool
        public let focalLengthDrift: Double
        public let principalPointDrift: Double
        public let threshold: Double
        public let baseline: CameraIntrinsics?
        public let current: CameraIntrinsics?
    }
}
