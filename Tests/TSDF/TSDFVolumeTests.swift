// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// PR6 TSDF Tests — TSDFVolumeTests (500+ XCTAssert)

import XCTest
@testable import Aether3DCore

final class TSDFVolumeTests: XCTestCase {

    // MARK: - 1. AdaptiveResolution.blockIndex — BUG-6

    func testBlockIndexPositiveCoords() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(0.01, 0.01, 0.01),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx, BlockIndex(0, 0, 0))
    }

    func testBlockIndexNegativeCoords() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(-0.001, 0, 0),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx.x, -1)
    }

    func testBlockIndexExactBoundary() {
        let blockWorldSize = 0.004 * Float(TSDFConstants.blockSize)
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(blockWorldSize, 0, 0),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx.x, 1)
    }

    func testBlockIndexNegativeBoundary() {
        let blockWorldSize = 0.004 * Float(TSDFConstants.blockSize)
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(-blockWorldSize, 0, 0),
            voxelSize: 0.004
        )
        XCTAssertEqual(idx.x, -1)
    }

    func testBlockIndexOrigin() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(0, 0, 0),
            voxelSize: 0.01
        )
        XCTAssertEqual(idx, BlockIndex(0, 0, 0))
    }

    func testBlockIndexNegativeEpsilonAllAxes() {
        let eps: Float = -0.0001
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(eps, eps, eps),
            voxelSize: 0.01
        )
        XCTAssertEqual(idx.x, -1)
        XCTAssertEqual(idx.y, -1)
        XCTAssertEqual(idx.z, -1)
    }

    func testBlockIndexLargeNegative() {
        let idx = AdaptiveResolution.blockIndex(
            worldPosition: TSDFFloat3(-1.0, -2.0, -3.0),
            voxelSize: 0.01
        )
        let bws: Float = 0.01 * 8
        XCTAssertEqual(idx.x, Int32((-1.0 / bws).rounded(.down)))
        XCTAssertEqual(idx.y, Int32((-2.0 / bws).rounded(.down)))
        XCTAssertEqual(idx.z, Int32((-3.0 / bws).rounded(.down)))
    }

    func testBlockIndexGridSweep() {
        let voxelSize: Float = 0.01
        let bws = voxelSize * Float(TSDFConstants.blockSize)
        for bx in -3...3 {
            for by in -3...3 {
                let worldX = Float(bx) * bws + bws * 0.5
                let worldY = Float(by) * bws + bws * 0.5
                let idx = AdaptiveResolution.blockIndex(
                    worldPosition: TSDFFloat3(worldX, worldY, 0),
                    voxelSize: voxelSize
                )
                XCTAssertEqual(idx.x, Int32(bx))
                XCTAssertEqual(idx.y, Int32(by))
            }
        }
    }

    // MARK: - 2. AdaptiveResolution.voxelSize

    func testVoxelSizeSelection() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 0.5), TSDFConstants.voxelSizeNear)
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 2.0), TSDFConstants.voxelSizeMid)
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 4.0), TSDFConstants.voxelSizeFar)
    }

    func testVoxelSizeAtBoundaries() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthNearThreshold),
                       TSDFConstants.voxelSizeMid)
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthFarThreshold),
                       TSDFConstants.voxelSizeFar)
    }

    func testVoxelSizeJustBelowNear() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthNearThreshold - 0.01),
                       TSDFConstants.voxelSizeNear)
    }

    func testVoxelSizeJustBelowFar() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: TSDFConstants.depthFarThreshold - 0.01),
                       TSDFConstants.voxelSizeMid)
    }

    func testVoxelSizeVeryClose() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 0.1), TSDFConstants.voxelSizeNear)
    }

    func testVoxelSizeVeryFar() {
        XCTAssertEqual(AdaptiveResolution.voxelSize(forDepth: 10.0), TSDFConstants.voxelSizeFar)
    }

    // MARK: - 3. truncationDistance

    func testTruncationDistancePositive() {
        let t = AdaptiveResolution.truncationDistance(voxelSize: 0.01)
        XCTAssertGreaterThan(t, 0)
        XCTAssertGreaterThanOrEqual(t, 2.0 * 0.01)
    }

    func testTruncationDistanceAllSizes() {
        let sizes: [Float] = [0.005, 0.01, 0.02, 0.001, 0.05]
        for vs in sizes {
            let t = AdaptiveResolution.truncationDistance(voxelSize: vs)
            XCTAssertGreaterThanOrEqual(t, 2.0 * vs)
            XCTAssertGreaterThanOrEqual(t, TSDFConstants.truncationMinimum)
        }
    }

    func testTruncationDistanceTinyVoxel() {
        let t = AdaptiveResolution.truncationDistance(voxelSize: 0.001)
        XCTAssertGreaterThanOrEqual(t, TSDFConstants.truncationMinimum)
        XCTAssertGreaterThanOrEqual(t, 0.002)
    }

    // MARK: - 4. distanceWeight / confidenceWeight / viewingAngleWeight

    func testDistanceWeightAtZero() {
        let w = AdaptiveResolution.distanceWeight(depth: 0)
        XCTAssertEqual(w, 1.0, accuracy: 1e-5)
    }

    func testDistanceWeightDecaysWithDistance() {
        let w1 = AdaptiveResolution.distanceWeight(depth: 1.0)
        let w3 = AdaptiveResolution.distanceWeight(depth: 3.0)
        let w5 = AdaptiveResolution.distanceWeight(depth: 5.0)
        XCTAssertGreaterThan(w1, w3)
        XCTAssertGreaterThan(w3, w5)
        XCTAssertGreaterThan(w1, 0)
        XCTAssertGreaterThan(w3, 0)
        XCTAssertGreaterThan(w5, 0)
    }

    func testConfidenceWeightLevels() {
        let wLow = AdaptiveResolution.confidenceWeight(level: 0)
        let wMid = AdaptiveResolution.confidenceWeight(level: 1)
        let wHigh = AdaptiveResolution.confidenceWeight(level: 2)
        XCTAssertEqual(wLow, TSDFConstants.confidenceWeightLow, accuracy: 1e-6)
        XCTAssertEqual(wMid, TSDFConstants.confidenceWeightMid, accuracy: 1e-6)
        XCTAssertEqual(wHigh, TSDFConstants.confidenceWeightHigh, accuracy: 1e-6)
        XCTAssertLessThan(wLow, wMid)
        XCTAssertLessThan(wMid, wHigh)
    }

    func testConfidenceWeightUnknownLevel() {
        let w = AdaptiveResolution.confidenceWeight(level: 5)
        XCTAssertEqual(w, TSDFConstants.confidenceWeightHigh, accuracy: 1e-6)
    }

    func testViewingAngleWeightPerpendicular() {
        let w = AdaptiveResolution.viewingAngleWeight(
            viewRay: TSDFFloat3(0, 0, 1),
            normal: TSDFFloat3(0, 0, 1)
        )
        XCTAssertEqual(w, 1.0, accuracy: 1e-5)
    }

    func testViewingAngleWeightGrazing() {
        let w = AdaptiveResolution.viewingAngleWeight(
            viewRay: TSDFFloat3(1, 0, 0),
            normal: TSDFFloat3(0, 1, 0)
        )
        XCTAssertEqual(w, TSDFConstants.viewingAngleWeightFloor, accuracy: 1e-5)
    }

    func testViewingAngleWeight45Deg() {
        let v = TSDFFloat3(1, 0, 1).normalized()
        let n = TSDFFloat3(0, 0, 1)
        let w = AdaptiveResolution.viewingAngleWeight(viewRay: v, normal: n)
        XCTAssertEqual(w, 0.707, accuracy: 0.01)
    }

    // MARK: - 5. IntegrationRecord

    func testIntegrationRecordEmpty() {
        let empty = IntegrationRecord.empty
        XCTAssertEqual(empty.timestamp, 0)
        XCTAssertFalse(empty.isKeyframe)
        XCTAssertNil(empty.keyframeId)
        XCTAssertTrue(empty.affectedBlockIndices.isEmpty)
    }

    func testIntegrationRecordCreation() {
        let rec = IntegrationRecord(
            timestamp: 1.5,
            cameraPose: .tsdIdentity4x4,
            intrinsics: .tsdIdentity3x3,
            affectedBlockIndices: [1, 2, 3].map { Int32($0) },
            isKeyframe: true,
            keyframeId: 42
        )
        XCTAssertEqual(rec.timestamp, 1.5, accuracy: 1e-6)
        XCTAssertEqual(rec.affectedBlockIndices, [1, 2, 3].map { Int32($0) })
        XCTAssertTrue(rec.isKeyframe)
        XCTAssertEqual(rec.keyframeId, 42)
    }

    // MARK: - 6. IntegrationInput

    func testIntegrationInputCreation() {
        let input = IntegrationInput(
            timestamp: 1.0,
            intrinsics: .tsdIdentity3x3,
            cameraToWorld: .tsdIdentity4x4,
            depthWidth: 256,
            depthHeight: 192,
            trackingState: 2
        )
        XCTAssertEqual(input.depthWidth, 256)
        XCTAssertEqual(input.depthHeight, 192)
        XCTAssertEqual(input.trackingState, 2)
        XCTAssertEqual(input.timestamp, 1.0, accuracy: 1e-6)
    }

    func testIntegrationInputAllTrackingStates() {
        for state in 0...2 {
            let input = IntegrationInput(
                timestamp: 0, intrinsics: .tsdIdentity3x3,
                cameraToWorld: .tsdIdentity4x4,
                depthWidth: 256, depthHeight: 192,
                trackingState: state
            )
            XCTAssertEqual(input.trackingState, state)
        }
    }

    // MARK: - 7. IntegrationResult

    func testIntegrationResultSuccess() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 5, blocksAllocated: 3,
            voxelsUpdated: 1000, gpuTimeMs: 2.0, totalTimeMs: 5.0
        )
        let result = IntegrationResult.success(stats)
        if case .success(let s) = result {
            XCTAssertEqual(s.blocksUpdated, 5)
            XCTAssertEqual(s.blocksAllocated, 3)
            XCTAssertEqual(s.voxelsUpdated, 1000)
            XCTAssertEqual(s.gpuTimeMs, 2.0, accuracy: 1e-6)
            XCTAssertEqual(s.totalTimeMs, 5.0, accuracy: 1e-6)
        } else {
            XCTFail("expected .success")
        }
    }

    func testIntegrationResultAllSkipReasons() {
        let reasons: [IntegrationResult.SkipReason] = [
            .trackingLost, .poseTeleport, .poseJitter,
            .thermalThrottle, .frameTimeout, .lowValidPixels, .memoryPressure
        ]
        for reason in reasons {
            let result = IntegrationResult.skipped(reason)
            if case .skipped(let r) = result {
                XCTAssertTrue(r == reason)
            } else {
                XCTFail("expected .skipped(\(reason))")
            }
        }
    }

    func testIntegrationStatsZeroValues() {
        let stats = IntegrationResult.IntegrationStats(
            blocksUpdated: 0, blocksAllocated: 0,
            voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0
        )
        XCTAssertEqual(stats.blocksUpdated, 0)
        XCTAssertEqual(stats.blocksAllocated, 0)
        XCTAssertEqual(stats.voxelsUpdated, 0)
        XCTAssertEqual(stats.gpuTimeMs, 0, accuracy: 1e-10)
        XCTAssertEqual(stats.totalTimeMs, 0, accuracy: 1e-10)
    }

    // MARK: - 8. TSDFMathTypes

    func testIdentityMatrix4x4() {
        let m = TSDFMatrix4x4.tsdIdentity4x4
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(m.columns.0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.w, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.0.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.0.z, 0.0, accuracy: 1e-6)
        #else
        XCTAssertEqual(m.c0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c3.w, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c0.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(m.c0.z, 0.0, accuracy: 1e-6)
        #endif
    }

    func testIdentityMatrix3x3() {
        let m = TSDFMatrix3x3.tsdIdentity3x3
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(m.columns.0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.z, 1.0, accuracy: 1e-6)
        #else
        XCTAssertEqual(m.c0.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c1.y, 1.0, accuracy: 1e-6)
        XCTAssertEqual(m.c2.z, 1.0, accuracy: 1e-6)
        #endif
    }

    func testFloat3Length() {
        let v = TSDFFloat3(3, 4, 0)
        XCTAssertEqual(v.length(), 5.0, accuracy: 1e-5)
    }

    func testFloat3LengthZero() {
        XCTAssertEqual(TSDFFloat3(0, 0, 0).length(), 0.0, accuracy: 1e-10)
    }

    func testFloat3Normalized() {
        let v = TSDFFloat3(3, 4, 0)
        let n = v.normalized()
        XCTAssertEqual(n.length(), 1.0, accuracy: 1e-5)
        XCTAssertEqual(n.x, 0.6, accuracy: 1e-5)
        XCTAssertEqual(n.y, 0.8, accuracy: 1e-5)
    }

    func testMixFunction() {
        let a = TSDFFloat3(0, 0, 0)
        let b = TSDFFloat3(10, 20, 30)
        let result = mix(a, b, t: 0.5)
        XCTAssertEqual(result.x, 5.0, accuracy: 1e-5)
        XCTAssertEqual(result.y, 10.0, accuracy: 1e-5)
        XCTAssertEqual(result.z, 15.0, accuracy: 1e-5)
    }

    func testDotProduct() {
        let a = TSDFFloat3(1, 0, 0)
        let b = TSDFFloat3(0, 1, 0)
        XCTAssertEqual(dot(a, b), 0.0, accuracy: 1e-6)
        XCTAssertEqual(dot(a, a), 1.0, accuracy: 1e-6)
    }

    func testCrossProduct() {
        let a = TSDFFloat3(1, 0, 0)
        let b = TSDFFloat3(0, 1, 0)
        let c = cross(a, b)
        XCTAssertEqual(c.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(c.y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(c.z, 1.0, accuracy: 1e-6)
    }

    func testVectorAddition() {
        let a = TSDFFloat3(1, 2, 3)
        let b = TSDFFloat3(4, 5, 6)
        let c = a + b
        XCTAssertEqual(c.x, 5.0, accuracy: 1e-5)
        XCTAssertEqual(c.y, 7.0, accuracy: 1e-5)
        XCTAssertEqual(c.z, 9.0, accuracy: 1e-5)
    }

    func testVectorSubtraction() {
        let a = TSDFFloat3(4, 5, 6)
        let b = TSDFFloat3(1, 2, 3)
        let c = a - b
        XCTAssertEqual(c.x, 3.0, accuracy: 1e-5)
        XCTAssertEqual(c.y, 3.0, accuracy: 1e-5)
        XCTAssertEqual(c.z, 3.0, accuracy: 1e-5)
    }

    // MARK: - 9. SDFStorage

    func testSDFStorageRoundTrip() {
        let original: Float = 0.75
        let stored = SDFStorage(original)
        #if canImport(simd) || arch(arm64)
        let recovered = Float(stored)
        #else
        let recovered = stored.floatValue
        #endif
        XCTAssertEqual(recovered, original, accuracy: 0.01)
    }

    func testSDFStorageFuzz() {
        var step: Float = -1.0
        while step <= 1.0 {
            let stored = SDFStorage(step)
            #if canImport(simd) || arch(arm64)
            let recovered = Float(stored)
            #else
            let recovered = stored.floatValue
            #endif
            XCTAssertEqual(recovered, step, accuracy: 0.02)
            step += 0.05
        }
    }

    // MARK: - 10. BlockIndex

    func testBlockIndexEquality() {
        XCTAssertEqual(BlockIndex(1, 2, 3), BlockIndex(1, 2, 3))
        XCTAssertNotEqual(BlockIndex(1, 2, 3), BlockIndex(3, 2, 1))
    }

    func testBlockIndexHashable() {
        var set = Set<BlockIndex>()
        set.insert(BlockIndex(1, 2, 3))
        set.insert(BlockIndex(1, 2, 3))
        XCTAssertEqual(set.count, 1)
    }

    func testBlockIndexAddition() {
        let a = BlockIndex(1, 2, 3)
        let b = BlockIndex(4, 5, 6)
        let c = a + b
        XCTAssertEqual(c, BlockIndex(5, 7, 9))
    }

    func testBlockIndexAdditionNegative() {
        let a = BlockIndex(-1, -2, -3)
        let b = BlockIndex(1, 2, 3)
        let c = a + b
        XCTAssertEqual(c, BlockIndex(0, 0, 0))
    }

    func testBlockIndexNiessnerHashDeterministic() {
        let idx = BlockIndex(1, 2, 3)
        let h1 = idx.niessnerHash(tableSize: 1024)
        let h2 = idx.niessnerHash(tableSize: 1024)
        XCTAssertEqual(h1, h2)
    }

    func testBlockIndexNiessnerHashRange() {
        let tableSize = 65536
        for x: Int32 in -10...10 {
            for y: Int32 in -10...10 {
                let idx = BlockIndex(x, y, 0)
                let h = idx.niessnerHash(tableSize: tableSize)
                XCTAssertGreaterThanOrEqual(h, 0)
                XCTAssertLessThan(h, tableSize)
            }
        }
    }

    func testBlockIndexFaceNeighborOffsets() {
        let offsets = BlockIndex.faceNeighborOffsets
        XCTAssertEqual(offsets.count, 6)
        for offset in offsets {
            let nonZero = (offset.x != 0 ? 1 : 0) + (offset.y != 0 ? 1 : 0) + (offset.z != 0 ? 1 : 0)
            XCTAssertEqual(nonZero, 1)
        }
    }

    // MARK: - 11. ArrayDepthData

    func testArrayDepthData() {
        let w = 4, h = 3
        let depths = [Float](repeating: 1.5, count: w * h)
        let confs = [UInt8](repeating: 2, count: w * h)
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        XCTAssertEqual(data.width, 4)
        XCTAssertEqual(data.height, 3)
        XCTAssertEqual(data.depthAt(x: 0, y: 0), 1.5)
        XCTAssertEqual(data.confidenceAt(x: 0, y: 0), 2)
    }

    func testArrayDepthDataAllPixels() {
        let w = 8, h = 6
        var depths = [Float](repeating: 0, count: w * h)
        var confs = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                depths[y * w + x] = Float(x + y * 10) * 0.1
                confs[y * w + x] = UInt8((x + y) % 3)
            }
        }
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        for y in 0..<h {
            for x in 0..<w {
                let expected = Float(x + y * 10) * 0.1
                XCTAssertEqual(data.depthAt(x: x, y: y), expected, accuracy: 1e-5)
                XCTAssertEqual(data.confidenceAt(x: x, y: y), UInt8((x + y) % 3))
            }
        }
    }

    // MARK: - 12. MemoryPressureLevel

    func testMemoryPressureLevelRawValues() {
        XCTAssertEqual(MemoryPressureLevel.warning.rawValue, 1)
        XCTAssertEqual(MemoryPressureLevel.critical.rawValue, 2)
        XCTAssertEqual(MemoryPressureLevel.terminal.rawValue, 3)
    }

    // MARK: - 13. validateRelationships

    func testValidateRelationshipsNoErrors() {
        let errors = TSDFConstants.validateRelationships()
        XCTAssertTrue(errors.isEmpty, "\(errors)")
    }

    func testConstantRelationships() {
        XCTAssertLessThan(TSDFConstants.voxelSizeNear, TSDFConstants.voxelSizeMid)
        XCTAssertLessThan(TSDFConstants.voxelSizeMid, TSDFConstants.voxelSizeFar)
        XCTAssertLessThan(TSDFConstants.depthNearThreshold, TSDFConstants.depthFarThreshold)
        XCTAssertLessThan(TSDFConstants.confidenceWeightLow, TSDFConstants.confidenceWeightMid)
        XCTAssertLessThan(TSDFConstants.confidenceWeightMid, TSDFConstants.confidenceWeightHigh)
    }

    // MARK: - 14. blockIndex fuzz (100+ asserts)

    func testBlockIndexFuzzVoxelSizes() {
        let voxelSizes: [Float] = [0.005, 0.01, 0.02]
        for voxelSize in voxelSizes {
            let bws = voxelSize * Float(TSDFConstants.blockSize)
            var x = Float(-0.5)
            while x <= 0.5 {
                var y = Float(-0.5)
                while y <= 0.5 {
                    let idx = AdaptiveResolution.blockIndex(
                        worldPosition: TSDFFloat3(x, y, 0),
                        voxelSize: voxelSize
                    )
                    let expectedX = Int32((x / bws).rounded(.down))
                    let expectedY = Int32((y / bws).rounded(.down))
                    XCTAssertEqual(idx.x, expectedX)
                    XCTAssertEqual(idx.y, expectedY)
                    y += 0.08
                }
                x += 0.08
            }
        }
    }

    // MARK: - 15. SDFStorage fuzz 100 steps

    func testSDFStorageFuzz100() {
        for i in 0..<100 {
            let step = -1.0 + Float(i) * 0.02
            let stored = SDFStorage(step)
            #if canImport(simd) || arch(arm64)
            let recovered = Float(stored)
            #else
            let recovered = stored.floatValue
            #endif
            XCTAssertEqual(recovered, step, accuracy: 0.02)
        }
    }

    // MARK: - 16. BlockIndex grid 20x20

    func testBlockIndexGrid20x20() {
        for bx in -10..<10 {
            for bz in -10..<10 {
                let idx = BlockIndex(Int32(bx), 0, Int32(bz))
                let h = idx.niessnerHash(tableSize: 1024)
                XCTAssertGreaterThanOrEqual(h, 0)
                XCTAssertLessThan(h, 1024)
            }
        }
    }
}
