# Coverage Governance

**Document Version:** 1.0  
**Status:** IMMUTABLE  
**Created Date:** 2026-01-27  
**Scope:** PR#1 - Coverage governance rules (principles only; no implementation)

---

## Constitutional Status

This document defines IMMUTABLE constitutional rules for Coverage as a system primitive. These rules are non-negotiable and override all other considerations including implementation convenience, business requirements, product goals, performance optimization, user experience improvements, deadlines, and emergency situations.

**PR1 is the LAST line of defense for Coverage integrity. PR1 cannot fail.**

---

## Core Principles

### PRINCIPLE-001: Coverage as Non-Negotiable System Fact

Coverage is a factual system primitive. Coverage is NOT:
- An adjustable metric
- A negotiable parameter
- A compromise constraint
- A reinterpretable semantic
- An overridable computation result
- A business KPI
- A completion indicator
- A quality proxy
- A UX affordance

Coverage IS:
- A system fact based on spatial evidence
- A constitutional-level primitive
- An immutable truth once computed
- A single-source value produced exclusively by CoverageEstimator
- Independent of product goals, business objectives, or user preferences

**Governance Priority Declaration:**
- Coverage governance rules override ALL product goals
- Coverage governance rules override ALL business requirements
- Coverage governance rules override ALL implementation convenience
- Coverage governance rules override ALL performance optimization
- Coverage governance rules override ALL user experience improvements
- Coverage governance rules override ALL deadlines
- Coverage governance rules override ALL emergency situations

**There are NO exceptions.**

### PRINCIPLE-002: PR1 as Last Line of Defense

PR1 is the LAST line of defense for Coverage integrity. PR1 cannot fail.

PR1 is the only opportunity to define Coverage governance rules. Once PR1 is merged:
- Rules become IMMUTABLE constitution
- Subsequent PRs can only comply, cannot weaken
- Any attempt to weaken rules MUST be rejected
- Rule changes MUST go through RFC and MUST NOT weaken existing rules

**Last Line of Defense Responsibility:**
- PR1 MUST define rules strict and complete enough
- PR1 MUST assume worst-case misuse and pressure
- PR1 MUST defensively design all rules
- PR1 MUST explicitly prohibit all known and potential misuse patterns

### PRINCIPLE-003: No Convenience Exceptions

The following reasons are NEVER valid justification for violating Coverage governance rules:
- "Implementation is more convenient"
- "Performance is better"
- "User experience is better"
- "Business requirement is urgent"
- "Just a temporary solution"
- "Will fix later"
- "Impact scope is small"
- "Only internal use"
- "Documentation will explain"
- "Tests will cover"
- "CI is flaky"
- "Tests are failing"
- "Platform is different"
- "Just this once"
- "Emergency situation"
- "Time pressure"
- "Deadline approaching"

**Prohibited Exception Patterns:**
- "Special case" exceptions
- "Just this once" exceptions
- "Emergency fix" exceptions
- "Backward compatibility" exceptions (if violating rules)
- "Gradual improvement" exceptions (if violating rules)
- "Temporary" exceptions
- "Phased" relaxations
- "Platform-specific" exceptions

**Only Allowed Changes:**
- Formal rule changes through RFC process
- Explicitly documented rule evolution (without weakening existing rules)
- Adding new defensive rules

### PRINCIPLE-004: Non-Regression Principle

Once Coverage governance rules are defined and merged in PR1:
- Rule strength MUST NOT decrease (subsequent PRs MUST NOT weaken any rules)
- Rule scope MUST NOT shrink (subsequent PRs MUST NOT shrink rule protection scope)
- Rule enforcement MUST NOT relax (subsequent PRs MUST NOT lower rule enforcement standards)
- Rule exceptions MUST NOT increase (subsequent PRs MUST NOT add new exceptions)
- Rule priority MUST NOT decrease (subsequent PRs MUST NOT lower rule priority)

**Rules can only be strengthened, never weakened.**

### PRINCIPLE-005: Worst-Case Interpretation Principle

When rules have any ambiguity, vagueness, or interpretation space:
- Choose the strictest interpretation
- Assume hostile intent
- Assume pressure environment
- Assume long-term maintenance
- Assume multiple contributors

**Interpretation Priority (strictest to most lenient):**
1. Strictest interpretation: Maximize rule protection scope
2. Defensive interpretation: Assume misuse and abuse
3. Explicitness interpretation: Eliminate all ambiguity
4. Consistency interpretation: Maintain consistency with other rules
5. Convenience interpretation: **NEVER USE**

### PRINCIPLE-006: Governance Threat Model

Coverage governance rules MUST defend against the following threats:

**Internal Threats:**
- T-001: Engineer convenience pressure
- T-002: Product manager business pressure
- T-003: QA quality pressure
- T-004: Architect optimization pressure
- T-005: Maintainer understanding deviation

**External Threats:**
- T-006: Business pressure
- T-007: Time pressure
- T-008: Technical debt accumulation

**Systemic Threats:**
- T-009: Rule drift
- T-010: Exception accumulation
- T-011: Interpretation relaxation

**Test and CI Threats:**
- T-012: Test failure pressure
- T-013: CI flakiness pressure
- T-014: Platform divergence pressure

All threats MUST be explicitly addressed in governance rules. Threat mitigation MUST be enforced.

### PRINCIPLE-007: Plan/Docs as Governed Artifacts

This governance document and the plan document are governed artifacts:
- Document changes MUST go through review
- Documents MUST maintain completeness and consistency
- Documents MUST NOT weaken Coverage governance rules
- Documents MUST explicitly document all constraints
- Documents MUST be defensively designed
- Documents MUST assume hostile conditions

### PRINCIPLE-008: Plan-to-Execution Assertion Gates

Before proceeding from planning phase to execution phase, the following assertion gates MUST pass:
- GATE-001: Core principles assertion
- GATE-002: Threat model assertion
- GATE-003: Non-regression principle assertion
- GATE-004: Worst-case interpretation assertion
- GATE-005: Prohibition of exceptions assertion
- GATE-006: Plan completeness assertion
- GATE-007: Execution boundary assertion
- GATE-008: Author confirmation assertion

All gates MUST pass. Any gate failure MUST block execution.

### PRINCIPLE-009: Future Compatibility Without Pre-Implementation

PR1 defines Coverage governance rules:
- MUST consider future extension possibilities
- MUST define rule evolution mechanisms
- MUST maintain rule extensibility
- MUST NOT pre-implement future features
- MUST NOT assume future implementation details
- MUST NOT reserve exceptions for future features

### PRINCIPLE-010: Citation-by-ID Requirement

Any future PR, design document, issue report, or code comment referencing Coverage governance rules:
- MUST use stable rule IDs (e.g., COVERAGE_OWNERSHIP_001, DEPENDENCY_DIRECTION_001)
- MUST NOT use only paraphrases or descriptive text
- MUST NOT use vague references like "related rules" or "governance requirements"

Citations without rule IDs MUST be rejected in code review.

