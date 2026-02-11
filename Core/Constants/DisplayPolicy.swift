// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DisplayPolicy.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Display Policy (Strict Separation)
//
// F: Display Policy - algorithm resolution vs user-facing visualization granularity
// Display policy MUST NOT affect identity/evidence collection
//

import Foundation

// MARK: - Display Refresh Policy (Closed Set)

/// Display refresh policy (closed set)
public enum DisplayRefreshPolicy: UInt8, Codable, CaseIterable {
    case immediate = 1      // Immediate update
    case debounced = 2      // Debounced update
    case throttled = 3      // Throttled update
    
    public var name: String {
        switch self {
        case .immediate: return "immediate"
        case .debounced: return "debounced"
        case .throttled: return "throttled"
        }
    }
}

// MARK: - User Facing Granularity Policy

/// User-facing granularity policy (closed set)
public struct UserFacingGranularityPolicy: Codable {
    /// Allowed aggregation levels (LengthQ closed set)
    public let allowedAggregationLevels: [LengthQ.DigestInput]
    
    /// Allowed drill-down levels (still NOT raw micro-triangles)
    public let allowedDrillDownLevels: [LengthQ.DigestInput]
    
    /// Target display pixel density (per visual cell)
    public let targetDisplayPixelDensityPerVisualCell: Int
    
    /// Display refresh policy
    public let displayRefreshPolicy: UInt8  // Raw value of DisplayRefreshPolicy
    
    /// Schema version ID
    public let schemaVersionId: UInt16
    
    /// Documentation
    public let documentation: String
    
    public init(
        allowedAggregationLevels: [LengthQ],
        allowedDrillDownLevels: [LengthQ],
        targetDisplayPixelDensityPerVisualCell: Int,
        displayRefreshPolicy: DisplayRefreshPolicy,
        schemaVersionId: UInt16,
        documentation: String
    ) {
        self.allowedAggregationLevels = allowedAggregationLevels.map { $0.digestInput() }
        self.allowedDrillDownLevels = allowedDrillDownLevels.map { $0.digestInput() }
        self.targetDisplayPixelDensityPerVisualCell = targetDisplayPixelDensityPerVisualCell
        self.displayRefreshPolicy = displayRefreshPolicy.rawValue
        self.schemaVersionId = schemaVersionId
        self.documentation = documentation
    }
}

extension UserFacingGranularityPolicy: Equatable {
    public static func == (lhs: UserFacingGranularityPolicy, rhs: UserFacingGranularityPolicy) -> Bool {
        return lhs.allowedAggregationLevels.count == rhs.allowedAggregationLevels.count &&
               lhs.allowedDrillDownLevels.count == rhs.allowedDrillDownLevels.count &&
               lhs.targetDisplayPixelDensityPerVisualCell == rhs.targetDisplayPixelDensityPerVisualCell &&
               lhs.displayRefreshPolicy == rhs.displayRefreshPolicy &&
               lhs.schemaVersionId == rhs.schemaVersionId &&
               lhs.documentation == rhs.documentation
    }
}

// MARK: - Display Policy

/// Display policy (immutable, auditable)
public enum DisplayPolicy {
    
    // MARK: - User Facing Granularity Policy
    
    /// User-facing granularity policy
    /// **Rule:** Display resolution != algorithm resolution
    /// Micro-scale patches/triangles MUST NOT be rendered directly to users
    /// UI must use aggregated display grid regardless of internal scale
    public static let userFacingGranularity = UserFacingGranularityPolicy(
        allowedAggregationLevels: [
            LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
            LengthQ(scaleId: .geomId, quanta: 10),  // 1cm
            LengthQ(scaleId: .geomId, quanta: 20),  // 2cm
        ],
        allowedDrillDownLevels: [
            LengthQ(scaleId: .geomId, quanta: 2),   // 2mm (still aggregated, not raw micro-triangles)
            LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
        ],
        targetDisplayPixelDensityPerVisualCell: 64,  // 64 pixels per visual cell
        displayRefreshPolicy: .throttled,
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "User-facing granularity policy: Algorithm resolution != display resolution. Micro-scale details must be aggregated. Display policy does NOT affect identity/evidence collection."
    )
    
    // MARK: - Rendering Rules (SSOT Constants)
    
    /// Wireframe rendering is debug-only and never default
    public static let wireframeDebugOnly = true
    
    /// Micro details must be aggregated to user-visible scale
    public static let requireAggregation = true
    
    // MARK: - Digest Input
    
    /// Digest input structure
    public struct DigestInput: Codable {
        public let userFacingGranularity: UserFacingGranularityPolicy
        public let wireframeDebugOnly: Bool
        public let requireAggregation: Bool
        public let schemaVersionId: UInt16
        
        public init(
            userFacingGranularity: UserFacingGranularityPolicy,
            wireframeDebugOnly: Bool,
            requireAggregation: Bool,
            schemaVersionId: UInt16
        ) {
            self.userFacingGranularity = userFacingGranularity
            self.wireframeDebugOnly = wireframeDebugOnly
            self.requireAggregation = requireAggregation
            self.schemaVersionId = schemaVersionId
        }
    }
    
    /// Get digest input
    public static func digestInput(schemaVersionId: UInt16) -> DigestInput {
        return DigestInput(
            userFacingGranularity: userFacingGranularity,
            wireframeDebugOnly: wireframeDebugOnly,
            requireAggregation: requireAggregation,
            schemaVersionId: schemaVersionId
        )
    }
}
