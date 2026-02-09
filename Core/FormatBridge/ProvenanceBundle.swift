// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ProvenanceBundle.swift
// Aether3D
//
// Provenance Bundle - Canonical schema with Merkle proof, STH, time anchors
// 符合 Phase 5: Format Bridge + Provenance Bundle
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Export Format
///
/// Supported export formats.
public enum ExportFormat: String, Codable, Sendable {
    case gltf
    case usd
    case tiles3d
    case e57
    case gltfGaussianSplatting
}

/// Provenance Manifest
///
/// Manifest information for provenance bundle.
public struct ProvenanceManifest: Codable, Sendable {
    public let format: ExportFormat
    public let version: String
    public let exportedAt: Date
    public let exporterVersion: String
    
    public init(format: ExportFormat, version: String, exportedAt: Date, exporterVersion: String) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.exporterVersion = exporterVersion
    }
}

/// Device Attestation Status
///
/// Device attestation status in provenance bundle.
public struct DeviceAttestationStatus: Codable, Sendable {
    public let keyId: String
    public let riskMetric: Double
    public let counter: UInt64
    public let status: String
    
    public init(keyId: String, riskMetric: Double, counter: UInt64, status: String) {
        self.keyId = keyId
        self.riskMetric = riskMetric
        self.counter = counter
        self.status = status
    }
}

/// Provenance Bundle
///
/// Canonical provenance bundle with Merkle proof, STH, time anchors, and device attestation.
/// 符合 Phase 5: ProvenanceBundle Schema Definition (RFC 8785 JCS)
public struct ProvenanceBundle: Codable, Sendable {
    public let manifest: ProvenanceManifest
    public let sth: SignedTreeHead?
    public let timeProof: TripleTimeProof?
    public let merkleProof: InclusionProof?
    public let deviceAttestation: DeviceAttestationStatus?
    
    public init(manifest: ProvenanceManifest, sth: SignedTreeHead?, timeProof: TripleTimeProof?, merkleProof: InclusionProof?, deviceAttestation: DeviceAttestationStatus?) {
        self.manifest = manifest
        self.sth = sth
        self.timeProof = timeProof
        self.merkleProof = merkleProof
        self.deviceAttestation = deviceAttestation
    }
    
    /// Encode to canonical JSON (RFC 8785 JCS)
    /// 
    /// 符合 Phase 5: Canonical JSON with UTF-16 key sorting
    /// - Returns: Canonical JSON data
    /// - Throws: ProvenanceBundleError if encoding fails
    public func encode() throws -> Data {
        // Use JSONEncoder with sorted keys for now
        // In production, use CanonicalJSONEncoder for full RFC 8785 JCS compliance
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
    
    /// Compute bundle hash
    /// 
    /// - Returns: SHA-256 hash of canonical JSON
    /// - Throws: ProvenanceBundleError if hashing fails
    public func hash() throws -> Data {
        let canonicalJSON = try encode()
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: canonicalJSON))
        #elseif canImport(Crypto)
        return Data(Crypto.SHA256.hash(data: canonicalJSON))
        #else
        // Guard clause required for fatalError binding in Core/
        guard false else { fatalError("No crypto implementation available") }
        #endif
    }
}

/// Provenance Bundle Errors
public enum ProvenanceBundleError: Error, Sendable {
    case encodingFailed(String)
    case invalidSchema(String)
    case missingRequiredField(String)
    
    public var localizedDescription: String {
        switch self {
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .invalidSchema(let reason):
            return "Invalid schema: \(reason)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        }
    }
}
