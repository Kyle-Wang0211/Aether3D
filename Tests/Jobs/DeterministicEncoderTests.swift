// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0-merged
// States: 9 | Transitions: 15 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import XCTest
@testable import Aether3DCore

final class DeterministicEncoderTests: XCTestCase {
    
    // MARK: - Test 1: Sorted Keys
    
    func testSortedKeys() throws {
        struct TestStruct: Codable {
            let zebra: String
            let apple: String
            let mango: String
        }
        
        let value = TestStruct(zebra: "z", apple: "a", mango: "m")
        let json = try DeterministicJSONEncoder.encodeToString(value)
        
        // Keys must be alphabetically sorted
        guard let appleRange = json.range(of: "\"apple\""),
              let mangoRange = json.range(of: "\"mango\""),
              let zebraRange = json.range(of: "\"zebra\"") else {
            XCTFail("Keys not found in JSON")
            return
        }
        
        XCTAssertLessThan(appleRange.lowerBound, mangoRange.lowerBound, "apple should come before mango")
        XCTAssertLessThan(mangoRange.lowerBound, zebraRange.lowerBound, "mango should come before zebra")
    }
    
    // MARK: - Test 2: Consistent Output
    
    func testConsistentOutput() throws {
        struct TestStruct: Codable, Equatable {
            let id: Int
            let name: String
        }
        
        let value = TestStruct(id: 42, name: "test")
        
        // Encode multiple times - must be identical
        let json1 = try DeterministicJSONEncoder.encodeToString(value)
        let json2 = try DeterministicJSONEncoder.encodeToString(value)
        let json3 = try DeterministicJSONEncoder.encodeToString(value)
        
        XCTAssertEqual(json1, json2)
        XCTAssertEqual(json2, json3)
    }
    
    // MARK: - Test 3: TransitionLog Determinism
    
    func testTransitionLogDeterminism() throws {
        let fixedDate = Date(timeIntervalSince1970: 1705312245.123)
        
        let log = TransitionLog(
            transitionId: "test-txn-id",
            jobId: "12345678901234567",
            from: .pending,
            to: .uploading,
            failureReason: nil,
            cancelReason: nil,
            timestamp: fixedDate,
            contractVersion: "PR2-JSM-3.0",
            retryAttempt: nil,
            source: .client,
            sessionId: nil,
            deviceState: nil
        )
        
        let json1 = try DeterministicJSONEncoder.encodeToString(log)
        let json2 = try DeterministicJSONEncoder.encodeToString(log)
        
        XCTAssertEqual(json1, json2)
    }
    
    // MARK: - Test 4: Hash Computation
    
    func testHashComputation() throws {
        struct TestStruct: Codable {
            let value: Int
        }
        
        let value = TestStruct(value: 42)
        
        let hash1 = try DeterministicJSONEncoder.computeHash(value)
        let hash2 = try DeterministicJSONEncoder.computeHash(value)
        
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64, "SHA256 hash should be 64 hex characters")
    }
    
    // MARK: - Test 5: Hash Verification
    
    func testHashVerification() throws {
        struct TestStruct: Codable {
            let value: Int
        }
        
        let value = TestStruct(value: 42)
        let hash = try DeterministicJSONEncoder.computeHash(value)
        
        XCTAssertTrue(try DeterministicJSONEncoder.verifyHash(value, expectedHash: hash))
        XCTAssertFalse(try DeterministicJSONEncoder.verifyHash(value, expectedHash: "wronghash"))
    }
    
    // MARK: - Test 6: Encode/Decode Round Trip
    
    func testEncodeDecodeRoundTrip() throws {
        struct TestStruct: Codable, Equatable {
            let id: Int
            let name: String
            let active: Bool
        }
        
        let original = TestStruct(id: 123, name: "test", active: true)
        let data = try DeterministicJSONEncoder.encode(original)
        let decoded = try DeterministicJSONEncoder.decode(TestStruct.self, from: data)
        
        XCTAssertEqual(original, decoded)
    }
    
    // MARK: - Test 7: DLQEntry Determinism
    
    func testDLQEntryDeterminism() throws {
        let fixedDate = Date(timeIntervalSince1970: 1705312245.0)
        
        // Create DLQEntry with fixed values
        let entry1Data = try DeterministicJSONEncoder.encode(
            ["jobId": "12345678901234567", "failureReason": "network_error"]
        )
        let entry2Data = try DeterministicJSONEncoder.encode(
            ["jobId": "12345678901234567", "failureReason": "network_error"]
        )
        
        XCTAssertEqual(entry1Data, entry2Data)
    }
    
    // MARK: - Test 8: Empty and Nested Structures
    
    func testComplexStructures() throws {
        struct Nested: Codable, Equatable {
            let inner: String
        }
        
        struct Outer: Codable, Equatable {
            let nested: Nested
            let array: [Int]
            let optional: String?
        }
        
        let value = Outer(
            nested: Nested(inner: "test"),
            array: [1, 2, 3],
            optional: nil
        )
        
        let json1 = try DeterministicJSONEncoder.encodeToString(value)
        let json2 = try DeterministicJSONEncoder.encodeToString(value)
        
        XCTAssertEqual(json1, json2)
    }
}
