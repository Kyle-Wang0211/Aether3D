# PR5 PATCH v1.5 SUPPLEMENT - SYSTEM PERIMETER HARDENING

> **Document Type**: Cursor Implementation Specification
> **Version**: 1.5.0-SUPPLEMENT
> **Extends**: PR5_PATCH_V1_4_SUPPLEMENT.md + pr5_v1.2_bulletproof_patch Plan
> **Total New Vulnerabilities Addressed**: 95 additional (315 total with v1.4)
> **New Modules**: 8 Major Domains (PART AC through PART AJ)
> **Focus**: System Perimeter - Supply Chain, Secrets, AuthZ, Abuse, DR, Privacy Attacks, Consent, Incident Response

---

## DOCUMENT PURPOSE

This supplement addresses the **"system outer perimeter"** - security domains that exist OUTSIDE the capture pipeline but critically determine production survivability. Without these, supply chain attacks, key compromise, AuthZ bypass, DDoS, disaster events, inference attacks, consent violations, and incident mishandling can instantly negate all pipeline hardening.

### Why This Matters

The v1.4 patch hardened:
- ✅ Capture pipeline internals (Perception → Decision → Ledger)
- ✅ Client-server verification (Cloud Mirror, Remote Attestation)
- ✅ Network integrity (Exactly-once, Idempotency)
- ✅ Config governance (Kill Switch, Feature Flags)

But production systems ALSO fail from:
- ❌ Compromised dependencies poisoning signed builds
- ❌ Leaked/mismanaged cryptographic keys
- ❌ Authorization bypass across tenant boundaries
- ❌ DDoS / abuse draining resources and budgets
- ❌ Disaster events with no tested recovery path
- ❌ Inference attacks extracting PII from "anonymized" data
- ❌ Missing/forged consent evidence for compliance audits
- ❌ Incident response paralysis during active attacks

This supplement closes those gaps.

---

## ERRATA FOR v1.4 (CRITICAL FIXES)

Before implementing this supplement, apply these corrections to v1.4's extreme values:

### ERRATA 1: Network Retry Count (Anti-Pattern Fix)

```
PROBLEM: U: maxRetryAttempts = 50 (lab) is ANTI-SECURITY
- Creates retry storms masking real network issues
- Amplifies DDoS impact
- Explodes costs and queue depths

CORRECTION:
- lab: maxRetryAttempts = 2 (stricter than production!)
- Use fault injection to TEST network failures, don't mask them with retries
- Add: maxRetryAttempts_P0_incident = 0 (disable retries during incidents)
```

### ERRATA 2: Audit Retention (Provability Violation)

```
PROBLEM: W: auditRetentionDays = 1 (lab) breaks provability
- Lab is a VERIFICATION environment, needs MORE audit data, not less
- 1-day retention prevents post-hoc analysis of test runs

CORRECTION:
- lab: auditRetentionDays = 30 (longer than debug for analysis)
- debug: auditRetentionDays = 7
- production: auditRetentionDays = 2555 (7 years, compliance)
```

### ERRATA 3: Memory Warning Threshold (Platform Mismatch)

```
PROBLEM: X: lowMemoryWarningMB = 10 (lab) is platform-invalid
- iOS/Android low-memory callbacks don't fire at precise MB values
- Single threshold causes false positives/negatives

CORRECTION:
- Replace single threshold with THREE-SIGNAL system:
  1. systemLowMemorySignal: Boolean (OS callback)
  2. workingSetTrendMB: [Int] (5-sample moving average)
  3. consecutiveWarningCount: Int (debounce)
- Lab config: workingSetTrendThreshold = 50MB, consecutiveWarningCount = 2
```

---

## ARCHITECTURE OVERVIEW: 8 NEW MODULES

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PR5 v1.5 SYSTEM PERIMETER ARCHITECTURE                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AC: SUPPLY CHAIN SECURITY                   │   │
│  │  BuildProvenanceManifest ←→ SBOMGenerator ←→ DependencyLockPolicy   │   │
│  │  [SLSA Level 3] [Reproducible Builds] [Artifact Signing]            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Signs                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AD: SECRETS & KEY MANAGEMENT                │   │
│  │  KeyHierarchySpec ←→ KMSAdapter ←→ KeyRevocationService             │   │
│  │  [HSM/KMS] [Envelope Encryption] [Key Hierarchy] [Break-Glass]      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Authenticates                          │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AE: IDENTITY & AUTHORIZATION                │   │
│  │  AuthZModel ←→ AuthZEnforcer ←→ AuthZProofEmitter                   │   │
│  │  [ABAC] [Least Privilege] [Resource Tree] [Audit Proof]             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Protects                               │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AF: ABUSE & COST PROTECTION                 │   │
│  │  AbuseScoringModel ←→ RateLimitPolicy ←→ CostBudgetSpec             │   │
│  │  [Token Bucket] [Multi-Layer Limits] [Cost Guards] [DDoS Shield]    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Recovers                               │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AG: BACKUP & DISASTER RECOVERY              │   │
│  │  BackupPolicy ←→ DRRunbook ←→ BackupAwareDeletionProof              │   │
│  │  [RPO/RTO] [Multi-Region] [DR Drills] [Deletion + Backup Conflict]  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Anonymizes                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AH: PRIVACY ATTACK SURFACE                  │   │
│  │  InferenceRiskScorer ←→ TrajectoryAnonymizer ←→ TrainingDataGate    │   │
│  │  [Membership Inference] [Location Re-ID] [Model Privacy]            │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Consents                               │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AI: CONSENT & POLICY UX                     │   │
│  │  ConsentReceipt ←→ ConsentVersionRegistry ←→ WithdrawalEnforcer     │   │
│  │  [Verifiable Consent] [Version Binding] [Withdrawal Propagation]    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ↓ Responds                               │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    PART AJ: INCIDENT RESPONSE & RED TEAM            │   │
│  │  IncidentRunbook ←→ RedTeamScenarioSuite ←→ PostmortemToGateCompiler│   │
│  │  [P0/P1/P2 Severity] [Auto-Containment] [Attack→Test→Gate Loop]     │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## EXTREME VALUES REFERENCE TABLE (LAB PROFILE)

| Module | Parameter | Production | Debug | Lab (Extreme) |
|--------|-----------|------------|-------|---------------|
| AC: Supply Chain | unpinnedDependencyPolicy | warn | allow | **hard-fail** |
| AC: Supply Chain | sbomMatchRequired | true | false | **true** |
| AC: Supply Chain | maxBuildVarianceBytes | 1024 | 10240 | **0** (byte-exact) |
| AC: Supply Chain | slsaLevelRequired | 2 | 1 | **3** |
| AD: Secrets | ephemeralSessionKeyTTLSec | 3600 | 7200 | **60** |
| AD: Secrets | maxKeyAgeForSigningSec | 86400 | 172800 | **300** |
| AD: Secrets | breakGlassRequires2Approvers | true | false | **true** |
| AD: Secrets | revocationPropagationP99Sec | 60 | 300 | **5** |
| AE: AuthZ | defaultDeny | true | false | **true** |
| AE: AuthZ | crossProjectAccess | deny | warn | **hard-deny** |
| AE: AuthZ | privilegedActionReauthSec | 300 | 3600 | **60** |
| AF: Abuse | maxUploadSessionsPerUserPerHour | 10 | 100 | **1** |
| AF: Abuse | maxActiveJobsPerTenant | 50 | 200 | **2** |
| AF: Abuse | mirrorVerificationCPUBudgetMsP95 | 100 | 500 | **10** |
| AF: Abuse | costSpikeAutoMitigatePercent | 50 | 100 | **20** |
| AG: DR | rpoMinutes | 15 | 60 | **5** |
| AG: DR | rtoMinutes | 30 | 120 | **15** |
| AG: DR | deletionProofMustIncludeBackup | true | false | **true** |
| AG: DR | drDrillFrequencyDays | 90 | 180 | **7** |
| AH: Privacy | maxLocationReidentificationRisk | 0.10 | 0.25 | **0.05** |
| AH: Privacy | trajectoryDownsampleFactor | 2 | 1 | **4** |
| AH: Privacy | highRiskDataPolicy | warn | allow | **localOnly+forbidUpload** |
| AI: Consent | consentRequiredForUpload | true | false | **true** |
| AI: Consent | consentReceiptRetentionDays | 2555 | 365 | **2555** |
| AI: Consent | withdrawalEffectiveP99Sec | 60 | 300 | **5** |
| AJ: Incident | p0DetectToContainP99Sec | 300 | 600 | **30** |
| AJ: Incident | autoKillSwitchOnP0 | true | false | **true** |
| AJ: Incident | redTeamScenariosPerRelease | 5 | 2 | **20** |

---

## PART AC: SUPPLY CHAIN SECURITY & REPRODUCIBLE BUILD

### AC.1 Problem Statement

**Vulnerability ID**: SUPPLY-001 through SUPPLY-015
**Severity**: CRITICAL
**Category**: Build Integrity, Dependency Poisoning, Artifact Tampering

Current gaps:
1. No SBOM (Software Bill of Materials) generation or verification
2. Dependencies not pinned to exact versions/hashes
3. Builds not reproducible (same source → different binary)
4. Artifacts not cryptographically signed with provenance
5. No CI enforcement of supply chain policies

**Attack Vectors**:
- Dependency confusion attacks (typosquatting, namespace hijacking)
- Compromised build server injecting malware
- Malicious maintainer pushing backdoored update
- Man-in-the-middle during dependency download

### AC.2 Solution Architecture

