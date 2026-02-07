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

/// IMU Data Collector
///
/// Collects IMU data at 100 Hz for motion analysis.
/// 符合 PR4-04: IMU-Integrated Metadata (100 Hz sampling)
public actor IMUDataCollector {
    
    // MARK: - State
    
    #if canImport(CoreMotion)
    private let motionManager: CMMotionManager
    #endif
    private var dataPoints: [IMUDataPoint] = []
    private var isCollecting: Bool = false
    private let samplingRate: Double
    
    // MARK: - Initialization
    
    /// Initialize IMU Data Collector
    /// 
    /// - Parameter samplingRate: Sampling rate in Hz (default: 100.0)
    public init(samplingRate: Double = 100.0) {
        #if canImport(CoreMotion)
        self.motionManager = CMMotionManager()
        #endif
        self.samplingRate = samplingRate
        
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
    /// - Throws: IMUError if collection fails
    public func startCollection() throws {
        guard !isCollecting else {
            return
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
        }
    }
}
