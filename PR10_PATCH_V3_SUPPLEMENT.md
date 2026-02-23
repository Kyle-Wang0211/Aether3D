# PR#10 — PATCH V3 SUPPLEMENT: Cross-Plan Reconciliation & Final Polish

> **Status:** MANDATORY SUPPLEMENT — applies ON TOP of V1 (21 patches) + V2 (14 patches)
> **Applies to:** ALL PR#10 files (5 new + 2 modified)
> **Source:** Cross-referencing b186ba4e (Enhanced Plan) against 9b8185e0 (Ultimate Plan) + actual codebase
> **Authority:** This is the THIRD and FINAL quality gate before implementation

---

## TABLE OF CONTENTS

1. [Cross-Plan Reconciliation Issues (8 New Findings)](#1-cross-plan-reconciliation-issues)
2. [PATCH-V3-A: Fix NEW_FILE_COUNT Internal Contradiction](#2-patch-v3-a-fix-new_file_count)
3. [PATCH-V3-B: Fix Modification A Contradiction (File-First, NOT After DB Commit)](#3-patch-v3-b-fix-modification-a-contradiction)
4. [PATCH-V3-C: Mandatory Pre-Read File List for Implementation Agent](#4-patch-v3-c-mandatory-pre-read-file-list)
5. [PATCH-V3-D: macOS F_FULLFSYNC Defense-in-Depth](#5-patch-v3-d-macos-f_fullfsync)
6. [PATCH-V3-E: copy_file_range() Zero-Copy Assembly Alternative](#6-patch-v3-e-copy_file_range)
7. [PATCH-V3-F: Streaming Merkle Tree for O(log N) Memory](#7-patch-v3-f-streaming-merkle)
8. [PATCH-V3-G: Content-Addressable Chunk Naming as Defense-in-Depth](#8-patch-v3-g-content-addressable-chunk-naming)
9. [PATCH-V3-H: Missing Tiered Acceptance Criteria in Enhanced Plan](#9-patch-v3-h-tiered-acceptance-criteria)
10. [PATCH-V3-I: Quality Tooling Requirements (ruff, mypy, coverage)](#10-patch-v3-i-quality-tooling)
11. [Master Merge Strategy: How to Use Both Plans](#11-master-merge-strategy)
12. [Updated Total Patch Summary](#12-updated-total-patch-summary)

---

## 1. CROSS-PLAN RECONCILIATION ISSUES

Through line-by-line comparison of both plan documents and the actual codebase, the following 8 issues were discovered. These are NOT bugs in the code — they are **ambiguities, contradictions, and missing details** in the plan documents that could cause an AI implementation agent to produce incorrect code.

| # | Issue | Severity | Root Cause |
|---|-------|----------|------------|
| 1 | `NEW_FILE_COUNT` = 4 in both plans, but there are 5 new files | **HIGH** | upload_contract_constants.py not counted |
| 2 | 9b8185e0 Section 3.1 says "AFTER DB commit" but PATCH-O says file-first | **HIGH** | Internal contradiction in Ultimate Plan |
| 3 | No mandatory pre-read file list in Enhanced Plan | **MEDIUM** | Agent may write code without reading existing code |
| 4 | macOS `os.fsync()` only flushes to drive cache, not to platter | **MEDIUM** | Cross-platform fsync semantics not specified |
| 5 | No mention of `copy_file_range()` for zero-copy assembly | **LOW** | Performance optimization not considered |
| 6 | Merkle tree computed in O(N) memory, could be O(log N) | **LOW** | Streaming Merkle not specified |
| 7 | Chunk files named by index (000000.chunk), not by hash | **LOW** | Content-addressable naming not specified |
| 8 | Enhanced Plan has no tiered acceptance criteria (Must/Should/Nice) | **MEDIUM** | Flat checklist gives no implementation priority |

---

## 2. PATCH-V3-A: FIX NEW_FILE_COUNT INTERNAL CONTRADICTION

**Problem:** Both plan documents are internally inconsistent about the number of new files:

- Enhanced Plan line 31: "新建5个服务文件（新增：upload_contract_constants.py）" → says 5
- Enhanced Plan line 65 (PATCH-A): "所有4个新文件都必须有完整的合同头" → says 4
- Ultimate Plan `UploadContractConstants.NEW_FILE_COUNT = 4` → says 4
- Ultimate Plan Section 2 table: Lists 5 files → says 5

**Fix:**

```python
# In upload_contract_constants.py:
# WHY 5 (not 4): upload_contract_constants.py itself is one of the 5 new files.
# Files: upload_service.py, integrity_checker.py, deduplicator.py,
#        cleanup_handler.py, upload_contract_constants.py
# GATE: This count MUST be updated if files are added/removed.
NEW_FILE_COUNT = 5
```

**Also fix Enhanced Plan PATCH-A wording:**
- Change "所有4个新文件" → "所有5个新文件" (all 5 new files must have constitutional contract headers)

---

## 3. PATCH-V3-B: FIX MODIFICATION A CONTRADICTION (FILE-FIRST, NOT AFTER DB COMMIT)

**Problem:** The Ultimate Plan (9b8185e0) has an internal contradiction:

- **Section 3.1, Modification A** (line 140): "Add chunk persistence AFTER DB commit"
  - Location: "After line 323 (`db.commit()`)"

- **Section 18, PATCH-O** (lines 976-1040): "Reverse order to file-first, DB-second"
  - "Step 1: Persist chunk to disk (may raise AssemblyError)"
  - "Step 2: Only AFTER file is persisted, commit DB record"

These are **mutually exclusive**. An AI agent following Section 3.1 literally would implement DB-first (wrong), while an AI agent following Section 18 would implement file-first (correct).

**Fix (MANDATORY):**

Section 3.1 Modification A MUST be corrected to read:

> **Modification A:** `upload_chunk()` — Add chunk persistence BEFORE DB commit
>
> - **Location:** REPLACE lines 314-325 (from `chunk = Chunk(...)` through `db.commit()`)
> - **Change:** Call `persist_chunk(upload_id, chunk_index, body, chunk_hash)` FIRST, then `db.add(chunk)` + `db.commit()`
> - **CRITICAL:** This implements file-first, DB-second ordering per PATCH-O
> - **If persist_chunk() fails:** Return HTTP 500, do NOT commit to DB

**Implementation agent instruction:**

```python
# CORRECT ordering (PATCH-O):
# 1. persist_chunk() — write file to disk
# 2. db.add(chunk) + db.commit() — record in DB
# NEVER: db.commit() first then persist_chunk()

# If you see ANY instruction saying "add chunk persistence AFTER DB commit",
# it is a known ERRATA. The correct order is FILE FIRST, DB SECOND.
```

---

## 4. PATCH-V3-C: MANDATORY PRE-READ FILE LIST FOR IMPLEMENTATION AGENT

**Problem:** The Enhanced Plan (b186ba4e) does not include a mandatory pre-read file list. The Ultimate Plan (9b8185e0) has this in Section 1.2 and Final Notes ("Read existing code FIRST"). Without it, an AI agent may write PR#10 code that conflicts with existing patterns.

**Fix:** Add to the Enhanced Plan:

```
## MANDATORY: Read These Files Before Writing ANY Code

Read EVERY file below. Do NOT skip any. Do NOT start writing until all are read.

| # | File | Why You Must Read It |
|---|------|---------------------|
| 1 | server/app/api/handlers/upload_handlers.py | You are MODIFYING this file. Understand every line. |
| 2 | server/main.py | You are MODIFYING this file. Find the lifespan function. |
| 3 | server/app/api/contract.py | Pydantic schemas you must use. APIErrorCode enum. |
| 4 | server/app/api/contract_constants.py | Existing constants (MAX_BUNDLE_SIZE, etc). |
| 5 | server/app/api/error_registry.py | 7-code closed set. Do NOT add new codes. |
| 6 | server/app/models.py | ORM models. UploadSession.bundle_hash has index. |
| 7 | server/app/core/config.py | Settings class. upload_path vs upload_dir. |
| 8 | server/app/core/storage.py | Dormant cleanup_storage(). save_upload_file() pattern. |
| 9 | server/app/core/ownership.py | Anti-enumeration error pattern. |
| 10 | server/app/middleware/idempotency.py | Timing-unsafe != on line 131 (pre-existing, not our scope). |
```

---

## 5. PATCH-V3-D: macOS F_FULLFSYNC DEFENSE-IN-DEPTH

**Problem:** The plans specify `os.fsync(fd)` for durability. On Linux, this correctly calls `fsync(2)` which flushes to persistent storage. On macOS, `os.fsync()` only flushes to the drive's volatile write cache, NOT to NAND/platter. macOS requires `fcntl(F_FULLFSYNC)` for true durability.

**Note:** Python 3.12+ on macOS does call `F_FULLFSYNC` from `os.fsync()`. However, Python 3.10-3.11 does NOT. Since our minimum is Python 3.10+, we need a defensive wrapper.

**Fix:**

```python
import sys
import os

def _durable_fsync(fd: int) -> None:
    """
    Platform-aware fsync with macOS F_FULLFSYNC support.

    SEAL FIX: On macOS < Python 3.12, os.fsync() only flushes to drive cache,
    NOT to persistent storage. F_FULLFSYNC ensures platter/NAND-level durability.
    On Linux, os.fsync() is already sufficient (flushes to device).

    Cross-Platform Guarantee:
    - Linux: calls fsync(2) → data durable on device
    - macOS Python ≥ 3.12: os.fsync() already calls F_FULLFSYNC
    - macOS Python 3.10-3.11: we call fcntl(F_FULLFSYNC) explicitly

    WHY not just always use F_FULLFSYNC: F_FULLFSYNC is macOS-only.
    On Linux, it would raise an error.
    """
    if sys.platform == "darwin":
        try:
            import fcntl
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            return
        except (ImportError, OSError):
            pass  # Fall through to regular fsync
    os.fsync(fd)
```

**Apply in:** `persist_chunk()` and `assemble_bundle()` — replace ALL `os.fsync(fd)` calls with `_durable_fsync(fd)`.

**Add to Cross-Platform Guarantees docstring:**
```
- _durable_fsync(): Uses F_FULLFSYNC on macOS (Python 3.10-3.11) for true
  durability. Python 3.12+ already does this in os.fsync().
```

---

## 6. PATCH-V3-E: copy_file_range() ZERO-COPY ASSEMBLY ALTERNATIVE

**Problem:** The plans specify reading chunks into a 256KB buffer and writing to the assembly file. On Linux 4.5+, `os.copy_file_range()` (available in Python 3.8+) can perform this as a kernel-to-kernel zero-copy operation, avoiding userspace buffer copies entirely.

**This is an OPTIONAL optimization, NOT a replacement for the existing three-way pipeline.** The three-way pipeline (read + hash + write) still requires reading data into userspace for hashing. However, for the write phase, `copy_file_range()` can be used when re-hashing is not needed.

**Fix:** Add a FUTURE comment in `upload_service.py`:

```python
# FUTURE-ZEROCOPY: For assembly without re-hashing (when all chunk hashes
# were verified at upload time and are trusted), use os.copy_file_range()
# for zero-copy kernel-to-kernel chunk concatenation:
#
#   os.copy_file_range(src_fd, dst_fd, chunk_size, src_offset)
#
# Available on Linux 4.5+ (Python 3.8+). Not available on macOS.
# Expected performance improvement: 2-3× for large bundles (> 100MB)
# by avoiding userspace buffer copies.
#
# Current implementation uses the three-way pipeline (read+hash+write)
# which MUST read data into userspace for re-hashing during assembly.
# This is correct but slower than zero-copy.
```

---

## 7. PATCH-V3-F: STREAMING MERKLE TREE FOR O(LOG N) MEMORY

**Problem:** The current Merkle tree specification (`merkle_compute_root()`) stores all leaf hashes in a list, requiring O(N) memory. For 200 chunks with 32-byte hashes, this is only 6.4KB, so it's not a practical concern. However, documenting the O(log N) streaming alternative future-proofs the architecture.

**Fix:** Add a FUTURE comment in `integrity_checker.py`:

```python
# FUTURE-STREAMING-MERKLE: For future support of very large bundles (>10,000 chunks),
# replace the list-based Merkle tree with a stack-based streaming builder:
#
#   class StreamingMerkleTree:
#       stack: list[tuple[int, bytes]]  # (level, hash) — O(log N) memory
#
#       def add_leaf(self, data: bytes) -> None:
#           current = leaf_hash(data)
#           level = 0
#           while self.stack and self.stack[-1][0] == level:
#               left_level, left_hash = self.stack.pop()
#               current = node_hash(left_hash, current)
#               level += 1
#           self.stack.append((level, current))
#
# Current O(N) approach is fine for MAX_CHUNK_COUNT=200 (6.4KB memory).
# Switch to streaming when MAX_CHUNK_COUNT exceeds 10,000.
```

---

## 8. PATCH-V3-G: CONTENT-ADDRESSABLE CHUNK NAMING AS DEFENSE-IN-DEPTH

**Problem:** The current plan names chunk files by index: `000000.chunk`, `000001.chunk`, etc. This is simple and correct, but naming by content hash (`{sha256_hex}.chunk`) provides additional defense against chunk substitution attacks — an attacker who gains write access to the upload directory cannot replace a chunk with different content without changing the filename.

**This is NOT a change to the current plan.** The index-based naming is correct and simpler. This is a FUTURE consideration.

**Fix:** Add FUTURE comment in `upload_service.py`:

```python
# FUTURE-CAS-NAMING: For defense-in-depth against chunk substitution attacks,
# consider naming chunk files by their SHA-256 hash instead of index:
#   Current:  chunks/000000.chunk, chunks/000001.chunk, ...
#   Future:   chunks/{sha256_hex}.chunk
#
# Benefits:
#   - Attacker cannot swap chunk content without changing filename
#   - Natural deduplication at the chunk level (same content = same file)
#   - Aligns with IPFS content-addressable storage model
#
# Trade-offs:
#   - Assembly must sort by a separate index mapping, not filename sort
#   - Slightly more complex cleanup (orphan detection by hash, not index)
#   - Current MAX_CHUNK_COUNT=200 makes substitution attack impractical
#
# DECISION: Keep index-based naming for PR#10 (simpler, sufficient).
# Re-evaluate when implementing cross-user dedup (Path 3) in future PR.
```

---

## 9. PATCH-V3-H: MISSING TIERED ACCEPTANCE CRITERIA IN ENHANCED PLAN

**Problem:** The Enhanced Plan (b186ba4e) has a flat checklist with no priority tiers. The Ultimate Plan (9b8185e0) has three tiers: "Must Have" (merge blockers), "Should Have" (quality complete), "Nice to Have" (future). Without tiers, an AI agent may treat all items as equally critical, wasting time on "nice to have" items before completing "must have" items.

**Fix:** Add tiered acceptance criteria to the Enhanced Plan:

```
## Acceptance Criteria (Tiered)

### MUST HAVE (PR#10 merge blockers — implement these FIRST)

- All 5 new files created with constitutional contract headers (PATCH-A)
- All 28 invariants (INV-U1 through INV-U28) in code comments (PATCH-B)
- All SEAL FIX and GATE markers present (PATCH-C)
- Probabilistic formula correct, no sqrt(N) floor (PATCH-D)
- Domain tag byte counts 22/26/25 (PATCH-E)
- upload_contract_constants.py exists, version PR10-UPLOAD-1.0 (PATCH-F)
- validate_path_component() + _assert_within_upload_dir() (PATCH-I)
- check_disk_quota() called in persist_chunk + create_upload (PATCH-K)
- persist_chunk uses write→fsync(fd)→rename→fsync(dir_fd) (PATCH-N)
- upload_chunk() does file-first, DB-second (PATCH-O)
- upload_handlers.py lines 277/297: != → hmac.compare_digest() (V2-A)
- chunk_hash validated against ^[0-9a-f]{64}$ (V2-B)
- chunk_index validated 0 <= index < chunk_count (V2-B)
- All code uses settings.upload_path not settings.upload_dir (V2-F)
- complete_upload() uses single db.commit() (V2-H)
- DISK_USAGE_REJECT_THRESHOLD = 0.85 (V2-L)
- All tests pass (`pytest -v --tb=long`)
- Zero new error codes (error_registry stays at 7)
- Zero new API endpoints (stays at 12)
- Zero new ORM models
- NEW_FILE_COUNT = 5 in contract constants (V3-A)
- _durable_fsync() wrapper for macOS compatibility (V3-D)

### SHOULD HAVE (quality complete — implement AFTER all Must Have)

- Every constant has WHY comment (PATCH-G)
- Every error path marked FAIL-CLOSED/FAIL-OPEN (PATCH-H)
- UploadErrorKind enum with is_retryable (PATCH-L)
- VerificationReceipt dataclass (PATCH-M)
- Cross-platform guarantees in docstrings (PATCH-P)
- Memory pressure comments (PATCH-Q)
- 2000+ test scenarios (PATCH-R)
- FUTURE comments in each file (PATCH-S)
- Cleanup failure handling (PATCH-T)
- bundle_hash re-validated before file path (V2-C)
- Disk quota uses HTTP 429 with WHY comment (V2-D, V2-E)
- _DEDUP_VALID_STATES named constant (V2-G)
- AssemblyState with transitions and assertions (V2-I)
- Logging strategy with hash truncation (V2-J)
- Test vectors verified against Swift formula (V2-K)
- Industry benchmark comments (V2-M)
- Meta-guardrail tests (V2-N)

### NICE TO HAVE (future PR#10.1)

- Performance benchmarks (assembly time < 1.0s for 500MB)
- Memory profiling (assembly uses < 2MB)
- Stress tests (concurrent uploads, disk full)
- copy_file_range() zero-copy assembly (V3-E)
- Streaming Merkle tree O(log N) memory (V3-F)
- Content-addressable chunk naming (V3-G)
```

---

## 10. PATCH-V3-I: QUALITY TOOLING REQUIREMENTS (RUFF, MYPY, COVERAGE)

**Problem:** The Enhanced Plan (b186ba4e) does not mention quality tooling. The Ultimate Plan specifies:
- Code coverage > 90% for new files
- No linter errors (`ruff check`, `mypy`)
- All type hints present
- All docstrings present for public APIs

**Fix:** Add to the Enhanced Plan:

```
## Quality Tooling (MANDATORY)

Before submitting PR#10, verify:

1. **ruff check server/app/services/**: Zero errors, zero warnings
2. **mypy server/app/services/ --strict**: Zero errors (all type hints present)
3. **pytest --cov=app.services --cov-report=term-missing**: Coverage > 90%
4. **pytest -v --tb=long**: All tests pass
5. Every public function has a docstring with:
   - One-line summary
   - Args/Returns/Raises sections
   - Relevant INV-U* invariant references
```

---

## 11. MASTER MERGE STRATEGY: HOW TO USE BOTH PLANS

The Enhanced Plan (b186ba4e) and Ultimate Plan (9b8185e0) are COMPLEMENTARY. Neither alone is sufficient.

### Recommended Implementation Approach

**Step 1: Use the Ultimate Plan (9b8185e0) as the STRUCTURAL BACKBONE**

The Ultimate Plan provides:
- Exact file layout and line count estimates
- Complete code snippets for every function
- Exact line numbers for modifications to existing files
- Full invariant text for all 28 INV-U* items
- Full constitutional contract headers for all 5 files
- Integration points section
- Branch and commit context

**Step 2: Apply the Enhanced Plan's (b186ba4e) V2 patches ON TOP**

The Enhanced Plan adds 14 critical patches that fix real bugs:
- V2-A: Timing-unsafe hash comparison in existing code
- V2-B: chunk_hash/chunk_index input validation
- V2-C: bundle_hash path traversal defense
- V2-D: HTTP 429 instead of 503
- V2-E: WHY comment for RATE_LIMITED
- V2-F: settings.upload_path instead of settings.upload_dir
- V2-G: _DEDUP_VALID_STATES named constant
- V2-H: Single-transaction complete_upload
- V2-I: Assembly state machine with transitions
- V2-J: Logging strategy
- V2-K: Test vector accuracy
- V2-L: DISK_USAGE_REJECT_THRESHOLD = 0.85
- V2-M: Industry benchmarks
- V2-N: Guardrail enforcement matrix

**Step 3: Apply V3 patches (this document)**

V3 resolves contradictions between the two plans and adds cross-platform safety:
- V3-A: NEW_FILE_COUNT = 5
- V3-B: Fix Modification A contradiction
- V3-C: Mandatory pre-read file list
- V3-D: macOS F_FULLFSYNC wrapper
- V3-E: FUTURE comment for copy_file_range()
- V3-F: FUTURE comment for streaming Merkle
- V3-G: FUTURE comment for CAS naming
- V3-H: Tiered acceptance criteria
- V3-I: Quality tooling requirements

### Conflict Resolution Rules

When the two plans CONTRADICT each other:
1. **V2/V3 patches ALWAYS win** over V1/Ultimate Plan
2. **Enhanced Plan's values** win over Ultimate Plan's values (e.g., 0.85 > 0.90)
3. **Enhanced Plan's `settings.upload_path`** wins over Ultimate Plan's `settings.upload_dir`
4. **PATCH-O (file-first)** wins over Section 3.1 ("after DB commit")
5. **NEW_FILE_COUNT = 5** (correct) wins over 4 (wrong)

---

## 12. UPDATED TOTAL PATCH SUMMARY

| Version | Patches | Key Focus |
|---------|---------|-----------|
| V1 (PATCH-A to PATCH-T) | 21 | Core architecture, security, testing |
| V2 (PATCH-V2-A to V2-N) | 14 | Bug fixes, input validation, industry alignment |
| V3 (PATCH-V3-A to V3-I) | 9 | Cross-plan reconciliation, cross-platform, quality |
| **TOTAL** | **44** | **Complete specification** |

### Cumulative Metrics

| Metric | V1 | V1+V2 | V1+V2+V3 |
|--------|-----|-------|-----------|
| Critical bugs fixed | 4 | 6 | 6 |
| High bugs fixed | 2 | 5 | 7 |
| Named invariants | 28 | 28 | 28 |
| SEAL FIX markers | 12+ | 16+ | 17+ |
| GATE markers | 9 | 11 | 12 |
| New files | 5 | 5 | 5 |
| Test scenarios | 2210 | 2210+ | 2210+ |
| DISK_USAGE threshold | 0.90 | 0.85 | 0.85 |
| NEW_FILE_COUNT constant | 4 | 4 | **5** (fixed) |
| macOS F_FULLFSYNC | ❌ | ❌ | ✅ |
| Tiered acceptance criteria | partial | ❌ | ✅ |
| Quality tooling specified | partial | ❌ | ✅ |

---

## END OF PATCH V3 SUPPLEMENT
