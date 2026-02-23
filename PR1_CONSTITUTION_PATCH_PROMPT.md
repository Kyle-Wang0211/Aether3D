# PR1 Constitution Patch: Cursor Implementation Prompt

**Version**: 1.0.0
**Date**: 2026-01-28
**Scope**: Three constitutional amendments for PR#1 SSOT Foundation
**Priority**: P0 (Foundation-level, blocks future PRs from technical debt)

---

## Executive Summary

You are implementing three constitutional amendments to PR#1 that will:
1. **PR1-1**: Elevate CI Hardening rules to constitutional status
2. **PR1-2**: Define Module Contract Equivalence framework
3. **PR1-3**: Establish Spec Drift Handling protocol

These amendments transform implicit engineering discipline into explicit, machine-verifiable constitutional law. Once merged, these rules are **IMMUTABLE** and apply to all future PRs (PR7, PR8, ..., PR∞).

---

## PART 1: PR1-1 — CI HARDENING CONSTITUTION

### 1.1 Document Creation

**File**: `docs/constitution/CI_HARDENING_CONSTITUTION.md`

**Purpose**: Prohibit non-deterministic time/timer primitives in production code. This is a cross-PR engineering discipline that prevents "why do we need ClockProvider again?" debates forever.

### 1.2 Document Content (EXACT)

```markdown
# CI Hardening Constitution

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** All production code across all platforms (Swift, Python, Kotlin, future languages)

---

## §0 ABSOLUTE AUTHORITY

This document establishes **non-negotiable** rules for deterministic, testable, CI-safe code. Violations are **SEV-0 Constitutional** and MUST be rejected at PR review.

**Rationale**: Direct time/timer calls create:
- Non-deterministic test failures
- CI flakiness on slow/fast machines
- Impossible-to-reproduce bugs
- Hidden coupling to wall-clock time

These rules exist because debugging time-dependent failures costs 10-100x more than following injection patterns from the start.

---

## §1 PROHIBITED PRIMITIVES (CLOSED SET)

### §1.1 Swift Prohibitions

| Primitive | Prohibition | Reason |
|-----------|-------------|--------|
| `Date()` | ❌ BANNED in business logic | Non-deterministic wall-clock |
| `Date(timeIntervalSinceNow:)` | ❌ BANNED | Same as Date() |
| `Date(timeIntervalSince1970:)` | ⚠️ ALLOWED only for deserialization | Not a time source |
| `Timer.scheduledTimer` | ❌ BANNED | Non-injectable timer |
| `DispatchQueue.asyncAfter` | ❌ BANNED | Non-injectable delay |
| `Thread.sleep` | ❌ BANNED | Blocks thread, non-injectable |
| `Task.sleep` | ❌ BANNED in production | Use injected scheduler |
| `CFAbsoluteTimeGetCurrent()` | ❌ BANNED | Low-level time source |
| `mach_absolute_time()` | ❌ BANNED | Platform-specific |
| `ProcessInfo.processInfo.systemUptime` | ⚠️ ALLOWED only via MonotonicClock wrapper | Must be injectable |

### §1.2 Python Prohibitions

| Primitive | Prohibition | Reason |
|-----------|-------------|--------|
| `datetime.now()` | ❌ BANNED in business logic | Non-deterministic |
| `datetime.utcnow()` | ❌ BANNED | Deprecated + non-deterministic |
| `time.time()` | ❌ BANNED | Non-deterministic |
| `time.sleep()` | ❌ BANNED in production | Non-injectable |
| `asyncio.sleep()` | ❌ BANNED without injection | Must use injectable scheduler |
| `threading.Timer` | ❌ BANNED | Non-injectable |

### §1.3 Future Language Policy

Any new language added to the codebase MUST define equivalent prohibitions before the first PR is merged. The prohibition list MUST be added to this document via RFC.

---

## §2 MANDATORY INJECTION PATTERNS

### §2.1 Swift Patterns

**ClockProvider Protocol (SSOT)**:
```swift
/// CONSTITUTIONAL CONTRACT - DO NOT MODIFY WITHOUT RFC
/// Source: CI_HARDENING_CONSTITUTION.md §2.1
public protocol ClockProvider: Sendable {
    /// Returns current time. Implementations MUST be deterministic in tests.
    func now() -> Date

    /// Returns monotonic time in seconds. MUST NOT go backwards.
    func monotonicNow() -> TimeInterval
}

/// Default implementation for production. Tests MUST inject mock.
public struct DefaultClockProvider: ClockProvider {
    public init() {}
    public func now() -> Date { Date() }
    public func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
```

**TimerScheduler Protocol (SSOT)**:
```swift
/// CONSTITUTIONAL CONTRACT - DO NOT MODIFY WITHOUT RFC
/// Source: CI_HARDENING_CONSTITUTION.md §2.1
public protocol TimerScheduler: Sendable {
    /// Schedules a one-shot callback after delay.
    /// Returns a cancellation token.
    func scheduleAfter(
        _ delay: TimeInterval,
        execute: @escaping @Sendable () -> Void
    ) -> AnyCancellable

