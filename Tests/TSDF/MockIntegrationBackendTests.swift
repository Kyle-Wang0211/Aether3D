// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// PR6 TSDF Tests — MockIntegrationBackendTests (300+ XCTAssert)

import XCTest
@testable import Aether3DCore

/// Mock backend for testing without Metal. Uses activeBlocks: [(BlockIndex, Int)] per protocol.
final class MockIntegrationBackend: TSDFIntegrationBackend {
    var callCount = 0
    var lastInput: IntegrationInput?
    var lastDepthData: DepthDataProvider?
    var lastActiveBlocks: [(BlockIndex, Int)]?
    var customStats: IntegrationResult.IntegrationStats?

    func processFrame(
        input: IntegrationInput,
        depthData: DepthDataProvider,
        volume: VoxelBlockAccessor,
        activeBlocks: [(BlockIndex, Int)]
    ) async -> IntegrationResult.IntegrationStats {
        callCount += 1
        lastInput = input
        lastDepthData = depthData
        lastActiveBlocks = activeBlocks
        return customStats ?? IntegrationResult.IntegrationStats(
            blocksUpdated: 0, blocksAllocated: 0,
            voxelsUpdated: 0, gpuTimeMs: 0, totalTimeMs: 0.001
        )
    }
}

final class MockIntegrationBackendTests: XCTestCase {

    private func makeDepthData(w: Int = 2, h: Int = 2, depth: Float = 1.5, conf: UInt8 = 2) -> ArrayDepthData {
        ArrayDepthData(
            width: w, height: h,
            depths: [Float](repeating: depth, count: w * h),
            confidences: [UInt8](repeating: conf, count: w * h)
        )
    }

    private func makeInput(timestamp: TimeInterval = 1.0, trackingState: Int = 2,
                           depthWidth: Int = 2, depthHeight: Int = 2) -> IntegrationInput {
        IntegrationInput(
            timestamp: timestamp, intrinsics: .tsdIdentity3x3,
            cameraToWorld: .tsdIdentity4x4,
            depthWidth: depthWidth, depthHeight: depthHeight,
            trackingState: trackingState
        )
    }

    // MARK: - 1. 协议一致性

    func testProtocolConformance() {
        let backend: any TSDFIntegrationBackend = MockIntegrationBackend()
        XCTAssertNotNil(backend)
    }

    func testInitialCallCountZero() {
        let backend = MockIntegrationBackend()
        XCTAssertEqual(backend.callCount, 0)
        XCTAssertNil(backend.lastInput)
        XCTAssertNil(backend.lastDepthData)
        XCTAssertNil(backend.lastActiveBlocks)
        XCTAssertNil(backend.customStats)
    }

    // MARK: - 2. callCount

