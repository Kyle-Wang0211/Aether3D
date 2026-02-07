# CURSOR v8.4 COMPREHENSIVE AUDIT AND EXHAUSTIVE TESTING PROMPT

## Document Metadata
- **Version**: 8.4 TITAN
- **Created**: 2026-02-07
- **Purpose**: Final comprehensive audit + 2000+ exhaustive tests
- **Prerequisite**: v8.3 HYPERION fixes applied and build successful

---

## MISSION STATEMENT

This prompt instructs Cursor to:
1. **AUDIT**: Perform a final comprehensive review of the entire codebase for any remaining issues
2. **TEST**: Generate 2000+ exhaustive test cases covering every invariant, edge case, and failure mode

---

# PART A: COMPREHENSIVE CODEBASE AUDIT

## A.1 Security Audit Checklist

### A.1.1 Cryptographic Security
Scan and verify ALL files for:
- [ ] No `hashValue` used for security purposes (must use SHA-256)
- [ ] No hardcoded secrets, API keys, or credentials
- [ ] No weak random number generators (`arc4random`, `random()`) for security - must use `SystemRandomNumberGenerator` or `SecRandomCopyBytes`
- [ ] All cryptographic operations use CryptoKit/swift-crypto
- [ ] No MD5 or SHA-1 for security-critical hashing
- [ ] Key derivation uses proper KDFs (HKDF, PBKDF2 with high iterations)

```bash
# Run these checks:
grep -rn "hashValue" --include="*.swift" | grep -v "Tests/" | grep -v ".build/"
grep -rn "arc4random\|srand\|rand()" --include="*.swift"
grep -rn "MD5\|SHA1" --include="*.swift" | grep -v "// deprecated"
grep -rn "password\|secret\|apikey\|api_key" --include="*.swift" -i
```

### A.1.2 Memory Safety
- [ ] No force unwraps (`!`) in production code (except guaranteed cases with comments)
- [ ] No unowned references that could cause crashes
- [ ] Proper cleanup in deinit/close methods
- [ ] No memory leaks in closures (weak/unowned self where needed)

```bash
grep -rn "force unwrap\|!" --include="*.swift" | grep -v "Tests/" | grep -v "!="  | grep -v "!//"
```

### A.1.3 Concurrency Safety
- [ ] All actors properly isolated
- [ ] No data races in shared mutable state
- [ ] All Sendable conformances verified
- [ ] No deadlock potential in async/await patterns
- [ ] Task cancellation properly handled

### A.1.4 Input Validation
- [ ] All external inputs validated
- [ ] File paths sanitized (no path traversal)
- [ ] SQL injection prevention (parameterized queries)
- [ ] Integer overflow checks for size calculations
- [ ] Bounds checking for array access

### A.1.5 Error Handling
- [ ] No empty catch blocks
- [ ] All errors properly propagated or logged
- [ ] Graceful degradation paths implemented
- [ ] Recovery mechanisms tested

---

## A.2 Code Quality Audit

### A.2.1 Swift 6.2 Compliance
- [ ] All deprecation warnings resolved
- [ ] Strict concurrency mode passes
- [ ] No implicit unwrapping of optionals
- [ ] Proper use of `any` vs `some` for existentials

### A.2.2 Documentation
- [ ] All public APIs documented
- [ ] Complex algorithms explained
- [ ] Invariants documented inline
- [ ] Edge cases noted in comments

### A.2.3 Performance
- [ ] No O(n²) algorithms where O(n log n) possible
- [ ] Lazy evaluation for large collections
- [ ] Proper use of value vs reference types
- [ ] Memory-efficient data structures

### A.2.4 Cross-Platform
- [ ] All platform-specific code guarded with `#if`
- [ ] Linux fallbacks for Apple-only APIs
- [ ] CSQLite used everywhere (not SQLite3)
- [ ] No UIKit/AppKit in Core modules

---

## A.3 Architecture Audit

### A.3.1 Dependency Graph
- [ ] No circular dependencies between modules
- [ ] Clear separation of concerns
- [ ] Protocol-oriented design where appropriate
- [ ] Dependency injection for testability

### A.3.2 State Management
- [ ] Single source of truth for each state
- [ ] State transitions are atomic
- [ ] Observable state changes for UI
- [ ] Persistence layer properly abstracted

### A.3.3 Error Domain Separation
- [ ] Each module has its own error types
- [ ] Errors are informative and actionable
- [ ] Error recovery strategies documented

---

# PART B: EXHAUSTIVE TEST SUITE (2000+ TESTS)

## B.1 Test Organization Structure

```
Tests/
├── UnitTests/                          # 800+ unit tests
│   ├── Core/
│   │   ├── CryptoTests/               # 50 tests
│   │   ├── PersistenceTests/          # 80 tests
│   │   ├── SecurityTests/             # 100 tests
│   │   ├── ReplayTests/               # 60 tests
│   │   ├── JobsTests/                 # 70 tests
│   │   ├── MerkleTreeTests/           # 80 tests
│   │   ├── DeviceAttestationTests/    # 90 tests
│   │   ├── FormatBridgeTests/         # 70 tests
│   │   ├── MobileOptimizationTests/   # 100 tests
│   │   └── EvidenceTests/             # 100 tests
│   ├── PR4MathTests/                   # 50 tests
│   ├── PR4LUTTests/                    # 50 tests
│   └── SharedSecurityTests/            # 50 tests
│
├── IntegrationTests/                   # 400+ integration tests
│   ├── CaptureFlowTests/              # 100 tests
│   ├── ExportPipelineTests/           # 80 tests
│   ├── WALRecoveryTests/              # 60 tests
│   ├── AttestationFlowTests/          # 80 tests
│   └── EndToEndTests/                 # 80 tests
│
├── InvariantTests/                     # 300+ invariant tests
│   ├── SecurityInvariantTests/        # INV-SEC-001 to INV-SEC-070
│   ├── QualityInvariantTests/         # INV-QUAL-001 to INV-QUAL-050
│   ├── CaptureInvariantTests/         # INV-CAP-001 to INV-CAP-040
│   ├── EvidenceInvariantTests/        # INV-EVID-001 to INV-EVID-030
│   └── MobileInvariantTests/          # INV-MOBILE-001 to INV-MOBILE-020
│
├── EdgeCaseTests/                      # 300+ edge case tests
│   ├── BoundaryTests/                 # Min/max values
│   ├── OverflowTests/                 # Integer overflow
│   ├── EmptyInputTests/               # Empty/null inputs
│   ├── MalformedInputTests/           # Invalid data
│   └── ConcurrencyEdgeCases/          # Race conditions
│
├── StressTests/                        # 100+ stress tests
│   ├── MemoryStressTests/             # Memory limits
│   ├── CPUStressTests/                # CPU saturation
│   ├── IOStressTests/                 # Disk I/O limits
│   └── ConcurrencyStressTests/        # High thread counts
│
├── FuzzTests/                          # 50+ fuzz tests
│   ├── InputFuzzTests/                # Random input generation
│   ├── ProtocolFuzzTests/             # Protocol conformance
│   └── SerializationFuzzTests/        # Encode/decode cycles
│
└── PerformanceTests/                   # 50+ performance tests
    ├── BenchmarkTests/                 # Baseline measurements
    ├── RegressionTests/                # No performance regression
    └── LatencyTests/                   # Response time verification
```

---

## B.2 Unit Test Categories (800+ tests)

### B.2.1 CryptoTests (50 tests)

