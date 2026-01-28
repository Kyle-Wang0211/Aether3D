# PR#5.1: Database Integration Fix Plan

**Parent PR**: PR#5 Quality Pre-check  
**Status**: Required before PR#5 merge  
**Scope**: DB integration + test harness + SQLite transactional correctness only

---

## Scope

**In Scope**:
- Fix SQLite constraint violations (code 19) in tests
- Fix retry loop exhaustion (maxRetriesExceeded)
- Ensure deterministic test isolation (unique DB per test)
- Fix transaction boundaries for session_seq computation
- Improve error classification (retryable vs non-retryable)

**Out of Scope** (NON-NEGOTIABLE):
- ❌ No policy changes (DecisionPolicy, thresholds, FPS tiers)
- ❌ No SSOT refactors (CanonicalJSON, CoverageDelta, etc.)
- ❌ No threshold changes (confidence, stability)
- ❌ No determinism contract changes (endianness, float formatting, sorting)

---

## Non-Goals

This PR fixes **test harness and database integration only**. It does NOT:
- Change any business logic
- Modify evidence layer semantics
- Alter audit trail structure
- Change hash chain computation
- Modify corruptedEvidence behavior

---

## Reproduction

**Exact Command**:
```bash
cd /Users/kaidongwang/Documents/progecttwo/progect2/progect2
swift test --filter WhiteCommitTests
```

**Expected**: All 18 tests pass  
**Actual**: 11 pass, 7 fail

---

## Failing Tests Inventory

**PR5.1 Enhanced Error Reporting**: All errors now include primary code, extended code, SQL operation tag, and error message.

### Test 1: `testCommitHashChainSessionScopedPrevPointer`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_COMMIT", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `WhiteCommitter.swift:39`
- **Suspected Constraint**: UNIQUE(sessionId, session_seq) - duplicate session_seq
- **Root Cause Hypothesis**: session_seq computation race condition or transaction scope issue

### Test 2: `testCommitUsesMonotonicMs`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_COMMIT", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `WhiteCommitter.swift:39`
- **Suspected Constraint**: UNIQUE(sessionId, session_seq) or CHECK(session_seq >= 1)
- **Root Cause Hypothesis**: Same as Test 1

### Test 3: `testCorruptedEvidenceStickyAndNonRecoverable`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_SESSION_FLAGS", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `QualityDatabase.swift:390`
- **Suspected Constraint**: CHECK(length(firstCorruptCommitSha) = 64 OR firstCorruptCommitSha IS NULL)
- **Root Cause Hypothesis**: Invalid SHA length or CHECK constraint validation timing

### Test 4: `testCrashRecoveryDetectsSequenceGap`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_COMMIT", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `WhiteCommitter.swift:39`
- **Suspected Constraint**: UNIQUE(sessionId, session_seq)
- **Root Cause Hypothesis**: Same as Test 1

### Test 5: `testCrashRecoveryVerifiesHashChain`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_COMMIT", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `WhiteCommitter.swift:39`
- **Suspected Constraint**: UNIQUE(sessionId, session_seq)
- **Root Cause Hypothesis**: Same as Test 1

### Test 6: `testSessionSeqContinuityAndOrdering_interleavedSessions`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_COMMIT", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `WhiteCommitter.swift:39`
- **Suspected Constraint**: UNIQUE(sessionId, session_seq)
- **Root Cause Hypothesis**: Test isolation failure (shared DB state across interleaved sessions)

### Test 7: `testWhiteCommitAtomicity_noRecord_noWhite`
- **Error**: `databaseUnknown(code: 19, extendedCode: <TBD>, sqlOperation: "INSERT_COMMIT", errorMessage: <TBD>)` - SQLITE_CONSTRAINT
- **Location**: `WhiteCommitter.swift:39`
- **Suspected Constraint**: UNIQUE(sessionId, session_seq) or CHECK(session_seq >= 1)
- **Root Cause Hypothesis**: Same as Test 1

