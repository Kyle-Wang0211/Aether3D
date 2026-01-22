# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""限流中间件（基于X-Device-Id，PATCH-1）"""

import time
from collections import defaultdict
from typing import Dict, List

from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.api.contract import APIError, APIErrorCode, APIResponse
from app.api.contract_constants import APIContractConstants

# GATE-8: /health端点豁免
EXEMPT_PATHS = ["/v1/health"]

# 端点限流规则（次/分钟）
RATE_LIMIT_RULES: Dict[str, int] = {
    "POST /v1/uploads": APIContractConstants.RATE_LIMIT_UPLOADS_PER_MINUTE,
    "PATCH /v1/uploads": APIContractConstants.RATE_LIMIT_CHUNKS_PER_MINUTE,
    "POST /v1/jobs": APIContractConstants.RATE_LIMIT_JOBS_PER_MINUTE,
    "GET /v1/jobs": APIContractConstants.RATE_LIMIT_QUERIES_PER_MINUTE,
    "POST /v1/jobs/cancel": APIContractConstants.RATE_LIMIT_JOBS_PER_MINUTE,
    "GET /v1/artifacts": APIContractConstants.RATE_LIMIT_QUERIES_PER_MINUTE,
}


class RateLimitMiddleware(BaseHTTPMiddleware):
    """限流中间件（基于X-Device-Id，PATCH-1）"""
    
    def __init__(self, app):
        super().__init__(app)
        # device_id -> endpoint -> [timestamps]
        self.request_counts: Dict[str, Dict[str, List[float]]] = defaultdict(lambda: defaultdict(list))
    
    def _get_endpoint_key(self, request: Request) -> str:
        """获取端点限流key"""
        method = request.method
        path = request.url.path
        
        # 匹配端点模式
        if path.startswith("/v1/uploads") and method == "POST":
            return "POST /v1/uploads"
        elif path.startswith("/v1/uploads") and method == "PATCH":
            return "PATCH /v1/uploads"
        elif path.startswith("/v1/jobs") and method == "POST":
            if path.endswith("/cancel"):
                return "POST /v1/jobs/cancel"
            return "POST /v1/jobs"
        elif path.startswith("/v1/jobs") and method == "GET":
            return "GET /v1/jobs"
        elif path.startswith("/v1/artifacts") and method == "GET":
            return "GET /v1/artifacts"
        
        # 默认不限流
        return None
    
    async def dispatch(self, request: Request, call_next):
        # GATE-8: /health豁免
        if request.url.path in EXEMPT_PATHS:
            return await call_next(request)
        
        # 获取device_id（应该已经通过identity middleware设置）
        device_id = getattr(request.state, "device_id", None)
        if not device_id:
            # 如果没有device_id，跳过限流（identity middleware会处理认证）
            return await call_next(request)
        
        # 获取端点限流key
        endpoint_key = self._get_endpoint_key(request)
        if not endpoint_key or endpoint_key not in RATE_LIMIT_RULES:
            # 不限流的端点
            return await call_next(request)
        
        limit = RATE_LIMIT_RULES[endpoint_key]
        window_seconds = 60  # 1分钟窗口
        
        # 清理旧记录
        current_time = time.time()
        cutoff_time = current_time - window_seconds
        self.request_counts[device_id][endpoint_key] = [
            ts for ts in self.request_counts[device_id][endpoint_key]
            if ts > cutoff_time
        ]
        
        # 检查限流
        if len(self.request_counts[device_id][endpoint_key]) >= limit:
            error_response = APIResponse(
                success=False,
                error=APIError(
                    code=APIErrorCode.RATE_LIMITED,
                    message="Too many requests",
                    details={"retry_after": str(window_seconds)}
                )
            )
            response = JSONResponse(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                content=error_response.model_dump(exclude_none=True)
            )
            # 添加限流headers
            response.headers["Retry-After"] = str(window_seconds)
            response.headers["X-RateLimit-Limit"] = str(limit)
            response.headers["X-RateLimit-Remaining"] = "0"
            response.headers["X-RateLimit-Reset"] = str(int(current_time + window_seconds))
            return response
        
        # 记录请求
        self.request_counts[device_id][endpoint_key].append(current_time)
        
        return await call_next(request)