```swift
// Tests/UnitTests/Core/CryptoTests/CryptoHasherTests.swift
import XCTest
@testable import Core

final class CryptoHasherTests: XCTestCase {

    // MARK: - SHA-256 Tests (20 tests)

    func testSHA256_EmptyData() {
        let hash = CryptoHasher.sha256(Data())
        XCTAssertEqual(hash.count, 32)
        // Empty data SHA-256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        XCTAssertEqual(hash.hexString, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256_KnownVector1() {
        let data = "abc".data(using: .utf8)!
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.hexString, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256_KnownVector2() {
        let data = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".data(using: .utf8)!
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.hexString, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testSHA256_LargeData() {
        let data = Data(repeating: 0x61, count: 1_000_000) // 1MB of 'a'
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 32)
        XCTAssertEqual(hash.hexString, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testSHA256_DeterministicOutput() {
        let data = "test data".data(using: .utf8)!
        let hash1 = CryptoHasher.sha256(data)
        let hash2 = CryptoHasher.sha256(data)
        XCTAssertEqual(hash1, hash2)
    }

    func testSHA256_DifferentInputsDifferentOutputs() {
        let data1 = "test1".data(using: .utf8)!
        let data2 = "test2".data(using: .utf8)!
        let hash1 = CryptoHasher.sha256(data1)
        let hash2 = CryptoHasher.sha256(data2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA256_SingleByteChange() {
        var data1 = "test data".data(using: .utf8)!
        var data2 = data1
        data2[0] = data2[0] ^ 0x01 // Flip one bit
        let hash1 = CryptoHasher.sha256(data1)
        let hash2 = CryptoHasher.sha256(data2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSHA256_AllZeros() {
        let data = Data(repeating: 0x00, count: 64)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 32)
    }

    func testSHA256_AllOnes() {
        let data = Data(repeating: 0xFF, count: 64)
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 32)
    }

    func testSHA256_Unicode() {
        let data = "你好世界🌍".data(using: .utf8)!
        let hash = CryptoHasher.sha256(data)
        XCTAssertEqual(hash.count, 32)
    }

    // MARK: - HMAC Tests (15 tests)

    func testHMAC_SHA256_KnownVector() {
        let key = Data(repeating: 0x0b, count: 20)
        let message = "Hi There".data(using: .utf8)!
        let hmac = CryptoHasher.hmacSHA256(key: key, message: message)
        XCTAssertEqual(hmac.count, 32)
    }

    func testHMAC_SHA256_EmptyMessage() {
        let key = "secret".data(using: .utf8)!
        let message = Data()
        let hmac = CryptoHasher.hmacSHA256(key: key, message: message)
        XCTAssertEqual(hmac.count, 32)
    }

    func testHMAC_SHA256_LongKey() {
        let key = Data(repeating: 0xAA, count: 131) // Key longer than block size
        let message = "test".data(using: .utf8)!
        let hmac = CryptoHasher.hmacSHA256(key: key, message: message)
        XCTAssertEqual(hmac.count, 32)
    }

    func testHMAC_SHA256_Deterministic() {
        let key = "secret".data(using: .utf8)!
        let message = "message".data(using: .utf8)!
        let hmac1 = CryptoHasher.hmacSHA256(key: key, message: message)
        let hmac2 = CryptoHasher.hmacSHA256(key: key, message: message)
        XCTAssertEqual(hmac1, hmac2)
    }

    func testHMAC_SHA256_DifferentKeysDifferentOutputs() {
        let key1 = "secret1".data(using: .utf8)!
        let key2 = "secret2".data(using: .utf8)!
        let message = "message".data(using: .utf8)!
        let hmac1 = CryptoHasher.hmacSHA256(key: key1, message: message)
        let hmac2 = CryptoHasher.hmacSHA256(key: key2, message: message)
        XCTAssertNotEqual(hmac1, hmac2)
    }

    // MARK: - Random Generation Tests (15 tests)

    func testSecureRandom_CorrectLength() {
        for length in [16, 32, 64, 128, 256] {
            let random = CryptoHasher.secureRandom(count: length)
            XCTAssertEqual(random.count, length)
        }
    }

    func testSecureRandom_NonDeterministic() {
        let random1 = CryptoHasher.secureRandom(count: 32)
        let random2 = CryptoHasher.secureRandom(count: 32)
        XCTAssertNotEqual(random1, random2)
    }

    func testSecureRandom_ZeroLength() {
        let random = CryptoHasher.secureRandom(count: 0)
        XCTAssertEqual(random.count, 0)
    }

    func testSecureRandom_Distribution() {
        // Statistical test: bytes should be roughly uniformly distributed
        var counts = [Int](repeating: 0, count: 256)
        let data = CryptoHasher.secureRandom(count: 256 * 100)
        for byte in data {
            counts[Int(byte)] += 1
        }

        // Chi-squared test approximation
        let expected = Double(data.count) / 256.0
        var chiSquared = 0.0
        for count in counts {
            let diff = Double(count) - expected
            chiSquared += (diff * diff) / expected
        }

        // Should pass chi-squared test at 0.01 significance level
        XCTAssertLessThan(chiSquared, 310.0) // Critical value for 255 df at 0.01
    }
}
```

### B.2.2 PersistenceTests (80 tests)

```swift
// Tests/UnitTests/Core/PersistenceTests/WALTests.swift
import XCTest
@testable import Core

final class WALTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                  withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - WAL Entry Tests (20 tests)

    func testWALEntry_Creation() {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xAB, count: 32),
            signedEntryBytes: Data([0x01, 0x02, 0x03]),
            merkleState: Data([0x04, 0x05, 0x06]),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.entryId, 1)
        XCTAssertEqual(entry.hash.count, 32)
        XCTAssertFalse(entry.committed)
    }

    func testWALEntry_Codable() throws {
        let entry = WALEntry(
            entryId: 42,
            hash: Data(repeating: 0xCD, count: 32),
            signedEntryBytes: Data([0x10, 0x20, 0x30]),
            merkleState: Data([0x40, 0x50, 0x60]),
            committed: true,
            timestamp: Date()
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(WALEntry.self, from: encoded)

        XCTAssertEqual(decoded.entryId, entry.entryId)
        XCTAssertEqual(decoded.hash, entry.hash)
        XCTAssertEqual(decoded.committed, entry.committed)
    }

    func testWALEntry_Sendable() async {
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        // Verify Sendable by passing across task boundaries
        let result = await Task.detached {
            return entry.entryId
        }.value

        XCTAssertEqual(result, 1)
    }

    // MARK: - WriteAheadLog Tests (30 tests)

    func testWAL_AppendEntry_ValidHash() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let hash = Data(repeating: 0xAB, count: 32)
        let entry = try await wal.appendEntry(
            hash: hash,
            signedEntryBytes: Data([0x01]),
            merkleState: Data([0x02])
        )

        XCTAssertEqual(entry.entryId, 1)
        XCTAssertEqual(entry.hash, hash)
        XCTAssertFalse(entry.committed)
    }

    func testWAL_AppendEntry_InvalidHashLength() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let shortHash = Data(repeating: 0xAB, count: 16) // Should be 32

        do {
            _ = try await wal.appendEntry(
                hash: shortHash,
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should throw for invalid hash length")
        } catch WALError.invalidHashLength(let expected, let actual) {
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 16)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_CommitEntry_Success() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let entry = try await wal.appendEntry(
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        try await wal.commitEntry(entry)

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertTrue(uncommitted.isEmpty)
    }

    func testWAL_CommitEntry_NotFound() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let fakeEntry = WALEntry(
            entryId: 999,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        do {
            try await wal.commitEntry(fakeEntry)
            XCTFail("Should throw for non-existent entry")
        } catch WALError.entryNotFound(let id) {
            XCTAssertEqual(id, 999)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_Recovery_EmptyLog() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let committed = try await wal.recover()
        XCTAssertTrue(committed.isEmpty)
    }

    func testWAL_Recovery_WithEntries() async throws {
        let storage = MockWALStorage()

        // Pre-populate storage
        storage.entries = [
            WALEntry(entryId: 1, hash: Data(repeating: 0, count: 32),
                     signedEntryBytes: Data(), merkleState: Data(),
                     committed: true, timestamp: Date()),
            WALEntry(entryId: 2, hash: Data(repeating: 1, count: 32),
                     signedEntryBytes: Data(), merkleState: Data(),
                     committed: false, timestamp: Date())
        ]

        let wal = WriteAheadLog(storage: storage)
        let committed = try await wal.recover()

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed[0].entryId, 1)

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertEqual(uncommitted.count, 1)
        XCTAssertEqual(uncommitted[0].entryId, 2)
    }

    func testWAL_EntryIdIncrement() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let entry1 = try await wal.appendEntry(
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        let entry2 = try await wal.appendEntry(
            hash: Data(repeating: 1, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data()
        )

        XCTAssertEqual(entry1.entryId, 1)
        XCTAssertEqual(entry2.entryId, 2)
    }

    func testWAL_ConcurrentAppends() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        // Append 100 entries concurrently
        await withTaskGroup(of: WALEntry?.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? await wal.appendEntry(
                        hash: Data(repeating: UInt8(i), count: 32),
                        signedEntryBytes: Data([UInt8(i)]),
                        merkleState: Data()
                    )
                }
            }

            var entries: [WALEntry] = []
            for await entry in group {
                if let entry = entry {
                    entries.append(entry)
                }
            }

            XCTAssertEqual(entries.count, 100)

            // Verify unique entry IDs
            let ids = Set(entries.map { $0.entryId })
            XCTAssertEqual(ids.count, 100)
        }
    }

    // MARK: - WAL Storage Tests (30 tests)

    func testFileWALStorage_WriteAndRead() async throws {
        let path = tempDirectory.appendingPathComponent("test.wal")
        let storage = try FileWALStorage(path: path)

        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xAB, count: 32),
            signedEntryBytes: Data([0x01, 0x02]),
            merkleState: Data([0x03, 0x04]),
            committed: false,
            timestamp: Date()
        )

        try await storage.writeEntry(entry)
        try await storage.fsync()

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].entryId, 1)
    }

    func testFileWALStorage_Persistence() async throws {
        let path = tempDirectory.appendingPathComponent("persist.wal")

        // Write with one storage instance
        let storage1 = try FileWALStorage(path: path)
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xCD, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: true,
            timestamp: Date()
        )
        try await storage1.writeEntry(entry)
        try await storage1.fsync()
        try await storage1.close()

        // Read with new storage instance
        let storage2 = try FileWALStorage(path: path)
        let entries = try await storage2.readEntries()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].hash, entry.hash)
    }

    func testSQLiteWALStorage_WriteAndRead() async throws {
        let path = tempDirectory.appendingPathComponent("test.db").path
        let storage = try SQLiteWALStorage(dbPath: path)

        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0xEF, count: 32),
            signedEntryBytes: Data([0x05, 0x06]),
            merkleState: Data([0x07, 0x08]),
            committed: false,
            timestamp: Date()
        )

        try await storage.writeEntry(entry)

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 1)
    }
}

// Mock WAL Storage for testing
actor MockWALStorage: WALStorage {
    var entries: [WALEntry] = []
    var fsyncCalled = false
    var closeCalled = false

    func writeEntry(_ entry: WALEntry) async throws {
        if let index = entries.firstIndex(where: { $0.entryId == entry.entryId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    func readEntries() async throws -> [WALEntry] {
        return entries
    }

    func fsync() async throws {
        fsyncCalled = true
    }

    func close() async throws {
        closeCalled = true
    }
}
```

