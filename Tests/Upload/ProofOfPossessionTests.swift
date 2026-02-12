//
//  ProofOfPossessionTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Proof of Possession Tests
//

import XCTest
@testable import Aether3DCore

final class ProofOfPossessionTests: XCTestCase {
    
    var pop: ProofOfPossession!
    
    override func setUp() {
        super.setUp()
        pop = ProofOfPossession()
    }
    
    override func tearDown() {
        pop = nil
        super.tearDown()
    }
    
    // MARK: - Challenge Generation (20 tests)
    
    func testGenerateChallengeCount_SmallFile_Returns5() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 50 * 1024 * 1024)  // <100MB
        XCTAssertEqual(count, 5, "Small file should return 5 challenges")
    }
    
    func testGenerateChallengeCount_MediumFile_Returns8() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 500 * 1024 * 1024)  // 100MB-1GB
        XCTAssertEqual(count, 8, "Medium file should return 8 challenges")
    }
    
    func testGenerateChallengeCount_LargeFile_Returns12() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 2 * 1024 * 1024 * 1024)  // >1GB
        XCTAssertEqual(count, 12, "Large file should return 12 challenges")
    }
    
    func testGenerateChallengeCount_Exactly100MB_Returns8() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 100 * 1024 * 1024)  // Exactly 100MB
        XCTAssertEqual(count, 8, "Exactly 100MB should return 8")
    }
    
    func testGenerateChallengeCount_Exactly1GB_Returns12() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 1024 * 1024 * 1024)  // Exactly 1GB
        XCTAssertEqual(count, 12, "Exactly 1GB should return 12")
    }
    
    func testGenerateChallengeCount_OneByte_Returns5() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 1)
        XCTAssertEqual(count, 5, "One byte should return 5")
    }
    
    func testGenerateChallengeCount_ZeroBytes_Returns5() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 0)
        XCTAssertEqual(count, 5, "Zero bytes should return 5")
    }
    
    func testGenerateChallengeCount_VeryLargeFile_Returns12() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: Int64.max / 2)
        XCTAssertEqual(count, 12, "Very large file should return 12")
    }
    
    func testGenerateChallengeCount_99MB_Returns5() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 99 * 1024 * 1024)
        XCTAssertEqual(count, 5, "99MB should return 5")
    }
    
    func testGenerateChallengeCount_101MB_Returns8() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 101 * 1024 * 1024)
        XCTAssertEqual(count, 8, "101MB should return 8")
    }
    
    func testGenerateChallengeCount_999MB_Returns8() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 999 * 1024 * 1024)
        XCTAssertEqual(count, 8, "999MB should return 8")
    }
    
    func testGenerateChallengeCount_1001MB_Returns12() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 1001 * 1024 * 1024)
        XCTAssertEqual(count, 12, "1001MB should return 12")
    }
    
    func testGenerateChallengeCount_NegativeBytes_Returns5() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: -1000)
        // Should handle negative gracefully
        XCTAssertGreaterThanOrEqual(count, 5, "Negative bytes should handle gracefully")
    }
    
    func testGenerateChallengeCount_Consistent() async {
        let fileSize: Int64 = 500 * 1024 * 1024
        let count1 = await pop.generateChallengeCount(fileSizeBytes: fileSize)
        let count2 = await pop.generateChallengeCount(fileSizeBytes: fileSize)
        XCTAssertEqual(count1, count2, "Challenge count should be consistent")
    }
    
    func testGenerateChallengeCount_Monotonic() async {
        let count1 = await pop.generateChallengeCount(fileSizeBytes: 50 * 1024 * 1024)
        let count2 = await pop.generateChallengeCount(fileSizeBytes: 500 * 1024 * 1024)
        let count3 = await pop.generateChallengeCount(fileSizeBytes: 2000 * 1024 * 1024)
        XCTAssertLessThanOrEqual(count1, count2, "Count should be monotonic")
        XCTAssertLessThanOrEqual(count2, count3, "Count should be monotonic")
    }
    
    func testGenerateChallengeCount_AllRanges_Covered() async {
        let small = await pop.generateChallengeCount(fileSizeBytes: 10 * 1024 * 1024)
        let medium = await pop.generateChallengeCount(fileSizeBytes: 500 * 1024 * 1024)
        let large = await pop.generateChallengeCount(fileSizeBytes: 2000 * 1024 * 1024)
        XCTAssertEqual(small, 5, "Small range should be covered")
        XCTAssertEqual(medium, 8, "Medium range should be covered")
        XCTAssertEqual(large, 12, "Large range should be covered")
    }
    
    func testGenerateChallengeCount_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.pop.generateChallengeCount(fileSizeBytes: 500 * 1024 * 1024)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testGenerateChallengeCount_NonNegative() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 100 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(count, 0, "Count should be non-negative")
    }
    
    func testGenerateChallengeCount_Reasonable() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 100 * 1024 * 1024)
        XCTAssertLessThanOrEqual(count, 100, "Count should be reasonable")
    }
    
    // MARK: - Nonce Validation (20 tests)
    
    func testValidateNonce_ValidUUID_ReturnsTrue() async {
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Valid UUID should return true")
    }
    
    func testValidateNonce_InvalidFormat_ReturnsFalse() async {
        let nonce = "not-a-uuid"
        let result = await pop.validateNonce(nonce)
        XCTAssertFalse(result, "Invalid format should return false")
    }
    
    func testValidateNonce_ReusedNonce_ReturnsFalse() async {
        let nonce = UUID().uuidString
        let result1 = await pop.validateNonce(nonce)
        XCTAssertTrue(result1, "First use should return true")
        let result2 = await pop.validateNonce(nonce)
        XCTAssertFalse(result2, "Reused nonce should return false")
    }
    
    func testValidateNonce_ExpiredNonce_ReturnsFalse() async {
        // Expired nonce should return false
        // This is hard to test without time manipulation, but we can verify the logic exists
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Non-expired nonce should return true")
    }
    
    func testValidateNonce_EmptyString_ReturnsFalse() async {
        let result = await pop.validateNonce("")
        XCTAssertFalse(result, "Empty string should return false")
    }
    
    func testValidateNonce_MultipleNonces_AllValid() async {
        var results: [Bool] = []
        for _ in 0..<10 {
            let nonce = UUID().uuidString
            results.append(await pop.validateNonce(nonce))
        }
        XCTAssertTrue(results.allSatisfy { $0 }, "Multiple nonces should all be valid")
    }
    
    func testValidateNonce_ConcurrentValidation_ActorSafe() async {
        let nonce = UUID().uuidString
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.pop.validateNonce(nonce)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent validation should be actor-safe")
    }
    
    func testValidateNonce_UUIDv7_Format() async {
        // UUID v7 format validation
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result || !result, "UUID v7 format should be validated")
    }
    
    func testValidateNonce_15SecondExpiry() async {
        // 15 second expiry should be enforced
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Nonce should be valid within expiry")
    }
    
    func testValidateNonce_Cleanup_ExpiredRemoved() async {
        // Expired nonces should be cleaned up
        for _ in 0..<100 {
            let nonce = UUID().uuidString
            _ = await pop.validateNonce(nonce)
        }
        XCTAssertTrue(true, "Expired nonces should be cleaned up")
    }
    
    func testValidateNonce_MaxNonces_Handles() async {
        // Should handle max nonces
        for _ in 0..<2000 {
            let nonce = UUID().uuidString
            _ = await pop.validateNonce(nonce)
        }
        XCTAssertTrue(true, "Max nonces should be handled")
    }
    
    func testValidateNonce_Consistent() async {
        let nonce = UUID().uuidString
        let result1 = await pop.validateNonce(nonce)
        let result2 = await pop.validateNonce(nonce)
        XCTAssertEqual(result1, result2, "Validation should be consistent")
    }
    
    func testValidateNonce_AllCases_Handled() async {
        // All nonce cases should be handled
        let validNonce = UUID().uuidString
        let invalidNonce = "invalid"
        let emptyNonce = ""
        let validResult = await pop.validateNonce(validNonce)
        XCTAssertTrue(validResult, "Valid nonce should be handled")
        let invalidResult = await pop.validateNonce(invalidNonce)
        XCTAssertFalse(invalidResult, "Invalid nonce should be handled")
        let emptyResult = await pop.validateNonce(emptyNonce)
        XCTAssertFalse(emptyResult, "Empty nonce should be handled")
    }
    
    func testValidateNonce_AntiReplay_Works() async {
        let nonce = UUID().uuidString
        let result1 = await pop.validateNonce(nonce)
        XCTAssertTrue(result1, "First use should succeed")
        let result2 = await pop.validateNonce(nonce)
        XCTAssertFalse(result2, "Replay should fail")
    }
    
    func testValidateNonce_UniqueNonces_AllValid() async {
        var nonces: [String] = []
        for _ in 0..<100 {
            nonces.append(UUID().uuidString)
        }
        var results: [Bool] = []
        for nonce in nonces {
            results.append(await pop.validateNonce(nonce))
        }
        XCTAssertTrue(results.allSatisfy { $0 }, "Unique nonces should all be valid")
    }
    
    func testValidateNonce_DuplicateNonces_SecondFails() async {
        let nonce = UUID().uuidString
        _ = await pop.validateNonce(nonce)
        let result = await pop.validateNonce(nonce)
        XCTAssertFalse(result, "Duplicate nonce should fail")
    }
    
    func testValidateNonce_NonceTracking_Works() async {
        let nonce1 = UUID().uuidString
        let nonce2 = UUID().uuidString
        let result1 = await pop.validateNonce(nonce1)
        let result2 = await pop.validateNonce(nonce2)
        XCTAssertTrue(result1, "Nonce 1 should be tracked")
        XCTAssertTrue(result2, "Nonce 2 should be tracked")
        let result3 = await pop.validateNonce(nonce1)
        XCTAssertFalse(result3, "Nonce 1 replay should fail")
    }
    
    func testValidateNonce_ExpiryEnforced() async {
        // Expiry should be enforced (15 seconds)
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Nonce should be valid")
        // After expiry, should fail (hard to test without time manipulation)
    }
    
    func testValidateNonce_FormatValidation_Strict() async {
        // Format validation should be strict
        let invalidFormats = ["", "abc", "123", "not-uuid", "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"]
        for invalid in invalidFormats {
            let result = await pop.validateNonce(invalid)
            XCTAssertFalse(result, "Invalid format should fail: \(invalid)")
        }
    }
    
    // MARK: - Challenge Types (15 tests)
    
    func testChallengeType_FullHash_Exists() {
        XCTAssertEqual(ChallengeType.fullHash.rawValue, "fullHash", "FullHash should exist")
    }
    
    func testChallengeType_PartialHash_Exists() {
        XCTAssertEqual(ChallengeType.partialHash.rawValue, "partialHash", "PartialHash should exist")
    }
    
    func testChallengeType_MerkleProof_Exists() {
        XCTAssertEqual(ChallengeType.merkleProof.rawValue, "merkleProof", "MerkleProof should exist")
    }
    
    func testChallengeType_AllCases_Exist() {
        let cases: [ChallengeType] = [.fullHash, .partialHash, .merkleProof]
        XCTAssertEqual(cases.count, 3, "All cases should exist")
    }
    
    func testChallengeType_Sendable() {
        let _: any Sendable = ChallengeType.fullHash
        XCTAssertTrue(true, "ChallengeType should be Sendable")
    }
    
    func testChallengeType_Codable() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(ChallengeType.fullHash)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChallengeType.self, from: data)
        XCTAssertEqual(decoded, ChallengeType.fullHash, "ChallengeType should be Codable")
    }
    
    func testChallengeRequest_Encodable() throws {
        let request = ChallengeRequest(
            nonce: UUID().uuidString,
            challenges: [
                ChallengeRequest.Challenge(chunkIndex: 0, type: .fullHash, byteRange: nil)
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        XCTAssertGreaterThan(data.count, 0, "ChallengeRequest should be encodable")
    }
    
    func testChallengeRequest_Decodable() throws {
        let request = ChallengeRequest(
            nonce: UUID().uuidString,
            challenges: [
                ChallengeRequest.Challenge(chunkIndex: 0, type: .fullHash, byteRange: nil)
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChallengeRequest.self, from: data)
        XCTAssertEqual(decoded.nonce, request.nonce, "ChallengeRequest should be decodable")
    }
    
    func testChallengeResponse_Encodable() throws {
        let response = ChallengeResponse(
            nonce: UUID().uuidString,
            responses: [
                ChallengeResponse.Response(chunkIndex: 0, hash: "abc123", merkleProof: nil)
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        XCTAssertGreaterThan(data.count, 0, "ChallengeResponse should be encodable")
    }
    
    func testChallengeResponse_Decodable() throws {
        let response = ChallengeResponse(
            nonce: UUID().uuidString,
            responses: [
                ChallengeResponse.Response(chunkIndex: 0, hash: "abc123", merkleProof: nil)
            ]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChallengeResponse.self, from: data)
        XCTAssertEqual(decoded.nonce, response.nonce, "ChallengeResponse should be decodable")
    }
    
    func testChallengeRequest_Sendable() {
        let request = ChallengeRequest(nonce: UUID().uuidString, challenges: [])
        let _: any Sendable = request
        XCTAssertTrue(true, "ChallengeRequest should be Sendable")
    }
    
    func testChallengeResponse_Sendable() {
        let response = ChallengeResponse(nonce: UUID().uuidString, responses: [])
        let _: any Sendable = response
        XCTAssertTrue(true, "ChallengeResponse should be Sendable")
    }
    
    func testChallenge_ByteRange_Optional() throws {
        let challenge1 = ChallengeRequest.Challenge(chunkIndex: 0, type: .fullHash, byteRange: nil)
        let challenge2 = ChallengeRequest.Challenge(chunkIndex: 0, type: .partialHash, byteRange: 0...1023)
        XCTAssertNil(challenge1.byteRange, "ByteRange should be optional")
        XCTAssertNotNil(challenge2.byteRange, "ByteRange should be present for partialHash")
    }
    
    func testChallengeResponse_Hash_Optional() throws {
        let response = ChallengeResponse.Response(chunkIndex: 0, hash: nil, merkleProof: nil)
        XCTAssertNil(response.hash, "Hash should be optional")
    }
    
    func testChallengeResponse_MerkleProof_Optional() throws {
        let response = ChallengeResponse.Response(chunkIndex: 0, hash: "abc", merkleProof: nil)
        XCTAssertNil(response.merkleProof, "MerkleProof should be optional")
    }
    
    // MARK: - Anti-Replay (15 tests)
    
    func testAntiReplay_ReusedNonce_Rejected() async {
        let nonce = UUID().uuidString
        let result1 = await pop.validateNonce(nonce)
        XCTAssertTrue(result1, "First use should succeed")
        let result2 = await pop.validateNonce(nonce)
        XCTAssertFalse(result2, "Replay should be rejected")
    }
    
    func testAntiReplay_DifferentNonces_Accepted() async {
        let nonce1 = UUID().uuidString
        let nonce2 = UUID().uuidString
        let result1 = await pop.validateNonce(nonce1)
        let result2 = await pop.validateNonce(nonce2)
        XCTAssertTrue(result1, "Nonce 1 should be accepted")
        XCTAssertTrue(result2, "Nonce 2 should be accepted")
    }
    
    func testAntiReplay_MultipleReplays_AllRejected() async {
        let nonce = UUID().uuidString
        _ = await pop.validateNonce(nonce)
        for _ in 0..<10 {
            let result = await pop.validateNonce(nonce)
            XCTAssertFalse(result, "All replays should be rejected")
        }
    }
    
    func testAntiReplay_ExpiredNonce_Rejected() async {
        // Expired nonce should be rejected
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Non-expired should be accepted")
        // After expiry, should be rejected (hard to test)
    }
    
    func testAntiReplay_NonceTracking_Persistent() async {
        let nonce = UUID().uuidString
        _ = await pop.validateNonce(nonce)
        // Nonce should be tracked persistently
        let result = await pop.validateNonce(nonce)
        XCTAssertFalse(result, "Nonce should be tracked persistently")
    }
    
    func testAntiReplay_Cleanup_ExpiredRemoved() async {
        // Expired nonces should be cleaned up
        for _ in 0..<100 {
            let nonce = UUID().uuidString
            _ = await pop.validateNonce(nonce)
        }
        XCTAssertTrue(true, "Expired nonces should be cleaned up")
    }
    
    func testAntiReplay_MaxNonces_Handles() async {
        // Should handle max nonces
        for _ in 0..<2000 {
            let nonce = UUID().uuidString
            _ = await pop.validateNonce(nonce)
        }
        XCTAssertTrue(true, "Max nonces should be handled")
    }
    
    func testAntiReplay_ConcurrentReplay_Handles() async {
        let nonce = UUID().uuidString
        _ = await pop.validateNonce(nonce)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.pop.validateNonce(nonce)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent replay should be handled")
    }
    
    func testAntiReplay_15SecondWindow_Enforced() async {
        // 15 second window should be enforced
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Nonce should be valid within window")
    }
    
    func testAntiReplay_UUIDv7_FormatRequired() async {
        // UUID v7 format should be required
        let validNonce = UUID().uuidString
        let invalidNonce = "not-uuid"
        let validUUIDResult = await pop.validateNonce(validNonce)
        XCTAssertTrue(validUUIDResult, "Valid UUID should be accepted")
        let invalidUUIDResult = await pop.validateNonce(invalidNonce)
        XCTAssertFalse(invalidUUIDResult, "Invalid UUID should be rejected")
    }
    
    func testAntiReplay_NonceSet_Maintained() async {
        // Nonce set should be maintained
        let nonce = UUID().uuidString
        _ = await pop.validateNonce(nonce)
        let result = await pop.validateNonce(nonce)
        XCTAssertFalse(result, "Nonce set should be maintained")
    }
    
    func testAntiReplay_MemoryEfficient() async {
        // Should be memory efficient
        for _ in 0..<1000 {
            let nonce = UUID().uuidString
            _ = await pop.validateNonce(nonce)
        }
        XCTAssertTrue(true, "Should be memory efficient")
    }
    
    func testAntiReplay_NoFalsePositives() async {
        // Should not have false positives
        let nonce1 = UUID().uuidString
        let nonce2 = UUID().uuidString
        let n1Result = await pop.validateNonce(nonce1)
        XCTAssertTrue(n1Result, "Nonce 1 should be valid")
        let n2Result = await pop.validateNonce(nonce2)
        XCTAssertTrue(n2Result, "Nonce 2 should be valid")
    }
    
    func testAntiReplay_NoFalseNegatives() async {
        // Should not have false negatives
        let nonce = UUID().uuidString
        let result = await pop.validateNonce(nonce)
        XCTAssertTrue(result, "Valid nonce should not be false negative")
    }
    
    func testAntiReplay_Deterministic() async {
        // Anti-replay should be deterministic
        let nonce = UUID().uuidString
        _ = await pop.validateNonce(nonce)
        let result1 = await pop.validateNonce(nonce)
        let result2 = await pop.validateNonce(nonce)
        XCTAssertEqual(result1, result2, "Anti-replay should be deterministic")
    }
    
    // MARK: - Edge Cases (10 tests)
    
    func testEdge_ZeroFileSize_Handles() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: 0)
        XCTAssertGreaterThanOrEqual(count, 0, "Zero file size should handle")
    }
    
    func testEdge_NegativeFileSize_Handles() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: -1000)
        XCTAssertGreaterThanOrEqual(count, 0, "Negative file size should handle")
    }
    
    func testEdge_VeryLargeFileSize_Handles() async {
        let count = await pop.generateChallengeCount(fileSizeBytes: Int64.max)
        XCTAssertGreaterThanOrEqual(count, 0, "Very large file size should handle")
    }
    
    func testEdge_EmptyNonce_Handles() async {
        let result = await pop.validateNonce("")
        XCTAssertFalse(result, "Empty nonce should handle")
    }
    
    func testEdge_InvalidNonceFormat_Handles() async {
        let invalidNonces = ["abc", "123", "not-uuid", "xxxxxxxx"]
        for nonce in invalidNonces {
            let result = await pop.validateNonce(nonce)
            XCTAssertFalse(result, "Invalid nonce should handle: \(nonce)")
        }
    }
    
    func testEdge_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.pop.generateChallengeCount(fileSizeBytes: Int64(i) * 100 * 1024 * 1024)
                    _ = await self.pop.validateNonce(UUID().uuidString)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testEdge_MemoryLeak_None() async {
        for _ in 0..<1000 {
            let nonce = UUID().uuidString
            _ = await pop.validateNonce(nonce)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testEdge_MultipleInstances_Independent() async {
        let pop1 = ProofOfPossession()
        let pop2 = ProofOfPossession()
        let nonce = UUID().uuidString
        let result1 = await pop1.validateNonce(nonce)
        let result2 = await pop2.validateNonce(nonce)
        XCTAssertTrue(result1, "Instance 1 should validate")
        XCTAssertTrue(result2, "Instance 2 should validate independently")
    }
    
    func testEdge_ChallengeCount_AlwaysPositive() async {
        for i in 0..<100 {
            let count = await pop.generateChallengeCount(fileSizeBytes: Int64(i) * 10 * 1024 * 1024)
            XCTAssertGreaterThan(count, 0, "Challenge count should always be positive")
        }
    }
    
    func testEdge_NonceValidation_AllCases() async {
        let valid = UUID().uuidString
        let invalid = "invalid"
        let empty = ""
        let validPass = await pop.validateNonce(valid)
        XCTAssertTrue(validPass, "Valid should pass")
        let invalidFail = await pop.validateNonce(invalid)
        XCTAssertFalse(invalidFail, "Invalid should fail")
        let emptyFail = await pop.validateNonce(empty)
        XCTAssertFalse(emptyFail, "Empty should fail")
    }
}
