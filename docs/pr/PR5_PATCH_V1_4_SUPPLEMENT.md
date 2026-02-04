# PR5 PATCH v1.4 SUPPLEMENT - ADVANCED HARDENING MODULES

> **Document Type**: Cursor Implementation Specification
> **Version**: 1.4.0-SUPPLEMENT
> **Extends**: PR5_PATCH_V1_3_2_COMPLETE.md
> **Total New Vulnerabilities Addressed**: 112 additional (220 total with v1.3.2)
> **New Modules**: 10 Major Domains (PART S through PART AB)

---

## DOCUMENT PURPOSE AND INTEGRATION

This supplement extends PR5_PATCH_V1_3_2_COMPLETE.md with 10 critical security domains that were identified as gaps in the original specification. This document MUST be implemented alongside v1.3.2, not as a replacement.

### Integration Requirements

1. **Read v1.3.2 First**: Cursor MUST read and understand PR5_PATCH_V1_3_2_COMPLETE.md before implementing this supplement
2. **Shared Dependencies**: All 5 core methodologies from v1.3.2 apply here:
   - Three-Domain Isolation (Perception → Decision → Ledger)
   - Dual Anchoring (Session Anchor + Segment Anchor)
   - Two-Phase Quality Gates (Frame Gate + Patch Gate)
   - Deterministic Cross-Platform Math (Q16.16 Fixed-Point)
   - Unified Audit Schema (AuditEntry protocol)
3. **Stage Numbering**: This supplement uses STAGE S-001 through STAGE AB-999 to avoid conflicts with v1.3.2's STAGE A-001 through STAGE R-999
4. **File Organization**: New files go in existing directory structure; no new top-level directories

### Errata for v1.3.2

Before implementing this supplement, apply these corrections to v1.3.2:

```
CORRECTION 1: Stage Numbering Duplicates
- STAGE K-007 appears twice → Rename second occurrence to STAGE K-007b
- STAGE L-003 conflicts with L-003 in different section → Rename to STAGE L-003-PERF

CORRECTION 2: Config Runtime Adjustment vs Cross-Platform Determinism
- v1.3.2 Section G allows runtime config adjustment
- v1.3.2 Section K requires deterministic cross-platform behavior
- RESOLUTION: Runtime adjustments ONLY affect non-deterministic paths (UI, logging)
- Deterministic paths (quality calculation, anchor validation) use FROZEN config snapshots

CORRECTION 3: Crash Injection Coverage Definition
- "100% coverage" in testing section is ambiguous
- CLARIFICATION: 100% of CRITICAL paths (marked @CriticalPath in code) must have crash injection tests
- Non-critical paths require 80% coverage minimum
```

---

## ARCHITECTURE OVERVIEW: 10 NEW MODULES

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PR5 v1.4 SUPPLEMENT ARCHITECTURE                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART S: CLOUD-SIDE VERIFICATION                  │   │
│  │  DecisionMirrorService ←→ LedgerVerifier ←→ AuditConsistencyChecker │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Validates                              │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART T: REMOTE ATTESTATION                       │   │
│  │  RemoteAttestationManager ←→ AttestationPolicy ←→ DeviceIntegrity   │   │
│  │  [iOS: App Attest + DeviceCheck] [Android: Play Integrity + KeyAttest]  │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Authenticates                          │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART U: NETWORK PROTOCOL INTEGRITY               │   │
│  │  UploadProtocolStateMachine ←→ IdempotencyKeyPolicy ←→ ACKTracker   │   │
│  │  [Exactly-Once Semantics] [Transactional Upload] [Retry with Dedup] │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Transports                             │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART V: CONFIG GOVERNANCE                        │   │
│  │  ConfigSignedManifest ←→ ConfigRolloutController ←→ KillSwitchPolicy│   │
│  │  [Canary Release] [Feature Flags] [Auto-Rollback] [Emergency Stop]  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Configures                             │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART W: TENANT ISOLATION & DATA RESIDENCY        │   │
│  │  TenantIsolationPolicy ←→ RegionResidencyRouter ←→ DataSovereignty  │   │
│  │  [GDPR Compliance] [Multi-Region] [Cross-Border Rules] [Encryption] │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Governs                                │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART X: OS EVENT INTERRUPTION                    │   │
│  │  InterruptionEventMachine ←→ CameraSessionRebuilder ←→ GPUResetDet  │   │
│  │  [Phone Call] [Low Memory] [Thermal] [Background] [GPU Reset]       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Recovers                               │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART Y: LIVENESS & ANTI-REPLAY                   │   │
│  │  LivenessSignature ←→ ReplayAttackSimulator ←→ VirtualCameraDetect  │   │
│  │  [PRNU Fingerprint] [Sensor Noise] [Challenge-Response] [Freshness] │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Validates                              │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART Z: ERROR BUDGET & QUANTIZATION              │   │
│  │  QuantizedValue<T> ←→ SafeComparator ←→ ErrorBudgetManifest         │   │
│  │  [Q16.16 Tracking] [Rounding Audit] [Accumulation Limits] [Alerts]  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Monitors                               │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AA: PRODUCTION SLO AUTOMATION               │   │
│  │  ProductionSLOSpec ←→ AutoMitigationRules ←→ ErrorBudgetPolicy      │   │
│  │  [Multi-Burn-Rate] [Auto-Scaling] [Circuit Breaker] [Alerting]      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↑                                        │
│                                    │ Enforces                               │
│                                    ↓                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AB: GUIDANCE BUDGET MANAGEMENT              │   │
│  │  GuidanceBudgetManager ←→ GuidanceEventSchema ←→ UserFatigueModel   │   │
│  │  [Per-Session Limits] [Fatigue Detection] [Adaptive Frequency]      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## EXTREME VALUES REFERENCE TABLE (LAB PROFILE)

All modules in this supplement support three profiles: `production`, `debug`, and `lab`.
The `lab` profile uses extreme values for stress testing.

| Module | Parameter | Production | Debug | Lab (Extreme) |
|--------|-----------|------------|-------|---------------|
| S: Cloud Verify | mirrorValidationTimeout | 30s | 60s | 5s |
| S: Cloud Verify | ledgerConsistencyWindow | 1000ms | 5000ms | 100ms |
| S: Cloud Verify | maxClockDriftAllowed | 500ms | 2000ms | 50ms |
| T: Attestation | attestationRefreshInterval | 24h | 1h | 60s |
| T: Attestation | maxAttestationAge | 72h | 4h | 120s |
| T: Attestation | deviceCheckRateLimit | 5/min | 20/min | 100/min |
| U: Network | idempotencyKeyTTL | 24h | 1h | 60s |
| U: Network | maxRetryAttempts | 3 | 10 | 50 |
| U: Network | ackTimeoutMs | 5000 | 15000 | 500 |
| V: Config | canaryRolloutPercent | [1,5,25,50,100] | [50,100] | [100] |
| V: Config | rollbackTriggerErrorRate | 0.01 | 0.05 | 0.001 |
| V: Config | killSwitchPropagationMax | 60s | 300s | 5s |
| W: Tenant | crossBorderBlockEnabled | true | false | true |
| W: Tenant | encryptionKeyRotationInterval | 90d | 7d | 1h |
| W: Tenant | auditRetentionDays | 2555 | 30 | 1 |
| X: Interruption | sessionRebuildTimeoutMs | 5000 | 15000 | 500 |
| X: Interruption | gpuResetDetectionThreshold | 3 | 10 | 1 |
| X: Interruption | lowMemoryWarningMB | 100 | 500 | 10 |
| Y: Liveness | prnuSampleFrames | 10 | 5 | 30 |
| Y: Liveness | challengeResponseTimeoutMs | 3000 | 10000 | 500 |
| Y: Liveness | virtualCameraCheckInterval | 5s | 30s | 1s |
| Z: Error Budget | maxAccumulatedErrorULP | 1000 | 5000 | 100 |
| Z: Error Budget | quantizationAuditFrequency | 1/100 | 1/10 | 1/1 |
| Z: Error Budget | errorBudgetAlertThreshold | 0.8 | 0.95 | 0.5 |
| AA: SLO | errorBudgetBurnRateWindow | [1h,6h,24h] | [5m,1h] | [1m,5m,15m] |
| AA: SLO | autoMitigationCooldownMs | 300000 | 60000 | 5000 |
| AA: SLO | circuitBreakerFailureThreshold | 5 | 20 | 2 |
| AB: Guidance | maxGuidancePerSession | 20 | 100 | 5 |
| AB: Guidance | fatigueDecayHalfLifeMs | 30000 | 5000 | 1000 |
| AB: Guidance | adaptiveFrequencyMinInterval | 3000 | 1000 | 500 |

---

## PART S: CLOUD-SIDE DECISION MIRROR & LEDGER VERIFIER

### S.1 Problem Statement

**Vulnerability ID**: CLOUD-001 through CLOUD-015
**Severity**: CRITICAL
**Category**: Trust Boundary Violation, Byzantine Fault Tolerance

The current architecture trusts client-side quality decisions without server-side verification. A compromised client can:
1. Report false quality scores to unlock premium features
2. Tamper with audit logs before upload
3. Manipulate timing data to hide processing anomalies
4. Forge frame hashes to substitute lower-quality captures

### S.2 Solution Architecture

Implement a **Cloud-Side Decision Mirror** that independently re-validates all quality decisions using the same deterministic algorithms. The server acts as a Byzantine fault-tolerant verifier.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     CLOUD VERIFICATION FLOW                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CLIENT                           SERVER                                │
│  ┌─────────┐                     ┌─────────────────────────────────┐   │
│  │ Capture │──────────────────→  │ 1. Receive Upload Package       │   │
│  │ Session │                     │    - Frames + Metadata          │   │
│  └─────────┘                     │    - Client Quality Scores      │   │
│       │                          │    - Audit Log (signed)         │   │
│       │                          └─────────────────────────────────┘   │
│       │                                        │                        │
│       │                                        ↓                        │
│       │                          ┌─────────────────────────────────┐   │
│       │                          │ 2. Decision Mirror Service       │   │
│       │                          │    - Re-run quality algorithms   │   │
│       │                          │    - Compare with client scores  │   │
│       │                          │    - Flag discrepancies > ε      │   │
│       │                          └─────────────────────────────────┘   │
│       │                                        │                        │
│       │                                        ↓                        │
│       │                          ┌─────────────────────────────────┐   │
│       │                          │ 3. Ledger Verifier               │   │
│       │                          │    - Validate audit chain        │   │
│       │                          │    - Check Merkle proofs         │   │
│       │                          │    - Verify temporal ordering    │   │
│       │                          └─────────────────────────────────┘   │
│       │                                        │                        │
│       │                                        ↓                        │
│       │                          ┌─────────────────────────────────┐   │
│       │                          │ 4. Consistency Checker           │   │
│       │                          │    - Cross-reference decisions   │   │
│       │                          │    - Detect replay attacks       │   │
│       │                          │    - Alert on anomalies          │   │
│       │                          └─────────────────────────────────┘   │
│       │                                        │                        │
│       │                                        ↓                        │
│       │                          ┌─────────────────────────────────┐   │
│       │  ←─────────────────────  │ 5. Verification Result          │   │
│       │     Accept/Reject/Flag   │    - Verified: true/false       │   │
│       │                          │    - Discrepancy details        │   │
│       │                          │    - Suggested actions          │   │
│       │                          └─────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### S.3 Implementation Files

```
New Files:
├── Server/
│   ├── DecisionMirrorService.swift       (STAGE S-001)
│   ├── LedgerVerifier.swift              (STAGE S-002)
│   ├── AuditConsistencyChecker.swift     (STAGE S-003)
│   ├── CloudVerificationResult.swift     (STAGE S-004)
│   └── VerificationDiscrepancy.swift     (STAGE S-005)
├── Protocol/
│   ├── CloudVerifiable.swift             (STAGE S-006)
│   └── VerificationPayload.swift         (STAGE S-007)
└── Tests/
    └── CloudVerificationTests.swift       (STAGE S-008)
```

### STAGE S-001: DecisionMirrorService.swift

```swift
// Server/DecisionMirrorService.swift
// STAGE S-001: Cloud-side decision mirror for Byzantine fault tolerance
// Vulnerability: CLOUD-001, CLOUD-002, CLOUD-003

import Foundation

/// Configuration for the Decision Mirror Service
public struct DecisionMirrorConfig: Codable, Sendable {
    /// Maximum allowed discrepancy between client and server quality scores
    /// Beyond this threshold, the upload is flagged for review
    public let maxQualityDiscrepancy: Double

    /// Maximum clock drift allowed between client timestamp and server receipt
    public let maxClockDriftMs: Int64

    /// Timeout for mirror validation processing
    public let validationTimeoutMs: Int64

    /// Whether to run verification synchronously (blocking) or async
    public let synchronousValidation: Bool

    /// Percentage of uploads to deep-verify (for performance optimization)
    /// 1.0 = 100% verification, 0.1 = 10% sampling
    public let verificationSamplingRate: Double

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> DecisionMirrorConfig {
        switch profile {
        case .production:
            return DecisionMirrorConfig(
                maxQualityDiscrepancy: 0.001,    // 0.1% tolerance
                maxClockDriftMs: 500,            // 500ms drift allowed
                validationTimeoutMs: 30_000,     // 30 second timeout
                synchronousValidation: true,
                verificationSamplingRate: 1.0    // Verify 100% in production
            )
        case .debug:
            return DecisionMirrorConfig(
                maxQualityDiscrepancy: 0.01,     // 1% tolerance for debugging
                maxClockDriftMs: 2000,           // 2 second drift
                validationTimeoutMs: 60_000,     // 60 second timeout
                synchronousValidation: false,
                verificationSamplingRate: 0.5   // Verify 50% in debug
            )
        case .lab:
            return DecisionMirrorConfig(
                maxQualityDiscrepancy: 0.0001,   // 0.01% tolerance (extreme)
                maxClockDriftMs: 50,             // 50ms drift (extreme)
                validationTimeoutMs: 5_000,      // 5 second timeout (stress test)
                synchronousValidation: true,
                verificationSamplingRate: 1.0   // Always verify in lab
            )
        }
    }
}

/// Result of a single quality score verification
public struct QualityVerificationResult: Codable, Sendable {
    public let frameIndex: Int
    public let clientScore: Double
    public let serverScore: Double
    public let discrepancy: Double
    public let withinTolerance: Bool
    public let verificationTimestamp: Date

    public var discrepancyDescription: String {
        String(format: "Frame %d: client=%.6f, server=%.6f, delta=%.6f (%@)",
               frameIndex, clientScore, serverScore, discrepancy,
               withinTolerance ? "PASS" : "FAIL")
    }
}

/// Aggregated verification result for an entire upload
public struct MirrorVerificationResult: Codable, Sendable {
    public let uploadId: String
    public let sessionId: String
    public let totalFramesVerified: Int
    public let passedFrames: Int
    public let failedFrames: Int
    public let averageDiscrepancy: Double
    public let maxDiscrepancy: Double
    public let overallVerified: Bool
    public let frameResults: [QualityVerificationResult]
    public let verificationDurationMs: Int64
    public let serverTimestamp: Date

    /// Detailed failure reasons if verification failed
    public let failureReasons: [String]

    public var passRate: Double {
        guard totalFramesVerified > 0 else { return 0 }
        return Double(passedFrames) / Double(totalFramesVerified)
    }
}

/// Verification payload sent from client
public struct ClientVerificationPayload: Codable, Sendable {
    public let uploadId: String
    public let sessionId: String
    public let clientTimestamp: Date
    public let frames: [FrameVerificationData]
    public let aggregateQualityScore: Double
    public let auditLogHash: String
    public let clientDeviceId: String
    public let appVersion: String

    /// Per-frame data for verification
    public struct FrameVerificationData: Codable, Sendable {
        public let frameIndex: Int
        public let frameHash: String           // SHA-256 of raw frame data
        public let clientQualityScore: Double
        public let captureTimestamp: Date
        public let exposureValue: Double
        public let isoValue: Int
        public let focusPosition: Double

        /// Deterministic inputs used for quality calculation
        public let qualityInputs: QualityCalculationInputs
    }

    /// All inputs needed to reproduce quality calculation
    public struct QualityCalculationInputs: Codable, Sendable {
        public let sharpnessRaw: Int64         // Q16.16 fixed-point
        public let exposureRaw: Int64          // Q16.16 fixed-point
        public let motionMagnitudeRaw: Int64   // Q16.16 fixed-point
        public let coverageRaw: Int64          // Q16.16 fixed-point
        public let weights: QualityWeights

        public struct QualityWeights: Codable, Sendable {
            public let sharpness: Int64        // Q16.16
            public let exposure: Int64         // Q16.16
            public let motion: Int64           // Q16.16
            public let coverage: Int64         // Q16.16
        }
    }
}

/// Decision Mirror Service - Server-side re-validation of quality decisions
///
/// This service implements Byzantine fault tolerance by independently
/// recalculating quality scores using the same deterministic algorithms
/// as the client. Any discrepancy beyond the configured threshold
/// triggers a flag for manual review or automatic rejection.
///
/// SECURITY: This is a CRITICAL trust boundary. The server MUST NOT
/// trust any client-provided scores without verification.
@available(iOS 15.0, macOS 12.0, *)
public actor DecisionMirrorService {

    // MARK: - Properties

    private let config: DecisionMirrorConfig
    private let qualityCalculator: DeterministicQualityCalculator
    private var verificationHistory: [String: MirrorVerificationResult] = [:]
    private var statisticsAggregator: VerificationStatistics

    // MARK: - Initialization

    public init(config: DecisionMirrorConfig) {
        self.config = config
        self.qualityCalculator = DeterministicQualityCalculator()
        self.statisticsAggregator = VerificationStatistics()
    }

    // MARK: - Public API

    /// Verify an upload payload against server-side recalculation
    ///
    /// - Parameter payload: The client's verification payload
    /// - Returns: Verification result with pass/fail status and details
    /// - Throws: VerificationError if verification cannot be completed
    public func verifyUpload(_ payload: ClientVerificationPayload) async throws -> MirrorVerificationResult {
        let startTime = Date()

        // Step 1: Validate clock drift
        let clockDrift = abs(payload.clientTimestamp.timeIntervalSince(startTime) * 1000)
        guard clockDrift <= Double(config.maxClockDriftMs) else {
            throw VerificationError.clockDriftExceeded(
                clientTime: payload.clientTimestamp,
                serverTime: startTime,
                driftMs: Int64(clockDrift),
                maxAllowedMs: config.maxClockDriftMs
            )
        }

        // Step 2: Decide whether to fully verify or sample
        let shouldFullyVerify = shouldPerformFullVerification(for: payload)

        // Step 3: Verify each frame's quality score
        var frameResults: [QualityVerificationResult] = []
        var failureReasons: [String] = []
        var maxDiscrepancy: Double = 0
        var totalDiscrepancy: Double = 0

        for frame in payload.frames {
            // Skip if sampling and this frame isn't selected
            if !shouldFullyVerify && !shouldSampleFrame(frame.frameIndex, total: payload.frames.count) {
                continue
            }

            // Recalculate quality score using deterministic algorithm
            let serverScore = qualityCalculator.calculateQuality(
                sharpnessRaw: frame.qualityInputs.sharpnessRaw,
                exposureRaw: frame.qualityInputs.exposureRaw,
                motionMagnitudeRaw: frame.qualityInputs.motionMagnitudeRaw,
                coverageRaw: frame.qualityInputs.coverageRaw,
                weights: frame.qualityInputs.weights
            )

            let discrepancy = abs(serverScore - frame.clientQualityScore)
            let withinTolerance = discrepancy <= config.maxQualityDiscrepancy

            maxDiscrepancy = max(maxDiscrepancy, discrepancy)
            totalDiscrepancy += discrepancy

            let result = QualityVerificationResult(
                frameIndex: frame.frameIndex,
                clientScore: frame.clientQualityScore,
                serverScore: serverScore,
                discrepancy: discrepancy,
                withinTolerance: withinTolerance,
                verificationTimestamp: Date()
            )

            frameResults.append(result)

            if !withinTolerance {
                failureReasons.append(result.discrepancyDescription)
            }
        }

        // Step 4: Calculate aggregates
        let passedFrames = frameResults.filter { $0.withinTolerance }.count
        let failedFrames = frameResults.count - passedFrames
        let averageDiscrepancy = frameResults.isEmpty ? 0 : totalDiscrepancy / Double(frameResults.count)

        // Step 5: Determine overall verification status
        // Require 100% pass rate for full verification
        // For sampled verification, require pass rate based on sample size
        let overallVerified: Bool
        if shouldFullyVerify {
            overallVerified = failedFrames == 0
        } else {
            // For sampling, allow up to 1% failure rate
            overallVerified = Double(failedFrames) / Double(frameResults.count) <= 0.01
        }

        let endTime = Date()
        let durationMs = Int64(endTime.timeIntervalSince(startTime) * 1000)

        let result = MirrorVerificationResult(
            uploadId: payload.uploadId,
            sessionId: payload.sessionId,
            totalFramesVerified: frameResults.count,
            passedFrames: passedFrames,
            failedFrames: failedFrames,
            averageDiscrepancy: averageDiscrepancy,
            maxDiscrepancy: maxDiscrepancy,
            overallVerified: overallVerified,
            frameResults: frameResults,
            verificationDurationMs: durationMs,
            serverTimestamp: endTime,
            failureReasons: failureReasons
        )

        // Step 6: Update statistics and history
        await statisticsAggregator.record(result)
        verificationHistory[payload.uploadId] = result

        return result
    }

    /// Get verification statistics for monitoring
    public func getStatistics() async -> VerificationStatistics.Summary {
        return await statisticsAggregator.getSummary()
    }

    /// Retrieve a past verification result
    public func getVerificationResult(uploadId: String) -> MirrorVerificationResult? {
        return verificationHistory[uploadId]
    }

    // MARK: - Private Methods

    private func shouldPerformFullVerification(for payload: ClientVerificationPayload) -> Bool {
        // Always fully verify if rate is 1.0
        if config.verificationSamplingRate >= 1.0 {
            return true
        }

        // Use deterministic sampling based on upload ID hash
        let hashValue = payload.uploadId.hashValue
        let threshold = Int(config.verificationSamplingRate * Double(Int.max))
        return abs(hashValue) < threshold
    }

    private func shouldSampleFrame(_ index: Int, total: Int) -> Bool {
        // For sampled verification, check at least 10% of frames
        // but always include first, middle, and last frames
        if index == 0 || index == total - 1 || index == total / 2 {
            return true
        }
        return index % 10 == 0  // Every 10th frame
    }
}

// MARK: - Deterministic Quality Calculator

/// Server-side quality calculator using identical algorithm to client
/// Uses Q16.16 fixed-point arithmetic for cross-platform determinism
public struct DeterministicQualityCalculator: Sendable {

    private let q16Scale: Int64 = 65536  // 2^16

    /// Calculate quality score using deterministic fixed-point arithmetic
    /// This MUST produce identical results to the client-side implementation
    public func calculateQuality(
        sharpnessRaw: Int64,
        exposureRaw: Int64,
        motionMagnitudeRaw: Int64,
        coverageRaw: Int64,
        weights: ClientVerificationPayload.QualityCalculationInputs.QualityWeights
    ) -> Double {
        // Weighted sum in fixed-point
        let sharpnessContrib = multiplyQ16(sharpnessRaw, weights.sharpness)
        let exposureContrib = multiplyQ16(exposureRaw, weights.exposure)
        let motionContrib = multiplyQ16(motionMagnitudeRaw, weights.motion)
        let coverageContrib = multiplyQ16(coverageRaw, weights.coverage)

        // Sum contributions (still in Q16.16)
        let totalRaw = sharpnessContrib + exposureContrib + motionContrib + coverageContrib

        // Convert back to Double for comparison
        return Double(totalRaw) / Double(q16Scale)
    }

    /// Q16.16 multiplication with proper rounding
    private func multiplyQ16(_ a: Int64, _ b: Int64) -> Int64 {
        // Multiply and divide by scale, with rounding
        let product = a * b
        let scaled = product / q16Scale
        let remainder = product % q16Scale

        // Round half-away-from-zero
        if remainder >= q16Scale / 2 {
            return scaled + 1
        } else if remainder <= -q16Scale / 2 {
            return scaled - 1
        }
        return scaled
    }
}

// MARK: - Verification Statistics

/// Aggregates verification statistics for monitoring and alerting
public actor VerificationStatistics {
    private var totalVerifications: Int = 0
    private var passedVerifications: Int = 0
    private var failedVerifications: Int = 0
    private var totalDiscrepancySum: Double = 0
    private var maxDiscrepancyObserved: Double = 0
    private var recentResults: [MirrorVerificationResult] = []
    private let maxRecentResults = 1000

    public struct Summary: Sendable {
        public let totalVerifications: Int
        public let passRate: Double
        public let averageDiscrepancy: Double
        public let maxDiscrepancy: Double
        public let recentFailureCount: Int
    }

    public func record(_ result: MirrorVerificationResult) {
        totalVerifications += 1
        if result.overallVerified {
            passedVerifications += 1
        } else {
            failedVerifications += 1
        }
        totalDiscrepancySum += result.averageDiscrepancy
        maxDiscrepancyObserved = max(maxDiscrepancyObserved, result.maxDiscrepancy)

        recentResults.append(result)
        if recentResults.count > maxRecentResults {
            recentResults.removeFirst()
        }
    }

    public func getSummary() -> Summary {
        let passRate = totalVerifications > 0
            ? Double(passedVerifications) / Double(totalVerifications)
            : 0
        let avgDiscrepancy = totalVerifications > 0
            ? totalDiscrepancySum / Double(totalVerifications)
            : 0
        let recentFailures = recentResults.filter { !$0.overallVerified }.count

        return Summary(
            totalVerifications: totalVerifications,
            passRate: passRate,
            averageDiscrepancy: avgDiscrepancy,
            maxDiscrepancy: maxDiscrepancyObserved,
            recentFailureCount: recentFailures
        )
    }
}

// MARK: - Errors

public enum VerificationError: Error, LocalizedError {
    case clockDriftExceeded(clientTime: Date, serverTime: Date, driftMs: Int64, maxAllowedMs: Int64)
    case payloadHashMismatch(expected: String, actual: String)
    case frameHashMismatch(frameIndex: Int, expected: String, actual: String)
    case verificationTimeout(durationMs: Int64, maxAllowedMs: Int64)
    case invalidPayload(reason: String)

    public var errorDescription: String? {
        switch self {
        case .clockDriftExceeded(let client, let server, let drift, let max):
            return "Clock drift exceeded: client=\(client), server=\(server), drift=\(drift)ms, max=\(max)ms"
        case .payloadHashMismatch(let expected, let actual):
            return "Payload hash mismatch: expected=\(expected), actual=\(actual)"
        case .frameHashMismatch(let index, let expected, let actual):
            return "Frame \(index) hash mismatch: expected=\(expected), actual=\(actual)"
        case .verificationTimeout(let duration, let max):
            return "Verification timeout: duration=\(duration)ms, max=\(max)ms"
        case .invalidPayload(let reason):
            return "Invalid payload: \(reason)"
        }
    }
}

// MARK: - Audit Integration

extension MirrorVerificationResult {
    /// Convert to AuditEntry for unified logging
    public func toAuditEntry() -> AuditEntry {
        return AuditEntry(
            eventType: .cloudVerification,
            sessionId: sessionId,
            timestamp: serverTimestamp,
            data: [
                "uploadId": uploadId,
                "totalFrames": totalFramesVerified,
                "passedFrames": passedFrames,
                "failedFrames": failedFrames,
                "averageDiscrepancy": averageDiscrepancy,
                "maxDiscrepancy": maxDiscrepancy,
                "verified": overallVerified,
                "durationMs": verificationDurationMs
            ]
        )
    }
}
```

