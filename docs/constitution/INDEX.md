# Aether3D Constitution Index

⚠️ Legal Hierarchy Notice

This repository follows a strict document hierarchy:

1. FP1_v1.3.10.md (Supreme Specification, SSOT)
2. IMPLEMENTATION.md (Binding Mapping)
3. All other documents (Non-authoritative)

Any interpretation, implementation, or discussion that conflicts
with FP1_v1.3.10.md is considered INVALID.

README.md is NOT a specification document.

---

## Constitution Documents

### PR#1 SSOT Foundation v1.1 Core Documents

- [SSOT_FOUNDATION_v1.1.md](SSOT_FOUNDATION_v1.1.md) - Core foundation document (A1-A5, B1-B3, CE, CL2)
  - **Who depends:** All subsequent PRs (PR#4, PR#6, PR#7+)
  - **What breaks if violated:** Platform determinism, cross-platform consistency, audit trail
  - **Why exists:** Establishes immutable platform-level contracts

- [MATH_SAFETY_INVARIANTS.md](MATH_SAFETY_INVARIANTS.md) - Math safety invariants (safe division, clamp rules)
  - **Who depends:** All coverage/PIZ/S-state calculation modules
  - **What breaks if violated:** Mathematical correctness, audit trail integrity
  - **Why exists:** Ensures all math operations are safe and auditable

- [SYSTEM_CONTRACTS.md](SYSTEM_CONTRACTS.md) - System contracts (mesh input, output fields, session boundaries)
  - **Who depends:** PR#6 (evidence grid), PR#4 (capture), API handlers
  - **What breaks if violated:** Input validation, output contract compliance
  - **Why exists:** Defines what inputs are legal and what outputs are guaranteed

- [CROSS_PLATFORM_CONSISTENCY.md](CROSS_PLATFORM_CONSISTENCY.md) - Cross-platform consistency rules
  - **Who depends:** All identity derivation, hash computation, color conversion modules
  - **What breaks if violated:** Cross-platform determinism, identity stability
  - **Why exists:** Ensures iOS/Android/Server produce identical results

- [AUDIT_IMMUTABILITY.md](AUDIT_IMMUTABILITY.md) - Audit immutability principles
  - **Who depends:** All storage/audit modules, dispute resolution systems
  - **What breaks if violated:** Audit trail integrity, legal defensibility
  - **Why exists:** Ensures all records are auditable and undeletable

- [USER_EXPLANATIONS.md](USER_EXPLANATIONS.md) - User explanation layer contract
  - **Who depends:** UI layer, support systems, pricing modules
  - **What breaks if violated:** User trust, support efficiency
  - **Why exists:** Defines what the system can say to users

- [CLOSED_SET_GOVERNANCE.md](CLOSED_SET_GOVERNANCE.md) - Closed-set governance rules
  - **Who depends:** All enum definitions, CI systems
  - **What breaks if violated:** Enum stability, log comparability
  - **Why exists:** Prevents silent enum drift across years

- [MIGRATION_GUIDE.md](MIGRATION_GUIDE.md) - Migration guide template
  - **Who depends:** Future version migrations, breaking change handlers
  - **What breaks if violated:** Migration safety, data integrity
  - **Why exists:** Provides template for safe version migrations

### PR#1 SSOT Foundation v1.1.1 Extension Documents

- [CROSS_PLATFORM_CANONICALIZATION.md](CROSS_PLATFORM_CANONICALIZATION.md) - Canonicalization rules (v1.1.1)
  - **Who depends:** DeterministicQuantization, DeterministicEncoding modules
  - **What breaks if violated:** Cross-platform determinism, identity stability
  - **Why exists:** Ensures pre-quantization floating-point representations are consistent

- [IDENTITY_INHERITANCE_MATRIX.md](IDENTITY_INHERITANCE_MATRIX.md) - Identity inheritance matrix (v1.1.1)
  - **Who depends:** Incremental reconstruction, migration systems
  - **What breaks if violated:** Silent identity drift, incorrect inheritance
  - **Why exists:** Prevents silent identity drift in incremental reconstruction

- [REPRODUCIBILITY_BOUNDARY.md](REPRODUCIBILITY_BOUNDARY.md) - Reproducibility boundary (v1.1.1)
  - **Who depends:** Replay systems, dispute resolution, audit verification
  - **What breaks if violated:** Asset reproducibility, dispute resolution capability
  - **Why exists:** Defines minimal replay bundle for complete asset reproduction

### PR#1 SSOT Foundation v1.1.1 Hardening Documents

- [GOLDEN_VECTOR_GOVERNANCE.md](GOLDEN_VECTOR_GOVERNANCE.md) - Golden vector governance policy
  - **Who depends:** All contributors modifying golden vectors, CI systems
  - **What breaks if violated:** Historical determinism, audit trail integrity
  - **Why exists:** Prevents silent golden vector rewrites, enforces breaking change documentation

- [DEVELOPER_FAILURE_TRIAGE.md](DEVELOPER_FAILURE_TRIAGE.md) - Developer failure triage map
  - **Who depends:** All contributors encountering test failures
  - **What breaks if violated:** Developer productivity, accidental violations
  - **Why exists:** Provides actionable guidance for test failures, prevents frustration

- [DETERMINISM_PHILOSOPHY.md](DETERMINISM_PHILOSOPHY.md) - Determinism philosophy
  - **Who depends:** All contributors, future maintainers
  - **What breaks if violated:** System intent alignment, long-term health
  - **Why exists:** Aligns future contributors with system intent, explains core principles

- [FAILURE_TRIAGE_MAP.md](FAILURE_TRIAGE_MAP.md) - Failure triage map (Guardian Layer)
  - **Who depends:** All contributors encountering test failures
  - **What breaks if violated:** Developer productivity, accidental violations
  - **Why exists:** Prevents "fixing tests" instead of fixing reality, provides actionable guidance

- [EXPLANATION_INTEGRITY_AUDIT.md](EXPLANATION_INTEGRITY_AUDIT.md) - Explanation integrity audit (Guardian Layer)
  - **Who depends:** Product managers, support team, developers
  - **What breaks if violated:** User trust, support efficiency, product quality
  - **Why exists:** Ensures system never lies to users, never shows unexplained outputs, never erodes trust

- [GUARDIAN_LAYER.md](GUARDIAN_LAYER.md) - Guardian Layer unified system
  - **Who depends:** All contributors, CI systems, product managers
  - **What breaks if violated:** System coherence, developer productivity, user trust
  - **Why exists:** Unifies CI enforcement, failure triage, and user trust into one coherent system

### Machine-Readable Catalogs (constants/)

- [constants/EDGE_CASE_TYPES.json](constants/EDGE_CASE_TYPES.json) - Edge case types catalog
  - **Who depends:** All modules that detect edge cases
  - **What breaks if violated:** Edge case handling consistency
  - **Why exists:** Machine-readable catalog of all edge cases

- [constants/RISK_FLAGS.json](constants/RISK_FLAGS.json) - Risk flags catalog
  - **Who depends:** Anti-cheat systems, risk assessment modules
  - **What breaks if violated:** Risk detection consistency
  - **Why exists:** Machine-readable catalog of all risk flags

- [constants/COLOR_MATRICES.json](constants/COLOR_MATRICES.json) - Color conversion matrices (CE)
  - **Who depends:** Color conversion modules, L3 evidence computation
  - **What breaks if violated:** Color consistency, cross-platform determinism
  - **Why exists:** SSOT for color conversion matrices (D65 fixed)

- [constants/USER_EXPLANATION_CATALOG.json](constants/USER_EXPLANATION_CATALOG.json) - User explanation catalog (B1)
  - **Who depends:** UI layer, support systems, explanation rendering
  - **What breaks if violated:** User trust, explanation consistency
  - **Why exists:** Machine-readable catalog of all user-facing explanations

- [constants/BREAKING_CHANGE_SURFACE.json](constants/BREAKING_CHANGE_SURFACE.json) - Breaking change surface (v1.1.1)
  - **Who depends:** RFC process, migration systems, CI checks
  - **What breaks if violated:** Breaking change detection, migration safety
  - **Why exists:** Machine-readable list of breaking change points

- [constants/MINIMUM_EXPLANATION_SET.json](constants/MINIMUM_EXPLANATION_SET.json) - Minimum explanation set (v1.1.1)
  - **Who depends:** CI validation, catalog completeness checks
  - **What breaks if violated:** Explanation coverage completeness
  - **Why exists:** Ensures critical explanations are never omitted

- [constants/DOMAIN_PREFIXES.json](constants/DOMAIN_PREFIXES.json) - Domain separation prefixes (v1.1.1)
  - **Who depends:** Hash computation, identity derivation
  - **What breaks if violated:** Hash collision, identity confusion
  - **Why exists:** Prevents ad-hoc prefixes that could cause collisions

- [constants/REASON_COMPATIBILITY.json](constants/REASON_COMPATIBILITY.json) - Reason compatibility rules
  - **Who depends:** Primary reason selection logic, explanation rendering
  - **What breaks if violated:** Contradictory reason combinations
  - **Why exists:** Prevents contradictory reason combinations

- [constants/GOLDEN_VECTORS_ENCODING.json](constants/GOLDEN_VECTORS_ENCODING.json) - Golden vectors for encoding
  - **Who depends:** DeterministicEncoding tests, CI validation
  - **What breaks if violated:** Encoding determinism verification
  - **Why exists:** Provides test vectors for encoding determinism

- [constants/GOLDEN_VECTORS_QUANTIZATION.json](constants/GOLDEN_VECTORS_QUANTIZATION.json) - Golden vectors for quantization
  - **Who depends:** DeterministicQuantization tests, CI validation
  - **What breaks if violated:** Quantization determinism verification
  - **Why exists:** Provides test vectors for quantization determinism

- [constants/GOLDEN_VECTORS_COLOR.json](constants/GOLDEN_VECTORS_COLOR.json) - Golden vectors for color conversion
  - **Who depends:** ColorSpace tests, CI validation
  - **What breaks if violated:** Color conversion determinism verification
  - **Why exists:** Provides test vectors for color conversion determinism

### Legacy Documents

- [FP1_v1.3.10.md](FP1_v1.3.10.md) - Supreme Specification
- [IMPLEMENTATION.md](IMPLEMENTATION.md) - Implementation Mapping
- [SEMVER.md](SEMVER.md) - Semantic Versioning
- [AUDIT_SPEC.md](AUDIT_SPEC.md) - Audit Specification
- [AUDIT_TRACE_CONTRACT.md](AUDIT_TRACE_CONTRACT.md) - Audit Trace Contract (PR#8.5)
- [DETERMINISM_SPEC.md](DETERMINISM_SPEC.md) - Determinism Specification
- [RFC_PROCESS.md](RFC_PROCESS.md) - RFC Process
- [RFC_TEMPLATE.md](RFC_TEMPLATE.md) - RFC Template
- [REPO_INVENTORY.md](REPO_INVENTORY.md) - Repository Inventory
- [REPO_SEAL_VERSION.md](REPO_SEAL_VERSION.md) - Repository Seal Version
- [MANUAL_CHECKS.md](MANUAL_CHECKS.md) - Manual Check Procedures
- [NO_RULES_OUTSIDE_CONSTITUTION.md](NO_RULES_OUTSIDE_CONSTITUTION.md) - Rules Boundary
- [DOC_SCOPE_BOUNDARIES.md](DOC_SCOPE_BOUNDARIES.md) - Document Scope Boundaries
- [GATES_POLICY.md](GATES_POLICY.md) - Gate Policy
- [GOVERNANCE_SPEC.md](GOVERNANCE_SPEC.md) - Governance Specification
- [CHANGELOG.md](CHANGELOG.md) - Constitution Changelog

