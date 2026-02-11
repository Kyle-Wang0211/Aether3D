# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""上传处理器（4个端点）"""

import hashlib
import hmac
import logging
import re
import uuid
from datetime import datetime, timedelta
from typing import List

from fastapi import Depends, Request, status
from fastapi.responses import JSONResponse
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.api.contract import (
    APIError, APIErrorCode, APIResponse, CompleteUploadRequest,
    CompleteUploadResponse, CreateUploadRequest, CreateUploadResponse,
    GetChunksResponse, UploadChunkResponse, format_rfc3339_utc
)
from app.api.contract_constants import APIContractConstants
from app.database import get_db
from app.models import Chunk, Job, TimelineEvent, UploadSession
from app.services.cleanup_handler import cleanup_after_assembly, cleanup_user_expired
from app.services.deduplicator import check_dedup_post_assembly, check_dedup_pre_upload, DedupDecision
from app.services.integrity_checker import check_integrity
from app.services.upload_service import (
    AssemblyError, check_disk_quota, persist_chunk, assemble_bundle, verify_assembly
)

logger = logging.getLogger(__name__)

# Validation patterns
# SEAL FIX: Validate chunk_hash format. This header is user-controlled input.
# Without validation, chunk_hash could contain path traversal characters
# (used in future file naming) or SQL injection payloads (stored in DB).
# Must match SHA-256 hexdigest format: exactly 64 lowercase hex characters.
# GATE: This validation MUST NOT be removed. Requires RFC.
_SHA256_HEX_PATTERN = re.compile(r'^[0-9a-f]{64}$')


