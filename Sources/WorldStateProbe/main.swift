// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import Metal
import simd

import Aether3DCore
import CAetherNativeBridge

private let worldStateSchemaVersion = "aether_world_state_v1"
private let worldStateGridCell: Float = 0.05
private let worldStateConfirmedSamples = 2
private let worldStateLockedSamples = 5
private let worldStateSurfaceCell: Float = 0.05
private let worldStateSurfaceMaxPoints = 200_000
private let worldStateSurfaceSupportThresholdMM: Float = 20.0
private let worldStateSurfaceNormalRadius: Float = 0.08
private let worldStateSurfaceSearchRings = 2

private let boxCenter = SIMD3<Float>(0.0, 0.15, 1.0)
private let boxHalfExtents = SIMD3<Float>(0.15, 0.15, 0.15)

private struct RawWorldStateTile: Sendable {
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
    let size: Float
    let quality: Float
}

private struct SurfaceIndex: Sendable {
    let points: [SIMD3<Float>]
    let buckets: [Int64: [Int]]
}

private struct RawWorldStateFrame: Sendable {
    let frameIndex: Int
    let timestampS: Double
    let coverage: Double
    let tiles: [RawWorldStateTile]
}

private struct WorldStateNeighbor: Codable, Sendable {
    let tile_id: String
    let gap_mm: Double
}

private struct WorldStateTile: Codable, Sendable {
    let tile_id: String
    let cell_id: String
    let state: String
    let visible: Bool
    let center: [Double]
    let normal: [Double]
    let corners: [[Double]]
    let u: Int?
    let v: Int?
    let neighbors: [WorldStateNeighbor]
    let surface_center_distance_mm: Double?
    let surface_normal_dot: Double?
    let surface_corner_support: [Bool]?
}

private struct WorldStateFrame: Codable, Sendable {
    let frame_index: Int
    let timestamp_s: Double
    let coverage: Double
    let tiles: [WorldStateTile]
}

private struct WorldStateMeta: Codable, Sendable {
    let scene_id: String
    let cell_level: Int
    let notes: String
}

private struct WorldStateExport: Codable, Sendable {
    let version: String
    let meta: WorldStateMeta
    let frames: [WorldStateFrame]
}

private struct DerivedTileDraft {
    var tile: WorldStateTile
    let center: SIMD3<Float>
    let normal: SIMD3<Float>
    let size: Float
}

private final class WorldStateRecorder {
    private var frames: [RawWorldStateFrame] = []
    private var firstTimestamp: TimeInterval?

    func recordFrame(
        frameIndex: Int,
        timestamp: TimeInterval,
        coverage: Float,
        renderData: PipelineCoordinatorBridge.RenderData?
    ) {
        if firstTimestamp == nil {
            firstTimestamp = timestamp
        }
        let baseTimestamp = firstTimestamp ?? timestamp
        let timestampS = max(0.0, timestamp - baseTimestamp)
        frames.append(
            RawWorldStateFrame(
                frameIndex: frameIndex,
                timestampS: timestampS,
                coverage: Double(max(0.0, min(1.0, coverage))),
                tiles: extractRawWorldStateTiles(from: renderData)
            )
        )
    }

    func snapshot() -> [RawWorldStateFrame] {
        frames
    }
}

private func safeNormalize(_ vector: SIMD3<Float>) -> SIMD3<Float> {
    let length = simd_length(vector)
    if length > 1e-6 {
        return vector / length
    }
    return SIMD3<Float>(0.0, 1.0, 0.0)
}

private func extractRawWorldStateTiles(
    from renderData: PipelineCoordinatorBridge.RenderData?
) -> [RawWorldStateTile] {
    guard let renderData,
          renderData.overlayCount > 0,
          let overlayVertices = renderData.overlayVertices else {
        return []
    }
    let vertexPointer = overlayVertices.bindMemory(
        to: aether_overlay_vertex_t.self,
        capacity: renderData.overlayCount
    )
    let vertices = UnsafeBufferPointer(start: vertexPointer, count: renderData.overlayCount)
    return vertices.map { vertex in
        RawWorldStateTile(
            center: SIMD3<Float>(vertex.position.0, vertex.position.1, vertex.position.2),
            normal: SIMD3<Float>(vertex.normal.0, vertex.normal.1, vertex.normal.2),
            size: vertex.size,
            quality: vertex.quality
        )
    }
}