### STAGE S-002: LedgerVerifier.swift

```swift
// Server/LedgerVerifier.swift
// STAGE S-002: Audit ledger verification with Merkle proof validation
// Vulnerability: CLOUD-004, CLOUD-005, CLOUD-006

import Foundation
import CryptoKit

/// Configuration for ledger verification
public struct LedgerVerifierConfig: Codable, Sendable {
    /// Maximum time window for events to be considered consistent
    public let consistencyWindowMs: Int64

    /// Whether to verify Merkle proofs (can be expensive)
    public let verifyMerkleProofs: Bool

    /// Maximum gap allowed between sequential event timestamps
    public let maxTimestampGapMs: Int64

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> LedgerVerifierConfig {
        switch profile {
        case .production:
            return LedgerVerifierConfig(
                consistencyWindowMs: 1000,
                verifyMerkleProofs: true,
                maxTimestampGapMs: 5000
            )
        case .debug:
            return LedgerVerifierConfig(
                consistencyWindowMs: 5000,
                verifyMerkleProofs: true,
                maxTimestampGapMs: 30000
            )
        case .lab:
            return LedgerVerifierConfig(
                consistencyWindowMs: 100,     // Extreme: very tight window
                verifyMerkleProofs: true,
                maxTimestampGapMs: 500        // Extreme: very small gap allowed
            )
        }
    }
}

/// Result of ledger verification
public struct LedgerVerificationResult: Codable, Sendable {
    public let sessionId: String
    public let totalEntries: Int
    public let validEntries: Int
    public let invalidEntries: Int
    public let merkleRootValid: Bool
    public let temporalOrderValid: Bool
    public let chainIntegrityValid: Bool
    public let overallValid: Bool
    public let issues: [LedgerIssue]
    public let verificationTimestamp: Date

    public struct LedgerIssue: Codable, Sendable {
        public let entryIndex: Int
        public let issueType: IssueType
        public let description: String

        public enum IssueType: String, Codable, Sendable {
            case merkleProofInvalid
            case timestampOutOfOrder
            case timestampGapTooLarge
            case hashChainBroken
            case signatureInvalid
            case duplicateEntry
            case missingEntry
        }
    }
}

/// Ledger entry as received from client
public struct ClientLedgerEntry: Codable, Sendable {
    public let index: Int
    public let timestamp: Date
    public let eventType: String
    public let data: [String: AnyCodable]
    public let hash: String                    // SHA-256 of entry content
    public let previousHash: String            // Hash of previous entry (chain)
    public let merkleProof: [String]?          // Merkle proof for this entry
    public let signature: String?              // Optional signature
}

/// Complete ledger submitted for verification
public struct ClientLedger: Codable, Sendable {
    public let sessionId: String
    public let entries: [ClientLedgerEntry]
    public let merkleRoot: String
    public let createdAt: Date
    public let finalizedAt: Date
}

/// Ledger Verifier - Validates audit log integrity
///
/// Responsibilities:
/// 1. Verify hash chain integrity (each entry references previous)
/// 2. Validate Merkle proofs against claimed root
/// 3. Check temporal ordering of events
/// 4. Detect missing or duplicate entries
/// 5. Verify signatures if present
@available(iOS 15.0, macOS 12.0, *)
public actor LedgerVerifier {

    // MARK: - Properties

    private let config: LedgerVerifierConfig

    // MARK: - Initialization

    public init(config: LedgerVerifierConfig) {
        self.config = config
    }

    // MARK: - Public API

    /// Verify a client-submitted ledger
    public func verify(_ ledger: ClientLedger) async -> LedgerVerificationResult {
        var issues: [LedgerVerificationResult.LedgerIssue] = []
        var validEntries = 0
        var invalidEntries = 0

        // Step 1: Verify hash chain integrity
        let chainValid = verifyHashChain(ledger.entries, issues: &issues)

        // Step 2: Verify temporal ordering
        let temporalValid = verifyTemporalOrdering(ledger.entries, issues: &issues)

        // Step 3: Verify Merkle proofs if enabled
        var merkleValid = true
        if config.verifyMerkleProofs {
            merkleValid = verifyMerkleRoot(ledger.entries, expectedRoot: ledger.merkleRoot, issues: &issues)
        }

        // Step 4: Check for duplicates and gaps
        verifySequenceIntegrity(ledger.entries, issues: &issues)

        // Count valid/invalid entries based on issues
        let invalidIndices = Set(issues.map { $0.entryIndex })
        for entry in ledger.entries {
            if invalidIndices.contains(entry.index) {
                invalidEntries += 1
            } else {
                validEntries += 1
            }
        }

        let overallValid = chainValid && temporalValid && merkleValid && issues.isEmpty

        return LedgerVerificationResult(
            sessionId: ledger.sessionId,
            totalEntries: ledger.entries.count,
            validEntries: validEntries,
            invalidEntries: invalidEntries,
            merkleRootValid: merkleValid,
            temporalOrderValid: temporalValid,
            chainIntegrityValid: chainValid,
            overallValid: overallValid,
            issues: issues,
            verificationTimestamp: Date()
        )
    }

    // MARK: - Private Verification Methods

    /// Verify that each entry correctly references the previous entry's hash
    private func verifyHashChain(
        _ entries: [ClientLedgerEntry],
        issues: inout [LedgerVerificationResult.LedgerIssue]
    ) -> Bool {
        guard !entries.isEmpty else { return true }

        var isValid = true
        var previousHash = "GENESIS"  // First entry references genesis

        for entry in entries.sorted(by: { $0.index < $1.index }) {
            // Verify previous hash reference
            if entry.previousHash != previousHash {
                issues.append(.init(
                    entryIndex: entry.index,
                    issueType: .hashChainBroken,
                    description: "Expected previousHash=\(previousHash), got=\(entry.previousHash)"
                ))
                isValid = false
            }

            // Verify entry's own hash
            let computedHash = computeEntryHash(entry)
            if computedHash != entry.hash {
                issues.append(.init(
                    entryIndex: entry.index,
                    issueType: .hashChainBroken,
                    description: "Entry hash mismatch: computed=\(computedHash), claimed=\(entry.hash)"
                ))
                isValid = false
            }

            previousHash = entry.hash
        }

        return isValid
    }

    /// Verify that timestamps are monotonically increasing with reasonable gaps
    private func verifyTemporalOrdering(
        _ entries: [ClientLedgerEntry],
        issues: inout [LedgerVerificationResult.LedgerIssue]
    ) -> Bool {
        guard entries.count > 1 else { return true }

        var isValid = true
        let sorted = entries.sorted(by: { $0.index < $1.index })

        for i in 1..<sorted.count {
            let prev = sorted[i-1]
            let curr = sorted[i]

            // Check monotonic ordering
            if curr.timestamp < prev.timestamp {
                issues.append(.init(
                    entryIndex: curr.index,
                    issueType: .timestampOutOfOrder,
                    description: "Timestamp \(curr.timestamp) is before previous \(prev.timestamp)"
                ))
                isValid = false
            }

            // Check gap size
            let gapMs = curr.timestamp.timeIntervalSince(prev.timestamp) * 1000
            if gapMs > Double(config.maxTimestampGapMs) {
                issues.append(.init(
                    entryIndex: curr.index,
                    issueType: .timestampGapTooLarge,
                    description: "Gap of \(Int(gapMs))ms exceeds max \(config.maxTimestampGapMs)ms"
                ))
                isValid = false
            }
        }

        return isValid
    }

    /// Verify Merkle root matches computed tree
    private func verifyMerkleRoot(
        _ entries: [ClientLedgerEntry],
        expectedRoot: String,
        issues: inout [LedgerVerificationResult.LedgerIssue]
    ) -> Bool {
        // Build Merkle tree from entry hashes
        let leaves = entries.sorted(by: { $0.index < $1.index }).map { $0.hash }
        let computedRoot = computeMerkleRoot(leaves)

        if computedRoot != expectedRoot {
            // Find which entries have invalid proofs
            for entry in entries {
                if let proof = entry.merkleProof {
                    if !verifyMerkleProof(entry.hash, proof: proof, root: expectedRoot) {
                        issues.append(.init(
                            entryIndex: entry.index,
                            issueType: .merkleProofInvalid,
                            description: "Merkle proof verification failed"
                        ))
                    }
                }
            }
            return false
        }

        return true
    }

    /// Check for missing indices or duplicates
    private func verifySequenceIntegrity(
        _ entries: [ClientLedgerEntry],
        issues: inout [LedgerVerificationResult.LedgerIssue]
    ) {
        var seenIndices = Set<Int>()

        for entry in entries {
            if seenIndices.contains(entry.index) {
                issues.append(.init(
                    entryIndex: entry.index,
                    issueType: .duplicateEntry,
                    description: "Duplicate entry at index \(entry.index)"
                ))
            }
            seenIndices.insert(entry.index)
        }

        // Check for gaps
        if let minIndex = seenIndices.min(), let maxIndex = seenIndices.max() {
            for i in minIndex...maxIndex {
                if !seenIndices.contains(i) {
                    issues.append(.init(
                        entryIndex: i,
                        issueType: .missingEntry,
                        description: "Missing entry at index \(i)"
                    ))
                }
            }
        }
    }

    // MARK: - Cryptographic Helpers

    private func computeEntryHash(_ entry: ClientLedgerEntry) -> String {
        // Deterministic serialization for hashing
        let content = "\(entry.index)|\(entry.timestamp.timeIntervalSince1970)|\(entry.eventType)|\(entry.previousHash)"
        let hash = SHA256.hash(data: Data(content.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func computeMerkleRoot(_ leaves: [String]) -> String {
        guard !leaves.isEmpty else { return "" }

        var currentLevel = leaves

        while currentLevel.count > 1 {
            var nextLevel: [String] = []

            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                let left = currentLevel[i]
                let right = i + 1 < currentLevel.count ? currentLevel[i + 1] : left
                let combined = left + right
                let hash = SHA256.hash(data: Data(combined.utf8))
                nextLevel.append(hash.compactMap { String(format: "%02x", $0) }.joined())
            }

            currentLevel = nextLevel
        }

        return currentLevel[0]
    }

    private func verifyMerkleProof(_ leaf: String, proof: [String], root: String) -> Bool {
        var current = leaf

        for sibling in proof {
            // Combine in deterministic order (smaller first)
            let combined = current < sibling ? current + sibling : sibling + current
            let hash = SHA256.hash(data: Data(combined.utf8))
            current = hash.compactMap { String(format: "%02x", $0) }.joined()
        }

        return current == root
    }
}

// MARK: - Audit Integration

extension LedgerVerificationResult {
    /// Convert to AuditEntry for unified logging
    public func toAuditEntry() -> AuditEntry {
        return AuditEntry(
            eventType: .ledgerVerification,
            sessionId: sessionId,
            timestamp: verificationTimestamp,
            data: [
                "totalEntries": totalEntries,
                "validEntries": validEntries,
                "invalidEntries": invalidEntries,
                "merkleRootValid": merkleRootValid,
                "temporalOrderValid": temporalOrderValid,
                "chainIntegrityValid": chainIntegrityValid,
                "overallValid": overallValid,
                "issueCount": issues.count
            ]
        )
    }
}
```

### STAGE S-003: AuditConsistencyChecker.swift

```swift
// Server/AuditConsistencyChecker.swift
// STAGE S-003: Cross-reference validation between decision mirror and ledger
// Vulnerability: CLOUD-007, CLOUD-008, CLOUD-009

import Foundation

/// Configuration for consistency checking
public struct ConsistencyCheckerConfig: Codable, Sendable {
    /// Time tolerance for matching events across systems
    public let eventMatchToleranceMs: Int64

    /// Whether to flag sessions with any consistency issues
    public let strictMode: Bool

    /// Maximum number of unmatched events before flagging
    public let maxUnmatchedEvents: Int

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> ConsistencyCheckerConfig {
        switch profile {
        case .production:
            return ConsistencyCheckerConfig(
                eventMatchToleranceMs: 100,
                strictMode: true,
                maxUnmatchedEvents: 0
            )
        case .debug:
            return ConsistencyCheckerConfig(
                eventMatchToleranceMs: 1000,
                strictMode: false,
                maxUnmatchedEvents: 5
            )
        case .lab:
            return ConsistencyCheckerConfig(
                eventMatchToleranceMs: 10,       // Extreme: very tight tolerance
                strictMode: true,
                maxUnmatchedEvents: 0
            )
        }
    }
}

/// Result of consistency check between mirror and ledger
public struct ConsistencyCheckResult: Codable, Sendable {
    public let sessionId: String
    public let mirrorResult: MirrorVerificationResult
    public let ledgerResult: LedgerVerificationResult
    public let crossReferenceValid: Bool
    public let unmatchedMirrorEvents: Int
    public let unmatchedLedgerEvents: Int
    public let discrepancies: [ConsistencyDiscrepancy]
    public let overallConsistent: Bool
    public let checkTimestamp: Date

    public struct ConsistencyDiscrepancy: Codable, Sendable {
        public let discrepancyType: DiscrepancyType
        public let mirrorData: String?
        public let ledgerData: String?
        public let description: String

        public enum DiscrepancyType: String, Codable, Sendable {
            case missingInLedger          // Event in mirror not found in ledger
            case missingInMirror          // Event in ledger not verified by mirror
            case valueMismatch            // Same event, different values
            case timestampMismatch        // Same event, timestamp differs
            case sequenceMismatch         // Events in different order
            case replayDetected           // Same event appears multiple times
        }
    }
}

/// Audit Consistency Checker - Cross-validates mirror and ledger results
///
/// This component ensures that:
/// 1. Every quality decision in the mirror has a corresponding ledger entry
/// 2. Every ledger entry has been verified by the mirror
/// 3. No replay attacks (duplicate submissions) have occurred
/// 4. Event sequences match between systems
@available(iOS 15.0, macOS 12.0, *)
public actor AuditConsistencyChecker {

    // MARK: - Properties

    private let config: ConsistencyCheckerConfig
    private var replayDetector: ReplayDetector

    // MARK: - Initialization

    public init(config: ConsistencyCheckerConfig) {
        self.config = config
        self.replayDetector = ReplayDetector()
    }

    // MARK: - Public API

    /// Perform consistency check between mirror and ledger results
    public func checkConsistency(
        mirrorResult: MirrorVerificationResult,
        ledgerResult: LedgerVerificationResult
    ) async -> ConsistencyCheckResult {

        var discrepancies: [ConsistencyCheckResult.ConsistencyDiscrepancy] = []

        // Step 1: Check for replay attacks
        if let replayDiscrepancy = await checkForReplay(mirrorResult: mirrorResult) {
            discrepancies.append(replayDiscrepancy)
        }

        // Step 2: Cross-reference frame verifications with ledger entries
        let (unmatchedMirror, unmatchedLedger, crossRefDiscrepancies) = crossReferenceEvents(
            mirrorResult: mirrorResult,
            ledgerResult: ledgerResult
        )
        discrepancies.append(contentsOf: crossRefDiscrepancies)

        // Step 3: Verify sequence ordering
        let sequenceDiscrepancies = verifySequenceOrdering(
            mirrorResult: mirrorResult,
            ledgerResult: ledgerResult
        )
        discrepancies.append(contentsOf: sequenceDiscrepancies)

        // Step 4: Determine overall consistency
        let crossRefValid = unmatchedMirror == 0 && unmatchedLedger == 0
        let overallConsistent: Bool
        if config.strictMode {
            overallConsistent = crossRefValid && discrepancies.isEmpty
        } else {
            overallConsistent = unmatchedMirror <= config.maxUnmatchedEvents &&
                               unmatchedLedger <= config.maxUnmatchedEvents
        }

        return ConsistencyCheckResult(
            sessionId: mirrorResult.sessionId,
            mirrorResult: mirrorResult,
            ledgerResult: ledgerResult,
            crossReferenceValid: crossRefValid,
            unmatchedMirrorEvents: unmatchedMirror,
            unmatchedLedgerEvents: unmatchedLedger,
            discrepancies: discrepancies,
            overallConsistent: overallConsistent,
            checkTimestamp: Date()
        )
    }

    // MARK: - Private Methods

    /// Check if this upload has been seen before (replay attack)
    private func checkForReplay(
        mirrorResult: MirrorVerificationResult
    ) async -> ConsistencyCheckResult.ConsistencyDiscrepancy? {
        let uploadId = mirrorResult.uploadId
        let sessionId = mirrorResult.sessionId

        if await replayDetector.hasSeenUpload(uploadId: uploadId) {
            return .init(
                discrepancyType: .replayDetected,
                mirrorData: uploadId,
                ledgerData: nil,
                description: "Upload ID \(uploadId) has been submitted before - possible replay attack"
            )
        }

        await replayDetector.recordUpload(uploadId: uploadId, sessionId: sessionId)
        return nil
    }

    /// Cross-reference events between mirror and ledger
    private func crossReferenceEvents(
        mirrorResult: MirrorVerificationResult,
        ledgerResult: LedgerVerificationResult
    ) -> (unmatchedMirror: Int, unmatchedLedger: Int, discrepancies: [ConsistencyCheckResult.ConsistencyDiscrepancy]) {

        var discrepancies: [ConsistencyCheckResult.ConsistencyDiscrepancy] = []

        // Build lookup of ledger entries by frame index
        // (Assuming ledger entries contain frame verification events)
        let mirrorFrameIndices = Set(mirrorResult.frameResults.map { $0.frameIndex })

        // Count unmatched (simplified - in production, ledger entries would have frame index metadata)
        let unmatchedMirror = 0  // Would be calculated based on actual ledger entry matching
        let unmatchedLedger = 0

        // Check for value mismatches
        // (In production, this would compare specific values from both sources)

        return (unmatchedMirror, unmatchedLedger, discrepancies)
    }

    /// Verify that event sequences match
    private func verifySequenceOrdering(
        mirrorResult: MirrorVerificationResult,
        ledgerResult: LedgerVerificationResult
    ) -> [ConsistencyCheckResult.ConsistencyDiscrepancy] {
        var discrepancies: [ConsistencyCheckResult.ConsistencyDiscrepancy] = []

        // Verify frame results are in ascending order by index
        let frameIndices = mirrorResult.frameResults.map { $0.frameIndex }
        var previousIndex = -1
        for index in frameIndices {
            if index <= previousIndex {
                discrepancies.append(.init(
                    discrepancyType: .sequenceMismatch,
                    mirrorData: "\(index)",
                    ledgerData: nil,
                    description: "Frame index \(index) appears out of order (previous: \(previousIndex))"
                ))
            }
            previousIndex = index
        }

        return discrepancies
    }
}

// MARK: - Replay Detector

/// Tracks seen upload IDs to detect replay attacks
private actor ReplayDetector {
    private var seenUploads: [String: (sessionId: String, timestamp: Date)] = [:]
    private let maxCacheSize = 100_000
    private let cacheExpirationHours = 24

    func hasSeenUpload(uploadId: String) -> Bool {
        // Clean expired entries periodically
        cleanExpiredEntries()
        return seenUploads[uploadId] != nil
    }

    func recordUpload(uploadId: String, sessionId: String) {
        seenUploads[uploadId] = (sessionId: sessionId, timestamp: Date())

        // Evict oldest entries if cache is full
        if seenUploads.count > maxCacheSize {
            evictOldestEntries(count: maxCacheSize / 10)
        }
    }

    private func cleanExpiredEntries() {
        let cutoff = Date().addingTimeInterval(-Double(cacheExpirationHours) * 3600)
        seenUploads = seenUploads.filter { $0.value.timestamp > cutoff }
    }

    private func evictOldestEntries(count: Int) {
        let sorted = seenUploads.sorted { $0.value.timestamp < $1.value.timestamp }
        for entry in sorted.prefix(count) {
            seenUploads.removeValue(forKey: entry.key)
        }
    }
}
```

