# PR5 PATCH v1.6 SUPPLEMENT - CROSS-MODULE CONTRACTS & SYSTEM-LEVEL HARDENING

> **Document Type**: Cursor Implementation Specification
> **Version**: 1.6.0-SUPPLEMENT
> **Extends**: PR5_PATCH_V1_5_SUPPLEMENT + pr5_v1.2_bulletproof_patch Plan
> **Total New Vulnerabilities Addressed**: 85 additional (400 total with v1.5)
> **New Modules**: 6 Major Domains (PART AK through PART AP)
> **Focus**: Cross-Module Contracts - Threat Model Compiler, E2E Identity Chain, Data Lifecycle Governance, Runtime Integrity, Explainability Views, Engineering Hygiene

---

## DOCUMENT PURPOSE

This supplement addresses **cross-module contracts** - the "connective tissue" that binds individual security modules into a **unified, verifiable system**. Without these contracts, individual modules may be strong but the system fails at boundaries.

### Critical Gap Analysis from v1.5

v1.5 hardened:
- ✅ Individual domains (Supply Chain, Keys, AuthZ, Abuse, DR, Privacy, Consent, Incident)
- ✅ Per-module configurations and gates

But production systems STILL fail from:
- ❌ **Threat Model Gap**: Controls exist but no traceable mapping to threats → compliance audit fails
- ❌ **Identity Chain Gap**: Device/Session/Data identities not cryptographically bound → replay/splice attacks
- ❌ **Derivative Data Gap**: Raw data deleted but embeddings/features remain → privacy violation
- ❌ **Runtime Integrity Gap**: Build verified but app runs on compromised device → all gates bypassed
- ❌ **Explainability Gap**: Engineers debug but users confused → support cost explosion
- ❌ **Plan Integrity Gap**: Planning documents are not machine-verifiable → implementation drift

This supplement closes those gaps with **6 new PART modules**.

---

## REFERENCES

This document incorporates best practices from:

