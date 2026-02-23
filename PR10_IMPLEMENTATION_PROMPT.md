# PR#10 — Server Upload Reception: Implementation Prompt

> **Target Branch:** `pr10/server-upload-reception`
> **Base:** `main` (commit `2e82c96` — Merge pull request #84)
> **Scope:** 4 new files + modifications to 3 existing files
> **Zero GPU required** — All operations are CPU + disk I/O

---

## TABLE OF CONTENTS

1. [Project Context & Architecture](#1-project-context--architecture)
2. [Critical Discoveries in Existing Code (9 Dormant Capabilities)](#2-critical-discoveries-in-existing-code-9-dormant-capabilities)
3. [File 1: upload_service.py — Three-Way Pipeline Atomic Assembly Engine](#3-file-1-upload_servicepy)
4. [File 2: integrity_checker.py — Five-Layer Progressive Verification Engine](#4-file-2-integrity_checkerpy)
5. [File 3: deduplicator.py — Three-Path Fusion Dedup Engine](#5-file-3-deduplicatorpy)
6. [File 4: cleanup_handler.py — Three-Tier Self-Healing Cleanup Engine](#6-file-4-cleanup_handlerpy)
7. [Modifications to Existing Files](#7-modifications-to-existing-files)
8. [Swift Client Byte-Level Alignment Contract](#8-swift-client-byte-level-alignment-contract)
9. [Acceptance Criteria & Testing](#9-acceptance-criteria--testing)
10. [Constants & Cross-Reference Table](#10-constants--cross-reference-table)

---

## 1. PROJECT CONTEXT & ARCHITECTURE

### 1.1 What is Aether3D?

Aether3D is a 3D Gaussian Splatting asset management platform. The iOS client captures 3D scenes, packages them into "bundles" (sealed archives with hash verification), uploads them in chunks to a Python/FastAPI server, which then processes them into viewable 3DGS assets.

### 1.2 Relevant PRs (1-8) Summary

| PR | What it built | Key files |
|----|--------------|-----------|
| PR#1 | SSOT governance, CI, repo structure | `.github/workflows/*` |
| PR#2 | Job state machine (9 states, 14 transitions) | `jobs/job_state.py` |
| PR#3 | API Contract v2.0 (12 endpoints, 7 error codes) | `server/app/api/*` |
| PR#4-7 | Pipeline, capture, viewer, audit | `server/app/pipelines/*`, `App/Capture/*` |
| PR#8 | Immutable Bundle Format (seal, verify, manifest) | `Core/Upload/*`, `Core/MerkleTree/*`, `Core/Constants/*` |

### 1.3 Server Directory Structure

```
server/
├── main.py                          # FastAPI app, lifespan events
├── app/
│   ├── api/
│   │   ├── contract.py              # Pydantic v2 schemas (CreateUploadRequest, etc.)
│   │   ├── contract_constants.py    # APIContractConstants (SSOT)
│   │   ├── error_registry.py        # 7 error codes (closed set)
│   │   ├── routes.py                # 12 endpoints registered
│   │   └── handlers/
│   │       └── upload_handlers.py   # 4 upload endpoints (THE MAIN FILE TO MODIFY)
│   ├── core/
│   │   ├── config.py                # Settings (upload_dir, retention_days, etc.)
│   │   ├── storage.py               # cleanup_old_files(), save_upload_file(), etc.
│   │   ├── ownership.py             # Anti-enumeration pattern (unified 404)
│   │   └── errors.py                # AppError hierarchy
│   ├── models.py                    # SQLAlchemy ORM (UploadSession, Chunk, Job, etc.)
│   ├── database.py                  # SQLAlchemy engine + SessionLocal
│   ├── services/
│   │   ├── __init__.py              # (empty)
│   │   └── job_service.py           # Job processing with throttled progress
│   ├── middleware/                   # auth, idempotency, identity, rate_limit, request_size
│   ├── pipelines/                   # base, factory, dummy, nerfstudio
│   └── repositories/                # asset_repo, job_repo
└── storage/
    └── uploads/                     # Upload file storage root
```

### 1.4 Swift Client Upload Architecture (PR#8)

Key files the Python server MUST align with:

| Swift File | What it does | Critical details |
|-----------|-------------|-----------------|
| `Core/Upload/HashCalculator.swift` | Streaming SHA-256, domain-separated hash, timing-safe compare | `sha256OfFile()`: 256KB chunks, TOCTOU-safe; `timingSafeEqual()`: Double-HMAC via CryptoKit; `sha256WithDomain()`: `SHA256(tag.ascii + data)` |
| `Core/Upload/BundleManifest.swift` | Manifest computation with bundleHash | `bundleHash = SHA256(BUNDLE_HASH_DOMAIN_TAG \|\| contextHash \|\| canonicalBytes)` — uses manual canonical JSON, NOT JSONEncoder |
| `Core/MerkleTree/MerkleTreeHash.swift` | RFC 9162 hash primitives | `hashLeaf(data) = SHA256(0x00 \|\| data)`, `hashNodes(left, right) = SHA256(0x01 \|\| left \|\| right)` |
| `Core/MerkleTree/MerkleTree.swift` | Merkle tree (actor) | `append()` calls `hashLeaf()` internally; `computeRoot()` iterative bottom-up; odd nodes promoted directly |
| `Core/Constants/BundleConstants.swift` | All bundle constants | `HASH_STREAM_CHUNK_BYTES=262_144`, domain tags with NUL terminator, `DUAL_ALGORITHM_ENABLED=false`, `PROBABILISTIC_VERIFICATION_DELTA=0.001`, `PROBABILISTIC_MIN_ASSETS=100` |
| `Core/Upload/VerificationMode.swift` | Four verification modes | full, progressive, probabilistic (hypergeometric sampling), incremental |
| `Core/Upload/AdaptiveChunkSizer.swift` | Chunk size strategies | fixed (5MB), adaptive (2-20MB), aggressive |
| `Core/Upload/ChunkManager.swift` | Parallel upload coordinator | 1-4 parallel uploads, exponential backoff with decorrelated jitter |
| `Core/Upload/UploadSession.swift` | 8 session states | ChunkStatus tracking (index, offset, size, state, retryCount) |
| `Core/Upload/NetworkSpeedMonitor.swift` | Speed classification | slow (<5Mbps), normal (<50Mbps), fast (<100Mbps), ultrafast (>100Mbps) |
| `Core/Upload/ACI.swift` | Aether Content Identifier | Format: `aci:<version>:<algorithm>:<digest>` |

---

## 2. CRITICAL DISCOVERIES IN EXISTING CODE (9 DORMANT CAPABILITIES)

These are capabilities that are **defined in the existing code but NEVER activated**. PR#10 MUST activate ALL of them.

### Dormant Capability #1: `upload_chunk()` does NOT persist chunk binary data to disk

**Location:** `server/app/api/handlers/upload_handlers.py`, lines 316-323

**Current code:**
```python
chunk = Chunk(
    id=str(uuid.uuid4()),
    upload_id=upload_id,
    chunk_index=chunk_index,
    chunk_hash=chunk_hash
)
db.add(chunk)
db.commit()
chunk_status = "stored"
# BUG: No file I/O! The chunk binary (in `body` variable) is discarded after DB commit.
# The `body` bytes are read at line 214 but never written to disk.
```

**What PR#10 must do:** After `db.commit()`, call `persist_chunk(upload_id, chunk_index, body, chunk_hash)` to write the actual chunk bytes to `storage/uploads/{upload_id}/chunks/{index:06d}.chunk`.

### Dormant Capability #2: `cleanup_storage()` is never called

**Location:** `server/app/core/storage.py`, lines 51-68

The function `cleanup_storage()` exists and correctly iterates over uploads, artifacts, and nerfstudio_work directories. But **no code anywhere** calls it — not in `main.py` lifespan, not in any background task, not in any endpoint.

**What PR#10 must do:** Call `cleanup_storage()` from `cleanup_handler.py`'s global cleanup tier, and trigger it in `main.py` lifespan startup.

### Dormant Capability #3: `Job.bundle_hash` has `index=True` but is never queried

**Location:** `server/app/models.py`, line 65

```python
bundle_hash = Column(String, nullable=False, index=True)
```

The index exists, but no code ever queries `Job` by `bundle_hash`. The column is written when creating a Job but never read back for dedup purposes.

**What PR#10 must do:** `deduplicator.py` must query `Job.bundle_hash` for both pre-upload instant-upload detection and post-assembly dedup confirmation.

### Dormant Capability #4: `cleanup_old_files()` exists but has no trigger

**Location:** `server/app/core/storage.py`, lines 15-48

The function correctly implements retention-based file cleanup (iterates directory, checks mtime, deletes old files/dirs). But it's only called BY `cleanup_storage()`, which itself is never called (Dormant #2).

**What PR#10 must do:** Chain activation: `cleanup_handler.cleanup_global()` → `cleanup_storage()` → `cleanup_old_files()`.

### Dormant Capability #5: `UploadSession.bundle_hash` has `index=True`

**Location:** `server/app/models.py`, line 23

```python
bundle_hash = Column(String, nullable=False, index=True)
```

Never queried for dedup — only used for the `complete_upload()` consistency check against the request body.

**What PR#10 must do:** `deduplicator.py` pre-upload check should also query `UploadSession.bundle_hash` to detect if the same bundle already has an in-progress upload.

### Dormant Capability #6: RFC 9162 Merkle Tree is fully implemented in Swift

**Location:** `Core/MerkleTree/MerkleTree.swift` + `Core/MerkleTree/MerkleTreeHash.swift`

Complete implementation exists on the client side. The server has NO Merkle tree implementation at all.

**What PR#10 must do:** `integrity_checker.py` must implement a Python Merkle tree that produces **byte-identical** results to the Swift implementation for the same inputs.

### Dormant Capability #7: Domain-separated hashing with NUL terminator

**Location:** `Core/Constants/BundleConstants.swift`, lines 93-99

```swift
public static let BUNDLE_HASH_DOMAIN_TAG = "aether.bundle.hash.v1\0"      // 23 bytes incl NUL
public static let MANIFEST_HASH_DOMAIN_TAG = "aether.bundle.manifest.v1\0" // 27 bytes incl NUL
public static let CONTEXT_HASH_DOMAIN_TAG = "aether.bundle.context.v1\0"   // 26 bytes incl NUL
```

Python server has no domain-separated hashing at all. `upload_handlers.py` line 276 uses raw `hashlib.sha256(body).hexdigest()`.

**What PR#10 must do:** `integrity_checker.py` must define these exact same domain tags (including the NUL byte `\x00`) and use them in `sha256_with_domain()`.

### Dormant Capability #8: Double-HMAC timing-safe comparison

**Location:** `Core/Upload/HashCalculator.swift`, lines 170-181

Swift uses `SymmetricKey(size: .bits256)` + `HMAC<SHA256>` for timing-safe comparison, with the critical note that CryptoKit's `MessageAuthenticationCode.==` delegates to `safeCompare()`.

**What PR#10 must do:** Python must use `hmac.compare_digest()` for ALL hash comparisons. Never use `==` on hash strings.

### Dormant Capability #9: Anti-enumeration unified 404 pattern

**Location:** `server/app/core/ownership.py`, lines 61-77

`create_ownership_error_response()` returns the same 404 for both "not found" and "not owned" — preventing attackers from enumerating valid resource IDs.

**What PR#10 must do:** ALL verification failures in `integrity_checker.py` must return a unified `HASH_MISMATCH` error, never revealing which specific layer failed (L1? L2? L3? size? chunk count?). This extends the anti-enumeration principle to integrity verification.

---

## 3. FILE 1: `upload_service.py`

### Location: `server/app/services/upload_service.py` (NEW FILE)

### Purpose: Three-Way Pipeline Atomic Assembly Engine

### Design Philosophy

Traditional chunk assembly requires 3 full I/O passes:
1. Read chunks → write concatenated bundle file (I/O #1)
2. Read bundle file → compute SHA-256 hash (I/O #2)
3. Compare hash (CPU only)

**The three-way pipeline does it in 1 pass:**
```
for each chunk_file:
    buf = read(chunk_file)      # Way 1: Read
    bundle_file.write(buf)      # Way 2: Write
    hasher.update(buf)          # Way 3: Hash
```

Performance improvement: **3x** for 500MB bundles (~3.0s → ~1.0s).

### Constants (MUST match Swift exactly)

```python
# From BundleConstants.HASH_STREAM_CHUNK_BYTES (line 57)
HASH_STREAM_CHUNK_BYTES: int = 262_144  # 256KB — Apple Silicon SHA-256 optimal

# Assembly buffer for write() syscall batching
ASSEMBLY_BUFFER_BYTES: int = 1_048_576  # 1MB

# Directory templates
CHUNK_DIR_TEMPLATE = "{upload_id}/chunks"
ASSEMBLY_DIR_TEMPLATE = "{upload_id}/assembly"

# Validation timeout (from PR10 spec)
VALIDATION_TIMEOUT_SECONDS: int = 60  # 5000x safety margin (actual: ~0.01s for 500MB)
```

### Function: `persist_chunk(upload_id, chunk_index, chunk_data, expected_hash) -> Path`

**CRITICAL — This fixes Dormant Capability #1**

Must:
1. Create directory `storage/uploads/{upload_id}/chunks/` if not exists
2. Write chunk data to temp file `{chunk_index:06d}.chunk.tmp`
3. Verify written file size == `len(chunk_data)`
4. Atomic rename: `.chunk.tmp` → `.chunk` (same filesystem = atomic on ext4/APFS)
5. Return final path

Why zero-padded 6 digits: Ensures `sorted(glob("*.chunk"))` returns chunks in correct order. Max 200 chunks (APIContractConstants.MAX_CHUNK_COUNT) fits in 3 digits, but 6 digits provides future safety.

Why atomic rename: Prevents partial writes from being visible. If the process crashes mid-write, only the `.tmp` file exists, which cleanup_handler will detect and remove.

### Function: `assemble_bundle(upload_id, session, db) -> AssemblyResult`

**Core assembly function using three-way pipeline**

Must:
1. Query all `Chunk` records for this `upload_id`, ordered by `chunk_index`
2. Validate: `len(chunks) == session.chunk_count`
3. Validate: chunk indices are contiguous (0, 1, 2, ..., N-1)
4. Open temp file: `storage/uploads/{upload_id}/assembly/{bundle_hash}.bundle.assembling`
5. Initialize: `hasher = hashlib.sha256()`, `total_bytes = 0`, `chunk_hashes_for_merkle = []`
6. For each chunk record (in order):
   a. Open chunk file: `storage/uploads/{upload_id}/chunks/{index:06d}.chunk`
   b. Also initialize per-chunk hasher: `chunk_hasher = hashlib.sha256()`
   c. Read in 256KB buffers (HASH_STREAM_CHUNK_BYTES):
      - `bundle_file.write(buf)` — Way 2
      - `hasher.update(buf)` — Way 3 (whole-file hash)
      - `chunk_hasher.update(buf)` — Way 3b (per-chunk hash)
   d. After entire chunk read: verify `hmac.compare_digest(chunk_hasher.hexdigest(), chunk_record.chunk_hash)`
   e. Collect `bytes.fromhex(chunk_hasher.hexdigest())` into `chunk_hashes_for_merkle`
7. After all chunks: `bundle_file.flush()` then `os.fsync(bundle_file.fileno())`
8. Validate: `total_bytes == session.bundle_size`
9. Atomic rename: `.assembling` → `storage/uploads/{bundle_hash}.bundle`
10. Return `AssemblyResult(bundle_path, sha256_hex, total_bytes, elapsed_seconds)`

**Memory usage:** O(256KB) constant — never loads a full chunk into memory.

**Error handling:**
- Any failure → delete `.assembling` temp file → raise `AssemblyError`
- `AssemblyError` is internal — never exposed to users (anti-enumeration)

### Function: `verify_assembly(result, expected_bundle_hash) -> bool`

Simple timing-safe comparison:
```python
import hmac
return hmac.compare_digest(result.sha256_hex.lower(), expected_bundle_hash.lower())
```

### Class: `AssemblyResult`

```python
class AssemblyResult:
    __slots__ = ("bundle_path", "sha256_hex", "total_bytes", "elapsed_seconds")
```

Using `__slots__` for performance (no `__dict__` overhead).

### Class: `AssemblyState(str, Enum)`

WAL-style state tracking:
- `PENDING` — waiting to start
- `ASSEMBLING` — three-way pipeline running
- `HASHING` — hash computed, pending verification
- `COMPLETED` — success
- `FAILED` — error (cleanup triggered)
- `RECOVERED` — crash recovery re-assembly

### Class: `AssemblyError(Exception)`

Internal-only exception. Never expose details to users.

---

## 4. FILE 2: `integrity_checker.py`

### Location: `server/app/services/integrity_checker.py` (NEW FILE)

### Purpose: Five-Layer Progressive Verification Engine

### Layer Architecture

| Layer | Verification | I/O Cost | Source |
|-------|-------------|----------|--------|
| L5 | Structural integrity (size, chunk count, index continuity) | Zero | Math comparison |
| L1 | Whole-file SHA-256 | Zero (three-way pipeline byproduct) | `AssemblyResult.sha256_hex` |
| L2 | Chunk chain verification | Zero (three-way pipeline byproduct) | `chunk_hashes_for_merkle` |
| L3 | RFC 9162 Merkle tree rebuild | O(N) in-memory | Python Merkle implementation |
| L4 | Domain-separated bundleHash recomputation | O(1) | Reserved for future manifest verification |

**Execution order:** L5 → L1 → L2 → L3 → L4 (cheapest first, fail-fast)

**KEY INSIGHT:** L1 and L2 are computed FOR FREE during assembly. The `integrity_checker` receives pre-computed values, not raw files. This means the checker itself does almost zero disk I/O.

### RFC 9162 Merkle Tree Implementation (MUST BE BYTE-IDENTICAL TO SWIFT)

**Domain separation prefixes:**
```python
MERKLE_LEAF_PREFIX: bytes = b"\x00"   # MerkleTreeHash.swift line 30
MERKLE_NODE_PREFIX: bytes = b"\x01"   # MerkleTreeHash.swift line 33
```

**Function: `merkle_hash_leaf(data: bytes) -> bytes`**

Exact replica of `MerkleTreeHash.hashLeaf()` (MerkleTreeHash.swift lines 41-51):
```python
def merkle_hash_leaf(data: bytes) -> bytes:
    return hashlib.sha256(MERKLE_LEAF_PREFIX + data).digest()
```

Swift equivalent:
```swift
var input = Data([leafPrefix])  // 0x00
input.append(data)
return Data(SHA256.hash(data: input))
```

**Function: `merkle_hash_nodes(left: bytes, right: bytes) -> bytes`**

Exact replica of `MerkleTreeHash.hashNodes()` (MerkleTreeHash.swift lines 61-73):
```python
def merkle_hash_nodes(left: bytes, right: bytes) -> bytes:
    assert len(left) == 32 and len(right) == 32
    return hashlib.sha256(MERKLE_NODE_PREFIX + left + right).digest()
```

Swift equivalent:
```swift
guard left.count == 32, right.count == 32 else { fatalError() }
var input = Data([nodePrefix])  // 0x01
input.append(left)
input.append(right)
return Data(SHA256.hash(data: input))
```

**Function: `merkle_compute_root(leaf_hashes: List[bytes]) -> bytes`**

Exact replica of `MerkleTree.computeRoot()` (MerkleTree.swift lines 119-138):

```python
def merkle_compute_root(leaf_hashes: List[bytes]) -> bytes:
    if not leaf_hashes:
        return b"\x00" * 32  # Empty tree → 32 zero bytes (MerkleTree.swift line 26)

    current_level = list(leaf_hashes)
    while len(current_level) > 1:
        next_level = []
        i = 0
        while i < len(current_level):
            if i + 1 < len(current_level):
                next_level.append(merkle_hash_nodes(current_level[i], current_level[i + 1]))
            else:
                # Odd node: promote directly (MerkleTree.swift lines 83-84)
                next_level.append(current_level[i])
            i += 2
        current_level = next_level
    return current_level[0]
```

**CRITICAL DETAIL:** When there's an odd number of nodes at any level, the unpaired node is promoted directly to the next level WITHOUT hashing. This matches Swift's behavior exactly (MerkleTree.swift line 83: `nextLevel.append(currentLevel[Int(i)])`).

### Domain Separation Tags (MUST include NUL byte)

```python
BUNDLE_HASH_DOMAIN_TAG: bytes = b"aether.bundle.hash.v1\x00"       # 23 bytes (BundleConstants.swift line 93)
MANIFEST_HASH_DOMAIN_TAG: bytes = b"aether.bundle.manifest.v1\x00"  # 27 bytes (BundleConstants.swift line 96)
CONTEXT_HASH_DOMAIN_TAG: bytes = b"aether.bundle.context.v1\x00"    # 26 bytes (BundleConstants.swift line 99)
```

**CRITICAL:** The `\x00` (NUL byte) MUST be included. In Swift, the string literal `"aether.bundle.hash.v1\0"` includes the NUL when converted via `.data(using: .ascii)!` because Swift string literals treat `\0` as a NUL character, and `.data(using: .ascii)` preserves it in the byte representation.

**Function: `sha256_with_domain(tag: bytes, data: bytes) -> str`**

```python
def sha256_with_domain(tag: bytes, data: bytes) -> str:
    return hashlib.sha256(tag + data).hexdigest()
```

This matches `HashCalculator.sha256WithDomain()` (HashCalculator.swift lines 106-116):
```swift
let tagData = tag.data(using: .ascii)!
var combined = Data()
combined.append(tagData)
combined.append(data)
return SHA256.hash(data: combined).hexString
```

### Timing-Safe Comparison

**Function: `timing_safe_equal_hex(a: str, b: str) -> bool`**

```python
def timing_safe_equal_hex(a: str, b: str) -> bool:
    return hmac.compare_digest(a.lower().encode(), b.lower().encode())
```

This aligns with `HashCalculator.timingSafeEqualHex()` (HashCalculator.swift lines 191-205). Swift uses Double-HMAC via CryptoKit; Python uses `hmac.compare_digest()` which is also timing-safe (implemented in C with constant-time XOR comparison).

**NEVER use `==` to compare hash strings.** The `==` operator in Python short-circuits on first differing byte, leaking timing information.

### Class: `IntegrityChecker`

**Constant:** `HASH_MISMATCH_ERROR = "HASH_MISMATCH"` — unified error (anti-enumeration)

**Method: `verify_full(...) -> VerificationResult`**

Parameters (all provided by assembly pipeline — no file I/O needed):
- `assembly_sha256_hex`: Whole-file hash from three-way pipeline
- `expected_bundle_hash`: Client-provided bundle_hash
- `chunk_hashes`: List of chunk SHA-256 bytes (from three-way pipeline)
- `bundle_size` / `expected_size`: Actual vs declared size
- `chunk_count` / `expected_chunk_count`: Actual vs declared count

Execution:
1. L5: `bundle_size != expected_size` → FAIL
2. L5: `chunk_count != expected_chunk_count` → FAIL
3. L1: `timing_safe_equal_hex(assembly_sha256_hex, expected_bundle_hash)` → FAIL if mismatch
4. L2: `len(chunk_hashes) != expected_chunk_count` → FAIL
5. L3: Build Merkle tree from `chunk_hashes`, compute root (for audit trail logging)
6. L4: Reserved for future manifest-level verification (pass-through for PR#10)

**Method: `verify_probabilistic(...) -> VerificationResult`**

For large bundles (>100 chunks). Uses hypergeometric sampling aligned with `VerificationMode.probabilistic` in Swift:
- `PROBABILISTIC_MIN_ASSETS = 100` (BundleConstants.swift line 192)
- `PROBABILISTIC_VERIFICATION_DELTA = 0.001` (99.9% confidence) (BundleConstants.swift line 189)
- Below 100 chunks → full verification
- Above 100 → sample `k = min(max(ceil(ln(delta)/ln(1-1/N)), ceil(sqrt(N))), N)` chunks

### Module-Level Convenience Function

```python
_checker = IntegrityChecker()

def check_integrity(*, assembly_sha256_hex, expected_bundle_hash, chunk_hashes,
                    bundle_size, expected_size, chunk_count, expected_chunk_count) -> bool:
    result = _checker.verify_full(...)
    return result.passed
```

Returns only `True`/`False` — never leaks which layer failed (anti-enumeration).

---

## 5. FILE 3: `deduplicator.py`

### Location: `server/app/services/deduplicator.py` (NEW FILE)

### Purpose: Three-Path Fusion Dedup Engine

### Path 1: Pre-Upload Instant Upload Detection

**When:** Called in `create_upload()` BEFORE creating the UploadSession.

**Logic (activates Dormant Capabilities #3 and #5):**
```python
# Check for existing completed/processing/queued Job with same bundle_hash for this user
existing_job = db.query(Job).filter(
    Job.bundle_hash == bundle_hash,
    Job.user_id == user_id,
    Job.state.in_(["completed", "queued", "processing"])
).first()

if existing_job:
    return DedupResult(decision=INSTANT_UPLOAD, existing_job_id=existing_job.id)

# Also check for in-progress upload of same bundle (informational logging only)
existing_upload = db.query(UploadSession).filter(
    UploadSession.bundle_hash == bundle_hash,
    UploadSession.user_id == user_id,
    UploadSession.status == "in_progress"
).first()
```

**Performance:** Both queries use existing indexes (`Job.bundle_hash index=True`, `UploadSession.bundle_hash index=True`). Cost: O(log N).

### Path 2: Post-Assembly Dedup Confirmation

**When:** Called in `complete_upload()` AFTER assembly + verification pass, BEFORE creating new Job.

**Why needed:** During the time chunks are being uploaded (could be minutes for large bundles), another identical bundle might have completed. This is the last dedup checkpoint.

**Logic:**
```python
existing_job = db.query(Job).filter(
    Job.bundle_hash == bundle_hash,
    Job.user_id == user_id,
    Job.state.in_(["completed", "queued", "processing"])
).first()

if existing_job:
    # Delete just-assembled bundle file (duplicate)
    # Return existing job_id
    return DedupResult(decision=REUSE_BUNDLE, existing_job_id=existing_job.id)
```

### Path 3: Cross-User Content-Addressable Dedup (RESERVED — NOT ENABLED IN PR#10)

Pre-built interface for future PRs (NFT marketplace, metaverse, multi-tenant):
```python
def check_cross_user(self, bundle_hash: str, db: Session) -> DedupResult:
    # PR10: Always returns PROCEED (not enabled)
    # Future: Query all users' Jobs, create symlinks to shared storage
    return DedupResult(decision=PROCEED)
```

### Enum: `DedupDecision`
- `PROCEED` — No duplicate found, continue normal flow
- `INSTANT_UPLOAD` — Bundle exists, skip entire upload
- `REUSE_BUNDLE` — Bundle exists (detected post-assembly), reuse existing job

### Dataclass: `DedupResult`
- `decision: DedupDecision`
- `existing_job_id: Optional[str]`
- `existing_bundle_path: Optional[str]`
- `message: str`

### Module-Level Convenience Functions
```python
_deduplicator = Deduplicator()

def check_dedup_pre_upload(bundle_hash, user_id, db) -> DedupResult
def check_dedup_post_assembly(bundle_hash, user_id, db) -> DedupResult
```

---

## 6. FILE 4: `cleanup_handler.py`

### Location: `server/app/services/cleanup_handler.py` (NEW FILE)

### Purpose: Three-Tier Self-Healing Cleanup Engine

### Tier 1: Immediate Cleanup (after assembly)

**When:** Called at the end of `complete_upload()`, regardless of success or failure.

**What it cleans:**
1. All chunk files in `storage/uploads/{upload_id}/chunks/`
2. Assembly temp directory `storage/uploads/{upload_id}/assembly/`
3. The `{upload_id}/` directory itself (if empty after cleanup)

**Why:** Once chunks are assembled into a bundle, they're redundant. On failure, they're useless. Either way, clean them immediately.

### Tier 2: User-Level Cleanup (on create_upload)

**When:** Called at the START of `create_upload()`, before creating new session.

**What it cleans:**
1. Query expired `in_progress` UploadSessions for this user (where `expires_at < now`)
2. Update their status to `"expired"` in DB
3. Delete their file directories `storage/uploads/{session.id}/`

**Why:** Users who abandon uploads leave stale sessions and files. Cleaning on next upload is a natural trigger.

**Activates:** Dormant Capability #2 (cleanup_storage is now called) and #4 (cleanup_old_files has a trigger).

### Tier 3: Global System Cleanup (lifespan + periodic)

**When:**
- Once at FastAPI lifespan startup
- Every 1 hour (check `should_run_global()` which compares elapsed time)

**What it cleans:**
1. ALL expired `in_progress` sessions across ALL users → mark as `"expired"`, delete files
2. Orphan directories: directories in `storage/uploads/` that have no matching active UploadSession in DB AND are older than 48 hours (2x expiry, safety margin)
3. `.assembling` residual files: any `*.assembling` file older than 2 hours (crash detection)
4. Call `cleanup_storage()` from `storage.py` (activates Dormant #2) which calls `cleanup_old_files()` (activates Dormant #4)

### Constants
```python
EXPIRY_HOURS = APIContractConstants.UPLOAD_EXPIRY_HOURS  # 24h
ORPHAN_RETENTION_HOURS = EXPIRY_HOURS * 2                # 48h safety margin
GLOBAL_CLEANUP_INTERVAL_SECONDS = 3600                    # 1 hour
ASSEMBLING_MAX_AGE_HOURS = 2                              # Crash detection threshold
```

### Class: `CleanupResult`
Track all cleanup operations:
- `chunks_deleted: int`
- `dirs_deleted: int`
- `sessions_expired: int`
- `orphans_cleaned: int`
- `assembling_cleaned: int`
- `elapsed_seconds: float`
- `errors: List[str]`

### Module-Level Convenience Functions
```python
_handler = CleanupHandler()

def cleanup_after_assembly(upload_id: str, success: bool) -> CleanupResult
def cleanup_user_expired(user_id: str, db: Session) -> CleanupResult
def cleanup_global(db: Session) -> CleanupResult
def should_run_global_cleanup() -> bool
```

---

## 7. MODIFICATIONS TO EXISTING FILES

### 7.1 `upload_handlers.py` — Three modifications

#### Modification A: `upload_chunk()` — Add chunk persistence after DB commit

**Location:** After line 323 (`db.commit()`)

**Add:**
```python
# PR#10: Persist chunk binary to disk (fixes Dormant Capability #1)
from app.services.upload_service import persist_chunk
persist_chunk(upload_id, chunk_index, body, chunk_hash)
```

#### Modification B: `create_upload()` — Add dedup check + user cleanup

**Location:** After line 97 (concurrent limit check), before line 100 (creating session)

**Add:**
```python
# PR#10: User-level cleanup of expired sessions
from app.services.cleanup_handler import cleanup_user_expired
cleanup_user_expired(user_id, db)

# PR#10: Pre-upload dedup check (instant upload)
from app.services.deduplicator import check_dedup_pre_upload, DedupDecision
dedup_result = check_dedup_pre_upload(request_body.bundle_hash, user_id, db)
if dedup_result.decision == DedupDecision.INSTANT_UPLOAD:
    response_data = CompleteUploadResponse(
        upload_id="instant",
        bundle_hash=request_body.bundle_hash,
        status="completed",
        job_id=dedup_result.existing_job_id
    )
    api_response = APIResponse(success=True, data=response_data.model_dump())
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )
```

#### Modification C: `complete_upload()` — Replace simple status update with full pipeline

**Location:** Replace lines 443-468 (from `upload_session.status = "completed"` through `db.commit()` after timeline event)

**Replace with:**
```python
# PR#10: Full pipeline — assemble → verify → dedup → create job → cleanup
from app.services.upload_service import assemble_bundle, verify_assembly, AssemblyError
from app.services.integrity_checker import check_integrity
from app.services.deduplicator import check_dedup_post_assembly, DedupDecision
from app.services.cleanup_handler import cleanup_after_assembly

try:
    # Step 1: Three-way pipeline atomic assembly
    assembly_result = assemble_bundle(upload_id, upload_session, db)

    # Step 2: Five-layer integrity verification
    chunk_hashes = [bytes.fromhex(c.chunk_hash) for c in chunks]
    integrity_ok = check_integrity(
        assembly_sha256_hex=assembly_result.sha256_hex,
        expected_bundle_hash=upload_session.bundle_hash,
        chunk_hashes=chunk_hashes,
        bundle_size=assembly_result.total_bytes,
        expected_size=upload_session.bundle_size,
        chunk_count=len(chunks),
        expected_chunk_count=upload_session.chunk_count,
    )

    if not integrity_ok:
        cleanup_after_assembly(upload_id, success=False)
        assembly_result.bundle_path.unlink(missing_ok=True)
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.STATE_CONFLICT,
                message="HASH_MISMATCH"  # Unified error (anti-enumeration)
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=error_response.model_dump(exclude_none=True)
        )

    # Step 3: Post-assembly dedup check
    dedup = check_dedup_post_assembly(upload_session.bundle_hash, user_id, db)
    if dedup.decision == DedupDecision.REUSE_BUNDLE:
        assembly_result.bundle_path.unlink(missing_ok=True)
        cleanup_after_assembly(upload_id, success=True)
        upload_session.status = "completed"
        db.commit()
        response_data = CompleteUploadResponse(
            upload_id=upload_id,
            bundle_hash=upload_session.bundle_hash,
            status="completed",
            job_id=dedup.existing_job_id
        )
        api_response = APIResponse(success=True, data=response_data.model_dump())
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content=api_response.model_dump(exclude_none=True)
        )

    # Step 4: No duplicate — create new Job + Timeline (original logic)
    upload_session.status = "completed"
    db.commit()

    job_id = str(uuid.uuid4())
    job = Job(
        id=job_id,
        user_id=user_id,
        bundle_hash=upload_session.bundle_hash,
        state="queued"
    )
    db.add(job)

    timeline_event = TimelineEvent(
        id=str(uuid.uuid4()),
        job_id=job_id,
        timestamp=datetime.utcnow(),
        from_state=None,
        to_state="queued",
        trigger="job_created"
    )
    db.add(timeline_event)
    db.commit()

    # Step 5: Immediate cleanup of chunk files
    cleanup_after_assembly(upload_id, success=True)

except AssemblyError as e:
    cleanup_after_assembly(upload_id, success=False)
    # Log internally, return unified error externally
    import logging
    logging.getLogger(__name__).error("Assembly failed: %s", e)
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.STATE_CONFLICT,
            message="HASH_MISMATCH"  # Never expose internal error details
        )
    )
    return JSONResponse(
        status_code=status.HTTP_409_CONFLICT,
        content=error_response.model_dump(exclude_none=True)
    )
```

### 7.2 `main.py` — Add global cleanup to lifespan

**Location:** Inside the `lifespan()` function, after `Base.metadata.create_all(bind=engine)` (line 31)

**Add:**
```python
# PR#10: Run global cleanup on startup
from app.database import SessionLocal
from app.services.cleanup_handler import cleanup_global
import logging
logger = logging.getLogger(__name__)
db = SessionLocal()
try:
    result = cleanup_global(db)
    logger.info("Startup cleanup completed: %s", result.to_dict())
finally:
    db.close()
```

### 7.3 `services/__init__.py` — Keep empty (no changes needed)

The existing `__init__.py` is empty. New service files are imported directly by their callers.

---

## 8. SWIFT CLIENT BYTE-LEVEL ALIGNMENT CONTRACT

This table is the **absolute source of truth** for cross-platform consistency. Every Python implementation MUST produce identical bytes for identical inputs.

| Concept | Python Implementation | Swift Implementation | Verification |
|---------|----------------------|---------------------|--------------|
| Merkle leaf hash | `SHA256(b"\x00" + data)` | `SHA256(Data([0x00]) + data)` | Same 32 bytes for same input |
| Merkle node hash | `SHA256(b"\x01" + left + right)` | `SHA256(Data([0x01]) + left + right)` | Same 32 bytes for same inputs |
| Merkle odd promotion | `next_level.append(current_level[i])` | `nextLevel.append(currentLevel[Int(i)])` | Node passes through unchanged |
| Merkle empty tree | `b"\x00" * 32` | `Data(repeating: 0, count: 32)` | 32 zero bytes |
| Domain tag: bundle hash | `b"aether.bundle.hash.v1\x00"` | `"aether.bundle.hash.v1\0".data(using: .ascii)!` | 23 bytes, NUL-terminated |
| Domain tag: manifest | `b"aether.bundle.manifest.v1\x00"` | `"aether.bundle.manifest.v1\0".data(using: .ascii)!` | 27 bytes |
| Domain tag: context | `b"aether.bundle.context.v1\x00"` | `"aether.bundle.context.v1\0".data(using: .ascii)!` | 26 bytes |
| Domain-separated hash | `SHA256(tag_bytes + data)` | `SHA256(tagData + data)` | Same hex for same inputs |
| Streaming chunk size | `262_144` (256KB) | `BundleConstants.HASH_STREAM_CHUNK_BYTES = 262_144` | Identical |
| Timing-safe compare | `hmac.compare_digest(a, b)` | `HMAC<SHA256>.== (safeCompare)` | Both constant-time |
| Hash output format | `.hexdigest()` (64 lowercase hex) | `_hexLowercase(Array(digest))` | 64 lowercase hex chars |
| Probabilistic threshold | `100` chunks minimum | `PROBABILISTIC_MIN_ASSETS = 100` | Identical |
| Probabilistic confidence | `0.999` (delta=0.001) | `PROBABILISTIC_VERIFICATION_DELTA = 0.001` | Identical |

---

## 9. ACCEPTANCE CRITERIA & TESTING

### AC-1: Bundle hash is verified server-side
- `integrity_checker.check_integrity()` returns `True` for valid bundles
- Returns `False` for any tampered chunk

### AC-2: Duplicate bundles return existing job
- Pre-upload: `deduplicator.check_dedup_pre_upload()` returns `INSTANT_UPLOAD` with existing `job_id`
- Post-assembly: `deduplicator.check_dedup_post_assembly()` returns `REUSE_BUNDLE` with existing `job_id`

### AC-3: Failed uploads are cleaned up
- `cleanup_handler.cleanup_after_assembly(success=False)` removes all chunk files and temp directories
- Expired sessions cleaned on next `create_upload()` call
- Global cleanup removes orphan directories older than 48h

### AC-4: Chunk binary data persisted to disk
- `upload_service.persist_chunk()` writes files to `storage/uploads/{upload_id}/chunks/{index:06d}.chunk`
- Atomic rename ensures no partial writes visible

### AC-5: Merkle tree produces byte-identical results to Swift
- Test: Given identical chunk hashes as input, Python `merkle_compute_root()` produces the same root hash as Swift `MerkleTree.computeRoot()`
- Test edge cases: 1 leaf, 2 leaves, 3 leaves (odd), powers of 2, prime numbers of leaves

### AC-6: All hash comparisons use timing-safe functions
- Grep: No `==` used anywhere on hash strings (only `hmac.compare_digest`)

### AC-7: All verification failures return unified error
- HTTP response always `409 STATE_CONFLICT` with message `"HASH_MISMATCH"`
- Internal logs contain specific failure layer (for debugging)
- External response NEVER reveals which layer failed

### AC-8: Three-way pipeline uses O(1) memory
- 500MB bundle assembly never exceeds 2MB memory (256KB buffer + overhead)

### AC-9: Global cleanup activated
- `cleanup_storage()` called in lifespan startup
- `cleanup_old_files()` triggered through the chain

### Suggested Test Files

```
server/tests/
├── test_upload_service.py
│   ├── test_persist_chunk_creates_file
│   ├── test_persist_chunk_atomic_rename
│   ├── test_assemble_bundle_three_way_pipeline
│   ├── test_assemble_bundle_hash_matches_simple_sha256
│   ├── test_assemble_bundle_size_mismatch_raises
│   ├── test_assemble_bundle_chunk_gap_raises
│   └── test_assemble_bundle_fsync_called
├── test_integrity_checker.py
│   ├── test_merkle_hash_leaf_matches_swift
│   ├── test_merkle_hash_nodes_matches_swift
│   ├── test_merkle_compute_root_single_leaf
│   ├── test_merkle_compute_root_two_leaves
│   ├── test_merkle_compute_root_three_leaves_odd_promotion
│   ├── test_merkle_compute_root_empty
│   ├── test_domain_tag_includes_nul_byte
│   ├── test_sha256_with_domain_matches_swift
│   ├── test_timing_safe_equal_hex
│   ├── test_verify_full_all_layers_pass
│   ├── test_verify_full_l1_fails
│   ├── test_verify_full_l5_size_mismatch
│   └── test_verify_probabilistic_below_threshold_does_full
├── test_deduplicator.py
│   ├── test_pre_upload_no_dup
│   ├── test_pre_upload_instant_upload
│   ├── test_post_assembly_no_dup
│   ├── test_post_assembly_reuse_bundle
│   └── test_cross_user_always_proceed
└── test_cleanup_handler.py
    ├── test_immediate_cleanup_removes_chunks
    ├── test_immediate_cleanup_removes_assembly_dir
    ├── test_user_cleanup_expires_sessions
    ├── test_global_cleanup_orphan_directories
    └── test_global_cleanup_assembling_residuals
```

---

## 10. CONSTANTS & CROSS-REFERENCE TABLE

### From `APIContractConstants` (contract_constants.py)

| Constant | Value | Used in |
|----------|-------|---------|
| `MAX_BUNDLE_SIZE_BYTES` | 500 * 1024 * 1024 (500MB) | Size validation |
| `MAX_CHUNK_COUNT` | 200 | Count validation |
| `CHUNK_SIZE_BYTES` | 5 * 1024 * 1024 (5MB) | Server-authoritative chunk size |
| `MAX_CHUNK_SIZE_BYTES` | 5 * 1024 * 1024 (5MB) | 413 size limit |
| `UPLOAD_EXPIRY_HOURS` | 24 | Cleanup expiry |
| `MAX_ACTIVE_UPLOADS_PER_USER` | 1 | Concurrent limit |

### From `BundleConstants.swift` (constants used in Python)

| Constant | Value | Python equivalent |
|----------|-------|-------------------|
| `HASH_STREAM_CHUNK_BYTES` | 262_144 | `HASH_STREAM_CHUNK_BYTES = 262_144` |
| `BUNDLE_HASH_DOMAIN_TAG` | `"aether.bundle.hash.v1\0"` | `b"aether.bundle.hash.v1\x00"` |
| `MANIFEST_HASH_DOMAIN_TAG` | `"aether.bundle.manifest.v1\0"` | `b"aether.bundle.manifest.v1\x00"` |
| `CONTEXT_HASH_DOMAIN_TAG` | `"aether.bundle.context.v1\0"` | `b"aether.bundle.context.v1\x00"` |
| `PROBABILISTIC_VERIFICATION_DELTA` | 0.001 | `confidence = 0.999` |
| `PROBABILISTIC_MIN_ASSETS` | 100 | `if n < 100: full verification` |
| `DUAL_ALGORITHM_ENABLED` | false | Not used in PR#10 (reserved) |

### From `Settings` (config.py)

| Setting | Default | Purpose |
|---------|---------|---------|
| `upload_dir` | `"storage/uploads"` | Root for all upload files |
| `uploads_retention_days` | 7 | cleanup_old_files retention |
| `database_url` | `"sqlite:///./aether3d.db"` | SQLAlchemy URL |

### File Path Conventions

```
storage/uploads/
├── {upload_id}/
│   ├── chunks/
│   │   ├── 000000.chunk        # Chunk index 0
│   │   ├── 000001.chunk        # Chunk index 1
│   │   └── ...
│   └── assembly/
│       └── {bundle_hash}.bundle.assembling  # Temp file during assembly
├── {bundle_hash}.bundle         # Final assembled bundle (at root level)
└── ...
```

---

## FINAL NOTES

1. **No new dependencies.** PR#10 uses only Python stdlib (`hashlib`, `hmac`, `os`, `shutil`, `pathlib`, `math`, `random`, `time`, `uuid`, `logging`, `enum`, `dataclasses`, `typing`) plus existing project deps (`sqlalchemy`, `fastapi`, `pydantic`).

2. **No new API endpoints.** PR#10 modifies the behavior of existing endpoints only.

3. **No new ORM models.** PR#10 uses existing `UploadSession`, `Chunk`, `Job`, `TimelineEvent` models.

4. **No GPU.** PR#10 is pure CPU + disk I/O. GPU is needed starting PR#11+ for 3DGS training.

5. **Error code registry unchanged.** The `HASH_MISMATCH` message uses existing `STATE_CONFLICT` error code. No new error codes needed. The `error_registry.py` assertion `len(ERROR_CODE_REGISTRY) == 7` remains valid.

6. **PR#9 and PR#10 are parallel.** They don't depend on each other.