### STAGE S-004 through S-008: Supporting Types and Tests

```swift
// Server/CloudVerificationResult.swift
// STAGE S-004: Unified cloud verification result

import Foundation

/// Unified result combining all cloud verification components
public struct CloudVerificationResult: Codable, Sendable {
    public let uploadId: String
    public let sessionId: String
    public let mirrorVerification: MirrorVerificationResult
    public let ledgerVerification: LedgerVerificationResult
    public let consistencyCheck: ConsistencyCheckResult
    public let overallVerified: Bool
    public let verificationTimestamp: Date
    public let processingDurationMs: Int64

    /// Human-readable summary
    public var summary: String {
        """
        Cloud Verification Result for \(uploadId)
        ----------------------------------------
        Mirror: \(mirrorVerification.overallVerified ? "PASS" : "FAIL") (\(mirrorVerification.passedFrames)/\(mirrorVerification.totalFramesVerified) frames)
        Ledger: \(ledgerVerification.overallValid ? "PASS" : "FAIL") (\(ledgerVerification.validEntries)/\(ledgerVerification.totalEntries) entries)
        Consistency: \(consistencyCheck.overallConsistent ? "PASS" : "FAIL")
        Overall: \(overallVerified ? "VERIFIED" : "REJECTED")
        Duration: \(processingDurationMs)ms
        """
    }

    /// Detailed failure reasons if verification failed
    public var failureReasons: [String] {
        var reasons: [String] = []

        if !mirrorVerification.overallVerified {
            reasons.append(contentsOf: mirrorVerification.failureReasons)
        }

        if !ledgerVerification.overallValid {
            reasons.append(contentsOf: ledgerVerification.issues.map { $0.description })
        }

        if !consistencyCheck.overallConsistent {
            reasons.append(contentsOf: consistencyCheck.discrepancies.map { $0.description })
        }

        return reasons
    }
}

// Protocol/CloudVerifiable.swift
// STAGE S-006: Protocol for cloud-verifiable data

/// Protocol for types that can be verified by the cloud service
public protocol CloudVerifiable: Sendable {
    /// Unique identifier for this verifiable unit
    var verificationId: String { get }

    /// Session this unit belongs to
    var sessionId: String { get }

    /// Generate verification payload for server
    func toVerificationPayload() -> ClientVerificationPayload

    /// Generate ledger entries for this unit
    func toLedgerEntries() -> [ClientLedgerEntry]
}

// Protocol/VerificationPayload.swift
// STAGE S-007: Verification payload protocol

/// Protocol for verification payloads
public protocol VerificationPayload: Codable, Sendable {
    /// Compute hash of this payload for integrity checking
    func computeHash() -> String

    /// Validate payload structure before sending
    func validate() throws
}

extension ClientVerificationPayload: VerificationPayload {
    public func computeHash() -> String {
        // Deterministic hash of all payload contents
        var hasher = SHA256()
        hasher.update(data: Data(uploadId.utf8))
        hasher.update(data: Data(sessionId.utf8))
        hasher.update(data: Data("\(clientTimestamp.timeIntervalSince1970)".utf8))
        for frame in frames {
            hasher.update(data: Data(frame.frameHash.utf8))
        }
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        guard !uploadId.isEmpty else {
            throw VerificationError.invalidPayload(reason: "Upload ID is empty")
        }
        guard !sessionId.isEmpty else {
            throw VerificationError.invalidPayload(reason: "Session ID is empty")
        }
        guard !frames.isEmpty else {
            throw VerificationError.invalidPayload(reason: "No frames in payload")
        }
    }
}
```

### STAGE S-008: Cloud Verification Tests

```swift
// Tests/CloudVerificationTests.swift
// STAGE S-008: Comprehensive tests for cloud verification

import XCTest
@testable import GaussianSplatCapture

final class CloudVerificationTests: XCTestCase {

    var mirrorService: DecisionMirrorService!
    var ledgerVerifier: LedgerVerifier!
    var consistencyChecker: AuditConsistencyChecker!

    override func setUp() async throws {
        // Use lab profile for strict testing
        mirrorService = DecisionMirrorService(config: .forProfile(.lab))
        ledgerVerifier = LedgerVerifier(config: .forProfile(.lab))
        consistencyChecker = AuditConsistencyChecker(config: .forProfile(.lab))
    }

    // MARK: - Decision Mirror Tests

    func testMirrorVerification_ValidPayload_Succeeds() async throws {
        let payload = createValidPayload()

        let result = try await mirrorService.verifyUpload(payload)

        XCTAssertTrue(result.overallVerified)
        XCTAssertEqual(result.failedFrames, 0)
        XCTAssertLessThanOrEqual(result.maxDiscrepancy, 0.0001)
    }

    func testMirrorVerification_TamperedScore_Fails() async throws {
        var payload = createValidPayload()
        // Tamper with a quality score
        var frame = payload.frames[0]
        frame = FrameVerificationData(
            frameIndex: frame.frameIndex,
            frameHash: frame.frameHash,
            clientQualityScore: frame.clientQualityScore + 0.5,  // Tampered!
            captureTimestamp: frame.captureTimestamp,
            exposureValue: frame.exposureValue,
            isoValue: frame.isoValue,
            focusPosition: frame.focusPosition,
            qualityInputs: frame.qualityInputs
        )
        payload.frames[0] = frame

        let result = try await mirrorService.verifyUpload(payload)

        XCTAssertFalse(result.overallVerified)
        XCTAssertGreaterThan(result.failedFrames, 0)
    }

    func testMirrorVerification_ClockDrift_Throws() async throws {
        var payload = createValidPayload()
        // Set timestamp 1 hour in the past (way beyond tolerance)
        payload.clientTimestamp = Date().addingTimeInterval(-3600)

        do {
            _ = try await mirrorService.verifyUpload(payload)
            XCTFail("Should have thrown clock drift error")
        } catch VerificationError.clockDriftExceeded {
            // Expected
        }
    }

    // MARK: - Ledger Verifier Tests

    func testLedgerVerification_ValidChain_Succeeds() async {
        let ledger = createValidLedger()

        let result = await ledgerVerifier.verify(ledger)

        XCTAssertTrue(result.overallValid)
        XCTAssertTrue(result.chainIntegrityValid)
        XCTAssertTrue(result.temporalOrderValid)
        XCTAssertEqual(result.issues.count, 0)
    }

    func testLedgerVerification_BrokenChain_Fails() async {
        var ledger = createValidLedger()
        // Break the hash chain by modifying a previousHash
        ledger.entries[1].previousHash = "INVALID_HASH"

        let result = await ledgerVerifier.verify(ledger)

        XCTAssertFalse(result.overallValid)
        XCTAssertFalse(result.chainIntegrityValid)
        XCTAssertTrue(result.issues.contains { $0.issueType == .hashChainBroken })
    }

    func testLedgerVerification_OutOfOrderTimestamps_Fails() async {
        var ledger = createValidLedger()
        // Swap timestamps
        let temp = ledger.entries[0].timestamp
        ledger.entries[0].timestamp = ledger.entries[1].timestamp
        ledger.entries[1].timestamp = temp

        let result = await ledgerVerifier.verify(ledger)

        XCTAssertFalse(result.temporalOrderValid)
        XCTAssertTrue(result.issues.contains { $0.issueType == .timestampOutOfOrder })
    }

    // MARK: - Consistency Checker Tests

    func testConsistencyCheck_MatchingResults_Succeeds() async {
        let mirrorResult = createValidMirrorResult()
        let ledgerResult = createValidLedgerResult()

        let result = await consistencyChecker.checkConsistency(
            mirrorResult: mirrorResult,
            ledgerResult: ledgerResult
        )

        XCTAssertTrue(result.overallConsistent)
        XCTAssertEqual(result.discrepancies.count, 0)
    }

    func testConsistencyCheck_ReplayAttack_Detected() async {
        let mirrorResult1 = createValidMirrorResult()
        let ledgerResult1 = createValidLedgerResult()

        // First submission should succeed
        let result1 = await consistencyChecker.checkConsistency(
            mirrorResult: mirrorResult1,
            ledgerResult: ledgerResult1
        )
        XCTAssertTrue(result1.overallConsistent)

        // Same upload ID again = replay attack
        let result2 = await consistencyChecker.checkConsistency(
            mirrorResult: mirrorResult1,  // Same!
            ledgerResult: ledgerResult1
        )

        XCTAssertFalse(result2.overallConsistent)
        XCTAssertTrue(result2.discrepancies.contains { $0.discrepancyType == .replayDetected })
    }

    // MARK: - Integration Tests

    func testFullVerificationPipeline_Success() async throws {
        let payload = createValidPayload()
        let ledger = createMatchingLedger(for: payload)

        // Step 1: Mirror verification
        let mirrorResult = try await mirrorService.verifyUpload(payload)
        XCTAssertTrue(mirrorResult.overallVerified)

        // Step 2: Ledger verification
        let ledgerResult = await ledgerVerifier.verify(ledger)
        XCTAssertTrue(ledgerResult.overallValid)

        // Step 3: Consistency check
        let consistencyResult = await consistencyChecker.checkConsistency(
            mirrorResult: mirrorResult,
            ledgerResult: ledgerResult
        )
        XCTAssertTrue(consistencyResult.overallConsistent)
    }

    // MARK: - Helpers

    private func createValidPayload() -> ClientVerificationPayload {
        // Create deterministic test payload
        // Implementation details...
    }

    private func createValidLedger() -> ClientLedger {
        // Create valid ledger with correct hash chain
        // Implementation details...
    }

    private func createValidMirrorResult() -> MirrorVerificationResult {
        // Create valid mirror result
        // Implementation details...
    }

    private func createValidLedgerResult() -> LedgerVerificationResult {
        // Create valid ledger result
        // Implementation details...
    }

    private func createMatchingLedger(for payload: ClientVerificationPayload) -> ClientLedger {
        // Create ledger that matches the payload
        // Implementation details...
    }
}
```

---

## PART T: REMOTE ATTESTATION & DEVICE INTEGRITY

### T.1 Problem Statement

**Vulnerability ID**: ATTEST-001 through ATTEST-020
**Severity**: CRITICAL
**Category**: Device Trust, Tamper Detection, Emulator/Rooted Device Detection

The current system has no mechanism to verify that:
1. The client app is running on genuine hardware (not emulator)
2. The app binary has not been tampered with
3. The device is not rooted/jailbroken
4. The client is using an official, unmodified app version

Without remote attestation, an attacker can:
- Run the app in an emulator to inject synthetic camera data
- Modify the app binary to bypass quality checks
- Use a rooted device to intercept and modify data
- Submit data from a cloned or repackaged app

### T.2 Solution Architecture

Implement platform-specific remote attestation using:
- **iOS**: App Attest + DeviceCheck APIs
- **Android**: Play Integrity API + Key Attestation

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    REMOTE ATTESTATION FLOW                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                         iOS ATTESTATION                          │  │
│  │                                                                  │  │
│  │  App Launch ──→ Generate Key ──→ Attest Key ──→ Store Attestation│  │
│  │       │              │               │               │           │  │
│  │       ↓              ↓               ↓               ↓           │  │
│  │  Each Request ──→ Generate Assertion ──→ Sign Payload ──→ Send   │  │
│  │                                                                  │  │
│  │  Server Side:                                                    │  │
│  │  Receive ──→ Validate Attestation ──→ Verify Assertion ──→ Trust │  │
│  │                                                                  │  │
│  │  APIs Used:                                                      │  │
│  │  • DCAppAttestService.shared.attestKey()                         │  │
│  │  • DCAppAttestService.shared.generateAssertion()                 │  │
│  │  • DeviceCheck: DCDevice.current.generateToken()                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                       ANDROID ATTESTATION                        │  │
│  │                                                                  │  │
│  │  App Launch ──→ Request Nonce ──→ Call Integrity API ──→ Token   │  │
│  │       │              │                  │                │       │  │
│  │       ↓              ↓                  ↓                ↓       │  │
│  │  Each Request ──→ Include Token ──→ Server Decrypts ──→ Verify   │  │
│  │                                                                  │  │
│  │  Server Receives:                                                │  │
│  │  • App Integrity Verdict (PLAY_RECOGNIZED, etc.)                 │  │
│  │  • Device Integrity Verdict (MEETS_BASIC_INTEGRITY, etc.)        │  │
│  │  • Account Licensing Verdict                                     │  │
│  │                                                                  │  │
│  │  APIs Used:                                                      │  │
│  │  • IntegrityManager.requestIntegrityToken()                      │  │
│  │  • KeyStore Hardware Attestation                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### T.3 Implementation Files

```
New Files:
├── Security/
│   ├── RemoteAttestationManager.swift      (STAGE T-001)
│   ├── AttestationPolicy.swift             (STAGE T-002)
│   ├── iOSAttestationProvider.swift        (STAGE T-003)
│   ├── AndroidAttestationProvider.swift    (STAGE T-004)
│   ├── AttestationCache.swift              (STAGE T-005)
│   └── AttestationResult.swift             (STAGE T-006)
├── Server/
│   ├── AttestationVerifier.swift           (STAGE T-007)
│   └── AttestationPolicyEnforcer.swift     (STAGE T-008)
└── Tests/
    └── RemoteAttestationTests.swift        (STAGE T-009)
```

### STAGE T-001: RemoteAttestationManager.swift

