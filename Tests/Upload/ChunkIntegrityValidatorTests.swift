//
//  ChunkIntegrityValidatorTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Chunk Integrity Validator Tests
//

import XCTest
@testable import Aether3DCore

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

final class ChunkIntegrityValidatorTests: XCTestCase {
    
    var validator: ChunkIntegrityValidator!
    
    override func setUp() {
        super.setUp()
        validator = ChunkIntegrityValidator()
    }
    
    override func tearDown() {
        validator = nil
        super.tearDown()
    }
    
    // MARK: - Helper Functions
    
    private func createChunkData(
        index: Int,
        data: Data,
        sha256Hex: String? = nil,
        crc32c: UInt32 = 0,
        timestamp: Date = Date(),
        nonce: String = UUID().uuidString
    ) -> ChunkData {
        let hash = sha256Hex ?? computeSHA256(data)
        return ChunkData(
            index: index,
            data: data,
            sha256Hex: hash,
            crc32c: crc32c,
            timestamp: timestamp,
            nonce: nonce
        )
    }
    
    private func createSessionContext(
        sessionId: String = UUID().uuidString,
        totalChunks: Int = 10,
        expectedFileSize: Int64 = 20 * 1024 * 1024,
        lastChunkIndex: Int = -1,
        lastCommitment: String? = nil
    ) -> UploadSessionContext {
        return UploadSessionContext(
            sessionId: sessionId,
            totalChunks: totalChunks,
            expectedFileSize: expectedFileSize,
            lastChunkIndex: lastChunkIndex,
            lastCommitment: lastCommitment
        )
    }
    
