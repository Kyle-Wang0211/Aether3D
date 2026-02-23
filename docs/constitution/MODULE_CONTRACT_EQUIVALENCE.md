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

## §8 AUTOMATED CONTRACT VERIFICATION

### §8.1 Contract Linter

Every repository MUST have a contract linter that validates:

| Check | Description | Failure Action |
|-------|-------------|----------------|
| Header presence | "CONSTITUTIONAL CONTRACT" comment exists | Block merge |
| Version format | `PR{N}-{DOMAIN}-{VERSION}` pattern | Block merge |
| Hash freshness | `.hash` file matches current document | Block merge |
| Enum count match | Code enum count = Contract declared count | Block merge |
| No @unknown default | Swift enums have no catch-all | Block merge |

### §8.2 Linter Implementation

**Swift**:
```swift
// Tests/ContractTests/ContractLinterTests.swift
func test_allContractsHaveValidHeader() {
    let contracts = FileManager.default.glob("Core/Constants/*Constants.swift")
    for contract in contracts {
        let content = try! String(contentsOfFile: contract)
        XCTAssert(
            content.contains("CONSTITUTIONAL CONTRACT"),
            "\(contract) missing CONSTITUTIONAL CONTRACT header"
        )
    }
}

func test_allContractsHaveMatchingHash() {
    let docs = FileManager.default.glob("docs/constitution/*.md")
    for doc in docs {
        let hashFile = doc.replacingOccurrences(of: ".md", with: ".hash")
        guard FileManager.default.fileExists(atPath: hashFile) else {
            XCTFail("\(doc) missing .hash file")
            continue
        }
        let content = try! String(contentsOfFile: doc)
        let expectedHash = try! String(contentsOfFile: hashFile).trimmingCharacters(in: .whitespacesAndNewlines)
        let actualHash = SHA256.hash(data: content.data(using: .utf8)!).hexString
        XCTAssertEqual(actualHash, expectedHash, "\(doc) hash mismatch - document modified without updating hash")
    }
}
```

### §8.3 CI Integration

```yaml
# .github/workflows/contract-lint.yml
name: Contract Linter
on: [push, pull_request]

jobs:
  lint-contracts:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Contract Linter
        run: |
          swift test --filter ContractLinterTests
      - name: Verify Hash Freshness
        run: |
          ./scripts/verify-all-hashes.sh
```

### §8.4 Hash Verification Script

**File**: `scripts/verify-all-hashes.sh`

```bash
#!/bin/bash
# Verify all constitution document hashes

set -e
FAILED=0

for md in docs/constitution/*.md; do
    hash_file="${md%.md}.hash"
    if [ ! -f "$hash_file" ]; then
        echo "ERROR: Missing hash file for $md"
        FAILED=1
        continue
    fi

    expected=$(cat "$hash_file" | tr -d '[:space:]')
    actual=$(shasum -a 256 "$md" | cut -d' ' -f1)

    if [ "$expected" != "$actual" ]; then
        echo "ERROR: Hash mismatch for $md"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        FAILED=1
    else
        echo "OK: $md"
    fi
done

exit $FAILED
```

---

## §9 CONTINUOUS HEALTH MONITORING

### §9.1 Daily Health Check

CI MUST run daily health checks (not just on PR):

```yaml
# .github/workflows/daily-health.yml
name: Daily Constitution Health
on:
  schedule:
    - cron: '0 6 * * *'  # 6 AM UTC daily
  workflow_dispatch:  # Manual trigger

jobs:
  health-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify All Hashes
        run: ./scripts/verify-all-hashes.sh
      - name: Count Drift Registry
        run: |
          DRIFT_COUNT=$(grep -c "^| D[0-9]" docs/drift/DRIFT_REGISTRY.md || echo 0)
          echo "drift_count=$DRIFT_COUNT" >> $GITHUB_OUTPUT
      - name: Check for Stale Bypasses
        run: ./scripts/check-overdue-bypasses.sh
      - name: Generate Health Report
        run: ./scripts/generate-health-report.sh
      - name: Upload Health Report
        uses: actions/upload-artifact@v4
        with:
          name: health-report-${{ github.run_id }}
          path: health-report.json
```

### §9.2 Health Metrics

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| Hash mismatches | 0 | - | ≥1 |
| Stale bypasses (>7 days) | 0 | 1-2 | ≥3 |
| Undocumented drifts | 0 | 1-2 | ≥3 |
| Missing golden vectors | 0 | 1-2 | ≥3 |

### §9.3 Health Report Format

**File**: `health-report.json`

```json
{
  "generated_at": "2026-01-28T06:00:00Z",
  "constitution_version": "1.0.0",
  "metrics": {
    "hash_mismatches": 0,
    "stale_bypasses": 0,
    "undocumented_drifts": 0,
    "missing_golden_vectors": 0,
    "total_drifts": 10,
    "total_documents": 5
  },
  "status": "HEALTHY",
  "details": []
}
```

### §9.4 Quarterly Audit

Every quarter, maintainers MUST:
1. Review all drifts in DRIFT_REGISTRY.md
2. Verify all bypasses have been resolved
3. Update this document's version if needed
4. Sign off on health report

**Audit Record Location**: `docs/audits/YYYY-QN-audit.md`

---

**END OF DOCUMENT**