private func sampleSurfacePoints(
    from renderData: PipelineCoordinatorBridge.RenderData?
) -> [SIMD3<Float>] {
    guard let renderData,
          renderData.pointCloudCount > 0,
          let pointCloudVertices = renderData.pointCloudVertices else {
        return []
    }
    let floatsPerPoint = 8
    let totalFloats = renderData.pointCloudCount * floatsPerPoint
    let pointPointer = pointCloudVertices.bindMemory(
        to: Float.self,
        capacity: totalFloats
    )
    let values = UnsafeBufferPointer(start: pointPointer, count: totalFloats)
    let step = max(1, renderData.pointCloudCount / worldStateSurfaceMaxPoints)
    var points: [SIMD3<Float>] = []
    points.reserveCapacity(max(1, renderData.pointCloudCount / step))
    var index = 0
    while index < renderData.pointCloudCount {
        let base = index * floatsPerPoint
        let alpha = values[base + 7]
        let point = SIMD3<Float>(values[base + 0], values[base + 1], values[base + 2])
        if alpha > 0.0001,
           point.x.isFinite,
           point.y.isFinite,
           point.z.isFinite {
            points.append(point)
        }
        index += step
    }
    return points
}

private func makeWorldStateExport(
    sceneID: String,
    frames: [RawWorldStateFrame],
    surfacePoints: [SIMD3<Float>]
) -> WorldStateExport {
    let surfaceIndex = buildSurfaceIndex(from: surfacePoints)
    var seenCounts: [String: Int] = [:]
    let exportedFrames = frames.map { frame in
        WorldStateFrame(
            frame_index: frame.frameIndex,
            timestamp_s: frame.timestampS,
            coverage: frame.coverage,
            tiles: deriveWorldStateTiles(
                from: frame.tiles,
                seenCounts: &seenCounts,
                surfaceIndex: surfaceIndex
            )
        )
    }
    return WorldStateExport(
        version: worldStateSchemaVersion,
        meta: WorldStateMeta(
            scene_id: sceneID,
            cell_level: 0,
            notes: "Derived from Aether overlay vertices. Tile state is a monotonic visibility-persistence proxy. Surface fields are approximated from the exported point cloud at capture stop."
        ),
        frames: exportedFrames
    )
}

