// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  VerificationMode.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Verification Modes
//

import Foundation

/// Four-mode verification strategy.
///
/// INV-B12: Adaptive four-mode verification (V6)
public enum VerificationMode {
    /// Progressive: Verify criticalPaths first, then remaining in priority order
    case progressive
    
    /// Probabilistic: Verify all critical + statistically sampled subset
    /// - delta: Miss probability (0.001 = 99.9% detection probability)
    case probabilistic(delta: Double = 0.001)
    
    /// Incremental: Only re-verify changed assets + Merkle path
    /// - previousReceipt: Previous verification receipt for comparison
    case incremental(previousReceipt: VerificationReceipt)
    
    /// Full: Verify all assets, rebuild Merkle tree, compare everything
    case full
}

/// Verification receipt — proof of completed verification.
///
/// Can be stored and reused for incremental verification.
public struct VerificationReceipt: Codable, Sendable {
    /// Bundle hash that was verified
    public let bundleHash: String
    
    /// Timestamp when verification completed (deterministicTimestamp format)
    public let verifiedAt: String
    
    /// Individual asset verification receipts
    public let assetReceipts: [AssetVerificationReceipt]
    
    /// Merkle root that was verified
    public let merkleRoot: String
}

/// Single asset verification receipt.
public struct AssetVerificationReceipt: Codable, Sendable {
    /// Asset path
    public let path: String
    
    /// Asset digest (OCI format)
    public let digest: String
    
    /// Asset byte count
    public let byteCount: Int64
    
    /// Timestamp when verified (deterministicTimestamp format)
    public let verifiedAt: String
}

/// Probabilistic sample size computation.
///
/// Uses hypergeometric distribution: for N total assets, to detect at least 1
/// tampered asset with probability >= 1 - delta, sample size =
/// ceil(N * (1 - pow(delta, 1.0/N))).
///
/// N=10000, delta=0.001 → sample ≈ 69 assets.
/// N=1000, delta=0.001 → sample ≈ 7 assets.
///
/// **SEAL FIX**: All critical-tier assets are ALWAYS verified regardless of mode.
/// **GATE**: Probabilistic mode must never skip critical/LOD assets.
internal func computeSampleSize(totalAssets: Int, delta: Double) -> Int {
    guard totalAssets > 0, delta > 0, delta < 1 else { return totalAssets }
    let n = Double(totalAssets)
    return min(totalAssets, Int(ceil(n * (1.0 - pow(delta, 1.0 / n)))))
}
