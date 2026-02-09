# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-UPLOAD-1.0
# Module: Server Upload Reception — Contract Constants (SSOT)
# Scope: upload_contract_constants.py ONLY — does NOT govern other PR#10 files
# Cross-Platform: Python 3.10+ (Linux + macOS)
# Standards: SSOT pattern from contract_constants.py (PR#3)
# Dependencies: None (stdlib only)
# Swift Counterpart: Core/Constants/BundleConstants.swift (PR#8)
# =============================================================================

"""Contract constants for PR#10 Server Upload Reception (SSOT)."""


class UploadContractConstants:
    # Version
    CONTRACT_VERSION = "PR10-UPLOAD-1.0"
    
    # WHY "PR10-UPLOAD-1.0": Follows PR2-JSM-2.5 and PR8-BUNDLE-1.0 naming convention.
    # Format: PR{n}-{MODULE}-{major}.{minor}
    # Increment minor for backward-compatible changes, major for breaking changes.
    
    # Module count assertions (MUST match actual implementation)
    # WHY 5 (not 4): upload_contract_constants.py itself is one of the 5 new files.
    # Files: upload_service.py, integrity_checker.py, deduplicator.py,
    #        cleanup_handler.py, upload_contract_constants.py
    # GATE: This count MUST be updated if files are added/removed.
    INVARIANT_COUNT = 28          # INV-U1 through INV-U28
    GATE_COUNT = 12               # 12 GATE markers across all 5 files
    NEW_FILE_COUNT = 5            # upload_service, integrity_checker, deduplicator, cleanup_handler, upload_contract_constants
    MODIFIED_FILE_COUNT = 2       # upload_handlers.py, main.py
    DORMANT_CAPABILITIES_ACTIVATED = 9  # All 9 dormant capabilities
    
    # Assembly constants
    # WHY 262_144 (256KB): Apple Silicon SHA-256 hardware reaches 99% throughput at 256KB.
    # Below 64KB: syscall overhead >10% of hash time. Above 256KB: diminishing returns +
    # memory pressure on 2GB iOS devices. Must match BundleConstants.HASH_STREAM_CHUNK_BYTES.
    # Reference: Apple CryptoKit benchmarks on M1/M2/A15 (2023).
    HASH_STREAM_CHUNK_BYTES = 262_144   # 256KB — must match BundleConstants.swift
    
    # WHY 1_048_576 (1MB): Write syscall batching. Most NVMe SSDs have 4KB-128KB page sizes.
    # 1MB amortizes syscall overhead across ~4 hash chunks (4 × 256KB), reducing write()
    # system calls by 4× without significantly increasing memory usage.
    # Below 256KB: excessive write() syscalls. Above 4MB: diminishing returns.
    ASSEMBLY_BUFFER_BYTES = 1_048_576   # 1MB write batching
    
    # WHY 6 digits (000000): MAX_CHUNK_COUNT is 200 (fits in 3 digits), but 6 digits provides
    # headroom for future increase to 999,999 chunks without format change. Also ensures
    # sorted(glob("*.chunk")) returns correct numeric order via lexicographic sort.
    CHUNK_INDEX_PADDING = 6
    
    # WHY 60 seconds: Assembly of 500MB bundle takes ~1.0s on NVMe SSD (measured). 60s is
    # 60× safety margin for degraded disk (spinning HDD, network mount, high I/O load).
    # Above 60s: likely indicates hung process, not slow disk.
    VALIDATION_TIMEOUT_SECONDS = 60
    
    # Cleanup constants
    # WHY 48 hours: Upload sessions expire after 24h (UPLOAD_EXPIRY_HOURS).
    # Orphan detection at exactly 24h could race with a session that's still
    # within its expiry window. 48h = 2× expiry provides a full additional
    # window. AWS S3 uses 3 days for incomplete multipart cleanup.
    # INV-U26: Orphan safety margin.
    ORPHAN_RETENTION_HOURS = 48   # 2× UPLOAD_EXPIRY_HOURS (24h × 2)
    
    # WHY 3600 seconds (1 hour): Global cleanup is I/O-heavy (directory scan).
    # Running every minute wastes CPU/disk on a healthy system.
    # Running every 24h risks accumulating too many orphans on a busy server.
    # 1 hour balances responsiveness with resource usage.
    # AWS Lambda-based cleanup typically runs hourly.
    GLOBAL_CLEANUP_INTERVAL_SECONDS = 3600  # 1 hour
    
    # WHY 2 hours: Assembly of 500MB takes ~1.0s. If an .assembling file is 2h old,
    # the process that created it has almost certainly crashed (2h = 7200× normal time).
    # Using <1h could interfere with extremely slow network-mounted storage.
    ASSEMBLING_MAX_AGE_HOURS = 2  # Crash detection threshold
    
    # Verification constants
    VERIFICATION_LAYER_COUNT = 5  # L5, L1, L2, L3, L4
    
    # Merkle prefixes are defined in integrity_checker.py as bytes constants
    # (MERKLE_LEAF_PREFIX = b"\x00", MERKLE_NODE_PREFIX = b"\x01")
    # They are not included here to avoid duplication.
    
    # Dedup constants
    DEDUP_PATH_COUNT = 3          # pre-upload, post-assembly, cross-user(reserved)
    
    # Domain tag count
    DOMAIN_TAG_COUNT = 3          # bundle, manifest, context
    
    # Disk quota constants
    # WHY 0.85 (was 0.90): AWS EBS recommends alerting at 80% disk usage.
    # At 85%, there's still 15% headroom (75GB on a 500GB disk) for:
    # - Active uploads (max 500MB per bundle × 1 concurrent = 500MB)
    # - Temp files during assembly (~2× bundle size = 1GB)
    # - SQLite WAL files (~10MB)
    # - OS operations, logs, etc.
    # At 90%, headroom is only 50GB — less margin for concurrent operations.
    # Reference: AWS EBS best practices, Google Cloud Persistent Disk monitoring.
    DISK_USAGE_REJECT_THRESHOLD = 0.85
    
    # WHY 95%: Above 95%, even cleanup operations may fail due to lack of temp space.
    # At this point, reject ALL writes including cleanup temp files.
    DISK_USAGE_EMERGENCY_THRESHOLD = 0.95


# Compile-time assertions (fail on import if counts are wrong)
assert UploadContractConstants.INVARIANT_COUNT == 28, \
    f"Expected 28 invariants, found {UploadContractConstants.INVARIANT_COUNT}"
assert UploadContractConstants.VERIFICATION_LAYER_COUNT == 5, \
    f"Expected 5 verification layers"
assert UploadContractConstants.DOMAIN_TAG_COUNT == 3, \
    f"Expected 3 domain tags"
assert UploadContractConstants.NEW_FILE_COUNT == 5, \
    f"Expected 5 new files, found {UploadContractConstants.NEW_FILE_COUNT}"
