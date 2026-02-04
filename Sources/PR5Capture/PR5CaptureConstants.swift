//
// PR5CaptureConstants.swift
// PR5Capture
//
// PR5 v1.8.1 - 所有常量定义（200+）
// 按 15+ 个 PART 组织（PART 0-11 + PART A-BB）
//

import Foundation

/// PR5Capture constants organized by PART
///
/// All thresholds, timeouts, and configuration values are defined here.
/// Values are organized by PART module for easy navigation.
public enum PR5CaptureConstants {
    
    // MARK: - PART 0: Sensor & Camera Pipeline
    
    public enum Sensor {
        /// ISP noise floor threshold (lab: 0.01, prod: 0.1)
        public static let ispNoiseFloorThreshold: [ConfigProfile: Double] = [
            .conservative: 0.1,
            .standard: 0.05,
            .extreme: 0.02,
            .lab: 0.01
        ]
        
        /// Maximum exposure lock drift (lab: 0.01, prod: 0.2)
        public static let exposureLockDriftMax: [ConfigProfile: Double] = [
            .conservative: 0.2,
            .standard: 0.1,
            .extreme: 0.05,
            .lab: 0.01
        ]
        
        /// Lens change detection threshold (lab: 0.01, prod: 0.15)
        public static let lensChangeDetectionThreshold: [ConfigProfile: Double] = [
            .conservative: 0.15,
            .standard: 0.1,
            .extreme: 0.05,
            .lab: 0.01
        ]
        
        /// Frame pacing normalization window (lab: 0.1s, prod: 1.0s)
        public static let framePacingNormalizationWindow: [ConfigProfile: TimeInterval] = [
            .conservative: 1.0,
            .standard: 0.5,
            .extreme: 0.2,
            .lab: 0.1
        ]
    }
    
    // MARK: - PART 1: State Machine
    
    public enum StateMachine {
        /// Hysteresis enter threshold (lab: 0.95, prod: 0.8)
        public static let hysteresisEnterThreshold: [ConfigProfile: Double] = [
            .conservative: 0.8,
            .standard: 0.85,
            .extreme: 0.9,
            .lab: 0.95
        ]
        
        /// Hysteresis exit threshold (lab: 0.8, prod: 0.6)
        public static let hysteresisExitThreshold: [ConfigProfile: Double] = [
            .conservative: 0.6,
            .standard: 0.65,
            .extreme: 0.7,
            .lab: 0.8
        ]
        
        /// Cooldown period in seconds (lab: 5.0s, prod: 1.0s)
        public static let cooldownPeriodSeconds: [ConfigProfile: TimeInterval] = [
            .conservative: 1.0,
            .standard: 2.0,
            .extreme: 3.0,
            .lab: 5.0
        ]
        
        /// Minimum dwell frames (lab: 20, prod: 3)
        public static let minimumDwellFrames: [ConfigProfile: Int] = [
            .conservative: 3,
            .standard: 5,
            .extreme: 10,
            .lab: 20
        ]
        
        /// Emergency transition rate limit (lab: 1.0/s, prod: 10.0/s)
        public static let emergencyTransitionRateLimit: [ConfigProfile: Double] = [
            .conservative: 10.0,
            .standard: 5.0,
            .extreme: 2.0,
            .lab: 1.0
        ]
    }
    
    // MARK: - PART 2: Frame Disposition
    
    public enum Disposition {
        /// Defer decision SLA timeout (lab: 0.5s, prod: 5.0s)
        public static let deferDecisionSLATimeout: [ConfigProfile: TimeInterval] = [
            .conservative: 5.0,
            .standard: 3.0,
            .extreme: 1.0,
            .lab: 0.5
        ]
        
        /// Minimum progress guarantee threshold (lab: 0.01, prod: 0.1)
        public static let minimumProgressThreshold: [ConfigProfile: Double] = [
            .conservative: 0.1,
            .standard: 0.05,
            .extreme: 0.02,
            .lab: 0.01
        ]
        
        /// Defer queue max depth (lab: 10, prod: 100)
        public static let deferQueueMaxDepth: [ConfigProfile: Int] = [
            .conservative: 100,
            .standard: 50,
            .extreme: 20,
            .lab: 10
        ]
    }
    
