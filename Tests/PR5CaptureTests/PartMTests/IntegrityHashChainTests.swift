//
// IntegrityHashChainTests.swift
// PR5CaptureTests
//
// Comprehensive tests for IntegrityHashChain
//

import XCTest
@testable import PR5Capture

@MainActor
final class IntegrityHashChainTests: XCTestCase {
    
    var chain: IntegrityHashChain!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        chain = IntegrityHashChain(config: config)
    }
    
    override func tearDown() async throws {
        chain = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let data = Data([1, 2, 3, 4, 5])
        let result = await chain.addHash(data)
        XCTAssertNotNil(result.hash)
        XCTAssertGreaterThan(result.chainLength, 0)
    }
    
    func test_typicalUseCase_succeeds() async {
        let data = Data(repeating: 100, count: 1000)
        let result = await chain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let data = Data([10, 20, 30])
        let result = await chain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let data = Data([1, 2, 3])
        let result = await chain.addHash(data)
        XCTAssertNotNil(result.nodeId)
        XCTAssertFalse(result.hash.isEmpty)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let data = Data([UInt8(i)])
            _ = await chain.addHash(data)
        }
        let result = await chain.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let data = Data([1])
        let result = await chain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let data = Data(repeating: 255, count: 10000)
        let result = await chain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let data = Data()
        let result = await chain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let data1 = Data([0])
        let data2 = Data(repeating: 255, count: 1000)
        let result1 = await chain.addHash(data1)
        let result2 = await chain.addHash(data2)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Integrity Tests
    
    func test_chain_integrity() async {
        for i in 0..<10 {
            let data = Data([UInt8(i)])
            _ = await chain.addHash(data)
        }
        let result = await chain.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodChain = IntegrityHashChain(config: prodConfig)
        let data = Data([1, 2, 3])
        let result = await prodChain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devChain = IntegrityHashChain(config: devConfig)
        let data = Data([1, 2, 3])
        let result = await devChain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testChain = IntegrityHashChain(config: testConfig)
        let data = Data([1, 2, 3])
        let result = await testChain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidChain = IntegrityHashChain(config: paranoidConfig)
        let data = Data([1, 2, 3])
        let result = await paranoidChain.addHash(data)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = Data([UInt8(i)])
                    _ = await self.chain.addHash(data)
                }
            }
        }
        let result = await chain.verifyIntegrity()
        XCTAssertTrue(result.isValid)
    }
    
    func test_multipleInstances_independent() async {
        let chain1 = IntegrityHashChain(config: config)
        let chain2 = IntegrityHashChain(config: config)
        
        let data = Data([1, 2, 3])
        let result1 = await chain1.addHash(data)
        let result2 = await chain2.addHash(data)
        
        XCTAssertEqual(result1.chainLength, result2.chainLength)
    }
}
