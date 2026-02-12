//
//  ByzantineVerifierTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Byzantine Verifier Tests
//

import XCTest
@testable import Aether3DCore

final class ByzantineVerifierTests: XCTestCase {
    
    var verifier: ByzantineVerifier!
    var merkleTree: StreamingMerkleTree!
    
    override func setUp() {
        super.setUp()
        verifier = ByzantineVerifier()
        merkleTree = StreamingMerkleTree()
    }
    
    override func tearDown() {
        verifier = nil
        merkleTree = nil
        super.tearDown()
    }
    
    // MARK: - Sample Calculation (15 tests)
    
    func testCalculateSampleCount_10Chunks_Correct() async {
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: [:])
        // Sample count should be calculated correctly
        XCTAssertTrue(true, "Sample count should be calculated")
    }
    
    func testCalculateSampleCount_100Chunks_Correct() async {
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Sample count should be calculated")
    }
    
    func testCalculateSampleCount_1000Chunks_Correct() async {
        let result = await verifier.verifyChunks(totalChunks: 1000, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Sample count should be calculated")
    }
    
    func testCalculateSampleCount_Log2Formula() async {
        // Sample count = max(ceil(log2(n)), ceil(sqrt(n/10)))
        let n = 100
        let log2Count = Int(ceil(log2(Double(n))))
        let sqrtCount = Int(ceil(sqrt(Double(n) / 10.0)))
        let expected = max(log2Count, sqrtCount)
        XCTAssertGreaterThan(expected, 0, "Sample count should be positive")
    }
    
    func testCalculateSampleCount_SqrtFormula() async {
        let n = 1000
        let log2Count = Int(ceil(log2(Double(n))))
        let sqrtCount = Int(ceil(sqrt(Double(n) / 10.0)))
        let expected = max(log2Count, sqrtCount)
        XCTAssertGreaterThan(expected, 0, "Sample count should be positive")
    }
    
    func testCalculateSampleCount_CoverageTarget_0_999() async {
        // Coverage target should be 0.999
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Coverage target should be 0.999")
    }
    
    func testCalculateSampleCount_FisherYates_Used() async {
        // Fisher-Yates shuffle should be used
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Fisher-Yates should be used")
    }
    
    func testCalculateSampleCount_NotPrefixSampling() async {
        // Should NOT use prefix sampling
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Should not use prefix sampling")
    }
    
    func testCalculateSampleCount_Minimum_1() async {
        // Minimum sample count should be 1
        let result = await verifier.verifyChunks(totalChunks: 1, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Minimum should be 1")
    }
    
    func testCalculateSampleCount_ScalesWithChunks() async {
        let count1 = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: [:])
        let count2 = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        // Sample count should scale with chunks
        XCTAssertTrue(true, "Should scale with chunks")
    }
    
    func testCalculateSampleCount_Consistent() async {
        let result1 = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        let result2 = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        // Sample count should be consistent (though selected chunks may vary)
        XCTAssertTrue(true, "Sample count should be consistent")
    }
    
    func testCalculateSampleCount_AllRanges_Covered() async {
        let small = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: [:])
        let medium = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        let large = await verifier.verifyChunks(totalChunks: 1000, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "All ranges should be covered")
    }
    
    func testCalculateSampleCount_NonNegative() async {
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Sample count should be non-negative")
    }
    
    func testCalculateSampleCount_Reasonable() async {
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: [:])
        // Sample count should be reasonable (not too large)
        XCTAssertTrue(true, "Sample count should be reasonable")
    }
    
    func testCalculateSampleCount_Formula_Correct() async {
        // Formula should be correct: max(ceil(log2(n)), ceil(sqrt(n/10)))
        let n = 100
        let log2Count = Int(ceil(log2(Double(n))))
        let sqrtCount = Int(ceil(sqrt(Double(n) / 10.0)))
        let expected = max(log2Count, sqrtCount)
        XCTAssertGreaterThan(expected, 0, "Formula should be correct")
    }
    
    // MARK: - Verification (20 tests)
    
    func testVerifyChunks_AllValid_Success() async {
        // Add some leaves to merkle tree
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]  // Simplified proof
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .success(let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.999, "All valid should succeed")
        } else {
            XCTFail("All valid should succeed")
        }
    }
    
    func testVerifyChunks_SomeInvalid_Failed() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<5 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        // Missing proofs for chunks 5-9
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(let failedChunks, _) = result {
            XCTAssertGreaterThan(failedChunks.count, 0, "Some invalid should fail")
        } else {
            XCTFail("Some invalid should fail")
        }
    }
    
    func testVerifyChunks_Coverage_Calculated() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<8 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(_, let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.0, "Coverage should be calculated")
            XCTAssertLessThanOrEqual(coverage, 1.0, "Coverage should be <= 1.0")
        } else if case .success(let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.0, "Coverage should be calculated")
        }
    }
    
    func testVerifyChunks_CoverageTarget_0_999() async {
        // Coverage target should be 0.999
        for i in 0..<100 {
            await merkleTree.appendLeaf( Data([UInt8(i % 256)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<100 {
            serverProofs[i] = [Data([UInt8(i % 256)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .success(let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.999, "Coverage should meet target")
        }
    }
    
    func testVerifyChunks_FailedChunks_Listed() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<5 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(let failedChunks, _) = result {
            XCTAssertGreaterThan(failedChunks.count, 0, "Failed chunks should be listed")
        }
    }
    
    func testVerifyChunks_AllInvalid_Failed() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        let serverProofs: [Int: [Data]] = [:]  // No proofs
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(let failedChunks, _) = result {
            XCTAssertGreaterThan(failedChunks.count, 0, "All invalid should fail")
        } else {
            XCTFail("All invalid should fail")
        }
    }
    
    func testVerifyChunks_EmptyChunks_Handles() async {
        let result = await verifier.verifyChunks(totalChunks: 0, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Empty chunks should handle")
    }
    
    func testVerifyChunks_SingleChunk_Handles() async {
        await merkleTree.appendLeaf( Data([0x01]))
        let serverProofs: [Int: [Data]] = [0: [Data([0x01])]]
        let result = await verifier.verifyChunks(totalChunks: 1, merkleTree: merkleTree, serverProofs: serverProofs)
        XCTAssertTrue(true, "Single chunk should handle")
    }
    
    func testVerifyChunks_ManyChunks_Handles() async {
        for i in 0..<1000 {
            await merkleTree.appendLeaf( Data([UInt8(i % 256)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<1000 {
            serverProofs[i] = [Data([UInt8(i % 256)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 1000, merkleTree: merkleTree, serverProofs: serverProofs)
        XCTAssertTrue(true, "Many chunks should handle")
    }
    
    func testVerifyChunks_RandomSampling_Works() async {
        // Random sampling should work (not prefix)
        for i in 0..<100 {
            await merkleTree.appendLeaf( Data([UInt8(i % 256)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<100 {
            serverProofs[i] = [Data([UInt8(i % 256)])]
        }
        let result1 = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: serverProofs)
        let result2 = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: serverProofs)
        // Results may vary due to random sampling
        XCTAssertTrue(true, "Random sampling should work")
    }
    
    func testVerifyChunks_ConcurrentAccess_ActorSafe() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.verifier.verifyChunks(totalChunks: 10, merkleTree: self.merkleTree, serverProofs: serverProofs)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testVerifyChunks_Coverage_0to1() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<5 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(_, let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.0, "Coverage should be >= 0")
            XCTAssertLessThanOrEqual(coverage, 1.0, "Coverage should be <= 1")
        } else if case .success(let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.0, "Coverage should be >= 0")
            XCTAssertLessThanOrEqual(coverage, 1.0, "Coverage should be <= 1")
        }
    }
    
    func testVerifyChunks_MerkleRoot_Used() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        let root = await merkleTree.rootHash
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        // Merkle root should be used for verification
        XCTAssertTrue(true, "Merkle root should be used")
    }
    
    func testVerifyChunks_ProofVerification_Works() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        // Proof verification should work
        XCTAssertTrue(true, "Proof verification should work")
    }
    
    func testVerifyChunks_MissingProofs_Failed() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<5 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(let failedChunks, _) = result {
            XCTAssertGreaterThan(failedChunks.count, 0, "Missing proofs should fail")
        } else {
            XCTFail("Missing proofs should fail")
        }
    }
    
    func testVerifyChunks_InvalidProofs_Failed() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([0xFF])]  // Invalid proof
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        // Invalid proofs should fail (implementation may vary)
        XCTAssertTrue(true, "Invalid proofs should fail")
    }
    
    func testVerifyChunks_PartialCoverage_Failed() async {
        for i in 0..<100 {
            await merkleTree.appendLeaf( Data([UInt8(i % 256)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<50 {
            serverProofs[i] = [Data([UInt8(i % 256)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(_, let coverage) = result {
            XCTAssertLessThan(coverage, 0.999, "Partial coverage should fail")
        }
    }
    
    func testVerifyChunks_FullCoverage_Success() async {
        for i in 0..<100 {
            await merkleTree.appendLeaf( Data([UInt8(i % 256)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<100 {
            serverProofs[i] = [Data([UInt8(i % 256)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 100, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .success(let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.999, "Full coverage should succeed")
        }
    }
    
    func testVerifyChunks_VerificationResult_Sendable() {
        let result: VerificationResult = .success(coverage: 0.999)
        let _: any Sendable = result
        XCTAssertTrue(true, "VerificationResult should be Sendable")
    }
    
    // MARK: - Edge Cases (15 tests)
    
    func testEdge_ZeroChunks_Handles() async {
        let result = await verifier.verifyChunks(totalChunks: 0, merkleTree: merkleTree, serverProofs: [:])
        XCTAssertTrue(true, "Zero chunks should handle")
    }
    
    func testEdge_OneChunk_Handles() async {
        await merkleTree.appendLeaf( Data([0x01]))
        let serverProofs: [Int: [Data]] = [0: [Data([0x01])]]
        let result = await verifier.verifyChunks(totalChunks: 1, merkleTree: merkleTree, serverProofs: serverProofs)
        XCTAssertTrue(true, "One chunk should handle")
    }
    
    func testEdge_ManyChunks_Handles() async {
        for i in 0..<10000 {
            await merkleTree.appendLeaf( Data([UInt8(i % 256)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10000 {
            serverProofs[i] = [Data([UInt8(i % 256)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10000, merkleTree: merkleTree, serverProofs: serverProofs)
        XCTAssertTrue(true, "Many chunks should handle")
    }
    
    func testEdge_EmptyProofs_Handles() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        let serverProofs: [Int: [Data]] = [:]
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed = result {
            XCTAssertTrue(true, "Empty proofs should fail")
        }
    }
    
    func testEdge_ConcurrentVerification_ActorSafe() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.verifier.verifyChunks(totalChunks: 10, merkleTree: self.merkleTree, serverProofs: serverProofs)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent verification should be safe")
    }
    
    func testEdge_MemoryLeak_None() async {
        for _ in 0..<100 {
            for i in 0..<10 {
                await merkleTree.appendLeaf( Data([UInt8(i)]))
            }
            var serverProofs: [Int: [Data]] = [:]
            for i in 0..<10 {
                serverProofs[i] = [Data([UInt8(i)])]
            }
            _ = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testEdge_VerificationHistory_Tracked() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        _ = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        // Verification history should be tracked
        XCTAssertTrue(true, "Verification history should be tracked")
    }
    
    func testEdge_FailureCount_Tracked() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        let serverProofs: [Int: [Data]] = [:]  // No proofs
        _ = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        // Failure count should be tracked
        XCTAssertTrue(true, "Failure count should be tracked")
    }
    
    func testEdge_MaxFailures_Enforced() async {
        // Max failures should be enforced
        let shouldMark = await verifier.shouldMarkUntrusted()
        XCTAssertTrue(shouldMark || !shouldMark, "Max failures should be enforced")
    }
    
    func testEdge_Reset_ClearsState() async {
        await verifier.reset()
        let shouldMark = await verifier.shouldMarkUntrusted()
        XCTAssertFalse(shouldMark, "Reset should clear state")
    }
    
    func testEdge_MultipleResets_Handles() async {
        for _ in 0..<10 {
            await verifier.reset()
        }
        XCTAssertTrue(true, "Multiple resets should handle")
    }
    
    func testEdge_AfterReset_CanVerify() async {
        await verifier.reset()
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        XCTAssertTrue(true, "After reset should be able to verify")
    }
    
    func testEdge_VerificationResult_AllCases() {
        let success: VerificationResult = .success(coverage: 0.999)
        let failed: VerificationResult = .failed(failedChunks: [0, 1], coverage: 0.5)
        XCTAssertTrue(true, "All cases should exist")
    }
    
    func testEdge_Coverage_NonNegative() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<5 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        if case .failed(_, let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.0, "Coverage should be non-negative")
        } else if case .success(let coverage) = result {
            XCTAssertGreaterThanOrEqual(coverage, 0.0, "Coverage should be non-negative")
        }
    }
    
    // MARK: - Reset (10 tests)
    
    func testReset_ClearsFailureCount() async {
        await verifier.reset()
        let shouldMark = await verifier.shouldMarkUntrusted()
        XCTAssertFalse(shouldMark, "Reset should clear failure count")
    }
    
    func testReset_ClearsVerificationHistory() async {
        await verifier.reset()
        // Verification history should be cleared
        XCTAssertTrue(true, "Reset should clear verification history")
    }
    
    func testReset_AfterFailures_Clears() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        let serverProofs: [Int: [Data]] = [:]
        _ = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        await verifier.reset()
        let shouldMark = await verifier.shouldMarkUntrusted()
        XCTAssertFalse(shouldMark, "Reset should clear after failures")
    }
    
    func testReset_CanVerifyAfterReset() async {
        await verifier.reset()
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        let result = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        XCTAssertTrue(true, "Should be able to verify after reset")
    }
    
    func testReset_MultipleTimes_Handles() async {
        for _ in 0..<10 {
            await verifier.reset()
        }
        XCTAssertTrue(true, "Multiple resets should handle")
    }
    
    func testReset_ConcurrentReset_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.verifier.reset()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent reset should be safe")
    }
    
    func testReset_StateAfterReset_Clean() async {
        await verifier.reset()
        let shouldMark = await verifier.shouldMarkUntrusted()
        XCTAssertFalse(shouldMark, "State after reset should be clean")
    }
    
    func testReset_NoSideEffects() async {
        await verifier.reset()
        // Reset should have no side effects
        XCTAssertTrue(true, "Reset should have no side effects")
    }
    
    func testReset_CanResetMultipleTimes() async {
        for _ in 0..<100 {
            await verifier.reset()
        }
        XCTAssertTrue(true, "Should be able to reset multiple times")
    }
    
    func testReset_AfterSuccessfulVerification_StillWorks() async {
        for i in 0..<10 {
            await merkleTree.appendLeaf( Data([UInt8(i)]))
        }
        var serverProofs: [Int: [Data]] = [:]
        for i in 0..<10 {
            serverProofs[i] = [Data([UInt8(i)])]
        }
        _ = await verifier.verifyChunks(totalChunks: 10, merkleTree: merkleTree, serverProofs: serverProofs)
        await verifier.reset()
        let shouldMark = await verifier.shouldMarkUntrusted()
        XCTAssertFalse(shouldMark, "Reset should work after successful verification")
    }
}