    // MARK: - PART 3: Quality Metrics
    
    public enum Quality {
        /// Global consistency threshold (lab: 0.9, prod: 0.7)
        public static let globalConsistencyThreshold: [ConfigProfile: Double] = [
            .conservative: 0.7,
            .standard: 0.75,
            .extreme: 0.8,
            .lab: 0.9
        ]
        
        /// Translation-parallax coupling factor (lab: 0.8, prod: 0.5)
        public static let translationParallaxCouplingFactor: [ConfigProfile: Double] = [
            .conservative: 0.5,
            .standard: 0.6,
            .extreme: 0.7,
            .lab: 0.8
        ]
        
        /// Metric independence penalty (lab: 0.3, prod: 0.1)
        public static let metricIndependencePenalty: [ConfigProfile: Double] = [
            .conservative: 0.1,
            .standard: 0.15,
            .extreme: 0.2,
            .lab: 0.3
        ]
    }
    
    // MARK: - PART A: Raw Provenance
    
    public enum Provenance {
        /// PRNU fingerprint matching threshold (lab: 0.95, prod: 0.8)
        public static let prnuMatchingThreshold: [ConfigProfile: Double] = [
            .conservative: 0.8,
            .standard: 0.85,
            .extreme: 0.9,
            .lab: 0.95
        ]
        
        /// HDR artifact detection threshold (lab: 0.05, prod: 0.2)
        public static let hdrArtifactThreshold: [ConfigProfile: Double] = [
            .conservative: 0.2,
            .standard: 0.15,
            .extreme: 0.1,
            .lab: 0.05
        ]
        
        /// Focus stability gate threshold (lab: 0.01, prod: 0.1)
        public static let focusStabilityThreshold: [ConfigProfile: Double] = [
            .conservative: 0.1,
            .standard: 0.05,
            .extreme: 0.02,
            .lab: 0.01
        ]
    }
    
    // MARK: - PART B: Timestamp & Synchronization
    
    public enum Timestamp {
        /// Maximum timestamp jitter allowed (lab: 5ms, prod: 50ms)
        public static let maxJitterMs: [ConfigProfile: Double] = [
            .conservative: 50.0,
            .standard: 25.0,
            .extreme: 10.0,
            .lab: 5.0
        ]
        
        /// Dual timestamp max delay warning (lab: 10ms, prod: 100ms)
        public static let dualTimestampMaxDelayMs: [ConfigProfile: Double] = [
            .conservative: 100.0,
            .standard: 50.0,
            .extreme: 20.0,
            .lab: 10.0
        ]
    }
    
    // MARK: - PART K: Cross-Platform Determinism
    
    public enum Determinism {
        /// Q16.16 scale factor
        public static let q16Scale: Int64 = 65536
        
        /// Maximum accumulated error in ULP (lab: 100, prod: 1000)
        public static let maxAccumulatedErrorULP: [ConfigProfile: Int] = [
            .conservative: 1000,
            .standard: 500,
            .extreme: 200,
            .lab: 100
        ]
        
        /// Quantization audit frequency (lab: 1/1, prod: 1/100)
        public static let quantizationAuditFrequency: [ConfigProfile: Double] = [
            .conservative: 0.01,  // 1/100
            .standard: 0.05,      // 1/20
            .extreme: 0.1,        // 1/10
            .lab: 1.0             // 1/1
        ]
    }
    
    // MARK: - PART L: Performance Budget
    
    public enum Performance {
        /// Latency jitter threshold in ms (lab: 10ms, prod: 100ms)
        public static let latencyJitterThresholdMs: [ConfigProfile: Double] = [
            .conservative: 100.0,
            .standard: 50.0,
            .extreme: 20.0,
            .lab: 10.0
        ]
        
        /// Memory peak threshold in MB (lab: 100MB, prod: 500MB)
        public static let memoryPeakThresholdMB: [ConfigProfile: Double] = [
            .conservative: 500.0,
            .standard: 300.0,
            .extreme: 200.0,
            .lab: 100.0
        ]
        