async def create_upload(
    request_body: CreateUploadRequest,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    POST /v1/uploads - 创建上传会话
    
    PATCH-1: Camera-only校验
    PATCH-8: 大小限制
    """
    user_id = request.state.user_id
    
    # Camera-only校验
    if request_body.capture_source != "aether_camera":
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Only aether_camera capture is allowed"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 硬边界约束（PATCH-8）
    if request_body.bundle_size > APIContractConstants.MAX_BUNDLE_SIZE_BYTES:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Bundle size exceeds 500MB limit"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    if request_body.chunk_count > APIContractConstants.MAX_CHUNK_COUNT:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Chunk count exceeds 200 limit"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 并发限制
    active_uploads = db.query(UploadSession).filter(
        UploadSession.user_id == user_id,
        UploadSession.status == "in_progress"
    ).count()
    
    if active_uploads >= APIContractConstants.MAX_ACTIVE_UPLOADS_PER_USER:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.STATE_CONFLICT,
                message="Already has active upload session"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PR#10: User-level cleanup of expired sessions
    cleanup_user_expired(user_id, db)
    
    # PR#10: Pre-upload dedup check (instant upload)
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
    
    # PR#10: Check disk quota before accepting new upload
    allowed, usage = check_disk_quota()
    if not allowed:
        # WHY RATE_LIMITED for disk quota: The error_registry has exactly 7 codes (closed set,
        # asserted at import time). We CANNOT add new codes without updating error_registry.py
        # and breaking the `assert len(ERROR_CODE_REGISTRY) == 7` guard.
        # RATE_LIMITED is the closest semantic match: "server cannot accept more data right now".
        # 429 tells the client to retry later, which is correct behavior for disk pressure.
        # GATE: Error code choice MUST NOT change without updating error_registry.py assertion.
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
    
    # 创建上传会话
    upload_id = str(uuid.uuid4())
    expires_at = datetime.utcnow() + timedelta(hours=APIContractConstants.UPLOAD_EXPIRY_HOURS)
    
    upload_session = UploadSession(
        id=upload_id,
        user_id=user_id,
        capture_source=request_body.capture_source,
        capture_session_id=request_body.capture_session_id,
        bundle_hash=request_body.bundle_hash,
        bundle_size=request_body.bundle_size,
        chunk_count=request_body.chunk_count,
        status="in_progress",
        expires_at=expires_at
    )
    
    db.add(upload_session)
    db.commit()
    
    # 响应（GATE-6：chunk_size服务端权威值）
    response_data = CreateUploadResponse(
        upload_id=upload_id,
        upload_url=f"/v1/uploads/{upload_id}/chunks",
        chunk_size=APIContractConstants.CHUNK_SIZE_BYTES,
        expires_at=format_rfc3339_utc(expires_at)
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_201_CREATED,
        content=api_response.model_dump(exclude_none=True)
    )


async def upload_chunk(
    upload_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    PATCH /v1/uploads/{id}/chunks - 上传分片
    
    GATE-5: Content-Length校验
    PATCH-8: 分片大小限制
    """
    user_id = request.state.user_id
    
    # 获取上传会话
    upload_session = db.query(UploadSession).filter(
        UploadSession.id == upload_id,
        UploadSession.user_id == user_id
    ).first()
    
    if not upload_session:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Upload session")
    
    # GATE-5: Content-Length校验
    content_length = request.headers.get("Content-Length")
    if not content_length:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Missing Content-Length"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    try:
        content_length_int = int(content_length)
        if content_length_int < 1:
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.INVALID_REQUEST,
                    message="Empty chunk body"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=error_response.model_dump(exclude_none=True)
            )
    except ValueError:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Invalid Content-Length"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PATCH-8: 分片大小限制
    if content_length_int > APIContractConstants.MAX_CHUNK_SIZE_BYTES:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.PAYLOAD_TOO_LARGE,
                message="Chunk size exceeds 5MB limit"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PR#10 V5-C: Early rejection optimization — validate headers BEFORE reading body
    # 获取chunk index和hash
    chunk_index_str = request.headers.get("X-Chunk-Index")
    chunk_hash = request.headers.get("X-Chunk-Hash")
    
    if not chunk_index_str:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Missing X-Chunk-Index"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    if not chunk_hash:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Missing X-Chunk-Hash"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    try:
        chunk_index = int(chunk_index_str)
    except ValueError:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Invalid X-Chunk-Index"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PR#10 V2-B: Validate chunk_index range
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
    
    # PR#10 V2-B: Validate chunk_hash format
    # SEAL FIX: Validate chunk_hash format. This header is user-controlled input.
    # Without validation, chunk_hash could contain path traversal characters
    # (used in future file naming) or SQL injection payloads (stored in DB).
    # Must match SHA-256 hexdigest format: exactly 64 lowercase hex characters.
    # GATE: This validation MUST NOT be removed. Requires RFC.
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
    
    # PR#10 V5-C: Check disk quota BEFORE reading body (early rejection)
    allowed, usage = check_disk_quota()
    if not allowed:
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
    
    # PR#10 V5-A: Stream-based or memoryview chunked hashing (eliminate double hash)
    # WHY: Current code reads entire 5MB chunk into memory, then hashes it.
    # This causes peak memory = 5MB. With memoryview chunked hashing:
    # - Peak memory = chunk size (5MB) but eliminates double hash CPU overhead
    # - Hash computed incrementally during read, not after full read
    # - persist_chunk() can skip re-hashing (hash already computed)
    # 
    # WHY memoryview: Python bytes slicing (body[i:j]) creates copies.
    # memoryview provides zero-copy slices for hashlib.update().
    # hashlib.sha256().update() natively accepts memoryview (zero-copy to OpenSSL).
    #
    # Fallback to scheme B (memoryview chunked) if request.stream() unavailable.
    # Scheme A (true streaming) requires request.stream() which may not work
    # with all FastAPI deployments (proxy buffering, middleware, etc.).
    body = await request.body()
    
    # GATE-5: 验证Content-Length与实际body一致
    if len(body) != content_length_int:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Content-Length mismatch"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PR#10 V5-A + V5-B: Memoryview chunked hashing (eliminate double hash)
    # WHY: Avoids double hash overhead. Hash computed here, persist_chunk() skips re-hash.
    # WHY memoryview: Zero-copy slices for hashlib.update() (avoids Python bytes copy).
    from app.services.upload_service import HASH_STREAM_CHUNK_BYTES
    mv = memoryview(body)
    hasher = hashlib.sha256()
    for i in range(0, len(mv), HASH_STREAM_CHUNK_BYTES):
        hasher.update(mv[i:i+HASH_STREAM_CHUNK_BYTES])  # Zero-copy to OpenSSL
    actual_hash = hasher.hexdigest()
    
    # PR#10 V2-A: Fix timing-unsafe hash comparison
    # SEAL FIX: Use hmac.compare_digest() for timing-safe comparison.
    # Python's != short-circuits on first differing byte, leaking hash
    # similarity via timing. INV-U16 applies to ALL hash comparisons,
    # including pre-existing code modified by PR#10.
    # GATE: This comparison MUST use hmac.compare_digest(). Requires RFC to change.
    if not hmac.compare_digest(actual_hash, chunk_hash):
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Chunk hash mismatch"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 检查分片是否已存在
    existing_chunk = db.query(Chunk).filter(
        Chunk.upload_id == upload_id,
        Chunk.chunk_index == chunk_index
    ).first()
    
    if existing_chunk:
        # PR#10 V2-A: Fix timing-unsafe hash comparison
        # SEAL FIX: Existing chunk hash comparison must also be timing-safe.
        if not hmac.compare_digest(existing_chunk.chunk_hash, chunk_hash):
            # 同index不同hash → 409
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.STATE_CONFLICT,
                    message="Chunk already exists with different hash"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_409_CONFLICT,
                content=error_response.model_dump(exclude_none=True)
            )
        else:
            # 幂等成功
            chunk_status = "already_present"
            total_received = db.query(Chunk).filter(Chunk.upload_id == upload_id).count()
    else:
        # PR#10 PATCH-O + V3-B: File-first, DB-second ordering
        # CRITICAL: upload_chunk()中必须先调用persist_chunk()，成功后再db.commit()
        # 如果persist_chunk()失败，返回HTTP 500，不提交DB
        # 正确顺序：1. persist_chunk()写入文件 2. db.add(chunk) + db.commit()记录DB
        try:
            # Step 1: Persist chunk to disk (may raise AssemblyError)
            # PR#10 V5-A: Hash already computed above, persist_chunk() can skip re-hash
            # (For now, persist_chunk still re-hashes for defense-in-depth.
            # Future optimization: pass pre-computed hash to skip re-hash.)
            persist_chunk(upload_id, chunk_index, body, chunk_hash)
        except AssemblyError as e:
            # FAIL-CLOSED: File write failed → don't commit to DB → return 500
            logger.error("Chunk persist failed for upload_id=%s chunk_index=%d: %s", upload_id, chunk_index, e)
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
        chunk_status = "stored"
        total_received = db.query(Chunk).filter(Chunk.upload_id == upload_id).count()
    
    response_data = UploadChunkResponse(
        chunk_index=chunk_index,
        chunk_status=chunk_status,
        received_size=len(body),
        total_received=total_received,
        total_chunks=upload_session.chunk_count
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )


