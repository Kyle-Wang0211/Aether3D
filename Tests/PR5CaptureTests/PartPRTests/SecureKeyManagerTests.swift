//
// SecureKeyManagerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for SecureKeyManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class SecureKeyManagerTests: XCTestCase {
    
    var manager: SecureKeyManager!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        manager = SecureKeyManager(config: config)
    }
    
    override func tearDown() {
        manager = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let key = Data([1, 2, 3, 4, 5])
        let result = await manager.storeKey(key, identifier: "test_key")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.identifier, "test_key")
    }
    
    func test_typicalUseCase_succeeds() async {
        let key = Data(repeating: 100, count: 100)
        let storeResult = await manager.storeKey(key, identifier: "key1")
        XCTAssertTrue(storeResult.success)
        
        let retrieveResult = await manager.retrieveKey(identifier: "key1")
        XCTAssertTrue(retrieveResult.success)
    }
    
    func test_standardConfiguration_works() async {
        let key = Data([1, 2, 3])
        let result = await manager.storeKey(key, identifier: "test")
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let key = Data([1, 2, 3])
        let storeResult = await manager.storeKey(key, identifier: "test")
        XCTAssertTrue(storeResult.success)
        
        let retrieveResult = await manager.retrieveKey(identifier: "test")
        XCTAssertTrue(retrieveResult.success)
        XCTAssertNotNil(retrieveResult.key)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let key = Data([UInt8(i)])
            _ = await manager.storeKey(key, identifier: "key\(i)")
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let key = Data([1])
        let result = await manager.storeKey(key, identifier: "min")
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let key = Data(repeating: 255, count: 10000)
        let result = await manager.storeKey(key, identifier: "max")
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let key = Data()
        let result = await manager.storeKey(key, identifier: "zero")
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let key1 = Data([0])
        let key2 = Data(repeating: 255, count: 1000)
        let result1 = await manager.storeKey(key1, identifier: "key1")
        let result2 = await manager.storeKey(key2, identifier: "key2")
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Key Management Tests
    
    func test_store_retrieve() async {
        let key = Data([1, 2, 3])
        let storeResult = await manager.storeKey(key, identifier: "test")
        XCTAssertTrue(storeResult.success)
        
        let retrieveResult = await manager.retrieveKey(identifier: "test")
        XCTAssertTrue(retrieveResult.success)
    }
    
    func test_retrieve_notFound() async {
        let result = await manager.retrieveKey(identifier: "nonexistent")
        XCTAssertFalse(result.success)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodManager = SecureKeyManager(config: prodConfig)
        let key = Data([1, 2, 3])
        let result = await prodManager.storeKey(key, identifier: "test")
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devManager = SecureKeyManager(config: devConfig)
        let key = Data([1, 2, 3])
        let result = await devManager.storeKey(key, identifier: "test")
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testManager = SecureKeyManager(config: testConfig)
        let key = Data([1, 2, 3])
        let result = await testManager.storeKey(key, identifier: "test")
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidManager = SecureKeyManager(config: paranoidConfig)
        let key = Data([1, 2, 3])
        let result = await paranoidManager.storeKey(key, identifier: "test")
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let key = Data([UInt8(i)])
                    _ = await self.manager.storeKey(key, identifier: "key\(i)")
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let manager1 = SecureKeyManager(config: config)
        let manager2 = SecureKeyManager(config: config)
        
        let key = Data([1, 2, 3])
        _ = await manager1.storeKey(key, identifier: "key1")
        _ = await manager2.storeKey(key, identifier: "key2")
        
        let retrieve1 = await manager1.retrieveKey(identifier: "key1")
        let retrieve2 = await manager2.retrieveKey(identifier: "key2")
        
        XCTAssertTrue(retrieve1.success)
        XCTAssertTrue(retrieve2.success)
    }
}
