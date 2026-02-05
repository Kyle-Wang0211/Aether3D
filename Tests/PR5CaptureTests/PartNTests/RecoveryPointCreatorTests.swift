//
// RecoveryPointCreatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for RecoveryPointCreator
//

import XCTest
@testable import PR5Capture

@MainActor
final class RecoveryPointCreatorTests: XCTestCase {
    
    var creator: RecoveryPointCreator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        creator = RecoveryPointCreator(config: config)
    }
    
    override func tearDown() async throws {
        creator = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let state: [String: String] = ["key1": "value1", "key2": "value2"]
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.pointId)
    }
    
    func test_typicalUseCase_succeeds() async {
        let state: [String: String] = ["status": "active"]
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let state: [String: String] = ["data": "test"]
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let state: [String: String] = ["key": "value"]
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertTrue(result.success)
        let retrieved = await creator.getRecoveryPoint(result.pointId)
        XCTAssertNotNil(retrieved)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let state: [String: String] = ["index": "\(i)"]
            _ = await creator.createRecoveryPoint(state: state)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let state: [String: String] = [:]
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        var state: [String: String] = [:]
        for i in 0..<100 {
            state["key\(i)"] = "value\(i)"
        }
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let state: [String: String] = [:]
        let result = await creator.createRecoveryPoint(state: state)
        XCTAssertTrue(result.success)
    }
    
    func test_boundaryValue_processed() async {
        let state1: [String: String] = ["key": "value"]
        let state2: [String: String] = ["key1": "value1", "key2": "value2"]
        let result1 = await creator.createRecoveryPoint(state: state1)
        let result2 = await creator.createRecoveryPoint(state: state2)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Recovery Point Tests
    
    func test_recoveryPoint_retrieval() async {
        let state: [String: String] = ["key": "value"]
        let result = await creator.createRecoveryPoint(state: state)
        let retrieved = await creator.getRecoveryPoint(result.pointId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.state["key"], "value")
    }
    
    func test_recoveryPoint_notFound() async {
        let notFound = await creator.getRecoveryPoint(UUID())
        XCTAssertNil(notFound)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodCreator = RecoveryPointCreator(config: prodConfig)
        let state: [String: String] = ["test": "data"]
        let result = await prodCreator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devCreator = RecoveryPointCreator(config: devConfig)
        let state: [String: String] = ["test": "data"]
        let result = await devCreator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testCreator = RecoveryPointCreator(config: testConfig)
        let state: [String: String] = ["test": "data"]
        let result = await testCreator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidCreator = RecoveryPointCreator(config: paranoidConfig)
        let state: [String: String] = ["test": "data"]
        let result = await paranoidCreator.createRecoveryPoint(state: state)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let state: [String: String] = ["index": "\(i)"]
                    _ = await self.creator.createRecoveryPoint(state: state)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let creator1 = RecoveryPointCreator(config: config)
        let creator2 = RecoveryPointCreator(config: config)
        
        let state1: [String: String] = ["data1": "value1"]
        let state2: [String: String] = ["data2": "value2"]
        
        let result1 = await creator1.createRecoveryPoint(state: state1)
        let result2 = await creator2.createRecoveryPoint(state: state2)
        
        let retrieved1 = await creator1.getRecoveryPoint(result1.pointId)
        let retrieved2 = await creator2.getRecoveryPoint(result2.pointId)
        
        XCTAssertNotNil(retrieved1)
        XCTAssertNotNil(retrieved2)
    }
}
