// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObservationVerdict.swift
// Aether3D
//
// PR2 Patch V4 - Observation Verdict (Closed Set)
// Determines how observation affects ledger
//

import Foundation

/// Observation verdict (closed set)
/// Determines how observation affects ledger
public enum ObservationVerdict: String, Codable, Sendable {
    
    /// Good observation: full credit
    case good
    
    /// Suspect observation: reduced delta multiplier, no penalty
    /// Used when uncertain (single frame anomaly, edge case)
    case suspect
    
    /// Bad observation: applies penalty with cooldown
    /// Only used when confident (confirmed dynamic object, sensor failure)
    case bad
    
    /// Unknown value placeholder (for forward compatibility, decode only)
    case unknown
    
    /// Verdict reason for debugging/analytics
    public struct Reason: Codable, Sendable {
        public let code: ReasonCode
        public let confidence: Double  // 0-1
        
        public enum ReasonCode: String, Codable, Sendable {
            // Good reasons
            case normalObservation
            case highConfidenceMatch
            case stableDepth
            
            // Suspect reasons
            case singleFrameAnomaly
            case edgeCaseGeometry
            case lowConfidenceMatch
            case slightMotionBlur
            
            // Bad reasons
            case confirmedDynamicObject
            case confirmedDepthFailure
            case confirmedExposureDrift
            case confirmedMotionBlur
            case multiFrameAnomaly
            
            /// Unknown reason code for forward compatibility
            case unknown
            
            // MARK: - Codable with Forward Compatibility
            
            public init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                
                if let code = ReasonCode(rawValue: rawValue) {
                    self = code
                } else {
                    self = .unknown
                    EvidenceLogger.warn("Unknown ReasonCode value decoded: \(rawValue), defaulting to .unknown")
                }
            }
            
            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                if self == .unknown {
                    try container.encode("unknown")
                } else {
                    try container.encode(self.rawValue)
                }
            }
        }
    }
    
    /// Delta multiplier based on verdict
    public var deltaMultiplier: Double {
        switch self {
        case .good:    return 1.0
        case .suspect: return 0.3   // Slows down but doesn't stop
        case .bad:     return 0.0   // No positive contribution
        case .unknown: return 0.3   // Treat unknown as suspect
        }
    }
    
    // MARK: - Codable with Forward Compatibility
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        
        if let verdict = ObservationVerdict(rawValue: rawValue) {
            self = verdict
        } else {
            // Unknown value: default to suspect (safe choice)
            // Log warning for debugging (if logger available)
            self = .unknown
            // Note: In production, this should log via EvidenceLogger
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        // Never encode .unknown
        guard self != .unknown else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Cannot encode .unknown verdict"))
        }
        
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// Extended observation with verdict
public struct JudgedObservation: Codable, Sendable {
    public let observation: EvidenceObservation
    public let verdict: ObservationVerdict
    public let reason: ObservationVerdict.Reason?
    
    /// Delta multiplier based on verdict
    public var deltaMultiplier: Double {
        return verdict.deltaMultiplier
    }
    
    public init(
        observation: EvidenceObservation,
        verdict: ObservationVerdict,
        reason: ObservationVerdict.Reason? = nil
    ) {
        self.observation = observation
        self.verdict = verdict
        self.reason = reason
    }
}