**Summary**: All 7 tests fail with `SQLITE_CONSTRAINT (code: 19)`. Enhanced error reporting now surfaces:
- Primary error code: 19 (SQLITE_CONSTRAINT)
- Extended error code: Available via `sqlite3_extended_errcode()` (will show specific constraint type)
- SQL operation tag: "INSERT_COMMIT" or "INSERT_SESSION_FLAGS"
- Error message: Available via `sqlite3_errmsg()` (will show violated constraint name)

---

## Root-Cause Hypotheses (Ranked by Evidence)

**PR5.1 Enhanced Error Reporting**: All errors now include extended codes and SQL operation tags. Run tests to get specific constraint violation details.

### Hypothesis 1: session_seq Computation Race Condition (HIGHEST CONFIDENCE)
**Evidence**:
- All 7 tests fail with `SQLITE_CONSTRAINT (code: 19, sqlOperation: "INSERT_COMMIT")`
- UNIQUE constraint: `UNIQUE(sessionId, session_seq)` likely violated
- Pattern: Multiple commits for same sessionId compute same session_seq

**Likely Cause**:
- `session_seq` computation (`SELECT COALESCE(MAX(session_seq),0)+1`) happens inside transaction
- BUT: Transaction may not be properly isolated (BEGIN IMMEDIATE not acquiring exclusive lock)
- OR: Test isolation failure - multiple test runs share DB state
- OR: Transaction rollback leaves session_seq computation inconsistent

**Fix Strategy** (ALLOWED):
- Ensure BEGIN IMMEDIATE acquires exclusive lock before session_seq computation
- Verify transaction boundaries: session_seq computation + insert must be atomic
- Add explicit lock acquisition verification

**Fix Strategy** (FORBIDDEN):
- ❌ Disable UNIQUE constraint
- ❌ Use AUTOINCREMENT instead of manual sequence
- ❌ Loosen schema (remove UNIQUE constraint)

---

### Hypothesis 2: Test Isolation Failure (HIGH CONFIDENCE)
**Evidence**:
- Test 6 (`testSessionSeqContinuityAndOrdering_interleavedSessions`) fails with constraint violation
- Pattern: Interleaved sessions may share DB state
- Previous test's commits may affect next test

**Likely Cause**:
- Test isolation improved (unique temp DB files), but cleanup may be incomplete
- OR: Test setup/teardown timing issue
- OR: Concurrent test execution (if tests run in parallel)

**Fix Strategy** (ALLOWED):
- Verify each test uses isolated DB file (already implemented)
- Ensure proper cleanup in tearDown()
- Add explicit DB file existence check before test start

**Fix Strategy** (FORBIDDEN):
- ❌ Share DB across tests
- ❌ Use global singleton DB instance
- ❌ Skip cleanup to "make tests pass"

---

### Hypothesis 3: CHECK Constraint Validation Timing (MEDIUM CONFIDENCE)
**Evidence**:
- Test 3 (`testCorruptedEvidenceStickyAndNonRecoverable`) fails with `sqlOperation: "INSERT_SESSION_FLAGS"`
- CHECK constraint: `CHECK(length(firstCorruptCommitSha) = 64 OR firstCorruptCommitSha IS NULL)`
- Pattern: Invalid SHA length or NULL handling

**Likely Cause**:
- CHECK constraint evaluated incorrectly
- OR: NULL handling in COALESCE not matching CHECK constraint logic
- OR: String length calculation differs from CHECK constraint

**Fix Strategy** (ALLOWED):
- Verify SHA length before insert
- Ensure NULL handling matches CHECK constraint logic
- Add explicit validation before SQL execution

**Fix Strategy** (FORBIDDEN):
- ❌ Disable CHECK constraint
- ❌ Loosen CHECK constraint (remove length requirement)
- ❌ Change schema to allow invalid values

---

### Hypothesis 4: Transaction Rollback Leaves Inconsistent State (MEDIUM CONFIDENCE)
**Evidence**:
- Pattern: Tests that create multiple commits may fail on second commit
- Transaction rollback may leave session_seq computation in inconsistent state

**Likely Cause**:
- Rollback doesn't reset session_seq computation
- Next commit computes session_seq based on rolled-back state
- Results in duplicate session_seq

**Fix Strategy** (ALLOWED):
- Ensure session_seq computation happens AFTER transaction start
- Verify rollback doesn't affect next transaction's session_seq computation
- Add explicit state verification after rollback