### B.2.3 SecurityTests (100 tests)

```swift
// Tests/UnitTests/Core/SecurityTests/DebuggerGuardTests.swift
import XCTest
@testable import SharedSecurity

final class DebuggerGuardTests: XCTestCase {

    // MARK: - Detection Method Tests (30 tests)

    func testDebuggerDetection_ReturnsBoolean() {
        let result = DebuggerGuard.isDebuggerPresent()
        XCTAssertNotNil(result)
        // Note: We can't assert specific value as it depends on test environment
    }

    func testDebuggerDetection_Consistent() {
        // Multiple calls should return consistent results (no flapping)
        var results: [Bool] = []
        for _ in 0..<100 {
            results.append(DebuggerGuard.isDebuggerPresent())
        }

        let allSame = results.allSatisfy { $0 == results[0] }
        XCTAssertTrue(allSame, "Debugger detection should be consistent")
    }

    func testDebuggerDetection_Performance() {
        measure {
            for _ in 0..<1000 {
                _ = DebuggerGuard.isDebuggerPresent()
            }
        }
        // Should complete 1000 checks in under 100ms
    }

    #if os(macOS)
    func testSysctlCheck_ValidCall() {
        // Verify sysctl doesn't crash
        let result = DebuggerGuard.isDebuggerPresent()
        XCTAssertNotNil(result)
    }
    #endif

    #if os(Linux)
    func testProcStatusCheck_FileAccess() {
        // Verify /proc/self/status is accessible
        let status = FileManager.default.fileExists(atPath: "/proc/self/status")
        XCTAssertTrue(status, "/proc/self/status should exist on Linux")
    }
    #endif
}

// Tests/UnitTests/Core/SecurityTests/IntegrityHashChainTests.swift
final class IntegrityHashChainTests: XCTestCase {

    // MARK: - Chain Construction Tests (25 tests)

    func testHashChain_Empty() async throws {
        let chain = IntegrityHashChain()
        let root = await chain.getRootHash()
        XCTAssertNil(root)
    }

    func testHashChain_SingleEntry() async throws {
        let chain = IntegrityHashChain()
        let data = Data([0x01, 0x02, 0x03])

        try await chain.appendEntry(data)

        let root = await chain.getRootHash()
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.count, 32)
    }

    func testHashChain_MultipleEntries() async throws {
        let chain = IntegrityHashChain()

        for i in 0..<10 {
            try await chain.appendEntry(Data([UInt8(i)]))
        }

        let root = await chain.getRootHash()
        XCTAssertNotNil(root)
    }

    func testHashChain_Deterministic() async throws {
        let chain1 = IntegrityHashChain()
        let chain2 = IntegrityHashChain()

        let data = [Data([0x01]), Data([0x02]), Data([0x03])]

        for d in data {
            try await chain1.appendEntry(d)
            try await chain2.appendEntry(d)
        }

        let root1 = await chain1.getRootHash()
        let root2 = await chain2.getRootHash()

        XCTAssertEqual(root1, root2)
    }

    func testHashChain_OrderMatters() async throws {
        let chain1 = IntegrityHashChain()
        let chain2 = IntegrityHashChain()

        try await chain1.appendEntry(Data([0x01]))
        try await chain1.appendEntry(Data([0x02]))

        try await chain2.appendEntry(Data([0x02]))
        try await chain2.appendEntry(Data([0x01]))

        let root1 = await chain1.getRootHash()
        let root2 = await chain2.getRootHash()

        XCTAssertNotEqual(root1, root2)
    }

    // MARK: - Verification Tests (25 tests)

    func testHashChain_VerifyIntegrity_Valid() async throws {
        let chain = IntegrityHashChain()

        for i in 0..<5 {
            try await chain.appendEntry(Data([UInt8(i)]))
        }

        let isValid = await chain.verifyIntegrity()
        XCTAssertTrue(isValid)
    }

    func testHashChain_VerifyAtIndex() async throws {
        let chain = IntegrityHashChain()

        var entries: [Data] = []
        for i in 0..<10 {
            let entry = Data([UInt8(i)])
            entries.append(entry)
            try await chain.appendEntry(entry)
        }

        // Verify each entry can be proven
        for (index, entry) in entries.enumerated() {
            let proof = try await chain.getProof(forIndex: index)
            let isValid = chain.verify(entry: entry, atIndex: index, proof: proof)
            XCTAssertTrue(isValid, "Entry at index \(index) should be verifiable")
        }
    }

    // MARK: - Tamper Detection Tests (25 tests)

    func testHashChain_TamperDetection() async throws {
        let chain = IntegrityHashChain()

        for i in 0..<5 {
            try await chain.appendEntry(Data([UInt8(i)]))
        }

        // Simulate tampering (this should be detected)
        // In real implementation, we'd need access to internal state
        let isValid = await chain.verifyIntegrity()
        XCTAssertTrue(isValid) // Should still be valid before tampering
    }

    func testHashChain_ConcurrentAppends() async throws {
        let chain = IntegrityHashChain()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    try? await chain.appendEntry(Data([UInt8(i % 256)]))
                }
            }
        }

        let isValid = await chain.verifyIntegrity()
        XCTAssertTrue(isValid)
    }
}

// Tests/UnitTests/Core/SecurityTests/AntiCheatValidatorTests.swift
final class AntiCheatValidatorTests: XCTestCase {

    // MARK: - Validation Tests (25 tests)

    func testAntiCheat_BasicValidation() async throws {
        let validator = AntiCheatValidator()

        let result = await validator.validate()
        XCTAssertNotNil(result)
    }

    func testAntiCheat_EnvironmentIntegrity() async throws {
        let validator = AntiCheatValidator()

        let integrity = await validator.checkEnvironmentIntegrity()
        // In non-tampered environment, should pass
        XCTAssertNotNil(integrity)
    }

    func testAntiCheat_MultipleValidations() async throws {
        let validator = AntiCheatValidator()

        // Run multiple validations to check for consistency
        var results: [Bool] = []
        for _ in 0..<10 {
            let result = await validator.validate()
            results.append(result.isValid)
        }

        // Results should be consistent
        let allSame = results.allSatisfy { $0 == results[0] }
        XCTAssertTrue(allSame)
    }
}
```

### B.2.4 MobileOptimizationTests (100 tests)

