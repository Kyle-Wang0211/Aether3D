// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class TriTetEvidenceMetadataTests: XCTestCase {
    func testBindingDigestIsDeterministic() {
        let binding = sampleBinding()
        let reasonCode = "OUTLIER_BOTH_INLIER"

        let digestA = TriTetEvidenceDigest.bindingDigest(
            from: binding,
            crossValidationReasonCode: reasonCode
        )
        let digestB = TriTetEvidenceDigest.bindingDigest(
            from: binding,
            crossValidationReasonCode: reasonCode
        )

        XCTAssertEqual(digestA, digestB)
        XCTAssertEqual(digestA.count, 64)
    }

    func testBindingDigestChangesWhenReasonCodeChanges() {
        let binding = sampleBinding()
        let digestA = TriTetEvidenceDigest.bindingDigest(
            from: binding,
            crossValidationReasonCode: "OUTLIER_BOTH_INLIER"
        )
        let digestB = TriTetEvidenceDigest.bindingDigest(
            from: binding,
            crossValidationReasonCode: "OUTLIER_DISAGREEMENT_DOWNGRADE"
        )

        XCTAssertNotEqual(digestA, digestB)
    }

    func testEvidenceObservationCodableRoundTripPreservesTriTetMetadata() throws {
        let binding = sampleBinding()
        let metadata = TriTetEvidenceDigest.metadata(
            from: binding,
            crossValidationReasonCode: "CALIBRATION_BOTH_PASS"
        )

        let observation = EvidenceObservation(
            patchId: "patch-42",
            timestamp: 123.456,
            frameId: "frame-42",
            errorType: nil,
            triTetMetadata: metadata
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(observation)
        let decoded = try JSONDecoder().decode(EvidenceObservation.self, from: payload)

        XCTAssertEqual(decoded.patchId, observation.patchId)
        XCTAssertEqual(decoded.frameId, observation.frameId)
        XCTAssertEqual(decoded.triTetMetadata?.triTetBindingDigest, metadata.triTetBindingDigest)
        XCTAssertEqual(decoded.triTetMetadata?.crossValidationReasonCode, metadata.crossValidationReasonCode)
        XCTAssertEqual(decoded.triTetMetadata?.digestVersion, TriTetEvidenceDigest.digestVersion)
    }

    private func sampleBinding() -> TriTetConsistencyBinding {
        TriTetConsistencyBinding(
            trianglePatchId: "patch-42",
            tetrahedronId: 7,
            classification: .measured,
            triToTetDistance: 0.0125,
            minTetViewCount: 5
        )
    }
}