**Fix Strategy** (FORBIDDEN):
- ❌ Skip rollback to "make tests pass"
- ❌ Use global sequence counter outside transactions

---

### Hypothesis 5: BEGIN IMMEDIATE Not Acquiring Exclusive Lock (LOW CONFIDENCE)
**Evidence**:
- BEGIN IMMEDIATE is used, but constraint violations still occur
- Pattern: Multiple commits for same sessionId compute same session_seq

**Likely Cause**:
- BEGIN IMMEDIATE may not be working as expected
- OR: SQLite version/configuration issue
- OR: WAL mode affects lock acquisition

**Fix Strategy** (ALLOWED):
- Verify BEGIN IMMEDIATE actually acquires exclusive lock
- Add explicit lock acquisition verification
- Test with different SQLite configurations

**Fix Strategy** (FORBIDDEN):
- ❌ Change transaction isolation level
- ❌ Disable WAL mode
- ❌ Use different SQLite backend

---

## Allowed vs Forbidden Fix Strategies

**PR5.1 Principle**: Fix database integration issues WITHOUT weakening guarantees or bypassing gates.

### ✅ ALLOWED Strategies
- Fix transaction boundaries (ensure session_seq computation + insert are atomic)
- Improve test isolation (unique DB files per test, proper cleanup)
- Enhance error classification (retry only retryable errors)
- Add explicit validation before SQL execution
- Verify PRAGMA setup and lock acquisition
- Improve error reporting (extended codes, SQL operation tags)

### ❌ FORBIDDEN Strategies
- ❌ Disable constraints (UNIQUE, CHECK, NOT NULL)
- ❌ Loosen schema (remove constraints, change types)
- ❌ Change thresholds or policies
- ❌ Modify SSOT implementations (CanonicalJSON, CoverageDelta, etc.)
- ❌ Skip tests or make tests "pass" by cheating
- ❌ Use different SQLite backend or configuration
- ❌ Change determinism contracts (endianness, float formatting, sorting)

**Separation of Concerns**:
- PR#5: Architectural guarantees, policy locks, determinism contracts
- PR#5.1: Database integration fixes ONLY (transaction boundaries, test isolation, error handling)

---

## Fix Plan (Ordered, Minimal-Risk)

### Fix 1: Test Database Isolation
**File**: `Tests/QualityPreCheck/WhiteCommitTests.swift`

**Change**:
- Add `TestDatabaseFactory` helper that creates unique temp DB file per test
- Ensure each test cleans up DB file in `tearDown()`
- Replace `:memory:` with unique temp file path

**Code**:
```swift
class TestDatabaseFactory {
    static func createTempDB() -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).db"
        return tempDir.appendingPathComponent(fileName).path
    }
    
    static func cleanup(_ dbPath: String) {
        try? FileManager.default.removeItem(atPath: dbPath)
    }
}
```

**Acceptance**: Each test uses isolated DB, no cross-test contamination

---

### Fix 2: Ensure PRAGMA Setup in Tests
**File**: `Core/Quality/WhiteCommitter/QualityDatabase.swift`

**Change**:
- Verify PRAGMA commands succeed (check return codes)
- Ensure PRAGMA is applied even if database exists
- Add explicit error handling for PRAGMA failures

**Code**:
```swift
// In open():
let walResult = sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
guard walResult == SQLITE_OK else {
    throw mapSQLiteError(walResult)
}
let syncResult = sqlite3_exec(db, "PRAGMA synchronous=FULL", nil, nil, nil)
guard syncResult == SQLITE_OK else {
    throw mapSQLiteError(syncResult)
}
```

**Acceptance**: PRAGMA setup verified, errors surfaced

---

### Fix 3: Fix Transaction Scope for session_seq
**File**: `Core/Quality/WhiteCommitter/WhiteCommitter.swift`

**Change**:
- Ensure `session_seq` computation happens INSIDE transaction
- Use BEGIN IMMEDIATE (or equivalent) to get exclusive lock
- Move `getNextSessionSeq()` call inside `attemptCommit()` transaction