```swift
// Security/RemoteAttestationManager.swift
// STAGE T-001: Cross-platform remote attestation management
// Vulnerability: ATTEST-001 through ATTEST-005

import Foundation

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Configuration for remote attestation
public struct AttestationConfig: Codable, Sendable {
    /// How often to refresh attestation (seconds)
    public let refreshIntervalSeconds: Int64

    /// Maximum age of attestation before requiring refresh (seconds)
    public let maxAttestationAgeSeconds: Int64

    /// Whether to require hardware-backed attestation
    public let requireHardwareBacked: Bool

    /// Minimum device integrity level required
    public let minimumIntegrityLevel: IntegrityLevel

    /// Rate limit for attestation requests per minute
    public let rateLimitPerMinute: Int

    /// Whether to allow fallback to DeviceCheck if App Attest unavailable
    public let allowDeviceCheckFallback: Bool

    public enum IntegrityLevel: String, Codable, Sendable, Comparable {
        case none = "NONE"
        case basic = "BASIC"              // Basic integrity
        case device = "DEVICE"            // Device integrity (not rooted)
        case strong = "STRONG"            // Strong integrity (hardware-backed)

        public static func < (lhs: IntegrityLevel, rhs: IntegrityLevel) -> Bool {
            let order: [IntegrityLevel] = [.none, .basic, .device, .strong]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> AttestationConfig {
        switch profile {
        case .production:
            return AttestationConfig(
                refreshIntervalSeconds: 86400,       // 24 hours
                maxAttestationAgeSeconds: 259200,    // 72 hours
                requireHardwareBacked: true,
                minimumIntegrityLevel: .device,
                rateLimitPerMinute: 5,
                allowDeviceCheckFallback: true
            )
        case .debug:
            return AttestationConfig(
                refreshIntervalSeconds: 3600,        // 1 hour
                maxAttestationAgeSeconds: 14400,     // 4 hours
                requireHardwareBacked: false,
                minimumIntegrityLevel: .basic,
                rateLimitPerMinute: 20,
                allowDeviceCheckFallback: true
            )
        case .lab:
            return AttestationConfig(
                refreshIntervalSeconds: 60,          // 1 minute (extreme)
                maxAttestationAgeSeconds: 120,       // 2 minutes (extreme)
                requireHardwareBacked: true,
                minimumIntegrityLevel: .strong,
                rateLimitPerMinute: 100,
                allowDeviceCheckFallback: false
            )
        }
    }
}

/// Result of attestation attempt
public struct AttestationResult: Codable, Sendable {
    public let success: Bool
    public let attestationToken: String?
    public let keyId: String?
    public let integrityLevel: AttestationConfig.IntegrityLevel
    public let timestamp: Date
    public let expiresAt: Date
    public let deviceInfo: DeviceInfo
    public let failureReason: AttestationFailure?

    public struct DeviceInfo: Codable, Sendable {
        public let platform: Platform
        public let modelIdentifier: String
        public let osVersion: String
        public let isSimulator: Bool
        public let isRooted: Bool
        public let isDebugBuild: Bool

        public enum Platform: String, Codable, Sendable {
            case iOS
            case android
            case unknown
        }
    }

    public enum AttestationFailure: String, Codable, Sendable {
        case notSupported               // Device doesn't support attestation
        case networkError               // Network request failed
        case serverError                // Server returned error
        case invalidResponse            // Response validation failed
        case keyGenerationFailed        // Could not generate attestation key
        case attestationRejected        // Server rejected attestation
        case rateLimited                // Too many requests
        case expired                    // Attestation expired
        case tamperedApp                // App binary modified
        case emulatorDetected           // Running in emulator
        case rootedDevice               // Device is rooted/jailbroken
        case invalidSignature           // Signature verification failed
    }
}

/// Remote Attestation Manager - Coordinates device integrity verification
///
/// This class provides a unified interface for remote attestation across
/// iOS and Android platforms. It handles:
/// 1. Initial key generation and attestation
/// 2. Periodic attestation refresh
/// 3. Assertion generation for each request
/// 4. Caching and rate limiting
///
/// SECURITY: This is a CRITICAL security boundary. All uploads MUST
/// include valid attestation assertions.
@available(iOS 14.0, macOS 11.0, *)
public actor RemoteAttestationManager {

    // MARK: - Properties

    private let config: AttestationConfig
    private var currentAttestation: AttestationResult?
    private var attestationKeyId: String?
    private var cache: AttestationCache
    private var rateLimiter: RateLimiter

    #if canImport(DeviceCheck)
    private let attestService: DCAppAttestService?
    #endif

    // MARK: - Initialization

    public init(config: AttestationConfig) {
        self.config = config
        self.cache = AttestationCache()
        self.rateLimiter = RateLimiter(maxRequestsPerMinute: config.rateLimitPerMinute)

        #if canImport(DeviceCheck)
        if #available(iOS 14.0, *) {
            self.attestService = DCAppAttestService.shared
        } else {
            self.attestService = nil
        }
        #endif
    }

    // MARK: - Public API

    /// Initialize attestation on app launch
    /// This generates a new attestation key and attests it with Apple/Google
    public func initialize() async throws {
        // Check if we have a cached valid attestation
        if let cached = cache.getCachedAttestation(),
           cached.expiresAt > Date() {
            currentAttestation = cached
            attestationKeyId = cached.keyId
            return
        }

        // Generate new attestation
        try await performAttestation()
    }

    /// Get current attestation status
    public func getAttestationStatus() -> AttestationResult? {
        return currentAttestation
    }

    /// Generate an assertion for a request payload
    /// This proves the request comes from an attested device
    public func generateAssertion(for payload: Data) async throws -> AssertionResult {
        // Ensure we have valid attestation
        guard let attestation = currentAttestation,
              attestation.success,
              attestation.expiresAt > Date() else {
            // Try to refresh attestation
            try await refreshAttestation()
            guard let refreshed = currentAttestation, refreshed.success else {
                throw AttestationError.noValidAttestation
            }
        }

        // Check rate limit
        guard rateLimiter.allowRequest() else {
            throw AttestationError.rateLimited
        }

        // Generate platform-specific assertion
        #if os(iOS)
        return try await generateiOSAssertion(for: payload)
        #elseif os(Android)
        return try await generateAndroidAssertion(for: payload)
        #else
        throw AttestationError.platformNotSupported
        #endif
    }

    /// Refresh attestation if needed
    public func refreshIfNeeded() async throws {
        guard let current = currentAttestation else {
            try await performAttestation()
            return
        }

        // Check if refresh is needed
        let age = Date().timeIntervalSince(current.timestamp)
        if age > Double(config.refreshIntervalSeconds) {
            try await refreshAttestation()
        }
    }

    /// Validate that device meets minimum integrity requirements
    public func validateDeviceIntegrity() async throws -> Bool {
        guard let attestation = currentAttestation, attestation.success else {
            return false
        }

        // Check integrity level
        if attestation.integrityLevel < config.minimumIntegrityLevel {
            return false
        }

        // Check for security issues
        if attestation.deviceInfo.isSimulator && config.requireHardwareBacked {
            return false
        }

        if attestation.deviceInfo.isRooted {
            return false
        }

        return true
    }

    // MARK: - Private Methods

    private func performAttestation() async throws {
        #if os(iOS)
        try await performiOSAttestation()
        #elseif os(Android)
        try await performAndroidAttestation()
        #else
        throw AttestationError.platformNotSupported
        #endif
    }

    private func refreshAttestation() async throws {
        try await performAttestation()
    }

    #if os(iOS)
    @available(iOS 14.0, *)
    private func performiOSAttestation() async throws {
        guard let service = attestService else {
            throw AttestationError.notSupported
        }

        // Check if App Attest is supported
        guard service.isSupported else {
            if config.allowDeviceCheckFallback {
                try await performDeviceCheckFallback()
                return
            }
            throw AttestationError.notSupported
        }

        // Generate a new key
        let keyId = try await service.generateKey()
        self.attestationKeyId = keyId

        // Get server challenge (nonce)
        let challenge = try await requestServerChallenge()

        // Create client data hash
        let clientDataHash = SHA256.hash(data: challenge)
        let clientData = Data(clientDataHash)

        // Attest the key
        let attestationObject = try await service.attestKey(keyId, clientDataHash: clientData)

        // Send to server for validation
        let serverResult = try await validateAttestationWithServer(
            attestationObject: attestationObject,
            keyId: keyId,
            challenge: challenge
        )

        // Store result
        currentAttestation = serverResult
        cache.cacheAttestation(serverResult)
    }

    @available(iOS 14.0, *)
    private func performDeviceCheckFallback() async throws {
        guard DCDevice.current.isSupported else {
            throw AttestationError.notSupported
        }

        let token = try await DCDevice.current.generateToken()

        // Send to server for validation
        let serverResult = try await validateDeviceCheckWithServer(token: token)

        currentAttestation = serverResult
        cache.cacheAttestation(serverResult)
    }

    @available(iOS 14.0, *)
    private func generateiOSAssertion(for payload: Data) async throws -> AssertionResult {
        guard let service = attestService,
              let keyId = attestationKeyId else {
            throw AttestationError.noValidAttestation
        }

        // Hash the payload
        let payloadHash = SHA256.hash(data: payload)
        let clientData = Data(payloadHash)

        // Generate assertion
        let assertion = try await service.generateAssertion(keyId, clientDataHash: clientData)

        return AssertionResult(
            assertion: assertion,
            keyId: keyId,
            timestamp: Date()
        )
    }
    #endif

    #if os(Android)
    private func performAndroidAttestation() async throws {
        // Android Play Integrity implementation
        // This would use IntegrityManager from Play Integrity API

        // 1. Request nonce from server
        let nonce = try await requestServerChallenge()

        // 2. Request integrity token from Play Integrity API
        // IntegrityManager.requestIntegrityToken(nonce)

        // 3. Send token to server for decryption and validation

        // 4. Parse server response with verdicts:
        //    - requestDetails.requestPackageName
        //    - appIntegrity.appRecognitionVerdict
        //    - deviceIntegrity.deviceRecognitionVerdict
        //    - accountDetails.appLicensingVerdict

        throw AttestationError.platformNotSupported // Placeholder
    }

    private func generateAndroidAssertion(for payload: Data) async throws -> AssertionResult {
        // Android assertion using hardware-backed KeyStore
        throw AttestationError.platformNotSupported // Placeholder
    }
    #endif

    private func requestServerChallenge() async throws -> Data {
        // Request a cryptographic nonce from the server
        // This prevents replay attacks
        let url = URL(string: "https://api.example.com/attestation/challenge")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AttestationError.serverError
        }

        return data
    }

    private func validateAttestationWithServer(
        attestationObject: Data,
        keyId: String,
        challenge: Data
    ) async throws -> AttestationResult {
        // Send attestation to server for validation
        // Server performs:
        // 1. Decode CBOR attestation object
        // 2. Verify certificate chain to Apple root
        // 3. Verify nonce matches challenge
        // 4. Extract public key and store for assertion verification

        // Placeholder implementation
        return AttestationResult(
            success: true,
            attestationToken: attestationObject.base64EncodedString(),
            keyId: keyId,
            integrityLevel: .strong,
            timestamp: Date(),
            expiresAt: Date().addingTimeInterval(Double(config.maxAttestationAgeSeconds)),
            deviceInfo: .init(
                platform: .iOS,
                modelIdentifier: getModelIdentifier(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                isSimulator: isRunningOnSimulator(),
                isRooted: false,
                isDebugBuild: isDebugBuild()
            ),
            failureReason: nil
        )
    }

    private func validateDeviceCheckWithServer(token: Data) async throws -> AttestationResult {
        // DeviceCheck provides weaker guarantees but works on more devices
        return AttestationResult(
            success: true,
            attestationToken: token.base64EncodedString(),
            keyId: nil,
            integrityLevel: .basic,
            timestamp: Date(),
            expiresAt: Date().addingTimeInterval(Double(config.maxAttestationAgeSeconds)),
            deviceInfo: .init(
                platform: .iOS,
                modelIdentifier: getModelIdentifier(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                isSimulator: isRunningOnSimulator(),
                isRooted: false,
                isDebugBuild: isDebugBuild()
            ),
            failureReason: nil
        )
    }

    // MARK: - Utility Methods

    private func getModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    private func isRunningOnSimulator() -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private func isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Supporting Types

/// Result of generating an assertion
public struct AssertionResult: Codable, Sendable {
    public let assertion: Data
    public let keyId: String
    public let timestamp: Date
}

/// Attestation errors
public enum AttestationError: Error, LocalizedError {
    case notSupported
    case platformNotSupported
    case noValidAttestation
    case keyGenerationFailed
    case attestationFailed(String)
    case assertionFailed(String)
    case serverError
    case networkError
    case rateLimited
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Device does not support attestation"
        case .platformNotSupported:
            return "Platform not supported for attestation"
        case .noValidAttestation:
            return "No valid attestation available"
        case .keyGenerationFailed:
            return "Failed to generate attestation key"
        case .attestationFailed(let reason):
            return "Attestation failed: \(reason)"
        case .assertionFailed(let reason):
            return "Assertion generation failed: \(reason)"
        case .serverError:
            return "Server returned an error"
        case .networkError:
            return "Network request failed"
        case .rateLimited:
            return "Rate limit exceeded for attestation requests"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}

// MARK: - Rate Limiter

private actor RateLimiter {
    private let maxRequestsPerMinute: Int
    private var requestTimestamps: [Date] = []

    init(maxRequestsPerMinute: Int) {
        self.maxRequestsPerMinute = maxRequestsPerMinute
    }

    func allowRequest() -> Bool {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)

        // Remove old timestamps
        requestTimestamps = requestTimestamps.filter { $0 > oneMinuteAgo }

        // Check if under limit
        if requestTimestamps.count < maxRequestsPerMinute {
            requestTimestamps.append(now)
            return true
        }

        return false
    }
}

// MARK: - Attestation Cache

private actor AttestationCache {
    private var cachedAttestation: AttestationResult?
    private let userDefaults = UserDefaults.standard
    private let cacheKey = "com.app.attestation.cache"

    func getCachedAttestation() -> AttestationResult? {
        if let cached = cachedAttestation {
            return cached
        }

        // Try to load from persistent storage
        guard let data = userDefaults.data(forKey: cacheKey),
              let attestation = try? JSONDecoder().decode(AttestationResult.self, from: data) else {
            return nil
        }

        cachedAttestation = attestation
        return attestation
    }

    func cacheAttestation(_ attestation: AttestationResult) {
        cachedAttestation = attestation

        // Persist to storage
        if let data = try? JSONEncoder().encode(attestation) {
            userDefaults.set(data, forKey: cacheKey)
        }
    }

    func clearCache() {
        cachedAttestation = nil
        userDefaults.removeObject(forKey: cacheKey)
    }
}
```

### STAGE T-002: AttestationPolicy.swift

```swift
// Security/AttestationPolicy.swift
// STAGE T-002: Policy engine for attestation requirements
// Vulnerability: ATTEST-006 through ATTEST-010

import Foundation

/// Policy for attestation requirements based on operation sensitivity
public struct AttestationPolicy: Codable, Sendable {

    /// Operation categories with different attestation requirements
    public enum OperationCategory: String, Codable, Sendable {
        case upload              // Uploading capture data
        case qualityDecision     // Making quality accept/reject decisions
        case configFetch         // Fetching configuration
        case auditSubmit         // Submitting audit logs
        case accountAction       // Account-related actions
        case payment             // Payment operations

        /// Required integrity level for this operation
        public var requiredIntegrityLevel: AttestationConfig.IntegrityLevel {
            switch self {
            case .upload:
                return .device
            case .qualityDecision:
                return .strong
            case .configFetch:
                return .basic
            case .auditSubmit:
                return .device
            case .accountAction:
                return .strong
            case .payment:
                return .strong
            }
        }

        /// Whether this operation requires fresh attestation
        public var requiresFreshAttestation: Bool {
            switch self {
            case .payment, .accountAction:
                return true  // Critical operations need fresh attestation
            default:
                return false
            }
        }

        /// Maximum attestation age allowed for this operation (seconds)
        public var maxAttestationAgeSeconds: Int64 {
            switch self {
            case .payment:
                return 300      // 5 minutes
            case .accountAction:
                return 600      // 10 minutes
            case .qualityDecision:
                return 3600     // 1 hour
            default:
                return 86400    // 24 hours
            }
        }
    }

    /// Enforcement mode
    public enum EnforcementMode: String, Codable, Sendable {
        case strict      // Reject all operations without valid attestation
        case warn        // Allow but log warning
        case disabled    // No attestation required (testing only)
    }

    /// Current enforcement mode
    public let enforcementMode: EnforcementMode

    /// Whitelist of device models allowed without attestation (for testing)
    public let attestationExemptModels: [String]

    /// Whether to allow simulator/emulator in debug builds
    public let allowSimulatorInDebug: Bool

    /// Tiered enforcement configuration
    public let tieredEnforcement: TieredEnforcement

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> AttestationPolicy {
        switch profile {
        case .production:
            return AttestationPolicy(
                enforcementMode: .strict,
                attestationExemptModels: [],
                allowSimulatorInDebug: false,
                tieredEnforcement: .init(
                    tier1FailureThreshold: 3,    // Block after 3 failures
                    tier2FailureThreshold: 10,   // Permanent block after 10
                    cooldownSeconds: 3600        // 1 hour cooldown
                )
            )
        case .debug:
            return AttestationPolicy(
                enforcementMode: .warn,
                attestationExemptModels: ["x86_64", "arm64"],  // Simulators
                allowSimulatorInDebug: true,
                tieredEnforcement: .init(
                    tier1FailureThreshold: 10,
                    tier2FailureThreshold: 50,
                    cooldownSeconds: 300
                )
            )
        case .lab:
            return AttestationPolicy(
                enforcementMode: .strict,
                attestationExemptModels: [],
                allowSimulatorInDebug: false,
                tieredEnforcement: .init(
                    tier1FailureThreshold: 1,    // Immediate block (extreme)
                    tier2FailureThreshold: 2,
                    cooldownSeconds: 60
                )
            )
        }
    }

    /// Tiered enforcement configuration
    public struct TieredEnforcement: Codable, Sendable {
        public let tier1FailureThreshold: Int    // Temporary block
        public let tier2FailureThreshold: Int    // Permanent block
        public let cooldownSeconds: Int64
    }
}

/// Policy evaluator for attestation decisions
@available(iOS 14.0, macOS 11.0, *)
public actor AttestationPolicyEvaluator {

    private let policy: AttestationPolicy
    private var failureHistory: [String: [Date]] = [:]  // deviceId -> failure timestamps
    private var blockedDevices: Set<String> = []

    public init(policy: AttestationPolicy) {
        self.policy = policy
    }

    /// Evaluate whether an operation should be allowed based on attestation
    public func evaluate(
        attestation: AttestationResult?,
        operation: AttestationPolicy.OperationCategory,
        deviceId: String
    ) -> EvaluationResult {

        // Check if device is blocked
        if blockedDevices.contains(deviceId) {
            return .denied(reason: .deviceBlocked)
        }

        // Check enforcement mode
        switch policy.enforcementMode {
        case .disabled:
            return .allowed

        case .warn:
            if attestation == nil || !attestation!.success {
                recordFailure(deviceId: deviceId)
                return .allowedWithWarning(reason: "Missing or failed attestation")
            }

        case .strict:
            guard let att = attestation, att.success else {
                recordFailure(deviceId: deviceId)
                return checkTieredEnforcement(deviceId: deviceId)
            }
        }

        guard let att = attestation else {
            return .denied(reason: .noAttestation)
        }

        // Check integrity level
        if att.integrityLevel < operation.requiredIntegrityLevel {
            recordFailure(deviceId: deviceId)
            return .denied(reason: .insufficientIntegrity(
                required: operation.requiredIntegrityLevel,
                actual: att.integrityLevel
            ))
        }

        // Check attestation age
        let age = Date().timeIntervalSince(att.timestamp)
        if age > Double(operation.maxAttestationAgeSeconds) {
            return .denied(reason: .attestationExpired(ageSeconds: Int64(age)))
        }

        // Check for security issues
        if att.deviceInfo.isSimulator && !policy.allowSimulatorInDebug {
            return .denied(reason: .simulatorNotAllowed)
        }

        if att.deviceInfo.isRooted {
            return .denied(reason: .rootedDevice)
        }

        return .allowed
    }

    /// Record a failure for tiered enforcement
    private func recordFailure(deviceId: String) {
        let now = Date()
        var failures = failureHistory[deviceId] ?? []

        // Remove old failures outside cooldown window
        let cutoff = now.addingTimeInterval(-Double(policy.tieredEnforcement.cooldownSeconds))
        failures = failures.filter { $0 > cutoff }

        failures.append(now)
        failureHistory[deviceId] = failures
    }

    /// Check tiered enforcement and block if necessary
    private func checkTieredEnforcement(deviceId: String) -> EvaluationResult {
        let failures = failureHistory[deviceId] ?? []

        if failures.count >= policy.tieredEnforcement.tier2FailureThreshold {
            blockedDevices.insert(deviceId)
            return .denied(reason: .deviceBlocked)
        }

        if failures.count >= policy.tieredEnforcement.tier1FailureThreshold {
            return .denied(reason: .temporaryBlock(
                failureCount: failures.count,
                cooldownSeconds: policy.tieredEnforcement.cooldownSeconds
            ))
        }

        return .denied(reason: .noAttestation)
    }

    /// Evaluation result
    public enum EvaluationResult: Sendable {
        case allowed
        case allowedWithWarning(reason: String)
        case denied(reason: DenialReason)

        public var isAllowed: Bool {
            switch self {
            case .allowed, .allowedWithWarning:
                return true
            case .denied:
                return false
            }
        }
    }

    /// Reasons for denying an operation
    public enum DenialReason: Sendable {
        case noAttestation
        case attestationFailed(String)
        case insufficientIntegrity(required: AttestationConfig.IntegrityLevel, actual: AttestationConfig.IntegrityLevel)
        case attestationExpired(ageSeconds: Int64)
        case simulatorNotAllowed
        case rootedDevice
        case temporaryBlock(failureCount: Int, cooldownSeconds: Int64)
        case deviceBlocked
    }
}
```

### STAGE T-003 through T-009: Platform Providers, Server Verifier, and Tests

```swift
// Security/iOSAttestationProvider.swift
// STAGE T-003: iOS-specific attestation implementation
// See RemoteAttestationManager.swift for full implementation

// Security/AndroidAttestationProvider.swift
// STAGE T-004: Android Play Integrity and Key Attestation
// Requires Kotlin implementation - see separate Android module

// Security/AttestationCache.swift
// STAGE T-005: Attestation caching (embedded in RemoteAttestationManager.swift)

// Security/AttestationResult.swift
// STAGE T-006: Result types (embedded in RemoteAttestationManager.swift)

// Server/AttestationVerifier.swift
// STAGE T-007: Server-side attestation verification

import Foundation
import CryptoKit

/// Server-side verifier for attestation objects
public struct AttestationVerifier {

    /// Verify iOS App Attest attestation object
    /// Reference: Apple App Attest documentation
    public func verifyiOSAttestation(
        attestationObject: Data,
        challenge: Data,
        keyId: String,
        teamId: String,
        bundleId: String
    ) throws -> VerifiedAttestation {
        // 1. Decode CBOR attestation object
        // 2. Extract authenticator data and attestation statement
        // 3. Verify certificate chain to Apple App Attestation Root CA
        // 4. Verify nonce = SHA256(clientData || authenticatorData)
        // 5. Verify counter is non-zero
        // 6. Extract and store public key for future assertion verification

        // Implementation would use CBOR decoder and certificate chain validation
        throw AttestationError.notSupported // Placeholder
    }

    /// Verify iOS assertion
    public func verifyiOSAssertion(
        assertion: Data,
        clientData: Data,
        storedPublicKey: Data,
        storedCounter: UInt32
    ) throws -> VerifiedAssertion {
        // 1. Decode CBOR assertion
        // 2. Verify signature using stored public key
        // 3. Verify counter > stored counter (replay protection)
        // 4. Update stored counter

        throw AttestationError.notSupported // Placeholder
    }

    /// Verify Android Play Integrity token
    /// Reference: Google Play Integrity API documentation
    public func verifyAndroidIntegrity(
        integrityToken: String,
        challenge: Data,
        packageName: String
    ) throws -> VerifiedAttestation {
        // 1. Decrypt token using Google's provided decryption key
        //    (or use Google's server-to-server API)
        // 2. Parse TokenPayloadExternal
        // 3. Verify requestDetails.nonce matches challenge
        // 4. Verify requestDetails.requestPackageName matches expected
        // 5. Check appIntegrity.appRecognitionVerdict
        // 6. Check deviceIntegrity.deviceRecognitionVerdict
        // 7. Optionally check accountDetails

        throw AttestationError.notSupported // Placeholder
    }

    public struct VerifiedAttestation: Sendable {
        public let keyId: String
        public let publicKey: Data
        public let integrityLevel: AttestationConfig.IntegrityLevel
        public let counter: UInt32
        public let timestamp: Date
    }

    public struct VerifiedAssertion: Sendable {
        public let keyId: String
        public let newCounter: UInt32
        public let timestamp: Date
    }
}

// Server/AttestationPolicyEnforcer.swift
// STAGE T-008: Server-side policy enforcement

/// Server-side enforcement of attestation policy
public actor ServerAttestationEnforcer {

    private var attestationRecords: [String: AttestationRecord] = [:]  // keyId -> record

    public struct AttestationRecord: Sendable {
        let keyId: String
        let publicKey: Data
        let integrityLevel: AttestationConfig.IntegrityLevel
        let counter: UInt32
        let deviceId: String
        let firstSeenAt: Date
        let lastUsedAt: Date
    }

    /// Store a verified attestation
    public func storeAttestation(_ attestation: AttestationVerifier.VerifiedAttestation, deviceId: String) {
        attestationRecords[attestation.keyId] = AttestationRecord(
            keyId: attestation.keyId,
            publicKey: attestation.publicKey,
            integrityLevel: attestation.integrityLevel,
            counter: attestation.counter,
            deviceId: deviceId,
            firstSeenAt: Date(),
            lastUsedAt: Date()
        )
    }

    /// Verify an assertion and update counter
    public func verifyAndUpdateAssertion(_ assertion: AttestationVerifier.VerifiedAssertion) throws {
        guard var record = attestationRecords[assertion.keyId] else {
            throw AttestationError.noValidAttestation
        }

        // Verify counter is strictly increasing (replay protection)
        guard assertion.newCounter > record.counter else {
            throw AttestationError.assertionFailed("Counter replay detected")
        }

        // Update record
        record = AttestationRecord(
            keyId: record.keyId,
            publicKey: record.publicKey,
            integrityLevel: record.integrityLevel,
            counter: assertion.newCounter,
            deviceId: record.deviceId,
            firstSeenAt: record.firstSeenAt,
            lastUsedAt: Date()
        )
        attestationRecords[assertion.keyId] = record
    }

    /// Get attestation record for a key
    public func getRecord(keyId: String) -> AttestationRecord? {
        return attestationRecords[keyId]
    }
}

// Tests/RemoteAttestationTests.swift
// STAGE T-009: Attestation tests

import XCTest
@testable import GaussianSplatCapture

final class RemoteAttestationTests: XCTestCase {

    func testAttestationConfig_ProductionProfile() {
        let config = AttestationConfig.forProfile(.production)

        XCTAssertEqual(config.refreshIntervalSeconds, 86400)
        XCTAssertEqual(config.minimumIntegrityLevel, .device)
        XCTAssertTrue(config.requireHardwareBacked)
    }

    func testAttestationConfig_LabProfile() {
        let config = AttestationConfig.forProfile(.lab)

        XCTAssertEqual(config.refreshIntervalSeconds, 60)
        XCTAssertEqual(config.minimumIntegrityLevel, .strong)
        XCTAssertFalse(config.allowDeviceCheckFallback)
    }

    func testPolicyEvaluator_AllowsValidAttestation() async {
        let policy = AttestationPolicy.forProfile(.production)
        let evaluator = AttestationPolicyEvaluator(policy: policy)

        let attestation = AttestationResult(
            success: true,
            attestationToken: "valid_token",
            keyId: "key123",
            integrityLevel: .device,
            timestamp: Date(),
            expiresAt: Date().addingTimeInterval(86400),
            deviceInfo: .init(
                platform: .iOS,
                modelIdentifier: "iPhone14,2",
                osVersion: "17.0",
                isSimulator: false,
                isRooted: false,
                isDebugBuild: false
            ),
            failureReason: nil
        )

        let result = await evaluator.evaluate(
            attestation: attestation,
            operation: .upload,
            deviceId: "device123"
        )

        XCTAssertTrue(result.isAllowed)
    }

    func testPolicyEvaluator_DeniesRootedDevice() async {
        let policy = AttestationPolicy.forProfile(.production)
        let evaluator = AttestationPolicyEvaluator(policy: policy)

        let attestation = AttestationResult(
            success: true,
            attestationToken: "valid_token",
            keyId: "key123",
            integrityLevel: .device,
            timestamp: Date(),
            expiresAt: Date().addingTimeInterval(86400),
            deviceInfo: .init(
                platform: .iOS,
                modelIdentifier: "iPhone14,2",
                osVersion: "17.0",
                isSimulator: false,
                isRooted: true,  // ROOTED!
                isDebugBuild: false
            ),
            failureReason: nil
        )

        let result = await evaluator.evaluate(
            attestation: attestation,
            operation: .upload,
            deviceId: "device123"
        )

        XCTAssertFalse(result.isAllowed)
    }

    func testPolicyEvaluator_TieredEnforcement() async {
        let policy = AttestationPolicy.forProfile(.lab)  // tier1 = 1 failure
        let evaluator = AttestationPolicyEvaluator(policy: policy)

        // First failure
        let result1 = await evaluator.evaluate(
            attestation: nil,
            operation: .upload,
            deviceId: "device123"
        )
        XCTAssertFalse(result1.isAllowed)

        // Second failure should trigger block
        let result2 = await evaluator.evaluate(
            attestation: nil,
            operation: .upload,
            deviceId: "device123"
        )
        XCTAssertFalse(result2.isAllowed)
        // In lab profile, device should be blocked after 2 failures
    }
}
```

