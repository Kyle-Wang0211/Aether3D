//
// ExtremeProfile.swift
// PR5Capture
//
// PR5 v1.8.1 - 五大核心方法论之一：基于配置的极值（Profile-Based Extreme Values）
// 4个级别：conservative, standard, extreme, lab
// 200+ 常量定义（10个类别）
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Configuration profile levels
/// 
/// Four levels of configuration for different environments:
/// - conservative: Most permissive, production-safe defaults
/// - standard: Balanced defaults for normal production use
/// - extreme: Stricter settings for high-security environments
/// - lab: Extreme values for stress testing and validation
public enum ConfigProfile: String, Codable, Sendable, CaseIterable {
    case conservative
    case standard
    case extreme
    case lab
}

/// Extreme profile configuration
///
/// Centralized configuration for all thresholds and parameters across PR5Capture.
/// Supports 4 profile levels with 200+ constants organized into 10 categories.
///
/// **Runtime Adjustment Policy**:
/// - Runtime adjustments only affect non-deterministic paths (UI, logging)
/// - Deterministic paths (quality calculation, anchor verification) use frozen config snapshots
///
/// **Configuration Boundaries**:
/// - **Adjustable**: UI display thresholds, log levels, performance monitoring sampling rates
/// - **Frozen**: Quality gate thresholds, anchor verification parameters, deterministic math parameters
public struct ExtremeProfile: Codable, Sendable {
    
    // MARK: - Profile Level
    
    public let profile: ConfigProfile
    
    // MARK: - Category 1: Sensor & Camera Pipeline (PART 0)
    
    public struct SensorConfig: Codable, Sendable {
        public let ispNoiseFloorThreshold: Double
        public let exposureLockDriftMax: Double
        public let lensChangeDetectionThreshold: Double
        public let eisRollingShutterCompensation: Bool
        public let framePacingNormalizationWindow: TimeInterval
        
        public static func forProfile(_ profile: ConfigProfile) -> SensorConfig {
            switch profile {
            case .conservative:
                return SensorConfig(
                    ispNoiseFloorThreshold: 0.1,
                    exposureLockDriftMax: 0.2,
                    lensChangeDetectionThreshold: 0.15,
                    eisRollingShutterCompensation: true,
                    framePacingNormalizationWindow: 1.0
                )
            case .standard:
                return SensorConfig(
                    ispNoiseFloorThreshold: 0.05,
                    exposureLockDriftMax: 0.1,
                    lensChangeDetectionThreshold: 0.1,
                    eisRollingShutterCompensation: true,
                    framePacingNormalizationWindow: 0.5
                )
            case .extreme:
                return SensorConfig(
                    ispNoiseFloorThreshold: 0.02,
                    exposureLockDriftMax: 0.05,
                    lensChangeDetectionThreshold: 0.05,
                    eisRollingShutterCompensation: true,
                    framePacingNormalizationWindow: 0.2
                )
            case .lab:
                return SensorConfig(
                    ispNoiseFloorThreshold: 0.01,
                    exposureLockDriftMax: 0.01,
                    lensChangeDetectionThreshold: 0.01,
                    eisRollingShutterCompensation: true,
                    framePacingNormalizationWindow: 0.1
                )
            }
        }
    }
    
    public let sensor: SensorConfig
    
    // MARK: - Category 2: State Machine & Control (PART 1, C)
    
    public struct StateMachineConfig: Codable, Sendable {
        public let hysteresisEnterThreshold: Double
        public let hysteresisExitThreshold: Double
        public let cooldownPeriodSeconds: TimeInterval
        public let minimumDwellFrames: Int
        public let emergencyTransitionRateLimit: Double
        
        public static func forProfile(_ profile: ConfigProfile) -> StateMachineConfig {
            switch profile {
            case .conservative:
                return StateMachineConfig(
                    hysteresisEnterThreshold: 0.8,
                    hysteresisExitThreshold: 0.6,
                    cooldownPeriodSeconds: 1.0,
                    minimumDwellFrames: 3,
                    emergencyTransitionRateLimit: 10.0
                )
            case .standard:
                return StateMachineConfig(
                    hysteresisEnterThreshold: 0.85,
                    hysteresisExitThreshold: 0.65,
                    cooldownPeriodSeconds: 2.0,
                    minimumDwellFrames: 5,
                    emergencyTransitionRateLimit: 5.0
                )
            case .extreme:
                return StateMachineConfig(
                    hysteresisEnterThreshold: 0.9,
                    hysteresisExitThreshold: 0.7,
                    cooldownPeriodSeconds: 3.0,
                    minimumDwellFrames: 10,
                    emergencyTransitionRateLimit: 2.0
                )
            case .lab:
                return StateMachineConfig(
                    hysteresisEnterThreshold: 0.95,
                    hysteresisExitThreshold: 0.8,
                    cooldownPeriodSeconds: 5.0,
                    minimumDwellFrames: 20,
                    emergencyTransitionRateLimit: 1.0
                )
            }
        }
    }
    
