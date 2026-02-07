//
// EISRollingShutterHandler.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 0: 传感器和相机管道
// EIS 检测，滚动快门补偿策略，关键帧适用性检查
//

import Foundation

/// EIS (Electronic Image Stabilization) rolling shutter handler
///
/// Detects EIS usage and handles rolling shutter compensation.
/// Checks keyframe suitability based on EIS state.
public actor EISRollingShutterHandler {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// EIS detection state
    private var isEISEnabled: Bool = false
    
    /// Rolling shutter compensation history
    private var compensationHistory: [(timestamp: Date, compensation: Double)] = []
    
    /// Keyframe suitability history
    private var keyframeSuitabilityHistory: [(frameId: UInt64, suitable: Bool, reason: String)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - EIS Detection
    
    /// Detect EIS from motion data
    ///
    /// Analyzes motion vectors to detect EIS compensation
    public func detectEIS(
        motionVectors: [MotionVector],
        gyroData: [GyroSample]?
    ) -> EISDetectionResult {
        // Analyze motion vector patterns
        // EIS typically shows smooth, compensated motion
        let eisScore = analyzeMotionCompensation(motionVectors)
        
        // Analyze gyro data if available
        let gyroScore = gyroData.map { analyzeGyroCompensation($0) } ?? 0.0
        
        // Combined score
        let combinedScore = (eisScore * 0.7) + (gyroScore * 0.3)
        
        // Threshold for EIS detection
        let threshold = 0.6
        let detected = combinedScore >= threshold
        
        isEISEnabled = detected
        
        return EISDetectionResult(
            isEISEnabled: detected,
            motionScore: eisScore,
            gyroScore: gyroScore,
            combinedScore: combinedScore,
            threshold: threshold
        )
    }
    
    /// Analyze motion compensation patterns
    private func analyzeMotionCompensation(_ motionVectors: [MotionVector]) -> Double {
        guard motionVectors.count >= 3 else { return 0.0 }
        
        // EIS shows smoother motion (lower variance in motion vectors)
        let magnitudes = motionVectors.map { sqrt($0.dx * $0.dx + $0.dy * $0.dy) }
        let mean = magnitudes.reduce(0.0, +) / Double(magnitudes.count)
        let variance = magnitudes.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(magnitudes.count)
        
        // Lower variance = higher EIS score
        let score = 1.0 / (1.0 + variance * 10.0)
        return min(1.0, score)
    }
    
    /// Analyze gyro compensation
    private func analyzeGyroCompensation(_ gyroData: [GyroSample]) -> Double {
        guard gyroData.count >= 3 else { return 0.0 }
        
        // EIS compensates for gyro motion
        // Check for correlation between gyro and motion compensation
        // NOTE: Basic: check for smooth gyro patterns
        let angularVelocities = gyroData.map { sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z) }
        let mean = angularVelocities.reduce(0.0, +) / Double(angularVelocities.count)
        let variance = angularVelocities.map { pow($0 - mean, 2) }.reduce(0.0, +) / Double(angularVelocities.count)
        
        // Lower variance = higher compensation score
        let score = 1.0 / (1.0 + variance * 5.0)
        return min(1.0, score)
    }
    
    // MARK: - Rolling Shutter Compensation
    
    /// Compute rolling shutter compensation
    ///
    /// Calculates compensation needed for rolling shutter effects
    public func computeCompensation(
        frameId: UInt64,
        motionVectors: [MotionVector],
        readoutTime: TimeInterval
    ) -> RollingShutterCompensation {
        guard isEISEnabled else {
            return RollingShutterCompensation(
                frameId: frameId,
                compensation: 0.0,
                readoutTime: readoutTime,
                applicable: false
            )
        }
        
        // Compute compensation based on motion and readout time
        let avgMotion = computeAverageMotion(motionVectors)
        let compensation = avgMotion * readoutTime * 0.5  // NOTE: Basic compensation
        
        // Record compensation
        compensationHistory.append((timestamp: Date(), compensation: compensation))
        
        // Keep only recent history (last 100)
        if compensationHistory.count > 100 {
            compensationHistory.removeFirst()
        }
        
        return RollingShutterCompensation(
            frameId: frameId,
            compensation: compensation,
            readoutTime: readoutTime,
            applicable: true
        )
    }
    
    /// Compute average motion from motion vectors
    private func computeAverageMotion(_ motionVectors: [MotionVector]) -> Double {
        guard !motionVectors.isEmpty else { return 0.0 }
        
        let magnitudes = motionVectors.map { sqrt($0.dx * $0.dx + $0.dy * $0.dy) }
        return magnitudes.reduce(0.0, +) / Double(magnitudes.count)
    }
    
    // MARK: - Keyframe Suitability
    
    /// Check keyframe suitability
    ///
    /// Determines if a frame is suitable as a keyframe based on EIS state
    public func checkKeyframeSuitability(
        frameId: UInt64,
        motionVectors: [MotionVector],
        quality: Double
    ) -> KeyframeSuitabilityResult {
        guard isEISEnabled else {
            // Without EIS, use standard quality threshold
            let suitable = quality >= 0.7
            let reason = suitable ? "Quality sufficient" : "Quality below threshold"
            
            keyframeSuitabilityHistory.append((frameId: frameId, suitable: suitable, reason: reason))
            return KeyframeSuitabilityResult(frameId: frameId, suitable: suitable, reason: reason)
        }
        
        // With EIS, check for motion stability
        let motionStability = computeMotionStability(motionVectors)
        let stabilityThreshold = 0.8
        
        let suitable = quality >= 0.7 && motionStability >= stabilityThreshold
        let reason = suitable ? "EIS stabilized, quality sufficient" : "Motion unstable or quality insufficient"
        
        keyframeSuitabilityHistory.append((frameId: frameId, suitable: suitable, reason: reason))
        
        // Keep only recent history (last 100)
        if keyframeSuitabilityHistory.count > 100 {
            keyframeSuitabilityHistory.removeFirst()
        }
        
        return KeyframeSuitabilityResult(frameId: frameId, suitable: suitable, reason: reason)
    }
    
    /// Compute motion stability
    private func computeMotionStability(_ motionVectors: [MotionVector]) -> Double {
        guard motionVectors.count >= 2 else { return 1.0 }
        
        // Compute variance in motion direction
        let directions = motionVectors.map { atan2($0.dy, $0.dx) }
        let meanDir = directions.reduce(0.0, +) / Double(directions.count)
        
        // Normalize variance to [0, 1]
        let variance = directions.map { pow($0 - meanDir, 2) }.reduce(0.0, +) / Double(directions.count)
        let stability = 1.0 / (1.0 + variance * 10.0)
        
        return min(1.0, max(0.0, stability))
    }
    
    // MARK: - Queries
    
    /// Get EIS state
    public func getEISState() -> Bool {
        return isEISEnabled
    }
    
    // MARK: - Data Types
    
    /// Motion vector
    public struct MotionVector: Sendable {
        public let dx: Double
        public let dy: Double
        
        public init(dx: Double, dy: Double) {
            self.dx = dx
            self.dy = dy
        }
    }
    
    /// Gyro sample
    public struct GyroSample: Sendable {
        public let x: Double
        public let y: Double
        public let z: Double
        public let timestamp: Date
        
        public init(x: Double, y: Double, z: Double, timestamp: Date = Date()) {
            self.x = x
            self.y = y
            self.z = z
            self.timestamp = timestamp
        }
    }
    
    /// EIS detection result
    public struct EISDetectionResult: Sendable {
        public let isEISEnabled: Bool
        public let motionScore: Double
        public let gyroScore: Double
        public let combinedScore: Double
        public let threshold: Double
    }
    
    /// Rolling shutter compensation
    public struct RollingShutterCompensation: Sendable {
        public let frameId: UInt64
        public let compensation: Double
        public let readoutTime: TimeInterval
        public let applicable: Bool
    }
    
    /// Keyframe suitability result
    public struct KeyframeSuitabilityResult: Sendable {
        public let frameId: UInt64
        public let suitable: Bool
        public let reason: String
    }
}
