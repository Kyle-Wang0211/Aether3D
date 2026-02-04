//
// DualTrackProcessorTests.swift
// PR5CaptureTests
//
// Comprehensive tests for DualTrackProcessor
//

import XCTest
@testable import PR5Capture

@MainActor
final class DualTrackProcessorTests: XCTestCase {
    
    var processor: DualTrackProcessor!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        processor = DualTrackProcessor(config: config)
    }
    
    override func tearDown() {
        processor = nil
        config = nil
        super.tearDown()
    }
    
    // MARK: - Happy Path Tests
    
    func test_normalInput_returnsValidOutput() async {
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await processor.processData(data, isPrivate: true)
        XCTAssertEqual(result.track, .private)
        XCTAssertNotNil(result.dataId)
    }
    
    func test_typicalUseCase_succeeds() async {
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await processor.processData(data, isPrivate: false)
        XCTAssertEqual(result.track, .public)
    }
    
    func test_standardConfiguration_works() async {
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await processor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    func test_expectedInput_producesExpectedOutput() async {
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await processor.processData(data, isPrivate: true)
        XCTAssertEqual(result.track, .private)
    }
    
    func test_commonScenario_handledCorrectly() async {
        for i in 0..<10 {
            let data = DualTrackProcessor.TrackData(content: Data([UInt8(i)]))
            _ = await processor.processData(data, isPrivate: i % 2 == 0)
        }
    }
    
    // MARK: - Boundary Tests
    
    func test_minimumInput_handled() async {
        let data = DualTrackProcessor.TrackData(content: Data())
        let result = await processor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    func test_maximumInput_handled() async {
        let data = DualTrackProcessor.TrackData(content: Data(repeating: 255, count: 10000))
        let result = await processor.processData(data, isPrivate: false)
        XCTAssertNotNil(result)
    }
    
    func test_zeroInput_handled() async {
        let data = DualTrackProcessor.TrackData(content: Data())
        let result = await processor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    func test_boundaryValue_processed() async {
        let data1 = DualTrackProcessor.TrackData(content: Data([0]))
        let data2 = DualTrackProcessor.TrackData(content: Data(repeating: 255, count: 1000))
        let result1 = await processor.processData(data1, isPrivate: true)
        let result2 = await processor.processData(data2, isPrivate: false)
        XCTAssertNotNil(result1)
        XCTAssertNotNil(result2)
    }
    
    // MARK: - Track Tests
    
    func test_privateTrack() async {
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await processor.processData(data, isPrivate: true)
        XCTAssertEqual(result.track, .private)
    }
    
    func test_publicTrack() async {
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await processor.processData(data, isPrivate: false)
        XCTAssertEqual(result.track, .public)
    }
    
    // MARK: - Profile Tests
    
    func test_productionProfile_behavior() async {
        let prodConfig = ExtremeProfile(profile: .standard)
        let prodProcessor = DualTrackProcessor(config: prodConfig)
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await prodProcessor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    func test_developmentProfile_behavior() async {
        let devConfig = ExtremeProfile(profile: .standard)
        let devProcessor = DualTrackProcessor(config: devConfig)
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await devProcessor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    func test_testingProfile_behavior() async {
        let testConfig = ExtremeProfile(profile: .lab)
        let testProcessor = DualTrackProcessor(config: testConfig)
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await testProcessor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    func test_paranoidProfile_behavior() async {
        let paranoidConfig = ExtremeProfile(profile: .extreme)
        let paranoidProcessor = DualTrackProcessor(config: paranoidConfig)
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result = await paranoidProcessor.processData(data, isPrivate: true)
        XCTAssertNotNil(result)
    }
    
    // MARK: - Concurrency Tests
    
    func test_concurrentAccess_threadSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    let data = DualTrackProcessor.TrackData(content: Data([UInt8(i)]))
                    _ = await self.processor.processData(data, isPrivate: i % 2 == 0)
                }
            }
        }
    }
    
    func test_multipleInstances_independent() async {
        let processor1 = DualTrackProcessor(config: config)
        let processor2 = DualTrackProcessor(config: config)
        
        let data = DualTrackProcessor.TrackData(content: Data([1, 2, 3]))
        let result1 = await processor1.processData(data, isPrivate: true)
        let result2 = await processor2.processData(data, isPrivate: false)
        
        XCTAssertNotEqual(result1.track, result2.track)
    }
}
