import time
from collections import defaultdict
from typing import Dict, List

from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware


class RateLimitMiddleware(BaseHTTPMiddleware):
    """Rate limiting middleware."""
    
    RATE_LIMIT_REQUESTS = 60
    RATE_LIMIT_WINDOW = 60  # seconds
    
    def __init__(self, app):
        super().__init__(app)
        self.request_counts: Dict[str, List[float]] = defaultdict(list)
    
    def _get_client_ip(self, request: Request) -> str:
        """Get client IP, handling reverse proxy."""
        # Check X-Forwarded-For header
        forwarded_for = request.headers.get("X-Forwarded-For")
        if forwarded_for:
            return forwarded_for.split(",")[0].strip()
        
        # Fallback to direct client
        if request.client:
            return request.client.host
        
        return "unknown"
    
    async def dispatch(self, request: Request, call_next):
        # Get client IP
        client_ip = self._get_client_ip(request)
        
        # Clean old entries
        current_time = time.time()
        cutoff_time = current_time - self.RATE_LIMIT_WINDOW
        self.request_counts[client_ip] = [
            ts for ts in self.request_counts[client_ip] if ts > cutoff_time
        ]
        
        # Check rate limit
        if len(self.request_counts[client_ip]) >= self.RATE_LIMIT_REQUESTS:
            return JSONResponse(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                content={
                    "error": "RATE_LIMIT_EXCEEDED",
                    "message": f"Rate limit exceeded: {self.RATE_LIMIT_REQUESTS} requests per {self.RATE_LIMIT_WINDOW} seconds",
                },
            )
        
        # Record request
        self.request_counts[client_ip].append(current_time)
        
        return await call_next(request)

