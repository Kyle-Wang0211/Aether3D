//
// ObservationTypes.swift
// Aether3D
//
// PR#1 ObservationModel CONSTITUTION - Cross-Platform Safe Types
//
// All types are cross-platform safe (no SIMD Codable, no Apple frameworks).
// Forward vector replaces quaternions for viewpoint definition.
//

import Foundation

// MARK: - ObservationID

/// Strong-typed observation identifier
public struct ObservationID: Codable, Equatable, Hashable {
    public let value: String
    
    public init(value: String) {
        self.value = value
    }
}

// MARK: - Vec3D

/// 3D vector (cross-platform safe, replaces SIMD3<Double>)
public struct Vec3D: Codable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double
    
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

// MARK: - ObservationTimestamp

/// Observation timestamp (Int64 milliseconds, avoids Double drift)
public struct ObservationTimestamp: Codable, Equatable {
    public let unixMs: Int64
    
    public init(unixMs: Int64) {
        self.unixMs = unixMs
    }
}

// MARK: - PatchID

/// Patch identifier
public struct PatchID: Codable, Equatable, Hashable {
    public let value: String
    
    public init(value: String) {
        self.value = value
    }
}

// MARK: - Confidence

/// Confidence value ∈ [0,1] (closed constraint)
public struct Confidence: Codable, Equatable {
    public let value: Double
    
    public init(_ value: Double) {
        precondition(value >= 0.0 && value <= 1.0, "Confidence must be in [0,1]")
        self.value = value
    }
}

// MARK: - OcclusionState

/// Occlusion state (closed-world, no "unknown")
public enum OcclusionState: String, Codable, CaseIterable {
    case notOccluded = "NOT_OCCLUDED"
    case partiallyOccluded = "PARTIALLY_OCCLUDED"
    case fullyOccluded = "FULLY_OCCLUDED"
}

// MARK: - LabColor

/// L*a*b* color sample (optional)
public struct LabColor: Codable, Equatable {
    public let l: Double
    public let a: Double
    public let b: Double
    
    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }
}

// MARK: - RawMeasurements

/// Raw measurements (no inference, no pair metrics)
public struct RawMeasurements: Codable, Equatable {
    public let depthMeters: Double?
    public let luminanceLStar: Double?
    public let lab: LabColor?
    public let sampleCount: Int
    
    public init(
        depthMeters: Double?,
        luminanceLStar: Double?,
        lab: LabColor?,
        sampleCount: Int
    ) {
        self.depthMeters = depthMeters
        self.luminanceLStar = luminanceLStar
        self.lab = lab
        self.sampleCount = sampleCount
    }
}

// MARK: - SensorPose

/// Sensor pose (position + forward vector)
/// Forward MUST be finite and unit-length within tolerance.
public struct SensorPose: Codable, Equatable {
    public let position: Vec3D
    public let forward: Vec3D
    
    public init(position: Vec3D, forward: Vec3D) {
        // Finite checks
        precondition(ObservationMath.isFinite(position), "Position must be finite")
        precondition(ObservationMath.isFinite(forward), "Forward must be finite")
        
        // Unit vector check (with tolerance)
        let norm = ObservationMath.norm(forward)
        precondition(norm > ObservationConstants.finiteEpsilon, "Forward must have non-zero length")
        let unitTolerance = abs(norm - 1.0)
        precondition(unitTolerance <= ObservationConstants.unitVectorTolerance,
                     "Forward must be unit-length within tolerance")
        
        self.position = position
        self.forward = forward
    }
    
    // ⚠️ 禁止 Hashable（float hashing 跨平台不稳定）
    // ⚠️ 禁止 Set<SensorPose>（使用几何计算判断 distinctness）
}

// MARK: - RayGeometry

/// Ray geometry (auditable)
public struct RayGeometry: Codable, Equatable {
    public let origin: Vec3D
    public let direction: Vec3D
    public let intersectionPoint: Vec3D?
    public let projectedOverlapArea: Double
    
    public init(
        origin: Vec3D,
        direction: Vec3D,
        intersectionPoint: Vec3D?,
        projectedOverlapArea: Double
    ) {
        self.origin = origin
        self.direction = direction
        self.intersectionPoint = intersectionPoint
        self.projectedOverlapArea = projectedOverlapArea
    }
}

// MARK: - Observation

/// Observation (immutable, auditable, raw-only)
public struct Observation: Codable, Equatable {
    public let schemaVersion: UInt16
    public let id: ObservationID
    public let timestamp: ObservationTimestamp
    public let patchId: PatchID
    public let sensorPose: SensorPose
    public let ray: RayGeometry
    public let raw: RawMeasurements
    public let confidence: Confidence
    public let occlusion: OcclusionState
    
    public init(
        schemaVersion: UInt16,
        id: ObservationID,
        timestamp: ObservationTimestamp,
        patchId: PatchID,
        sensorPose: SensorPose,
        ray: RayGeometry,
        raw: RawMeasurements,
        confidence: Confidence,
        occlusion: OcclusionState
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.timestamp = timestamp
        self.patchId = patchId
        self.sensorPose = sensorPose
        self.ray = ray
        self.raw = raw
        self.confidence = confidence
        self.occlusion = occlusion
    }
}
