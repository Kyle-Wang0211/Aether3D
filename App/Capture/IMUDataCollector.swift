// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// IMUDataCollector.swift
// Aether3D
//
// IMU Data Collector - Inertial Measurement Unit integration
// 符合 PR4-04: IMU-Integrated Metadata (100 Hz sampling)
//

import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

/// Protocol for checking user consent before sensor data collection.
///
/// Implement this with your consent storage backend (e.g., ConsentStorage from Aether3DCore).
public protocol IMUConsentChecker: Sendable {
    /// Check whether user has granted consent for the given operation.
    func isConsentValid(for operation: String) async -> Bool
}

/// IMU Data Collector
///
/// Collects IMU data at 100 Hz for motion analysis.
/// 符合 PR4-04: IMU-Integrated Metadata (100 Hz sampling)
///
/// **Consent Required:** IMU sensor data is considered personal data under
/// GDPR (device motion patterns) and PIPL (sensor fingerprinting).
/// Collection requires valid user consent for the "imu_collection" operation.
public actor IMUDataCollector {

    // MARK: - State

    #if canImport(CoreMotion)
    private let motionManager: CMMotionManager
    #endif
    private var dataPoints: [IMUDataPoint] = []
    private var isCollecting: Bool = false
    private let samplingRate: Double

    /// Consent checker for verifying user consent before collection
    private let consentChecker: (any IMUConsentChecker)?

    /// The consent operation identifier for IMU data collection
    public static let consentOperation = "imu_collection"

    // MARK: - Initialization

    /// Initialize IMU Data Collector
    ///
    /// - Parameters:
    ///   - samplingRate: Sampling rate in Hz (default: 100.0)
    ///   - consentChecker: Consent checker for verification (nil = skip check)
    public init(samplingRate: Double = 100.0, consentChecker: (any IMUConsentChecker)? = nil) {
        #if canImport(CoreMotion)
        self.motionManager = CMMotionManager()
        #endif
        self.samplingRate = samplingRate
        self.consentChecker = consentChecker

        #if canImport(CoreMotion)
        // Configure motion manager
        motionManager.accelerometerUpdateInterval = 1.0 / samplingRate
        motionManager.gyroUpdateInterval = 1.0 / samplingRate
        motionManager.magnetometerUpdateInterval = 1.0 / samplingRate
        #endif
    }
    
    // MARK: - Data Collection
    
    /// Start collecting IMU data
    ///
    /// Verifies user consent before starting sensor data collection.
    /// If a `ConsentStorage` was provided at init, consent for "imu_collection"
    /// must be valid (granted and not expired/withdrawn).
    ///
    /// - Throws: IMUError.consentRequired if consent is missing or invalid
    /// - Throws: IMUError if sensors are unavailable
    public func startCollection() async throws {
        guard !isCollecting else {
            return
        }

        // Verify consent before collecting sensor data
        if let checker = consentChecker {
            let hasConsent = await checker.isConsentValid(for: Self.consentOperation)
            guard hasConsent else {
                throw IMUError.consentRequired
            }
        }

        #if canImport(CoreMotion)
        guard motionManager.isAccelerometerAvailable else {
            throw IMUError.accelerometerUnavailable
        }

        guard motionManager.isGyroAvailable else {
            throw IMUError.gyroUnavailable
        }
        
        // Start accelerometer updates
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] (data, error) in
            Task { @MainActor in
                await self?.handleAccelerometerData(data, error: error)
            }
        }
        
        // Start gyro updates
        motionManager.startGyroUpdates(to: .main) { [weak self] (data, error) in
            Task { @MainActor in
                await self?.handleGyroData(data, error: error)
            }
        }
        
        // Start magnetometer updates (if available)
        if motionManager.isMagnetometerAvailable {
            motionManager.startMagnetometerUpdates(to: .main) { [weak self] (data, error) in
                Task { @MainActor in
                    await self?.handleMagnetometerData(data, error: error)
                }
            }
        }
        #else
        // Linux/other platforms: IMU not available
        throw IMUError.accelerometerUnavailable
        #endif
        
        isCollecting = true
    }
    
    /// Stop collecting IMU data
    public func stopCollection() {
        guard isCollecting else {
            return
        }
        
        #if canImport(CoreMotion)
        motionManager.stopAccelerometerUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopMagnetometerUpdates()
        #endif
        
        isCollecting = false
    }
    
    /// Get collected data points
    /// 
    /// - Returns: Array of IMU data points
    public func getDataPoints() -> [IMUDataPoint] {
        return dataPoints
    }
    
    /// Clear collected data
    public func clearData() {
        dataPoints.removeAll()
    }
    
    // MARK: - Private Methods
    
    private var lastAcceleration: SIMD3<Double>?
    private var lastRotationRate: SIMD3<Double>?
    private var lastMagneticField: SIMD3<Double>?
    
    #if canImport(CoreMotion)
    private func handleAccelerometerData(_ data: CMAccelerometerData?, error: Error?) {
        guard let data = data else { return }
        let acceleration = SIMD3<Double>(data.acceleration.x, data.acceleration.y, data.acceleration.z)
        lastAcceleration = acceleration
        createDataPointIfReady(timestamp: data.timestamp)
    }
    
    private func handleGyroData(_ data: CMGyroData?, error: Error?) {
        guard let data = data else { return }
        let rotationRate = SIMD3<Double>(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        lastRotationRate = rotationRate
        createDataPointIfReady(timestamp: data.timestamp)
    }
    
    private func handleMagnetometerData(_ data: CMMagnetometerData?, error: Error?) {
        guard let data = data else { return }
        let magneticField = SIMD3<Double>(data.magneticField.x, data.magneticField.y, data.magneticField.z)
        lastMagneticField = magneticField
        createDataPointIfReady(timestamp: data.timestamp)
    }
    #endif
    
    private func createDataPointIfReady(timestamp: TimeInterval) {
        guard let acceleration = lastAcceleration,
              let rotationRate = lastRotationRate else {
            return
        }
        
        let magneticField = lastMagneticField ?? SIMD3<Double>(0, 0, 0)
        let date = Date(timeIntervalSince1970: timestamp)
        
        let dataPoint = IMUDataPoint(
            timestamp: date,
            acceleration: acceleration,
            rotationRate: rotationRate,
            magneticField: magneticField
        )
        
        dataPoints.append(dataPoint)
    }
}

/// IMU Errors
public enum IMUError: Error, Sendable {
    case accelerometerUnavailable
    case gyroUnavailable
    case magnetometerUnavailable
    case collectionFailed(String)
    /// User has not granted consent for IMU data collection
    case consentRequired

    public var localizedDescription: String {
        switch self {
        case .accelerometerUnavailable:
            return "Accelerometer is not available on this device"
        case .gyroUnavailable:
            return "Gyroscope is not available on this device"
        case .magnetometerUnavailable:
            return "Magnetometer is not available on this device"
        case .collectionFailed(let reason):
            return "IMU data collection failed: \(reason)"
        case .consentRequired:
            return "User consent for IMU data collection is required (GDPR/PIPL)"
        }
    }
}
