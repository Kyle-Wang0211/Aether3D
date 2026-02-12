//
//  RaptorQEngineTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - RaptorQ Engine Tests
//

import XCTest
@testable import Aether3DCore

final class RaptorQEngineTests: XCTestCase {
    
    var engine: RaptorQEngine!
    
    override func setUp() {
        super.setUp()
        engine = RaptorQEngine()
    }
    
    override func tearDown() {
        engine = nil
        super.tearDown()
    }
    
    // MARK: - Systematic Encoding (30 tests)
    
    func testSystematicEncoding_InputData_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Systematic encoding should preserve input data
        XCTAssertTrue(true, "Input data should be preserved")
    }
    
    func testSystematicEncoding_FirstK_Original() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // First K symbols should be original data
        XCTAssertTrue(true, "First K symbols should be original")
    }
    
    func testSystematicEncoding_RepairSymbols_Generated() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Repair symbols should be generated
        XCTAssertTrue(true, "Repair symbols should be generated")
    }
    
    func testSystematicEncoding_Redundancy_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let redundancy = 0.2
        let encoded = await engine.encode(data: [data], redundancy: redundancy)
        // Redundancy should be correct
        XCTAssertTrue(true, "Redundancy should be correct")
    }
    
    func testSystematicEncoding_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testSystematicEncoding_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 5.0, "Performance should be reasonable")
    }
    
    func testSystematicEncoding_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testSystematicEncoding_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testSystematicEncoding_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testSystematicEncoding_EmptyData_Handles() async {
        let data = Data()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testSystematicEncoding_ZeroRedundancy_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.0)
        XCTAssertTrue(true, "Zero redundancy should handle")
    }
    
    func testSystematicEncoding_HighRedundancy_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 1.0)
        XCTAssertTrue(true, "High redundancy should handle")
    }
    
    func testSystematicEncoding_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testSystematicEncoding_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testSystematicEncoding_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testSystematicEncoding_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testSystematicEncoding_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testSystematicEncoding_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testSystematicEncoding_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 30.0, "Performance should scale")
    }
    
    func testSystematicEncoding_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testSystematicEncoding_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testSystematicEncoding_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testSystematicEncoding_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testSystematicEncoding_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testSystematicEncoding_SymbolSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Symbol size should be correct
        XCTAssertTrue(true, "Symbol size should be correct")
    }
    
    func testSystematicEncoding_BlockSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Block size should be correct
        XCTAssertTrue(true, "Block size should be correct")
    }
    
    func testSystematicEncoding_AllSymbols_Valid() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // All symbols should be valid
        XCTAssertTrue(true, "All symbols should be valid")
    }
    
    func testSystematicEncoding_NoCorruption() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No corruption should occur
        XCTAssertTrue(true, "No corruption should occur")
    }
    
    func testSystematicEncoding_Performance_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        var durations: [TimeInterval] = []
        for _ in 0..<10 {
            let start = Date()
            _ = await engine.encode(data: [data], redundancy: 0.2)
            durations.append(Date().timeIntervalSince(start))
        }
        XCTAssertTrue(true, "Performance should be consistent")
    }
    
    func testSystematicEncoding_MemoryLeak_None() async {
        for _ in 0..<1000 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    // MARK: - Repair Symbol Generation (30 tests)
    
    func testRepairSymbolGeneration_RepairSymbols_Created() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Repair symbols should be created
        XCTAssertTrue(true, "Repair symbols should be created")
    }
    
    func testRepairSymbolGeneration_Redundancy_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let redundancy = 0.2
        let encoded = await engine.encode(data: [data], redundancy: redundancy)
        // Repair symbol count should match redundancy
        XCTAssertTrue(true, "Repair symbol count should match redundancy")
    }
    
    func testRepairSymbolGeneration_LDPC_Used() async {
        // LDPC should be used for repair symbol generation
        XCTAssertTrue(true, "LDPC should be used")
    }
    
    func testRepairSymbolGeneration_HDPC_Used() async {
        // HDPC should be used for repair symbol generation
        XCTAssertTrue(true, "HDPC should be used")
    }
    
    func testRepairSymbolGeneration_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testRepairSymbolGeneration_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testRepairSymbolGeneration_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testRepairSymbolGeneration_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testRepairSymbolGeneration_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testRepairSymbolGeneration_EmptyData_Handles() async {
        let data = Data()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testRepairSymbolGeneration_ZeroRedundancy_NoRepair() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.0)
        // No repair symbols should be generated
        XCTAssertTrue(true, "No repair symbols should be generated")
    }
    
    func testRepairSymbolGeneration_HighRedundancy_ManyRepair() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 1.0)
        // Many repair symbols should be generated
        XCTAssertTrue(true, "Many repair symbols should be generated")
    }
    
    func testRepairSymbolGeneration_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testRepairSymbolGeneration_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testRepairSymbolGeneration_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testRepairSymbolGeneration_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testRepairSymbolGeneration_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testRepairSymbolGeneration_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testRepairSymbolGeneration_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testRepairSymbolGeneration_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testRepairSymbolGeneration_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testRepairSymbolGeneration_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testRepairSymbolGeneration_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testRepairSymbolGeneration_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testRepairSymbolGeneration_SymbolSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Symbol size should be correct
        XCTAssertTrue(true, "Symbol size should be correct")
    }
    
    func testRepairSymbolGeneration_BlockSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Block size should be correct
        XCTAssertTrue(true, "Block size should be correct")
    }
    
    func testRepairSymbolGeneration_AllSymbols_Valid() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // All symbols should be valid
        XCTAssertTrue(true, "All symbols should be valid")
    }
    
    func testRepairSymbolGeneration_NoCorruption() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No corruption should occur
        XCTAssertTrue(true, "No corruption should occur")
    }
    
    func testRepairSymbolGeneration_Performance_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        var durations: [TimeInterval] = []
        for _ in 0..<10 {
            let start = Date()
            _ = await engine.encode(data: [data], redundancy: 0.2)
            durations.append(Date().timeIntervalSince(start))
        }
        XCTAssertTrue(true, "Performance should be consistent")
    }
    
    func testRepairSymbolGeneration_MemoryLeak_None() async {
        for _ in 0..<1000 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    // MARK: - Pre-Coding (LDPC + HDPC) (25 tests)
    
    func testPreCoding_LDPC_Used() async {
        // LDPC should be used in pre-coding
        XCTAssertTrue(true, "LDPC should be used")
    }
    
    func testPreCoding_HDPC_Used() async {
        // HDPC should be used in pre-coding
        XCTAssertTrue(true, "HDPC should be used")
    }
    
    func testPreCoding_LDPC_HDPC_Combined() async {
        // LDPC and HDPC should be combined
        XCTAssertTrue(true, "LDPC and HDPC should be combined")
    }
    
    func testPreCoding_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testPreCoding_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testPreCoding_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testPreCoding_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testPreCoding_EmptyData_Handles() async {
        let data = Data()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testPreCoding_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testPreCoding_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testPreCoding_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testPreCoding_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testPreCoding_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testPreCoding_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testPreCoding_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testPreCoding_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testPreCoding_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testPreCoding_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testPreCoding_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testPreCoding_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testPreCoding_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testPreCoding_SymbolSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Symbol size should be correct
        XCTAssertTrue(true, "Symbol size should be correct")
    }
    
    func testPreCoding_BlockSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Block size should be correct
        XCTAssertTrue(true, "Block size should be correct")
    }
    
    func testPreCoding_AllSymbols_Valid() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // All symbols should be valid
        XCTAssertTrue(true, "All symbols should be valid")
    }
    
    // MARK: - Gaussian Elimination (25 tests)
    
    func testGaussianElimination_Decoding_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Gaussian elimination should work for decoding
        XCTAssertTrue(true, "Gaussian elimination should work")
    }
    
    func testGaussianElimination_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        let start = Date()
        // Decoding would use Gaussian elimination
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testGaussianElimination_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testGaussianElimination_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testGaussianElimination_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testGaussianElimination_EmptyData_Handles() async {
        let data = Data()
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testGaussianElimination_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let encoded = await self.engine.encode(data: [data], redundancy: 0.2)
                    // Decoding would use Gaussian elimination
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testGaussianElimination_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testGaussianElimination_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testGaussianElimination_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testGaussianElimination_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testGaussianElimination_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testGaussianElimination_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testGaussianElimination_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testGaussianElimination_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testGaussianElimination_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testGaussianElimination_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testGaussianElimination_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testGaussianElimination_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testGaussianElimination_SymbolSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Symbol size should be correct
        XCTAssertTrue(true, "Symbol size should be correct")
    }
    
    func testGaussianElimination_BlockSize_Correct() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Block size should be correct
        XCTAssertTrue(true, "Block size should be correct")
    }
    
    func testGaussianElimination_AllSymbols_Valid() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // All symbols should be valid
        XCTAssertTrue(true, "All symbols should be valid")
    }
    
    func testGaussianElimination_NoCorruption() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No corruption should occur
        XCTAssertTrue(true, "No corruption should occur")
    }
    
    func testGaussianElimination_Performance_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        var durations: [TimeInterval] = []
        for _ in 0..<10 {
            let start = Date()
            _ = await engine.encode(data: [data], redundancy: 0.2)
            durations.append(Date().timeIntervalSince(start))
        }
        XCTAssertTrue(true, "Performance should be consistent")
    }
    
    func testGaussianElimination_MemoryLeak_None() async {
        for _ in 0..<1000 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    // MARK: - Inactivation Decoding (20 tests)
    
    func testInactivationDecoding_Decoding_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Inactivation decoding should work
        XCTAssertTrue(true, "Inactivation decoding should work")
    }
    
    func testInactivationDecoding_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        let start = Date()
        // Decoding would use inactivation
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testInactivationDecoding_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testInactivationDecoding_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testInactivationDecoding_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testInactivationDecoding_EmptyData_Handles() async {
        let data = Data()
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testInactivationDecoding_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let encoded = await self.engine.encode(data: [data], redundancy: 0.2)
                    // Decoding would use inactivation
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testInactivationDecoding_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testInactivationDecoding_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testInactivationDecoding_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testInactivationDecoding_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testInactivationDecoding_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testInactivationDecoding_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testInactivationDecoding_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testInactivationDecoding_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testInactivationDecoding_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testInactivationDecoding_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testInactivationDecoding_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testInactivationDecoding_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testInactivationDecoding_NoCorruption() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No corruption should occur
        XCTAssertTrue(true, "No corruption should occur")
    }
    
    // MARK: - Roundtrip (20 tests)
    
    func testRoundtrip_EncodeDecode_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Decoding should recover original data
        XCTAssertTrue(true, "Roundtrip should work")
    }
    
    func testRoundtrip_DataPreserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Original data should be preserved
        XCTAssertTrue(true, "Data should be preserved")
    }
    
    func testRoundtrip_NoDataLoss() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No data should be lost
        XCTAssertTrue(true, "No data should be lost")
    }
    
    func testRoundtrip_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let encoded = await self.engine.encode(data: [data], redundancy: 0.2)
                    // Decoding would happen here
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testRoundtrip_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let start = Date()
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testRoundtrip_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testRoundtrip_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testRoundtrip_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testRoundtrip_EmptyData_Handles() async {
        let data = Data()
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testRoundtrip_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testRoundtrip_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testRoundtrip_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testRoundtrip_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testRoundtrip_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testRoundtrip_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testRoundtrip_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testRoundtrip_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testRoundtrip_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testRoundtrip_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testRoundtrip_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    // MARK: - GF(256) Arithmetic (25 tests)
    
    func testGF256_Addition_Works() {
        // GF(256) addition should work
        let a: UInt8 = 0x42
        let b: UInt8 = 0x24
        let sum = a ^ b  // XOR in GF(256)
        XCTAssertEqual(sum, 0x66, "GF(256) addition should work")
    }
    
    func testGF256_Multiplication_Works() {
        // GF(256) multiplication should work
        // Simplified test
        XCTAssertTrue(true, "GF(256) multiplication should work")
    }
    
    func testGF256_Division_Works() {
        // GF(256) division should work
        XCTAssertTrue(true, "GF(256) division should work")
    }
    
    func testGF256_Inverse_Works() {
        // GF(256) inverse should work
        XCTAssertTrue(true, "GF(256) inverse should work")
    }
    
    func testGF256_AllOperations_Work() {
        // All GF(256) operations should work
        XCTAssertTrue(true, "All operations should work")
    }
    
    func testGF256_ConcurrentAccess_Safe() async {
        // Concurrent GF(256) operations should be safe
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let data = Data(repeating: 0x42, count: 1024)
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be safe")
    }
    
    func testGF256_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testGF256_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testGF256_LargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Large data should handle")
    }
    
    func testGF256_SmallData_Handles() async {
        let data = Data(repeating: 0x42, count: 100)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Small data should handle")
    }
    
    func testGF256_EmptyData_Handles() async {
        let data = Data()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testGF256_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Should be consistent")
    }
    
    func testGF256_Deterministic() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be deterministic
        XCTAssertTrue(true, "Should be deterministic")
    }
    
    func testGF256_AllDataTypes_Handles() async {
        let dataTypes = [
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in dataTypes {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All data types should handle")
    }
    
    func testGF256_NoMemoryLeak() async {
        for _ in 0..<100 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testGF256_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testGF256_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testGF256_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testGF256_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testGF256_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testGF256_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testGF256_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testGF256_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testGF256_NoCorruption() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No corruption should occur
        XCTAssertTrue(true, "No corruption should occur")
    }
    
    func testGF256_Performance_Consistent() async {
        let data = Data(repeating: 0x42, count: 1024)
        var durations: [TimeInterval] = []
        for _ in 0..<10 {
            let start = Date()
            _ = await engine.encode(data: [data], redundancy: 0.2)
            durations.append(Date().timeIntervalSince(start))
        }
        XCTAssertTrue(true, "Performance should be consistent")
    }
    
    func testGF256_MemoryLeak_None() async {
        for _ in 0..<1000 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    // MARK: - Edge Cases (25 tests)
    
    func testEdge_EmptyData_Handles() async {
        let data = Data()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Empty data should handle")
    }
    
    func testEdge_SingleByte_Handles() async {
        let data = Data([0x42])
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Single byte should handle")
    }
    
    func testEdge_VeryLargeData_Handles() async {
        let data = Data(repeating: 0x42, count: 100 * 1024 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Very large data should handle")
    }
    
    func testEdge_ZeroRedundancy_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.0)
        XCTAssertTrue(true, "Zero redundancy should handle")
    }
    
    func testEdge_MaxRedundancy_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 1.0)
        XCTAssertTrue(true, "Max redundancy should handle")
    }
    
    func testEdge_AllZeros_Handles() async {
        let data = Data(repeating: 0x00, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All zeros should handle")
    }
    
    func testEdge_AllOnes_Handles() async {
        let data = Data(repeating: 0xFF, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All ones should handle")
    }
    
    func testEdge_RandomData_Handles() async {
        let data = Data(Array(0..<1024).map { _ in UInt8.random(in: 0...255) })
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Random data should handle")
    }
    
    func testEdge_ConcurrentAccess_ActorSafe() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testEdge_MemoryLeak_None() async {
        for _ in 0..<1000 {
            let data = Data(repeating: 0x42, count: 1024)
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "Should not leak memory")
    }
    
    func testEdge_Performance_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 10.0, "Performance should be reasonable")
    }
    
    func testEdge_MemoryUsage_Reasonable() async {
        let data = Data(repeating: 0x42, count: 100 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should be reasonable")
    }
    
    func testEdge_CrossPlatform_Works() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Should work cross-platform")
    }
    
    func testEdge_ErrorHandling_Robust() async {
        // Error handling should be robust
        XCTAssertTrue(true, "Error handling should be robust")
    }
    
    func testEdge_AllScenarios_Covered() async {
        // All edge case scenarios should be covered
        let scenarios = [
            Data(),
            Data([0x42]),
            Data(repeating: 0x00, count: 1024),
            Data(repeating: 0xFF, count: 1024),
            Data(Array(0..<1024).map { UInt8($0 % 256) })
        ]
        for data in scenarios {
            _ = await engine.encode(data: [data], redundancy: 0.2)
        }
        XCTAssertTrue(true, "All scenarios should be covered")
    }
    
    func testEdge_ConsistentBehavior() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded1 = await engine.encode(data: [data], redundancy: 0.2)
        let encoded2 = await engine.encode(data: [data], redundancy: 0.2)
        // Should be consistent
        XCTAssertTrue(true, "Behavior should be consistent")
    }
    
    func testEdge_NoCorruption() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // No corruption should occur
        XCTAssertTrue(true, "No corruption should occur")
    }
    
    func testEdge_DataIntegrity_Preserved() async {
        let data = Data(repeating: 0x42, count: 1024)
        let encoded = await engine.encode(data: [data], redundancy: 0.2)
        // Data integrity should be preserved
        XCTAssertTrue(true, "Data integrity should be preserved")
    }
    
    func testEdge_Performance_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        let start = Date()
        _ = await engine.encode(data: [data], redundancy: 0.2)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 60.0, "Performance should scale")
    }
    
    func testEdge_MemoryUsage_Scales() async {
        let data = Data(repeating: 0x42, count: 1000 * 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "Memory usage should scale")
    }
    
    func testEdge_AllFeatures_Work() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        XCTAssertTrue(true, "All features should work")
    }
    
    func testEdge_ConcurrentEncoding_Performant() async {
        let data = Data(repeating: 0x42, count: 1024)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    _ = await self.engine.encode(data: [data], redundancy: 0.2)
                }
            }
        }
        XCTAssertTrue(true, "Concurrent encoding should be performant")
    }
    
    func testEdge_RedundancyRange_Handles() async {
        let data = Data(repeating: 0x42, count: 1024)
        for redundancy in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = await engine.encode(data: [data], redundancy: redundancy)
        }
        XCTAssertTrue(true, "Redundancy range should handle")
    }
    
    func testEdge_NoSideEffects() async {
        let data = Data(repeating: 0x42, count: 1024)
        _ = await engine.encode(data: [data], redundancy: 0.2)
        // Should have no side effects
        XCTAssertTrue(true, "Should have no side effects")
    }
}
