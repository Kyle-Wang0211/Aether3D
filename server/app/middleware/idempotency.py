from __future__ import annotations

from typing import Awaitable, Callable, Optional
import hashlib
import json
import time

from fastapi import Request, Response, status
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from app.api.contract import APIError, APIErrorCode, APIResponse, compute_payload_hash
from app.api.contract_constants import APIContractConstants

# In-memory cache: scope is enforced by cache_key construction.
# value: (payload_hash, stored_response_json, status_code, stored_at_epoch)
_idempotency_cache: dict[str, tuple[str, dict, int, float]] = {}


def _canonicalize_path(path: str) -> str:
    if path != "/" and path.endswith("/"):
        return path[:-1]
    return path


def _build_cache_key(user_id: str, method: str, path: str, idempotency_key: str) -> str:
    """
    Build idempotency cache key from (user_id, method, canonical_path, idempotency_key).
    
    Args:
        user_id: User identifier
        method: HTTP method
        path: Request path (will be canonicalized)
        idempotency_key: Idempotency key
    
    Returns:
        Cache key string
    """
    canonical_path = _canonicalize_path(path)
    return f"{user_id}:{method}:{canonical_path}:{idempotency_key}"


def resolve_user_id_or_400(request: Request) -> tuple[str, Optional[JSONResponse]]:
    """
    MUST NOT skip. Resolve identity deterministically.
    Order:
      1) request.state.user_id
      2) X-Device-Id header
      3) return error response (closed-world)
    Also inject back into request.state.user_id for consistency.
    
    Returns:
        (user_id, None) if successful
        (None, error_response) if identity missing
    """
    user_id = getattr(request.state, "user_id", None)
    if not user_id:
        user_id = request.headers.get("X-Device-Id")
    if not user_id:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.INVALID_REQUEST,
                message="Missing user identity"
            )
        )
        return None, JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=error_response.model_dump(exclude_none=True)
        )
    request.state.user_id = user_id
    return user_id, None


class IdempotencyMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        # Only enforce idempotency for write methods (keep existing behavior conservative)
        if request.method not in ("POST", "PUT", "PATCH"):
            return await call_next(request)

        # Read body ONCE (Starlette caches request.body())
        body_bytes: bytes = b""
        try:
            body_bytes = await request.body()
        except Exception:
            body_bytes = b""

        # Extract idempotency_key: header preferred, then JSON body fallback
        idempotency_key: Optional[str] = request.headers.get("X-Idempotency-Key")
        if not idempotency_key and body_bytes:
            try:
                body_dict = json.loads(body_bytes)
                if isinstance(body_dict, dict):
                    idempotency_key = body_dict.get("idempotency_key")
            except Exception:
                idempotency_key = None

        # If no idempotency requested, proceed normally
        if not idempotency_key:
            return await call_next(request)

        # Resolve identity (MUST NOT SKIP)
        user_id, error_response = resolve_user_id_or_400(request)
        if error_response is not None:
            return error_response

        # Scope: (user_id, method, canonical_path, key)
        cache_key = _build_cache_key(user_id, request.method, request.url.path, idempotency_key)

        # Compute payload hash (existing contract helper)
        # PR1E: parse JSON dict first, fallback to raw bytes hash for non-JSON/non-dict
        if body_bytes:
            try:
                body_dict = json.loads(body_bytes)
                if isinstance(body_dict, dict):
                    payload_hash = compute_payload_hash(body_dict)
                else:
                    # Non-dict JSON (array, string, etc.) - hash raw bytes
                    payload_hash = hashlib.sha256(body_bytes).hexdigest()
            except (json.JSONDecodeError, ValueError, TypeError):
                # Non-JSON body - hash raw bytes
                payload_hash = hashlib.sha256(body_bytes).hexdigest()
        else:
            # Empty body
            payload_hash = hashlib.sha256(b"").hexdigest()

        # Check cache
        cached = _idempotency_cache.get(cache_key)
        if cached is not None:
            cached_hash, cached_body, cached_status, _ts = cached
            if cached_hash != payload_hash:
                # Same key, different payload => 409 STATE_CONFLICT
                error_response = APIResponse(
                    success=False,
                    error=APIError(
                        code=APIErrorCode.STATE_CONFLICT,
                        message="Idempotency key reuse with different payload (payload mismatch)",
                    )
                )
                return JSONResponse(
                    status_code=status.HTTP_409_CONFLICT,
                    content=error_response.model_dump(exclude_none=True)
                )
            return JSONResponse(status_code=cached_status, content=cached_body)

        # Execute request
        response = await call_next(request)

        # Store successful responses only (contract: return original result)
        if response.status_code in (200, 201):
            try:
                # Starlette Response may not have .body; ensure we read iterator safely
                raw = b""
                async for chunk in response.body_iterator:
                    raw += chunk

                # Attempt to parse JSON body for caching. If not JSON, skip caching safely.
                try:
                    parsed = json.loads(raw.decode("utf-8")) if raw else {}
                    if not isinstance(parsed, dict):
                        # Only cache dict-like APIResponse envelopes
                        return Response(
                            content=raw, status_code=response.status_code, headers=dict(response.headers), media_type=response.media_type
                        )
                except Exception:
                    return Response(
                        content=raw, status_code=response.status_code, headers=dict(response.headers), media_type=response.media_type
                    )

                # Cache
                _idempotency_cache[cache_key] = (payload_hash, parsed, response.status_code, time.time())

                # Return the rebuilt response (because body_iterator already consumed)
                return JSONResponse(status_code=response.status_code, content=parsed, headers=dict(response.headers))
            except Exception:
                # Fail-open: do not break success path
                return response

        return response
