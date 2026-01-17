# PR#5 Quality Pre-check: Industrial-Grade Fix Plan

**Status**: BLOCKED - P0 Fixes Required  
**Last Updated**: 2025-01-XX  
**Project Type**: SwiftPM (Package.swift)

---

## Gate Architecture

### Unified Gate Script: `scripts/quality_gate.sh`

**Single entry point** for all quality checks. Called by:
- Pre-push hook: `.git/hooks/pre-push` → `scripts/quality_gate.sh`
- CI workflow: `.github/workflows/quality_precheck.yml` → `scripts/quality_gate.sh`
- Local verification: `./scripts/quality_gate.sh`

**Exit codes**:
- `0`: All gates pass
- `1`: Gate failure (blocks merge/push)

---

## P0 Blockers: Executable Fix Plan

### P0-1: Unified Quality Gate Script

**File**: `scripts/quality_gate.sh` (CREATE)

**Exact Implementation**:
```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== PR#5 Quality Pre-check Gates ==="

# Gate 1: Tests
echo "[1/4] Running tests..."
swift test --filter QualityPreCheck || {
    echo "FAIL: Tests failed"
    exit 1
}

# Gate 2: Lint
echo "[2/4] Running lint..."
"$SCRIPT_DIR/quality_lint.sh" || {
    echo "FAIL: Lint failed"
    exit 1
}

# Gate 3: Fixture verification
echo "[3/4] Verifying golden fixtures..."
swift test --filter QualityPreCheckFixtures || {
    echo "FAIL: Fixture verification failed"
    exit 1
}

# Gate 4: Determinism verification
echo "[4/4] Verifying determinism contracts..."
swift test --filter QualityPreCheckDeterminism || {
    echo "FAIL: Determinism verification failed"
    exit 1
}

echo "=== All gates passed ==="
exit 0
```

**Verification Command**:
```bash
chmod +x scripts/quality_gate.sh
./scripts/quality_gate.sh
```

**Acceptance Criteria**:
- [ ] Script exists and is executable
- [ ] All 4 gates execute in sequence
- [ ] Exit code 1 on any gate failure
- [ ] Exit code 0 only when all gates pass

---

### P0-2: Fix Lint Script (Functional + Strict)

**File**: `scripts/quality_lint.sh` (FIX)

**Exact Fixes**:

#### Fix 1: `?? 0` Check (Line 13)
**Current**: `if grep -r "?? 0" Core/Quality/; then` (fails silently)  
**Fix**:
```bash
echo "Checking for nil coalescing (?? 0)..."
if grep -rn "?? 0" Core/Quality/ --include="*.swift" > /dev/null 2>&1; then
    echo "ERROR: Found '?? 0' pattern - use explicit nil handling"
    grep -rn "?? 0" Core/Quality/ --include="*.swift"
    exit 1
fi
```

#### Fix 2: Date() Check (Line 36)
**Current**: Only warns  
**Fix**:
```bash
echo "Checking for Date() usage in decision windows..."
VIOLATIONS=$(grep -rn "Date()" Core/Quality/State/ Core/Quality/Direction/ Core/Quality/Speed/ Core/Quality/Degradation/ --include="*.swift" 2>/dev/null | grep -v "ts_wallclock_real\|display\|comment\|//" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found Date() usage in decision code (should use MonotonicClock)"
    echo "$VIOLATIONS"
    exit 1
fi
```

#### Fix 3: CanonicalJSON Check (Line 28)
**Current**: Counts lines, not files  
**Fix**:
```bash
echo "Checking CanonicalJSON single file..."
CANONICAL_FILES=$(find Core/Quality/Serialization -name "*CanonicalJSON*.swift" -type f | wc -l | tr -d ' ')
if [ "$CANONICAL_FILES" -ne 1 ]; then
    echo "ERROR: Expected exactly 1 CanonicalJSON file, found $CANONICAL_FILES"
    find Core/Quality/Serialization -name "*CanonicalJSON*.swift" -type f
    exit 1
fi
```

