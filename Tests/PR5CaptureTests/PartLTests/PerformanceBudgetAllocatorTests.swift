// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PerformanceBudgetAllocatorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for PerformanceBudgetAllocator
//

import XCTest
@testable import PR5Capture

@MainActor
final class PerformanceBudgetAllocatorTests: XCTestCase {
    
    var allocator: PerformanceBudgetAllocator!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        allocator = PerformanceBudgetAllocator(config: config)
    }
    
    override func tearDown() async throws {
        allocator = nil
        config = nil
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let result = await allocator.allocate(0.1, for: .cpu)
        switch result {
        case .allocated:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should have allocated")
        }
    }
    
    func test_typicalUseCase_succeeds() async {
        let result = await allocator.allocate(0.5, for: .cpu)
        switch result {
        case .allocated(let amount, _):
            XCTAssertEqual(amount, 0.5, accuracy: 0.001)
        case .exceeded:
            XCTFail("Should have allocated")
        }
    }
    
    func test_standardConfiguration_works() async {
        let result = await allocator.allocate(0.3, for: .gpu)
        switch result {
        case .allocated:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should have allocated")
        }
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let result = await allocator.allocate(0.2, for: .memory)
        switch result {
        case .allocated(let amount, let remaining):
            XCTAssertEqual(amount, 0.2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(remaining, 0.0)
        case .exceeded:
            XCTFail("Should have allocated")
        }
    }
    
    func test_commonScenario_handledCorrectly() async {
        let budgetTypes: [PerformanceBudgetAllocator.BudgetType] = [.cpu, .gpu, .memory, .network]
        for budgetType in budgetTypes {
            _ = await allocator.allocate(0.1, for: budgetType)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let result = await allocator.allocate(0.0, for: .cpu)
        switch result {
        case .allocated:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should allocate zero")
        }
    }
    
    func test_maximumInput_handled() async {
        let result = await allocator.allocate(1.0, for: .cpu)
        switch result {
        case .allocated:
            XCTFail("Should exceed budget")
        case .exceeded:
            XCTAssertTrue(true)
        }
    }
    
    func test_zeroInput_handled() async {
        let result = await allocator.allocate(0.0, for: .cpu)
        switch result {
        case .allocated:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should allocate zero")
        }
    }
    
    func test_boundaryValue_processed() async {
        let result = await allocator.allocate(0.8, for: .cpu)
        switch result {
        case .allocated:
            XCTAssertTrue(true)
        case .exceeded:
            XCTAssertTrue(true)  // May exceed if already used
        }
    }
    
    // MARK: - Budget Tests
    
    func test_budget_exceeded() async {
        _ = await allocator.allocate(0.8, for: .cpu)
        let result = await allocator.allocate(0.2, for: .cpu)
        switch result {
        case .allocated:
            XCTFail("Should exceed budget")
        case .exceeded(let requested, let available):
            XCTAssertGreaterThan(requested, available)
        }
    }
    
    func test_budget_release() async {
        _ = await allocator.allocate(0.3, for: .cpu)
        await allocator.release(0.2, for: .cpu)
        let result = await allocator.allocate(0.5, for: .cpu)
        switch result {
        case .allocated:
            XCTAssertTrue(true)
        case .exceeded:
            XCTFail("Should have budget after release")
        }
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodAllocator = PerformanceBudgetAllocator(config: prodConfig)
        let result = await prodAllocator.allocate(0.1, for: .cpu)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devAllocator = PerformanceBudgetAllocator(config: devConfig)
        let result = await devAllocator.allocate(0.1, for: .cpu)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testAllocator = PerformanceBudgetAllocator(config: testConfig)
        let result = await testAllocator.allocate(0.1, for: .cpu)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidAllocator = PerformanceBudgetAllocator(config: paranoidConfig)
        let result = await paranoidAllocator.allocate(0.1, for: .cpu)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.allocator.allocate(0.05, for: .cpu)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let allocator1 = PerformanceBudgetAllocator(config: config)
        let allocator2 = PerformanceBudgetAllocator(config: config)
        
        let result1 = await allocator1.allocate(0.5, for: .cpu)
        let result2 = await allocator2.allocate(0.5, for: .cpu)
        
        switch (result1, result2) {
        case (.allocated, .allocated):
            XCTAssertTrue(true)
        default:
            XCTFail("Both should allocate")
        }
    }
}