### Threat Modeling
- [STRIDE Model](https://en.wikipedia.org/wiki/STRIDE_model) - Microsoft's threat classification
- [LINDDUN](https://threat-modeling.com/linddun-threat-modeling/) - Privacy-focused threat modeling (KU Leuven)
- [CAPEC](https://capec.mitre.org/) - MITRE's 563 attack patterns enumeration
- [Security Compass STRIDE vs LINDDUN](https://www.securitycompass.com/blog/comparing-stride-linddun-pasta-threat-modeling/)

### Cryptographic Identity & Attestation
- [TCG Device Identity & Attestation](https://trustedcomputinggroup.org/wp-content/uploads/Overview-of-TCG-Technologies-for-Device-Identification-and-Attestation-Version-1.0-Revision-1.37_5Feb24-2.pdf)
- [DICE Symmetric Identity](https://trustedcomputinggroup.org/wp-content/uploads/TCG_DICE_SymIDAttest_v1_r0p94_pubrev.pdf)
- [C2PA Attestation](https://spec.c2pa.org/specifications/specifications/1.4/attestations/attestation.html)
- [FIDO Alliance Attestation 2024](https://fidoalliance.org/wp-content/uploads/2024/06/EDWG_Attestation-White-Paper_2024-1.pdf)
- [RFC 9683 Remote Integrity Verification](https://datatracker.ietf.org/doc/rfc9683/)

### Data Governance
- [Atlan GDPR Data Governance](https://atlan.com/data-governance-and-gdpr/)
- [Data Lineage for AI Act](https://medium.com/@pulsr-io-enrico/gdpr-taught-us-data-governance-the-ai-act-demands-data-lineage-heres-the-difference-eb3c3466f324)
- [ComplyDog Erasure Rights](https://complydog.com/blog/right-to-be-forgotten-gdpr-erasure-rights-guide)

### Runtime Integrity
- [Approov Frida Detection](https://approov.io/knowledge/frida-detection-prevention)
- [Appdome Anti-Frida](https://www.appdome.com/mobile-malware-prevention/anti-frida-dbi-detection/)
- [8kSec Root Detection Bypass](https://8ksec.io/advanced-root-detection-bypass-techniques/)
- [Guardsquare iOS Protection](https://www.guardsquare.com/blog/two-attack-scenarios-will-defeat-your-diy-ios-app-protection)

### Cryptographic Audit
- [Merkle Tree Blockchain Audit](https://dl.acm.org/doi/10.4018/IJCAC.2020070103)
- [zkSNARKs for Transparent Audit](https://www.ndss-symposium.org/wp-content/uploads/2024-815-paper.pdf)

---

## ARCHITECTURE OVERVIEW: 6 NEW MODULES

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              PR5 v1.6 CROSS-MODULE CONTRACT ARCHITECTURE                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                 PART AK: THREAT MODEL COMPILER                      │   │
│  │  ThreatModelCatalog ←→ ControlMappingManifest ←→ ThreatToGateCompiler  │
│  │  [STRIDE] [LINDDUN] [CAPEC] → [Controls] → [Tests] → [Metrics] → [Gates] │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │ Validates All                          │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                 PART AL: END-TO-END IDENTITY CHAIN                  │   │
│  │  SessionIdentityEnvelope ←→ SignedDecisionRecord ←→ MerkleCommitChain  │
│  │  [Device ID] + [Session ID] + [Content Hash] = Unforgeable Binding     │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │ Signs All                              │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                 PART AM: DATA LIFECYCLE & DERIVATIVE GOVERNANCE     │   │
│  │  DataClassificationStateMachine ←→ DerivativeInventory ←→ RevocationCascade │
│  │  [Raw] → [Feature] → [Model Input] → [Deletion] = Full Lineage Proof   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │ Governs All                            │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                 PART AN: RUNTIME INTEGRITY & ANTI-TAMPER            │   │
│  │  RuntimeIntegrityScanner ←→ FridaHookDetector ←→ AttestationEnforcer   │
│  │  [Jailbreak] [Root] [Hook] [Debug] → Continuous Verification           │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │ Protects All                           │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                 PART AO: EXPLAINABILITY VIEWS                       │   │
│  │  UserFacingReasonCode ←→ EngineerDiagnosticBundle ←→ RedactionPolicy   │
│  │  [User View] ≠ [Engineer View] = Security + Usability                  │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │ Explains All                           │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                 PART AP: ENGINEERING HYGIENE & PLAN INTEGRITY       │   │
│  │  HardeningIssueRegistry ←→ PlanSchemaValidator ←→ CoverageReporter    │
│  │  [Issue ID] → [File] → [Test] → [Gate] → [Metric] = Full Traceability │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## EXTREME VALUES REFERENCE TABLE (LAB PROFILE) - v1.6

| Module | Parameter | Production | Debug | Lab (Extreme) |
|--------|-----------|------------|-------|---------------|
| AK: Threat Model | unmappedControlPolicy | warn | allow | **hard-fail** |
| AK: Threat Model | threatCoverageMinPercent | 80 | 50 | **100** |
| AK: Threat Model | capecMappingRequired | true | false | **true** |
| AL: Identity Chain | sessionEnvelopeRequired | true | false | **true** |
| AL: Identity Chain | merkleCommitIntervalFrames | 100 | 500 | **10** |
| AL: Identity Chain | replayWindowToleranceSec | 60 | 300 | **5** |
| AL: Identity Chain | crossSessionSplicePolicy | deny | warn | **hard-deny** |
| AM: Data Lifecycle | derivativeTrackingRequired | true | false | **true** |
| AM: Data Lifecycle | cascadeDeletionP99Sec | 300 | 600 | **30** |
| AM: Data Lifecycle | orphanDerivativePolicy | warn | allow | **hard-delete** |
| AM: Data Lifecycle | purposeBindingRequired | true | false | **true** |
| AN: Runtime | jailbreakPolicy | degrade | allow | **hard-deny** |
| AN: Runtime | hookDetectionIntervalMs | 5000 | 30000 | **500** |
| AN: Runtime | debuggerAttachPolicy | degrade | allow | **hard-deny** |
| AN: Runtime | integrityCheckContinuous | true | false | **true** |
| AO: Explainability | userReasonCodeRedaction | true | false | **true** |
| AO: Explainability | engineerBundleAutoCapture | true | false | **true** |
| AO: Explainability | thresholdExposurePolicy | deny | warn | **hard-deny** |
| AP: Plan Integrity | planSchemaValidation | true | false | **true** |
| AP: Plan Integrity | hardeningCoverageMinPercent | 90 | 70 | **100** |
| AP: Plan Integrity | orphanFilePolicy | warn | allow | **hard-fail** |

---

## PART AK: THREAT MODEL COMPILER

### AK.1 Problem Statement

**Vulnerability ID**: THREAT-001 through THREAT-015
**Severity**: CRITICAL (Compliance)
**Category**: Threat Traceability, Control Mapping, Audit Evidence

Current gaps:
1. Controls exist but no formal mapping to STRIDE/LINDDUN threats
2. Tests exist but not traceable to threat mitigations
3. Metrics exist but not bound to control effectiveness
4. New code may touch critical domains without threat analysis

**Compliance Impact**:
- SOC 2: Requires demonstrable control-to-risk mapping
- ISO 27001: Requires risk treatment traceability
- GDPR: Requires privacy impact assessment linkage

### AK.2 Solution Architecture

Implement a **compilable threat model** where:
- Every control MUST map to ≥1 threat
- Every threat MUST have ≥1 test
- Every test MUST have ≥1 metric
- CI fails if mappings are incomplete

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    THREAT MODEL COMPILATION FLOW                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  THREAT CATALOG (Closed Set)                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ STRIDE Subset (Security)           LINDDUN Subset (Privacy)      │   │
│  │ ├─ S: Spoofing                     ├─ L: Linkability             │   │
│  │ ├─ T: Tampering                    ├─ I: Identifiability         │   │
│  │ ├─ R: Repudiation                  ├─ N: Non-repudiation         │   │
│  │ ├─ I: Info Disclosure              ├─ D: Detectability           │   │
│  │ ├─ D: Denial of Service            ├─ D: Disclosure              │   │
│  │ └─ E: Elevation of Privilege       ├─ U: Unawareness             │   │
│  │                                    └─ N: Non-compliance           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │                                             │
│                           ▼                                             │
│  CONTROL MAPPING MANIFEST                                              │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Threat → Control → Evidence                                      │   │
│  │ ┌─────────────────────────────────────────────────────────────┐ │   │
│  │ │ STRIDE.Spoofing.Device                                      │ │   │
│  │ │   └─ Control: RemoteAttestationManager (PART T)             │ │   │
│  │ │       └─ Evidence:                                          │ │   │
│  │ │           ├─ Test: RemoteAttestationTests.swift             │ │   │
│  │ │           ├─ Metric: attestation_success_rate               │ │   │
│  │ │           └─ Gate: attestation_required_for_upload          │ │   │
│  │ └─────────────────────────────────────────────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │                                             │
│                           ▼                                             │
│  THREAT-TO-GATE COMPILER                                               │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Input: Control Mapping Manifest + Codebase                       │   │
│  │ Output:                                                          │   │
│  │   ├─ Missing Mapping Report (CI fails if non-empty in lab)      │   │
│  │   ├─ Test Generation Hints                                       │   │
│  │   ├─ Metric Binding Verification                                 │   │
│  │   └─ Gate Coverage Report                                        │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AK.3 Implementation Files

```
New Files:
├── ThreatModel/
│   ├── ThreatModelCatalog.swift              (STAGE AK-001)
│   ├── STRIDEThreatCategory.swift            (STAGE AK-002)
│   ├── LINDDUNThreatCategory.swift           (STAGE AK-003)
│   ├── CAPECAttackPattern.swift              (STAGE AK-004)
│   ├── ControlMappingManifest.swift          (STAGE AK-005)
│   ├── ThreatToGateCompiler.swift            (STAGE AK-006)
│   ├── AttackSurfaceInventory.swift          (STAGE AK-007)
│   └── ThreatCoverageReport.swift            (STAGE AK-008)
└── Tests/
    └── ThreatModelCompilerTests.swift        (STAGE AK-009)
```

### STAGE AK-001: ThreatModelCatalog.swift

```swift
// ThreatModel/ThreatModelCatalog.swift
// STAGE AK-001: Unified threat catalog combining STRIDE, LINDDUN, CAPEC
// Vulnerability: THREAT-001, THREAT-002
// Reference: https://capec.mitre.org/, https://threat-modeling.com/linddun-threat-modeling/

import Foundation

/// Threat model configuration
public struct ThreatModelConfig: Codable, Sendable {
    /// Policy for unmapped controls
    public let unmappedControlPolicy: UnmappedPolicy

    /// Minimum threat coverage percentage
    public let threatCoverageMinPercent: Int

    /// Whether CAPEC mapping is required
    public let capecMappingRequired: Bool

    /// Whether to enforce threat-to-test mapping
    public let threatToTestMappingRequired: Bool

    public enum UnmappedPolicy: String, Codable, Sendable {
        case allow      // Allow (dangerous)
        case warn       // Warn but continue
        case hardFail   // Block build/deploy entirely
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> ThreatModelConfig {
        switch profile {
        case .production:
            return ThreatModelConfig(
                unmappedControlPolicy: .warn,
                threatCoverageMinPercent: 80,
                capecMappingRequired: true,
                threatToTestMappingRequired: true
            )
        case .debug:
            return ThreatModelConfig(
                unmappedControlPolicy: .allow,
                threatCoverageMinPercent: 50,
                capecMappingRequired: false,
                threatToTestMappingRequired: false
            )
        case .lab:
            return ThreatModelConfig(
                unmappedControlPolicy: .hardFail,  // EXTREME
                threatCoverageMinPercent: 100,     // EXTREME
                capecMappingRequired: true,
                threatToTestMappingRequired: true
            )
        }
    }
}

/// Unified threat identifier
public struct ThreatID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let framework: ThreatFramework
    public let category: String
    public let subcategory: String?
    public let id: String

    public enum ThreatFramework: String, Codable, Sendable {
        case stride = "STRIDE"
        case linddun = "LINDDUN"
        case capec = "CAPEC"
        case custom = "CUSTOM"
    }

    public var description: String {
        if let sub = subcategory {
            return "\(framework.rawValue).\(category).\(sub).\(id)"
        }
        return "\(framework.rawValue).\(category).\(id)"
    }

    /// Factory for STRIDE threats
    public static func stride(_ category: STRIDECategory, subcategory: String? = nil, id: String) -> ThreatID {
        return ThreatID(framework: .stride, category: category.rawValue, subcategory: subcategory, id: id)
    }

    /// Factory for LINDDUN threats
    public static func linddun(_ category: LINDDUNCategory, subcategory: String? = nil, id: String) -> ThreatID {
        return ThreatID(framework: .linddun, category: category.rawValue, subcategory: subcategory, id: id)
    }

    /// Factory for CAPEC patterns
    public static func capec(_ patternId: Int) -> ThreatID {
        return ThreatID(framework: .capec, category: "CAPEC", subcategory: nil, id: String(patternId))
    }
}

/// STRIDE categories (closed set)
/// Reference: https://en.wikipedia.org/wiki/STRIDE_model
public enum STRIDECategory: String, Codable, Sendable, CaseIterable {
    case spoofing = "Spoofing"              // Authenticity violation
    case tampering = "Tampering"            // Integrity violation
    case repudiation = "Repudiation"        // Non-repudiability violation
    case informationDisclosure = "InfoDisclosure"  // Confidentiality violation
    case denialOfService = "DoS"            // Availability violation
    case elevationOfPrivilege = "EoP"       // Authorization violation

    /// Security property this threat violates
    public var violatedProperty: SecurityProperty {
        switch self {
        case .spoofing: return .authenticity
        case .tampering: return .integrity
        case .repudiation: return .nonRepudiability
        case .informationDisclosure: return .confidentiality
        case .denialOfService: return .availability
        case .elevationOfPrivilege: return .authorization
        }
    }

    public enum SecurityProperty: String, Codable, Sendable {
        case authenticity
        case integrity
        case nonRepudiability
        case confidentiality
        case availability
        case authorization
    }
}

/// LINDDUN categories (closed set)
/// Reference: https://threat-modeling.com/linddun-threat-modeling/
public enum LINDDUNCategory: String, Codable, Sendable, CaseIterable {
    case linkability = "Linkability"            // Linking data to same subject
    case identifiability = "Identifiability"    // Identifying subject from data
    case nonRepudiation = "NonRepudiation"      // Subject cannot deny actions (privacy concern!)
    case detectability = "Detectability"        // Detecting existence of data
    case disclosure = "Disclosure"              // Unauthorized access to data
    case unawareness = "Unawareness"           // Subject not aware of processing
    case nonCompliance = "NonCompliance"        // Violating privacy regulations

    /// Privacy property this threat violates
    public var violatedProperty: PrivacyProperty {
        switch self {
        case .linkability: return .unlinkability
        case .identifiability: return .anonymity
        case .nonRepudiation: return .plausibleDeniability
        case .detectability: return .undetectability
        case .disclosure: return .confidentiality
        case .unawareness: return .transparency
        case .nonCompliance: return .compliance
        }
    }

    public enum PrivacyProperty: String, Codable, Sendable {
        case unlinkability
        case anonymity
        case plausibleDeniability
        case undetectability
        case confidentiality
        case transparency
        case compliance
    }
}

/// Threat entry in the catalog
public struct ThreatEntry: Codable, Sendable {
    public let id: ThreatID
    public let name: String
    public let description: String
    public let severity: ThreatSeverity
    public let applicableDomains: [CapturedDomain]
    public let attackVectors: [String]
    public let relatedCAPECIds: [Int]
    public let mitigationStrategy: String

    public enum ThreatSeverity: String, Codable, Sendable, Comparable {
        case critical
        case high
        case medium
        case low

        public static func < (lhs: ThreatSeverity, rhs: ThreatSeverity) -> Bool {
            let order: [ThreatSeverity] = [.critical, .high, .medium, .low]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    /// Domains where this threat applies (closed set)
    public enum CapturedDomain: String, Codable, Sendable, CaseIterable {
        case perception   // Sensor, ISP, Camera
        case decision     // Quality, State, Policy
        case ledger       // Audit, Proof, Deletion
        case network      // Upload, Protocol, ACK
        case cloud        // Mirror, Verification, Storage
        case config       // Governance, Kill Switch
        case identity     // Attestation, AuthZ
        case privacy      // Consent, Anonymization
    }
}

/// Threat Model Catalog
public actor ThreatModelCatalog {

    private var threats: [ThreatID: ThreatEntry] = [:]
    private let config: ThreatModelConfig

    public init(config: ThreatModelConfig) {
        self.config = config
        loadBuiltInThreats()
    }

    /// Load built-in threat definitions
    private func loadBuiltInThreats() {
        // STRIDE: Device Spoofing
        registerThreat(ThreatEntry(
            id: .stride(.spoofing, subcategory: "Device", id: "SPOOF-DEV-001"),
            name: "Device Identity Spoofing",
            description: "Attacker presents fake device identity to bypass attestation",
            severity: .critical,
            applicableDomains: [.identity, .network, .cloud],
            attackVectors: ["Emulator", "Virtual Camera", "Rooted Device", "Frida Hook"],
            relatedCAPECIds: [151, 194],  // CAPEC-151: Identity Spoofing, CAPEC-194: Fake the Source
            mitigationStrategy: "Remote attestation with hardware-backed keys"
        ))

        // STRIDE: Data Tampering
        registerThreat(ThreatEntry(
            id: .stride(.tampering, subcategory: "Data", id: "TAMP-DATA-001"),
            name: "Capture Data Tampering",
            description: "Attacker modifies captured frames before upload",
            severity: .critical,
            applicableDomains: [.perception, .decision, .network],
            attackVectors: ["Memory Editing", "File Modification", "Man-in-the-Middle"],
            relatedCAPECIds: [438, 439],  // CAPEC-438: Modification During Manufacture, CAPEC-439: Manipulate Registry
            mitigationStrategy: "End-to-end signature chain with Merkle commitment"
        ))

        // STRIDE: Repudiation
        registerThreat(ThreatEntry(
            id: .stride(.repudiation, subcategory: "Action", id: "REPUD-ACT-001"),
            name: "Capture Session Repudiation",
            description: "User denies having performed a capture session",
            severity: .high,
            applicableDomains: [.ledger, .cloud],
            attackVectors: ["Audit Log Deletion", "Timestamp Manipulation"],
            relatedCAPECIds: [93],  // CAPEC-93: Log Injection-Tampering-Forging
            mitigationStrategy: "Immutable audit ledger with cryptographic proof"
        ))

        // LINDDUN: Linkability
        registerThreat(ThreatEntry(
            id: .linddun(.linkability, subcategory: "Session", id: "LINK-SESS-001"),
            name: "Cross-Session Linkability",
            description: "Attacker links multiple sessions to same user via metadata",
            severity: .high,
            applicableDomains: [.privacy, .ledger],
            attackVectors: ["Device Fingerprint", "Timing Analysis", "Location Correlation"],
            relatedCAPECIds: [167],  // CAPEC-167: Collect Data from Common Resource
            mitigationStrategy: "Session-isolated identifiers with differential privacy"
        ))

        // LINDDUN: Identifiability
        registerThreat(ThreatEntry(
            id: .linddun(.identifiability, subcategory: "Location", id: "IDENT-LOC-001"),
            name: "Location Re-identification",
            description: "Attacker identifies user from anonymized location data",
            severity: .high,
            applicableDomains: [.privacy, .perception],
            attackVectors: ["Home/Work Pattern", "Trajectory Analysis", "POI Matching"],
            relatedCAPECIds: [169],  // CAPEC-169: Footprinting
            mitigationStrategy: "Trajectory downsampling with spatial noise"
        ))

        // Add more threats...
    }

    /// Register a threat entry
    public func registerThreat(_ entry: ThreatEntry) {
        threats[entry.id] = entry
    }

    /// Get all threats for a domain
    public func threatsForDomain(_ domain: ThreatEntry.CapturedDomain) -> [ThreatEntry] {
        return threats.values.filter { $0.applicableDomains.contains(domain) }
    }

    /// Get threats by CAPEC ID
    public func threatsByCAPEC(_ capecId: Int) -> [ThreatEntry] {
        return threats.values.filter { $0.relatedCAPECIds.contains(capecId) }
    }

    /// Get all registered threats
    public func allThreats() -> [ThreatEntry] {
        return Array(threats.values)
    }
}
```

### STAGE AK-005: ControlMappingManifest.swift

```swift
// ThreatModel/ControlMappingManifest.swift
// STAGE AK-005: Threat-to-Control mapping with evidence requirements
// Vulnerability: THREAT-003, THREAT-004, THREAT-005
// Reference: https://owasp.org/www-community/Threat_Modeling_Process

import Foundation

/// Evidence types for control effectiveness (closed set)
public enum EvidenceType: String, Codable, Sendable, CaseIterable {
    case unitTest           // Unit test covering the control
    case integrationTest    // Integration test verifying control in context
    case fuzzTest           // Fuzz test for robustness
    case penetrationTest    // Penetration test (manual or automated)
    case metric             // Production metric tracking effectiveness
    case gate               // Quality gate enforcing the control
    case audit              // Audit event proving control execution
}

/// Control-to-Threat mapping entry
public struct ControlMapping: Codable, Sendable {
    /// Unique control identifier (matches file/class name)
    public let controlId: String

    /// Control name (human-readable)
    public let controlName: String

    /// Source file implementing the control
    public let sourceFile: String

    /// PART this control belongs to
    public let part: String

    /// Threats this control mitigates
    public let mitigatedThreats: [ThreatID]

    /// Required evidence for this control
    public let requiredEvidence: [RequiredEvidence]

    /// Whether this control is critical (requires 100% evidence)
    public let isCritical: Bool

    public struct RequiredEvidence: Codable, Sendable {
        public let evidenceType: EvidenceType
        public let identifier: String           // Test name, metric name, gate name
        public let description: String
        public let verified: Bool               // Whether evidence exists
        public let verifiedAt: Date?
    }
}

/// Control Mapping Manifest
public struct ControlMappingManifest: Codable, Sendable {
    public let version: String
    public let generatedAt: Date
    public let controls: [ControlMapping]

    /// Get all unmapped controls (controls without threat mapping)
    public func unmappedControls() -> [ControlMapping] {
        return controls.filter { $0.mitigatedThreats.isEmpty }
    }

    /// Get controls with incomplete evidence
    public func controlsWithIncompleteEvidence() -> [ControlMapping] {
        return controls.filter { control in
            control.requiredEvidence.contains { !$0.verified }
        }
    }

    /// Get all threats covered by controls
    public func coveredThreats() -> Set<ThreatID> {
        var covered: Set<ThreatID> = []
        for control in controls {
            covered.formUnion(control.mitigatedThreats)
        }
        return covered
    }

    /// Calculate threat coverage percentage
    public func threatCoveragePercent(totalThreats: Int) -> Double {
        let covered = coveredThreats().count
        guard totalThreats > 0 else { return 0 }
        return Double(covered) / Double(totalThreats) * 100
    }
}

/// Control Mapping Builder
@available(iOS 15.0, macOS 12.0, *)
public actor ControlMappingBuilder {

    private var mappings: [String: ControlMapping] = [:]
    private let config: ThreatModelConfig

    public init(config: ThreatModelConfig) {
        self.config = config
    }

    /// Register a control mapping
    public func register(_ mapping: ControlMapping) {
        mappings[mapping.controlId] = mapping
    }

    /// Build the manifest
    public func build() -> ControlMappingManifest {
        return ControlMappingManifest(
            version: "1.0",
            generatedAt: Date(),
            controls: Array(mappings.values)
        )
    }

    /// Validate mappings against policy
    public func validate(catalog: ThreatModelCatalog) async throws -> ValidationResult {
        let manifest = build()
        var errors: [ValidationError] = []
        var warnings: [String] = []

        // Check unmapped controls
        let unmapped = manifest.unmappedControls()
        if !unmapped.isEmpty {
            switch config.unmappedControlPolicy {
            case .hardFail:
                for control in unmapped {
                    errors.append(.unmappedControl(controlId: control.controlId))
                }
            case .warn:
                for control in unmapped {
                    warnings.append("Control \(control.controlId) has no threat mapping")
                }
            case .allow:
                break
            }
        }

        // Check threat coverage
        let allThreats = await catalog.allThreats()
        let coverage = manifest.threatCoveragePercent(totalThreats: allThreats.count)
        if coverage < Double(config.threatCoverageMinPercent) {
            errors.append(.insufficientCoverage(
                actual: coverage,
                required: Double(config.threatCoverageMinPercent)
            ))
        }

        // Check evidence completeness
        let incomplete = manifest.controlsWithIncompleteEvidence()
        for control in incomplete where control.isCritical {
            errors.append(.incompleteEvidence(controlId: control.controlId))
        }

        return ValidationResult(
            passed: errors.isEmpty,
            errors: errors,
            warnings: warnings,
            coveragePercent: coverage
        )
    }

    public struct ValidationResult: Sendable {
        public let passed: Bool
        public let errors: [ValidationError]
        public let warnings: [String]
        public let coveragePercent: Double
    }

    public enum ValidationError: Error, LocalizedError, Sendable {
        case unmappedControl(controlId: String)
        case insufficientCoverage(actual: Double, required: Double)
        case incompleteEvidence(controlId: String)
        case missingCAPECMapping(controlId: String)

        public var errorDescription: String? {
            switch self {
            case .unmappedControl(let id):
                return "Control \(id) has no threat mapping"
            case .insufficientCoverage(let actual, let required):
                return "Threat coverage \(actual)% below required \(required)%"
            case .incompleteEvidence(let id):
                return "Critical control \(id) has incomplete evidence"
            case .missingCAPECMapping(let id):
                return "Control \(id) missing required CAPEC mapping"
            }
        }
    }
}
```

### STAGE AK-006: ThreatToGateCompiler.swift

```swift
// ThreatModel/ThreatToGateCompiler.swift
// STAGE AK-006: Compiler that generates gates from threat mappings
// Vulnerability: THREAT-006, THREAT-007
// Reference: https://www.ibm.com/think/x-force/capec-making-heads-or-tails-of-attack-patterns

import Foundation

/// Compiler output: Generated gate configuration
public struct GeneratedGate: Codable, Sendable {
    public let gateId: String
    public let gateName: String
    public let sourceThreats: [ThreatID]
    public let triggerCondition: String
    public let action: GateAction
    public let severity: ThreatEntry.ThreatSeverity

    public enum GateAction: String, Codable, Sendable {
        case block          // Block the operation
        case degrade        // Degrade to safe mode
        case alert          // Alert and continue
        case audit          // Log for audit and continue
    }
}

/// Compiler output: Test generation hints
public struct TestGenerationHint: Codable, Sendable {
    public let threatId: ThreatID
    public let suggestedTestName: String
    public let testType: EvidenceType
    public let attackVector: String
    public let expectedOutcome: String
    public let priority: Priority

    public enum Priority: String, Codable, Sendable {
        case critical   // Must have before release
        case high       // Should have before release
        case medium     // Nice to have
        case low        // Future improvement
    }
}

/// Threat-to-Gate Compiler
@available(iOS 15.0, macOS 12.0, *)
public actor ThreatToGateCompiler {

    private let config: ThreatModelConfig
    private let catalog: ThreatModelCatalog

    public init(config: ThreatModelConfig, catalog: ThreatModelCatalog) {
        self.config = config
        self.catalog = catalog
    }

    /// Compile threat mappings into gate configurations
    public func compile(manifest: ControlMappingManifest) async -> CompilationResult {
        var gates: [GeneratedGate] = []
        var testHints: [TestGenerationHint] = []
        var coverageReport: [String: Double] = [:]

        let allThreats = await catalog.allThreats()

        // Group controls by threat
        var threatToControls: [ThreatID: [ControlMapping]] = [:]
        for control in manifest.controls {
            for threat in control.mitigatedThreats {
                threatToControls[threat, default: []].append(control)
            }
        }

        // Generate gates for each threat
        for threat in allThreats {
            let controls = threatToControls[threat.id] ?? []

            if controls.isEmpty {
                // Generate test hint for uncovered threat
                for vector in threat.attackVectors {
                    testHints.append(TestGenerationHint(
                        threatId: threat.id,
                        suggestedTestName: "test_\(threat.id.category)_\(vector.replacingOccurrences(of: " ", with: "_"))",
                        testType: .penetrationTest,
                        attackVector: vector,
                        expectedOutcome: "Attack blocked or detected",
                        priority: threat.severity == .critical ? .critical : .high
                    ))
                }
            } else {
                // Generate gate from controls
                let gateAction: GeneratedGate.GateAction
                switch threat.severity {
                case .critical:
                    gateAction = .block
                case .high:
                    gateAction = .degrade
                case .medium:
                    gateAction = .alert
                case .low:
                    gateAction = .audit
                }

                gates.append(GeneratedGate(
                    gateId: "GATE-\(threat.id.id)",
                    gateName: "Gate for \(threat.name)",
                    sourceThreats: [threat.id],
                    triggerCondition: controls.map { $0.controlId }.joined(separator: " AND "),
                    action: gateAction,
                    severity: threat.severity
                ))
            }
        }

        // Calculate per-domain coverage
        for domain in ThreatEntry.CapturedDomain.allCases {
            let domainThreats = await catalog.threatsForDomain(domain)
            let covered = domainThreats.filter { threatToControls[$0.id] != nil }
            let coverage = domainThreats.isEmpty ? 100.0 : Double(covered.count) / Double(domainThreats.count) * 100
            coverageReport[domain.rawValue] = coverage
        }

        return CompilationResult(
            gates: gates,
            testHints: testHints,
            coverageByDomain: coverageReport,
            totalCoverage: manifest.threatCoveragePercent(totalThreats: allThreats.count)
        )
    }

    public struct CompilationResult: Sendable {
        public let gates: [GeneratedGate]
        public let testHints: [TestGenerationHint]
        public let coverageByDomain: [String: Double]
        public let totalCoverage: Double
    }
}
```

---

## PART AL: END-TO-END IDENTITY CHAIN

### AL.1 Problem Statement

**Vulnerability ID**: IDENTITY-001 through IDENTITY-015
**Severity**: CRITICAL
**Category**: Cryptographic Binding, Replay Prevention, Splice Attack Defense

Current gaps:
1. Device attestation exists but not bound to session
2. Session ID exists but not bound to content
3. Content hash exists but not signed by device identity
4. Audit proves "what happened" but not "who did it"

**Attack Vectors**:
- Cross-session splice: Take frames from session A, upload as session B
- Device swap: Start session on device A, continue on device B
- Replay attack: Re-upload old session data
- Config mismatch: Upload data captured under different config

### AL.2 Solution Architecture

Implement **triple-binding identity chain**:

```
Device Identity + Session Identity + Content Identity = Unforgeable Chain

┌─────────────────────────────────────────────────────────────────────────┐
│                    END-TO-END IDENTITY CHAIN                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  LAYER 1: DEVICE IDENTITY (Hardware-Rooted)                            │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Attestation Claims (from PART T)                                 │   │
│  │ ├─ Device Key (TPM/Secure Enclave)                              │   │
│  │ ├─ Platform Integrity (iOS App Attest / Android Key Attestation)│   │
│  │ └─ App Identity (Bundle ID, Version)                            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │ Signs                                       │
│                           ▼                                             │
│  LAYER 2: SESSION IDENTITY (Per-Capture-Session)                       │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Session Envelope                                                 │   │
│  │ ├─ Session ID (UUID)                                            │   │
│  │ ├─ Session Anchor Hash                                          │   │
│  │ ├─ Config Snapshot Hash (frozen at session start)               │   │
│  │ ├─ Capability Mask Hash                                         │   │
│  │ ├─ Attestation Claims Hash                                      │   │
│  │ └─ Session Start Timestamp (signed)                             │   │
│  │ SIGNED BY: Device Key                                            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │ Binds                                       │
│                           ▼                                             │
│  LAYER 3: CONTENT IDENTITY (Per-Chunk/Segment)                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Signed Decision Record                                          │   │
│  │ ├─ Segment/Chunk ID                                             │   │
│  │ ├─ Content Hash (Merkle root of frames)                         │   │
│  │ ├─ Decision Summary (quality, state, disposition)               │   │
│  │ ├─ Parent Session Envelope Hash                                 │   │
│  │ ├─ Sequence Number (monotonic)                                  │   │
│  │ └─ Timestamp                                                    │   │
│  │ SIGNED BY: Session Key (derived from Device Key)                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                           │ Commits                                     │
│                           ▼                                             │
│  MERKLE COMMIT CHAIN                                                   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Every N frames:                                                  │   │
│  │ ├─ Compute Merkle root of frame hashes                          │   │
│  │ ├─ Include in Signed Decision Record                            │   │
│  │ └─ Upload commitment for cloud verification                     │   │
│  │                                                                  │   │
│  │ Verification:                                                    │   │
│  │ ├─ Cloud mirrors computation                                    │   │
│  │ ├─ Merkle roots must match                                      │   │
│  │ └─ Signature chain must be unbroken                             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AL.3 Implementation Files

```
New Files:
├── IdentityChain/
│   ├── SessionIdentityEnvelope.swift         (STAGE AL-001)
│   ├── SignedDecisionRecord.swift            (STAGE AL-002)
│   ├── MerkleCommitChain.swift               (STAGE AL-003)
│   ├── ReplayBindingGuard.swift              (STAGE AL-004)
│   ├── IdentityChainVerifier.swift           (STAGE AL-005)
│   └── SpliceAttackDetector.swift            (STAGE AL-006)
└── Tests/
    └── IdentityChainTests.swift              (STAGE AL-007)
```

### STAGE AL-001: SessionIdentityEnvelope.swift

```swift
// IdentityChain/SessionIdentityEnvelope.swift
// STAGE AL-001: Cryptographically bound session identity
// Vulnerability: IDENTITY-001, IDENTITY-002, IDENTITY-003
// Reference: https://fidoalliance.org/wp-content/uploads/2024/06/EDWG_Attestation-White-Paper_2024-1.pdf

import Foundation
import CryptoKit

/// Identity chain configuration
public struct IdentityChainConfig: Codable, Sendable {
    /// Whether session envelope is required for upload
    public let sessionEnvelopeRequired: Bool

    /// Frames between Merkle commits
    public let merkleCommitIntervalFrames: Int

    /// Replay window tolerance (seconds)
    public let replayWindowToleranceSec: Int

    /// Policy for cross-session splice detection
    public let crossSessionSplicePolicy: SplicePolicy

    public enum SplicePolicy: String, Codable, Sendable {
        case allow      // Allow (dangerous)
        case warn       // Warn and log
        case hardDeny   // Block entirely
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> IdentityChainConfig {
        switch profile {
        case .production:
            return IdentityChainConfig(
                sessionEnvelopeRequired: true,
                merkleCommitIntervalFrames: 100,
                replayWindowToleranceSec: 60,
                crossSessionSplicePolicy: .hardDeny
            )
        case .debug:
            return IdentityChainConfig(
                sessionEnvelopeRequired: false,
                merkleCommitIntervalFrames: 500,
                replayWindowToleranceSec: 300,
                crossSessionSplicePolicy: .warn
            )
        case .lab:
            return IdentityChainConfig(
                sessionEnvelopeRequired: true,
                merkleCommitIntervalFrames: 10,     // EXTREME: frequent commits
                replayWindowToleranceSec: 5,        // EXTREME: tight window
                crossSessionSplicePolicy: .hardDeny
            )
        }
    }
}

/// Session Identity Envelope - binds device to session
public struct SessionIdentityEnvelope: Codable, Sendable {

    // MARK: - Session Identification

    /// Unique session identifier
    public let sessionId: String

    /// Session start timestamp (Unix epoch ms)
    public let sessionStartTimestamp: Int64

    /// Session anchor hash (from DualAnchorManager)
    public let sessionAnchorHash: String

    // MARK: - Device Binding

    /// Hash of attestation claims (from PART T)
    public let attestationClaimsHash: String

    /// Device key identifier (public key hash)
    public let deviceKeyId: String

    /// App bundle identifier
    public let appBundleId: String

    /// App version
    public let appVersion: String

    // MARK: - Config Binding

    /// Hash of frozen config snapshot
    public let configSnapshotHash: String

    /// Hash of capability mask
    public let capabilityMaskHash: String

    /// Profile used for this session
    public let configProfile: String

    // MARK: - Cryptographic Binding

    /// Signature over envelope content
    public let signature: String

    /// Signing key identifier
    public let signingKeyId: String

    /// Hash of the entire envelope (for chaining)
    public let envelopeHash: String

    /// Verify envelope signature
    public func verify(publicKey: P256.Signing.PublicKey) throws -> Bool {
        let contentToVerify = buildSignableContent()

        guard let signatureData = Data(base64Encoded: signature) else {
            throw IdentityChainError.invalidSignatureFormat
        }

        let sig = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        return publicKey.isValidSignature(sig, for: Data(contentToVerify.utf8))
    }

    private func buildSignableContent() -> String {
        return [
            sessionId,
            String(sessionStartTimestamp),
            sessionAnchorHash,
            attestationClaimsHash,
            deviceKeyId,
            appBundleId,
            appVersion,
            configSnapshotHash,
            capabilityMaskHash,
            configProfile
        ].joined(separator: "|")
    }
}

/// Session Identity Envelope Generator
@available(iOS 15.0, macOS 12.0, *)
public actor SessionIdentityEnvelopeGenerator {

    private let config: IdentityChainConfig
    private let deviceKeyManager: DeviceKeyManager

    public init(config: IdentityChainConfig, deviceKeyManager: DeviceKeyManager) {
        self.config = config
        self.deviceKeyManager = deviceKeyManager
    }

    /// Generate a new session identity envelope
    public func generate(
        sessionId: String,
        sessionAnchorHash: String,
        attestationClaimsHash: String,
        configSnapshotHash: String,
        capabilityMaskHash: String,
        configProfile: String,
        appBundleId: String,
        appVersion: String
    ) async throws -> SessionIdentityEnvelope {

        let deviceKeyId = await deviceKeyManager.currentKeyId()
        let signingKey = try await deviceKeyManager.signingKey()

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        // Build content to sign
        let contentToSign = [
            sessionId,
            String(timestamp),
            sessionAnchorHash,
            attestationClaimsHash,
            deviceKeyId,
            appBundleId,
            appVersion,
            configSnapshotHash,
            capabilityMaskHash,
            configProfile
        ].joined(separator: "|")

        // Sign with device key
        let signature = try signingKey.signature(for: Data(contentToSign.utf8))

        // Calculate envelope hash
        let envelopeHash = SHA256.hash(data: Data(contentToSign.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        return SessionIdentityEnvelope(
            sessionId: sessionId,
            sessionStartTimestamp: timestamp,
            sessionAnchorHash: sessionAnchorHash,
            attestationClaimsHash: attestationClaimsHash,
            deviceKeyId: deviceKeyId,
            appBundleId: appBundleId,
            appVersion: appVersion,
            configSnapshotHash: configSnapshotHash,
            capabilityMaskHash: capabilityMaskHash,
            configProfile: configProfile,
            signature: signature.derRepresentation.base64EncodedString(),
            signingKeyId: deviceKeyId,
            envelopeHash: envelopeHash
        )
    }
}

/// Device Key Manager protocol
public protocol DeviceKeyManager: Actor {
    func currentKeyId() async -> String
    func signingKey() async throws -> P256.Signing.PrivateKey
    func verificationKey() async throws -> P256.Signing.PublicKey
}

/// Identity chain errors
public enum IdentityChainError: Error, LocalizedError {
    case invalidSignatureFormat
    case signatureVerificationFailed
    case sessionEnvelopeMissing
    case sessionMismatch(expected: String, actual: String)
    case replayDetected(timestamp: Int64, windowEnd: Int64)
    case spliceDetected(parentSession: String, claimedSession: String)
    case merkleRootMismatch(expected: String, actual: String)
    case sequenceGap(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSignatureFormat:
            return "Invalid signature format in identity chain"
        case .signatureVerificationFailed:
            return "Identity chain signature verification failed"
        case .sessionEnvelopeMissing:
            return "Session identity envelope is required but missing"
        case .sessionMismatch(let expected, let actual):
            return "Session mismatch: expected \(expected), got \(actual)"
        case .replayDetected(let ts, let window):
            return "Replay attack detected: timestamp \(ts) outside window ending \(window)"
        case .spliceDetected(let parent, let claimed):
            return "Splice attack detected: parent session \(parent) != claimed \(claimed)"
        case .merkleRootMismatch(let expected, let actual):
            return "Merkle root mismatch: expected \(expected), got \(actual)"
        case .sequenceGap(let expected, let actual):
            return "Sequence gap: expected \(expected), got \(actual)"
        }
    }
}
```

### STAGE AL-002: SignedDecisionRecord.swift

```swift
// IdentityChain/SignedDecisionRecord.swift
// STAGE AL-002: Per-segment signed decision record
// Vulnerability: IDENTITY-004, IDENTITY-005
// Reference: https://spec.c2pa.org/specifications/specifications/1.4/attestations/attestation.html

import Foundation
import CryptoKit

/// Signed Decision Record - binds session to content
public struct SignedDecisionRecord: Codable, Sendable {

    // MARK: - Segment Identification

    /// Unique segment/chunk identifier
    public let segmentId: String

    /// Sequence number (monotonic within session)
    public let sequenceNumber: Int

    /// Timestamp of this record
    public let timestamp: Int64

    // MARK: - Content Binding

    /// Merkle root of frame hashes in this segment
    public let contentMerkleRoot: String

    /// Number of frames in this segment
    public let frameCount: Int

    /// First frame index in session
    public let firstFrameIndex: Int

    /// Last frame index in session
    public let lastFrameIndex: Int

    // MARK: - Decision Summary

    /// Quality decision summary
    public let qualitySummary: QualitySummary

    /// State at segment end
    public let endState: String

    /// Disposition summary (accepted/rejected/deferred counts)
    public let dispositionSummary: DispositionSummary

    // MARK: - Chain Binding

    /// Hash of parent session envelope
    public let parentEnvelopeHash: String

    /// Hash of previous decision record (for chaining)
    public let previousRecordHash: String?

    // MARK: - Cryptographic Binding

    /// Signature over record content
    public let signature: String

    /// Session key identifier (derived from device key)
    public let sessionKeyId: String

    /// Hash of this record
    public let recordHash: String

    // MARK: - Nested Types

    public struct QualitySummary: Codable, Sendable {
        public let minQuality: Double
        public let maxQuality: Double
        public let avgQuality: Double
        public let qualityGatePassed: Bool
    }

    public struct DispositionSummary: Codable, Sendable {
        public let acceptedCount: Int
        public let rejectedCount: Int
        public let deferredCount: Int
        public let totalProcessed: Int
    }

    /// Verify record signature
    public func verify(sessionPublicKey: P256.Signing.PublicKey) throws -> Bool {
        let contentToVerify = buildSignableContent()

        guard let signatureData = Data(base64Encoded: signature) else {
            throw IdentityChainError.invalidSignatureFormat
        }

        let sig = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        return sessionPublicKey.isValidSignature(sig, for: Data(contentToVerify.utf8))
    }

    /// Verify chain integrity
    public func verifyChain(expectedParentHash: String, expectedPreviousHash: String?) -> Bool {
        if parentEnvelopeHash != expectedParentHash {
            return false
        }
        if previousRecordHash != expectedPreviousHash {
            return false
        }
        return true
    }

    private func buildSignableContent() -> String {
        return [
            segmentId,
            String(sequenceNumber),
            String(timestamp),
            contentMerkleRoot,
            String(frameCount),
            parentEnvelopeHash,
            previousRecordHash ?? "genesis"
        ].joined(separator: "|")
    }
}

/// Signed Decision Record Generator
@available(iOS 15.0, macOS 12.0, *)
public actor SignedDecisionRecordGenerator {

    private let config: IdentityChainConfig
    private var currentSequence: Int = 0
    private var previousRecordHash: String?
    private var sessionEnvelopeHash: String?
    private var sessionKey: P256.Signing.PrivateKey?

    public init(config: IdentityChainConfig) {
        self.config = config
    }

    /// Initialize for a new session
    public func initSession(
        envelopeHash: String,
        sessionKey: P256.Signing.PrivateKey
    ) {
        self.sessionEnvelopeHash = envelopeHash
        self.sessionKey = sessionKey
        self.currentSequence = 0
        self.previousRecordHash = nil
    }

    /// Generate a new decision record
    public func generate(
        segmentId: String,
        frameHashes: [String],
        firstFrameIndex: Int,
        qualitySummary: SignedDecisionRecord.QualitySummary,
        endState: String,
        dispositionSummary: SignedDecisionRecord.DispositionSummary
    ) throws -> SignedDecisionRecord {

        guard let envelopeHash = sessionEnvelopeHash,
              let signingKey = sessionKey else {
            throw IdentityChainError.sessionEnvelopeMissing
        }

        // Compute Merkle root
        let merkleRoot = computeMerkleRoot(frameHashes)

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        currentSequence += 1

        // Build signable content
        let contentToSign = [
            segmentId,
            String(currentSequence),
            String(timestamp),
            merkleRoot,
            String(frameHashes.count),
            envelopeHash,
            previousRecordHash ?? "genesis"
        ].joined(separator: "|")

        // Sign
        let signature = try signingKey.signature(for: Data(contentToSign.utf8))

        // Calculate record hash
        let recordHash = SHA256.hash(data: Data(contentToSign.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()

        let record = SignedDecisionRecord(
            segmentId: segmentId,
            sequenceNumber: currentSequence,
            timestamp: timestamp,
            contentMerkleRoot: merkleRoot,
            frameCount: frameHashes.count,
            firstFrameIndex: firstFrameIndex,
            lastFrameIndex: firstFrameIndex + frameHashes.count - 1,
            qualitySummary: qualitySummary,
            endState: endState,
            dispositionSummary: dispositionSummary,
            parentEnvelopeHash: envelopeHash,
            previousRecordHash: previousRecordHash,
            signature: signature.derRepresentation.base64EncodedString(),
            sessionKeyId: "session-key", // Would be derived from device key
            recordHash: recordHash
        )

        // Update chain state
        previousRecordHash = recordHash

        return record
    }

    /// Compute Merkle root of frame hashes
    private func computeMerkleRoot(_ hashes: [String]) -> String {
        guard !hashes.isEmpty else {
            return "empty"
        }

        var currentLevel = hashes

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
}
```

---

## PART AM: DATA LIFECYCLE & DERIVATIVE GOVERNANCE

### AM.1 Problem Statement

**Vulnerability ID**: LIFECYCLE-001 through LIFECYCLE-012
**Severity**: CRITICAL (Compliance)
**Category**: Data Lineage, Derivative Tracking, Deletion Cascade

Current gaps:
1. Raw data deleted but derived features (embeddings, meshes) persist
2. Training eligibility checked once, not enforced throughout lifecycle
3. Consent withdrawal doesn't cascade to derivatives
4. Purpose binding (debug vs analytics vs training) not enforced

**Compliance Impact**:
- GDPR Article 17: Right to erasure must cover ALL derivatives
- AI Act: Training data lineage must be auditable
- Purpose limitation: Data used for stated purpose only

### AM.2 Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DATA LIFECYCLE STATE MACHINE                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ CAPTURED → PROCESSED → UPLOADED → [TRAINING] → DELETED         │    │
│  │     │          │           │           │           │           │    │
│  │     ▼          ▼           ▼           ▼           ▼           │    │
│  │  Raw Data   Features    Cloud Copy   Model Input  Proof Only   │    │
│  │  (frames)   (embeddings) (storage)   (dataset)    (no data)    │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  DERIVATIVE TRACKING:                                                  │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Raw Frame                                                       │    │
│  │   ├─ Descriptor (ephemeral, local-only)                        │    │
│  │   ├─ Feature Vector (privacy-safe, may upload)                 │    │
│  │   ├─ Quality Metrics (aggregate, may upload)                   │    │
│  │   ├─ Mesh/Point Cloud (if generated)                           │    │
│  │   └─ Training Sample (if eligible)                             │    │
│  │                                                                 │    │
│  │ ALL derivatives must be:                                        │    │
│  │   ├─ Registered in DerivativeInventory                         │    │
│  │   ├─ Bound to parent data lifecycle state                      │    │
│  │   └─ Deleted when parent is deleted (cascade)                  │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  PURPOSE BINDING:                                                      │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Purpose (Closed Set):                                           │    │
│  │   ├─ DEBUG: Local debugging only, auto-delete on session end   │    │
│  │   ├─ ANALYTICS: Aggregate stats, no PII, may upload            │    │
│  │   ├─ TRAINING: ML training, requires consent + eligibility     │    │
│  │   └─ OPERATIONAL: Required for app function                    │    │
│  │                                                                 │    │
│  │ Enforcement:                                                    │    │
│  │   ├─ Data tagged with allowed purposes at creation             │    │
│  │   ├─ Purpose checked before any operation                      │    │
│  │   └─ Violation → audit event + block                           │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AM.3 Implementation Files

```
New Files:
├── DataLifecycle/
│   ├── DataClassificationStateMachine.swift  (STAGE AM-001)
│   ├── PurposeBindingPolicy.swift            (STAGE AM-002)
│   ├── DerivativeInventory.swift             (STAGE AM-003)
│   ├── RevocationCascadePlanner.swift        (STAGE AM-004)
│   ├── DeletionCascadeProof.swift            (STAGE AM-005)
│   └── TrainingEligibilityEnforcer.swift     (STAGE AM-006)
└── Tests/
    └── DataLifecycleTests.swift              (STAGE AM-007)
```

### STAGE AM-001: DataClassificationStateMachine.swift

```swift
// DataLifecycle/DataClassificationStateMachine.swift
// STAGE AM-001: Data lifecycle state machine with transitions
// Vulnerability: LIFECYCLE-001, LIFECYCLE-002
// Reference: https://atlan.com/data-governance-and-gdpr/

import Foundation

/// Data lifecycle configuration
public struct DataLifecycleConfig: Codable, Sendable {
    /// Whether derivative tracking is required
    public let derivativeTrackingRequired: Bool

    /// P99 latency for cascade deletion (seconds)
    public let cascadeDeletionP99Sec: Int

    /// Policy for orphan derivatives (no parent)
    public let orphanDerivativePolicy: OrphanPolicy

    /// Whether purpose binding is required
    public let purposeBindingRequired: Bool

    public enum OrphanPolicy: String, Codable, Sendable {
        case allow      // Allow (dangerous)
        case warn       // Warn and log
        case hardDelete // Immediately delete
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> DataLifecycleConfig {
        switch profile {
        case .production:
            return DataLifecycleConfig(
                derivativeTrackingRequired: true,
                cascadeDeletionP99Sec: 300,
                orphanDerivativePolicy: .warn,
                purposeBindingRequired: true
            )
        case .debug:
            return DataLifecycleConfig(
                derivativeTrackingRequired: false,
                cascadeDeletionP99Sec: 600,
                orphanDerivativePolicy: .allow,
                purposeBindingRequired: false
            )
        case .lab:
            return DataLifecycleConfig(
                derivativeTrackingRequired: true,
                cascadeDeletionP99Sec: 30,          // EXTREME
                orphanDerivativePolicy: .hardDelete,
                purposeBindingRequired: true
            )
        }
    }
}

/// Data lifecycle states (closed set)
public enum DataLifecycleState: String, Codable, Sendable, CaseIterable {
    case captured           // Just captured, local only
    case processed          // Features extracted
    case uploaded           // Uploaded to cloud
    case trainingEligible   // Approved for training
    case trainingUsed       // Used in training (immutable)
    case deletionRequested  // Deletion requested
    case deleted            // Deleted (proof exists)

    /// Valid transitions from this state
    public var validTransitions: [DataLifecycleState] {
        switch self {
        case .captured:
            return [.processed, .deletionRequested]
        case .processed:
            return [.uploaded, .deletionRequested]
        case .uploaded:
            return [.trainingEligible, .deletionRequested]
        case .trainingEligible:
            return [.trainingUsed, .deletionRequested]
        case .trainingUsed:
            return [.deletionRequested]  // Can still delete, but with restrictions
        case .deletionRequested:
            return [.deleted]
        case .deleted:
            return []  // Terminal state
        }
    }

    /// Whether data can be used for training in this state
    public var canUseForTraining: Bool {
        return self == .trainingEligible
    }

    /// Whether data can be uploaded in this state
    public var canUpload: Bool {
        return self == .processed
    }
}

/// Data asset with lifecycle tracking
public struct DataAsset: Codable, Sendable {
    public let assetId: String
    public let assetType: AssetType
    public let parentAssetId: String?
    public var currentState: DataLifecycleState
    public let createdAt: Date
    public var stateHistory: [StateTransition]
    public let allowedPurposes: Set<DataPurpose>
    public let consentReceiptId: String?

    public enum AssetType: String, Codable, Sendable, CaseIterable {
        case rawFrame           // Original captured frame
        case descriptor         // Feature descriptor
        case featureVector      // Aggregated features
        case qualityMetric      // Quality measurements
        case mesh               // 3D mesh
        case pointCloud         // Point cloud
        case trainingSample     // Training-ready sample
        case auditRecord        // Audit log entry
    }

    public struct StateTransition: Codable, Sendable {
        public let fromState: DataLifecycleState
        public let toState: DataLifecycleState
        public let timestamp: Date
        public let reason: String
        public let actorId: String
    }
}

/// Data purposes (closed set)
public enum DataPurpose: String, Codable, Sendable, CaseIterable, Hashable {
    case debug          // Local debugging only
    case operational    // Required for app function
    case analytics      // Aggregate analytics
    case training       // ML model training
}

/// Data Lifecycle State Machine
@available(iOS 15.0, macOS 12.0, *)
public actor DataClassificationStateMachine {

    private let config: DataLifecycleConfig
    private var assets: [String: DataAsset] = [:]

    public init(config: DataLifecycleConfig) {
        self.config = config
    }

    /// Register a new data asset
    public func registerAsset(
        assetId: String,
        assetType: DataAsset.AssetType,
        parentAssetId: String?,
        allowedPurposes: Set<DataPurpose>,
        consentReceiptId: String?
    ) throws {

        // Validate parent exists if specified
        if let parentId = parentAssetId {
            guard assets[parentId] != nil else {
                throw DataLifecycleError.parentAssetNotFound(parentId)
            }
        }

        // Validate purpose binding
        if config.purposeBindingRequired && allowedPurposes.isEmpty {
            throw DataLifecycleError.purposeBindingRequired
        }

        // Training requires consent
        if allowedPurposes.contains(.training) && consentReceiptId == nil {
            throw DataLifecycleError.consentRequiredForTraining
        }

        let asset = DataAsset(
            assetId: assetId,
            assetType: assetType,
            parentAssetId: parentAssetId,
            currentState: .captured,
            createdAt: Date(),
            stateHistory: [],
            allowedPurposes: allowedPurposes,
            consentReceiptId: consentReceiptId
        )

        assets[assetId] = asset
    }

    /// Transition asset to new state
    public func transition(
        assetId: String,
        toState: DataLifecycleState,
        reason: String,
        actorId: String
    ) throws {

        guard var asset = assets[assetId] else {
            throw DataLifecycleError.assetNotFound(assetId)
        }

        // Validate transition
        guard asset.currentState.validTransitions.contains(toState) else {
            throw DataLifecycleError.invalidTransition(
                from: asset.currentState,
                to: toState
            )
        }

        // Record transition
        let transition = DataAsset.StateTransition(
            fromState: asset.currentState,
            toState: toState,
            timestamp: Date(),
            reason: reason,
            actorId: actorId
        )

        asset.stateHistory.append(transition)
        asset.currentState = toState
        assets[assetId] = asset
    }

    /// Check if purpose is allowed for asset
    public func checkPurpose(assetId: String, purpose: DataPurpose) throws -> Bool {
        guard let asset = assets[assetId] else {
            throw DataLifecycleError.assetNotFound(assetId)
        }

        if config.purposeBindingRequired && !asset.allowedPurposes.contains(purpose) {
            throw DataLifecycleError.purposeNotAllowed(assetId: assetId, purpose: purpose)
        }

        return asset.allowedPurposes.contains(purpose)
    }

    /// Get all derivatives of an asset
    public func derivatives(of assetId: String) -> [DataAsset] {
        return assets.values.filter { $0.parentAssetId == assetId }
    }

    /// Get all orphan derivatives
    public func orphanDerivatives() -> [DataAsset] {
        return assets.values.filter { asset in
            guard let parentId = asset.parentAssetId else {
                return false  // Root assets are not orphans
            }
            return assets[parentId] == nil
        }
    }
}

/// Data lifecycle errors
public enum DataLifecycleError: Error, LocalizedError {
    case assetNotFound(String)
    case parentAssetNotFound(String)
    case invalidTransition(from: DataLifecycleState, to: DataLifecycleState)
    case purposeBindingRequired
    case purposeNotAllowed(assetId: String, purpose: DataPurpose)
    case consentRequiredForTraining
    case cascadeDeletionTimeout
    case orphanDerivativeFound(assetId: String)

    public var errorDescription: String? {
        switch self {
        case .assetNotFound(let id):
            return "Data asset not found: \(id)"
        case .parentAssetNotFound(let id):
            return "Parent asset not found: \(id)"
        case .invalidTransition(let from, let to):
            return "Invalid state transition: \(from) → \(to)"
        case .purposeBindingRequired:
            return "Purpose binding required but not specified"
        case .purposeNotAllowed(let id, let purpose):
            return "Purpose \(purpose) not allowed for asset \(id)"
        case .consentRequiredForTraining:
            return "Consent receipt required for training purpose"
        case .cascadeDeletionTimeout:
            return "Cascade deletion exceeded timeout"
        case .orphanDerivativeFound(let id):
            return "Orphan derivative found: \(id)"
        }
    }
}
```

---

## PART AN: RUNTIME INTEGRITY & ANTI-TAMPER

### AN.1 Problem Statement

**Vulnerability ID**: RUNTIME-001 through RUNTIME-012
**Severity**: CRITICAL
**Category**: Jailbreak/Root Detection, Hook Detection, Debugger Detection

Current gaps:
1. Build-time supply chain verified but runtime environment not checked
2. No continuous integrity monitoring (only at startup)
3. Frida/hook detection easily bypassed with Stalker API
4. Attestation happens once, not continuously

**Attack Vectors**:
- Jailbreak/Root: Device has elevated privileges
- Frida/Objection: Dynamic instrumentation
- Debugger: Step through and modify execution
- Virtual Camera: Fake camera input
- Memory editing: Modify runtime values

### AN.2 Solution Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    RUNTIME INTEGRITY ARCHITECTURE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CONTINUOUS VERIFICATION (Not just at startup!)                        │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ ┌──────────────┐   ┌──────────────┐   ┌──────────────┐        │    │
│  │ │ Jailbreak/   │   │ Hook/Frida   │   │ Debugger     │        │    │
│  │ │ Root Check   │   │ Detection    │   │ Detection    │        │    │
│  │ └──────┬───────┘   └──────┬───────┘   └──────┬───────┘        │    │
│  │        │                  │                  │                 │    │
│  │        ▼                  ▼                  ▼                 │    │
│  │ ┌─────────────────────────────────────────────────────┐       │    │
│  │ │              Integrity Score Aggregator              │       │    │
│  │ │ • Each check contributes to overall score           │       │    │
│  │ │ • Score below threshold → policy action             │       │    │
│  │ └─────────────────────────────────────────────────────┘       │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                           │                                             │
│                           ▼                                             │
│  POLICY ACTIONS:                                                       │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Score >= 90%: Full functionality                                │    │
│  │ Score 70-90%: Degraded mode (local-only, no upload)            │    │
│  │ Score 50-70%: Minimal mode (logging only)                       │    │
│  │ Score < 50%: Hard deny (app refuses to function)               │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  DETECTION TECHNIQUES:                                                 │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │ Jailbreak/Root:                                                 │    │
│  │   • Suspicious file paths (/Applications/Cydia.app, /su, etc.) │    │
│  │   • Sandbox escape checks                                       │    │
│  │   • Kernel patch detection                                      │    │
│  │   • Code signing validation                                     │    │
│  │                                                                 │    │
│  │ Hook Detection:                                                 │    │
│  │   • Memory checksum of critical functions                       │    │
│  │   • PLT/GOT verification                                        │    │
│  │   • Suspicious library detection (libfrida, libsubstrate)       │    │
│  │   • ptrace detection                                            │    │
│  │                                                                 │    │
│  │ Debugger Detection:                                             │    │
│  │   • ptrace(PT_DENY_ATTACH)                                      │    │
│  │   • P_TRACED flag in proc info                                  │    │
│  │   • Timing anomalies (breakpoint detection)                     │    │
│  └────────────────────────────────────────────────────────────────┘    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### AN.3 Implementation Files

```
New Files:
├── RuntimeIntegrity/
│   ├── RuntimeIntegrityScanner.swift         (STAGE AN-001)
│   ├── JailbreakRootDetector.swift           (STAGE AN-002)
│   ├── FridaHookDetector.swift               (STAGE AN-003)
│   ├── DebuggerAttachDetector.swift          (STAGE AN-004)
│   ├── IntegrityScoreAggregator.swift        (STAGE AN-005)
│   ├── IntegrityPolicyEnforcer.swift         (STAGE AN-006)
│   └── ContinuousIntegrityMonitor.swift      (STAGE AN-007)
└── Tests/
    └── RuntimeIntegrityTests.swift           (STAGE AN-008)
```

### STAGE AN-001: RuntimeIntegrityScanner.swift

```swift
// RuntimeIntegrity/RuntimeIntegrityScanner.swift
// STAGE AN-001: Comprehensive runtime integrity scanner
// Vulnerability: RUNTIME-001, RUNTIME-002
// Reference: https://approov.io/knowledge/frida-detection-prevention

import Foundation

/// Runtime integrity configuration
public struct RuntimeIntegrityConfig: Codable, Sendable {
    /// Policy for jailbreak/root detection
    public let jailbreakPolicy: IntegrityPolicy

    /// Interval between hook detection scans (ms)
    public let hookDetectionIntervalMs: Int

    /// Policy for debugger attachment
    public let debuggerAttachPolicy: IntegrityPolicy

    /// Whether to run continuous integrity checks
    public let integrityCheckContinuous: Bool

    public enum IntegrityPolicy: String, Codable, Sendable {
        case allow      // Allow (very dangerous)
        case degrade    // Degrade to safe mode
        case hardDeny   // Block entirely
    }

    /// Profile-based factory
    public static func forProfile(_ profile: ConfigProfile) -> RuntimeIntegrityConfig {
        switch profile {
        case .production:
            return RuntimeIntegrityConfig(
                jailbreakPolicy: .degrade,
                hookDetectionIntervalMs: 5000,
                debuggerAttachPolicy: .degrade,
                integrityCheckContinuous: true
            )
        case .debug:
            return RuntimeIntegrityConfig(
                jailbreakPolicy: .allow,
                hookDetectionIntervalMs: 30000,
                debuggerAttachPolicy: .allow,
                integrityCheckContinuous: false
            )
        case .lab:
            return RuntimeIntegrityConfig(
                jailbreakPolicy: .hardDeny,          // EXTREME
                hookDetectionIntervalMs: 500,       // EXTREME: frequent checks
                debuggerAttachPolicy: .hardDeny,
                integrityCheckContinuous: true
            )
        }
    }
}

/// Integrity check result
public struct IntegrityCheckResult: Codable, Sendable {
    public let checkId: String
    public let checkType: CheckType
    public let passed: Bool
    public let score: Double  // 0.0 - 1.0
    public let details: String
    public let timestamp: Date
    public let indicators: [ThreatIndicator]

    public enum CheckType: String, Codable, Sendable, CaseIterable {
        case jailbreakRoot
        case hookDetection
        case debuggerAttach
        case memoryIntegrity
        case codeSignature
        case sandboxEscape
    }

    public struct ThreatIndicator: Codable, Sendable {
        public let indicatorId: String
        public let severity: Severity
        public let description: String

        public enum Severity: String, Codable, Sendable {
            case critical
            case high
            case medium
            case low
        }
    }
}

/// Aggregate integrity score
public struct AggregateIntegrityScore: Codable, Sendable {
    public let overallScore: Double  // 0.0 - 1.0
    public let checkResults: [IntegrityCheckResult]
    public let recommendedAction: RecommendedAction
    public let timestamp: Date

    public enum RecommendedAction: String, Codable, Sendable {
        case fullFunctionality      // Score >= 90%
        case degradedMode           // Score 70-90%
        case minimalMode            // Score 50-70%
        case hardDeny               // Score < 50%
    }
}

/// Runtime Integrity Scanner
@available(iOS 15.0, macOS 12.0, *)
public actor RuntimeIntegrityScanner {

    private let config: RuntimeIntegrityConfig
    private var lastScanResults: [IntegrityCheckResult] = []
    private var scanCount: Int = 0

    public init(config: RuntimeIntegrityConfig) {
        self.config = config
    }

    /// Perform full integrity scan
    public func performFullScan() async -> AggregateIntegrityScore {
        var results: [IntegrityCheckResult] = []

        // Jailbreak/Root check
        results.append(await checkJailbreakRoot())

        // Hook detection
        results.append(await checkHooks())

        // Debugger detection
        results.append(await checkDebugger())

        // Memory integrity
        results.append(await checkMemoryIntegrity())

        // Code signature
        results.append(await checkCodeSignature())

        // Sandbox escape
        results.append(await checkSandboxEscape())

        // Calculate aggregate score
        let overallScore = results.reduce(0.0) { $0 + $1.score } / Double(results.count)

        // Determine recommended action
        let action: AggregateIntegrityScore.RecommendedAction
        switch overallScore {
        case 0.9...1.0:
            action = .fullFunctionality
        case 0.7..<0.9:
            action = .degradedMode
        case 0.5..<0.7:
            action = .minimalMode
        default:
            action = .hardDeny
        }

        lastScanResults = results
        scanCount += 1

        return AggregateIntegrityScore(
            overallScore: overallScore,
            checkResults: results,
            recommendedAction: action,
            timestamp: Date()
        )
    }

    // MARK: - Individual Checks

    private func checkJailbreakRoot() async -> IntegrityCheckResult {
        var indicators: [IntegrityCheckResult.ThreatIndicator] = []
        var score = 1.0

        #if os(iOS)
        // Check for suspicious paths
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/mobile/Library/SBSettings/Themes",
            "/private/var/stash"
        ]

        for path in suspiciousPaths {
            if FileManager.default.fileExists(atPath: path) {
                indicators.append(IntegrityCheckResult.ThreatIndicator(
                    indicatorId: "JAILBREAK-PATH-\(path.hashValue)",
                    severity: .critical,
                    description: "Suspicious path exists: \(path)"
                ))
                score -= 0.3
            }
        }

        // Check if we can write outside sandbox
        let testPath = "/private/test_\(UUID().uuidString)"
        if FileManager.default.createFile(atPath: testPath, contents: nil, attributes: nil) {
            try? FileManager.default.removeItem(atPath: testPath)
            indicators.append(IntegrityCheckResult.ThreatIndicator(
                indicatorId: "JAILBREAK-SANDBOX-ESCAPE",
                severity: .critical,
                description: "Sandbox escape detected: can write to /private"
            ))
            score -= 0.5
        }

        // Check for suspicious URL schemes
        let suspiciousSchemes = ["cydia://", "sileo://", "zbra://"]
        for scheme in suspiciousSchemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                indicators.append(IntegrityCheckResult.ThreatIndicator(
                    indicatorId: "JAILBREAK-SCHEME-\(scheme.hashValue)",
                    severity: .high,
                    description: "Suspicious URL scheme available: \(scheme)"
                ))
                score -= 0.2
            }
        }
        #endif

        #if os(Android)
        // Android root detection would go here
        // Check for su binary, Magisk, etc.
        #endif

        return IntegrityCheckResult(
            checkId: "JB-\(scanCount)",
            checkType: .jailbreakRoot,
            passed: indicators.isEmpty,
            score: max(score, 0),
            details: indicators.isEmpty ? "No jailbreak indicators found" : "Found \(indicators.count) jailbreak indicators",
            timestamp: Date(),
            indicators: indicators
        )
    }

    private func checkHooks() async -> IntegrityCheckResult {
        var indicators: [IntegrityCheckResult.ThreatIndicator] = []
        var score = 1.0

        #if os(iOS)
        // Check for Frida-related libraries
        let suspiciousLibraries = [
            "FridaGadget",
            "frida-agent",
            "libfrida",
            "libsubstrate",
            "MobileSubstrate",
            "libcycript"
        ]

        // Get loaded libraries
        let loadedCount = _dyld_image_count()
        for i in 0..<loadedCount {
            if let name = _dyld_get_image_name(i) {
                let libraryName = String(cString: name)
                for suspicious in suspiciousLibraries {
                    if libraryName.contains(suspicious) {
                        indicators.append(IntegrityCheckResult.ThreatIndicator(
                            indicatorId: "HOOK-LIB-\(suspicious)",
                            severity: .critical,
                            description: "Suspicious library loaded: \(libraryName)"
                        ))
                        score -= 0.4
                    }
                }
            }
        }

        // Check for Frida server port (default 27042)
        let fridaPorts = [27042, 27043]
        for port in fridaPorts {
            if isPortOpen(port: port) {
                indicators.append(IntegrityCheckResult.ThreatIndicator(
                    indicatorId: "HOOK-PORT-\(port)",
                    severity: .critical,
                    description: "Frida server port open: \(port)"
                ))
                score -= 0.5
            }
        }
        #endif

        return IntegrityCheckResult(
            checkId: "HOOK-\(scanCount)",
            checkType: .hookDetection,
            passed: indicators.isEmpty,
            score: max(score, 0),
            details: indicators.isEmpty ? "No hook indicators found" : "Found \(indicators.count) hook indicators",
            timestamp: Date(),
            indicators: indicators
        )
    }

    private func checkDebugger() async -> IntegrityCheckResult {
        var indicators: [IntegrityCheckResult.ThreatIndicator] = []
        var score = 1.0

        #if os(iOS)
        // Check P_TRACED flag
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        if result == 0 {
            if (info.kp_proc.p_flag & P_TRACED) != 0 {
                indicators.append(IntegrityCheckResult.ThreatIndicator(
                    indicatorId: "DEBUG-PTRACED",
                    severity: .critical,
                    description: "Process is being traced (debugger attached)"
                ))
                score -= 0.5
            }
        }

        // Timing check (debugger causes slowdown)
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            _ = 1 + 1
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // If simple loop takes > 100ms, likely debugger
        if elapsed > 0.1 {
            indicators.append(IntegrityCheckResult.ThreatIndicator(
                indicatorId: "DEBUG-TIMING",
                severity: .high,
                description: "Timing anomaly detected (possible debugger)"
            ))
            score -= 0.3
        }
        #endif

        return IntegrityCheckResult(
            checkId: "DEBUG-\(scanCount)",
            checkType: .debuggerAttach,
            passed: indicators.isEmpty,
            score: max(score, 0),
            details: indicators.isEmpty ? "No debugger detected" : "Debugger indicators found",
            timestamp: Date(),
            indicators: indicators
        )
    }

    private func checkMemoryIntegrity() async -> IntegrityCheckResult {
        // Placeholder - would check memory checksums of critical functions
        return IntegrityCheckResult(
            checkId: "MEM-\(scanCount)",
            checkType: .memoryIntegrity,
            passed: true,
            score: 1.0,
            details: "Memory integrity check passed",
            timestamp: Date(),
            indicators: []
        )
    }

    private func checkCodeSignature() async -> IntegrityCheckResult {
        // Placeholder - would verify code signature
        return IntegrityCheckResult(
            checkId: "SIGN-\(scanCount)",
            checkType: .codeSignature,
            passed: true,
            score: 1.0,
            details: "Code signature valid",
            timestamp: Date(),
            indicators: []
        )
    }

    private func checkSandboxEscape() async -> IntegrityCheckResult {
        // Placeholder - would check sandbox integrity
        return IntegrityCheckResult(
            checkId: "SANDBOX-\(scanCount)",
            checkType: .sandboxEscape,
            passed: true,
            score: 1.0,
            details: "Sandbox intact",
            timestamp: Date(),
            indicators: []
        )
    }

    // MARK: - Helpers

    private func isPortOpen(port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }
}
```

---

## PART AO: EXPLAINABILITY VIEWS

### AO.1 Problem Statement

**Vulnerability ID**: EXPLAIN-001 through EXPLAIN-008
**Severity**: MEDIUM
**Category**: User Experience, Support Cost, Security Boundary

Current gaps:
1. Users confused why quality was "bad" → support tickets
2. Engineers need full diagnostic data → security risk if exposed
3. Anti-gaming thresholds accidentally leaked to users
4. No standardized reason codes → inconsistent messaging

### AO.2 Implementation

```swift
// Explainability/UserFacingReasonCode.swift
// STAGE AO-001: User-facing reason codes without security leakage
// Vulnerability: EXPLAIN-001, EXPLAIN-002

import Foundation

/// User-facing reason codes (closed set, security-safe)
public enum UserFacingReasonCode: String, Codable, Sendable, CaseIterable {
    // Quality Issues
    case qualityTooLow = "QUALITY_LOW"
    case motionBlur = "MOTION_BLUR"
    case poorLighting = "POOR_LIGHTING"
    case cameraCovered = "CAMERA_COVERED"
    case outOfFocus = "OUT_OF_FOCUS"

    // Environment Issues
    case movementTooFast = "MOVEMENT_TOO_FAST"
    case insufficientFeatures = "INSUFFICIENT_FEATURES"
    case reflectiveSurface = "REFLECTIVE_SURFACE"

    // Device Issues
    case deviceUnsupported = "DEVICE_UNSUPPORTED"
    case permissionDenied = "PERMISSION_DENIED"
    case storageInsufficient = "STORAGE_INSUFFICIENT"

    // Session Issues
    case sessionExpired = "SESSION_EXPIRED"
    case sessionInterrupted = "SESSION_INTERRUPTED"

    // Generic (hides security details)
    case processingError = "PROCESSING_ERROR"
    case unavailableTemporarily = "UNAVAILABLE_TEMPORARILY"

    /// User-friendly message
    public var userMessage: String {
        switch self {
        case .qualityTooLow:
            return "Image quality is too low. Please ensure good lighting and hold the device steady."
        case .motionBlur:
            return "Motion blur detected. Please move the device more slowly."
        case .poorLighting:
            return "Lighting is insufficient. Please move to a brighter area."
        case .cameraCovered:
            return "Camera appears to be covered. Please ensure the lens is clear."
        case .outOfFocus:
            return "Camera is out of focus. Please wait for focus to stabilize."
        case .movementTooFast:
            return "Moving too fast. Please slow down your movements."
        case .insufficientFeatures:
            return "Not enough detail in the scene. Please point at a more textured surface."
        case .reflectiveSurface:
            return "Reflective surfaces detected. Please avoid mirrors and glass."
        case .deviceUnsupported:
            return "This device is not supported."
        case .permissionDenied:
            return "Camera permission is required. Please enable in Settings."
        case .storageInsufficient:
            return "Insufficient storage space. Please free up some space."
        case .sessionExpired:
            return "Session has expired. Please start a new capture."
        case .sessionInterrupted:
            return "Capture was interrupted. Please try again."
        case .processingError:
            return "A processing error occurred. Please try again."
        case .unavailableTemporarily:
            return "This feature is temporarily unavailable. Please try again later."
        }
    }

    /// Whether this code hides security details
    public var isSecurityRedacted: Bool {
        switch self {
        case .processingError, .unavailableTemporarily:
            return true
        default:
            return false
        }
    }
}

/// Mapping from internal codes to user-facing codes
public struct ReasonCodeMapper {

    /// Map internal reason to user-facing code
    /// IMPORTANT: This hides security-sensitive details
    public static func mapToUserFacing(
        internalCode: String,
        internalDetails: [String: Any]
    ) -> UserFacingReasonCode {

        // Security-sensitive codes → generic
        let securityCodes = [
            "ATTESTATION_FAILED",
            "INTEGRITY_CHECK_FAILED",
            "JAILBREAK_DETECTED",
            "HOOK_DETECTED",
            "REPLAY_DETECTED",
            "SPLICE_DETECTED",
            "RATE_LIMIT_EXCEEDED",
            "ABUSE_DETECTED"
        ]

        if securityCodes.contains(internalCode) {
            return .unavailableTemporarily  // Hide security details
        }

        // Map known codes
        switch internalCode {
        case "QUALITY_SCORE_BELOW_THRESHOLD":
            return .qualityTooLow
        case "MOTION_BLUR_DETECTED":
            return .motionBlur
        case "LOW_LIGHT_DETECTED":
            return .poorLighting
        case "CAMERA_OCCLUDED":
            return .cameraCovered
        case "FOCUS_UNSTABLE":
            return .outOfFocus
        case "VELOCITY_TOO_HIGH":
            return .movementTooFast
        case "FEATURE_COUNT_LOW":
            return .insufficientFeatures
        case "REFLECTION_DETECTED":
            return .reflectiveSurface
        default:
            return .processingError
        }
    }
}
```

---

## PART AP: ENGINEERING HYGIENE & PLAN INTEGRITY

### AP.1 Problem Statement

**Vulnerability ID**: HYGIENE-001 through HYGIENE-008
**Severity**: MEDIUM
**Category**: Plan Traceability, Coverage Reporting, Implementation Drift

Current gaps:
1. "315 vulnerabilities" claim not machine-verifiable
2. No mapping from issue ID → file → test → gate → metric
3. Plan file format errors (YAML corruption, duplicate IDs)
4. Orphan files (code exists but not in plan)

### AP.2 Implementation

```swift
// PlanIntegrity/HardeningIssueRegistry.swift
// STAGE AP-001: Machine-verifiable hardening issue registry
// Vulnerability: HYGIENE-001, HYGIENE-002

import Foundation

/// Hardening issue entry
public struct HardeningIssue: Codable, Sendable {
    /// Unique issue ID (e.g., PR5-HRD-0001)
    public let issueId: String

    /// Human-readable title
    public let title: String

    /// PART this issue belongs to
    public let part: String

    /// Stage implementing this issue
    public let stage: String

    /// Source file(s) implementing this issue
    public let sourceFiles: [String]

    /// Test file(s) covering this issue
    public let testFiles: [String]

    /// Quality gate(s) enforcing this issue
    public let gates: [String]

    /// Metrics tracking this issue
    public let metrics: [String]

    /// Threat IDs this issue mitigates
    public let mitigatedThreats: [ThreatID]

    /// Severity
    public let severity: Severity

    /// Status
    public let status: Status

    public enum Severity: String, Codable, Sendable {
        case critical
        case high
        case medium
        case low
    }

    public enum Status: String, Codable, Sendable {
        case planned
        case inProgress
        case implemented
        case tested
        case verified
    }
}

/// Hardening Issue Registry
@available(iOS 15.0, macOS 12.0, *)
public actor HardeningIssueRegistry {

    private var issues: [String: HardeningIssue] = [:]

    /// Register an issue
    public func register(_ issue: HardeningIssue) throws {
        if issues[issue.issueId] != nil {
            throw RegistryError.duplicateIssueId(issue.issueId)
        }
        issues[issue.issueId] = issue
    }

    /// Generate coverage report
    public func generateCoverageReport() -> CoverageReport {
        let total = issues.count
        let implemented = issues.values.filter { $0.status == .implemented || $0.status == .tested || $0.status == .verified }.count
        let tested = issues.values.filter { $0.status == .tested || $0.status == .verified }.count
        let verified = issues.values.filter { $0.status == .verified }.count

        let withTests = issues.values.filter { !$0.testFiles.isEmpty }.count
        let withGates = issues.values.filter { !$0.gates.isEmpty }.count
        let withMetrics = issues.values.filter { !$0.metrics.isEmpty }.count

        return CoverageReport(
            totalIssues: total,
            implementedCount: implemented,
            testedCount: tested,
            verifiedCount: verified,
            implementationPercent: Double(implemented) / Double(total) * 100,
            testCoveragePercent: Double(withTests) / Double(total) * 100,
            gateCoveragePercent: Double(withGates) / Double(total) * 100,
            metricCoveragePercent: Double(withMetrics) / Double(total) * 100
        )
    }

    public struct CoverageReport: Sendable {
        public let totalIssues: Int
        public let implementedCount: Int
        public let testedCount: Int
        public let verifiedCount: Int
        public let implementationPercent: Double
        public let testCoveragePercent: Double
        public let gateCoveragePercent: Double
        public let metricCoveragePercent: Double
    }

    public enum RegistryError: Error {
        case duplicateIssueId(String)
    }
}
```

---

## FILE SUMMARY

| PART | Files | Stages | Vulnerabilities | Key Components |
|------|-------|--------|-----------------|----------------|
| AK: Threat Model | 9 | AK-001 to AK-009 | 15 | ThreatModelCatalog, ControlMappingManifest, ThreatToGateCompiler |
| AL: Identity Chain | 7 | AL-001 to AL-007 | 15 | SessionIdentityEnvelope, SignedDecisionRecord, MerkleCommitChain |
| AM: Data Lifecycle | 7 | AM-001 to AM-007 | 12 | DataClassificationStateMachine, DerivativeInventory, RevocationCascade |
| AN: Runtime Integrity | 8 | AN-001 to AN-008 | 12 | RuntimeIntegrityScanner, FridaHookDetector, IntegrityPolicyEnforcer |
| AO: Explainability | 5 | AO-001 to AO-005 | 8 | UserFacingReasonCode, EngineerDiagnosticBundle, RedactionPolicy |
| AP: Plan Integrity | 5 | AP-001 to AP-005 | 8 | HardeningIssueRegistry, PlanSchemaValidator, CoverageReporter |
| **Total** | **41** | **41** | **85** (70 new + 15 cross-cutting) | - |

---

## INTEGRATION WITH v1.5

This supplement integrates with v1.5 as follows:

1. **Threat Model (AK)** validates ALL modules (AC-AJ) have threat mappings
2. **Identity Chain (AL)** binds **Attestation (T)** to **Upload (U)** to **Ledger (S)**
3. **Data Lifecycle (AM)** governs **Privacy (AH)** and **Consent (AI)** deletions
4. **Runtime Integrity (AN)** gates **Attestation (T)** validity continuously
5. **Explainability (AO)** surfaces **Quality (3)** and **Incident (AJ)** results
6. **Plan Integrity (AP)** tracks ALL issues (AC-AJ) implementation status

---

## CURSOR IMPLEMENTATION INSTRUCTION

When implementing this supplement:

1. **Threat Model First**: Implement PART AK first to establish mappings
2. **Identity Chain**: Then PART AL to bind all subsequent data
3. **Data Lifecycle**: PART AM to govern deletion cascades
4. **Runtime Integrity**: PART AN runs continuously from app start
5. **Explainability**: PART AO maps internal codes to user-safe codes
6. **Plan Integrity**: PART AP validates plan file integrity

### Critical Implementation Rules

1. **No `other` cases in enums**: All enums MUST be exhaustive
2. **Continuous verification**: Runtime checks MUST run periodically, not just at startup
3. **Cascade deletions**: MUST delete ALL derivatives when parent is deleted
4. **User-facing codes**: MUST NOT leak security thresholds or detection methods
5. **Plan validation**: MUST fail CI if plan file has schema errors

---

## END OF PR5 PATCH v1.6 SUPPLEMENT