### PRINCIPLE-011: Terminology Closed-Set Requirement

Coverage governance document MUST include a "Terminology (Closed Set)" section defining canonical meanings for key terms.

All key terms MUST have explicit canonical definitions. Terminology definitions form a closed set. Undefined terms are prohibited. New terms require RFC approval.

---

## Violation Severity Levels

Violations of Coverage governance rules are classified into severity levels:

**SEV-0 (Constitutional Violation):**
- Violation of core constitutional rules (ownership, dependency, scope, versioning)
- Impact: System architecture destruction, Coverage integrity compromised
- Handling: Immediately reject PR, MUST fix
- Examples: CoverageEstimator depends on StateMachine, Coverage value modified

**SEV-1 (Governance Violation):**
- Violation of governance mechanism rules (enforcement, testing, documentation)
- Impact: Governance failure, rules cannot be enforced
- Handling: Reject PR, MUST fix
- Examples: Missing required tests, missing audit records

**SEV-2 (Quality Violation):**
- Violation of quality requirement rules (documentation, format)
- Impact: Documentation quality degradation, maintainability reduction
- Handling: Require fix, negotiable timing
- Examples: Documentation format inconsistency, terminology usage inconsistency

**SEV-3 (Minor Issue):**
- Violation of auxiliary rules or best practices
- Impact: Minor quality degradation
- Handling: Suggest fix, non-blocking
- Examples: Minor terminology inconsistency

**Severity Mapping:**
- Core rules (ownership, dependency, scope, versioning): SEV-0
- Governance mechanism rules (enforcement, testing, documentation): SEV-1
- Quality rules (documentation, format): SEV-2
- Auxiliary rules: SEV-3

---

## Rule 1: Coverage Ownership (COVERAGE_OWNERSHIP_001)

**Rule ID:** COVERAGE_OWNERSHIP_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Ownership Declaration

Coverage definition, computation, and interpretation are exclusively owned by CoverageEstimator. No other module may modify, clamp, reinterpret, or override Coverage values.

### Allowed Read-Only Access

The following modules MAY read Coverage values:
- StateMachine (for state transition decisions)
- UX layer (for display only, MUST NOT modify)
- Pipeline (for flow control, MUST NOT modify)
- QA systems (for validation, MUST NOT modify)
- Audit systems (for recording, MUST NOT modify)

### Prohibited Operations

The following operations are EXPLICITLY FORBIDDEN:
- **Modification**: MUST NOT modify Coverage values
- **Clamping**: MUST NOT clamp Coverage values to any range
- **Reinterpretation**: MUST NOT reinterpret Coverage semantics
- **Override**: MUST NOT override CoverageEstimator results
- **Post-processing**: MUST NOT post-process Coverage values for business needs
- **Adjustment**: MUST NOT adjust Coverage values for UX metrics
- **Normalization**: MUST NOT renormalize Coverage values
- **Scaling**: MUST NOT scale Coverage values
- **Offset**: MUST NOT add offsets to Coverage values
- **Smoothing**: MUST NOT smooth Coverage values
- **Thresholding**: MUST NOT convert Coverage to binary values
- **Quantization**: MUST NOT quantize Coverage values (except for display, with original preserved)

### Enforcement Requirement

Any code attempting to modify, clamp, reinterpret, or override Coverage values MUST be rejected by CI and code review.

---

## Rule 2: Dependency Direction (DEPENDENCY_DIRECTION_001)

**Rule ID:** DEPENDENCY_DIRECTION_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Unidirectional Dependency Rule

Dependency direction is STRICTLY unidirectional.

**Allowed Dependencies:**
- StateMachine MAY read Coverage
- UX layer MAY read Coverage
- Pipeline MAY read Coverage
- QA systems MAY read Coverage
- Audit systems MAY read Coverage

**Prohibited Dependencies:**
- CoverageEstimator MUST NOT read StateMachine
- CoverageEstimator MUST NOT read Pipeline state
- CoverageEstimator MUST NOT read business rules
- CoverageEstimator MUST NOT read user preferences
- CoverageEstimator MUST NOT read system configuration (except Coverage computation input parameters)
- CoverageEstimator MUST NOT read platform-specific information
- CoverageEstimator MUST NOT read device identifiers
- CoverageEstimator MUST NOT read session identifiers
- CoverageEstimator MUST NOT read timestamps (except spatial evidence timestamps)

### Constitutionally Invalid Designs

Any design making Coverage values dependent on the following is constitutionally invalid:
- System state (StateMachine state)
- Business process state
- User operation history
- Timestamps or session duration
- Device type or platform characteristics
- Business rules or policies
- Test results or CI status
- Performance metrics
- UX metrics

### Platform Independence Requirement

Coverage rules MUST be platform-independent at the semantic level. Platform differences are NEVER valid exceptions.

**Prohibited Platform-Specific Shortcuts:**
- MUST NOT create iOS-specific Coverage computation
- MUST NOT create Linux-specific Coverage computation
- MUST NOT create macOS-specific Coverage computation
- MUST NOT create CI-specific Coverage computation
- MUST NOT use platform-specific optimizations that affect Coverage semantics
- MUST NOT justify platform differences as exceptions to rules

**Platform Consistency Requirement:**
- iOS, Linux, macOS, and CI environments MUST produce identical Coverage values (within tolerance)
- Platform differences MUST NOT affect Coverage computation semantics
- Platform-specific performance optimizations MUST maintain semantic consistency

### Enforcement Requirement

Code review and CI MUST detect and reject any design making CoverageEstimator dependent on StateMachine, platform-specific information, or any prohibited input.

---

## Rule 3: Freeze Semantics (FREEZE_SEMANTICS_001)

**Rule ID:** FREEZE_SEMANTICS_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Freeze Definition

Coverage values may be frozen for asset integrity protection, audit record immutability, or chain verification requirements.

### Freeze Decision Level

Freeze is a SYSTEM-LEVEL decision, NOT CoverageEstimator's responsibility.

### CoverageEstimator Constraints

CoverageEstimator MUST:
- Remain stateless (no session state or historical state)
- Remain unaware of freeze (MUST NOT receive, query, or depend on freeze status)
- NOT implement freeze logic (freeze logic MUST be implemented outside CoverageEstimator)

### Prohibited Operations

CoverageEstimator MUST NOT:
- Check if assets are frozen
- Adjust computation based on freeze status
- Maintain freeze history records
- Implement any form of freeze mechanism

### Freeze Implementation Location

Freeze logic MUST be implemented outside CoverageEstimator:
- Asset management systems
- Audit record systems
- Chain verification systems

### Enforcement Requirement

Any code implementing freeze logic inside CoverageEstimator MUST be rejected.

---

## Rule 4: Specification Versioning (SPEC_VERSIONING_001)

**Rule ID:** SPEC_VERSIONING_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Versioning Principle

Coverage semantics are governed by CoverageSpecVersion. CoverageSpecVersion is a specification version, NOT a code version.

### Audit Record Requirements