#### Fix 4: ConfidenceGate Bypass Check (Line 43)
**Current**: Placeholder  
**Fix**:
```bash
echo "Checking ConfidenceGate.checkGrayToWhite usage..."
VIOLATIONS=$(grep -rn "ConfidenceGate\.checkGrayToWhite\|checkGrayToWhite" Core/Quality/ --include="*.swift" | grep -v "DecisionPolicy.swift\|//" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: ConfidenceGate.checkGrayToWhite called outside DecisionPolicy"
    echo "$VIOLATIONS"
    exit 1
fi
```

#### Fix 5: JSONEncoder/JSONSerialization Check
**Add**:
```bash
echo "Checking for JSONEncoder/JSONSerialization in audit paths..."
VIOLATIONS=$(grep -rn "JSONEncoder\|JSONSerialization" Core/Quality/Serialization/ --include="*.swift" | grep -v "//\|comment" || true)
if [ -n "$VIOLATIONS" ]; then
    echo "ERROR: Found JSONEncoder/JSONSerialization in audit serialization (SSOT violation)"
    echo "$VIOLATIONS"
    exit 1
fi
```

#### Fix 6: SSOT Duplicate Check
**Add**:
```bash
echo "Checking SSOT implementations..."
# CanonicalJSON
CANONICAL_COUNT=$(find Core -name "*CanonicalJSON*.swift" -type f | wc -l | tr -d ' ')
if [ "$CANONICAL_COUNT" -ne 1 ]; then
    echo "ERROR: Multiple CanonicalJSON implementations found"
    find Core -name "*CanonicalJSON*.swift" -type f
    exit 1
fi

# CoverageDelta encoder
DELTA_ENCODER_COUNT=$(grep -rl "func encode()" Core/Quality/WhiteCommitter/CoverageDelta.swift | wc -l | tr -d ' ')
if [ "$DELTA_ENCODER_COUNT" -ne 1 ]; then
    echo "ERROR: Multiple CoverageDelta encoder implementations"
    exit 1
fi

# DeterministicTriangulator
TRIANGULATOR_COUNT=$(find Core/Quality/Geometry -name "*Triangulator*.swift" -type f | wc -l | tr -d ' ')
if [ "$TRIANGULATOR_COUNT" -ne 1 ]; then
    echo "ERROR: Multiple Triangulator implementations found"
    exit 1
fi
```

**Verification Command**:
```bash
chmod +x scripts/quality_lint.sh
./scripts/quality_lint.sh
```

**Acceptance Criteria**:
- [ ] All checks exit 1 on violation
- [ ] No "Would check" placeholders
- [ ] Excludes build/DerivedData directories
- [ ] Grep logic correct (matches cause exit 1)

---

### P0-3: Seal ConfidenceGate (Nest in DecisionPolicy)

**Files**:
- `Core/Quality/State/DecisionPolicy.swift` (MODIFY)
- `Core/Quality/State/ConfidenceGate.swift` (DELETE or REFACTOR)

**Exact Changes**:

**Step 1**: Move `checkGrayToWhite` into DecisionPolicy as private nested helper:
```swift
// Core/Quality/State/DecisionPolicy.swift
public struct DecisionPolicy {
    // ... existing code ...
    
    /// Private helper for Gray→White confidence check
    /// Compile-time sealed: cannot be called outside this file
    private static func checkGrayToWhiteConfidence(
        criticalMetrics: CriticalMetricBundle,
        fpsTier: FpsTier
    ) -> Bool {
        let threshold = fpsTier == .full ? 0.80 : 0.90
        let brightnessPass = criticalMetrics.brightness.confidence >= threshold
        let laplacianPass = criticalMetrics.laplacian.confidence >= threshold
        return brightnessPass && laplacianPass
    }
    
    public static func canTransition(...) -> (allowed: Bool, reason: String?) {
        // ... existing code ...
        
        // Replace line 45:
        let confidencePass = checkGrayToWhiteConfidence(
            criticalMetrics: criticalMetrics,
            fpsTier: fpsTier
        )
        
        // ... rest of code ...
    }
}
```

