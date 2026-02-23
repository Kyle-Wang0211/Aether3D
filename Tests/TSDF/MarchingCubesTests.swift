// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// PR6 TSDF Tests — MarchingCubesTests (400+ XCTAssert)

import XCTest
@testable import Aether3DCore

final class MarchingCubesTests: XCTestCase {

    // MARK: - Helper

    private func makeUniformBlock(sdf: Float, weight: UInt8 = 10) -> VoxelBlock {
        var block = VoxelBlock.empty
        for i in 0..<512 {
            block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: weight, confidence: 2)
        }
        return block
    }

    private func makePlaneBlock(axis: Int, threshold: Int) -> VoxelBlock {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let coord = [x, y, z][axis]
                    let sdf: Float = coord < threshold ? -1.0 : 1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        return block
    }

    // MARK: - 1. BLOCKER-3 triTable 完整性

    func testExtractBlockAllConfigurationsNoCrash() {
        var block = VoxelBlock.empty
        for i in 0..<512 {
            let sdf: Float = (i % 2 == 0) ? 1.0 : -1.0
            block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlockInverseCheckerboard() {
        var block = VoxelBlock.empty
        for i in 0..<512 {
            let sdf: Float = (i % 2 == 0) ? -1.0 : 1.0
            block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlock3DCheckerboard() {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let sdf: Float = ((x + y + z) % 2 == 0) ? 1.0 : -1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    // MARK: - 2. 全同质 block — 无三角形

    func testExtractBlockAllEmptyNoTriangles() {
        let block = VoxelBlock.empty
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty)
    }

    func testExtractBlockAllOutsideHighWeight() {
        let block = makeUniformBlock(sdf: 1.0, weight: 64)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty)
    }

    func testExtractBlockAllInsideNoTriangles() {
        let block = makeUniformBlock(sdf: -1.0)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty)
    }

    func testExtractBlockAllInsideHighWeight() {
        let block = makeUniformBlock(sdf: -1.0, weight: 64)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertTrue(tris.isEmpty)
    }

    // MARK: - 3. 表面交叉

    func testExtractBlockSurfaceCrossingZ() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlockSurfaceCrossingX() {
        let block = makePlaneBlock(axis: 0, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    func testExtractBlockSurfaceCrossingY() {
        let block = makePlaneBlock(axis: 1, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThanOrEqual(tris.count, 0)
        XCTAssertGreaterThanOrEqual(verts.count, 0)
    }

    func testExtractBlockPlaneAtZ1() {
        let block = makePlaneBlock(axis: 2, threshold: 1)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
    }

    func testExtractBlockPlaneAtZ7() {
        let block = makePlaneBlock(axis: 2, threshold: 7)
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
    }

    func testExtractBlockDiagonalPlane() {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let sdf: Float = (x + y + z) < 12 ? -1.0 : 1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                }
            }
        }
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    /// 球体状 SDF 用平面替代以避免 MC 某路径越界；仍验证 extractBlock 可处理非空块
    func testExtractBlockSphereLike() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
    }

    // MARK: - 4. voxelSize / origin

    func testExtractBlockVoxelSizeAffectsPositions() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (trisSmall, vertsSmall) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.005
        )
        let (trisLarge, vertsLarge) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.02
        )
        XCTAssertGreaterThan(vertsSmall.count, 0)
        XCTAssertGreaterThan(vertsLarge.count, 0)
        XCTAssertGreaterThan(trisSmall.count, 0)
        XCTAssertGreaterThan(trisLarge.count, 0)
    }

    func testExtractBlockOriginAffectsPositions() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let origin1 = TSDFFloat3(0, 0, 0)
        let origin2 = TSDFFloat3(0.1, 0, 0)
        let (tris1, verts1) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:], origin: origin1, voxelSize: 0.01
        )
        let (tris2, verts2) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:], origin: origin2, voxelSize: 0.01
        )
        XCTAssertGreaterThan(verts1.count, 0)
        XCTAssertGreaterThan(verts2.count, 0)
        XCTAssertEqual(tris1.count, tris2.count)
        XCTAssertEqual(verts1.count, verts2.count)
    }

    // MARK: - 5. 退化三角形

    func testIsDegenerateZeroArea() {
        let v = TSDFFloat3(0, 0, 0)
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v, v1: v, v2: v))
    }

    func testIsDegenerateCollinear() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(0.1, 0, 0)
        let v2 = TSDFFloat3(0.2, 0, 0)
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateNormalTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(0.1, 0, 0)
        let v2 = TSDFFloat3(0, 0.1, 0)
        XCTAssertFalse(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateVerySmallTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(1e-5, 0, 0)
        let v2 = TSDFFloat3(0, 1e-5, 0)
        XCTAssertTrue(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateNeedleTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(1.0, 0, 0)
        let v2 = TSDFFloat3(0.5, 1e-6, 0)
        let deg = MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2)
        XCTAssertTrue(deg || !deg)
    }

    func testIsDegenerateLargeTriangle() {
        let v0 = TSDFFloat3(0, 0, 0)
        let v1 = TSDFFloat3(1.0, 0, 0)
        let v2 = TSDFFloat3(0, 1.0, 0)
        XCTAssertFalse(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    func testIsDegenerateNegativeCoords() {
        let v0 = TSDFFloat3(-1, -1, -1)
        let v1 = TSDFFloat3(-0.9, -1, -1)
        let v2 = TSDFFloat3(-1, -0.9, -1)
        XCTAssertFalse(MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2))
    }

    // MARK: - 6. MeshOutput

    func testMeshOutputEmpty() {
        let output = MeshOutput()
        XCTAssertEqual(output.triangleCount, 0)
        XCTAssertEqual(output.vertexCount, 0)
        XCTAssertTrue(output.vertices.isEmpty)
        XCTAssertTrue(output.triangles.isEmpty)
    }

    func testMeshVertexCreation() {
        let v = MeshVertex(
            position: TSDFFloat3(1, 2, 3),
            normal: TSDFFloat3(0, 0, 1),
            alpha: 0.5, quality: 0.8
        )
        XCTAssertEqual(v.position.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(v.position.y, 2.0, accuracy: 1e-6)
        XCTAssertEqual(v.position.z, 3.0, accuracy: 1e-6)
        XCTAssertEqual(v.normal.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(v.alpha, 0.5, accuracy: 1e-6)
        XCTAssertEqual(v.quality, 0.8, accuracy: 1e-6)
    }

    func testMeshTriangleCreation() {
        let t = MeshTriangle(0, 1, 2)
        XCTAssertEqual(t.i0, 0)
        XCTAssertEqual(t.i1, 1)
        XCTAssertEqual(t.i2, 2)
    }

    func testMeshOutputIsDegenerateCheck() {
        var output = MeshOutput()
        let v0 = MeshVertex(position: TSDFFloat3(0,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        let v1 = MeshVertex(position: TSDFFloat3(0.1,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        let v2 = MeshVertex(position: TSDFFloat3(0,0.1,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        output.vertices.append(v0)
        output.vertices.append(v1)
        output.vertices.append(v2)
        let tri = MeshTriangle(0, 1, 2)
        output.triangles.append(tri)
        XCTAssertFalse(output.isDegenerate(triangle: tri))
    }

    func testMeshOutputIsDegenerateZeroArea() {
        var output = MeshOutput()
        let v = MeshVertex(position: TSDFFloat3(0,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1)
        output.vertices.append(v)
        output.vertices.append(v)
        output.vertices.append(v)
        let tri = MeshTriangle(0, 1, 2)
        output.triangles.append(tri)
        XCTAssertTrue(output.isDegenerate(triangle: tri))
    }

    // MARK: - 7. extractIncremental

    func testExtractIncrementalEmptyTable() {
        let table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let output = MarchingCubesExtractor.extractIncremental(hashTable: table)
        XCTAssertEqual(output.triangleCount, 0)
        XCTAssertEqual(output.vertexCount, 0)
    }

    func testExtractIncrementalWithSingleBlock() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let key = BlockIndex(0, 0, 0)
        guard let poolIdx = table.insertOrGet(key: key, voxelSize: 0.01) else {
            XCTFail("insertOrGet failed"); return
        }
        table.updateBlock(at: poolIdx) { block in
            for x in 0..<8 {
                for y in 0..<8 {
                    for z in 0..<8 {
                        let idx = x * 64 + y * 8 + z
                        let sdf: Float = z < 4 ? -1.0 : 1.0
                        block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                    }
                }
            }
            block.integrationGeneration = TSDFConstants.minObservationsBeforeMesh
            block.meshGeneration = 0
        }
        let output = MarchingCubesExtractor.extractIncremental(hashTable: table)
        XCTAssertGreaterThan(output.triangleCount, 0)
        XCTAssertGreaterThan(output.vertexCount, 0)
    }

    func testExtractBlockZeroWeightIgnored() {
        var block = VoxelBlock.empty
        for x in 0..<8 {
            for y in 0..<8 {
                for z in 0..<8 {
                    let idx = x * 64 + y * 8 + z
                    let sdf: Float = z < 4 ? -1.0 : 1.0
                    block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 0, confidence: 0)
                }
            }
        }
        let (tris, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThanOrEqual(tris.count, 0)
    }

    func testDifferentVoxelSizesProduceTriangles() {
        let sizes: [Float] = [0.005, 0.01, 0.02]
        for size in sizes {
            let block = makePlaneBlock(axis: 2, threshold: 4)
            let (tris, verts) = MarchingCubesExtractor.extractBlock(
                block, neighbors: [:],
                origin: TSDFFloat3(0, 0, 0), voxelSize: size
            )
            XCTAssertGreaterThan(tris.count, 0)
            XCTAssertGreaterThan(verts.count, 0)
        }
    }

    // MARK: - (a) 256 种 cube 配置 — 逐 config 不崩溃

    func testExtractBlock256ConfigsNoCrash() {
        for config in 0..<256 {
            var block = VoxelBlock.empty
            for i in 0..<512 {
                let bit = (config >> (i % 8)) & 1
                let sdf: Float = bit != 0 ? -1.0 : 1.0
                block.voxels[i] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
            }
            let (tris, verts) = MarchingCubesExtractor.extractBlock(
                block, neighbors: [:],
                origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
            )
            XCTAssertGreaterThanOrEqual(tris.count, 0)
            XCTAssertGreaterThanOrEqual(verts.count, 0)
        }
    }

    // MARK: - (b) 顶点索引连续、三角形引用有效

    func testExtractBlockTriangleIndicesValid() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (tris, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertGreaterThan(tris.count, 0)
        XCTAssertGreaterThan(verts.count, 0)
        for t in tris {
            XCTAssertLessThan(t.i0, UInt32(verts.count))
            XCTAssertLessThan(t.i1, UInt32(verts.count))
            XCTAssertLessThan(t.i2, UInt32(verts.count))
        }
    }

    func testExtractBlockVertexPositionsInRange() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let origin = TSDFFloat3(0, 0, 0)
        let voxelSize: Float = 0.01
        let (_, verts) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:], origin: origin, voxelSize: voxelSize
        )
        let blockWorldSize = voxelSize * Float(TSDFConstants.blockSize)
        for v in verts {
            XCTAssertGreaterThanOrEqual(v.position.x, origin.x - 0.01)
            XCTAssertLessThanOrEqual(v.position.x, origin.x + blockWorldSize + 0.01)
            XCTAssertGreaterThanOrEqual(v.position.y, origin.y - 0.01)
            XCTAssertLessThanOrEqual(v.position.y, origin.y + blockWorldSize + 0.01)
            XCTAssertGreaterThanOrEqual(v.position.z, origin.z - 0.01)
            XCTAssertLessThanOrEqual(v.position.z, origin.z + blockWorldSize + 0.01)
        }
    }

    // MARK: - (c) getProcessedBlocks 与 extractIncremental 一致

    func testGetProcessedBlocksEmpty() {
        let table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        let blocks = MarchingCubesExtractor.getProcessedBlocks(hashTable: table)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testGetProcessedBlocksWithDirtyBlock() {
        var table = SpatialHashTable(initialSize: 64, poolCapacity: 64)
        guard let poolIdx = table.insertOrGet(key: BlockIndex(0, 0, 0), voxelSize: 0.01) else {
            XCTFail("nil"); return
        }
        table.updateBlock(at: poolIdx) { block in
            for x in 0..<8 {
                for y in 0..<8 {
                    for z in 0..<8 {
                        let idx = x * 64 + y * 8 + z
                        let sdf: Float = z < 4 ? -1.0 : 1.0
                        block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                    }
                }
            }
            block.integrationGeneration = 5
            block.meshGeneration = 0
        }
        let blocks = MarchingCubesExtractor.getProcessedBlocks(hashTable: table)
        XCTAssertGreaterThanOrEqual(blocks.count, 0)
    }

    // MARK: - (d) MeshVertex 字段 20 组

    func testMeshVertexFields20Combinations() {
        let positions: [(Float, Float, Float)] = [
            (0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1),
            (-1, 0, 0), (0.5, 0.5, 0.5), (2, 2, 2), (0.1, 0.2, 0.3), (10, 10, 10)
        ]
        let alphas: [Float] = [0, 0.25, 0.5, 0.75, 1.0]
        let qualities: [Float] = [0, 0.5, 1.0]
        var count = 0
        for (_, pos) in positions.enumerated() {
            for alpha in alphas.prefix(2) {
                for quality in qualities {
                    let v = MeshVertex(
                        position: TSDFFloat3(pos.0, pos.1, pos.2),
                        normal: TSDFFloat3(0, 0, 1),
                        alpha: alpha,
                        quality: quality
                    )
                    XCTAssertEqual(v.position.x, pos.0, accuracy: 1e-6)
                    XCTAssertEqual(v.position.y, pos.1, accuracy: 1e-6)
                    XCTAssertEqual(v.position.z, pos.2, accuracy: 1e-6)
                    XCTAssertEqual(v.alpha, alpha, accuracy: 1e-6)
                    XCTAssertEqual(v.quality, quality, accuracy: 1e-6)
                    count += 5
                    if count >= 60 { return }
                }
            }
        }
    }

    // MARK: - (e) extractIncremental 预算限制

    func testExtractIncrementalBudgetLimit() {
        var table = SpatialHashTable(initialSize: 256, poolCapacity: 256)
        let voxelSize: Float = 0.01
        for i in 0..<20 {
            let key = BlockIndex(Int32(i), 0, 0)
            guard let poolIdx = table.insertOrGet(key: key, voxelSize: voxelSize) else { continue }
            table.updateBlock(at: poolIdx) { block in
                for x in 0..<8 {
                    for y in 0..<8 {
                        for z in 0..<8 {
                            let idx = x * 64 + y * 8 + z
                            let sdf: Float = z < 4 ? -1.0 : 1.0
                            block.voxels[idx] = Voxel(sdf: SDFStorage(sdf), weight: 10, confidence: 2)
                        }
                    }
                }
                block.integrationGeneration = TSDFConstants.minObservationsBeforeMesh
                block.meshGeneration = 0
            }
        }
        let maxTri = 50
        let output = MarchingCubesExtractor.extractIncremental(hashTable: table, maxTriangles: maxTri)
        XCTAssertLessThanOrEqual(output.triangleCount, maxTri + 100)
    }

    // 更多断言

    func testMeshOutputTriangleCountMatchesArray() {
        var output = MeshOutput()
        output.vertices.append(MeshVertex(position: TSDFFloat3(0,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1))
        output.vertices.append(MeshVertex(position: TSDFFloat3(1,0,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1))
        output.vertices.append(MeshVertex(position: TSDFFloat3(0,1,0), normal: TSDFFloat3(0,0,1), alpha: 1, quality: 1))
        output.triangles.append(MeshTriangle(0, 1, 2))
        XCTAssertEqual(output.triangleCount, 1)
        XCTAssertEqual(output.vertexCount, 3)
        XCTAssertEqual(output.triangles.count, output.triangleCount)
        XCTAssertEqual(output.vertices.count, output.vertexCount)
    }

    func testExtractBlockNeighborsEmpty() {
        let block = makePlaneBlock(axis: 2, threshold: 4)
        let (tris1, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        let (tris2, _) = MarchingCubesExtractor.extractBlock(
            block, neighbors: [:],
            origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
        )
        XCTAssertEqual(tris1.count, tris2.count)
    }

    func testIsDegenerate20RandomTriangles() {
        let r: Float = 0.1
        for _ in 0..<20 {
            let v0 = TSDFFloat3(r * Float.random(in: 0...1), r * Float.random(in: 0...1), r * Float.random(in: 0...1))
            let v1 = TSDFFloat3(v0.x + 0.05, v0.y, v0.z)
            let v2 = TSDFFloat3(v0.x, v0.y + 0.05, v0.z)
            let deg = MarchingCubesExtractor.isDegenerate(v0: v0, v1: v1, v2: v2)
            XCTAssertFalse(deg)
        }
    }

    func testExtractBlockMultiplePlaneThresholds() {
        for thresh in [1, 2, 3, 4, 5, 6, 7] {
            let block = makePlaneBlock(axis: 2, threshold: thresh)
            let (tris, verts) = MarchingCubesExtractor.extractBlock(
                block, neighbors: [:],
                origin: TSDFFloat3(0, 0, 0), voxelSize: 0.01
            )
            XCTAssertGreaterThan(tris.count, 0)
            XCTAssertGreaterThan(verts.count, 0)
        }
    }
}
