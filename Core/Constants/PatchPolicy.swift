//
// PatchPolicy.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Patch (Triangle) Scale Policy
//
// D1: PatchPolicy spec table (per profile) using LengthQ
//

import Foundation

// MARK: - Patch Policy

/// Patch policy specification (per profile)
public struct PatchPolicySpec: Codable {
    /// Profile identifier
    public let profileId: UInt8
    
    /// Minimum edge length (LengthQ)
    public let minEdgeLength: LengthQ.DigestInput
    
    /// Maximum edge length (LengthQ)
    public let maxEdgeLength: LengthQ.DigestInput
    
    /// Schema version ID
    public let schemaVersionId: UInt16
    
    /// Documentation
    public let documentation: String
    
    public init(
        profileId: UInt8,
        minEdgeLength: LengthQ.DigestInput,
        maxEdgeLength: LengthQ.DigestInput,
        schemaVersionId: UInt16,
        documentation: String
    ) {
        self.profileId = profileId
        self.minEdgeLength = minEdgeLength
        self.maxEdgeLength = maxEdgeLength
        self.schemaVersionId = schemaVersionId
        self.documentation = documentation
    }
}

extension PatchPolicySpec: Equatable {
    public static func == (lhs: PatchPolicySpec, rhs: PatchPolicySpec) -> Bool {
        return lhs.profileId == rhs.profileId &&
               lhs.minEdgeLength.scaleId == rhs.minEdgeLength.scaleId &&
               lhs.minEdgeLength.quanta == rhs.minEdgeLength.quanta &&
               lhs.maxEdgeLength.scaleId == rhs.maxEdgeLength.scaleId &&
               lhs.maxEdgeLength.quanta == rhs.maxEdgeLength.quanta &&
               lhs.schemaVersionId == rhs.schemaVersionId &&
               lhs.documentation == rhs.documentation
    }
}

/// Patch policy table (immutable, auditable)
public enum PatchPolicy {
    
    // MARK: - Policy Specifications
    
    /// Patch policy for standard profile
    public static let standard = PatchPolicySpec(
        profileId: CaptureProfile.standard.profileId,
        minEdgeLength: LengthQ(scaleId: .geomId, quanta: 5).digestInput(),  // 5mm
        maxEdgeLength: LengthQ(scaleId: .geomId, quanta: 500).digestInput(), // 50cm
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Standard patch policy: 5mm to 50cm edge lengths"
    )
    
    /// Patch policy for smallObjectMacro profile
    public static let smallObjectMacro = PatchPolicySpec(
        profileId: CaptureProfile.smallObjectMacro.profileId,
        minEdgeLength: LengthQ(scaleId: .systemMinimum, quanta: 10).digestInput(), // 0.5mm
        maxEdgeLength: LengthQ(scaleId: .geomId, quanta: 50).digestInput(), // 5cm
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Small object macro patch policy: 0.5mm to 5cm edge lengths (supports sub-millimeter detail)"
    )
    
    /// Patch policy for largeScene profile
    public static let largeScene = PatchPolicySpec(
        profileId: CaptureProfile.largeScene.profileId,
        minEdgeLength: LengthQ(scaleId: .geomId, quanta: 10).digestInput(), // 10mm
        maxEdgeLength: LengthQ(scaleId: .geomId, quanta: 1000).digestInput(), // 1m
        schemaVersionId: SSOTVersion.schemaVersionId,
        documentation: "Large scene patch policy: 10mm to 1m edge lengths"
    )
    
    // MARK: - Policy Lookup
    
    /// Get patch policy for a profile
    public static func policy(for profile: CaptureProfile) -> PatchPolicySpec {
        switch profile {
        case .standard:
            return standard
        case .smallObjectMacro:
            return smallObjectMacro
        case .largeScene:
            return largeScene
        }
    }
    
    // MARK: - All Policies
    
    /// All patch policy specifications
    public static let allPolicies: [PatchPolicySpec] = [
        standard,
        smallObjectMacro,
        largeScene
    ]
    
    // MARK: - Digest Input
    
    /// Digest input structure
    public struct DigestInput: Codable {
        public let policies: [PatchPolicySpec]
        public let schemaVersionId: UInt16
        
        public init(policies: [PatchPolicySpec], schemaVersionId: UInt16) {
            self.policies = policies
            self.schemaVersionId = schemaVersionId
        }
    }
    
    /// Get digest input
    public static func digestInput(schemaVersionId: UInt16) -> DigestInput {
        return DigestInput(policies: allPolicies, schemaVersionId: schemaVersionId)
    }
}