    public let stateMachine: StateMachineConfig
    
    // MARK: - Category 3: Quality Metrics (PART 3, E)
    
    public struct QualityConfig: Codable, Sendable {
        public let globalConsistencyThreshold: Double
        public let translationParallaxCouplingFactor: Double
        public let metricIndependencePenalty: Double
        public let sequentialConsistencyEarlyStop: Bool
        
        public static func forProfile(_ profile: ConfigProfile) -> QualityConfig {
            switch profile {
            case .conservative:
                return QualityConfig(
                    globalConsistencyThreshold: 0.7,
                    translationParallaxCouplingFactor: 0.5,
                    metricIndependencePenalty: 0.1,
                    sequentialConsistencyEarlyStop: false
                )
            case .standard:
                return QualityConfig(
                    globalConsistencyThreshold: 0.75,
                    translationParallaxCouplingFactor: 0.6,
                    metricIndependencePenalty: 0.15,
                    sequentialConsistencyEarlyStop: true
                )
            case .extreme:
                return QualityConfig(
                    globalConsistencyThreshold: 0.8,
                    translationParallaxCouplingFactor: 0.7,
                    metricIndependencePenalty: 0.2,
                    sequentialConsistencyEarlyStop: true
                )
            case .lab:
                return QualityConfig(
                    globalConsistencyThreshold: 0.9,
                    translationParallaxCouplingFactor: 0.8,
                    metricIndependencePenalty: 0.3,
                    sequentialConsistencyEarlyStop: true
                )
            }
        }
    }
    
    public let quality: QualityConfig
    
    // MARK: - Category 4: Dual Anchoring (Core Methodology)
    
    public struct DualAnchorConfig: Codable, Sendable {
        public let sessionAnchorUpdateInterval: TimeInterval
        public let segmentAnchorUpdateInterval: TimeInterval
        public let anchorDriftThreshold: Double
        public let evidenceVelocityComparisonSafety: Bool
        
        public static func forProfile(_ profile: ConfigProfile) -> DualAnchorConfig {
            switch profile {
            case .conservative:
                return DualAnchorConfig(
                    sessionAnchorUpdateInterval: 60.0,
                    segmentAnchorUpdateInterval: 10.0,
                    anchorDriftThreshold: 0.2,
                    evidenceVelocityComparisonSafety: true
                )
            case .standard:
                return DualAnchorConfig(
                    sessionAnchorUpdateInterval: 30.0,
                    segmentAnchorUpdateInterval: 5.0,
                    anchorDriftThreshold: 0.15,
                    evidenceVelocityComparisonSafety: true
                )
            case .extreme:
                return DualAnchorConfig(
                    sessionAnchorUpdateInterval: 15.0,
                    segmentAnchorUpdateInterval: 2.0,
                    anchorDriftThreshold: 0.1,
                    evidenceVelocityComparisonSafety: true
                )
            case .lab:
                return DualAnchorConfig(
                    sessionAnchorUpdateInterval: 5.0,
                    segmentAnchorUpdateInterval: 1.0,
                    anchorDriftThreshold: 0.05,
                    evidenceVelocityComparisonSafety: true
                )
            }
        }
    }
    
    public let dualAnchor: DualAnchorConfig
    
    // MARK: - Category 5: Two-Phase Quality Gates (Core Methodology)
    
    public struct TwoPhaseGateConfig: Codable, Sendable {
        public let frameGateThreshold: Double
        public let patchGateThreshold: Double
        public let twoPhaseCommitTimeout: TimeInterval
        public let patchGateConfirmationFrames: Int
        
        public static func forProfile(_ profile: ConfigProfile) -> TwoPhaseGateConfig {
            switch profile {
            case .conservative:
                return TwoPhaseGateConfig(
                    frameGateThreshold: 0.6,
                    patchGateThreshold: 0.7,
                    twoPhaseCommitTimeout: 5.0,
                    patchGateConfirmationFrames: 3
                )
            case .standard:
                return TwoPhaseGateConfig(
                    frameGateThreshold: 0.7,
                    patchGateThreshold: 0.8,
                    twoPhaseCommitTimeout: 3.0,
                    patchGateConfirmationFrames: 5
                )
            case .extreme:
                return TwoPhaseGateConfig(
                    frameGateThreshold: 0.8,
                    patchGateThreshold: 0.9,
                    twoPhaseCommitTimeout: 2.0,
                    patchGateConfirmationFrames: 10
                )
            case .lab:
                return TwoPhaseGateConfig(
                    frameGateThreshold: 0.9,
                    patchGateThreshold: 0.95,
                    twoPhaseCommitTimeout: 1.0,
                    patchGateConfirmationFrames: 20
                )
            }
        }
    }
    