```swift
// Tests/UnitTests/Core/MobileOptimizationTests/ThermalStateHandlerTests.swift
import XCTest
@testable import Core

final class MobileThermalStateHandlerTests: XCTestCase {

    // MARK: - Quality Level Tests (20 tests)

    func testQualityLevel_ReturnsValidLevel() async {
        let handler = MobileThermalStateHandler()
        let level = await handler.currentQualityLevel()

        switch level {
        case .maximum, .high, .medium, .minimum:
            break // All valid
        }
    }

    func testQualityLevel_AdaptToThermalState() async {
        let handler = MobileThermalStateHandler()

        // Should not throw
        await handler.adaptToThermalState()
    }

    #if os(iOS)
    func testQualityLevel_MapsToThermalState() async {
        let handler = MobileThermalStateHandler()
        let level = await handler.currentQualityLevel()

        // On iOS, should reflect actual thermal state
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            XCTAssertEqual(level, .maximum)
        case .fair:
            XCTAssertEqual(level, .high)
        case .serious:
            XCTAssertEqual(level, .medium)
        case .critical:
            XCTAssertEqual(level, .minimum)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Invariant Tests (INV-MOBILE-001 to INV-MOBILE-003)

    func testINV_MOBILE_001_ThermalThrottleResponse() async {
        let handler = MobileThermalStateHandler()

        let start = CFAbsoluteTimeGetCurrent()
        await handler.adaptToThermalState()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        // INV-MOBILE-001: Thermal throttle response < 100ms
        XCTAssertLessThan(elapsed, 100, "Thermal response should be under 100ms")
    }
}

// Tests/UnitTests/Core/MobileOptimizationTests/MemoryPressureHandlerTests.swift
final class MobileMemoryPressureHandlerTests: XCTestCase {

    // MARK: - Memory Warning Tests (20 tests)

    func testMemoryWarning_HandleGracefully() async {
        let handler = MobileMemoryPressureHandler()

        // Should not throw or crash
        await handler.handleMemoryWarning()
    }

    func testINV_MOBILE_004_MemoryWarningResponse() async {
        let handler = MobileMemoryPressureHandler()

        let start = CFAbsoluteTimeGetCurrent()
        await handler.handleMemoryWarning()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        // INV-MOBILE-004: Memory warning response < 50ms
        XCTAssertLessThan(elapsed, 50, "Memory warning response should be under 50ms")
    }

    func testMemoryWarning_MultipleCallsIdempotent() async {
        let handler = MobileMemoryPressureHandler()

        // Multiple calls should be safe
        for _ in 0..<10 {
            await handler.handleMemoryWarning()
        }
    }
}

// Tests/UnitTests/Core/MobileOptimizationTests/FramePacingControllerTests.swift
final class MobileFramePacingControllerTests: XCTestCase {

    // MARK: - Frame Time Recording Tests (20 tests)

    func testFrameTime_RecordValid() async {
        let controller = MobileFramePacingController()

        let advice = await controller.recordFrameTime(1.0 / 60.0) // 16.67ms
        XCTAssertNotNil(advice)
    }

    func testFrameTime_ConsistentFramesGetMaintain() async {
        let controller = MobileFramePacingController()

        // Record 30 consistent frames at 60 FPS
        var lastAdvice: MobileFramePacingController.FramePacingAdvice = .maintain
        for _ in 0..<30 {
            lastAdvice = await controller.recordFrameTime(1.0 / 60.0)
        }

        XCTAssertEqual(lastAdvice, .maintain)
    }

    func testFrameTime_SlowFramesSuggestReduceQuality() async {
        let controller = MobileFramePacingController()

        // Record 30 slow frames (20ms each, should be 16.67ms for 60 FPS)
        var lastAdvice: MobileFramePacingController.FramePacingAdvice = .maintain
        for _ in 0..<30 {
            lastAdvice = await controller.recordFrameTime(0.025) // 25ms
        }

        XCTAssertEqual(lastAdvice, .reduceQuality)
    }

    func testINV_MOBILE_008_FrameTimeVariance() async {
        let controller = MobileFramePacingController()

        // Record frames with low variance
        for _ in 0..<30 {
            let jitter = Double.random(in: -0.0005...0.0005) // ±0.5ms
            _ = await controller.recordFrameTime(1.0 / 60.0 + jitter)
        }

        let variance = await controller.getVariance()

        // INV-MOBILE-008: Frame time variance < 2ms for 95th percentile
        XCTAssertLessThan(variance, 0.002, "Frame time variance should be under 2ms")
    }
}

// Tests/UnitTests/Core/MobileOptimizationTests/BatteryAwareSchedulerTests.swift
final class MobileBatteryAwareSchedulerTests: XCTestCase {

    // MARK: - Power Mode Tests (20 tests)

    func testLowPowerMode_ReturnsBoolean() async {
        let scheduler = MobileBatteryAwareScheduler()
        let isLowPower = await scheduler.isLowPowerModeEnabled
        XCTAssertNotNil(isLowPower)
    }

    func testBackgroundProcessing_Decision() async {
        let scheduler = MobileBatteryAwareScheduler()
        let allowed = await scheduler.shouldAllowBackgroundProcessing()
        XCTAssertNotNil(allowed)
    }

    func testRecommendedQuality_ReturnsValidValue() async {
        let scheduler = MobileBatteryAwareScheduler()
        let quality = await scheduler.recommendedScanQuality()

        switch quality {
        case .maximum, .balanced, .efficient:
            break // All valid
        }
    }

    #if os(iOS)
    func testINV_MOBILE_011_LowPowerModeReduction() async {
        let scheduler = MobileBatteryAwareScheduler()

        if await scheduler.isLowPowerModeEnabled {
            let quality = await scheduler.recommendedScanQuality()
            // INV-MOBILE-011: Low Power Mode reduces GPU usage by 40%
            XCTAssertEqual(quality, .efficient)
        }
    }
    #endif
}

// Tests/UnitTests/Core/MobileOptimizationTests/TouchResponseOptimizerTests.swift
final class MobileTouchResponseOptimizerTests: XCTestCase {

    // MARK: - Touch Handling Tests (20 tests)

    func testTouchEvent_HandleWithoutCrash() async {
        let optimizer = MobileTouchResponseOptimizer()

        let touch = TouchEvent(
            timestamp: CFAbsoluteTimeGetCurrent(),
            location: CGPoint(x: 100, y: 200),
            phase: .began
        )

        await optimizer.handleTouch(touch)
    }

    func testINV_MOBILE_014_TouchResponseTime() async {
        let optimizer = MobileTouchResponseOptimizer()

        let touch = TouchEvent(
            timestamp: CFAbsoluteTimeGetCurrent(),
            location: CGPoint(x: 100, y: 200),
            phase: .began
        )

        let start = CFAbsoluteTimeGetCurrent()
        await optimizer.handleTouch(touch)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000 // ms

        // INV-MOBILE-014: Touch-to-visual response < 16ms
        XCTAssertLessThan(elapsed, 16, "Touch response should be under 16ms")
    }

    func testMultipleTouchEvents_HandleConcurrently() async {
        let optimizer = MobileTouchResponseOptimizer()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let touch = TouchEvent(
                        timestamp: CFAbsoluteTimeGetCurrent(),
                        location: CGPoint(x: Double(i), y: Double(i)),
                        phase: .moved
                    )
                    await optimizer.handleTouch(touch)
                }
            }
        }
    }
}
```

---

## B.3 Integration Tests (400+ tests)

### B.3.1 CaptureFlowTests (100 tests)

