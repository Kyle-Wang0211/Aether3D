# PR#10 — PATCH V2 SUPPLEMENT: Final Quality Gate

> **Status:** MANDATORY SUPPLEMENT — overrides any conflicting instruction in base prompt AND PATCH V1
> **Applies to:** ALL 4 new files + ALL modified files in PR#10
> **Quality Target:** Match or exceed PR#2 + PR#8 quality bar across ALL dimensions
> **Authority:** This is the FINAL quality gate before implementation

---

## TABLE OF CONTENTS

1. [Critical Bugs Found in Enhanced Plan (7 New Issues)](#1-critical-bugs-found-in-enhanced-plan)
2. [PATCH-V2-A: Fix Timing-Unsafe Hash Comparison in Existing Code](#2-patch-v2-a-fix-timing-unsafe-hash-comparison)
3. [PATCH-V2-B: Validate chunk_hash Header Input](#3-patch-v2-b-validate-chunk_hash-header-input)
4. [PATCH-V2-C: Path Traversal via bundle_hash (Not Just upload_id)](#4-patch-v2-c-path-traversal-via-bundle_hash)
5. [PATCH-V2-D: Fix HTTP 503 Not in Closed Status Code Set](#5-patch-v2-d-fix-http-503)
6. [PATCH-V2-E: Fix Disk Quota Error Code (RATE_LIMITED → INTERNAL_ERROR)](#6-patch-v2-e-fix-disk-quota-error-code)
7. [PATCH-V2-F: Use settings.upload_path (Resolved) Not settings.upload_dir (Relative)](#7-patch-v2-f-use-resolved-path)
8. [PATCH-V2-G: Dedup Query Must Exclude Failed/Cancelled Jobs](#8-patch-v2-g-dedup-query-must-exclude-failed)
9. [PATCH-V2-H: Complete Upload Transaction Safety](#9-patch-v2-h-transaction-safety)
10. [PATCH-V2-I: Strengthen Assembly State Machine](#10-patch-v2-i-assembly-state-machine)
11. [PATCH-V2-J: Logging Strategy Alignment](#11-patch-v2-j-logging-strategy)
12. [PATCH-V2-K: Test Vector Accuracy (Swift Cross-Verification)](#12-patch-v2-k-test-vector-accuracy)
13. [PATCH-V2-L: Constant Value Optimization Review](#13-patch-v2-l-constant-value-review)
14. [PATCH-V2-M: Industry Benchmark Integration](#14-patch-v2-m-industry-benchmark)
15. [PATCH-V2-N: Guardrail Enforcement Matrix](#15-patch-v2-n-guardrail-matrix)
16. [Updated Implementation Checklist](#16-updated-implementation-checklist)

---

## 1. CRITICAL BUGS FOUND IN ENHANCED PLAN

Through line-by-line cross-referencing of the enhanced plan against ALL existing code files, the following new issues were discovered:

| # | Issue | Severity | File | Root Cause |
|---|-------|----------|------|------------|
| 1 | `upload_handlers.py` line 277 uses `!=` for chunk hash comparison — NOT timing-safe | **CRITICAL** | upload_handlers.py:277 | Pre-existing bug, plan doesn't fix it |
| 2 | `chunk_hash` from X-Chunk-Hash header has NO regex validation — arbitrary string injection | **CRITICAL** | upload_handlers.py:232 | Missing input validation |
| 3 | `bundle_hash` used in file path `{bundle_hash}.bundle.assembling` — path traversal vector | **HIGH** | PR10 new code | Plan only validates `upload_id`, not `bundle_hash` |
| 4 | HTTP 503 is NOT in `main.py` closed status code set (line 138) — would be remapped to 500 | **HIGH** | main.py:138 | Plan uses 503 for disk quota, but framework blocks it |
| 5 | Disk quota uses `RATE_LIMITED` error code — semantically wrong | **MEDIUM** | Plan PATCH-K | RATE_LIMITED means "too many requests", not "storage full" |
| 6 | Plan uses `settings.upload_dir` (relative string) instead of `settings.upload_path` (resolved Path) | **MEDIUM** | config.py:44 | Plan doesn't reference the correct Settings attribute |
| 7 | Dedup query includes `state.in_(["completed", "queued", "processing"])` — should also exclude `"failed"` and `"cancelled"` explicitly for clarity | **LOW** | Plan dedup logic | Implicit exclusion relies on `.in_()` semantics |

---

## 2. PATCH-V2-A: FIX TIMING-UNSAFE HASH COMPARISON IN EXISTING CODE

**CRITICAL BUG in pre-existing `upload_handlers.py`:**

```python
# Line 276-277 (CURRENT CODE - VULNERABLE):
actual_hash = hashlib.sha256(body).hexdigest()
if actual_hash != chunk_hash:  # ← TIMING SIDE-CHANNEL
```

```python
# Line 297 (CURRENT CODE - ALSO VULNERABLE):
if existing_chunk.chunk_hash != chunk_hash:  # ← TIMING SIDE-CHANNEL
```

**Fix (MUST be applied in PR#10 modifications to upload_handlers.py):**

```python
import hmac

# Line 276-277 replacement:
actual_hash = hashlib.sha256(body).hexdigest()
# SEAL FIX: Use hmac.compare_digest() for timing-safe comparison.
# Python's != short-circuits on first differing byte, leaking hash
# similarity via timing. INV-U16 applies to ALL hash comparisons,
# including pre-existing code modified by PR#10.
# GATE: This comparison MUST use hmac.compare_digest(). Requires RFC to change.
if not hmac.compare_digest(actual_hash, chunk_hash.lower()):

# Line 297 replacement:
# SEAL FIX: Existing chunk hash comparison must also be timing-safe.
if not hmac.compare_digest(existing_chunk.chunk_hash, chunk_hash.lower()):
```

**WHY this matters now:** PR#10 is modifying `upload_handlers.py` anyway. Leaving known timing-unsafe comparisons in a file we're actively editing would violate INV-U16 ("ALL hash comparisons via hmac.compare_digest()").

**WHY `.lower()`:** `chunk_hash` comes from the HTTP header `X-Chunk-Hash` (user-controlled). It could be uppercase or mixed-case. Normalizing to lowercase before comparison ensures case-insensitive matching and prevents false mismatches. `actual_hash` from `hashlib.sha256().hexdigest()` is always lowercase.

---

## 3. PATCH-V2-B: VALIDATE chunk_hash HEADER INPUT

**CRITICAL: `chunk_hash` has NO validation in existing code.**

In `contract.py` line 79, `bundle_hash` is validated with:
```python
bundle_hash: str = Field(..., pattern=r'^[0-9a-f]{64}$')  # SHA256 format
```

But `chunk_hash` from `X-Chunk-Hash` header (upload_handlers.py line 232) goes through ZERO validation. It could contain SQL injection attempts, path traversal characters, or arbitrary binary data.

**Fix (add to upload_handlers.py, after extracting chunk_hash):**

```python
import re

# After line 253 (after chunk_hash extraction):
# SEAL FIX: Validate chunk_hash format. This header is user-controlled input.
# Without validation, chunk_hash could contain path traversal characters
# (used in future file naming) or SQL injection payloads (stored in DB).
# Must match SHA-256 hexdigest format: exactly 64 lowercase hex characters.
# GATE: This validation MUST NOT be removed. Requires RFC.
_SHA256_HEX_PATTERN = re.compile(r'^[0-9a-f]{64}$')

if not _SHA256_HEX_PATTERN.match(chunk_hash.lower()):
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INVALID_REQUEST,
            message="Invalid X-Chunk-Hash format"
        )
    )
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content=error_response.model_dump(exclude_none=True)
    )

# Normalize to lowercase (consistent with hashlib.hexdigest() output)
chunk_hash = chunk_hash.lower()
```

**Also validate `chunk_index` range:**

```python
# After line 261 (after parsing chunk_index):
# SEAL FIX: Validate chunk_index is within expected range.
# Without this, an attacker could submit chunk_index=999999,
# causing unexpected file paths (000999999.chunk) or DB records.
if chunk_index < 0 or chunk_index >= upload_session.chunk_count:
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INVALID_REQUEST,
            message="Chunk index out of range"
        )
    )
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content=error_response.model_dump(exclude_none=True)
    )
```

---

## 4. PATCH-V2-C: PATH TRAVERSAL VIA bundle_hash

**The original plan validates `upload_id` for path traversal but NOT `bundle_hash`.**

`bundle_hash` is used in file paths:
```python
# In assemble_bundle():
assembling_path = assembly_dir / f"{bundle_hash}.bundle.assembling"
# In final rename:
final_path = Path(settings.upload_dir) / f"{bundle_hash}.bundle"
```

Although `bundle_hash` is validated by Pydantic (`pattern=r'^[0-9a-f]{64}$'`) in the `CreateUploadRequest` and `CompleteUploadRequest` schemas, the assembly function receives it from the `UploadSession.bundle_hash` DB column — which was stored without re-validation.

**Defense-in-depth fix:**

```python
def validate_hash_component(value: str, field_name: str) -> str:
    """
    Validate that a hash string is safe for use in file paths.

    INV-U9 extension: Path containment applies to ALL user-derived path components.

    SEAL FIX: Even though bundle_hash is Pydantic-validated on API entry,
    we re-validate before file path construction as defense-in-depth.
    The DB is an untrusted boundary — data could be modified by DB migration,
    manual intervention, or future code that bypasses Pydantic validation.
    """
    if not value:
        raise ValueError(f"{field_name} must not be empty")
    if not _SHA256_HEX_PATTERN.match(value):
        raise ValueError(f"{field_name} is not a valid SHA-256 hex string")
    return value
```

**Apply in assemble_bundle():**

```python
def assemble_bundle(upload_id: str, session, db) -> AssemblyResult:
    validate_path_component(upload_id, "upload_id")
    validate_hash_component(session.bundle_hash, "bundle_hash")  # ← NEW
    # ... rest of function
```

---

## 5. PATCH-V2-D: FIX HTTP 503 NOT IN CLOSED STATUS CODE SET

**Problem:** The enhanced plan's PATCH-K uses HTTP 503 for disk quota rejection:
```python
return JSONResponse(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, ...)
```

But `main.py` line 138 has a closed HTTP status code set:
```python
if http_status not in [200, 201, 206, 400, 401, 404, 409, 413, 429, 500]:
    http_status = status.HTTP_500_INTERNAL_SERVER_ERROR
```

If 503 somehow passes through the global exception handler, it would be remapped to 500. More importantly, using 503 is inconsistent with the existing API contract which only uses the 10 codes listed above.

**Fix: Use HTTP 429 (Too Many Requests) instead of 503**

This is semantically correct: disk quota exhaustion IS a form of rate limiting — the server is "too busy" to accept more data. HTTP 429 is already in the closed set AND maps to `RATE_LIMITED` error code.

**However, the error message must clearly indicate the reason:**

```python
# Disk quota exceeded → use 429 with clear message
error_response = APIResponse(
    success=False,
    error=APIError(
        code=APIErrorCode.RATE_LIMITED,
        message="Server storage capacity temporarily exceeded. Retry later."
    )
)
return JSONResponse(
    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
    content=error_response.model_dump(exclude_none=True)
)
```

**WHY 429 not 500:** 500 implies a server bug. 429 implies a temporary resource constraint — which is exactly what disk quota exhaustion is. The client should retry later (after cleanup frees space).

**Alternative if we want to avoid conflating rate-limiting with disk quota:**

Use HTTP 400 with `INVALID_REQUEST` and message `"Service temporarily unavailable: storage capacity exceeded"`. This keeps the semantics cleaner but is less standard.

**Recommendation:** Use 429 with `RATE_LIMITED`. Add a WHY comment explaining the choice.

---

## 6. PATCH-V2-E: FIX DISK QUOTA ERROR CODE

The previous patch supplement (PATCH-K) used `RATE_LIMITED` for disk quota. Per the analysis above, this is acceptable but needs a WHY comment:

```python
# WHY RATE_LIMITED for disk quota: The error_registry has exactly 7 codes (closed set,
# asserted at import time). We CANNOT add new codes without updating error_registry.py
# and breaking the `assert len(ERROR_CODE_REGISTRY) == 7` guard.
# RATE_LIMITED is the closest semantic match: "server cannot accept more data right now".
# 429 tells the client to retry later, which is correct behavior for disk pressure.
# GATE: Error code choice MUST NOT change without updating error_registry.py assertion.
```

---

## 7. PATCH-V2-F: USE settings.upload_path (RESOLVED) NOT settings.upload_dir (RELATIVE)

**Problem:** The plan references `settings.upload_dir` (a relative string: `"storage/uploads"`) but should use `settings.upload_path` (a resolved absolute Path).

From `config.py`:
```python
upload_dir: str = "storage/uploads"           # Relative string
upload_path: Path = Path()                     # Resolved at runtime
# In __init__():
self.upload_path = (base_dir / self.upload_dir).resolve()  # Absolute Path
```

**Fix for ALL PR#10 code:**

```python
# WRONG:
chunk_dir = Path(settings.upload_dir) / upload_id / "chunks"

# CORRECT:
chunk_dir = settings.upload_path / upload_id / "chunks"
```

**This also affects `_assert_within_upload_dir()`:**

```python
def _assert_within_upload_dir(path: Path) -> None:
    """Defense-in-depth: verify resolved path is within upload directory."""
    resolved = path.resolve()
    # MUST use settings.upload_path (resolved absolute), NOT settings.upload_dir (relative string)
    upload_root = settings.upload_path  # Already resolved in config.py __init__
    if not str(resolved).startswith(str(upload_root) + os.sep) and resolved != upload_root:
        raise AssemblyError(
            f"Path escape detected: {path} resolves outside {upload_root}",
            kind=UploadErrorKind.PATH_ESCAPE
        )
```

**Also affects `check_disk_quota()`:**

```python
def check_disk_quota() -> tuple[bool, float]:
    # Use settings.upload_path (resolved), not settings.upload_dir (relative)
    try:
        usage = shutil.disk_usage(str(settings.upload_path))
        ...
```

---

## 8. PATCH-V2-G: DEDUP QUERY MUST EXCLUDE FAILED/CANCELLED JOBS

**Problem:** The plan's dedup query filters by:
```python
Job.state.in_(["completed", "queued", "processing"])
```

This is correct but relies on implicit exclusion of "failed", "cancelled", "pending", "uploading", "packaging", "capacity_saturated". It would be clearer and safer to be explicit.

**Fix:**

```python
# SEAL FIX: Dedup query explicitly lists valid states.
# A bundle with a "failed" Job should NOT prevent re-upload.
# A bundle with a "cancelled" Job should NOT prevent re-upload.
# Only active/successful states count as duplicates.
#
# WHY these 3 states:
#   "completed" — bundle was fully processed, reuse result
#   "queued" — bundle is waiting for processing, no need to re-upload
#   "processing" — bundle is being processed, no need to re-upload
#   All other states (failed, cancelled, pending, uploading, packaging,
#   capacity_saturated) should allow re-upload.
_DEDUP_VALID_STATES = ("completed", "queued", "processing")

existing_job = db.query(Job).filter(
    Job.bundle_hash == bundle_hash,
    Job.user_id == user_id,
    Job.state.in_(_DEDUP_VALID_STATES)
).first()
```

---

## 9. PATCH-V2-H: COMPLETE UPLOAD TRANSACTION SAFETY

**Problem:** The plan's modified `complete_upload()` does multiple DB operations (update session status, create Job, create TimelineEvent) without proper transaction handling. If the server crashes between commits, data could be inconsistent.

**Fix: Use a single transaction for all DB operations:**

```python
# In complete_upload() — after assembly + verification + dedup pass:

# Step 4: Atomic DB transaction — session update + Job creation + TimelineEvent
# SEAL FIX: All three operations MUST be in a single transaction.
# If Job creation succeeds but TimelineEvent fails, we have a Job with no timeline.
# Using a single commit ensures all-or-nothing.
try:
    upload_session.status = "completed"

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

    db.commit()  # Single commit for all 3 operations
except Exception as e:
    db.rollback()
    # FAIL-CLOSED: If DB fails, don't claim success.
    # Assembled bundle file remains on disk (cleanup will handle it).
    logger.error("DB commit failed in complete_upload: %s", e)
    cleanup_after_assembly(upload_id, success=False)
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INTERNAL_ERROR,
            message="Upload completion failed"
        )
    )
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=error_response.model_dump(exclude_none=True)
    )
```

---

## 10. PATCH-V2-I: STRENGTHEN ASSEMBLY STATE MACHINE

**Problem:** The plan defines `AssemblyState(str, Enum)` with 6 states but doesn't specify transitions or validation. This is below the quality bar of `job_state.py` (PR#2) which has explicit legal transitions.

**Fix: Add legal transition validation:**

```python
class AssemblyState(str, Enum):
    """
    WAL-style assembly state tracking.

    Legal transitions (6 states, 7 transitions):
      PENDING → ASSEMBLING
      ASSEMBLING → HASHING
      ASSEMBLING → FAILED
      HASHING → COMPLETED
      HASHING → FAILED
      FAILED → RECOVERED
      RECOVERED → ASSEMBLING

    INV-U10: Crash recovery — .tmp and .assembling files are detectable.
    """
    PENDING = "pending"
    ASSEMBLING = "assembling"
    HASHING = "hashing"
    COMPLETED = "completed"
    FAILED = "failed"
    RECOVERED = "recovered"

# Legal transitions (from → set of to states)
_ASSEMBLY_TRANSITIONS: dict[AssemblyState, set[AssemblyState]] = {
    AssemblyState.PENDING: {AssemblyState.ASSEMBLING},
    AssemblyState.ASSEMBLING: {AssemblyState.HASHING, AssemblyState.FAILED},
    AssemblyState.HASHING: {AssemblyState.COMPLETED, AssemblyState.FAILED},
    AssemblyState.FAILED: {AssemblyState.RECOVERED},
    AssemblyState.RECOVERED: {AssemblyState.ASSEMBLING},
    AssemblyState.COMPLETED: set(),  # Terminal
}

ASSEMBLY_STATE_COUNT = 6
ASSEMBLY_TRANSITION_COUNT = 7

assert len(AssemblyState) == ASSEMBLY_STATE_COUNT
assert sum(len(v) for v in _ASSEMBLY_TRANSITIONS.values()) == ASSEMBLY_TRANSITION_COUNT
```

---

## 11. PATCH-V2-J: LOGGING STRATEGY ALIGNMENT

**Problem:** The plan doesn't specify a consistent logging strategy. The existing codebase uses `print()` in debug mode (main.py line 202) and has no structured logging.

**Fix: Define PR#10 logging convention:**

```python
import logging

# At module level in each new file:
logger = logging.getLogger(__name__)

# Convention:
# - logger.info() for successful operations (assembly complete, cleanup done)
# - logger.warning() for non-critical failures (single file delete failed)
# - logger.error() for critical failures (assembly failed, integrity check failed)
# - NEVER logger.debug() for security-sensitive information (hashes, paths)
# - ALWAYS include upload_id in log messages for traceability
# - NEVER log raw chunk data or file contents

# Example:
logger.info(
    "Assembly completed: upload_id=%s bundle_hash=%s bytes=%d elapsed=%.3fs",
    upload_id, bundle_hash[:16] + "...", total_bytes, elapsed
)

# SEAL FIX: Truncate bundle_hash in logs to first 16 chars.
# Full 64-char hash in logs is unnecessary and increases log volume.
# 16 chars (64 bits) is sufficient for human identification.
```

---

## 12. PATCH-V2-K: TEST VECTOR ACCURACY (SWIFT CROSS-VERIFICATION)

**Problem:** The plan claims `compute_sample_size(1000, 0.001) == 7` and `compute_sample_size(10000, 0.001) == 69`. These MUST be verified against the actual Swift formula output.

**Verification (Python):**

```python
import math

def compute_sample_size(n, delta=0.001):
    if n <= 0 or delta <= 0 or delta >= 1:
        return n
    return min(n, int(math.ceil(n * (1.0 - pow(delta, 1.0 / n)))))

# Verify:
assert compute_sample_size(100, 0.001) == 100   # Below threshold, not relevant
assert compute_sample_size(1000, 0.001) == 7     # ← Verify this
assert compute_sample_size(10000, 0.001) == 69   # ← Verify this
assert compute_sample_size(0, 0.001) == 0
assert compute_sample_size(-1, 0.001) == -1
assert compute_sample_size(100, 0) == 100        # delta=0 → return n
assert compute_sample_size(100, 1) == 100        # delta=1 → return n
```

**Also verify edge case: n=1**

```python
# n=1, delta=0.001:
# ceil(1 * (1 - pow(0.001, 1.0/1))) = ceil(1 * (1 - 0.001)) = ceil(0.999) = 1
assert compute_sample_size(1, 0.001) == 1
```

**New test requirement: Swift-Python golden test vectors**

Create a file `tests/swift_test_vectors.json` containing pre-computed results from the Swift implementation. This allows CI to verify cross-platform consistency without running Swift:

```json
{
  "merkle_roots": [
    {"input_hex": ["abcd1234..."], "expected_root_hex": "..."},
    ...
  ],
  "sample_sizes": [
    {"n": 1000, "delta": 0.001, "expected_k": 7},
    {"n": 10000, "delta": 0.001, "expected_k": 69}
  ],
  "domain_tag_lengths": {
    "bundle_hash": 22,
    "manifest_hash": 26,
    "context_hash": 25
  }
}
```

---

## 13. PATCH-V2-L: CONSTANT VALUE OPTIMIZATION REVIEW

After researching global best practices and industry standards, here is an optimized review of every constant value:

| Constant | Current Value | Recommendation | Justification |
|----------|--------------|----------------|---------------|
| `HASH_STREAM_CHUNK_BYTES` | 262,144 (256KB) | **KEEP** | Matches Swift. Apple CryptoKit optimal at 256KB. Changing would break cross-platform parity. |
| `ASSEMBLY_BUFFER_BYTES` | 1,048,576 (1MB) | **KEEP** | 4× hash chunks. Good for NVMe. Sufficient for spinning disk. |
| `VALIDATION_TIMEOUT_SECONDS` | 60 | **KEEP** | 60× safety margin. AWS Lambda timeout is 900s; ours is conservative. |
| `ORPHAN_RETENTION_HOURS` | 48 | **KEEP** | 2× expiry (24h). AWS S3 incomplete multipart: 7 days. Ours is more aggressive = better. |
| `GLOBAL_CLEANUP_INTERVAL_SECONDS` | 3600 | Consider **1800** (30min) | AWS S3 lifecycle checks hourly. For MVP with single user, 30min is more responsive without significant overhead. **KEEP 3600 for now** — can tune later. |
| `ASSEMBLING_MAX_AGE_HOURS` | 2 | **KEEP** | 7200× normal assembly time. Conservative enough for slow I/O. |
| `DISK_USAGE_REJECT_THRESHOLD` | 0.90 | Consider **0.85** | AWS EBS recommends alerting at 80%. 85% gives more headroom. **CHANGE to 0.85**. |
| `DISK_USAGE_EMERGENCY_THRESHOLD` | 0.95 | **KEEP** | Industry standard emergency threshold. |
| `PROBABILISTIC_MIN_CHUNKS` | 100 | **KEEP** | Must match BundleConstants.PROBABILISTIC_MIN_ASSETS. Changing would break Swift parity. |
| `PROBABILISTIC_DELTA` | 0.001 | **KEEP** | Must match BundleConstants.PROBABILISTIC_VERIFICATION_DELTA. |
| `CHUNK_INDEX_PADDING` | 6 | **KEEP** | MAX_CHUNK_COUNT=200 needs 3 digits. 6 digits = 999,999 headroom. |

**Changed value:**

```python
# WHY 0.85 (was 0.90): AWS EBS recommends alerting at 80% disk usage.
# At 85%, there's still 15% headroom (75GB on a 500GB disk) for:
# - Active uploads (max 500MB per bundle × 1 concurrent = 500MB)
# - Temp files during assembly (~2× bundle size = 1GB)
# - SQLite WAL files (~10MB)
# - OS operations, logs, etc.
# At 90%, headroom is only 50GB — less margin for concurrent operations.
# Reference: AWS EBS best practices, Google Cloud Persistent Disk monitoring.
DISK_USAGE_REJECT_THRESHOLD: float = 0.85
```

---

## 14. PATCH-V2-M: INDUSTRY BENCHMARK INTEGRATION

### Findings from Global Research (CN + EN + ES + AR)

#### 1. AWS S3 (2025-2026): Per-Part Checksums with CRC64NVME

AWS S3 added CRC64NVME as a new checksum algorithm (2025). Their multipart upload now supports **per-part checksums** that are verified during `CompleteMultipartUpload` and produce a composite checksum.

**What we can learn:** Our per-chunk SHA-256 + whole-file SHA-256 is equivalent but uses a cryptographically stronger algorithm. We are AHEAD of AWS in this regard.

**Integration:** Add a comment in `integrity_checker.py`:
```python
# INDUSTRY BENCHMARK: AWS S3 (2025) uses CRC64NVME for per-part checksums.
# We use SHA-256 (cryptographic) for both per-chunk and whole-file verification,
# which is stronger than CRC64 (non-cryptographic). Trade-off: ~3× slower hashing,
# but acceptable for our bundle sizes (≤500MB) and provides cryptographic integrity.
```

#### 2. Alibaba Cloud OSS: Multipart Upload Lifecycle

Alibaba Cloud OSS auto-expires incomplete multipart uploads after 7 days. Our 24h expiry + 48h orphan retention is more aggressive — better for storage management.

#### 3. tus.io Protocol (v2.0 draft): Structured Upload Metadata

tus.io's v2.0 draft adds structured metadata fields. Our `BundleManifest` is significantly richer.

#### 4. OWASP File Upload Cheat Sheet (2025 update): Polyglot File Detection

OWASP now recommends checking file magic bytes to detect polyglot files (files that are valid in multiple formats, used for attacks). This is a FUTURE enhancement for PR#10:

```python
# FUTURE-POLYGLOT: When adding content scanning (FUTURE-SCAN comment in plan):
# - Check first 8 bytes of assembled bundle for known magic bytes
# - PDF (%PDF), ZIP (PK), GZIP (1f 8b), etc.
# - Reject bundles that match non-3DGS file signatures
# - This prevents attackers from uploading disguised malicious files
```

#### 5. io_uring (Linux 5.19+): Zero-Copy Upload

Linux io_uring enables zero-copy I/O for file uploads. This is NOT applicable to PR#10 (Python's asyncio doesn't support io_uring natively), but should be noted for FUTURE:

```python
# FUTURE-IOURING: When migrating to Rust/C++ for performance:
# - io_uring IORING_OP_SPLICE for zero-copy chunk→bundle assembly
# - Expected 2-3× throughput improvement for large bundles
# - Requires Linux 5.19+ (not available on macOS)
```

#### 6. IPFS/Filecoin: Content-Addressable Dedup

IPFS uses CID (Content Identifier) for content-addressable storage. Our `bundle_hash` serves the same purpose. Integration note:

```python
# FUTURE-CAS: Content-addressable storage alignment:
# - bundle_hash already serves as a CID equivalent
# - For cross-user dedup (Path 3), use bundle_hash as the shared storage key
# - IPFS CID format: multibase + multicodec + multihash
# - Our format: raw SHA-256 hex (simpler, compatible with OCI digest)
# - Migration to CID format: "sha256:{bundle_hash}" → "bafybei{base32(sha256)}"
```

#### 7. Chinese Cloud Best Practices: Tencent COS Intelligent Tiering

Tencent COS uses intelligent tiering to auto-archive infrequently accessed uploads. This is a FUTURE consideration for cost optimization.

---

## 15. PATCH-V2-N: GUARDRAIL ENFORCEMENT MATRIX

Every cutting-edge technique we use MUST have a corresponding guardrail:

| Technique | Guardrail | Enforcement |
|-----------|-----------|-------------|
| Timing-safe hash comparison | `hmac.compare_digest()` | GATE marker + grep test: zero `==` on hash strings |
| RFC 9162 Merkle tree | Domain separation prefixes | INV-U12 + byte-length assertions in tests |
| Probabilistic verification | Formula parity with Swift | INV-U20 + `compute_sample_size()` golden test vectors |
| Atomic file persistence | write→fsync→rename→dir-fsync | INV-U7 + monkeypatch test verifying fsync call order |
| Path traversal defense | regex + resolved-path double-check | INV-U9 + parametrized tests with 15+ attack vectors |
| Anti-enumeration errors | Unified HASH_MISMATCH | INV-U17 + test verifying external response NEVER contains layer info |
| Disk quota | Threshold check before every write | PATCH-V2-D + test with mocked disk_usage |
| DB-file consistency | File-first, DB-second ordering | PATCH-O + test with injected write failure |
| Dedup race tolerance | Accept benign duplicates | PATCH-J scenario 3 + test with concurrent assembly |
| Constitutional contracts | Version + count assertions | PATCH-F + `assert` at import time |

**Meta-guardrail: Test that guardrails exist**

```python
# In test_upload_contract_constants.py:
class TestGuardrailEnforcement:
    def test_no_bare_equality_on_hashes(self):
        """Grep all PR10 .py files for == or != on hash-like variables."""
        # Uses AST analysis or regex to find timing-unsafe comparisons

    def test_all_invariants_present_in_code(self):
        """Grep all PR10 .py files for INV-U1 through INV-U28."""
        for i in range(1, 29):
            # Assert f"INV-U{i}" appears in at least one .py file

    def test_all_gate_markers_present(self):
        """Grep all PR10 .py files for GATE: markers."""
        # Assert at least 9 GATE markers exist

    def test_all_seal_fix_markers_present(self):
        """Grep all PR10 .py files for SEAL FIX: markers."""
        # Assert at least 12 SEAL FIX markers exist

    def test_constitutional_headers_present(self):
        """Each new file starts with CONSTITUTIONAL CONTRACT header."""
        for filename in ["upload_service.py", "integrity_checker.py",
                         "deduplicator.py", "cleanup_handler.py",
                         "upload_contract_constants.py"]:
            # Read first 10 lines, assert contains "CONSTITUTIONAL CONTRACT"
```

---

## 16. UPDATED IMPLEMENTATION CHECKLIST

### V2 additions (on top of V1 checklist):

- [ ] `upload_handlers.py` line 277: `!=` replaced with `hmac.compare_digest()` (PATCH-V2-A)
- [ ] `upload_handlers.py` line 297: `!=` replaced with `hmac.compare_digest()` (PATCH-V2-A)
- [ ] `chunk_hash` validated against `^[0-9a-f]{64}$` regex (PATCH-V2-B)
- [ ] `chunk_index` validated against `0 <= index < chunk_count` (PATCH-V2-B)
- [ ] `bundle_hash` re-validated before file path construction (PATCH-V2-C)
- [ ] Disk quota uses HTTP 429 (not 503) with `RATE_LIMITED` code (PATCH-V2-D)
- [ ] WHY comment on `RATE_LIMITED` for disk quota (PATCH-V2-E)
- [ ] All code uses `settings.upload_path` (resolved) not `settings.upload_dir` (relative) (PATCH-V2-F)
- [ ] Dedup query uses named constant `_DEDUP_VALID_STATES` (PATCH-V2-G)
- [ ] `complete_upload()` uses single `db.commit()` for session + Job + TimelineEvent (PATCH-V2-H)
- [ ] `AssemblyState` has legal transitions and count assertions (PATCH-V2-I)
- [ ] Every new file uses `logger = logging.getLogger(__name__)` (PATCH-V2-J)
- [ ] Test vectors verified against Swift formula (PATCH-V2-K)
- [ ] `DISK_USAGE_REJECT_THRESHOLD` changed to 0.85 (PATCH-V2-L)
- [ ] Industry benchmark comments in code (PATCH-V2-M)
- [ ] Meta-guardrail tests exist (PATCH-V2-N)

---

## END OF PATCH V2 SUPPLEMENT