        /// Defer queue max depth (lab: 10, prod: 100)
        public static let deferQueueMaxDepth: [ConfigProfile: Int] = [
            .conservative: 100,
            .standard: 50,
            .extreme: 20,
            .lab: 10
        ]
    }
    
    // MARK: - PART M: Testing & Anti-Gaming
    
    public enum Testing {
        /// Soak test duration in minutes (lab: 60min, prod: 5min)
        public static let soakTestDurationMinutes: [ConfigProfile: Int] = [
            .conservative: 5,
            .standard: 15,
            .extreme: 30,
            .lab: 60
        ]
        
        /// Fuzz test iterations (lab: 100000, prod: 100)
        public static let fuzzTestIterations: [ConfigProfile: Int] = [
            .conservative: 100,
            .standard: 1000,
            .extreme: 10000,
            .lab: 100000
        ]
        
        /// Fake brightening detection threshold (lab: 0.05, prod: 0.2)
        public static let fakeBrighteningThreshold: [ConfigProfile: Double] = [
            .conservative: 0.2,
            .standard: 0.15,
            .extreme: 0.1,
            .lab: 0.05
        ]
    }
    
    // MARK: - PART N: Crash Recovery
    
    public enum Recovery {
        /// WAL batch size (lab: 10, prod: 100)
        public static let walBatchSize: [ConfigProfile: Int] = [
            .conservative: 100,
            .standard: 50,
            .extreme: 20,
            .lab: 10
        ]
        
        /// Crash injection coverage percent (lab: 100%, prod: 50%)
        public static let crashInjectionCoveragePercent: [ConfigProfile: Double] = [
            .conservative: 50.0,
            .standard: 80.0,
            .extreme: 95.0,
            .lab: 100.0
        ]
        
        /// Recovery verification timeout (lab: 1.0s, prod: 10.0s)
        public static let recoveryVerificationTimeout: [ConfigProfile: TimeInterval] = [
            .conservative: 10.0,
            .standard: 5.0,
            .extreme: 2.0,
            .lab: 1.0
        ]
    }
    
    // MARK: - PART S: Cloud Verification
    
    public enum CloudVerification {
        /// Mirror validation timeout (lab: 5s, prod: 30s)
        public static let mirrorValidationTimeout: [ConfigProfile: TimeInterval] = [
            .conservative: 30.0,
            .standard: 15.0,
            .extreme: 10.0,
            .lab: 5.0
        ]
        
        /// Ledger consistency window (lab: 100ms, prod: 1000ms)
        public static let ledgerConsistencyWindow: [ConfigProfile: TimeInterval] = [
            .conservative: 1.0,
            .standard: 0.5,
            .extreme: 0.2,
            .lab: 0.1
        ]
        
        /// Maximum clock drift allowed (lab: 50ms, prod: 500ms)
        public static let maxClockDriftAllowed: [ConfigProfile: TimeInterval] = [
            .conservative: 0.5,
            .standard: 0.25,
            .extreme: 0.1,
            .lab: 0.05
        ]
    }
    
    // MARK: - PART T: Remote Attestation
    
    public enum Attestation {
        /// Attestation refresh interval (lab: 60s, prod: 24h)
        public static let attestationRefreshInterval: [ConfigProfile: TimeInterval] = [
            .conservative: 86400.0,  // 24h
            .standard: 3600.0,       // 1h
            .extreme: 300.0,         // 5min
            .lab: 60.0               // 1min
        ]
        
        /// Maximum attestation age (lab: 120s, prod: 72h)
        public static let maxAttestationAge: [ConfigProfile: TimeInterval] = [
            .conservative: 259200.0,  // 72h
            .standard: 14400.0,      // 4h
            .extreme: 600.0,         // 10min
            .lab: 120.0              // 2min
        ]
        
        /// Device check rate limit (lab: 100/min, prod: 5/min)
        public static let deviceCheckRateLimit: [ConfigProfile: Int] = [
            .conservative: 5,
            .standard: 20,
            .extreme: 50,
            .lab: 100
        ]
    }
    
    // MARK: - PART U: Network Protocol
    
    public enum Network {
        /// Idempotency key TTL (lab: 60s, prod: 24h)
        public static let idempotencyKeyTTL: [ConfigProfile: TimeInterval] = [
            .conservative: 86400.0,  // 24h
            .standard: 3600.0,       // 1h
            .extreme: 300.0,         // 5min
            .lab: 60.0               // 1min
        ]
        