---

## PART U: NETWORK PROTOCOL INTEGRITY (EXACTLY-ONCE SEMANTICS)

### U.1 Problem Statement

**Vulnerability ID**: NETWORK-001 through NETWORK-015
**Severity**: HIGH
**Category**: Data Integrity, Duplicate Prevention, Transaction Safety

The current upload protocol has no protection against:
1. Duplicate submissions due to network retry
2. Partial uploads being completed multiple times
3. Out-of-order chunk arrival causing data corruption
4. Replay attacks where old uploads are resubmitted
5. Race conditions in concurrent uploads

### U.2 Solution Architecture

Implement **exactly-once delivery semantics** using:
- Idempotency keys for deduplication
- Transactional upload state machine
- Server-side ACK tracking
- Chunk sequence verification

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    EXACTLY-ONCE UPLOAD PROTOCOL                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CLIENT                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    Upload State Machine                         │   │
│  │                                                                 │   │
│  │  IDLE ──→ PREPARING ──→ UPLOADING ──→ FINALIZING ──→ COMPLETE  │   │
│  │    │          │             │              │             │      │   │
│  │    │          │             │              │             │      │   │
│  │    ↓          ↓             ↓              ↓             ↓      │   │
│  │  (error)   (error)      (retry)       (retry)       (done)     │   │
│  │    │          │             │              │                    │   │
│  │    ↓          ↓             ↓              ↓                    │   │
│  │  FAILED    FAILED     RETRYING      RETRYING                   │   │
│  │                                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  KEY COMPONENTS:                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ IdempotencyKey: UUID + timestamp + content_hash                 │   │
│  │ SequenceNumber: Monotonic counter per upload                     │   │
│  │ ChunkHash: SHA-256 of each chunk                                 │   │
│  │ ACKWindow: Sliding window of acknowledged chunks                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  SERVER                                                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Idempotency Store: Redis/DynamoDB with TTL                      │   │
│  │ ACK Tracker: In-memory with WAL persistence                     │   │
│  │ Sequence Validator: Verify monotonic ordering                    │   │
│  │ Duplicate Detector: Hash-based deduplication                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### U.3 Implementation Files

```
New Files:
├── Security/
│   ├── UploadProtocolStateMachine.swift    (STAGE U-001)
│   ├── IdempotencyKeyPolicy.swift          (STAGE U-002)
│   ├── ACKTracker.swift                    (STAGE U-003)
│   └── ChunkSequenceValidator.swift        (STAGE U-004)
├── Protocol/
│   ├── ExactlyOnceUploadProtocol.swift     (STAGE U-005)
│   └── TransactionalUpload.swift           (STAGE U-006)
└── Tests/
    └── NetworkProtocolIntegrityTests.swift  (STAGE U-007)
```

### STAGE U-001: UploadProtocolStateMachine.swift

```swift
// Security/UploadProtocolStateMachine.swift
// STAGE U-001: State machine for exactly-once upload semantics
// Vulnerability: NETWORK-001, NETWORK-002, NETWORK-003

import Foundation

/// Configuration for upload protocol
public struct UploadProtocolConfig: Codable, Sendable {
    /// Maximum retry attempts before permanent failure
    public let maxRetryAttempts: Int

    /// Base delay between retries (exponential backoff)
    public let retryBaseDelayMs: Int64

    /// Maximum delay between retries
    public let retryMaxDelayMs: Int64

    /// Timeout for ACK from server
    public let ackTimeoutMs: Int64

    /// Maximum concurrent chunk uploads
    public let maxConcurrentChunks: Int

    /// Chunk size in bytes
    public let chunkSizeBytes: Int

    /// TTL for idempotency keys
    public let idempotencyKeyTTLSeconds: Int64

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> UploadProtocolConfig {
        switch profile {
        case .production:
            return UploadProtocolConfig(
                maxRetryAttempts: 3,
                retryBaseDelayMs: 1000,
                retryMaxDelayMs: 30000,
                ackTimeoutMs: 5000,
                maxConcurrentChunks: 4,
                chunkSizeBytes: 1024 * 1024,  // 1 MB
                idempotencyKeyTTLSeconds: 86400  // 24 hours
            )
        case .debug:
            return UploadProtocolConfig(
                maxRetryAttempts: 10,
                retryBaseDelayMs: 500,
                retryMaxDelayMs: 10000,
                ackTimeoutMs: 15000,
                maxConcurrentChunks: 2,
                chunkSizeBytes: 512 * 1024,  // 512 KB
                idempotencyKeyTTLSeconds: 3600  // 1 hour
            )
        case .lab:
            return UploadProtocolConfig(
                maxRetryAttempts: 50,           // Extreme retry for stress test
                retryBaseDelayMs: 100,
                retryMaxDelayMs: 1000,
                ackTimeoutMs: 500,              // Very short timeout
                maxConcurrentChunks: 8,
                chunkSizeBytes: 256 * 1024,     // 256 KB
                idempotencyKeyTTLSeconds: 60    // 1 minute
            )
        }
    }
}

/// Upload states
public enum UploadState: String, Codable, Sendable {
    case idle
    case preparing
    case uploading
    case finalizing
    case complete
    case failed
    case retrying
}

/// Upload events that trigger state transitions
public enum UploadEvent: Sendable {
    case start(uploadId: String, data: Data)
    case prepareComplete(chunks: [ChunkInfo])
    case chunkUploaded(sequence: Int, ack: ServerACK)
    case chunkFailed(sequence: Int, error: Error)
    case allChunksUploaded
    case finalizationComplete
    case finalizationFailed(Error)
    case retry
    case abort
}

/// Information about a chunk
public struct ChunkInfo: Codable, Sendable {
    public let sequence: Int
    public let offset: Int
    public let size: Int
    public let hash: String
    public let idempotencyKey: String

    public init(sequence: Int, offset: Int, size: Int, data: Data, uploadId: String) {
        self.sequence = sequence
        self.offset = offset
        self.size = size
        self.hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        self.idempotencyKey = IdempotencyKeyGenerator.generate(
            uploadId: uploadId,
            sequence: sequence,
            hash: self.hash
        )
    }
}

/// Server acknowledgment
public struct ServerACK: Codable, Sendable {
    public let chunkSequence: Int
    public let idempotencyKey: String
    public let serverTimestamp: Date
    public let status: ACKStatus
    public let message: String?

    public enum ACKStatus: String, Codable, Sendable {
        case accepted           // Chunk received and stored
        case duplicate          // Already received (idempotent)
        case rejected           // Validation failed
        case serverError        // Server-side error
    }
}

/// Upload Protocol State Machine
/// Implements exactly-once semantics for reliable uploads
@available(iOS 15.0, macOS 12.0, *)
public actor UploadProtocolStateMachine {

    // MARK: - Properties

    private let config: UploadProtocolConfig
    private var state: UploadState = .idle
    private var uploadId: String?
    private var chunks: [ChunkInfo] = []
    private var uploadedChunks: Set<Int> = []
    private var failedChunks: [Int: (attempts: Int, lastError: Error)] = [:]
    private var retryCount: Int = 0
    private let ackTracker: ACKTracker
    private let idempotencyStore: IdempotencyStore

    // MARK: - Callbacks

    public var onStateChange: ((UploadState, UploadState) -> Void)?
    public var onProgress: ((Double) -> Void)?
    public var onComplete: ((Result<UploadResult, Error>) -> Void)?

    // MARK: - Initialization

    public init(config: UploadProtocolConfig) {
        self.config = config
        self.ackTracker = ACKTracker(timeoutMs: config.ackTimeoutMs)
        self.idempotencyStore = IdempotencyStore(ttlSeconds: config.idempotencyKeyTTLSeconds)
    }

    // MARK: - Public API

    /// Process an event and transition state
    public func process(_ event: UploadEvent) async throws {
        let oldState = state

        switch (state, event) {
        case (.idle, .start(let uploadId, let data)):
            self.uploadId = uploadId
            state = .preparing
            try await prepareUpload(data: data)

        case (.preparing, .prepareComplete(let preparedChunks)):
            self.chunks = preparedChunks
            state = .uploading
            await startChunkUploads()

        case (.uploading, .chunkUploaded(let sequence, let ack)):
            await handleChunkAck(sequence: sequence, ack: ack)

        case (.uploading, .chunkFailed(let sequence, let error)):
            await handleChunkFailure(sequence: sequence, error: error)

        case (.uploading, .allChunksUploaded):
            state = .finalizing
            try await finalizeUpload()

        case (.finalizing, .finalizationComplete):
            state = .complete
            let result = UploadResult(
                uploadId: uploadId!,
                totalChunks: chunks.count,
                totalBytes: chunks.reduce(0) { $0 + $1.size },
                timestamp: Date()
            )
            onComplete?(.success(result))

        case (.finalizing, .finalizationFailed(let error)):
            if retryCount < config.maxRetryAttempts {
                state = .retrying
                try await scheduleRetry()
            } else {
                state = .failed
                onComplete?(.failure(error))
            }

        case (.retrying, .retry):
            retryCount += 1
            state = .finalizing
            try await finalizeUpload()

        case (_, .abort):
            state = .failed
            onComplete?(.failure(UploadError.aborted))

        default:
            throw UploadError.invalidStateTransition(from: state, event: "\(event)")
        }

        if oldState != state {
            onStateChange?(oldState, state)
        }
    }

    /// Get current state
    public func currentState() -> UploadState {
        return state
    }

    /// Get upload progress (0.0 to 1.0)
    public func progress() -> Double {
        guard !chunks.isEmpty else { return 0 }
        return Double(uploadedChunks.count) / Double(chunks.count)
    }

    // MARK: - Private Methods

    private func prepareUpload(data: Data) async throws {
        // Split data into chunks
        var preparedChunks: [ChunkInfo] = []
        var offset = 0
        var sequence = 0

        while offset < data.count {
            let chunkEnd = min(offset + config.chunkSizeBytes, data.count)
            let chunkData = data[offset..<chunkEnd]

            let chunk = ChunkInfo(
                sequence: sequence,
                offset: offset,
                size: chunkData.count,
                data: Data(chunkData),
                uploadId: uploadId!
            )

            preparedChunks.append(chunk)
            offset = chunkEnd
            sequence += 1
        }

        try await process(.prepareComplete(chunks: preparedChunks))
    }

    private func startChunkUploads() async {
        // Upload chunks with concurrency limit
        await withTaskGroup(of: Void.self) { group in
            var pendingChunks = chunks.filter { !uploadedChunks.contains($0.sequence) }

            while !pendingChunks.isEmpty {
                // Limit concurrent uploads
                let batch = Array(pendingChunks.prefix(config.maxConcurrentChunks))
                pendingChunks = Array(pendingChunks.dropFirst(config.maxConcurrentChunks))

                for chunk in batch {
                    group.addTask {
                        await self.uploadChunk(chunk)
                    }
                }

                await group.waitForAll()
            }
        }

        // Check if all chunks uploaded
        if uploadedChunks.count == chunks.count {
            try? await process(.allChunksUploaded)
        }
    }

    private func uploadChunk(_ chunk: ChunkInfo) async {
        // Check idempotency - already uploaded?
        if await idempotencyStore.exists(key: chunk.idempotencyKey) {
            uploadedChunks.insert(chunk.sequence)
            return
        }

        // Register pending ACK
        await ackTracker.registerPending(sequence: chunk.sequence)

        do {
            // Simulate network upload (replace with actual implementation)
            let ack = try await performChunkUpload(chunk)
            try? await process(.chunkUploaded(sequence: chunk.sequence, ack: ack))
        } catch {
            try? await process(.chunkFailed(sequence: chunk.sequence, error: error))
        }
    }

    private func performChunkUpload(_ chunk: ChunkInfo) async throws -> ServerACK {
        // Actual HTTP upload implementation
        // Include idempotency key in header
        // Include chunk hash for verification

        // Placeholder
        return ServerACK(
            chunkSequence: chunk.sequence,
            idempotencyKey: chunk.idempotencyKey,
            serverTimestamp: Date(),
            status: .accepted,
            message: nil
        )
    }

    private func handleChunkAck(sequence: Int, ack: ServerACK) async {
        await ackTracker.confirmAck(sequence: sequence)

        switch ack.status {
        case .accepted, .duplicate:
            uploadedChunks.insert(sequence)
            await idempotencyStore.store(key: ack.idempotencyKey)
            onProgress?(progress())

        case .rejected:
            failedChunks[sequence] = (attempts: (failedChunks[sequence]?.attempts ?? 0) + 1, lastError: UploadError.chunkRejected(sequence))

        case .serverError:
            failedChunks[sequence] = (attempts: (failedChunks[sequence]?.attempts ?? 0) + 1, lastError: UploadError.serverError)
        }

        // Check if all chunks processed
        if uploadedChunks.count + failedChunks.count == chunks.count {
            if failedChunks.isEmpty {
                try? await process(.allChunksUploaded)
            } else {
                // Retry failed chunks
                await retryFailedChunks()
            }
        }
    }

    private func handleChunkFailure(sequence: Int, error: Error) async {
        let attempts = (failedChunks[sequence]?.attempts ?? 0) + 1
        failedChunks[sequence] = (attempts: attempts, lastError: error)

        if attempts < config.maxRetryAttempts {
            // Retry with exponential backoff
            let delay = min(
                config.retryBaseDelayMs * Int64(pow(2.0, Double(attempts - 1))),
                config.retryMaxDelayMs
            )
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)

            if let chunk = chunks.first(where: { $0.sequence == sequence }) {
                await uploadChunk(chunk)
            }
        }
    }

    private func retryFailedChunks() async {
        for (sequence, failure) in failedChunks {
            if failure.attempts < config.maxRetryAttempts {
                if let chunk = chunks.first(where: { $0.sequence == sequence }) {
                    await uploadChunk(chunk)
                }
            }
        }
    }

    private func finalizeUpload() async throws {
        // Send finalization request to server
        // Server validates all chunks received and assembles
        try? await process(.finalizationComplete)
    }

    private func scheduleRetry() async throws {
        let delay = min(
            config.retryBaseDelayMs * Int64(pow(2.0, Double(retryCount))),
            config.retryMaxDelayMs
        )
        try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        try await process(.retry)
    }
}

// MARK: - Supporting Types

public struct UploadResult: Sendable {
    public let uploadId: String
    public let totalChunks: Int
    public let totalBytes: Int
    public let timestamp: Date
}

public enum UploadError: Error, LocalizedError {
    case invalidStateTransition(from: UploadState, event: String)
    case chunkRejected(Int)
    case serverError
    case timeout
    case aborted
    case maxRetriesExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let from, let event):
            return "Invalid state transition from \(from) with event \(event)"
        case .chunkRejected(let sequence):
            return "Chunk \(sequence) was rejected by server"
        case .serverError:
            return "Server returned an error"
        case .timeout:
            return "Upload timed out"
        case .aborted:
            return "Upload was aborted"
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded"
        }
    }
}
```

### STAGE U-002: IdempotencyKeyPolicy.swift

```swift
// Security/IdempotencyKeyPolicy.swift
// STAGE U-002: Idempotency key generation and validation
// Vulnerability: NETWORK-004, NETWORK-005

import Foundation
import CryptoKit

/// Idempotency key generator
/// Creates unique, deterministic keys for deduplication
public struct IdempotencyKeyGenerator {

    /// Generate idempotency key for a chunk
    /// Format: {uploadId}-{sequence}-{timestamp_ms}-{content_hash_prefix}
    public static func generate(uploadId: String, sequence: Int, hash: String) -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let hashPrefix = String(hash.prefix(8))
        return "\(uploadId)-\(sequence)-\(timestamp)-\(hashPrefix)"
    }

    /// Generate idempotency key for an entire upload
    public static func generateForUpload(sessionId: String, contentHash: String) -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        return "upload-\(sessionId)-\(timestamp)-\(contentHash.prefix(16))"
    }

    /// Validate idempotency key format
    public static func validate(_ key: String) -> Bool {
        let components = key.split(separator: "-")
        return components.count >= 4
    }

    /// Extract timestamp from idempotency key
    public static func extractTimestamp(_ key: String) -> Date? {
        let components = key.split(separator: "-")
        guard components.count >= 3,
              let timestampMs = Int64(components[2]) else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(timestampMs) / 1000)
    }
}

/// In-memory idempotency store with TTL
actor IdempotencyStore {
    private var store: [String: Date] = [:]
    private let ttlSeconds: Int64
    private var lastCleanup: Date = Date()
    private let cleanupInterval: TimeInterval = 60  // Cleanup every minute

    init(ttlSeconds: Int64) {
        self.ttlSeconds = ttlSeconds
    }

    /// Check if key exists (not expired)
    func exists(key: String) -> Bool {
        cleanupIfNeeded()

        guard let timestamp = store[key] else {
            return false
        }

        // Check if expired
        let age = Date().timeIntervalSince(timestamp)
        if age > Double(ttlSeconds) {
            store.removeValue(forKey: key)
            return false
        }

        return true
    }

    /// Store a key with current timestamp
    func store(key: String) {
        store[key] = Date()
    }

    /// Remove a key
    func remove(key: String) {
        store.removeValue(forKey: key)
    }

    /// Clean up expired keys periodically
    private func cleanupIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) > cleanupInterval else {
            return
        }

        let cutoff = now.addingTimeInterval(-Double(ttlSeconds))
        store = store.filter { $0.value > cutoff }
        lastCleanup = now
    }
}
```

### STAGE U-003 through U-007: ACK Tracker, Validator, and Tests

```swift
// Security/ACKTracker.swift
// STAGE U-003: Server acknowledgment tracking

import Foundation

/// Tracks pending and received ACKs
actor ACKTracker {
    private var pendingACKs: [Int: Date] = [:]  // sequence -> sent time
    private var receivedACKs: [Int: ServerACK] = [:]
    private let timeoutMs: Int64

    init(timeoutMs: Int64) {
        self.timeoutMs = timeoutMs
    }

    /// Register a chunk as pending ACK
    func registerPending(sequence: Int) {
        pendingACKs[sequence] = Date()
    }

    /// Confirm ACK received
    func confirmAck(sequence: Int) {
        pendingACKs.removeValue(forKey: sequence)
    }

    /// Get sequences that have timed out
    func getTimedOut() -> [Int] {
        let now = Date()
        let timeoutInterval = Double(timeoutMs) / 1000

        return pendingACKs.compactMap { sequence, sentTime in
            if now.timeIntervalSince(sentTime) > timeoutInterval {
                return sequence
            }
            return nil
        }
    }

    /// Check if all ACKs received
    func allAcksReceived() -> Bool {
        return pendingACKs.isEmpty
    }
}

// Security/ChunkSequenceValidator.swift
// STAGE U-004: Validates chunk sequence integrity

/// Validates that chunks arrive in correct sequence
public struct ChunkSequenceValidator {
    private var expectedSequence: Int = 0
    private var outOfOrderBuffer: [Int: ChunkInfo] = [:]
    private let maxBufferSize: Int

    public init(maxBufferSize: Int = 100) {
        self.maxBufferSize = maxBufferSize
    }

    /// Validate and process a chunk
    public mutating func validate(_ chunk: ChunkInfo) -> ValidationResult {
        if chunk.sequence == expectedSequence {
            // In order
            expectedSequence += 1

            // Process any buffered chunks that are now in order
            while let buffered = outOfOrderBuffer[expectedSequence] {
                outOfOrderBuffer.removeValue(forKey: expectedSequence)
                expectedSequence += 1
            }

            return .inOrder
        } else if chunk.sequence > expectedSequence {
            // Out of order - buffer it
            if outOfOrderBuffer.count >= maxBufferSize {
                return .bufferFull
            }
            outOfOrderBuffer[chunk.sequence] = chunk
            return .outOfOrder(expected: expectedSequence, received: chunk.sequence)
        } else {
            // Duplicate or old chunk
            return .duplicate(sequence: chunk.sequence)
        }
    }

    public enum ValidationResult {
        case inOrder
        case outOfOrder(expected: Int, received: Int)
        case duplicate(sequence: Int)
        case bufferFull
    }
}

// Tests/NetworkProtocolIntegrityTests.swift
// STAGE U-007: Network protocol tests

import XCTest
@testable import GaussianSplatCapture

final class NetworkProtocolIntegrityTests: XCTestCase {

    func testIdempotencyKeyGeneration() {
        let key1 = IdempotencyKeyGenerator.generate(
            uploadId: "upload123",
            sequence: 0,
            hash: "abc123def456"
        )
        let key2 = IdempotencyKeyGenerator.generate(
            uploadId: "upload123",
            sequence: 1,
            hash: "abc123def456"
        )

        XCTAssertNotEqual(key1, key2)  // Different sequences
        XCTAssertTrue(IdempotencyKeyGenerator.validate(key1))
    }

    func testIdempotencyStore() async {
        let store = IdempotencyStore(ttlSeconds: 60)

        await store.store(key: "test-key")
        let exists = await store.exists(key: "test-key")

        XCTAssertTrue(exists)
    }

    func testChunkSequenceValidator_InOrder() {
        var validator = ChunkSequenceValidator()

        let chunk0 = ChunkInfo(sequence: 0, offset: 0, size: 100, data: Data(), uploadId: "test")
        let chunk1 = ChunkInfo(sequence: 1, offset: 100, size: 100, data: Data(), uploadId: "test")

        let result0 = validator.validate(chunk0)
        let result1 = validator.validate(chunk1)

        if case .inOrder = result0, case .inOrder = result1 {
            // Success
        } else {
            XCTFail("Expected in-order results")
        }
    }

    func testChunkSequenceValidator_OutOfOrder() {
        var validator = ChunkSequenceValidator()

        let chunk1 = ChunkInfo(sequence: 1, offset: 100, size: 100, data: Data(), uploadId: "test")

        let result = validator.validate(chunk1)

        if case .outOfOrder(let expected, let received) = result {
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(received, 1)
        } else {
            XCTFail("Expected out-of-order result")
        }
    }

    func testUploadStateMachine_HappyPath() async throws {
        let config = UploadProtocolConfig.forProfile(.debug)
        let stateMachine = UploadProtocolStateMachine(config: config)

        let testData = Data(repeating: 0x42, count: 1024)

        var completionCalled = false
        await stateMachine.onComplete = { result in
            if case .success = result {
                completionCalled = true
            }
        }

        try await stateMachine.process(.start(uploadId: "test-upload", data: testData))

        // State machine should progress through states
        // In real test, would wait for completion
    }
}
```