**Step 2**: Update ConfidenceGate.swift to remove `checkGrayToWhite`:
```swift
// Keep only checkBlackToGray (public, allowed)
public struct ConfidenceGate {
    public static func checkBlackToGray(...) -> Bool {
        // ... existing implementation ...
    }
    // REMOVE checkGrayToWhite entirely
}
```

**Verification Command**:
```bash
# Should compile
swift build

# Should fail if checkGrayToWhite called elsewhere
grep -rn "checkGrayToWhite\|checkGrayToWhiteConfidence" Core/Quality/ --include="*.swift" | grep -v "DecisionPolicy.swift" | grep -v "//"
# Should return empty (no matches)
```

**Acceptance Criteria**:
- [ ] `checkGrayToWhiteConfidence` is `private static` nested in DecisionPolicy
- [ ] No external references to `checkGrayToWhite` exist
- [ ] Compilation succeeds
- [ ] Lint passes (ConfidenceGate bypass check)

---

### P0-4: Remove `?? 0` Violations

**Files to Fix**:
1. `Core/Quality/Hints/HintSuppression.swift:20`
2. `Core/Quality/Hints/HintSuppression.swift:26`
3. `Core/Quality/Hints/HintController.swift:46`
4. `Core/Quality/Hints/HintController.swift:61`
5. `Core/Quality/State/ConfidenceGate.swift:23`
6. `Core/Quality/State/ConfidenceGate.swift:24`

**Exact Replacements**:

**File 1**: `Core/Quality/Hints/HintSuppression.swift:20`
```swift
// BEFORE:
let count = invalidHintCounts[domain] ?? 0

// AFTER:
let count: Int
if let existing = invalidHintCounts[domain] {
    count = existing
} else {
    count = 0
}
```

**File 1**: `Core/Quality/Hints/HintSuppression.swift:26`
```swift
// BEFORE:
invalidHintCounts[domain] = (invalidHintCounts[domain] ?? 0) + 1

// AFTER:
let current = invalidHintCounts[domain] ?? 0
invalidHintCounts[domain] = current + 1
// OR better:
invalidHintCounts[domain, default: 0] += 1
```

**File 2**: `Core/Quality/Hints/HintController.swift:46`
```swift
// BEFORE:
let count = subtleCountByDirection[directionId] ?? 0

// AFTER:
let count = subtleCountByDirection[directionId] ?? 0  // Wait, this is dictionary access
// Actually, use:
let count: Int
if let existing = subtleCountByDirection[directionId] {
    count = existing
} else {
    count = 0
}
```

**File 2**: `Core/Quality/Hints/HintController.swift:61`
```swift
// BEFORE:
subtleCountByDirection[directionId] = (subtleCountByDirection[directionId] ?? 0) + 1

// AFTER:
subtleCountByDirection[directionId, default: 0] += 1
```

**File 3**: `Core/Quality/State/ConfidenceGate.swift:23-24`
```swift
// BEFORE:
let brightnessPass = brightness?.confidence ?? 0.0 >= 0.7
let focusPass = focus?.confidence ?? 0.0 >= 0.7

// AFTER:
let brightnessPass: Bool
if let brightness = brightness {
    brightnessPass = brightness.confidence >= 0.7
} else {
    brightnessPass = false
}

let focusPass: Bool
if let focus = focus {
    focusPass = focus.confidence >= 0.7
} else {
    focusPass = false
}
```

**Verification Command**:
```bash
grep -rn "?? 0" Core/Quality/ --include="*.swift"
# Should return 0 matches
```

**Acceptance Criteria**:
- [ ] Zero matches for `?? 0` in Core/Quality/
- [ ] Compilation succeeds
- [ ] Lint passes

---

### P0-5: Fix CanonicalJSON SSOT Violation

**File**: `Core/Quality/Serialization/CanonicalJSON.swift` (REWRITE)

**Problem**: Uses JSONEncoder/JSONSerialization (lines 22-35)

**Solution**: Pure Swift canonical encoder

