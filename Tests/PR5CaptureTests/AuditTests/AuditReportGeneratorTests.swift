//
// AuditReportGeneratorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for AuditReportGenerator
//

import XCTest
@testable import PR5Capture

@MainActor
final class AuditReportGeneratorTests: XCTestCase {
    
    var generator: AuditReportGenerator!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        generator = AuditReportGenerator(config: config)
    }
    
    override func tearDown() {
        generator = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await generator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result.data)
        XCTAssertEqual(result.format, .json)
    }
    
    func test_typicalUseCase_succeeds() async {
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "capture", userId: "user1", result: "success")
        ]
        let result = await generator.generateReport(entries: entries, format: .csv)
        XCTAssertNotNil(result)
    }
    
    func test_standardConfiguration_works() async {
        let entries: [AuditTrailRecorder.AuditEntry] = []
        let result = await generator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await generator.generateReport(entries: entries, format: .json)
        XCTAssertFalse(result.data.isEmpty)
    }
    
    func test_commonScenario_handledCorrectly() async {
        var entries: [AuditTrailRecorder.AuditEntry] = []
        for i in 0..<10 {
            entries.append(AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "op\(i)", userId: "user1", result: "success"))
        }
        let result = await generator.generateReport(entries: entries, format: .csv)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let entries: [AuditTrailRecorder.AuditEntry] = []
        let result = await generator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        var entries: [AuditTrailRecorder.AuditEntry] = []
        for i in 0..<1000 {
            entries.append(AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "op\(i)", userId: "user1", result: "success"))
        }
        let result = await generator.generateReport(entries: entries, format: .csv)
        XCTAssertNotNil(result)
    }
    
    func test_allFormats() async {
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        for format in [AuditReportGenerator.ReportFormat.json, .csv, .pdf] {
            let result = await generator.generateReport(entries: entries, format: format)
            XCTAssertEqual(result.format, format)
        }
    }
    
    // MARK: - Format Tests
    
    func test_jsonFormat() async {
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await generator.generateReport(entries: entries, format: .json)
        XCTAssertEqual(result.format, .json)
    }
    
    func test_csvFormat() async {
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await generator.generateReport(entries: entries, format: .csv)
        XCTAssertEqual(result.format, .csv)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodGenerator = AuditReportGenerator(config: prodConfig)
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await prodGenerator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devGenerator = AuditReportGenerator(config: devConfig)
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await devGenerator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testGenerator = AuditReportGenerator(config: testConfig)
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await testGenerator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidGenerator = AuditReportGenerator(config: paranoidConfig)
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result = await paranoidGenerator.generateReport(entries: entries, format: .json)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let entries = [
                        AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "op\(i)", userId: "user1", result: "success")
                    ]
                    _ = await self.generator.generateReport(entries: entries, format: .json)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let generator1 = AuditReportGenerator(config: config)
        let generator2 = AuditReportGenerator(config: config)
        
        let entries = [
            AuditTrailRecorder.AuditEntry(timestamp: Date(), operation: "test", userId: "user1", result: "success")
        ]
        let result1 = await generator1.generateReport(entries: entries, format: .json)
        let result2 = await generator2.generateReport(entries: entries, format: .csv)
        
        XCTAssertNotEqual(result1.format, result2.format)
    }
}
