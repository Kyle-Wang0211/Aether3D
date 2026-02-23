// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class TriTetTSDFMappingTests: XCTestCase {
    func testParityIsDerivedFromBlockIndexSumModuloTwo() {
        XCTAssertEqual(TriTetTSDFMapping.parity(for: BlockIndex(0, 0, 0)), 0)
        XCTAssertEqual(TriTetTSDFMapping.parity(for: BlockIndex(1, 0, 0)), 1)
        XCTAssertEqual(TriTetTSDFMapping.parity(for: BlockIndex(2, 1, 0)), 1)
        XCTAssertEqual(TriTetTSDFMapping.parity(for: BlockIndex(-1, 0, 0)), 1)
    }

    func testMapRejectsOutOfRangeTetIndex() {
        XCTAssertNil(TriTetTSDFMapping.map(blockIndex: BlockIndex(0, 0, 0), localTetIndex: -1))
        XCTAssertNil(TriTetTSDFMapping.map(blockIndex: BlockIndex(0, 0, 0), localTetIndex: 5))
    }

    func testDecompositionMatchesKuhn5TablesForBothParityFamilies() {
        assertDecompositionMatchesReference(blockIndex: BlockIndex(4, 2, 0), parity: 0)
        assertDecompositionMatchesReference(blockIndex: BlockIndex(5, 2, 0), parity: 1)
    }

    func testMappingEmitsDeterministicCornerCoordinates() {
        let block = BlockIndex(10, 20, 30)
        guard let cell = TriTetTSDFMapping.map(blockIndex: block, localTetIndex: 0) else {
            return XCTFail("Expected valid tet mapping")
        }

        // parity=0, tet0 = (0,1,3,7)
        XCTAssertEqual(cell.c0, BlockIndex(10, 20, 30))
        XCTAssertEqual(cell.c1, BlockIndex(11, 20, 30))
        XCTAssertEqual(cell.c2, BlockIndex(11, 21, 30))
        XCTAssertEqual(cell.c3, BlockIndex(11, 21, 31))
    }

    func testDigestAndDecompositionAreDeterministic() {
        let block = BlockIndex(3, 7, 11)
        let first = TriTetTSDFMapping.decomposition(for: block)
        let second = TriTetTSDFMapping.decomposition(for: block)

        XCTAssertEqual(first, second)
        XCTAssertTrue(TriTetTSDFMapping.isDeterministicDecomposition(for: block))
        XCTAssertEqual(
            TriTetTSDFMapping.decompositionDigest(for: block),
            TriTetTSDFMapping.decompositionDigest(for: block)
        )
    }

    private func assertDecompositionMatchesReference(blockIndex: BlockIndex, parity: Int) {
        XCTAssertEqual(TriTetTSDFMapping.parity(for: blockIndex), parity)
        let mapped = TriTetTSDFMapping.decomposition(for: blockIndex)
        let expected = TriTetConsistencyEngine.kuhn5(parity: parity)

        XCTAssertEqual(mapped.count, 5)
        XCTAssertEqual(expected.count, 5)
        for index in 0..<5 {
            XCTAssertEqual(mapped[index].localTetIndex, index)
            let actual = mapped[index].localVertices
            XCTAssertEqual(
                [actual.0, actual.1, actual.2, actual.3],
                [expected[index].0, expected[index].1, expected[index].2, expected[index].3],
                "Mismatch at local tet index \(index)"
            )
        }
    }
}