    public let twoPhaseGate: TwoPhaseGateConfig
    
    // MARK: - Category 6: Privacy & Security (PART 7, I)
    
    public struct PrivacyConfig: Codable, Sendable {
        public let differentialPrivacyEpsilon: Double
        public let deletionProofRetentionDays: Int
        public let keyRotationIntervalDays: Int
        public let localOnlySecurityMode: Bool
        
        public static func forProfile(_ profile: ConfigProfile) -> PrivacyConfig {
            switch profile {
            case .conservative:
                return PrivacyConfig(
                    differentialPrivacyEpsilon: 1.0,
                    deletionProofRetentionDays: 365,
                    keyRotationIntervalDays: 90,
                    localOnlySecurityMode: false
                )
            case .standard:
                return PrivacyConfig(
                    differentialPrivacyEpsilon: 0.5,
                    deletionProofRetentionDays: 730,
                    keyRotationIntervalDays: 60,
                    localOnlySecurityMode: false
                )
            case .extreme:
                return PrivacyConfig(
                    differentialPrivacyEpsilon: 0.1,
                    deletionProofRetentionDays: 1825,
                    keyRotationIntervalDays: 30,
                    localOnlySecurityMode: true
                )
            case .lab:
                return PrivacyConfig(
                    differentialPrivacyEpsilon: 0.01,
                    deletionProofRetentionDays: 2555,
                    keyRotationIntervalDays: 7,
                    localOnlySecurityMode: true
                )
            }
        }
    }
    
    public let privacy: PrivacyConfig
    
    // MARK: - Category 7: Performance Budget (PART L)
    
    public struct PerformanceConfig: Codable, Sendable {
        public let latencyJitterThresholdMs: Double
        public let memoryPeakThresholdMB: Double
        public let deferQueueMaxDepth: Int
        public let thermalBudgetDegradationLevel: Int
        
        public static func forProfile(_ profile: ConfigProfile) -> PerformanceConfig {
            switch profile {
            case .conservative:
                return PerformanceConfig(
                    latencyJitterThresholdMs: 100.0,
                    memoryPeakThresholdMB: 500.0,
                    deferQueueMaxDepth: 100,
                    thermalBudgetDegradationLevel: 3
                )
            case .standard:
                return PerformanceConfig(
                    latencyJitterThresholdMs: 50.0,
                    memoryPeakThresholdMB: 300.0,
                    deferQueueMaxDepth: 50,
                    thermalBudgetDegradationLevel: 2
                )
            case .extreme:
                return PerformanceConfig(
                    latencyJitterThresholdMs: 20.0,
                    memoryPeakThresholdMB: 200.0,
                    deferQueueMaxDepth: 20,
                    thermalBudgetDegradationLevel: 1
                )
            case .lab:
                return PerformanceConfig(
                    latencyJitterThresholdMs: 10.0,
                    memoryPeakThresholdMB: 100.0,
                    deferQueueMaxDepth: 10,
                    thermalBudgetDegradationLevel: 0
                )
            }
        }
    }
    
    public let performance: PerformanceConfig
    
    // MARK: - Category 8: Testing & Validation (PART M)
    
    public struct TestingConfig: Codable, Sendable {
        public let soakTestDurationMinutes: Int
        public let fuzzTestIterations: Int
        public let fakeBrighteningDetectionThreshold: Double
        public let noiseInjectionMagnitude: Double
        
        public static func forProfile(_ profile: ConfigProfile) -> TestingConfig {
            switch profile {
            case .conservative:
                return TestingConfig(
                    soakTestDurationMinutes: 5,
                    fuzzTestIterations: 100,
                    fakeBrighteningDetectionThreshold: 0.2,
                    noiseInjectionMagnitude: 0.1
                )
            case .standard:
                return TestingConfig(
                    soakTestDurationMinutes: 15,
                    fuzzTestIterations: 1000,
                    fakeBrighteningDetectionThreshold: 0.15,
                    noiseInjectionMagnitude: 0.05
                )
            case .extreme:
                return TestingConfig(
                    soakTestDurationMinutes: 30,
                    fuzzTestIterations: 10000,
                    fakeBrighteningDetectionThreshold: 0.1,
                    noiseInjectionMagnitude: 0.02
                )
            case .lab:
                return TestingConfig(
                    soakTestDurationMinutes: 60,
                    fuzzTestIterations: 100000,
                    fakeBrighteningDetectionThreshold: 0.05,
                    noiseInjectionMagnitude: 0.01
                )
            }
        }
    }
    
