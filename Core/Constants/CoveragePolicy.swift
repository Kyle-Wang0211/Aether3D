//
// CoveragePolicy.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Coverage Policy (Closed Set Thresholds)
//
// D2: CoveragePolicy spec (per profile) defining closed-set thresholds
// WITHOUT algorithms - only defines what "coverage sufficiency" means
//

import Foundation

// MARK: - Evidence Confidence Level (Closed Set)

/// Evidence confidence level (closed set, append-only)
/// **Rule ID:** PR6_GRID_CONFIDENCE_001
/// PR6 Extension: Added L4, L5, L6 levels for Evidence Grid System
public enum EvidenceConfidenceLevel: UInt8, Codable, CaseIterable {
    case L0 = 0  // Lowest confidence
    case L1 = 1  // Medium confidence
    case L2 = 2  // High confidence
    case L3 = 3  // Highest confidence (asset-grade)
    case L4 = 4  // PR6: Extended confidence level
    case L5 = 5  // PR6: Extended confidence level
    case L6 = 6  // PR6: Extended confidence level
    
    public var name: String {
        switch self {
        case .L0: return "L0"
        case .L1: return "L1"
        case .L2: return "L2"
        case .L3: return "L3"
        case .L4: return "L4"
        case .L5: return "L5"
        case .L6: return "L6"
        }
    }
}

// MARK: - Coverage Policy Specification

/// Coverage policy specification (per profile)
public struct CoveragePolicySpec: Codable {
    /// Profile identifier
    public let profileId: UInt8
    
    /// Minimum views per cell (closed integer)
    public let minViewsPerCell: Int
    
    /// Minimum parallax bins (closed integer)
    public let minParallaxBins: Int
    
    /// Maximum hole diameter allowed (LengthQ)
    public let maxHoleDiameterAllowed: LengthQ.DigestInput
    
    /// Evidence confidence levels (closed set)
    public let evidenceConfidenceLevels: [UInt8]  // Raw values of EvidenceConfidenceLevel
    
    /// Schema version ID
    public let schemaVersionId: UInt16
    
    /// Documentation
    public let documentation: String
    
    public init(
        profileId: UInt8,
        minViewsPerCell: Int,
        minParallaxBins: Int,
        maxHoleDiameterAllowed: LengthQ.DigestInput,
        evidenceConfidenceLevels: [EvidenceConfidenceLevel],
        schemaVersionId: UInt16,
        documentation: String
    ) {
        self.profileId = profileId
        self.minViewsPerCell = minViewsPerCell
        self.minParallaxBins = minParallaxBins
        self.maxHoleDiameterAllowed = maxHoleDiameterAllowed
        self.evidenceConfidenceLevels = evidenceConfidenceLevels.map { $0.rawValue }
        self.schemaVersionId = schemaVersionId
        self.documentation = documentation
    }
}

extension CoveragePolicySpec: Equatable {
    public static func == (lhs: CoveragePolicySpec, rhs: CoveragePolicySpec) -> Bool {
        return lhs.profileId == rhs.profileId &&
               lhs.minViewsPerCell == rhs.minViewsPerCell &&
               lhs.minParallaxBins == rhs.minParallaxBins &&
               lhs.maxHoleDiameterAllowed.scaleId == rhs.maxHoleDiameterAllowed.scaleId &&
               lhs.maxHoleDiameterAllowed.quanta == rhs.maxHoleDiameterAllowed.quanta &&
               lhs.evidenceConfidenceLevels == rhs.evidenceConfidenceLevels &&
               lhs.schemaVersionId == rhs.schemaVersionId &&
               lhs.documentation == rhs.documentation
    }
}

// MARK: - Coverage Policy

/// Coverage policy table (immutable, auditable)
public enum CoveragePolicy {
    
    // MARK: - Policy Specifications
    
