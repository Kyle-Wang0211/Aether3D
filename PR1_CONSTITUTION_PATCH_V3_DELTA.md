# PR1 Constitution Patch V3 Delta - Improvement Patches

**Version**: 3.0.0-delta
**Date**: 2026-01-28
**Purpose**: Address gaps identified in V2 plan, to be applied ON TOP of V2 implementation

---

## DELTA-1: Hash Files → MANDATORY (Not Optional)

### Problem
V2 plan marks hash files as "可选增强" (optional enhancement), but MODULE_CONTRACT_EQUIVALENCE §2.4 requires hash files as **MANDATORY**.

### Fix
Change implementation order - hash files MUST be created immediately after each document:

```bash
# MANDATORY: Execute after EACH document creation
# Step 1: Create document
# Step 2: Generate hash (IMMEDIATELY, same commit)

# For CI_HARDENING_CONSTITUTION.md
shasum -a 256 docs/constitution/CI_HARDENING_CONSTITUTION.md | cut -d' ' -f1 > docs/constitution/CI_HARDENING_CONSTITUTION.hash

# For MODULE_CONTRACT_EQUIVALENCE.md
shasum -a 256 docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md | cut -d' ' -f1 > docs/constitution/MODULE_CONTRACT_EQUIVALENCE.hash

# For SPEC_DRIFT_HANDLING.md
shasum -a 256 docs/constitution/SPEC_DRIFT_HANDLING.md | cut -d' ' -f1 > docs/constitution/SPEC_DRIFT_HANDLING.hash

# For LOCAL_PREFLIGHT_GATE.md
shasum -a 256 docs/constitution/LOCAL_PREFLIGHT_GATE.md | cut -d' ' -f1 > docs/constitution/LOCAL_PREFLIGHT_GATE.hash

# For EMERGENCY_PROTOCOL.md
shasum -a 256 docs/constitution/EMERGENCY_PROTOCOL.md | cut -d' ' -f1 > docs/constitution/EMERGENCY_PROTOCOL.hash
```

### Updated File List
Add these files to creation list:
- `docs/constitution/CI_HARDENING_CONSTITUTION.hash`
- `docs/constitution/MODULE_CONTRACT_EQUIVALENCE.hash`
- `docs/constitution/SPEC_DRIFT_HANDLING.hash`
- `docs/constitution/LOCAL_PREFLIGHT_GATE.hash`
- `docs/constitution/EMERGENCY_PROTOCOL.hash`

---

## DELTA-2: Content Source Clarification

### Problem
V2 plan lists "内容要点" (content outline) but doesn't specify where Cursor should get the EXACT document content.

### Fix
Add this instruction to the plan:

```
CONTENT SOURCE INSTRUCTION:
━━━━━━━━━━━━━━━━━━━━━━━━━━━
All document content MUST be copied EXACTLY from:

  /Users/kaidongwang/Documents/progecttwo/progect2/progect2/PR1_CONSTITUTION_PATCH_PROMPT_V2.md

Sections:
- PART 1 (§1.2) → CI_HARDENING_CONSTITUTION.md content
- PART 2 (§2.2) → MODULE_CONTRACT_EQUIVALENCE.md content
- PART 3 (§3.2) → SPEC_DRIFT_HANDLING.md content
- PART 3 (§3.3) → DRIFT_REGISTRY.md content

DO NOT paraphrase or summarize. Copy the EXACT markdown content between the ``` fences.
```

---

## DELTA-3: Patch 1/3/5 Complete Content (Missing from V2)

### Problem
V2 plan says CI_HARDENING should have "§8 from Patch 1" and MODULE_CONTRACT should have "§8 from Patch 3 + §9 from Patch 5", but V2 prompt only contains §0-§7. The §8/§9 content was never written.

### Fix
Provide the complete §8/§9 content to append to documents:

---

### PATCH-1: §8 for CI_HARDENING_CONSTITUTION.md

**Append this section AFTER §7 CHANGELOG:**

```markdown
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
```

---

### PATCH-3: §8 for MODULE_CONTRACT_EQUIVALENCE.md

**Append this section AFTER §7 CHANGELOG:**

```markdown
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
```

---

### PATCH-5: §9 for MODULE_CONTRACT_EQUIVALENCE.md

**Append this section AFTER §8:**

```markdown
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
```

---

## DELTA-4: Patch 2 & 4 Complete Document Content

### Problem
V2 plan references LOCAL_PREFLIGHT_GATE.md and EMERGENCY_PROTOCOL.md but doesn't provide the full document content.

### Fix

---

### LOCAL_PREFLIGHT_GATE.md (Patch 2) - Complete Content

**File**: `docs/constitution/LOCAL_PREFLIGHT_GATE.md`

```markdown
# Local Pre-flight Gate

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** All contributors before pushing code

