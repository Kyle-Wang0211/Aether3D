// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class TriTetMerkleLeafTests: XCTestCase {
    func testLeafHashIsDeterministicAndFixedSize() {
        let leaf = TriTetMerkleLeaf(
            patchId: "patch-A",
            evidenceDigest: "evidence-digest-A",
            triTetBindingDigest: "tri-tet-digest-A",
            crossValidationReasonCode: "OUTLIER_BOTH_INLIER"
        )

        let hashA = leaf.leafHash()
        let hashB = leaf.leafHash()

        XCTAssertEqual(hashA, hashB)
        XCTAssertEqual(hashA.count, 32)
    }

    func testProofVerificationIncludesTriTetBindingDigest() async throws {
        let leafA = TriTetMerkleLeaf(
            patchId: "patch-A",
            evidenceDigest: "evidence-digest-A",
            triTetBindingDigest: "tri-tet-digest-A",
            crossValidationReasonCode: "OUTLIER_BOTH_INLIER"
        )
        let leafB = TriTetMerkleLeaf(
            patchId: "patch-B",
            evidenceDigest: "evidence-digest-B",
            triTetBindingDigest: "tri-tet-digest-B",
            crossValidationReasonCode: "CALIBRATION_BOTH_PASS"
        )

        let tree = MerkleTree()
        await tree.appendHash(leafA.leafHash())
        await tree.appendHash(leafB.leafHash())

        let root = await tree.rootHash
        let proof = try await tree.generateInclusionProof(leafIndex: 0)
        XCTAssertTrue(TriTetMerkleProof.verifyInclusion(leaf: leafA, proof: proof, rootHash: root))

        let tampered = TriTetMerkleLeaf(
            patchId: leafA.patchId,
            evidenceDigest: leafA.evidenceDigest,
            triTetBindingDigest: "tri-tet-digest-A-tampered",
            crossValidationReasonCode: leafA.crossValidationReasonCode
        )
        XCTAssertFalse(TriTetMerkleProof.verifyInclusion(leaf: tampered, proof: proof, rootHash: root))
    }

    func testCanonicalDataChangesWhenReasonCodeChanges() {
        let keep = TriTetMerkleLeaf(
            patchId: "patch-A",
            evidenceDigest: "evidence-digest-A",
            triTetBindingDigest: "tri-tet-digest-A",
            crossValidationReasonCode: "CALIBRATION_BOTH_PASS"
        )
        let reject = TriTetMerkleLeaf(
            patchId: "patch-A",
            evidenceDigest: "evidence-digest-A",
            triTetBindingDigest: "tri-tet-digest-A",
            crossValidationReasonCode: "CALIBRATION_BOTH_FAIL"
        )

        XCTAssertNotEqual(keep.canonicalData(), reject.canonicalData())
        XCTAssertNotEqual(keep.leafHash(), reject.leafHash())
    }
}