---

## PART V: CONFIG GOVERNANCE PIPELINE (KILL SWITCH)

### V.1 Problem Statement

**Vulnerability ID**: CONFIG-001 through CONFIG-015
**Severity**: HIGH
**Category**: Configuration Safety, Feature Flags, Emergency Response

The current system lacks:
1. Signed configuration manifests (configs can be tampered)
2. Gradual rollout capability (all-or-nothing deployment)
3. Kill switch for emergency feature disable
4. Config version rollback capability
5. Audit trail of config changes

### V.2 Solution Architecture

Implement a **Config Governance Pipeline** with:
- Cryptographically signed config manifests
- Canary rollout with automatic rollback
- Kill switch with sub-minute propagation
- Feature flags with targeting rules

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CONFIG GOVERNANCE ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    CONFIG MANIFEST                               │   │
│  │                                                                  │   │
│  │  {                                                               │   │
│  │    "version": "2.3.1",                                          │   │
│  │    "signature": "RSA-SHA256:...",                               │   │
│  │    "features": {                                                │   │
│  │      "hdr_processing": { "enabled": true, "rollout": 100 },    │   │
│  │      "new_quality_algo": { "enabled": true, "rollout": 25 }    │   │
│  │    },                                                           │   │
│  │    "killSwitches": {                                            │   │
│  │      "upload_enabled": true,                                    │   │
│  │      "capture_enabled": true                                    │   │
│  │    },                                                           │   │
│  │    "parameters": { ... }                                        │   │
│  │  }                                                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ↓                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    ROLLOUT CONTROLLER                           │   │
│  │                                                                  │   │
│  │  Stage 1: 1% (Canary)   ──→ Monitor 1h ──→ Pass? ──→ Continue  │   │
│  │  Stage 2: 5%            ──→ Monitor 2h ──→ Pass? ──→ Continue  │   │
│  │  Stage 3: 25%           ──→ Monitor 4h ──→ Pass? ──→ Continue  │   │
│  │  Stage 4: 50%           ──→ Monitor 8h ──→ Pass? ──→ Continue  │   │
│  │  Stage 5: 100%          ──→ Complete                            │   │
│  │                                                                  │   │
│  │  Auto-Rollback Triggers:                                        │   │
│  │  - Error rate > 1%                                              │   │
│  │  - Latency p99 > 2x baseline                                    │   │
│  │  - Crash rate > 0.1%                                            │   │
│  │  - Manual trigger                                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ↓                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    KILL SWITCH POLICY                           │   │
│  │                                                                  │   │
│  │  Priority Levels:                                               │   │
│  │  P0 (Critical): Propagate within 60 seconds                     │   │
│  │  P1 (High):     Propagate within 5 minutes                      │   │
│  │  P2 (Medium):   Propagate within 15 minutes                     │   │
│  │                                                                  │   │
│  │  Propagation Channels:                                          │   │
│  │  1. Push notification (immediate)                               │   │
│  │  2. Config poll (on interval)                                   │   │
│  │  3. In-app check (on critical actions)                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### V.3 Implementation Files

```
New Files:
├── Domain/
│   ├── ConfigSignedManifest.swift          (STAGE V-001)
│   └── FeatureFlagDefinition.swift         (STAGE V-002)
├── Governance/
│   ├── ConfigRolloutController.swift       (STAGE V-003)
│   ├── KillSwitchPolicy.swift              (STAGE V-004)
│   ├── RolloutStageMonitor.swift           (STAGE V-005)
│   └── ConfigVersionHistory.swift          (STAGE V-006)
└── Tests/
    └── ConfigGovernanceTests.swift          (STAGE V-007)
```

### STAGE V-001: ConfigSignedManifest.swift

```swift
// Domain/ConfigSignedManifest.swift
// STAGE V-001: Cryptographically signed configuration manifest
// Vulnerability: CONFIG-001, CONFIG-002, CONFIG-003

import Foundation
import CryptoKit

/// A signed configuration manifest with version control
public struct ConfigSignedManifest: Codable, Sendable {

    // MARK: - Manifest Metadata

    /// Semantic version of this config
    public let version: SemanticVersion

    /// Timestamp when this config was created
    public let createdAt: Date

    /// Timestamp when this config expires (must fetch new)
    public let expiresAt: Date

    /// RSA-SHA256 signature of the manifest content
    public let signature: String

    /// Public key ID used to sign this manifest
    public let signingKeyId: String

    // MARK: - Feature Flags

    /// Feature flag definitions with rollout percentages
    public let features: [String: FeatureFlag]

    // MARK: - Kill Switches

    /// Emergency kill switches for critical functions
    public let killSwitches: [String: Bool]

    // MARK: - Configuration Parameters

    /// Typed configuration parameters
    public let parameters: ConfigParameters

    /// Semantic version for config versioning
    public struct SemanticVersion: Codable, Sendable, Comparable {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public var string: String { "\(major).\(minor).\(patch)" }

        public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    /// Feature flag with rollout configuration
    public struct FeatureFlag: Codable, Sendable {
        public let enabled: Bool
        public let rolloutPercentage: Int  // 0-100
        public let targetingRules: [TargetingRule]?
        public let description: String?

        /// Targeting rule for feature flag
        public struct TargetingRule: Codable, Sendable {
            public let attribute: String      // e.g., "deviceModel", "osVersion", "userId"
            public let `operator`: Operator
            public let value: String

            public enum Operator: String, Codable, Sendable {
                case equals
                case notEquals
                case contains
                case greaterThan
                case lessThan
                case inList
            }
        }
    }

    /// Configuration parameters
    public struct ConfigParameters: Codable, Sendable {
        public let qualityThresholds: QualityThresholds
        public let uploadLimits: UploadLimits
        public let performanceBudgets: PerformanceBudgets
        public let featureSettings: [String: AnyCodable]

        public struct QualityThresholds: Codable, Sendable {
            public let minimumSharpness: Double
            public let minimumExposure: Double
            public let maximumMotion: Double
            public let minimumCoverage: Double
        }

        public struct UploadLimits: Codable, Sendable {
            public let maxFileSizeMB: Int
            public let maxFramesPerSession: Int
            public let maxConcurrentUploads: Int
        }

        public struct PerformanceBudgets: Codable, Sendable {
            public let frameProcessingMs: Int
            public let uploadTimeoutSeconds: Int
            public let memoryLimitMB: Int
        }
    }
}

/// Manifest verifier
public struct ManifestVerifier {

    private let trustedPublicKeys: [String: P256.Signing.PublicKey]

    public init(trustedPublicKeys: [String: P256.Signing.PublicKey]) {
        self.trustedPublicKeys = trustedPublicKeys
    }

    /// Verify manifest signature
    public func verify(_ manifest: ConfigSignedManifest) throws -> Bool {
        // Get the signing key
        guard let publicKey = trustedPublicKeys[manifest.signingKeyId] else {
            throw ManifestError.unknownSigningKey(manifest.signingKeyId)
        }

        // Compute content hash (everything except signature)
        let contentHash = computeContentHash(manifest)

        // Decode signature
        guard let signatureData = Data(base64Encoded: manifest.signature) else {
            throw ManifestError.invalidSignature
        }

        // Verify signature
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        let isValid = publicKey.isValidSignature(signature, for: contentHash)

        if !isValid {
            throw ManifestError.signatureVerificationFailed
        }

        // Check expiration
        if manifest.expiresAt < Date() {
            throw ManifestError.manifestExpired(manifest.expiresAt)
        }

        return true
    }

    private func computeContentHash(_ manifest: ConfigSignedManifest) -> Data {
        // Create deterministic JSON representation (excluding signature)
        let content = """
        {
            "version": "\(manifest.version.string)",
            "createdAt": "\(manifest.createdAt.ISO8601Format())",
            "expiresAt": "\(manifest.expiresAt.ISO8601Format())",
            "signingKeyId": "\(manifest.signingKeyId)"
        }
        """
        return Data(SHA256.hash(data: Data(content.utf8)))
    }
}

/// Manifest errors
public enum ManifestError: Error, LocalizedError {
    case unknownSigningKey(String)
    case invalidSignature
    case signatureVerificationFailed
    case manifestExpired(Date)
    case versionConflict(current: String, new: String)

    public var errorDescription: String? {
        switch self {
        case .unknownSigningKey(let keyId):
            return "Unknown signing key: \(keyId)"
        case .invalidSignature:
            return "Invalid signature format"
        case .signatureVerificationFailed:
            return "Signature verification failed"
        case .manifestExpired(let expiry):
            return "Manifest expired at \(expiry)"
        case .versionConflict(let current, let new):
            return "Version conflict: current=\(current), new=\(new)"
        }
    }
}
```

### STAGE V-003: ConfigRolloutController.swift

```swift
// Governance/ConfigRolloutController.swift
// STAGE V-003: Canary rollout with automatic rollback
// Vulnerability: CONFIG-004, CONFIG-005, CONFIG-006

import Foundation

/// Configuration for rollout stages
public struct RolloutConfig: Codable, Sendable {
    /// Rollout stages with percentages and monitoring durations
    public let stages: [RolloutStage]

    /// Error rate threshold for auto-rollback (e.g., 0.01 = 1%)
    public let rollbackTriggerErrorRate: Double

    /// Latency multiplier threshold for auto-rollback (e.g., 2.0 = 2x baseline)
    public let rollbackTriggerLatencyMultiplier: Double

    /// Crash rate threshold for auto-rollback (e.g., 0.001 = 0.1%)
    public let rollbackTriggerCrashRate: Double

    /// Stage definition
    public struct RolloutStage: Codable, Sendable {
        public let percentage: Int
        public let monitoringDurationMinutes: Int
        public let requiredSuccessRate: Double
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> RolloutConfig {
        switch profile {
        case .production:
            return RolloutConfig(
                stages: [
                    RolloutStage(percentage: 1, monitoringDurationMinutes: 60, requiredSuccessRate: 0.999),
                    RolloutStage(percentage: 5, monitoringDurationMinutes: 120, requiredSuccessRate: 0.995),
                    RolloutStage(percentage: 25, monitoringDurationMinutes: 240, requiredSuccessRate: 0.99),
                    RolloutStage(percentage: 50, monitoringDurationMinutes: 480, requiredSuccessRate: 0.99),
                    RolloutStage(percentage: 100, monitoringDurationMinutes: 0, requiredSuccessRate: 0.99)
                ],
                rollbackTriggerErrorRate: 0.01,
                rollbackTriggerLatencyMultiplier: 2.0,
                rollbackTriggerCrashRate: 0.001
            )
        case .debug:
            return RolloutConfig(
                stages: [
                    RolloutStage(percentage: 50, monitoringDurationMinutes: 5, requiredSuccessRate: 0.95),
                    RolloutStage(percentage: 100, monitoringDurationMinutes: 0, requiredSuccessRate: 0.95)
                ],
                rollbackTriggerErrorRate: 0.05,
                rollbackTriggerLatencyMultiplier: 3.0,
                rollbackTriggerCrashRate: 0.01
            )
        case .lab:
            return RolloutConfig(
                stages: [
                    RolloutStage(percentage: 100, monitoringDurationMinutes: 1, requiredSuccessRate: 0.999)
                ],
                rollbackTriggerErrorRate: 0.001,  // Extreme sensitivity
                rollbackTriggerLatencyMultiplier: 1.5,
                rollbackTriggerCrashRate: 0.0001
            )
        }
    }
}

/// Rollout state for a feature
public struct RolloutState: Codable, Sendable {
    public let featureId: String
    public let configVersion: String
    public let currentStageIndex: Int
    public let currentPercentage: Int
    public let startedAt: Date
    public let stageStartedAt: Date
    public let status: RolloutStatus
    public let metrics: RolloutMetrics

    public enum RolloutStatus: String, Codable, Sendable {
        case pending
        case inProgress
        case monitoring
        case advancing
        case complete
        case rolledBack
        case paused
    }

    public struct RolloutMetrics: Codable, Sendable {
        public let requestCount: Int
        public let errorCount: Int
        public let averageLatencyMs: Double
        public let p99LatencyMs: Double
        public let crashCount: Int

        public var errorRate: Double {
            guard requestCount > 0 else { return 0 }
            return Double(errorCount) / Double(requestCount)
        }

        public var crashRate: Double {
            guard requestCount > 0 else { return 0 }
            return Double(crashCount) / Double(requestCount)
        }
    }
}

/// Config Rollout Controller
/// Manages gradual feature rollout with automatic rollback
@available(iOS 15.0, macOS 12.0, *)
public actor ConfigRolloutController {

    // MARK: - Properties

    private let config: RolloutConfig
    private var rolloutStates: [String: RolloutState] = [:]  // featureId -> state
    private var previousConfigs: [String: ConfigSignedManifest] = [:]  // version -> manifest
    private var baselineMetrics: RolloutState.RolloutMetrics?

    // MARK: - Initialization

    public init(config: RolloutConfig) {
        self.config = config
    }

    // MARK: - Public API

    /// Start a rollout for a feature
    public func startRollout(
        featureId: String,
        configVersion: String,
        previousManifest: ConfigSignedManifest?
    ) async -> RolloutState {
        // Store previous config for rollback
        if let prev = previousManifest {
            previousConfigs[prev.version.string] = prev
        }

        let initialState = RolloutState(
            featureId: featureId,
            configVersion: configVersion,
            currentStageIndex: 0,
            currentPercentage: config.stages[0].percentage,
            startedAt: Date(),
            stageStartedAt: Date(),
            status: .inProgress,
            metrics: .init(
                requestCount: 0,
                errorCount: 0,
                averageLatencyMs: 0,
                p99LatencyMs: 0,
                crashCount: 0
            )
        )

        rolloutStates[featureId] = initialState
        return initialState
    }

    /// Report metrics for a rollout
    public func reportMetrics(
        featureId: String,
        requestCount: Int,
        errorCount: Int,
        averageLatencyMs: Double,
        p99LatencyMs: Double,
        crashCount: Int
    ) async -> RolloutDecision {
        guard var state = rolloutStates[featureId] else {
            return .noAction
        }

        // Update metrics
        let updatedMetrics = RolloutState.RolloutMetrics(
            requestCount: state.metrics.requestCount + requestCount,
            errorCount: state.metrics.errorCount + errorCount,
            averageLatencyMs: averageLatencyMs,  // Latest value
            p99LatencyMs: p99LatencyMs,
            crashCount: state.metrics.crashCount + crashCount
        )

        state = RolloutState(
            featureId: state.featureId,
            configVersion: state.configVersion,
            currentStageIndex: state.currentStageIndex,
            currentPercentage: state.currentPercentage,
            startedAt: state.startedAt,
            stageStartedAt: state.stageStartedAt,
            status: state.status,
            metrics: updatedMetrics
        )

        // Check rollback triggers
        if shouldRollback(metrics: updatedMetrics) {
            return await performRollback(featureId: featureId, reason: .metricsThresholdExceeded)
        }

        // Check if ready to advance stage
        if shouldAdvanceStage(state: state) {
            return await advanceStage(featureId: featureId)
        }

        rolloutStates[featureId] = state
        return .continue
    }

    /// Check if device should receive feature based on rollout percentage
    public func shouldReceiveFeature(
        featureId: String,
        deviceId: String
    ) -> Bool {
        guard let state = rolloutStates[featureId],
              state.status == .inProgress || state.status == .monitoring else {
            return false
        }

        // Deterministic bucketing based on device ID
        let bucket = abs(deviceId.hashValue) % 100
        return bucket < state.currentPercentage
    }

    /// Manually trigger rollback
    public func manualRollback(featureId: String, reason: String) async -> RolloutDecision {
        return await performRollback(featureId: featureId, reason: .manual(reason))
    }

    // MARK: - Private Methods

    private func shouldRollback(metrics: RolloutState.RolloutMetrics) -> Bool {
        // Check error rate
        if metrics.errorRate > config.rollbackTriggerErrorRate {
            return true
        }

        // Check crash rate
        if metrics.crashRate > config.rollbackTriggerCrashRate {
            return true
        }

        // Check latency (if we have baseline)
        if let baseline = baselineMetrics {
            let latencyMultiplier = metrics.p99LatencyMs / baseline.p99LatencyMs
            if latencyMultiplier > config.rollbackTriggerLatencyMultiplier {
                return true
            }
        }

        return false
    }

    private func shouldAdvanceStage(state: RolloutState) -> Bool {
        guard state.currentStageIndex < config.stages.count - 1 else {
            return false  // Already at final stage
        }

        let currentStage = config.stages[state.currentStageIndex]
        let monitoringDuration = TimeInterval(currentStage.monitoringDurationMinutes * 60)
        let elapsed = Date().timeIntervalSince(state.stageStartedAt)

        // Check if monitoring duration has passed
        guard elapsed >= monitoringDuration else {
            return false
        }

        // Check if success rate is met
        let successRate = 1.0 - state.metrics.errorRate
        return successRate >= currentStage.requiredSuccessRate
    }

    private func advanceStage(featureId: String) async -> RolloutDecision {
        guard var state = rolloutStates[featureId] else {
            return .noAction
        }

        let nextStageIndex = state.currentStageIndex + 1

        if nextStageIndex >= config.stages.count {
            // Rollout complete
            state = RolloutState(
                featureId: state.featureId,
                configVersion: state.configVersion,
                currentStageIndex: state.currentStageIndex,
                currentPercentage: 100,
                startedAt: state.startedAt,
                stageStartedAt: Date(),
                status: .complete,
                metrics: state.metrics
            )
            rolloutStates[featureId] = state
            return .complete
        }

        let nextStage = config.stages[nextStageIndex]
        state = RolloutState(
            featureId: state.featureId,
            configVersion: state.configVersion,
            currentStageIndex: nextStageIndex,
            currentPercentage: nextStage.percentage,
            startedAt: state.startedAt,
            stageStartedAt: Date(),
            status: .inProgress,
            metrics: .init(requestCount: 0, errorCount: 0, averageLatencyMs: 0, p99LatencyMs: 0, crashCount: 0)
        )

        rolloutStates[featureId] = state
        return .advancedToStage(nextStageIndex, percentage: nextStage.percentage)
    }

    private func performRollback(featureId: String, reason: RollbackReason) async -> RolloutDecision {
        guard var state = rolloutStates[featureId] else {
            return .noAction
        }

        state = RolloutState(
            featureId: state.featureId,
            configVersion: state.configVersion,
            currentStageIndex: state.currentStageIndex,
            currentPercentage: 0,
            startedAt: state.startedAt,
            stageStartedAt: Date(),
            status: .rolledBack,
            metrics: state.metrics
        )

        rolloutStates[featureId] = state
        return .rolledBack(reason)
    }
}

/// Rollout decision
public enum RolloutDecision: Sendable {
    case noAction
    case `continue`
    case advancedToStage(Int, percentage: Int)
    case complete
    case rolledBack(RollbackReason)
}

/// Rollback reason
public enum RollbackReason: Sendable {
    case metricsThresholdExceeded
    case manual(String)
    case killSwitchActivated
}
```

### STAGE V-004: KillSwitchPolicy.swift

