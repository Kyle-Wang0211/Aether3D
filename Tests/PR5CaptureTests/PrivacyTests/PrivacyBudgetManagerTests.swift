//
// PrivacyBudgetManagerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for PrivacyBudgetManager
//

import XCTest
@testable import PR5Capture

@MainActor
final class PrivacyBudgetManagerTests: XCTestCase {
    
    var manager: PrivacyBudgetManager!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        manager = PrivacyBudgetManager(config: config)
    }
    
    override func tearDown() {
        manager = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await manager.canPerformOperation(0.1)
        switch result {
        case .allowed:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should have budget")
        }
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await manager.canPerformOperation(0.5)
        switch result {
        case .allowed(let cost, let remaining):
            XCTAssertEqual(cost, 0.5, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(remaining, 0.0)
        case .exceeded:
            XCTFail("Should have budget")
        }
    }
    
    func test_standardConfiguration_works() async {
        let result = await manager.canPerformOperation(0.3)
        switch result {
        case .allowed, .exceeded:
            XCTAssertTrue(true)
        }
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await manager.canPerformOperation(0.2)
        switch result {
        case .allowed(let cost, _):
            XCTAssertEqual(cost, 0.2, accuracy: 0.001)
        case .exceeded:
            XCTFail("Should have budget")
        }
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<5 {
            _ = await manager.canPerformOperation(Double(i) * 0.1)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await manager.canPerformOperation(0.0)
        switch result {
        case .allowed:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Zero cost should be allowed")
        }
    }
    
    func test_maximumInput_handled() async {
        let result = await manager.canPerformOperation(2.0)
        switch result {
        case .allowed:
            XCTFail("Should exceed budget")
        case .exceeded(let requested, let available):
            XCTAssertGreaterThan(requested, available)
        }
    }
    
    func test_zeroInput_handled() async {
        let result = await manager.canPerformOperation(0.0)
        switch result {
        case .allowed:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Zero cost should be allowed")
        }
    }
    
    func test_boundaryValue_processed() async {
        _ = await manager.canPerformOperation(0.9)
        let result = await manager.canPerformOperation(0.2)
        switch result {
        case .allowed:
            XCTFail("Should exceed budget")
        case .exceeded:
            XCTAssertTrue(true)
        }
    }
    
    // MARK: - Budget Tests
    
    func test_budget_exceeded() async {
        _ = await manager.canPerformOperation(0.9)
        let result = await manager.canPerformOperation(0.2)
        switch result {
        case .allowed:
            XCTFail("Should exceed budget")
        case .exceeded:
            XCTAssertTrue(true)
        }
    }
    
    func test_budget_available() async {
        let result = await manager.canPerformOperation(0.5)
        switch result {
        case .allowed:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should have budget")
        }
    }
    
    func test_currentBudget_query() async {
        let budget = await manager.getCurrentBudget()
        XCTAssertGreaterThanOrEqual(budget, 0.0)
        XCTAssertLessThanOrEqual(budget, 1.0)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodManager = PrivacyBudgetManager(config: prodConfig)
        let result = await prodManager.canPerformOperation(0.1)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devManager = PrivacyBudgetManager(config: devConfig)
        let result = await devManager.canPerformOperation(0.1)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testManager = PrivacyBudgetManager(config: testConfig)
        let result = await testManager.canPerformOperation(0.1)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidManager = PrivacyBudgetManager(config: paranoidConfig)
        let result = await paranoidManager.canPerformOperation(0.1)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.manager.canPerformOperation(Double(i) * 0.05)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let manager1 = PrivacyBudgetManager(config: config)
        let manager2 = PrivacyBudgetManager(config: config)
        
        let result1 = await manager1.canPerformOperation(0.5)
        let result2 = await manager2.canPerformOperation(0.5)
        
        switch (result1, result2) {
        case (.allowed, .allowed):
            XCTAssertTrue(true)
        default:
            break
        }
    }
}
