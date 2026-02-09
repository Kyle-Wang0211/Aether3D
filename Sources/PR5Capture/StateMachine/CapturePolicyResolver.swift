// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CapturePolicyResolver.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 1 + C: 状态机加固和增强
// 统一策略解析，冲突仲裁，ISP 补偿应用
//

import Foundation

/// Capture policy resolver
///
/// Resolves capture policies with conflict arbitration.
/// Applies ISP compensation based on detected ISP strength.
public actor CapturePolicyResolver {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Policy Sources
    
    /// Active policies from different sources
    private var activePolicies: [PolicySource: CapturePolicy] = [:]
    
    /// ISP compensation factor (from ISPDetector)
    private var ispCompensationFactor: Double = 1.0
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Policy Management
    
    /// Register policy from a source
    public func registerPolicy(_ policy: CapturePolicy, from source: PolicySource) {
        activePolicies[source] = policy
    }
    
    /// Remove policy from a source
    public func removePolicy(from source: PolicySource) {
        activePolicies.removeValue(forKey: source)
    }
    
    /// Update ISP compensation factor
    public func updateISPCompensation(_ factor: Double) {
        ispCompensationFactor = factor
    }
    
    // MARK: - Policy Resolution
    
    /// Resolve final policy from all sources
    ///
    /// Applies conflict arbitration and ISP compensation
    public func resolvePolicy() -> ResolvedCapturePolicy {
        guard !activePolicies.isEmpty else {
            // Default policy
            return ResolvedCapturePolicy(
                qualityThreshold: 0.7,
                frameRate: 30,
                resolution: .standard,
                ispCompensation: 1.0,
                sources: [],
                conflicts: []
            )
        }
        
        // Collect all policy values
        var qualityThresholds: [Double] = []
        var frameRates: [Int] = []
        var resolutions: [Resolution] = []
        
        for (source, policy) in activePolicies {
            qualityThresholds.append(policy.qualityThreshold)
            frameRates.append(policy.frameRate)
            resolutions.append(policy.resolution)
        }
        
        // Resolve conflicts (use most restrictive)
        let resolvedQuality = qualityThresholds.max() ?? 0.7
        let resolvedFrameRate = frameRates.min() ?? 30
        let resolvedResolution = resolutions.min() ?? .standard
        
        // Detect conflicts
        var conflicts: [PolicyConflict] = []
        if qualityThresholds.count > 1 && qualityThresholds.min() != qualityThresholds.max() {
            conflicts.append(PolicyConflict(
                type: .qualityThreshold,
                sources: Array(activePolicies.keys),
                values: qualityThresholds
            ))
        }
        
        // Apply ISP compensation to quality threshold
        let compensatedQuality = resolvedQuality * ispCompensationFactor
        
        return ResolvedCapturePolicy(
            qualityThreshold: compensatedQuality,
            frameRate: resolvedFrameRate,
            resolution: resolvedResolution,
            ispCompensation: ispCompensationFactor,
            sources: Array(activePolicies.keys),
            conflicts: conflicts
        )
    }
    
    // MARK: - Data Types
    
    /// Policy source
    public enum PolicySource: String, Codable, Sendable, CaseIterable {
        case user
        case system
        case adaptive
        case emergency
    }
    
    /// Capture policy
    public struct CapturePolicy: Codable, Sendable {
        public let qualityThreshold: Double
        public let frameRate: Int
        public let resolution: Resolution
        
        public init(qualityThreshold: Double, frameRate: Int, resolution: Resolution) {
            self.qualityThreshold = qualityThreshold
            self.frameRate = frameRate
            self.resolution = resolution
        }
    }
    
    /// Resolution
    public enum Resolution: String, Codable, Sendable, CaseIterable, Comparable {
        case low
        case standard
        case high
        case ultra
        
        public static func < (lhs: Resolution, rhs: Resolution) -> Bool {
            let order: [Resolution] = [.low, .standard, .high, .ultra]
            guard let lhsIndex = order.firstIndex(of: lhs),
                  let rhsIndex = order.firstIndex(of: rhs) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
    }
    
    /// Resolved capture policy
    public struct ResolvedCapturePolicy: Sendable {
        public let qualityThreshold: Double
        public let frameRate: Int
        public let resolution: Resolution
        public let ispCompensation: Double
        public let sources: [PolicySource]
        public let conflicts: [PolicyConflict]
    }
    
    /// Policy conflict
    public struct PolicyConflict: Sendable {
        public let type: ConflictType
        public let sources: [PolicySource]
        public let values: [Double]
        
        public enum ConflictType: String, Sendable {
            case qualityThreshold
            case frameRate
            case resolution
        }
    }
}