    private func computeSHA256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let hash = CryptoKit.SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let hash = Crypto.SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
        #else
        fatalError("No crypto backend available")
        #endif
    }
    
    // MARK: - Pre-Upload Validation
    
    func testPreUpload_ValidChunk_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Valid chunk should pass validation")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_HashMismatch_ReturnsInvalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(
            index: 0,
            data: data,
            sha256Hex: "0000000000000000000000000000000000000000000000000000000000000000"
        )
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .hashMismatch, "Hash mismatch should be detected")
        } else {
            XCTFail("Expected invalid result for hash mismatch")
    
        }
    }
    func testPreUpload_IndexNegative_ReturnsInvalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: -1, data: data)
        let session = createSessionContext(totalChunks: 10)
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .indexOutOfRange, "Negative index should be rejected")
        } else {
            XCTFail("Expected invalid result for negative index")
    
        }
    }
    func testPreUpload_IndexTooLarge_ReturnsInvalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 10, data: data)
        let session = createSessionContext(totalChunks: 10)
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .indexOutOfRange, "Index >= totalChunks should be rejected")
        } else {
            XCTFail("Expected invalid result for index too large")
    
        }
    }
    func testPreUpload_IndexAtBoundary_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 9, data: data)
        let session = createSessionContext(totalChunks: 10)
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Index at boundary (totalChunks-1) should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_SizeTooSmall_NonLastChunk_ReturnsInvalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MIN_BYTES - 1)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext(totalChunks: 10)
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .sizeOutOfBounds, "Size below minimum should be rejected for non-last chunk")
        } else {
            XCTFail("Expected invalid result for size too small")
    
        }
    }
    func testPreUpload_SizeTooSmall_LastChunk_ReturnsValid() async {
        let data = Data(repeating: 1, count: 100)
        let chunk = createChunkData(index: 9, data: data)
        let session = createSessionContext(totalChunks: 10, lastChunkIndex: 8)
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Last chunk can be smaller than minimum")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_SizeTooLarge_ReturnsInvalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MAX_BYTES + 1)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .sizeOutOfBounds, "Size above maximum should be rejected")
        } else {
            XCTFail("Expected invalid result for size too large")
    
        }
    }
    func testPreUpload_SizeAtMinimum_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MIN_BYTES)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Size at minimum should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_SizeAtMaximum_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MAX_BYTES)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Size at maximum should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_CounterNotMonotonic_ReturnsInvalid() async {
        let sessionId = UUID().uuidString
        let session = createSessionContext(sessionId: sessionId)
        
        // First chunk
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = createChunkData(index: 1, data: data1)
        let result1 = await validator.validatePreUpload(chunk: chunk1, session: session)
        if case .valid = result1 {
            XCTAssertTrue(true, "First chunk should be valid")
        } else {
            XCTFail("Expected valid result")
        
        // Second chunk with lower index
        let data2 = Data(repeating: 2, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk2 = createChunkData(index: 0, data: data2)
        let result2 = await validator.validatePreUpload(chunk: chunk2, session: session)
        
        if case .invalid(let reason) = result2 {
            XCTAssertEqual(reason, .counterNotMonotonic, "Counter should be monotonic")
        } else {
            XCTFail("Expected invalid result for non-monotonic counter")
    
            }
        }
    }
    func testPreUpload_CounterMonotonic_ReturnsValid() async {
        let sessionId = UUID().uuidString
        let session = createSessionContext(sessionId: sessionId)
        
        // First chunk
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = createChunkData(index: 0, data: data1)
        let result1 = await validator.validatePreUpload(chunk: chunk1, session: session)
        if case .valid = result1 {
            XCTAssertTrue(true, "First chunk should be valid")
        } else {
            XCTFail("Expected valid result")
        
        // Second chunk with higher index
        let data2 = Data(repeating: 2, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk2 = createChunkData(index: 1, data: data2)
        let result2 = await validator.validatePreUpload(chunk: chunk2, session: session)
        
        if case .valid = result2 {
            XCTAssertTrue(true, "Monotonic counter should be valid")
        } else {
            XCTFail("Expected valid result")
    
            }
        }
    }
    func testPreUpload_CounterSameIndex_ReturnsInvalid() async {
        let sessionId = UUID().uuidString
        let session = createSessionContext(sessionId: sessionId)
        
        // First chunk
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = createChunkData(index: 0, data: data1)
        let result1 = await validator.validatePreUpload(chunk: chunk1, session: session)
        if case .valid = result1 {
            XCTAssertTrue(true, "First chunk should be valid")
        } else {
            XCTFail("Expected valid result")
        
        // Second chunk with same index
        let data2 = Data(repeating: 2, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk2 = createChunkData(index: 0, data: data2)
        let result2 = await validator.validatePreUpload(chunk: chunk2, session: session)
        
        if case .invalid(let reason) = result2 {
            XCTAssertEqual(reason, .counterNotMonotonic, "Same index should be rejected")
        } else {
            XCTFail("Expected invalid result for same index")
    
            }
        }
    }
    func testPreUpload_NonceExpired_ReturnsInvalid() async {
        let expiredTimestamp = Date().addingTimeInterval(-121) // 121 seconds ago
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data, timestamp: expiredTimestamp)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .nonceExpired, "Expired nonce should be rejected")
        } else {
            XCTFail("Expected invalid result for expired nonce")
    
        }
    }
    func testPreUpload_NonceFresh_ReturnsValid() async {
        let freshTimestamp = Date().addingTimeInterval(-60) // 60 seconds ago
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data, timestamp: freshTimestamp)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Fresh nonce should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_NonceReused_ReturnsInvalid() async {
        let nonce = UUID().uuidString
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = createChunkData(index: 0, data: data1, nonce: nonce)
        let session = createSessionContext()
        
        // First use
        let result1 = await validator.validatePreUpload(chunk: chunk1, session: session)
        if case .valid = result1 {
            XCTAssertTrue(true, "First use should be valid")
        } else {
            XCTFail("Expected valid result")
        
        // Reuse same nonce
        let data2 = Data(repeating: 2, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk2 = createChunkData(index: 1, data: data2, nonce: nonce)
        let result2 = await validator.validatePreUpload(chunk: chunk2, session: session)
        
        if case .invalid(let reason) = result2 {
            XCTAssertEqual(reason, .nonceExpired, "Reused nonce should be rejected")
        } else {
            XCTFail("Expected invalid result for reused nonce")
    
            }
        }
    }
    func testPreUpload_MultipleChunks_SameSession_Valid() async {
        let sessionId = UUID().uuidString
        let session = createSessionContext(sessionId: sessionId, totalChunks: 5)
        
        for i in 0..<5 {
            let data = Data(repeating: UInt8(i), count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
            let chunk = createChunkData(index: i, data: data)
            let result = await validator.validatePreUpload(chunk: chunk, session: session)
            if case .valid = result {
                XCTAssertTrue(true, "Chunk \(i) should be valid")
            } else {
                XCTFail("Expected valid result")
    
            }
        }
    }
    func testPreUpload_MultipleSessions_IndependentCounters() async {
        let session1 = createSessionContext(sessionId: "session1", totalChunks: 5)
        let session2 = createSessionContext(sessionId: "session2", totalChunks: 5)
        
        // Both sessions start with index 0
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = createChunkData(index: 0, data: data1)
        
        let result1 = await validator.validatePreUpload(chunk: chunk1, session: session1)
        if case .valid = result1 {
            XCTAssertTrue(true, "Session1 chunk 0 should be valid")
        } else {
            XCTFail("Expected valid result")
        
        let result2 = await validator.validatePreUpload(chunk: chunk1, session: session2)
        if case .valid = result2 {
            XCTAssertTrue(true, "Session2 chunk 0 should be valid (independent counter)")
        } else {
            XCTFail("Expected valid result")
    
            }
        }
    }
    func testPreUpload_EmptyData_LastChunk_ReturnsValid() async {
        let data = Data()
        let chunk = createChunkData(index: 9, data: data)
        let session = createSessionContext(totalChunks: 10, lastChunkIndex: 8)
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Empty data for last chunk should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_LargeData_WithinMax_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MAX_BYTES - 1)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Large data within max should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_AllChecksPass_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "All checks passing should return valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_IndexZero_FirstChunk_ReturnsValid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Index 0 should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_IndexOne_SecondChunk_ReturnsValid() async {
        let sessionId = UUID().uuidString
        let session = createSessionContext(sessionId: sessionId)
        
        // First chunk
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = createChunkData(index: 0, data: data1)
        _ = await validator.validatePreUpload(chunk: chunk1, session: session)
        
        // Second chunk
        let data2 = Data(repeating: 2, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk2 = createChunkData(index: 1, data: data2)
        let result2 = await validator.validatePreUpload(chunk: chunk2, session: session)
        
        if case .valid = result2 {
            XCTAssertTrue(true, "Index 1 should be valid after index 0")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_NonceAtWindowBoundary_ReturnsValid() async {
        let boundaryTimestamp = Date().addingTimeInterval(-119.9) // Just under 120 seconds ago
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data, timestamp: boundaryTimestamp)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Nonce at window boundary should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPreUpload_NonceJustExpired_ReturnsInvalid() async {
        let expiredTimestamp = Date().addingTimeInterval(-120.1) // Just over 120 seconds
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data, timestamp: expiredTimestamp)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .nonceExpired, "Just expired nonce should be rejected")
        } else {
            XCTFail("Expected invalid result for just expired nonce")
    
        }
    }
    func testPreUpload_FutureTimestamp_ReturnsValid() async {
        let futureTimestamp = Date().addingTimeInterval(60) // 60 seconds in future
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = createChunkData(index: 0, data: data, timestamp: futureTimestamp)
        let session = createSessionContext()
        
        let result = await validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Future timestamp should be valid (clock skew tolerance)")
        } else {
            XCTFail("Expected valid result")
    
    // MARK: - Post-ACK Validation
    
        }
    }
    func testPostACK_ValidResponse_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Valid response should pass validation")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_ChunkIndexMismatch_ReturnsInvalid() async {
        let response = UploadChunkResponse(
            chunkIndex: 1,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .indexOutOfRange, "Chunk index mismatch should be detected")
        } else {
            XCTFail("Expected invalid result for chunk index mismatch")
    
        }
    }
    func testPostACK_ZeroReceivedSize_ReturnsInvalid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: 0,
            totalReceived: 0,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .sizeOutOfBounds, "Zero received size should be rejected")
        } else {
            XCTFail("Expected invalid result for zero received size")
    
        }
    }
    func testPostACK_NegativeReceivedSize_ReturnsInvalid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: -1,
            totalReceived: 0,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .sizeOutOfBounds, "Negative received size should be rejected")
        } else {
            XCTFail("Expected invalid result for negative received size")
    
        }
    }
    func testPostACK_PositiveReceivedSize_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: 1024,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Positive received size should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_AlreadyPresentStatus_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "already_present",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Already present status should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_MultipleChunks_SequentialValidation() async {
        for i in 0..<5 {
            let response = UploadChunkResponse(
                chunkIndex: i,
                chunkStatus: "stored",
                receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
                totalReceived: i + 1,
                totalChunks: 10
            )
            
            let result = await validator.validatePostACK(
                chunkIndex: i,
                serverResponse: response,
                expectedHash: "testhash"
            )
            
            if case .valid = result {
            XCTAssertTrue(true, "Chunk \(i) should be valid")
                    } else {
                        XCTFail("Expected valid result")
            XCTAssertTrue(true, "Chunk \(i) should be valid")
    
            }
        }
    }
    func testPostACK_LargeReceivedSize_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_MAX_BYTES,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Large received size should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_SmallReceivedSize_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_MIN_BYTES,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Small received size should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_LastChunk_SmallSize_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 9,
            chunkStatus: "stored",
            receivedSize: 100,
            totalReceived: 10,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 9,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Last chunk with small size should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_TotalReceivedMatches_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 4,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 5,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 4,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Total received matching chunk index should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_IndexAtBoundary_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 9,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 10,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 9,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Index at boundary should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_IndexZero_FirstChunk_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 0,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 1,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 0,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Index 0 should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testPostACK_AllFieldsMatch_ReturnsValid() async {
        let response = UploadChunkResponse(
            chunkIndex: 5,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 6,
            totalChunks: 10
        )
        
        let result = await validator.validatePostACK(
            chunkIndex: 5,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "All fields matching should be valid")
        } else {
            XCTFail("Expected valid result")
    
    // MARK: - Nonce Validation
    
        }
    }
    func testValidateNonce_FreshNonce_ReturnsTrue() async {
        let nonce = UUID().uuidString
        let timestamp = Date()
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Fresh nonce should be valid")
    
    }
    func testValidateNonce_ExpiredNonce_ReturnsFalse() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(-121) // 121 seconds ago
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertFalse(result, "Expired nonce should be invalid")
    
    }
    func testValidateNonce_ReusedNonce_ReturnsFalse() async {
        let nonce = UUID().uuidString
        let timestamp = Date()
        
        // First use
        let result1 = await validator.validateNonce(nonce, timestamp: timestamp)
        XCTAssertTrue(result1, "First use should be valid")
        
        // Reuse
        let result2 = await validator.validateNonce(nonce, timestamp: timestamp)
        XCTAssertFalse(result2, "Reused nonce should be invalid")
    
    }
    func testValidateNonce_AtWindowBoundary_ReturnsTrue() async {
        let nonce = UUID().uuidString
        // Use slightly less than 120 seconds to account for timing precision
        let timestamp = Date().addingTimeInterval(-119.9) // Just under 120 seconds ago
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Nonce at window boundary should be valid")
    
    }
    func testValidateNonce_JustExpired_ReturnsFalse() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(-120.1) // Just over 120 seconds
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertFalse(result, "Just expired nonce should be invalid")
    
    }
    func testValidateNonce_MultipleNonces_AllValid() async {
        for _ in 0..<10 {
            let nonce = UUID().uuidString
            let timestamp = Date()
            let result = await validator.validateNonce(nonce, timestamp: timestamp)
            XCTAssertTrue(result, "Each unique nonce should be valid")
    
        }
    }
    func testValidateNonce_FutureTimestamp_ReturnsTrue() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(60) // 60 seconds in future
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Future timestamp should be valid (clock skew tolerance)")
    
    }
    func testValidateNonce_LRU_Eviction_RemovesOldest() async {
        // Fill cache to maxNonces
        for i in 0..<8000 {
            let nonce = UUID().uuidString
            let timestamp = Date().addingTimeInterval(-Double(i)) // Staggered timestamps
            _ = await validator.validateNonce(nonce, timestamp: timestamp)
        
        // Add one more to trigger eviction
        let newNonce = UUID().uuidString
        let result = await validator.validateNonce(newNonce, timestamp: Date())
        XCTAssertTrue(result, "New nonce should be valid after eviction")
    
        }
    }
    func testValidateNonce_ExpiredEntries_Removed() async {
        // Add expired nonce
        let expiredNonce = UUID().uuidString
        let expiredTimestamp = Date().addingTimeInterval(-121)
        _ = await validator.validateNonce(expiredNonce, timestamp: expiredTimestamp)
        
        // Wait a bit
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Add fresh nonce (should trigger cleanup)
        let freshNonce = UUID().uuidString
        let result = await validator.validateNonce(freshNonce, timestamp: Date())
        XCTAssertTrue(result, "Fresh nonce should be valid")
        
        // Expired nonce should be removed
        let expiredResult = await validator.validateNonce(expiredNonce, timestamp: expiredTimestamp)
        XCTAssertFalse(expiredResult, "Expired nonce should be removed")
    
    }
    func testValidateNonce_20PercentEviction_WhenOverMax() async {
        // Fill cache to exactly maxNonces
        var nonces: [String] = []
        for i in 0..<8000 {
            let nonce = UUID().uuidString
            nonces.append(nonce)
            let timestamp = Date().addingTimeInterval(-Double(8000 - i))
            _ = await validator.validateNonce(nonce, timestamp: timestamp)
        
        // Add one more to trigger eviction
        let newNonce = UUID().uuidString
        _ = await validator.validateNonce(newNonce, timestamp: Date())
        
        // Oldest 20% (1600) should be evicted
        // Check that oldest nonces are no longer valid
        let oldestNonce = nonces[0]
        let oldestTimestamp = Date().addingTimeInterval(-8000)
        let result = await validator.validateNonce(oldestNonce, timestamp: oldestTimestamp)
        XCTAssertFalse(result, "Oldest nonce should be evicted")
    
        }
    }
    func testValidateNonce_UniqueNonces_AllAccepted() async {
        var results: [Bool] = []
        for _ in 0..<100 {
            let nonce = UUID().uuidString
            let result = await validator.validateNonce(nonce, timestamp: Date())
            results.append(result)
        
        let allValid = results.allSatisfy { $0 }
        XCTAssertTrue(allValid, "All unique nonces should be accepted")
    
        }
    }
    func testValidateNonce_SameNonce_DifferentTimestamps_FirstAccepted() async {
        let nonce = UUID().uuidString
        let timestamp1 = Date()
        let timestamp2 = Date().addingTimeInterval(1)
        
        let result1 = await validator.validateNonce(nonce, timestamp: timestamp1)
        XCTAssertTrue(result1, "First use should be valid")
        
        let result2 = await validator.validateNonce(nonce, timestamp: timestamp2)
        XCTAssertFalse(result2, "Same nonce with different timestamp should be rejected")
    
    }
    func testValidateNonce_EmptyString_ReturnsTrue() async {
        let nonce = ""
        let timestamp = Date()
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Empty string nonce should be valid (edge case)")
    
    }
    func testValidateNonce_VeryLongNonce_ReturnsTrue() async {
        let nonce = String(repeating: "a", count: 1000)
        let timestamp = Date()
        
        let result = await validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Very long nonce should be valid")
    
    }
    func testValidateNonce_ConcurrentValidation_NoRace() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let nonce = UUID().uuidString
                    return await self.validator.validateNonce(nonce, timestamp: Date())
                }
            }
            var validCount = 0
            for await result in group {
                if result {
                    validCount += 1
                }
            }
            XCTAssertEqual(validCount, 100, "All concurrent nonces should be valid")
        }
    }
    func testValidateNonce_TimestampMonotonicity_Enforced() async {
        let nonce1 = UUID().uuidString
        let timestamp1 = Date()
        _ = await self.validator.validateNonce(nonce1, timestamp: timestamp1)
        
        let nonce2 = UUID().uuidString
        let timestamp2 = Date().addingTimeInterval(-1) // Earlier timestamp
        let result2 = await self.validator.validateNonce(nonce2, timestamp: timestamp2)
        
        XCTAssertTrue(result2, "Earlier timestamp should still be valid if within window")
    
    }
    func testValidateNonce_MaxNonces_Reached() async {
        // Fill cache to maxNonces
        for i in 0..<8000 {
            let nonce = UUID().uuidString
            let timestamp = Date().addingTimeInterval(-Double(i))
            _ = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        // Cache should be at maxNonces
        let newNonce = UUID().uuidString
        let result = await self.validator.validateNonce(newNonce, timestamp: Date())
        XCTAssertTrue(result, "New nonce should be valid even at max capacity")
    
        }
    }
    func testValidateNonce_WindowBoundary_EdgeCase() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(-119.9) // Just under boundary
        
        let result = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Nonce exactly at window boundary should be valid")
    
    }
    func testValidateNonce_RecentTimestamp_ReturnsTrue() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(-1) // 1 second ago
        
        let result = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Recent timestamp should be valid")
    
    }
    func testValidateNonce_OldTimestamp_WithinWindow_ReturnsTrue() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(-119) // 119 seconds ago
        
        let result = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        XCTAssertTrue(result, "Old timestamp within window should be valid")
    
    // MARK: - Commitment Chain Validation
    
    }
    func testValidateCommitmentChain_FirstChunk_NoPrevious_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "testhash",
            previousCommitment: nil,
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "First chunk with no previous commitment should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testValidateCommitmentChain_WithPreviousCommitment_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "testhash",
            previousCommitment: "previoushash",
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Chunk with previous commitment should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testValidateCommitmentChain_MultipleChunks_Sequential() async {
        let sessionId = UUID().uuidString
        
        // First chunk
        let result1 = await self.validator.validateCommitmentChain(
            chunkHash: "hash1",
            previousCommitment: nil,
            sessionId: sessionId
        )
        if case .valid = result1 {
            XCTAssertTrue(true, "First chunk should be valid")
        } else {
            XCTFail("Expected valid result")
        
        // Second chunk
        let result2 = await self.validator.validateCommitmentChain(
            chunkHash: "hash2",
            previousCommitment: "hash1",
            sessionId: sessionId
        )
        if case .valid = result2 {
            XCTAssertTrue(true, "Second chunk should be valid")
        } else {
            XCTFail("Expected valid result")
    
            }
        }
    }
    func testValidateCommitmentChain_DifferentSessions_Independent() async {
        let session1 = UUID().uuidString
        let session2 = UUID().uuidString
        
        let result1 = await self.validator.validateCommitmentChain(
            chunkHash: "hash1",
            previousCommitment: nil,
            sessionId: session1
        )
        if case .valid = result1 {
            XCTAssertTrue(true, "Session1 chunk should be valid")
        } else {
            XCTFail("Expected valid result")
        
        let result2 = await self.validator.validateCommitmentChain(
            chunkHash: "hash1",
            previousCommitment: nil,
            sessionId: session2
        )
        if case .valid = result2 {
            XCTAssertTrue(true, "Session2 chunk should be valid (independent)")
        } else {
            XCTFail("Expected valid result")
    
            }
        }
    }
    func testValidateCommitmentChain_EmptyHash_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "",
            previousCommitment: nil,
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Empty hash should be valid (edge case)")
        } else {
            XCTFail("Expected valid result")
        }
    }
    
    func testValidateCommitmentChain_LongHash_ReturnsValid() async {
        let longHash = String(repeating: "a", count: 100)
        let result = await self.validator.validateCommitmentChain(
            chunkHash: longHash,
            previousCommitment: nil,
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Long hash should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testValidateCommitmentChain_SameHash_DifferentSessions_ReturnsValid() async {
        let hash = "samehash"
        let session1 = UUID().uuidString
        let session2 = UUID().uuidString
        
        let result1 = await self.validator.validateCommitmentChain(
            chunkHash: hash,
            previousCommitment: nil,
            sessionId: session1
        )
        if case .valid = result1 {
            XCTAssertTrue(true, "Session1 should be valid")
        } else {
            XCTFail("Expected valid result")
        
        let result2 = await self.validator.validateCommitmentChain(
            chunkHash: hash,
            previousCommitment: nil,
            sessionId: session2
        )
        if case .valid = result2 {
            XCTAssertTrue(true, "Session2 should be valid (same hash allowed)")
        } else {
            XCTFail("Expected valid result")
    
            }
        }
    }
    func testValidateCommitmentChain_ChainContinuity_Valid() async {
        let sessionId = UUID().uuidString
        var previousCommitment: String? = nil
        
        for i in 0..<10 {
            let hash = "hash\(i)"
            let result = await self.validator.validateCommitmentChain(
                chunkHash: hash,
                previousCommitment: previousCommitment,
                sessionId: sessionId
            )
            if case .valid = result {
            XCTAssertTrue(true, "Chunk \(i) should be valid")
                    } else {
                        XCTFail("Expected valid result")
            previousCommitment = hash
    
            }
        }
    }
    func testValidateCommitmentChain_NilPrevious_FirstChunk_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "hash1",
            previousCommitment: nil,
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Nil previous commitment for first chunk should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testValidateCommitmentChain_NonNilPrevious_SubsequentChunk_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "hash2",
            previousCommitment: "hash1",
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Non-nil previous commitment should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testValidateCommitmentChain_EmptySessionId_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "hash",
            previousCommitment: nil,
            sessionId: ""
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Empty session ID should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testValidateCommitmentChain_ConcurrentChains_NoInterference() async {
        let session1 = UUID().uuidString
        let session2 = UUID().uuidString

        await withTaskGroup(of: ValidationResult.self) { group in
            group.addTask {
                await self.validator.validateCommitmentChain(
                    chunkHash: "hash1",
                    previousCommitment: nil,
                    sessionId: session1
                )
            }
            group.addTask {
                await self.validator.validateCommitmentChain(
                    chunkHash: "hash2",
                    previousCommitment: nil,
                    sessionId: session2
                )
            }
            var results: [ValidationResult] = []
            for await result in group {
                results.append(result)
            }
            let allValid = results.allSatisfy { result in
                if case .valid = result {
                    return true
                } else {
                    return false
                }
            }
            XCTAssertTrue(allValid, "Concurrent chains should not interfere")
        }
    }
    func testValidateCommitmentChain_MultipleChunks_SameSession() async {
        let sessionId = UUID().uuidString

        for i in 0..<5 {
            let result = await self.validator.validateCommitmentChain(
                chunkHash: "hash\(i)",
                previousCommitment: i > 0 ? "hash\(i-1)" : nil,
                sessionId: sessionId
            )
            if case .valid = result {
                XCTAssertTrue(true, "Chunk \(i) should be valid")
            } else {
                XCTFail("Expected valid result")
            }
        }
    }
    func testValidateCommitmentChain_GenesisCommitment_ReturnsValid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "genesis",
            previousCommitment: nil,
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Genesis commitment should be valid")
        } else {
            XCTFail("Expected valid result")
    
    // MARK: - Edge Cases
    
        }
    }
    func testEdge_EmptyData_LastChunk_Valid() async {
        let data = Data()
        let chunk = self.createChunkData(index: 9, data: data)
        let session = self.createSessionContext(totalChunks: 10, lastChunkIndex: 8)
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Empty data for last chunk should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testEdge_MaximumChunkSize_Valid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MAX_BYTES)
        let chunk = self.createChunkData(index: 0, data: data)
        let session = self.createSessionContext()
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Maximum chunk size should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testEdge_MinimumChunkSize_Valid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_MIN_BYTES)
        let chunk = self.createChunkData(index: 0, data: data)
        let session = self.createSessionContext()
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Minimum chunk size should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testEdge_SingleChunk_Session_Valid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = self.createChunkData(index: 0, data: data)
        let session = self.createSessionContext(totalChunks: 1)
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Single chunk session should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testEdge_VeryLargeSession_Valid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = self.createChunkData(index: 0, data: data)
        let session = self.createSessionContext(totalChunks: 10000)
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .valid = result {
            XCTAssertTrue(true, "Very large session should be valid")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testEdge_ConcurrentSessions_NoInterference() async {
        await withTaskGroup(of: ValidationResult.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let sessionId = "session\(i)"
                    let data = Data(repeating: UInt8(i), count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
                    let chunk = self.createChunkData(index: 0, data: data)
                    let session = self.createSessionContext(sessionId: sessionId)
                    return await self.validator.validatePreUpload(chunk: chunk, session: session)
                }
            }
            var results: [ValidationResult] = []
            for await result in group {
                results.append(result)
            }
            let allValid = results.allSatisfy { result in
                if case .valid = result {
                    return true
                } else {
                    return false
                }
            }
            XCTAssertTrue(allValid, "Concurrent sessions should not interfere")
        }
    }
    func testEdge_RapidNonceValidation_NoRace() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    let nonce = UUID().uuidString
                    return await self.validator.validateNonce(nonce, timestamp: Date())
                }
            }
            var validCount = 0
            for await result in group {
                if result {
                    validCount += 1
                }
            }
            XCTAssertEqual(validCount, 1000, "All rapid nonce validations should succeed")
        }
    }
    func testEdge_MaxNonces_EvictionWorks() async {
        // Fill to max
        for i in 0..<8000 {
            let nonce = UUID().uuidString
            let timestamp = Date().addingTimeInterval(-Double(8000 - i))
            _ = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        // Add more to trigger eviction
        for i in 0..<100 {
            let nonce = UUID().uuidString
            let result = await self.validator.validateNonce(nonce, timestamp: Date())
            XCTAssertTrue(result, "Nonce \(i) should be valid after eviction")
    
            }
        }
    }
    func testEdge_ZeroTotalChunks_Invalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = self.createChunkData(index: 0, data: data)
        let session = self.createSessionContext(totalChunks: 0)
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .indexOutOfRange, "Zero total chunks should reject any index")
        } else {
            XCTFail("Expected invalid result for zero total chunks")
    
        }
    }
    func testEdge_NegativeTotalChunks_Invalid() async {
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = self.createChunkData(index: 0, data: data)
        let session = self.createSessionContext(totalChunks: -1)
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .indexOutOfRange, "Negative total chunks should reject any index")
        } else {
            XCTFail("Expected invalid result for negative total chunks")
    
        }
    }
    func testEdge_NonceCache_Overflow_Handled() async {
        // Fill cache beyond max
        for i in 0..<10000 {
            let nonce = UUID().uuidString
            let timestamp = Date().addingTimeInterval(-Double(10000 - i))
            _ = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        // Cache should be trimmed
        let newNonce = UUID().uuidString
        let result = await self.validator.validateNonce(newNonce, timestamp: Date())
        XCTAssertTrue(result, "New nonce should be valid after overflow handling")
    
        }
    }
    func testEdge_MultipleErrors_FirstErrorReturned() async {
        // Create chunk with multiple errors: negative index + hash mismatch
        let data = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk = self.createChunkData(
            index: -1,
            data: data,
            sha256Hex: "wronghash"
        )
        let session = self.createSessionContext()
        
        let result = await self.validator.validatePreUpload(chunk: chunk, session: session)
        
        // Should return first error (indexOutOfRange)
        if case .invalid(let reason) = result {
            XCTAssertEqual(reason, .indexOutOfRange, "First error should be returned")
        } else {
            XCTFail("Expected invalid result")
    
        }
    }
    func testEdge_NonceValidation_AfterExpiration_Removed() async {
        let nonce = UUID().uuidString
        let timestamp = Date().addingTimeInterval(-60) // 60 seconds ago
        
        // First validation
        let result1 = await self.validator.validateNonce(nonce, timestamp: timestamp)
        XCTAssertTrue(result1, "First validation should be valid")
        
        // Wait for expiration
        try? await Task.sleep(nanoseconds: 61_000_000_000) // 61 seconds
        
        // Try to reuse (should fail because expired)
        let result2 = await self.validator.validateNonce(nonce, timestamp: timestamp)
        XCTAssertFalse(result2, "Expired nonce should be invalid")
    
    }
    func testEdge_SessionCounter_Reset_AfterNewSession() async {
        let session1 = self.createSessionContext(sessionId: "session1")
        let session2 = self.createSessionContext(sessionId: "session2")
        
        // Session1: chunk 0
        let data1 = Data(repeating: 1, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk1 = self.createChunkData(index: 0, data: data1)
        _ = await self.validator.validatePreUpload(chunk: chunk1, session: session1)
        
        // Session2: chunk 0 (should be valid, independent counter)
        let data2 = Data(repeating: 2, count: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES)
        let chunk2 = self.createChunkData(index: 0, data: data2)
        let result2 = await self.validator.validatePreUpload(chunk: chunk2, session: session2)
        
        if case .valid = result2 {
            XCTAssertTrue(true, "New session should have independent counter")
        } else {
            XCTFail("Expected valid result")
    
        }
    }
    func testEdge_NonceCache_LRU_OrderPreserved() async {
        // Add nonces with staggered timestamps
        var nonces: [String] = []
        for i in 0..<100 {
            let nonce = UUID().uuidString
            nonces.append(nonce)
            let timestamp = Date().addingTimeInterval(-Double(100 - i))
            _ = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        // Fill to max to trigger eviction
        for i in 100..<8000 {
            let nonce = UUID().uuidString
            let timestamp = Date().addingTimeInterval(-Double(8000 - i))
            _ = await self.validator.validateNonce(nonce, timestamp: timestamp)
        
        // Oldest should be evicted
        let oldestNonce = nonces[0]
        let oldestTimestamp = Date().addingTimeInterval(-100)
        let result = await self.validator.validateNonce(oldestNonce, timestamp: oldestTimestamp)
        XCTAssertFalse(result, "Oldest nonce should be evicted")
    
            }
        }
    }
    func testEdge_PostACK_AllFields_Validated() async {
        let response = UploadChunkResponse(
            chunkIndex: 5,
            chunkStatus: "stored",
            receivedSize: UploadConstants.CHUNK_SIZE_DEFAULT_BYTES,
            totalReceived: 6,
            totalChunks: 10
        )
        
        let result = await self.validator.validatePostACK(
            chunkIndex: 5,
            serverResponse: response,
            expectedHash: "testhash"
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "All fields validated should return valid")
        } else {
            XCTFail("Expected valid result")
        }
    }
    
    func testEdge_CommitmentChain_EmptyHash_Valid() async {
        let result = await self.validator.validateCommitmentChain(
            chunkHash: "",
            previousCommitment: nil,
            sessionId: UUID().uuidString
        )
        
        if case .valid = result {
            XCTAssertTrue(true, "Empty hash should be valid")
        } else {
            XCTFail("Expected valid result")
        }
    }
}

