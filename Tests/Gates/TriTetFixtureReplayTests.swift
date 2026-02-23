// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import XCTest
@testable import Aether3DCore

final class TriTetFixtureReplayTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Kuhn5Tables: Decodable {
            let parity0: [[Int]]
            let parity1: [[Int]]
        }

        struct Expected: Decodable {
            let max_unknown_ratio: Float
        }

        struct ReplaySample: Decodable {
            struct Config: Decodable {
                let measuredMinViewCount: Int
                let estimatedMinViewCount: Int
                let maxTriangleToTetDistance: Float
            }

            struct Vertex: Decodable {
                let index: Int
                let position: [Float]
                let viewCount: Int
            }

            struct Tetrahedron: Decodable {
                let id: Int
                let vertices: [Int]
            }

            struct Triangle: Decodable {
                let patchId: String
                let vertices: [[Float]]
            }

            struct SampleExpected: Decodable {
                let measuredCount: Int
                let estimatedCount: Int
                let unknownCount: Int
                let classificationByPatch: [String: String]
            }

            let name: String
            let config: Config
            let vertices: [Vertex]
            let tetrahedra: [Tetrahedron]
            let triangles: [Triangle]
            let expected: SampleExpected
        }

        let kuhn5: Kuhn5Tables
        let replay_samples: [ReplaySample]
        let expected: Expected
    }

    func testKuhn5TablesMatchDeterministicReference() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.kuhn5.parity0, TriTetConsistencyEngine.kuhn5(parity: 0).map { [$0.0, $0.1, $0.2, $0.3] })
        XCTAssertEqual(fixture.kuhn5.parity1, TriTetConsistencyEngine.kuhn5(parity: 1).map { [$0.0, $0.1, $0.2, $0.3] })
    }

    func testReplaySamplesMatchExpectedMeasuredEstimatedUnknown() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.replay_samples.isEmpty)

        for sample in fixture.replay_samples {
            let config = TriTetConfig(
                measuredMinViewCount: sample.config.measuredMinViewCount,
                estimatedMinViewCount: sample.config.estimatedMinViewCount,
                maxTriangleToTetDistance: sample.config.maxTriangleToTetDistance
            )

            let report = TriTetConsistencyEngine.evaluate(
                triangles: sample.triangles.map(makeTriangle(_:)),
                vertices: sample.vertices.map(makeVertex(_:)),
                tetrahedra: sample.tetrahedra.compactMap(makeTet(_:)),
                config: config
            )

            XCTAssertEqual(report.measuredCount, sample.expected.measuredCount, "Measured mismatch for \(sample.name)")
            XCTAssertEqual(report.estimatedCount, sample.expected.estimatedCount, "Estimated mismatch for \(sample.name)")
            XCTAssertEqual(report.unknownCount, sample.expected.unknownCount, "Unknown mismatch for \(sample.name)")

            for binding in report.bindings {
                let expectedClass = sample.expected.classificationByPatch[binding.trianglePatchId]
                XCTAssertEqual(
                    binding.classification.rawValue,
                    expectedClass,
                    "Classification mismatch for \(sample.name):\(binding.trianglePatchId)"
                )
            }
        }
    }

    func testReplayUnknownRatioWithinFixtureThreshold() throws {
        let fixture = try loadFixture()
        let maxAllowed = fixture.expected.max_unknown_ratio
        XCTAssertFalse(fixture.replay_samples.isEmpty)

        for sample in fixture.replay_samples {
            let report = TriTetConsistencyEngine.evaluate(
                triangles: sample.triangles.map(makeTriangle(_:)),
                vertices: sample.vertices.map(makeVertex(_:)),
                tetrahedra: sample.tetrahedra.compactMap(makeTet(_:)),
                config: TriTetConfig(
                    measuredMinViewCount: sample.config.measuredMinViewCount,
                    estimatedMinViewCount: sample.config.estimatedMinViewCount,
                    maxTriangleToTetDistance: sample.config.maxTriangleToTetDistance
                )
            )
            let total = report.measuredCount + report.estimatedCount + report.unknownCount
            let ratio = total > 0 ? Float(report.unknownCount) / Float(total) : 0
            XCTAssertLessThanOrEqual(ratio, maxAllowed, "Unknown ratio exceeded for \(sample.name)")
        }
    }

    private func makeVertex(_ row: Fixture.ReplaySample.Vertex) -> TriTetVertex {
        TriTetVertex(
            index: row.index,
            position: SIMD3<Float>(row.position[0], row.position[1], row.position[2]),
            viewCount: row.viewCount
        )
    }

    private func makeTet(_ row: Fixture.ReplaySample.Tetrahedron) -> TriTetTetrahedron? {
        guard row.vertices.count == 4 else { return nil }
        return TriTetTetrahedron(
            id: row.id,
            vertices: (row.vertices[0], row.vertices[1], row.vertices[2], row.vertices[3])
        )
    }

    private func makeTriangle(_ row: Fixture.ReplaySample.Triangle) -> ScanTriangle {
        let a = SIMD3<Float>(row.vertices[0][0], row.vertices[0][1], row.vertices[0][2])
        let b = SIMD3<Float>(row.vertices[1][0], row.vertices[1][1], row.vertices[1][2])
        let c = SIMD3<Float>(row.vertices[2][0], row.vertices[2][1], row.vertices[2][2])
        return ScanTriangle(
            patchId: row.patchId,
            vertices: (a, b, c),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.0
        )
    }

    private func loadFixture() throws -> Fixture {
        let repoRoot = try resolveRepoRoot()
        let path = repoRoot.appendingPathComponent("Tests/Fixtures/tri_tet_kuhn5_replay_v1.json")
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func resolveRepoRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        throw NSError(
            domain: "TriTetFixtureReplayTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to locate repository root"]
        )
    }
}
