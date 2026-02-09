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

"""
Three-Tier Self-Healing Cleanup Engine.

This module implements three tiers of cleanup:

1. Tier 1: Immediate cleanup (after assembly) — removes chunk files and temp directories
2. Tier 2: User-level cleanup (on create_upload) — expires stale sessions for user
3. Tier 3: Global system cleanup (lifespan + periodic) — system-wide orphan cleanup

All cleanup operations are fail-open (log errors but continue) to prevent
partial cleanup failures from blocking operations.

Cross-Platform Guarantees:
- Python 3.10+ required
- shutil.rmtree(): Works on both platforms. On macOS, may fail on locked files
  (not applicable for our use case — upload files are not locked).
- os.path.getmtime(): Available on both platforms. Used for age-based cleanup.
- time.time(): Available on both platforms. Used for timestamp comparisons.
"""

import logging
import os
import shutil
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import List

from sqlalchemy.orm import Session

from app.api.contract_constants import APIContractConstants
from app.core.config import settings
from app.core.storage import cleanup_storage
from app.models import UploadSession
from app.services.upload_contract_constants import UploadContractConstants

logger = logging.getLogger(__name__)

# Constants
# GATE: EXPIRY_HOURS — must match APIContractConstants.UPLOAD_EXPIRY_HOURS.
#        Changing this breaks Tier 2 cleanup timing. Requires RFC.
EXPIRY_HOURS = APIContractConstants.UPLOAD_EXPIRY_HOURS  # 24h

# GATE: ORPHAN_RETENTION_HOURS — must be 2× EXPIRY_HOURS (INV-U26).
#        Changing breaks orphan safety margin. Requires RFC.
ORPHAN_RETENTION_HOURS = UploadContractConstants.ORPHAN_RETENTION_HOURS  # 48h safety margin

# GATE: GLOBAL_CLEANUP_INTERVAL_SECONDS — changing affects cleanup frequency.
#        Too frequent wastes I/O, too infrequent accumulates orphans. Requires RFC.
GLOBAL_CLEANUP_INTERVAL_SECONDS = UploadContractConstants.GLOBAL_CLEANUP_INTERVAL_SECONDS  # 1 hour

# GATE: ASSEMBLING_MAX_AGE_HOURS — crash detection threshold.
#        Changing affects false positive rate. Requires RFC.
ASSEMBLING_MAX_AGE_HOURS = UploadContractConstants.ASSEMBLING_MAX_AGE_HOURS  # 2 hours

# Track last global cleanup time
_last_global_cleanup_time: float = 0.0


@dataclass
class CleanupResult:
    """
    Result of cleanup operation.
    
    GATE: CleanupResult fields — adding/removing fields breaks cleanup result logging.
          Requires RFC.
    """
    chunks_deleted: int = 0
    dirs_deleted: int = 0
    sessions_expired: int = 0
    orphans_cleaned: int = 0
    assembling_cleaned: int = 0
    elapsed_seconds: float = 0.0
    errors: List[str] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        """Serialize for logging."""
        return {
            "chunks_deleted": self.chunks_deleted,
            "dirs_deleted": self.dirs_deleted,
            "sessions_expired": self.sessions_expired,
            "orphans_cleaned": self.orphans_cleaned,
            "assembling_cleaned": self.assembling_cleaned,
            "elapsed_seconds": round(self.elapsed_seconds, 3),
            "error_count": len(self.errors),
        }