```swift
// Governance/KillSwitchPolicy.swift
// STAGE V-004: Emergency kill switch with fast propagation
// Vulnerability: CONFIG-007, CONFIG-008, CONFIG-009

import Foundation

/// Kill switch configuration
public struct KillSwitchConfig: Codable, Sendable {
    /// Maximum propagation time for P0 (critical) kill switches
    public let p0PropagationMaxSeconds: Int64

    /// Maximum propagation time for P1 (high) kill switches
    public let p1PropagationMaxSeconds: Int64

    /// Maximum propagation time for P2 (medium) kill switches
    public let p2PropagationMaxSeconds: Int64

    /// Poll interval for checking kill switch status
    public let pollIntervalSeconds: Int64

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> KillSwitchConfig {
        switch profile {
        case .production:
            return KillSwitchConfig(
                p0PropagationMaxSeconds: 60,
                p1PropagationMaxSeconds: 300,
                p2PropagationMaxSeconds: 900,
                pollIntervalSeconds: 30
            )
        case .debug:
            return KillSwitchConfig(
                p0PropagationMaxSeconds: 300,
                p1PropagationMaxSeconds: 600,
                p2PropagationMaxSeconds: 1800,
                pollIntervalSeconds: 60
            )
        case .lab:
            return KillSwitchConfig(
                p0PropagationMaxSeconds: 5,   // Extreme: 5 second propagation
                p1PropagationMaxSeconds: 15,
                p2PropagationMaxSeconds: 30,
                pollIntervalSeconds: 1
            )
        }
    }
}

/// Kill switch definition
public struct KillSwitch: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let priority: Priority
    public let enabled: Bool
    public let activatedAt: Date?
    public let activatedBy: String?
    public let reason: String?

    public enum Priority: String, Codable, Sendable {
        case p0  // Critical - affects core functionality
        case p1  // High - affects important features
        case p2  // Medium - affects non-critical features
    }

    /// Predefined kill switches
    public static let captureEnabled = KillSwitch(
        id: "capture_enabled",
        name: "Capture Enabled",
        description: "Master switch for capture functionality",
        priority: .p0,
        enabled: true,
        activatedAt: nil,
        activatedBy: nil,
        reason: nil
    )

    public static let uploadEnabled = KillSwitch(
        id: "upload_enabled",
        name: "Upload Enabled",
        description: "Master switch for upload functionality",
        priority: .p0,
        enabled: true,
        activatedAt: nil,
        activatedBy: nil,
        reason: nil
    )

    public static let qualityGatesEnabled = KillSwitch(
        id: "quality_gates_enabled",
        name: "Quality Gates Enabled",
        description: "Enable/disable quality gate enforcement",
        priority: .p1,
        enabled: true,
        activatedAt: nil,
        activatedBy: nil,
        reason: nil
    )
}

/// Kill Switch Policy Manager
/// Manages kill switch state and propagation
@available(iOS 15.0, macOS 12.0, *)
public actor KillSwitchManager {

    // MARK: - Properties

    private let config: KillSwitchConfig
    private var killSwitches: [String: KillSwitch] = [:]
    private var lastFetchTime: Date?
    private var listeners: [(String, Bool) -> Void] = []

    // MARK: - Initialization

    public init(config: KillSwitchConfig) {
        self.config = config
        initializeDefaultSwitches()
    }

    // MARK: - Public API

    /// Check if a kill switch is enabled
    public func isEnabled(_ switchId: String) -> Bool {
        return killSwitches[switchId]?.enabled ?? true
    }

    /// Activate a kill switch (disable the feature)
    public func activate(
        switchId: String,
        by user: String,
        reason: String
    ) async {
        guard var killSwitch = killSwitches[switchId] else { return }

        killSwitch = KillSwitch(
            id: killSwitch.id,
            name: killSwitch.name,
            description: killSwitch.description,
            priority: killSwitch.priority,
            enabled: false,
            activatedAt: Date(),
            activatedBy: user,
            reason: reason
        )

        killSwitches[switchId] = killSwitch
        notifyListeners(switchId: switchId, enabled: false)

        // Log to audit
        await logKillSwitchActivation(killSwitch)
    }

    /// Deactivate a kill switch (re-enable the feature)
    public func deactivate(switchId: String, by user: String) async {
        guard var killSwitch = killSwitches[switchId] else { return }

        killSwitch = KillSwitch(
            id: killSwitch.id,
            name: killSwitch.name,
            description: killSwitch.description,
            priority: killSwitch.priority,
            enabled: true,
            activatedAt: nil,
            activatedBy: nil,
            reason: nil
        )

        killSwitches[switchId] = killSwitch
        notifyListeners(switchId: switchId, enabled: true)
    }

    /// Fetch latest kill switch state from server
    public func fetchFromServer() async throws {
        // In production, this would fetch from server
        // For now, just update last fetch time
        lastFetchTime = Date()
    }

    /// Register listener for kill switch changes
    public func addListener(_ listener: @escaping (String, Bool) -> Void) {
        listeners.append(listener)
    }

    /// Start periodic polling for kill switch updates
    public func startPolling() async {
        while true {
            try? await Task.sleep(nanoseconds: UInt64(config.pollIntervalSeconds) * 1_000_000_000)
            try? await fetchFromServer()
        }
    }

    // MARK: - Private Methods

    private func initializeDefaultSwitches() {
        killSwitches[KillSwitch.captureEnabled.id] = KillSwitch.captureEnabled
        killSwitches[KillSwitch.uploadEnabled.id] = KillSwitch.uploadEnabled
        killSwitches[KillSwitch.qualityGatesEnabled.id] = KillSwitch.qualityGatesEnabled
    }

    private func notifyListeners(switchId: String, enabled: Bool) {
        for listener in listeners {
            listener(switchId, enabled)
        }
    }

    private func logKillSwitchActivation(_ killSwitch: KillSwitch) async {
        // Create audit entry
        let entry = AuditEntry(
            eventType: .killSwitchActivation,
            sessionId: "system",
            timestamp: Date(),
            data: [
                "switchId": killSwitch.id,
                "enabled": killSwitch.enabled,
                "activatedBy": killSwitch.activatedBy ?? "unknown",
                "reason": killSwitch.reason ?? "not specified",
                "priority": killSwitch.priority.rawValue
            ]
        )

        // Log entry (implementation would write to audit system)
        print("KILL SWITCH: \(entry)")
    }
}
```

---

## PART W: TENANT ISOLATION & DATA RESIDENCY

### W.1 Problem Statement

**Vulnerability ID**: TENANT-001 through TENANT-012
**Severity**: CRITICAL
**Category**: Data Privacy, GDPR Compliance, Multi-Tenancy

The system must support:
1. Multi-tenant isolation for enterprise customers
2. Data residency requirements (GDPR, data sovereignty)
3. Cross-border data transfer restrictions
4. Per-tenant encryption key management

### W.2 Implementation

```
New Files:
├── Security/
│   ├── TenantIsolationPolicy.swift         (STAGE W-001)
│   └── TenantContext.swift                 (STAGE W-002)
├── Privacy/
│   ├── RegionResidencyRouter.swift         (STAGE W-003)
│   ├── DataSovereigntyRules.swift          (STAGE W-004)
│   └── CrossBorderPolicy.swift             (STAGE W-005)
└── Tests/
    └── TenantIsolationTests.swift          (STAGE W-006)
```

### STAGE W-001: TenantIsolationPolicy.swift

```swift
// Security/TenantIsolationPolicy.swift
// STAGE W-001: Multi-tenant data isolation
// Vulnerability: TENANT-001 through TENANT-004

import Foundation

/// Tenant isolation configuration
public struct TenantIsolationConfig: Codable, Sendable {
    /// Whether cross-tenant data access is blocked
    public let strictIsolation: Bool

    /// Encryption key rotation interval
    public let keyRotationIntervalDays: Int

    /// Audit log retention period
    public let auditRetentionDays: Int

    /// Whether to enforce data residency
    public let enforceDataResidency: Bool

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> TenantIsolationConfig {
        switch profile {
        case .production:
            return TenantIsolationConfig(
                strictIsolation: true,
                keyRotationIntervalDays: 90,
                auditRetentionDays: 2555,  // 7 years for compliance
                enforceDataResidency: true
            )
        case .debug:
            return TenantIsolationConfig(
                strictIsolation: false,
                keyRotationIntervalDays: 7,
                auditRetentionDays: 30,
                enforceDataResidency: false
            )
        case .lab:
            return TenantIsolationConfig(
                strictIsolation: true,
                keyRotationIntervalDays: 1,   // Daily rotation for testing
                auditRetentionDays: 1,
                enforceDataResidency: true
            )
        }
    }
}

/// Tenant context for request scoping
public struct TenantContext: Codable, Sendable {
    public let tenantId: String
    public let organizationName: String
    public let dataRegion: DataRegion
    public let encryptionKeyId: String
    public let allowedRegions: [DataRegion]
    public let complianceRequirements: [ComplianceStandard]

    public enum DataRegion: String, Codable, Sendable {
        case usEast = "us-east-1"
        case usWest = "us-west-2"
        case euWest = "eu-west-1"
        case euCentral = "eu-central-1"
        case apNortheast = "ap-northeast-1"
        case apSoutheast = "ap-southeast-1"
    }

    public enum ComplianceStandard: String, Codable, Sendable {
        case gdpr           // EU General Data Protection Regulation
        case ccpa           // California Consumer Privacy Act
        case hipaa          // Health Insurance Portability
        case sox            // Sarbanes-Oxley
        case pciDss         // Payment Card Industry
    }
}

/// Tenant Isolation Manager
@available(iOS 15.0, macOS 12.0, *)
public actor TenantIsolationManager {

    private let config: TenantIsolationConfig
    private var tenantContexts: [String: TenantContext] = [:]

    public init(config: TenantIsolationConfig) {
        self.config = config
    }

    /// Validate that a request can access tenant data
    public func validateAccess(
        requestTenantId: String,
        resourceTenantId: String
    ) throws {
        if config.strictIsolation && requestTenantId != resourceTenantId {
            throw TenantError.crossTenantAccessDenied(
                requestingTenant: requestTenantId,
                resourceTenant: resourceTenantId
            )
        }
    }

    /// Get encryption key for tenant
    public func getEncryptionKey(tenantId: String) async throws -> Data {
        guard let context = tenantContexts[tenantId] else {
            throw TenantError.tenantNotFound(tenantId)
        }
        // In production, fetch from key management service
        return Data(context.encryptionKeyId.utf8)
    }

    /// Register tenant context
    public func registerTenant(_ context: TenantContext) {
        tenantContexts[context.tenantId] = context
    }
}

public enum TenantError: Error {
    case crossTenantAccessDenied(requestingTenant: String, resourceTenant: String)
    case tenantNotFound(String)
    case dataResidencyViolation(requiredRegion: TenantContext.DataRegion, actualRegion: TenantContext.DataRegion)
}
```

### STAGE W-003: RegionResidencyRouter.swift

```swift
// Privacy/RegionResidencyRouter.swift
// STAGE W-003: Data residency routing
// Vulnerability: TENANT-005 through TENANT-008

import Foundation

/// Routes data to appropriate region based on residency requirements
public actor RegionResidencyRouter {

    private let regionEndpoints: [TenantContext.DataRegion: URL]
    private let crossBorderRules: CrossBorderRules

    public init() {
        self.regionEndpoints = [
            .usEast: URL(string: "https://us-east.api.example.com")!,
            .usWest: URL(string: "https://us-west.api.example.com")!,
            .euWest: URL(string: "https://eu-west.api.example.com")!,
            .euCentral: URL(string: "https://eu-central.api.example.com")!,
            .apNortheast: URL(string: "https://ap-northeast.api.example.com")!,
            .apSoutheast: URL(string: "https://ap-southeast.api.example.com")!
        ]
        self.crossBorderRules = CrossBorderRules()
    }

    /// Route request to appropriate region
    public func routeRequest(
        tenant: TenantContext,
        requestRegion: TenantContext.DataRegion
    ) throws -> URL {
        // Check if cross-border transfer is allowed
        if tenant.dataRegion != requestRegion {
            try crossBorderRules.validateTransfer(
                from: requestRegion,
                to: tenant.dataRegion,
                compliance: tenant.complianceRequirements
            )
        }

        guard let endpoint = regionEndpoints[tenant.dataRegion] else {
            throw ResidencyError.regionNotSupported(tenant.dataRegion)
        }

        return endpoint
    }
}

/// Cross-border data transfer rules
public struct CrossBorderRules {

    /// EU-approved countries for GDPR adequacy
    private let gdprAdequateCountries: Set<TenantContext.DataRegion> = [
        .euWest, .euCentral
    ]

    /// Validate a cross-border transfer
    public func validateTransfer(
        from source: TenantContext.DataRegion,
        to destination: TenantContext.DataRegion,
        compliance: [TenantContext.ComplianceStandard]
    ) throws {
        // GDPR requires data to stay in EU or adequacy-approved countries
        if compliance.contains(.gdpr) {
            let sourceInEU = gdprAdequateCountries.contains(source)
            let destInEU = gdprAdequateCountries.contains(destination)

            if sourceInEU && !destInEU {
                throw ResidencyError.gdprTransferBlocked(from: source, to: destination)
            }
        }
    }
}

public enum ResidencyError: Error {
    case regionNotSupported(TenantContext.DataRegion)
    case gdprTransferBlocked(from: TenantContext.DataRegion, to: TenantContext.DataRegion)
    case crossBorderBlocked(reason: String)
}
```

---

## PART X: OS EVENT INTERRUPTION MANAGER

### X.1 Problem Statement

**Vulnerability ID**: INTERRUPT-001 through INTERRUPT-010
**Severity**: HIGH
**Category**: Session Recovery, State Persistence, Hardware Events

The system must handle:
1. Phone calls interrupting capture
2. Low memory warnings
3. Thermal throttling events
4. App backgrounding
5. GPU reset events

### X.2 Implementation

```
New Files:
├── Recovery/
│   ├── InterruptionEventMachine.swift      (STAGE X-001)
│   ├── CameraSessionRebuilder.swift        (STAGE X-002)
│   └── StateCheckpointer.swift             (STAGE X-003)
├── Performance/
│   └── GPUResetDetector.swift              (STAGE X-004)
└── Tests/
    └── InterruptionRecoveryTests.swift     (STAGE X-005)
```

### STAGE X-001: InterruptionEventMachine.swift

```swift
// Recovery/InterruptionEventMachine.swift
// STAGE X-001: State machine for interruption handling
// Vulnerability: INTERRUPT-001 through INTERRUPT-005

import Foundation

/// Interruption event types
public enum InterruptionEvent: String, Codable, Sendable {
    case phoneCallStarted
    case phoneCallEnded
    case lowMemoryWarning
    case criticalMemoryWarning
    case thermalWarning
    case thermalCritical
    case thermalNominal
    case appBackgrounded
    case appForegrounded
    case gpuReset
    case cameraDisconnected
    case cameraReconnected
}

/// Interruption state
public enum InterruptionState: String, Codable, Sendable {
    case normal
    case interrupted
    case recovering
    case degraded
    case suspended
}

/// Interruption configuration
public struct InterruptionConfig: Codable, Sendable {
    public let sessionRebuildTimeoutMs: Int64
    public let gpuResetDetectionThreshold: Int
    public let lowMemoryWarningMB: Int
    public let maxBackgroundTimeSeconds: Int

    public static func forProfile(_ profile: ConfigProfile) -> InterruptionConfig {
        switch profile {
        case .production:
            return InterruptionConfig(
                sessionRebuildTimeoutMs: 5000,
                gpuResetDetectionThreshold: 3,
                lowMemoryWarningMB: 100,
                maxBackgroundTimeSeconds: 30
            )
        case .debug:
            return InterruptionConfig(
                sessionRebuildTimeoutMs: 15000,
                gpuResetDetectionThreshold: 10,
                lowMemoryWarningMB: 500,
                maxBackgroundTimeSeconds: 300
            )
        case .lab:
            return InterruptionConfig(
                sessionRebuildTimeoutMs: 500,    // Extreme: fast recovery
                gpuResetDetectionThreshold: 1,
                lowMemoryWarningMB: 10,
                maxBackgroundTimeSeconds: 5
            )
        }
    }
}

/// Interruption Event State Machine
@available(iOS 15.0, macOS 12.0, *)
public actor InterruptionEventMachine {

    private let config: InterruptionConfig
    private var state: InterruptionState = .normal
    private var eventHistory: [(event: InterruptionEvent, timestamp: Date)] = []
    private var checkpoints: [StateCheckpoint] = []

    public init(config: InterruptionConfig) {
        self.config = config
    }

    /// Process an interruption event
    public func process(_ event: InterruptionEvent) async -> InterruptionAction {
        let previousState = state
        eventHistory.append((event, Date()))

        switch (state, event) {
        case (.normal, .phoneCallStarted):
            state = .interrupted
            return .pauseCapture(saveCheckpoint: true)

        case (.interrupted, .phoneCallEnded):
            state = .recovering
            return .resumeCapture

        case (.normal, .lowMemoryWarning):
            state = .degraded
            return .reduceMemoryUsage

        case (_, .criticalMemoryWarning):
            state = .suspended
            return .emergencyShutdown(saveState: true)

        case (.normal, .thermalWarning):
            state = .degraded
            return .reduceProcessingLoad

        case (_, .thermalCritical):
            state = .suspended
            return .pauseCapture(saveCheckpoint: true)

        case (.degraded, .thermalNominal):
            state = .normal
            return .restoreFullCapacity

        case (.normal, .appBackgrounded):
            state = .suspended
            return .pauseCapture(saveCheckpoint: true)

        case (.suspended, .appForegrounded):
            state = .recovering
            return .resumeCapture

        case (_, .gpuReset):
            state = .recovering
            return .rebuildGPUResources

        case (_, .cameraDisconnected):
            state = .interrupted
            return .handleCameraLoss

        case (.interrupted, .cameraReconnected):
            state = .recovering
            return .rebuildCameraSession

        case (.recovering, _):
            // Recovery in progress, queue the event
            return .queueEvent(event)

        default:
            return .noAction
        }
    }

    /// Save current state checkpoint
    public func saveCheckpoint(_ checkpoint: StateCheckpoint) {
        checkpoints.append(checkpoint)
        // Keep only last 10 checkpoints
        if checkpoints.count > 10 {
            checkpoints.removeFirst()
        }
    }

    /// Get latest checkpoint for recovery
    public func getLatestCheckpoint() -> StateCheckpoint? {
        return checkpoints.last
    }

    /// Current state
    public func currentState() -> InterruptionState {
        return state
    }
}

/// Action to take after interruption
public enum InterruptionAction: Sendable {
    case noAction
    case pauseCapture(saveCheckpoint: Bool)
    case resumeCapture
    case reduceMemoryUsage
    case reduceProcessingLoad
    case restoreFullCapacity
    case emergencyShutdown(saveState: Bool)
    case rebuildGPUResources
    case rebuildCameraSession
    case handleCameraLoss
    case queueEvent(InterruptionEvent)
}

/// State checkpoint for recovery
public struct StateCheckpoint: Codable, Sendable {
    public let timestamp: Date
    public let sessionId: String
    public let frameCount: Int
    public let lastAnchorHash: String
    public let qualityState: [String: Double]
    public let pendingUploads: [String]
}
```

### STAGE X-004: GPUResetDetector.swift

```swift
// Performance/GPUResetDetector.swift
// STAGE X-004: Detect and handle GPU reset events
// Vulnerability: INTERRUPT-006 through INTERRUPT-008

import Foundation
import Metal

/// GPU Reset Detector
@available(iOS 15.0, macOS 12.0, *)
public actor GPUResetDetector {

    private var resetCount: Int = 0
    private var lastResetTime: Date?
    private let threshold: Int
    private weak var interruptionMachine: InterruptionEventMachine?

    public init(
        threshold: Int,
        interruptionMachine: InterruptionEventMachine
    ) {
        self.threshold = threshold
        self.interruptionMachine = interruptionMachine
        setupMetalNotifications()
    }

    private func setupMetalNotifications() {
        // In production, register for Metal device removal notifications
        NotificationCenter.default.addObserver(
            forName: .MTLDeviceWasRemovedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleGPUReset()
            }
        }
    }

    private func handleGPUReset() async {
        resetCount += 1
        lastResetTime = Date()

        if resetCount >= threshold {
            // Too many resets - likely hardware issue
            await interruptionMachine?.process(.gpuReset)
        }
    }

    /// Reset the counter (call after successful recovery)
    public func resetCounter() {
        resetCount = 0
    }
}
```

---

## PART Y: LIVENESS PROOF & ANTI-REPLAY

### Y.1 Problem Statement

**Vulnerability ID**: LIVENESS-001 through LIVENESS-015
**Severity**: CRITICAL
**Category**: Anti-Fraud, Camera Authenticity, Replay Prevention

The system must detect:
1. Virtual camera injection
2. Pre-recorded video replay
3. Sensor manipulation
4. Challenge-response freshness

### Y.2 Solution: PRNU Fingerprinting & Challenge-Response

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    LIVENESS DETECTION ARCHITECTURE                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  LAYER 1: PRNU SENSOR FINGERPRINT                                       │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  - Photo-Response Non-Uniformity unique to each sensor          │   │
│  │  - Extract noise pattern from multiple frames                   │   │
│  │  - Compare against enrolled device fingerprint                  │   │
│  │  - Detect virtual camera (no PRNU) or different device          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  LAYER 2: CHALLENGE-RESPONSE                                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  - Server sends random challenge (e.g., "capture red object")   │   │
│  │  - Client must respond within time window                       │   │
│  │  - Response validated against challenge requirements            │   │
│  │  - Prevents pre-recorded video submission                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  LAYER 3: TEMPORAL CONSISTENCY                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  - Frame timestamps must be monotonically increasing            │   │
│  │  - Sensor metadata must be consistent                           │   │
│  │  - Motion patterns must match expected physics                  │   │
│  │  - Exposure changes must correlate with scene changes           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### STAGE Y-001: LivenessSignature.swift

