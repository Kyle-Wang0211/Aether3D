# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""请求大小强制中间件（PATCH-8）"""

from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.api.contract import APIError, APIErrorCode, APIResponse
from app.api.contract_constants import APIContractConstants


class RequestSizeMiddleware(BaseHTTPMiddleware):
    """请求大小强制中间件（PATCH-8）"""
    
    async def dispatch(self, request: Request, call_next):
        # PATCH-8: Header大小检查（8KB → 400 INVALID_REQUEST）
        header_size = sum(
            len(key.encode('utf-8')) + len(value.encode('utf-8')) + 4  # +4 for ": \r\n"
            for key, value in request.headers.items()
        )
        
        if header_size > APIContractConstants.MAX_HEADER_SIZE_BYTES:
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.INVALID_REQUEST,
                    message="Request header too large"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=error_response.model_dump(exclude_none=True)
            )
        
        # PATCH-8: JSON body大小检查（64KB → 413 PAYLOAD_TOO_LARGE）
        # 仅对application/json检查
        content_type = request.headers.get("content-type", "")
        if content_type.startswith("application/json"):
            # 读取body检查大小
            body = await request.body()
            if len(body) > APIContractConstants.MAX_JSON_BODY_SIZE_BYTES:
                error_response = APIResponse(
                    success=False,
                    error=APIError(
                        code=APIErrorCode.PAYLOAD_TOO_LARGE,
                        message="Request body too large"
                    )
                )
                return JSONResponse(
                    status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                    content=error_response.model_dump(exclude_none=True)
                )
            
            # 重新创建request body（已被消费）
            async def receive():
                return {"type": "http.request", "body": body}
            request._receive = receive
        
        return await call_next(request)

