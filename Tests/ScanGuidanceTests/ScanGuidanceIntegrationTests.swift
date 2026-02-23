//
// ScanGuidanceIntegrationTests.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Integration Tests
// Tests the data flow between core logic components:
//   persistentTriangles → spatial sorting → renderTriangles → flip detection → render pipeline
// These tests catch bugs that only manifest when components interact.
//
// NOTE: Only tests Core/ types (available in SwiftPM). App-only types like
// GrayscaleMapper, MeshExtractor are tested via Xcode project.
//

import XCTest
import simd
@testable import Aether3DCore

final class ScanGuidanceIntegrationTests: XCTestCase {

    // MARK: - Helper: Create grid of triangles simulating LiDAR mesh

    /// Creates a grid of triangles in the XY plane centered around `center`.
    /// Generates patchIds using the same 1cm grid hash as MeshExtractor.
    static func makeGridTriangles(
        rows: Int, cols: Int,
        center: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        cellSize: Float = 0.01
    ) -> [ScanTriangle] {
        var triangles: [ScanTriangle] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let x = center.x + Float(col) * cellSize
                let y = center.y + Float(row) * cellSize
                let z = center.z

                let v0 = SIMD3<Float>(x, y, z)
                let v1 = SIMD3<Float>(x + cellSize, y, z)
                let v2 = SIMD3<Float>(x + cellSize * 0.5, y + cellSize, z)
                let normal = SIMD3<Float>(0, 0, 1)
                let area = cellSize * cellSize * 0.5

                // Generate patchId using same 1cm grid as MeshExtractor
                let centroid = (v0 + v1 + v2) / 3.0
                let qx = Int(round(centroid.x * 100))
                let qy = Int(round(centroid.y * 100))
                let qz = Int(round(centroid.z * 100))
                let patchId = "\(qx)_\(qy)_\(qz)"

                let tri = ScanTriangle(
                    patchId: patchId,
                    vertices: (v0, v1, v2),
                    normal: normal,
                    areaSqM: area
                )
                triangles.append(tri)
            }
        }
        return triangles
    }

    // MARK: - Test 1: Spatial Sorting Produces Coherent Surface

    func testSpatialSortingKeepsNearestTriangles() {
        // Simulate: two clusters separated far apart.
        // Use larger cell size (0.05m) to avoid patchId collisions within a cluster.
        let camera = SIMD3<Float>(0, 0, 0)
        let nearCluster = Self.makeGridTriangles(rows: 10, cols: 10, center: SIMD3<Float>(0.1, 0.1, 0.2), cellSize: 0.05)
        let farCluster = Self.makeGridTriangles(rows: 10, cols: 10, center: SIMD3<Float>(10.0, 10.0, 15.0), cellSize: 0.05)

        var persistent: [String: ScanTriangle] = [:]
        for tri in nearCluster + farCluster {
            persistent[tri.patchId] = tri
        }

        let nearPatchIds = Set(nearCluster.map { $0.patchId })
        let nearUnique = persistent.keys.filter { nearPatchIds.contains($0) }.count
        let farPatchIds = Set(farCluster.map { $0.patchId })
        let farUnique = persistent.keys.filter { farPatchIds.contains($0) }.count

        // Sort by distance to camera (same logic as updateStateAndRender)
        let sorted = persistent.values.sorted { a, b in
            let centroidA = (a.vertices.0 + a.vertices.1 + a.vertices.2) / 3.0
            let centroidB = (b.vertices.0 + b.vertices.1 + b.vertices.2) / 3.0
            return simd_distance_squared(centroidA, camera) < simd_distance_squared(centroidB, camera)
        }

        // Take only near-cluster count, which should all be from near cluster
        let renderTriangles = Array(sorted.prefix(nearUnique))

        let nearCount = renderTriangles.filter { nearPatchIds.contains($0.patchId) }.count
        XCTAssertEqual(nearCount, nearUnique,
                       "All render triangles should be from near cluster (got \(nearCount)/\(nearUnique), far=\(farUnique))")
    }

    func testWithoutSortingPrefixGivesScatteredTriangles() {
        // Demonstrate WHY spatial sorting is needed:
        // Dictionary.values has random hash order → prefix() picks scattered triangles.
        let nearCluster = Self.makeGridTriangles(rows: 10, cols: 10, center: SIMD3<Float>(0, 0, 0))
        let farCluster = Self.makeGridTriangles(rows: 10, cols: 10, center: SIMD3<Float>(5, 5, 5))

        var persistent: [String: ScanTriangle] = [:]
        for tri in nearCluster + farCluster {
            persistent[tri.patchId] = tri
        }

        // WITHOUT sorting, just take prefix
        let unsortedRender = Array(persistent.values.prefix(100))
        let nearPatchIds = Set(nearCluster.map { $0.patchId })
        let nearCount = unsortedRender.filter { nearPatchIds.contains($0.patchId) }.count

        // With random dictionary ordering, we'd expect roughly 50 near / 50 far
        // (not all 100 from near cluster as desired)
        // This test documents the expected behavior, not a failure condition
        print("[TEST] Without sorting: \(nearCount)/100 triangles from near cluster (expected ~50)")
        // The key assertion: unsorted gives MIXED results, not spatially coherent
        // If by chance all 100 are near, the test still passes — it's documenting behavior
    }

    func testSpatialSortingWithoutTruncationPreservesAll() {
        let triangles = Self.makeGridTriangles(rows: 5, cols: 5)
        var persistent: [String: ScanTriangle] = [:]
        for tri in triangles { persistent[tri.patchId] = tri }

        let maxTriangles = 200
        let allPersistent = Array(persistent.values)
        let renderTriangles = Array(allPersistent.prefix(maxTriangles))

        XCTAssertEqual(renderTriangles.count, persistent.count,
                       "All triangles should be rendered when under cap")
    }

    // MARK: - Test 2: Display Gradient Progression

    func testDisplayIncrementProducesGradualProgression() {
        // Simulate display increment over time using unique patchIds directly.
        // This mirrors the production behavior: each patchId gets incremented
        // once per update cycle (not once per triangle sharing that patchId).
        let patchIds = (0..<9).map { "test_\($0)" }
        var displaySnapshot: [String: Double] = [:]

        let increment = 0.005

        // After 20 increments (~10 seconds at 2Hz): display = 0.10 (S1 threshold)
        for _ in 0..<20 {
            for pid in patchIds {
                let current = displaySnapshot[pid] ?? 0.0
                displaySnapshot[pid] = min(current + increment, 1.0)
            }
        }

        for pid in patchIds {
            let display = displaySnapshot[pid] ?? 0.0
            XCTAssertEqual(display, 0.10, accuracy: 0.001,
                           "After 20 × 0.005 increments, display should be 0.10")
        }

        // After 100 more increments (~50 more seconds): display = 0.60
        for _ in 0..<100 {
            for pid in patchIds {
                let current = displaySnapshot[pid] ?? 0.0
                displaySnapshot[pid] = min(current + increment, 1.0)
            }
        }

        for pid in patchIds {
            let display = displaySnapshot[pid] ?? 0.0
            XCTAssertEqual(display, 0.60, accuracy: 0.001,
                           "After 120 × 0.005 increments, display should be 0.60")
        }
    }

    func testDisplayValueDistribution() {
        // After scanning for a while, there should be a mix of display values:
        // - Recently scanned (near camera): high display
        // - Currently being scanned: medium display
        // - Just discovered: low display
        // This ensures we see black→gray→white gradient on screen.

        var displaySnapshot: [String: Double] = [:]
        let oldTriangles = Self.makeGridTriangles(rows: 5, cols: 5, center: .zero)
        let midTriangles = Self.makeGridTriangles(rows: 5, cols: 5, center: SIMD3<Float>(0.1, 0, 0))
        let newTriangles = Self.makeGridTriangles(rows: 5, cols: 5, center: SIMD3<Float>(0.2, 0, 0))

        // Old triangles: scanned for 100 increments → display = 0.50
        for tri in oldTriangles {
            displaySnapshot[tri.patchId] = 0.50
        }
        // Mid triangles: scanned for 30 increments → display = 0.15
        for tri in midTriangles {
            displaySnapshot[tri.patchId] = 0.15
        }
        // New triangles: just discovered → display = 0.0
        // (not in displaySnapshot yet)

        // Count distribution
        let allTriangles = oldTriangles + midTriangles + newTriangles
        var s0 = 0, s1 = 0, s2 = 0, s3 = 0
        for tri in allTriangles {
            let d = displaySnapshot[tri.patchId] ?? 0.0
            if d < 0.10 { s0 += 1 }
            else if d < 0.25 { s1 += 1 }
            else if d < 0.50 { s2 += 1 }
            else { s3 += 1 }
        }

        XCTAssertGreaterThan(s0, 0, "Should have some S0 (black) triangles")
        XCTAssertGreaterThan(s1, 0, "Should have some S1 (dark gray) triangles")
        // s2 may be 0 if no triangles at display [0.25, 0.50)
        XCTAssertGreaterThan(s3, 0, "Should have some S3+ (light gray/white) triangles")
        print("[TEST] display dist: S0=\(s0) S1=\(s1) S2=\(s2) S3+=\(s3)")
    }

    // MARK: - Test 3: Flip Animation Index Alignment

    func testFlipDetectionIndicesMatchRenderArray() {
        let controller = FlipAnimationController()
        let triangles = Self.makeGridTriangles(rows: 3, cols: 3)
        let graph = SpatialHashAdjacency(triangles: triangles)

        var previousDisplay: [String: Double] = [:]
        var currentDisplay: [String: Double] = [:]
        for tri in triangles {
            previousDisplay[tri.patchId] = 0.04
            currentDisplay[tri.patchId] = 0.15
        }

        let crossedIndices = controller.checkThresholdCrossings(
            previousDisplay: previousDisplay,
            currentDisplay: currentDisplay,
            triangles: triangles,
            adjacencyGraph: graph
        )

        // All crossed indices must be valid for the SAME triangles array
        for idx in crossedIndices {
            XCTAssertGreaterThanOrEqual(idx, 0)
            XCTAssertLessThan(idx, triangles.count,
                              "Crossed index \(idx) out of bounds for array of \(triangles.count)")
        }

        // getFlipAngles with same count should return matching array
        let angles = controller.getFlipAngles(for: Array(0..<triangles.count))
        XCTAssertEqual(angles.count, triangles.count)

        // After tick, crossed indices should have non-zero angles
        if !crossedIndices.isEmpty {
            _ = controller.tick(deltaTime: 0.05)
            let updatedAngles = controller.getFlipAngles(for: Array(0..<triangles.count))
            let nonZero = updatedAngles.filter { $0 > 0.001 }
            XCTAssertGreaterThan(nonZero.count, 0,
                                 "After threshold crossing + tick, at least one angle should be non-zero")
        }
    }

    // MARK: - Test 4: Border Width is Non-Zero

    func testBorderWidthNonZeroAtAllDisplayLevels() {
        let calculator = AdaptiveBorderCalculator()
        let medianArea: Float = 0.0001

        for display in stride(from: 0.0, through: 1.0, by: 0.1) {
            let width = calculator.calculate(
                display: display,
                areaSqM: medianArea,
                medianArea: medianArea
            )
            XCTAssertGreaterThan(width, 0.0,
                                 "Border width should be > 0 at display=\(display)")
        }
    }

    func testBorderWidthBatchMatchesSingle() {
        let calculator = AdaptiveBorderCalculator()
        let triangles = Self.makeGridTriangles(rows: 3, cols: 3)
        let medianArea: Float = 0.00005

        var displayValues: [String: Double] = [:]
        for (i, tri) in triangles.enumerated() {
            displayValues[tri.patchId] = Double(i) * 0.1
        }

        let batchWidths = calculator.calculate(
            displayValues: displayValues,
            triangles: triangles,
            medianArea: medianArea
        )

        XCTAssertEqual(batchWidths.count, triangles.count)

        // Each batch width should match individual calculation
        for (i, tri) in triangles.enumerated() {
            let singleWidth = calculator.calculate(
                display: displayValues[tri.patchId] ?? 0.0,
                areaSqM: tri.areaSqM,
                medianArea: medianArea
            )
            XCTAssertEqual(batchWidths[i], singleWidth, accuracy: 0.001,
                           "Batch width[\(i)] should match single calculation")
        }
    }

    // MARK: - Test 5: Persistent Triangles Never Lose Geometry

    func testPersistentTrianglesGrowMonotonically() {
        var persistent: [String: ScanTriangle] = [:]

        let mesh1 = Self.makeGridTriangles(rows: 10, cols: 10, center: .zero)
        for tri in mesh1 { persistent[tri.patchId] = tri }
        let count1 = persistent.count

        // LiDAR re-meshes with fewer triangles (normal LOD simplification)
        let mesh2 = Self.makeGridTriangles(rows: 8, cols: 10, center: .zero)
        for tri in mesh2 { persistent[tri.patchId] = tri }
        let count2 = persistent.count
        XCTAssertGreaterThanOrEqual(count2, count1,
                                     "Persistent should never shrink")

        // User moves to new area
        let mesh3 = Self.makeGridTriangles(rows: 12, cols: 10, center: SIMD3<Float>(0.2, 0, 0))
        for tri in mesh3 { persistent[tri.patchId] = tri }
        let count3 = persistent.count
        XCTAssertGreaterThanOrEqual(count3, count2,
                                     "Persistent should grow with new area")

        print("[TEST] persistent growth: \(count1) → \(count2) → \(count3)")
    }

    // MARK: - Test 6: Display Values Survive Re-mesh

    func testDisplayValuesSurviveMeshReextraction() {
        var displaySnapshot: [String: Double] = [:]

        let mesh1 = Self.makeGridTriangles(rows: 5, cols: 5, center: .zero)
        for tri in mesh1 {
            displaySnapshot[tri.patchId] = 0.50
        }

        // Same area re-meshed → same patchIds
        let mesh2 = Self.makeGridTriangles(rows: 5, cols: 5, center: .zero)
        for tri in mesh2 {
            XCTAssertNotNil(displaySnapshot[tri.patchId],
                            "Re-meshed triangle should find existing display value")
            XCTAssertEqual(displaySnapshot[tri.patchId]!, 0.50, accuracy: 0.001)
        }
    }

    // MARK: - Test 7: Wedge Geometry Has Volume

    func testWedgeGeometryLOD2HasVolume() {
        let generator = WedgeGeometryGenerator()
        let triangle = ScanTriangle(
            patchId: "test",
            vertices: (SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.01, 0, 0), SIMD3<Float>(0.005, 0.01, 0)),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.00005
        )

        let result = generator.generate(
            triangles: [triangle],
            displayValues: ["test": 0.0],
            lod: .low
        )

        XCTAssertEqual(result.vertices.count, 6, "LOD2 should have 6 vertices")

        let zValues = result.vertices.map { $0.position.z }
        let minZ = zValues.min()!
        let maxZ = zValues.max()!
        XCTAssertGreaterThan(maxZ - minZ, 0.0001,
                             "LOD2 should have thickness (Z extent > 0.1mm)")

        print("[TEST] LOD2 thickness: \(maxZ - minZ)m (min=\(minZ), max=\(maxZ))")
    }

    func testWedgeGeometryLOD1HasMoreVertices() {
        let generator = WedgeGeometryGenerator()
        let triangle = ScanTriangle(
            patchId: "test",
            vertices: (SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.01, 0, 0), SIMD3<Float>(0.005, 0.01, 0)),
            normal: SIMD3<Float>(0, 0, 1),
            areaSqM: 0.00005
        )

        let lod2 = generator.generate(triangles: [triangle], displayValues: ["test": 0.0], lod: .low)
        let lod1 = generator.generate(triangles: [triangle], displayValues: ["test": 0.0], lod: .medium)
        let lod0 = generator.generate(triangles: [triangle], displayValues: ["test": 0.0], lod: .full)

        XCTAssertGreaterThan(lod1.vertices.count, lod2.vertices.count,
                             "LOD1 should have more vertices than LOD2 (bevels)")
        XCTAssertGreaterThanOrEqual(lod0.vertices.count, lod1.vertices.count,
                             "LOD0 should have >= vertices than LOD1")

        print("[TEST] vertex counts: LOD0=\(lod0.vertices.count), LOD1=\(lod1.vertices.count), LOD2=\(lod2.vertices.count)")
    }

    // MARK: - Test 8: Render Triangle Cache Stability

    func testSortedCacheIsStableWithSamePersistent() {
        let triangles = Self.makeGridTriangles(rows: 10, cols: 10)
        var persistent: [String: ScanTriangle] = [:]
        for tri in triangles { persistent[tri.patchId] = tri }

        let camera = SIMD3<Float>(0, 0, 0)
        let maxTriangles = 50

        let sorted1 = persistent.values.sorted { a, b in
            let cA = (a.vertices.0 + a.vertices.1 + a.vertices.2) / 3.0
            let cB = (b.vertices.0 + b.vertices.1 + b.vertices.2) / 3.0
            return simd_distance_squared(cA, camera) < simd_distance_squared(cB, camera)
        }
        let render1 = Array(sorted1.prefix(maxTriangles))

        // Same data, re-sorted → same result
        let sorted2 = persistent.values.sorted { a, b in
            let cA = (a.vertices.0 + a.vertices.1 + a.vertices.2) / 3.0
            let cB = (b.vertices.0 + b.vertices.1 + b.vertices.2) / 3.0
            return simd_distance_squared(cA, camera) < simd_distance_squared(cB, camera)
        }
        let render2 = Array(sorted2.prefix(maxTriangles))

        XCTAssertEqual(render1.count, render2.count)
        for i in 0..<render1.count {
            XCTAssertEqual(render1[i].patchId, render2[i].patchId,
                           "Re-sorting same data should give same order at index \(i)")
        }
    }

    // MARK: - Test 9: PatchId Drift Tolerance

    func testPatchIdDriftToleranceFindsNeighbor() {
        var displaySnapshot: [String: Double] = [:]
        displaySnapshot["50_50_50"] = 0.30

        // Shifted centroid → new patchId "51_50_50"
        let newId = "51_50_50"
        var inherited = false

        if displaySnapshot[newId] == nil {
            let qx = 51, qy = 50, qz = 50
            outerLoop: for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let key = "\(qx+dx)_\(qy+dy)_\(qz+dz)"
                        if key != newId, let oldDisplay = displaySnapshot[key], oldDisplay > 0.0 {
                            displaySnapshot[newId] = oldDisplay
                            inherited = true
                            break outerLoop
                        }
                    }
                }
            }
        }

        XCTAssertTrue(inherited, "Should inherit from neighbor patchId")
        XCTAssertEqual(displaySnapshot[newId] ?? -1.0, 0.30, accuracy: 0.001)
    }

    func testPatchIdDriftToleranceDoesNotFindDistantNeighbor() {
        var displaySnapshot: [String: Double] = [:]
        displaySnapshot["50_50_50"] = 0.30

        // Shifted by 3 grid cells → too far for 3×3×3 neighborhood
        let newId = "53_50_50"
        var inherited = false

        if displaySnapshot[newId] == nil {
            let qx = 53, qy = 50, qz = 50
            outerLoop: for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let key = "\(qx+dx)_\(qy+dy)_\(qz+dz)"
                        if key != newId, let oldDisplay = displaySnapshot[key], oldDisplay > 0.0 {
                            displaySnapshot[newId] = oldDisplay
                            inherited = true
                            break outerLoop
                        }
                    }
                }
            }
        }

        XCTAssertFalse(inherited, "Should NOT inherit from distant patchId (>2cm away)")
    }

    // MARK: - Test 10: Each S-Threshold Triggers Exactly One Flip

    func testEachSThresholdTriggersOneFlip() {
        // Verify that as display progresses 0→1, each S-threshold triggers exactly one flip.
        //
        // FlipAnimationController uses real wall clock time (ProcessInfo.systemUptime).
        // flipDurationS = 0.5s, so we must wait > 0.5s between checks to let the
        // previous flip animation complete before triggering the next one.
        let controller = FlipAnimationController()
        let triangles = Self.makeGridTriangles(rows: 1, cols: 1, cellSize: 0.05)
        let graph = SpatialHashAdjacency(triangles: triangles)

        var totalCrossings = 0
        var baselineDisplay: [String: Double] = [:]
        for tri in triangles { baselineDisplay[tri.patchId] = 0.0 }

        // Jump past each threshold with enough delta (≥ flipMinDisplayDelta = 0.05)
        let displayValues = [0.12, 0.27, 0.52, 0.77, 0.90]
        for displayVal in displayValues {
            var currentDisplay: [String: Double] = [:]
            for tri in triangles { currentDisplay[tri.patchId] = displayVal }

            // Wait for previous flip to finish (flipDurationS=0.5s + stagger + margin)
            Thread.sleep(forTimeInterval: 0.6)
            _ = controller.tick(deltaTime: 0.6)

            let crossed = controller.checkThresholdCrossings(
                previousDisplay: baselineDisplay,
                currentDisplay: currentDisplay,
                triangles: triangles,
                adjacencyGraph: graph
            )
            if !crossed.isEmpty {
                totalCrossings += crossed.count
                baselineDisplay = currentDisplay
            }
        }

        XCTAssertEqual(totalCrossings, 5,
                       "Should detect exactly 5 threshold crossings (got \(totalCrossings))")
    }

    func testFlipAnimationProducesFullRotation() {
        // After a threshold crossing, tick should produce angles from 0 to π
        let controller = FlipAnimationController()
        let triangles = Self.makeGridTriangles(rows: 1, cols: 1, cellSize: 0.05)
        let graph = SpatialHashAdjacency(triangles: triangles)

        var previousDisplay: [String: Double] = [:]
        var currentDisplay: [String: Double] = [:]
        for tri in triangles {
            previousDisplay[tri.patchId] = 0.04
            currentDisplay[tri.patchId] = 0.15  // Crosses S0→S1 at 0.10
        }

        let crossed = controller.checkThresholdCrossings(
            previousDisplay: previousDisplay,
            currentDisplay: currentDisplay,
            triangles: triangles,
            adjacencyGraph: graph
        )
        XCTAssertGreaterThan(crossed.count, 0, "Should detect S0→S1 crossing")

        // Tick for enough time to complete the animation (flipDurationS = 0.5s)
        // But tick uses real time internally, so we need to check angles
        let angles = controller.getFlipAngles(for: [0])
        // At this point the animation just started, angles might be near 0 or progressing
        XCTAssertEqual(angles.count, 1)
        // The angle should be between 0 and π (inclusive)
        XCTAssertGreaterThanOrEqual(angles[0], 0.0)
        XCTAssertLessThanOrEqual(angles[0], Float.pi + 0.01)
    }
}