    /// Schedules a repeating callback.
    func scheduleRepeating(
        interval: TimeInterval,
        execute: @escaping @Sendable () -> Void
    ) -> AnyCancellable
}
```

### §2.2 Python Patterns

**ClockProvider ABC (SSOT)**:
```python
# CONSTITUTIONAL CONTRACT - DO NOT MODIFY WITHOUT RFC
# Source: CI_HARDENING_CONSTITUTION.md §2.2
from abc import ABC, abstractmethod
from datetime import datetime

class ClockProvider(ABC):
    """Injectable time source. Tests MUST inject mock."""

    @abstractmethod
    def now(self) -> datetime:
        """Returns current UTC time."""
        pass

    @abstractmethod
    def monotonic_now(self) -> float:
        """Returns monotonic seconds. MUST NOT go backwards."""
        pass

class DefaultClockProvider(ClockProvider):
    """Production implementation. Tests inject MockClockProvider."""

    def now(self) -> datetime:
        return datetime.now(tz=timezone.utc)

    def monotonic_now(self) -> float:
        return time.monotonic()
```

---

## §3 ALLOWED EXCEPTIONS (CLOSED SET)

### §3.1 Allowlist Structure

| Exception ID | File Pattern | Allowed Primitive | Reason |
|--------------|--------------|-------------------|--------|
| `E001` | `**/Default*Provider.swift` | `Date()` | Default implementation |
| `E002` | `**/Default*Provider.swift` | `Timer.scheduledTimer` | Default implementation |
| `E003` | `**/Default*Provider.py` | `datetime.now()` | Default implementation |
| `E004` | `**/*Tests.swift` | `Date()` | Test setup only |
| `E005` | `**/*_test.py` | `datetime.now()` | Test setup only |
| `E006` | `**/CaptureMetadata.swift` | `: Date` (type annotation) | Type declaration, not call |
| `E007` | `**/*Formatter*` | `DateFormatter` | Formatting, not time source |

### §3.2 Adding New Exceptions

New exceptions REQUIRE:
1. RFC with justification
2. Approval from 2+ maintainers
3. Update to this allowlist with new Exception ID
4. Corresponding update to static scan tests

Exceptions are **append-only**. Removing an exception requires major version bump.

---

## §4 ENFORCEMENT MECHANISMS

### §4.1 Static Scan Tests (MANDATORY)

Every repository MUST have these tests that run on every PR:

**Swift Test**:
```swift
func test_productionCodeBansDateConstructor() {
    let violations = StaticScanner.scan(
        directory: "Sources/",
        pattern: #"Date\(\s*\)"#,
        excluding: Self.allowlist
    )
    XCTAssertEqual(violations, [], "Date() found in production code")
}

func test_productionCodeBansTimerScheduledTimer() {
    let violations = StaticScanner.scan(
        directory: "Sources/",
        pattern: #"Timer\.scheduledTimer"#,
        excluding: Self.allowlist
    )
    XCTAssertEqual(violations, [], "Timer.scheduledTimer found")
}
```

**Python Test**:
```python
def test_production_code_bans_datetime_now():
    violations = static_scan(
        directory="src/",
        pattern=r"datetime\.now\(\)",
        excluding=ALLOWLIST
    )
    assert violations == [], f"datetime.now() found: {violations}"
```

### §4.2 CI Gate Configuration

**GitHub Actions Gate** (REQUIRED in all repos):
```yaml
# .github/workflows/ci.yml
jobs:
  ci-hardening-gate:
    name: CI Hardening Constitutional Check
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run CI Hardening Scan
        run: |
          swift test --filter CIHardeningScanTests
          # OR for Python:
          # pytest tests/test_ci_hardening_scan.py -v
      - name: Verify No Violations
        if: failure()
        run: |
          echo "::error::CI Hardening Constitution violated. See §1 for prohibited primitives."
          exit 1
```

### §4.3 Pre-commit Hook (RECOMMENDED)

```bash
#!/bin/bash
# .git/hooks/pre-commit
# CI Hardening quick check

if grep -rn "Date()" --include="*.swift" Sources/ | grep -v "Default.*Provider"; then
    echo "ERROR: Date() found in production code. Use ClockProvider."
    exit 1
fi
```

---

## §5 VIOLATION SEVERITY

| Violation Type | Severity | Response |
|----------------|----------|----------|
| Direct Date()/datetime.now() in business logic | SEV-0 | Block merge, require fix |
| Timer.scheduledTimer in production | SEV-0 | Block merge, require fix |
| Missing ClockProvider injection | SEV-1 | Block merge, require refactor |
| Allowlist bypass without RFC | SEV-0 | Revert immediately |
| Missing static scan test | SEV-1 | Add before next release |

---

## §6 MIGRATION GUIDE

### §6.1 For Existing Code

If you find existing violations:
1. Create a tracking issue
2. Add to allowlist with `LEGACY:` prefix and issue number
3. Schedule refactor within 2 sprints
4. Remove from allowlist after refactor

### §6.2 For New Code

All new code MUST:
1. Accept ClockProvider/TimerScheduler via constructor injection
2. Default to production implementation
3. Document injectable dependencies in class/function header

**Example**:
```swift
/// Records video capture sessions.
///
/// - Dependencies (Injectable):
///   - clockProvider: Time source for duration calculations
///   - timerScheduler: Scheduling for periodic file size checks
final class RecordingController {
    private let clockProvider: ClockProvider
    private let timerScheduler: TimerScheduler

    init(
        clockProvider: ClockProvider = DefaultClockProvider(),
        timerScheduler: TimerScheduler = DefaultTimerScheduler()
    ) {
        self.clockProvider = clockProvider
        self.timerScheduler = timerScheduler
    }
}
```

---

## §7 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial constitution |

---

**END OF DOCUMENT**
```

### 1.3 Implementation Checklist for PR1-1

- [ ] Create `docs/constitution/CI_HARDENING_CONSTITUTION.md` with exact content above
- [ ] Add entry to `docs/constitution/INDEX.md`:
  ```markdown
  - [CI_HARDENING_CONSTITUTION.md](CI_HARDENING_CONSTITUTION.md) - CI hardening rules (IMMUTABLE)
    - **Who depends:** All production code, all future PRs
    - **What breaks if violated:** Test determinism, CI reliability
    - **Why exists:** Prevents time-dependent bugs and CI flakiness
  ```
- [ ] Verify existing code compliance:
  - `App/Capture/CameraSession.swift` - already uses ClockProvider ✓
  - `App/Capture/InterruptionHandler.swift` - already uses TimerScheduler ✓
  - `App/Capture/RecordingController.swift` - already compliant ✓
- [ ] Ensure `Tests/CaptureTests/CaptureStaticScanTests.swift` exists and covers §4.1

---

## PART 2: PR1-2 — MODULE CONTRACT EQUIVALENCE

### 2.1 Document Creation

**File**: `docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md`

**Purpose**: Define what makes a PR's internal contract (like PR5's EXECUTIVE_REPORT) constitutionally valid. This prevents "does PR5's report count as law?" debates.

### 2.2 Document Content (EXACT)

```markdown
# Module Contract Equivalence

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** All PRs that define domain-specific contracts

---

## §0 PURPOSE

PR#1 is the **skeleton** — the platform-level constitution that defines universal rules.

Each subsequent PR MAY define **domain-specific contracts** (Executive Reports, Contract Documents, Specification Files) that extend PR#1 within their bounded context.

This document defines:
1. What makes a domain contract **constitutionally valid**
2. How domain contracts relate to PR#1
3. The compliance checklist every domain contract MUST satisfy

---

## §1 HIERARCHY OF AUTHORITY

```
┌─────────────────────────────────────────────────────────────┐
│  LEVEL 0: PR#1 SSOT Foundation (Supreme, Immutable)         │
│  - SSOT_FOUNDATION_v1.1.md                                  │
│  - CI_HARDENING_CONSTITUTION.md                             │
│  - CLOSED_SET_GOVERNANCE.md                                 │
│  - All docs/constitution/*.md                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼ MUST NOT CONTRADICT
┌─────────────────────────────────────────────────────────────┐
│  LEVEL 1: Domain Contracts (PR-scoped, Immutable after PR)  │
│  - PR#2: JSM Contract (ContractConstants.swift)             │
│  - PR#3: API_CONTRACT.md                                    │
│  - PR#4: CaptureRecordingConstants.swift                    │
│  - PR#5: EXECUTIVE_REPORT.md + QualityPreCheckConstants     │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼ MUST SATISFY
┌─────────────────────────────────────────────────────────────┐
│  LEVEL 2: Implementation Code                               │
│  - All .swift, .py, .kt files                               │
│  - Tests validate Level 1 contracts                         │
└─────────────────────────────────────────────────────────────┘
```

**Rule**: Lower levels CANNOT contradict higher levels. If conflict exists, higher level wins.

---

## §2 DOMAIN CONTRACT VALIDITY REQUIREMENTS

A domain contract is **constitutionally valid** if and only if it satisfies ALL of the following:

### §2.1 SSOT Constants File (MANDATORY)

**Requirement**: Domain MUST have a single-source-of-truth constants file.

**Swift Pattern**:
```swift
// Core/Constants/{Domain}Constants.swift
// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR{N}-{DOMAIN}-{VERSION}
// ============================================================================
public enum {Domain}Constants {
    public static let ...
}
```

**Python Pattern**:
```python
# {domain}/contract_constants.py
# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR{N}-{DOMAIN}-{VERSION}
# =============================================================================
class ContractConstants:
    ...
```

**Verification**: `grep -r "CONSTITUTIONAL CONTRACT" Core/Constants/` returns the file.

### §2.2 Illegal Input/State Coverage (MANDATORY)

**Requirement**: Tests MUST cover:
- All illegal inputs → rejected with correct error
- All illegal state transitions → rejected with correct error
- Boundary conditions (off-by-one, empty, max)

**Minimum Coverage**:
| Category | Minimum Tests |
|----------|---------------|
| Illegal inputs | ≥ 5 cases |
| Illegal state transitions | 100% of illegal pairs |
| Boundary conditions | ≥ 3 per threshold |

**Verification**: Test file contains `test*Illegal*` or `test*Invalid*` or `test*Boundary*` functions.

### §2.3 State Change Logging (MANDATORY)

**Requirement**: Every state change MUST be logged with:
- Timestamp (ISO8601 UTC)
- Previous state
- New state
- Trigger/reason

**Pattern**:
```swift
func transition(from: State, to: State, reason: String) {
    logger.info("[STATE] \(from.rawValue) → \(to.rawValue) reason=\(reason)")
    // ... actual transition
}
```

**Verification**: `grep -r "STATE.*→" Sources/` returns logging calls.

### §2.4 Machine-Verifiable Contract Document (MANDATORY)

**Requirement**: Domain MUST have a contract document that is:
- Markdown format
- Contains version number
- Has corresponding `.hash` file (SHA256 of document)

**Structure**:
```
docs/constitution/{DOMAIN}_CONTRACT.md
docs/constitution/{DOMAIN}_CONTRACT.hash
```

OR for PR-specific:
```
PR{N}_{DOMAIN}_EXECUTIVE_REPORT.md
PR{N}_{DOMAIN}_EXECUTIVE_REPORT.hash
```

**Hash Verification Test**:
```swift
func test_contractDocumentHashIntegrity() {
    let doc = try! String(contentsOfFile: "docs/constitution/API_CONTRACT.md")
    let expected = try! String(contentsOfFile: "docs/constitution/API_CONTRACT.hash").trimmingCharacters(in: .whitespacesAndNewlines)
    let actual = SHA256.hash(data: doc.data(using: .utf8)!).hexString
    XCTAssertEqual(actual, expected, "Contract document modified without updating hash")
}
```

### §2.5 Closed-Set Compliance (MANDATORY)

**Requirement**: All enums, error codes, and status values MUST be closed sets per CLOSED_SET_GOVERNANCE.md.

**Verification Checklist**:
- [ ] No `@unknown default` in switches
- [ ] No `default:` that swallows unknown cases
- [ ] All enums have frozen case order hash
- [ ] CI test validates enum count matches contract

---

## §3 COMPLIANCE CHECKLIST

Every domain contract PR MUST include this checklist in the PR description:

```markdown
## Domain Contract Compliance Checklist

- [ ] **§2.1 SSOT Constants**: `Core/Constants/{Domain}Constants.swift` exists with header
- [ ] **§2.2 Illegal Coverage**: Tests cover ≥5 illegal inputs, 100% illegal transitions
- [ ] **§2.3 State Logging**: All state changes logged with timestamp/from/to/reason
- [ ] **§2.4 Contract Doc**: `{DOMAIN}_CONTRACT.md` + `.hash` file exists
- [ ] **§2.5 Closed-Set**: No `@unknown default`, all enums have frozen hash

**Contract Version**: PR{N}-{DOMAIN}-{VERSION}
**Hash**: {SHA256 of contract document}
```

---

## §4 EQUIVALENCE DECLARATION

When a domain contract satisfies all §2 requirements, it is **constitutionally equivalent** to a PR#1 amendment within its bounded context.

**What this means**:
- The domain contract is **binding** for all code in that domain
- Violations are **SEV-1** (domain-level) not SEV-0 (platform-level)
- The contract is **immutable** after PR merge (append-only)
- Future PRs in the same domain MUST NOT contradict it

**What this does NOT mean**:
- Domain contracts do NOT override PR#1 rules
- Domain contracts do NOT apply outside their bounded context
- Domain contracts are NOT automatically inherited by other domains

---

## §5 CROSS-DOMAIN CONSISTENCY

When multiple domains interact, the following rules apply:

### §5.1 Shared Constants

If two domains need the same constant:
1. Move constant to PR#1 `SSOT_CONSTANTS.md`
2. Both domains reference the single source
3. Neither domain may redefine it

### §5.2 Interface Contracts

If Domain A calls Domain B:
1. Domain B's contract defines the interface
2. Domain A MUST NOT assume behavior beyond B's contract
3. Changes to B's interface require RFC

### §5.3 Conflict Resolution

If domain contracts conflict:
1. Raise RFC immediately
2. PR#1 maintainers decide resolution
3. Losing domain MUST update its contract

---

## §6 EXAMPLES

### §6.1 PR#2 JSM Contract (VALID)

| Requirement | Status | Evidence |
|-------------|--------|----------|
| §2.1 SSOT Constants | ✅ | `Core/Jobs/ContractConstants.swift` |
| §2.2 Illegal Coverage | ✅ | `testAllStatePairs()` covers 81 pairs |
| §2.3 State Logging | ✅ | `TransitionLog` with timestamp/from/to |
| §2.4 Contract Doc | ✅ | `PR2_JSM_v2.5_VERIFICATION_REPORT.md` |
| §2.5 Closed-Set | ✅ | `frozenCaseOrderHash` in all enums |

### §6.2 PR#5 Quality Pre-check (VALID)

| Requirement | Status | Evidence |
|-------------|--------|----------|
| §2.1 SSOT Constants | ✅ | `Core/Constants/QualityPreCheckConstants.swift` |
| §2.2 Illegal Coverage | ✅ | Degraded/Emergency tier policy tests |
| §2.3 State Logging | ✅ | Audit commit with hash chain |
| §2.4 Contract Doc | ✅ | `PR5_FINAL_EXECUTIVE_REPORT.md` |
| §2.5 Closed-Set | ✅ | DecisionPolicy sealed at compile-time |

---

## §7 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial constitution |

---

**END OF DOCUMENT**
```

### 2.3 Implementation Checklist for PR1-2

- [ ] Create `docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md` with exact content above
- [ ] Add entry to `docs/constitution/INDEX.md`:
  ```markdown
  - [MODULE_CONTRACT_EQUIVALENCE.md](MODULE_CONTRACT_EQUIVALENCE.md) - Domain contract validity rules
    - **Who depends:** All future PRs defining domain-specific contracts
    - **What breaks if violated:** Contract legitimacy, cross-PR consistency
    - **Why exists:** Establishes what makes a PR's internal contract valid
  ```
- [ ] Verify existing PRs comply (they already do based on analysis):
  - PR#2: JSM → ContractConstants.swift ✓
  - PR#3: API → API_CONTRACT.md ✓
  - PR#4: Capture → CaptureRecordingConstants.swift ✓
  - PR#5: Quality → QualityPreCheckConstants.swift + EXECUTIVE_REPORT ✓

---

## PART 3: PR1-3 — SPEC DRIFT HANDLING

### 3.1 Document Creation

**File**: `docs/constitution/SPEC_DRIFT_HANDLING.md`

**Purpose**: Legitimize the gap between "plan constants" and "implemented constants". Prevent eternal debates about whether changing a threshold is a bug or a feature.

### 3.2 Document Content (EXACT)

```markdown
# Spec Drift Handling Protocol

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** All PRs where implementation differs from initial plan

---

## §0 CORE PRINCIPLE

**Plan constants are hypotheses. SSOT constants are truth.**

Initial plans (like "MAX_DURATION=120s") are educated guesses made before implementation. During implementation, engineers discover reality:
- Physical constraints (device limits, API behaviors)
- User needs (real-world usage patterns)
- Safety margins (edge case protection)

This document establishes **legal, auditable drift** from plan to implementation.

---

## §1 WHAT IS SPEC DRIFT?

### §1.1 Definition

**Spec Drift** occurs when:
```
Plan Value ≠ Implemented SSOT Value
```

### §1.2 Examples from This Project

| PR | Constant | Plan Value | SSOT Value | Drift Type |
|----|----------|------------|------------|------------|
| PR#1 | MAX_FRAMES | 2000 | 5000 | Relaxed |
| PR#1 | SFM_REGISTRATION_MIN | 0.60 | 0.75 | Stricter |
| PR#1 | PSNR_MIN | 20.0 dB | 30.0 dB | Stricter |
| PR#2 | States | 8 | 9 | Extended (+C-Class) |
| PR#2 | Transitions | 15 | 14 | Corrected |
| PR#4 | MIN_DURATION | 10s | 2s | Relaxed |
| PR#4 | MAX_DURATION | 120s | 900s | Relaxed |
| PR#4 | MAX_SIZE | 2GB | 2TiB | Massively Relaxed |
| PR#5 | LAPLACIAN_THRESHOLD | 100 | 200 | Stricter |
| PR#5 | LOW_LIGHT_BRIGHTNESS | 30 | 60 | Stricter |

---

## §2 DRIFT CLASSIFICATION

### §2.1 Drift Categories

| Category | Definition | Risk Level | Approval |
|----------|------------|------------|----------|
| **STRICTER** | New value rejects more inputs | LOW | Self-approval |
| **RELAXED** | New value accepts more inputs | MEDIUM | Peer review |
| **EXTENDED** | New enum case / new state added | MEDIUM | Peer review |
| **CORRECTED** | Plan was mathematically wrong | LOW | Self-approval |
| **BREAKING** | Changes existing behavior | HIGH | RFC required |

### §2.2 Risk Assessment Matrix

| Drift Affects | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING |
|---------------|----------|---------|----------|-----------|----------|
| Local-only (one module) | ✅ Safe | ✅ Safe | ✅ Safe | ✅ Safe | ⚠️ RFC |
| Cross-module | ✅ Safe | ⚠️ Review | ⚠️ Review | ✅ Safe | ⚠️ RFC |
| Cross-platform (iOS↔Server) | ⚠️ Review | ⚠️ Review | ⚠️ Review | ⚠️ Review | 🚨 RFC |
| API contract | 🚨 RFC | 🚨 RFC | 🚨 RFC | ⚠️ Review | 🚨 RFC |
| Billing/pricing | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC |
| Security boundary | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC | 🚨 RFC |

---

## §3 DRIFT REGISTRATION (MANDATORY)

### §3.1 Drift Registry File

**File**: `docs/drift/DRIFT_REGISTRY.md`

Every spec drift MUST be registered. Format:

```markdown
# Spec Drift Registry

## Active Drifts

| ID | PR | Constant | Plan | SSOT | Category | Reason | Impact | Date |
|----|----|---------|----- |------|----------|--------|--------|------|
| D001 | PR#1 | MAX_FRAMES | 2000 | 5000 | RELAXED | 15-min video needs more frames | Local | 2026-01-XX |
| D002 | PR#1 | SFM_REGISTRATION_MIN | 0.60 | 0.75 | STRICTER | Quality guarantee | Local | 2026-01-XX |
| ... | ... | ... | ... | ... | ... | ... | ... | ... |

## Drift Count by PR

| PR | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING | Total |
|----|----------|---------|----------|-----------|----------|-------|
| PR#1 | 2 | 1 | 0 | 0 | 0 | 3 |
| PR#2 | 0 | 0 | 1 | 1 | 0 | 2 |
| PR#4 | 0 | 3 | 0 | 0 | 0 | 3 |
| PR#5 | 2 | 0 | 0 | 0 | 0 | 2 |
```

### §3.2 Registration Process

1. **Discover drift** during implementation
2. **Classify** using §2.1 categories
3. **Assess risk** using §2.2 matrix
4. **Register** in DRIFT_REGISTRY.md with:
   - Unique ID (D001, D002, ...)
   - PR number
   - Constant name (SSOT ID)
   - Plan value (from original plan doc)
   - SSOT value (actual implementation)
   - Category
   - Reason (1-2 sentences)
   - Impact scope
   - Date
5. **Update** PR's Contract/Executive Report with drift reference
6. **If cross-platform/API/billing/security** → Create RFC

---

## §4 DRIFT APPROVAL WORKFLOW

### §4.1 Self-Approval (STRICTER, CORRECTED, Local)

```
Developer discovers drift
    │
    ▼
Register in DRIFT_REGISTRY.md
    │
    ▼
Update Contract/Executive Report
    │
    ▼
Include in PR description
    │
    ▼
Done (no additional approval needed)
```

### §4.2 Peer Review (RELAXED, EXTENDED, Cross-module)

```
Developer discovers drift
    │
    ▼
Register in DRIFT_REGISTRY.md
    │
    ▼
Update Contract/Executive Report
    │
    ▼
Add "DRIFT REVIEW" label to PR
    │
    ▼
Require 1 additional reviewer approval
    │
    ▼
Done
```

### §4.3 RFC Required (Cross-platform, API, Billing, Security, BREAKING)

```
Developer discovers drift
    │
    ▼
STOP implementation
    │
    ▼
Create RFC in docs/rfcs/
    │
    ▼
RFC review (minimum 3 business days)
    │
    ▼
RFC approval by 2+ maintainers
    │
    ▼
Register in DRIFT_REGISTRY.md with RFC link
    │
    ▼
Update ALL affected contracts
    │
    ▼
Continue implementation
```

---

## §5 DRIFT DOCUMENTATION IN PR

### §5.1 PR Description Template

Every PR with drift MUST include:

```markdown
## Spec Drift Declaration

This PR contains **{N}** spec drifts from the original plan:

| Drift ID | Constant | Plan → SSOT | Category | Reason |
|----------|----------|-------------|----------|--------|
| D0XX | {NAME} | {OLD} → {NEW} | {CAT} | {REASON} |

**Cross-platform impact**: None / Yes (see RFC-XXX)
**API contract impact**: None / Yes (see API_CONTRACT.md update)
**Billing impact**: None / Yes (see RFC-XXX)

All drifts registered in `docs/drift/DRIFT_REGISTRY.md`.
```

### §5.2 Contract/Executive Report Update

Add drift section:

```markdown
## Spec Drift from Plan

| Drift ID | Constant | Plan | SSOT | Reason |
|----------|----------|------|------|--------|
| D0XX | ... | ... | ... | ... |

All values in this document reflect SSOT (implementation truth), not plan (initial hypothesis).
```

---

## §6 TRUTH HIERARCHY

When conflicts arise, this is the resolution order:

```
1. SSOT Constants File (Core/Constants/*.swift)     ← ULTIMATE TRUTH
2. Contract/Executive Report (with drift section)   ← Documented truth
3. Drift Registry (docs/drift/DRIFT_REGISTRY.md)    ← Historical record
4. Original Plan Document                           ← Historical hypothesis
```

**Rule**: If code and docs disagree, code wins. Then fix docs.

---

## §7 ANTI-PATTERNS

### §7.1 Forbidden Practices

| Anti-Pattern | Why Bad | Correct Approach |
|--------------|---------|------------------|
| Changing SSOT without registering drift | Invisible change, audit failure | Register in DRIFT_REGISTRY |
| Keeping plan value in comments "for reference" | Confusion about truth | Remove or mark as `HISTORICAL` |
| Multiple sources for same constant | SSOT violation | Consolidate to one source |
| Drift without updating contract doc | Doc-code desync | Update contract in same PR |
| Undocumented "temporary" relaxation | Permanent tech debt | Register or don't do it |

### §7.2 Detection

CI SHOULD warn on:
- Constants in comments that differ from SSOT
- Multiple definitions of same constant name
- Contract docs older than SSOT file (mtime check)

---

## §8 EXAMPLES

### §8.1 Good Drift Declaration

```markdown
## PR#4 Spec Drift Declaration

This PR contains **3** spec drifts:

| Drift ID | Constant | Plan → SSOT | Category | Reason |
|----------|----------|-------------|----------|--------|
| D010 | MIN_DURATION | 10s → 2s | RELAXED | User testing showed 10s too restrictive for quick scans |
| D011 | MAX_DURATION | 120s → 900s | RELAXED | Pro users need longer recordings for large objects |
| D012 | MAX_SIZE | 2GB → 2TiB | RELAXED | Future-proofing for 8K video, current HW can't hit this |

**Cross-platform impact**: None (client-only constants)
**API contract impact**: None (not sent to server)
**Billing impact**: None (recording limits don't affect pricing)
```

### §8.2 Bad Drift (Anti-Pattern)

```swift
// BAD: Undocumented drift
public static let maxDuration: TimeInterval = 900 // was 120 in plan, changed because reasons

// GOOD: Properly documented
/// Maximum recording duration.
/// - SSOT: 900 seconds (15 minutes)
/// - Drift: D011 (RELAXED from plan value 120s)
/// - Reason: Pro users need longer recordings
public static let maxDuration: TimeInterval = 900
```

---

## §9 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial protocol |

---

**END OF DOCUMENT**
```

### 3.3 Create Drift Registry

**File**: `docs/drift/DRIFT_REGISTRY.md`

```markdown
# Spec Drift Registry

**Last Updated**: 2026-01-28
**Total Drifts**: 10

---

## Active Drifts

| ID | PR | Constant | Plan | SSOT | Category | Reason | Impact | Date |
|----|----|---------|----- |------|----------|--------|--------|------|
| D001 | PR#1 | SystemConstants.maxFrames | 2000 | 5000 | RELAXED | 15-min video at 2fps needs up to 1800 frames, 5000 provides headroom | Local | 2026-01-XX |
| D002 | PR#1 | QualityThresholds.sfmRegistrationMinRatio | 0.60 | 0.75 | STRICTER | Higher quality bar ensures reliable 3D reconstruction | Local | 2026-01-XX |
| D003 | PR#1 | QualityThresholds.psnrMinDb | 20.0 | 30.0 | STRICTER | Industry standard for acceptable visual quality | Local | 2026-01-XX |
| D004 | PR#2 | ContractConstants.STATE_COUNT | 8 | 9 | EXTENDED | Added CAPACITY_SATURATED for PR1 C-Class | Cross-module | 2026-01-XX |
| D005 | PR#2 | ContractConstants.LEGAL_TRANSITION_COUNT | 15 | 14 | CORRECTED | Actual legal transitions after analysis | Local | 2026-01-XX |
| D006 | PR#4 | CaptureRecordingConstants.minDurationSeconds | 10 | 2 | RELAXED | User testing showed 10s too restrictive | Local | 2026-01-XX |
| D007 | PR#4 | CaptureRecordingConstants.maxDurationSeconds | 120 | 900 | RELAXED | Pro users need longer recordings | Local | 2026-01-XX |
| D008 | PR#4 | CaptureRecordingConstants.maxBytes | 2GB | 2TiB | RELAXED | Future-proofing for 8K video | Local | 2026-01-XX |
| D009 | PR#5 | FrameQualityConstants.blurThresholdLaplacian | 100 | 200 | STRICTER | 2x industry standard for quality guarantee | Local | 2026-01-XX |
| D010 | PR#5 | FrameQualityConstants.darkThresholdBrightness | 30 | 60 | STRICTER | Better dark scene handling | Local | 2026-01-XX |

---

## Drift Count by PR

| PR | STRICTER | RELAXED | EXTENDED | CORRECTED | BREAKING | Total |
|----|----------|---------|----------|-----------|----------|-------|
| PR#1 | 2 | 1 | 0 | 0 | 0 | 3 |
| PR#2 | 0 | 0 | 1 | 1 | 0 | 2 |
| PR#3 | 0 | 0 | 0 | 0 | 0 | 0 |
| PR#4 | 0 | 3 | 0 | 0 | 0 | 3 |
| PR#5 | 2 | 0 | 0 | 0 | 0 | 2 |
| **Total** | **4** | **4** | **1** | **1** | **0** | **10** |

---

## Drift Statistics

- **Most drifts by category**: STRICTER (4), RELAXED (4)
- **Most drifts by PR**: PR#4 (3), PR#1 (3)
- **Cross-platform drifts**: 1 (D004)
- **RFCs required**: 0
- **Breaking changes**: 0

---

## Notes

All drifts in this registry have been:
1. Classified per SPEC_DRIFT_HANDLING.md §2
2. Assessed per risk matrix
3. Approved per workflow (self/peer/RFC)
4. Documented in respective PR Contract/Executive Reports

---

**END OF REGISTRY**
```

### 3.4 Implementation Checklist for PR1-3

- [ ] Create `docs/constitution/SPEC_DRIFT_HANDLING.md` with exact content above
- [ ] Create `docs/drift/` directory
- [ ] Create `docs/drift/DRIFT_REGISTRY.md` with initial registry
- [ ] Add entry to `docs/constitution/INDEX.md`:
  ```markdown
  - [SPEC_DRIFT_HANDLING.md](SPEC_DRIFT_HANDLING.md) - Spec drift protocol
    - **Who depends:** All PRs with plan-to-implementation differences
    - **What breaks if violated:** Audit trail, change tracking
    - **Why exists:** Legitimizes drift, prevents eternal debates
  ```
- [ ] Update each PR's Contract/Executive Report with drift section (optional, can be done incrementally)

---

## PART 4: FINAL IMPLEMENTATION INSTRUCTIONS

### 4.1 File Creation Order

Execute in this exact order:

1. `docs/constitution/CI_HARDENING_CONSTITUTION.md`
2. `docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md`
3. `docs/constitution/SPEC_DRIFT_HANDLING.md`
4. `docs/drift/DRIFT_REGISTRY.md`
5. Update `docs/constitution/INDEX.md` (add all 3 new entries)

### 4.2 Verification Commands

After creation, run:

```bash
# Verify files exist
ls -la docs/constitution/CI_HARDENING_CONSTITUTION.md
ls -la docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md
ls -la docs/constitution/SPEC_DRIFT_HANDLING.md
ls -la docs/drift/DRIFT_REGISTRY.md

# Verify INDEX.md updated
grep -c "CI_HARDENING_CONSTITUTION" docs/constitution/INDEX.md
grep -c "MODULE_CONTRACT_EQUIVALENCE" docs/constitution/INDEX.md
grep -c "SPEC_DRIFT_HANDLING" docs/constitution/INDEX.md

# Verify no syntax errors in markdown
# (Install markdownlint if not present)
markdownlint docs/constitution/CI_HARDENING_CONSTITUTION.md
markdownlint docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md
markdownlint docs/constitution/SPEC_DRIFT_HANDLING.md
markdownlint docs/drift/DRIFT_REGISTRY.md
```

### 4.3 Git Commit Message

```
feat(pr1): add constitutional amendments for CI hardening, module contracts, and spec drift

PR1-1: CI_HARDENING_CONSTITUTION.md
- Prohibit Date()/Timer.scheduledTimer in production
- Mandate ClockProvider/TimerScheduler injection
- Define allowlist and enforcement mechanisms

PR1-2: MODULE_CONTRACT_EQUIVALENCE.md
- Define what makes domain contracts valid
- Establish compliance checklist (SSOT/tests/logging/docs/closed-set)
- Clarify hierarchy: PR1 > Domain Contracts > Implementation

PR1-3: SPEC_DRIFT_HANDLING.md
- Legitimize plan-to-implementation drift
- Define classification (STRICTER/RELAXED/EXTENDED/CORRECTED/BREAKING)
- Create DRIFT_REGISTRY.md with 10 existing drifts

These amendments transform implicit engineering discipline into explicit,
machine-verifiable constitutional law. All future PRs (PR7+) MUST comply.

Co-Authored-By: Claude <noreply@anthropic.com>
```

### 4.4 Post-Implementation Validation

After merge, verify:

1. **CI Hardening**: Existing static scan tests still pass
2. **Module Contract**: Existing PRs (2-5) satisfy checklist (they do)
3. **Spec Drift**: Registry accurately reflects all known drifts

---

## PART 5: FUTURE-PROOFING NOTES

### 5.1 Why This Design Is Future-Proof

| Aspect | Design Choice | Future Benefit |
|--------|---------------|----------------|
| **Closed allowlists** | Exceptions require RFC | New modules can't bypass rules |
| **Machine-verifiable** | Hash files, static scans | CI catches violations automatically |
| **Append-only** | No deletion, only addition | Historical audit trail preserved |
| **Hierarchical** | PR1 > Domain > Code | Clear conflict resolution |
| **Language-agnostic** | Patterns for Swift/Python/future | Easy to add Kotlin/Rust/Go |

### 5.2 What This Prevents

| Problem | Prevention Mechanism |
|---------|---------------------|
| "Why ClockProvider?" debates | CI_HARDENING_CONSTITUTION §0 |
| "Is PR5's report law?" confusion | MODULE_CONTRACT_EQUIVALENCE §4 |
| "Plan said X but code is Y" arguments | SPEC_DRIFT_HANDLING + Registry |
| Undocumented changes | Drift registration is mandatory |
| Cross-platform inconsistency | Drift risk matrix flags cross-platform |
| Silent breaking changes | BREAKING category requires RFC |

### 5.3 Extension Points

When adding new languages/platforms:
1. Add prohibitions to CI_HARDENING_CONSTITUTION §1.3
2. Add injection patterns to §2
3. Add allowlist entries to §3.1 if needed
4. Add static scan tests per §4.1

When adding new domains:
1. Follow MODULE_CONTRACT_EQUIVALENCE checklist
2. Register any drifts in DRIFT_REGISTRY
3. Create domain contract with hash file

---

**END OF PROMPT**

---

## APPENDIX: Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────────┐
│                    PR1 CONSTITUTION PATCH SUMMARY                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  PR1-1: CI HARDENING CONSTITUTION                                   │
│  ─────────────────────────────────                                  │
│  • Date() / Timer.scheduledTimer → BANNED                           │
│  • ClockProvider / TimerScheduler → MANDATORY                       │
│  • Static scan tests → GATE                                         │
│                                                                     │
│  PR1-2: MODULE CONTRACT EQUIVALENCE                                 │
│  ──────────────────────────────────                                 │
│  • SSOT Constants file → REQUIRED                                   │
│  • Illegal input/state tests → REQUIRED                             │
│  • State change logging → REQUIRED                                  │
│  • Contract doc + hash → REQUIRED                                   │
│  • Closed-set compliance → REQUIRED                                 │
│                                                                     │
│  PR1-3: SPEC DRIFT HANDLING                                         │
│  ──────────────────────────────                                     │
│  • Plan ≠ SSOT → LEGAL (if registered)                              │
│  • STRICTER/CORRECTED → Self-approval                               │
│  • RELAXED/EXTENDED → Peer review                                   │
│  • Cross-platform/API/Billing → RFC required                        │
│  • DRIFT_REGISTRY.md → Mandatory registration                       │
│                                                                     │
│  FILES TO CREATE:                                                   │
│  • docs/constitution/CI_HARDENING_CONSTITUTION.md                   │
│  • docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md                 │
│  • docs/constitution/SPEC_DRIFT_HANDLING.md                         │
│  • docs/drift/DRIFT_REGISTRY.md                                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```