    /// Coverage policy for standard profile
    public static let standard = CoveragePolicySpec(
        profileId: CaptureProfile.standard.profileId,
        minViewsPerCell: 3,
        minParallaxBins: 2,
        maxHoleDiameterAllowed: LengthQ(scaleId: .geomId, quanta: 10).digestInput(), // 1cm
        evidenceConfidenceLevels: [.L0, .L1, .L2, .L3],
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Standard coverage policy: 3 views/cell, 2 parallax bins, max 1cm holes"
    )
    
    /// Coverage policy for smallObjectMacro profile
    public static let smallObjectMacro = CoveragePolicySpec(
        profileId: CaptureProfile.smallObjectMacro.profileId,
        minViewsPerCell: 5,
        minParallaxBins: 3,
        maxHoleDiameterAllowed: LengthQ(scaleId: .systemMinimum, quanta: 10).digestInput(), // 0.5mm
        evidenceConfidenceLevels: [.L0, .L1, .L2, .L3],
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Small object macro coverage policy: 5 views/cell, 3 parallax bins, max 0.5mm holes"
    )
    
    /// Coverage policy for largeScene profile
    public static let largeScene = CoveragePolicySpec(
        profileId: CaptureProfile.largeScene.profileId,
        minViewsPerCell: 2,
        minParallaxBins: 2,
        maxHoleDiameterAllowed: LengthQ(scaleId: .geomId, quanta: 50).digestInput(), // 5cm
        evidenceConfidenceLevels: [.L0, .L1, .L2, .L3],
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Large scene coverage policy: 2 views/cell, 2 parallax bins, max 5cm holes"
    )

    /// Coverage policy for proMacro profile
    public static let proMacro = CoveragePolicySpec(
        profileId: CaptureProfile.proMacro.profileId,
        minViewsPerCell: 6,
        minParallaxBins: 4,
        maxHoleDiameterAllowed: LengthQ(scaleId: .systemMinimum, quanta: 5).digestInput(), // 0.25mm
        evidenceConfidenceLevels: [.L0, .L1, .L2, .L3],
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Pro macro coverage policy: 6 views/cell, 4 parallax bins, max 0.25mm holes (turntable scanning)"
    )

    /// Coverage policy for cinematicScene profile
    public static let cinematicScene = CoveragePolicySpec(
        profileId: CaptureProfile.cinematicScene.profileId,
        minViewsPerCell: 2,
        minParallaxBins: 2,
        maxHoleDiameterAllowed: LengthQ(scaleId: .geomId, quanta: 30).digestInput(), // 3cm
        evidenceConfidenceLevels: [.L0, .L1, .L2, .L3],
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Cinematic scene coverage policy: 2 views/cell, 2 parallax bins, max 3cm holes (dolly movement)"
    )

    // MARK: - Policy Lookup
    
    /// Get coverage policy for a profile
    public static func policy(for profile: CaptureProfile) -> CoveragePolicySpec {
        switch profile {
        case .standard:
            return standard
        case .smallObjectMacro:
            return smallObjectMacro
        case .largeScene:
            return largeScene
        case .proMacro:
            return proMacro
        case .cinematicScene:
            return cinematicScene
        }
    }
    
    // MARK: - All Policies
    
    /// All coverage policy specifications
    public static let allPolicies: [CoveragePolicySpec] = [
        standard,
        smallObjectMacro,
        largeScene,
        proMacro,
        cinematicScene
    ]
    
    // MARK: - Digest Input
    
    /// Digest input structure
    public struct DigestInput: Codable {
        public let policies: [CoveragePolicySpec]
        public let schemaVersionId: UInt16
        
        public init(policies: [CoveragePolicySpec], schemaVersionId: UInt16) {
            self.policies = policies
            self.schemaVersionId = schemaVersionId
        }
    }
    
    /// Get digest input
    public static func digestInput(schemaVersionId: UInt16) -> DigestInput {
        return DigestInput(policies: allPolicies, schemaVersionId: schemaVersionId)
    }
}