---

## §0 PURPOSE

This document establishes **local pre-flight checks** that MUST pass before `git push`.

**Rationale**:
- CI queues are shared resources
- Failed CI runs waste 5-15 minutes per run
- Obvious errors (syntax, banned patterns) should be caught locally
- "Works on my machine" is not an excuse

---

## §1 MANDATORY LOCAL CHECKS

### §1.1 Check Categories

| Category | Check | Failure = Block Push |
|----------|-------|---------------------|
| Syntax | Swift/Python compiles | Yes |
| Banned Patterns | No Date()/datetime.now() in production | Yes |
| SSOT Integrity | Hash files match documents | Yes |
| Test Smoke | At least unit tests pass | Recommended |

### §1.2 Check Timing

```
Developer writes code
       │
       ▼
git add <files>
       │
       ▼
git commit -m "message"
       │
       ▼
[PRE-PUSH HOOK RUNS] ◄── This document defines what runs here
       │
       ├── Pass → git push proceeds
       │
       └── Fail → Push blocked, developer fixes locally
```

---

## §2 PRE-PUSH HOOK

### §2.1 Installation

**Automatic** (recommended):
```bash
# Run once after clone
./scripts/install-hooks.sh
```

**Manual**:
```bash
cp scripts/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

### §2.2 Hook Implementation

**File**: `.git/hooks/pre-push` (or `scripts/pre-push`)

```bash
#!/bin/bash
# Pre-push hook for PR1 Constitution compliance
# Source: LOCAL_PREFLIGHT_GATE.md §2.2

set -e

echo "╔════════════════════════════════════════╗"
echo "║     LOCAL PRE-FLIGHT CHECK             ║"
echo "╚════════════════════════════════════════╝"

FAILED=0

# §1.1 Check 1: Syntax
echo "▶ [1/4] Checking Swift syntax..."
if ! swift build --target Core 2>/dev/null; then
    echo "  ✗ Swift build failed"
    FAILED=1
else
    echo "  ✓ Swift syntax OK"
fi

# §1.1 Check 2: Banned Patterns
echo "▶ [2/4] Scanning for banned patterns..."
if ! ./scripts/scan-prohibited-patterns.sh; then
    echo "  ✗ Banned patterns found"
    FAILED=1
else
    echo "  ✓ No banned patterns"
fi

# §1.1 Check 3: SSOT Integrity
echo "▶ [3/4] Verifying SSOT integrity..."
if ! ./scripts/verify-ssot-integrity.sh; then
    echo "  ✗ SSOT integrity failed"
    FAILED=1
else
    echo "  ✓ SSOT integrity OK"
fi

# §1.1 Check 4: Smoke Test (optional but recommended)
echo "▶ [4/4] Running smoke tests..."
if swift test --filter SmokeTests 2>/dev/null; then
    echo "  ✓ Smoke tests passed"
else
    echo "  ⚠ Smoke tests failed (warning only)"
fi

echo ""
if [ $FAILED -ne 0 ]; then
    echo "╔════════════════════════════════════════╗"
    echo "║  ✗ PRE-FLIGHT FAILED - PUSH BLOCKED    ║"
    echo "╚════════════════════════════════════════╝"
    echo ""
    echo "Fix the issues above and try again."
    exit 1
else
    echo "╔════════════════════════════════════════╗"
    echo "║  ✓ PRE-FLIGHT PASSED - PUSH ALLOWED    ║"
    echo "╚════════════════════════════════════════╝"
    exit 0
fi
```

---

## §3 SUPPORT SCRIPTS

### §3.1 Prohibited Pattern Scanner

**File**: `scripts/scan-prohibited-patterns.sh`

```bash
#!/bin/bash
# Scan for CI_HARDENING_CONSTITUTION prohibited patterns
# Source: LOCAL_PREFLIGHT_GATE.md §3.1

set -e

VIOLATIONS=0

# Swift prohibited patterns
SWIFT_PATTERNS=(
    'Date()'
    'Timer\.scheduledTimer'
    'DispatchQueue.*asyncAfter'
    'Thread\.sleep'
    'Task\.sleep'
)

