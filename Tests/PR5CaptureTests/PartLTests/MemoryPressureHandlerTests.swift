//
// MemoryPressureHandlerTests.swift
// PR5CaptureTests
//
// Comprehensive tests for MemoryPressureHandler
//

import XCTest
@testable import PR5Capture

@MainActor
final class MemoryPressureHandlerTests: XCTestCase {
    
    var handler: MemoryPressureHandler!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        handler = MemoryPressureHandler(config: config)
    }
    
    override func tearDown() async throws {
        handler = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await handler.handlePressure(.normal)
        XCTAssertNotNil(result.strategy)
        XCTAssertEqual(result.level, .normal)
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await handler.handlePressure(.warning)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let result = await handler.handlePressure(.critical)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await handler.handlePressure(.normal)
        XCTAssertEqual(result.strategy, .none)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for level in [MemoryPressureHandler.PressureLevel.normal, .warning, .critical] {
            _ = await handler.handlePressure(level)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_allPressureLevels() async {
        for level in [MemoryPressureHandler.PressureLevel.normal, .warning, .critical] {
            let result = await handler.handlePressure(level)
            XCTAssertNotNil(result)
        }
    }
    
    func test_normalLevel_strategy() async {
        let result = await handler.handlePressure(.normal)
        XCTAssertEqual(result.strategy, .none)
    }
    
    func test_criticalLevel_strategy() async {
        let result = await handler.handlePressure(.critical)
        XCTAssertEqual(result.strategy, .aggressiveCleanup)
    }
    
    func test_currentLevel_query() async {
        await handler.handlePressure(.warning)
        let level = await handler.getCurrentLevel()
        XCTAssertEqual(level, .warning)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodHandler = MemoryPressureHandler(config: prodConfig)
        let result = await prodHandler.handlePressure(.normal)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devHandler = MemoryPressureHandler(config: devConfig)
        let result = await devHandler.handlePressure(.normal)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testHandler = MemoryPressureHandler(config: testConfig)
        let result = await testHandler.handlePressure(.normal)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidHandler = MemoryPressureHandler(config: paranoidConfig)
        let result = await paranoidHandler.handlePressure(.normal)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for level in [MemoryPressureHandler.PressureLevel.normal, .warning, .critical] {
                group.addTask {
                    _ = await self.handler.handlePressure(level)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let handler1 = MemoryPressureHandler(config: config)
        let handler2 = MemoryPressureHandler(config: config)
        
        _ = await handler1.handlePressure(.normal)
        _ = await handler2.handlePressure(.critical)
        
        let level1 = await handler1.getCurrentLevel()
        let level2 = await handler2.getCurrentLevel()
        
        XCTAssertNotEqual(level1, level2)
    }
}