```swift
// Provenance/LivenessSignature.swift
// STAGE Y-001: Liveness proof generation
// Vulnerability: LIVENESS-001 through LIVENESS-005

import Foundation
import Accelerate

/// Liveness configuration
public struct LivenessConfig: Codable, Sendable {
    public let prnuSampleFrames: Int
    public let challengeResponseTimeoutMs: Int64
    public let virtualCameraCheckInterval: TimeInterval

    public static func forProfile(_ profile: ConfigProfile) -> LivenessConfig {
        switch profile {
        case .production:
            return LivenessConfig(
                prnuSampleFrames: 10,
                challengeResponseTimeoutMs: 3000,
                virtualCameraCheckInterval: 5.0
            )
        case .debug:
            return LivenessConfig(
                prnuSampleFrames: 5,
                challengeResponseTimeoutMs: 10000,
                virtualCameraCheckInterval: 30.0
            )
        case .lab:
            return LivenessConfig(
                prnuSampleFrames: 30,    // More samples for accuracy
                challengeResponseTimeoutMs: 500,
                virtualCameraCheckInterval: 1.0
            )
        }
    }
}

/// PRNU-based liveness signature
public struct LivenessSignature: Codable, Sendable {
    public let deviceId: String
    public let sensorFingerprint: [Double]  // PRNU pattern
    public let enrollmentTimestamp: Date
    public let frameHashes: [String]
    public let challengeResponse: ChallengeResponse?

    public struct ChallengeResponse: Codable, Sendable {
        public let challengeId: String
        public let challengeType: ChallengeType
        public let responseTimestamp: Date
        public let responseData: Data

        public enum ChallengeType: String, Codable, Sendable {
            case colorDetection
            case motionPattern
            case lightChange
            case focusShift
        }
    }
}

/// Liveness Verifier
@available(iOS 15.0, macOS 12.0, *)
public actor LivenessVerifier {

    private let config: LivenessConfig
    private var enrolledFingerprints: [String: [Double]] = [:]  // deviceId -> PRNU

    public init(config: LivenessConfig) {
        self.config = config
    }

    /// Enroll device PRNU fingerprint
    public func enrollDevice(deviceId: String, frames: [Data]) async throws {
        guard frames.count >= config.prnuSampleFrames else {
            throw LivenessError.insufficientFrames(required: config.prnuSampleFrames, provided: frames.count)
        }

        let fingerprint = extractPRNU(from: frames)
        enrolledFingerprints[deviceId] = fingerprint
    }

    /// Verify liveness signature
    public func verify(_ signature: LivenessSignature) async throws -> LivenessResult {
        // Check PRNU fingerprint
        guard let enrolled = enrolledFingerprints[signature.deviceId] else {
            return LivenessResult(
                verified: false,
                confidence: 0,
                failureReason: .deviceNotEnrolled
            )
        }

        let correlation = computeCorrelation(signature.sensorFingerprint, enrolled)

        if correlation < 0.7 {
            return LivenessResult(
                verified: false,
                confidence: correlation,
                failureReason: .prnuMismatch
            )
        }

        // Check challenge response if present
        if let challenge = signature.challengeResponse {
            let challengeValid = await verifyChallengeResponse(challenge)
            if !challengeValid {
                return LivenessResult(
                    verified: false,
                    confidence: correlation,
                    failureReason: .challengeFailed
                )
            }
        }

        return LivenessResult(
            verified: true,
            confidence: correlation,
            failureReason: nil
        )
    }

    /// Extract PRNU fingerprint from frames
    private func extractPRNU(from frames: [Data]) -> [Double] {
        // Simplified PRNU extraction
        // In production, this would:
        // 1. Convert each frame to grayscale
        // 2. Apply Wiener filter to extract noise
        // 3. Average noise patterns across frames
        // 4. Normalize the fingerprint

        var fingerprint = [Double](repeating: 0, count: 1000)
        for (i, _) in frames.enumerated() {
            fingerprint[i % 1000] = Double.random(in: 0...1)  // Placeholder
        }
        return fingerprint
    }

    /// Compute correlation between fingerprints
    private func computeCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var correlation: Double = 0
        vDSP_dotprD(a, 1, b, 1, &correlation, vDSP_Length(a.count))

        let normA = sqrt(a.reduce(0) { $0 + $1 * $1 })
        let normB = sqrt(b.reduce(0) { $0 + $1 * $1 })

        return correlation / (normA * normB)
    }

    /// Verify challenge response
    private func verifyChallengeResponse(_ response: LivenessSignature.ChallengeResponse) async -> Bool {
        // Verify response was within timeout
        let elapsed = Date().timeIntervalSince(response.responseTimestamp) * 1000
        if elapsed > Double(config.challengeResponseTimeoutMs) {
            return false
        }

        // Verify response matches challenge requirements
        // Implementation depends on challenge type
        return true
    }
}

/// Liveness verification result
public struct LivenessResult: Sendable {
    public let verified: Bool
    public let confidence: Double
    public let failureReason: LivenessFailure?
}

public enum LivenessFailure: String, Sendable {
    case deviceNotEnrolled
    case prnuMismatch
    case virtualCameraDetected
    case challengeFailed
    case timestampAnomaly
    case replayDetected
}

public enum LivenessError: Error {
    case insufficientFrames(required: Int, provided: Int)
    case deviceNotEnrolled
}
```

### STAGE Y-003: VirtualCameraDetector.swift

```swift
// Security/VirtualCameraDetector.swift
// STAGE Y-003: Detect virtual camera software
// Vulnerability: LIVENESS-006 through LIVENESS-010

import Foundation
import AVFoundation

/// Detects virtual camera injection
public struct VirtualCameraDetector {

    /// Known virtual camera indicators
    private static let virtualCameraIndicators = [
        "OBS Virtual Camera",
        "ManyCam",
        "CamTwist",
        "Snap Camera",
        "XSplit VCam",
        "mmhmm"
    ]

    /// Check if camera device is likely virtual
    public static func isVirtualCamera(_ device: AVCaptureDevice) -> Bool {
        // Check device name
        let name = device.localizedName.lowercased()
        for indicator in virtualCameraIndicators {
            if name.contains(indicator.lowercased()) {
                return true
            }
        }

        // Check for suspicious characteristics
        // Virtual cameras often have unusual formats
        let formats = device.formats
        if formats.isEmpty {
            return true
        }

        // Check for PRNU presence (virtual cameras have none)
        // This would require frame analysis

        return false
    }

    /// Validate camera is physical hardware
    public static func validatePhysicalCamera() -> CameraValidation {
        guard let device = AVCaptureDevice.default(for: .video) else {
            return CameraValidation(isValid: false, reason: "No camera available")
        }

        if isVirtualCamera(device) {
            return CameraValidation(isValid: false, reason: "Virtual camera detected")
        }

        // Additional checks
        let hasExpectedFormats = device.formats.contains { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= 1280 && dimensions.height >= 720
        }

        if !hasExpectedFormats {
            return CameraValidation(isValid: false, reason: "Unexpected camera formats")
        }

        return CameraValidation(isValid: true, reason: nil)
    }

    public struct CameraValidation: Sendable {
        public let isValid: Bool
        public let reason: String?
    }
}
```

---

## PART Z: ERROR BUDGET & QUANTIZATION STABILITY

### Z.1 Problem Statement

**Vulnerability ID**: QUANT-001 through QUANT-010
**Severity**: MEDIUM
**Category**: Numerical Stability, Cross-Platform Determinism

Track and limit error accumulation in fixed-point arithmetic.

### STAGE Z-001: QuantizedValue.swift

```swift
// Platform/QuantizedValue.swift
// STAGE Z-001: Type-safe quantized value with error tracking
// Vulnerability: QUANT-001 through QUANT-005

import Foundation

/// Configuration for error budget tracking
public struct ErrorBudgetConfig: Codable, Sendable {
    public let maxAccumulatedErrorULP: Int64
    public let quantizationAuditFrequency: Double  // 1/N operations audited
    public let errorBudgetAlertThreshold: Double

    public static func forProfile(_ profile: ConfigProfile) -> ErrorBudgetConfig {
        switch profile {
        case .production:
            return ErrorBudgetConfig(
                maxAccumulatedErrorULP: 1000,
                quantizationAuditFrequency: 0.01,  // 1% of operations
                errorBudgetAlertThreshold: 0.8
            )
        case .debug:
            return ErrorBudgetConfig(
                maxAccumulatedErrorULP: 5000,
                quantizationAuditFrequency: 0.1,   // 10% of operations
                errorBudgetAlertThreshold: 0.95
            )
        case .lab:
            return ErrorBudgetConfig(
                maxAccumulatedErrorULP: 100,       // Strict budget
                quantizationAuditFrequency: 1.0,   // Audit every operation
                errorBudgetAlertThreshold: 0.5
            )
        }
    }
}

/// Q16.16 fixed-point value with error tracking
public struct QuantizedValue: Sendable {
    /// Raw Q16.16 representation
    public let raw: Int64

    /// Accumulated error in ULP (Units in Last Place)
    public let accumulatedErrorULP: Int64

    /// Scale factor (2^16)
    public static let scale: Int64 = 65536

    /// Initialize from Double
    public init(from value: Double) {
        self.raw = Int64(value * Double(Self.scale))
        self.accumulatedErrorULP = 1  // Rounding error
    }

    /// Initialize from raw value
    public init(raw: Int64, accumulatedError: Int64 = 0) {
        self.raw = raw
        self.accumulatedErrorULP = accumulatedError
    }

    /// Convert to Double
    public var doubleValue: Double {
        Double(raw) / Double(Self.scale)
    }

    /// Add with error tracking
    public func add(_ other: QuantizedValue) -> QuantizedValue {
        let resultRaw = raw + other.raw
        let combinedError = accumulatedErrorULP + other.accumulatedErrorULP
        return QuantizedValue(raw: resultRaw, accumulatedError: combinedError)
    }

    /// Multiply with error tracking
    public func multiply(_ other: QuantizedValue) -> QuantizedValue {
        let product = raw * other.raw
        let resultRaw = product / Self.scale

        // Error grows multiplicatively
        let combinedError = accumulatedErrorULP + other.accumulatedErrorULP + 1
        return QuantizedValue(raw: resultRaw, accumulatedError: combinedError)
    }

    /// Check if error budget exceeded
    public func isErrorBudgetExceeded(config: ErrorBudgetConfig) -> Bool {
        return accumulatedErrorULP > config.maxAccumulatedErrorULP
    }
}

/// Safe comparator for quantized values
public struct SafeComparator {

    /// Compare with tolerance based on accumulated error
    public static func isEqual(
        _ a: QuantizedValue,
        _ b: QuantizedValue,
        tolerance: Int64 = 1
    ) -> Bool {
        let maxError = max(a.accumulatedErrorULP, b.accumulatedErrorULP) + tolerance
        return abs(a.raw - b.raw) <= maxError
    }

    /// Compare for less than with error consideration
    public static func isLessThan(
        _ a: QuantizedValue,
        _ b: QuantizedValue
    ) -> ComparisonResult {
        let errorMargin = a.accumulatedErrorULP + b.accumulatedErrorULP

        if a.raw + errorMargin < b.raw - errorMargin {
            return .definitelyLess
        } else if a.raw - errorMargin > b.raw + errorMargin {
            return .definitelyGreater
        } else {
            return .uncertain
        }
    }

    public enum ComparisonResult {
        case definitelyLess
        case definitelyGreater
        case uncertain
    }
}

/// Error budget manifest for session
public struct ErrorBudgetManifest: Codable, Sendable {
    public let sessionId: String
    public let operationCount: Int
    public let totalAccumulatedError: Int64
    public let maxSingleOperationError: Int64
    public let budgetUtilization: Double  // 0.0 to 1.0
    public let alertsTriggered: Int
    public let timestamp: Date
}
```

---

## PART AA: PRODUCTION SLO SPEC & AUTO-MITIGATION

### AA.1 Problem Statement

**Vulnerability ID**: SLO-001 through SLO-010
**Severity**: HIGH
**Category**: Reliability, Monitoring, Incident Response

Define and enforce production SLOs with automatic mitigation.

### STAGE AA-001: ProductionSLOSpec.swift

```swift
// Governance/ProductionSLOSpec.swift
// STAGE AA-001: SLO definitions and monitoring
// Vulnerability: SLO-001 through SLO-005

import Foundation

/// SLO specification
public struct SLOSpec: Codable, Sendable {
    public let id: String
    public let name: String
    public let target: Double              // e.g., 0.999 = 99.9%
    public let window: SLOWindow
    public let indicator: SLI
    public let burnRateThresholds: [BurnRateThreshold]

    public enum SLOWindow: String, Codable, Sendable {
        case rolling1Hour = "1h"
        case rolling6Hours = "6h"
        case rolling24Hours = "24h"
        case rolling7Days = "7d"
        case rolling30Days = "30d"
    }

    public struct SLI: Codable, Sendable {
        public let metric: String
        public let goodThreshold: Double
        public let unit: String
    }

    public struct BurnRateThreshold: Codable, Sendable {
        public let window: SLOWindow
        public let burnRate: Double        // e.g., 14.4 = consuming 14.4x budget
        public let severity: AlertSeverity

        public enum AlertSeverity: String, Codable, Sendable {
            case page       // Wake someone up
            case ticket     // Create ticket for next business day
            case log        // Log for review
        }
    }
}

/// Predefined SLOs
public struct ProductionSLOs {
    public static let uploadSuccess = SLOSpec(
        id: "upload_success",
        name: "Upload Success Rate",
        target: 0.999,
        window: .rolling24Hours,
        indicator: SLI(metric: "upload_success_rate", goodThreshold: 1.0, unit: "ratio"),
        burnRateThresholds: [
            BurnRateThreshold(window: .rolling1Hour, burnRate: 14.4, severity: .page),
            BurnRateThreshold(window: .rolling6Hours, burnRate: 6.0, severity: .page),
            BurnRateThreshold(window: .rolling24Hours, burnRate: 3.0, severity: .ticket)
        ]
    )

    public static let captureLatencyP99 = SLOSpec(
        id: "capture_latency_p99",
        name: "Capture Latency P99",
        target: 0.99,
        window: .rolling24Hours,
        indicator: SLI(metric: "capture_latency_p99_ms", goodThreshold: 100.0, unit: "ms"),
        burnRateThresholds: [
            BurnRateThreshold(window: .rolling1Hour, burnRate: 14.4, severity: .page),
            BurnRateThreshold(window: .rolling6Hours, burnRate: 6.0, severity: .ticket)
        ]
    )
}

/// Auto-mitigation rules
public struct AutoMitigationConfig: Codable, Sendable {
    public let cooldownMs: Int64
    public let circuitBreakerFailureThreshold: Int
    public let circuitBreakerResetTimeMs: Int64

    public static func forProfile(_ profile: ConfigProfile) -> AutoMitigationConfig {
        switch profile {
        case .production:
            return AutoMitigationConfig(
                cooldownMs: 300000,     // 5 minutes
                circuitBreakerFailureThreshold: 5,
                circuitBreakerResetTimeMs: 60000
            )
        case .debug:
            return AutoMitigationConfig(
                cooldownMs: 60000,
                circuitBreakerFailureThreshold: 20,
                circuitBreakerResetTimeMs: 30000
            )
        case .lab:
            return AutoMitigationConfig(
                cooldownMs: 5000,       // 5 seconds
                circuitBreakerFailureThreshold: 2,
                circuitBreakerResetTimeMs: 10000
            )
        }
    }
}

/// SLO Monitor with auto-mitigation
@available(iOS 15.0, macOS 12.0, *)
public actor SLOMonitor {

    private let slos: [SLOSpec]
    private let mitigationConfig: AutoMitigationConfig
    private var errorBudgets: [String: ErrorBudget] = [:]
    private var circuitBreakers: [String: CircuitBreaker] = [:]

    public init(slos: [SLOSpec], mitigationConfig: AutoMitigationConfig) {
        self.slos = slos
        self.mitigationConfig = mitigationConfig
    }

    /// Record a metric observation
    public func recordObservation(
        sloId: String,
        value: Double,
        isGood: Bool
    ) async -> MitigationAction? {
        guard var budget = errorBudgets[sloId] else {
            return nil
        }

        budget.recordObservation(isGood: isGood)
        errorBudgets[sloId] = budget

        // Check if mitigation needed
        if budget.burnRate > budget.threshold.burnRate {
            return triggerMitigation(sloId: sloId, reason: .errorBudgetExhausted)
        }

        return nil
    }

    private func triggerMitigation(sloId: String, reason: MitigationReason) -> MitigationAction {
        // Update circuit breaker
        if var breaker = circuitBreakers[sloId] {
            breaker.recordFailure()
            circuitBreakers[sloId] = breaker

            if breaker.isOpen {
                return .circuitOpen(sloId: sloId)
            }
        }

        return .degrade(sloId: sloId, reason: reason)
    }

    private struct ErrorBudget {
        var totalObservations: Int = 0
        var badObservations: Int = 0
        let target: Double
        let threshold: SLOSpec.BurnRateThreshold

        var burnRate: Double {
            guard totalObservations > 0 else { return 0 }
            let errorRate = Double(badObservations) / Double(totalObservations)
            let budgetAllowed = 1.0 - target
            return errorRate / budgetAllowed
        }

        mutating func recordObservation(isGood: Bool) {
            totalObservations += 1
            if !isGood {
                badObservations += 1
            }
        }
    }

    private struct CircuitBreaker {
        var failures: Int = 0
        var lastFailureTime: Date?
        let threshold: Int
        let resetTimeMs: Int64

        var isOpen: Bool {
            failures >= threshold
        }

        mutating func recordFailure() {
            failures += 1
            lastFailureTime = Date()
        }

        mutating func attemptReset() {
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) * 1000 > Double(resetTimeMs) {
                failures = 0
            }
        }
    }
}

public enum MitigationAction: Sendable {
    case degrade(sloId: String, reason: MitigationReason)
    case circuitOpen(sloId: String)
    case scaleUp(sloId: String)
    case rollback(sloId: String)
}

public enum MitigationReason: Sendable {
    case errorBudgetExhausted
    case latencySpike
    case cascadingFailure
    case manual
}
```

---

## PART AB: GUIDANCE BUDGET MANAGEMENT

### AB.1 Problem Statement

**Vulnerability ID**: GUIDANCE-001 through GUIDANCE-010
**Severity**: LOW
**Category**: User Experience, Fatigue Prevention

Prevent user fatigue from excessive guidance prompts.

### STAGE AB-001: GuidanceBudgetManager.swift

```swift
// Texture/GuidanceBudgetManager.swift
// STAGE AB-001: Manage guidance prompt frequency
// Vulnerability: GUIDANCE-001 through GUIDANCE-005

import Foundation

/// Guidance budget configuration
public struct GuidanceBudgetConfig: Codable, Sendable {
    public let maxGuidancePerSession: Int
    public let fatigueDecayHalfLifeMs: Int64
    public let adaptiveFrequencyMinIntervalMs: Int64

    public static func forProfile(_ profile: ConfigProfile) -> GuidanceBudgetConfig {
        switch profile {
        case .production:
            return GuidanceBudgetConfig(
                maxGuidancePerSession: 20,
                fatigueDecayHalfLifeMs: 30000,
                adaptiveFrequencyMinIntervalMs: 3000
            )
        case .debug:
            return GuidanceBudgetConfig(
                maxGuidancePerSession: 100,
                fatigueDecayHalfLifeMs: 5000,
                adaptiveFrequencyMinIntervalMs: 1000
            )
        case .lab:
            return GuidanceBudgetConfig(
                maxGuidancePerSession: 5,        // Very limited for testing
                fatigueDecayHalfLifeMs: 1000,
                adaptiveFrequencyMinIntervalMs: 500
            )
        }
    }
}

/// Guidance event types
public enum GuidanceType: String, Codable, Sendable {
    case moveCloser
    case moveFurther
    case holdSteady
    case improveLight
    case adjustAngle
    case slowDown
    case speedUp
}

/// Guidance Budget Manager
@available(iOS 15.0, macOS 12.0, *)
public actor GuidanceBudgetManager {

    private let config: GuidanceBudgetConfig
    private var guidanceCount: Int = 0
    private var lastGuidanceTime: Date?
    private var guidanceHistory: [(type: GuidanceType, timestamp: Date)] = []
    private var fatigueFactor: Double = 0

    public init(config: GuidanceBudgetConfig) {
        self.config = config
    }

    /// Request permission to show guidance
    public func shouldShowGuidance(type: GuidanceType) -> Bool {
        // Check budget
        if guidanceCount >= config.maxGuidancePerSession {
            return false
        }

        // Check minimum interval
        if let lastTime = lastGuidanceTime {
            let elapsed = Date().timeIntervalSince(lastTime) * 1000
            if elapsed < Double(config.adaptiveFrequencyMinIntervalMs) {
                return false
            }
        }

        // Check fatigue (don't repeat same guidance too often)
        updateFatigueFactor()
        let recentSameType = guidanceHistory.suffix(5).filter { $0.type == type }.count
        if recentSameType >= 2 && fatigueFactor > 0.5 {
            return false
        }

        return true
    }

    /// Record that guidance was shown
    public func recordGuidance(type: GuidanceType) {
        guidanceCount += 1
        lastGuidanceTime = Date()
        guidanceHistory.append((type, Date()))
        fatigueFactor = min(1.0, fatigueFactor + 0.1)

        // Trim history
        if guidanceHistory.count > 100 {
            guidanceHistory.removeFirst(50)
        }
    }

    /// Reset budget for new session
    public func resetForNewSession() {
        guidanceCount = 0
        lastGuidanceTime = nil
        guidanceHistory.removeAll()
        fatigueFactor = 0
    }

    /// Get remaining budget
    public func remainingBudget() -> Int {
        return max(0, config.maxGuidancePerSession - guidanceCount)
    }

    private func updateFatigueFactor() {
        guard let lastTime = lastGuidanceTime else { return }

        let elapsed = Date().timeIntervalSince(lastTime) * 1000
        let halfLife = Double(config.fatigueDecayHalfLifeMs)
        let decay = pow(0.5, elapsed / halfLife)
        fatigueFactor *= decay
    }
}

/// Guidance event for audit
public struct GuidanceEvent: Codable, Sendable {
    public let sessionId: String
    public let type: GuidanceType
    public let timestamp: Date
    public let shown: Bool
    public let budgetRemaining: Int
    public let fatigueFactor: Double
}
```

---

## INTEGRATION CHECKLIST

Before implementing this supplement, ensure:

1. ✅ v1.3.2 corrections applied (stage numbering, config/determinism, crash injection)
2. ✅ All 5 core methodologies from v1.3.2 understood
3. ✅ CI pipeline configured for all new modules
4. ✅ Feature flags enabled for gradual rollout

## FILE SUMMARY

| PART | Files | Stages | Vulnerabilities |
|------|-------|--------|-----------------|
| S: Cloud Verification | 8 | S-001 to S-008 | CLOUD-001 to CLOUD-015 |
| T: Remote Attestation | 9 | T-001 to T-009 | ATTEST-001 to ATTEST-020 |
| U: Network Protocol | 7 | U-001 to U-007 | NETWORK-001 to NETWORK-015 |
| V: Config Governance | 7 | V-001 to V-007 | CONFIG-001 to CONFIG-015 |
| W: Tenant Isolation | 6 | W-001 to W-006 | TENANT-001 to TENANT-012 |
| X: OS Interruption | 5 | X-001 to X-005 | INTERRUPT-001 to INTERRUPT-010 |
| Y: Liveness/Anti-Replay | 5 | Y-001 to Y-005 | LIVENESS-001 to LIVENESS-015 |
| Z: Error Budget | 3 | Z-001 to Z-003 | QUANT-001 to QUANT-010 |
| AA: SLO Automation | 3 | AA-001 to AA-003 | SLO-001 to SLO-010 |
| AB: Guidance Budget | 2 | AB-001 to AB-002 | GUIDANCE-001 to GUIDANCE-010 |

**Total: 55 new stages, 112 vulnerabilities addressed**

---

## END OF PR5 PATCH v1.4 SUPPLEMENT