private func deriveWorldStateTiles(
    from rawTiles: [RawWorldStateTile],
    seenCounts: inout [String: Int],
    surfaceIndex: SurfaceIndex?
) -> [WorldStateTile] {
    guard !rawTiles.isEmpty else { return [] }

    var drafts: [DerivedTileDraft] = []
    drafts.reserveCapacity(rawTiles.count)

    for rawTile in rawTiles {
        let normalizedNormal = safeNormalize(rawTile.normal)
        let cell = overlayCellIndices(for: rawTile.center)
        let cellKey = packOverlayCellKey(gx: cell.gx, gy: cell.gy, gz: cell.gz)
        let cellID = "spatial:\(cellKey)|grid:\(cell.gx):\(cell.gy):\(cell.gz)"
        let tileID = "tile:\(cellKey)"
        let seenCount = (seenCounts[tileID] ?? 0) + 1
        seenCounts[tileID] = seenCount

        let corners = tileCorners(
            center: rawTile.center,
            normal: normalizedNormal,
            halfSize: rawTile.size
        )
        let uv = planeGridCoordinates(for: rawTile.center, normal: normalizedNormal)
        let surfaceMetrics = deriveSurfaceMetrics(
            center: rawTile.center,
            corners: corners,
            normal: normalizedNormal,
            surfaceIndex: surfaceIndex
        )
        drafts.append(
            DerivedTileDraft(
                tile: WorldStateTile(
                    tile_id: tileID,
                    cell_id: cellID,
                    state: worldState(forVisibilitySamples: seenCount),
                    visible: true,
                    center: vectorArray(rawTile.center),
                    normal: vectorArray(normalizedNormal),
                    corners: corners.map(vectorArray),
                    u: uv.u,
                    v: uv.v,
                    neighbors: [],
                    surface_center_distance_mm: surfaceMetrics.centerDistanceMM,
                    surface_normal_dot: surfaceMetrics.normalDot,
                    surface_corner_support: surfaceMetrics.cornerSupport
                ),
                center: rawTile.center,
                normal: normalizedNormal,
                size: rawTile.size
            )
        )
    }

    var neighborsByIndex = Array(repeating: [WorldStateNeighbor](), count: drafts.count)
    for i in 0..<drafts.count {
        for j in (i + 1)..<drafts.count {
            guard let gapMm = sideGapIfAdjacent(lhs: drafts[i], rhs: drafts[j]) else {
                continue
            }
            neighborsByIndex[i].append(
                WorldStateNeighbor(tile_id: drafts[j].tile.tile_id, gap_mm: gapMm)
            )
            neighborsByIndex[j].append(
                WorldStateNeighbor(tile_id: drafts[i].tile.tile_id, gap_mm: gapMm)
            )
        }
    }

    for index in drafts.indices {
        drafts[index].tile = WorldStateTile(
            tile_id: drafts[index].tile.tile_id,
            cell_id: drafts[index].tile.cell_id,
            state: drafts[index].tile.state,
            visible: drafts[index].tile.visible,
            center: drafts[index].tile.center,
            normal: drafts[index].tile.normal,
            corners: drafts[index].tile.corners,
            u: drafts[index].tile.u,
            v: drafts[index].tile.v,
            neighbors: neighborsByIndex[index].sorted { lhs, rhs in
                if lhs.gap_mm == rhs.gap_mm {
                    return lhs.tile_id < rhs.tile_id
                }
                return lhs.gap_mm < rhs.gap_mm
            },
            surface_center_distance_mm: drafts[index].tile.surface_center_distance_mm,
            surface_normal_dot: drafts[index].tile.surface_normal_dot,
            surface_corner_support: drafts[index].tile.surface_corner_support
        )
    }

    return drafts.map(\.tile)
}

private func worldState(forVisibilitySamples seenCount: Int) -> String {
    if seenCount >= worldStateLockedSamples {
        return "locked"
    }
    if seenCount >= worldStateConfirmedSamples {
        return "confirmed"
    }
    return "provisional"
}

private func overlayCellIndices(for position: SIMD3<Float>) -> (gx: Int, gy: Int, gz: Int) {
    (
        gx: Int(floor(position.x / worldStateGridCell)),
        gy: Int(floor(position.y / worldStateGridCell)),
        gz: Int(floor(position.z / worldStateGridCell))
    )
}

private func surfaceCellIndices(for position: SIMD3<Float>) -> (gx: Int, gy: Int, gz: Int) {
    (
        gx: Int(floor(position.x / worldStateSurfaceCell)),
        gy: Int(floor(position.y / worldStateSurfaceCell)),
        gz: Int(floor(position.z / worldStateSurfaceCell))
    )
}

private func packOverlayCellKey(gx: Int, gy: Int, gz: Int) -> Int64 {
    let ox = Int64(gx + 2048)
    let oy = Int64(gy + 2048)
    let oz = Int64(gz + 2048)
    return (ox << 24) ^ (oy << 12) ^ oz
}

private func buildSurfaceIndex(from points: [SIMD3<Float>]) -> SurfaceIndex? {
    guard !points.isEmpty else { return nil }
    var buckets: [Int64: [Int]] = [:]
    buckets.reserveCapacity(max(64, points.count / 6))
    for (index, point) in points.enumerated() {
        let cell = surfaceCellIndices(for: point)
        let key = packOverlayCellKey(gx: cell.gx, gy: cell.gy, gz: cell.gz)
        buckets[key, default: []].append(index)
    }
    return SurfaceIndex(points: points, buckets: buckets)
}

private func candidateSurfaceIndices(
    around query: SIMD3<Float>,
    surfaceIndex: SurfaceIndex,
    maxRings: Int = worldStateSurfaceSearchRings
) -> [Int] {
    let cell = surfaceCellIndices(for: query)
    for ring in 0...maxRings {
        var indices: [Int] = []
        for gx in (cell.gx - ring)...(cell.gx + ring) {
            for gy in (cell.gy - ring)...(cell.gy + ring) {
                for gz in (cell.gz - ring)...(cell.gz + ring) {
                    let key = packOverlayCellKey(gx: gx, gy: gy, gz: gz)
                    if let bucket = surfaceIndex.buckets[key] {
                        indices.append(contentsOf: bucket)
                    }
                }
            }
        }
        if !indices.isEmpty {
            return indices
        }
    }
    return []
}

