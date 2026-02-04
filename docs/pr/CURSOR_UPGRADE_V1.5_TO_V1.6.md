# CURSOR INSTRUCTION: Upgrade PR5 Plan from v1.5 to v1.6

## 🎯 YOUR TASK

Upgrade the existing `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md` file from v1.5 to v1.6, integrating **Cross-Module Contracts** - the connective tissue binding all security modules into a unified verifiable system.

---

## 📁 REQUIRED READING (IN ORDER)

### 1. Current Plan Document (Target for Upgrade)
```
pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md
```
This is the file you will modify.

### 2. v1.6 Supplement Document (~3,500+ lines, Complete Swift Implementation)
```
/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_6_SUPPLEMENT_CROSS_MODULE_CONTRACTS.md
```
**MUST READ COMPLETELY** - Contains 6 new modules with complete code.

### 3. v1.5 Supplement Document (For Reference)
```
/Users/kaidongwang/Documents/progecttwo/progect2/progect2/docs/pr/PR5_PATCH_V1_5_SUPPLEMENT_SYSTEM_PERIMETER.md
```
Reference for understanding existing v1.5 modules (AC through AJ).

---

## ⚠️ CRITICAL: v1.5 ERRATA TO APPLY FIRST (3 Fixes)

Before adding v1.6 content, **MUST apply these v1.5 errata fixes**:

### Errata 1: Network Retry Count (Anti-Security Pattern)
```
❌ WRONG: U: maxRetryAttempts = 50 (lab)
   Problem: Creates retry storm, masks network issues, amplifies DDoS

✅ FIX:
   - lab: maxRetryAttempts = 2 (stricter than production!)
   - NEW: maxRetryAttempts_P0_incident = 0 (disable retry during incident)
```

### Errata 2: Audit Retention Period (Provability Violation)
```
❌ WRONG: W: auditRetentionDays = 1 (lab)
   Problem: Lab is validation environment, needs MORE audit data

✅ FIX:
   - lab: auditRetentionDays = 30 (longer than debug for analysis)
   - debug: auditRetentionDays = 7
   - production: auditRetentionDays = 2555 (7-year compliance)
```

### Errata 3: Memory Warning Threshold (Platform Mismatch)
```
❌ WRONG: X: lowMemoryWarningMB = 10 (lab)
   Problem: iOS/Android don't trigger callbacks at precise MB values

✅ FIX: Replace single threshold with 3-signal system:
   1. systemLowMemorySignal: Boolean (OS callback)
   2. workingSetTrendMB: [Int] (5-sample moving average)
   3. consecutiveWarningCount: Int (debounce)
   - Lab: workingSetTrendThreshold = 50MB, consecutiveWarningCount = 2
```

---

## 📝 UPGRADE STEPS

### Step 1: Update Document Header

Update version from v1.5.0 to v1.6.0:

```markdown
# PR5 v1.6.0 Complete Hardening Patch - Implementation Plan

## Overview

This plan implements PR5 Capture Optimization v1.6.0 Complete Hardening Patch, addressing **400 production-critical vulnerabilities**
(v1.2: 60 + v1.3: 52 + v1.3.2: 108 + v1.4: 112 + v1.5: 95 + v1.6: 85 = 400 total after deduplication),
covering the complete system from sensor to cloud to operational compliance with **cross-module contracts**.

## Version Evolution

- **v1.2**: Foundation Hardening (60 vulnerabilities)
- **v1.3**: Production Validation Hardening (52 new vulnerabilities)
- **v1.3.2**: Extreme Hardening (108 new vulnerabilities) - Five Core Methodologies
- **v1.4**: Advanced Security Hardening (112 new vulnerabilities) - End-to-Cloud Verification
- **v1.5**: System Perimeter Hardening (95 new vulnerabilities) - Supply Chain to Incident Response
- **v1.6**: Cross-Module Contracts (85 new vulnerabilities) ← **NEW**
  - PART AK: Threat Model Compiler (STRIDE/LINDDUN/CAPEC → Control → Test → Metric → Gate)
  - PART AL: End-to-End Identity Chain (Device + Session + Content cryptographic binding)
  - PART AM: Data Lifecycle & Derivative Governance (Lineage tracking, cascade deletion)
  - PART AN: Runtime Integrity & Anti-Tamper (Continuous jailbreak/hook/debug detection)
  - PART AO: Explainability Views (User-safe messages vs Engineer diagnostics)
  - PART AP: Engineering Hygiene & Plan Integrity (Machine-verifiable issue tracking)
```

