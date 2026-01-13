# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""幂等性中间件（PATCH-7：canonical JSON hash）"""

from typing import Optional
from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.api.contract import APIError, APIErrorCode, APIResponse, compute_payload_hash
from app.api.contract_constants import APIContractConstants

# 简单的内存缓存（生产环境应使用Redis等）
_idempotency_cache: dict[str, tuple[str, float]] = {}  # key -> (payload_hash, timestamp)


class IdempotencyMiddleware(BaseHTTPMiddleware):
    """幂等性检查中间件（PATCH-7）"""
    
    async def dispatch(self, request: Request, call_next):
        # 仅对POST/PATCH请求检查幂等性
        if request.method not in ["POST", "PATCH"]:
            return await call_next(request)
        
        # 获取idempotency_key（从header或body）
        idempotency_key: Optional[str] = None
        
        # 尝试从header获取
        idempotency_key = request.headers.get("X-Idempotency-Key")
        
        # 如果header没有，尝试从body获取（仅JSON）
        if not idempotency_key and request.headers.get("content-type", "").startswith("application/json"):
            try:
                body = await request.body()
                if body:
                    import json
                    body_dict = json.loads(body)
                    idempotency_key = body_dict.get("idempotency_key")
                    # 重新创建request body（已被消费）
                    async def receive():
                        return {"type": "http.request", "body": body}
                    request._receive = receive
            except Exception:
                pass
        
        if not idempotency_key:
            return await call_next(request)
        
        # 计算payload hash（PATCH-7：canonical JSON）
        try:
            body = await request.body()
            if body:
                import json
                payload = json.loads(body)
                payload_hash = compute_payload_hash(payload)
                
                # 检查缓存
                if idempotency_key in _idempotency_cache:
                    cached_hash, _ = _idempotency_cache[idempotency_key]
                    if cached_hash != payload_hash:
                        # 同key不同payload → 409 STATE_CONFLICT
                        error_response = APIResponse(
                            success=False,
                            error=APIError(
                                code=APIErrorCode.STATE_CONFLICT,
                                message="Idempotency key conflict: payload mismatch",
                                details={
                                    "expected_payload_hash": cached_hash,
                                    "actual_payload_hash": payload_hash
                                }
                            )
                        )
                        return JSONResponse(
                            status_code=status.HTTP_409_CONFLICT,
                            content=error_response.model_dump(exclude_none=True)
                        )
                    # 同key同payload → 幂等成功，继续处理（handler会返回已存在的结果）
                
                # 缓存payload hash（24小时TTL）
                import time
                _idempotency_cache[idempotency_key] = (payload_hash, time.time())
                
                # 重新创建request body
                async def receive():
                    return {"type": "http.request", "body": body}
                request._receive = receive
        except Exception:
            # JSON解析失败等错误，交给后续处理器处理
            pass
        
        return await call_next(request)

