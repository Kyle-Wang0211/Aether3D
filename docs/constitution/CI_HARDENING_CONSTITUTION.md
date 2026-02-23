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
from datetime import datetime, timezone
import time

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

## §8 CROSS-PLATFORM PARITY

### §8.1 Scope

This section applies when the same logic runs on multiple platforms:
- iOS ↔ macOS
- iOS ↔ Linux (Server)
- Swift ↔ Python (cross-language)

### §8.2 Byte-Identical Output Requirement

When the same input is processed on different platforms, output MUST be **byte-identical**.

**Applies to:**
| Output Type | Requirement | Verification |
|-------------|-------------|--------------|
| JSON serialization | Byte-identical | SHA256 hash match |
| Hash computations | Byte-identical | Direct comparison |
| Timestamps | UTC, ISO8601, no timezone drift | String match |
| Floating point | Fixed precision (6 decimal places) | String comparison |
| File paths | Normalized (no trailing slash, forward slash only) | String match |

### §8.3 Golden Test Vectors

Every cross-platform algorithm MUST have golden test vectors:

```swift
// iOS Test
func test_crossPlatformParity_jsonSerialization() {
    let input = GoldenTestVectors.jobStateTransition
    let output = JSONEncoder.canonical.encode(input)
    let hash = SHA256.hash(data: output).hexString
    XCTAssertEqual(hash, GoldenTestVectors.expectedHash_jobStateTransition)
}
```

```python
# Linux/Server Test
def test_cross_platform_parity_json_serialization():
    input = GOLDEN_TEST_VECTORS["job_state_transition"]
    output = json.dumps(input, sort_keys=True, separators=(',', ':'))
    hash = hashlib.sha256(output.encode()).hexdigest()
    assert hash == GOLDEN_TEST_VECTORS["expected_hash_job_state_transition"]
```

### §8.4 Golden Vector Registry

**File**: `Core/Constants/GoldenTestVectors.swift` (iOS)
**File**: `server/constants/golden_test_vectors.py` (Server)

Both files MUST contain identical test cases with identical expected outputs.

### §8.5 CI Enforcement

```yaml
# .github/workflows/cross-platform-parity.yml
jobs:
  parity-check:
    strategy:
      matrix:
        os: [macos-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - name: Run Golden Vector Tests
        run: |
          swift test --filter GoldenVectorTests  # macOS
          # OR
          pytest tests/test_golden_vectors.py    # Linux
      - name: Upload Hash Manifest
        uses: actions/upload-artifact@v4
        with:
          name: hash-manifest-${{ matrix.os }}
          path: hash-manifest.json

  compare-hashes:
    needs: parity-check
    runs-on: ubuntu-latest
    steps:
      - name: Download All Manifests
        uses: actions/download-artifact@v4
      - name: Compare Hashes
        run: |
          diff hash-manifest-macos-latest/hash-manifest.json \
               hash-manifest-ubuntu-latest/hash-manifest.json
          if [ $? -ne 0 ]; then
            echo "::error::Cross-platform parity violation detected!"
            exit 1
          fi
```

### §8.6 Violation Response

| Violation | Severity | Action |
|-----------|----------|--------|
| Hash mismatch between platforms | SEV-0 | Block merge, investigate root cause |
| Missing golden vector for cross-platform code | SEV-1 | Add vectors before merge |
| Platform-specific workaround without RFC | SEV-1 | Require RFC or remove |

---

**END OF DOCUMENT**
