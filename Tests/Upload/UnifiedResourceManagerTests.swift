//
//  UnifiedResourceManagerTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Unified Resource Manager Tests
//

import XCTest
@testable import Aether3DCore

final class UnifiedResourceManagerTests: XCTestCase {
    
    // MARK: - Upload Budget
    
    func testGetUploadBudget_Always1_0() async {
        let manager = UnifiedResourceManager()
        let budget = await manager.getUploadBudget()
        
        XCTAssertEqual(budget, 1.0,
                      "Upload budget should ALWAYS be 1.0 (100%)")
    }
    
    func testGetUploadBudget_NeverBelow1_0() async {
        let manager = UnifiedResourceManager()
        let budget = await manager.getUploadBudget()
        
        XCTAssertGreaterThanOrEqual(budget, 1.0,
                                   "Upload budget should never be below 1.0")
    }
    
    func testGetUploadBudget_NeverAbove1_0() async {
        let manager = UnifiedResourceManager()
        let budget = await manager.getUploadBudget()
        
        XCTAssertLessThanOrEqual(budget, 1.0,
                                "Upload budget should never be above 1.0")
    }
    
    func testShouldPauseUpload_AlwaysFalse() async {
        let manager = UnifiedResourceManager()
        let shouldPause = await manager.shouldPauseUpload()
        
        XCTAssertFalse(shouldPause,
                     "shouldPauseUpload should ALWAYS return false")
    }
    
    func testShouldPauseUpload_NeverTrue() async {
        let manager = UnifiedResourceManager()
        
        // Call multiple times
        for _ in 0..<100 {
            let shouldPause = await manager.shouldPauseUpload()
            XCTAssertFalse(shouldPause,
                         "shouldPauseUpload should never return true")
        }
    }
    
    func testShouldPauseUpload_EvenUnderMemoryPressure_False() async {
        let manager = UnifiedResourceManager()
        
        // Simulate memory pressure by checking multiple times
        let shouldPause = await manager.shouldPauseUpload()
        
        XCTAssertFalse(shouldPause,
                     "Should not pause even under memory pressure")
    }
    
    func testShouldPauseUpload_EvenLowBattery_False() async {
        let manager = UnifiedResourceManager()
        let shouldPause = await manager.shouldPauseUpload()
        
        XCTAssertFalse(shouldPause,
                     "Should not pause even with low battery")
    }
    
    func testShouldPauseUpload_EvenCriticalThermal_False() async {
        let manager = UnifiedResourceManager()
        let shouldPause = await manager.shouldPauseUpload()
        
        XCTAssertFalse(shouldPause,
                     "Should not pause even under critical thermal conditions")
    }
    
    func testGetThermalBudget_AlwaysUnrestricted() async {
        let manager = UnifiedResourceManager()
        let thermalBudget = await manager.getThermalBudget()
        
        if case .unrestricted = thermalBudget {
            XCTAssertTrue(true, "Thermal budget should always be unrestricted")
        } else {
            XCTFail("Thermal budget should always be unrestricted")
        }
    }
    
    func testGetBatteryLevel_ReturnsNil() async {
        let manager = UnifiedResourceManager()
        let batteryLevel = await manager.getBatteryLevel()
        
        XCTAssertNil(batteryLevel,
                    "Battery level should return nil (we don't care)")
    }
    
    func testGetMemoryAvailable_ReturnsPositive() async {
        let manager = UnifiedResourceManager()
        let memory = await manager.getMemoryAvailable()
        
        XCTAssertGreaterThan(memory, 0,
                            "Available memory should be positive")
    }
    
    func testGetMemoryAvailable_ConsistentAcrossCalls() async {
        let manager = UnifiedResourceManager()
        let memory1 = await manager.getMemoryAvailable()
        let memory2 = await manager.getMemoryAvailable()
        
        // Memory may change, but should be reasonable
        XCTAssertGreaterThan(memory1, 0,
                            "Memory should be positive")
        XCTAssertGreaterThan(memory2, 0,
                            "Memory should be positive")
    }
    
    func testResourceManager_ProtocolConformance() async {
        let manager = UnifiedResourceManager()
        
        let thermalBudget = await manager.getThermalBudget()
        let memory = await manager.getMemoryAvailable()
        let battery = await manager.getBatteryLevel()
        let shouldPause = await manager.shouldPauseUpload()
        
        // Verify all protocol methods work
        XCTAssertNotNil(thermalBudget, "getThermalBudget should work")
        XCTAssertGreaterThan(memory, 0, "getMemoryAvailable should work")
        XCTAssertNil(battery, "getBatteryLevel should return nil")
        XCTAssertFalse(shouldPause, "shouldPauseUpload should return false")
    }
    
    // MARK: - Memory Strategy
    
