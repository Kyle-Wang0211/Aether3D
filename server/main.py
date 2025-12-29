from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.routes import router
from app.core.config import settings
from app.core.errors import AppError
from app.database import Base, engine
from app.middleware.auth import AuthMiddleware
from app.middleware.rate_limit import RateLimitMiddleware


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan context manager for startup/shutdown."""
    # Create database tables
    Base.metadata.create_all(bind=engine)
    yield
    # Cleanup (if needed)


app = FastAPI(
    title="Aether3D API",
    description="3D Gaussian Splatting Generation API",
    version="0.1.0",
    lifespan=lifespan,
    debug=settings.debug,
)

# Add middleware
app.add_middleware(AuthMiddleware)
app.add_middleware(RateLimitMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include API router with /api/v1 prefix
app.include_router(router, prefix="/api/v1")

# Health check endpoint (root path, not under /api/v1)
@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "ok"}


# Global exception handler
@app.exception_handler(AppError)
async def app_error_handler(request: Request, exc: AppError):
    """Handle AppError exceptions."""
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content={"error": exc.code, "message": exc.message},
    )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Handle all other exceptions."""
    error_code = "INTERNAL_ERROR"
    error_message = "Internal server error"
    
    if settings.debug:
        error_message = str(exc)
    
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"error": error_code, "message": error_message},
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