# Python prohibited patterns
PYTHON_PATTERNS=(
    'datetime\.now()'
    'datetime\.utcnow()'
    'time\.time()'
    'time\.sleep('
)

echo "Scanning Swift files..."
for pattern in "${SWIFT_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" --include="*.swift" Sources/ 2>/dev/null | grep -v "Default.*Provider" | grep -v "Tests/" || true)
    if [ -n "$matches" ]; then
        echo "VIOLATION: $pattern found:"
        echo "$matches"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

echo "Scanning Python files..."
for pattern in "${PYTHON_PATTERNS[@]}"; do
    matches=$(grep -rn "$pattern" --include="*.py" src/ 2>/dev/null | grep -v "default.*provider" | grep -v "test_" || true)
    if [ -n "$matches" ]; then
        echo "VIOLATION: $pattern found:"
        echo "$matches"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
done

if [ $VIOLATIONS -gt 0 ]; then
    echo ""
    echo "Found $VIOLATIONS violation(s). See CI_HARDENING_CONSTITUTION.md §1."
    exit 1
fi

echo "No prohibited patterns found."
exit 0
```

### §3.2 SSOT Integrity Verifier

**File**: `scripts/verify-ssot-integrity.sh`

```bash
#!/bin/bash
# Verify SSOT document hash integrity
# Source: LOCAL_PREFLIGHT_GATE.md §3.2

set -e

FAILED=0