### Step 2: Append v1.6 Extreme Values Table After Existing Tables

```markdown
## Extreme Values Reference Table (Lab Profile) - v1.6 Cross-Module Contracts

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
```

### Step 3: Append 6 New PART Modules (Copy from v1.6 Supplement)

From `PR5_PATCH_V1_6_SUPPLEMENT_CROSS_MODULE_CONTRACTS.md`, copy ALL content for:

1. **PART AK: Threat Model Compiler** (STAGE AK-001 to AK-009)
   - ThreatModelCatalog.swift
   - STRIDEThreatCategory.swift (inline in catalog)
   - LINDDUNThreatCategory.swift (inline in catalog)
   - CAPECAttackPattern.swift
   - ControlMappingManifest.swift
   - ThreatToGateCompiler.swift
   - AttackSurfaceInventory.swift
   - ThreatCoverageReport.swift
   - ThreatModelCompilerTests.swift

2. **PART AL: End-to-End Identity Chain** (STAGE AL-001 to AL-007)
   - DeviceIdentityProvider.swift
   - SessionIdentityEnvelope.swift
   - ContentHasher.swift
   - SignedDecisionRecord.swift
   - MerkleCommitChain.swift
   - IdentityChainValidator.swift
   - IdentityChainTests.swift

3. **PART AM: Data Lifecycle & Derivative Governance** (STAGE AM-001 to AM-007)
   - DataClassification.swift
   - DataClassificationStateMachine.swift
   - DerivativeInventory.swift
   - RevocationCascade.swift
   - PurposeBinding.swift
   - DataLifecycleTests.swift

4. **PART AN: Runtime Integrity & Anti-Tamper** (STAGE AN-001 to AN-008)
   - RuntimeIntegrityScanner.swift
   - JailbreakDetector.swift
   - FridaHookDetector.swift
   - DebuggerDetector.swift
   - IntegrityCheckScheduler.swift
   - AttestationEnforcer.swift
   - RuntimeIntegrityTests.swift

5. **PART AO: Explainability Views** (STAGE AO-001 to AO-006)
   - UserFacingReasonCode.swift
   - EngineerDiagnosticBundle.swift
   - RedactionPolicy.swift
   - ExplainabilityRouter.swift
   - ExplainabilityTests.swift

6. **PART AP: Engineering Hygiene & Plan Integrity** (STAGE AP-001 to AP-008)
   - HardeningIssueRegistry.swift
   - IssueTraceabilityMatrix.swift
   - PlanSchemaValidator.swift
   - CoverageReporter.swift
   - OrphanFileDetector.swift
   - PlanIntegrityTests.swift

### Step 4: Update Project Structure

Add new directories in project structure section:

```
Sources/
├── PR5Capture/
│   ├── ThreatModel/                          # PART AK
│   │   ├── ThreatModelCatalog.swift
│   │   ├── CAPECAttackPattern.swift
│   │   ├── ControlMappingManifest.swift
│   │   ├── ThreatToGateCompiler.swift
│   │   ├── AttackSurfaceInventory.swift
│   │   └── ThreatCoverageReport.swift
│   ├── IdentityChain/                        # PART AL
│   │   ├── DeviceIdentityProvider.swift
│   │   ├── SessionIdentityEnvelope.swift
│   │   ├── ContentHasher.swift
│   │   ├── SignedDecisionRecord.swift
│   │   ├── MerkleCommitChain.swift
│   │   └── IdentityChainValidator.swift
│   ├── DataLifecycle/                        # PART AM
│   │   ├── DataClassification.swift
│   │   ├── DataClassificationStateMachine.swift
│   │   ├── DerivativeInventory.swift
│   │   ├── RevocationCascade.swift
│   │   └── PurposeBinding.swift
│   ├── RuntimeIntegrity/                     # PART AN
│   │   ├── RuntimeIntegrityScanner.swift
│   │   ├── JailbreakDetector.swift
│   │   ├── FridaHookDetector.swift
│   │   ├── DebuggerDetector.swift
│   │   ├── IntegrityCheckScheduler.swift
│   │   └── AttestationEnforcer.swift
│   ├── Explainability/                       # PART AO
│   │   ├── UserFacingReasonCode.swift
│   │   ├── EngineerDiagnosticBundle.swift
│   │   ├── RedactionPolicy.swift
│   │   └── ExplainabilityRouter.swift
│   └── PlanIntegrity/                        # PART AP
│       ├── HardeningIssueRegistry.swift
│       ├── IssueTraceabilityMatrix.swift
│       ├── PlanSchemaValidator.swift
│       ├── CoverageReporter.swift
│       └── OrphanFileDetector.swift
```

