# PR#3 — API Contract v2.0
# Stage: WHITEBOX | Camera-only
# Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

"""主应用（PATCH-5, GATE-2, GATE-3：框架覆盖）"""

from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.routing import NoMatchFound

from app.api.contract import APIError, APIErrorCode, APIResponse
from app.api.routes import router
from app.core.config import settings
from app.database import Base, engine
from app.middleware.idempotency import IdempotencyMiddleware
from app.middleware.identity import IdentityMiddleware
from app.middleware.rate_limit import RateLimitMiddleware
from app.middleware.request_id import RequestIdMiddleware
from app.middleware.request_size import RequestSizeMiddleware


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan context manager for startup/shutdown."""
    # Create database tables
    Base.metadata.create_all(bind=engine)
    
    # PR#10: Run global cleanup on startup
    from app.database import SessionLocal
    from app.services.cleanup_handler import cleanup_global
    import logging
    logger = logging.getLogger(__name__)
    db = SessionLocal()
    try:
        result = cleanup_global(db)
        logger.info("Startup cleanup completed: %s", result.to_dict())
    finally:
        db.close()
    
    yield
    # Cleanup (if needed)


# GATE-3: 禁用尾斜杠重定向
app = FastAPI(
    title="Aether3D API",
    description="3D Gaussian Splatting Generation API",
    version="0.1.0",
    lifespan=lifespan,
    debug=settings.debug,
    redirect_slashes=False  # GATE-3
)

# 中间件顺序（重要）：
# 1. Request-Id（最外层，所有响应都需要）
# 2. Request Size（PATCH-8：header和JSON body大小检查）
# 3. Identity（X-Device-Id校验）
# 4. Rate Limit（基于device_id）
# 5. Idempotency（幂等性检查）
app.add_middleware(RequestIdMiddleware)
app.add_middleware(RequestSizeMiddleware)
app.add_middleware(IdentityMiddleware)
app.add_middleware(RateLimitMiddleware)
app.add_middleware(IdempotencyMiddleware)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 注册路由（前缀：/v1，不是/api/v1）
app.include_router(router, prefix="/v1")

# PATCH-5: 全局异常处理器覆盖FastAPI默认

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    """
    PATCH-5: RequestValidationError → 400 INVALID_REQUEST（不是422）
    """
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INVALID_REQUEST,
            message="Invalid request"
        )
    )
    
    # GATE-7: 包含X-Request-Id
    request_id = getattr(request.state, "request_id", None)
    headers = {}
    if request_id:
        headers["X-Request-Id"] = request_id
    
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content=error_response.model_dump(exclude_none=True),
        headers=headers
    )


@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    """
    GATE-2: MethodNotAllowed → 404 RESOURCE_NOT_FOUND（不是405）
    """
    # GATE-2: 405 → 404
    if exc.status_code == status.HTTP_405_METHOD_NOT_ALLOWED:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message="Resource not found"
            )
        )
        # PR1E: 返回404状态码，不是405
        http_status = status.HTTP_404_NOT_FOUND
    else:
        # 其他HTTP异常映射到业务错误码
        error_code = APIErrorCode.INTERNAL_ERROR
        if exc.status_code == status.HTTP_401_UNAUTHORIZED:
            error_code = APIErrorCode.AUTH_FAILED
        elif exc.status_code == status.HTTP_404_NOT_FOUND:
            error_code = APIErrorCode.RESOURCE_NOT_FOUND
        elif exc.status_code == status.HTTP_409_CONFLICT:
            error_code = APIErrorCode.STATE_CONFLICT
        elif exc.status_code == status.HTTP_413_REQUEST_ENTITY_TOO_LARGE:
            error_code = APIErrorCode.PAYLOAD_TOO_LARGE
        elif exc.status_code == status.HTTP_429_TOO_MANY_REQUESTS:
            error_code = APIErrorCode.RATE_LIMITED
        
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=error_code,
                message=exc.detail if exc.detail else "Request failed"
            )
        )
        
        # 确保状态码在闭集中
        http_status = exc.status_code
        if http_status not in [200, 201, 206, 400, 401, 404, 409, 413, 429, 500]:
            http_status = status.HTTP_500_INTERNAL_SERVER_ERROR
    
    # GATE-7: 包含X-Request-Id
    request_id = getattr(request.state, "request_id", None)
    headers = {}
    if request_id:
        headers["X-Request-Id"] = request_id
    
    return JSONResponse(
        status_code=http_status,
        content=error_response.model_dump(exclude_none=True),
        headers=headers
    )


@app.exception_handler(NoMatchFound)
async def no_match_found_handler(request: Request, exc: NoMatchFound):
    """
    PATCH-6: 未知端点/方法 → 404 RESOURCE_NOT_FOUND
    """
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.RESOURCE_NOT_FOUND,
            message="Resource not found"
        )
    )
    
    # GATE-7: 包含X-Request-Id
    request_id = getattr(request.state, "request_id", None)
    headers = {}
    if request_id:
        headers["X-Request-Id"] = request_id
    
    return JSONResponse(
        status_code=status.HTTP_404_NOT_FOUND,
        content=error_response.model_dump(exclude_none=True),
        headers=headers
    )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """
    全局异常处理器（兜底）
    """
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INTERNAL_ERROR,
            message="Internal server error"
        )
    )
    
    # GATE-7: 包含X-Request-Id
    request_id = getattr(request.state, "request_id", None)
    headers = {}
    if request_id:
        headers["X-Request-Id"] = request_id
    
    # 日志记录（生产环境）
    if settings.debug:
        import traceback
        print(f"Unhandled exception: {exc}")
        print(traceback.format_exc())
    
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=error_response.model_dump(exclude_none=True),
        headers=headers
    )


if __name__ == "__main__":
    import uvicorn
    
    # SQLite requires workers=1
    workers = 1 if "sqlite" in settings.database_url else 1
    
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=settings.debug,
        workers=workers,
    )