**Exact Implementation**:
```swift
// Remove lines 21-40, replace with:
public static func encode(_ value: Any) throws -> String {
    // Handle Encodable types by manual serialization
    if let encodable = value as? Encodable {
        // Convert to dictionary manually (no JSONEncoder)
        let dict = try encodableToDictionary(encodable)
        return try canonicalize(dict)
    } else if let dict = value as? [String: Any] {
        return try canonicalize(dict)
    } else {
        throw EncodingError.invalidValue(value, ...)
    }
}

private static func encodableToDictionary(_ encodable: Encodable) throws -> [String: Any] {
    // Manual conversion for AuditRecord
    // This is type-specific - implement for each Codable type used
    // For now, handle AuditRecord explicitly
    if let record = encodable as? AuditRecord {
        return [
            "ruleIds": record.ruleIds.map { $0.rawValue },
            "metricSnapshot": [
                "brightness": record.metricSnapshot.brightness as Any,
                "laplacian": record.metricSnapshot.laplacian as Any,
                // ... other fields
            ],
            "decisionPathDigest": record.decisionPathDigest,
            "thresholdVersion": record.thresholdVersion,
            "buildGitSha": record.buildGitSha
        ]
    }
    throw EncodingError.invalidValue(encodable, ...)
}
```

**Alternative (Simpler)**: Remove JSONEncoder path entirely, require `[String: Any]` input:
```swift
public static func encode(_ dict: [String: Any]) throws -> String {
    return try canonicalize(dict)
}
```

**Update Call Sites**:
- `Core/Quality/WhiteCommitter/AuditRecord.swift:toCanonicalJSONBytes()`
- Change to: `try CanonicalJSON.encode(self.toDictionary())`
- Add `toDictionary()` method to AuditRecord

**Verification Command**:
```bash
grep -rn "JSONEncoder\|JSONSerialization" Core/Quality/Serialization/ --include="*.swift" | grep -v "//"
# Should return 0 matches
```

**Acceptance Criteria**:
- [ ] No JSONEncoder/JSONSerialization imports in CanonicalJSON.swift
- [ ] Lint passes (JSONEncoder check)
- [ ] Tests pass (canonical encoding)
- [ ] Golden fixtures verify determinism

---

### P0-6: Implement corruptedEvidence Sticky Persistence

**Files**:
- `Core/Quality/WhiteCommitter/QualityDatabase.swift` (MODIFY)
- `Core/Quality/WhiteCommitter/WhiteCommitter.swift` (MODIFY)
- `Core/Quality/WhiteCommitter/CrashRecovery.swift` (MODIFY)

**Design**: Session-scoped sticky flag table (NOT boolean column in commits)

**Step 1**: Create `session_flags` table in QualityDatabase.swift:
```swift
// In initializeSchema(), add:
let createSessionFlagsSQL = """
CREATE TABLE IF NOT EXISTS session_flags (
    sessionId TEXT PRIMARY KEY,
    corruptedEvidenceSticky BOOLEAN NOT NULL DEFAULT 0,
    firstCorruptCommitSha TEXT,
    ts_first_corrupt_ms INTEGER,
    CHECK(length(firstCorruptCommitSha) = 64 OR firstCorruptCommitSha IS NULL)
)
"""
try execute(createSessionFlagsSQL)
```

**Step 2**: Add methods to QualityDatabase:
```swift
func setCorruptedEvidence(sessionId: String, commitSha: String, timestamp: Int64) throws {
    let sql = """
    INSERT INTO session_flags (sessionId, corruptedEvidenceSticky, firstCorruptCommitSha, ts_first_corrupt_ms)
    VALUES (?, 1, ?, ?)
    ON CONFLICT(sessionId) DO UPDATE SET
        corruptedEvidenceSticky = 1,
        firstCorruptCommitSha = COALESCE(firstCorruptCommitSha, excluded.firstCorruptCommitSha),
        ts_first_corrupt_ms = COALESCE(ts_first_corrupt_ms, excluded.ts_first_corrupt_ms)
    """
    // Execute SQL...
}

func hasCorruptedEvidence(sessionId: String) throws -> Bool {
    let sql = "SELECT corruptedEvidenceSticky FROM session_flags WHERE sessionId = ?"
    // Query and return boolean
}
```