# Check constitution documents
for md in docs/constitution/*.md; do
    [ -f "$md" ] || continue

    hash_file="${md%.md}.hash"
    if [ ! -f "$hash_file" ]; then
        # Hash file not required for all documents yet
        continue
    fi

    expected=$(cat "$hash_file" | tr -d '[:space:]')
    actual=$(shasum -a 256 "$md" | cut -d' ' -f1)

    if [ "$expected" != "$actual" ]; then
        echo "INTEGRITY VIOLATION: $md"
        echo "  Document has been modified without updating hash"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        echo "  Fix: shasum -a 256 $md | cut -d' ' -f1 > $hash_file"
        FAILED=1
    fi
done

# Check constants files have headers
for swift in Core/Constants/*Constants.swift; do
    [ -f "$swift" ] || continue

    if ! grep -q "CONSTITUTIONAL CONTRACT" "$swift"; then
        echo "HEADER MISSING: $swift"
        echo "  Constants file missing 'CONSTITUTIONAL CONTRACT' header"
        FAILED=1
    fi
done

if [ $FAILED -ne 0 ]; then
    exit 1
fi

echo "SSOT integrity verified."
exit 0
```

---

## §4 CI INTEGRATION

### §4.1 Preflight Job

CI SHOULD mirror local checks:

```yaml
# .github/workflows/ci.yml
jobs:
  preflight:
    name: Pre-flight Checks
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Scan Prohibited Patterns
        run: ./scripts/scan-prohibited-patterns.sh
      - name: Verify SSOT Integrity
        run: ./scripts/verify-ssot-integrity.sh
```

### §4.2 Feedback Loop

If CI fails but local passed:
1. Developer's hook may be outdated
2. Run `./scripts/install-hooks.sh` to update
3. If still mismatch, report to maintainers

---

## §5 DEVELOPER EXPERIENCE

### §5.1 Speed Requirement

Local pre-flight MUST complete in **< 30 seconds** on average hardware.

If checks take longer:
- Move slow checks to CI-only
- Optimize scripts
- Use incremental checking

### §5.2 Clear Error Messages

Every failure MUST include:
1. What failed
2. Where to look (file:line if possible)
3. How to fix (link to constitution section)

### §5.3 IDE Integration (Optional)

For VSCode:
```json
// .vscode/tasks.json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Pre-flight Check",
      "type": "shell",
      "command": "./scripts/pre-push",
      "problemMatcher": []
    }
  ]
}
```

---

## §6 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial constitution |

---

**END OF DOCUMENT**
```

---

### EMERGENCY_PROTOCOL.md (Patch 4) - Complete Content

**File**: `docs/constitution/EMERGENCY_PROTOCOL.md`

```markdown
# Emergency Protocol

**Document Version:** 1.0.0
**Created Date:** 2026-01-28
**Status:** IMMUTABLE (append-only after merge)
**Scope:** Production emergencies requiring constitution bypass

---

## §0 PURPOSE

This document defines **when and how** constitutional rules may be temporarily bypassed during genuine emergencies.

**Core Principle**: Constitution rules exist to prevent problems. But when production is on fire, we need a legal escape hatch that maintains accountability.

---

## §1 EMERGENCY CLASSIFICATION

### §1.1 Severity Levels

| Level | Name | Definition | Example |
|-------|------|------------|---------|
| E0 | CRITICAL | Production down, revenue loss, data loss risk | Server crash, payment failures |
| E1 | SEVERE | Major feature broken, significant user impact | Auth broken, uploads failing |
| E2 | MODERATE | Feature degraded, workaround exists | Slow performance, UI glitch |
| E3 | MINOR | Cosmetic issue, no functional impact | Wrong color, typo |

### §1.2 Bypass Eligibility

| Level | Constitution Bypass Allowed? |
|-------|------------------------------|
| E0 | Yes, with immediate post-fix |
| E1 | Yes, with 24-hour post-fix |
| E2 | No, use normal process |
| E3 | No, use normal process |

---

## §2 BYPASS AUTHORIZATION

### §2.1 Who Can Authorize

| Level | Authorizer |
|-------|------------|
| E0 | Any maintainer (can self-authorize if sole responder) |
| E1 | 2 maintainers (or 1 maintainer + 1 senior engineer) |

### §2.2 Authorization Record

Every bypass MUST be recorded:

```markdown
## Emergency Bypass Record

- **Bypass ID**: EB-YYYY-MM-DD-NNN
- **Level**: E0/E1
- **Authorized by**: @username
- **Time**: ISO8601 timestamp
- **Rules bypassed**: [List specific constitution sections]
- **Justification**: [1-2 sentences]
- **Tracking issue**: #NNN
```

---

## §3 BYPASS MECHANISM

### §3.1 Git Commit Format

Emergency commits MUST use this format:

```
EMERGENCY[E0]: Fix production crash in payment processing

BYPASS: CI_HARDENING_CONSTITUTION §1.1 (Date() used directly)
JUSTIFICATION: ClockProvider not available in hotfix branch
TRACKING: #1234
AUTHORIZED: @maintainer1
EXPIRES: 2026-01-30T00:00:00Z

[actual commit message]

Co-Authored-By: Claude <noreply@anthropic.com>
```

### §3.2 CI Bypass

For E0 only, CI checks may be skipped:

```bash
# Only for E0, with justification in commit message
git push --no-verify  # Skip pre-push hook

# In GitHub, use emergency label to skip required checks
# Requires admin permission
```

### §3.3 Bypass Tracking File

**File**: `docs/emergencies/ACTIVE_BYPASSES.md`

```markdown
# Active Emergency Bypasses

| Bypass ID | Level | Created | Expires | Rules | Issue | Status |
|-----------|-------|---------|---------|-------|-------|--------|
| EB-2026-01-28-001 | E0 | 2026-01-28 | 2026-01-30 | CI_HARD §1.1 | #1234 | ACTIVE |

## Resolution Queue

Bypasses MUST be resolved by expiry date or escalated.
```

---

## §4 RECOVERY REQUIREMENTS

### §4.1 Mandatory Recovery Timeline

| Level | Fix Deployed | Constitution Compliant | Post-mortem |
|-------|--------------|------------------------|-------------|
| E0 | ASAP | Within 48 hours | Within 7 days |
| E1 | Within 4 hours | Within 7 days | Within 14 days |

### §4.2 Recovery Commit

After emergency fix, a follow-up commit MUST:
1. Make the code constitution-compliant
2. Reference the bypass ID
3. Close the tracking issue

```
fix(emergency): Make payment fix constitution-compliant

Resolves emergency bypass EB-2026-01-28-001:
- Replaced Date() with ClockProvider injection
- Added missing tests

Closes #1234
```

### §4.3 Overdue Bypass Detection

CI MUST check for overdue bypasses daily:

```bash
#!/bin/bash
# scripts/check-overdue-bypasses.sh

TODAY=$(date -u +%Y-%m-%dT%H:%M:%SZ)

grep "| ACTIVE |" docs/emergencies/ACTIVE_BYPASSES.md | while read line; do
    EXPIRES=$(echo "$line" | cut -d'|' -f5 | tr -d ' ')
    if [[ "$TODAY" > "$EXPIRES" ]]; then
        BYPASS_ID=$(echo "$line" | cut -d'|' -f2 | tr -d ' ')
        echo "::error::OVERDUE BYPASS: $BYPASS_ID expired on $EXPIRES"
        exit 1
    fi
done
```

---

## §5 POST-MORTEM

### §5.1 Required Sections

Every E0/E1 post-mortem MUST include:

```markdown
# Post-Mortem: EB-YYYY-MM-DD-NNN

## Summary
[1-2 sentences]

## Timeline
| Time | Event |
|------|-------|
| ... | ... |

## Root Cause
[What actually broke and why]

## Constitution Rules Bypassed
| Rule | Why Bypassed | How Resolved |
|------|--------------|--------------|
| ... | ... | ... |

## Prevention
[What changes prevent recurrence]

## Action Items
- [ ] Item 1
- [ ] Item 2
```

### §5.2 Post-Mortem Storage

**Location**: `docs/emergencies/postmortems/EB-YYYY-MM-DD-NNN.md`

---

## §6 ABUSE PREVENTION

### §6.1 Abuse Indicators

| Indicator | Threshold | Action |
|-----------|-----------|--------|
| Bypasses per month | > 3 | Mandatory process review |
| Same rule bypassed | > 2 times | Rule may need amendment |
| Overdue recoveries | > 1 | Escalate to leadership |
| Missing post-mortems | Any | Block future bypasses for author |

### §6.2 Accountability

- All bypasses are logged permanently
- Bypass history is reviewed quarterly
- Repeat offenders lose self-authorization privilege

---

## §7 CHANGELOG

| Version | Date | Change |
|---------|------|--------|
| 1.0.0 | 2026-01-28 | Initial protocol |

---

**END OF DOCUMENT**
```

---

## DELTA-5: INDEX.md Format Verification

### Problem
Plan assumes INDEX.md has a specific section structure without verifying.

### Fix
Before updating INDEX.md, Cursor MUST:

```bash
# Step 1: Read current INDEX.md structure
cat docs/constitution/INDEX.md

# Step 2: Identify the correct insertion point
# Look for "Core Documents" or similar section

# Step 3: Match existing entry format exactly
# Copy the format of existing entries
```

### Expected INDEX.md Entry Format

Based on typical constitution index format, entries should look like:

```markdown
## Constitution Documents

| Document | Purpose | Status |
|----------|---------|--------|
| [SSOT_FOUNDATION_v1.1.md](SSOT_FOUNDATION_v1.1.md) | Core SSOT principles | IMMUTABLE |
| [CI_HARDENING_CONSTITUTION.md](CI_HARDENING_CONSTITUTION.md) | CI hardening rules | IMMUTABLE |
| [MODULE_CONTRACT_EQUIVALENCE.md](MODULE_CONTRACT_EQUIVALENCE.md) | Domain contract validity | IMMUTABLE |
| [SPEC_DRIFT_HANDLING.md](SPEC_DRIFT_HANDLING.md) | Spec drift protocol | IMMUTABLE |
| [LOCAL_PREFLIGHT_GATE.md](LOCAL_PREFLIGHT_GATE.md) | Local pre-flight checks | IMMUTABLE |
| [EMERGENCY_PROTOCOL.md](EMERGENCY_PROTOCOL.md) | Emergency bypass protocol | IMMUTABLE |
```

**OR** if using bullet list format:

```markdown
- [CI_HARDENING_CONSTITUTION.md](CI_HARDENING_CONSTITUTION.md) - CI硬化规则 (IMMUTABLE)
  - **Who depends:** All production code
  - **What breaks if violated:** Test determinism, CI reliability
  - **Why exists:** Prevents time-dependent bugs
```

---

## DELTA-6: Scripts Phase Decision

### Problem
Plan lists 6 scripts but unclear if they should be created in this PR or deferred.

### Fix
Explicitly mark scripts as **Phase 1** (create now) or **Phase 2** (defer):

| Script | Phase | Reason |
|--------|-------|--------|
| `scripts/scan-prohibited-patterns.sh` | **Phase 1** | Required by LOCAL_PREFLIGHT_GATE §3.1 |
| `scripts/verify-ssot-integrity.sh` | **Phase 1** | Required by LOCAL_PREFLIGHT_GATE §3.2 |
| `scripts/install-hooks.sh` | **Phase 1** | Required by LOCAL_PREFLIGHT_GATE §2.1 |
| `scripts/verify-all-hashes.sh` | **Phase 1** | Required by MODULE_CONTRACT §8.4 |
| `scripts/check-overdue-bypasses.sh` | **Phase 1** | Required by EMERGENCY_PROTOCOL §4.3 |
| `scripts/lint-contracts.sh` | Phase 2 | Nice-to-have, not blocking |
| `scripts/generate-health-report.sh` | Phase 2 | Nice-to-have, not blocking |
| `scripts/verify-constitution-health.sh` | Phase 2 | Nice-to-have, not blocking |

### install-hooks.sh Content

**File**: `scripts/install-hooks.sh`

```bash
#!/bin/bash
# Install git hooks for PR1 Constitution compliance
# Source: LOCAL_PREFLIGHT_GATE.md §2.1

set -e

HOOK_DIR=".git/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing git hooks..."

# Install pre-push hook
if [ -f "$HOOK_DIR/pre-push" ]; then
    echo "Backing up existing pre-push hook..."
    mv "$HOOK_DIR/pre-push" "$HOOK_DIR/pre-push.backup"
fi

cp "$SCRIPT_DIR/pre-push" "$HOOK_DIR/pre-push"
chmod +x "$HOOK_DIR/pre-push"

echo "✓ pre-push hook installed"
echo ""
echo "Hooks installed successfully!"
echo "Run './scripts/pre-push' manually to test."
```

---

## SUMMARY: Updated Implementation Order

```
PHASE 1: Core Documents (with hash files)
├── 1. docs/constitution/CI_HARDENING_CONSTITUTION.md (V2 §0-§7 + DELTA-3 §8)
├── 2. docs/constitution/CI_HARDENING_CONSTITUTION.hash
├── 3. docs/constitution/MODULE_CONTRACT_EQUIVALENCE.md (V2 §0-§7 + DELTA-3 §8-§9)
├── 4. docs/constitution/MODULE_CONTRACT_EQUIVALENCE.hash
├── 5. docs/constitution/SPEC_DRIFT_HANDLING.md (V2 content)
├── 6. docs/constitution/SPEC_DRIFT_HANDLING.hash
├── 7. docs/drift/ directory
└── 8. docs/drift/DRIFT_REGISTRY.md (V2 content)

PHASE 2: Patch Documents (with hash files)
├── 9. docs/constitution/LOCAL_PREFLIGHT_GATE.md (DELTA-4 content)
├── 10. docs/constitution/LOCAL_PREFLIGHT_GATE.hash
├── 11. docs/constitution/EMERGENCY_PROTOCOL.md (DELTA-4 content)
├── 12. docs/constitution/EMERGENCY_PROTOCOL.hash
└── 13. docs/emergencies/ACTIVE_BYPASSES.md (empty template)

PHASE 3: Support Scripts
├── 14. scripts/scan-prohibited-patterns.sh
├── 15. scripts/verify-ssot-integrity.sh
├── 16. scripts/verify-all-hashes.sh
├── 17. scripts/install-hooks.sh
├── 18. scripts/pre-push
└── 19. scripts/check-overdue-bypasses.sh

PHASE 4: Index Update
└── 20. docs/constitution/INDEX.md (add 5 new entries, matching existing format)

PHASE 5: Verification
├── ls -la docs/constitution/*.md docs/constitution/*.hash
├── ls -la docs/drift/
├── ls -la scripts/*.sh
├── ./scripts/verify-all-hashes.sh
├── swift build
└── swift test --filter CaptureStaticScanTests
```

---

## Git Commit Message (Updated)

```
feat(pr1): add constitutional amendments with full automation support

PR1-1: CI_HARDENING_CONSTITUTION.md
- Prohibit Date()/Timer.scheduledTimer in production
- Mandate ClockProvider/TimerScheduler injection
- Add §8 cross-platform parity requirements

PR1-2: MODULE_CONTRACT_EQUIVALENCE.md
- Define domain contract validity (5-point checklist)
- Add §8 automated contract verification
- Add §9 continuous health monitoring

PR1-3: SPEC_DRIFT_HANDLING.md + DRIFT_REGISTRY.md
- Legitimize plan-to-implementation drift
- Register 10 existing drifts (D001-D010)

Patch 2: LOCAL_PREFLIGHT_GATE.md
- Pre-push hook with 4 mandatory checks
- Support scripts for local verification

Patch 4: EMERGENCY_PROTOCOL.md
- E0/E1 emergency bypass procedures
- Mandatory recovery timeline
- Abuse prevention mechanisms

All documents include .hash files per MODULE_CONTRACT §2.4.

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

**END OF DELTA PATCH**