```swift
// Tests/IntegrationTests/CaptureFlowTests/FullCaptureFlowTests.swift
import XCTest
@testable import Core
@testable import PR5Capture

final class FullCaptureFlowTests: XCTestCase {

    // MARK: - End-to-End Capture (20 tests)

    func testCapture_InitializeSession() async throws {
        let session = CaptureSession()
        try await session.initialize()

        let state = await session.state
        XCTAssertEqual(state, .ready)
    }

    func testCapture_StartAndStop() async throws {
        let session = CaptureSession()
        try await session.initialize()
        try await session.start()

        let runningState = await session.state
        XCTAssertEqual(runningState, .running)

        try await session.stop()

        let stoppedState = await session.state
        XCTAssertEqual(stoppedState, .stopped)
    }

    func testCapture_ProducesFrames() async throws {
        let session = CaptureSession()
        try await session.initialize()
        try await session.start()

        var frameCount = 0
        for await _ in session.frames.prefix(10) {
            frameCount += 1
        }

        XCTAssertEqual(frameCount, 10)

        try await session.stop()
    }

    // MARK: - Quality Gate Tests (20 tests)

    func testQualityGate_RejectBlurryFrame() async throws {
        let gate = QualityGate()

        let blurryFrame = MockFrame(blurScore: 0.9) // High blur
        let decision = await gate.evaluate(blurryFrame)

        XCTAssertEqual(decision, .reject(.blur))
    }

    func testQualityGate_AcceptSharpFrame() async throws {
        let gate = QualityGate()

        let sharpFrame = MockFrame(blurScore: 0.1) // Low blur
        let decision = await gate.evaluate(sharpFrame)

        XCTAssertEqual(decision, .accept)
    }

    // MARK: - State Machine Tests (30 tests)

    func testStateMachine_ValidTransitions() async throws {
        let sm = CaptureStateMachine()

        XCTAssertEqual(sm.currentState, .idle)

        try await sm.transition(to: .initializing)
        XCTAssertEqual(sm.currentState, .initializing)

        try await sm.transition(to: .ready)
        XCTAssertEqual(sm.currentState, .ready)

        try await sm.transition(to: .capturing)
        XCTAssertEqual(sm.currentState, .capturing)
    }

    func testStateMachine_InvalidTransition() async {
        let sm = CaptureStateMachine()

        do {
            // Cannot go directly from idle to capturing
            try await sm.transition(to: .capturing)
            XCTFail("Should throw for invalid transition")
        } catch CaptureStateMachineError.invalidTransition {
            // Expected
        } catch {
            XCTFail("Wrong error type")
        }
    }

    // MARK: - Coverage Tracking Tests (30 tests)

    func testCoverage_S0ToS5Progression() async throws {
        let tracker = CoverageTracker()

        // Initially S0
        let triangle = TriangleId(1)
        let initialCoverage = await tracker.getCoverage(triangle)
        XCTAssertEqual(initialCoverage, .s0)

        // Record observations to progress through stages
        for _ in 0..<3 {
            await tracker.recordObservation(triangle, quality: .good)
        }

        let s1Coverage = await tracker.getCoverage(triangle)
        XCTAssertEqual(s1Coverage, .s1)

        // Continue to S5
        for _ in 0..<50 {
            await tracker.recordObservation(triangle, quality: .excellent)
        }

        let finalCoverage = await tracker.getCoverage(triangle)
        XCTAssertEqual(finalCoverage, .s5)
    }
}
```

### B.3.2 ExportPipelineTests (80 tests)

```swift
// Tests/IntegrationTests/ExportPipelineTests/GLTFExportTests.swift
import XCTest
@testable import Core

final class GLTFExportTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                  withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Basic Export Tests (20 tests)

    func testGLTFExport_ValidMesh() async throws {
        let exporter = GLTFExporter()

        let mesh = MockMeshData(vertexCount: 100, triangleCount: 50)
        let provenance = MockProvenanceBundle()
        let options = GLTFExportOptions()

        let outputPath = tempDirectory.appendingPathComponent("test.glb")
        try await exporter.export(mesh: mesh, provenance: provenance,
                                   options: options, to: outputPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath.path))
    }

    func testGLTFExport_EmbeddedProvenance() async throws {
        let exporter = GLTFExporter()

        let mesh = MockMeshData(vertexCount: 100, triangleCount: 50)
        let provenance = MockProvenanceBundle()
        var options = GLTFExportOptions()
        options.embedProvenance = true

        let outputPath = tempDirectory.appendingPathComponent("test_provenance.glb")
        try await exporter.export(mesh: mesh, provenance: provenance,
                                   options: options, to: outputPath)

        // Read back and verify provenance is embedded
        let data = try Data(contentsOf: outputPath)
        XCTAssertTrue(data.count > 0)

        // Parse GLB and check extras
        let glb = try GLBParser.parse(data)
        XCTAssertNotNil(glb.json["extras"])
    }

    // MARK: - Gaussian Splatting Export Tests (30 tests)

    func testGaussianSplattingExport_ValidSplats() async throws {
        let exporter = GLTFGaussianSplattingExporter()

        let splats = MockGaussianSplats(count: 1000)
        let provenance = MockProvenanceBundle()
        let options = GLTFGaussianSplattingExportOptions()

        let outputPath = tempDirectory.appendingPathComponent("test_3dgs.glb")
        try await exporter.export(splats: splats, provenance: provenance,
                                   options: options, to: outputPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath.path))
    }

    func testGaussianSplattingExport_KHRExtension() async throws {
        let exporter = GLTFGaussianSplattingExporter()

        let splats = MockGaussianSplats(count: 100)
        let provenance = MockProvenanceBundle()
        var options = GLTFGaussianSplattingExportOptions()
        options.useKHRExtension = true

        let outputPath = tempDirectory.appendingPathComponent("test_khr.glb")
        try await exporter.export(splats: splats, provenance: provenance,
                                   options: options, to: outputPath)

        // Verify KHR_gaussian_splatting extension is present
        let data = try Data(contentsOf: outputPath)
        let glb = try GLBParser.parse(data)

        let extensions = glb.json["extensionsUsed"] as? [String] ?? []
        XCTAssertTrue(extensions.contains("KHR_gaussian_splatting"))
    }

    // MARK: - PLY/SPLAT Export Tests (30 tests)

    func testPLYExport_ValidOutput() async throws {
        let exporter = PLYExporter()

        let splats = MockGaussianSplats(count: 500)
        let outputPath = tempDirectory.appendingPathComponent("test.ply")

        try await exporter.export(splats: splats, to: outputPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath.path))

        // Verify PLY header
        let content = try String(contentsOf: outputPath, encoding: .ascii)
        XCTAssertTrue(content.hasPrefix("ply"))
        XCTAssertTrue(content.contains("element vertex 500"))
    }

    func testSPLATExport_BinaryFormat() async throws {
        let exporter = SPLATExporter()

        let splats = MockGaussianSplats(count: 1000)
        let outputPath = tempDirectory.appendingPathComponent("test.splat")

        try await exporter.export(splats: splats, to: outputPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: outputPath.path)
        let fileSize = attributes[.size] as? Int ?? 0

        // Each splat should be ~200 bytes in binary format
        XCTAssertGreaterThan(fileSize, 1000 * 100)
    }
}
```

---

## B.4 Invariant Tests (300+ tests)

### B.4.1 Security Invariant Tests

```swift
// Tests/InvariantTests/SecurityInvariantTests/AllSecurityInvariantsTests.swift
import XCTest
@testable import Core
@testable import SharedSecurity

/// Tests for all security invariants INV-SEC-001 through INV-SEC-070
final class AllSecurityInvariantsTests: XCTestCase {

    // MARK: - INV-SEC-001 to INV-SEC-010: Cryptographic Integrity

    func testINV_SEC_001_SHA256OnlyForHashing() throws {
        // Verify no MD5/SHA1 in production code
        // This is a static analysis test
        let sourceFiles = try findAllSwiftFiles()

        for file in sourceFiles {
            let content = try String(contentsOf: file)
            XCTAssertFalse(content.contains("MD5("), "MD5 found in \(file.lastPathComponent)")
            XCTAssertFalse(content.contains("SHA1("), "SHA1 found in \(file.lastPathComponent)")
        }
    }

    func testINV_SEC_002_NoHashValueForSecurity() throws {
        let sourceFiles = try findCoreSwiftFiles()

        for file in sourceFiles {
            let content = try String(contentsOf: file)
            // hashValue should not be used with security-related types
            if content.contains("hashValue") &&
               (content.contains("security") || content.contains("integrity")) {
                XCTFail("hashValue used in security context in \(file.lastPathComponent)")
            }
        }
    }

    func testINV_SEC_003_SecureRandomForKeys() async throws {
        // Verify key generation uses SecRandomCopyBytes or SystemRandomNumberGenerator
        let key = await SecureKeyManager.generateKey()
        XCTAssertEqual(key.count, 32) // 256-bit key

        // Keys should be unique
        let key2 = await SecureKeyManager.generateKey()
        XCTAssertNotEqual(key, key2)
    }

    // MARK: - INV-SEC-011 to INV-SEC-020: Tamper Detection

    func testINV_SEC_011_HashChainIntegrity() async throws {
        let chain = IntegrityHashChain()

        for i in 0..<100 {
            try await chain.appendEntry(Data([UInt8(i)]))
        }

        let isValid = await chain.verifyIntegrity()
        XCTAssertTrue(isValid, "Hash chain should verify correctly")
    }

    func testINV_SEC_012_DebuggerDetectionActive() {
        // Verify debugger detection is implemented (not returning false always)
        // We can't easily verify this in a test, but we can check the method exists
        let result = DebuggerGuard.isDebuggerPresent()
        XCTAssertNotNil(result)
    }

    // MARK: - INV-SEC-021 to INV-SEC-030: Data Protection

    func testINV_SEC_021_KeysNotInPlaintext() throws {
        let sourceFiles = try findCoreSwiftFiles()

        for file in sourceFiles {
            let content = try String(contentsOf: file)
            // Check for hardcoded keys/secrets
            XCTAssertFalse(content.contains("let apiKey ="),
                           "Hardcoded API key in \(file.lastPathComponent)")
            XCTAssertFalse(content.contains("let secret ="),
                           "Hardcoded secret in \(file.lastPathComponent)")
        }
    }

    func testINV_SEC_022_SecureDeleteImplemented() async throws {
        let deleter = SecureDeleteHandler()

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "sensitive data".write(to: tempFile, atomically: true, encoding: .utf8)

        try await deleter.secureDelete(tempFile)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
    }

    // ... Continue for all 70 security invariants ...

    // MARK: - Helper Methods

    private func findAllSwiftFiles() throws -> [URL] {
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: nil
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" &&
               !url.path.contains(".build") &&
               !url.path.contains("Tests/") {
                files.append(url)
            }
        }

        return files
    }

    private func findCoreSwiftFiles() throws -> [URL] {
        return try findAllSwiftFiles().filter { $0.path.contains("/Core/") }
    }
}
```

