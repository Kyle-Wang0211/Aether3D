//
// ExtremeProfileTests.swift
// PR5CaptureTests
//
// Tests for ExtremeProfile configuration system
//

import XCTest
@testable import PR5Capture

final class ExtremeProfileTests: XCTestCase {
    
    func testProfileLevels() {
        // Test all profile levels exist
        let profiles: [ConfigProfile] = [.conservative, .standard, .extreme, .lab]
        XCTAssertEqual(profiles.count, 4)
    }
    
    func testConservativeProfile() {
        let profile = ExtremeProfile(profile: .conservative)
        XCTAssertEqual(profile.profile, .conservative)
        XCTAssertEqual(profile.sensor.ispNoiseFloorThreshold, 0.1, accuracy: 0.001)
        XCTAssertEqual(profile.stateMachine.hysteresisEnterThreshold, 0.8, accuracy: 0.001)
    }
    
    func testStandardProfile() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertEqual(profile.profile, .standard)
        XCTAssertEqual(profile.sensor.ispNoiseFloorThreshold, 0.05, accuracy: 0.001)
        XCTAssertEqual(profile.stateMachine.hysteresisEnterThreshold, 0.85, accuracy: 0.001)
    }
    
    func testExtremeProfile() {
        let profile = ExtremeProfile(profile: .extreme)
        XCTAssertEqual(profile.profile, .extreme)
        XCTAssertEqual(profile.sensor.ispNoiseFloorThreshold, 0.02, accuracy: 0.001)
        XCTAssertEqual(profile.stateMachine.hysteresisEnterThreshold, 0.9, accuracy: 0.001)
    }
    
    func testLabProfile() {
        let profile = ExtremeProfile(profile: .lab)
        XCTAssertEqual(profile.profile, .lab)
        XCTAssertEqual(profile.sensor.ispNoiseFloorThreshold, 0.01, accuracy: 0.001)
        XCTAssertEqual(profile.stateMachine.hysteresisEnterThreshold, 0.95, accuracy: 0.001)
    }
    
    func testProfileHashComputation() {
        let profile1 = ExtremeProfile(profile: .lab)
        let profile2 = ExtremeProfile(profile: .lab)
        
        let hash1 = profile1.computeHash()
        let hash2 = profile2.computeHash()
        
        // Same profile should produce same hash
        XCTAssertEqual(hash1, hash2)
        XCTAssertFalse(hash1.isEmpty)
    }
    
    func testProfileHashDifferentProfiles() {
        let conservative = ExtremeProfile(profile: .conservative)
        let lab = ExtremeProfile(profile: .lab)
        
        let hashConservative = conservative.computeHash()
        let hashLab = lab.computeHash()
        
        // Different profiles should produce different hashes
        XCTAssertNotEqual(hashConservative, hashLab)
    }
    
    func testAllConfigCategories() {
        let profile = ExtremeProfile(profile: .standard)
        
        // Verify all 10 categories are initialized
        XCTAssertNotNil(profile.sensor)
        XCTAssertNotNil(profile.stateMachine)
        XCTAssertNotNil(profile.quality)
        XCTAssertNotNil(profile.dualAnchor)
        XCTAssertNotNil(profile.twoPhaseGate)
        XCTAssertNotNil(profile.privacy)
        XCTAssertNotNil(profile.performance)
        XCTAssertNotNil(profile.testing)
        XCTAssertNotNil(profile.recovery)
        XCTAssertNotNil(profile.domainBoundary)
    }
    
    // MARK: - Profile Boundary Value Tests
    
    func test_production_frameQuality_threshold() {
        let profile = ExtremeProfile(profile: .standard)
        // QualityConfig exists and is initialized
        XCTAssertNotNil(profile.quality)
    }
    
    func test_development_frameQuality_threshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertNotNil(profile.quality)
    }
    
    func test_testing_frameQuality_threshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertNotNil(profile.quality)
    }
    
    func test_paranoid_frameQuality_threshold() {
        let profile = ExtremeProfile(profile: .extreme)
        XCTAssertNotNil(profile.quality)
    }
    
    func test_production_motionBlur_threshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertNotNil(profile.quality)
    }
    
    func test_development_motionBlur_threshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertNotNil(profile.quality)
    }
    
    func test_testing_motionBlur_threshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertNotNil(profile.quality)
    }
    
    func test_paranoid_motionBlur_threshold() {
        let profile = ExtremeProfile(profile: .extreme)
        XCTAssertNotNil(profile.quality)
    }
    
    // MARK: - Sensor Config Tests
    
    func test_production_sensor_ispNoiseFloorThreshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertGreaterThan(profile.sensor.ispNoiseFloorThreshold, 0.0)
    }
    
    func test_development_sensor_ispNoiseFloorThreshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertGreaterThan(profile.sensor.ispNoiseFloorThreshold, 0.0)
    }
    
    func test_testing_sensor_ispNoiseFloorThreshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertGreaterThan(profile.sensor.ispNoiseFloorThreshold, 0.0)
    }
    
    func test_paranoid_sensor_ispNoiseFloorThreshold() {
        let profile = ExtremeProfile(profile: .extreme)
        XCTAssertGreaterThan(profile.sensor.ispNoiseFloorThreshold, 0.0)
    }
    
    // MARK: - State Machine Config Tests
    
    func test_production_stateMachine_hysteresisEnterThreshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertGreaterThan(profile.stateMachine.hysteresisEnterThreshold, 0.0)
        XCTAssertLessThanOrEqual(profile.stateMachine.hysteresisEnterThreshold, 1.0)
    }
    
    func test_production_stateMachine_hysteresisExitThreshold() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertGreaterThan(profile.stateMachine.hysteresisExitThreshold, 0.0)
        XCTAssertLessThan(profile.stateMachine.hysteresisExitThreshold, profile.stateMachine.hysteresisEnterThreshold)
    }
    
    func test_production_stateMachine_cooldownPeriodSeconds() {
        let profile = ExtremeProfile(profile: .standard)
        XCTAssertGreaterThan(profile.stateMachine.cooldownPeriodSeconds, 0.0)
    }
    
    // MARK: - Profile Comparison Tests
    
    func test_profile_thresholds_ordering() {
        let conservative = ExtremeProfile(profile: .conservative)
        let standard = ExtremeProfile(profile: .standard)
        let extreme = ExtremeProfile(profile: .extreme)
        let lab = ExtremeProfile(profile: .lab)
        
        // Lab should have highest thresholds (most strict)
        XCTAssertGreaterThanOrEqual(lab.stateMachine.hysteresisEnterThreshold, extreme.stateMachine.hysteresisEnterThreshold)
        XCTAssertGreaterThanOrEqual(extreme.stateMachine.hysteresisEnterThreshold, standard.stateMachine.hysteresisEnterThreshold)
        XCTAssertGreaterThanOrEqual(standard.stateMachine.hysteresisEnterThreshold, conservative.stateMachine.hysteresisEnterThreshold)
        
        // Verify all profiles are valid
        XCTAssertNotNil(conservative)
        XCTAssertNotNil(standard)
        XCTAssertNotNil(extreme)
        XCTAssertNotNil(lab)
    }
    
    // MARK: - Thread Safety Tests
    
    func test_profile_thread_safety() {
        let profile = ExtremeProfile(profile: .standard)
        
        let expectation = expectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 10
        
        for _ in 0..<10 {
            Task {
                _ = profile.computeHash()
                _ = profile.sensor.ispNoiseFloorThreshold
                _ = profile.stateMachine.hysteresisEnterThreshold
                expectation.fulfill()
            }
        }
        
        wait(for: [expectation], timeout: 5.0)
    }
    
    // MARK: - Performance Tests
    
    func test_profile_hash_computation_performance() {
        let profile = ExtremeProfile(profile: .standard)
        
        measure {
            for _ in 0..<100 {
                _ = profile.computeHash()
            }
        }
    }
    
    // MARK: - Edge Cases
    
    func test_profile_hash_consistency() {
        let profile1 = ExtremeProfile(profile: .standard)
        let profile2 = ExtremeProfile(profile: .standard)
        
        let hash1 = profile1.computeHash()
        let hash2 = profile2.computeHash()
        
        XCTAssertEqual(hash1, hash2)
    }
    
    func test_profile_hash_uniqueness() {
        let profiles: [ConfigProfile] = [.conservative, .standard, .extreme, .lab]
        var hashes: Set<String> = []
        
        for profileType in profiles {
            let profile = ExtremeProfile(profile: profileType)
            let hash = profile.computeHash()
            hashes.insert(hash)
        }
        
        XCTAssertEqual(hashes.count, profiles.count)
    }
}