All audit records MUST:
- Store CoverageSpecVersion (each Coverage value MUST be accompanied by its CoverageSpecVersion)
- Store Coverage value (original Coverage value MUST be recorded)
- Store timestamp (record generation timestamp)

### Prohibited Versioning Methods

The following methods are EXPLICITLY FORBIDDEN for reinterpreting historical Coverage:
- Code version numbers (MUST NOT use code version to infer Coverage semantics)
- Implementation details (MUST NOT reinterpret Coverage based on implementation details)
- Algorithm versions (MUST NOT use algorithm version to change Coverage meaning)
- Library versions (MUST NOT use dependency library versions to infer Coverage semantics)

### Historical Coverage Interpretation Rules

Historical Coverage values MUST:
- Be interpreted using CoverageSpecVersion recorded at computation time
- NOT be recomputed using current code version
- NOT be reinterpreted using current algorithm semantics

### Version Migration Rules

If CoverageSpecVersion changes:
- New version MUST explicitly define differences from old version
- Historical records MUST retain original CoverageSpecVersion
- Historical records' CoverageSpecVersion MUST NOT be modified

### Enforcement Requirement

Audit systems MUST verify each Coverage record contains CoverageSpecVersion. Records missing CoverageSpecVersion are invalid.

---

## Rule 5: Scope Limitation (SCOPE_LIMITATION_001)

**Rule ID:** SCOPE_LIMITATION_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Coverage Definition Scope

Coverage measures ONLY **spatial evidence sufficiency**.

Coverage represents:
- Proportion of theoretical target area covered by evidence
- Sufficiency of spatial sampling points
- Spatial evidence completeness for geometric reconstruction

### Explicitly Excluded Scope

Coverage does NOT represent:
- Visual quality (Coverage does NOT measure visual fidelity or image quality)
- Aesthetic completeness (Coverage does NOT assess aesthetic value or visual appeal)
- Texture fidelity (Coverage does NOT measure texture detail or texture quality)
- Final model quality (Coverage does NOT predict final 3D model quality)
- User satisfaction (Coverage does NOT reflect user satisfaction with results)
- Business value (Coverage does NOT represent asset business value or market value)
- Completion (Coverage is NOT a project completion indicator)
- Quality metrics (Coverage is NOT a quality metric)

### Misuse Detection

The following usage patterns are Coverage misuse:
- Using Coverage as visual quality indicator
- Using Coverage as user satisfaction indicator
- Using Coverage as business KPI
- Using Coverage to predict final model quality
- Using Coverage to assess texture fidelity
- Using Coverage as completion indicator

### Enforcement Requirement

Documentation, code comments, and API documentation MUST explicitly state Coverage scope limitations. Any use of Coverage outside its defined scope MUST be rejected.

---

## Rule 6: Immutability (IMMUTABILITY_001)

**Rule ID:** IMMUTABILITY_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Post-Computation Immutability

Once Coverage value is computed by CoverageEstimator, it MUST NOT be modified by any other module.

### Prohibited Modification Operations

The following operations are EXPLICITLY FORBIDDEN:
- Post-processing (MUST NOT post-process Coverage values)
- Normalization (MUST NOT renormalize Coverage values)
- Scaling (MUST NOT scale Coverage values)
- Offset (MUST NOT add offsets to Coverage values)
- Smoothing (MUST NOT smooth Coverage values)
- Thresholding (MUST NOT convert Coverage to binary values)
- Quantization (MUST NOT quantize Coverage values, except for display with original preserved)

### Display Layer Exception

Display layer (UX) MAY:
- Format Coverage values for display (e.g., percentage formatting)
- Map Coverage values to visualizations (e.g., color mapping)
- Apply display-related transformations (e.g., logarithmic scaling for visualization)

BUT MUST satisfy:
- Original Coverage value MUST be preserved
- Display transformations MUST NOT affect stored Coverage values
- Display transformations MUST be reversible (for debugging)

### Enforcement Requirement

Any code modifying CoverageEstimator output MUST be rejected. Display layer transformations MUST be explicitly marked as display-only and MUST NOT affect stored values.

---

## Rule 7: Single Source Principle (SINGLE_SOURCE_001)

**Rule ID:** SINGLE_SOURCE_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Single Computation Source

Coverage values MUST be computed by CoverageEstimator as the SINGLE source. Multiple Coverage computation implementations are FORBIDDEN.

### Prohibited Behaviors

The following behaviors are EXPLICITLY FORBIDDEN:
- Multiple implementations (MUST NOT have multiple Coverage computation implementations)
- Fallback implementations (MUST NOT have fallback or degraded Coverage implementations)
- Platform-specific implementations (MUST NOT have platform-specific Coverage computation, unless performance optimization with identical semantics)
- Version-specific implementations (MUST NOT have different versions of Coverage computation coexisting)

### Platform Consistency Requirement

If platform-specific performance optimizations exist:
- Semantics MUST be completely identical
- Cross-platform results MUST be within tolerance (see CROSS_PLATFORM_CONSISTENCY.md)
- MUST pass cross-platform consistency tests

### Enforcement Requirement

CI MUST verify only one Coverage computation implementation exists. Multiple implementations MUST be rejected.

---

## Rule 8: Input Boundary (INPUT_BOUNDARY_001)

**Rule ID:** INPUT_BOUNDARY_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Allowed Inputs

CoverageEstimator MAY receive ONLY the following inputs:
- Spatial evidence data (patch data, viewpoint data, geometric data)
- Computation parameters (Coverage computation parameters, e.g., thresholds, precision)
- Specification version (CoverageSpecVersion for selecting computation rules)

### Prohibited Inputs

CoverageEstimator MUST NOT receive:
- System state (StateMachine state, Pipeline state)
- Business rules (business policies, business thresholds)
- User preferences (user settings, user preferences)
- Historical data (session history, user history, unless part of spatial evidence)
- Time information (timestamps, session duration, unless spatial evidence timestamps)
- Device information (device type, platform characteristics, unless affecting spatial evidence quality)
- Freeze status (asset freeze status, audit freeze status)
- Test results (test outcomes, test status)
- CI status (CI build status, CI test results)
- Platform-specific information (platform identifiers, platform capabilities)

### Input Validation Requirement

CoverageEstimator MUST:
- Validate inputs contain only allowed types
- Reject requests containing prohibited inputs
- Record input validation failures

### Enforcement Requirement

Code review MUST verify CoverageEstimator input interface. Interfaces containing prohibited inputs MUST be rejected.

---

## Rule 9: Output Boundary (OUTPUT_BOUNDARY_001)

**Rule ID:** OUTPUT_BOUNDARY_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Required Outputs

CoverageEstimator MUST output:
- Coverage value (Double type, range [0, 1])
- CoverageSpecVersion (specification version for interpreting Coverage value)
- Computation metadata (computation timestamp, input digest for audit)

### Prohibited Outputs

CoverageEstimator MUST NOT output:
- State suggestions (MUST NOT suggest system states)
- Business suggestions (MUST NOT suggest business decisions)
- UX suggestions (MUST NOT suggest UX behaviors)
- Quality assessments (MUST NOT output quality assessments; Coverage is NOT a quality metric)
- Completion assessments (MUST NOT output completion assessments)