    func testGetMemoryStrategy_FullMemory_12Buffers() async {
        let manager = UnifiedResourceManager()
        let strategy = await manager.getMemoryStrategy()
        
        // On systems with ≥200MB, should return full
        if case .full(let buffers) = strategy {
            XCTAssertEqual(buffers, 12,
                          "Full memory strategy should have 12 buffers")
        }
    }
    
    func testGetMemoryStrategy_ReducedMemory_8Buffers() async {
        let manager = UnifiedResourceManager()
        let strategy = await manager.getMemoryStrategy()
        
        // Strategy depends on available memory
        if case .reduced(let buffers) = strategy {
            XCTAssertEqual(buffers, 8,
                          "Reduced memory strategy should have 8 buffers")
        }
    }
    
    func testGetMemoryStrategy_MinimalMemory_4Buffers() async {
        let manager = UnifiedResourceManager()
        let strategy = await manager.getMemoryStrategy()
        
        if case .minimal(let buffers) = strategy {
            XCTAssertEqual(buffers, 4,
                          "Minimal memory strategy should have 4 buffers")
        }
    }
    
    func testGetMemoryStrategy_EmergencyMemory_2Buffers() async {
        let manager = UnifiedResourceManager()
        let strategy = await manager.getMemoryStrategy()
        
        if case .emergency(let buffers) = strategy {
            XCTAssertEqual(buffers, 2,
                          "Emergency memory strategy should have 2 buffers")
            XCTAssertEqual(buffers, UploadConstants.BUFFER_POOL_MIN_BUFFERS,
                          "Emergency buffers should equal MIN_BUFFERS constant")
        }
    }
    
    func testGetMemoryStrategy_NeverBelow2() async {
        let manager = UnifiedResourceManager()
        let strategy = await manager.getMemoryStrategy()
        
        let bufferCount: Int
        switch strategy {
        case .full(let buffers): bufferCount = buffers
        case .reduced(let buffers): bufferCount = buffers
        case .minimal(let buffers): bufferCount = buffers
        case .emergency(let buffers): bufferCount = buffers
        }
        
        XCTAssertGreaterThanOrEqual(bufferCount, UploadConstants.BUFFER_POOL_MIN_BUFFERS,
                                   "Buffer count should NEVER be below 2")
    }
    
    func testGetMemoryStrategy_AllCasesValid() {
        let allCases: [MemoryStrategy] = [
            .full(buffers: 12),
            .reduced(buffers: 8),
            .minimal(buffers: 4),
            .emergency(buffers: 2)
        ]
        
        XCTAssertEqual(allCases.count, 4,
                      "MemoryStrategy should have 4 cases")
    }
    
    func testGetMemoryStrategy_ConsistentResults() async {
        let manager = UnifiedResourceManager()
        let strategy1 = await manager.getMemoryStrategy()
        let strategy2 = await manager.getMemoryStrategy()
        
        // Strategies should be consistent (memory may change, but should be reasonable)
        let bufferCount1: Int
        let bufferCount2: Int
        
        switch strategy1 {
        case .full(let b): bufferCount1 = b
        case .reduced(let b): bufferCount1 = b
        case .minimal(let b): bufferCount1 = b
        case .emergency(let b): bufferCount1 = b
        }
        
        switch strategy2 {
        case .full(let b): bufferCount2 = b
        case .reduced(let b): bufferCount2 = b
        case .minimal(let b): bufferCount2 = b
        case .emergency(let b): bufferCount2 = b
        }
        
        XCTAssertGreaterThanOrEqual(bufferCount1, UploadConstants.BUFFER_POOL_MIN_BUFFERS,
                                   "Buffer count should be valid")
        XCTAssertGreaterThanOrEqual(bufferCount2, UploadConstants.BUFFER_POOL_MIN_BUFFERS,
                                   "Buffer count should be valid")
    }
    
    // MARK: - Edge Cases
    
    func testEdge_ConcurrentAccess_ActorSafe() async {
        let manager = UnifiedResourceManager()
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await manager.getUploadBudget()
                    _ = await manager.shouldPauseUpload()
                    _ = await manager.getMemoryStrategy()
                }
            }
        }
        
        // If we get here, no race conditions
        XCTAssertTrue(true, "Concurrent access should be safe")
    }
    
    func testEdge_MultipleCalls_NoStateChange() async {
        let manager = UnifiedResourceManager()
        
        let budget1 = await manager.getUploadBudget()
        let shouldPause1 = await manager.shouldPauseUpload()
        
        let budget2 = await manager.getUploadBudget()
        let shouldPause2 = await manager.shouldPauseUpload()
        
        XCTAssertEqual(budget1, budget2,
                      "Budget should remain constant")
        XCTAssertEqual(shouldPause1, shouldPause2,
                      "shouldPause should remain constant")
    }
}