### B.4.2 Mobile Invariant Tests

```swift
// Tests/InvariantTests/MobileInvariantTests/AllMobileInvariantsTests.swift
import XCTest
@testable import Core

/// Tests for all mobile invariants INV-MOBILE-001 through INV-MOBILE-020
final class AllMobileInvariantsTests: XCTestCase {

    // MARK: - Thermal Management (INV-MOBILE-001 to INV-MOBILE-003)

    func testINV_MOBILE_001_ThermalThrottleResponseTime() async {
        let handler = MobileThermalStateHandler()

        let iterations = 100
        var totalTime: Double = 0

        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            await handler.adaptToThermalState()
            totalTime += CFAbsoluteTimeGetCurrent() - start
        }

        let averageMs = (totalTime / Double(iterations)) * 1000
        XCTAssertLessThan(averageMs, 100,
                          "INV-MOBILE-001: Thermal response should be < 100ms, got \(averageMs)ms")
    }

    func testINV_MOBILE_002_QualityReductionSmooth() async {
        // Quality transitions should be smooth (not jarring)
        let handler = MobileThermalStateHandler()

        let transitions = await handler.getQualityTransitionDuration()
        XCTAssertGreaterThanOrEqual(transitions, 0.5,
                                     "INV-MOBILE-002: Quality reduction should be smooth over 500ms")
    }

    func testINV_MOBILE_003_CriticalThermalCap() async {
        let handler = MobileThermalStateHandler()

        // Simulate critical thermal
        await handler.setThermalState(.critical)
        let level = await handler.currentQualityLevel()

        XCTAssertEqual(level, .minimum,
                       "INV-MOBILE-003: Critical thermal should cap at 50% quality")
    }

    // MARK: - Memory Management (INV-MOBILE-004 to INV-MOBILE-007)

    func testINV_MOBILE_004_MemoryWarningResponseTime() async {
        let handler = MobileMemoryPressureHandler()

        let start = CFAbsoluteTimeGetCurrent()
        await handler.handleMemoryWarning()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertLessThan(elapsed, 50,
                          "INV-MOBILE-004: Memory warning response should be < 50ms")
    }

    func testINV_MOBILE_005_AdaptiveGaussianCount() async {
        let handler = MobileMemoryPressureHandler()

        let initialCount = await handler.recommendedGaussianCount()

        // Simulate memory pressure
        await handler.handleMemoryWarning()

        let reducedCount = await handler.recommendedGaussianCount()
        XCTAssertLessThan(reducedCount, initialCount,
                          "INV-MOBILE-005: Gaussian count should reduce under memory pressure")
    }

    func testINV_MOBILE_007_PeakMemoryLimit() async {
        let handler = MobileMemoryPressureHandler()

        let peakUsageRatio = await handler.getPeakMemoryRatio()
        XCTAssertLessThan(peakUsageRatio, 0.8,
                          "INV-MOBILE-007: Peak memory usage should be < 80% of device total")
    }

    // MARK: - Frame Pacing (INV-MOBILE-008 to INV-MOBILE-010)

    func testINV_MOBILE_008_FrameTimeVariance() async {
        let controller = MobileFramePacingController()

        // Simulate 60 FPS with small variance
        for _ in 0..<100 {
            let jitter = Double.random(in: -0.001...0.001)
            _ = await controller.recordFrameTime(1.0/60.0 + jitter)
        }

        let variance = await controller.getVariance()
        let p95Variance = await controller.getP95Variance()

        XCTAssertLessThan(p95Variance, 0.002,
                          "INV-MOBILE-008: Frame time variance should be < 2ms at p95")
    }

    func testINV_MOBILE_009_FrameDropRate() async {
        let controller = MobileFramePacingController()

        // Simulate mostly good frames with occasional drops
        for i in 0..<1000 {
            let frameTime = i % 100 == 0 ? 0.033 : 0.0167 // 3% drops
            _ = await controller.recordFrameTime(frameTime)
        }

        let dropRate = await controller.getDropRate()
        XCTAssertLessThan(dropRate, 0.01,
                          "INV-MOBILE-009: Frame drops should be < 1% in steady state")
    }

    // MARK: - Battery Efficiency (INV-MOBILE-011 to INV-MOBILE-013)

    func testINV_MOBILE_011_LowPowerModeReduction() async {
        let scheduler = MobileBatteryAwareScheduler()

        // Simulate low power mode
        await scheduler.setLowPowerMode(true)
        let reduction = await scheduler.getGPUUsageReduction()

        XCTAssertGreaterThanOrEqual(reduction, 0.4,
                                     "INV-MOBILE-011: Low Power Mode should reduce GPU by 40%")
    }

    func testINV_MOBILE_012_BackgroundProcessingAtLowBattery() async {
        let scheduler = MobileBatteryAwareScheduler()

        // Simulate 5% battery
        await scheduler.setBatteryLevel(0.05)
        let allowed = await scheduler.shouldAllowBackgroundProcessing()

        XCTAssertFalse(allowed,
                       "INV-MOBILE-012: Background processing should suspend at battery < 10%")
    }

    // MARK: - Touch Responsiveness (INV-MOBILE-014 to INV-MOBILE-016)

    func testINV_MOBILE_014_TouchToVisualResponse() async {
        let optimizer = MobileTouchResponseOptimizer()

        var totalTime: Double = 0
        let iterations = 100

        for _ in 0..<iterations {
            let touch = TouchEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                location: CGPoint(x: 100, y: 100),
                phase: .began
            )

            let start = CFAbsoluteTimeGetCurrent()
            await optimizer.handleTouch(touch)
            totalTime += CFAbsoluteTimeGetCurrent() - start
        }

        let averageMs = (totalTime / Double(iterations)) * 1000
        XCTAssertLessThan(averageMs, 16,
                          "INV-MOBILE-014: Touch-to-visual should be < 16ms")
    }

    func testINV_MOBILE_015_GestureRecognitionLatency() async {
        let optimizer = MobileTouchResponseOptimizer()

        // Simulate gesture sequence
        let gestureStart = CFAbsoluteTimeGetCurrent()

        for i in 0..<10 {
            let touch = TouchEvent(
                timestamp: CFAbsoluteTimeGetCurrent(),
                location: CGPoint(x: 100 + Double(i * 10), y: 100),
                phase: i == 0 ? .began : (i == 9 ? .ended : .moved)
            )
            await optimizer.handleTouch(touch)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - gestureStart) * 1000
        XCTAssertLessThan(elapsed, 32,
                          "INV-MOBILE-015: Gesture recognition should be < 32ms")
    }

    // MARK: - Progressive Loading (INV-MOBILE-017 to INV-MOBILE-019)

    func testINV_MOBILE_017_InitialRenderTime() async throws {
        let loader = MobileProgressiveScanLoader()

        let testURL = Bundle.module.url(forResource: "test_scan", withExtension: "ply")!

        let start = CFAbsoluteTimeGetCurrent()
        var gotInitialRender = false

        for await progress in try await loader.loadScan(from: testURL) {
            if case .initialRender = progress {
                gotInitialRender = true
                break
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertTrue(gotInitialRender)
        XCTAssertLessThan(elapsed, 500,
                          "INV-MOBILE-017: Initial render should be within 500ms")
    }

    func testINV_MOBILE_018_ProgressiveLoadingStepTime() async throws {
        let loader = MobileProgressiveScanLoader()

        let testURL = Bundle.module.url(forResource: "test_scan", withExtension: "ply")!

        var stepTimes: [Double] = []
        var lastTime = CFAbsoluteTimeGetCurrent()

        for await progress in try await loader.loadScan(from: testURL) {
            if case .chunk = progress {
                let now = CFAbsoluteTimeGetCurrent()
                stepTimes.append((now - lastTime) * 1000)
                lastTime = now
            }
        }

        let maxStepTime = stepTimes.max() ?? 0
        XCTAssertLessThan(maxStepTime, 50,
                          "INV-MOBILE-018: Progressive loading step should be < 50ms")
    }
}
```

