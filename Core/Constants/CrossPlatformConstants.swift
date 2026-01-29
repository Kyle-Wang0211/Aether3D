//
// CrossPlatformConstants.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Cross-Platform Consistency Constants
//
// This file defines constants for cross-platform consistency (A2, A3, A5, CL2, F1).
//

import Foundation

/// Cross-platform consistency constants.
///
/// **Rule ID:** A2, A3, A5, CL2, F1
/// **Status:** IMMUTABLE
public enum CrossPlatformConstants {
    
    // MARK: - Quantization Precision Constants (A3)
    
    /// Quantization precision for geomId (1mm, cross-epoch stable).
    /// **Rule ID:** A3
    /// **Status:** IMMUTABLE
    /// **Unit:** meters
    /// **Scope:** identity
    public static let QUANT_POS_GEOM_ID: Double = 1e-3
    
    /// Quantization precision for patchId (0.1mm, epoch-local precise).
    /// **Rule ID:** A3
    /// **Status:** IMMUTABLE
    /// **Unit:** meters
    /// **Scope:** identity
    public static let QUANT_POS_PATCH_ID: Double = 1e-4
    
    // MARK: - Byte Order Constants (A2)
    
    /// Byte order for all integer encoding: Big-Endian.
    /// **Rule ID:** A2
    /// **Status:** IMMUTABLE
    public static let BYTE_ORDER = "BIG_ENDIAN"
    
    // MARK: - meshEpochSalt Input Closure Constants (A5)
    
    /// meshEpochSalt included inputs (identity-causal).
    /// **Rule ID:** A5
    /// **Status:** IMMUTABLE
    ///
    /// These inputs causally determine mesh geometry:
    /// - rawVideoDigest
    /// - cameraIntrinsicsDigest
    /// - reconstructionParamsDigest
    /// - pipelineVersion
    public static let MESH_EPOCH_SALT_INCLUDED_INPUTS = [
        "rawVideoDigest",
        "cameraIntrinsicsDigest",
        "reconstructionParamsDigest",
        "pipelineVersion"
    ]
    
    /// meshEpochSalt excluded inputs (must not affect identity).
    /// **Rule ID:** A5
    /// **Status:** IMMUTABLE
    ///
    /// These inputs are explicitly forbidden:
    /// - deviceModelClass (causes meaningless identity forks)
    /// - timestampRange (breaks cross-device inheritance)
    public static let MESH_EPOCH_SALT_EXCLUDED_INPUTS = [
        "deviceModelClass",
        "timestampRange"
    ]
    
    /// meshEpochSalt audit-only inputs (not identity-causal).
    /// **Rule ID:** A5
    /// **Status:** IMMUTABLE
    ///
    /// These inputs are used for audit/dispute resolution only:
    /// - frameDigestMerkleRoot
    public static let MESH_EPOCH_SALT_AUDIT_ONLY_INPUTS = [
        "frameDigestMerkleRoot"
    ]
    
    // MARK: - Cross-Platform Numerical Consistency Tolerances (CL2)
    
    /// Coverage/Ratio relative error tolerance.
    /// **Rule ID:** CL2
    /// **Status:** IMMUTABLE
    /// **Unit:** relative error
    /// **Scope:** equivalence_test
    ///
    /// **Note:** These tolerances apply to cross-platform equivalence checks, not algorithm quality.
    public static let TOLERANCE_COVERAGE_RATIO_RELATIVE: Double = 1e-4
    
    /// Lab color component absolute error tolerance.
    /// **Rule ID:** CL2, F2
    /// **Status:** IMMUTABLE
    /// **Unit:** absolute error per channel
    /// **Scope:** equivalence_test
    ///
    /// **Note:** Per-channel absolute error (not ΔE). Channels: L*, a*, b*
    public static let TOLERANCE_LAB_COLOR_ABSOLUTE: Double = 1e-3
    
    // MARK: - Relative Error Formula Constants (F1 - v1.1.1)
    
    /// Epsilon for relative error formula (prevents division by zero).
    /// **Rule ID:** F1
    /// **Status:** IMMUTABLE
    /// **Unit:** dimensionless
    /// **Scope:** equivalence_test
    ///
    /// Formula: relErr(a, b) = |a - b| / max(eps, max(|a|, |b|))
    public static let RELATIVE_ERROR_EPSILON: Double = 1e-12
    
    // MARK: - Hash Algorithm (G2 - v1.1.1)
    
    /// Hash algorithm identifier (v1.1.1 finalized).
    /// **Rule ID:** G2
    /// **Status:** IMMUTABLE
    ///
    /// Single algorithm only. Any future alternative requires new schema.
    public static let HASH_ALGO_ID = "SHA256"
    
    // MARK: - Digest Output Encoding
    
    /// Digest output encoding format.
    /// **Rule ID:** C84
    /// **Status:** IMMUTABLE
    ///
    /// Choose ONE and lock it: lowercase hex OR base64url.
    /// Prefer lowercase hex.
    public static let DIGEST_ENCODING_FORMAT = "hex_lowercase"
}