        /// Maximum retry attempts (lab: 2, prod: 3)
        public static let maxRetryAttempts: [ConfigProfile: Int] = [
            .conservative: 3,
            .standard: 3,
            .extreme: 2,
            .lab: 2
        ]
        
        /// Maximum retry attempts during P0 incident (always 0)
        public static let maxRetryAttemptsP0Incident: Int = 0
        
        /// ACK timeout in ms (lab: 500ms, prod: 5000ms)
        public static let ackTimeoutMs: [ConfigProfile: Int] = [
            .conservative: 5000,
            .standard: 3000,
            .extreme: 1000,
            .lab: 500
        ]
    }
    
    // MARK: - PART V: Config Governance
    
    public enum ConfigGovernance {
        /// Canary rollout percentages (lab: [100], prod: [1,5,25,50,100])
        public static let canaryRolloutPercent: [ConfigProfile: [Int]] = [
            .conservative: [1, 5, 25, 50, 100],
            .standard: [5, 25, 50, 100],
            .extreme: [10, 50, 100],
            .lab: [100]
        ]
        
        /// Rollback trigger error rate (lab: 0.001, prod: 0.01)
        public static let rollbackTriggerErrorRate: [ConfigProfile: Double] = [
            .conservative: 0.01,
            .standard: 0.005,
            .extreme: 0.002,
            .lab: 0.001
        ]
        
        /// Kill switch propagation max time (lab: 5s, prod: 60s)
        public static let killSwitchPropagationMax: [ConfigProfile: TimeInterval] = [
            .conservative: 60.0,
            .standard: 30.0,
            .extreme: 10.0,
            .lab: 5.0
        ]
    }
    
    // MARK: - PART W: Tenant Isolation
    
    public enum TenantIsolation {
        /// Cross-border block enabled (lab: true, prod: true)
        public static let crossBorderBlockEnabled: [ConfigProfile: Bool] = [
            .conservative: true,
            .standard: true,
            .extreme: true,
            .lab: true
        ]
        
        /// Encryption key rotation interval (lab: 1h, prod: 90d)
        public static let encryptionKeyRotationInterval: [ConfigProfile: TimeInterval] = [
            .conservative: 7776000.0,  // 90 days
            .standard: 604800.0,      // 7 days
            .extreme: 86400.0,        // 1 day
            .lab: 3600.0              // 1 hour
        ]
        
        /// Audit retention days (lab: 30, prod: 2555)
        public static let auditRetentionDays: [ConfigProfile: Int] = [
            .conservative: 2555,  // ~7 years
            .standard: 1825,     // 5 years
            .extreme: 730,        // 2 years
            .lab: 30             // 30 days
        ]
    }
    
    // MARK: - PART X: OS Interruption
    
    public enum Interruption {
        /// Session rebuild timeout in ms (lab: 500ms, prod: 5000ms)
        public static let sessionRebuildTimeoutMs: [ConfigProfile: Int] = [
            .conservative: 5000,
            .standard: 3000,
            .extreme: 1000,
            .lab: 500
        ]
        
        /// GPU reset detection threshold (lab: 1, prod: 3)
        public static let gpuResetDetectionThreshold: [ConfigProfile: Int] = [
            .conservative: 3,
            .standard: 2,
            .extreme: 1,
            .lab: 1
        ]
        
        /// Working set trend threshold in MB (lab: 50MB, prod: 100MB)
        public static let workingSetTrendThresholdMB: [ConfigProfile: Double] = [
            .conservative: 100.0,
            .standard: 75.0,
            .extreme: 50.0,
            .lab: 50.0
        ]
        
        /// Consecutive warning count (lab: 2, prod: 3)
        public static let consecutiveWarningCount: [ConfigProfile: Int] = [
            .conservative: 3,
            .standard: 3,
            .extreme: 2,
            .lab: 2
        ]
    }
    
    // MARK: - PART Y: Liveness & Anti-Replay
    
