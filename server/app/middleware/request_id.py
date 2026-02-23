# PR1E — API Contract Hardening Patch
# Request-Id Forwarding (Strict Validation + Always Present)

"""Request-Id中间件（GATE-7 + PR1E严格验证）"""

import re
import uuid
from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

# PR1E: X-Request-Id格式严格验证：^[A-Za-z0-9_-]{8,64}$
# 最小8字符，最大64字符，只允许字母、数字、下划线、连字符
REQUEST_ID_PATTERN = re.compile(r'^[A-Za-z0-9_-]{8,64}$')


class RequestIdMiddleware(BaseHTTPMiddleware):
    """Request-Id处理中间件（GATE-7）"""
    
    async def dispatch(self, request: Request, call_next):
        # 获取客户端传入的X-Request-Id
        client_request_id = request.headers.get("X-Request-Id", "")
        
        # 格式校验
        if client_request_id and REQUEST_ID_PATTERN.match(client_request_id):
            request_id = client_request_id
        else:
            # 格式非法或未提供，生成新ID
            request_id = f"req_{uuid.uuid4().hex[:16]}"
        
        # 存储到request state
        request.state.request_id = request_id
        
        # 调用下一个中间件/处理器
        response = await call_next(request)
        
        # GATE-7: 所有响应（包括错误和二进制下载）必须包含X-Request-Id
        if isinstance(response, Response):
            response.headers["X-Request-Id"] = request_id
        
        return response