### Output Format Requirement

CoverageEstimator output MUST:
- Contain only Coverage values and metadata
- NOT contain explanatory text (explanations provided by USER_EXPLANATION_CATALOG)
- NOT contain suggestions or recommendations

### Enforcement Requirement

Code review MUST verify CoverageEstimator output interface. Interfaces containing prohibited outputs MUST be rejected.

---

## Rule 10: Statelessness (STATELESSNESS_001)

**Rule ID:** STATELESSNESS_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Stateless Requirement

CoverageEstimator MUST be COMPLETELY stateless.

### Prohibited State

CoverageEstimator MUST NOT maintain:
- Session state (MUST NOT maintain session-level state)
- Historical state (MUST NOT maintain historical Coverage values)
- Accumulated state (MUST NOT accumulate any form of statistics)
- Cache state (MUST NOT cache computation results, unless performance optimization with no semantic impact)
- Configuration state (MUST NOT maintain runtime configuration state)

### Allowed Temporary State

Only the following temporary state is allowed (during computation):
- Computation intermediate results (temporary variables during computation)
- Performance cache (pure function result cache with no semantic impact)

### State Check Requirement

Each Coverage computation MUST be:
- Independent (MUST NOT depend on previous computations)
- Reproducible (same input MUST produce same output)
- Side-effect-free (MUST NOT modify any external state)

### Enforcement Requirement

Code review MUST verify CoverageEstimator statelessness. Any state maintenance MUST be rejected.

---

## Rule 11: Determinism Requirement (DETERMINISM_001)

**Rule ID:** DETERMINISM_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Determinism Principle

Coverage computation MUST be COMPLETELY deterministic.

### Determinism Requirements