Implement [SLSA Level 3](https://slsa.dev/spec/v1.2/) compliant supply chain:
- Hermetic builds with pinned dependencies
- Cryptographic provenance attestation
- SBOM generation and verification
- Artifact signing with transparency log

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    SUPPLY CHAIN SECURITY FLOW                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  SOURCE CODE                                                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Repository with signed commits                                  │   │
│  │ Branch protection rules                                          │   │
│  │ Required reviews                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │                                             │
│                           ▼                                             │
│  DEPENDENCY RESOLUTION                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ DependencyLockPolicy.swift                                       │   │
│  │ • Package.resolved with SHA-256 hashes                           │   │
│  │ • Allowlist of approved packages                                 │   │
│  │ • Automatic CVE scanning                                         │   │
│  │ • UNPINNED_DEPENDENCY → hard-fail (lab)                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │                                             │
│                           ▼                                             │
│  HERMETIC BUILD                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ BuildProvenanceManifest.swift                                    │   │
│  │ • Isolated build environment (no network after deps fetched)    │   │
│  │ • Captured: toolchain version, flags, environment               │   │
│  │ • Reproducibility: same inputs → byte-identical output          │   │
│  │ • maxBuildVarianceBytes = 0 (lab)                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │                                             │
│                           ▼                                             │
│  SBOM GENERATION                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ SBOMGenerator.swift + SBOMVerifier.swift                         │   │
│  │ • SPDX 2.3 or CycloneDX 1.5 format                              │   │
│  │ • All transitive dependencies listed                             │   │
│  │ • License compliance check                                       │   │
│  │ • Vulnerability cross-reference (NVD, OSV)                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │                                             │
│                           ▼                                             │
│  ARTIFACT SIGNING                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ ArtifactSignatureVerifier.swift                                  │   │
│  │ • Sign with Sigstore/in-toto attestation                        │   │
│  │ • Publish to transparency log (Rekor)                            │   │
│  │ • SLSA provenance document attached                              │   │
│  │ • Verify before deployment                                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AC.3 Implementation Files

```
New Files:
├── Build/
│   ├── BuildProvenanceManifest.swift       (STAGE AC-001)
│   ├── SBOMGenerator.swift                 (STAGE AC-002)
│   ├── SBOMVerifier.swift                  (STAGE AC-003)
│   ├── DependencyLockPolicy.swift          (STAGE AC-004)
│   └── ArtifactSignatureVerifier.swift     (STAGE AC-005)
├── Governance/
│   └── SupplyChainGate.swift               (STAGE AC-006)
└── Tests/
    └── SupplyChainSecurityTests.swift      (STAGE AC-007)
```

### STAGE AC-001: BuildProvenanceManifest.swift

```swift
// Build/BuildProvenanceManifest.swift
// STAGE AC-001: SLSA-compliant build provenance manifest
// Vulnerability: SUPPLY-001, SUPPLY-002, SUPPLY-003
// Reference: https://slsa.dev/spec/v1.2/

import Foundation
import CryptoKit

/// Configuration for build provenance
public struct BuildProvenanceConfig: Codable, Sendable {
    /// Maximum allowed variance in build output (bytes)
    /// 0 = byte-exact reproducibility required
    public let maxBuildVarianceBytes: Int

    /// Required SLSA level (1, 2, or 3)
    public let slsaLevelRequired: Int

    /// Whether to enforce hermetic builds (no network after dep fetch)
    public let enforceHermeticBuild: Bool

    /// Whether unpinned dependencies cause hard failure
    public let unpinnedDependencyPolicy: UnpinnedPolicy

    public enum UnpinnedPolicy: String, Codable, Sendable {
        case allow      // Allow (dangerous)
        case warn       // Warn but continue
        case hardFail   // Block build entirely
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> BuildProvenanceConfig {
        switch profile {
        case .production:
            return BuildProvenanceConfig(
                maxBuildVarianceBytes: 1024,      // Allow minor variance
                slsaLevelRequired: 2,
                enforceHermeticBuild: true,
                unpinnedDependencyPolicy: .warn
            )
        case .debug:
            return BuildProvenanceConfig(
                maxBuildVarianceBytes: 10240,
                slsaLevelRequired: 1,
                enforceHermeticBuild: false,
                unpinnedDependencyPolicy: .allow
            )
        case .lab:
            return BuildProvenanceConfig(
                maxBuildVarianceBytes: 0,         // EXTREME: byte-exact
                slsaLevelRequired: 3,             // EXTREME: highest SLSA
                enforceHermeticBuild: true,
                unpinnedDependencyPolicy: .hardFail  // EXTREME: no unpinned
            )
        }
    }
}

/// SLSA Build Provenance following in-toto attestation format
/// Reference: https://slsa.dev/spec/draft/build-provenance
public struct BuildProvenanceManifest: Codable, Sendable {

    // MARK: - Provenance Metadata

    /// Unique identifier for this build
    public let buildId: String

    /// Timestamp when build started
    public let buildStartedOn: Date

    /// Timestamp when build finished
    public let buildFinishedOn: Date

    /// SLSA build level achieved (1, 2, or 3)
    public let slsaBuildLevel: Int

    // MARK: - Build Definition

    /// Git repository URL
    public let sourceRepository: String

    /// Git commit SHA (full 40-char)
    public let sourceCommitSHA: String

    /// Git ref (branch/tag)
    public let sourceRef: String

    /// Build configuration file path
    public let buildConfigPath: String

    /// Build configuration hash
    public let buildConfigHash: String

    // MARK: - Build Environment

    /// Build platform identifier
    public let builderIdentity: BuilderIdentity

    /// Toolchain versions
    public let toolchain: ToolchainManifest

    /// Environment variables (sanitized - no secrets)
    public let environmentHash: String

    /// Whether build was hermetic (isolated after dep fetch)
    public let wasHermetic: Bool

    // MARK: - Dependencies

    /// All resolved dependencies with hashes
    public let resolvedDependencies: [ResolvedDependency]

    /// Total dependency count
    public let dependencyCount: Int

    /// Whether all dependencies were pinned
    public let allDependenciesPinned: Bool

    // MARK: - Output Artifacts

    /// Output artifact hashes
    public let outputArtifacts: [OutputArtifact]

    /// Reproducibility verification result
    public let reproducibilityVerified: Bool

    /// Variance from reference build (bytes)
    public let buildVarianceBytes: Int

    // MARK: - Signature

    /// Signature over manifest content
    public let signature: String

    /// Signing key identifier
    public let signingKeyId: String

    /// Timestamp of signature
    public let signedAt: Date

    // MARK: - Nested Types

    public struct BuilderIdentity: Codable, Sendable {
        public let platform: String          // "github-actions", "gitlab-ci", etc.
        public let runId: String
        public let runnerOS: String
        public let runnerArch: String
    }

    public struct ToolchainManifest: Codable, Sendable {
        public let swiftVersion: String
        public let xcodeVersion: String?
        public let clangVersion: String
        public let llvmVersion: String
        public let sdkVersion: String
    }

    public struct ResolvedDependency: Codable, Sendable {
        public let name: String
        public let version: String
        public let exactHash: String          // SHA-256 of package
        public let source: DependencySource
        public let isPinned: Bool
        public let transitiveDepth: Int       // 0 = direct, 1+ = transitive

        public enum DependencySource: String, Codable, Sendable {
            case swiftPackageManager
            case cocoapods
            case carthage
            case vendored
        }
    }

    public struct OutputArtifact: Codable, Sendable {
        public let name: String
        public let path: String
        public let sha256: String
        public let sizeBytes: Int
        public let artifactType: ArtifactType

        public enum ArtifactType: String, Codable, Sendable {
            case executable
            case framework
            case staticLibrary
            case xcframework
            case appBundle
        }
    }
}

/// Build Provenance Generator
@available(iOS 15.0, macOS 12.0, *)
public actor BuildProvenanceGenerator {

    private let config: BuildProvenanceConfig

    public init(config: BuildProvenanceConfig) {
        self.config = config
    }

    /// Generate provenance manifest for current build
    public func generate(
        sourceCommit: String,
        sourceRepo: String,
        sourceRef: String,
        dependencies: [BuildProvenanceManifest.ResolvedDependency],
        artifacts: [BuildProvenanceManifest.OutputArtifact],
        toolchain: BuildProvenanceManifest.ToolchainManifest,
        buildStarted: Date,
        buildFinished: Date,
        signingKey: P256.Signing.PrivateKey,
        signingKeyId: String
    ) throws -> BuildProvenanceManifest {

        // Check unpinned dependency policy
        let unpinnedDeps = dependencies.filter { !$0.isPinned }
        if !unpinnedDeps.isEmpty {
            switch config.unpinnedDependencyPolicy {
            case .hardFail:
                throw ProvenanceError.unpinnedDependenciesFound(unpinnedDeps.map { $0.name })
            case .warn:
                print("WARNING: Unpinned dependencies: \(unpinnedDeps.map { $0.name })")
            case .allow:
                break
            }
        }

        // Determine SLSA level achieved
        let slsaLevel = calculateSLSALevel(
            allPinned: unpinnedDeps.isEmpty,
            hermetic: config.enforceHermeticBuild
        )

        if slsaLevel < config.slsaLevelRequired {
            throw ProvenanceError.slsaLevelNotMet(required: config.slsaLevelRequired, achieved: slsaLevel)
        }

        let buildId = UUID().uuidString

        // Create manifest (without signature)
        var manifest = BuildProvenanceManifest(
            buildId: buildId,
            buildStartedOn: buildStarted,
            buildFinishedOn: buildFinished,
            slsaBuildLevel: slsaLevel,
            sourceRepository: sourceRepo,
            sourceCommitSHA: sourceCommit,
            sourceRef: sourceRef,
            buildConfigPath: "Package.swift",
            buildConfigHash: "placeholder",
            builderIdentity: captureBuilderIdentity(),
            toolchain: toolchain,
            environmentHash: hashEnvironment(),
            wasHermetic: config.enforceHermeticBuild,
            resolvedDependencies: dependencies,
            dependencyCount: dependencies.count,
            allDependenciesPinned: unpinnedDeps.isEmpty,
            outputArtifacts: artifacts,
            reproducibilityVerified: false,  // Set after verification
            buildVarianceBytes: 0,
            signature: "",
            signingKeyId: signingKeyId,
            signedAt: Date()
        )

        // Sign the manifest
        let contentToSign = try JSONEncoder().encode(manifest)
        let signature = try signingKey.signature(for: contentToSign)
        manifest = BuildProvenanceManifest(
            buildId: manifest.buildId,
            buildStartedOn: manifest.buildStartedOn,
            buildFinishedOn: manifest.buildFinishedOn,
            slsaBuildLevel: manifest.slsaBuildLevel,
            sourceRepository: manifest.sourceRepository,
            sourceCommitSHA: manifest.sourceCommitSHA,
            sourceRef: manifest.sourceRef,
            buildConfigPath: manifest.buildConfigPath,
            buildConfigHash: manifest.buildConfigHash,
            builderIdentity: manifest.builderIdentity,
            toolchain: manifest.toolchain,
            environmentHash: manifest.environmentHash,
            wasHermetic: manifest.wasHermetic,
            resolvedDependencies: manifest.resolvedDependencies,
            dependencyCount: manifest.dependencyCount,
            allDependenciesPinned: manifest.allDependenciesPinned,
            outputArtifacts: manifest.outputArtifacts,
            reproducibilityVerified: manifest.reproducibilityVerified,
            buildVarianceBytes: manifest.buildVarianceBytes,
            signature: signature.derRepresentation.base64EncodedString(),
            signingKeyId: signingKeyId,
            signedAt: Date()
        )

        return manifest
    }

    /// Verify reproducibility by comparing with reference build
    public func verifyReproducibility(
        manifest: BuildProvenanceManifest,
        referenceArtifacts: [BuildProvenanceManifest.OutputArtifact]
    ) throws -> ReproducibilityResult {

        var totalVariance = 0
        var mismatches: [(artifact: String, expected: String, actual: String)] = []

        for artifact in manifest.outputArtifacts {
            guard let reference = referenceArtifacts.first(where: { $0.name == artifact.name }) else {
                mismatches.append((artifact.name, "missing", artifact.sha256))
                continue
            }

            if artifact.sha256 != reference.sha256 {
                // Calculate byte difference (if size available)
                let sizeDiff = abs(artifact.sizeBytes - reference.sizeBytes)
                totalVariance += sizeDiff
                mismatches.append((artifact.name, reference.sha256, artifact.sha256))
            }
        }

        let passed = totalVariance <= config.maxBuildVarianceBytes && mismatches.isEmpty

        return ReproducibilityResult(
            passed: passed,
            varianceBytes: totalVariance,
            maxAllowedVariance: config.maxBuildVarianceBytes,
            mismatches: mismatches
        )
    }

    // MARK: - Private Helpers

    private func calculateSLSALevel(allPinned: Bool, hermetic: Bool) -> Int {
        // SLSA Level 3 requires:
        // - Hermetic, reproducible builds
        // - Signed provenance from trusted builder
        // - Non-falsifiable (builder isolation)

        if hermetic && allPinned {
            return 3
        } else if allPinned {
            return 2
        } else {
            return 1
        }
    }

    private func captureBuilderIdentity() -> BuildProvenanceManifest.BuilderIdentity {
        return BuildProvenanceManifest.BuilderIdentity(
            platform: ProcessInfo.processInfo.environment["CI_PLATFORM"] ?? "local",
            runId: ProcessInfo.processInfo.environment["CI_RUN_ID"] ?? UUID().uuidString,
            runnerOS: ProcessInfo.processInfo.operatingSystemVersionString,
            runnerArch: ProcessInfo.processInfo.machineArchitecture
        )
    }

    private func hashEnvironment() -> String {
        // Hash sanitized environment (exclude secrets)
        let safeVars = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.contains("SECRET") && !key.contains("TOKEN") && !key.contains("KEY")
        }
        let sorted = safeVars.sorted { $0.key < $1.key }
        let content = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(content.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

/// Reproducibility verification result
public struct ReproducibilityResult: Sendable {
    public let passed: Bool
    public let varianceBytes: Int
    public let maxAllowedVariance: Int
    public let mismatches: [(artifact: String, expected: String, actual: String)]
}

/// Provenance errors
public enum ProvenanceError: Error, LocalizedError {
    case unpinnedDependenciesFound([String])
    case slsaLevelNotMet(required: Int, achieved: Int)
    case signatureVerificationFailed
    case reproducibilityFailed(variance: Int, max: Int)

    public var errorDescription: String? {
        switch self {
        case .unpinnedDependenciesFound(let deps):
            return "Unpinned dependencies found: \(deps.joined(separator: ", "))"
        case .slsaLevelNotMet(let required, let achieved):
            return "SLSA level \(required) required, but only achieved level \(achieved)"
        case .signatureVerificationFailed:
            return "Build provenance signature verification failed"
        case .reproducibilityFailed(let variance, let max):
            return "Build reproducibility failed: \(variance) bytes variance exceeds max \(max)"
        }
    }
}

// Extension for ProcessInfo
extension ProcessInfo {
    var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
```

### STAGE AC-002: SBOMGenerator.swift

```swift
// Build/SBOMGenerator.swift
// STAGE AC-002: Software Bill of Materials generator
// Vulnerability: SUPPLY-004, SUPPLY-005
// Reference: https://spdx.dev/, https://cyclonedx.org/

import Foundation

/// SBOM format options
public enum SBOMFormat: String, Codable, Sendable {
    case spdx23 = "SPDX-2.3"
    case cyclonedx15 = "CycloneDX-1.5"
}

/// Software Bill of Materials
public struct SBOM: Codable, Sendable {
    public let format: SBOMFormat
    public let version: String
    public let createdAt: Date
    public let toolName: String
    public let toolVersion: String

    /// Primary component (the application being built)
    public let primaryComponent: SBOMComponent

    /// All dependencies (direct and transitive)
    public let components: [SBOMComponent]

    /// Relationships between components
    public let relationships: [SBOMRelationship]

    /// Vulnerability matches (if scanned)
    public let vulnerabilities: [SBOMVulnerability]

    /// License summary
    public let licenseSummary: LicenseSummary

    public struct SBOMComponent: Codable, Sendable {
        public let name: String
        public let version: String
        public let purl: String                    // Package URL (standard format)
        public let sha256: String
        public let licenses: [String]
        public let supplier: String?
        public let downloadLocation: String?
    }

    public struct SBOMRelationship: Codable, Sendable {
        public let source: String                  // Component name
        public let target: String                  // Dependency name
        public let relationshipType: RelationshipType

        public enum RelationshipType: String, Codable, Sendable {
            case dependsOn = "DEPENDS_ON"
            case devDependsOn = "DEV_DEPENDENCY_OF"
            case buildToolOf = "BUILD_TOOL_OF"
        }
    }

    public struct SBOMVulnerability: Codable, Sendable {
        public let id: String                      // CVE ID or OSV ID
        public let severity: Severity
        public let affectedComponent: String
        public let fixedInVersion: String?
        public let description: String

        public enum Severity: String, Codable, Sendable {
            case critical
            case high
            case medium
            case low
            case unknown
        }
    }

    public struct LicenseSummary: Codable, Sendable {
        public let totalComponents: Int
        public let licenseBreakdown: [String: Int]  // License -> count
        public let hasIncompatibleLicenses: Bool
        public let incompatibleLicenses: [String]
    }
}

/// SBOM Generator
public actor SBOMGenerator {

    public func generate(
        projectName: String,
        projectVersion: String,
        dependencies: [BuildProvenanceManifest.ResolvedDependency],
        format: SBOMFormat = .cyclonedx15
    ) async -> SBOM {

        let components = dependencies.map { dep in
            SBOM.SBOMComponent(
                name: dep.name,
                version: dep.version,
                purl: "pkg:swift/\(dep.name)@\(dep.version)",
                sha256: dep.exactHash,
                licenses: [],  // Would be populated from package metadata
                supplier: nil,
                downloadLocation: nil
            )
        }

        let relationships = dependencies.filter { $0.transitiveDepth == 0 }.map { dep in
            SBOM.SBOMRelationship(
                source: projectName,
                target: dep.name,
                relationshipType: .dependsOn
            )
        }

        return SBOM(
            format: format,
            version: "1.0",
            createdAt: Date(),
            toolName: "PR5CaptureOptimization",
            toolVersion: projectVersion,
            primaryComponent: SBOM.SBOMComponent(
                name: projectName,
                version: projectVersion,
                purl: "pkg:swift/\(projectName)@\(projectVersion)",
                sha256: "",
                licenses: ["Proprietary"],
                supplier: "Company",
                downloadLocation: nil
            ),
            components: components,
            relationships: relationships,
            vulnerabilities: [],  // Would be populated by CVE scan
            licenseSummary: SBOM.LicenseSummary(
                totalComponents: components.count,
                licenseBreakdown: [:],
                hasIncompatibleLicenses: false,
                incompatibleLicenses: []
            )
        )
    }
}

/// SBOM Verifier - Verifies SBOM matches actual build
public actor SBOMVerifier {

    /// Verify SBOM matches resolved dependencies
    public func verify(
        sbom: SBOM,
        actualDependencies: [BuildProvenanceManifest.ResolvedDependency]
    ) -> SBOMVerificationResult {

        var missingInSBOM: [String] = []
        var extraInSBOM: [String] = []
        var hashMismatches: [(name: String, sbomHash: String, actualHash: String)] = []

        // Check each actual dependency is in SBOM
        for dep in actualDependencies {
            guard let sbomComponent = sbom.components.first(where: { $0.name == dep.name }) else {
                missingInSBOM.append(dep.name)
                continue
            }

            if sbomComponent.sha256 != dep.exactHash && !sbomComponent.sha256.isEmpty {
                hashMismatches.append((dep.name, sbomComponent.sha256, dep.exactHash))
            }
        }

        // Check for extra components in SBOM not in actual build
        let actualNames = Set(actualDependencies.map { $0.name })
        for component in sbom.components {
            if !actualNames.contains(component.name) && component.name != sbom.primaryComponent.name {
                extraInSBOM.append(component.name)
            }
        }

        let passed = missingInSBOM.isEmpty && extraInSBOM.isEmpty && hashMismatches.isEmpty

        return SBOMVerificationResult(
            passed: passed,
            missingInSBOM: missingInSBOM,
            extraInSBOM: extraInSBOM,
            hashMismatches: hashMismatches
        )
    }
}

public struct SBOMVerificationResult: Sendable {
    public let passed: Bool
    public let missingInSBOM: [String]
    public let extraInSBOM: [String]
    public let hashMismatches: [(name: String, sbomHash: String, actualHash: String)]
}
```

---

## PART AD: SECRETS & KEY MANAGEMENT HARDENING

### AD.1 Problem Statement

**Vulnerability ID**: SECRETS-001 through SECRETS-012
**Severity**: CRITICAL
**Category**: Key Hierarchy, HSM/KMS Integration, Key Lifecycle

Current gaps:
1. No formal key hierarchy (Root → Tenant → Dataset → Session)
2. Cloud-side keys may be in plain environment variables
3. No key usage constraints (encrypt-only vs sign-only)
4. No emergency revocation with fast propagation
5. No break-glass procedure with multi-person approval

### AD.2 Solution Architecture

Implement [envelope encryption](https://docs.cloud.google.com/docs/security/key-management-deep-dive) with HSM-backed root keys:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    KEY HIERARCHY ARCHITECTURE                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  LEVEL 0: ROOT KEY (HSM-Protected, Offline)                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • Stored in Hardware Security Module (AWS CloudHSM, Azure HSM)  │   │
│  │ • Never exported, never leaves HSM                               │   │
│  │ • Used ONLY to encrypt Tenant Master Keys                        │   │
│  │ • Rotation: Annually with overlap period                         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │ Encrypts                                    │
│                           ▼                                             │
│  LEVEL 1: TENANT MASTER KEY (Per-Tenant)                               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • One per tenant (customer isolation)                            │   │
│  │ • Encrypted by Root Key, stored in KMS                           │   │
│  │ • Used to encrypt Dataset Keys                                   │   │
│  │ • Rotation: Quarterly or on-demand                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │ Encrypts                                    │
│                           ▼                                             │
│  LEVEL 2: DATASET ENCRYPTION KEY (Per-Dataset)                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • One per capture dataset                                        │   │
│  │ • Encrypted by Tenant Master Key                                 │   │
│  │ • Used to encrypt Session Keys                                   │   │
│  │ • Rotation: Monthly                                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │ Encrypts                                    │
│                           ▼                                             │
│  LEVEL 3: SESSION EPHEMERAL KEY (Per-Session)                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • Generated fresh for each capture session                       │   │
│  │ • Encrypted by Dataset Key before storage                        │   │
│  │ • Short TTL (production: 1h, lab: 60s)                          │   │
│  │ • Auto-deleted after session completion                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  KEY USAGE CONSTRAINTS (Closed Set):                                   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • ENCRYPT_ONLY: Can only encrypt, cannot decrypt                 │   │
│  │ • DECRYPT_ONLY: Can only decrypt, cannot encrypt                 │   │
│  │ • SIGN_ONLY: Can only sign, cannot verify                        │   │
│  │ • VERIFY_ONLY: Can only verify, cannot sign                      │   │
│  │ • WRAP_ONLY: Can only wrap other keys                           │   │
│  │ • UNWRAP_ONLY: Can only unwrap other keys                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AD.3 Implementation Files

```
New Files:
├── Security/
│   ├── KeyHierarchySpec.swift              (STAGE AD-001)
│   ├── KeyUsageClosedSet.swift             (STAGE AD-002)
│   ├── EnvelopeEncryption.swift            (STAGE AD-003)
│   └── BreakGlassPolicy.swift              (STAGE AD-004)
├── Server/
│   ├── KMSAdapter.swift                    (STAGE AD-005)
│   └── KeyRevocationService.swift          (STAGE AD-006)
├── Audit/
│   └── KeyEventSchema.swift                (STAGE AD-007)
└── Tests/
    └── KeyManagementTests.swift            (STAGE AD-008)
```

### STAGE AD-001: KeyHierarchySpec.swift

```swift
// Security/KeyHierarchySpec.swift
// STAGE AD-001: Formal key hierarchy specification
// Vulnerability: SECRETS-001, SECRETS-002, SECRETS-003
// Reference: https://docs.cloud.google.com/docs/security/key-management-deep-dive

import Foundation

/// Configuration for key management
public struct KeyManagementConfig: Codable, Sendable {
    /// TTL for ephemeral session keys (seconds)
    public let ephemeralSessionKeyTTLSec: Int64

    /// Maximum age for signing keys (seconds)
    public let maxKeyAgeForSigningSec: Int64

    /// Whether break-glass requires 2 approvers
    public let breakGlassRequires2Approvers: Bool

    /// P99 latency target for revocation propagation (seconds)
    public let revocationPropagationP99Sec: Int64

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> KeyManagementConfig {
        switch profile {
        case .production:
            return KeyManagementConfig(
                ephemeralSessionKeyTTLSec: 3600,      // 1 hour
                maxKeyAgeForSigningSec: 86400,        // 24 hours
                breakGlassRequires2Approvers: true,
                revocationPropagationP99Sec: 60
            )
        case .debug:
            return KeyManagementConfig(
                ephemeralSessionKeyTTLSec: 7200,
                maxKeyAgeForSigningSec: 172800,
                breakGlassRequires2Approvers: false,
                revocationPropagationP99Sec: 300
            )
        case .lab:
            return KeyManagementConfig(
                ephemeralSessionKeyTTLSec: 60,        // EXTREME: 1 minute
                maxKeyAgeForSigningSec: 300,          // EXTREME: 5 minutes
                breakGlassRequires2Approvers: true,
                revocationPropagationP99Sec: 5        // EXTREME: 5 seconds
            )
        }
    }
}

/// Key hierarchy levels
public enum KeyHierarchyLevel: Int, Codable, Sendable, Comparable {
    case root = 0           // HSM-protected root
    case tenantMaster = 1   // Per-tenant master key
    case dataset = 2        // Per-dataset key
    case sessionEphemeral = 3  // Per-session ephemeral

    public static func < (lhs: KeyHierarchyLevel, rhs: KeyHierarchyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// What this level can encrypt
    public var canEncrypt: KeyHierarchyLevel? {
        switch self {
        case .root: return .tenantMaster
        case .tenantMaster: return .dataset
        case .dataset: return .sessionEphemeral
        case .sessionEphemeral: return nil  // Encrypts data, not keys
        }
    }
}

/// Key usage constraints (closed set)
public enum KeyUsage: String, Codable, Sendable, CaseIterable {
    case encryptOnly = "ENCRYPT_ONLY"
    case decryptOnly = "DECRYPT_ONLY"
    case signOnly = "SIGN_ONLY"
    case verifyOnly = "VERIFY_ONLY"
    case wrapOnly = "WRAP_ONLY"       // Wrap other keys
    case unwrapOnly = "UNWRAP_ONLY"   // Unwrap other keys

    /// Validate operation against usage constraint
    public func allows(operation: KeyOperation) -> Bool {
        switch (self, operation) {
        case (.encryptOnly, .encrypt), (.decryptOnly, .decrypt):
            return true
        case (.signOnly, .sign), (.verifyOnly, .verify):
            return true
        case (.wrapOnly, .wrapKey), (.unwrapOnly, .unwrapKey):
            return true
        default:
            return false
        }
    }
}

/// Key operations (closed set)
public enum KeyOperation: String, Codable, Sendable {
    case encrypt
    case decrypt
    case sign
    case verify
    case wrapKey
    case unwrapKey
    case derive
}

/// Key metadata
public struct KeyMetadata: Codable, Sendable {
    public let keyId: String
    public let hierarchyLevel: KeyHierarchyLevel
    public let allowedUsages: [KeyUsage]
    public let createdAt: Date
    public let expiresAt: Date
    public let rotatedAt: Date?
    public let revokedAt: Date?
    public let parentKeyId: String?        // Key that wraps this key
    public let tenantId: String?           // Owning tenant (if applicable)
    public let algorithm: KeyAlgorithm

    public enum KeyAlgorithm: String, Codable, Sendable {
        case aes256gcm = "AES-256-GCM"
        case ecdsaP256 = "ECDSA-P256"
        case rsaOaep2048 = "RSA-OAEP-2048"
    }

    /// Check if key is valid for use
    public var isValid: Bool {
        let now = Date()
        return revokedAt == nil && now < expiresAt
    }
}

/// Key Hierarchy Manager
@available(iOS 15.0, macOS 12.0, *)
public actor KeyHierarchyManager {

    private let config: KeyManagementConfig
    private let kmsAdapter: KMSAdapter
    private var keyCache: [String: KeyMetadata] = [:]

    public init(config: KeyManagementConfig, kmsAdapter: KMSAdapter) {
        self.config = config
        self.kmsAdapter = kmsAdapter
    }

    /// Generate a new key at the specified level
    public func generateKey(
        level: KeyHierarchyLevel,
        usages: [KeyUsage],
        tenantId: String?,
        parentKeyId: String?
    ) async throws -> KeyMetadata {

        // Validate parent relationship
        if let parentLevel = level.canEncrypt?.rawValue,
           level.rawValue > 0 {
            // Parent must exist and be valid
            guard let parentId = parentKeyId,
                  let parent = keyCache[parentId],
                  parent.isValid,
                  parent.hierarchyLevel.rawValue == level.rawValue - 1 else {
                throw KeyError.invalidParentKey
            }
        }

        // Determine expiry based on level
        let ttl: TimeInterval
        switch level {
        case .root:
            ttl = 365 * 24 * 3600  // 1 year
        case .tenantMaster:
            ttl = 90 * 24 * 3600   // 90 days
        case .dataset:
            ttl = 30 * 24 * 3600   // 30 days
        case .sessionEphemeral:
            ttl = TimeInterval(config.ephemeralSessionKeyTTLSec)
        }

        let keyId = UUID().uuidString
        let now = Date()

        // Generate key via KMS
        try await kmsAdapter.createKey(
            keyId: keyId,
            algorithm: .aes256gcm,
            usages: usages,
            parentKeyId: parentKeyId
        )

        let metadata = KeyMetadata(
            keyId: keyId,
            hierarchyLevel: level,
            allowedUsages: usages,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            rotatedAt: nil,
            revokedAt: nil,
            parentKeyId: parentKeyId,
            tenantId: tenantId,
            algorithm: .aes256gcm
        )

        keyCache[keyId] = metadata
        return metadata
    }

    /// Validate key usage before operation
    public func validateUsage(
        keyId: String,
        operation: KeyOperation
    ) throws {
        guard let metadata = keyCache[keyId] else {
            throw KeyError.keyNotFound(keyId)
        }

        guard metadata.isValid else {
            throw KeyError.keyExpiredOrRevoked(keyId)
        }

        let allowed = metadata.allowedUsages.contains { $0.allows(operation: operation) }
        guard allowed else {
            throw KeyError.usageNotAllowed(keyId: keyId, operation: operation, allowedUsages: metadata.allowedUsages)
        }
    }

    /// Revoke a key and all its children
    public func revokeKey(keyId: String, reason: String) async throws {
        guard var metadata = keyCache[keyId] else {
            throw KeyError.keyNotFound(keyId)
        }

        // Revoke in KMS
        try await kmsAdapter.revokeKey(keyId: keyId, reason: reason)

        // Update local cache
        metadata = KeyMetadata(
            keyId: metadata.keyId,
            hierarchyLevel: metadata.hierarchyLevel,
            allowedUsages: metadata.allowedUsages,
            createdAt: metadata.createdAt,
            expiresAt: metadata.expiresAt,
            rotatedAt: metadata.rotatedAt,
            revokedAt: Date(),
            parentKeyId: metadata.parentKeyId,
            tenantId: metadata.tenantId,
            algorithm: metadata.algorithm
        )
        keyCache[keyId] = metadata

        // Revoke all children
        let children = keyCache.values.filter { $0.parentKeyId == keyId }
        for child in children {
            try await revokeKey(keyId: child.keyId, reason: "Parent key revoked: \(keyId)")
        }
    }
}

/// KMS Adapter protocol
public protocol KMSAdapter: Actor {
    func createKey(keyId: String, algorithm: KeyMetadata.KeyAlgorithm, usages: [KeyUsage], parentKeyId: String?) async throws
    func revokeKey(keyId: String, reason: String) async throws
    func encrypt(keyId: String, plaintext: Data) async throws -> Data
    func decrypt(keyId: String, ciphertext: Data) async throws -> Data
}

/// Key errors
public enum KeyError: Error, LocalizedError {
    case keyNotFound(String)
    case keyExpiredOrRevoked(String)
    case usageNotAllowed(keyId: String, operation: KeyOperation, allowedUsages: [KeyUsage])
    case invalidParentKey
    case breakGlassRequired
    case insufficientApprovers(required: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .keyNotFound(let id):
            return "Key not found: \(id)"
        case .keyExpiredOrRevoked(let id):
            return "Key expired or revoked: \(id)"
        case .usageNotAllowed(let id, let op, let allowed):
            return "Key \(id) does not allow operation \(op). Allowed: \(allowed)"
        case .invalidParentKey:
            return "Invalid or missing parent key for hierarchy level"
        case .breakGlassRequired:
            return "Break-glass procedure required for this operation"
        case .insufficientApprovers(let required, let actual):
            return "Insufficient approvers: \(actual)/\(required) required"
        }
    }
}
```

---

## PART AE: IDENTITY & AUTHORIZATION (ABAC)

### AE.1 Problem Statement

**Vulnerability ID**: AUTHZ-001 through AUTHZ-010
**Severity**: CRITICAL
**Category**: Authorization Model, Least Privilege, Audit Proof

Current gaps:
1. Tenant isolation exists but no fine-grained resource AuthZ
2. No resource hierarchy (Tenant → Project → Dataset → Session → Artifact)
3. No authorization proof for audit (why was access allowed?)
4. Missing least-privilege enforcement

### AE.2 Solution Architecture

Implement [ABAC (Attribute-Based Access Control)](https://www.splunk.com/en_us/blog/learn/abac-attribute-based-access-control.html):

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    AUTHORIZATION MODEL                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  RESOURCE HIERARCHY:                                                    │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Tenant                                                          │   │
│  │   └── Project                                                   │   │
│  │         └── Dataset                                             │   │
│  │               └── Session                                       │   │
│  │                     └── Artifact (Frame, Audit, Proof)         │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  PERMISSION CLOSED SET:                                                │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • read        - Read resource                                   │   │
│  │ • write       - Create/update resource                          │   │
│  │ • delete      - Delete resource                                 │   │
│  │ • upload      - Upload capture data                             │   │
│  │ • download    - Download artifacts                              │   │
│  │ • verify      - Trigger verification                            │   │
│  │ • admin       - Administrative operations                       │   │
│  │ • audit       - Read audit logs                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  AUTHZ DECISION FLOW:                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Request → Extract Attributes → Evaluate Policies → Decision    │   │
│  │                                      │                          │   │
│  │ Attributes:                          ↓                          │   │
│  │ • Subject (user, service, device)   Policy Engine               │   │
│  │ • Resource (type, id, owner)              │                     │   │
│  │ • Action (permission)                     ↓                     │   │
│  │ • Environment (time, IP, MFA)       Emit AuthZProof             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AE.3 Implementation

```swift
// Tenant/AuthZModel.swift
// STAGE AE-001: Attribute-based access control model
// Vulnerability: AUTHZ-001 through AUTHZ-005
// Reference: https://www.splunk.com/en_us/blog/learn/abac-attribute-based-access-control.html

import Foundation

/// Authorization configuration
public struct AuthZConfig: Codable, Sendable {
    /// Whether to deny by default (true = secure)
    public let defaultDeny: Bool

    /// Cross-project access policy
    public let crossProjectAccess: CrossProjectPolicy

    /// Time window for privileged action re-authentication (seconds)
    public let privilegedActionReauthSec: Int64

    public enum CrossProjectPolicy: String, Codable, Sendable {
        case allow      // Allow (dangerous)
        case warn       // Warn and log
        case hardDeny   // Block entirely
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> AuthZConfig {
        switch profile {
        case .production:
            return AuthZConfig(
                defaultDeny: true,
                crossProjectAccess: .hardDeny,
                privilegedActionReauthSec: 300
            )
        case .debug:
            return AuthZConfig(
                defaultDeny: false,
                crossProjectAccess: .warn,
                privilegedActionReauthSec: 3600
            )
        case .lab:
            return AuthZConfig(
                defaultDeny: true,           // EXTREME: strict
                crossProjectAccess: .hardDeny,
                privilegedActionReauthSec: 60  // EXTREME: frequent reauth
            )
        }
    }
}

/// Resource types (closed set)
public enum ResourceType: String, Codable, Sendable, CaseIterable {
    case tenant
    case project
    case dataset
    case session
    case frame
    case auditLog
    case deletionProof
    case configuration
}

/// Permissions (closed set)
public enum Permission: String, Codable, Sendable, CaseIterable {
    case read
    case write
    case delete
    case upload
    case download
    case verify
    case admin
    case audit
}

/// Authorization subject (who is requesting)
public struct AuthZSubject: Codable, Sendable {
    public let subjectId: String
    public let subjectType: SubjectType
    public let tenantId: String
    public let roles: [String]
    public let attributes: [String: String]

    public enum SubjectType: String, Codable, Sendable {
        case user
        case serviceAccount
        case device
    }
}

/// Authorization resource (what is being accessed)
public struct AuthZResource: Codable, Sendable {
    public let resourceId: String
    public let resourceType: ResourceType
    public let ownerTenantId: String
    public let ownerProjectId: String?
    public let parentResourceId: String?
    public let attributes: [String: String]
}

/// Authorization context (environment)
public struct AuthZContext: Codable, Sendable {
    public let timestamp: Date
    public let sourceIP: String?
    public let mfaVerified: Bool
    public let deviceAttested: Bool
    public let sessionAge: TimeInterval
}

/// Authorization request
public struct AuthZRequest: Codable, Sendable {
    public let requestId: String
    public let subject: AuthZSubject
    public let resource: AuthZResource
    public let permission: Permission
    public let context: AuthZContext
}

/// Authorization decision with proof
public struct AuthZDecision: Codable, Sendable {
    public let requestId: String
    public let allowed: Bool
    public let reason: DecisionReason
    public let matchedPolicies: [String]
    public let timestamp: Date
    public let auditProof: AuthZProof

    public enum DecisionReason: String, Codable, Sendable {
        case explicitAllow       // Policy explicitly allows
        case explicitDeny        // Policy explicitly denies
        case defaultDeny         // No matching policy, default deny
        case tenantMismatch      // Cross-tenant access blocked
        case projectMismatch     // Cross-project access blocked
        case insufficientPrivilege  // Missing required role/permission
        case reauthRequired      // Re-authentication needed
        case mfaRequired         // MFA verification needed
    }
}

/// Authorization proof for audit
public struct AuthZProof: Codable, Sendable {
    public let proofId: String
    public let requestHash: String      // Hash of request
    public let decisionHash: String     // Hash of decision
    public let timestamp: Date
    public let evaluatedPolicies: [EvaluatedPolicy]
    public let subjectAttributes: [String: String]
    public let resourceAttributes: [String: String]

    public struct EvaluatedPolicy: Codable, Sendable {
        public let policyId: String
        public let policyVersion: String
        public let matched: Bool
        public let effect: PolicyEffect

        public enum PolicyEffect: String, Codable, Sendable {
            case allow
            case deny
            case notApplicable
        }
    }
}

/// Authorization Enforcer
@available(iOS 15.0, macOS 12.0, *)
public actor AuthZEnforcer {

    private let config: AuthZConfig
    private var policies: [AuthZPolicy] = []

    public init(config: AuthZConfig) {
        self.config = config
    }

    /// Evaluate authorization request
    public func evaluate(_ request: AuthZRequest) async -> AuthZDecision {
        var evaluatedPolicies: [AuthZProof.EvaluatedPolicy] = []
        var matchedAllowPolicies: [String] = []
        var matchedDenyPolicies: [String] = []

        // Check tenant isolation first
        if request.subject.tenantId != request.resource.ownerTenantId {
            return createDecision(
                request: request,
                allowed: false,
                reason: .tenantMismatch,
                matchedPolicies: [],
                evaluatedPolicies: []
            )
        }

        // Check cross-project access
        if let projectId = request.resource.ownerProjectId,
           !request.subject.attributes.keys.contains("project:\(projectId)") {
            switch config.crossProjectAccess {
            case .hardDeny:
                return createDecision(
                    request: request,
                    allowed: false,
                    reason: .projectMismatch,
                    matchedPolicies: [],
                    evaluatedPolicies: []
                )
            case .warn:
                // Log warning but continue
                print("WARNING: Cross-project access attempt: \(request.requestId)")
            case .allow:
                break
            }
        }

        // Evaluate all policies
        for policy in policies {
            let evaluation = policy.evaluate(request)
            evaluatedPolicies.append(AuthZProof.EvaluatedPolicy(
                policyId: policy.policyId,
                policyVersion: policy.version,
                matched: evaluation.matched,
                effect: evaluation.effect
            ))

            if evaluation.matched {
                switch evaluation.effect {
                case .allow:
                    matchedAllowPolicies.append(policy.policyId)
                case .deny:
                    matchedDenyPolicies.append(policy.policyId)
                case .notApplicable:
                    break
                }
            }
        }

        // Deny takes precedence over allow
        if !matchedDenyPolicies.isEmpty {
            return createDecision(
                request: request,
                allowed: false,
                reason: .explicitDeny,
                matchedPolicies: matchedDenyPolicies,
                evaluatedPolicies: evaluatedPolicies
            )
        }

        // Check for explicit allow
        if !matchedAllowPolicies.isEmpty {
            return createDecision(
                request: request,
                allowed: true,
                reason: .explicitAllow,
                matchedPolicies: matchedAllowPolicies,
                evaluatedPolicies: evaluatedPolicies
            )
        }

        // Default deny
        return createDecision(
            request: request,
            allowed: config.defaultDeny ? false : true,
            reason: config.defaultDeny ? .defaultDeny : .explicitAllow,
            matchedPolicies: [],
            evaluatedPolicies: evaluatedPolicies
        )
    }

    /// Register a policy
    public func registerPolicy(_ policy: AuthZPolicy) {
        policies.append(policy)
    }

    // MARK: - Private

    private func createDecision(
        request: AuthZRequest,
        allowed: Bool,
        reason: AuthZDecision.DecisionReason,
        matchedPolicies: [String],
        evaluatedPolicies: [AuthZProof.EvaluatedPolicy]
    ) -> AuthZDecision {

        let requestHash = SHA256.hash(data: try! JSONEncoder().encode(request))
            .compactMap { String(format: "%02x", $0) }.joined()

        let proof = AuthZProof(
            proofId: UUID().uuidString,
            requestHash: requestHash,
            decisionHash: "",  // Computed after decision
            timestamp: Date(),
            evaluatedPolicies: evaluatedPolicies,
            subjectAttributes: request.subject.attributes,
            resourceAttributes: request.resource.attributes
        )

        return AuthZDecision(
            requestId: request.requestId,
            allowed: allowed,
            reason: reason,
            matchedPolicies: matchedPolicies,
            timestamp: Date(),
            auditProof: proof
        )
    }
}

/// Authorization Policy
public struct AuthZPolicy: Codable, Sendable {
    public let policyId: String
    public let version: String
    public let effect: AuthZProof.EvaluatedPolicy.PolicyEffect
    public let subjects: SubjectMatcher
    public let resources: ResourceMatcher
    public let permissions: [Permission]
    public let conditions: [PolicyCondition]

    public struct SubjectMatcher: Codable, Sendable {
        public let roles: [String]?
        public let attributes: [String: String]?
    }

    public struct ResourceMatcher: Codable, Sendable {
        public let types: [ResourceType]?
        public let attributes: [String: String]?
    }

    public struct PolicyCondition: Codable, Sendable {
        public let attribute: String
        public let `operator`: ConditionOperator
        public let value: String

        public enum ConditionOperator: String, Codable, Sendable {
            case equals
            case notEquals
            case contains
            case greaterThan
            case lessThan
        }
    }

    public func evaluate(_ request: AuthZRequest) -> (matched: Bool, effect: AuthZProof.EvaluatedPolicy.PolicyEffect) {
        // Check permission match
        guard permissions.contains(request.permission) else {
            return (false, .notApplicable)
        }

        // Check subject match
        if let roles = subjects.roles {
            let hasMatchingRole = request.subject.roles.contains { roles.contains($0) }
            if !hasMatchingRole {
                return (false, .notApplicable)
            }
        }

        // Check resource match
        if let types = resources.types {
            if !types.contains(request.resource.resourceType) {
                return (false, .notApplicable)
            }
        }

        // All conditions must match
        for condition in conditions {
            if !evaluateCondition(condition, request: request) {
                return (false, .notApplicable)
            }
        }

        return (true, effect)
    }

    private func evaluateCondition(_ condition: PolicyCondition, request: AuthZRequest) -> Bool {
        // Get attribute value from subject or resource
        let value = request.subject.attributes[condition.attribute]
            ?? request.resource.attributes[condition.attribute]
            ?? ""

        switch condition.operator {
        case .equals:
            return value == condition.value
        case .notEquals:
            return value != condition.value
        case .contains:
            return value.contains(condition.value)
        case .greaterThan:
            return (Double(value) ?? 0) > (Double(condition.value) ?? 0)
        case .lessThan:
            return (Double(value) ?? 0) < (Double(condition.value) ?? 0)
        }
    }
}
```

---

## PART AF: ABUSE & COST PROTECTION

### AF.1 Problem Statement

**Vulnerability ID**: ABUSE-001 through ABUSE-012
**Severity**: HIGH
**Category**: Rate Limiting, DDoS, Cost Guards

Current gaps:
1. No multi-layer rate limiting (IP/Device/User/Tenant)
2. No abuse scoring model
3. No cost budget enforcement
4. Mirror verification can be DDoS'd

### AF.2 Implementation

```swift
// Security/AbuseScoringModel.swift
// STAGE AF-001: Abuse detection and scoring
// Vulnerability: ABUSE-001 through ABUSE-005
// Reference: https://www.apisec.ai/blog/api-rate-limiting-strategies-preventing

import Foundation

/// Abuse protection configuration
public struct AbuseProtectionConfig: Codable, Sendable {
    /// Max upload sessions per user per hour
    public let maxUploadSessionsPerUserPerHour: Int

    /// Max active jobs per tenant
    public let maxActiveJobsPerTenant: Int

    /// CPU budget for mirror verification (ms P95)
    public let mirrorVerificationCPUBudgetMsP95: Int

    /// Cost spike threshold for auto-mitigation (percentage increase in 5 min)
    public let costSpikeAutoMitigatePercent: Int

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> AbuseProtectionConfig {
        switch profile {
        case .production:
            return AbuseProtectionConfig(
                maxUploadSessionsPerUserPerHour: 10,
                maxActiveJobsPerTenant: 50,
                mirrorVerificationCPUBudgetMsP95: 100,
                costSpikeAutoMitigatePercent: 50
            )
        case .debug:
            return AbuseProtectionConfig(
                maxUploadSessionsPerUserPerHour: 100,
                maxActiveJobsPerTenant: 200,
                mirrorVerificationCPUBudgetMsP95: 500,
                costSpikeAutoMitigatePercent: 100
            )
        case .lab:
            return AbuseProtectionConfig(
                maxUploadSessionsPerUserPerHour: 1,    // EXTREME
                maxActiveJobsPerTenant: 2,             // EXTREME
                mirrorVerificationCPUBudgetMsP95: 10,  // EXTREME
                costSpikeAutoMitigatePercent: 20       // EXTREME
            )
        }
    }
}

/// Token bucket rate limiter
/// Reference: https://www.eraser.io/decision-node/api-rate-limiting-strategies-token-bucket-vs-leaky-bucket
public actor TokenBucketRateLimiter {

    private let capacity: Int
    private let refillRate: Double  // tokens per second
    private var tokens: Double
    private var lastRefill: Date

    public init(capacity: Int, refillRatePerSecond: Double) {
        self.capacity = capacity
        self.refillRate = refillRatePerSecond
        self.tokens = Double(capacity)
        self.lastRefill = Date()
    }

    /// Try to consume tokens, returns true if allowed
    public func tryConsume(tokens: Int = 1) -> Bool {
        refill()

        if self.tokens >= Double(tokens) {
            self.tokens -= Double(tokens)
            return true
        }
        return false
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        let refillAmount = elapsed * refillRate
        tokens = min(Double(capacity), tokens + refillAmount)
        lastRefill = now
    }
}

/// Multi-layer rate limit manager
@available(iOS 15.0, macOS 12.0, *)
public actor MultiLayerRateLimiter {

    private let config: AbuseProtectionConfig
    private var userBuckets: [String: TokenBucketRateLimiter] = [:]
    private var tenantBuckets: [String: TokenBucketRateLimiter] = [:]
    private var ipBuckets: [String: TokenBucketRateLimiter] = [:]

    public init(config: AbuseProtectionConfig) {
        self.config = config
    }

    /// Check all rate limits
    public func checkLimits(
        userId: String,
        tenantId: String,
        ipAddress: String
    ) async -> RateLimitResult {

        // User limit
        let userBucket = userBuckets[userId] ?? TokenBucketRateLimiter(
            capacity: config.maxUploadSessionsPerUserPerHour,
            refillRatePerSecond: Double(config.maxUploadSessionsPerUserPerHour) / 3600
        )
        userBuckets[userId] = userBucket

        if await !userBucket.tryConsume() {
            return RateLimitResult(
                allowed: false,
                limitType: .user,
                retryAfterSeconds: 60
            )
        }

        // Tenant limit
        let tenantBucket = tenantBuckets[tenantId] ?? TokenBucketRateLimiter(
            capacity: config.maxActiveJobsPerTenant,
            refillRatePerSecond: Double(config.maxActiveJobsPerTenant) / 60
        )
        tenantBuckets[tenantId] = tenantBucket

        if await !tenantBucket.tryConsume() {
            return RateLimitResult(
                allowed: false,
                limitType: .tenant,
                retryAfterSeconds: 30
            )
        }

        return RateLimitResult(allowed: true, limitType: nil, retryAfterSeconds: nil)
    }
}

public struct RateLimitResult: Sendable {
    public let allowed: Bool
    public let limitType: LimitType?
    public let retryAfterSeconds: Int?

    public enum LimitType: String, Sendable {
        case ip
        case user
        case tenant
        case global
    }
}

/// Cost budget tracker
@available(iOS 15.0, macOS 12.0, *)
public actor CostBudgetTracker {

    private let config: AbuseProtectionConfig
    private var costHistory: [(timestamp: Date, cost: Double)] = []
    private let historyWindow: TimeInterval = 300  // 5 minutes

    public init(config: AbuseProtectionConfig) {
        self.config = config
    }

    /// Record a cost event
    public func recordCost(_ cost: Double) {
        let now = Date()
        costHistory.append((now, cost))

        // Prune old entries
        let cutoff = now.addingTimeInterval(-historyWindow)
        costHistory = costHistory.filter { $0.timestamp > cutoff }
    }

    /// Check if cost spike triggers mitigation
    public func shouldMitigate() -> CostMitigationDecision {
        guard costHistory.count >= 2 else {
            return CostMitigationDecision(shouldMitigate: false, spikePercent: 0)
        }

        let midpoint = costHistory.count / 2
        let firstHalf = costHistory.prefix(midpoint).map { $0.cost }.reduce(0, +)
        let secondHalf = costHistory.suffix(from: midpoint).map { $0.cost }.reduce(0, +)

        guard firstHalf > 0 else {
            return CostMitigationDecision(shouldMitigate: false, spikePercent: 0)
        }

        let spikePercent = ((secondHalf - firstHalf) / firstHalf) * 100
        let shouldMitigate = spikePercent > Double(config.costSpikeAutoMitigatePercent)

        return CostMitigationDecision(
            shouldMitigate: shouldMitigate,
            spikePercent: spikePercent
        )
    }
}

public struct CostMitigationDecision: Sendable {
    public let shouldMitigate: Bool
    public let spikePercent: Double
}
```

---

## PART AG: BACKUP & DISASTER RECOVERY

### AG.1 Problem Statement

**Vulnerability ID**: DR-001 through DR-010
**Severity**: CRITICAL
**Category**: Data Durability, Business Continuity, Compliance

Current gaps:
1. No formal RPO/RTO targets with automated verification
2. Deletion proofs don't account for backup copies
3. No DR drill cadence enforcement
4. Multi-region consistency not guaranteed during failover

### AG.2 Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DISASTER RECOVERY ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  PRIMARY REGION                     SECONDARY REGION                    │
│  ┌─────────────────────┐           ┌─────────────────────┐             │
│  │ Active Services     │           │ Standby Services    │             │
│  │ ┌─────────────────┐ │  Async    │ ┌─────────────────┐ │             │
│  │ │ Database        │─┼───Repl───▶│ │ Database        │ │             │
│  │ └─────────────────┘ │           │ └─────────────────┘ │             │
│  │ ┌─────────────────┐ │           │ ┌─────────────────┐ │             │
│  │ │ Object Storage  │─┼───Repl───▶│ │ Object Storage  │ │             │
│  │ └─────────────────┘ │           │ └─────────────────┘ │             │
│  │ ┌─────────────────┐ │           │ ┌─────────────────┐ │             │
│  │ │ Audit Ledger    │─┼───Repl───▶│ │ Audit Ledger    │ │             │
│  │ └─────────────────┘ │           │ └─────────────────┘ │             │
│  └─────────────────────┘           └─────────────────────┘             │
│           │                                  ▲                          │
│           │                                  │                          │
│           ▼                                  │                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                    BACKUP POLICY                                 │   │
│  │ • RPO: 5 min (lab) / 15 min (prod)                              │   │
│  │ • RTO: 15 min (lab) / 30 min (prod)                             │   │
│  │ • Backup verification: continuous                                │   │
│  │ • Deletion requires backup confirmation                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  DR DRILL GATE:                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • Drill frequency: 7 days (lab) / 90 days (prod)                │   │
│  │ • Must complete within RTO                                       │   │
│  │ • Auto-blocks deployment if overdue                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AG.3 Implementation Files

```
New Files:
├── DR/
│   ├── BackupPolicy.swift                    (STAGE AG-001)
│   ├── DisasterRecoveryRunbook.swift         (STAGE AG-002)
│   ├── BackupAwareDeletionProof.swift        (STAGE AG-003)
│   ├── DRDrillGate.swift                     (STAGE AG-004)
│   └── MultiRegionConsistencyChecker.swift   (STAGE AG-005)
└── Tests/
    └── DisasterRecoveryTests.swift           (STAGE AG-006)
```

### STAGE AG-001: BackupPolicy.swift

```swift
// DR/BackupPolicy.swift
// STAGE AG-001: Backup policy with RPO/RTO targets
// Vulnerability: DR-001, DR-002, DR-003
// Reference: https://www.veeam.com/blog/rpo-rto-definitions.html

import Foundation

/// Disaster recovery configuration
public struct DRConfig: Codable, Sendable {
    /// Recovery Point Objective in minutes
    public let rpoMinutes: Int

    /// Recovery Time Objective in minutes
    public let rtoMinutes: Int

    /// Whether deletion proof must include backup verification
    public let deletionProofMustIncludeBackup: Bool

    /// DR drill frequency in days
    public let drDrillFrequencyDays: Int

    /// Maximum replication lag before alert (seconds)
    public let maxReplicationLagSeconds: Int

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> DRConfig {
        switch profile {
        case .production:
            return DRConfig(
                rpoMinutes: 15,
                rtoMinutes: 30,
                deletionProofMustIncludeBackup: true,
                drDrillFrequencyDays: 90,
                maxReplicationLagSeconds: 300
            )
        case .debug:
            return DRConfig(
                rpoMinutes: 60,
                rtoMinutes: 120,
                deletionProofMustIncludeBackup: false,
                drDrillFrequencyDays: 180,
                maxReplicationLagSeconds: 600
            )
        case .lab:
            return DRConfig(
                rpoMinutes: 5,              // EXTREME
                rtoMinutes: 15,             // EXTREME
                deletionProofMustIncludeBackup: true,
                drDrillFrequencyDays: 7,    // EXTREME
                maxReplicationLagSeconds: 30 // EXTREME
            )
        }
    }
}

/// Backup types (closed set)
public enum BackupType: String, Codable, Sendable, CaseIterable {
    case full           // Complete backup
    case incremental    // Changes since last backup
    case differential   // Changes since last full backup
    case continuous     // Continuous replication (WAL shipping)
}

/// Backup status (closed set)
public enum BackupStatus: String, Codable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case verified
    case corrupted
}

/// Backup record
public struct BackupRecord: Codable, Sendable {
    public let backupId: String
    public let backupType: BackupType
    public let createdAt: Date
    public let completedAt: Date?
    public let status: BackupStatus
    public let sizeBytes: Int64
    public let checksum: String
    public let sourceRegion: String
    public let targetRegion: String
    public let datasetIds: [String]
    public let verifiedAt: Date?
    public let verificationChecksum: String?

    /// Time since backup was created
    public var age: TimeInterval {
        Date().timeIntervalSince(createdAt)
    }
}

/// Backup Policy Manager
@available(iOS 15.0, macOS 12.0, *)
public actor BackupPolicyManager {

    private let config: DRConfig
    private var backupHistory: [BackupRecord] = []
    private var lastDrillDate: Date?

    public init(config: DRConfig) {
        self.config = config
    }

    /// Check if RPO is being met
    public func checkRPOCompliance() -> RPOComplianceResult {
        let now = Date()
        let rpoSeconds = TimeInterval(config.rpoMinutes * 60)

        // Find most recent verified backup
        let lastVerifiedBackup = backupHistory
            .filter { $0.status == .verified }
            .max { $0.completedAt ?? $0.createdAt < $1.completedAt ?? $1.createdAt }

        guard let backup = lastVerifiedBackup,
              let completedAt = backup.completedAt else {
            return RPOComplianceResult(
                compliant: false,
                currentRPOSeconds: nil,
                targetRPOSeconds: Int(rpoSeconds),
                lastBackupTime: nil,
                recommendation: "No verified backups found"
            )
        }

        let currentRPO = now.timeIntervalSince(completedAt)
        let compliant = currentRPO <= rpoSeconds

        return RPOComplianceResult(
            compliant: compliant,
            currentRPOSeconds: Int(currentRPO),
            targetRPOSeconds: Int(rpoSeconds),
            lastBackupTime: completedAt,
            recommendation: compliant ? nil : "Backup overdue by \(Int(currentRPO - rpoSeconds)) seconds"
        )
    }

    /// Record a new backup
    public func recordBackup(_ backup: BackupRecord) {
        backupHistory.append(backup)

        // Keep last 1000 records
        if backupHistory.count > 1000 {
            backupHistory.removeFirst(backupHistory.count - 1000)
        }
    }

    /// Verify backup integrity
    public func verifyBackup(backupId: String, actualChecksum: String) throws -> BackupRecord {
        guard let index = backupHistory.firstIndex(where: { $0.backupId == backupId }) else {
            throw DRError.backupNotFound(backupId)
        }

        var backup = backupHistory[index]

        if backup.checksum != actualChecksum {
            backup = BackupRecord(
                backupId: backup.backupId,
                backupType: backup.backupType,
                createdAt: backup.createdAt,
                completedAt: backup.completedAt,
                status: .corrupted,
                sizeBytes: backup.sizeBytes,
                checksum: backup.checksum,
                sourceRegion: backup.sourceRegion,
                targetRegion: backup.targetRegion,
                datasetIds: backup.datasetIds,
                verifiedAt: Date(),
                verificationChecksum: actualChecksum
            )
            backupHistory[index] = backup
            throw DRError.backupCorrupted(backupId, expected: backup.checksum, actual: actualChecksum)
        }

        backup = BackupRecord(
            backupId: backup.backupId,
            backupType: backup.backupType,
            createdAt: backup.createdAt,
            completedAt: backup.completedAt,
            status: .verified,
            sizeBytes: backup.sizeBytes,
            checksum: backup.checksum,
            sourceRegion: backup.sourceRegion,
            targetRegion: backup.targetRegion,
            datasetIds: backup.datasetIds,
            verifiedAt: Date(),
            verificationChecksum: actualChecksum
        )
        backupHistory[index] = backup
        return backup
    }

    /// Check if DR drill is overdue
    public func isDrillOverdue() -> Bool {
        guard let lastDrill = lastDrillDate else {
            return true
        }

        let drillIntervalSeconds = TimeInterval(config.drDrillFrequencyDays * 24 * 3600)
        return Date().timeIntervalSince(lastDrill) > drillIntervalSeconds
    }

    /// Record DR drill completion
    public func recordDrillCompletion(duration: TimeInterval) throws {
        let rtoSeconds = TimeInterval(config.rtoMinutes * 60)

        if duration > rtoSeconds {
            throw DRError.drillExceededRTO(duration: Int(duration), rtoSeconds: Int(rtoSeconds))
        }

        lastDrillDate = Date()
    }
}

/// RPO Compliance Result
public struct RPOComplianceResult: Sendable {
    public let compliant: Bool
    public let currentRPOSeconds: Int?
    public let targetRPOSeconds: Int
    public let lastBackupTime: Date?
    public let recommendation: String?
}

/// DR Errors
public enum DRError: Error, LocalizedError {
    case backupNotFound(String)
    case backupCorrupted(String, expected: String, actual: String)
    case drillExceededRTO(duration: Int, rtoSeconds: Int)
    case deletionBlockedNoBackupVerification(datasetId: String)
    case replicationLagExceeded(currentLag: Int, maxLag: Int)

    public var errorDescription: String? {
        switch self {
        case .backupNotFound(let id):
            return "Backup not found: \(id)"
        case .backupCorrupted(let id, let expected, let actual):
            return "Backup corrupted: \(id). Expected checksum: \(expected), actual: \(actual)"
        case .drillExceededRTO(let duration, let rto):
            return "DR drill took \(duration)s, exceeds RTO of \(rto)s"
        case .deletionBlockedNoBackupVerification(let id):
            return "Deletion blocked: dataset \(id) has no verified backup"
        case .replicationLagExceeded(let current, let max):
            return "Replication lag \(current)s exceeds maximum \(max)s"
        }
    }
}
```

### STAGE AG-003: BackupAwareDeletionProof.swift

```swift
// DR/BackupAwareDeletionProof.swift
// STAGE AG-003: Deletion proof that includes backup verification
// Vulnerability: DR-004, DR-005
// Reference: GDPR Article 17 - Right to erasure

import Foundation
import CryptoKit

/// Backup-aware deletion proof
/// Extends standard deletion proof to include backup verification
public struct BackupAwareDeletionProof: Codable, Sendable {

    // MARK: - Standard Deletion Proof Fields

    public let proofId: String
    public let datasetId: String
    public let deletionRequestedAt: Date
    public let deletionCompletedAt: Date
    public let requestedBy: String
    public let reason: DeletionReason

    // MARK: - Backup Verification Fields (NEW)

    /// All backup locations that contained this data
    public let backupLocations: [BackupLocation]

    /// Whether all backups were verified deleted
    public let allBackupsDeleted: Bool

    /// Individual backup deletion records
    public let backupDeletionRecords: [BackupDeletionRecord]

    /// Hash of the entire proof chain
    public let proofChainHash: String

    // MARK: - Nested Types

    public enum DeletionReason: String, Codable, Sendable {
        case userRequest        // GDPR right to erasure
        case retentionExpired   // Data retention period ended
        case legalHold          // Legal requirement
        case policyViolation    // Terms of service violation
        case consentWithdrawn   // User withdrew consent
    }

    public struct BackupLocation: Codable, Sendable {
        public let region: String
        public let backupType: BackupType
        public let backupId: String
        public let createdAt: Date
    }

    public struct BackupDeletionRecord: Codable, Sendable {
        public let backupId: String
        public let deletedAt: Date
        public let deletionMethod: DeletionMethod
        public let verifiedAt: Date?
        public let verificationMethod: VerificationMethod?

        public enum DeletionMethod: String, Codable, Sendable {
            case cryptographicErasure   // Key destroyed, data irrecoverable
            case physicalDeletion       // Data blocks zeroed
            case logicalDeletion        // Marked for deletion, pending physical
        }

        public enum VerificationMethod: String, Codable, Sendable {
            case checksumMismatch       // Data no longer readable
            case storageConfirmation    // Storage provider confirmed
            case auditScan              // Independent audit verified
        }
    }
}

/// Backup-Aware Deletion Service
@available(iOS 15.0, macOS 12.0, *)
public actor BackupAwareDeletionService {

    private let config: DRConfig
    private let backupManager: BackupPolicyManager

    public init(config: DRConfig, backupManager: BackupPolicyManager) {
        self.config = config
        self.backupManager = backupManager
    }

    /// Create deletion proof with backup verification
    public func createDeletionProof(
        datasetId: String,
        requestedBy: String,
        reason: BackupAwareDeletionProof.DeletionReason,
        backupLocations: [BackupAwareDeletionProof.BackupLocation]
    ) async throws -> BackupAwareDeletionProof {

        // If config requires backup verification, all backups must be deleted first
        if config.deletionProofMustIncludeBackup && !backupLocations.isEmpty {
            throw DRError.deletionBlockedNoBackupVerification(datasetId: datasetId)
        }

        let proofId = UUID().uuidString
        let now = Date()

        // Create proof chain hash
        let proofData = "\(proofId)|\(datasetId)|\(now.timeIntervalSince1970)|\(requestedBy)"
        let hash = SHA256.hash(data: Data(proofData.utf8))
        let proofChainHash = hash.compactMap { String(format: "%02x", $0) }.joined()

        return BackupAwareDeletionProof(
            proofId: proofId,
            datasetId: datasetId,
            deletionRequestedAt: now,
            deletionCompletedAt: now,
            requestedBy: requestedBy,
            reason: reason,
            backupLocations: backupLocations,
            allBackupsDeleted: backupLocations.isEmpty,
            backupDeletionRecords: [],
            proofChainHash: proofChainHash
        )
    }

    /// Add backup deletion record to proof
    public func addBackupDeletionRecord(
        proof: BackupAwareDeletionProof,
        record: BackupAwareDeletionProof.BackupDeletionRecord
    ) -> BackupAwareDeletionProof {
        var records = proof.backupDeletionRecords
        records.append(record)

        let allDeleted = records.count == proof.backupLocations.count &&
            records.allSatisfy { $0.verifiedAt != nil }

        // Recalculate proof chain hash
        let proofData = "\(proof.proofId)|\(proof.datasetId)|\(records.count)|\(allDeleted)"
        let hash = SHA256.hash(data: Data(proofData.utf8))
        let newHash = hash.compactMap { String(format: "%02x", $0) }.joined()

        return BackupAwareDeletionProof(
            proofId: proof.proofId,
            datasetId: proof.datasetId,
            deletionRequestedAt: proof.deletionRequestedAt,
            deletionCompletedAt: allDeleted ? Date() : proof.deletionCompletedAt,
            requestedBy: proof.requestedBy,
            reason: proof.reason,
            backupLocations: proof.backupLocations,
            allBackupsDeleted: allDeleted,
            backupDeletionRecords: records,
            proofChainHash: newHash
        )
    }
}
```

---

## PART AH: PRIVACY ATTACK SURFACE

### AH.1 Problem Statement

**Vulnerability ID**: PRIVACY-001 through PRIVACY-012
**Severity**: HIGH
**Category**: Inference Attacks, Re-identification, Model Privacy

Current gaps:
1. No membership inference risk scoring
2. Location data can enable re-identification
3. Training data eligibility not gated by privacy risk
4. No trajectory anonymization

### AH.2 Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    PRIVACY ATTACK DEFENSE                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  INFERENCE RISK PIPELINE:                                               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Raw Data → Risk Scorer → Policy Gate → Output                   │   │
│  │     │          │             │            │                     │   │
│  │     ▼          ▼             ▼            ▼                     │   │
│  │  Location   Score:      localOnly?    Anonymized               │   │
│  │  + Time    0.0-1.0     forbidUpload?  Data                     │   │
│  │  + Device              downsample?                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  RE-IDENTIFICATION DEFENSES:                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 1. Trajectory Downsampling: Remove N-1 of every N points        │   │
│  │ 2. Location Snapping: Snap to grid (reduce precision)           │   │
│  │ 3. Temporal Jittering: Add noise to timestamps                  │   │
│  │ 4. k-Anonymity: Ensure k similar records exist                  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  TRAINING DATA ELIGIBILITY:                                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Data can only be used for training if:                          │   │
│  │ • Re-identification risk < threshold (0.05 in lab)              │   │
│  │ • Consent explicitly includes training use                      │   │
│  │ • Data has been anonymized                                      │   │
│  │ • Membership inference defense applied (differential privacy)   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AH.3 Implementation Files

```
New Files:
├── InferencePrivacy/
│   ├── InferenceRiskScorer.swift             (STAGE AH-001)
│   ├── TrajectoryAnonymizer.swift            (STAGE AH-002)
│   ├── TrainingDataEligibilityGate.swift     (STAGE AH-003)
│   ├── LocationPrivacyPolicy.swift           (STAGE AH-004)
│   └── MembershipInferenceDefense.swift      (STAGE AH-005)
└── Tests/
    └── PrivacyAttackTests.swift              (STAGE AH-006)
```

### STAGE AH-001: InferenceRiskScorer.swift

```swift
// InferencePrivacy/InferenceRiskScorer.swift
// STAGE AH-001: Risk scoring for inference and re-identification attacks
// Vulnerability: PRIVACY-001, PRIVACY-002, PRIVACY-003
// Reference: https://arxiv.org/abs/1610.05820 (Membership Inference Attacks)

import Foundation

/// Privacy attack protection configuration
public struct PrivacyAttackConfig: Codable, Sendable {
    /// Maximum acceptable re-identification risk (0.0 - 1.0)
    public let maxLocationReidentificationRisk: Double

    /// Trajectory downsampling factor (keep 1 in N points)
    public let trajectoryDownsampleFactor: Int

    /// Policy for high-risk data
    public let highRiskDataPolicy: HighRiskPolicy

    /// Minimum k for k-anonymity
    public let kAnonymityMinK: Int

    /// Differential privacy epsilon
    public let differentialPrivacyEpsilon: Double

    public enum HighRiskPolicy: String, Codable, Sendable {
        case allow                  // Allow (dangerous)
        case warn                   // Warn and log
        case localOnlyForbidUpload  // Keep local, block upload
        case deleteImmediately      // Delete high-risk data
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> PrivacyAttackConfig {
        switch profile {
        case .production:
            return PrivacyAttackConfig(
                maxLocationReidentificationRisk: 0.10,
                trajectoryDownsampleFactor: 2,
                highRiskDataPolicy: .warn,
                kAnonymityMinK: 5,
                differentialPrivacyEpsilon: 1.0
            )
        case .debug:
            return PrivacyAttackConfig(
                maxLocationReidentificationRisk: 0.25,
                trajectoryDownsampleFactor: 1,
                highRiskDataPolicy: .allow,
                kAnonymityMinK: 2,
                differentialPrivacyEpsilon: 2.0
            )
        case .lab:
            return PrivacyAttackConfig(
                maxLocationReidentificationRisk: 0.05,  // EXTREME
                trajectoryDownsampleFactor: 4,          // EXTREME
                highRiskDataPolicy: .localOnlyForbidUpload,
                kAnonymityMinK: 10,                     // EXTREME
                differentialPrivacyEpsilon: 0.1         // EXTREME
            )
        }
    }
}

/// Risk factors for re-identification
public struct ReidentificationRiskFactors: Codable, Sendable {
    /// Location precision (meters)
    public let locationPrecisionMeters: Double

    /// Time precision (seconds)
    public let timePrecisionSeconds: Double

    /// Number of data points
    public let dataPointCount: Int

    /// Whether device identifiers are present
    public let hasDeviceIdentifiers: Bool

    /// Whether biometric data is present
    public let hasBiometricData: Bool

    /// Population density of location (people per km²)
    public let populationDensity: Double?

    /// Time span of data (hours)
    public let timeSpanHours: Double
}

/// Re-identification risk score result
public struct ReidentificationRiskScore: Codable, Sendable {
    /// Overall risk score (0.0 - 1.0)
    public let overallScore: Double

    /// Component scores
    public let locationScore: Double
    public let temporalScore: Double
    public let volumeScore: Double
    public let sensitivityScore: Double

    /// Risk level classification
    public let riskLevel: RiskLevel

    /// Recommended mitigations
    public let recommendedMitigations: [Mitigation]

    public enum RiskLevel: String, Codable, Sendable {
        case low        // < 0.10
        case medium     // 0.10 - 0.25
        case high       // 0.25 - 0.50
        case critical   // > 0.50
    }

    public enum Mitigation: String, Codable, Sendable {
        case downsampleTrajectory
        case snapToGrid
        case addTemporalNoise
        case removeDeviceIds
        case applyDifferentialPrivacy
        case requireExplicitConsent
        case blockUpload
    }
}

/// Inference Risk Scorer
@available(iOS 15.0, macOS 12.0, *)
public actor InferenceRiskScorer {

    private let config: PrivacyAttackConfig

    public init(config: PrivacyAttackConfig) {
        self.config = config
    }

    /// Calculate re-identification risk score
    public func calculateRisk(_ factors: ReidentificationRiskFactors) -> ReidentificationRiskScore {

        // Location precision risk (higher precision = higher risk)
        let locationScore: Double
        switch factors.locationPrecisionMeters {
        case 0..<10:
            locationScore = 0.9   // Very precise
        case 10..<100:
            locationScore = 0.6   // Precise
        case 100..<1000:
            locationScore = 0.3   // Moderate
        default:
            locationScore = 0.1   // Low precision
        }

        // Temporal precision risk
        let temporalScore: Double
        switch factors.timePrecisionSeconds {
        case 0..<60:
            temporalScore = 0.8   // Sub-minute
        case 60..<3600:
            temporalScore = 0.5   // Sub-hour
        default:
            temporalScore = 0.2   // Coarse
        }

        // Volume risk (more data = easier to identify)
        let volumeScore: Double
        switch factors.dataPointCount {
        case 0..<10:
            volumeScore = 0.2
        case 10..<100:
            volumeScore = 0.4
        case 100..<1000:
            volumeScore = 0.6
        default:
            volumeScore = 0.9
        }

        // Sensitivity risk
        var sensitivityScore = 0.0
        if factors.hasDeviceIdentifiers {
            sensitivityScore += 0.4
        }
        if factors.hasBiometricData {
            sensitivityScore += 0.5
        }
        sensitivityScore = min(sensitivityScore, 1.0)

        // Population density adjustment (sparser = higher risk)
        var densityMultiplier = 1.0
        if let density = factors.populationDensity {
            if density < 100 {
                densityMultiplier = 1.5  // Rural, easier to identify
            } else if density > 10000 {
                densityMultiplier = 0.7  // Dense urban, harder to identify
            }
        }

        // Calculate overall score
        let rawScore = (locationScore * 0.35 +
                       temporalScore * 0.20 +
                       volumeScore * 0.25 +
                       sensitivityScore * 0.20) * densityMultiplier

        let overallScore = min(max(rawScore, 0.0), 1.0)

        // Determine risk level
        let riskLevel: ReidentificationRiskScore.RiskLevel
        switch overallScore {
        case 0..<0.10:
            riskLevel = .low
        case 0.10..<0.25:
            riskLevel = .medium
        case 0.25..<0.50:
            riskLevel = .high
        default:
            riskLevel = .critical
        }

        // Determine mitigations
        var mitigations: [ReidentificationRiskScore.Mitigation] = []

        if locationScore > 0.5 {
            mitigations.append(.snapToGrid)
        }
        if volumeScore > 0.5 {
            mitigations.append(.downsampleTrajectory)
        }
        if temporalScore > 0.5 {
            mitigations.append(.addTemporalNoise)
        }
        if factors.hasDeviceIdentifiers {
            mitigations.append(.removeDeviceIds)
        }
        if overallScore > config.maxLocationReidentificationRisk {
            mitigations.append(.applyDifferentialPrivacy)
            mitigations.append(.requireExplicitConsent)
        }
        if overallScore > 0.5 {
            mitigations.append(.blockUpload)
        }

        return ReidentificationRiskScore(
            overallScore: overallScore,
            locationScore: locationScore,
            temporalScore: temporalScore,
            volumeScore: volumeScore,
            sensitivityScore: sensitivityScore,
            riskLevel: riskLevel,
            recommendedMitigations: mitigations
        )
    }

    /// Check if data passes privacy threshold
    public func passesPrivacyThreshold(_ score: ReidentificationRiskScore) -> Bool {
        return score.overallScore <= config.maxLocationReidentificationRisk
    }

    /// Apply high-risk data policy
    public func applyHighRiskPolicy(_ score: ReidentificationRiskScore) -> HighRiskPolicyDecision {
        if passesPrivacyThreshold(score) {
            return HighRiskPolicyDecision(
                action: .allow,
                reason: "Risk score \(score.overallScore) within threshold \(config.maxLocationReidentificationRisk)"
            )
        }

        switch config.highRiskDataPolicy {
        case .allow:
            return HighRiskPolicyDecision(
                action: .allow,
                reason: "High risk policy set to allow"
            )
        case .warn:
            return HighRiskPolicyDecision(
                action: .warnAndAllow,
                reason: "High risk detected, logged warning"
            )
        case .localOnlyForbidUpload:
            return HighRiskPolicyDecision(
                action: .blockUpload,
                reason: "High risk data blocked from upload"
            )
        case .deleteImmediately:
            return HighRiskPolicyDecision(
                action: .delete,
                reason: "High risk data marked for deletion"
            )
        }
    }
}

/// High risk policy decision
public struct HighRiskPolicyDecision: Sendable {
    public let action: Action
    public let reason: String

    public enum Action: String, Sendable {
        case allow
        case warnAndAllow
        case blockUpload
        case delete
    }
}
```

### STAGE AH-002: TrajectoryAnonymizer.swift

```swift
// InferencePrivacy/TrajectoryAnonymizer.swift
// STAGE AH-002: Trajectory anonymization for location privacy
// Vulnerability: PRIVACY-004, PRIVACY-005
// Reference: https://arxiv.org/abs/1706.08336 (Trajectory Anonymization)

import Foundation

/// Location point for trajectory
public struct LocationPoint: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Date
    public let accuracy: Double?

    public init(latitude: Double, longitude: Double, timestamp: Date, accuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.accuracy = accuracy
    }
}

/// Anonymized trajectory
public struct AnonymizedTrajectory: Codable, Sendable {
    public let originalPointCount: Int
    public let anonymizedPointCount: Int
    public let points: [LocationPoint]
    public let anonymizationMethod: AnonymizationMethod
    public let privacyBudgetConsumed: Double  // Differential privacy epsilon consumed

    public enum AnonymizationMethod: String, Codable, Sendable {
        case downsampling
        case gridSnapping
        case temporalJittering
        case spatialNoise
        case combined
    }
}

/// Trajectory Anonymizer
@available(iOS 15.0, macOS 12.0, *)
public actor TrajectoryAnonymizer {

    private let config: PrivacyAttackConfig

    public init(config: PrivacyAttackConfig) {
        self.config = config
    }

    /// Anonymize a trajectory using multiple techniques
    public func anonymize(_ points: [LocationPoint]) -> AnonymizedTrajectory {
        var anonymizedPoints = points
        var methodsApplied: [AnonymizedTrajectory.AnonymizationMethod] = []
        var privacyBudget = 0.0

        // 1. Downsampling
        if config.trajectoryDownsampleFactor > 1 {
            anonymizedPoints = downsample(anonymizedPoints, factor: config.trajectoryDownsampleFactor)
            methodsApplied.append(.downsampling)
        }

        // 2. Grid snapping (reduce precision)
        let gridSize = calculateGridSize()
        anonymizedPoints = snapToGrid(anonymizedPoints, gridSizeMeters: gridSize)
        methodsApplied.append(.gridSnapping)

        // 3. Temporal jittering
        anonymizedPoints = addTemporalJitter(anonymizedPoints)
        methodsApplied.append(.temporalJittering)

        // 4. Spatial noise (Laplacian for differential privacy)
        if config.differentialPrivacyEpsilon < Double.infinity {
            anonymizedPoints = addSpatialNoise(anonymizedPoints, epsilon: config.differentialPrivacyEpsilon)
            privacyBudget = config.differentialPrivacyEpsilon
            methodsApplied.append(.spatialNoise)
        }

        let method: AnonymizedTrajectory.AnonymizationMethod = methodsApplied.count > 1 ? .combined : methodsApplied.first ?? .downsampling

        return AnonymizedTrajectory(
            originalPointCount: points.count,
            anonymizedPointCount: anonymizedPoints.count,
            points: anonymizedPoints,
            anonymizationMethod: method,
            privacyBudgetConsumed: privacyBudget
        )
    }

    // MARK: - Private Methods

    private func downsample(_ points: [LocationPoint], factor: Int) -> [LocationPoint] {
        guard factor > 1 else { return points }

        var result: [LocationPoint] = []
        for (index, point) in points.enumerated() {
            if index % factor == 0 {
                result.append(point)
            }
        }

        // Always include last point
        if let last = points.last, result.last != last {
            result.append(last)
        }

        return result
    }

    private func snapToGrid(_ points: [LocationPoint], gridSizeMeters: Double) -> [LocationPoint] {
        // Convert grid size from meters to degrees (approximate)
        let metersPerDegree = 111000.0  // At equator
        let gridSizeDegrees = gridSizeMeters / metersPerDegree

        return points.map { point in
            let snappedLat = (point.latitude / gridSizeDegrees).rounded() * gridSizeDegrees
            let snappedLon = (point.longitude / gridSizeDegrees).rounded() * gridSizeDegrees

            return LocationPoint(
                latitude: snappedLat,
                longitude: snappedLon,
                timestamp: point.timestamp,
                accuracy: max(point.accuracy ?? 0, gridSizeMeters)
            )
        }
    }

    private func addTemporalJitter(_ points: [LocationPoint]) -> [LocationPoint] {
        // Add random jitter of up to ±30 seconds
        let maxJitter: TimeInterval = 30

        return points.map { point in
            let jitter = TimeInterval.random(in: -maxJitter...maxJitter)
            return LocationPoint(
                latitude: point.latitude,
                longitude: point.longitude,
                timestamp: point.timestamp.addingTimeInterval(jitter),
                accuracy: point.accuracy
            )
        }
    }

    private func addSpatialNoise(_ points: [LocationPoint], epsilon: Double) -> [LocationPoint] {
        // Add Laplacian noise for differential privacy
        // Sensitivity = 1 (assuming normalized coordinates)
        let scale = 1.0 / epsilon

        return points.map { point in
            let noiseLat = laplacianNoise(scale: scale)
            let noiseLon = laplacianNoise(scale: scale)

            // Convert noise to small coordinate offset (approximately ±100m at scale=1)
            let metersPerDegree = 111000.0
            let noiseMeters = 100.0  // Base noise level in meters

            return LocationPoint(
                latitude: point.latitude + (noiseLat * noiseMeters / metersPerDegree),
                longitude: point.longitude + (noiseLon * noiseMeters / metersPerDegree),
                timestamp: point.timestamp,
                accuracy: (point.accuracy ?? 0) + noiseMeters * scale
            )
        }
    }

    private func laplacianNoise(scale: Double) -> Double {
        // Generate Laplacian noise using inverse CDF method
        let u = Double.random(in: 0..<1) - 0.5
        return -scale * sign(u) * log(1 - 2 * abs(u))
    }

    private func sign(_ x: Double) -> Double {
        return x >= 0 ? 1 : -1
    }

    private func calculateGridSize() -> Double {
        // Grid size based on risk threshold
        // Lower risk threshold = larger grid = less precision
        switch config.maxLocationReidentificationRisk {
        case 0..<0.05:
            return 500.0   // 500m grid
        case 0.05..<0.10:
            return 200.0   // 200m grid
        case 0.10..<0.25:
            return 100.0   // 100m grid
        default:
            return 50.0    // 50m grid
        }
    }
}
```

---

## PART AI: CONSENT & POLICY UX CONTRACT

### AI.1 Problem Statement

**Vulnerability ID**: CONSENT-001 through CONSENT-012
**Severity**: CRITICAL (Compliance)
**Category**: GDPR, Verifiable Consent, Withdrawal

Current gaps:
1. No verifiable consent receipts
2. Consent not version-bound to session
3. Withdrawal not propagating fast enough
4. Missing consent evidence for audits

### AI.2 Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    CONSENT MANAGEMENT ARCHITECTURE                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CONSENT RECEIPT:                                                       │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • Cryptographically signed                                       │   │
│  │ • Version-bound (policy version + session ID)                    │   │
│  │ • Timestamped                                                    │   │
│  │ • Purpose-specific                                               │   │
│  │ • Retention: 7 years (compliance)                                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  CONSENT FLOW:                                                         │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ User Action → Consent UI → Generate Receipt → Store → Bind to  │    │
│  │                              │                         Session │    │
│  │                              ▼                                  │    │
│  │                        Emit Audit Event                         │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  WITHDRAWAL FLOW:                                                      │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Withdrawal Request → Validate → Propagate → Block Operations   │    │
│  │        │                                           │            │    │
│  │        ▼                                           ▼            │    │
│  │  P99 < 5 seconds (lab)                    Mark Sessions Invalid │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  VERSION REGISTRY:                                                     │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • Each policy version immutable                                  │   │
│  │ • Version hash included in receipt                               │   │
│  │ • Audit trail of all versions                                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AI.3 Implementation Files

```
New Files:
├── Consent/
│   ├── ConsentReceipt.swift                 (STAGE AI-001)
│   ├── ConsentVersionRegistry.swift         (STAGE AI-002)
│   ├── WithdrawalEnforcer.swift             (STAGE AI-003)
│   ├── ConsentPurpose.swift                 (STAGE AI-004)
│   └── ConsentAuditEmitter.swift            (STAGE AI-005)
└── Tests/
    └── ConsentManagementTests.swift         (STAGE AI-006)
```

### STAGE AI-001: ConsentReceipt.swift

```swift
// Consent/ConsentReceipt.swift
// STAGE AI-001: Verifiable consent receipt
// Vulnerability: CONSENT-001, CONSENT-002, CONSENT-003
// Reference: https://kantarainitiative.org/download/consent-receipt-specification-v1-1-0/

import Foundation
import CryptoKit

/// Consent management configuration
public struct ConsentConfig: Codable, Sendable {
    /// Whether consent is required for upload
    public let consentRequiredForUpload: Bool

    /// Consent receipt retention in days
    public let consentReceiptRetentionDays: Int

    /// P99 latency for withdrawal propagation (seconds)
    public let withdrawalEffectiveP99Sec: Int

    /// Whether to require re-consent on policy update
    public let requireReconsentOnPolicyUpdate: Bool

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> ConsentConfig {
        switch profile {
        case .production:
            return ConsentConfig(
                consentRequiredForUpload: true,
                consentReceiptRetentionDays: 2555,  // 7 years
                withdrawalEffectiveP99Sec: 60,
                requireReconsentOnPolicyUpdate: true
            )
        case .debug:
            return ConsentConfig(
                consentRequiredForUpload: false,
                consentReceiptRetentionDays: 365,
                withdrawalEffectiveP99Sec: 300,
                requireReconsentOnPolicyUpdate: false
            )
        case .lab:
            return ConsentConfig(
                consentRequiredForUpload: true,
                consentReceiptRetentionDays: 2555,  // Keep long for testing
                withdrawalEffectiveP99Sec: 5,       // EXTREME
                requireReconsentOnPolicyUpdate: true
            )
        }
    }
}

/// Consent purposes (closed set - GDPR Article 6 bases)
public enum ConsentPurpose: String, Codable, Sendable, CaseIterable {
    case capture          // Capture and store images
    case processing       // Process images (quality analysis)
    case upload           // Upload to cloud
    case training         // Use for ML model training
    case analytics        // Use for aggregate analytics
    case thirdParty       // Share with third parties
    case marketing        // Marketing communications
}

/// Consent receipt - verifiable proof of consent
public struct ConsentReceipt: Codable, Sendable {

    // MARK: - Receipt Identification

    /// Unique receipt ID
    public let receiptId: String

    /// Receipt version (format version)
    public let receiptVersion: String

    /// When consent was given
    public let consentedAt: Date

    // MARK: - Subject Identification

    /// User/subject identifier (hashed for privacy)
    public let subjectIdHash: String

    /// Session this consent is bound to
    public let boundSessionId: String?

    // MARK: - Consent Details

    /// Purposes consented to
    public let purposes: [ConsentPurpose]

    /// Policy version at time of consent
    public let policyVersion: String

    /// Hash of the policy document
    public let policyDocumentHash: String

    /// Consent method (how consent was obtained)
    public let consentMethod: ConsentMethod

    // MARK: - Validity

    /// When this consent expires (if time-limited)
    public let expiresAt: Date?

    /// Whether consent has been withdrawn
    public let withdrawn: Bool

    /// When consent was withdrawn
    public let withdrawnAt: Date?

    // MARK: - Cryptographic Proof

    /// Signature over receipt content
    public let signature: String

    /// Signing key identifier
    public let signingKeyId: String

    /// Hash of the entire receipt (for integrity)
    public let receiptHash: String

    // MARK: - Nested Types

    public enum ConsentMethod: String, Codable, Sendable {
        case explicitOptIn      // User clicked "I agree"
        case implicitContinued  // Continued use implies consent (less valid)
        case apiCall            // Consent via API
        case parentalConsent    // Guardian consented (for minors)
    }

    /// Check if consent is currently valid
    public var isValid: Bool {
        if withdrawn {
            return false
        }
        if let expiry = expiresAt, Date() > expiry {
            return false
        }
        return true
    }

    /// Check if consent covers a specific purpose
    public func covers(purpose: ConsentPurpose) -> Bool {
        return isValid && purposes.contains(purpose)
    }
}

/// Consent Receipt Generator
@available(iOS 15.0, macOS 12.0, *)
public actor ConsentReceiptGenerator {

    private let config: ConsentConfig
    private let signingKey: P256.Signing.PrivateKey
    private let signingKeyId: String

    public init(config: ConsentConfig, signingKey: P256.Signing.PrivateKey, signingKeyId: String) {
        self.config = config
        self.signingKey = signingKey
        self.signingKeyId = signingKeyId
    }

    /// Generate a new consent receipt
    public func generate(
        subjectId: String,
        purposes: [ConsentPurpose],
        policyVersion: String,
        policyDocumentHash: String,
        method: ConsentReceipt.ConsentMethod,
        boundSessionId: String? = nil,
        expiresAt: Date? = nil
    ) throws -> ConsentReceipt {

        let receiptId = UUID().uuidString
        let now = Date()

        // Hash subject ID for privacy
        let subjectIdHash = SHA256.hash(data: Data(subjectId.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        // Create receipt content for signing
        let contentForSigning = [
            receiptId,
            subjectIdHash,
            purposes.map { $0.rawValue }.sorted().joined(separator: ","),
            policyVersion,
            policyDocumentHash,
            String(now.timeIntervalSince1970)
        ].joined(separator: "|")

        // Sign the content
        let signature = try signingKey.signature(for: Data(contentForSigning.utf8))

        // Calculate receipt hash
        let receiptHash = SHA256.hash(data: Data(contentForSigning.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        return ConsentReceipt(
            receiptId: receiptId,
            receiptVersion: "1.0",
            consentedAt: now,
            subjectIdHash: subjectIdHash,
            boundSessionId: boundSessionId,
            purposes: purposes,
            policyVersion: policyVersion,
            policyDocumentHash: policyDocumentHash,
            consentMethod: method,
            expiresAt: expiresAt,
            withdrawn: false,
            withdrawnAt: nil,
            signature: signature.derRepresentation.base64EncodedString(),
            signingKeyId: signingKeyId,
            receiptHash: receiptHash
        )
    }

    /// Verify a consent receipt's signature
    public func verify(_ receipt: ConsentReceipt, publicKey: P256.Signing.PublicKey) throws -> Bool {
        // Recreate content that was signed
        let contentForSigning = [
            receipt.receiptId,
            receipt.subjectIdHash,
            receipt.purposes.map { $0.rawValue }.sorted().joined(separator: ","),
            receipt.policyVersion,
            receipt.policyDocumentHash,
            String(receipt.consentedAt.timeIntervalSince1970)
        ].joined(separator: "|")

        guard let signatureData = Data(base64Encoded: receipt.signature) else {
            throw ConsentError.invalidSignatureFormat
        }

        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)

        return publicKey.isValidSignature(signature, for: Data(contentForSigning.utf8))
    }
}

/// Consent errors
public enum ConsentError: Error, LocalizedError {
    case consentRequired(purpose: ConsentPurpose)
    case consentWithdrawn(receiptId: String)
    case consentExpired(receiptId: String)
    case policyVersionMismatch(expected: String, actual: String)
    case invalidSignatureFormat
    case signatureVerificationFailed
    case withdrawalPropagationTimeout

    public var errorDescription: String? {
        switch self {
        case .consentRequired(let purpose):
            return "Consent required for: \(purpose.rawValue)"
        case .consentWithdrawn(let id):
            return "Consent has been withdrawn: \(id)"
        case .consentExpired(let id):
            return "Consent has expired: \(id)"
        case .policyVersionMismatch(let expected, let actual):
            return "Policy version mismatch: expected \(expected), got \(actual)"
        case .invalidSignatureFormat:
            return "Invalid consent receipt signature format"
        case .signatureVerificationFailed:
            return "Consent receipt signature verification failed"
        case .withdrawalPropagationTimeout:
            return "Consent withdrawal propagation timed out"
        }
    }
}
```

### STAGE AI-003: WithdrawalEnforcer.swift

```swift
// Consent/WithdrawalEnforcer.swift
// STAGE AI-003: Fast consent withdrawal propagation
// Vulnerability: CONSENT-004, CONSENT-005
// Reference: GDPR Article 7(3) - Right to withdraw consent

import Foundation

/// Withdrawal request
public struct WithdrawalRequest: Codable, Sendable {
    public let requestId: String
    public let subjectIdHash: String
    public let receiptIds: [String]?  // nil = withdraw all
    public let purposes: [ConsentPurpose]?  // nil = all purposes
    public let requestedAt: Date
    public let reason: WithdrawalReason?

    public enum WithdrawalReason: String, Codable, Sendable {
        case userRequest
        case parentalRevocation
        case accountDeletion
        case legalRequirement
    }
}

/// Withdrawal result
public struct WithdrawalResult: Codable, Sendable {
    public let requestId: String
    public let success: Bool
    public let withdrawnReceiptIds: [String]
    public let propagationTimeMs: Int64
    public let blockedSessions: [String]
    public let errors: [String]
}

/// Withdrawal Enforcer
@available(iOS 15.0, macOS 12.0, *)
public actor WithdrawalEnforcer {

    private let config: ConsentConfig
    private var activeConsents: [String: ConsentReceipt] = [:]
    private var withdrawnSubjects: Set<String> = []

    public init(config: ConsentConfig) {
        self.config = config
    }

    /// Process a withdrawal request
    public func processWithdrawal(_ request: WithdrawalRequest) async throws -> WithdrawalResult {
        let startTime = Date()
        var withdrawnIds: [String] = []
        var blockedSessions: [String] = []
        var errors: [String] = []

        // Find matching consents
        let matchingConsents = activeConsents.filter { id, receipt in
            // Match by subject
            guard receipt.subjectIdHash == request.subjectIdHash else {
                return false
            }

            // Match by receipt ID if specified
            if let requestedIds = request.receiptIds {
                return requestedIds.contains(id)
            }

            // Match by purpose if specified
            if let requestedPurposes = request.purposes {
                return receipt.purposes.contains { requestedPurposes.contains($0) }
            }

            return true
        }

        // Withdraw each consent
        for (id, receipt) in matchingConsents {
            // Mark as withdrawn
            let withdrawnReceipt = ConsentReceipt(
                receiptId: receipt.receiptId,
                receiptVersion: receipt.receiptVersion,
                consentedAt: receipt.consentedAt,
                subjectIdHash: receipt.subjectIdHash,
                boundSessionId: receipt.boundSessionId,
                purposes: receipt.purposes,
                policyVersion: receipt.policyVersion,
                policyDocumentHash: receipt.policyDocumentHash,
                consentMethod: receipt.consentMethod,
                expiresAt: receipt.expiresAt,
                withdrawn: true,
                withdrawnAt: Date(),
                signature: receipt.signature,
                signingKeyId: receipt.signingKeyId,
                receiptHash: receipt.receiptHash
            )

            activeConsents[id] = withdrawnReceipt
            withdrawnIds.append(id)

            // Block associated session
            if let sessionId = receipt.boundSessionId {
                blockedSessions.append(sessionId)
            }
        }

        // Mark subject as withdrawn (for fast lookups)
        withdrawnSubjects.insert(request.subjectIdHash)

        let propagationTime = Int64(Date().timeIntervalSince(startTime) * 1000)

        // Check against P99 target
        let targetMs = Int64(config.withdrawalEffectiveP99Sec * 1000)
        if propagationTime > targetMs {
            errors.append("Propagation time \(propagationTime)ms exceeded target \(targetMs)ms")
        }

        return WithdrawalResult(
            requestId: request.requestId,
            success: errors.isEmpty,
            withdrawnReceiptIds: withdrawnIds,
            propagationTimeMs: propagationTime,
            blockedSessions: blockedSessions,
            errors: errors
        )
    }

    /// Check if a subject has withdrawn consent
    public func hasWithdrawn(subjectIdHash: String) -> Bool {
        return withdrawnSubjects.contains(subjectIdHash)
    }

    /// Validate consent for an operation
    public func validateConsent(
        subjectIdHash: String,
        purpose: ConsentPurpose,
        policyVersion: String
    ) throws {
        // Quick check for withdrawn subjects
        if withdrawnSubjects.contains(subjectIdHash) {
            throw ConsentError.consentWithdrawn(receiptId: "all")
        }

        // Find valid consent
        let validConsent = activeConsents.values.first { receipt in
            receipt.subjectIdHash == subjectIdHash &&
            receipt.isValid &&
            receipt.covers(purpose: purpose)
        }

        guard let consent = validConsent else {
            throw ConsentError.consentRequired(purpose: purpose)
        }

        // Check policy version
        if config.requireReconsentOnPolicyUpdate && consent.policyVersion != policyVersion {
            throw ConsentError.policyVersionMismatch(expected: policyVersion, actual: consent.policyVersion)
        }
    }

    /// Register a new consent
    public func registerConsent(_ receipt: ConsentReceipt) {
        activeConsents[receipt.receiptId] = receipt

        // Remove from withdrawn set if re-consenting
        withdrawnSubjects.remove(receipt.subjectIdHash)
    }
}
```

---

## PART AJ: INCIDENT RESPONSE & RED TEAM LOOP

### AJ.1 Problem Statement

**Vulnerability ID**: INCIDENT-001 through INCIDENT-012
**Severity**: CRITICAL
**Category**: Incident Detection, Response, Learning Loop

Current gaps:
1. No formal incident severity classification
2. No automated containment triggers
3. No red team → test fixture → gate pipeline
4. Postmortems not feeding back to risk register

### AJ.2 Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    INCIDENT RESPONSE ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  SEVERITY CLASSIFICATION (Closed Set):                                 │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ P0 - Critical: Data breach, service down, security compromise    │   │
│  │ P1 - High: Major feature broken, significant data loss           │   │
│  │ P2 - Medium: Feature degraded, minor data inconsistency          │   │
│  │ P3 - Low: Cosmetic issues, minor bugs                            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  INCIDENT LIFECYCLE:                                                   │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Detection → Classification → Containment → Mitigation →        │    │
│  │                                             Postmortem          │    │
│  │     │           │              │              │                 │    │
│  │     ▼           ▼              ▼              ▼                 │    │
│  │ Auto-detect  P0/P1/P2/P3   Kill Switch   Root Cause            │    │
│  │ (30s P99)                  (auto for P0)  Analysis              │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  RED TEAM → GATE LOOP:                                                 │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Red Team Attack → Capture as Test Scenario → Add to Test       │    │
│  │      │                                       Suite → Create    │    │
│  │      ▼                                       Quality Gate →    │    │
│  │ Document in                                  Update Risk       │    │
│  │ Risk Register                                Register          │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  AUTOMATED CONTAINMENT:                                                │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ • P0 → Auto kill switch + page on-call                          │   │
│  │ • P1 → Alert + manual kill switch available                     │   │
│  │ • P2 → Alert + ticket                                           │   │
│  │ • P3 → Log + backlog                                            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AJ.3 Implementation Files

```
New Files:
├── IncidentResponse/
│   ├── IncidentSeverity.swift               (STAGE AJ-001)
│   ├── IncidentRunbook.swift                (STAGE AJ-002)
│   ├── AutoContainmentPolicy.swift          (STAGE AJ-003)
│   ├── RedTeamScenarioSuite.swift           (STAGE AJ-004)
│   └── PostmortemToGateCompiler.swift       (STAGE AJ-005)
└── Tests/
    └── IncidentResponseTests.swift          (STAGE AJ-006)
```

### STAGE AJ-001: IncidentSeverity.swift

```swift
// IncidentResponse/IncidentSeverity.swift
// STAGE AJ-001: Incident severity classification and response
// Vulnerability: INCIDENT-001, INCIDENT-002
// Reference: https://response.pagerduty.com/oncall/being_oncall/

import Foundation

/// Incident response configuration
public struct IncidentResponseConfig: Codable, Sendable {
    /// P99 time from detection to containment (seconds)
    public let p0DetectToContainP99Sec: Int

    /// Auto-trigger kill switch on P0
    public let autoKillSwitchOnP0: Bool

    /// Number of red team scenarios required per release
    public let redTeamScenariosPerRelease: Int

    /// Maximum time before postmortem must be completed (hours)
    public let postmortemDeadlineHours: Int

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> IncidentResponseConfig {
        switch profile {
        case .production:
            return IncidentResponseConfig(
                p0DetectToContainP99Sec: 300,    // 5 minutes
                autoKillSwitchOnP0: true,
                redTeamScenariosPerRelease: 5,
                postmortemDeadlineHours: 72
            )
        case .debug:
            return IncidentResponseConfig(
                p0DetectToContainP99Sec: 600,
                autoKillSwitchOnP0: false,
                redTeamScenariosPerRelease: 2,
                postmortemDeadlineHours: 168
            )
        case .lab:
            return IncidentResponseConfig(
                p0DetectToContainP99Sec: 30,     // EXTREME
                autoKillSwitchOnP0: true,
                redTeamScenariosPerRelease: 20,  // EXTREME
                postmortemDeadlineHours: 24
            )
        }
    }
}

/// Incident severity (closed set)
public enum IncidentSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case p0 = "P0"  // Critical
    case p1 = "P1"  // High
    case p2 = "P2"  // Medium
    case p3 = "P3"  // Low

    public static func < (lhs: IncidentSeverity, rhs: IncidentSeverity) -> Bool {
        let order: [IncidentSeverity] = [.p0, .p1, .p2, .p3]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    /// Description of this severity level
    public var description: String {
        switch self {
        case .p0:
            return "Critical: Data breach, complete service outage, or active security compromise"
        case .p1:
            return "High: Major feature completely broken, significant data loss/corruption"
        case .p2:
            return "Medium: Feature degraded, minor data inconsistency, workaround available"
        case .p3:
            return "Low: Cosmetic issues, minor bugs, documentation errors"
        }
    }

    /// Response time target (seconds)
    public var responseTimeTarget: Int {
        switch self {
        case .p0: return 300     // 5 minutes
        case .p1: return 1800    // 30 minutes
        case .p2: return 14400   // 4 hours
        case .p3: return 86400   // 24 hours
        }
    }

    /// Whether this requires immediate escalation
    public var requiresImmediateEscalation: Bool {
        switch self {
        case .p0, .p1: return true
        case .p2, .p3: return false
        }
    }
}

/// Incident category (closed set)
public enum IncidentCategory: String, Codable, Sendable, CaseIterable {
    case security           // Security breach, unauthorized access
    case dataLoss           // Data corruption, deletion
    case serviceOutage      // Complete or partial outage
    case performance        // Severe degradation
    case compliance         // Regulatory violation
    case privacy            // Privacy breach
    case integrity          // Data/system integrity issue
}

/// Incident record
public struct Incident: Codable, Sendable {
    public let incidentId: String
    public let severity: IncidentSeverity
    public let category: IncidentCategory
    public let title: String
    public let description: String
    public let detectedAt: Date
    public let containedAt: Date?
    public let resolvedAt: Date?
    public let status: IncidentStatus
    public let affectedSystems: [String]
    public let affectedTenants: [String]
    public let timeline: [IncidentTimelineEntry]
    public let assignee: String?
    public let postmortemId: String?

    public enum IncidentStatus: String, Codable, Sendable {
        case detected
        case acknowledged
        case investigating
        case contained
        case mitigating
        case resolved
        case postmortem
        case closed
    }

    /// Time to containment (nil if not yet contained)
    public var timeToContainment: TimeInterval? {
        guard let contained = containedAt else { return nil }
        return contained.timeIntervalSince(detectedAt)
    }
}

/// Incident timeline entry
public struct IncidentTimelineEntry: Codable, Sendable {
    public let timestamp: Date
    public let action: TimelineAction
    public let actor: String
    public let details: String

    public enum TimelineAction: String, Codable, Sendable {
        case detected
        case acknowledged
        case escalated
        case killSwitchActivated
        case investigationStarted
        case rootCauseIdentified
        case mitigationApplied
        case resolved
        case postmortemStarted
        case postmortemCompleted
    }
}

/// Incident Manager
@available(iOS 15.0, macOS 12.0, *)
public actor IncidentManager {

    private let config: IncidentResponseConfig
    private var activeIncidents: [String: Incident] = [:]
    private var incidentHistory: [Incident] = []

    public init(config: IncidentResponseConfig) {
        self.config = config
    }

    /// Create a new incident
    public func createIncident(
        severity: IncidentSeverity,
        category: IncidentCategory,
        title: String,
        description: String,
        affectedSystems: [String],
        affectedTenants: [String]
    ) async -> Incident {

        let incidentId = "INC-\(UUID().uuidString.prefix(8))"
        let now = Date()

        let incident = Incident(
            incidentId: incidentId,
            severity: severity,
            category: category,
            title: title,
            description: description,
            detectedAt: now,
            containedAt: nil,
            resolvedAt: nil,
            status: .detected,
            affectedSystems: affectedSystems,
            affectedTenants: affectedTenants,
            timeline: [
                IncidentTimelineEntry(
                    timestamp: now,
                    action: .detected,
                    actor: "system",
                    details: "Incident automatically detected"
                )
            ],
            assignee: nil,
            postmortemId: nil
        )

        activeIncidents[incidentId] = incident

        // Auto-trigger containment for P0
        if severity == .p0 && config.autoKillSwitchOnP0 {
            await triggerAutoContainment(incidentId: incidentId)
        }

        return incident
    }

    /// Trigger automatic containment (kill switch)
    private func triggerAutoContainment(incidentId: String) async {
        guard var incident = activeIncidents[incidentId] else { return }

        var timeline = incident.timeline
        timeline.append(IncidentTimelineEntry(
            timestamp: Date(),
            action: .killSwitchActivated,
            actor: "auto-containment",
            details: "Kill switch automatically activated for P0 incident"
        ))

        incident = Incident(
            incidentId: incident.incidentId,
            severity: incident.severity,
            category: incident.category,
            title: incident.title,
            description: incident.description,
            detectedAt: incident.detectedAt,
            containedAt: Date(),
            resolvedAt: incident.resolvedAt,
            status: .contained,
            affectedSystems: incident.affectedSystems,
            affectedTenants: incident.affectedTenants,
            timeline: timeline,
            assignee: incident.assignee,
            postmortemId: incident.postmortemId
        )

        activeIncidents[incidentId] = incident
    }

    /// Check if response time SLA is being met
    public func checkResponseTimeSLA(incidentId: String) -> ResponseTimeSLAResult {
        guard let incident = activeIncidents[incidentId] else {
            return ResponseTimeSLAResult(met: false, reason: "Incident not found")
        }

        let target = incident.severity.responseTimeTarget
        let elapsed = Date().timeIntervalSince(incident.detectedAt)

        // P0 uses config-specific target
        let actualTarget: Int
        if incident.severity == .p0 {
            actualTarget = config.p0DetectToContainP99Sec
        } else {
            actualTarget = target
        }

        let met = elapsed <= TimeInterval(actualTarget)

        return ResponseTimeSLAResult(
            met: met,
            targetSeconds: actualTarget,
            elapsedSeconds: Int(elapsed),
            reason: met ? nil : "Elapsed \(Int(elapsed))s exceeds target \(actualTarget)s"
        )
    }

    /// Mark incident as resolved
    public func resolveIncident(incidentId: String, resolution: String) {
        guard var incident = activeIncidents[incidentId] else { return }

        var timeline = incident.timeline
        timeline.append(IncidentTimelineEntry(
            timestamp: Date(),
            action: .resolved,
            actor: incident.assignee ?? "system",
            details: resolution
        ))

        incident = Incident(
            incidentId: incident.incidentId,
            severity: incident.severity,
            category: incident.category,
            title: incident.title,
            description: incident.description,
            detectedAt: incident.detectedAt,
            containedAt: incident.containedAt ?? Date(),
            resolvedAt: Date(),
            status: .resolved,
            affectedSystems: incident.affectedSystems,
            affectedTenants: incident.affectedTenants,
            timeline: timeline,
            assignee: incident.assignee,
            postmortemId: incident.postmortemId
        )

        // Move to history
        incidentHistory.append(incident)
        activeIncidents.removeValue(forKey: incidentId)
    }
}

/// Response time SLA result
public struct ResponseTimeSLAResult: Sendable {
    public let met: Bool
    public let targetSeconds: Int?
    public let elapsedSeconds: Int?
    public let reason: String?

    public init(met: Bool, targetSeconds: Int? = nil, elapsedSeconds: Int? = nil, reason: String? = nil) {
        self.met = met
        self.targetSeconds = targetSeconds
        self.elapsedSeconds = elapsedSeconds
        self.reason = reason
    }
}
```

### STAGE AJ-004: RedTeamScenarioSuite.swift

```swift
// IncidentResponse/RedTeamScenarioSuite.swift
// STAGE AJ-004: Red team scenarios feeding back to test gates
// Vulnerability: INCIDENT-005, INCIDENT-006
// Reference: MITRE ATT&CK Framework

import Foundation

/// Red team scenario
public struct RedTeamScenario: Codable, Sendable {
    public let scenarioId: String
    public let name: String
    public let description: String
    public let category: AttackCategory
    public let mitreTacticIds: [String]
    public let mitreTechniqueIds: [String]
    public let severity: IncidentSeverity
    public let attackVector: String
    public let preconditions: [String]
    public let steps: [AttackStep]
    public let expectedOutcome: ExpectedOutcome
    public let defenseValidation: DefenseValidation
    public let createdAt: Date
    public let lastTestedAt: Date?
    public let lastTestPassed: Bool?

    /// Attack category (closed set)
    public enum AttackCategory: String, Codable, Sendable, CaseIterable {
        case injectionAttack        // Prompt injection, code injection
        case authBypass             // Authentication/authorization bypass
        case dataExfiltration       // Unauthorized data access
        case dosAttack              // Denial of service
        case privacyAttack          // Re-identification, inference
        case supplyChainAttack      // Dependency poisoning
        case cryptoAttack           // Key compromise, crypto weakness
        case socialEngineering      // Phishing, pretexting
    }

    /// Attack step
    public struct AttackStep: Codable, Sendable {
        public let stepNumber: Int
        public let action: String
        public let expectedResult: String
        public let detectionPoint: String?
    }

    /// Expected outcome
    public enum ExpectedOutcome: String, Codable, Sendable {
        case blocked            // Attack should be blocked
        case detected           // Attack should be detected
        case contained          // Attack should be contained
        case alertGenerated     // Alert should be generated
    }

    /// Defense validation
    public struct DefenseValidation: Codable, Sendable {
        public let defenseId: String
        public let defenseName: String
        public let expectedBehavior: String
        public let gateId: String?      // Quality gate this validates
        public let riskRegisterId: String?  // Risk register entry
    }
}

/// Red Team Scenario Manager
@available(iOS 15.0, macOS 12.0, *)
public actor RedTeamScenarioManager {

    private let config: IncidentResponseConfig
    private var scenarios: [RedTeamScenario] = []
    private var testResults: [String: RedTeamTestResult] = [:]

    public init(config: IncidentResponseConfig) {
        self.config = config
    }

    /// Register a red team scenario
    public func registerScenario(_ scenario: RedTeamScenario) {
        scenarios.append(scenario)
    }

    /// Check if release has sufficient red team coverage
    public func checkReleaseCoverage() -> ReleaseCoverageResult {
        let testedScenarios = scenarios.filter { $0.lastTestedAt != nil }
        let passedScenarios = scenarios.filter { $0.lastTestPassed == true }

        let meetsRequirement = testedScenarios.count >= config.redTeamScenariosPerRelease

        // Check category coverage
        var categoryCoverage: [RedTeamScenario.AttackCategory: Int] = [:]
        for scenario in testedScenarios {
            categoryCoverage[scenario.category, default: 0] += 1
        }

        let missingCategories = RedTeamScenario.AttackCategory.allCases.filter {
            categoryCoverage[$0, default: 0] == 0
        }

        return ReleaseCoverageResult(
            meetsRequirement: meetsRequirement,
            requiredScenarios: config.redTeamScenariosPerRelease,
            testedScenarios: testedScenarios.count,
            passedScenarios: passedScenarios.count,
            categoryCoverage: categoryCoverage.mapKeys { $0.rawValue },
            missingCategories: missingCategories.map { $0.rawValue }
        )
    }

    /// Record test result for a scenario
    public func recordTestResult(
        scenarioId: String,
        passed: Bool,
        details: String,
        defenseTriggered: Bool,
        detectionTimeMs: Int64?
    ) {
        let result = RedTeamTestResult(
            scenarioId: scenarioId,
            testedAt: Date(),
            passed: passed,
            details: details,
            defenseTriggered: defenseTriggered,
            detectionTimeMs: detectionTimeMs
        )

        testResults[scenarioId] = result

        // Update scenario's last test info
        if let index = scenarios.firstIndex(where: { $0.scenarioId == scenarioId }) {
            var scenario = scenarios[index]
            scenario = RedTeamScenario(
                scenarioId: scenario.scenarioId,
                name: scenario.name,
                description: scenario.description,
                category: scenario.category,
                mitreTacticIds: scenario.mitreTacticIds,
                mitreTechniqueIds: scenario.mitreTechniqueIds,
                severity: scenario.severity,
                attackVector: scenario.attackVector,
                preconditions: scenario.preconditions,
                steps: scenario.steps,
                expectedOutcome: scenario.expectedOutcome,
                defenseValidation: scenario.defenseValidation,
                createdAt: scenario.createdAt,
                lastTestedAt: Date(),
                lastTestPassed: passed
            )
            scenarios[index] = scenario
        }
    }

    /// Generate test fixtures from scenarios
    public func generateTestFixtures() -> [RedTeamTestFixture] {
        return scenarios.map { scenario in
            RedTeamTestFixture(
                fixtureId: "RTF-\(scenario.scenarioId)",
                scenarioId: scenario.scenarioId,
                testName: "test_redteam_\(scenario.category.rawValue)_\(scenario.scenarioId)",
                expectedOutcome: scenario.expectedOutcome,
                gateId: scenario.defenseValidation.gateId
            )
        }
    }
}

/// Red team test result
public struct RedTeamTestResult: Codable, Sendable {
    public let scenarioId: String
    public let testedAt: Date
    public let passed: Bool
    public let details: String
    public let defenseTriggered: Bool
    public let detectionTimeMs: Int64?
}

/// Release coverage result
public struct ReleaseCoverageResult: Sendable {
    public let meetsRequirement: Bool
    public let requiredScenarios: Int
    public let testedScenarios: Int
    public let passedScenarios: Int
    public let categoryCoverage: [String: Int]
    public let missingCategories: [String]
}

/// Test fixture generated from red team scenario
public struct RedTeamTestFixture: Codable, Sendable {
    public let fixtureId: String
    public let scenarioId: String
    public let testName: String
    public let expectedOutcome: RedTeamScenario.ExpectedOutcome
    public let gateId: String?
}

// Helper extension
extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        var result: [T: Value] = [:]
        for (key, value) in self {
            result[transform(key)] = value
        }
        return result
    }
}

---

## FILE SUMMARY

| PART | Files | Stages | Vulnerabilities | Key Components |
|------|-------|--------|-----------------|----------------|
| AC: Supply Chain | 7 | AC-001 to AC-007 | 15 | BuildProvenanceManifest, SBOMGenerator, ArtifactSignatureVerifier |
| AD: Secrets | 8 | AD-001 to AD-008 | 12 | KeyHierarchySpec, EnvelopeEncryption, KMSAdapter |
| AE: AuthZ | 5 | AE-001 to AE-005 | 10 | AuthZModel, AuthZEnforcer, AuthZProof |
| AF: Abuse | 6 | AF-001 to AF-006 | 12 | TokenBucketRateLimiter, CostBudgetTracker |
| AG: DR | 6 | AG-001 to AG-006 | 10 | BackupPolicy, BackupAwareDeletionProof, DRDrillGate |
| AH: Privacy Attacks | 6 | AH-001 to AH-006 | 12 | InferenceRiskScorer, TrajectoryAnonymizer |
| AI: Consent | 6 | AI-001 to AI-006 | 12 | ConsentReceipt, WithdrawalEnforcer |
| AJ: Incident | 6 | AJ-001 to AJ-006 | 12 | IncidentManager, RedTeamScenarioSuite |
| **Total** | **50** | **50** | **95** | - |

---

## INTEGRATION WITH v1.4

This supplement integrates with v1.4 as follows:

1. **Supply Chain (AC)** signs artifacts consumed by **Remote Attestation (T)**
2. **Key Management (AD)** provides keys for **Envelope Encryption** across all modules
3. **AuthZ (AE)** gates all API calls including **Cloud Verification (S)** and **Upload (U)**
4. **Abuse Protection (AF)** wraps **Network Protocol (U)** with rate limits
5. **DR (AG)** extends **Tenant Isolation (W)** with backup-aware deletion
6. **Privacy Attacks (AH)** augments **Liveness (Y)** with inference risk
7. **Consent (AI)** binds to **Audit (S)** for consent event logging
8. **Incident (AJ)** triggers **Kill Switch (V)** and feeds **Risk Register (O)**

---

## CURSOR IMPLEMENTATION INSTRUCTION

When implementing this supplement:

1. **Apply Errata First**: Fix v1.4's extreme values (retry count, audit retention, memory threshold)
2. **Implement in Order**: AC → AD → AE → AF → AG → AH → AI → AJ
3. **Test Each Module**: Use lab profile for stress testing
4. **Integrate with v1.4**: Ensure cross-module dependencies work
5. **Verify Closed Sets**: All enums must be exhaustive with no "other" cases
6. **Audit Everything**: Every decision must emit an audit event

---

## END OF PR5 PATCH v1.5 SUPPLEMENT