    public enum Liveness {
        /// PRNU sample frames (lab: 30, prod: 10)
        public static let prnuSampleFrames: [ConfigProfile: Int] = [
            .conservative: 10,
            .standard: 15,
            .extreme: 20,
            .lab: 30
        ]
        
        /// Challenge-response timeout in ms (lab: 500ms, prod: 3000ms)
        public static let challengeResponseTimeoutMs: [ConfigProfile: Int] = [
            .conservative: 3000,
            .standard: 2000,
            .extreme: 1000,
            .lab: 500
        ]
        
        /// Virtual camera check interval (lab: 1s, prod: 5s)
        public static let virtualCameraCheckInterval: [ConfigProfile: TimeInterval] = [
            .conservative: 5.0,
            .standard: 3.0,
            .extreme: 2.0,
            .lab: 1.0
        ]
    }
    
    // MARK: - PART Z: Error Budget
    
    public enum ErrorBudget {
        /// Maximum accumulated error in ULP (lab: 100, prod: 1000)
        public static let maxAccumulatedErrorULP: [ConfigProfile: Int] = [
            .conservative: 1000,
            .standard: 500,
            .extreme: 200,
            .lab: 100
        ]
        
        /// Quantization audit frequency (lab: 1/1, prod: 1/100)
        public static let quantizationAuditFrequency: [ConfigProfile: Double] = [
            .conservative: 0.01,
            .standard: 0.1,
            .extreme: 0.5,
            .lab: 1.0
        ]
        
        /// Error budget alert threshold (lab: 0.5, prod: 0.8)
        public static let errorBudgetAlertThreshold: [ConfigProfile: Double] = [
            .conservative: 0.8,
            .standard: 0.7,
            .extreme: 0.6,
            .lab: 0.5
        ]
    }
    
    // MARK: - PART AA: SLO Automation
    
    public enum SLO {
        /// Error budget burn rate windows (lab: [1m,5m,15m], prod: [1h,6h,24h])
        public static let errorBudgetBurnRateWindow: [ConfigProfile: [TimeInterval]] = [
            .conservative: [3600.0, 21600.0, 86400.0],  // 1h, 6h, 24h
            .standard: [1800.0, 3600.0, 14400.0],       // 30min, 1h, 4h
            .extreme: [300.0, 900.0, 3600.0],           // 5min, 15min, 1h
            .lab: [60.0, 300.0, 900.0]                  // 1min, 5min, 15min
        ]
        
        /// Auto-mitigation cooldown in ms (lab: 5000ms, prod: 300000ms)
        public static let autoMitigationCooldownMs: [ConfigProfile: Int] = [
            .conservative: 300000,  // 5min
            .standard: 120000,      // 2min
            .extreme: 60000,        // 1min
            .lab: 5000             // 5s
        ]
        
        /// Circuit breaker failure threshold (lab: 2, prod: 5)
        public static let circuitBreakerFailureThreshold: [ConfigProfile: Int] = [
            .conservative: 5,
            .standard: 3,
            .extreme: 2,
            .lab: 2
        ]
    }
    
    // MARK: - PART AB: Guidance Budget
    
    public enum Guidance {
        /// Maximum guidance per session (lab: 5, prod: 20)
        public static let maxGuidancePerSession: [ConfigProfile: Int] = [
            .conservative: 20,
            .standard: 15,
            .extreme: 10,
            .lab: 5
        ]
        
        /// Fatigue decay half-life in ms (lab: 1000ms, prod: 30000ms)
        public static let fatigueDecayHalfLifeMs: [ConfigProfile: Int] = [
            .conservative: 30000,
            .standard: 15000,
            .extreme: 5000,
            .lab: 1000
        ]
        
        /// Adaptive frequency minimum interval in ms (lab: 500ms, prod: 3000ms)
        public static let adaptiveFrequencyMinIntervalMs: [ConfigProfile: Int] = [
            .conservative: 3000,
            .standard: 2000,
            .extreme: 1000,
            .lab: 500
        ]
    }
    
    // MARK: - Helper Methods
    
    /// Get constant value for a profile
    public static func getValue<T>(_ dictionary: [ConfigProfile: T], profile: ConfigProfile) -> T {
        return dictionary[profile] ?? dictionary[.standard]!
    }
}
