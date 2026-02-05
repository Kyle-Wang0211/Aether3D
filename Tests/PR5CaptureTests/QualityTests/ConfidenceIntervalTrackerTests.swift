//
// ConfidenceIntervalTrackerTests.swift
// PR5CaptureTests
//
// Tests for ConfidenceIntervalTracker
//

import XCTest
@testable import PR5Capture

@MainActor
final class ConfidenceIntervalTrackerTests: XCTestCase {
    
    var tracker: ConfidenceIntervalTracker!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        tracker = ConfidenceIntervalTracker(config: config)
    }
    
    override func tearDown() async throws {
        tracker = nil
        config = nil
    }
    
    func testConfidenceInterval() async {
        // Record measurements
        for i in 0..<10 {
            _ = await tracker.trackMeasurement(0.7 + Double(i) * 0.01)
        }
        
        let interval = await tracker.getCurrentInterval()
        XCTAssertNotNil(interval)
        if let (lower, upper) = interval {
            XCTAssertLessThan(lower, upper)
        }
    }
    
    func testWithinInterval() async {
        // Record measurements
        for i in 0..<10 {
            _ = await tracker.trackMeasurement(0.7 + Double(i) * 0.01)
        }
        
        let within = await tracker.isWithinInterval(0.75)
        // Should be within interval for consistent measurements
        XCTAssertTrue(within)
    }
}
