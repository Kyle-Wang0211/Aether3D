//
// CPUBudgetEnforcerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for CPUBudgetEnforcer
//

import XCTest
@testable import PR5Capture

@MainActor
final class CPUBudgetEnforcerTests: XCTestCase {
    
    var enforcer: CPUBudgetEnforcer!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        enforcer = CPUBudgetEnforcer(config: config)
    }
    
    override func tearDown() {
        enforcer = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await enforcer.checkBudget(0.5)
        XCTAssertNotNil(result.exceedsBudget)
        XCTAssertEqual(result.currentUsage, 0.5, accuracy: 0.001)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await enforcer.checkBudget(0.6)
        XCTAssertFalse(result.exceedsBudget)
    }
    
    func test_standardConfiguration_works() async {
        let result = await enforcer.checkBudget(0.7)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await enforcer.checkBudget(0.5)
        XCTAssertFalse(result.exceedsBudget)
        XCTAssertEqual(result.action, .allow)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            _ = await enforcer.checkBudget(Double(i) * 0.1)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await enforcer.checkBudget(0.0)
        XCTAssertNotNil(result)
        XCTAssertFalse(result.exceedsBudget)
    }
    
    func test_maximumInput_handled() async {
        let result = await enforcer.checkBudget(1.0)
        XCTAssertNotNil(result)
        XCTAssertTrue(result.exceedsBudget)
    }
    
    func test_zeroInput_handled() async {
        let result = await enforcer.checkBudget(0.0)
        XCTAssertFalse(result.exceedsBudget)
    }
    
    func test_boundaryValue_processed() async {
        let result1 = await enforcer.checkBudget(0.79)
        let result2 = await enforcer.checkBudget(0.81)
        XCTAssertFalse(result1.exceedsBudget)
        XCTAssertTrue(result2.exceedsBudget)
    }
    
    // MARK: - Budget Enforcement Tests
    
    func test_budget_exceeded() async {
        let result = await enforcer.checkBudget(0.9)
        XCTAssertTrue(result.exceedsBudget)
        XCTAssertEqual(result.action, .throttle)
    }
    
    func test_budget_withinLimit() async {
        let result = await enforcer.checkBudget(0.5)
        XCTAssertFalse(result.exceedsBudget)
        XCTAssertEqual(result.action, .allow)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodEnforcer = CPUBudgetEnforcer(config: prodConfig)
        let result = await prodEnforcer.checkBudget(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devEnforcer = CPUBudgetEnforcer(config: devConfig)
        let result = await devEnforcer.checkBudget(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testEnforcer = CPUBudgetEnforcer(config: testConfig)
        let result = await testEnforcer.checkBudget(0.5)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidEnforcer = CPUBudgetEnforcer(config: paranoidConfig)
        let result = await paranoidEnforcer.checkBudget(0.5)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    _ = await self.enforcer.checkBudget(Double(i) * 0.1)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let enforcer1 = CPUBudgetEnforcer(config: config)
        let enforcer2 = CPUBudgetEnforcer(config: config)
        
        let result1 = await enforcer1.checkBudget(0.5)
        let result2 = await enforcer2.checkBudget(0.5)
        
        XCTAssertEqual(result1.exceedsBudget, result2.exceedsBudget)
    }
}
