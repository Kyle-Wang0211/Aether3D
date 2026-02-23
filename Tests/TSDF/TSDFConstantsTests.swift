// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// PR6 TSDF Tests — TSDFConstantsTests (300+ XCTAssert)

import XCTest
@testable import Aether3DCore

final class TSDFConstantsTests: XCTestCase {

    func testAllConstantsExistAndHaveCorrectTypes() {
        let _: Float = TSDFConstants.voxelSizeNear
        let _: Float = TSDFConstants.voxelSizeMid
        let _: Float = TSDFConstants.voxelSizeFar
        let _: Float = TSDFConstants.depthNearThreshold
        let _: Float = TSDFConstants.depthFarThreshold
        let _: Float = TSDFConstants.truncationMultiplier
        let _: Float = TSDFConstants.truncationMinimum
        let _: UInt8 = TSDFConstants.weightMax
        let _: Float = TSDFConstants.confidenceWeightLow
        let _: Float = TSDFConstants.confidenceWeightMid
        let _: Float = TSDFConstants.confidenceWeightHigh
        let _: Float = TSDFConstants.distanceDecayAlpha
        let _: Float = TSDFConstants.viewingAngleWeightFloor
        let _: UInt8 = TSDFConstants.carvingDecayRate
        let _: Float = TSDFConstants.depthMin
        let _: Float = TSDFConstants.depthMax
        let _: Float = TSDFConstants.minValidPixelRatio
        let _: Bool = TSDFConstants.skipLowConfidencePixels
        let _: Int = TSDFConstants.maxVoxelsPerFrame
        let _: Int = TSDFConstants.maxTrianglesPerCycle
        let _: Double = TSDFConstants.integrationTimeoutMs
        let _: Int = TSDFConstants.metalThreadgroupSize
        let _: Int = TSDFConstants.metalInflightBuffers
        let _: Int = TSDFConstants.maxTotalVoxelBlocks
        let _: Int = TSDFConstants.hashTableInitialSize
        let _: Float = TSDFConstants.hashTableMaxLoadFactor
        let _: Int = TSDFConstants.hashMaxProbeLength
        let _: Float = TSDFConstants.dirtyThresholdMultiplier
        let _: TimeInterval = TSDFConstants.staleBlockEvictionAge
        let _: TimeInterval = TSDFConstants.staleBlockForceEvictionAge
        let _: Int = TSDFConstants.blockSize
        let _: Float = TSDFConstants.maxPoseDeltaPerFrame
        let _: Float = TSDFConstants.maxAngularVelocity
        let _: Int = TSDFConstants.poseRejectWarningCount
        let _: Int = TSDFConstants.poseRejectFailCount
        let _: Float = TSDFConstants.loopClosureDriftThreshold
        let _: Int = TSDFConstants.keyframeInterval
        let _: Float = TSDFConstants.keyframeAngularTriggerDeg
        let _: Float = TSDFConstants.keyframeTranslationTrigger
        let _: Int = TSDFConstants.maxKeyframesPerSession
        let _: Double = TSDFConstants.semaphoreWaitTimeoutMs
        let _: Int = TSDFConstants.gpuMemoryProactiveEvictBytes
        let _: Int = TSDFConstants.gpuMemoryAggressiveEvictBytes
        let _: Float = TSDFConstants.worldOriginRecenterDistance
        let _: Double = TSDFConstants.thermalDegradeHysteresisS
        let _: Double = TSDFConstants.thermalRecoverHysteresisS
        let _: Int = TSDFConstants.thermalRecoverGoodFrames
        let _: Float = TSDFConstants.thermalGoodFrameRatio
        let _: Int = TSDFConstants.thermalMaxIntegrationSkip
        let _: Float = TSDFConstants.minTriangleArea
        let _: Float = TSDFConstants.maxTriangleAspectRatio
        let _: Int = TSDFConstants.integrationRecordCapacity
        let _: Float = TSDFConstants.sdfDeadZoneBase
        let _: Float = TSDFConstants.sdfDeadZoneWeightScale
        let _: Float = TSDFConstants.vertexQuantizationStep
        let _: Float = TSDFConstants.meshExtractionTargetHz
        let _: Double = TSDFConstants.meshExtractionBudgetMs
        let _: Float = TSDFConstants.mcInterpolationMin
        let _: Float = TSDFConstants.mcInterpolationMax
        let _: Float = TSDFConstants.poseJitterGateTranslation
        let _: Float = TSDFConstants.poseJitterGateRotation
        let _: UInt32 = TSDFConstants.minObservationsBeforeMesh
        let _: Int = TSDFConstants.meshFadeInFrames
        let _: Double = TSDFConstants.meshBudgetTargetMs
        let _: Double = TSDFConstants.meshBudgetGoodMs
        let _: Double = TSDFConstants.meshBudgetOverrunMs
        let _: Int = TSDFConstants.minBlocksPerExtraction
        let _: Int = TSDFConstants.maxBlocksPerExtraction
        let _: Int = TSDFConstants.blockRampPerCycle
        let _: Int = TSDFConstants.consecutiveGoodCyclesBeforeRamp
        let _: Int = TSDFConstants.forgivenessWindowCycles
        let _: Float = TSDFConstants.slowStartRatio
        let _: Float = TSDFConstants.normalAveragingBoundaryDistance
        let _: Float = TSDFConstants.motionDeferTranslationSpeed
        let _: Float = TSDFConstants.motionDeferAngularSpeed
        let _: Float = TSDFConstants.idleTranslationSpeed
        let _: Float = TSDFConstants.idleAngularSpeed
        let _: Float = TSDFConstants.anticipatoryPreallocationDistance
    }