class CleanupHandler:
    """
    Three-tier self-healing cleanup engine.

    INV-U25: Fail-open deletion — if deletion raises, log error and continue.
    INV-U26: Orphan safety margin — orphan directories only deleted after 2× expiry (48h).
    INV-U27: DB-before-file — always update DB state BEFORE deleting files.
    INV-U28: Global cleanup idempotent — running cleanup_global() twice produces no errors.
    """
    
    def cleanup_after_assembly(self, upload_id: str, success: bool) -> CleanupResult:
        """
        Tier 1: Immediate cleanup after assembly.

        INV-U25: Fail-open deletion — individual file failures are logged but
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

        Args:
            upload_id: Upload session ID
            success: Whether assembly succeeded

        Returns:
            CleanupResult with deletion counts and errors
        """
        start_time = time.monotonic()
        result = CleanupResult()
        
        # Delete chunk files
        chunk_dir = settings.upload_path / upload_id / "chunks"
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
        assembly_dir = settings.upload_path / upload_id / "assembly"
        if assembly_dir.exists():
            try:
                shutil.rmtree(str(assembly_dir), ignore_errors=False)
                result.dirs_deleted += 1
            except OSError as e:
                logger.warning("Failed to remove assembly dir %s: %s", assembly_dir, e)
                result.errors.append(f"dir: {assembly_dir}: {e}")
        
        # Try to remove the upload_id directory (only succeeds if empty)
        upload_dir = settings.upload_path / upload_id
        if upload_dir.exists():
            try:
                upload_dir.rmdir()  # Only removes if empty
                result.dirs_deleted += 1
            except OSError:
                # Not empty — some cleanup failed. Tier 3 will handle it.
                pass
        
        result.elapsed_seconds = time.monotonic() - start_time
        logger.info(
            "Tier 1 cleanup completed: upload_id=%s success=%s chunks=%d dirs=%d errors=%d",
            upload_id, success, result.chunks_deleted, result.dirs_deleted, len(result.errors)
        )
        
        return result
    
    def cleanup_user_expired(self, user_id: str, db: Session) -> CleanupResult:
        """
        Tier 2: User-level cleanup of expired sessions.

        INV-U27: DB-before-file — always update DB state BEFORE deleting files.

        Called at the START of create_upload(), before creating new session.

        SEAL FIX: Update DB status to "expired" BEFORE deleting files.
        If we delete files first and crash before DB update, the DB will reference
        non-existent files with status="in_progress", causing ghost uploads.

        Args:
            user_id: User ID
            db: SQLAlchemy session

        Returns:
            CleanupResult with cleanup statistics
        """
        start_time = time.monotonic()
        result = CleanupResult()
        
        now = datetime.utcnow()
        expired_sessions = db.query(UploadSession).filter(
            UploadSession.user_id == user_id,
            UploadSession.status == "in_progress",
            UploadSession.expires_at < now
        ).all()
        
        for session in expired_sessions:
            try:
                # INV-U27: Update DB BEFORE deleting files
                session.status = "expired"
                db.commit()
                result.sessions_expired += 1
                
                # Now delete files
                session_dir = settings.upload_path / session.id
                if session_dir.exists():
                    try:
                        shutil.rmtree(str(session_dir), ignore_errors=False)
                        result.dirs_deleted += 1
                    except OSError as e:
                        logger.warning("Failed to delete expired session dir %s: %s", session_dir, e)
                        result.errors.append(f"dir: {session_dir}: {e}")
            except Exception as e:
                # FAIL-OPEN: If DB update fails, log and continue
                logger.error("Failed to expire session %s: %s", session.id, e, exc_info=True)
                db.rollback()
                result.errors.append(f"session: {session.id}: {e}")
        
        result.elapsed_seconds = time.monotonic() - start_time
        if result.sessions_expired > 0:
            logger.info(
                "Tier 2 cleanup completed: user_id=%s expired=%d dirs=%d",
                user_id, result.sessions_expired, result.dirs_deleted
            )
        
        return result
    
    def cleanup_global(self, db: Session) -> CleanupResult:
        """
        Tier 3: Global system cleanup.

        INV-U25: Fail-open deletion — individual file failures are logged but continue.
        INV-U26: Orphan safety margin — orphan directories only deleted after 2× expiry (48h).
        INV-U28: Global cleanup idempotent — running cleanup_global() twice produces no errors.

        Called:
        - Once at FastAPI lifespan startup
        - Every 1 hour (check should_run_global())

        What it cleans:
        1. ALL expired in_progress sessions across ALL users → mark as expired, delete files
        2. Orphan directories: directories in storage/uploads/ that have no matching active
           UploadSession in DB AND are older than 48 hours (2× expiry, safety margin)
        3. .assembling residual files: any *.assembling file older than 2 hours (crash detection)
        4. Call cleanup_storage() from storage.py (activates Dormant #2) which calls
           cleanup_old_files() (activates Dormant #4)

        Args:
            db: SQLAlchemy session

        Returns:
            CleanupResult with cleanup statistics
        """
        start_time = time.monotonic()
        result = CleanupResult()
        
        now = datetime.utcnow()
        cutoff_time = now - timedelta(hours=ORPHAN_RETENTION_HOURS)
        assembling_cutoff_time = now - timedelta(hours=ASSEMBLING_MAX_AGE_HOURS)
        
        # 1. Expire all expired sessions
        expired_sessions = db.query(UploadSession).filter(
            UploadSession.status == "in_progress",
            UploadSession.expires_at < now
        ).all()
        
        for session in expired_sessions:
            try:
                # INV-U27: DB-before-file
                session.status = "expired"
                db.commit()
                result.sessions_expired += 1
                
                session_dir = settings.upload_path / session.id
                if session_dir.exists():
                    try:
                        shutil.rmtree(str(session_dir), ignore_errors=False)
                        result.dirs_deleted += 1
                    except OSError as e:
                        logger.warning("Failed to delete expired session dir %s: %s", session_dir, e)
                        result.errors.append(f"dir: {session_dir}: {e}")
            except Exception as e:
                logger.error("Failed to expire session %s: %s", session.id, e, exc_info=True)
                db.rollback()
                result.errors.append(f"session: {session.id}: {e}")
        
        # 2. Find orphan directories
        active_upload_ids = {s.id for s in db.query(UploadSession.id).filter(
            UploadSession.status == "in_progress"
        ).all()}
        
        if settings.upload_path.exists():
            for item in settings.upload_path.iterdir():
                if not item.is_dir():
                    continue
                
                # Skip if it's an active upload session
                if item.name in active_upload_ids:
                    continue
                
                # Check age
                try:
                    mtime = datetime.fromtimestamp(item.stat().st_mtime)
                    if mtime < cutoff_time:
                        # INV-U26: Orphan safety margin — only delete after 2× expiry
                        try:
                            shutil.rmtree(str(item), ignore_errors=False)
                            result.orphans_cleaned += 1
                            result.dirs_deleted += 1
                        except OSError as e:
                            logger.warning("Failed to delete orphan dir %s: %s", item, e)
                            result.errors.append(f"orphan: {item}: {e}")
                except OSError as e:
                    logger.warning("Failed to stat orphan dir %s: %s", item, e)
                    result.errors.append(f"orphan_stat: {item}: {e}")
        
        # 3. Clean .assembling residual files
        if settings.upload_path.exists():
            for item in settings.upload_path.rglob("*.assembling"):
                try:
                    mtime = datetime.fromtimestamp(item.stat().st_mtime)
                    if mtime < assembling_cutoff_time:
                        item.unlink()
                        result.assembling_cleaned += 1
                except OSError as e:
                    logger.warning("Failed to delete .assembling file %s: %s", item, e)
                    result.errors.append(f"assembling: {item}: {e}")
        
        # 4. Call cleanup_storage() (activates Dormant #2 and #4)
        try:
            cleanup_result = cleanup_storage()
            logger.info("cleanup_storage() completed: %s", cleanup_result)
        except Exception as e:
            logger.error("cleanup_storage() failed: %s", e, exc_info=True)
            result.errors.append(f"cleanup_storage: {e}")
        
        result.elapsed_seconds = time.monotonic() - start_time
        logger.info(
            "Tier 3 cleanup completed: expired=%d orphans=%d assembling=%d dirs=%d errors=%d elapsed=%.3fs",
            result.sessions_expired, result.orphans_cleaned, result.assembling_cleaned,
            result.dirs_deleted, len(result.errors), result.elapsed_seconds
        )
        
        return result