**Current Flow** (WRONG):
```swift
let sessionSeq = try database.getNextSessionSeq(...)  // Outside transaction
try database.beginTransaction()
try database.insertCommit(...)  // May conflict
```

**Fixed Flow**:
```swift
try database.beginImmediateTransaction()  // Exclusive lock
let sessionSeq = try database.getNextSessionSeq(...)  // Inside transaction
try database.insertCommit(...)  // Atomic
```

**Acceptance**: session_seq computation and insert are atomic

---

### Fix 4: Error Classification - Retry Only Retryable Errors
**File**: `Core/Quality/WhiteCommitter/WhiteCommitter.swift`

**Change**:
- Classify SQLite errors: retryable vs non-retryable
- Retry ONLY on SQLITE_BUSY, SQLITE_LOCKED
- Do NOT retry on SQLITE_CONSTRAINT (19) - throw immediately
- Include SQLite extended error code in CommitError

**Code**:
```swift
private func isRetryableError(_ error: CommitError) -> Bool {
    switch error {
    case .databaseBusy, .databaseLocked:
        return true
    case .databaseUnknown(let code):
        // SQLITE_BUSY = 5, SQLITE_LOCKED = 6
        return code == 5 || code == 6
    default:
        return false
    }
}
```

**Acceptance**: Constraint errors surface immediately, not masked by retry loop

---

### Fix 5: Improve Error Surfacing
**File**: `Core/Quality/WhiteCommitter/WhiteCommitter.swift`, `QualityDatabase.swift`

**Change**:
- When `maxRetriesExceeded` occurs, include last SQLite error code
- Include SQL statement context in error message
- Add extended error code to CommitError

**Code**:
```swift
case .maxRetriesExceeded(let lastError, let sqliteCode):
    // Include last error and SQLite code in error message
```

**Acceptance**: Debugging information available when retries exhaust

---

### Fix 6: Verify BEGIN IMMEDIATE Usage
**File**: `Core/Quality/WhiteCommitter/QualityDatabase.swift`

**Change**:
- Add `beginImmediateTransaction()` method
- Use BEGIN IMMEDIATE for commit transactions
- Ensure exclusive lock acquired before sequence computation

**Code**:
```swift
func beginImmediateTransaction() throws {
    let sql = "BEGIN IMMEDIATE TRANSACTION"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw mapSQLiteError(sqlite3_errcode(db))
    }
}
```

**Acceptance**: Exclusive lock acquired before sequence computation

---

## Acceptance Criteria

### Must Pass
1. ✅ `swift test --filter WhiteCommitTests` passes 100% (18/18 tests)
2. ✅ `./scripts/quality_gate.sh` passes Gate 1 (Tests)
3. ✅ No flakiness: tests pass consistently on repeated runs
4. ✅ No constraint violations: SQLITE_CONSTRAINT errors eliminated
5. ✅ No retry exhaustion: maxRetriesExceeded errors eliminated

### Must Not Change
1. ✅ DecisionPolicy logic unchanged
2. ✅ Thresholds unchanged
3. ✅ Determinism contracts unchanged
4. ✅ Evidence layer semantics unchanged

---

## Implementation Order

1. **Fix 1**: Test database isolation (prevents cross-test contamination)
2. **Fix 2**: PRAGMA verification (ensures DB setup correct)
3. **Fix 6**: BEGIN IMMEDIATE (ensures exclusive lock)
4. **Fix 3**: Transaction scope for session_seq (ensures atomicity)
5. **Fix 4**: Error classification (surfaces real errors)
6. **Fix 5**: Error surfacing (improves debugging)

---

## Verification Commands

**After fixes**:
```bash
# Run tests
swift test --filter WhiteCommitTests

# Run full gate
./scripts/quality_gate.sh

# Verify no constraint violations
swift test --filter WhiteCommitTests 2>&1 | grep -i "constraint\|code: 19"

# Verify no retry exhaustion
swift test --filter WhiteCommitTests 2>&1 | grep -i "maxRetriesExceeded"
```

**Expected**: All commands show 0 failures

---

## Follow-up

After PR#5.1 merges:
- PR#5 can be merged (Gate 1 will pass)
- Evidence layer correctness proven
- Long-term maintenance path clear

---

**End of Plan**