private func nearestSurfaceDistance(
    to query: SIMD3<Float>,
    surfaceIndex: SurfaceIndex
) -> Float? {
    let indices = candidateSurfaceIndices(around: query, surfaceIndex: surfaceIndex)
    guard !indices.isEmpty else { return nil }
    var best = Float.greatestFiniteMagnitude
    for idx in indices {
        let distance = simd_length(surfaceIndex.points[idx] - query)
        if distance < best {
            best = distance
        }
    }
    return best.isFinite ? best : nil
}

private func localSurfaceNormalDot(
    center: SIMD3<Float>,
    tileNormal: SIMD3<Float>,
    surfaceIndex: SurfaceIndex
) -> Double? {
    let indices = candidateSurfaceIndices(around: center, surfaceIndex: surfaceIndex, maxRings: 3)
    guard !indices.isEmpty else { return nil }
    let radius = worldStateSurfaceNormalRadius
    var neighbors: [SIMD3<Float>] = []
    neighbors.reserveCapacity(32)
    for idx in indices {
        let point = surfaceIndex.points[idx]
        if simd_length(point - center) <= radius {
            neighbors.append(point)
        }
    }
    if neighbors.count < 3 {
        let sorted = indices
            .map { surfaceIndex.points[$0] }
            .sorted { simd_length($0 - center) < simd_length($1 - center) }
        neighbors = Array(sorted.prefix(8))
    }
    guard neighbors.count >= 3 else { return nil }
    let estimated = estimatePlaneNormal(from: neighbors, preferredNormal: tileNormal)
    let dot = simd_dot(safeNormalize(estimated), safeNormalize(tileNormal))
    return Double(max(-1.0, min(1.0, dot)))
}

private func estimatePlaneNormal(
    from points: [SIMD3<Float>],
    preferredNormal: SIMD3<Float>
) -> SIMD3<Float> {
    let count = Float(points.count)
    let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / count
    var cxx: Float = 0
    var cxy: Float = 0
    var cxz: Float = 0
    var cyy: Float = 0
    var cyz: Float = 0
    var czz: Float = 0
    for point in points {
        let d = point - centroid
        cxx += d.x * d.x
        cxy += d.x * d.y
        cxz += d.x * d.z
        cyy += d.y * d.y
        cyz += d.y * d.z
        czz += d.z * d.z
    }
    let scale = 1.0 / max(1.0, count - 1.0)
    var matrix = [
        [cxx * scale, cxy * scale, cxz * scale],
        [cxy * scale, cyy * scale, cyz * scale],
        [cxz * scale, cyz * scale, czz * scale]
    ]
    var eigenvectors = [
        [Float(1), Float(0), Float(0)],
        [Float(0), Float(1), Float(0)],
        [Float(0), Float(0), Float(1)]
    ]
    for _ in 0..<12 {
        var p = 0
        var q = 1
        var maxValue = abs(matrix[0][1])
        for i in 0..<3 {
            for j in (i + 1)..<3 {
                let value = abs(matrix[i][j])
                if value > maxValue {
                    maxValue = value
                    p = i
                    q = j
                }
            }
        }
        if maxValue < 1e-6 {
            break
        }
        let phi = 0.5 * atan2(2.0 * matrix[p][q], matrix[q][q] - matrix[p][p])
        let c = cos(phi)
        let s = sin(phi)
        for i in 0..<3 {
            let mip = matrix[i][p]
            let miq = matrix[i][q]
            matrix[i][p] = c * mip - s * miq
            matrix[i][q] = s * mip + c * miq
        }
        for j in 0..<3 {
            let mpj = matrix[p][j]
            let mqj = matrix[q][j]
            matrix[p][j] = c * mpj - s * mqj
            matrix[q][j] = s * mpj + c * mqj
        }
        matrix[p][q] = 0
        matrix[q][p] = 0
        for i in 0..<3 {
            let vip = eigenvectors[i][p]
            let viq = eigenvectors[i][q]
            eigenvectors[i][p] = c * vip - s * viq
            eigenvectors[i][q] = s * vip + c * viq
        }
    }
    let eigenvalues = [matrix[0][0], matrix[1][1], matrix[2][2]]
    let minIndex = eigenvalues.enumerated().min { $0.element < $1.element }?.offset ?? 0
    var normal = SIMD3<Float>(
        eigenvectors[0][minIndex],
        eigenvectors[1][minIndex],
        eigenvectors[2][minIndex]
    )
    normal = safeNormalize(normal)
    if simd_dot(normal, preferredNormal) < 0 {
        normal = -normal
    }
    return normal
}