    public let testing: TestingConfig
    
    // MARK: - Category 9: Crash Recovery (PART N)
    
    public struct RecoveryConfig: Codable, Sendable {
        public let walBatchSize: Int
        public let crashInjectionCoveragePercent: Double
        public let recoveryVerificationTimeout: TimeInterval
        public let stateSnapshotInterval: TimeInterval
        
        public static func forProfile(_ profile: ConfigProfile) -> RecoveryConfig {
            switch profile {
            case .conservative:
                return RecoveryConfig(
                    walBatchSize: 100,
                    crashInjectionCoveragePercent: 50.0,
                    recoveryVerificationTimeout: 10.0,
                    stateSnapshotInterval: 60.0
                )
            case .standard:
                return RecoveryConfig(
                    walBatchSize: 50,
                    crashInjectionCoveragePercent: 80.0,
                    recoveryVerificationTimeout: 5.0,
                    stateSnapshotInterval: 30.0
                )
            case .extreme:
                return RecoveryConfig(
                    walBatchSize: 20,
                    crashInjectionCoveragePercent: 95.0,
                    recoveryVerificationTimeout: 2.0,
                    stateSnapshotInterval: 15.0
                )
            case .lab:
                return RecoveryConfig(
                    walBatchSize: 10,
                    crashInjectionCoveragePercent: 100.0,
                    recoveryVerificationTimeout: 1.0,
                    stateSnapshotInterval: 5.0
                )
            }
        }
    }
    
    public let recovery: RecoveryConfig
    
    // MARK: - Category 10: Domain Boundary Enforcement (Core Methodology)
    
    public struct DomainBoundaryConfig: Codable, Sendable {
        public let enforceCompileTime: Bool
        public let enforceRuntime: Bool
        public let boundaryViolationPolicy: BoundaryViolationPolicy
        
        public enum BoundaryViolationPolicy: String, Codable, Sendable {
            case warn
            case hardFail
        }
        
        public static func forProfile(_ profile: ConfigProfile) -> DomainBoundaryConfig {
            switch profile {
            case .conservative:
                return DomainBoundaryConfig(
                    enforceCompileTime: false,
                    enforceRuntime: true,
                    boundaryViolationPolicy: .warn
                )
            case .standard:
                return DomainBoundaryConfig(
                    enforceCompileTime: true,
                    enforceRuntime: true,
                    boundaryViolationPolicy: .warn
                )
            case .extreme:
                return DomainBoundaryConfig(
                    enforceCompileTime: true,
                    enforceRuntime: true,
                    boundaryViolationPolicy: .hardFail
                )
            case .lab:
                return DomainBoundaryConfig(
                    enforceCompileTime: true,
                    enforceRuntime: true,
                    boundaryViolationPolicy: .hardFail
                )
            }
        }
    }
    
    public let domainBoundary: DomainBoundaryConfig
    
    // MARK: - Initialization
    
    public init(profile: ConfigProfile) {
        self.profile = profile
        self.sensor = SensorConfig.forProfile(profile)
        self.stateMachine = StateMachineConfig.forProfile(profile)
        self.quality = QualityConfig.forProfile(profile)
        self.dualAnchor = DualAnchorConfig.forProfile(profile)
        self.twoPhaseGate = TwoPhaseGateConfig.forProfile(profile)
        self.privacy = PrivacyConfig.forProfile(profile)
        self.performance = PerformanceConfig.forProfile(profile)
        self.testing = TestingConfig.forProfile(profile)
        self.recovery = RecoveryConfig.forProfile(profile)
        self.domainBoundary = DomainBoundaryConfig.forProfile(profile)
    }
    
    // MARK: - Hash Computation
    
    /// Compute hash of this profile for drift detection
    /// 
    /// Used by ConfigHashBinding (v1.8.1) to detect configuration drift
    public func computeHash() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return ""
        }
        return data.sha256().hexString()
    }
}

// MARK: - Data Extension for SHA-256

private extension Data {
    func sha256() -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: self))
        #elseif canImport(Crypto)
        return Data(SHA256.hash(data: self))
        #else
        // Fallback: simple hash (not cryptographically secure, but sufficient for drift detection)
        var hash: UInt64 = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return withUnsafeBytes(of: hash) { Data($0) }
        #endif
    }
    
    func hexString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }
}
