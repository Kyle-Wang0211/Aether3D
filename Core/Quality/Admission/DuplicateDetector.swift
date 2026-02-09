// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DuplicateDetector.swift
// Aether3D
//
// PR#1 C-Class SOFT/HARD LIMIT - Duplicate Detector
//
// Deterministic duplicate detection based on SSOT constants
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(simd)
import simd
#endif

/// Patch candidate (simplified for duplicate detection)
public struct PatchCandidate {
    public let candidateId: UUID
    public let pose: SIMD3<Float>  // Simplified pose representation
    public let coverageCell: SIMD2<Int>  // Coverage cell coordinates
    public let radiance: SIMD3<Float>  // Radiance values
    
    public init(candidateId: UUID, pose: SIMD3<Float>, coverageCell: SIMD2<Int>, radiance: SIMD3<Float>) {
        self.candidateId = candidateId
        self.pose = pose
        self.coverageCell = coverageCell
        self.radiance = radiance
    }
}

/// Duplicate detector (deterministic, reproducible)
/// 
/// **v2.3b Sealed:**
/// - MUST be reproducible (same input produces same signature)
/// - MUST be based on SSOT constants, not runtime parameters
/// - Priority: MUST be evaluated before SOFT/HARD checks
public struct DuplicateDetector {
    public init() {}
    /// Compute duplicate signature for a patch candidate
    /// 
    /// Signature is deterministic and reproducible based on:
    /// - POSE_EPS (pose tolerance)
    /// - COVERAGE_CELL_SIZE (coverage cell size)
    /// - RADIANCE_BINNING (radiance binning)
    public static func computeDuplicateSignature(_ patch: PatchCandidate) -> String {
        // Bin pose with epsilon tolerance
        let poseBin = binPose(patch.pose, epsilon: CapacityLimitConstants.POSE_EPS)
        
        // Bin coverage cell
        let coverageBin = binCoverageCell(patch.coverageCell, size: CapacityLimitConstants.COVERAGE_CELL_SIZE)
        
        // Bin radiance
        let radianceBin = binRadiance(patch.radiance, binning: CapacityLimitConstants.RADIANCE_BINNING)
        
        // Hash all bins to create signature
        var signatureData = Data()
        signatureData.append(poseBin.0)
        signatureData.append(poseBin.1)
        signatureData.append(poseBin.2)
        signatureData.append(contentsOf: withUnsafeBytes(of: coverageBin.0.bigEndian) { Data($0) })
        signatureData.append(contentsOf: withUnsafeBytes(of: coverageBin.1.bigEndian) { Data($0) })
        signatureData.append(radianceBin.0)
        signatureData.append(radianceBin.1)
        signatureData.append(radianceBin.2)
        
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: signatureData)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: simple hash for platforms without CryptoKit
        var hashValue: UInt64 = 5381
        for byte in signatureData {
            hashValue = ((hashValue << 5) &+ hashValue) &+ UInt64(byte)
        }
        return String(format: "%016llx", hashValue)
        #endif
    }
    
    /// Check if patch is duplicate based on signature
    public static func isDuplicate(_ patch: PatchCandidate, existingSignatures: Set<String>) -> Bool {
        let signature = computeDuplicateSignature(patch)
        return existingSignatures.contains(signature)
    }
    
    // MARK: - Private Helpers
    
    private static func binPose(_ pose: SIMD3<Float>, epsilon: Double) -> (UInt8, UInt8, UInt8) {
        let x = UInt8(max(0, min(255, Int((Double(pose.x) / epsilon).rounded()))))
        let y = UInt8(max(0, min(255, Int((Double(pose.y) / epsilon).rounded()))))
        let z = UInt8(max(0, min(255, Int((Double(pose.z) / epsilon).rounded()))))
        return (x, y, z)
    }
    
    private static func binCoverageCell(_ cell: SIMD2<Int>, size: Double) -> (Int, Int) {
        let x = Int((Double(cell.x) / size).rounded())
        let y = Int((Double(cell.y) / size).rounded())
        return (x, y)
    }
    
    private static func binRadiance(_ radiance: SIMD3<Float>, binning: Int) -> (UInt8, UInt8, UInt8) {
        let r = UInt8(max(0, min(255, Int(radiance.x * Float(binning)))))
        let g = UInt8(max(0, min(255, Int(radiance.y * Float(binning)))))
        let b = UInt8(max(0, min(255, Int(radiance.z * Float(binning)))))
        return (r, g, b)
    }
}
