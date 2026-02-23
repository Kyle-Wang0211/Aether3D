// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Canonical Merkle leaf payload carrying Tri/Tet binding provenance.
public struct TriTetMerkleLeaf: Codable, Sendable, Equatable {
    public let patchId: String
    public let evidenceDigest: String
    public let triTetBindingDigest: String
    public let crossValidationReasonCode: String
    public let schemaVersion: Int

    public init(
        patchId: String,
        evidenceDigest: String,
        triTetBindingDigest: String,
        crossValidationReasonCode: String,
        schemaVersion: Int = 1
    ) {
        self.patchId = patchId
        self.evidenceDigest = evidenceDigest
        self.triTetBindingDigest = triTetBindingDigest
        self.crossValidationReasonCode = crossValidationReasonCode
        self.schemaVersion = schemaVersion
    }

    public func canonicalData() -> Data {
        let payload = [
            "v=\(schemaVersion)",
            encodedField(key: "patch", value: patchId),
            encodedField(key: "evidence", value: evidenceDigest),
            encodedField(key: "tri_tet", value: triTetBindingDigest),
            encodedField(key: "reason", value: crossValidationReasonCode),
        ].joined(separator: "|")
        return Data(payload.utf8)
    }

    public func leafHash() -> Data {
        MerkleTreeHash.hashLeaf(canonicalData())
    }

    private func encodedField(key: String, value: String) -> String {
        "\(key)=\(value.utf8.count):\(value)"
    }
}

public enum TriTetMerkleProof {
    /// Verify inclusion proof with a leaf whose payload includes Tri/Tet digest.
    public static func verifyInclusion(
        leaf: TriTetMerkleLeaf,
        proof: InclusionProof,
        rootHash: Data
    ) -> Bool {
        proof.verify(leafHash: leaf.leafHash(), rootHash: rootHash)
    }
}