private func deriveSurfaceMetrics(
    center: SIMD3<Float>,
    corners: [SIMD3<Float>],
    normal: SIMD3<Float>,
    surfaceIndex: SurfaceIndex?
) -> (centerDistanceMM: Double?, normalDot: Double?, cornerSupport: [Bool]?) {
    guard let surfaceIndex else {
        return (nil, nil, nil)
    }
    let centerDistance = nearestSurfaceDistance(to: center, surfaceIndex: surfaceIndex)
    let centerDistanceMM = centerDistance.map { Double($0 * 1000.0) }
    let supportThreshold = worldStateSurfaceSupportThresholdMM / 1000.0
    let cornerSupport = corners.map { corner in
        guard let distance = nearestSurfaceDistance(to: corner, surfaceIndex: surfaceIndex) else {
            return false
        }
        return distance <= supportThreshold
    }
    let normalDot = localSurfaceNormalDot(center: center, tileNormal: normal, surfaceIndex: surfaceIndex)
    return (centerDistanceMM, normalDot, cornerSupport)
}

private func buildTileBasis(normal: SIMD3<Float>) -> (tangent: SIMD3<Float>, bitangent: SIMD3<Float>) {
    let up = abs(normal.y) < 0.9
        ? SIMD3<Float>(0.0, 1.0, 0.0)
        : SIMD3<Float>(1.0, 0.0, 0.0)
    let tangent = safeNormalize(simd_cross(up, normal))
    let bitangent = safeNormalize(simd_cross(normal, tangent))
    return (tangent, bitangent)
}

