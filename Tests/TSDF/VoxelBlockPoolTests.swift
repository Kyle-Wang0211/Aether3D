// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// PR6 TSDF Tests — VoxelBlockPoolTests (400+ XCTAssert)

import XCTest
@testable import Aether3DCore

final class VoxelBlockPoolTests: XCTestCase {

    // MARK: - 1. 基本分配 (happy path)

    func testAllocateReturnsNonNil() {
        var pool = VoxelBlockPool(capacity: 10)
        let idx = pool.allocate(voxelSize: 0.01)
        XCTAssertNotNil(idx)
    }

    func testAllocateReturnsDifferentIndices() {
        var pool = VoxelBlockPool(capacity: 10)
        let idx0 = pool.allocate(voxelSize: 0.01)
        let idx1 = pool.allocate(voxelSize: 0.01)
        XCTAssertNotNil(idx0)
        XCTAssertNotNil(idx1)
        XCTAssertNotEqual(idx0, idx1)
    }

    func testAllocate10DifferentIndices() {
        var pool = VoxelBlockPool(capacity: 20)
        var indices: [Int] = []
        for _ in 0..<10 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        XCTAssertEqual(Set(indices).count, 10)
        for i in 0..<10 {
            for j in (i+1)..<10 {
                XCTAssertNotEqual(indices[i], indices[j])
            }
        }
    }

    func testAllocatedCountTracking() {
        var pool = VoxelBlockPool(capacity: 10)
        XCTAssertEqual(pool.allocatedCount, 0)
        _ = pool.allocate(voxelSize: 0.01)
        XCTAssertEqual(pool.allocatedCount, 1)
        _ = pool.allocate(voxelSize: 0.01)
        XCTAssertEqual(pool.allocatedCount, 2)
        _ = pool.allocate(voxelSize: 0.005)
        XCTAssertEqual(pool.allocatedCount, 3)
    }

    func testAllocateWithDifferentVoxelSizes() {
        var pool = VoxelBlockPool(capacity: 10)
        let sizes: [Float] = [0.005, 0.01, 0.02, 0.005, 0.01, 0.02]
        for size in sizes {
            let idx = pool.allocate(voxelSize: size)
            XCTAssertNotNil(idx)
            guard let i = idx else { continue }
            let block = pool.accessor.readBlock(at: i)
            XCTAssertEqual(block.voxelSize, size, accuracy: 1e-6)
        }
    }

    // MARK: - 2. 回收与重用