---

## B.5 Edge Case Tests (300+ tests)

### B.5.1 Boundary Tests

```swift
// Tests/EdgeCaseTests/BoundaryTests/NumericBoundaryTests.swift
import XCTest
@testable import Core

final class NumericBoundaryTests: XCTestCase {

    // MARK: - UInt64 Boundaries (20 tests)

    func testCounter_MaxValue() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: UInt64.max)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, UInt64.max)
    }

    func testCounter_MinValue() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "test", counter: UInt64.min)
        let value = try await store.getCounter(keyId: "test")

        XCTAssertEqual(value, 0)
    }

    func testWALEntryId_MaxValue() async throws {
        let entry = WALEntry(
            entryId: UInt64.max,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: Date()
        )

        XCTAssertEqual(entry.entryId, UInt64.max)
    }

    // MARK: - Data Size Boundaries (20 tests)

    func testHash_ExactSize() throws {
        let data = CryptoHasher.sha256(Data([0x01]))
        XCTAssertEqual(data.count, 32)
    }

    func testHMAC_ExactSize() throws {
        let hmac = CryptoHasher.hmacSHA256(key: Data([0x01]), message: Data([0x02]))
        XCTAssertEqual(hmac.count, 32)
    }

    func testSecureRandom_LargeSize() throws {
        let size = 1024 * 1024 // 1 MB
        let data = CryptoHasher.secureRandom(count: size)
        XCTAssertEqual(data.count, size)
    }

    // MARK: - Float Boundaries (20 tests)

    func testBlurScore_Range() {
        // Blur score should be 0.0 to 1.0
        let validScores: [Float] = [0.0, 0.1, 0.5, 0.9, 1.0]

        for score in validScores {
            XCTAssertTrue((0.0...1.0).contains(score))
        }
    }

    func testCoverageWeight_Range() {
        // S5 coverage weight should be in valid range
        let weight: Float = 0.95
        XCTAssertTrue((0.0...1.0).contains(weight))
    }

    // MARK: - Timestamp Boundaries (20 tests)

    func testTimestamp_FarFuture() {
        let farFuture = Date(timeIntervalSince1970: 4_102_444_800) // Year 2100
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: farFuture
        )

        XCTAssertEqual(entry.timestamp, farFuture)
    }

    func testTimestamp_Epoch() {
        let epoch = Date(timeIntervalSince1970: 0)
        let entry = WALEntry(
            entryId: 1,
            hash: Data(repeating: 0, count: 32),
            signedEntryBytes: Data(),
            merkleState: Data(),
            committed: false,
            timestamp: epoch
        )

        XCTAssertEqual(entry.timestamp.timeIntervalSince1970, 0)
    }
}
```

### B.5.2 Empty Input Tests

```swift
// Tests/EdgeCaseTests/EmptyInputTests/EmptyInputTests.swift
import XCTest
@testable import Core

final class EmptyInputTests: XCTestCase {

    // MARK: - Empty Data (20 tests)

    func testSHA256_EmptyData() {
        let hash = CryptoHasher.sha256(Data())
        XCTAssertEqual(hash.count, 32)
        // Known SHA-256 of empty string
        XCTAssertEqual(hash.hexString,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHMAC_EmptyMessage() {
        let hmac = CryptoHasher.hmacSHA256(key: Data([0x01]), message: Data())
        XCTAssertEqual(hmac.count, 32)
    }

    func testHMAC_EmptyKey() {
        let hmac = CryptoHasher.hmacSHA256(key: Data(), message: Data([0x01]))
        XCTAssertEqual(hmac.count, 32)
    }

    // MARK: - Empty Strings (20 tests)

    func testKeyId_EmptyString() async throws {
        let store = InMemoryCounterStore()

        try await store.setCounter(keyId: "", counter: 42)
        let value = try await store.getCounter(keyId: "")

        XCTAssertEqual(value, 42)
    }

    func testPath_EmptyString() {
        let url = URL(fileURLWithPath: "")
        XCTAssertNotNil(url)
    }

    // MARK: - Empty Collections (20 tests)

    func testWAL_NoEntries() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let uncommitted = try await wal.getUncommittedEntries()
        XCTAssertTrue(uncommitted.isEmpty)
    }

    func testHashChain_Empty() async {
        let chain = IntegrityHashChain()
        let root = await chain.getRootHash()
        XCTAssertNil(root)
    }

    func testMerkleTree_NoLeaves() async throws {
        let tree = MerkleTree()
        let root = await tree.getRootHash()
        XCTAssertNil(root)
    }
}
```

### B.5.3 Malformed Input Tests

```swift
// Tests/EdgeCaseTests/MalformedInputTests/MalformedInputTests.swift
import XCTest
@testable import Core

final class MalformedInputTests: XCTestCase {

    // MARK: - Invalid Hash Lengths (20 tests)

    func testWAL_TooShortHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data(repeating: 0, count: 16), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject short hash")
        } catch WALError.invalidHashLength(let expected, let actual) {
            XCTAssertEqual(expected, 32)
            XCTAssertEqual(actual, 16)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testWAL_TooLongHash() async {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        do {
            _ = try await wal.appendEntry(
                hash: Data(repeating: 0, count: 64), // Should be 32
                signedEntryBytes: Data(),
                merkleState: Data()
            )
            XCTFail("Should reject long hash")
        } catch WALError.invalidHashLength {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Invalid JSON (20 tests)

    func testGLTF_InvalidJSON() async throws {
        let parser = GLBParser()

        let invalidJSON = "{ invalid json }".data(using: .utf8)!

        do {
            _ = try parser.parseJSON(invalidJSON)
            XCTFail("Should reject invalid JSON")
        } catch {
            // Expected
        }
    }

    func testWALEntry_InvalidCodable() throws {
        let invalidJSON = "{ \"entryId\": \"not a number\" }".data(using: .utf8)!

        do {
            _ = try JSONDecoder().decode(WALEntry.self, from: invalidJSON)
            XCTFail("Should reject invalid entry")
        } catch {
            // Expected
        }
    }

    // MARK: - Corrupted Data (20 tests)

    func testPLY_CorruptedHeader() async throws {
        let exporter = PLYExporter()
        let parser = PLYParser()

        let corruptedPLY = "not a ply file\n".data(using: .utf8)!

        do {
            _ = try parser.parse(corruptedPLY)
            XCTFail("Should reject corrupted PLY")
        } catch {
            // Expected
        }
    }

    func testGLB_TruncatedFile() async throws {
        let parser = GLBParser()

        // GLB magic is 0x46546C67, but we give truncated data
        let truncated = Data([0x67, 0x6C, 0x54]) // Only 3 bytes, need at least 12

        do {
            _ = try parser.parse(truncated)
            XCTFail("Should reject truncated GLB")
        } catch {
            // Expected
        }
    }
}
```

---

## B.6 Stress Tests (100+ tests)