private func tileCorners(
    center: SIMD3<Float>,
    normal: SIMD3<Float>,
    halfSize: Float
) -> [SIMD3<Float>] {
    let basis = buildTileBasis(normal: normal)
    let tangent = basis.tangent
    let bitangent = basis.bitangent
    let signs: [(Float, Float)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    return signs.map { sign in
        center + sign.0 * halfSize * tangent + sign.1 * halfSize * bitangent
    }
}

private func planeGridCoordinates(
    for center: SIMD3<Float>,
    normal: SIMD3<Float>
) -> (u: Int, v: Int) {
    let absNormal = SIMD3<Float>(abs(normal.x), abs(normal.y), abs(normal.z))
    if absNormal.y >= absNormal.x && absNormal.y >= absNormal.z {
        return (Int(floor(center.x / worldStateGridCell)), Int(floor(center.z / worldStateGridCell)))
    }
    if absNormal.x >= absNormal.y && absNormal.x >= absNormal.z {
        return (Int(floor(center.z / worldStateGridCell)), Int(floor(center.y / worldStateGridCell)))
    }
    return (Int(floor(center.x / worldStateGridCell)), Int(floor(center.y / worldStateGridCell)))
}

private func sideGapIfAdjacent(lhs: DerivedTileDraft, rhs: DerivedTileDraft) -> Double? {
    let normalDot = simd_dot(lhs.normal, rhs.normal)
    if normalDot < 0.85 {
        return nil
    }
    let centerDistance = simd_length(lhs.center - rhs.center)
    if centerDistance > 0.11 {
        return nil
    }

    let avgNormal = safeNormalize(lhs.normal + rhs.normal)
    let basis = buildTileBasis(normal: avgNormal)
    let delta = rhs.center - lhs.center
    let du = abs(simd_dot(delta, basis.tangent))
    let dv = abs(simd_dot(delta, basis.bitangent))
    let halfSum = lhs.size + rhs.size

    let nu = du / worldStateGridCell
    let nv = dv / worldStateGridCell
    let err10 = hypotf(nu - 1.0, nv)
    let err01 = hypotf(nu, nv - 1.0)
    if min(err10, err01) >= 0.30 {
        return nil
    }
    let axisSeparation = err10 <= err01 ? du : dv
    let gapMm = Double(max(0.0, axisSeparation - halfSum) * 1000.0)
    return gapMm
}

private func vectorArray(_ vector: SIMD3<Float>) -> [Double] {
    [Double(vector.x), Double(vector.y), Double(vector.z)]
}

private func rayCast(
    origin: SIMD3<Float>,
    direction: SIMD3<Float>,
    maxDepth: Float
) -> (distance: Float, normal: SIMD3<Float>) {
    var bestT = maxDepth + 1.0
    var bestNormal = SIMD3<Float>(repeating: 0)

    if abs(direction.y) > 1e-8 {
        let t = -origin.y / direction.y
        if t > 0.05 && t < bestT {
            let hit = origin + direction * t
            if hit.x > -3.0 && hit.x < 3.0 && hit.z > -1.0 && hit.z < 4.0 {
                bestT = t
                bestNormal = SIMD3<Float>(0, 1, 0)
            }
        }
    }

    let boxMin = boxCenter - boxHalfExtents
    let boxMax = boxCenter + boxHalfExtents
    let faces: [(SIMD3<Float>, Float)] = [
        (SIMD3<Float>(1, 0, 0), boxMax.x),
        (SIMD3<Float>(-1, 0, 0), -boxMin.x),
        (SIMD3<Float>(0, 1, 0), boxMax.y),
        (SIMD3<Float>(0, -1, 0), -boxMin.y),
        (SIMD3<Float>(0, 0, 1), boxMax.z),
        (SIMD3<Float>(0, 0, -1), -boxMin.z)
    ]

    for (normal, offset) in faces {
        let denom = simd_dot(normal, direction)
        if abs(denom) < 1e-8 {
            continue
        }
        let t = (offset - simd_dot(normal, origin)) / denom
        if t > 0.05 && t < bestT {
            let hit = origin + direction * t
            if hit.x >= boxMin.x - 0.001 && hit.x <= boxMax.x + 0.001 &&
               hit.y >= boxMin.y - 0.001 && hit.y <= boxMax.y + 0.001 &&
               hit.z >= boxMin.z - 0.001 && hit.z <= boxMax.z + 0.001 {
                bestT = t
                bestNormal = normal
            }
        }
    }

    return (bestT, bestNormal)
}

private func normalToBGRA(_ normal: SIMD3<Float>) -> (UInt8, UInt8, UInt8, UInt8) {
    if normal.y > 0.5 {
        return (128, 128, 128, 255)
    }
    if normal.x > 0.5 {
        return (40, 40, 200, 255)
    }
    if normal.x < -0.5 {
        return (200, 200, 40, 255)
    }
    if normal.y < -0.5 {
        return (200, 40, 200, 255)
    }
    if normal.z > 0.5 {
        return (200, 40, 40, 255)
    }
    if normal.z < -0.5 {
        return (40, 200, 200, 255)
    }
    return (100, 100, 100, 255)
}

private func generateFrame(
    angleRad: Float,
    radius: Float,
    camHeight: Float,
    width: Int,
    height: Int,
    fx: Float,
    fy: Float,
    cx: Float,
    cy: Float
) -> (bgra: [UInt8], depth: [Float], transform: simd_float4x4, intrinsics: simd_float3x3) {
    let cameraPosition = SIMD3<Float>(
        boxCenter.x + radius * cos(angleRad),
        camHeight,
        boxCenter.z + radius * sin(angleRad)
    )
    let forward = safeNormalize(boxCenter - cameraPosition)
    var right = SIMD3<Float>(forward.z, 0.0, -forward.x)
    right = safeNormalize(right)
    let up = SIMD3<Float>(
        right.y * forward.z - right.z * forward.y,
        right.z * forward.x - right.x * forward.z,
        right.x * forward.y - right.y * forward.x
    )

    let transform = simd_float4x4(
        columns: (
            SIMD4<Float>(right.x, right.y, right.z, 0.0),
            SIMD4<Float>(up.x, up.y, up.z, 0.0),
            SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0.0),
            SIMD4<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z, 1.0)
        )
    )
    let intrinsics = simd_float3x3(
        columns: (
            SIMD3<Float>(fx, 0.0, 0.0),
            SIMD3<Float>(0.0, fy, 0.0),
            SIMD3<Float>(cx, cy, 1.0)
        )
    )

    var bgra = Array(repeating: UInt8(0), count: width * height * 4)
    var depth = Array(repeating: Float(0), count: width * height)

    for v in 0..<height {
        for u in 0..<width {
            let px = (Float(u) - cx) / fx
            let py = (Float(v) - cy) / fy
            let rayCamera = SIMD3<Float>(px, py, 1.0)
            var rayWorld = right * rayCamera.x + up * rayCamera.y + (-forward) * rayCamera.z
            rayWorld = safeNormalize(rayWorld)

            let hit = rayCast(origin: cameraPosition, direction: rayWorld, maxDepth: 5.0)
            let idx = v * width + u
            if hit.distance < 5.0 {
                depth[idx] = hit.distance
                let color = normalToBGRA(hit.normal)
                bgra[idx * 4 + 0] = color.0
                bgra[idx * 4 + 1] = color.1
                bgra[idx * 4 + 2] = color.2
                bgra[idx * 4 + 3] = color.3
            } else {
                bgra[idx * 4 + 0] = 20
                bgra[idx * 4 + 1] = 20
                bgra[idx * 4 + 2] = 20
                bgra[idx * 4 + 3] = 255
            }
        }
    }

    return (bgra, depth, transform, intrinsics)
}

