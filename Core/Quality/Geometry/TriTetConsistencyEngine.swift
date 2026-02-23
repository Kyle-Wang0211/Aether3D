// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(simd)
import simd
#endif

public struct TriTetVertex: Sendable, Codable, Equatable {
    public let index: Int
    public let position: SIMD3<Float>
    public let viewCount: Int

    public init(index: Int, position: SIMD3<Float>, viewCount: Int) {
        self.index = index
        self.position = position
        self.viewCount = viewCount
    }
}

public struct TriTetTetrahedron: Sendable, Codable, Equatable {
    public let id: Int
    public let v0: Int
    public let v1: Int
    public let v2: Int
    public let v3: Int

    public var vertices: (Int, Int, Int, Int) {
        (v0, v1, v2, v3)
    }

    public init(id: Int, vertices: (Int, Int, Int, Int)) {
        self.id = id
        self.v0 = vertices.0
        self.v1 = vertices.1
        self.v2 = vertices.2
        self.v3 = vertices.3
    }
}

public struct TriTetConfig: Sendable, Codable, Equatable {
    public let measuredMinViewCount: Int
    public let estimatedMinViewCount: Int
    public let maxTriangleToTetDistance: Float

    public init(
        measuredMinViewCount: Int? = nil,
        estimatedMinViewCount: Int? = nil,
        maxTriangleToTetDistance: Float? = nil,
        profile: PureVisionRuntimeProfile = .balanced
    ) {
        let thresholds = PureVisionRuntimeProfileConfig.config(for: profile).triTet
        self.measuredMinViewCount = measuredMinViewCount ?? thresholds.measuredMinViewCount
        self.estimatedMinViewCount = estimatedMinViewCount ?? thresholds.estimatedMinViewCount
        self.maxTriangleToTetDistance = maxTriangleToTetDistance ?? thresholds.maxTriangleToTetDistance
    }
}

public struct TriTetConsistencyBinding: Sendable, Codable, Equatable {
    public let trianglePatchId: String
    public let tetrahedronId: Int
    public let classification: ReconstructionConfidenceClass
    public let triToTetDistance: Float
    public let minTetViewCount: Int
}

public struct TriTetConsistencyReport: Sendable, Codable, Equatable {
    public let combinedScore: Float
    public let measuredCount: Int
    public let estimatedCount: Int
    public let unknownCount: Int
    public let bindings: [TriTetConsistencyBinding]
}

/// Deterministic Kuhn 5-tet decomposition and TRI/TET consistency scoring.
public enum TriTetConsistencyEngine {
    /// Cube vertex order:
    /// 0(0,0,0),1(1,0,0),2(0,1,0),3(1,1,0),4(0,0,1),5(1,0,1),6(0,1,1),7(1,1,1)
    public static func kuhn5(parity: Int = 0) -> [(Int, Int, Int, Int)] {
        if parity & 1 == 0 {
            return [
                (0, 1, 3, 7),
                (0, 3, 2, 7),
                (0, 2, 6, 7),
                (0, 6, 4, 7),
                (0, 4, 5, 7)
            ]
        }
        return [
            (1, 0, 2, 6),
            (1, 2, 3, 6),
            (1, 3, 7, 6),
            (1, 7, 5, 6),
            (1, 5, 4, 6)
        ]
    }

    public static func evaluate(
        triangles: [ScanTriangle],
        vertices: [TriTetVertex],
        tetrahedra: [TriTetTetrahedron],
        config: TriTetConfig = .init()
    ) -> TriTetConsistencyReport {
        guard !triangles.isEmpty, !vertices.isEmpty, !tetrahedra.isEmpty else {
            return TriTetConsistencyReport(
                combinedScore: 0,
                measuredCount: 0,
                estimatedCount: 0,
                unknownCount: 0,
                bindings: []
            )
        }

        let vertexLookup = Dictionary(uniqueKeysWithValues: vertices.map { ($0.index, $0) })
        var bindings: [TriTetConsistencyBinding] = []
        var measured = 0
        var estimated = 0
        var unknown = 0
        var scoreSum: Float = 0

        for tri in triangles {
            let triCentroid = triangleCentroid(tri)
            guard let nearest = nearestTet(centroid: triCentroid, tetrahedra: tetrahedra, vertexLookup: vertexLookup) else {
                unknown += 1
                bindings.append(
                    TriTetConsistencyBinding(
                        trianglePatchId: tri.patchId,
                        tetrahedronId: -1,
                        classification: .unknown,
                        triToTetDistance: .infinity,
                        minTetViewCount: 0
                    )
                )
                continue
            }

            let classification: ReconstructionConfidenceClass
            if nearest.minViewCount >= config.measuredMinViewCount && nearest.distance <= config.maxTriangleToTetDistance {
                classification = .measured
                measured += 1
            } else if nearest.minViewCount >= config.estimatedMinViewCount {
                classification = .estimated
                estimated += 1
            } else {
                classification = .unknown
                unknown += 1
            }

            let localScore: Float
            switch classification {
            case .measured: localScore = 1.0
            case .estimated: localScore = 0.6
            case .unknown: localScore = 0.1
            }
            scoreSum += localScore

            bindings.append(
                TriTetConsistencyBinding(
                    trianglePatchId: tri.patchId,
                    tetrahedronId: nearest.tet.id,
                    classification: classification,
                    triToTetDistance: nearest.distance,
                    minTetViewCount: nearest.minViewCount
                )
            )
        }

        let combined = bindings.isEmpty ? 0 : scoreSum / Float(bindings.count)
        return TriTetConsistencyReport(
            combinedScore: combined,
            measuredCount: measured,
            estimatedCount: estimated,
            unknownCount: unknown,
            bindings: bindings
        )
    }

    private struct NearestTetResult {
        let tet: TriTetTetrahedron
        let distance: Float
        let minViewCount: Int
    }

    private static func nearestTet(
        centroid: SIMD3<Float>,
        tetrahedra: [TriTetTetrahedron],
        vertexLookup: [Int: TriTetVertex]
    ) -> NearestTetResult? {
        var best: NearestTetResult?
        for tet in tetrahedra {
            let ids = [tet.vertices.0, tet.vertices.1, tet.vertices.2, tet.vertices.3]
            let points = ids.compactMap { vertexLookup[$0]?.position }
            guard points.count == 4 else { continue }

            let tetCentroid = (points[0] + points[1] + points[2] + points[3]) * 0.25
            let distance = simdLength(centroid - tetCentroid)
            let minViews = ids.compactMap { vertexLookup[$0]?.viewCount }.min() ?? 0

            let candidate = NearestTetResult(tet: tet, distance: distance, minViewCount: minViews)
            if let current = best {
                if distance < current.distance || (abs(distance - current.distance) < 1e-7 && tet.id < current.tet.id) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }

    private static func triangleCentroid(_ tri: ScanTriangle) -> SIMD3<Float> {
        let (a, b, c) = tri.vertices
        return (a + b + c) / 3.0
    }
}