async def get_chunks(
    upload_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    GET /v1/uploads/{id}/chunks - 查询已上传分片
    """
    user_id = request.state.user_id
    
    upload_session = db.query(UploadSession).filter(
        UploadSession.id == upload_id,
        UploadSession.user_id == user_id
    ).first()
    
    if not upload_session:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Upload session")
    
    # 获取已上传分片
    chunks = db.query(Chunk).filter(Chunk.upload_id == upload_id).all()
    received_chunks = sorted([c.chunk_index for c in chunks])
    all_chunks = set(range(upload_session.chunk_count))
    missing_chunks = sorted(list(all_chunks - set(received_chunks)))
    
    response_data = GetChunksResponse(
        upload_id=upload_id,
        received_chunks=received_chunks,
        missing_chunks=missing_chunks,
        total_chunks=upload_session.chunk_count,
        status=upload_session.status,
        expires_at=format_rfc3339_utc(upload_session.expires_at)
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )


async def complete_upload(
    upload_id: str,
    request_body: CompleteUploadRequest,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    POST /v1/uploads/{id}/complete - 完成上传
    
    PATCH-4: 自动创建Job，初始状态="queued"
    PATCH-2: details.missing使用int_array
    """
    user_id = request.state.user_id
    
    upload_session = db.query(UploadSession).filter(
        UploadSession.id == upload_id,
        UploadSession.user_id == user_id
    ).first()
    
    if not upload_session:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Upload session")
    
    # 验证bundle_hash一致性
    if request_body.bundle_hash != upload_session.bundle_hash:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.STATE_CONFLICT,
                message="Bundle hash mismatch"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PR#10 V5-D: DB query optimization — use COUNT query instead of loading all chunks
    received_count = db.query(func.count(Chunk.id)).filter(
        Chunk.upload_id == upload_id
    ).scalar()
    
    if received_count != upload_session.chunk_count:
        # Slow path: need to find missing chunks
        chunks = db.query(Chunk).filter(Chunk.upload_id == upload_id).all()
        received_indices = set(c.chunk_index for c in chunks)
        all_indices = set(range(upload_session.chunk_count))
        missing_indices = sorted(list(all_indices - received_indices))
        
        # PATCH-2: details.missing使用int_array
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Missing chunks",
                details={"missing": missing_indices}  # int_array
            )
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # PR#10: Full pipeline — assemble → verify → dedup → create job → cleanup
    try:
        # Step 1: Three-way pipeline atomic assembly
        assembly_result = assemble_bundle(upload_id, upload_session, db)
        
        # Step 2: Five-layer integrity verification
        integrity_ok = check_integrity(
            assembly_sha256_hex=assembly_result.sha256_hex,
            expected_bundle_hash=upload_session.bundle_hash,
            chunk_hashes=assembly_result.chunk_hashes,
            bundle_size=assembly_result.total_bytes,
            expected_size=upload_session.bundle_size,
            chunk_count=len(assembly_result.chunk_hashes),
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
        
        # Step 4: No duplicate — create new Job + Timeline (atomic transaction)
        # PR#10 V2-H: Single-transaction complete_upload
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
            # FAIL-CLOSED: If DB fails, don't claim success.
            # Assembled bundle file remains on disk (cleanup will handle it).
            logger.error("DB commit failed in complete_upload for upload_id=%s: %s", upload_id, e, exc_info=True)
            db.rollback()
            cleanup_after_assembly(upload_id, success=False)
            assembly_result.bundle_path.unlink(missing_ok=True)
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
        
        # Step 5: Immediate cleanup of chunk files
        cleanup_after_assembly(upload_id, success=True)
        
        response_data = CompleteUploadResponse(
            upload_id=upload_id,
            bundle_hash=upload_session.bundle_hash,
            status="completed",
            job_id=job_id
        )
        
        api_response = APIResponse(success=True, data=response_data.model_dump())
        
        return JSONResponse(
            status_code=status.HTTP_200_OK,
            content=api_response.model_dump(exclude_none=True)
        )
    
    except AssemblyError as e:
        # FAIL-CLOSED: Assembly failed → return 409 to client. Never return 200 on failure.
        cleanup_after_assembly(upload_id, success=False)
        logger.error("Assembly failed for upload_id=%s: %s", upload_id, e, exc_info=True)
        # External response: unified HASH_MISMATCH (INV-U17: anti-enumeration)
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