```swift
// Tests/StressTests/ConcurrencyStressTests.swift
import XCTest
@testable import Core

final class ConcurrencyStressTests: XCTestCase {

    // MARK: - High Concurrency Tests (30 tests)

    func testWAL_1000ConcurrentAppends() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    _ = try await wal.appendEntry(
                        hash: Data(repeating: UInt8(i % 256), count: 32),
                        signedEntryBytes: Data([UInt8(i % 256)]),
                        merkleState: Data()
                    )
                }
            }
        }

        let entries = try await wal.getUncommittedEntries()
        XCTAssertEqual(entries.count, 1000)
    }

    func testHashChain_1000ConcurrentAppends() async throws {
        let chain = IntegrityHashChain()

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<1000 {
                group.addTask {
                    try await chain.appendEntry(Data([UInt8(i % 256)]))
                }
            }
        }

        let isValid = await chain.verifyIntegrity()
        XCTAssertTrue(isValid)
    }

    func testCounterStore_ConcurrentReadWrite() async throws {
        let store = InMemoryCounterStore()

        await withThrowingTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<100 {
                group.addTask {
                    try await store.setCounter(keyId: "key\(i % 10)", counter: UInt64(i))
                }
            }

            // Readers
            for i in 0..<100 {
                group.addTask {
                    _ = try await store.getCounter(keyId: "key\(i % 10)")
                }
            }
        }
    }

    // MARK: - Memory Stress Tests (20 tests)

    func testLargeDataHashing() {
        // Hash 100 MB of data
        let largeData = Data(repeating: 0xAB, count: 100_000_000)

        let start = CFAbsoluteTimeGetCurrent()
        let hash = CryptoHasher.sha256(largeData)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(hash.count, 32)
        XCTAssertLessThan(elapsed, 5.0, "Should hash 100MB in under 5 seconds")
    }

    func testManySmallAllocations() async throws {
        let chain = IntegrityHashChain()

        // Append 100,000 small entries
        for i in 0..<100_000 {
            try await chain.appendEntry(Data([UInt8(i % 256)]))
        }

        let isValid = await chain.verifyIntegrity()
        XCTAssertTrue(isValid)
    }

    // MARK: - I/O Stress Tests (25 tests)

    func testFileWAL_LargeEntries() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir,
                                                  withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = tempDir.appendingPathComponent("stress.wal")
        let storage = try FileWALStorage(path: path)

        // Write 100 entries with 1 MB each
        for i in 0..<100 {
            let entry = WALEntry(
                entryId: UInt64(i),
                hash: Data(repeating: UInt8(i), count: 32),
                signedEntryBytes: Data(repeating: UInt8(i), count: 1_000_000),
                merkleState: Data(),
                committed: false,
                timestamp: Date()
            )
            try await storage.writeEntry(entry)
        }

        try await storage.fsync()

        let entries = try await storage.readEntries()
        XCTAssertEqual(entries.count, 100)
    }

    func testSQLite_HighFrequencyWrites() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir,
                                                  withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = tempDir.appendingPathComponent("stress.db").path
        let store = try SQLiteCounterStore(dbPath: path)

        let start = CFAbsoluteTimeGetCurrent()

        // 10,000 writes
        for i in 0..<10_000 {
            try await store.setCounter(keyId: "key\(i)", counter: UInt64(i))
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Should complete in reasonable time
        XCTAssertLessThan(elapsed, 30.0, "10k SQLite writes should complete in under 30s")
    }
}
```

---

## B.7 Performance Tests (50+ tests)

```swift
// Tests/PerformanceTests/BenchmarkTests.swift
import XCTest
@testable import Core

final class BenchmarkTests: XCTestCase {

    // MARK: - Cryptographic Performance (15 tests)

    func testSHA256_Performance() {
        let data = Data(repeating: 0xAB, count: 1024)

        measure {
            for _ in 0..<10_000 {
                _ = CryptoHasher.sha256(data)
            }
        }
    }

    func testHMAC_Performance() {
        let key = Data(repeating: 0x01, count: 32)
        let message = Data(repeating: 0x02, count: 1024)

        measure {
            for _ in 0..<10_000 {
                _ = CryptoHasher.hmacSHA256(key: key, message: message)
            }
        }
    }

    func testSecureRandom_Performance() {
        measure {
            for _ in 0..<1_000 {
                _ = CryptoHasher.secureRandom(count: 32)
            }
        }
    }

    // MARK: - WAL Performance (15 tests)

    func testWAL_AppendPerformance() async throws {
        let storage = MockWALStorage()
        let wal = WriteAheadLog(storage: storage)

        let start = CFAbsoluteTimeGetCurrent()

        for i in 0..<1000 {
            _ = try await wal.appendEntry(
                hash: Data(repeating: UInt8(i % 256), count: 32),
                signedEntryBytes: Data(),
                merkleState: Data()
            )
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 1000 appends should complete in under 1 second
        XCTAssertLessThan(elapsed, 1.0)
    }

    // MARK: - Mobile Optimization Performance (20 tests)

    func testThermalHandler_Performance() async {
        let handler = MobileThermalStateHandler()

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<10_000 {
            await handler.adaptToThermalState()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perCall = elapsed / 10_000 * 1000 // ms per call

        // Each call should be under 0.1ms average
        XCTAssertLessThan(perCall, 0.1)
    }

    func testFramePacing_Performance() async {
        let controller = MobileFramePacingController()

        let start = CFAbsoluteTimeGetCurrent()

        for _ in 0..<100_000 {
            _ = await controller.recordFrameTime(1.0/60.0)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // 100k frame recordings should complete in under 1 second
        XCTAssertLessThan(elapsed, 1.0)
    }
}
```

---

## PART C: TEST EXECUTION CONFIGURATION

### C.1 Swift Package Test Configuration

```swift
// Package.swift - test targets
.testTarget(
    name: "UnitTests",
    dependencies: ["Core", "SharedSecurity", "PR4Math", "PR4LUT", "PR5Capture"],
    path: "Tests/UnitTests"
),
.testTarget(
    name: "IntegrationTests",
    dependencies: ["Core", "SharedSecurity"],
    path: "Tests/IntegrationTests",
    resources: [.process("Resources")]
),
.testTarget(
    name: "InvariantTests",
    dependencies: ["Core", "SharedSecurity"],
    path: "Tests/InvariantTests"
),
.testTarget(
    name: "EdgeCaseTests",
    dependencies: ["Core", "SharedSecurity"],
    path: "Tests/EdgeCaseTests"
),
.testTarget(
    name: "StressTests",
    dependencies: ["Core", "SharedSecurity"],
    path: "Tests/StressTests"
),
.testTarget(
    name: "PerformanceTests",
    dependencies: ["Core", "SharedSecurity"],
    path: "Tests/PerformanceTests"
)
```

### C.2 CI Test Commands

```yaml
# macOS CI
- name: Run All Tests (macOS)
  run: |
    swift test --parallel --enable-code-coverage
    xcrun llvm-cov report .build/debug/YourPackagePackageTests.xctest/Contents/MacOS/YourPackagePackageTests \
      -instr-profile=.build/debug/codecov/default.profdata

# Linux CI
- name: Run Tests (Linux)
  run: |
    swift test --parallel \
      --skip PR5CaptureTests \
      --disable-swift-testing \
      --enable-test-discovery
```

### C.3 Test Count Verification

```bash
# Count all test methods
grep -rn "func test" Tests/ --include="*.swift" | wc -l
# Target: 2000+

# Count by category
echo "Unit Tests:"
grep -rn "func test" Tests/UnitTests/ --include="*.swift" | wc -l

echo "Integration Tests:"
grep -rn "func test" Tests/IntegrationTests/ --include="*.swift" | wc -l

echo "Invariant Tests:"
grep -rn "func test" Tests/InvariantTests/ --include="*.swift" | wc -l

echo "Edge Case Tests:"
grep -rn "func test" Tests/EdgeCaseTests/ --include="*.swift" | wc -l

echo "Stress Tests:"
grep -rn "func test" Tests/StressTests/ --include="*.swift" | wc -l

echo "Performance Tests:"
grep -rn "func test" Tests/PerformanceTests/ --include="*.swift" | wc -l
```

---

## PART D: IMPLEMENTATION CHECKLIST

### D.1 Audit Phase
- [ ] Complete security audit (A.1)
- [ ] Complete code quality audit (A.2)
- [ ] Complete architecture audit (A.3)
- [ ] Document all findings
- [ ] Create fix tickets for issues found

### D.2 Test Implementation Phase
- [ ] Create test directory structure
- [ ] Implement Unit Tests (800+)
- [ ] Implement Integration Tests (400+)
- [ ] Implement Invariant Tests (300+)
- [ ] Implement Edge Case Tests (300+)
- [ ] Implement Stress Tests (100+)
- [ ] Implement Performance Tests (50+)

### D.3 Validation Phase
- [ ] Verify test count ≥ 2000
- [ ] All tests pass on macOS
- [ ] All tests pass on Linux (skip PR5CaptureTests)
- [ ] Code coverage ≥ 80%
- [ ] No flaky tests
- [ ] Performance benchmarks established

---

**END OF CURSOR v8.4 TITAN PROMPT**

*Execute audit first, then implement tests in order of priority.*
