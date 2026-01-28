# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""身份认证中间件（PATCH-1：X-Device-Id身份模型）"""

import re
from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.api.contract import APIError, APIErrorCode, APIResponse

# UUID v4格式（小写，带连字符）
UUID_V4_PATTERN = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')

# GATE-8: /health端点豁免（包括尾斜杠）
EXEMPT_PATHS = ["/v1/health", "/v1/health/"]


class IdentityMiddleware(BaseHTTPMiddleware):
    """X-Device-Id身份认证中间件（PATCH-1）"""
    
    async def dispatch(self, request: Request, call_next):
        # GATE-8: /health豁免
        if request.url.path in EXEMPT_PATHS:
            return await call_next(request)
        
        # 获取X-Device-Id header
        device_id = request.headers.get("X-Device-Id", "")
        
        # 格式校验
        if not device_id or not UUID_V4_PATTERN.match(device_id):
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.INVALID_REQUEST,
                    message="Missing or invalid X-Device-Id"
                )
            )
            return JSONResponse(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=error_response.model_dump(exclude_none=True)
            )
        
        # 白盒阶段：device_id = user_id（1:1映射）
        request.state.device_id = device_id
        request.state.user_id = device_id  # 1:1映射
        
        return await call_next(request)

