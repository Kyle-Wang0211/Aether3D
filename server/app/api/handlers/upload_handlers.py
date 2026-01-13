# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""上传处理器（4个端点）"""

import hashlib
import uuid
from datetime import datetime, timedelta
from typing import List

from fastapi import Depends, Request, status
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from app.api.contract import (
    APIError, APIErrorCode, APIResponse, CompleteUploadRequest,
    CompleteUploadResponse, CreateUploadRequest, CreateUploadResponse,
    GetChunksResponse, UploadChunkResponse, format_rfc3339_utc
)
from app.api.contract_constants import APIContractConstants
from app.database import get_db
from app.models import Chunk, Job, TimelineEvent, UploadSession


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
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Upload session not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
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
    
    # 读取分片数据
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
    
    # 验证chunk hash
    actual_hash = hashlib.sha256(body).hexdigest()
    if actual_hash != chunk_hash:
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
        if existing_chunk.chunk_hash != chunk_hash:
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
        # 保存新分片
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
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Upload session not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
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
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Upload session not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
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
    
    # 检查所有分片是否已上传
    chunks = db.query(Chunk).filter(Chunk.upload_id == upload_id).all()
    received_indices = set(c.chunk_index for c in chunks)
    all_indices = set(range(upload_session.chunk_count))
    missing_indices = sorted(list(all_indices - received_indices))
    
    if missing_indices:
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
    
    # 更新上传会话状态
    upload_session.status = "completed"
    db.commit()
    
    # PATCH-4: 自动创建Job，初始状态="queued"
    job_id = str(uuid.uuid4())
    job = Job(
        id=job_id,
        user_id=user_id,
        bundle_hash=upload_session.bundle_hash,
        state="queued"  # PATCH-4
    )
    db.add(job)
    
    # 创建时间线事件
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

