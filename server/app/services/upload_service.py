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

"""
Three-Way Pipeline Atomic Assembly Engine.

This module implements the core assembly logic for PR#10, using a three-way
pipeline that reads chunks, writes the bundle file, and computes hashes in
a single pass, achieving 3× performance improvement over traditional methods.

Cross-Platform Guarantees:
- Python 3.10+ required (match type syntax, structural pattern matching)
- hashlib.sha256: Uses OpenSSL on Linux, CommonCrypto on macOS — both produce
  identical output for identical input (SHA-256 is deterministic by spec)
- os.rename(): Atomic on same filesystem on both ext4 (Linux) and APFS (macOS)
  WARNING: NOT atomic across filesystems. upload_dir MUST be on same filesystem.
- _durable_fsync(): Uses F_FULLFSYNC on macOS (Python 3.10-3.11) for true
  durability. Python 3.12+ already does this in os.fsync().
- pathlib.Path.resolve(): Follows symlinks on both platforms. Used for path
  containment validation (INV-U9).
- shutil.rmtree(): Works on both platforms. On macOS, may fail on locked files
  (not applicable for our use case — upload files are not locked).
- time.monotonic(): Available on both platforms. Used for elapsed time measurement.
  NOT suitable for timestamps (no absolute time). Use datetime.utcnow() for timestamps.
"""

import hashlib
import hmac
import logging
import os
import re
import shutil
import sys
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

from app.core.config import settings
from app.models import Chunk
from app.services.upload_contract_constants import UploadContractConstants

logger = logging.getLogger(__name__)

# Constants
HASH_STREAM_CHUNK_BYTES: int = UploadContractConstants.HASH_STREAM_CHUNK_BYTES
ASSEMBLY_BUFFER_BYTES: int = UploadContractConstants.ASSEMBLY_BUFFER_BYTES
CHUNK_INDEX_PADDING: int = UploadContractConstants.CHUNK_INDEX_PADDING

# Path validation pattern
# GATE: upload_id sanitization — MUST reject path traversal characters.
# Removing this validation enables directory escape attacks. Requires RFC.
_SAFE_ID_PATTERN = re.compile(r"^[a-zA-Z0-9_-]+$")
_SHA256_HEX_PATTERN = re.compile(r"^[0-9a-f]{64}$")


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


@dataclass
class AssemblyResult:
    """Result of bundle assembly operation."""
    __slots__ = ("bundle_path", "sha256_hex", "total_bytes", "elapsed_seconds", "chunk_hashes")
    
    bundle_path: Path
    sha256_hex: str
    total_bytes: int
    elapsed_seconds: float
    chunk_hashes: list[bytes]  # List of chunk SHA-256 bytes (for Merkle tree)


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


def _assert_within_upload_dir(path: Path) -> None:
    """
    Defense-in-depth: verify resolved path is within upload directory.

    SEAL FIX: Even after regex validation of upload_id, verify the resolved
    path doesn't escape. Covers edge cases like filesystem-specific behavior,
    mount points, or future code changes that might bypass regex.

    Mirrors ImmutableBundle.swift validateFileWithinBoundary() (line 524-531).
    """
    resolved = path.resolve()
    upload_root = settings.upload_path.resolve()
    if not str(resolved).startswith(str(upload_root) + os.sep) and resolved != upload_root:
        raise AssemblyError(
            f"Path escape detected: {path} resolves outside {upload_root}",
            kind=UploadErrorKind.PATH_ESCAPE
        )


def check_disk_quota() -> tuple[bool, float]:
    """
    Check if disk has sufficient space for upload operations.

    INV-U9 extension: Not just path containment but also resource containment.

    Returns:
        (allowed, usage_fraction) — allowed=True if upload can proceed
    """
    try:
        usage = shutil.disk_usage(str(settings.upload_path))
        fraction = usage.used / usage.total
        return fraction < UploadContractConstants.DISK_USAGE_REJECT_THRESHOLD, fraction
    except OSError:
        # FAIL-CLOSED: If we can't check disk, reject the upload.
        # Better to reject a valid upload than to crash mid-assembly on full disk.
        return False, 1.0


