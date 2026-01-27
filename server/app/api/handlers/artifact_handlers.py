# PR1E — API Contract Hardening Patch
# Range Contract Tightening + Anti-enumeration

"""产物处理器（2个端点）"""

from pathlib import Path

from fastapi import Depends, Request, status
from fastapi.responses import JSONResponse, StreamingResponse
from sqlalchemy.orm import Session

from app.api.contract import APIError, APIErrorCode, APIResponse, GetArtifactResponse, format_rfc3339_utc
from app.core.config import settings
from app.core.range_parser import RangeParseError, create_range_error_response, parse_single_range
from app.database import get_db
from app.models import Artifact


async def get_artifact(
    artifact_id: str,
    request: Request,
    db: Session = Depends(get_db)
) -> JSONResponse:
    """
    GET /v1/artifacts/{id} - 获取产物元信息
    """
    user_id = request.state.user_id
    
    # PR1E: 通过job关联查询（确保ownership，统一返回404）
    artifact = db.query(Artifact).join(Artifact.job).filter(
        Artifact.id == artifact_id,
        Artifact.job.has(user_id=user_id)
    ).first()
    
    if not artifact:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Artifact")
    
    # 过期检查（统一返回404）
    from datetime import datetime
    if datetime.utcnow() > artifact.expires_at:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Artifact")
    
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
    
    # PR1E: 通过job关联查询（确保ownership，统一返回404）
    artifact = db.query(Artifact).join(Artifact.job).filter(
        Artifact.id == artifact_id,
        Artifact.job.has(user_id=user_id)
    ).first()
    
    if not artifact:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Artifact")
    
    # 过期检查（统一返回404）
    from datetime import datetime
    if datetime.utcnow() > artifact.expires_at:
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Artifact")
    
    # 读取文件（文件不存在也返回404）
    file_path = Path(artifact.file_path)
    if not file_path.exists():
        from app.core.ownership import create_ownership_error_response
        return create_ownership_error_response("Artifact")
    
    file_size = artifact.size
    
    # PR1E: 明确拒绝If-Range header
    if request.headers.get("If-Range"):
        return create_range_error_response("If-Range header not supported")
    
    # PR1E: 处理Range请求（使用range_parser）
    range_header = request.headers.get("Range")
    headers = {}
    
    # GATE-7: 包含X-Request-Id
    request_id = getattr(request.state, "request_id", None)
    if request_id:
        headers["X-Request-Id"] = request_id
    
    if range_header:
        try:
            # PR1E: 使用range_parser解析（严格拒绝suffix/open-ended/multi-range）
            start, end = parse_single_range(range_header, file_size)
        except RangeParseError as e:
            # PR1E: 所有Range错误返回400 INVALID_REQUEST（不是416）
            return create_range_error_response(str(e))
        
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

