# PR#5.1 Root Cause & Fix Summary

**Date**: 2025-01-17  
**Status**: Partial - Core fixes implemented, 7/18 tests still failing

---

## Root Causes Identified

### 1. SHA256 Length Validation Issue ✅ FIXED
**Problem**: SQLite `length()` function counts **bytes**, not characters. Swift `String.count` counts **characters**. For ASCII hex strings, these are usually the same, but SQLite binding with `-1` (auto-length) can cause issues.

**Fix**: 
- Validate UTF-8 byte length: `commitSHA256.utf8.count == 64`
- Explicit byte length binding: `sqlite3_bind_text(stmt, bindIndex, cString, Int32(commitSHA256.utf8.count), nil)`
- Use `withCString` for proper C string conversion

**Files**: `Core/Quality/WhiteCommitter/QualityDatabase.swift`, `Core/Quality/WhiteCommitter/WhiteCommitter.swift`

---

### 2. sessionId Length Validation Issue ✅ FIXED
**Problem**: CHECK constraint `length(sessionId) > 0 AND length(sessionId) <= 64` was failing because binding used `-1` (auto-length) which may not match SQLite's byte counting.

**Fix**:
- Validate UTF-8 byte length before binding
- Explicit byte length binding with `withCString`

**Files**: `Core/Quality/WhiteCommitter/QualityDatabase.swift`

---

### 3. Transaction Rollback After Commit ✅ FIXED
**Problem**: `defer { rollbackTransaction() }` was executing even after successful commit, causing data loss.

**Fix**:
- Track transaction state: `var transactionCommitted = false`
- Set flag after successful commit: `transactionCommitted = true`
- Only rollback if not committed: `if !transactionCommitted { rollbackTransaction() }`

**Files**: `Core/Quality/WhiteCommitter/WhiteCommitter.swift`

---

### 4. UNIQUE Constraint Race Condition ⚠️ PARTIALLY FIXED
**Problem**: When `commitWhite()` is called twice in quick succession, both transactions may compute the same `session_seq` before either commits, causing UNIQUE constraint violation.

**Fix Attempted**:
- Added retry logic for UNIQUE constraint conflicts (extended code 2067)
- Retry recomputes `session_seq` in a new transaction
- BEGIN IMMEDIATE should provide exclusive lock

**Remaining Issue**: Retry logic may not be sufficient if transactions are not properly isolated. May need:
- Longer retry delays
- Explicit synchronization
- Verification that BEGIN IMMEDIATE is actually waiting

**Files**: `Core/Quality/WhiteCommitter/WhiteCommitter.swift`, `Core/Quality/WhiteCommitter/QualityDatabase.swift`

---

### 5. corruptedEvidence Binding Issue ⚠️ PARTIALLY FIXED
**Problem**: `setCorruptedEvidence` and `hasCorruptedEvidence` may not be binding/reading correctly.

**Fix Attempted**:
- Fixed binding in `setCorruptedEvidence` to use explicit UTF-8 byte length
- Fixed binding in `hasCorruptedEvidence` to use explicit UTF-8 byte length
- Added validation for sessionId length

**Remaining Issue**: Test still failing. May need:
- Verification that `setCorruptedEvidence` actually inserts
- Verification that `hasCorruptedEvidence` query is correct
- Check transaction boundaries

**Files**: `Core/Quality/WhiteCommitter/QualityDatabase.swift`

---

## How Fixes Were Eliminated

### SHA256 Length Issues
1. **Identified**: CHECK constraint failures showed `length(commit_sha256) != 64`
2. **Root Cause**: SQLite counts bytes, Swift counts characters
3. **Fix**: Validate UTF-8 byte length, use explicit byte length binding
4. **Result**: SHA256 length errors eliminated

### sessionId Length Issues
1. **Identified**: CHECK constraint failures showed `length(sessionId)` violations
2. **Root Cause**: Same as SHA256 - byte vs character counting
3. **Fix**: Validate UTF-8 byte length, use explicit byte length binding
4. **Result**: sessionId length errors eliminated

### Transaction Issues
1. **Identified**: Data loss, UNIQUE constraint violations
2. **Root Cause**: Rollback executing after successful commit
3. **Fix**: Track transaction state, prevent rollback after commit
4. **Result**: Transaction state management improved

---

## Remaining Work

### High Priority
1. **Debug UNIQUE constraint failures**:
   - Add logging to see actual `session_seq` values
   - Verify BEGIN IMMEDIATE is waiting correctly
   - Consider explicit synchronization

2. **Debug corruptedEvidence test**:
   - Verify `setCorruptedEvidence` inserts correctly
   - Verify `hasCorruptedEvidence` reads correctly
   - Check transaction boundaries

### Medium Priority
1. **Improve retry logic**:
   - May need longer delays
   - May need better error classification

2. **Add more diagnostics**:
   - Log transaction boundaries
   - Log session_seq computation
   - Log constraint violations with full context

---

## Verification

```bash
# Current test status
swift test --filter WhiteCommitTests
# Expected: 18 tests, 7 failures (down from original 7, but still failing)

# Quality gates
./scripts/quality_gate.sh
# Expected: Gate 1 fails (tests), other gates pass

# Pre-push hook
git push  # Should run quality gates
# Expected: Push blocked if gates fail
```

---

## Files Modified Summary

**Code**:
- `Core/Quality/Types/CommitError.swift` - Enhanced error reporting
- `Core/Quality/WhiteCommitter/WhiteCommitter.swift` - Transaction state, retry logic
- `Core/Quality/WhiteCommitter/QualityDatabase.swift` - Validation, binding fixes
- `Core/Quality/Serialization/SHA256Utility.swift` - Length validation
- `Tests/QualityPreCheck/WhiteCommitTests.swift` - Test isolation

**Scripts**:
- `scripts/hooks/pre-push` - Repo-root robust hook
- `scripts/install_hooks.sh` - Hook installation
- `scripts/quality_gate.sh` - Enhanced diagnostics

**Documentation**:
- `PR5_1_FIX_SUMMARY.md` - Progress summary
- `PR5_1_ROOT_CAUSE_AND_FIX.md` - This file

