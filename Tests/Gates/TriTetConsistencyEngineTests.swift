// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
#if canImport(simd)
import simd
#endif
@testable import Aether3DCore

final class TriTetConsistencyEngineTests: XCTestCase {
    func testKuhn5ReturnsFiveTetrahedra() {
        let even = TriTetConsistencyEngine.kuhn5(parity: 0)
        let odd = TriTetConsistencyEngine.kuhn5(parity: 1)

        XCTAssertEqual(even.count, 5)
        XCTAssertEqual(odd.count, 5)
        XCTAssertNotEqual(even[0].0, odd[0].0) // parity should switch diagonal family
    }

    func testConsistencyClassifiesMeasuredForHighCoverage() {
        let verts = sampleVertices(viewCount: 4)
        let tetrahedra = TriTetConsistencyEngine.kuhn5(parity: 0).enumerated().map {
            TriTetTetrahedron(id: $0.offset, vertices: $0.element)
        }
        let triangle = ScanTriangle(
            patchId: "tri-1",
            vertices: (SIMD3<Float>(0.2, 0.2, 0.2), SIMD3<Float>(0.3, 0.2, 0.2), SIMD3<Float>(0.2, 0.3, 0.2)),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.005
        )

        let report = TriTetConsistencyEngine.evaluate(
            triangles: [triangle],
            vertices: verts,
            tetrahedra: tetrahedra,
            config: TriTetConfig(measuredMinViewCount: 3, estimatedMinViewCount: 2, maxTriangleToTetDistance: 2.0)
        )

        XCTAssertEqual(report.measuredCount, 1)
        XCTAssertEqual(report.unknownCount, 0)
        XCTAssertGreaterThan(report.combinedScore, 0.9)
    }

    func testConsistencyClassifiesUnknownForLowCoverage() {
        let verts = sampleVertices(viewCount: 1)
        let tetrahedra = TriTetConsistencyEngine.kuhn5(parity: 0).enumerated().map {
            TriTetTetrahedron(id: $0.offset, vertices: $0.element)
        }
        let triangle = ScanTriangle(
            patchId: "tri-2",
            vertices: (SIMD3<Float>(0.6, 0.6, 0.6), SIMD3<Float>(0.7, 0.6, 0.6), SIMD3<Float>(0.6, 0.7, 0.6)),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.006
        )

        let report = TriTetConsistencyEngine.evaluate(
            triangles: [triangle],
            vertices: verts,
            tetrahedra: tetrahedra,
            config: TriTetConfig(measuredMinViewCount: 3, estimatedMinViewCount: 2, maxTriangleToTetDistance: 2.0)
        )

        XCTAssertEqual(report.measuredCount, 0)
        XCTAssertEqual(report.unknownCount, 1)
        XCTAssertLessThan(report.combinedScore, 0.2)
    }

    private func sampleVertices(viewCount: Int) -> [TriTetVertex] {
        [
            TriTetVertex(index: 0, position: SIMD3<Float>(0, 0, 0), viewCount: viewCount),
            TriTetVertex(index: 1, position: SIMD3<Float>(1, 0, 0), viewCount: viewCount),
            TriTetVertex(index: 2, position: SIMD3<Float>(0, 1, 0), viewCount: viewCount),
            TriTetVertex(index: 3, position: SIMD3<Float>(1, 1, 0), viewCount: viewCount),
            TriTetVertex(index: 4, position: SIMD3<Float>(0, 0, 1), viewCount: viewCount),
            TriTetVertex(index: 5, position: SIMD3<Float>(1, 0, 1), viewCount: viewCount),
            TriTetVertex(index: 6, position: SIMD3<Float>(0, 1, 1), viewCount: viewCount),
            TriTetVertex(index: 7, position: SIMD3<Float>(1, 1, 1), viewCount: viewCount)
        ]
    }
}

