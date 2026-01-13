# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""产物处理器（2个端点）"""

import re
from pathlib import Path

from fastapi import Depends, Request, status
from fastapi.responses import JSONResponse, StreamingResponse
from sqlalchemy.orm import Session

from app.api.contract import APIError, APIErrorCode, APIResponse, GetArtifactResponse, format_rfc3339_utc
from app.core.config import settings
from app.database import get_db
from app.models import Artifact

# Range格式：bytes=start-end（单Range，PATCH-6）
RANGE_PATTERN = re.compile(r'^bytes=(\d+)-(\d+)$')


async def get_artifact(
    artifact_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    GET /v1/artifacts/{id} - 获取产物元信息
    """
    user_id = request.state.user_id
    
    # 通过job关联查询（确保ownership）
    artifact = db.query(Artifact).join(Artifact.job).filter(
        Artifact.id == artifact_id,
        Artifact.job.has(user_id=user_id)
    ).first()
    
    if not artifact:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Artifact not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 过期检查
    from datetime import datetime
    if datetime.utcnow() > artifact.expires_at:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Artifact not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
    response_data = GetArtifactResponse(
        artifact_id=artifact.id,
        job_id=artifact.job_id,
        format=artifact.format,
        size=artifact.size,
        hash=artifact.hash,
        created_at=format_rfc3339_utc(artifact.created_at),
        expires_at=format_rfc3339_utc(artifact.expires_at),
        download_url=f"/v1/artifacts/{artifact.id}/download"
    )
    
    api_response = APIResponse(success=True, data=response_data.model_dump())
    
    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content=api_response.model_dump(exclude_none=True)
    )


async def download_artifact(
    artifact_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> StreamingResponse:
    """
    GET /v1/artifacts/{id}/download - 下载产物
    
    PATCH-3: 二进制响应（无JSON包装）
    PATCH-6: Range请求支持，无效→400（不是416）
    GATE-7: 包含X-Request-Id header
    """
    user_id = request.state.user_id
    
    # 通过job关联查询（确保ownership）
    artifact = db.query(Artifact).join(Artifact.job).filter(
        Artifact.id == artifact_id,
        Artifact.job.has(user_id=user_id)
    ).first()
    
    if not artifact:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Artifact not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 过期检查
    from datetime import datetime
    if datetime.utcnow() > artifact.expires_at:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Artifact not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
    # 读取文件
    file_path = Path(artifact.file_path)
    if not file_path.exists():
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Artifact file not found"
            )
        )
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=error_response.model_dump(exclude_none=True)
        )
    
    file_size = artifact.size
    
    # 处理Range请求（PATCH-6）
    range_header = request.headers.get("Range")
    headers = {}
    
    # GATE-7: 包含X-Request-Id
    request_id = getattr(request.state, "request_id", None)
    if request_id:
        headers["X-Request-Id"] = request_id
    
    if range_header:
        # PATCH-6: 检查多Range（包含逗号）
        if "," in range_header:
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.INVALID_REQUEST,
                    message="Multi-range not supported"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=error_response.model_dump(exclude_none=True)
            )
        
        # 解析Range header
        match = RANGE_PATTERN.match(range_header)
        if not match:
            # 无效格式 → 400（PATCH-6，不是416）
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.INVALID_REQUEST,
                    message="Invalid Range format"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=error_response.model_dump(exclude_none=True)
            )
        
        start = int(match.group(1))
        end = int(match.group(2))
        
        # 验证范围
        if start > end or start < 0 or end >= file_size:
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.INVALID_REQUEST,
                    message="Range not satisfiable"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=error_response.model_dump(exclude_none=True)
            )
        
        # 206 Partial Content
        range_length = end - start + 1
        headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"
        headers["Content-Length"] = str(range_length)
        headers["Accept-Ranges"] = "bytes"
        headers["ETag"] = f'"{artifact.hash}"'
        headers["Content-Disposition"] = f'attachment; filename="artifact.{artifact.format}"'
        
        def generate():
            with open(file_path, "rb") as f:
                f.seek(start)
                remaining = range_length
                while remaining > 0:
                    chunk_size = min(8192, remaining)
                    chunk = f.read(chunk_size)
                    if not chunk:
                        break
                    yield chunk
                    remaining -= len(chunk)
        
        return StreamingResponse(
            generate(),
            status_code=status.HTTP_206_PARTIAL_CONTENT,
            headers=headers,
            media_type="application/octet-stream"
        )
    else:
        # 200 OK（完整下载）
        headers["Content-Length"] = str(file_size)
        headers["Accept-Ranges"] = "bytes"
        headers["ETag"] = f'"{artifact.hash}"'
        headers["Content-Disposition"] = f'attachment; filename="artifact.{artifact.format}"'
        
        def generate():
            with open(file_path, "rb") as f:
                while True:
                    chunk = f.read(8192)
                    if not chunk:
                        break
                    yield chunk
        
        return StreamingResponse(
            generate(),
            status_code=status.HTTP_200_OK,
            headers=headers,
            media_type="application/octet-stream"
        )

