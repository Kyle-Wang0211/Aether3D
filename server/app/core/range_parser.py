# PR1E — API Contract Hardening Patch
# Range Contract Tightening (Single-Range Only, Strict Reject)

"""Range解析工具（单range，严格拒绝不支持的格式）"""

from fastapi import status
from fastapi.responses import JSONResponse

from app.api.contract import APIError, APIErrorCode, APIResponse


class RangeParseError(Exception):
    """Range解析错误"""
    pass


def parse_single_range(range_header: str, total_size: int) -> tuple[int, int]:
    """
    PR1E: 解析单Range header，严格拒绝不支持的格式
    
    Args:
        range_header: Range header值（例如 "bytes=0-1023"）
        total_size: 文件总大小（字节）
    
    Returns:
        (start, end): 起始和结束字节位置（包含）
    
    Raises:
        RangeParseError: 如果格式不支持或无效
    """
    # PR1E: 明确拒绝suffix ranges (bytes=-500)
    if range_header.startswith("bytes=-"):
        raise RangeParseError("Suffix ranges not supported")
    
    # PR1E: 明确拒绝open-ended ranges (bytes=500-)
    if range_header.endswith("-") and not range_header.endswith("--"):
        raise RangeParseError("Open-ended ranges not supported")
    
    # PR1E: 明确拒绝多range（包含逗号）
    if "," in range_header:
        raise RangeParseError("Multi-range not supported")
    
    # 解析格式: bytes=start-end
    if not range_header.startswith("bytes="):
        raise RangeParseError("Invalid Range format: must start with 'bytes='")
    
    range_spec = range_header[6:]  # 移除 "bytes=" 前缀
    
    # 解析start-end
    if "-" not in range_spec:
        raise RangeParseError("Invalid Range format: missing '-' separator")
    
    parts = range_spec.split("-", 1)
    if len(parts) != 2:
        raise RangeParseError("Invalid Range format: invalid separator")
    
    start_str, end_str = parts
    
    # 验证start和end都是数字
    try:
        start = int(start_str)
        end = int(end_str)
    except ValueError:
        raise RangeParseError("Invalid Range format: start and end must be integers")
    
    # 验证范围有效性
    if start < 0:
        raise RangeParseError("Range start must be non-negative")
    
    if end < start:
        raise RangeParseError("Range end must be >= start")
    
    if start >= total_size:
        raise RangeParseError("Range start exceeds file size")
    
    if end >= total_size:
        raise RangeParseError("Range end exceeds file size")
    
    return (start, end)


def create_range_error_response(message: str) -> JSONResponse:
    """
    创建Range错误响应（400 INVALID_REQUEST，不是416）
    """
    error_response = APIResponse(
        success=False,
        error=APIError(
            code=APIErrorCode.INVALID_REQUEST,
            message=message
        )
    )
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content=error_response.model_dump(exclude_none=True)
    )
