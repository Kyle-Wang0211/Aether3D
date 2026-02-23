from fastapi import Request, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.core.config import settings


class AuthMiddleware(BaseHTTPMiddleware):
    """Authentication middleware using API key."""
    
    WHITELIST_PATHS = [
        "/health",
        "/docs",
        "/openapi.json",
        "/redoc",
    ]
    
    async def dispatch(self, request: Request, call_next):
        # If API_KEY is empty, disable auth
        if not settings.api_key:
            return await call_next(request)
        
        # Check whitelist (exact match or startswith for /docs/*)
        path = request.url.path
        if any(
            path == whitelist_path or path.startswith(whitelist_path + "/")
            for whitelist_path in self.WHITELIST_PATHS
        ):
            return await call_next(request)
        
        # Check API key
        api_key = request.headers.get("X-API-Key")
        if api_key != settings.api_key:
            return JSONResponse(
                status_code=status.HTTP_401_UNAUTHORIZED,
                content={"error": "UNAUTHORIZED", "message": "Invalid or missing API key"},
            )
        
        return await call_next(request)