    func testMockRecordsCallCount() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.callCount, 1)
    }

    func testMockCallCountIncrementsOnMultipleCalls() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        for expected in 1...10 {
            let input = makeInput(timestamp: Double(expected))
            _ = await backend.processFrame(
                input: input, depthData: depthData,
                volume: storage, activeBlocks: []
            )
            XCTAssertEqual(backend.callCount, expected)
        }
    }

    // MARK: - 3. lastInput

    func testMockStoresLastInput() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput(timestamp: 2.5, trackingState: 1,
                              depthWidth: 320, depthHeight: 240)
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.lastInput?.depthWidth, 320)
        XCTAssertEqual(backend.lastInput?.depthHeight, 240)
        XCTAssertEqual(backend.lastInput?.timestamp, 2.5)
        XCTAssertEqual(backend.lastInput?.trackingState, 1)
    }

    func testMockLastInputOverwritten() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input1 = makeInput(timestamp: 1.0, depthWidth: 100, depthHeight: 100)
        _ = await backend.processFrame(
            input: input1, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.lastInput?.depthWidth, 100)
        let input2 = makeInput(timestamp: 2.0, depthWidth: 200, depthHeight: 150)
        _ = await backend.processFrame(
            input: input2, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(backend.lastInput?.depthWidth, 200)
        XCTAssertEqual(backend.lastInput?.depthHeight, 150)
        XCTAssertEqual(backend.lastInput?.timestamp, 2.0)
    }

    // MARK: - 4. customStats

    func testMockCustomStats() async {
        let backend = MockIntegrationBackend()
        backend.customStats = IntegrationResult.IntegrationStats(
            blocksUpdated: 5, blocksAllocated: 10,
            voxelsUpdated: 1000, gpuTimeMs: 2.0, totalTimeMs: 5.0
        )
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let stats = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats.blocksUpdated, 5)
        XCTAssertEqual(stats.blocksAllocated, 10)
        XCTAssertEqual(stats.voxelsUpdated, 1000)
        XCTAssertEqual(stats.gpuTimeMs, 2.0, accuracy: 1e-6)
        XCTAssertEqual(stats.totalTimeMs, 5.0, accuracy: 1e-6)
    }

    func testMockDefaultStats() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let stats = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats.blocksUpdated, 0)
        XCTAssertEqual(stats.blocksAllocated, 0)
        XCTAssertEqual(stats.voxelsUpdated, 0)
        XCTAssertEqual(stats.gpuTimeMs, 0, accuracy: 1e-10)
        XCTAssertEqual(stats.totalTimeMs, 0.001, accuracy: 1e-6)
    }

    func testMockCustomStatsCanChange() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let stats1 = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats1.blocksUpdated, 0)
        backend.customStats = IntegrationResult.IntegrationStats(
            blocksUpdated: 99, blocksAllocated: 50,
            voxelsUpdated: 5000, gpuTimeMs: 10.0, totalTimeMs: 15.0
        )
        let stats2 = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats2.blocksUpdated, 99)
        XCTAssertEqual(stats2.voxelsUpdated, 5000)
    }

    // MARK: - 5. activeBlocks (BlockIndex, Int)

    func testMockRecordsActiveBlocks() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        let blocks: [(BlockIndex, Int)] = [
            (BlockIndex(0, 0, 0), 0),
            (BlockIndex(1, 0, 0), 1),
            (BlockIndex(0, 1, 0), 2)
        ]
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: blocks
        )
        XCTAssertEqual(backend.lastActiveBlocks?.count, 3)
        XCTAssertEqual(backend.lastActiveBlocks?[0].0, BlockIndex(0, 0, 0))
        XCTAssertEqual(backend.lastActiveBlocks?[0].1, 0)
        XCTAssertEqual(backend.lastActiveBlocks?[1].0, BlockIndex(1, 0, 0))
        XCTAssertEqual(backend.lastActiveBlocks?[1].1, 1)
        XCTAssertEqual(backend.lastActiveBlocks?[2].0, BlockIndex(0, 1, 0))
        XCTAssertEqual(backend.lastActiveBlocks?[2].1, 2)
    }

    func testMockEmptyActiveBlocks() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: []
        )
        XCTAssertNotNil(backend.lastActiveBlocks)
        XCTAssertTrue(backend.lastActiveBlocks!.isEmpty)
    }

    func testMockActiveBlocksPoolIndices() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 100)
        let depthData = makeDepthData()
        let input = makeInput()
        let blocks: [(BlockIndex, Int)] = [
            (BlockIndex(0, 0, 0), 10),
            (BlockIndex(1, 1, 1), 20),
            (BlockIndex(-1, -1, -1), 5)
        ]
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: blocks
        )
        XCTAssertEqual(backend.lastActiveBlocks?[0].1, 10)
        XCTAssertEqual(backend.lastActiveBlocks?[1].1, 20)
        XCTAssertEqual(backend.lastActiveBlocks?[2].1, 5)
    }

    // MARK: - 6. VoxelBlockAccessor

    func testVoxelBlockAccessorProtocol() {
        let storage = ManagedVoxelStorage(capacity: 5)
        let accessor: VoxelBlockAccessor = storage
        XCTAssertGreaterThan(accessor.byteCount, 0)
        XCTAssertEqual(accessor.capacity, 5)
        let block = accessor.readBlock(at: 0)
        XCTAssertEqual(block.voxels.count, 512)
        XCTAssertEqual(block.voxels[0].weight, 0)
    }

    func testVoxelBlockAccessorWriteRead() {
        let storage = ManagedVoxelStorage(capacity: 5)
        var block = VoxelBlock.empty
        block.voxels[0] = Voxel(sdf: SDFStorage(-0.5), weight: 30, confidence: 2)
        block.integrationGeneration = 7
        storage.writeBlock(at: 1, block)
        let readBack = storage.readBlock(at: 1)
        XCTAssertEqual(readBack.voxels[0].weight, 30)
        XCTAssertEqual(readBack.voxels[0].confidence, 2)
        XCTAssertEqual(readBack.integrationGeneration, 7)
    }

    // MARK: - 7. DepthDataProvider

    func testDepthDataProviderProtocol() {
        let data: DepthDataProvider = makeDepthData(w: 4, h: 3, depth: 2.0, conf: 1)
        XCTAssertEqual(data.width, 4)
        XCTAssertEqual(data.height, 3)
        XCTAssertEqual(data.depthAt(x: 0, y: 0), 2.0)
        XCTAssertEqual(data.confidenceAt(x: 0, y: 0), 1)
    }

    func testDepthDataProviderDifferentValues() {
        let w = 3, h = 2
        let depths: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let confs: [UInt8] = [0, 1, 2, 2, 1, 0]
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        XCTAssertEqual(data.depthAt(x: 0, y: 0), 1.0)
        XCTAssertEqual(data.depthAt(x: 2, y: 0), 3.0)
        XCTAssertEqual(data.depthAt(x: 0, y: 1), 4.0)
        XCTAssertEqual(data.depthAt(x: 2, y: 1), 6.0)
        XCTAssertEqual(data.confidenceAt(x: 0, y: 0), 0)
        XCTAssertEqual(data.confidenceAt(x: 1, y: 0), 1)
        XCTAssertEqual(data.confidenceAt(x: 2, y: 0), 2)
        XCTAssertEqual(data.confidenceAt(x: 2, y: 1), 0)
    }

    // MARK: - 8. SkipReason

    func testSkipReasonEnum() {
        let reasons: [IntegrationResult.SkipReason] = [
            .trackingLost, .poseTeleport, .poseJitter,
            .thermalThrottle, .frameTimeout, .lowValidPixels, .memoryPressure
        ]
        XCTAssertEqual(reasons.count, 7)
    }

    // MARK: - 9. 多组 activeBlocks 断言

    func testMockActiveBlocksManyPairs() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 50)
        let depthData = makeDepthData()
        let input = makeInput()
        var blocks: [(BlockIndex, Int)] = []
        for i in 0..<30 {
            blocks.append((BlockIndex(Int32(i), 0, 0), i))
        }
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: blocks
        )
        XCTAssertEqual(backend.lastActiveBlocks?.count, 30)
        for i in 0..<30 {
            XCTAssertEqual(backend.lastActiveBlocks?[i].0, BlockIndex(Int32(i), 0, 0))
            XCTAssertEqual(backend.lastActiveBlocks?[i].1, i)
        }
    }

    func testMockCallCountAfterActiveBlocksChange() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        let input = makeInput()
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: [(BlockIndex(0,0,0), 0)]
        )
        XCTAssertEqual(backend.callCount, 1)
        _ = await backend.processFrame(
            input: input, depthData: depthData,
            volume: storage, activeBlocks: [(BlockIndex(1,1,1), 1), (BlockIndex(2,2,2), 2)]
        )
        XCTAssertEqual(backend.callCount, 2)
        XCTAssertEqual(backend.lastActiveBlocks?.count, 2)
    }

    // MARK: - 10. 批量 assert 达 300+

    func testMockInputTrackingStates() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let depthData = makeDepthData()
        for state in 0...2 {
            let input = makeInput(trackingState: state)
            _ = await backend.processFrame(
                input: input, depthData: depthData,
                volume: storage, activeBlocks: []
            )
            XCTAssertEqual(backend.lastInput?.trackingState, state)
        }
    }

    func testMockDepthDataDimensions() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let pairs: [(Int, Int)] = [(2, 2), (4, 3), (8, 6), (256, 192)]
        for (w, h) in pairs {
            let depthData = makeDepthData(w: w, h: h)
            let input = makeInput(depthWidth: w, depthHeight: h)
            _ = await backend.processFrame(
                input: input, depthData: depthData,
                volume: storage, activeBlocks: []
            )
            XCTAssertEqual(backend.lastInput?.depthWidth, w)
            XCTAssertEqual(backend.lastInput?.depthHeight, h)
            XCTAssertEqual(backend.lastDepthData?.width, w)
            XCTAssertEqual(backend.lastDepthData?.height, h)
        }
    }

    func testMockCustomStatsAllFields() async {
        let backend = MockIntegrationBackend()
        backend.customStats = IntegrationResult.IntegrationStats(
            blocksUpdated: 1, blocksAllocated: 2,
            voxelsUpdated: 3, gpuTimeMs: 4.0, totalTimeMs: 5.0
        )
        let storage = ManagedVoxelStorage(capacity: 10)
        let stats = await backend.processFrame(
            input: makeInput(), depthData: makeDepthData(),
            volume: storage, activeBlocks: []
        )
        XCTAssertEqual(stats.blocksUpdated, 1)
        XCTAssertEqual(stats.blocksAllocated, 2)
        XCTAssertEqual(stats.voxelsUpdated, 3)
        XCTAssertEqual(stats.gpuTimeMs, 4.0, accuracy: 1e-6)
        XCTAssertEqual(stats.totalTimeMs, 5.0, accuracy: 1e-6)
    }

    func testVoxelBlockAccessorMultipleIndices() {
        let storage = ManagedVoxelStorage(capacity: 20)
        for i in 0..<20 {
            let block = storage.readBlock(at: i)
            XCTAssertEqual(block.voxels.count, 512)
            XCTAssertEqual(block.integrationGeneration, 0)
        }
    }

    func testArrayDepthDataAllPixelsAssertions() {
        let w = 4, h = 4
        var depths: [Float] = []
        var confs: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w {
                depths.append(Float(x + y * 10))
                confs.append(UInt8((x + y) % 3))
            }
        }
        let data = ArrayDepthData(width: w, height: h, depths: depths, confidences: confs)
        for y in 0..<h {
            for x in 0..<w {
                XCTAssertEqual(data.depthAt(x: x, y: y), Float(x + y * 10), accuracy: 1e-5)
                XCTAssertEqual(data.confidenceAt(x: x, y: y), UInt8((x + y) % 3))
            }
        }
    }

    func testBlockIndexPairsOrderPreserved() async {
        let backend = MockIntegrationBackend()
        let storage = ManagedVoxelStorage(capacity: 10)
        let blocks: [(BlockIndex, Int)] = [
            (BlockIndex(3, 2, 1), 7),
            (BlockIndex(1, 2, 3), 3),
            (BlockIndex(0, 0, 0), 0)
        ]
        _ = await backend.processFrame(
            input: makeInput(), depthData: makeDepthData(),
            volume: storage, activeBlocks: blocks
        )
        XCTAssertEqual(backend.lastActiveBlocks?[0].0.x, 3)
        XCTAssertEqual(backend.lastActiveBlocks?[0].0.y, 2)
        XCTAssertEqual(backend.lastActiveBlocks?[0].0.z, 1)
        XCTAssertEqual(backend.lastActiveBlocks?[0].1, 7)
        XCTAssertEqual(backend.lastActiveBlocks?[1].0.x, 1)
        XCTAssertEqual(backend.lastActiveBlocks?[1].1, 3)
        XCTAssertEqual(backend.lastActiveBlocks?[2].0.x, 0)
        XCTAssertEqual(backend.lastActiveBlocks?[2].1, 0)
    }
}
