//
// ExposureLockVerifier.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 0: 传感器和相机管道
// 曝光锁定验证，ISO/快门漂移检测，白平衡锁定验证
//

import Foundation

/// Exposure lock verifier
///
/// Verifies exposure lock stability and detects ISO/shutter drift.
/// Validates white balance lock consistency.
public actor ExposureLockVerifier {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Exposure settings history
    private var exposureHistory: [(timestamp: Date, iso: Double, shutter: Double, wb: Double)] = []
    
    /// Lock state
    private var isLocked: Bool = false
    private var lockedSettings: (iso: Double, shutter: Double, wb: Double)?
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Lock Management
    
    /// Lock exposure settings
    public func lockExposure(iso: Double, shutter: Double, whiteBalance: Double) {
        isLocked = true
        lockedSettings = (iso: iso, shutter: shutter, wb: whiteBalance)
    }
    
    /// Unlock exposure
    public func unlockExposure() {
        isLocked = false
        lockedSettings = nil
    }
    
    // MARK: - Verification
    
    /// Verify exposure lock
    ///
    /// Checks if current settings match locked settings within tolerance
    public func verifyLock(
        currentISO: Double,
        currentShutter: Double,
        currentWB: Double
    ) -> ExposureLockVerificationResult {
        guard isLocked, let locked = lockedSettings else {
            return ExposureLockVerificationResult(
                isLocked: false,
                isoDrift: 0.0,
                shutterDrift: 0.0,
                wbDrift: 0.0,
                hasDrift: false,
                threshold: 0.0
            )
        }
        
        // Compute drifts
        let isoDrift = abs(currentISO - locked.iso) / locked.iso
        let shutterDrift = abs(currentShutter - locked.shutter) / locked.shutter
        let wbDrift = abs(currentWB - locked.wb) / locked.wb
        
        // Get threshold from config
        let threshold = PR5CaptureConstants.getValue(
            PR5CaptureConstants.Sensor.exposureLockDriftMax,
            profile: config.profile
        )
        
        let hasDrift = isoDrift >= threshold || shutterDrift >= threshold || wbDrift >= threshold
        
        // Record in history
        exposureHistory.append((
            timestamp: Date(),
            iso: currentISO,
            shutter: currentShutter,
            wb: currentWB
        ))
        
        // Keep only recent history (last 100)
        if exposureHistory.count > 100 {
            exposureHistory.removeFirst()
        }
        
        return ExposureLockVerificationResult(
            isLocked: true,
            isoDrift: isoDrift,
            shutterDrift: shutterDrift,
            wbDrift: wbDrift,
            hasDrift: hasDrift,
            threshold: threshold,
            lockedISO: locked.iso,
            lockedShutter: locked.shutter,
            lockedWB: locked.wb
        )
    }
    
    // MARK: - Queries
    
    /// Get current lock state
    public func getLockState() -> Bool {
        return isLocked
    }
    
    /// Get exposure history
    public func getExposureHistory() -> [(timestamp: Date, iso: Double, shutter: Double, wb: Double)] {
        return exposureHistory
    }
    
    // MARK: - Result Types
    
    /// Exposure lock verification result
    public struct ExposureLockVerificationResult: Sendable {
        public let isLocked: Bool
        public let isoDrift: Double
        public let shutterDrift: Double
        public let wbDrift: Double
        public let hasDrift: Bool
        public let threshold: Double
        public let lockedISO: Double?
        public let lockedShutter: Double?
        public let lockedWB: Double?
        
        public init(
            isLocked: Bool,
            isoDrift: Double,
            shutterDrift: Double,
            wbDrift: Double,
            hasDrift: Bool,
            threshold: Double,
            lockedISO: Double? = nil,
            lockedShutter: Double? = nil,
            lockedWB: Double? = nil
        ) {
            self.isLocked = isLocked
            self.isoDrift = isoDrift
            self.shutterDrift = shutterDrift
            self.wbDrift = wbDrift
            self.hasDrift = hasDrift
            self.threshold = threshold
            self.lockedISO = lockedISO
            self.lockedShutter = lockedShutter
            self.lockedWB = lockedWB
        }
    }
}