### Step 5: Update Summary Table

```markdown
## File Summary

| PART | File Count | Stage Count | Vulnerability Count |
|------|------------|-------------|---------------------|
| Original 0-11 (v1.2) | ~30 | ~60 | 60 |
| Original A-R (v1.3/v1.3.2) | ~50+ | ~108 | 160 |
| S-AB (v1.4) | ~55 | ~55 | 112 |
| AC-AJ (v1.5) | ~50 | ~50 | 95 |
| AK: Threat Model Compiler | 9 | AK-001 to AK-009 | 15 |
| AL: Identity Chain | 7 | AL-001 to AL-007 | 12 |
| AM: Data Lifecycle | 7 | AM-001 to AM-007 | 14 |
| AN: Runtime Integrity | 8 | AN-001 to AN-008 | 16 |
| AO: Explainability | 6 | AO-001 to AO-006 | 12 |
| AP: Plan Integrity | 8 | AP-001 to AP-008 | 16 |
| **TOTAL** | **~230** | **~300** | **400** |
```

### Step 6: Update Success Criteria

Append after existing success criteria:

```markdown
### v1.6 New Success Criteria

✅ v1.5 Errata Applied (3 numerical fixes)
✅ All STRIDE threats have mapped controls (100% lab coverage)
✅ All LINDDUN threats have mapped controls (100% lab coverage)
✅ CAPEC attack patterns linked to relevant threats
✅ Session identity envelope validated on every upload
✅ Merkle commit chain verified every 10 frames (lab)
✅ Replay attack detection within 5-second window (lab)
✅ Derivative data inventory complete with purpose binding
✅ Cascade deletion completes in <30s P99 (lab)
✅ Runtime integrity check runs every 500ms (lab)
✅ Jailbreak/root detection blocks sensitive operations
✅ Frida hook detection prevents upload
✅ User-facing reason codes don't expose thresholds
✅ Engineer diagnostic bundles auto-captured on failure
✅ All hardening issues have machine-verifiable IDs
✅ 100% test coverage for all v1.6 modules (lab)
```

---

## ✅ COMPLETION CHECKLIST

- [ ] Version number updated to v1.6.0
- [ ] Total vulnerability count updated to 400
- [ ] v1.5 errata corrections applied (3 fixes)
- [ ] v1.6 extreme values table added
- [ ] 6 new PART modules fully appended (AK through AP)
- [ ] ALL Swift code included (from supplement document)
- [ ] Project structure updated with 6 new directories
- [ ] Summary table updated
- [ ] Success criteria updated
- [ ] Five Core Methodologies consistently applied in new modules
- [ ] Cross-module integration relationships documented

---

## 🔗 v1.5 ↔ v1.6 MODULE INTEGRATION RELATIONSHIPS

```
v1.5 Modules                    v1.6 Modules
─────────────────────────────────────────────────────────
T: Remote Attestation   ←── validates ──→  AL: Identity Chain
AC: Supply Chain        ←── maps to ──→    AK: Threat Model
AD: Key Management      ←── signs ──→      AL: Identity Chain
AE: AuthZ               ←── enforced by ──→ AN: Runtime Integrity
AF: Abuse Prevention    ←── uses ──→       AO: Explainability (reason codes)
AG: DR/Backup           ←── tracks ──→     AM: Data Lifecycle
AH: Privacy             ←── audits ──→     AM: Data Lifecycle (derivatives)
AI: Consent             ←── recorded by ──→ AM: Data Lifecycle (purpose binding)
AJ: Incident Response   ←── detected by ──→ AN: Runtime Integrity
All Modules             ←── traced by ──→  AP: Plan Integrity
```