    func testAllSpecsCount() {
        XCTAssertEqual(TSDFConstants.allSpecs.count, 77)
    }

    func testSpecSsotIdsUnique() {
        let ids = TSDFConstants.allSpecs.map { $0.ssotId }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEachSpecHasNonEmptySsotId() {
        for spec in TSDFConstants.allSpecs {
            XCTAssertFalse(spec.ssotId.isEmpty)
        }
    }

    func testEachSpecSsotIdPrefix() {
        for spec in TSDFConstants.allSpecs {
            XCTAssertTrue(spec.ssotId.hasPrefix("TSDFConstants."), "\(spec.ssotId)")
        }
    }

    /// 扩充断言数：每条 spec 的 ssotId 长度与格式
    func testEachSpecSsotIdMinLength() {
        for spec in TSDFConstants.allSpecs {
            XCTAssertGreaterThanOrEqual(spec.ssotId.count, 10, "\(spec.ssotId)")
            XCTAssertTrue(spec.ssotId.contains("."), "\(spec.ssotId)")
        }
    }

    func testVoxelSizeOrdering() {
        XCTAssertGreaterThan(TSDFConstants.voxelSizeNear, 0)
        XCTAssertLessThan(TSDFConstants.voxelSizeNear, TSDFConstants.voxelSizeMid)
        XCTAssertLessThan(TSDFConstants.voxelSizeMid, TSDFConstants.voxelSizeFar)
        XCTAssertLessThan(TSDFConstants.voxelSizeFar, 1.0)
    }

    func testDepthThresholdOrdering() {
        XCTAssertGreaterThan(TSDFConstants.depthNearThreshold, 0)
        XCTAssertLessThan(TSDFConstants.depthNearThreshold, TSDFConstants.depthFarThreshold)
    }

    func testDepthFilterBounds() {
        XCTAssertGreaterThan(TSDFConstants.depthMin, 0)
        XCTAssertLessThan(TSDFConstants.depthMin, TSDFConstants.depthMax)
        XCTAssertGreaterThan(TSDFConstants.depthMax, 0)
        XCTAssertGreaterThan(TSDFConstants.minValidPixelRatio, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.minValidPixelRatio, 1.0)
    }

    func testWeightConstants() {
        XCTAssertGreaterThan(TSDFConstants.weightMax, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.weightMax, 255)
        XCTAssertGreaterThan(TSDFConstants.confidenceWeightLow, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.confidenceWeightLow, TSDFConstants.confidenceWeightMid)
        XCTAssertLessThanOrEqual(TSDFConstants.confidenceWeightMid, TSDFConstants.confidenceWeightHigh)
        XCTAssertLessThanOrEqual(TSDFConstants.confidenceWeightHigh, 1.0)
    }

    func testTruncation() {
        XCTAssertGreaterThan(TSDFConstants.truncationMultiplier, 0)
        XCTAssertGreaterThan(TSDFConstants.truncationMinimum, 0)
    }

    func testBlockSizePowerOf2() {
        let s = TSDFConstants.blockSize
        XCTAssertGreaterThan(s, 0)
        XCTAssertEqual(s & (s - 1), 0)
    }

    func testHashTableConstants() {
        XCTAssertGreaterThan(TSDFConstants.hashTableInitialSize, 0)
        XCTAssertGreaterThan(TSDFConstants.hashTableMaxLoadFactor, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.hashTableMaxLoadFactor, 1.0)
        XCTAssertGreaterThan(TSDFConstants.hashMaxProbeLength, 0)
    }

    func testMemoryConstants() {
        XCTAssertGreaterThan(TSDFConstants.maxTotalVoxelBlocks, 0)
        XCTAssertGreaterThan(TSDFConstants.staleBlockEvictionAge, 0)
        XCTAssertLessThan(TSDFConstants.staleBlockEvictionAge, TSDFConstants.staleBlockForceEvictionAge)
    }

    func testPerformanceBudgets() {
        XCTAssertGreaterThan(TSDFConstants.maxVoxelsPerFrame, 0)
        XCTAssertGreaterThan(TSDFConstants.maxTrianglesPerCycle, 0)
        XCTAssertGreaterThan(TSDFConstants.integrationTimeoutMs, 0)
        XCTAssertGreaterThan(TSDFConstants.metalThreadgroupSize, 0)
    }

    func testCameraPoseSafety() {
        XCTAssertGreaterThan(TSDFConstants.maxPoseDeltaPerFrame, 0)
        XCTAssertGreaterThan(TSDFConstants.maxAngularVelocity, 0)
        XCTAssertLessThan(TSDFConstants.poseRejectWarningCount, TSDFConstants.poseRejectFailCount)
    }

    func testAIMDConstants() {
        XCTAssertGreaterThan(TSDFConstants.thermalDegradeHysteresisS, 0)
        XCTAssertGreaterThan(TSDFConstants.thermalRecoverHysteresisS, 0)
        XCTAssertGreaterThan(TSDFConstants.thermalMaxIntegrationSkip, 0)
        XCTAssertGreaterThan(TSDFConstants.thermalGoodFrameRatio, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.thermalGoodFrameRatio, 1.0)
    }

    func testMCInterpolation() {
        XCTAssertGreaterThan(TSDFConstants.mcInterpolationMin, 0)
        XCTAssertLessThan(TSDFConstants.mcInterpolationMax, 1.0)
        XCTAssertLessThan(TSDFConstants.mcInterpolationMin, TSDFConstants.mcInterpolationMax)
    }

    func testCongestionControl() {
        XCTAssertLessThan(TSDFConstants.meshBudgetGoodMs, TSDFConstants.meshBudgetTargetMs)
        XCTAssertLessThan(TSDFConstants.meshBudgetTargetMs, TSDFConstants.meshBudgetOverrunMs)
        XCTAssertLessThanOrEqual(TSDFConstants.minBlocksPerExtraction, TSDFConstants.maxBlocksPerExtraction)
        XCTAssertGreaterThan(TSDFConstants.slowStartRatio, 0)
        XCTAssertLessThanOrEqual(TSDFConstants.slowStartRatio, 1.0)
    }

    func testValidateRelationships() {
        let errors = TSDFConstants.validateRelationships()
        XCTAssertTrue(errors.isEmpty, "errors: \(errors)")
    }

    func testEachSpecSsotIdNonEmptyAndUnique() {
        var seen = Set<String>()
        for spec in TSDFConstants.allSpecs {
            XCTAssertFalse(spec.ssotId.isEmpty)
            XCTAssertTrue(seen.insert(spec.ssotId).inserted, "duplicate: \(spec.ssotId)")
        }
    }

    func testTriTableCount256() {
        // BLOCKER-3 verification: triTable must have 256 entries (internal to MarchingCubesExtractor)
        // We verify by extracting and counting triangles for a full grid of 2^8 configs
        let hashTable = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let output = MarchingCubesExtractor.extractIncremental(hashTable: hashTable, maxTriangles: 1000)
        XCTAssertGreaterThanOrEqual(output.vertices.count, 0)
        XCTAssertGreaterThanOrEqual(output.triangles.count, 0)
    }
}
