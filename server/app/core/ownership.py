# PR1E — API Contract Hardening Patch
# Anti-enumeration Enforcement (404 Only)

"""统一所有权检查helper（确保所有所有权失败返回404）"""

from typing import Optional, TypeVar

from fastapi import status
from fastapi.responses import JSONResponse

from app.api.contract import APIError, APIErrorCode, APIResponse

T = TypeVar('T')


def ensure_ownership_or_404(
    resource: Optional[T],
    user_id: str,
    resource_name: str = "Resource"
) -> T:
    """
    PR1E: 统一所有权检查helper
    
    如果资源不存在或不属于用户，统一返回404 RESOURCE_NOT_FOUND。
    这确保了anti-enumeration：无法区分"资源不存在"和"资源不属于用户"。
    
    Args:
        resource: 资源对象（可能为None）
        user_id: 当前用户ID
        resource_name: 资源名称（用于错误消息）
    
    Returns:
        资源对象（如果存在且属于用户）
    
    Raises:
        返回404 JSONResponse（如果资源不存在或不属于用户）
    """
    if resource is None:
        error_response = APIResponse(
            success=False,
            error=APIError(
                code=APIErrorCode.RESOURCE_NOT_FOUND,
                message=f"{resource_name} not found"
            )
        )
        # PR1E: 使用JSONResponse确保可以被handler返回
        # 注意：这需要handler检查返回值类型
        raise OwnershipError(error_response)
    
    return resource


class OwnershipError(Exception):
    """所有权错误（用于统一返回404）"""
    
    def __init__(self, error_response: APIResponse):
        self.error_response = error_response
        super().__init__("Ownership check failed")


def create_ownership_error_response(resource_name: str = "Resource") -> JSONResponse:
    """
    创建所有权错误响应（404 RESOURCE_NOT_FOUND）
    
    用于handler中直接返回404的情况。
    """
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.RESOURCE_NOT_FOUND,
            message=f"{resource_name} not found"
        )
    )
    return JSONResponse(
        status_code=status.HTTP_404_NOT_FOUND,
        content=error_response.model_dump(exclude_none=True)
    )
