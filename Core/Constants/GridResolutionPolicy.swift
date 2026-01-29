//
// GridResolutionPolicy.swift
// Aether3D
//
// PR#1 Ultra-Granular Capture - Grid Resolution Policy (Closed Set)
//
// C: Grid Resolution Policy with two-layer limits
// - systemMinimumQuantum: minimum representable quantum
// - recommendedCaptureFloor: per-profile default floor
//

import Foundation

// MARK: - Grid Resolution Policy

/// Grid resolution policy (closed set, immutable mappings)
public enum GridResolutionPolicy {
    
    // MARK: - System Minimum Quantum
    
    /// System minimum quantum (LengthQ) - the minimum representable quantum for determinism/future hardware
    /// This is the absolute floor for the system
    public static let systemMinimumQuantum = LengthQ(scaleId: .systemMinimum, quanta: 1)  // 0.05mm
    
    // MARK: - Recommended Capture Floor (per profile)
    
    /// Recommended capture floor for standard profile
    public static let recommendedCaptureFloorStandard = LengthQ(scaleId: .geomId, quanta: 1)  // 1mm
    
    /// Recommended capture floor for smallObjectMacro profile
    public static let recommendedCaptureFloorSmallObjectMacro = LengthQ(scaleId: .systemMinimum, quanta: 5)  // 0.25mm
    
    /// Recommended capture floor for largeScene profile
    public static let recommendedCaptureFloorLargeScene = LengthQ(scaleId: .geomId, quanta: 5)  // 5mm
    
    /// Get recommended capture floor for a profile
    public static func recommendedCaptureFloor(for profile: CaptureProfile) -> LengthQ {
        switch profile {
        case .standard:
            return recommendedCaptureFloorStandard
        case .smallObjectMacro:
            return recommendedCaptureFloorSmallObjectMacro
        case .largeScene:
            return recommendedCaptureFloorLargeScene
        }
    }
    
    // MARK: - Closed Set of Allowed Grid Cell Sizes
    
    /// Closed set of allowed grid cell sizes (LengthQ)
    /// **Rule:** Only these values are allowed. No dynamic or arbitrary resolutions.
    public static let allowedGridCellSizes: [LengthQ] = [
        LengthQ(scaleId: .systemMinimum, quanta: 5),   // 0.25mm
        LengthQ(scaleId: .systemMinimum, quanta: 10), // 0.5mm
        LengthQ(scaleId: .geomId, quanta: 1),          // 1mm
        LengthQ(scaleId: .geomId, quanta: 2),          // 2mm
        LengthQ(scaleId: .geomId, quanta: 5),          // 5mm
        LengthQ(scaleId: .geomId, quanta: 10),         // 1cm
        LengthQ(scaleId: .geomId, quanta: 20),         // 2cm
        LengthQ(scaleId: .geomId, quanta: 50),         // 5cm
    ]
    
    // MARK: - Profile to Grid Resolution Mapping
    
    /// Get allowed grid resolutions for a profile (immutable mapping)
    public static func allowedResolutions(for profile: CaptureProfile) -> [LengthQ] {
        switch profile {
        case .standard:
            return [
                LengthQ(scaleId: .geomId, quanta: 2),   // 2mm
                LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),  // 1cm
                LengthQ(scaleId: .geomId, quanta: 20),  // 2cm
                LengthQ(scaleId: .geomId, quanta: 50),  // 5cm
            ]
        case .smallObjectMacro:
            return [
                LengthQ(scaleId: .systemMinimum, quanta: 5),  // 0.25mm
                LengthQ(scaleId: .systemMinimum, quanta: 10), // 0.5mm
                LengthQ(scaleId: .geomId, quanta: 1),         // 1mm
                LengthQ(scaleId: .geomId, quanta: 2),         // 2mm
                LengthQ(scaleId: .geomId, quanta: 5),         // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),        // 1cm
            ]
        case .largeScene:
            return [
                LengthQ(scaleId: .geomId, quanta: 5),   // 5mm
                LengthQ(scaleId: .geomId, quanta: 10),  // 1cm
                LengthQ(scaleId: .geomId, quanta: 20),   // 2cm
                LengthQ(scaleId: .geomId, quanta: 50),  // 5cm
            ]
        }
    }
    
    // MARK: - Validation
    
    /// Validate that a resolution is in the closed set
    public static func validateResolution(_ resolution: LengthQ) -> Bool {
        return allowedGridCellSizes.contains(resolution)
    }
    
    /// Validate that a resolution is allowed for a profile
    public static func validateResolution(_ resolution: LengthQ, for profile: CaptureProfile) -> Bool {
        let allowed = allowedResolutions(for: profile)
        return allowed.contains(resolution)
    }
    
    // MARK: - Digest Input
    
    /// Digest input structure
    public struct DigestInput: Codable {
        public let systemMinimumQuantum: LengthQ.DigestInput
        public let recommendedCaptureFloors: [KeyedValue<UInt8, LengthQ.DigestInput>]  // profileId -> floor
        public let allowedGridCellSizes: [LengthQ.DigestInput]
        public let profileMappings: [KeyedValue<UInt8, [LengthQ.DigestInput]>]  // profileId -> resolutions
        public let schemaVersionId: UInt16
        
        public init(
            systemMinimumQuantum: LengthQ.DigestInput,
            recommendedCaptureFloors: [KeyedValue<UInt8, LengthQ.DigestInput>],
            allowedGridCellSizes: [LengthQ.DigestInput],
            profileMappings: [KeyedValue<UInt8, [LengthQ.DigestInput]>],
            schemaVersionId: UInt16
        ) {
            self.systemMinimumQuantum = systemMinimumQuantum
            self.recommendedCaptureFloors = recommendedCaptureFloors
            self.allowedGridCellSizes = allowedGridCellSizes
            self.profileMappings = profileMappings
            self.schemaVersionId = schemaVersionId
        }
    }
    
    /// Get digest input
    public static func digestInput(schemaVersionId: UInt16) -> DigestInput {
        var recommendedFloorsArr: [KeyedValue<UInt8, LengthQ.DigestInput>] = []
        var profileMappingsArr: [KeyedValue<UInt8, [LengthQ.DigestInput]>] = []
        
        // Use stable order (sorted by profileId) to ensure deterministic dictionary encoding
        let profiles = CaptureProfile.allCases.sorted { $0.profileId < $1.profileId }
        for profile in profiles {
            let floor = recommendedCaptureFloor(for: profile)
            recommendedFloorsArr.append(KeyedValue(key: profile.profileId, value: floor.digestInput()))
            
            let resolutions = allowedResolutions(for: profile)
            profileMappingsArr.append(KeyedValue(key: profile.profileId, value: resolutions.map { $0.digestInput() }))
        }
        
        // Explicitly sort arrays by key to ensure determinism
        recommendedFloorsArr.sort { $0.key < $1.key }
        profileMappingsArr.sort { $0.key < $1.key }
        
        return DigestInput(
            systemMinimumQuantum: systemMinimumQuantum.digestInput(),
            recommendedCaptureFloors: recommendedFloorsArr,
            allowedGridCellSizes: allowedGridCellSizes.map { $0.digestInput() },
            profileMappings: profileMappingsArr,
            schemaVersionId: schemaVersionId
        )
    }
}