private func createBridge() -> (PipelineCoordinatorBridge, OpaquePointer, OpaquePointer) {
    guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
        fatalError("Metal device unavailable")
    }

    let mtlDevicePtr = Unmanaged.passUnretained(mtlDevice).toOpaque()
    guard let gpuDevice = aether_gpu_device_create_metal(mtlDevicePtr) else {
        fatalError("aether_gpu_device_create_metal failed")
    }

    var splatConfig = aether_splat_config_t()
    _ = aether_splat_default_config(&splatConfig)
    splatConfig.max_splats = 100_000

    var splatEnginePtr: OpaquePointer?
    let rc = aether_splat_engine_create(
        UnsafeMutableRawPointer(gpuDevice),
        &splatConfig,
        &splatEnginePtr
    )
    guard rc == 0, let engine = splatEnginePtr else {
        aether_gpu_device_destroy(gpuDevice)
        fatalError("aether_splat_engine_create failed rc=\(rc)")
    }

    var config = aether_coordinator_config_t()
    _ = aether_coordinator_default_config(&config)
    config.min_frames_to_start_training = 4
    config.training_batch_size = 4
    config.min_displacement_m = 0.003
    config.min_blur_score = 0.0
    config.min_quality_score = 0.0
    config.max_gaussians = 100_000
    config.max_iterations = 500
    config.render_width = 320
    config.render_height = 240
    config.depth_model_path = nil
    config.depth_model_path_large = nil
    config.blend_start_splat_count = 10
    config.blend_end_splat_count = 100

    guard let bridge = PipelineCoordinatorBridge(
        gpuDevicePtr: UnsafeMutableRawPointer(gpuDevice),
        splatEnginePtr: UnsafeMutableRawPointer(engine),
        config: &config
    ) else {
        aether_splat_engine_destroy(engine)
        aether_gpu_device_destroy(gpuDevice)
        fatalError("PipelineCoordinatorBridge creation failed")
    }

    return (bridge, gpuDevice, engine)
}

