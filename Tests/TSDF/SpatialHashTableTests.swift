// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// PR6 TSDF Tests — SpatialHashTableTests (BUG-4/BUG-5 regression + CRUD)

import XCTest
@testable import Aether3DCore

final class SpatialHashTableTests: XCTestCase {

    func testInsertAndLookup() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(1, 2, 3)
        let poolIdx = table.insertOrGet(key: key, voxelSize: 0.004)
        XCTAssertNotNil(poolIdx)
        XCTAssertEqual(table.lookup(key: key), poolIdx)
    }

    func testLookupMissingNil() {
        let table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        XCTAssertNil(table.lookup(key: BlockIndex(99, 99, 99)))
    }

    func testIdempotentInsert() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(5, 5, 5)
        let idx1 = table.insertOrGet(key: key, voxelSize: 0.004)
        let idx2 = table.insertOrGet(key: key, voxelSize: 0.004)
        XCTAssertEqual(idx1, idx2)
    }

    func testInsert100UniqueKeys() {
        var table = SpatialHashTable(initialSize: 256, poolCapacity: 256)
        var indices: [Int] = []
        for i: Int32 in 0..<100 {
            if let idx = table.insertOrGet(key: BlockIndex(i, i &* 7, i &* 13), voxelSize: 0.01) {
                indices.append(idx)
            }
        }
        XCTAssertEqual(indices.count, 100)
        XCTAssertEqual(Set(indices).count, 100)
        for i: Int32 in 0..<100 {
            XCTAssertNotNil(table.lookup(key: BlockIndex(i, i &* 7, i &* 13)))
        }
    }

    func testRemoveExisting() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(1, 1, 1)
        _ = table.insertOrGet(key: key, voxelSize: 0.004)
        table.remove(key: key)
        XCTAssertNil(table.lookup(key: key))
    }

    func testRemoveNonexistent() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        table.remove(key: BlockIndex(99, 99, 99))
    }

    /// BUG-5 regression: remove must not break linear probing chain
    func testRemoveMiddlePreservesChain() {
        var table = SpatialHashTable(initialSize: 16, poolCapacity: 32)
        let keys = (0..<10).map { BlockIndex(Int32($0), Int32($0), Int32($0)) }
        var poolIndices: [BlockIndex: Int] = [:]
        for key in keys {
            if let idx = table.insertOrGet(key: key, voxelSize: 0.004) { poolIndices[key] = idx }
        }
        for i in stride(from: 0, to: 10, by: 2) {
            table.remove(key: keys[i])
        }
        for i in stride(from: 1, to: 10, by: 2) {
            XCTAssertEqual(table.lookup(key: keys[i]), poolIndices[keys[i]])
        }
    }

    /// BUG-4 regression: rehash must preserve pool indices (no re-allocate)
    func testRehashPreservesPoolIndices() {
        var table = SpatialHashTable(initialSize: 16, poolCapacity: 64)
        var original: [BlockIndex: Int] = [:]
        for i: Int32 in 0..<12 {
            let key = BlockIndex(i, 0, 0)
            if let idx = table.insertOrGet(key: key, voxelSize: 0.004) { original[key] = idx }
        }
        for (key, expectedIdx) in original {
            XCTAssertEqual(table.lookup(key: key), expectedIdx)
        }
    }

    func testNegativeCoordinates() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        for x: Int32 in [-100, -1, 0, 1, 100] {
            for y: Int32 in [-50, 0, 50] {
                let key = BlockIndex(x, y, 0)
                let idx = table.insertOrGet(key: key, voxelSize: 0.01)
                XCTAssertNotNil(idx)
                XCTAssertEqual(table.lookup(key: key), idx)
            }
        }
    }

    func testForEachBlockCountMatchesCount() {
        var table = SpatialHashTable(initialSize: 128, poolCapacity: 128)
        let n = 30
        for i: Int32 in 0..<Int32(n) { _ = table.insertOrGet(key: BlockIndex(i, 0, 0), voxelSize: 0.01) }
        var visited = 0
        table.forEachBlock { _, _, _ in visited += 1 }
        XCTAssertEqual(visited, n)
        XCTAssertEqual(table.count, n)
    }

    func testGetAllBlocksCount() {
        var table = SpatialHashTable(initialSize: 128, poolCapacity: 128)
        for i: Int32 in 0..<25 { _ = table.insertOrGet(key: BlockIndex(i, 0, 0), voxelSize: 0.01) }
        XCTAssertEqual(table.getAllBlocks().count, 25)
    }

    func testUpdateBlockAndReadBack() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        guard let idx = table.insertOrGet(key: BlockIndex(0,0,0), voxelSize: 0.01) else { XCTFail("nil"); return }
        table.updateBlock(at: idx) { $0.integrationGeneration = 42; $0.meshGeneration = 10 }
        let b = table.readBlock(at: idx)
        XCTAssertEqual(b.integrationGeneration, 42)
        XCTAssertEqual(b.meshGeneration, 10)
    }

    /// 扩充断言：插入 100 个 key 后逐条 lookup 并验证 poolIndex 与 readBlock
    func testInsert100KeysLookupAndReadBlock() {
        var table = SpatialHashTable(initialSize: 256, poolCapacity: 256)
        var keyToPool: [(BlockIndex, Int)] = []
        for i: Int32 in 0..<100 {
            let key = BlockIndex(i, i &* 2, i &* 3)
            guard let poolIdx = table.insertOrGet(key: key, voxelSize: 0.01) else { XCTFail("i=\(i)"); return }
            keyToPool.append((key, poolIdx))
        }
        XCTAssertEqual(table.count, 100)
        for (key, expectedPool) in keyToPool {
            let looked = table.lookup(key: key)
            XCTAssertNotNil(looked)
            XCTAssertEqual(looked, expectedPool)
            let block = table.readBlock(at: expectedPool)
            XCTAssertEqual(block.voxels.count, 512)
        }
    }
}