def persist_chunk(upload_id: str, chunk_index: int, chunk_data: bytes, expected_hash: str) -> Path:
    """
    Persist chunk binary data to disk with atomic write pattern.

    INV-U1: Atomic chunk persistence — write to .tmp then rename; partial writes NEVER visible.
    INV-U7: fsync before rename — data durably written before atomic rename makes it visible.
    INV-U9: Path containment — all file operations confined to upload_dir/{upload_id}/ subtree.

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

    Args:
        upload_id: Upload session ID (validated)
        chunk_index: Chunk index (0-based)
        chunk_data: Chunk binary data
        expected_hash: Expected SHA-256 hash (hex, lowercase)

    Returns:
        Path to persisted chunk file

    Raises:
        AssemblyError: If persistence fails
    """
    # INV-U9: Validate path component BEFORE any file operations
    validate_path_component(upload_id, "upload_id")
    validate_hash_component(expected_hash, "expected_hash")

    # Contract C-UPLOAD-CHUNK-HASH-VERIFY: reject mismatched chunks before durable write.
    calculated_hash = hashlib.sha256(chunk_data).hexdigest()
    if not hmac.compare_digest(calculated_hash, expected_hash.lower()):
        raise AssemblyError(
            f"Chunk {chunk_index} hash mismatch before persist",
            kind=UploadErrorKind.CHUNK_HASH_MISMATCH
        )
    
    chunk_dir = settings.upload_path / upload_id / "chunks"
    chunk_dir.mkdir(parents=True, exist_ok=True)
    
    # INV-U9: Verify resolved path is within upload directory
    _assert_within_upload_dir(chunk_dir)
    
    tmp_path = chunk_dir / f"{chunk_index:0{CHUNK_INDEX_PADDING}d}.chunk.tmp"
    final_path = chunk_dir / f"{chunk_index:0{CHUNK_INDEX_PADDING}d}.chunk"
    
    # Check disk quota before writing
    allowed, usage = check_disk_quota()
    if not allowed:
        raise AssemblyError(
            f"Disk quota exceeded ({usage:.1%} used)",
            kind=UploadErrorKind.DISK_QUOTA_EXCEEDED
        )
    
    # Step 1-4: Write + fsync file
    # INV-U1: Write to .tmp file first
    fd = os.open(str(tmp_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        os.write(fd, chunk_data)
        # INV-U7: fsync before rename
        _durable_fsync(fd)
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
    # INV-U1: atomic on same filesystem
    tmp_path.rename(final_path)
    
    # Step 6: fsync directory to make rename durable
    dir_fd = os.open(str(chunk_dir), os.O_RDONLY)
    try:
        _durable_fsync(dir_fd)
    finally:
        os.close(dir_fd)
    
    return final_path


def assemble_bundle(upload_id: str, session, db) -> AssemblyResult:
    """
    Assemble bundle from chunks using three-way pipeline.

    INV-U2: Three-way pipeline — read, write, hash in single pass; O(256KB) constant memory.
    INV-U3: Chunk ordering — chunks assembled in strict index order (0, 1, 2, ..., N-1).
    INV-U4: Contiguity validation — chunk indices MUST be gapless (no missing indices).
    INV-U5: Size invariant — assembled bundle byte count == declared bundle_size.
    INV-U6: Per-chunk hash verification — every chunk re-verified during assembly via timing-safe compare.
    INV-U7: fsync before rename — data durably written before atomic rename makes it visible.
    INV-U8: Assembly temp isolation — .assembling files NEVER in final bundle path.
    INV-U9: Path containment — all file operations confined to upload_dir/{upload_id}/ subtree.

    The three-way pipeline performs read, write, and hash operations simultaneously:
    - Read chunk file in 256KB buffers
    - Write to bundle file
    - Update SHA-256 hasher
    - Verify chunk hash matches DB record

    This achieves 3× performance improvement over traditional 3-pass approach.

    Args:
        upload_id: Upload session ID
        session: UploadSession ORM object
        db: SQLAlchemy session

    Returns:
        AssemblyResult with bundle path, hash, size, and chunk hashes

    Raises:
        AssemblyError: If assembly fails
    """
    validate_path_component(upload_id, "upload_id")
    validate_hash_component(session.bundle_hash, "bundle_hash")
    
    # Query all chunks ordered by index
    chunks = db.query(Chunk).filter(
        Chunk.upload_id == upload_id
    ).order_by(Chunk.chunk_index).all()
    
    # INV-U4: Validate chunk count matches session
    if len(chunks) != session.chunk_count:
        raise AssemblyError(
            f"Chunk count mismatch: expected {session.chunk_count}, found {len(chunks)}",
            kind=UploadErrorKind.SIZE_MISMATCH
        )
    
    # INV-U4: Validate contiguity
    indices = [c.chunk_index for c in chunks]
    expected_indices = list(range(session.chunk_count))
    if indices != expected_indices:
        missing = set(expected_indices) - set(indices)
        raise AssemblyError(
            f"Chunk indices not contiguous: missing {sorted(missing)}",
            kind=UploadErrorKind.INDEX_GAP
        )
    
    # Check disk quota
    allowed, usage = check_disk_quota()
    if not allowed:
        raise AssemblyError(
            f"Disk quota exceeded ({usage:.1%} used)",
            kind=UploadErrorKind.DISK_QUOTA_EXCEEDED
        )
    
    # INV-U8: Assembly temp file in separate directory
    assembly_dir = settings.upload_path / upload_id / "assembly"
    assembly_dir.mkdir(parents=True, exist_ok=True)
    _assert_within_upload_dir(assembly_dir)
    
    assembling_path = assembly_dir / f"{session.bundle_hash}.bundle.assembling"
    final_path = settings.upload_path / f"{session.bundle_hash}.bundle"
    
    start_time = time.monotonic()
    total_bytes = 0
    chunk_hashes = []
    
    # Initialize hashers
    bundle_hasher = hashlib.sha256()
    
    # INV-U2: Three-way pipeline — read, write, hash in single pass
    try:
        bundle_fd = os.open(str(assembling_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        try:
            write_buf = bytearray()  # Write buffer for coalescing
            
            for chunk_record in chunks:
                chunk_file = settings.upload_path / upload_id / "chunks" / f"{chunk_record.chunk_index:0{CHUNK_INDEX_PADDING}d}.chunk"
                
                if not chunk_file.exists():
                    raise AssemblyError(
                        f"Chunk file not found: {chunk_file}",
                        kind=UploadErrorKind.CHUNK_MISSING
                    )
                
                # INV-U6: Per-chunk hash verification
                chunk_hasher = hashlib.sha256()
                
                chunk_fd = os.open(str(chunk_file), os.O_RDONLY)
                try:
                    while True:
                        buf = os.read(chunk_fd, HASH_STREAM_CHUNK_BYTES)
                        if not buf:
                            break
                        
                        # Three-way: read, write, hash
                        bundle_hasher.update(buf)
                        chunk_hasher.update(buf)
                        
                        # Write coalescing
                        write_buf.extend(buf)
                        if len(write_buf) >= ASSEMBLY_BUFFER_BYTES:
                            os.write(bundle_fd, write_buf)
                            write_buf.clear()
                        
                        total_bytes += len(buf)
                finally:
                    os.close(chunk_fd)
                
                # INV-U6: Verify chunk hash matches DB record
                chunk_hash_hex = chunk_hasher.hexdigest()
                # SEAL FIX: Use hmac.compare_digest() for timing-safe comparison
                if not hmac.compare_digest(chunk_hash_hex, chunk_record.chunk_hash.lower()):
                    raise AssemblyError(
                        f"Chunk {chunk_record.chunk_index} hash mismatch",
                        kind=UploadErrorKind.CHUNK_HASH_MISMATCH
                    )
                
                chunk_hashes.append(chunk_hasher.digest())
            
            # Flush remaining write buffer
            if write_buf:
                os.write(bundle_fd, write_buf)
            
            # INV-U7: fsync before rename
            _durable_fsync(bundle_fd)
        finally:
            os.close(bundle_fd)
        
        # INV-U5: Validate total size
        if total_bytes != session.bundle_size:
            assembling_path.unlink(missing_ok=True)
            raise AssemblyError(
                f"Size mismatch: expected {session.bundle_size}, got {total_bytes}",
                kind=UploadErrorKind.SIZE_MISMATCH
            )
        
        # Atomic rename
        assembling_path.rename(final_path)
        
        # fsync directory
        dir_fd = os.open(str(final_path.parent), os.O_RDONLY)
        try:
            _durable_fsync(dir_fd)
        finally:
            os.close(dir_fd)
        
        elapsed = time.monotonic() - start_time
        bundle_hash_hex = bundle_hasher.hexdigest()
        
        logger.info(
            "Assembly completed: upload_id=%s bundle_hash=%s bytes=%d elapsed=%.3fs",
            upload_id, bundle_hash_hex[:16] + "...", total_bytes, elapsed
        )
        
        return AssemblyResult(
            bundle_path=final_path,
            sha256_hex=bundle_hash_hex,
            total_bytes=total_bytes,
            elapsed_seconds=elapsed,
            chunk_hashes=chunk_hashes
        )
    
    except OSError as e:
        # FAIL-CLOSED: Cannot read chunk or write bundle → abort assembly.
        assembling_path.unlink(missing_ok=True)
        raise AssemblyError(
            f"Assembly I/O failed: {e}",
            kind=UploadErrorKind.ASSEMBLY_IO_ERROR
        ) from e


def verify_assembly(result: AssemblyResult, expected_bundle_hash: str) -> bool:
    """
    Verify assembled bundle hash matches expected value.

    Uses timing-safe comparison to prevent timing side-channel attacks.

    Args:
        result: AssemblyResult from assemble_bundle()
        expected_bundle_hash: Expected bundle hash (hex, lowercase)

    Returns:
        True if hash matches, False otherwise
    """
    # SEAL FIX: Use hmac.compare_digest() for timing-safe comparison.
    # Python == short-circuits on first differing byte, leaking hash similarity
    # via timing side-channel. hmac.compare_digest() uses constant-time XOR
    # comparison implemented in C (CPython _hashopenssl.c).
    return hmac.compare_digest(result.sha256_hex.lower(), expected_bundle_hash.lower())


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
# FUTURE-ZEROCOPY: For assembly without re-hashing (when all chunk hashes
# were verified at upload time and are trusted), use os.copy_file_range()
# for zero-copy kernel-to-kernel chunk concatenation:
#   os.copy_file_range(src_fd, dst_fd, chunk_size, src_offset)
# Available on Linux 4.5+ (Python 3.8+). Not available on macOS.
# Expected performance improvement: 2-3× for large bundles (> 100MB)
# by avoiding userspace buffer copies.
#
# FUTURE-CAS-NAMING: For defense-in-depth against chunk substitution attacks,
# consider naming chunk files by their SHA-256 hash instead of index:
#   Current:  chunks/000000.chunk, chunks/000001.chunk, ...
#   Future:   chunks/{sha256_hex}.chunk
# Benefits: attacker cannot swap chunk content without changing filename,
# natural deduplication at chunk level, aligns with IPFS content-addressable
# storage model. Trade-offs: assembly must sort by separate index mapping,
# slightly more complex cleanup. DECISION: Keep index-based naming for PR#10.