---

## 🔐 v1.6 SPECIFIC SECURITY PRINCIPLES

### Principle 1: Threat-Control Traceability
Every security control MUST be traceable to a specific threat. Untraceable controls are:
- **Lab**: BUILD FAILURE (hard-fail)
- **Debug**: Warning logged
- **Production**: Warning to security team

### Principle 2: Cryptographic Identity Chain
Every piece of data MUST be cryptographically bound to:
1. Device identity (hardware-attested)
2. Session identity (signed envelope)
3. Content hash (Merkle commitment)

This triple-binding prevents:
- Replay attacks (content re-use)
- Splice attacks (cross-session mixing)
- Repudiation (session denial)

### Principle 3: Derivative Awareness
Deletion of raw data MUST cascade to ALL derivatives:
- Features extracted from raw data
- Embeddings generated from features
- Model inputs derived from embeddings

Orphan derivatives are:
- **Lab**: Auto-deleted (hard-delete)
- **Debug**: Warning logged
- **Production**: Compliance alert

### Principle 4: Continuous Runtime Verification
Security verification is NOT a one-time startup check:
- **Jailbreak**: Continuous detection (every check interval)
- **Hooks**: Library scan + timing anomalies
- **Debugger**: P_TRACED + port scanning
- **Emulator**: Hardware feature validation

### Principle 5: Explainability Separation
User-facing messages MUST NOT reveal:
- Threshold values (gaming prevention)
- Detection algorithms (bypass prevention)
- Internal metrics (information disclosure)

Engineer diagnostics MUST capture:
- Full context for debugging
- Metric values at failure time
- System state snapshot

### Principle 6: Machine-Verifiable Planning
Planning documents MUST be parseable by CI:
- Every issue has unique ID
- Every ID links to file, test, gate, metric
- Orphan files detected automatically
- Coverage gaps reported before merge

---

## 📚 REFERENCE DOCUMENTATION

This upgrade is based on:

### Threat Modeling Standards
- STRIDE Model (Microsoft) - Security threat classification
- LINDDUN Framework (KU Leuven) - Privacy threat classification
- CAPEC (MITRE) - 563 attack pattern enumeration

### Identity & Attestation
- TCG Device Identifier Composition Engine (DICE)
- FIDO Alliance Attestation Guidelines (2024)
- C2PA Content Authenticity Specification v1.4
- RFC 9683 Remote Integrity Verification

### Data Governance
- GDPR Article 17 (Right to Erasure)
- Data Lineage for EU AI Act Compliance
- Purpose Binding under GDPR Processing Principles

### Runtime Security
- Approov Frida Detection Best Practices
- Appdome Anti-Hook Techniques
- 8kSec Root Detection Bypass Research
- Guardsquare iOS Protection Guidelines

### Cryptographic Audit
- Merkle Tree for Blockchain Audit Trails
- zkSNARK-based Transparent Auditing

---

## 🚀 EXECUTION INSTRUCTIONS

1. **FIRST READ** `PR5_PATCH_V1_6_SUPPLEMENT_CROSS_MODULE_CONTRACTS.md` completely
2. **VERIFY** you understand the 6 new PART modules (AK through AP)
3. **APPLY** the 3 v1.5 errata fixes
4. **THEN MODIFY** `pr5_v1.2_bulletproof_patch_实现计划_7517201e.plan.md`
5. **ENSURE** all Swift code is copied completely - DO NOT simplify or omit

### Code Copying Rules

When copying Swift code from the supplement:
1. **PRESERVE** all comments including vulnerability IDs
2. **PRESERVE** all `// Reference:` links
3. **PRESERVE** all STAGE markers
4. **PRESERVE** exact parameter names and types
5. **PRESERVE** ConfigProfile-based factory methods
6. **DO NOT** abbreviate with "..." or "// same as above"
7. **DO NOT** merge files to "simplify"
8. **DO NOT** remove any test files

### Phase Numbering

New phases should be numbered after existing v1.5 phases:
- If v1.5 ends at phase35, v1.6 starts at phase36
- Each STAGE becomes one implementation phase
- Group related STAGEs into logical phase blocks

**BEGIN UPGRADE NOW!**
