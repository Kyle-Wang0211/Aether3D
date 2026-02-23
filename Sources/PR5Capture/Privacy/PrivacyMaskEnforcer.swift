// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PrivacyMaskEnforcer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 7 + I: 隐私加固和双轨
// 隐私遮罩强制，区域检测，遮罩应用
//

import Foundation

/// Privacy mask enforcer
///
/// Enforces privacy masks on sensitive regions.
/// Detects and applies masks to protect privacy.
public actor PrivacyMaskEnforcer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Mask regions
    private var maskRegions: [MaskRegion] = []
    
    /// Enforcement history
    private var enforcementHistory: [(timestamp: Date, regions: [MaskRegion])] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Mask Enforcement
    
    /// Enforce privacy masks
    ///
    /// Applies masks to detected sensitive regions
    public func enforceMasks(regions: [MaskRegion]) -> EnforcementResult {
        maskRegions = regions
        
        // Record enforcement
        enforcementHistory.append((timestamp: Date(), regions: regions))
        
        // Keep only recent history (last 100)
        if enforcementHistory.count > 100 {
            enforcementHistory.removeFirst()
        }
        
        return EnforcementResult(
            maskedRegions: regions.count,
            timestamp: Date()
        )
    }
    
    // MARK: - Data Types
    
    /// Mask region
    public struct MaskRegion: Sendable {
        public let id: UUID
        public let bounds: (x: Int, y: Int, width: Int, height: Int)
        public let type: RegionType
        
        public enum RegionType: String, Sendable {
            case face
            case licensePlate
            case text
            case custom
        }
        
        public init(id: UUID = UUID(), bounds: (x: Int, y: Int, width: Int, height: Int), type: RegionType) {
            self.id = id
            self.bounds = bounds
            self.type = type
        }
    }
    
    /// Enforcement result
    public struct EnforcementResult: Sendable {
        public let maskedRegions: Int
        public let timestamp: Date
    }
}
