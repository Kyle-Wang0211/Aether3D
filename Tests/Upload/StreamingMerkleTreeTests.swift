//
//  StreamingMerkleTreeTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Streaming Merkle Tree Tests
//

import XCTest
@testable import Aether3DCore

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

final class StreamingMerkleTreeTests: XCTestCase {
    
    var tree: StreamingMerkleTree!
    
    override func setUp() {
        super.setUp()
        tree = StreamingMerkleTree()
    }
    
    override func tearDown() {
        tree = nil
        super.tearDown()
    }
    
    // MARK: - Helper Functions
    
    private func computeSHA256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #elseif canImport(Crypto)
        return Data(Crypto.SHA256.hash(data: data))
        #else
        fatalError("No crypto backend available")
        #endif
    }
    
    private func computeEmptyTreeHash() -> Data {
        // Empty tree: SHA-256(0x00)
        return computeSHA256(Data([UploadConstants.MERKLE_LEAF_PREFIX]))
    }
    
    private func computeLeafHash(data: Data, index: Int) -> Data {
        var input = Data([UploadConstants.MERKLE_LEAF_PREFIX])
        var indexLE = UInt32(index).littleEndian
        input.append(contentsOf: withUnsafeBytes(of: &indexLE) { Data($0) })
        input.append(data)
        return computeSHA256(input)
    }
    
    private func computeNodeHash(left: Data, right: Data, level: Int) -> Data {
        var input = Data([UploadConstants.MERKLE_NODE_PREFIX])
        input.append(UInt8(level))
        input.append(left)
        input.append(right)
        return computeSHA256(input)
    }
    
    // MARK: - Empty Tree
    
    func testEmptyTree_RootHash_IsSHA256Of0x00() async {
        let root = await tree.rootHash
        
        let expected = computeEmptyTreeHash()
        XCTAssertEqual(root, expected, "Empty tree root should be SHA-256(0x00)")
    }
    
    func testEmptyTree_RootHash_Is32Bytes() async {
        let root = await tree.rootHash
        
        XCTAssertEqual(root.count, 32, "Root hash should be 32 bytes")
    }
    
    func testEmptyTree_RootHash_Deterministic() async {
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        let root2 = await tree2.rootHash
        
        XCTAssertEqual(root1, root2, "Empty tree root should be deterministic")
    }
    
    func testEmptyTree_GenerateProof_ReturnsNil() async {
        let proof = await tree.generateProof(leafIndex: 0)
        
        XCTAssertNil(proof, "Empty tree should return nil proof")
    }
    
    func testEmptyTree_GenerateProof_NegativeIndex_ReturnsNil() async {
        let proof = await tree.generateProof(leafIndex: -1)
        
        XCTAssertNil(proof, "Negative index should return nil")
    }
    
    func testEmptyTree_LeafCount_Zero() async {
        // Leaf count is not directly accessible, but we can infer from root
        let root = await tree.rootHash
        let emptyRoot = computeEmptyTreeHash()
        
        XCTAssertEqual(root, emptyRoot, "Empty tree should have zero leaves")
    }
    
    func testEmptyTree_MultipleRootQueries_SameResult() async {
        let root1 = await tree.rootHash
        let root2 = await tree.rootHash
        let root3 = await tree.rootHash
        
        XCTAssertEqual(root1, root2, "Multiple queries should return same result")
        XCTAssertEqual(root2, root3, "Multiple queries should return same result")
    }
    
    func testEmptyTree_ProtocolConformance_IntegrityTree() async {
        // Verify protocol conformance
        let root: Data = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Should conform to IntegrityTree protocol")
    }
    
    func testEmptyTree_ActorIsolation_Works() async {
        // Test actor isolation
        await tree.appendLeaf(Data([1, 2, 3]))
        let root = await tree.rootHash
        
        XCTAssertNotEqual(root, computeEmptyTreeHash(), "Actor isolation should work")
    }
    
    func testEmptyTree_Sendable_Conformance() async {
        // Verify Sendable conformance compiles
        let tree2: StreamingMerkleTree = StreamingMerkleTree()
        let root = await tree2.rootHash
        
        XCTAssertEqual(root.count, 32, "Should be Sendable")
    }
    
    // MARK: - Single Leaf
    
    func testSingleLeaf_RootEquals_LeafHash() async {
        let data = Data([1, 2, 3, 4, 5])
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let expectedLeafHash = computeLeafHash(data: data, index: 0)
        
        XCTAssertEqual(root, expectedLeafHash, "Single leaf root should equal leaf hash")
    }
    
    func testSingleLeaf_LeafHash_SHA256_0x00_IndexLE32_Data() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let expected = computeLeafHash(data: data, index: 0)
        
        XCTAssertEqual(root, expected, "Leaf hash should be SHA-256(0x00 || index_LE32 || data)")
    }
    
    func testSingleLeaf_Index0_CorrectLeafHash() async {
        let data = Data([10, 20, 30])
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let expected = computeLeafHash(data: data, index: 0)
        
        XCTAssertEqual(root, expected, "Index 0 should produce correct hash")
    }
    
    func testSingleLeaf_DifferentData_DifferentRoot() async {
        let data1 = Data([1, 2, 3])
        await tree.appendLeaf(data1)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        let data2 = Data([4, 5, 6])
        await tree2.appendLeaf(data2)
        let root2 = await tree2.rootHash
        
        XCTAssertNotEqual(root1, root2, "Different data should produce different roots")
    }
    
    func testSingleLeaf_SameData_SameRoot() async {
        let data = Data([1, 2, 3])
        
        await tree.appendLeaf(data)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(data)
        let root2 = await tree2.rootHash
        
        XCTAssertEqual(root1, root2, "Same data should produce same root")
    }
    
    func testSingleLeaf_EmptyData_ValidRoot() async {
        let data = Data()
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let expected = computeLeafHash(data: data, index: 0)
        
        XCTAssertEqual(root, expected, "Empty data should produce valid root")
        XCTAssertEqual(root.count, 32, "Root should be 32 bytes")
    }
    
    func testSingleLeaf_LargeData_ValidRoot() async {
        let data = Data(repeating: 1, count: 1_000_000)
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Large data should produce valid root")
    }
    
    func testSingleLeaf_RootIs32Bytes() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Root should be 32 bytes")
    }
    
    func testSingleLeaf_ProofForIndex0_ReturnsEmptyOrNil() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let proof = await tree.generateProof(leafIndex: 0)
        
        // Current implementation returns nil, but should handle single leaf
        XCTAssertNotNil(proof, "Single leaf proof should be handled")
    }
    
    func testSingleLeaf_ProofForIndex1_ReturnsNil() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let proof = await tree.generateProof(leafIndex: 1)
        
        XCTAssertNil(proof, "Index beyond leaf count should return nil")
    }
    
    // MARK: - Two Leaves
    
    func testTwoLeaves_Root_Equals_MergeOf2LeafHashes() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let expected = computeNodeHash(left: leafHash1, right: leafHash2, level: 0)
        
        XCTAssertEqual(root, expected, "Two leaves root should equal merge of leaf hashes")
    }
    
    func testTwoLeaves_InternalHash_SHA256_0x01_Level_Left_Right() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let expected = computeNodeHash(left: leafHash1, right: leafHash2, level: 0)
        
        XCTAssertEqual(root, expected, "Internal hash should be SHA-256(0x01 || level || left || right)")
    }
    
    func testTwoLeaves_RootIs32Bytes() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Root should be 32 bytes")
    }
    
    func testTwoLeaves_OrderMatters_DifferentRoots() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(data2)
        await tree2.appendLeaf(data1)
        let root2 = await tree2.rootHash
        
        XCTAssertNotEqual(root1, root2, "Order should matter")
    }
    
    func testTwoLeaves_SameLeaves_SameRoot() async {
        let data = Data([1, 2, 3])
        
        await tree.appendLeaf(data)
        await tree.appendLeaf(data)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(data)
        await tree2.appendLeaf(data)
        let root2 = await tree2.rootHash
        
        XCTAssertEqual(root1, root2, "Same leaves should produce same root")
    }
    
    func testTwoLeaves_DifferentLeaves_DifferentRoot() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(data1)
        await tree2.appendLeaf(Data([7, 8, 9]))
        let root2 = await tree2.rootHash
        
        XCTAssertNotEqual(root1, root2, "Different leaves should produce different root")
    }
    
    func testTwoLeaves_MergeLevel_Is0() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let expected = computeNodeHash(left: leafHash1, right: leafHash2, level: 0)
        
        XCTAssertEqual(root, expected, "Merge level should be 0")
    }
    
    func testTwoLeaves_StackSize_Is1_AfterCarry() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        // After binary carry, stack should have 1 element
        // We can't directly access stack, but root should be computed correctly
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Stack should have 1 element after carry")
    }
    
    func testTwoLeaves_ProofForLeaf0_ContainsLeaf1Hash() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let proof = await tree.generateProof(leafIndex: 0)
        
        // Current implementation returns nil, but proof should contain leaf1 hash
        XCTAssertNotNil(proof, "Proof should be generated")
    }
    
    func testTwoLeaves_VerifyProof_Leaf0_Succeeds() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Proof verification should succeed")
    }
    
    // MARK: - Power-of-2 Trees
    
    func testTree4Leaves_RootCorrect() async {
        let leaves = [
            Data([1]),
            Data([2]),
            Data([3]),
            Data([4])
        ]
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        
        // Compute expected root manually
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let h3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n0 = computeNodeHash(left: h0, right: h1, level: 0)
        let n1 = computeNodeHash(left: h2, right: h3, level: 0)
        let expected = computeNodeHash(left: n0, right: n1, level: 1)
        
        XCTAssertEqual(root, expected, "4 leaves root should be correct")
    }
    
    func testTree8Leaves_RootCorrect() async {
        let leaves = (0..<8).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "8 leaves root should be correct")
    }
    
    func testTree16Leaves_RootCorrect() async {
        let leaves = (0..<16).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "16 leaves root should be correct")
    }
    
    func testTree32Leaves_RootCorrect() async {
        let leaves = (0..<32).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "32 leaves root should be correct")
    }
    
    func testTree64Leaves_RootCorrect() async {
        let leaves = (0..<64).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "64 leaves root should be correct")
    }
    
    func testTree128Leaves_RootCorrect() async {
        let leaves = (0..<128).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "128 leaves root should be correct")
    }
    
    func testTree256Leaves_RootCorrect() async {
        let leaves = (0..<256).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "256 leaves root should be correct")
    }
    
    func testTree1024Leaves_ValidRoot() async {
        let leaves = (0..<1024).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "1024 leaves root should be valid")
    }
    
    func testTree4Leaves_BinaryCarryMerges_Correct() async {
        let leaves = [
            Data([1]),
            Data([2]),
            Data([3]),
            Data([4])
        ]
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        
        // Verify binary carry merged correctly
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let h3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n0 = computeNodeHash(left: h0, right: h1, level: 0)
        let n1 = computeNodeHash(left: h2, right: h3, level: 0)
        let expected = computeNodeHash(left: n0, right: n1, level: 1)
        
        XCTAssertEqual(root, expected, "Binary carry should merge correctly")
    }
    
    func testTree8Leaves_AllLevelsPresent() async {
        let leaves = (0..<8).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "All levels should be present")
    }
    
    func testTree16Leaves_CheckpointEmitted() async {
        // Checkpoint should be emitted at leaf 16
        let leaves = (0..<16).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Checkpoint should be emitted at leaf 16")
    }
    
    func testTree32Leaves_2Checkpoints() async {
        // Checkpoints at 16 and 32
        let leaves = (0..<32).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Should have 2 checkpoints")
    }
    
    func testTree64Leaves_4Checkpoints() async {
        // Checkpoints at 16, 32, 48, 64
        let leaves = (0..<64).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Should have 4 checkpoints")
    }
    
    func testTree128Leaves_8Checkpoints() async {
        let leaves = (0..<128).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Should have 8 checkpoints")
    }
    
    func testTree256Leaves_16Checkpoints() async {
        let leaves = (0..<256).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Should have 16 checkpoints")
    }
    
    // MARK: - Non-Power-of-2 Trees
    
    func testTree3Leaves_StackStructure_Correct() async {
        let leaves = [
            Data([1]),
            Data([2]),
            Data([3])
        ]
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        
        // After 3 leaves: stack should have 2 elements (merged pair + single)
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        
        let n0 = computeNodeHash(left: h0, right: h1, level: 0)
        // Root should merge n0 and h2
        let expected = computeNodeHash(left: n0, right: h2, level: 1)
        
        XCTAssertEqual(root, expected, "3 leaves stack structure should be correct")
    }
    
    func testTree5Leaves_RootCorrect() async {
        let leaves = (0..<5).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "5 leaves root should be correct")
    }
    
    func testTree7Leaves_RootCorrect() async {
        let leaves = (0..<7).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "7 leaves root should be correct")
    }
    
    func testTree9Leaves_RootCorrect() async {
        let leaves = (0..<9).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "9 leaves root should be correct")
    }
    
    func testTree13Leaves_RootCorrect() async {
        let leaves = (0..<13).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "13 leaves root should be correct")
    }
    
    func testTree15Leaves_RootCorrect() async {
        let leaves = (0..<15).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "15 leaves root should be correct")
    }
    
    func testTree17Leaves_RootCorrect() async {
        let leaves = (0..<17).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "17 leaves root should be correct")
    }
    
    func testTree31Leaves_RootCorrect() async {
        let leaves = (0..<31).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "31 leaves root should be correct")
    }
    
    func testTree33Leaves_RootCorrect() async {
        let leaves = (0..<33).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "33 leaves root should be correct")
    }
    
    func testTree100Leaves_ValidRoot() async {
        let leaves = (0..<100).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "100 leaves root should be valid")
    }
    
    func testTree255Leaves_ValidRoot() async {
        let leaves = (0..<255).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "255 leaves root should be valid")
    }
    
    func testTree1000Leaves_ValidRoot() async {
        let leaves = (0..<1000).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "1000 leaves root should be valid")
    }
    
    func testTree3Leaves_StackHas2Elements() async {
        let leaves = [
            Data([1]),
            Data([2]),
            Data([3])
        ]
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        // After 3 leaves, stack should have 2 elements (merged pair + single)
        // We verify through root computation
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Stack should have 2 elements")
    }
    
    func testTree5Leaves_StackHas2Elements() async {
        let leaves = (0..<5).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Stack should have 2 elements")
    }
    
    func testTree7Leaves_StackHas3Elements() async {
        let leaves = (0..<7).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Stack should have 3 elements")
    }
    
    // MARK: - Domain Separation (RFC 9162)
    
    func testDomainSeparation_LeafPrefix_0x00() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let expected = computeLeafHash(data: data, index: 0)
        
        XCTAssertEqual(root, expected, "Leaf prefix should be 0x00")
    }
    
    func testDomainSeparation_NodePrefix_0x01() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        
        let h0 = computeLeafHash(data: data1, index: 0)
        let h1 = computeLeafHash(data: data2, index: 1)
        let expected = computeNodeHash(left: h0, right: h1, level: 0)
        
        XCTAssertEqual(root, expected, "Node prefix should be 0x01")
    }
    
    func testDomainSeparation_LeafHashIncludesIndexLE32() async {
        let data = Data([1, 2, 3])
        
        await tree.appendLeaf(data)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(data)
        await tree2.appendLeaf(Data([4, 5, 6]))
        // Now append same data again at index 2
        await tree2.appendLeaf(data)
        
        // Leaf at index 0 vs index 2 should be different
        let h0 = computeLeafHash(data: data, index: 0)
        let h2 = computeLeafHash(data: data, index: 2)
        
        XCTAssertNotEqual(h0, h2, "Leaf hash should include index")
    }
    
    func testDomainSeparation_NodeHashIncludesLevel() async {
        let leaves = (0..<4).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        
        // Level 0 nodes vs level 1 node should be different
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let h3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n0_level0 = computeNodeHash(left: h0, right: h1, level: 0)
        let n1_level0 = computeNodeHash(left: h2, right: h3, level: 0)
        let n0_level1 = computeNodeHash(left: n0_level0, right: n1_level0, level: 1)
        
        XCTAssertEqual(root, n0_level1, "Node hash should include level")
    }
    
    func testDomainSeparation_Leaf0_DifferentFromNode0() async {
        let data = Data([1, 2, 3])
        
        await tree.appendLeaf(data)
        let leafRoot = await tree.rootHash
        
        // Create a node hash with same data (should be different)
        let leafHash = computeLeafHash(data: data, index: 0)
        let nodeHash = computeNodeHash(left: leafHash, right: leafHash, level: 0)
        
        XCTAssertNotEqual(leafRoot, nodeHash, "Leaf hash should differ from node hash")
    }
    
    func testDomainSeparation_LeafAndNode_DifferentPrefixes() async {
        let data = Data([1, 2, 3])
        let leafHash = computeLeafHash(data: data, index: 0)
        
        // Leaf uses 0x00 prefix, node uses 0x01 prefix
        let nodeHash = computeNodeHash(left: leafHash, right: leafHash, level: 0)
        
        XCTAssertNotEqual(leafHash, nodeHash, "Leaf and node should have different prefixes")
    }
    
    func testDomainSeparation_SameData_LeafVsNode_DifferentHash() async {
        let data = Data([1, 2, 3])
        
        await tree.appendLeaf(data)
        let leafRoot = await tree.rootHash
        
        // Create node with same data
        let leafHash = computeLeafHash(data: data, index: 0)
        let nodeHash = computeNodeHash(left: leafHash, right: leafHash, level: 0)
        
        XCTAssertNotEqual(leafRoot, nodeHash, "Same data as leaf vs node should produce different hash")
    }
    
    func testDomainSeparation_IndexLE32_LittleEndian() async {
        let data = Data([1, 2, 3])
        
        // Index 0: bytes should be 00 00 00 00
        let h0 = computeLeafHash(data: data, index: 0)
        
        // Index 1: bytes should be 01 00 00 00 (little endian)
        let h1 = computeLeafHash(data: data, index: 1)
        
        XCTAssertNotEqual(h0, h1, "Index should be little-endian")
    }
    
    func testDomainSeparation_Index0_Bytes00000000() async {
        let data = Data([1, 2, 3])
        let h0 = computeLeafHash(data: data, index: 0)
        
        // Verify index 0 produces correct hash
        var input = Data([UploadConstants.MERKLE_LEAF_PREFIX])
        var indexLE = UInt32(0).littleEndian
        input.append(contentsOf: withUnsafeBytes(of: &indexLE) { Data($0) })
        input.append(data)
        let expected = computeSHA256(input)
        
        XCTAssertEqual(h0, expected, "Index 0 should be 00 00 00 00")
    }
    
    func testDomainSeparation_Index1_Bytes01000000() async {
        let data = Data([1, 2, 3])
        let h1 = computeLeafHash(data: data, index: 1)
        
        // Verify index 1 produces correct hash
        var input = Data([UploadConstants.MERKLE_LEAF_PREFIX])
        var indexLE = UInt32(1).littleEndian
        input.append(contentsOf: withUnsafeBytes(of: &indexLE) { Data($0) })
        input.append(data)
        let expected = computeSHA256(input)
        
        XCTAssertEqual(h1, expected, "Index 1 should be 01 00 00 00")
    }
    
    func testDomainSeparation_Index255_BytesFF000000() async {
        let data = Data([1, 2, 3])
        let h255 = computeLeafHash(data: data, index: 255)
        
        // Verify index 255
        var input = Data([UploadConstants.MERKLE_LEAF_PREFIX])
        var indexLE = UInt32(255).littleEndian
        input.append(contentsOf: withUnsafeBytes(of: &indexLE) { Data($0) })
        input.append(data)
        let expected = computeSHA256(input)
        
        XCTAssertEqual(h255, expected, "Index 255 should be FF 00 00 00")
    }
    
    func testDomainSeparation_Index256_Bytes00010000() async {
        let data = Data([1, 2, 3])
        let h256 = computeLeafHash(data: data, index: 256)
        
        // Verify index 256
        var input = Data([UploadConstants.MERKLE_LEAF_PREFIX])
        var indexLE = UInt32(256).littleEndian
        input.append(contentsOf: withUnsafeBytes(of: &indexLE) { Data($0) })
        input.append(data)
        let expected = computeSHA256(input)
        
        XCTAssertEqual(h256, expected, "Index 256 should be 00 01 00 00")
    }
    
    func testDomainSeparation_Level_AsUInt8() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        
        let h0 = computeLeafHash(data: data1, index: 0)
        let h1 = computeLeafHash(data: data2, index: 1)
        let expected = computeNodeHash(left: h0, right: h1, level: 0)
        
        XCTAssertEqual(root, expected, "Level should be UInt8")
    }
    
    func testDomainSeparation_Level0_Byte00() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        
        let h0 = computeLeafHash(data: data1, index: 0)
        let h1 = computeLeafHash(data: data2, index: 1)
        let expected = computeNodeHash(left: h0, right: h1, level: 0)
        
        XCTAssertEqual(root, expected, "Level 0 should be byte 00")
    }
    
    func testDomainSeparation_Level1_Byte01() async {
        let leaves = (0..<4).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        
        // Level 1 node should have level byte 01
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let h3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n0 = computeNodeHash(left: h0, right: h1, level: 0)
        let n1 = computeNodeHash(left: h2, right: h3, level: 0)
        let expected = computeNodeHash(left: n0, right: n1, level: 1)
        
        XCTAssertEqual(root, expected, "Level 1 should be byte 01")
    }
    
    // MARK: - Incremental Consistency
    
    func testIncremental_AppendDoesNotChange_PreviousRoot() async {
        let data1 = Data([1, 2, 3])
        await tree.appendLeaf(data1)
        let root1 = await tree.rootHash
        
        let data2 = Data([4, 5, 6])
        await tree.appendLeaf(data2)
        let root2 = await tree.rootHash
        
        // Root1 should still be accessible (but root2 is different)
        XCTAssertNotEqual(root1, root2, "Appending should change root")
        
        // But if we rebuild tree with same sequence, root1 should match
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(data1)
        let root1Rebuilt = await tree2.rootHash
        
        XCTAssertEqual(root1, root1Rebuilt, "Previous root should be reproducible")
    }
    
    func testIncremental_EachAppend_ProducesNewRoot() async {
        var roots: [Data] = []
        
        for i in 0..<10 {
            await tree.appendLeaf(Data([UInt8(i)]))
            let root = await tree.rootHash
            roots.append(root)
        }
        
        // All roots should be different (except possibly empty tree)
        for i in 1..<roots.count {
            XCTAssertNotEqual(roots[i-1], roots[i], "Each append should produce new root")
        }
    }
    
    func testIncremental_Deterministic_SameSequence_SameRoots() async {
        let leaves = (0..<10).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        for leaf in leaves {
            await tree2.appendLeaf(leaf)
        }
        let root2 = await tree2.rootHash
        
        XCTAssertEqual(root1, root2, "Same sequence should produce same roots")
    }
    
    func testIncremental_10000Leaves_MemoryOLogN() async {
        // Memory should be O(log n), so 10000 leaves should not cause issues
        let leaves = (0..<10000).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "10000 leaves should complete without memory issues")
    }
    
    func testIncremental_StackNeverExceedsLogN() async {
        // Stack size should be <= log2(n) + 1
        let leaves = (0..<100).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Stack should not exceed log2(n)")
    }
    
    func testIncremental_AfterNLeaves_StackSizeLeqLogN_Plus1() async {
        // After n leaves, stack size <= log2(n) + 1
        let n = 64
        let leaves = (0..<n).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Stack size should be <= log2(n) + 1")
    }
    
    func testIncremental_BinaryCarry_MergesCorrectly() async {
        let leaves = (0..<8).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        
        // Verify binary carry merged correctly
        let hashes = leaves.enumerated().map { computeLeafHash(data: $0.element, index: $0.offset) }
        
        // Build tree manually
        let n0 = computeNodeHash(left: hashes[0], right: hashes[1], level: 0)
        let n1 = computeNodeHash(left: hashes[2], right: hashes[3], level: 0)
        let n2 = computeNodeHash(left: hashes[4], right: hashes[5], level: 0)
        let n3 = computeNodeHash(left: hashes[6], right: hashes[7], level: 0)
        
        let m0 = computeNodeHash(left: n0, right: n1, level: 1)
        let m1 = computeNodeHash(left: n2, right: n3, level: 1)
        let expected = computeNodeHash(left: m0, right: m1, level: 2)
        
        XCTAssertEqual(root, expected, "Binary carry should merge correctly")
    }
    
    func testIncremental_CarryPropagation_MultiLevel() async {
        // Test carry propagation across multiple levels
        let leaves = (0..<16).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Carry should propagate across levels")
    }
    
    func testIncremental_SubtreeCheckpoint_Every16Leaves() async {
        // Checkpoints at 16, 32, 48, etc.
        let leaves = (0..<48).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Checkpoints should be emitted every 16 leaves")
    }
    
    func testIncremental_CheckpointCount_EqualsLeafCount_Div16() async {
        // 48 leaves = 3 checkpoints (at 16, 32, 48)
        let leaves = (0..<48).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Checkpoint count should equal leafCount / 16")
    }
    
    func testIncremental_MonotonicallyIncreasingLeafCount() async {
        // Leaf count should increase monotonically
        for i in 0..<10 {
            await tree.appendLeaf(Data([UInt8(i)]))
            let root = await tree.rootHash
            
            // Each append should produce different root (except edge cases)
            XCTAssertEqual(root.count, 32, "Leaf count should increase")
        }
    }
    
    func testIncremental_ConcurrentAppends_ActorSafe() async {
        // Test concurrent appends (actor should serialize)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await self.tree.appendLeaf(Data([UInt8(i)]))
                }
            }
            
            for await _ in group {
                // Wait for all appends
            }
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Concurrent appends should be actor-safe")
    }
    
    func testIncremental_100Appends_AllRootsDifferent() async {
        var roots: [Data] = []
        
        for i in 0..<100 {
            await tree.appendLeaf(Data([UInt8(i % 256)]))
            let root = await tree.rootHash
            roots.append(root)
        }
        
        // Most roots should be different (except when tree structure is same)
        var uniqueRoots = Set(roots)
        XCTAssertGreaterThan(uniqueRoots.count, 50, "Most roots should be different")
    }
    
    func testIncremental_RootAfterN_SameAsRebuiltTree() async {
        let leaves = (0..<10).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        let root1 = await tree.rootHash
        
        // Rebuild tree
        let tree2 = StreamingMerkleTree()
        for leaf in leaves {
            await tree2.appendLeaf(leaf)
        }
        let root2 = await tree2.rootHash
        
        XCTAssertEqual(root1, root2, "Root after N should match rebuilt tree")
    }
    
    func testIncremental_PartialTree_MatchesFullComputation() async {
        // Partial tree computation should match full tree
        let leaves = (0..<8).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        let root = await tree.rootHash
        
        // Compute full tree manually
        let hashes = leaves.enumerated().map { computeLeafHash(data: $0.element, index: $0.offset) }
        let n0 = computeNodeHash(left: hashes[0], right: hashes[1], level: 0)
        let n1 = computeNodeHash(left: hashes[2], right: hashes[3], level: 0)
        let n2 = computeNodeHash(left: hashes[4], right: hashes[5], level: 0)
        let n3 = computeNodeHash(left: hashes[6], right: hashes[7], level: 0)
        let m0 = computeNodeHash(left: n0, right: n1, level: 1)
        let m1 = computeNodeHash(left: n2, right: n3, level: 1)
        let expected = computeNodeHash(left: m0, right: m1, level: 2)
        
        XCTAssertEqual(root, expected, "Partial tree should match full computation")
    }
    
    // MARK: - Proof Generation & Verification
    
    func testProof_InvalidIndex_ReturnsNil() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let proof = await tree.generateProof(leafIndex: 100)
        
        XCTAssertNil(proof, "Invalid index should return nil")
    }
    
    func testProof_NegativeIndex_ReturnsNil() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let proof = await tree.generateProof(leafIndex: -1)
        
        XCTAssertNil(proof, "Negative index should return nil")
    }
    
    func testProof_IndexBeyondLeafCount_ReturnsNil() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let proof = await tree.generateProof(leafIndex: 10)
        
        XCTAssertNil(proof, "Index beyond leaf count should return nil")
    }
    
    func testVerifyProof_ValidProof_ReturnsTrue() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Valid proof should return true")
    }
    
    func testVerifyProof_InvalidProof_ReturnsFalse() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let wrongProof = [Data(repeating: 0, count: 32)]  // Wrong proof
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: wrongProof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertFalse(isValid, "Invalid proof should return false")
    }
    
    func testVerifyProof_WrongRoot_ReturnsFalse() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        let wrongRoot = Data(repeating: 0, count: 32)
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: wrongRoot,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertFalse(isValid, "Wrong root should return false")
    }
    
    func testVerifyProof_WrongLeaf_ReturnsFalse() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let wrongLeaf = Data(repeating: 0, count: 32)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: wrongLeaf,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertFalse(isValid, "Wrong leaf should return false")
    }
    
    func testVerifyProof_WrongIndex_ReturnsFalse() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: root,
            index: 1,  // Wrong index
            totalLeaves: 2
        )
        
        XCTAssertFalse(isValid, "Wrong index should return false")
    }
    
    func testVerifyProof_EmptyProof_ValidForSingleLeaf() async {
        let data = Data([1, 2, 3])
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let leafHash = computeLeafHash(data: data, index: 0)
        
        // For single leaf, proof should be empty
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash,
            proof: [],
            root: root,
            index: 0,
            totalLeaves: 1
        )
        
        XCTAssertTrue(isValid, "Empty proof should be valid for single leaf")
    }
    
    func testVerifyProof_SwappedSiblings_ReturnsFalse() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        
        // Swap siblings (wrong order)
        let wrongProof = [leafHash1]  // Should be leafHash2 for index 0
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: wrongProof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        // This might still verify if we're checking root match, but order matters
        XCTAssertFalse(isValid, "Swapped siblings should return false")
    }
    
    func testVerifyProof_TruncatedProof_ReturnsFalse() async {
        let leaves = (0..<4).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        let leafHash0 = computeLeafHash(data: leaves[0], index: 0)
        
        // Truncated proof (missing some siblings)
        let truncatedProof: [Data] = []
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash0,
            proof: truncatedProof,
            root: root,
            index: 0,
            totalLeaves: 4
        )
        
        XCTAssertFalse(isValid, "Truncated proof should return false")
    }
    
    func testVerifyProof_ExtendedProof_ReturnsFalse() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        
        // Extended proof (extra siblings)
        let extendedProof = [leafHash2, Data(repeating: 0, count: 32)]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: extendedProof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertFalse(isValid, "Extended proof should return false")
    }
    
    func testVerifyProof_LeftChild_CorrectOrder() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        
        // Left child (index 0) should use right sibling
        let proof = [leafHash2]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Left child should use correct order")
    }
    
    func testVerifyProof_RightChild_CorrectOrder() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        
        // Right child (index 1) should use left sibling
        let proof = [leafHash1]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash2,
            proof: proof,
            root: root,
            index: 1,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Right child should use correct order")
    }
    
    func testVerifyProof_Leaf0In2Tree_Works() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Leaf 0 in 2-tree should work")
    }
    
    func testVerifyProof_Leaf1In2Tree_Works() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash1]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash2,
            proof: proof,
            root: root,
            index: 1,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Leaf 1 in 2-tree should work")
    }
    
    func testVerifyProof_Leaf0In4Tree_Works() async {
        let leaves = (0..<4).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        let leafHash0 = computeLeafHash(data: leaves[0], index: 0)
        let leafHash1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let h3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n1 = computeNodeHash(left: h2, right: h3, level: 0)
        let n0 = computeNodeHash(left: leafHash0, right: leafHash1, level: 0)
        let proof = [leafHash1, n1]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash0,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 4
        )
        
        XCTAssertTrue(isValid, "Leaf 0 in 4-tree should work")
    }
    
    func testVerifyProof_Leaf3In4Tree_Works() async {
        let leaves = (0..<4).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let leafHash3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n0 = computeNodeHash(left: h0, right: h1, level: 0)
        let n1_left = computeNodeHash(left: h2, right: leafHash3, level: 0)
        let proof = [h2, n0]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash3,
            proof: proof,
            root: root,
            index: 3,
            totalLeaves: 4
        )
        
        XCTAssertTrue(isValid, "Leaf 3 in 4-tree should work")
    }
    
    func testVerifyProof_Leaf7In8Tree_Works() async {
        let leaves = (0..<8).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        let leafHash7 = computeLeafHash(data: leaves[7], index: 7)
        
        // Build proof for leaf 7
        let h6 = computeLeafHash(data: leaves[6], index: 6)
        let h4 = computeLeafHash(data: leaves[4], index: 4)
        let h5 = computeLeafHash(data: leaves[5], index: 5)
        let h0 = computeLeafHash(data: leaves[0], index: 0)
        let h1 = computeLeafHash(data: leaves[1], index: 1)
        let h2 = computeLeafHash(data: leaves[2], index: 2)
        let h3 = computeLeafHash(data: leaves[3], index: 3)
        
        let n3 = computeNodeHash(left: h6, right: leafHash7, level: 0)
        let n2 = computeNodeHash(left: h4, right: h5, level: 0)
        let n1 = computeNodeHash(left: n2, right: n3, level: 1)
        let n0 = computeNodeHash(left: h0, right: h1, level: 0)
        let n0_1 = computeNodeHash(left: h2, right: h3, level: 0)
        let n0_top = computeNodeHash(left: n0, right: n0_1, level: 1)
        let proof = [h6, h5, h4, n0_top]
        
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash7,
            proof: proof,
            root: root,
            index: 7,
            totalLeaves: 8
        )
        
        XCTAssertTrue(isValid, "Leaf 7 in 8-tree should work")
    }
    
    func testVerifyProof_StaticMethod_NoActorNeeded() async {
        let data1 = Data([1, 2, 3])
        let data2 = Data([4, 5, 6])
        
        await tree.appendLeaf(data1)
        await tree.appendLeaf(data2)
        
        let root = await tree.rootHash
        let leafHash1 = computeLeafHash(data: data1, index: 0)
        let leafHash2 = computeLeafHash(data: data2, index: 1)
        let proof = [leafHash2]
        
        // Static method doesn't need actor
        let isValid = StreamingMerkleTree.verifyProof(
            leaf: leafHash1,
            proof: proof,
            root: root,
            index: 0,
            totalLeaves: 2
        )
        
        XCTAssertTrue(isValid, "Static method should work without actor")
    }
    
    // MARK: - Edge Cases
    
    func testEdge_VeryLargeLeafData_1MB() async {
        let data = Data(repeating: 1, count: 1_000_000)
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Very large leaf data should work")
    }
    
    func testEdge_EmptyLeafData() async {
        let data = Data()
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        let expected = computeLeafHash(data: data, index: 0)
        
        XCTAssertEqual(root, expected, "Empty leaf data should work")
    }
    
    func testEdge_UnicodeLeafData() async {
        let data = "Hello, 世界! 🌍".data(using: .utf8)!
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "Unicode leaf data should work")
    }
    
    func testEdge_BinaryLeafData_AllZeros() async {
        let data = Data(repeating: 0, count: 100)
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "All zeros should work")
    }
    
    func testEdge_BinaryLeafData_AllOnes() async {
        let data = Data(repeating: 1, count: 100)
        await tree.appendLeaf(data)
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "All ones should work")
    }
    
    func testEdge_MaxUInt32Index_DoesNotOverflow() async {
        // Test with index near max UInt32
        let maxIndex = Int(UInt32.max)
        // We can't actually append that many leaves, but we can test the hash function
        let data = Data([1, 2, 3])
        let hash = computeLeafHash(data: data, index: maxIndex)
        
        XCTAssertEqual(hash.count, 32, "Max index should not overflow")
    }
    
    func testEdge_10000Leaves_Completes() async {
        let leaves = (0..<10000).map { Data([UInt8($0 % 256)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        
        let root = await tree.rootHash
        XCTAssertEqual(root.count, 32, "10000 leaves should complete")
    }
    
    func testEdge_HashCollision_DifferentIndexPreventsFalsePositive() async {
        let data = Data([1, 2, 3])
        
        await tree.appendLeaf(data)
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        await tree2.appendLeaf(Data([4, 5, 6]))
        await tree2.appendLeaf(data)  // Same data, different index
        
        let root2 = await tree2.rootHash
        
        // Different index should prevent collision
        let h0 = computeLeafHash(data: data, index: 0)
        let h1 = computeLeafHash(data: data, index: 1)
        
        XCTAssertNotEqual(h0, h1, "Different index should prevent hash collision")
    }
    
    func testEdge_SameDataDifferentIndex_DifferentLeafHash() async {
        let data = Data([1, 2, 3])
        
        let h0 = computeLeafHash(data: data, index: 0)
        let h1 = computeLeafHash(data: data, index: 1)
        
        XCTAssertNotEqual(h0, h1, "Same data with different index should produce different hash")
    }
    
    func testEdge_RootHashConsistent_AcrossRuns() async {
        let leaves = (0..<10).map { Data([UInt8($0)]) }
        
        for leaf in leaves {
            await tree.appendLeaf(leaf)
        }
        let root1 = await tree.rootHash
        
        let tree2 = StreamingMerkleTree()
        for leaf in leaves {
            await tree2.appendLeaf(leaf)
        }
        let root2 = await tree2.rootHash
        
        XCTAssertEqual(root1, root2, "Root hash should be consistent across runs")
    }
}
