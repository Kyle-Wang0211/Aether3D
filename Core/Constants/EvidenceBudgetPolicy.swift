//
// EvidenceBudgetPolicy.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Evidence Budget Policy
//
// D3: EvidenceBudgetPolicy (per profile) to cap deterministic resource growth
// Prevents unbounded cost, preserves determinism, ensures explainable failure modes
//

import Foundation

// MARK: - Evidence Budget Policy Specification

/// Evidence budget policy specification (per profile)
public struct EvidenceBudgetPolicySpec: Codable {
    /// Profile identifier
    public let profileId: UInt8
    
    /// Maximum grid cells (closed integer)
    public let maxCells: Int
    
    /// Maximum patches (closed integer)
    public let maxPatches: Int
    
    /// Maximum evidence events (closed integer)
    public let maxEvidenceEvents: Int
    
    /// Maximum audit bytes (Int64)
    public let maxAuditBytes: Int64
    
    /// Schema version ID
    public let schemaVersionId: UInt16
    
    /// Documentation (must explain "responsibility to users + devs")
    public let documentation: String
    
    public init(
        profileId: UInt8,
        maxCells: Int,
        maxPatches: Int,
        maxEvidenceEvents: Int,
        maxAuditBytes: Int64,
        schemaVersionId: UInt16,
        documentation: String
    ) {
        self.profileId = profileId
        self.maxCells = maxCells
        self.maxPatches = maxPatches
        self.maxEvidenceEvents = maxEvidenceEvents
        self.maxAuditBytes = maxAuditBytes
        self.schemaVersionId = schemaVersionId
        self.documentation = documentation
    }
}

extension EvidenceBudgetPolicySpec: Equatable {
    public static func == (lhs: EvidenceBudgetPolicySpec, rhs: EvidenceBudgetPolicySpec) -> Bool {
        return lhs.profileId == rhs.profileId &&
               lhs.maxCells == rhs.maxCells &&
               lhs.maxPatches == rhs.maxPatches &&
               lhs.maxEvidenceEvents == rhs.maxEvidenceEvents &&
               lhs.maxAuditBytes == rhs.maxAuditBytes &&
               lhs.schemaVersionId == rhs.schemaVersionId &&
               lhs.documentation == rhs.documentation
    }
}

// MARK: - Evidence Budget Policy

/// Evidence budget policy table (immutable, auditable)
public enum EvidenceBudgetPolicy {
    
    // MARK: - Policy Specifications
    
    /// Evidence budget for standard profile
    public static let standard = EvidenceBudgetPolicySpec(
        profileId: CaptureProfile.standard.profileId,
        maxCells: 1_000_000,        // 1M cells
        maxPatches: 10_000_000,      // 10M patches
        maxEvidenceEvents: 100_000_000, // 100M events
        maxAuditBytes: 10_000_000_000,  // 10GB audit
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Standard evidence budget: Prevents unbounded cost growth, ensures deterministic resource limits, provides explainable failure modes when exceeded. Responsibility to users: predictable performance. Responsibility to devs: clear resource constraints."
    )
    
    /// Evidence budget for smallObjectMacro profile
    public static let smallObjectMacro = EvidenceBudgetPolicySpec(
        profileId: CaptureProfile.smallObjectMacro.profileId,
        maxCells: 10_000_000,        // 10M cells (higher due to finer resolution)
        maxPatches: 50_000_000,      // 50M patches
        maxEvidenceEvents: 500_000_000, // 500M events
        maxAuditBytes: 50_000_000_000,  // 50GB audit
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Small object macro evidence budget: Higher limits due to finer resolution. Prevents unbounded cost growth, ensures deterministic resource limits, provides explainable failure modes when exceeded."
    )
    
    /// Evidence budget for largeScene profile
    public static let largeScene = EvidenceBudgetPolicySpec(
        profileId: CaptureProfile.largeScene.profileId,
        maxCells: 5_000_000,         // 5M cells
        maxPatches: 20_000_000,      // 20M patches
        maxEvidenceEvents: 200_000_000, // 200M events
        maxAuditBytes: 20_000_000_000,  // 20GB audit
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Large scene evidence budget: Balanced limits for room-scale scenes. Prevents unbounded cost growth, ensures deterministic resource limits, provides explainable failure modes when exceeded."
    )

    /// Evidence budget for proMacro profile
    public static let proMacro = EvidenceBudgetPolicySpec(
        profileId: CaptureProfile.proMacro.profileId,
        maxCells: 15_000_000,        // 15M cells (highest detail turntable)
        maxPatches: 75_000_000,      // 75M patches
        maxEvidenceEvents: 750_000_000, // 750M events
        maxAuditBytes: 75_000_000_000,  // 75GB audit
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Pro macro evidence budget: Highest limits for professional turntable scanning. Prevents unbounded cost growth, ensures deterministic resource limits, provides explainable failure modes when exceeded."
    )

    /// Evidence budget for cinematicScene profile
    public static let cinematicScene = EvidenceBudgetPolicySpec(
        profileId: CaptureProfile.cinematicScene.profileId,
        maxCells: 3_000_000,         // 3M cells (cinematic dolly)
        maxPatches: 15_000_000,      // 15M patches
        maxEvidenceEvents: 150_000_000, // 150M events
        maxAuditBytes: 15_000_000_000,  // 15GB audit
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Cinematic scene evidence budget: Balanced limits for cinematic dolly captures. Prevents unbounded cost growth, ensures deterministic resource limits, provides explainable failure modes when exceeded."
    )

    // MARK: - Policy Lookup
    
    /// Get evidence budget policy for a profile
    public static func policy(for profile: CaptureProfile) -> EvidenceBudgetPolicySpec {
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
    
    /// All evidence budget policy specifications
    public static let allPolicies: [EvidenceBudgetPolicySpec] = [
        standard,
        smallObjectMacro,
        largeScene,
        proMacro,
        cinematicScene
    ]
    
    // MARK: - Digest Input
    
    /// Digest input structure
    public struct DigestInput: Codable {
        public let policies: [EvidenceBudgetPolicySpec]
        public let schemaVersionId: UInt16
        
        public init(policies: [EvidenceBudgetPolicySpec], schemaVersionId: UInt16) {
            self.policies = policies
            self.schemaVersionId = schemaVersionId
        }
    }
    
    /// Get digest input
    public static func digestInput(schemaVersionId: UInt16) -> DigestInput {
        return DigestInput(policies: allPolicies, schemaVersionId: schemaVersionId)
    }
}