**Step 3**: Check in WhiteCommitter.commitWhite():
```swift
// At start of commitWhite(), before transaction:
let hasCorrupted = try database.hasCorruptedEvidence(sessionId: sessionId)
if hasCorrupted {
    throw CommitError.corruptedEvidence
}
```

**Step 4**: Set in CrashRecovery:
```swift
// In recoverSession(), when corruption detected:
try database.setCorruptedEvidence(
    sessionId: sessionId,
    commitSha: commits[0].commitSHA256,  // First corrupt commit
    timestamp: MonotonicClock.nowMs()
)
```

**Verification Command**:
```bash
swift test --filter testCorruptedEvidenceStickyAndNonRecoverable
```

**Acceptance Criteria**:
- [ ] `session_flags` table exists
- [ ] `commitWhite()` blocks when corruptedEvidence is set
- [ ] State persists across sessions
- [ ] Test verifies stickiness

---

### P0-7: Create Golden Fixtures (Real Bytes + SHA256)

**Directory**: `Tests/QualityPreCheck/Fixtures/` (CREATE)

#### Fixture 1: CoverageDelta Endianness

**File**: `Tests/QualityPreCheck/Fixtures/CoverageDeltaEndiannessFixture.json`
```json
{
  "testCases": [
    {
      "name": "single_cell_gray",
      "input": {
        "changes": [
          {"cellIndex": 100, "newState": 1}
        ]
      },
      "expectedBytesHex": "010000006400000001",
      "expectedSHA256": "a3f5c8d9e2b1a4f6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
    },
    {
      "name": "two_cells_mixed",
      "input": {
        "changes": [
          {"cellIndex": 256, "newState": 2},
          {"cellIndex": 512, "newState": 1}
        ]
      },
      "expectedBytesHex": "0200000000010000020002000001",
      "expectedSHA256": "b4e6d9f0c3a2b5e7d8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1"
    }
  ]
}
```

**Note**: SHA256 values above are placeholders. **MUST compute real values**:
```bash
# Compute real SHA256:
echo -n "010000006400000001" | xxd -r -p | shasum -a 256
```

#### Fixture 2: CoverageGrid Packing

**File**: `Tests/QualityPreCheck/Fixtures/CoverageGridPackingFixture.json`
```json
{
  "testCases": [
    {
      "name": "first_row_mixed",
      "input": {
        "grid": [
          {"row": 0, "col": 0, "state": 0},
          {"row": 0, "col": 1, "state": 1},
          {"row": 0, "col": 2, "state": 2},
          {"row": 0, "col": 3, "state": 0}
        ]
      },
      "expectedBytesHex": "01100200...",
      "expectedSHA256": "..."
    }
  ]
}
```

#### Fixture 3: CanonicalJSON Float Edge Cases

**File**: `Tests/QualityPreCheck/Fixtures/CanonicalJSONFloatFixture.json`
```json
{
  "testCases": [
    {
      "name": "negative_zero",
      "input": -0.0,
      "expected": "0.000000"
    },
    {
      "name": "rounding_boundary_up",
      "input": 0.1234565,
      "expected": "0.123457"
    },
    {
      "name": "rounding_boundary_down",
      "input": 0.1234564,
      "expected": "0.123456"
    },
    {
      "name": "scientific_notation_rejected",
      "input": 1.23e10,
      "shouldReject": true
    }
  ]
}
```

**Verification Command**:
```bash
swift test --filter QualityPreCheckFixtures
```

**Acceptance Criteria**:
- [ ] Fixtures exist in JSON format
- [ ] Real SHA256 values (not placeholders)
- [ ] Tests parse fixtures and verify bytes + hashes
- [ ] Cross-platform determinism verified

---

### P0-8: Replace Placeholder Tests with Real Assertions

**File**: `Tests/QualityPreCheck/WhiteCommitTests.swift` (REWRITE)

**Test Matrix** (17 tests):