Given identical inputs:
- MUST produce identical output (Coverage values MUST be completely consistent)
- MUST be cross-platform consistent (iOS, Android, Server MUST produce identical results within tolerance)
- MUST be cross-time consistent (today's and tomorrow's computation results MUST be consistent)
- MUST be cross-session consistent (different sessions' computation results MUST be consistent)

### Prohibited Non-Deterministic Sources

The following non-deterministic sources are EXPLICITLY FORBIDDEN:
- Random numbers (MUST NOT use random numbers, except for testing)
- Timestamps (MUST NOT use timestamps to affect computation)
- Device IDs (MUST NOT use device identifiers)
- Session IDs (MUST NOT use session identifiers)
- Platform characteristics (MUST NOT depend on platform-specific behaviors, unless performance optimization with identical semantics)

### Tolerance Requirement

Cross-platform consistency tolerance:
- Relative error ≤ 1e-4 (see CROSS_PLATFORM_CONSISTENCY.md)

### Enforcement Requirement

CI MUST include determinism tests. Any non-deterministic behavior MUST be rejected.

---

## Rule 12: Audit Requirement (AUDIT_REQUIREMENT_001)

**Rule ID:** AUDIT_REQUIREMENT_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-1 (Governance Violation)

### Audit Record Requirement

Each Coverage computation MUST generate an audit record.

### Required Audit Fields

Audit records MUST contain:
- Coverage value (computed Coverage value)
- CoverageSpecVersion (specification version used)
- Input digest (digest of input data for reproduction)
- Computation timestamp (time when computation occurred)
- Computation ID (unique identifier for this computation)

### Audit Record Immutability

Once audit records are created:
- MUST NOT be modified (MUST NOT modify created audit records)
- MUST NOT be deleted (MUST NOT delete audit records)
- MUST be permanently stored (audit records MUST be permanently stored)

### Audit Record Access

Audit records MUST:
- Be queryable (support querying by time, asset, session)
- Be verifiable (support verifying Coverage value correctness)
- Be reproducible (support reproducing Coverage computation)

### Enforcement Requirement

Audit systems MUST verify each Coverage computation has corresponding audit record. Computations missing audit records are invalid.

---

## Rule 13: Misuse Prevention (MISUSE_PREVENTION_001)

**Rule ID:** MISUSE_PREVENTION_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Common Misuse Patterns

The following patterns are Coverage misuse and MUST be prevented:

#### Misuse 1: Business KPI Usage
- **Prohibited**: Using Coverage as business completion KPI
- **Reason**: Coverage is NOT a completion indicator
- **Detection**: Code review MUST reject code using Coverage for business KPIs

#### Misuse 2: Quality Proxy
- **Prohibited**: Using Coverage as visual quality or model quality proxy
- **Reason**: Coverage does NOT measure quality
- **Detection**: Documentation and code MUST explicitly state Coverage is NOT a quality metric

#### Misuse 3: State Dependency
- **Prohibited**: Making Coverage dependent on system state
- **Reason**: Violates dependency direction rule
- **Detection**: CI MUST detect CoverageEstimator dependency on StateMachine

#### Misuse 4: Post-Processing Modification
- **Prohibited**: Post-processing Coverage values
- **Reason**: Violates immutability rule
- **Detection**: Code review MUST reject code modifying Coverage values

#### Misuse 5: Scope Extension
- **Prohibited**: Using Coverage outside its defined scope
- **Reason**: Violates scope limitation rule
- **Detection**: Documentation review MUST verify Coverage usage conforms to defined scope

### Prevention Measures

The following prevention measures MUST be implemented:
- Code review checklist (MUST include Coverage misuse check items)
- CI automation checks (MUST include Coverage misuse detection)
- Explicit documentation (MUST explicitly state Coverage scope and limitations)
- Training requirements (all developers MUST understand Coverage governance rules)

### Enforcement Requirement

Code review and CI MUST include Coverage misuse detection. Any misuse MUST be rejected.

---

## Rule 14: Version Compatibility (VERSION_COMPATIBILITY_001)

**Rule ID:** VERSION_COMPATIBILITY_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Version Compatibility Requirements

CoverageSpecVersion changes MUST:
- Be backward compatible (new version MUST be able to read old version Coverage values)
- Be forward compatible (old version MUST be able to identify, though not necessarily understand, new version Coverage values)
- Provide migration path (MUST provide explicit migration path)

### Prohibited Changes

The following changes are EXPLICITLY FORBIDDEN:
- Semantic breaking changes (MUST NOT change Coverage semantics, unless major version)
- Scope breaking changes (MUST NOT change Coverage scope definition)
- Value domain breaking changes (MUST NOT change Coverage value domain [0, 1])

### Allowed Changes

The following changes are allowed (require major version):
- Algorithm improvements (improve Coverage computation algorithm with consistent semantics)
- Precision improvements (improve Coverage computation precision with consistent value domain)
- Performance optimizations (optimize Coverage computation performance with consistent results)

### Version Migration Rules

Version migration MUST:
- Be explicitly documented (MUST document differences between versions)
- Provide migration tools (MUST provide migration tools if needed)
- Preserve audit records (MUST preserve original CoverageSpecVersion in audit records)

### Enforcement Requirement

Version changes MUST go through RFC process. Breaking changes MUST be explicitly marked and documented.

---

## Rule 15: Test Requirement (TEST_REQUIREMENT_001)

**Rule ID:** TEST_REQUIREMENT_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-1 (Governance Violation)

### Required Tests

CoverageEstimator MUST include the following tests:

#### Test 1: Ownership Test
- **Purpose**: Verify Coverage ownership rule
- **Requirement**: Verify other modules cannot modify Coverage values

#### Test 2: Dependency Direction Test
- **Purpose**: Verify dependency direction rule
- **Requirement**: Verify CoverageEstimator does not depend on StateMachine

#### Test 3: Statelessness Test
- **Purpose**: Verify statelessness
- **Requirement**: Verify CoverageEstimator maintains no state

#### Test 4: Determinism Test
- **Purpose**: Verify determinism
- **Requirement**: Verify identical inputs produce identical outputs

#### Test 5: Cross-Platform Consistency Test
- **Purpose**: Verify cross-platform consistency
- **Requirement**: Verify iOS, Android, Server produce consistent results

#### Test 6: Scope Limitation Test
- **Purpose**: Verify scope limitation
- **Requirement**: Verify Coverage does not measure quality or other non-spatial-evidence metrics

#### Test 7: Input Boundary Test
- **Purpose**: Verify input boundary
- **Requirement**: Verify CoverageEstimator rejects prohibited inputs

#### Test 8: Output Boundary Test
- **Purpose**: Verify output boundary
- **Requirement**: Verify CoverageEstimator does not output prohibited content

### Test Coverage Requirements

Test coverage MUST:
- Be ≥ 90% (CoverageEstimator code coverage MUST be ≥ 90%)
- Cover all rules (all governance rules MUST have corresponding tests)
- Include edge cases (MUST include edge cases and error cases)

### Test Failure Handling

**Test failure is NEVER justification for relaxing rules.**

The following are EXPLICITLY FORBIDDEN:
- Relaxing rules to make tests pass
- Adding exceptions to rules to fix test failures
- Modifying rules to accommodate test failures
- Using test failures as justification for rule violations
- "Make tests pass first, fix rules later" logic

**Test failure handling:**
- Fix tests to conform to rules
- Fix implementation to conform to rules
- Fix test infrastructure to properly validate rules
- NEVER relax rules

### Enforcement Requirement

CI MUST run all required tests. Any test failure MUST block merge. Test failures MUST be resolved by fixing tests or implementation, NEVER by relaxing rules.

---

## Rule 16: Documentation Requirement (DOCUMENTATION_REQUIREMENT_001)

**Rule ID:** DOCUMENTATION_REQUIREMENT_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-2 (Quality Violation)

### Required Documentation

The following documentation MUST exist and remain current:

#### Document 1: Coverage Definition Document
- **Content**: Clear definition of Coverage
- **Requirement**: MUST explicitly state what Coverage measures and what it does NOT measure

#### Document 2: Coverage Scope Document
- **Content**: Coverage scope limitations
- **Requirement**: MUST explicitly list what Coverage does NOT represent

#### Document 3: Coverage Usage Guide
- **Content**: How to correctly use Coverage
- **Requirement**: MUST include correct usage examples and misuse examples

#### Document 4: Coverage Governance Rules Document
- **Content**: This document
- **Requirement**: MUST remain current and reflect all governance rules

### Documentation Quality Requirements

Documentation MUST:
- Be clear (language clear, unambiguous)
- Be complete (cover all governance rules)
- Be accessible (easy to find and understand)
- Be maintainable (easy to update)

### Enforcement Requirement

Documentation review MUST verify documentation completeness and accuracy. Incomplete documentation MUST be rejected.

---

## Rule 17: Change Control (CHANGE_CONTROL_001)

**Rule ID:** CHANGE_CONTROL_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-1 (Governance Violation)

### Change Control Requirements

Any change to Coverage governance rules MUST:
- Go through RFC process (MUST submit RFC and undergo review)
- Be explicitly documented (MUST explicitly document change content and reason)
- Be versioned (MUST update document version number)
- Consider backward compatibility (MUST consider backward compatibility)

### Prohibited Changes

The following changes are FORBIDDEN:
- Weakening rules (MUST NOT weaken any governance rules)
- Removing rules (MUST NOT remove any governance rules, unless error correction)
- Blurring rules (MUST NOT make rules ambiguous or unenforceable)

### Non-Regression Principle

**Rules can only be strengthened, never weakened.**

Once Coverage governance rules are defined and merged in PR1:
- Rule strength MUST NOT decrease (subsequent PRs MUST NOT weaken any rules)
- Rule scope MUST NOT shrink (subsequent PRs MUST NOT shrink rule protection scope)
- Rule enforcement MUST NOT relax (subsequent PRs MUST NOT lower rule enforcement standards)
- Rule exceptions MUST NOT increase (subsequent PRs MUST NOT add new exceptions)
- Rule priority MUST NOT decrease (subsequent PRs MUST NOT lower rule priority)

### Allowed Changes

The following changes are allowed:
- Clarifying rules (clarify rule wording without changing meaning)
- Adding rules (add new governance rules)
- Correcting errors (correct errors in documentation)
- Strengthening rules (strengthen existing rules)

### Change Review Requirements

Change review MUST:
- Verify necessity (verify change necessity)
- Verify impact (assess change impact)
- Verify compatibility (verify backward compatibility)
- Obtain approval (obtain necessary approval)
- Verify non-regression (verify rules are not weakened)

### Enforcement Requirement

All changes MUST go through RFC process. Changes without RFC MUST be rejected. Changes weakening rules MUST be rejected.

---

## Rule 18: Enforcement Mechanism (ENFORCEMENT_001)

**Rule ID:** ENFORCEMENT_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-1 (Governance Violation)

### Enforcement Levels

Coverage governance rules MUST be enforced at the following levels:

#### Level 1: Code Review
- **Requirement**: Code review MUST check Coverage governance rule compliance
- **Checklist**: MUST use Coverage governance rule checklist

#### Level 2: CI Automation
- **Requirement**: CI MUST include Coverage governance rule automation checks
- **Check items**: MUST check ownership, dependency direction, statelessness, determinism, etc.

#### Level 3: Test Verification
- **Requirement**: Tests MUST verify Coverage governance rules
- **Coverage**: MUST cover all governance rules

#### Level 4: Documentation Review
- **Requirement**: Documentation review MUST verify Coverage usage conforms to governance rules
- **Check items**: MUST check Coverage usage in documentation conforms to rules

### CI Instability Handling

**CI instability is NEVER justification for bypassing governance.**

The following are EXPLICITLY FORBIDDEN:
- Bypassing governance checks due to CI flakiness
- Disabling governance checks due to CI instability
- Using CI instability as justification for rule violations
- "CI is flaky, skip governance checks" logic
- Temporary disabling of governance checks

**CI green ≠ governance correctness.**

A green CI status does NOT indicate governance correctness. CI may be:
- Flaky (passing incorrectly)
- Incomplete (missing checks)
- Misconfigured (incorrect checks)
- Bypassed (checks disabled)

**Governance correctness MUST be verified independently of CI status.**

### Enforcement Failure Handling

Enforcement failures MUST:
- Block merge (any rule violation MUST block PR merge)
- Record violation (MUST record violation details)
- Require fix (MUST require violation fix)

### Enforcement Requirement

All enforcement mechanisms MUST be in place and running. Missing enforcement mechanisms MUST be treated as blocking issues.

---

## Rule 19: Platform Independence (PLATFORM_INDEPENDENCE_001)

**Rule ID:** PLATFORM_INDEPENDENCE_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Platform Independence Principle

Coverage rules MUST be platform-independent at the semantic level. Platform differences are NEVER valid exceptions.

### Assumed Platform Divergence

**iOS, Linux, macOS, and CI environments WILL diverge unless explicitly constrained.**

The system MUST assume:
- Platforms will diverge in behavior unless explicitly constrained
- Platform-specific optimizations will affect semantics unless prevented
- Platform differences will be used as excuses for rule violations unless prohibited
- CI environments will differ from production unless constrained

### Platform Consistency Requirements

Coverage computation MUST:
- Produce identical results across iOS, Linux, macOS, and CI (within tolerance)
- Maintain identical semantics across all platforms
- Enforce identical rules across all platforms
- Reject platform-specific exceptions

### Prohibited Platform-Specific Shortcuts

The following are EXPLICITLY FORBIDDEN:
- iOS-specific Coverage computation shortcuts
- Linux-specific Coverage computation shortcuts
- macOS-specific Coverage computation shortcuts
- CI-specific Coverage computation shortcuts
- Platform-specific rule exceptions
- Platform differences as justification for rule violations
- "This platform is different" excuses

### Platform-Specific Optimization Constraints

If platform-specific performance optimizations exist:
- Semantics MUST be completely identical
- Results MUST be within cross-platform tolerance
- Rules MUST be identically enforced
- Exceptions MUST NOT be platform-specific

### Enforcement Requirement

CI MUST verify platform consistency. Platform-specific rule violations MUST be rejected.

---

## Rule 20: Threat Model (THREAT_MODEL_001)

**Rule ID:** THREAT_MODEL_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-1 (Governance Violation)

### Threat Model Overview

Coverage governance rules MUST defend against the following threats:

### Internal Threats

#### Threat T-001: Engineer Convenience Pressure
- **Scenario**: Engineers violate rules to simplify implementation
- **Manifestation**: "This exception won't affect the system"
- **Defense**: Prohibit all convenience exceptions (explicitly forbidden)

#### Threat T-002: Product Manager Business Pressure
- **Scenario**: Product managers demand using Coverage as business KPI
- **Manifestation**: "We need Coverage to show completion"
- **Defense**: Explicitly state Coverage is NOT a business KPI

#### Threat T-003: QA Quality Pressure
- **Scenario**: QA attempts to "correct" Coverage values to match expectations
- **Manifestation**: "This Coverage value is wrong, it should be higher"
- **Defense**: Prohibit Coverage value modification

#### Threat T-004: Architect Optimization Pressure
- **Scenario**: Architects violate dependency rules for performance optimization
- **Manifestation**: "Letting CoverageEstimator read state would be more efficient"
- **Defense**: Strict unidirectional dependency

#### Threat T-005: Maintainer Understanding Deviation
- **Scenario**: New maintainers misunderstand rules and introduce violations
- **Manifestation**: "I thought this rule didn't apply to this case"
- **Defense**: Worst-case interpretation rules, explicit prohibition lists

### External Threats

#### Threat T-006: Business Pressure
- **Scenario**: Business requirements conflict with rules
- **Manifestation**: "This feature must ship, rules can be adjusted later"
- **Defense**: Governance overrides business goals

#### Threat T-007: Time Pressure
- **Scenario**: Urgent releases cause rule bypassing
- **Manifestation**: "This is an emergency fix, rule checks can be skipped"
- **Defense**: Prohibit all exceptions, including emergency exceptions

#### Threat T-008: Technical Debt Accumulation
- **Scenario**: Technical debt makes rule enforcement difficult
- **Manifestation**: "Existing code violates rules, new code is allowed to violate too"
- **Defense**: Non-regression principle, rule strength protection

### Systemic Threats

#### Threat T-009: Rule Drift
- **Scenario**: Rules gradually weakened in practice
- **Manifestation**: "This rule is too strict, we don't actually need it"
- **Defense**: Non-regression principle, rule strength protection

#### Threat T-010: Exception Accumulation
- **Scenario**: Exceptions gradually accumulate, rules become ineffective
- **Manifestation**: "This exception already exists, one more doesn't matter"
- **Defense**: Prohibit all exceptions

#### Threat T-011: Interpretation Relaxation
- **Scenario**: Rule interpretation gradually relaxed
- **Manifestation**: "This rule can be interpreted this way"
- **Defense**: Worst-case interpretation rules

### Test and CI Threats

#### Threat T-012: Test Failure Pressure
- **Scenario**: Tests fail, pressure to relax rules to make tests pass
- **Manifestation**: "Tests are failing, let's relax the rules"
- **Defense**: Test failure is NEVER justification for relaxing rules

#### Threat T-013: CI Flakiness Pressure
- **Scenario**: CI is flaky, pressure to bypass governance checks
- **Manifestation**: "CI is flaky, skip governance checks"
- **Defense**: CI instability is NEVER justification for bypassing governance

#### Threat T-014: Platform Divergence Pressure
- **Scenario**: Platforms diverge, pressure to allow platform-specific exceptions
- **Manifestation**: "iOS is different, allow iOS-specific exception"
- **Defense**: Platform differences are NEVER valid exceptions

### Threat Mitigation Strategies

Mitigation strategies:
- Explicitly prohibit all threat patterns
- Define explicit detection mechanisms
- Define explicit rejection mechanisms
- Define explicit review mechanisms
- Define explicit enforcement mechanisms

### Enforcement Requirement

All threats MUST be explicitly addressed in governance rules. Threat mitigation MUST be enforced.

---

## Rule 21: Worst-Case Interpretation (WORST_CASE_INTERPRETATION_001)

**Rule ID:** WORST_CASE_INTERPRETATION_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-1 (Governance Violation)

### Interpretation Principle

When rules have any ambiguity, vagueness, or interpretation space:
- **Choose the strictest interpretation**
- **Assume hostile intent**
- **Assume pressure environment**
- **Assume long-term maintenance**
- **Assume multiple contributors**

### Interpretation Priority (Strictest to Most Lenient)

1. **Strictest interpretation**: Maximize rule protection scope
2. **Defensive interpretation**: Assume misuse and abuse
3. **Explicitness interpretation**: Eliminate all ambiguity
4. **Consistency interpretation**: Maintain consistency with other rules
5. **Convenience interpretation**: **NEVER USE**

### Ambiguity Handling Rules

**Ambiguity Detection:**
- Any wording allowing two or more interpretations is ambiguous
- Any wording that could be "reasonably" interpreted as allowing violations is ambiguous
- Any wording that could be exploited by "special cases" is ambiguous

**Ambiguity Handling:**
- Immediately clarify ambiguity using strictest interpretation
- Explicitly prohibit all possible misuse patterns
- Add explicit prohibition lists

### Boundary Case Handling

**Boundary Case Definition:**
- Ambiguous areas near rule boundaries
- Cases that might be considered "exceptions"
- Cases that might be considered "special circumstances"

**Boundary Case Handling:**
- Explicitly state boundary cases do NOT constitute exceptions
- Explicitly prohibit special handling of boundary cases
- Explicitly require boundary cases follow strictest rules

### Enforcement Requirement

All rule interpretations MUST use strictest interpretation. Ambiguous rules MUST be clarified immediately.

---

## Rule 22: Prohibition of Convenience Exceptions (NO_CONVENIENCE_EXCEPTIONS_001)

**Rule ID:** NO_CONVENIENCE_EXCEPTIONS_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-0 (Constitutional Violation)

### Convenience Exception Prohibition

The following reasons are NEVER valid justification for violating Coverage governance rules:
- "Implementation is more convenient"
- "Performance is better"
- "User experience is better"
- "Business requirement is urgent"
- "Just a temporary solution"
- "Will fix later"
- "Impact scope is small"
- "Only internal use"
- "Documentation will explain"
- "Tests will cover"
- "CI is flaky"
- "Tests are failing"
- "Platform is different"
- "Just this once"
- "Emergency situation"
- "Time pressure"
- "Deadline approaching"

### Prohibited Exception Patterns

The following patterns are EXPLICITLY FORBIDDEN:
- "Special case" exceptions
- "Just this once" exceptions
- "Emergency fix" exceptions
- "Backward compatibility" exceptions (if violating rules)
- "Gradual improvement" exceptions (if violating rules)
- "Temporary" exceptions
- "Phased" relaxations
- "Platform-specific" exceptions

### Only Allowed Changes

The ONLY allowed changes:
- Formal rule changes through RFC process
- Explicitly documented rule evolution (without weakening existing rules)
- Adding new defensive rules

### Enforcement Requirement

Any convenience-based exception MUST be rejected. Any "just this once" pattern MUST be rejected.

---

## Rule 23: Citation-by-ID Requirement (CITATION_BY_ID_001)

**Rule ID:** CITATION_BY_ID_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-2 (Quality Violation)

### Citation-by-ID Principle

**PRINCIPLE-010: Citations MUST use stable rule IDs**

Any future PR, design document, issue report, or code comment referencing Coverage governance rules:

- ✅ **MUST use stable rule IDs**: MUST reference rule IDs (e.g., COVERAGE_OWNERSHIP_001, DEPENDENCY_DIRECTION_001)
- ❌ **Prohibited paraphrase-only**: MUST NOT reference rules using only paraphrases or descriptive text
- ❌ **Prohibited vague references**: MUST NOT use vague references like "related rules" or "governance requirements"

### Citation Format Requirements

Citations MUST:
- Include rule ID (format: RULE_NAME_XXX)
- May include rule name as supplementary explanation
- MUST NOT use only rule name or description

### Review Requirements

Code review MUST:
- Verify rule citations include rule IDs
- Treat paraphrase-only citations as invalid in review
- Reject vague citations and require explicit rule IDs

### Enforcement Requirements

Documentation MUST:
- Explicitly state that rule citations MUST use rule IDs
- Include rule ID citation verification items in code review checklist
- CI (future implementation) MUST verify rule citations include rule IDs

### Prohibited Citation Patterns

The following citation patterns are EXPLICITLY FORBIDDEN:
- "This follows coverage governance rules" (vague, no rule ID)
- "Per ownership requirements" (paraphrase, no rule ID)
- "Coverage rules require..." (vague, no rule ID)
- "As per governance" (vague, no rule ID)

### Required Citation Patterns

The following citation patterns are REQUIRED:
- "Per COVERAGE_OWNERSHIP_001: Coverage ownership"
- "Rule DEPENDENCY_DIRECTION_001 prohibits..."
- "As required by SPEC_VERSIONING_001"

### Enforcement Requirement

Any citation not including a rule ID MUST be rejected in code review. Documentation MUST explicitly state citation-by-ID requirement.

---

## Rule 24: Terminology Closed-Set Requirement (TERMINOLOGY_CLOSED_SET_001)

**Rule ID:** TERMINOLOGY_CLOSED_SET_001  
**Status:** IMMUTABLE  
**Priority:** P0 (Constitutional)  
**Severity:** SEV-2 (Quality Violation)

### Terminology Closed-Set Principle

**PRINCIPLE-011: Terminology MUST form a closed set**

Coverage governance document MUST include a "Terminology (Closed Set)" section defining canonical meanings for key terms.

### Required Terminology Definitions

The governance document MUST define canonical meanings for the following key terms:

- **Coverage**: Measurement metric for spatial evidence sufficiency
- **CoverageEstimator**: Exclusive module responsible for Coverage computation and interpretation
- **Freeze**: System-level decision making Coverage values immutable
- **CoverageSpecVersion**: Specification version governing Coverage semantics
- **Governance Rule**: Coverage governance rule
- **Violation**: Act of violating Coverage governance rules

### Terminology Closed-Set Requirements

Terminology MUST:
- ✅ All key terms have explicit canonical definitions
- ✅ Terminology definitions form a closed set (undefined terms are NOT allowed)
- ✅ Terminology definitions are stable (MUST NOT change arbitrarily)
- ❌ Prohibited: Using undefined terms
- ❌ Prohibited: Using ambiguous or multiple meanings of terms

### New Terminology Addition Requirements

New terminology MUST:
- Be added through RFC process
- Be explicitly added to Terminology Closed Set section
- Terms added without RFC are invalid

### Terminology Usage Requirements

Terminology usage MUST:
- Match Terminology Closed Set definitions in documentation
- Match Terminology Closed Set definitions in code comments
- Be verified for correctness in review

### Enforcement Requirements

Governance document MUST:
- Include "Terminology (Closed Set)" section
- Documentation review MUST verify Terminology Closed Set completeness
- Code review MUST verify terminology usage correctness

### Enforcement Requirement

Any use of undefined terminology MUST be rejected. Documentation MUST include Terminology Closed Set section.

---

## Terminology (Closed Set)

This section defines canonical meanings for key terms used in Coverage governance. All terms form a closed set. Undefined terms are prohibited. New terms require RFC approval.

### Core Terms

**Coverage**
- **Definition**: Measurement metric for spatial evidence sufficiency
- **Scope**: Measures proportion of theoretical target area covered by evidence, sufficiency of spatial sampling points, spatial evidence completeness for geometric reconstruction
- **NOT**: Visual quality, aesthetic completeness, texture fidelity, final model quality, user satisfaction, business value, completion indicator
- **Type**: Double, range [0, 1]
- **Source**: CoverageEstimator (exclusive)

**CoverageEstimator**
- **Definition**: Exclusive module responsible for Coverage definition, computation, and interpretation
- **Ownership**: Owns all Coverage-related computation and semantics
- **Constraints**: MUST be stateless, MUST NOT depend on StateMachine, MUST NOT implement freeze logic
- **Input**: Spatial evidence data, computation parameters, CoverageSpecVersion
- **Output**: Coverage value, CoverageSpecVersion, computation metadata

**Freeze**
- **Definition**: System-level decision making Coverage values immutable for asset integrity protection, audit record immutability, or chain verification requirements
- **Level**: System-level (NOT CoverageEstimator responsibility)
- **Implementation**: Outside CoverageEstimator (asset management systems, audit record systems, chain verification systems)
- **CoverageEstimator Constraint**: MUST remain unaware of freeze status

**CoverageSpecVersion**
- **Definition**: Specification version governing Coverage semantics
- **Type**: Specification version (NOT code version)
- **Purpose**: Manages Coverage semantic versioning
- **Usage**: MUST be stored with every Coverage value in audit records
- **Prohibited**: MUST NOT use code version numbers, implementation details, algorithm versions, or library versions to infer Coverage semantics

**Governance Rule**
- **Definition**: Coverage governance rule defined in this document
- **Status**: IMMUTABLE (constitutional-level)
- **Priority**: P0 (Constitutional)
- **Format**: RULE_NAME_XXX (e.g., COVERAGE_OWNERSHIP_001)
- **Change Control**: Requires RFC, MUST NOT weaken existing rules

**Violation**
- **Definition**: Act of violating Coverage governance rules
- **Severity Levels**: SEV-0 (Constitutional), SEV-1 (Governance), SEV-2 (Quality), SEV-3 (Minor)
- **Handling**: MUST be rejected, MUST block merge for SEV-0 and SEV-1
- **Detection**: Code review, CI automation, test verification, documentation review

### Governance Terms

**Rule ID**
- **Definition**: Stable identifier for governance rules (format: RULE_NAME_XXX)
- **Purpose**: Enables precise citation and reference
- **Requirement**: MUST be used in all rule citations
- **Example**: COVERAGE_OWNERSHIP_001, DEPENDENCY_DIRECTION_001

**Citation**
- **Definition**: Reference to governance rules in PRs, design documents, issue reports, or code comments
- **Requirement**: MUST include rule ID
- **Prohibited**: Paraphrase-only citations, vague citations
- **Format**: "Per RULE_NAME_XXX: rule description"

**Terminology Closed Set**
- **Definition**: Canonical set of terminology definitions forming a closed set
- **Requirement**: All key terms MUST be defined
- **Stability**: Definitions MUST be stable
- **Extension**: New terms require RFC approval

### System Terms

**StateMachine**
- **Definition**: System module managing state transitions
- **Relationship to Coverage**: MAY read Coverage values, MUST NOT modify Coverage values
- **CoverageEstimator Constraint**: CoverageEstimator MUST NOT read StateMachine

**Audit Record**
- **Definition**: Immutable record of Coverage computation
- **Required Fields**: Coverage value, CoverageSpecVersion, input digest, computation timestamp, computation ID
- **Immutability**: MUST NOT be modified or deleted once created
- **Purpose**: Enables verification, reproduction, and querying

**Platform**
- **Definition**: Execution environment (iOS, Linux, macOS, CI)
- **Coverage Constraint**: Coverage computation MUST be platform-independent at semantic level
- **Consistency Requirement**: All platforms MUST produce identical Coverage values (within tolerance)
- **Prohibited**: Platform-specific Coverage computation shortcuts or exceptions

### Enforcement Terms

**Code Review**
- **Definition**: Review process verifying code compliance with governance rules
- **Requirement**: MUST check Coverage governance rule compliance
- **Checklist**: MUST use Coverage governance rule checklist

**CI Automation**
- **Definition**: Continuous Integration automation checking Coverage governance rules
- **Requirement**: MUST include Coverage governance rule automation checks
- **Check Items**: Ownership, dependency direction, statelessness, determinism, etc.

**Test Verification**
- **Definition**: Test process verifying Coverage governance rules
- **Requirement**: Tests MUST verify Coverage governance rules
- **Coverage**: MUST cover all governance rules

### Prohibited Terms

The following terms are PROHIBITED unless explicitly defined in this Terminology Closed Set:
- Any undefined terminology
- Ambiguous or multiple-meaning terms
- Terms not added through RFC process

### Terminology Stability

Terminology definitions are IMMUTABLE. Changes require:
- RFC process approval
- Explicit documentation of changes
- Version control
- Backward compatibility consideration

---

## Constitutional Status Declaration

### Non-Negotiability

All rules in this document are **CONSTITUTIONAL-LEVEL** and non-negotiable. These rules:
- Override implementation convenience
- Override business requirements
- Override product requirements
- Override performance optimization
- Override user experience improvements
- Override deadlines
- Override emergency situations

**There are NO exceptions.**

### Subsequent PR Constraints

Subsequent implementation PRs (ownership defined later) MUST:
- Comply with all rules (MUST NOT violate any governance rules)
- NOT weaken rules (MUST NOT weaken or remove any rules)
- May add rules (may add new governance rules through RFC)

### Rule Priority

Rule priority:
- **P0 (Constitutional)**: All rules are P0 priority
- **Override other rules**: These rules override all other rules (unless higher-level constitutional rules)

### PR1 as Last Line of Defense

**PR1 is the LAST line of defense for Coverage integrity. PR1 cannot fail.**

PR1 MUST:
- Define rules strict and complete enough
- Assume worst-case misuse and pressure
- Defensively design all rules
- Explicitly prohibit all known and potential misuse patterns
- Establish non-negotiable governance framework

Once PR1 is merged:
- Rules become IMMUTABLE constitution
- Subsequent PRs can only comply, cannot weaken
- Any attempt to weaken rules MUST be rejected
- Rule changes MUST go through RFC and MUST NOT weaken existing rules

---

## Related Documents

- [SSOT_FOUNDATION_v1.1.md](SSOT_FOUNDATION_v1.1.md) - Core foundation document
- [SYSTEM_CONTRACTS.md](SYSTEM_CONTRACTS.md) - System contracts
- [CROSS_PLATFORM_CONSISTENCY.md](CROSS_PLATFORM_CONSISTENCY.md) - Cross-platform consistency rules
- [AUDIT_IMMUTABILITY.md](AUDIT_IMMUTABILITY.md) - Audit immutability principles
- [MATH_SAFETY_INVARIANTS.md](MATH_SAFETY_INVARIANTS.md) - Math safety invariants

---

**Status:** IMMUTABLE  
**Change Strategy:** Append-only; existing rules immutable  
**Audience:** All developers, architects, product managers, QA engineers  
**Last Line of Defense:** PR1 is the last line of defense for Coverage integrity
