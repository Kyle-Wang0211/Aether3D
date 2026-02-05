//
// ExposureLockVerifierTests.swift
// PR5CaptureTests
//
// Tests for ExposureLockVerifier
//

import XCTest
@testable import PR5Capture

@MainActor
final class ExposureLockVerifierTests: XCTestCase {
    
    var verifier: ExposureLockVerifier!
    var config: ExtremeProfile!
    
    override func setUp() async throws {
        config = ExtremeProfile(profile: .standard)
        verifier = ExposureLockVerifier(config: config)
    }
    
    override func tearDown() async throws {
        verifier = nil
        config = nil
    }
    
    func testExposureLock() async {
        await verifier.lockExposure(iso: 100.0, shutter: 1.0/60.0, whiteBalance: 5500.0)
        
        let isLocked = await verifier.getLockState()
        XCTAssertTrue(isLocked)
    }
    
    func testExposureVerificationNoDrift() async {
        await verifier.lockExposure(iso: 100.0, shutter: 1.0/60.0, whiteBalance: 5500.0)
        
        // Verify with same settings (no drift)
        let result = await verifier.verifyLock(
            currentISO: 100.0,
            currentShutter: 1.0/60.0,
            currentWB: 5500.0
        )
        
        XCTAssertTrue(result.isLocked)
        XCTAssertFalse(result.hasDrift)
    }
    
    func testExposureVerificationWithDrift() async {
        await verifier.lockExposure(iso: 100.0, shutter: 1.0/60.0, whiteBalance: 5500.0)
        
        // Verify with drifted settings
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Sensor.exposureLockDriftMax,
            profile: .standard
        )
        
        let driftedISO = 100.0 * (1.0 + threshold + 0.1)  // Exceeds threshold
        
        let result = await verifier.verifyLock(
            currentISO: driftedISO,
            currentShutter: 1.0/60.0,
            currentWB: 5500.0
        )
        
        XCTAssertTrue(result.isLocked)
        XCTAssertTrue(result.hasDrift)
        XCTAssertGreaterThan(result.isoDrift, threshold)
    }
    
    func testUnlockExposure() async {
        await verifier.lockExposure(iso: 100.0, shutter: 1.0/60.0, whiteBalance: 5500.0)
        await verifier.unlockExposure()
        
        let isLocked = await verifier.getLockState()
        XCTAssertFalse(isLocked)
    }
}
