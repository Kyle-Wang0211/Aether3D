//
// Observation.swift
// Aether3D
//
// PR2 Patch V4 - Observation Data Structure
// NOTE: This is PR2-specific, different from Core/Models/Observation
//

import Foundation

/// Observation error types
public enum ObservationErrorType: String, Codable, Sendable {
    case dynamicObject       // Moving object in scene
    case depthDistortion     // Depth sensor failure (glass, mirrors)
    case exposureDrift       // Auto-exposure changed
    case whiteBalanceDrift   // White balance shifted
    case motionBlur          // Camera moved too fast
    
    /// Unknown error type for forward compatibility
    case unknown
    
    // MARK: - Codable with Forward Compatibility
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        
        if let errorType = ObservationErrorType(rawValue: rawValue) {
            self = errorType
        } else {
            // Unknown value: default to unknown
            self = .unknown
            EvidenceLogger.warn("Unknown ObservationErrorType value decoded: \(rawValue), defaulting to .unknown")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        // Encode unknown as "unknown" for debugging
        var container = encoder.singleValueContainer()
        if self == .unknown {
            try container.encode("unknown")
        } else {
            try container.encode(self.rawValue)
        }
    }
}

/// Evidence observation data from a captured frame
/// NOTE: This is PR2-specific, different from Core/Models/Observation
/// This struct does NOT contain a quality field for ledger updates.
/// Quality is computed externally by Gate/Soft functions and passed separately.
public struct EvidenceObservation: Codable, Sendable {
    
    /// Patch ID this observation belongs to
    /// Uses spatial hash or voxel ID
    public let patchId: String
    
    /// Whether this observation is erroneous (DEPRECATED: use verdict instead)
    /// Kept for backward compatibility during migration
    /// - Dynamic object entered/left frame
    /// - ARKit depth distortion (glass, mirrors)
    /// - Auto-exposure/white-balance drift
    @available(*, deprecated, message: "Use verdict: ObservationVerdict instead")
    public let isErroneous: Bool  // LINT_OK: Deprecated API kept for backward compatibility
    
    /// Observation timestamp (will be migrated to CrossPlatformTimestamp)
    public let timestamp: TimeInterval
    
    /// Source frame ID
    public let frameId: String
    
    /// Error type (if isErroneous = true)
    public let errorType: ObservationErrorType?
    
    @available(*, deprecated, message: "Use init with verdict instead")
    public init(
        patchId: String,
        isErroneous: Bool,  // LINT_OK: Deprecated API kept for backward compatibility
        timestamp: TimeInterval,
        frameId: String,
        errorType: ObservationErrorType? = nil
    ) {
        self.patchId = patchId
        self.isErroneous = isErroneous
        self.timestamp = timestamp
        self.frameId = frameId
        self.errorType = errorType
    }
    
    /// Initialize with verdict (preferred)
    public init(
        patchId: String,
        timestamp: TimeInterval,
        frameId: String,
        errorType: ObservationErrorType? = nil
    ) {
        self.patchId = patchId
        self.isErroneous = false  // Default, verdict should be set separately
        self.timestamp = timestamp
        self.frameId = frameId
        self.errorType = errorType
    }
}

// NOTE: Use EvidenceObservation explicitly to avoid conflict with Core/Models/Observation
