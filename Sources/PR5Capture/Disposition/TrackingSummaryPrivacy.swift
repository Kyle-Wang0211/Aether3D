//
// TrackingSummaryPrivacy.swift
// PR5Capture
//
// PR5 v1.8.1 - PART D: 账本完整性增强
// 跟踪摘要隐私保护
//

import Foundation

/// Tracking summary privacy protector
///
/// Protects privacy in tracking summaries by applying anonymization.
/// Ensures sensitive information is not exposed in summaries.
public actor TrackingSummaryPrivacy {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Privacy Levels
    
    public enum PrivacyLevel: String, Codable, Sendable, CaseIterable {
        case none       // No privacy protection
        case basic      // Basic anonymization
        case standard   // Standard privacy protection
        case strict    // Strict privacy protection
    }
    
    // MARK: - State
    
    /// Current privacy level
    private var privacyLevel: PrivacyLevel = .standard
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Privacy Protection
    
    /// Anonymize tracking summary
    ///
    /// Applies privacy protection to tracking summary
    public func anonymizeSummary(
        _ summary: PoseChainPreserver.TrackingSummary
    ) -> AnonymizedSummary {
        switch privacyLevel {
        case .none:
            return AnonymizedSummary(
                frameId: summary.frameId,
                anonymizedPose: summary.pose,
                featureCount: summary.features.count,
                hasIMUData: summary.imuData != nil,
                privacyLevel: .none
            )
            
        case .basic:
            // Basic: Remove feature descriptors, keep counts
            return AnonymizedSummary(
                frameId: summary.frameId,
                anonymizedPose: anonymizePose(summary.pose, level: .basic),
                featureCount: summary.features.count,
                hasIMUData: summary.imuData != nil,
                privacyLevel: .basic
            )
            
        case .standard:
            // Standard: Quantize pose, remove IMU details
            return AnonymizedSummary(
                frameId: summary.frameId,
                anonymizedPose: anonymizePose(summary.pose, level: .standard),
                featureCount: summary.features.count,
                hasIMUData: false,  // Hide IMU data presence
                privacyLevel: .standard
            )
            
        case .strict:
            // Strict: Heavily quantize pose, minimal information
            return AnonymizedSummary(
                frameId: summary.frameId,
                anonymizedPose: anonymizePose(summary.pose, level: .strict),
                featureCount: quantizeFeatureCount(summary.features.count),
                hasIMUData: false,
                privacyLevel: .strict
            )
        }
    }
    
    /// Anonymize pose
    private func anonymizePose(_ pose: PoseChainPreserver.Pose, level: PrivacyLevel) -> PoseChainPreserver.Pose {
        switch level {
        case .none:
            return pose
            
        case .basic:
            // Round to 0.1m precision
            let quantizedPosition = SIMD3<Double>(
                round(pose.position.x * 10.0) / 10.0,
                round(pose.position.y * 10.0) / 10.0,
                round(pose.position.z * 10.0) / 10.0
            )
            return PoseChainPreserver.Pose(position: quantizedPosition, orientation: pose.orientation)
            
        case .standard:
            // Round to 1.0m precision
            let quantizedPosition = SIMD3<Double>(
                round(pose.position.x),
                round(pose.position.y),
                round(pose.position.z)
            )
            return PoseChainPreserver.Pose(position: quantizedPosition, orientation: pose.orientation)
            
        case .strict:
            // Round to 5.0m precision
            let quantizedPosition = SIMD3<Double>(
                round(pose.position.x / 5.0) * 5.0,
                round(pose.position.y / 5.0) * 5.0,
                round(pose.position.z / 5.0) * 5.0
            )
            return PoseChainPreserver.Pose(position: quantizedPosition, orientation: pose.orientation)
        }
    }
    
    /// Quantize feature count
    private func quantizeFeatureCount(_ count: Int) -> Int {
        // Round to nearest 10
        return (count / 10) * 10
    }
    
    /// Set privacy level
    public func setPrivacyLevel(_ level: PrivacyLevel) {
        privacyLevel = level
    }
    
    /// Get privacy level
    public func getPrivacyLevel() -> PrivacyLevel {
        return privacyLevel
    }
    
    // MARK: - Data Types
    
    /// Anonymized summary
    public struct AnonymizedSummary: Sendable {
        public let frameId: UInt64
        public let anonymizedPose: PoseChainPreserver.Pose
        public let featureCount: Int
        public let hasIMUData: Bool
        public let privacyLevel: PrivacyLevel
    }
}
