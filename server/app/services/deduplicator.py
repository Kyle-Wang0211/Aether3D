# =============================================================================
# CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
# Contract Version: PR10-DEDUP-1.0
# Module: Three-Path Fusion Dedup Engine
# Scope: deduplicator.py ONLY — does NOT govern other PR#10 files
# Cross-Platform: Python 3.10+ (Linux + macOS)
# Dependencies: sqlalchemy (existing), hmac (stdlib)
# Activates: Dormant Capabilities #3 (Job.bundle_hash index) and #5 (UploadSession.bundle_hash index)
# =============================================================================

"""
Three-Path Fusion Dedup Engine.

This module implements deduplication logic to prevent duplicate bundle uploads
and processing. It uses three paths:

1. Pre-upload instant upload detection — checks before creating UploadSession
2. Post-assembly dedup confirmation — checks after assembly completes
3. Cross-user content-addressable dedup — reserved for future (PR#10: disabled)

All queries use existing indexed columns for O(log N) performance.
"""

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Optional

from sqlalchemy.orm import Session

from app.models import Job, UploadSession

logger = logging.getLogger(__name__)

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
# GATE: _DEDUP_VALID_STATES — this tuple MUST match Job.state values exactly.
#        Adding/removing states changes dedup behavior. Requires RFC.
_DEDUP_VALID_STATES = ("completed", "queued", "processing")


class DedupDecision(str, Enum):
    """Deduplication decision result."""
    PROCEED = "proceed"              # No duplicate found, continue normal flow
    INSTANT_UPLOAD = "instant_upload"  # Bundle exists, skip entire upload
    REUSE_BUNDLE = "reuse_bundle"     # Bundle exists (detected post-assembly), reuse existing job


@dataclass(frozen=True)
class DedupResult:
    """
    Deduplication result.

    INV-U24: Dedup result immutability — DedupResult is frozen after creation (frozen=True).
    
    GATE: DedupResult frozen=True — this dataclass MUST remain frozen.
          Changing to mutable would break INV-U24. Requires RFC.
    """
    decision: DedupDecision
    existing_job_id: Optional[str] = None
    existing_bundle_path: Optional[str] = None
    message: str = ""


class Deduplicator:
    """
    Three-path fusion dedup engine.

    INV-U21: Index-backed queries — all dedup queries use existing indexed columns.
    INV-U22: User-scoped dedup — NEVER return another user's job/session.
    INV-U23: Race-safe post-assembly check — double-check AFTER assembly, before Job creation.
    """
    
    def check_pre_upload(self, bundle_hash: str, user_id: str, db: Session) -> DedupResult:
        """
        Path 1: Pre-upload instant upload detection.

        INV-U21: Index-backed queries — all dedup queries use existing indexed columns.
        INV-U22: User-scoped dedup — NEVER return another user's job/session.

        Called in create_upload() BEFORE creating the UploadSession.

        Performance: Both queries use existing indexes (Job.bundle_hash index=True,
        UploadSession.bundle_hash index=True). Cost: O(log N).

        Args:
            bundle_hash: Bundle hash to check
            user_id: User ID (for scoping)
            db: SQLAlchemy session

        Returns:
            DedupResult with decision and existing job_id if found
        """
        # Check for existing completed/processing/queued Job with same bundle_hash for this user
        existing_job = db.query(Job).filter(
            Job.bundle_hash == bundle_hash,
            Job.user_id == user_id,
            Job.state.in_(_DEDUP_VALID_STATES)
        ).first()
        
        if existing_job:
            logger.info(
                "Pre-upload dedup: instant upload detected for bundle_hash=%s job_id=%s",
                bundle_hash[:16] + "...", existing_job.id
            )
            return DedupResult(
                decision=DedupDecision.INSTANT_UPLOAD,
                existing_job_id=existing_job.id,
                message="Bundle already exists, skipping upload"
            )
        
        # Also check for in-progress upload of same bundle (informational logging only)
        existing_upload = db.query(UploadSession).filter(
            UploadSession.bundle_hash == bundle_hash,
            UploadSession.user_id == user_id,
            UploadSession.status == "in_progress"
        ).first()
        
        if existing_upload:
            logger.info(
                "Pre-upload dedup: in-progress upload detected for bundle_hash=%s upload_id=%s",
                bundle_hash[:16] + "...", existing_upload.id
            )
        
        return DedupResult(
            decision=DedupDecision.PROCEED,
            message="No duplicate found"
        )
    
    def check_post_assembly(self, bundle_hash: str, user_id: str, db: Session) -> DedupResult:
        """
        Path 2: Post-assembly dedup confirmation.

        INV-U21: Index-backed queries — all dedup queries use existing indexed columns.
        INV-U22: User-scoped dedup — NEVER return another user's job/session.
        INV-U23: Race-safe post-assembly check — double-check AFTER assembly completes, before Job creation.

        Called in complete_upload() AFTER assembly + verification pass, BEFORE creating new Job.

        Why needed: During the time chunks are being uploaded (could be minutes for large bundles),
        another identical bundle might have completed. This is the last dedup checkpoint.

        Args:
            bundle_hash: Bundle hash to check
            user_id: User ID (for scoping)
            db: SQLAlchemy session

        Returns:
            DedupResult with decision and existing job_id if found
        """
        existing_job = db.query(Job).filter(
            Job.bundle_hash == bundle_hash,
            Job.user_id == user_id,
            Job.state.in_(_DEDUP_VALID_STATES)
        ).first()
        
        if existing_job:
            logger.info(
                "Post-assembly dedup: reuse bundle detected for bundle_hash=%s job_id=%s",
                bundle_hash[:16] + "...", existing_job.id
            )
            return DedupResult(
                decision=DedupDecision.REUSE_BUNDLE,
                existing_job_id=existing_job.id,
                message="Bundle already exists, reusing existing job"
            )
        
        return DedupResult(
            decision=DedupDecision.PROCEED,
            message="No duplicate found"
        )
    
    def check_cross_user(self, bundle_hash: str, db: Session) -> DedupResult:
        """
        Path 3: Cross-user content-addressable dedup (RESERVED — NOT ENABLED IN PR#10).

        Pre-built interface for future PRs (NFT marketplace, metaverse, multi-tenant).

        Args:
            bundle_hash: Bundle hash to check
            db: SQLAlchemy session

        Returns:
            DedupResult with PROCEED decision (not enabled in PR#10)
        """
        # PR10: Always returns PROCEED (not enabled)
        # Future: Query all users' Jobs, create symlinks to shared storage
        return DedupResult(
            decision=DedupDecision.PROCEED,
            message="Cross-user dedup not enabled in PR#10"
        )


# Module-level convenience functions
_deduplicator = Deduplicator()


def check_dedup_pre_upload(bundle_hash: str, user_id: str, db: Session) -> DedupResult:
    """Convenience function for pre-upload dedup check."""
    return _deduplicator.check_pre_upload(bundle_hash, user_id, db)


def check_dedup_post_assembly(bundle_hash: str, user_id: str, db: Session) -> DedupResult:
    """Convenience function for post-assembly dedup check."""
    return _deduplicator.check_post_assembly(bundle_hash, user_id, db)


# FUTURE-NFT: When adding NFT/metaverse support:
#   - Cross-user dedup (Path 3) → content-addressable shared storage
#   - bundleHash → NFT token ID (immutable reference)
#   - Merkle proof → on-chain verification
#   - Assembly receipts → NFT metadata (provenance chain)
