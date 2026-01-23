//
// DeterministicIdentityAPI.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1.1 - Single-Entry Deterministic Identity APIs
//
// This file provides centralized APIs for identity-relevant encoding.
// All identity derivation MUST go through these APIs.
//

import Foundation

/// Single-entry deterministic identity APIs (3.1).
///
/// **Rule ID:** 3.1
/// **Status:** IMMUTABLE
///
/// **Purpose:** Prevent future PRs from re-implementing encoding "almost correctly".
/// Keep identity logic auditable and greppable.
///
/// **Rule:** All identity-relevant encoding MUST go through these APIs.
/// No ad-hoc byte assembly, no direct Data.append(...) for identity material.
public enum DeterministicIdentityAPI {
    
    // MARK: - Domain-Separated Hash Input Construction
    
    /// Creates domain-separated bytes for patchId computation.
    ///
    /// **Rule ID:** A2, G1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter inputBytes: The input bytes to hash
    /// - Returns: Domain-separated bytes ready for hashing
    /// - Throws: EncodingError if domain prefix encoding fails
    public static func makePatchIdHashInput(_ inputBytes: Data) throws -> Data {
        var result = Data()
        result.append(try DeterministicEncoding.encodeDomainPrefix(DeterministicEncoding.DOMAIN_PREFIX_PATCH_ID))
        result.append(inputBytes)
        return result
    }
    
    /// Creates domain-separated bytes for geomId computation.
    ///
    /// **Rule ID:** A2, G1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter inputBytes: The input bytes to hash
    /// - Returns: Domain-separated bytes ready for hashing
    /// - Throws: EncodingError if domain prefix encoding fails
    public static func makeGeomIdHashInput(_ inputBytes: Data) throws -> Data {
        var result = Data()
        result.append(try DeterministicEncoding.encodeDomainPrefix(DeterministicEncoding.DOMAIN_PREFIX_GEOM_ID))
        result.append(inputBytes)
        return result
    }
    
    /// Creates domain-separated bytes for meshEpochSalt computation.
    ///
    /// **Rule ID:** A2, A5, G1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter inputBytes: The input bytes to hash
    /// - Returns: Domain-separated bytes ready for hashing
    /// - Throws: EncodingError if domain prefix encoding fails
    public static func makeMeshEpochSaltHashInput(_ inputBytes: Data) throws -> Data {
        var result = Data()
        result.append(try DeterministicEncoding.encodeDomainPrefix(DeterministicEncoding.DOMAIN_PREFIX_MESH_EPOCH))
        result.append(inputBytes)
        return result
    }
    
    /// Creates domain-separated bytes for assetRoot computation.
    ///
    /// **Rule ID:** A2, G1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter inputBytes: The input bytes to hash
    /// - Returns: Domain-separated bytes ready for hashing
    /// - Throws: EncodingError if domain prefix encoding fails
    public static func makeAssetRootHashInput(_ inputBytes: Data) throws -> Data {
        var result = Data()
        result.append(try DeterministicEncoding.encodeDomainPrefix(DeterministicEncoding.DOMAIN_PREFIX_ASSET_ROOT))
        result.append(inputBytes)
        return result
    }
    
    /// Creates domain-separated bytes for evidence hash computation.
    ///
    /// **Rule ID:** A2, G1
    /// **Status:** IMMUTABLE
    ///
    /// - Parameter inputBytes: The input bytes to hash
    /// - Returns: Domain-separated bytes ready for hashing
    /// - Throws: EncodingError if domain prefix encoding fails
    public static func makeEvidenceHashInput(_ inputBytes: Data) throws -> Data {
        var result = Data()
        result.append(try DeterministicEncoding.encodeDomainPrefix(DeterministicEncoding.DOMAIN_PREFIX_EVIDENCE))
        result.append(inputBytes)
        return result
    }
    
    // MARK: - Forbidden Usage Patterns
    
    /// **FORBIDDEN:** Direct Data.append(...) for identity material
    /// **FORBIDDEN:** Ad-hoc byte assembly for identity hashing
    /// **FORBIDDEN:** Free-form string literals in identity hashing
    ///
    /// **Rule ID:** 3.1, 3.2
    /// **Status:** IMMUTABLE
    ///
    /// All identity-relevant encoding MUST go through:
    /// - DeterministicEncoding (for encoding)
    /// - DeterministicQuantization (for quantization)
    /// - DeterministicIdentityAPI (for domain separation)
    ///
    /// This keeps identity logic auditable and greppable.
}
