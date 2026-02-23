# PR#5 Quality Pre-check: P0 Blocker Checklist

**Status**: BLOCKED  
**Verification**: Run `./scripts/quality_gate.sh` after each fix

---

## P0 Blockers (Must Fix Before Merge)

### ✅ P0-1: Unified Quality Gate Script
- [ ] File: `scripts/quality_gate.sh` exists
- [ ] Executable (`chmod +x`)
- [ ] Runs 4 gates: tests + lint + fixtures + determinism
- [ ] Exit code 1 on failure, 0 on success
- [ ] Command: `./scripts/quality_gate.sh` passes

**Gate**: `scripts/quality_gate.sh`

---

### ✅ P0-2: Functional Lint Script
- [ ] File: `scripts/quality_lint.sh` fixed
- [ ] `?? 0` check exits 1 on match
- [ ] `Date()` check exits 1 (not warn)
- [ ] CanonicalJSON check counts files (not lines)
- [ ] ConfidenceGate bypass check implemented
- [ ] JSONEncoder/JSONSerialization check implemented
- [ ] SSOT duplicate checks implemented
- [ ] No "Would check" placeholders
- [ ] Command: `./scripts/quality_lint.sh` passes

**Gate**: Part of `scripts/quality_gate.sh`

---

### ✅ P0-3: ConfidenceGate Sealed
- [ ] `checkGrayToWhiteConfidence` is `private static` nested in DecisionPolicy
- [ ] Removed from ConfidenceGate.swift
- [ ] No external references (grep returns 0)
- [ ] Compilation succeeds
- [ ] Lint passes

**Files**: 
- `Core/Quality/State/DecisionPolicy.swift`
- `Core/Quality/State/ConfidenceGate.swift`

**Verification**: `grep -rn "checkGrayToWhite" Core/Quality/ --include="*.swift" | grep -v "DecisionPolicy.swift" | grep -v "//"` returns empty

---

### ✅ P0-4: Remove `?? 0` Violations
- [ ] Fixed: `Core/Quality/Hints/HintSuppression.swift:20,26`
- [ ] Fixed: `Core/Quality/Hints/HintController.swift:46,61`
- [ ] Fixed: `Core/Quality/State/ConfidenceGate.swift:23,24`
- [ ] Zero matches: `grep -rn "?? 0" Core/Quality/ --include="*.swift"` returns empty
- [ ] Compilation succeeds
- [ ] Lint passes

**Gate**: `scripts/quality_lint.sh` (?? 0 check)

---

### ✅ P0-5: Fix CanonicalJSON SSOT
- [ ] Removed JSONEncoder/JSONSerialization from `Core/Quality/Serialization/CanonicalJSON.swift`
- [ ] Pure Swift canonical encoder implemented
- [ ] Zero matches: `grep -rn "JSONEncoder\|JSONSerialization" Core/Quality/Serialization/ --include="*.swift" | grep -v "//"` returns empty
- [ ] Tests pass
- [ ] Golden fixtures verify determinism

**Files**: `Core/Quality/Serialization/CanonicalJSON.swift`

**Gate**: `scripts/quality_lint.sh` (JSONEncoder check) + tests

---

### ✅ P0-6: corruptedEvidence Sticky Persistence
- [ ] `session_flags` table created in QualityDatabase
- [ ] `setCorruptedEvidence()` method implemented
- [ ] `hasCorruptedEvidence()` method implemented
- [ ] `commitWhite()` checks flag before transaction
- [ ] `CrashRecovery` sets flag on corruption
- [ ] Test: `testCorruptedEvidenceStickyAndNonRecoverable()` passes

**Files**:
- `Core/Quality/WhiteCommitter/QualityDatabase.swift`
- `Core/Quality/WhiteCommitter/WhiteCommitter.swift`
- `Core/Quality/WhiteCommitter/CrashRecovery.swift`

**Gate**: Test + manual verification

---

### ✅ P0-7: Golden Fixtures (Real SHA256)
- [ ] `Tests/QualityPreCheck/Fixtures/CoverageDeltaEndiannessFixture.json` exists
- [ ] `Tests/QualityPreCheck/Fixtures/CoverageGridPackingFixture.json` exists
- [ ] `Tests/QualityPreCheck/Fixtures/CanonicalJSONFloatFixture.json` exists
- [ ] All SHA256 values are REAL (computed from bytes, not placeholders)
- [ ] Tests parse fixtures and verify bytes + hashes
- [ ] Command: `swift test --filter QualityPreCheckFixtures` passes

**Gate**: `scripts/quality_gate.sh` (fixture verification)

---

### ✅ P0-8: Real Tests (No Placeholders)
- [ ] All 17 tests in `Tests/QualityPreCheck/WhiteCommitTests.swift` have real assertions
- [ ] Zero `XCTAssertTrue(true)` placeholders
- [ ] Tests use golden fixtures where applicable
- [ ] Command: `swift test --filter QualityPreCheck` passes

**Gate**: `scripts/quality_gate.sh` (tests)

---

### ✅ P0-9: CI Workflow
- [ ] File: `.github/workflows/quality_precheck.yml` exists
- [ ] Runs on pull_request
- [ ] Calls `scripts/quality_gate.sh`
- [ ] Blocks merge on failure
- [ ] Verified: Create PR, CI runs and blocks

**Gate**: CI enforcement

---

### ✅ P0-10: Pre-push Hook
- [ ] File: `.git/hooks/pre-push` exists
- [ ] Executable (`chmod +x`)
- [ ] Calls `scripts/quality_gate.sh`
- [ ] Blocks push on failure
- [ ] Verified: Attempt push, hook blocks

**Gate**: Pre-push enforcement

---

## Final Verification

**Command**:
```bash
./scripts/quality_gate.sh
```

**Expected Output**:
```
=== PR#5 Quality Pre-check Gates ===
[1/4] Running tests...
Test Suite 'QualityPreCheck' passed
[2/4] Running lint...
Lint checks completed successfully
[3/4] Verifying golden fixtures...
Test Suite 'QualityPreCheckFixtures' passed
[4/4] Verifying determinism contracts...
Test Suite 'QualityPreCheckDeterminism' passed
=== All gates passed ===
```

**Exit Code**: `0`

---

## Merge Criteria

**ALL P0 blockers must be ✅ before merge consideration.**

**Verification**: Run `./scripts/quality_gate.sh` and verify exit code 0.

