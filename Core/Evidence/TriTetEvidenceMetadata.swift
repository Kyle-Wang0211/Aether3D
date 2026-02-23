// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Tri/Tet-bound evidence metadata persisted with observation-level records.
public struct TriTetEvidenceMetadata: Codable, Sendable, Equatable {
    /// SHA-256 digest generated from deterministic Tri/Tet binding payload.
    public let triTetBindingDigest: String

    /// Cross-validation reason code emitted by rule+ML dual-lane fusion.
    public let crossValidationReasonCode: String

    /// Digest schema version to keep evolution append-only.
    public let digestVersion: Int

    public init(
        triTetBindingDigest: String,
        crossValidationReasonCode: String,
        digestVersion: Int = TriTetEvidenceDigest.digestVersion
    ) {
        self.triTetBindingDigest = triTetBindingDigest
        self.crossValidationReasonCode = crossValidationReasonCode
        self.digestVersion = digestVersion
    }
}

/// Deterministic digest builder for Tri/Tet evidence bindings.
public enum TriTetEvidenceDigest {
    public static let digestVersion: Int = 1

    public static func metadata(
        from binding: TriTetConsistencyBinding,
        crossValidationReasonCode: String
    ) -> TriTetEvidenceMetadata {
        TriTetEvidenceMetadata(
            triTetBindingDigest: bindingDigest(
                from: binding,
                crossValidationReasonCode: crossValidationReasonCode
            ),
            crossValidationReasonCode: crossValidationReasonCode,
            digestVersion: digestVersion
        )
    }

    public static func bindingDigest(
        from binding: TriTetConsistencyBinding,
        crossValidationReasonCode: String
    ) -> String {
        SHA256Utility.sha256(canonicalPayload(
            from: binding,
            crossValidationReasonCode: crossValidationReasonCode
        ))
    }

    public static func canonicalPayload(
        from binding: TriTetConsistencyBinding,
        crossValidationReasonCode: String
    ) -> String {
        let distanceMicrometers = Int(
            (Double(binding.triToTetDistance) * 1_000_000.0).rounded(.toNearestOrAwayFromZero)
        )

        let fields = [
            "v=\(digestVersion)",
            encodedField(key: "patch", value: binding.trianglePatchId),
            "tet=\(binding.tetrahedronId)",
            encodedField(key: "class", value: binding.classification.rawValue),
            "dist_um=\(distanceMicrometers)",
            "min_views=\(binding.minTetViewCount)",
            encodedField(key: "reason", value: crossValidationReasonCode),
        ]
        return fields.joined(separator: "|")
    }

    private static func encodedField(key: String, value: String) -> String {
        "\(key)=\(value.utf8.count):\(value)"
    }
}