#### Test 1: `testWhiteCommitAtomicity_noRecord_noWhite`
```swift
func testWhiteCommitAtomicity_noRecord_noWhite() throws {
    let db = QualityDatabase(dbPath: ":memory:")
    try db.open()
    let committer = WhiteCommitter(database: db)
    
    // Create invalid audit record (missing fields)
    let invalidRecord = AuditRecord(
        ruleIds: [],
        metricSnapshot: MetricSnapshotMinimal(),
        decisionPathDigest: "",
        thresholdVersion: "",
        buildGitSha: ""
    )
    
    let delta = CoverageDelta(changes: [])
    
    XCTAssertThrowsError(try committer.commitWhite(
        sessionId: "test-session",
        auditRecord: invalidRecord,
        coverageDelta: delta
    )) { error in
        XCTAssertTrue(error is CommitError)
    }
}
```

#### Test 2: `testCorruptedEvidenceStickyAndNonRecoverable`
```swift
func testCorruptedEvidenceStickyAndNonRecoverable() throws {
    let db = QualityDatabase(dbPath: ":memory:")
    try db.open()
    
    // Set corruptedEvidence
    try db.setCorruptedEvidence(
        sessionId: "test-session",
        commitSha: "0" * 64,
        timestamp: MonotonicClock.nowMs()
    )
    
    // Verify sticky
    XCTAssertTrue(try db.hasCorruptedEvidence(sessionId: "test-session"))
    
    // Attempt commit - should fail
    let committer = WhiteCommitter(database: db)
    XCTAssertThrowsError(try committer.commitWhite(...)) { error in
        XCTAssertEqual(error as? CommitError, .corruptedEvidence)
    }
    
    // Verify still sticky after failed commit
    XCTAssertTrue(try db.hasCorruptedEvidence(sessionId: "test-session"))
}
```

#### Test 3: `testCoverageDeltaPayloadEndiannessAndHash`
```swift
func testCoverageDeltaPayloadEndiannessAndHash() throws {
    // Load fixture
    let fixture = try loadFixture("CoverageDeltaEndiannessFixture.json")
    
    for testCase in fixture.testCases {
        let delta = CoverageDelta(changes: testCase.input.changes)
        let payload = try delta.encode()
        
        // Verify bytes
        XCTAssertEqual(payload.hexString, testCase.expectedBytesHex)
        
        // Verify SHA256
        let sha256 = try delta.computeSHA256()
        XCTAssertEqual(sha256, testCase.expectedSHA256)
    }
}
```

#### Test 4: `testCanonicalJSONFloatEdgeCases`
```swift
func testCanonicalJSONFloatEdgeCases() throws {
    let fixture = try loadFixture("CanonicalJSONFloatFixture.json")
    
    for testCase in fixture.testCases {
        if testCase.shouldReject {
            XCTAssertThrowsError(try CanonicalJSON.encode(testCase.input))
        } else {
            let result = try CanonicalJSON.encode(testCase.input)
            XCTAssertEqual(result, testCase.expected)
        }
    }
}
```

#### Test 5: `testCommitWhiteRetryOnUniqueConflict`
```swift
func testCommitWhiteRetryOnUniqueConflict() throws {
    // Mock database to simulate UNIQUE conflict
    // Verify retry count <= 3
    // Verify total time <= 300ms
    // Verify exponential backoff
}
```

#### Test 6: `testSessionSeqContinuityAndOrdering_interleavedSessions`
```swift
func testSessionSeqContinuityAndOrdering_interleavedSessions() throws {
    let db = QualityDatabase(dbPath: ":memory:")
    try db.open()
    
    // Insert interleaved commits for 2 sessions
    // Verify each session's session_seq is 1..N continuous
    // Verify recovery orders correctly
}
```

**Verification Command**:
```bash
swift test --filter QualityPreCheck
```

**Acceptance Criteria**:
- [ ] All 17 tests have real assertions
- [ ] No `XCTAssertTrue(true)` placeholders
- [ ] Tests use golden fixtures where applicable
- [ ] All tests pass

---

### P0-9: CI Workflow

**File**: `.github/workflows/quality_precheck.yml` (CREATE)