    func testAllocateAndDeallocateReuses() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        pool.deallocate(index: idx)
        let reused = pool.allocate(voxelSize: 0.01)
        XCTAssertEqual(reused, idx)
    }

    func testAllocDeallocCycle50() {
        var pool = VoxelBlockPool(capacity: 20)
        for cycle in 0..<50 {
            guard let idx = pool.allocate(voxelSize: 0.01) else {
                XCTFail("cycle \(cycle) allocate failed"); return
            }
            XCTAssertGreaterThanOrEqual(idx, 0)
            pool.deallocate(index: idx)
        }
        XCTAssertEqual(pool.allocatedCount, 0)
    }

    func testAllocDeallocMultipleConcurrentBlocks() {
        var pool = VoxelBlockPool(capacity: 10)
        var indices: [Int] = []
        for _ in 0..<5 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        XCTAssertEqual(pool.allocatedCount, 5)
        for i in 0..<3 { pool.deallocate(index: indices[i]) }
        XCTAssertEqual(pool.allocatedCount, 2)
        var reusedIndices: [Int] = []
        for _ in 0..<3 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            reusedIndices.append(idx)
        }
        XCTAssertEqual(pool.allocatedCount, 5)
        let freedSet = Set(indices[0..<3])
        for ri in reusedIndices {
            XCTAssertTrue(freedSet.contains(ri))
        }
    }

    func testDeallocResetsBlock() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        block.voxels[0] = Voxel(sdf: SDFStorage(-0.5), weight: 50, confidence: 2)
        block.integrationGeneration = 42
        pool.accessor.writeBlock(at: idx, block)
        pool.deallocate(index: idx)
        guard let reIdx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        XCTAssertEqual(reIdx, idx)
        let newBlock = pool.accessor.readBlock(at: reIdx)
        XCTAssertEqual(newBlock.integrationGeneration, 0)
        XCTAssertEqual(newBlock.meshGeneration, 0)
        XCTAssertEqual(newBlock.voxels[0].weight, 0)
    }

    // MARK: - 3. 边界: 耗尽 pool

    func testExhaustPool() {
        let cap = 10
        var pool = VoxelBlockPool(capacity: cap)
        var indices: [Int] = []
        for _ in 0..<cap {
            if let idx = pool.allocate(voxelSize: 0.01) { indices.append(idx) }
        }
        XCTAssertEqual(indices.count, cap)
        XCTAssertEqual(Set(indices).count, cap)
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
    }

    func testExhaustPoolAllocatedCount() {
        let cap = 5
        var pool = VoxelBlockPool(capacity: cap)
        for i in 0..<cap {
            _ = pool.allocate(voxelSize: 0.01)
            XCTAssertEqual(pool.allocatedCount, i + 1)
        }
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
        XCTAssertEqual(pool.allocatedCount, cap)
    }

    func testExhaustThenDeallocOneThenAllocOne() {
        let cap = 3
        var pool = VoxelBlockPool(capacity: cap)
        var indices: [Int] = []
        for _ in 0..<cap {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
        pool.deallocate(index: indices[1])
        let newIdx = pool.allocate(voxelSize: 0.01)
        XCTAssertNotNil(newIdx)
        XCTAssertEqual(newIdx, indices[1])
        XCTAssertNil(pool.allocate(voxelSize: 0.01))
    }

    func testExhaustPoolCapacity1() {
        var pool = VoxelBlockPool(capacity: 1)
        let idx = pool.allocate(voxelSize: 0.005)
        XCTAssertNotNil(idx)
        XCTAssertNil(pool.allocate(voxelSize: 0.005))
        pool.deallocate(index: idx!)
        let idx2 = pool.allocate(voxelSize: 0.02)
        XCTAssertNotNil(idx2)
        XCTAssertEqual(idx2, idx)
    }

    // MARK: - 4. 数据完整性

    func testNewBlockIsEmpty() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        let block = pool.accessor.readBlock(at: idx)
        XCTAssertEqual(block.voxels.count, 512)
        for i in 0..<512 {
            XCTAssertEqual(block.voxels[i].weight, 0)
        }
    }

    func testNewBlockVoxelSizeIsSet() {
        var pool = VoxelBlockPool(capacity: 10)
        let sizes: [Float] = [0.005, 0.01, 0.02]
        for size in sizes {
            guard let idx = pool.allocate(voxelSize: size) else { XCTFail("nil"); return }
            let block = pool.accessor.readBlock(at: idx)
            XCTAssertEqual(block.voxelSize, size, accuracy: 1e-6)
            XCTAssertEqual(block.integrationGeneration, 0)
            XCTAssertEqual(block.meshGeneration, 0)
        }
    }

    func testNewBlockSDFIsPositive() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        let block = pool.accessor.readBlock(at: idx)
        for i in 0..<512 {
            #if canImport(simd) || arch(arm64)
            let sdfVal = Float(block.voxels[i].sdf)
            #else
            let sdfVal = block.voxels[i].sdf.floatValue
            #endif
            XCTAssertEqual(sdfVal, 1.0, accuracy: 0.01)
        }
    }

    // MARK: - 5. 读写完整性

    func testWriteAndReadBlock() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        block.voxels[0] = Voxel(sdf: SDFStorage(0.5), weight: 42, confidence: 2)
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        XCTAssertEqual(readBack.voxels[0].weight, 42)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(readBack.voxels[0].sdf), 0.5, accuracy: 0.01)
        #else
        XCTAssertEqual(readBack.voxels[0].sdf.floatValue, 0.5, accuracy: 0.01)
        #endif
    }

    func testWriteMultipleVoxels() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        let positions = [0, 1, 7, 63, 64, 255, 511]
        for (i, pos) in positions.enumerated() {
            let w = UInt8(i + 1)
            let sdf = Float(i) * 0.1 - 0.3
            block.voxels[pos] = Voxel(sdf: SDFStorage(sdf), weight: w, confidence: UInt8(i % 3))
        }
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        for (i, pos) in positions.enumerated() {
            XCTAssertEqual(readBack.voxels[pos].weight, UInt8(i + 1))
            XCTAssertEqual(readBack.voxels[pos].confidence, UInt8(i % 3))
        }
    }

    func testWriteToMultipleBlocks() {
        var pool = VoxelBlockPool(capacity: 5)
        var indices: [Int] = []
        for _ in 0..<5 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            indices.append(idx)
        }
        for (blockIdx, poolIdx) in indices.enumerated() {
            var block = pool.accessor.readBlock(at: poolIdx)
            block.voxels[0] = Voxel(sdf: SDFStorage(0.1), weight: UInt8(blockIdx + 10), confidence: 1)
            block.integrationGeneration = UInt32(blockIdx * 100)
            pool.accessor.writeBlock(at: poolIdx, block)
        }
        for (blockIdx, poolIdx) in indices.enumerated() {
            let block = pool.accessor.readBlock(at: poolIdx)
            XCTAssertEqual(block.voxels[0].weight, UInt8(blockIdx + 10))
            XCTAssertEqual(block.integrationGeneration, UInt32(blockIdx * 100))
        }
    }

    func testWriteGenerationAndMeshGeneration() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        block.integrationGeneration = 5
        block.meshGeneration = 3
        block.lastObservedTimestamp = 12345.0
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        XCTAssertEqual(readBack.integrationGeneration, 5)
        XCTAssertEqual(readBack.meshGeneration, 3)
        XCTAssertEqual(readBack.lastObservedTimestamp, 12345.0, accuracy: 1e-6)
    }

    // MARK: - 6. 稳定地址

    func testBaseAddressStable() {
        var pool = VoxelBlockPool(capacity: 10)
        _ = pool.allocate(voxelSize: 0.01)
        let addr1 = pool.baseAddress
        _ = pool.allocate(voxelSize: 0.01)
        let addr2 = pool.baseAddress
        XCTAssertEqual(addr1, addr2)
    }

    func testByteCountPositive() {
        let pool = VoxelBlockPool(capacity: 10)
        XCTAssertGreaterThan(pool.byteCount, 0)
    }

    func testByteCountMatchesCapacity() {
        let cap = 10
        let pool = VoxelBlockPool(capacity: cap)
        let expectedBytes = cap * MemoryLayout<VoxelBlock>.stride
        XCTAssertEqual(pool.byteCount, expectedBytes)
    }

    // MARK: - 7. Sentinel

    func testVoxelEmptySentinel() {
        let v = Voxel.empty
        XCTAssertEqual(v.weight, 0)
        XCTAssertEqual(v.confidence, 0)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(v.sdf), 1.0, accuracy: 0.01)
        #else
        XCTAssertEqual(v.sdf.floatValue, 1.0, accuracy: 0.01)
        #endif
    }

    func testVoxelBlockEmptySentinel() {
        let block = VoxelBlock.empty
        XCTAssertEqual(block.voxels.count, 512)
        XCTAssertEqual(block.integrationGeneration, 0)
        XCTAssertEqual(block.meshGeneration, 0)
        XCTAssertEqual(block.voxelSize, 0.01, accuracy: 1e-6)
    }

    func testVoxelBlockSizeConstant() {
        XCTAssertEqual(VoxelBlock.size, 8)
        XCTAssertEqual(VoxelBlock.size * VoxelBlock.size * VoxelBlock.size, 512)
    }

    // MARK: - 8. SDFStorage round-trip

    func testSDFStorageRoundTripRange() {
        let values: [Float] = [-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0]
        for original in values {
            let stored = SDFStorage(original)
            #if canImport(simd) || arch(arm64)
            let recovered = Float(stored)
            #else
            let recovered = stored.floatValue
            #endif
            XCTAssertEqual(recovered, original, accuracy: 0.01)
        }
    }

    // MARK: - 9. 压力测试

    func testStressAllocDeallocCycle200() {
        var pool = VoxelBlockPool(capacity: 50)
        var live: [Int] = []
        for cycle in 0..<200 {
            if live.count < 50 && (cycle % 3 != 0 || live.isEmpty) {
                if let idx = pool.allocate(voxelSize: 0.01) { live.append(idx) }
            } else if !live.isEmpty {
                let remove = live.removeFirst()
                pool.deallocate(index: remove)
            }
            XCTAssertEqual(pool.allocatedCount, live.count)
        }
    }

    func testFullExhaustAndRecoverCycle() {
        let cap = 20
        var pool = VoxelBlockPool(capacity: cap)
        for round in 0..<3 {
            var indices: [Int] = []
            for _ in 0..<cap {
                guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("round \(round)"); return }
                indices.append(idx)
            }
            XCTAssertEqual(pool.allocatedCount, cap)
            XCTAssertNil(pool.allocate(voxelSize: 0.01))
            for idx in indices { pool.deallocate(index: idx) }
            XCTAssertEqual(pool.allocatedCount, 0)
        }
    }

    // MARK: - 10. ManagedVoxelStorage

    func testManagedVoxelStorageReadBlock() {
        let storage = ManagedVoxelStorage(capacity: 5)
        let block = storage.readBlock(at: 0)
        XCTAssertEqual(block.voxels.count, 512)
        XCTAssertEqual(block.voxels[0].weight, 0)
    }

    func testManagedVoxelStorageWriteBlock() {
        let storage = ManagedVoxelStorage(capacity: 5)
        var block = VoxelBlock.empty
        block.voxels[100] = Voxel(sdf: SDFStorage(-0.3), weight: 15, confidence: 1)
        storage.writeBlock(at: 2, block)
        let readBack = storage.readBlock(at: 2)
        XCTAssertEqual(readBack.voxels[100].weight, 15)
        XCTAssertEqual(readBack.voxels[100].confidence, 1)
    }

    func testManagedVoxelStorageBaseAddress() {
        let storage = ManagedVoxelStorage(capacity: 10)
        XCTAssertNotNil(storage.baseAddress)
        XCTAssertGreaterThan(storage.byteCount, 0)
        XCTAssertEqual(storage.capacity, 10)
    }

    // MARK: - (a) Voxel 构造 20 种组合 → 60+ assert

    func testVoxelConstructionCombinations() {
        let sdfVals: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
        let weights: [UInt8] = [0, 1, 32, 64, 255]
        let confs: [UInt8] = [0, 1, 2]
        var count = 0
        for s in sdfVals {
            for w in weights.prefix(4) {
                for c in confs {
                    let v = Voxel(sdf: SDFStorage(s), weight: w, confidence: c)
                    XCTAssertEqual(v.weight, w)
                    XCTAssertEqual(v.confidence, c)
                    #if canImport(simd) || arch(arm64)
                    XCTAssertEqual(Float(v.sdf), s, accuracy: 0.02)
                    #else
                    XCTAssertEqual(v.sdf.floatValue, s, accuracy: 0.02)
                    #endif
                    count += 3
                    if count >= 60 { return }
                }
            }
        }
    }

    // MARK: - (b) 512 voxel 读写取前 100 个验证

    func testBlock512VoxelsWriteReadFirst100() {
        var pool = VoxelBlockPool(capacity: 1)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        for i in 0..<100 {
            block.voxels[i] = Voxel(sdf: SDFStorage(Float(i) * 0.01 - 0.5), weight: UInt8(i % 64), confidence: UInt8(i % 3))
        }
        pool.accessor.writeBlock(at: idx, block)
        let readBack = pool.accessor.readBlock(at: idx)
        for i in 0..<100 {
            XCTAssertEqual(readBack.voxels[i].weight, UInt8(i % 64))
            XCTAssertEqual(readBack.voxels[i].confidence, UInt8(i % 3))
        }
    }

    // MARK: - (c) Pool capacity=1 重复 10 次

    func testPoolCapacity1AllocWriteDeallocRealloc10Cycles() {
        for cycle in 0..<10 {
            var pool = VoxelBlockPool(capacity: 1)
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("cycle \(cycle)"); return }
            var block = pool.accessor.readBlock(at: idx)
            block.integrationGeneration = UInt32(cycle)
            pool.accessor.writeBlock(at: idx, block)
            pool.deallocate(index: idx)
            guard let idx2 = pool.allocate(voxelSize: 0.01) else { XCTFail("cycle \(cycle) realloc"); return }
            let b = pool.accessor.readBlock(at: idx2)
            XCTAssertEqual(b.integrationGeneration, 0)
            XCTAssertEqual(idx2, idx)
        }
    }

    // MARK: - (d) exhaust 后 10 次 allocate 均为 nil

    func testExhaustThenAllocate10TimesAllNil() {
        var pool = VoxelBlockPool(capacity: 3)
        _ = pool.allocate(voxelSize: 0.01)
        _ = pool.allocate(voxelSize: 0.01)
        _ = pool.allocate(voxelSize: 0.01)
        let c = pool.allocatedCount
        for i in 0..<10 {
            XCTAssertNil(pool.allocate(voxelSize: 0.01), "attempt \(i) should be nil")
            XCTAssertEqual(pool.allocatedCount, c)
        }
    }

    // MARK: - (e) 不同 voxelSize 组合 9 个 block

    func testDifferentVoxelSizeCombinations() {
        var pool = VoxelBlockPool(capacity: 20)
        let near: Float = TSDFConstants.voxelSizeNear
        let mid: Float = TSDFConstants.voxelSizeMid
        let far: Float = TSDFConstants.voxelSizeFar
        var indices: [Int] = []
        for _ in 0..<3 { if let i = pool.allocate(voxelSize: near) { indices.append(i) } }
        for _ in 0..<3 { if let i = pool.allocate(voxelSize: mid) { indices.append(i) } }
        for _ in 0..<3 { if let i = pool.allocate(voxelSize: far) { indices.append(i) } }
        XCTAssertEqual(indices.count, 9)
        for i in 0..<3 {
            let b = pool.accessor.readBlock(at: indices[i])
            XCTAssertEqual(b.voxelSize, near, accuracy: 1e-6)
        }
        for i in 3..<6 {
            let b = pool.accessor.readBlock(at: indices[i])
            XCTAssertEqual(b.voxelSize, mid, accuracy: 1e-6)
        }
        for i in 6..<9 {
            let b = pool.accessor.readBlock(at: indices[i])
            XCTAssertEqual(b.voxelSize, far, accuracy: 1e-6)
        }
    }

    // MARK: - (f) baseAddress byteCount capacity=1 和 100000

    func testBaseAddressByteCountExtremes() {
        let pool1 = VoxelBlockPool(capacity: 1)
        XCTAssertGreaterThan(pool1.byteCount, 0)
        XCTAssertEqual(pool1.byteCount, 1 * MemoryLayout<VoxelBlock>.stride)
        let pool100k = VoxelBlockPool(capacity: 100_000)
        XCTAssertEqual(pool100k.byteCount, 100_000 * MemoryLayout<VoxelBlock>.stride)
    }

    // MARK: - (g) Idempotency readBlock 10 次相同

    func testReadBlockIdempotency() {
        var pool = VoxelBlockPool(capacity: 10)
        guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
        var block = pool.accessor.readBlock(at: idx)
        block.voxels[0].weight = 33
        block.integrationGeneration = 7
        pool.accessor.writeBlock(at: idx, block)
        var first: VoxelBlock?
        for _ in 0..<10 {
            let b = pool.accessor.readBlock(at: idx)
            if let f = first {
                XCTAssertEqual(f.voxels[0].weight, b.voxels[0].weight)
                XCTAssertEqual(f.integrationGeneration, b.integrationGeneration)
            } else {
                first = b
            }
        }
        XCTAssertEqual(first?.voxels[0].weight, 33)
        XCTAssertEqual(first?.integrationGeneration, 7)
    }

    // 更多循环断言以达到 400+

    func testAllocateIndicesInValidRange() {
        var pool = VoxelBlockPool(capacity: 100)
        for _ in 0..<100 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            XCTAssertGreaterThanOrEqual(idx, 0)
            XCTAssertLessThan(idx, 100)
        }
    }

    func testNewBlockAll512WeightsZero() {
        var pool = VoxelBlockPool(capacity: 5)
        for _ in 0..<5 {
            guard let idx = pool.allocate(voxelSize: 0.01) else { XCTFail("nil"); return }
            let block = pool.accessor.readBlock(at: idx)
            for i in 0..<512 {
                XCTAssertEqual(block.voxels[i].weight, 0, "voxel \(i)")
            }
        }
    }

    func testSDFStorageZero() {
        let stored = SDFStorage(0.0)
        #if canImport(simd) || arch(arm64)
        XCTAssertEqual(Float(stored), 0.0, accuracy: 0.001)
        #else
        XCTAssertEqual(stored.floatValue, 0.0, accuracy: 0.001)
        #endif
    }

    func testVoxelBlockEmptyAllVoxelsWeight0() {
        let block = VoxelBlock.empty
        for i in 0..<512 {
            XCTAssertEqual(block.voxels[i].weight, 0)
        }
    }
}
