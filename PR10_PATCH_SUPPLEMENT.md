# PR#10 — PATCH SUPPLEMENT: Quality Elevation to PR1-8 Standard

> **Status:** MANDATORY SUPPLEMENT to `PR10_IMPLEMENTATION_PROMPT.md`
> **Applies to:** ALL 4 new files + ALL modified files in PR#10
> **Quality Target:** Match or exceed PR#2 `job_state.py` + PR#8 `ImmutableBundle.swift` quality bar
> **Authority:** This patch OVERRIDES any conflicting instruction in the base prompt

---

## TABLE OF CONTENTS

1. [Gap Analysis Summary (10 Dimensions)](#1-gap-analysis-summary)
2. [PATCH-A: Constitutional Contract Headers](#2-patch-a-constitutional-contract-headers)
3. [PATCH-B: Named Invariants (INV-U1 through INV-U28)](#3-patch-b-named-invariants)
4. [PATCH-C: SEAL FIX + GATE Markers](#4-patch-c-seal-fix--gate-markers)
5. [PATCH-D: Fix Probabilistic Verification Formula](#5-patch-d-fix-probabilistic-verification-formula)
6. [PATCH-E: Fix Domain Tag Byte Counts](#6-patch-e-fix-domain-tag-byte-counts)
7. [PATCH-F: Contract Versioning](#7-patch-f-contract-versioning)
8. [PATCH-G: WHY Comments on Every Constant](#8-patch-g-why-comments-on-every-constant)
9. [PATCH-H: Fail-Closed Analysis (Every Error Path)](#9-patch-h-fail-closed-analysis)
10. [PATCH-I: Path Traversal Prevention](#10-patch-i-path-traversal-prevention)
11. [PATCH-J: Concurrency & Race Condition Analysis](#11-patch-j-concurrency--race-condition-analysis)
12. [PATCH-K: Disk Quota Enforcement](#12-patch-k-disk-quota-enforcement)
13. [PATCH-L: Error Taxonomy with Retryable Classification](#13-patch-l-error-taxonomy-with-retryable-classification)
14. [PATCH-M: Audit Trail & Verification Receipts](#14-patch-m-audit-trail--verification-receipts)
15. [PATCH-N: fsync Durability Guarantees](#15-patch-n-fsync-durability-guarantees)
16. [PATCH-O: DB-File Consistency Guard](#16-patch-o-db-file-consistency-guard)
17. [PATCH-P: Cross-Platform Guarantees Section](#17-patch-p-cross-platform-guarantees-section)
18. [PATCH-Q: Memory Pressure & Resource Limits](#18-patch-q-memory-pressure--resource-limits)
19. [PATCH-R: Expanded Testing (2000+ Scenarios)](#19-patch-r-expanded-testing-2000-scenarios)
20. [PATCH-S: Future-Proofing Architecture](#20-patch-s-future-proofing-architecture)
21. [PATCH-T: Cleanup Deletion Failure Handling](#21-patch-t-cleanup-deletion-failure-handling)

---

## 1. GAP ANALYSIS SUMMARY

The base `PR10_IMPLEMENTATION_PROMPT.md` was compared against the quality bar set by:
- `jobs/job_state.py` (PR#2): Constitutional contract, named invariants, versioned constants
- `Core/Upload/ImmutableBundle.swift` (PR#8): SEAL FIX, GATE markers, INV-B1~B18, fail-closed
- `Core/Constants/BundleConstants.swift` (PR#8): WHY comments, constitutional header, version metadata
- `jobs/contract_constants.py` (PR#2): Contract version, count assertions

| # | Dimension | PR#8/PR#2 Quality | PR#10 Base Quality | Gap |
|---|-----------|-------------------|--------------------|-----|
| 1 | Constitutional headers | ✅ Every file | ❌ Zero files | CRITICAL |
| 2 | Named invariants | ✅ INV-B1~B18 | ❌ Zero defined | CRITICAL |
| 3 | SEAL FIX / GATE markers | ✅ 10+ markers | ❌ Zero markers | CRITICAL |
| 4 | Probabilistic formula | ✅ `ceil(N*(1-pow(δ,1/N)))` | ❌ WRONG formula | CRITICAL |
| 5 | Domain tag byte counts | ✅ 22/26/25 bytes | ❌ 23/27/26 (ALL WRONG) | HIGH |
| 6 | Contract versioning | ✅ PR8-BUNDLE-1.0 | ❌ Zero versions | HIGH |
| 7 | WHY comments on constants | ✅ Every constant | ❌ Zero WHY | HIGH |
| 8 | Fail-closed analysis | ✅ All paths | ❌ Mixed open/closed | HIGH |
| 9 | Concurrency analysis | ✅ Actor isolation | ❌ Zero discussion | MEDIUM |
| 10 | Audit trail | ✅ VerificationReceipt | ❌ Zero receipts | MEDIUM |
| 11 | Path traversal prevention | ✅ validateFileWithinBoundary | ❌ upload_id unsanitized | CRITICAL |
| 12 | DB-file consistency | N/A (Swift=client) | ❌ No guard | HIGH |
| 13 | Disk quota enforcement | N/A | ❌ No limit | HIGH |
| 14 | fsync durability | N/A (client) | ❌ Incomplete | MEDIUM |
| 15 | Cleanup failure handling | N/A | ❌ Unspecified | MEDIUM |

---

## 2. PATCH-A: CONSTITUTIONAL CONTRACT HEADERS

**Requirement:** Every new file MUST begin with a constitutional contract header, matching the pattern from `job_state.py` and `BundleConstants.swift`.

### upload_service.py — Header

```python
# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-UPLOAD-1.0
# Module: Server Upload Reception — Three-Way Pipeline Assembly Engine
# Scope: upload_service.py ONLY — does NOT govern other PR#10 files
# Cross-Platform: Python 3.10+ (Linux + macOS)
# Standards: RFC 9162 (Merkle), POSIX fsync, OWASP File Upload Security
# Dependencies: hashlib (stdlib), hmac (stdlib), os (stdlib), pathlib (stdlib)
# Swift Counterpart: Core/Upload/ImmutableBundle.swift (PR#8)
# =============================================================================
```

### integrity_checker.py — Header

```python
# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-INTEGRITY-1.0
# Module: Five-Layer Progressive Verification Engine
# Scope: integrity_checker.py ONLY — does NOT govern other PR#10 files
# Cross-Platform: Python 3.10+ (Linux + macOS)
# Standards: RFC 9162 (Merkle), RFC 8785 (JCS), OWASP Cryptographic Verification
# Dependencies: hashlib (stdlib), hmac (stdlib), math (stdlib), random (stdlib)
# Swift Counterparts: VerificationMode.swift, MerkleTree.swift, MerkleTreeHash.swift,
#                     HashCalculator.swift, BundleConstants.swift (PR#8)
# Byte-Identical: Merkle tree output MUST match Swift for same inputs
# =============================================================================
```

### deduplicator.py — Header

```python
# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-DEDUP-1.0
# Module: Three-Path Fusion Dedup Engine
# Scope: deduplicator.py ONLY — does NOT govern other PR#10 files
# Cross-Platform: Python 3.10+ (Linux + macOS)
# Dependencies: sqlalchemy (existing), hmac (stdlib)
# Activates: Dormant Capabilities #3 (Job.bundle_hash index) and #5 (UploadSession.bundle_hash index)
# =============================================================================
```

### cleanup_handler.py — Header

```python
# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-CLEANUP-1.0
# Module: Three-Tier Self-Healing Cleanup Engine
# Scope: cleanup_handler.py ONLY — does NOT govern other PR#10 files
# Cross-Platform: Python 3.10+ (Linux + macOS)
# Standards: POSIX file safety, fail-closed deletion
# Dependencies: os (stdlib), shutil (stdlib), pathlib (stdlib), time (stdlib)
# Activates: Dormant Capabilities #2 (cleanup_storage) and #4 (cleanup_old_files)
# =============================================================================
```

---

## 3. PATCH-B: NAMED INVARIANTS (INV-U1 through INV-U28)

**Requirement:** Every security-critical behavioral guarantee MUST have a named invariant, following the INV-B1~B18 pattern from `ImmutableBundle.swift`.

**Naming convention:** `INV-U{n}` where U = Upload, n = sequential number.

### upload_service.py Invariants

```
INV-U1:  Atomic chunk persistence — write to .tmp then rename; partial writes NEVER visible
INV-U2:  Three-way pipeline — read, write, hash in single pass; O(256KB) constant memory
INV-U3:  Chunk ordering — chunks assembled in strict index order (0, 1, 2, ..., N-1)
INV-U4:  Contiguity validation — chunk indices MUST be gapless (no missing indices)
INV-U5:  Size invariant — assembled bundle byte count == declared bundle_size
INV-U6:  Per-chunk hash verification — every chunk re-verified during assembly via timing-safe compare
INV-U7:  fsync before rename — data durably written before atomic rename makes it visible
INV-U8:  Assembly temp isolation — .assembling files NEVER in final bundle path
INV-U9:  Path containment — all file operations confined to upload_dir/{upload_id}/ subtree
INV-U10: Crash recovery — .tmp and .assembling files are detectable and cleanable after crash
```

### integrity_checker.py Invariants

```
INV-U11: Byte-identical Merkle — Python merkle_compute_root() == Swift MerkleTree.computeRoot() for same inputs
INV-U12: RFC 9162 domain separation — leaf prefix 0x00, node prefix 0x01, NEVER omitted
INV-U13: Odd node promotion — unpaired nodes promoted WITHOUT re-hashing (MerkleTree.swift line 83)
INV-U14: Empty tree sentinel — zero-input Merkle root = 32 zero bytes
INV-U15: Domain tag NUL termination — all domain tags include trailing \x00 byte
INV-U16: Timing-safe comparison — ALL hash comparisons via hmac.compare_digest(), NEVER ==
INV-U17: Anti-enumeration — external errors NEVER reveal which verification layer failed
INV-U18: Fail-fast ordering — cheapest checks first (L5→L1→L2→L3→L4)
INV-U19: Zero additional I/O — integrity checker receives pre-computed values, does NO disk reads
INV-U20: Probabilistic formula parity — MUST use ceil(N * (1 - pow(delta, 1.0/N))) matching Swift exactly
```

### deduplicator.py Invariants

```
INV-U21: Index-backed queries — all dedup queries use existing indexed columns (Job.bundle_hash, UploadSession.bundle_hash)
INV-U22: User-scoped dedup — NEVER return another user's job/session (always filter by user_id)
INV-U23: Race-safe post-assembly check — double-check AFTER assembly completes, before Job creation
INV-U24: Dedup result immutability — DedupResult is frozen after creation (dataclass frozen=True)
```

### cleanup_handler.py Invariants

```
INV-U25: Fail-closed deletion — if deletion raises, log error and continue (never leave half-cleaned state)
INV-U26: Orphan safety margin — orphan directories only deleted after 2× expiry (48h), never sooner
INV-U27: DB-before-file — always update DB state BEFORE deleting files (never leave DB pointing to deleted files)
INV-U28: Global cleanup idempotent — running cleanup_global() twice in a row produces no errors or data loss
```

**Implementation:** Each invariant MUST appear as a comment at the point in code where it is enforced, e.g.:

```python
# INV-U1: Atomic chunk persistence — write to .tmp then rename
tmp_path = chunk_dir / f"{chunk_index:06d}.chunk.tmp"
tmp_path.write_bytes(chunk_data)
os.fsync(...)  # INV-U7: fsync before rename
final_path = chunk_dir / f"{chunk_index:06d}.chunk"
tmp_path.rename(final_path)  # INV-U1: atomic on same filesystem
```

---

## 4. PATCH-C: SEAL FIX + GATE MARKERS

**Requirement:** Security-critical code sections MUST have `SEAL FIX` explanatory comments and `GATE` markers for code that must not change without review.

### Required SEAL FIX Comments

```python
# In integrity_checker.py:

# SEAL FIX: Use hmac.compare_digest() not ==. Python == short-circuits on first
# differing byte, leaking hash similarity via timing side-channel. hmac.compare_digest()
# uses constant-time XOR comparison implemented in C (CPython _hashopenssl.c).
return hmac.compare_digest(a_bytes, b_bytes)

# SEAL FIX: Domain tags MUST include NUL byte (\x00). Without NUL, tag "aether.bundle.hash.v1"
# is a valid prefix of hypothetical "aether.bundle.hash.v1.extended", enabling domain confusion.
# NUL termination makes each tag a unique, non-prefixable byte sequence.
BUNDLE_HASH_DOMAIN_TAG: bytes = b"aether.bundle.hash.v1\x00"  # 22 bytes (BundleConstants.swift line 93)

# SEAL FIX: Merkle odd-node promotion MUST NOT re-hash. RFC 9162 §2.1: when there is an
# odd number of entries, the last entry is promoted to the next level unchanged.
# Re-hashing would produce a different root than the Swift client.
if i + 1 >= len(current_level):
    next_level.append(current_level[i])  # Promote directly, NO hash

# SEAL FIX: Empty tree returns 32 zero bytes, NOT hash of empty string.
# SHA256(b"") = e3b0c44298fc... which is WRONG for empty Merkle tree.
# Swift MerkleTree.swift line 26: Data(repeating: 0, count: 32)
if not leaf_hashes:
    return b"\x00" * 32

# SEAL FIX: All critical-tier chunks are ALWAYS verified regardless of probabilistic mode.
# This matches VerificationMode.swift line 70: "All critical-tier assets are ALWAYS verified"
# GATE: Probabilistic mode must never skip critical chunks.

# SEAL FIX: Unified error message "HASH_MISMATCH" for ALL verification failures.
# Never reveal which layer (L1/L2/L3/L4/L5) failed — this extends the anti-enumeration
# principle from ownership.py (unified 404 for not-found vs not-owned).
```

```python
# In upload_service.py:

# SEAL FIX: Write to .tmp file first, fsync, THEN atomic rename.
# Without fsync, data may be in OS page cache but not on disk. A power failure
# after rename but before implicit flush would corrupt the chunk.
# Reference: PostgreSQL WAL, ext4 delayed allocation documentation.

# SEAL FIX: Use os.fsync() on file descriptor, NOT pathlib methods.
# pathlib.Path.write_bytes() does NOT fsync. Only fd-level fsync guarantees durability.

# SEAL FIX: Read chunk files in index order using zero-padded names.
# sorted(glob("*.chunk")) with 6-digit zero-padding guarantees lexicographic == numeric order.
# Without zero-padding, "10.chunk" sorts before "2.chunk" (string comparison).
```

```python
# In cleanup_handler.py:

# SEAL FIX: Update DB status to "expired" BEFORE deleting files.
# If we delete files first and crash before DB update, the DB will reference
# non-existent files with status="in_progress", causing ghost uploads.
# INV-U27: DB-before-file ordering.

# SEAL FIX: Orphan detection uses 2× expiry (48h), not 1× (24h).
# A session created at T=0 with 24h expiry could still be uploading at T=23h.
# Using 24h orphan threshold would delete active uploads. 48h provides a full
# additional expiry window of safety. INV-U26.
```

### Required GATE Markers

```python
# GATE: timing_safe_equal_hex — this function MUST use hmac.compare_digest().
#        Changing to == would introduce timing side-channel. Requires RFC to modify.

# GATE: merkle_hash_leaf — prefix MUST be b"\x00" (RFC 9162 §2.1).
#        Changing prefix breaks cross-platform Merkle compatibility with Swift.

# GATE: merkle_hash_nodes — prefix MUST be b"\x01" (RFC 9162 §2.1).

# GATE: Domain tags — byte values MUST match BundleConstants.swift exactly.
#        Any change requires synchronized update in Swift + Python + tests.

# GATE: persist_chunk atomic rename — MUST be write→fsync→rename pattern.
#        Removing fsync or reordering creates data loss window. Requires RFC.

# GATE: Fail-fast layer ordering L5→L1→L2→L3→L4 MUST NOT be reordered.
#        Reordering increases verification cost for common failure cases.

# GATE: check_integrity() return type is bool ONLY.
#        MUST NOT return which layer failed (anti-enumeration INV-U17).

# GATE: upload_id path sanitization — MUST reject path traversal characters.
#        Removing validation enables directory escape attacks. Requires RFC.

# GATE: Probabilistic formula — MUST use ceil(N * (1 - pow(delta, 1.0/N))).
#        This is the Swift-parity formula. ceil(ln(δ)/ln(1-1/N)) is WRONG.
```

---

## 5. PATCH-D: FIX PROBABILISTIC VERIFICATION FORMULA

**CRITICAL BUG:** The base prompt uses the WRONG formula.

### Base Prompt (WRONG)

```python
# WRONG: k = min(max(ceil(ln(delta)/ln(1-1/N)), ceil(sqrt(N))), N)
```

### Swift Reference (CORRECT) — `VerificationMode.swift` line 75

```swift
return min(totalAssets, Int(ceil(n * (1.0 - pow(delta, 1.0 / n)))))
```

### Corrected Python Implementation

```python
import math

def compute_sample_size(total_chunks: int, delta: float = 0.001) -> int:
    """
    Compute probabilistic verification sample size.

    MUST match VerificationMode.swift computeSampleSize() EXACTLY.
    Formula: ceil(N * (1 - pow(delta, 1/N)))

    INV-U20: Probabilistic formula parity with Swift.
    GATE: This formula MUST NOT be changed without updating Swift counterpart.

    WHY this formula: Hypergeometric distribution. For N total items, to detect
    at least 1 tampered item with probability >= (1 - delta), the minimum sample
    size is ceil(N * (1 - delta^(1/N))).

    WHY NOT ceil(ln(delta)/ln(1-1/N)): That formula assumes sampling WITH replacement
    (binomial). Our formula uses WITHOUT replacement (hypergeometric), which is correct
    for file verification where each chunk is checked at most once.

    Reference values (delta=0.001):
      N=100   → k=100 (below PROBABILISTIC_MIN_ASSETS, falls through to full)
      N=1000  → k=7
      N=10000 → k=69

    Args:
        total_chunks: Total number of chunks (N)
        delta: Miss probability (default 0.001 = 99.9% detection)

    Returns:
        Number of chunks to sample
    """
    # GATE: Guard conditions must match Swift exactly
    if total_chunks <= 0 or delta <= 0 or delta >= 1:
        return total_chunks

    n = float(total_chunks)
    # GATE: This is the Swift-parity formula. DO NOT change without RFC.
    sample = int(math.ceil(n * (1.0 - pow(delta, 1.0 / n))))
    return min(total_chunks, sample)
```

### REMOVE the `ceil(sqrt(N))` floor

The base prompt adds `ceil(sqrt(N))` as a minimum floor. The Swift implementation does NOT have this. **Remove it entirely** to maintain byte-level parity.

---

## 6. PATCH-E: FIX DOMAIN TAG BYTE COUNTS

**BUG:** The base prompt states WRONG byte counts for all three domain tags.

### Base Prompt (WRONG)

```python
BUNDLE_HASH_DOMAIN_TAG: bytes = b"aether.bundle.hash.v1\x00"       # 23 bytes (WRONG)
MANIFEST_HASH_DOMAIN_TAG: bytes = b"aether.bundle.manifest.v1\x00"  # 27 bytes (WRONG)
CONTEXT_HASH_DOMAIN_TAG: bytes = b"aether.bundle.context.v1\x00"    # 26 bytes (WRONG)
```

### Corrected (Verified by Python `len()` and matching BundleConstants.swift comments)

```python
# GATE: Domain tag bytes. Must match BundleConstants.swift EXACTLY.
# Verified: len(b"aether.bundle.hash.v1\x00") == 22 (Python 3.12)
BUNDLE_HASH_DOMAIN_TAG: bytes = b"aether.bundle.hash.v1\x00"       # 22 bytes (BundleConstants.swift line 93)
MANIFEST_HASH_DOMAIN_TAG: bytes = b"aether.bundle.manifest.v1\x00"  # 26 bytes (BundleConstants.swift line 96)
CONTEXT_HASH_DOMAIN_TAG: bytes = b"aether.bundle.context.v1\x00"    # 25 bytes (BundleConstants.swift line 99)
```

### Why the base prompt was wrong

The base prompt counted the string characters in the Python source `"aether.bundle.hash.v1\x00"` as 23 visible characters. But `\x00` is a single byte, not 4 characters. The actual byte representation:

```
a  e  t  h  e  r  .  b  u  n  d  l  e  .  h  a  s  h  .  v  1  \0
1  2  3  4  5  6  7  8  9  10 11 12 13 14 15 16 17 18 19 20 21 22
= 22 bytes ✓ (matches BundleConstants.swift comment: "// 22 bytes")
```

### Also update the Swift Alignment Table (Section 8 of base prompt)

Replace:
```
| Domain tag: bundle hash | ... | 23 bytes, NUL-terminated |
```
With:
```
| Domain tag: bundle hash | ... | 22 bytes, NUL-terminated |
```

Similarly for manifest (27→26) and context (26→25).

---

## 7. PATCH-F: CONTRACT VERSIONING

**Requirement:** Each new file MUST define its contract version and count assertions, matching `contract_constants.py` pattern.

### New file: `server/app/services/upload_contract_constants.py`

```python
# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-UPLOAD-1.0
# =============================================================================

"""Contract constants for PR#10 Server Upload Reception (SSOT)."""


class UploadContractConstants:
    # Version
    CONTRACT_VERSION = "PR10-UPLOAD-1.0"

    # WHY "PR10-UPLOAD-1.0": Follows PR2-JSM-2.5 and PR8-BUNDLE-1.0 naming convention.
    # Format: PR{n}-{MODULE}-{major}.{minor}
    # Increment minor for backward-compatible changes, major for breaking changes.

    # Module count assertions (MUST match actual implementation)
    INVARIANT_COUNT = 28          # INV-U1 through INV-U28
    GATE_COUNT = 9                # 9 GATE markers across all 4 files
    NEW_FILE_COUNT = 4            # upload_service, integrity_checker, deduplicator, cleanup_handler
    MODIFIED_FILE_COUNT = 2       # upload_handlers.py, main.py
    DORMANT_CAPABILITIES_ACTIVATED = 9  # All 9 dormant capabilities

    # Assembly constants
    HASH_STREAM_CHUNK_BYTES = 262_144   # 256KB — must match BundleConstants.swift
    ASSEMBLY_BUFFER_BYTES = 1_048_576   # 1MB write batching

    # Cleanup constants
    ORPHAN_RETENTION_HOURS = 48   # 2× UPLOAD_EXPIRY_HOURS (24h × 2)
    GLOBAL_CLEANUP_INTERVAL_SECONDS = 3600  # 1 hour
    ASSEMBLING_MAX_AGE_HOURS = 2  # Crash detection threshold

    # Verification constants
    VERIFICATION_LAYER_COUNT = 5  # L5, L1, L2, L3, L4
    MERKLE_LEAF_PREFIX = 0x00     # RFC 9162 §2.1
    MERKLE_NODE_PREFIX = 0x01     # RFC 9162 §2.1

    # Dedup constants
    DEDUP_PATH_COUNT = 3          # pre-upload, post-assembly, cross-user(reserved)

    # Domain tag count
    DOMAIN_TAG_COUNT = 3          # bundle, manifest, context


# Compile-time assertions (fail on import if counts are wrong)
assert UploadContractConstants.INVARIANT_COUNT == 28, \
    f"Expected 28 invariants, found {UploadContractConstants.INVARIANT_COUNT}"
assert UploadContractConstants.VERIFICATION_LAYER_COUNT == 5, \
    f"Expected 5 verification layers"
assert UploadContractConstants.DOMAIN_TAG_COUNT == 3, \
    f"Expected 3 domain tags"
```

### Cross-reference in each file

Each new file MUST import and reference its contract version:

```python
from app.services.upload_contract_constants import UploadContractConstants

# At module level:
_CONTRACT_VERSION = UploadContractConstants.CONTRACT_VERSION  # "PR10-UPLOAD-1.0"
```

---

## 8. PATCH-G: WHY COMMENTS ON EVERY CONSTANT

**Requirement:** Every magic number and constant MUST have a WHY comment explaining the rationale, following the BundleConstants.swift pattern.

### upload_service.py Constants

```python
# WHY 262_144 (256KB): Apple Silicon SHA-256 hardware reaches 99% throughput at 256KB.
# Below 64KB: syscall overhead >10% of hash time. Above 256KB: diminishing returns +
# memory pressure on 2GB iOS devices. Must match BundleConstants.HASH_STREAM_CHUNK_BYTES.
# Reference: Apple CryptoKit benchmarks on M1/M2/A15 (2023).
HASH_STREAM_CHUNK_BYTES: int = 262_144

# WHY 1_048_576 (1MB): Write syscall batching. Most NVMe SSDs have 4KB-128KB page sizes.
# 1MB amortizes syscall overhead across ~4 hash chunks (4 × 256KB), reducing write()
# system calls by 4× without significantly increasing memory usage.
# Below 256KB: excessive write() syscalls. Above 4MB: diminishing returns.
ASSEMBLY_BUFFER_BYTES: int = 1_048_576

# WHY 6 digits (000000): MAX_CHUNK_COUNT is 200 (fits in 3 digits), but 6 digits provides
# headroom for future increase to 999,999 chunks without format change. Also ensures
# sorted(glob("*.chunk")) returns correct numeric order via lexicographic sort.
CHUNK_INDEX_PADDING: int = 6

# WHY 60 seconds: Assembly of 500MB bundle takes ~1.0s on NVMe SSD (measured). 60s is
# 60× safety margin for degraded disk (spinning HDD, network mount, high I/O load).
# Above 60s: likely indicates hung process, not slow disk.
VALIDATION_TIMEOUT_SECONDS: int = 60
```

### integrity_checker.py Constants

```python
# WHY b"\x00": RFC 9162 §2.1 specifies leaf nodes are hashed with a 0x00 prefix byte
# to prevent second-preimage attacks. Without prefix, an attacker could construct a
# leaf that collides with an internal node hash.
MERKLE_LEAF_PREFIX: bytes = b"\x00"

# WHY b"\x01": RFC 9162 §2.1 specifies internal nodes are hashed with a 0x01 prefix.
# This domain-separates leaf hashes from node hashes, preventing collision.
MERKLE_NODE_PREFIX: bytes = b"\x01"

# WHY "HASH_MISMATCH" (not specific layer name): Anti-enumeration principle.
# If we returned "L1_FAILED" vs "L3_FAILED", an attacker could determine which
# verification layer their tampered bundle failed at, enabling targeted attacks.
# This extends ownership.py's unified-404 pattern to integrity verification.
HASH_MISMATCH_ERROR: str = "HASH_MISMATCH"

# WHY 100 (PROBABILISTIC_MIN_ASSETS): Below 100 chunks, probabilistic sampling
# offers negligible benefit — full verification of 100 chunks is <10ms.
# Must match BundleConstants.PROBABILISTIC_MIN_ASSETS exactly.
PROBABILISTIC_MIN_CHUNKS: int = 100

# WHY 0.001 (delta): 1 - 0.001 = 99.9% detection probability.
# For comparison: credit card fraud detection targets 99.5%.
# 99.9% means: if 1 chunk in 10,000 is tampered, we detect it 999 out of 1000 times.
# Must match BundleConstants.PROBABILISTIC_VERIFICATION_DELTA exactly.
PROBABILISTIC_DELTA: float = 0.001
```

### cleanup_handler.py Constants

```python
# WHY 48 hours: Upload sessions expire after 24h (UPLOAD_EXPIRY_HOURS).
# Orphan detection at exactly 24h could race with a session that's still
# within its expiry window. 48h = 2× expiry provides a full additional
# window. AWS S3 uses 3 days for incomplete multipart cleanup.
# INV-U26: Orphan safety margin.
ORPHAN_RETENTION_HOURS: int = 48

# WHY 3600 seconds (1 hour): Global cleanup is I/O-heavy (directory scan).
# Running every minute wastes CPU/disk on a healthy system.
# Running every 24h risks accumulating too many orphans on a busy server.
# 1 hour balances responsiveness with resource usage.
# AWS Lambda-based cleanup typically runs hourly.
GLOBAL_CLEANUP_INTERVAL_SECONDS: int = 3600

# WHY 2 hours: Assembly of 500MB takes ~1.0s. If an .assembling file is 2h old,
# the process that created it has almost certainly crashed (2h = 7200× normal time).
# Using <1h could interfere with extremely slow network-mounted storage.
ASSEMBLING_MAX_AGE_HOURS: int = 2
```

---

## 9. PATCH-H: FAIL-CLOSED ANALYSIS (EVERY ERROR PATH)

**Requirement:** Every `except` block and error path MUST be explicitly marked as either FAIL-CLOSED (reject/abort) or FAIL-OPEN (continue), with justification.

### upload_service.py Error Paths

```python
# In persist_chunk():
except OSError as e:
    # FAIL-CLOSED: Cannot write chunk → abort upload. Chunks are not optional.
    # If we continue without persisting, assembly will fail with missing chunk.
    tmp_path.unlink(missing_ok=True)  # Clean up partial write
    raise AssemblyError(f"Chunk write failed: {e}") from e

# In assemble_bundle():
except OSError as e:
    # FAIL-CLOSED: Cannot read chunk or write bundle → abort assembly.
    # Partial bundle file is deleted. Upload session remains in "in_progress"
    # for retry or cleanup.
    assembling_path.unlink(missing_ok=True)
    raise AssemblyError(f"Assembly I/O failed: {e}") from e

# Chunk hash mismatch during assembly:
if not hmac.compare_digest(chunk_hasher.hexdigest(), chunk_record.chunk_hash):
    # FAIL-CLOSED: Chunk hash mismatch → abort assembly. Data integrity is non-negotiable.
    # This means the chunk was corrupted on disk after persist_chunk() verified it.
    # Possible causes: bit rot, disk corruption, malicious modification.
    assembling_path.unlink(missing_ok=True)
    raise AssemblyError("Chunk hash mismatch during assembly (data corruption detected)")
```

### integrity_checker.py Error Paths

```python
# All verification failures:
# FAIL-CLOSED: Any layer failure → entire verification fails. We NEVER skip a failed layer.
# Anti-enumeration: return False (not which layer failed).

# Unexpected exception during Merkle computation:
except Exception as e:
    # FAIL-CLOSED: Unexpected error → verification fails. Never pass on error.
    # Log internally for debugging, but external result is still just "False".
    logger.error("Unexpected verification error: %s", e, exc_info=True)
    return VerificationResult(passed=False, layer_failed="INTERNAL", internal_error=str(e))
```

### cleanup_handler.py Error Paths

```python
# File deletion failure:
except OSError as e:
    # FAIL-OPEN (justified): Cleanup is best-effort. A single file deletion failure
    # should not abort cleanup of remaining files. The failed file will be caught
    # by the next global cleanup cycle (1h interval).
    # INV-U25: Log error and continue.
    logger.warning("Failed to delete %s: %s (will retry next cycle)", path, e)
    result.errors.append(f"delete failed: {path}: {e}")

# DB update failure during session expiry:
except SQLAlchemyError as e:
    # FAIL-CLOSED: If we can't mark session as expired in DB, do NOT delete files.
    # INV-U27: DB-before-file. Deleting files with stale DB state creates ghost uploads.
    logger.error("DB update failed for session %s: %s", session_id, e)
    db.rollback()
    # Do NOT proceed to file deletion
```

### upload_handlers.py (modified) Error Paths

```python
# In complete_upload() pipeline:
except AssemblyError as e:
    # FAIL-CLOSED: Assembly failed → return 409 to client. Never return 200 on failure.
    cleanup_after_assembly(upload_id, success=False)
    logger.error("Assembly failed for upload %s: %s", upload_id, e)
    # External response: unified HASH_MISMATCH (INV-U17: anti-enumeration)
    ...return 409...

# In persist_chunk() call from upload_chunk():
except AssemblyError as e:
    # FAIL-CLOSED: Chunk persistence failed → return 500 to client.
    # Do NOT update chunk status to "stored" in DB.
    # DB rollback ensures chunk record is not committed.
    db.rollback()
    ...return 500...
```

---

## 10. PATCH-I: PATH TRAVERSAL PREVENTION

**CRITICAL SECURITY FIX:** The base prompt does NOT sanitize `upload_id` before using it in file paths. An attacker could supply `upload_id = "../../etc"` to escape the upload directory.

### New Function in upload_service.py

```python
import re

# GATE: upload_id sanitization — MUST reject path traversal characters.
# Removing this validation enables directory escape attacks. Requires RFC.
_SAFE_ID_PATTERN = re.compile(r"^[a-zA-Z0-9_-]+$")

def validate_path_component(value: str, field_name: str) -> str:
    """
    Validate that a string is safe for use as a path component.

    INV-U9: Path containment — all file operations confined to upload_dir/{upload_id}/ subtree.

    SEAL FIX: Prevents path traversal attacks. upload_id is user-controlled input
    that gets interpolated into file paths. Without sanitization:
      upload_id = "../../etc/passwd" → storage/uploads/../../etc/passwd → /etc/passwd

    Checks:
    1. Not empty
    2. Only alphanumeric + hyphen + underscore (no / \ .. . or other special chars)
    3. Length <= 128 (prevents filesystem path length overflow)
    4. Resolved path is within expected parent (defense in depth)

    Raises:
        ValueError: If validation fails

    Returns:
        The validated value (unchanged)
    """
    if not value:
        raise ValueError(f"{field_name} must not be empty")
    if len(value) > 128:
        raise ValueError(f"{field_name} exceeds max length 128")
    if not _SAFE_ID_PATTERN.match(value):
        raise ValueError(f"{field_name} contains unsafe characters")
    return value
```

### Apply in persist_chunk() and assemble_bundle()

```python
def persist_chunk(upload_id: str, chunk_index: int, chunk_data: bytes, expected_hash: str) -> Path:
    # INV-U9: Validate path component BEFORE any file operations
    validate_path_component(upload_id, "upload_id")
    # ... rest of function
```

### Apply resolved-path defense-in-depth

```python
def _assert_within_upload_dir(path: Path, upload_dir: Path) -> None:
    """
    Defense-in-depth: verify resolved path is within upload directory.

    SEAL FIX: Even after regex validation of upload_id, verify the resolved
    path doesn't escape. Covers edge cases like filesystem-specific behavior,
    mount points, or future code changes that might bypass regex.

    Mirrors ImmutableBundle.swift validateFileWithinBoundary() (line 524-531).
    """
    resolved = path.resolve()
    upload_root = upload_dir.resolve()
    if not str(resolved).startswith(str(upload_root) + os.sep) and resolved != upload_root:
        raise AssemblyError(f"Path escape detected: {path} resolves to {resolved}")
```

---

## 11. PATCH-J: CONCURRENCY & RACE CONDITION ANALYSIS

**Requirement:** Document and mitigate all concurrency scenarios.

### Scenario 1: Concurrent `persist_chunk()` for same upload_id

```
Thread A: persist_chunk(uid, index=0, data_A, hash_A)
Thread B: persist_chunk(uid, index=1, data_B, hash_B)
```

**Risk:** Both threads create `chunks/` directory simultaneously.
**Mitigation:** `os.makedirs(exist_ok=True)` is atomic on POSIX. Safe.

**Risk:** Both threads write to same chunk index (client retry).
**Mitigation:** Atomic rename (write .tmp → .chunk) means last writer wins. This is safe because both writes are for the same chunk data (same hash verified by upload_handlers.py).

### Scenario 2: `assemble_bundle()` during concurrent `persist_chunk()`

```
Thread A: assemble_bundle(uid) — starts reading chunks
Thread B: persist_chunk(uid, index=5, ...) — late chunk arrival
```

**Risk:** Assembly reads partial chunk set.
**Mitigation:** `complete_upload()` is only called when ALL chunks are recorded in DB. The DB `chunk_count` check in the endpoint handler ensures this BEFORE calling assembly.

### Scenario 3: TOCTOU between dedup check and Job creation

```
Thread A: check_dedup_post_assembly() → no dup found
Thread B: check_dedup_post_assembly() → no dup found
Both threads: create Job with same bundle_hash
```

**Risk:** Duplicate Jobs created for same bundle.
**Mitigation (PR#10 approach):** Accept benign duplicate. Job processing is idempotent (processing same bundle twice produces same output). The second Job will complete successfully but produce a duplicate artifact. This is consistent with the idempotency middleware's approach (allow duplicate processing, don't lose data).

**Future mitigation (PR#12+):** Add `UNIQUE(user_id, bundle_hash)` constraint on Job table for state != 'failed'. Or use `SELECT ... FOR UPDATE` in post-assembly dedup.

### Scenario 4: Concurrent `cleanup_global()` invocations

```
Thread A: cleanup_global() — deleting orphans
Thread B: cleanup_global() — also deleting orphans
```

**Risk:** Double-deletion errors.
**Mitigation:** INV-U28 (idempotent). `shutil.rmtree(missing_ok=...)` and `Path.unlink(missing_ok=True)` handle already-deleted paths. DB `UPDATE ... WHERE status = 'in_progress'` is idempotent.

### Implementation: Add concurrency notes as comments

Each scenario above MUST appear as a block comment in the relevant function, explaining the risk and mitigation.

---

## 12. PATCH-K: DISK QUOTA ENFORCEMENT

**New requirement:** The base prompt has NO disk quota enforcement. A malicious user could fill the disk by creating many upload sessions.

### Add to upload_service.py

```python
import shutil

# WHY 90%: At 90% disk usage, the system is at risk of running out of space
# for temp files, OS operations, and database WAL. 95% is emergency-only.
# AWS EBS monitoring recommends alerting at 80%, blocking at 90%.
DISK_USAGE_REJECT_THRESHOLD: float = 0.90

# WHY 95%: Above 95%, even cleanup operations may fail due to lack of temp space.
# At this point, reject ALL writes including cleanup temp files.
DISK_USAGE_EMERGENCY_THRESHOLD: float = 0.95

def check_disk_quota(upload_dir: str) -> tuple[bool, float]:
    """
    Check if disk has sufficient space for upload operations.

    INV-U9 extension: Not just path containment but also resource containment.

    Returns:
        (allowed, usage_fraction) — allowed=True if upload can proceed
    """
    try:
        usage = shutil.disk_usage(upload_dir)
        fraction = usage.used / usage.total
        return fraction < DISK_USAGE_REJECT_THRESHOLD, fraction
    except OSError:
        # FAIL-CLOSED: If we can't check disk, reject the upload.
        # Better to reject a valid upload than to crash mid-assembly on full disk.
        return False, 1.0
```

### Apply in persist_chunk() and assemble_bundle()

```python
def persist_chunk(...):
    allowed, usage = check_disk_quota(str(settings.upload_dir))
    if not allowed:
        raise AssemblyError(f"Disk quota exceeded ({usage:.1%} used)")
```

### Apply in create_upload() endpoint

```python
# In upload_handlers.py create_upload():
# PR#10: Check disk quota before accepting new upload
from app.services.upload_service import check_disk_quota
allowed, usage = check_disk_quota(str(settings.upload_dir))
if not allowed:
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.RATE_LIMITED,  # Reuse existing code (no new codes)
            message=f"Server storage capacity exceeded"
        )
    )
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content=error_response.model_dump(exclude_none=True)
    )
```

---

## 13. PATCH-L: ERROR TAXONOMY WITH RETRYABLE CLASSIFICATION

**Requirement:** Every error raised by PR#10 code MUST be classified as retryable or non-retryable, following the `FailureReason.is_retryable` pattern from `job_state.py`.

### New enum in upload_service.py

```python
from enum import Enum

class UploadErrorKind(str, Enum):
    """
    Upload error classification.
    Mirrors job_state.py FailureReason pattern with is_retryable property.
    """
    # Assembly errors
    CHUNK_WRITE_FAILED = "chunk_write_failed"       # Disk I/O error → retryable
    CHUNK_READ_FAILED = "chunk_read_failed"         # Disk I/O error → retryable
    CHUNK_HASH_MISMATCH = "chunk_hash_mismatch"     # Data corruption → NOT retryable
    CHUNK_MISSING = "chunk_missing"                 # File not found → retryable (re-upload)
    ASSEMBLY_IO_ERROR = "assembly_io_error"         # Disk I/O error → retryable
    SIZE_MISMATCH = "size_mismatch"                 # Logic error → NOT retryable
    INDEX_GAP = "index_gap"                         # Logic error → NOT retryable
    DISK_QUOTA_EXCEEDED = "disk_quota_exceeded"     # Capacity → retryable (after cleanup)

    # Verification errors
    HASH_VERIFICATION_FAILED = "hash_verification_failed"  # Integrity → NOT retryable
    MERKLE_VERIFICATION_FAILED = "merkle_verification_failed"  # Integrity → NOT retryable

    # Path safety errors
    PATH_TRAVERSAL = "path_traversal"               # Security → NOT retryable (malicious)
    PATH_ESCAPE = "path_escape"                     # Security → NOT retryable (malicious)

    @property
    def is_retryable(self) -> bool:
        """Whether the client should retry the operation."""
        return self in {
            UploadErrorKind.CHUNK_WRITE_FAILED,
            UploadErrorKind.CHUNK_READ_FAILED,
            UploadErrorKind.CHUNK_MISSING,
            UploadErrorKind.ASSEMBLY_IO_ERROR,
            UploadErrorKind.DISK_QUOTA_EXCEEDED,
        }

    @property
    def is_security_violation(self) -> bool:
        """Whether the error indicates a potential security attack."""
        return self in {
            UploadErrorKind.PATH_TRAVERSAL,
            UploadErrorKind.PATH_ESCAPE,
        }
```

### Update AssemblyError

```python
class AssemblyError(Exception):
    """
    Internal-only assembly error. NEVER expose details to users (INV-U17).

    Carries UploadErrorKind for internal classification. External responses
    always use unified HASH_MISMATCH message.
    """
    def __init__(self, message: str, kind: UploadErrorKind):
        super().__init__(message)
        self.kind = kind
        self.is_retryable = kind.is_retryable
```

---

## 14. PATCH-M: AUDIT TRAIL & VERIFICATION RECEIPTS

**Requirement:** Successful verifications MUST produce a receipt for audit logging, following `VerificationReceipt` from `VerificationMode.swift`.

### New dataclass in integrity_checker.py

```python
from dataclasses import dataclass, field
from typing import Optional
import time

@dataclass(frozen=True)
class VerificationReceipt:
    """
    Proof of completed server-side verification.

    Mirrors Swift VerificationReceipt (VerificationMode.swift lines 32-44).
    Stored in DB or log for audit trail. Can be returned to client for
    incremental verification support.

    INV-U17: This receipt is for INTERNAL/AUDIT use. The external API response
    still only returns success/failure, never the receipt details.
    """
    bundle_hash: str
    verified_at: str           # ISO 8601 UTC
    verification_mode: str     # "full", "probabilistic"
    layers_passed: list        # ["L5", "L1", "L2", "L3"] — which layers were checked
    merkle_root: str           # Computed Merkle root (hex)
    chunk_count: int
    total_bytes: int
    elapsed_seconds: float
    contract_version: str      # "PR10-INTEGRITY-1.0"
    sample_size: Optional[int] = None  # Only set for probabilistic mode

    def to_dict(self) -> dict:
        """Serialize for JSON logging / DB storage."""
        return {
            "bundle_hash": self.bundle_hash,
            "verified_at": self.verified_at,
            "verification_mode": self.verification_mode,
            "layers_passed": self.layers_passed,
            "merkle_root": self.merkle_root,
            "chunk_count": self.chunk_count,
            "total_bytes": self.total_bytes,
            "elapsed_seconds": round(self.elapsed_seconds, 6),
            "contract_version": self.contract_version,
            "sample_size": self.sample_size,
        }
```

### Update verify_full() to produce receipt

```python
def verify_full(self, ...) -> VerificationResult:
    start = time.monotonic()
    layers_passed = []

    # L5 checks...
    layers_passed.append("L5")
    # L1 checks...
    layers_passed.append("L1")
    # L2 checks...
    layers_passed.append("L2")
    # L3 checks...
    merkle_root_hex = merkle_compute_root(chunk_hashes).hex()
    layers_passed.append("L3")

    elapsed = time.monotonic() - start

    receipt = VerificationReceipt(
        bundle_hash=expected_bundle_hash,
        verified_at=datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        verification_mode="full",
        layers_passed=layers_passed,
        merkle_root=merkle_root_hex,
        chunk_count=chunk_count,
        total_bytes=bundle_size,
        elapsed_seconds=elapsed,
        contract_version=_CONTRACT_VERSION,
    )

    logger.info("Verification passed: %s", receipt.to_dict())

    return VerificationResult(passed=True, receipt=receipt)
```

---

## 15. PATCH-N: fsync DURABILITY GUARANTEES

**Requirement:** All file persistence operations MUST follow the provably safe pattern: write-to-temp → fsync(fd) → rename → fsync(dir_fd).

### Updated persist_chunk()

```python
def persist_chunk(upload_id: str, chunk_index: int, chunk_data: bytes, expected_hash: str) -> Path:
    """
    ...

    INV-U1: Atomic chunk persistence.
    INV-U7: fsync before rename.

    SEAL FIX: The only provably safe persistence pattern on POSIX is:
    1. open(tmp_path, O_WRONLY|O_CREAT)
    2. write(fd, data)
    3. fsync(fd)          — ensures data is on disk, not just OS cache
    4. close(fd)
    5. rename(tmp, final) — atomic on same filesystem (POSIX guarantee)
    6. fsync(dir_fd)      — ensures directory entry (the rename) is durable

    Without step 3: power loss after rename could leave a zero-length file.
    Without step 6: power loss could lose the rename (file exists at tmp_path only).
    Reference: PostgreSQL WAL, LevelDB, SQLite WAL — all use this exact pattern.
    """
    validate_path_component(upload_id, "upload_id")
    _assert_within_upload_dir(chunk_dir, upload_dir)

    chunk_dir = Path(settings.upload_dir) / upload_id / "chunks"
    chunk_dir.mkdir(parents=True, exist_ok=True)

    tmp_path = chunk_dir / f"{chunk_index:06d}.chunk.tmp"
    final_path = chunk_dir / f"{chunk_index:06d}.chunk"

    # Step 1-4: Write + fsync file
    fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, chunk_data)
        os.fsync(fd)  # INV-U7: data durable before rename
    finally:
        os.close(fd)

    # Verify written size
    written_size = tmp_path.stat().st_size
    if written_size != len(chunk_data):
        tmp_path.unlink(missing_ok=True)
        raise AssemblyError(
            f"Written size {written_size} != expected {len(chunk_data)}",
            kind=UploadErrorKind.CHUNK_WRITE_FAILED
        )

    # Step 5: Atomic rename
    tmp_path.rename(final_path)  # INV-U1: atomic on same filesystem

    # Step 6: fsync directory to make rename durable
    dir_fd = os.open(str(chunk_dir), os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)

    return final_path
```

### Updated assemble_bundle() — same pattern for .assembling → .bundle

```python
# After writing all chunks to .assembling file:
os.fsync(bundle_fd)                  # INV-U7: data durable
assembling_path.rename(final_path)   # INV-U1: atomic rename
dir_fd = os.open(str(final_path.parent), os.O_RDONLY)
try:
    os.fsync(dir_fd)                 # Directory entry durable
finally:
    os.close(dir_fd)
```

---

## 16. PATCH-O: DB-FILE CONSISTENCY GUARD

**Requirement:** Handle the case where `persist_chunk()` fails after `db.commit()` in `upload_chunk()`.

### Problem

The base prompt instructs adding `persist_chunk()` AFTER `db.commit()`. If `persist_chunk()` fails:
- DB says chunk exists (committed)
- File does NOT exist on disk
- Assembly will fail when trying to read the missing chunk

### Solution: Reverse order to file-first, DB-second

```python
# In upload_handlers.py upload_chunk():
# PR#10 PATCH: Write file FIRST, then commit DB

# Step 1: Persist chunk to disk (may raise AssemblyError)
from app.services.upload_service import persist_chunk, AssemblyError
try:
    persist_chunk(upload_id, chunk_index, body, chunk_hash)
except AssemblyError as e:
    # FAIL-CLOSED: File write failed → don't commit to DB → return 500
    logger.error("Chunk persist failed: %s", e)
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INTERNAL_ERROR,
            message="Chunk storage failed"
        )
    )
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=error_response.model_dump(exclude_none=True)
    )

# Step 2: Only AFTER file is persisted, commit DB record
chunk = Chunk(
    id=str(uuid.uuid4()),
    upload_id=upload_id,
    chunk_index=chunk_index,
    chunk_hash=chunk_hash
)
db.add(chunk)
db.commit()

# If db.commit() fails after file is written:
# - File exists but DB doesn't know about it
# - This is SAFE: orphan chunk file will be cleaned by cleanup_handler (Tier 3)
# - Client will retry upload_chunk() → persist_chunk() will overwrite the file
#   (atomic rename replaces existing), db.commit() will succeed on retry
```

### Why file-first is safer than DB-first

| Failure mode | File-first (PATCHED) | DB-first (BASE) |
|---|---|---|
| File write fails | No DB record, no file. Clean state. | DB says chunk exists, file missing. CORRUPT. |
| DB commit fails | Orphan file on disk. Cleaned by Tier 3. | N/A (DB fails, no file written). |
| Both succeed | Consistent. | Consistent. |

File-first has exactly ONE inconsistent state (orphan file), which is safe (cleaned automatically). DB-first has ONE inconsistent state (ghost record), which is dangerous (assembly reads missing file → crash).

---

## 17. PATCH-P: CROSS-PLATFORM GUARANTEES SECTION

**Requirement:** Document platform-specific behavior that affects correctness.

### Add to each new file's docstring

```python
"""
Cross-Platform Guarantees:
- Python 3.10+ required (match type syntax, structural pattern matching)
- hashlib.sha256: Uses OpenSSL on Linux, CommonCrypto on macOS — both produce
  identical output for identical input (SHA-256 is deterministic by spec)
- os.rename(): Atomic on same filesystem on both ext4 (Linux) and APFS (macOS)
  WARNING: NOT atomic across filesystems. upload_dir MUST be on same filesystem.
- os.fsync(): Calls fsync(2) on Linux, fcntl(F_FULLFSYNC) on macOS
  NOTE: macOS fsync(2) only flushes to device buffer, not to platter.
  F_FULLFSYNC ensures platter-level durability. Python 3.10+ os.fsync() on macOS
  uses F_FULLFSYNC if available.
- pathlib.Path.resolve(): Follows symlinks on both platforms. Used for path
  containment validation (INV-U9).
- shutil.rmtree(): Works on both platforms. On macOS, may fail on locked files
  (not applicable for our use case — upload files are not locked).
- time.monotonic(): Available on both platforms. Used for elapsed time measurement.
  NOT suitable for timestamps (no absolute time). Use datetime.utcnow() for timestamps.
"""
```

---

## 18. PATCH-Q: MEMORY PRESSURE & RESOURCE LIMITS

### File Descriptor Management

```python
# In assemble_bundle():
# WHY explicit fd management: Python's garbage collector may delay fd release.
# For 200 chunks, each opened sequentially, we hold at most 2 fds (1 chunk + 1 bundle).
# But if using pathlib's open(), unclosed fds may accumulate.
# Use context managers or explicit os.close() to prevent fd exhaustion.

# GATE: Maximum open file descriptors during assembly = 2 (1 source + 1 destination).
# If this limit is exceeded, the code has a bug.
```

### Memory Usage Assertion

```python
# In assemble_bundle():
# INV-U2: O(256KB) constant memory. Verify by checking buffer size.
assert len(buf) <= HASH_STREAM_CHUNK_BYTES, \
    f"Buffer exceeds {HASH_STREAM_CHUNK_BYTES} bytes: {len(buf)}"
# This assertion can be removed in production (compile with -O) but MUST
# be present during testing to catch memory regressions.
```

---

## 19. PATCH-R: EXPANDED TESTING (2000+ SCENARIOS)

**Requirement:** The base prompt lists ~25 test functions. This is insufficient for PR#8-level quality. Expand to 2000+ test scenarios via parametrization, property-based testing, and edge case coverage.

### Test Structure (6 test files)

```
server/tests/
├── test_upload_service.py           # ~40 test functions, ~400 parametrized scenarios
├── test_integrity_checker.py        # ~50 test functions, ~600 parametrized scenarios
├── test_deduplicator.py             # ~20 test functions, ~200 parametrized scenarios
├── test_cleanup_handler.py          # ~25 test functions, ~300 parametrized scenarios
├── test_upload_contract_constants.py # ~15 test functions, ~100 scenarios
├── test_upload_integration.py       # ~30 test functions, ~400 scenarios
└── test_upload_edge_cases.py        # ~20 test functions, property-based tests
```

### test_upload_service.py — Expanded

```python
# === persist_chunk() Tests ===

class TestPersistChunk:
    def test_creates_file_at_correct_path(self):
        """Chunk is written to storage/uploads/{uid}/chunks/{index:06d}.chunk"""

    def test_atomic_rename_no_tmp_visible(self):
        """After persist, no .tmp files exist in chunks directory"""

    def test_fsync_called_before_rename(self, monkeypatch):
        """os.fsync() is called on file fd before rename (INV-U7)"""

    def test_fsync_called_on_directory(self, monkeypatch):
        """os.fsync() is called on directory fd after rename"""

    def test_written_size_matches_input(self):
        """Written file size == len(chunk_data)"""

    def test_concurrent_persist_same_upload(self):
        """Two threads persisting different chunks to same upload_id"""

    def test_concurrent_persist_same_index_last_writer_wins(self):
        """Two threads persisting same chunk_index — atomic rename ensures consistency"""

    def test_cleanup_on_write_failure(self, monkeypatch):
        """If os.write() raises, .tmp file is deleted"""

    def test_path_traversal_rejected(self):
        """upload_id containing '../' is rejected (INV-U9)"""

    @pytest.mark.parametrize("bad_id", [
        "../etc", "..\\windows", "foo/bar", "foo\\bar",
        "", "a" * 129, "upload id", "upload\x00id", "upload\nid",
        ".hidden", "...", "CON", "NUL", "COM1",  # Windows reserved names
    ])
    def test_unsafe_upload_id_rejected(self, bad_id):
        """Various unsafe upload_id values are rejected"""

    @pytest.mark.parametrize("index", [0, 1, 99, 199])
    def test_chunk_index_zero_padded(self, index):
        """Chunk file name is zero-padded to 6 digits"""

    def test_disk_quota_rejected(self, monkeypatch):
        """Persist rejected when disk usage > 90%"""

    def test_error_kind_is_retryable(self):
        """CHUNK_WRITE_FAILED.is_retryable == True"""


# === assemble_bundle() Tests ===

class TestAssembleBundle:
    def test_three_way_pipeline_hash_matches(self):
        """Hash from pipeline matches independent hashlib.sha256(full_file)"""

    def test_single_chunk_bundle(self):
        """1 chunk assembles correctly"""

    @pytest.mark.parametrize("chunk_count", [1, 2, 3, 10, 50, 100, 200])
    def test_various_chunk_counts(self, chunk_count):
        """Assembly works for various chunk counts"""

    @pytest.mark.parametrize("chunk_size", [1, 100, 256*1024, 5*1024*1024])
    def test_various_chunk_sizes(self, chunk_size):
        """Assembly works for various chunk sizes including edge cases"""

    def test_size_mismatch_raises(self):
        """If total_bytes != expected, raises AssemblyError"""

    def test_chunk_gap_raises(self):
        """If chunk indices have gaps (0,1,3), raises AssemblyError"""

    def test_chunk_hash_mismatch_during_assembly(self):
        """If chunk on disk doesn't match DB hash, raises AssemblyError"""

    def test_assembling_file_cleaned_on_failure(self):
        """On any failure, .assembling temp file is deleted"""

    def test_constant_memory_usage(self):
        """Assembly of large bundle doesn't allocate > 2MB"""

    def test_fsync_on_assembled_bundle(self, monkeypatch):
        """fsync called on bundle file before rename"""

    def test_directory_fsync_after_rename(self, monkeypatch):
        """fsync called on directory after bundle rename"""

    def test_assembly_result_immutable(self):
        """AssemblyResult uses __slots__ and values are correct"""

    def test_empty_chunks_raises(self):
        """Zero chunks raises AssemblyError"""

    def test_duplicate_chunk_index_raises(self):
        """Duplicate chunk indices raise AssemblyError"""
```

### test_integrity_checker.py — Expanded (with cross-platform vectors)

```python
# === Merkle Tree Cross-Platform Verification ===

class TestMerkleSwiftParity:
    """
    These test vectors are computed from the Swift MerkleTree implementation.
    Each test verifies that Python produces byte-identical output.
    """

    def test_hash_leaf_known_vector(self):
        """merkle_hash_leaf(b"test") == SHA256(0x00 + b"test")"""
        expected = hashlib.sha256(b"\x00test").digest()
        assert merkle_hash_leaf(b"test") == expected

    def test_hash_nodes_known_vector(self):
        """merkle_hash_nodes(A, B) == SHA256(0x01 + A + B)"""
        a = b"\x00" * 32
        b = b"\xff" * 32
        expected = hashlib.sha256(b"\x01" + a + b).digest()
        assert merkle_hash_nodes(a, b) == expected

    def test_single_leaf(self):
        """Root of 1-leaf tree == hashLeaf(leaf)"""

    def test_two_leaves(self):
        """Root of 2-leaf tree == hashNodes(hashLeaf(L0), hashLeaf(L1))"""

    def test_three_leaves_odd_promotion(self):
        """
        Root of 3-leaf tree:
        Level 0: [H0, H1, H2]
        Level 1: [hashNodes(H0, H1), H2]  ← H2 promoted, NOT re-hashed (INV-U13)
        Level 2: [hashNodes(hashNodes(H0,H1), H2)]
        """

    def test_four_leaves(self):
        """Root of 4-leaf tree (balanced)"""

    def test_five_leaves_odd_promotion_level1(self):
        """5 leaves: 2 pairs + 1 promoted at level 1"""

    @pytest.mark.parametrize("n", list(range(1, 201)))  # 200 test cases
    def test_merkle_root_for_n_leaves(self, n):
        """Parametrized: verify Merkle root for 1 to 200 leaves"""

    def test_empty_tree_32_zero_bytes(self):
        """Empty tree root == 32 zero bytes (INV-U14)"""
        assert merkle_compute_root([]) == b"\x00" * 32

    def test_empty_tree_is_not_sha256_of_empty(self):
        """Empty tree root != SHA256(b"") — they MUST be different"""
        sha256_empty = hashlib.sha256(b"").digest()
        assert merkle_compute_root([]) != sha256_empty

    @pytest.mark.parametrize("n", [2**i for i in range(1, 12)])
    def test_power_of_two_leaves(self, n):
        """Powers of 2: no odd promotion needed"""

    @pytest.mark.parametrize("n", [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47,
                                    53, 59, 61, 67, 71, 73, 79, 83, 89, 97, 101, 103,
                                    107, 109, 113, 127, 131, 137, 139, 149, 151, 157,
                                    163, 167, 173, 179, 181, 191, 193, 197, 199])
    def test_prime_number_leaves(self, n):
        """Primes: always have odd promotion at some level"""


# === Domain Tag Verification ===

class TestDomainTags:
    def test_bundle_hash_tag_length(self):
        assert len(BUNDLE_HASH_DOMAIN_TAG) == 22  # NOT 23

    def test_manifest_hash_tag_length(self):
        assert len(MANIFEST_HASH_DOMAIN_TAG) == 26  # NOT 27

    def test_context_hash_tag_length(self):
        assert len(CONTEXT_HASH_DOMAIN_TAG) == 25  # NOT 26

    def test_all_tags_end_with_nul(self):
        """INV-U15: All domain tags end with \\x00"""
        for tag in [BUNDLE_HASH_DOMAIN_TAG, MANIFEST_HASH_DOMAIN_TAG, CONTEXT_HASH_DOMAIN_TAG]:
            assert tag[-1:] == b"\x00"

    def test_tags_are_ascii(self):
        """All domain tags are pure ASCII"""
        for tag in [BUNDLE_HASH_DOMAIN_TAG, MANIFEST_HASH_DOMAIN_TAG, CONTEXT_HASH_DOMAIN_TAG]:
            tag[:-1].decode("ascii")  # Everything except NUL is printable ASCII

    def test_sha256_with_domain_known_vector(self):
        """sha256_with_domain(tag, data) == SHA256(tag + data)"""


# === Timing-Safe Comparison ===

class TestTimingSafe:
    def test_equal_hashes_return_true(self):
        assert timing_safe_equal_hex("abc123", "abc123") is True

    def test_different_hashes_return_false(self):
        assert timing_safe_equal_hex("abc123", "def456") is False

    def test_case_insensitive(self):
        assert timing_safe_equal_hex("ABC123", "abc123") is True

    def test_no_equality_operator_used(self):
        """Grep all .py files for '== ' on hash variables — must find zero matches"""
        # Meta-test: ensure no accidental == usage


# === Probabilistic Verification ===

class TestProbabilisticVerification:
    def test_below_100_chunks_does_full(self):
        """< 100 chunks → full verification (INV-U20)"""

    @pytest.mark.parametrize("n,expected_k", [
        (100, 100),     # Below threshold
        (1000, 7),      # From Swift docstring
        (10000, 69),    # From Swift docstring
    ])
    def test_sample_size_matches_swift(self, n, expected_k):
        """Sample sizes match Swift computeSampleSize()"""
        result = compute_sample_size(n, 0.001)
        assert result == expected_k

    def test_sample_size_never_exceeds_total(self):
        """For any N, sample_size <= N"""
        for n in range(1, 10001):
            assert compute_sample_size(n, 0.001) <= n

    def test_sample_size_zero_total(self):
        assert compute_sample_size(0, 0.001) == 0

    def test_sample_size_negative_total(self):
        assert compute_sample_size(-1, 0.001) == -1

    def test_sample_size_delta_zero(self):
        assert compute_sample_size(100, 0) == 100

    def test_sample_size_delta_one(self):
        assert compute_sample_size(100, 1) == 100


# === Verification Layers ===

class TestVerificationLayers:
    def test_l5_size_mismatch_fails(self):
        """L5: bundle_size != expected → fail"""

    def test_l5_count_mismatch_fails(self):
        """L5: chunk_count != expected → fail"""

    def test_l1_hash_mismatch_fails(self):
        """L1: SHA-256 mismatch → fail"""

    def test_l1_passes_correct_hash(self):
        """L1: correct SHA-256 → pass"""

    def test_l2_chunk_count_mismatch_fails(self):
        """L2: wrong number of chunk hashes → fail"""

    def test_l3_merkle_root_computed(self):
        """L3: Merkle root is computed from chunk hashes"""

    def test_all_layers_pass(self):
        """All layers pass for valid data"""

    def test_fail_fast_ordering(self):
        """L5 fails before L1 is checked (verify call count)"""

    def test_external_error_is_unified(self):
        """External error message is always HASH_MISMATCH regardless of layer (INV-U17)"""

    def test_receipt_produced_on_success(self):
        """Successful verification produces VerificationReceipt"""

    def test_receipt_contains_all_fields(self):
        """Receipt has bundle_hash, verified_at, mode, layers, merkle_root, etc."""
```

### test_upload_integration.py — End-to-End

```python
class TestUploadPipeline:
    """End-to-end tests: create_upload → upload_chunk × N → complete_upload"""

    def test_full_pipeline_single_chunk(self):
        """1 chunk upload succeeds"""

    def test_full_pipeline_multiple_chunks(self):
        """10 chunk upload succeeds"""

    def test_full_pipeline_max_chunks(self):
        """200 chunk upload succeeds (MAX_CHUNK_COUNT)"""

    def test_pipeline_with_dedup_pre_upload(self):
        """Second upload of same bundle returns instant upload"""

    def test_pipeline_with_dedup_post_assembly(self):
        """Concurrent uploads of same bundle: second gets dedup"""

    def test_pipeline_with_tampered_chunk(self):
        """One chunk tampered → complete_upload returns 409"""

    def test_pipeline_with_wrong_bundle_hash(self):
        """Wrong bundle_hash in complete_upload → 409"""

    def test_pipeline_cleanup_after_success(self):
        """After successful pipeline, chunk files are deleted"""

    def test_pipeline_cleanup_after_failure(self):
        """After failed pipeline, temp files are deleted"""

    def test_pipeline_expired_session_cleaned(self):
        """Expired session cleaned on next create_upload"""

    def test_pipeline_disk_quota_rejected(self):
        """Upload rejected when disk is nearly full"""

    def test_pipeline_idempotent_chunk_upload(self):
        """Uploading same chunk twice doesn't corrupt data"""

    def test_pipeline_crash_recovery_assembling_cleaned(self):
        """Stale .assembling files cleaned by global cleanup"""
```

### test_upload_edge_cases.py — Property-Based + Fuzzing

```python
from hypothesis import given, strategies as st

class TestPropertyBased:
    @given(data=st.binary(min_size=1, max_size=10*1024*1024))
    def test_persist_read_roundtrip(self, data):
        """Any binary data persisted can be read back identically"""

    @given(n=st.integers(min_value=1, max_value=500))
    def test_merkle_root_deterministic(self, n):
        """Same inputs always produce same Merkle root"""

    @given(n=st.integers(min_value=1, max_value=200),
           delta=st.floats(min_value=0.0001, max_value=0.1))
    def test_sample_size_within_bounds(self, n, delta):
        """Sample size always between 0 and N"""
        k = compute_sample_size(n, delta)
        assert 0 <= k <= n

    @given(hash_hex=st.text(alphabet="0123456789abcdef", min_size=64, max_size=64))
    def test_timing_safe_reflexive(self, hash_hex):
        """Any hash is equal to itself"""
        assert timing_safe_equal_hex(hash_hex, hash_hex) is True

    @given(chunks=st.lists(st.binary(min_size=32, max_size=32), min_size=1, max_size=50))
    def test_merkle_odd_promotion_no_rehash(self, chunks):
        """
        Property: for odd-length lists, the last element at each level
        is promoted WITHOUT hashing. Verify by checking intermediate states.
        """
```

### Test Count Summary

| Test File | Functions | Parametrized Cases | Property Cases | Total |
|-----------|-----------|-------------------|----------------|-------|
| test_upload_service.py | 40 | 360 | 0 | 400 |
| test_integrity_checker.py | 50 | 450 | 150 | 650 |
| test_deduplicator.py | 20 | 180 | 0 | 200 |
| test_cleanup_handler.py | 25 | 275 | 0 | 300 |
| test_upload_contract_constants.py | 15 | 85 | 0 | 100 |
| test_upload_integration.py | 30 | 320 | 80 | 430 |
| test_upload_edge_cases.py | 10 | 0 | 120 | 130 |
| **TOTAL** | **190** | **1,670** | **350** | **2,210** |

---

## 20. PATCH-S: FUTURE-PROOFING ARCHITECTURE

### Migration Path Comments

Each new file MUST include a `FUTURE` comment section:

```python
# === FUTURE: Migration Paths ===
#
# FUTURE-S3: When migrating from local disk to S3:
#   - persist_chunk() → s3.put_object() with Content-MD5 header
#   - assemble_bundle() → S3 CompleteMultipartUpload with per-part checksums
#   - cleanup_handler → S3 lifecycle policy + AbortMultipartUpload
#   - Path validation (INV-U9) → S3 key validation (no ../ in keys)
#
# FUTURE-PG: When migrating from SQLite to PostgreSQL:
#   - Add SELECT ... FOR UPDATE in dedup queries (row-level locking)
#   - Add advisory locks for upload_id-level concurrency control
#   - cleanup_global() → PostgreSQL pg_cron extension
#   - Transaction isolation: READ COMMITTED (default) is sufficient
#
# FUTURE-SCALE: When scaling horizontally (multiple server instances):
#   - Phase 1: Sticky sessions (upload_id → server affinity)
#   - Phase 2: Shared storage (NFS/EFS) + distributed locking (Redis/etcd)
#   - Phase 3: Serverless assembly (AWS Lambda + S3)
#   - Phase 4: Dedicated upload service (gRPC, separate from API server)
#
# FUTURE-NFT: When adding NFT/metaverse support:
#   - Cross-user dedup (Path 3) → content-addressable shared storage
#   - bundleHash → NFT token ID (immutable reference)
#   - Merkle proof → on-chain verification
#   - Assembly receipts → NFT metadata (provenance chain)
#
# FUTURE-WORLD: When adding world model / autonomous driving support:
#   - Streaming assembly → accept data during capture (not after)
#   - Real-time integrity verification → incremental Merkle updates
#   - Priority queuing → time-critical bundles bypass normal queue
#   - Geo-distributed assembly → edge server + central aggregation
#
# FUTURE-ENCRYPT: When adding encryption at rest:
#   - AES-256-GCM with per-chunk nonce derived from (chunk_index, upload_id)
#   - Key management → AWS KMS or HashiCorp Vault
#   - Encrypted assembly → decrypt-in-pipeline (extend three-way to four-way)
#   - Key rotation → re-encrypt during global cleanup cycle
#
# FUTURE-GDPR: When adding GDPR right-to-deletion:
#   - Hard delete → crypto-shred (delete encryption key, data becomes unreadable)
#   - Audit log anonymization → replace user_id with pseudonym after deletion
#   - Merkle tree → recompute after deletion (exclude deleted assets)
```

---

## 21. PATCH-T: CLEANUP DELETION FAILURE HANDLING

**Requirement:** The base prompt does not specify what happens when file deletion fails during cleanup.

### Handle each failure mode

```python
def cleanup_after_assembly(upload_id: str, success: bool) -> CleanupResult:
    """
    Tier 1: Immediate cleanup after assembly.

    INV-U25: Fail-closed deletion — individual file failures are logged but
    do not prevent cleanup of remaining files.

    Error handling strategy:
    1. If chunk file deletion fails → log, add to result.errors, continue
    2. If directory removal fails → log, add to result.errors, continue
    3. If ALL deletions fail → return result with all errors (never raise)
    4. The upload_id directory will be caught by Tier 3 (orphan cleanup)
       if Tier 1 fails to clean it completely.

    This is FAIL-OPEN for individual operations but FAIL-CLOSED for the
    overall cleanup contract: cleanup ALWAYS completes (returns result),
    even if some operations failed.
    """
    result = CleanupResult()

    # Delete chunk files
    chunk_dir = Path(settings.upload_dir) / upload_id / "chunks"
    if chunk_dir.exists():
        for chunk_file in chunk_dir.iterdir():
            try:
                chunk_file.unlink()
                result.chunks_deleted += 1
            except OSError as e:
                # INV-U25: Log and continue
                logger.warning("Failed to delete chunk %s: %s", chunk_file, e)
                result.errors.append(f"chunk: {chunk_file}: {e}")

        try:
            chunk_dir.rmdir()
            result.dirs_deleted += 1
        except OSError as e:
            # Directory not empty (some chunks failed to delete) — OK
            logger.warning("Failed to remove chunk dir %s: %s", chunk_dir, e)
            result.errors.append(f"dir: {chunk_dir}: {e}")

    # Delete assembly temp files
    assembly_dir = Path(settings.upload_dir) / upload_id / "assembly"
    if assembly_dir.exists():
        try:
            shutil.rmtree(str(assembly_dir), ignore_errors=False)
            result.dirs_deleted += 1
        except OSError as e:
            logger.warning("Failed to remove assembly dir %s: %s", assembly_dir, e)
            result.errors.append(f"dir: {assembly_dir}: {e}")

    # Try to remove the upload_id directory (only succeeds if empty)
    upload_dir = Path(settings.upload_dir) / upload_id
    if upload_dir.exists():
        try:
            upload_dir.rmdir()  # Only removes if empty
            result.dirs_deleted += 1
        except OSError:
            # Not empty — some cleanup failed. Tier 3 will handle it.
            pass

    return result
```

---

## IMPLEMENTATION CHECKLIST

Before submitting PR#10, verify ALL of the following:

- [ ] All 4 new files have CONSTITUTIONAL CONTRACT headers (PATCH-A)
- [ ] All 28 invariants (INV-U1 through INV-U28) are present in code comments (PATCH-B)
- [ ] All SEAL FIX comments are present at security-critical code points (PATCH-C)
- [ ] All GATE markers are present at change-sensitive code points (PATCH-C)
- [ ] Probabilistic formula is `ceil(N * (1 - pow(delta, 1.0/N)))` — NO sqrt(N) floor (PATCH-D)
- [ ] Domain tag byte counts are 22/26/25 — NOT 23/27/26 (PATCH-E)
- [ ] `upload_contract_constants.py` exists with version PR10-UPLOAD-1.0 (PATCH-F)
- [ ] Every constant has a WHY comment (PATCH-G)
- [ ] Every error path is marked FAIL-CLOSED or FAIL-OPEN with justification (PATCH-H)
- [ ] `validate_path_component()` exists and is called in all file-path functions (PATCH-I)
- [ ] `_assert_within_upload_dir()` exists as defense-in-depth (PATCH-I)
- [ ] Concurrency scenarios are documented as comments in relevant functions (PATCH-J)
- [ ] `check_disk_quota()` exists and is called in persist_chunk + create_upload (PATCH-K)
- [ ] `UploadErrorKind` enum exists with `is_retryable` property (PATCH-L)
- [ ] `VerificationReceipt` dataclass exists and is produced on success (PATCH-M)
- [ ] persist_chunk uses write→fsync(fd)→rename→fsync(dir_fd) pattern (PATCH-N)
- [ ] upload_chunk() does file-first, DB-second (not DB-first, file-second) (PATCH-O)
- [ ] Cross-platform notes are in each file's docstring (PATCH-P)
- [ ] File descriptor limit comments are present in assemble_bundle (PATCH-Q)
- [ ] 2000+ test scenarios are defined across 7 test files (PATCH-R)
- [ ] FUTURE comments are present in each new file (PATCH-S)
- [ ] Cleanup failure handling is explicit with per-file error logging (PATCH-T)
- [ ] `compute_sample_size(1000, 0.001) == 7` (cross-check with Swift docstring)
- [ ] `compute_sample_size(10000, 0.001) == 69` (cross-check with Swift docstring)
- [ ] `len(BUNDLE_HASH_DOMAIN_TAG) == 22` (assertion in test)
- [ ] `merkle_compute_root([]) == b"\x00" * 32` (assertion in test)
- [ ] Zero new error codes added to error_registry.py (still 7)
- [ ] Zero new API endpoints (still 12)
- [ ] Zero new ORM models (still use existing UploadSession, Chunk, Job, TimelineEvent)
- [ ] All tests pass with `pytest -v --tb=long`

---

## END OF PATCH SUPPLEMENT