# Module-level convenience functions
_handler = CleanupHandler()


def cleanup_after_assembly(upload_id: str, success: bool) -> CleanupResult:
    """Convenience function for Tier 1 cleanup."""
    return _handler.cleanup_after_assembly(upload_id, success)


def cleanup_user_expired(user_id: str, db: Session) -> CleanupResult:
    """Convenience function for Tier 2 cleanup."""
    return _handler.cleanup_user_expired(user_id, db)


def cleanup_global(db: Session) -> CleanupResult:
    """Convenience function for Tier 3 cleanup."""
    return _handler.cleanup_global(db)


def should_run_global_cleanup() -> bool:
    """
    Check if global cleanup should run.

    Returns True if GLOBAL_CLEANUP_INTERVAL_SECONDS have elapsed since last run.
    """
    global _last_global_cleanup_time
    now = time.time()
    if now - _last_global_cleanup_time >= GLOBAL_CLEANUP_INTERVAL_SECONDS:
        _last_global_cleanup_time = now
        return True
    return False


# FUTURE-S3: When migrating from local disk to S3:
#   - cleanup_after_assembly() → S3 DeleteObjects for chunk files
#   - cleanup_global() → S3 lifecycle policy + AbortMultipartUpload
#   - Orphan detection → S3 list objects with prefix, compare with DB
#
# FUTURE-PG: When migrating from SQLite to PostgreSQL:
#   - cleanup_global() → PostgreSQL pg_cron extension for scheduled cleanup
#   - Add advisory locks to prevent concurrent cleanup_global() invocations
#   - Use PostgreSQL's LISTEN/NOTIFY for cleanup triggers