private func runProbe() throws {
    let (bridge, gpuDevice, splatEngine) = createBridge()
    defer {
        _ = bridge
        aether_splat_engine_destroy(splatEngine)
        aether_gpu_device_destroy(gpuDevice)
    }

    let recorder = WorldStateRecorder()
    let width = 320
    let height = 240
    let fx: Float = 280.0
    let fy: Float = 280.0
    let cx: Float = 160.0
    let cy: Float = 120.0
    let radius: Float = 0.8
    let camHeight: Float = 0.20
    let linearSpeed: Float = 0.05
    let angularSpeed = linearSpeed / radius
    let effectiveFPS: Double = 13.0
    let totalFrames = 120

    var accepted = 0
    var dropped = 0

    print("[WorldStateProbe] Starting synthetic scan: \(totalFrames) frames @ \(effectiveFPS) fps")

    for frameIndex in 0..<totalFrames {
        let timestamp = Double(frameIndex) / effectiveFPS
        let angle = Float(timestamp) * angularSpeed
        let frame = generateFrame(
            angleRad: angle,
            radius: radius,
            camHeight: camHeight,
            width: width,
            height: height,
            fx: fx,
            fy: fy,
            cx: cx,
            cy: cy
        )

        let frameAccepted = frame.bgra.withUnsafeBufferPointer { rgbaBuffer in
            frame.depth.withUnsafeBufferPointer { depthBuffer in
                bridge.onFrame(
                    rgba: rgbaBuffer.baseAddress!,
                    width: UInt32(width),
                    height: UInt32(height),
                    transform: frame.transform,
                    intrinsics: frame.intrinsics,
                    featurePoints: nil,
                    featureCount: 0,
                    neDepth: nil,
                    neDepthW: 0,
                    neDepthH: 0,
                    lidarDepth: depthBuffer.baseAddress,
                    lidarW: UInt32(width),
                    lidarH: UInt32(height),
                    thermalState: 0
                )
            }
        }

        if frameAccepted {
            accepted += 1
        } else {
            dropped += 1
        }

        Thread.sleep(forTimeInterval: 1.0 / effectiveFPS)

        let snapshot = bridge.getSnapshot()
        let renderData = bridge.getRenderData()
        recorder.recordFrame(
            frameIndex: frameIndex,
            timestamp: timestamp,
            coverage: snapshot?.coverage ?? 0.0,
            renderData: renderData
        )

        if (frameIndex + 1) % 20 == 0 || frameIndex == totalFrames - 1 {
            let overlayCount = renderData?.overlayCount ?? 0
            let pointCount = renderData?.pointCloudCount ?? 0
            let coverage = snapshot.map { String(format: "%.3f", Double($0.coverage)) } ?? "nil"
            print("[WorldStateProbe] frame=\(frameIndex + 1)/\(totalFrames) accepted=\(accepted) dropped=\(dropped) coverage=\(coverage) overlay=\(overlayCount) points=\(pointCount)")
        }
    }

    _ = bridge.finishScanning()
    let stepsReached = bridge.waitForTraining(minSteps: 300, timeoutSeconds: 4.0)
    let finalRenderData = bridge.getRenderData()
    let surfacePoints = {
        let copied = bridge.copySurfacePoints(maxPoints: Int(worldStateSurfaceMaxPoints))
        if !copied.isEmpty {
            return copied
        }
        return sampleSurfacePoints(from: finalRenderData)
    }()

    let recordID = UUID()
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let exportDir = documents
        .appendingPathComponent("Aether3D")
        .appendingPathComponent("exports")
    try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

    let plyURL = exportDir.appendingPathComponent("\(recordID.uuidString).ply")
    var artifactExported = false
    if bridge.exportPLY(path: plyURL.path) {
        artifactExported = true
    } else if bridge.exportPointCloudPLY(path: plyURL.path) {
        artifactExported = true
    }

    let worldStateURL = exportDir.appendingPathComponent("\(recordID.uuidString).world_state.json")
    let exportPayload = makeWorldStateExport(
        sceneID: recordID.uuidString,
        frames: recorder.snapshot(),
        surfacePoints: surfacePoints
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(exportPayload)
    try data.write(to: worldStateURL, options: .atomic)

    let snapshot = bridge.getSnapshot()
    let finalOverlay = finalRenderData?.overlayCount ?? 0
    let finalPointCount = finalRenderData?.pointCloudCount ?? 0
    let finalCoverage = snapshot.map { String(format: "%.4f", Double($0.coverage)) } ?? "nil"

    print("[WorldStateProbe] stepsReached=\(stepsReached) overlay=\(finalOverlay) points=\(finalPointCount) coverage=\(finalCoverage)")
    print("[WorldStateProbe] artifactExported=\(artifactExported) ply=\(plyURL.path)")
    print("WORLD_STATE_JSON=\(worldStateURL.path)")
}

do {
    try runProbe()
} catch {
    fputs("[WorldStateProbe] ERROR: \(error)\n", stderr)
    exit(1)
}
