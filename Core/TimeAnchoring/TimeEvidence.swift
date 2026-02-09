// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// TimeEvidence.swift
// Aether3D
//
// Phase 1: Time Anchoring - Unified Time Evidence Model
//

import Foundation

/// Unified time evidence from a single source
///
/// **Purpose:** Abstract over TSA, Roughtime, and OpenTimestamps
///
/// **Invariants:**
/// - INV-C2: All time values use Big-Endian encoding
public struct TimeEvidence: Codable, Sendable {
    /// Evidence source
    public let source: Source
    
    /// Time in UTC nanoseconds since Unix epoch
    public let timeNs: UInt64
    
    /// Uncertainty radius in nanoseconds (optional)
    /// If present, time is in interval [timeNs - uncertaintyNs, timeNs + uncertaintyNs]
    public let uncertaintyNs: UInt64?
    
    /// Verification status
    public let verificationStatus: VerificationStatus
    
    /// Raw proof bytes (source-specific format)
    public let rawProof: Data
    
    /// Evidence source enumeration
    public enum Source: String, Codable, Sendable {
        case tsa
        case roughtime
        case opentimestamps
    }
    
    /// Verification status
    public enum VerificationStatus: String, Codable, Sendable {
        case verified
        case unverified
        case failed
    }
    
    /// Time interval: [lower, upper]
    public var timeInterval: (lower: UInt64, upper: UInt64) {
        if let uncertainty = uncertaintyNs {
            let lower = timeNs >= uncertainty ? timeNs - uncertainty : 0
            let upper = timeNs + uncertainty
            return (lower: lower, upper: upper)
        } else {
            // Point estimate (no uncertainty)
            return (lower: timeNs, upper: timeNs)
        }
    }
    
    /// Check if this evidence agrees with another (intervals overlap)
    public func agrees(with other: TimeEvidence) -> Bool {
        let selfInterval = timeInterval
        let otherInterval = other.timeInterval
        
        // Intervals overlap if: self.lower <= other.upper && other.lower <= self.upper
        return selfInterval.lower <= otherInterval.upper && otherInterval.lower <= selfInterval.upper
    }
}