**Exact Implementation**:
```yaml
name: Quality Pre-check Gates

on:
  pull_request:
    paths:
      - 'Core/Quality/**'
      - 'Tests/QualityPreCheck/**'
      - 'scripts/quality_gate.sh'
      - 'scripts/quality_lint.sh'

jobs:
  quality-gates:
    runs-on: macos-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      
      - name: Setup Swift
        uses: swift-actions/setup-swift@v1
        with:
          swift-version: "5.9"
      
      - name: Run Quality Gates
        run: |
          chmod +x scripts/quality_gate.sh
          ./scripts/quality_gate.sh
```

**Verification**: Create PR, verify CI runs and blocks on failure

**Acceptance Criteria**:
- [ ] Workflow exists
- [ ] Runs on PR
- [ ] Calls `scripts/quality_gate.sh`
- [ ] Blocks merge on failure

---

### P0-10: Pre-push Hook

**File**: `.git/hooks/pre-push` (CREATE)

**Exact Implementation**:
```bash
#!/bin/bash
# Pre-push hook for Quality Pre-check gates

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
"$SCRIPT_DIR/quality_gate.sh"
```

**Installation**:
```bash
chmod +x .git/hooks/pre-push
```

**Acceptance Criteria**:
- [ ] Hook exists and is executable
- [ ] Blocks push on gate failure
- [ ] Allows push on success

---

## P0 Blocker Checklist

**Before merge, verify ALL**:

- [ ] **P0-1**: `scripts/quality_gate.sh` exists, executable, all 4 gates pass
- [ ] **P0-2**: `scripts/quality_lint.sh` functional, no placeholders, exits 1 on violations
- [ ] **P0-3**: ConfidenceGate sealed (nested in DecisionPolicy, private)
- [ ] **P0-4**: Zero `?? 0` violations (grep returns 0 matches)
- [ ] **P0-5**: CanonicalJSON has no JSONEncoder/JSONSerialization (grep returns 0)
- [ ] **P0-6**: corruptedEvidence sticky persistence (session_flags table, blocks commits)
- [ ] **P0-7**: Golden fixtures exist with real SHA256 values
- [ ] **P0-8**: All 17 tests have real assertions (no placeholders)
- [ ] **P0-9**: CI workflow exists and blocks PR on failure
- [ ] **P0-10**: Pre-push hook exists and blocks push on failure

**Verification Command**:
```bash
./scripts/quality_gate.sh && echo "ALL GATES PASS" || echo "GATES FAILED"
```

---

## High-Priority Fixes (P1)

### P1-1: Migration Safety Implementation
**File**: `Core/Quality/WhiteCommitter/QualityDatabase.swift:108`  
**Fix**: Implement `checkAndMigrateSchema()` with lock + rollback  
**Test**: `testSchemaMigrationSafety()`

### P1-2: CoverageGrid Packing Implementation
**File**: `Core/Quality/Models/CoverageGrid.swift`  
**Fix**: Add explicit 2-bit packing method  
**Test**: Use golden fixture

### P1-3: OOM Detection
**Files**: Multiple  
**Fix**: Detect OOM, mark corruptedEvidence  
**Test**: `testOOMMarksCorruptedEvidence()`

### P1-4: MonotonicClock Fallback Fix
**File**: `Core/Quality/Time/MonotonicClock.swift:54`  
**Fix**: Remove Date() fallback or fail on non-Apple platforms

---

## Execution Order (PHASE 2)

1. Create `scripts/quality_gate.sh`
2. Fix `scripts/quality_lint.sh` (all 6 fixes)
3. Create CI workflow
4. Seal ConfidenceGate (nest in DecisionPolicy)
5. Remove `?? 0` violations (6 files)
6. Fix CanonicalJSON (remove JSONEncoder)
7. Implement corruptedEvidence persistence
8. Create golden fixtures (with real SHA256)
9. Replace placeholder tests (17 tests)
10. Run `./scripts/quality_gate.sh` and verify all pass

---

## Notes

- **SHA256 Placeholders**: All fixture SHA256 values MUST be computed from actual bytes
- **Test Coverage**: Each test must assert specific invariants, not just "doesn't crash"
- **Determinism**: Golden fixtures are the ONLY proof of cross-platform determinism
- **CI Enforcement**: If CI doesn't block, gates are not enforced
